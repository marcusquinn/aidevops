#!/usr/bin/env bash
# worker-watchdog.sh — Detect and kill hung/idle headless AI workers (t1419)
#
# Solves: Headless workers dispatched manually (outside the pulse supervisor)
# have no monitoring. Workers that crash, hang, or enter the OpenCode idle-state
# bug sit indefinitely consuming resources and blocking issue re-dispatch.
#
# Three failure modes detected:
#   1. CPU idle: Worker completed but sits in file-watcher (OpenCode idle bug).
#      Signal: tree CPU < WORKER_IDLE_CPU_THRESHOLD for WORKER_IDLE_TIMEOUT.
#   2. Progress stall: Worker is running but producing no output (stuck on API,
#      rate-limited, spinning). Signal: no log growth for WORKER_PROGRESS_TIMEOUT.
#   3. Runtime ceiling: Worker has been running too long regardless of activity.
#      Signal: elapsed > WORKER_MAX_RUNTIME. Prevents infinite loops.
#
# On kill:
#   - Posts a comment on the associated GitHub issue explaining the kill reason
#   - Removes the worker's status:in-progress label
#   - Adds status:available label so the issue is re-queued for dispatch
#   - Logs the action to the watchdog log file
#
# Usage:
#   worker-watchdog.sh                  # Single check (for launchd)
#   worker-watchdog.sh --check          # Same as above
#   worker-watchdog.sh --status         # Show current worker state
#   worker-watchdog.sh --install        # Install launchd plist (runs every 120s)
#   worker-watchdog.sh --uninstall      # Remove launchd plist
#   worker-watchdog.sh --help           # Show usage
#
# Environment:
#   WORKER_IDLE_TIMEOUT          Seconds of low CPU before kill (default: 300)
#   WORKER_IDLE_CPU_THRESHOLD    CPU% below this = idle (default: 5)
#   WORKER_PROGRESS_TIMEOUT      Seconds without log growth = stuck (default: 600)
#   WORKER_MAX_RUNTIME           Hard ceiling in seconds (default: 10800 = 3h)
#   WORKER_DRY_RUN               Set to "true" to log but not kill (default: false)
#   WORKER_WATCHDOG_NOTIFY       Set to "false" to disable macOS notifications
#   WORKER_PROCESS_PATTERN       CLI name to match (default: opencode)

set -euo pipefail

#######################################
# PATH normalisation
#######################################
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

#######################################
# Configuration
#######################################
readonly SCRIPT_NAME="worker-watchdog"
readonly SCRIPT_VERSION="1.0.0"

WORKER_IDLE_TIMEOUT="${WORKER_IDLE_TIMEOUT:-300}"           # 5 min idle = completed, sitting in file watcher
WORKER_IDLE_CPU_THRESHOLD="${WORKER_IDLE_CPU_THRESHOLD:-5}" # CPU% below this = idle
WORKER_PROGRESS_TIMEOUT="${WORKER_PROGRESS_TIMEOUT:-600}"   # 10 min no log output = stuck
WORKER_MAX_RUNTIME="${WORKER_MAX_RUNTIME:-10800}"           # 3 hour hard ceiling
WORKER_DRY_RUN="${WORKER_DRY_RUN:-false}"
WORKER_WATCHDOG_NOTIFY="${WORKER_WATCHDOG_NOTIFY:-true}"
WORKER_PROCESS_PATTERN="${WORKER_PROCESS_PATTERN:-opencode}" # CLI name to match (update if CLI changes)

# Validate numeric config
WORKER_IDLE_TIMEOUT=$(_validate_int WORKER_IDLE_TIMEOUT "$WORKER_IDLE_TIMEOUT" 300 60)
WORKER_IDLE_CPU_THRESHOLD=$(_validate_int WORKER_IDLE_CPU_THRESHOLD "$WORKER_IDLE_CPU_THRESHOLD" 5)
WORKER_PROGRESS_TIMEOUT=$(_validate_int WORKER_PROGRESS_TIMEOUT "$WORKER_PROGRESS_TIMEOUT" 600 120)
WORKER_MAX_RUNTIME=$(_validate_int WORKER_MAX_RUNTIME "$WORKER_MAX_RUNTIME" 10800 600)

# Paths
readonly LOG_DIR="${HOME}/.aidevops/logs"
readonly LOG_FILE="${LOG_DIR}/worker-watchdog.log"
readonly STATE_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
readonly IDLE_STATE_DIR="${STATE_DIR}/worker-idle-tracking"

readonly LAUNCHD_LABEL="sh.aidevops.worker-watchdog"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

#######################################
# Ensure directories exist
#######################################
ensure_dirs() {
	mkdir -p "$LOG_DIR" "$STATE_DIR" "$IDLE_STATE_DIR" 2>/dev/null || true
	return 0
}

#######################################
# Log a message with timestamp
# Arguments:
#   $1 - message
#######################################
log_msg() {
	local msg="$1"
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	echo "[${timestamp}] [${SCRIPT_NAME}] ${msg}" >>"$LOG_FILE"
	return 0
}

#######################################
# Send macOS notification
# Arguments:
#   $1 - title
#   $2 - message
#######################################
notify() {
	local title="$1"
	local message="$2"
	if [[ "$WORKER_WATCHDOG_NOTIFY" == "true" ]] && command -v osascript &>/dev/null; then
		osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Find all headless worker processes
#
# Workers are identified by: processes matching WORKER_PROCESS_PATTERN
# running with /full-loop in their command line (headless dispatch pattern).
#
# Output: one line per worker: "PID|ELAPSED_SECS|COMMAND"
#######################################
find_workers() {
	# Match worker processes with /full-loop (headless workers)
	# Build grep pattern: bracket-trick on first char excludes grep from results
	local pattern_char="${WORKER_PROCESS_PATTERN:0:1}"
	local pattern_rest="${WORKER_PROCESS_PATTERN:1}"
	local grep_pattern="[${pattern_char}]${pattern_rest}"
	local line pid cmd elapsed_seconds

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Skip watchdog processes
		[[ "$line" == *"worker-watchdog"* ]] && continue

		# Extract PID (first field) and command (rest of line)
		pid="${line%%[[:space:]]*}"
		cmd="${line#*[[:space:]]}"
		[[ -z "$pid" ]] && continue
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ -z "$cmd" ]] && continue

		# Get elapsed time
		elapsed_seconds=$(_get_process_age "$pid")

		# Output: PID|ELAPSED|COMMAND
		echo "${pid}|${elapsed_seconds}|${cmd}"
	done < <(ps axo pid,command | grep "$grep_pattern" | grep '/full-loop' || true)

	return 0
}

#######################################
# Extract issue number from worker command line
#
# Workers are dispatched with commands like:
#   opencode run --title "Issue #42: Fix auth" "/full-loop Implement issue #42 ..."
#
# Arguments:
#   $1 - command line string
# Output: issue number or empty string
#######################################
extract_issue_number() {
	local cmd="$1"

	# Try patterns: "Issue #NNN", "issue #NNN", "#NNN:", "GH#NNN"
	if [[ "$cmd" =~ [Ii]ssue[[:space:]]+#([0-9]+) ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "$cmd" =~ GH#([0-9]+) ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "$cmd" =~ \#([0-9]+): ]]; then
		echo "${BASH_REMATCH[1]}"
	else
		echo ""
	fi
	return 0
}

#######################################
# Extract repo slug from worker command line
#
# Workers are dispatched with --dir pointing to a worktree.
# We resolve the repo slug from the git remote.
#
# Arguments:
#   $1 - command line string
# Output: owner/repo slug or empty string
#######################################
extract_repo_slug() {
	local cmd="$1"

	# Extract --dir from command line
	local worktree_dir=""
	if [[ "$cmd" =~ --dir[[:space:]]+([^[:space:]]+) ]]; then
		worktree_dir="${BASH_REMATCH[1]}"
	fi

	if [[ -z "$worktree_dir" || ! -d "$worktree_dir" ]]; then
		echo ""
		return 0
	fi

	# Get remote URL and extract slug
	local remote_url
	remote_url=$(git -C "$worktree_dir" remote get-url origin) || true

	if [[ -z "$remote_url" ]]; then
		echo ""
		return 0
	fi

	# Parse slug from SSH or HTTPS URL
	local slug=""
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+) ]]; then
		slug="${BASH_REMATCH[1]}"
		# Remove .git suffix if present
		slug="${slug%.git}"
	fi

	echo "$slug"
	return 0
}

#######################################
# Check if a worker is idle (CPU below threshold)
#
# Tracks consecutive idle checks via state files. A worker is only
# killed after being idle for WORKER_IDLE_TIMEOUT seconds, not on
# a single low-CPU reading.
#
# Arguments:
#   $1 - PID
#   $2 - current tree CPU%
# Returns: 0 if idle long enough to kill, 1 if not yet
#######################################
check_idle() {
	local pid="$1"
	local tree_cpu="$2"
	local idle_file="${IDLE_STATE_DIR}/idle-${pid}"

	if [[ "$tree_cpu" -lt "$WORKER_IDLE_CPU_THRESHOLD" ]]; then
		# Worker is idle — track when idle started
		if [[ ! -f "$idle_file" ]]; then
			date +%s >"$idle_file"
			return 1
		fi

		local idle_since
		idle_since=$(cat "$idle_file" 2>/dev/null || echo "0")
		[[ "$idle_since" =~ ^[0-9]+$ ]] || idle_since=0

		local now
		now=$(date +%s)
		local idle_duration=$((now - idle_since))

		if [[ "$idle_duration" -ge "$WORKER_IDLE_TIMEOUT" ]]; then
			return 0 # Idle long enough — kill
		fi
		return 1
	else
		# Worker is active — reset idle tracking
		rm -f "$idle_file" 2>/dev/null || true
		return 1
	fi
}

#######################################
# Check if a worker's log output has stalled
#
# Uses the OpenCode session DB to check for recent messages.
# Falls back to checking process tree CPU if DB is unavailable.
#
# Arguments:
#   $1 - PID
#   $2 - command line
#   $3 - elapsed seconds
# Returns: 0 if stalled, 1 if making progress
#######################################
check_progress_stall() {
	local pid="$1"
	local cmd="$2"
	local elapsed_seconds="$3"
	local stall_file="${IDLE_STATE_DIR}/stall-${pid}"

	# Skip progress check for very young workers (< 10 min)
	if [[ "$elapsed_seconds" -lt 600 ]]; then
		rm -f "$stall_file" 2>/dev/null || true
		return 1
	fi

	# Check OpenCode session DB for recent messages
	local db_path="${HOME}/.local/share/opencode/opencode.db"
	local has_recent_activity=false

	if [[ -f "$db_path" ]]; then
		local session_title=""
		if [[ "$cmd" =~ --title[[:space:]]+\"([^\"]+)\" ]] || [[ "$cmd" =~ --title[[:space:]]+([^[:space:]]+) ]]; then
			session_title="${BASH_REMATCH[1]}"
		fi

		if [[ -n "$session_title" ]]; then
			local escaped_title="${session_title//\'/\'\'}"
			local recent_count
			recent_count=$(sqlite3 "$db_path" "
				SELECT COUNT(*)
				FROM message m
				JOIN session s ON m.session_id = s.id
				WHERE s.title LIKE '%${escaped_title}%'
				AND m.created_at > datetime('now', '-${WORKER_PROGRESS_TIMEOUT} seconds')
			" || echo 0)

			if [[ "$recent_count" -gt 0 ]]; then
				has_recent_activity=true
			fi
		fi
	fi

	if [[ "$has_recent_activity" == "true" ]]; then
		# Activity detected — reset stall tracking
		rm -f "$stall_file" 2>/dev/null || true
		return 1
	fi

	# No recent activity — track when stall started
	if [[ ! -f "$stall_file" ]]; then
		date +%s >"$stall_file"
		return 1
	fi

	local stall_since
	stall_since=$(cat "$stall_file" 2>/dev/null || echo "0")
	[[ "$stall_since" =~ ^[0-9]+$ ]] || stall_since=0

	local now
	now=$(date +%s)
	local stall_duration=$((now - stall_since))

	if [[ "$stall_duration" -ge "$WORKER_PROGRESS_TIMEOUT" ]]; then
		return 0 # Stalled long enough — kill
	fi
	return 1
}

#######################################
# Kill a worker and handle cleanup
#
# Arguments:
#   $1 - PID
#   $2 - reason (idle|stall|runtime)
#   $3 - command line
#   $4 - elapsed seconds
#######################################
kill_worker() {
	local pid="$1"
	local reason="$2"
	local cmd="$3"
	local elapsed_seconds="$4"

	local duration
	duration=$(_format_duration "$elapsed_seconds")
	local sanitized_cmd
	sanitized_cmd=$(_sanitize_log_field "$cmd")

	if [[ "$WORKER_DRY_RUN" == "true" ]]; then
		log_msg "DRY RUN: Would kill worker PID=${pid} reason=${reason} elapsed=${duration} cmd=${sanitized_cmd}"
		echo "  DRY RUN: Would kill PID ${pid} (${reason}, running ${duration})"
		return 0
	fi

	log_msg "Killing worker PID=${pid} reason=${reason} elapsed=${duration} cmd=${sanitized_cmd}"

	# Graceful kill first
	_kill_tree "$pid" || true
	sleep 2

	# Force kill if still alive
	if kill -0 "$pid" 2>/dev/null; then
		_force_kill_tree "$pid" || true
		log_msg "Force-killed worker PID=${pid}"
	fi

	# Clean up idle/stall tracking files
	rm -f "${IDLE_STATE_DIR}/idle-${pid}" "${IDLE_STATE_DIR}/stall-${pid}" 2>/dev/null || true

	# Post-kill: update GitHub issue labels and comment
	post_kill_github_update "$cmd" "$reason" "$duration"

	# Notify
	notify "Worker Watchdog" "Killed worker (${reason}) after ${duration}"

	return 0
}

#######################################
# Post-kill GitHub issue update
#
# Comments on the issue and swaps labels so the issue is re-queued.
#
# Arguments:
#   $1 - command line
#   $2 - kill reason
#   $3 - formatted duration
#######################################
post_kill_github_update() {
	local cmd="$1"
	local reason="$2"
	local duration="$3"

	# Extract issue number and repo slug
	local issue_number
	issue_number=$(extract_issue_number "$cmd")
	local repo_slug
	repo_slug=$(extract_repo_slug "$cmd")

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		log_msg "Cannot update GitHub: issue=${issue_number:-unknown} repo=${repo_slug:-unknown}"
		return 0
	fi

	# Map reason to human-readable description
	local reason_desc=""
	case "$reason" in
	idle) reason_desc="Worker process became idle (CPU below ${WORKER_IDLE_CPU_THRESHOLD}% for ${WORKER_IDLE_TIMEOUT}s) — likely completed or hit the OpenCode idle-state bug." ;;
	stall) reason_desc="Worker stopped producing output for ${WORKER_PROGRESS_TIMEOUT}s — likely stuck on API rate limiting or an unrecoverable error." ;;
	runtime) reason_desc="Worker exceeded the ${duration} runtime ceiling — killed to prevent infinite loops." ;;
	*) reason_desc="Worker killed by watchdog (reason: ${reason})." ;;
	esac

	# Post comment
	local comment_body="## Worker Watchdog Kill

**Reason:** ${reason_desc}

**Runtime:** ${duration}

This issue has been re-labeled \`status:available\` for re-dispatch. The next pulse or manual dispatch will pick it up.

_Automated by \`worker-watchdog.sh\` (t1419)_"

	if gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" 2>>"$LOG_FILE"; then
		log_msg "Posted kill comment on ${repo_slug}#${issue_number}"
	else
		log_msg "Failed to post comment on ${repo_slug}#${issue_number}"
	fi

	# Remove in-progress label, add available label
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--remove-label "status:in-progress" \
		--add-label "status:available" 2>>"$LOG_FILE" || {
		log_msg "Failed to update labels on ${repo_slug}#${issue_number}"
	}

	return 0
}

#######################################
# Main check: scan all workers and apply detection signals
#######################################
cmd_check() {
	ensure_dirs

	local workers
	workers=$(find_workers)

	if [[ -z "$workers" ]]; then
		# No workers running — clean up stale tracking files
		rm -f "${IDLE_STATE_DIR}"/idle-* "${IDLE_STATE_DIR}"/stall-* 2>/dev/null || true
		return 0
	fi

	local worker_count=0
	local killed_count=0

	while IFS='|' read -r pid elapsed_seconds cmd; do
		[[ -z "$pid" ]] && continue
		worker_count=$((worker_count + 1))

		local tree_cpu
		tree_cpu=$(_get_process_tree_cpu "$pid")

		local duration
		duration=$(_format_duration "$elapsed_seconds")

		# Check 1: Runtime ceiling (highest priority — unconditional kill)
		if [[ "$elapsed_seconds" -ge "$WORKER_MAX_RUNTIME" ]]; then
			log_msg "RUNTIME CEILING: PID=${pid} elapsed=${duration} (max=$(_format_duration "$WORKER_MAX_RUNTIME"))"
			kill_worker "$pid" "runtime" "$cmd" "$elapsed_seconds"
			killed_count=$((killed_count + 1))
			continue
		fi

		# Check 2: CPU idle detection
		if check_idle "$pid" "$tree_cpu"; then
			log_msg "IDLE DETECTED: PID=${pid} cpu=${tree_cpu}% elapsed=${duration}"
			kill_worker "$pid" "idle" "$cmd" "$elapsed_seconds"
			killed_count=$((killed_count + 1))
			continue
		fi

		# Check 3: Progress stall detection
		if check_progress_stall "$pid" "$cmd" "$elapsed_seconds"; then
			log_msg "PROGRESS STALL: PID=${pid} elapsed=${duration}"
			kill_worker "$pid" "stall" "$cmd" "$elapsed_seconds"
			killed_count=$((killed_count + 1))
			continue
		fi

	done <<<"$workers"

	if [[ "$killed_count" -gt 0 ]]; then
		log_msg "Check complete: ${worker_count} workers scanned, ${killed_count} killed"
	fi

	# Clean up tracking files for PIDs that no longer exist
	local tracking_file
	for tracking_file in "${IDLE_STATE_DIR}"/idle-* "${IDLE_STATE_DIR}"/stall-*; do
		[[ -f "$tracking_file" ]] || continue
		local tracked_pid
		tracked_pid=$(basename "$tracking_file" | sed 's/^idle-//;s/^stall-//')
		if [[ "$tracked_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$tracked_pid" 2>/dev/null; then
			rm -f "$tracking_file" 2>/dev/null || true
		fi
	done

	return 0
}

#######################################
# Status: show current worker state
#######################################
cmd_status() {
	ensure_dirs

	echo "=== Worker Watchdog Status ==="
	echo ""
	echo "--- Configuration ---"
	echo ""
	echo "  Idle timeout:        $(_format_duration "$WORKER_IDLE_TIMEOUT") (CPU < ${WORKER_IDLE_CPU_THRESHOLD}%)"
	echo "  Progress timeout:    $(_format_duration "$WORKER_PROGRESS_TIMEOUT")"
	echo "  Runtime ceiling:     $(_format_duration "$WORKER_MAX_RUNTIME")"
	echo "  Dry run:             ${WORKER_DRY_RUN}"
	echo "  Notifications:       ${WORKER_WATCHDOG_NOTIFY}"

	echo ""
	echo "--- Active Workers ---"
	echo ""

	local workers
	workers=$(find_workers)

	if [[ -z "$workers" ]]; then
		echo "  No headless workers running"
	else
		local count=0
		while IFS='|' read -r pid elapsed_seconds cmd; do
			[[ -z "$pid" ]] && continue
			count=$((count + 1))

			local tree_cpu
			tree_cpu=$(_get_process_tree_cpu "$pid")
			local duration
			duration=$(_format_duration "$elapsed_seconds")
			local issue_number
			issue_number=$(extract_issue_number "$cmd")
			local repo_slug
			repo_slug=$(extract_repo_slug "$cmd")

			echo "  Worker #${count}:"
			echo "    PID:      ${pid}"
			echo "    Runtime:  ${duration}"
			echo "    Tree CPU: ${tree_cpu}%"
			[[ -n "$issue_number" ]] && echo "    Issue:    ${repo_slug:-unknown}#${issue_number}"

			# Show idle tracking state
			if [[ -f "${IDLE_STATE_DIR}/idle-${pid}" ]]; then
				local idle_since
				idle_since=$(cat "${IDLE_STATE_DIR}/idle-${pid}" 2>/dev/null || echo "0")
				local now
				now=$(date +%s)
				local idle_for=$((now - idle_since))
				echo "    Idle for: $(_format_duration "$idle_for") / $(_format_duration "$WORKER_IDLE_TIMEOUT")"
			fi

			# Show stall tracking state
			if [[ -f "${IDLE_STATE_DIR}/stall-${pid}" ]]; then
				local stall_since
				stall_since=$(cat "${IDLE_STATE_DIR}/stall-${pid}" 2>/dev/null || echo "0")
				local now
				now=$(date +%s)
				local stall_for=$((now - stall_since))
				echo "    Stalled:  $(_format_duration "$stall_for") / $(_format_duration "$WORKER_PROGRESS_TIMEOUT")"
			fi

			# Struggle ratio
			local sr_result
			sr_result=$(_compute_struggle_ratio "$pid" "$elapsed_seconds" "$cmd")
			local sr_ratio sr_commits sr_messages sr_flag
			IFS='|' read -r sr_ratio sr_commits sr_messages sr_flag <<<"$sr_result"
			if [[ "$sr_ratio" != "n/a" ]]; then
				echo "    Struggle: ratio=${sr_ratio} commits=${sr_commits} messages=${sr_messages} ${sr_flag:+[${sr_flag}]}"
			fi

			echo ""
		done <<<"$workers"
		echo "  Total: ${count} worker(s)"
	fi

	echo ""
	echo "--- Launchd ---"
	echo ""
	if [[ -f "${PLIST_PATH}" ]]; then
		if launchctl list 2>/dev/null | grep -q "${LAUNCHD_LABEL}"; then
			echo "  Status: installed and loaded"
		else
			echo "  Status: installed but NOT loaded"
		fi
	else
		echo "  Status: not installed (run --install)"
	fi

	echo ""
	return 0
}

#######################################
# Install launchd plist
#######################################
cmd_install() {
	local script_path
	script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
	local installed_path="${HOME}/.aidevops/agents/scripts/${SCRIPT_NAME}.sh"
	if [[ -x "${installed_path}" ]]; then
		script_path="${installed_path}"
	fi

	ensure_dirs
	mkdir -p "$(dirname "${PLIST_PATH}")"

	local home_escaped="${HOME}"

	cat >"${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${script_path}</string>
		<string>--check</string>
	</array>
	<key>StartInterval</key>
	<integer>120</integer>
	<key>StandardOutPath</key>
	<string>${home_escaped}/.aidevops/logs/worker-watchdog-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${home_escaped}/.aidevops/logs/worker-watchdog-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${home_escaped}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
EOF

	launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
	launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"

	echo "Installed and loaded: ${LAUNCHD_LABEL}"
	echo "Plist: ${PLIST_PATH}"
	echo "Log: ${LOG_FILE}"
	echo "Check interval: 120 seconds"
	return 0
}

#######################################
# Uninstall launchd plist
#######################################
cmd_uninstall() {
	if [[ -f "${PLIST_PATH}" ]]; then
		launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
		rm -f "${PLIST_PATH}"
		echo "Uninstalled: ${LAUNCHD_LABEL}"
	else
		echo "Not installed"
	fi

	# Clean up state files
	rm -rf "${IDLE_STATE_DIR}" 2>/dev/null || true
	echo "Cleaned up state files"
	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<HELP
Usage: ${SCRIPT_NAME}.sh [COMMAND]

Commands:
  --check, -c       Single check (default, for launchd)
  --status, -s      Show current worker state
  --install, -i     Install launchd plist (runs every 120s)
  --uninstall, -u   Remove launchd plist and state files
  --help, -h        Show this help

Detection signals:
  CPU idle:         Tree CPU < ${WORKER_IDLE_CPU_THRESHOLD}% for $(_format_duration "$WORKER_IDLE_TIMEOUT")
  Progress stall:   No session messages for $(_format_duration "$WORKER_PROGRESS_TIMEOUT")
  Runtime ceiling:  Hard kill after $(_format_duration "$WORKER_MAX_RUNTIME")

On kill:
  - Posts comment on associated GitHub issue
  - Removes status:in-progress label
  - Adds status:available label for re-dispatch
  - Logs to ${LOG_FILE}

Environment variables:
  WORKER_IDLE_TIMEOUT          Idle detection window (default: 300s)
  WORKER_IDLE_CPU_THRESHOLD    CPU% idle threshold (default: 5)
  WORKER_PROGRESS_TIMEOUT      Stall detection window (default: 600s)
  WORKER_MAX_RUNTIME           Hard runtime ceiling (default: 10800s = 3h)
  WORKER_DRY_RUN               Log but don't kill (default: false)
  WORKER_WATCHDOG_NOTIFY       macOS notifications (default: true)
  WORKER_PROCESS_PATTERN       CLI name to match (default: opencode)
HELP
	return 0
}

#######################################
# Main
#######################################
main() {
	local cmd="${1:-check}"

	case "${cmd}" in
	--check | -c | check)
		cmd_check
		;;
	--status | -s | status)
		cmd_status
		;;
	--install | -i | install)
		cmd_install
		;;
	--uninstall | -u | uninstall)
		cmd_uninstall
		;;
	--help | -h | help)
		cmd_help
		;;
	*)
		echo "Unknown command: ${cmd}" >&2
		echo "Run with --help for usage" >&2
		return 1
		;;
	esac
}

main "$@"
