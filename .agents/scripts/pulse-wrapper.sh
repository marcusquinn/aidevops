#!/usr/bin/env bash
# pulse-wrapper.sh - Wrapper for supervisor pulse with dedup and lifecycle management
#
# Solves: opencode run enters idle state after completing the pulse prompt
# but never exits, blocking all future pulses via the pgrep dedup guard.
#
# This wrapper:
#   1. Uses a PID file with staleness check (not pgrep) for dedup
#   2. Cleans up orphaned opencode processes before each pulse
#   3. Calculates dynamic worker concurrency from available RAM
#   4. Lets the pulse run to completion — no hard timeout
#
# Lifecycle: launchd fires every 120s. If a pulse is still running, the
# dedup check skips. If a pulse has been running longer than PULSE_STALE_THRESHOLD
# (default 30 min), it's assumed stuck (opencode idle bug) and killed so the
# next invocation can start fresh. This is the ONLY kill mechanism — no
# arbitrary timeouts that would interrupt active work.
#
# Called by launchd every 120s via the supervisor-pulse plist.

set -euo pipefail

#######################################
# PATH normalisation
# The MCP shell environment may have a minimal PATH that excludes /bin
# and other standard directories, causing `env bash` to fail. Ensure
# essential directories are always present.
#######################################
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

#######################################
# Configuration
#######################################
PULSE_STALE_THRESHOLD="${PULSE_STALE_THRESHOLD:-1800}" # 30 min = definitely stuck (opencode idle bug)

# Validate numeric configuration
if ! [[ "$PULSE_STALE_THRESHOLD" =~ ^[0-9]+$ ]]; then
	echo "[pulse-wrapper] Invalid PULSE_STALE_THRESHOLD: $PULSE_STALE_THRESHOLD — using default 1800" >&2
	PULSE_STALE_THRESHOLD=1800
fi
PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
OPENCODE_BIN="${OPENCODE_BIN:-/opt/homebrew/bin/opencode}"
PULSE_DIR="${PULSE_DIR:-${HOME}/Git/aidevops}"
PULSE_MODEL="${PULSE_MODEL:-anthropic/claude-sonnet-4-6}"
ORPHAN_MAX_AGE="${ORPHAN_MAX_AGE:-7200}"       # 2 hours — kill orphans older than this
RAM_PER_WORKER_MB="${RAM_PER_WORKER_MB:-1024}" # 1 GB per worker
RAM_RESERVE_MB="${RAM_RESERVE_MB:-8192}"       # 8 GB reserved for OS + user apps
MAX_WORKERS_CAP="${MAX_WORKERS_CAP:-8}"        # Hard ceiling regardless of RAM
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"

#######################################
# Ensure log directory exists
#######################################
mkdir -p "$(dirname "$PIDFILE")"

#######################################
# Check for stale PID file and clean up
# Returns: 0 if safe to proceed, 1 if another pulse is genuinely running
#######################################
check_dedup() {
	if [[ ! -f "$PIDFILE" ]]; then
		return 0
	fi

	local old_pid
	old_pid=$(cat "$PIDFILE" 2>/dev/null || echo "")

	if [[ -z "$old_pid" ]]; then
		rm -f "$PIDFILE"
		return 0
	fi

	# Check if the process is still running
	if ! kill -0 "$old_pid" 2>/dev/null; then
		# Process is dead, clean up stale PID file
		rm -f "$PIDFILE"
		return 0
	fi

	# Process is running — check how long
	local elapsed_seconds
	elapsed_seconds=$(_get_process_age "$old_pid")

	if [[ "$elapsed_seconds" -gt "$PULSE_STALE_THRESHOLD" ]]; then
		# Process has been running too long — it's stuck
		echo "[pulse-wrapper] Killing stale pulse process $old_pid (running ${elapsed_seconds}s, threshold ${PULSE_STALE_THRESHOLD}s)" >>"$LOGFILE"
		_kill_tree "$old_pid"
		sleep 2
		# Force kill if still alive
		if kill -0 "$old_pid" 2>/dev/null; then
			_force_kill_tree "$old_pid"
		fi
		rm -f "$PIDFILE"
		return 0
	fi

	# Process is running and within time limit — genuine dedup
	echo "[pulse-wrapper] Pulse already running (PID $old_pid, ${elapsed_seconds}s elapsed). Skipping." >>"$LOGFILE"
	return 1
}

#######################################
# Kill a process and all its children (macOS-compatible)
# Arguments:
#   $1 - PID to kill
#######################################
_kill_tree() {
	local pid="$1"
	# Find all child processes recursively (bash 3.2 compatible — no mapfile)
	local child
	while IFS= read -r child; do
		[[ -n "$child" ]] && _kill_tree "$child"
	done < <(pgrep -P "$pid" 2>/dev/null || true)
	kill "$pid" 2>/dev/null || true
	return 0
}

#######################################
# Force kill a process and all its children
# Arguments:
#   $1 - PID to kill
#######################################
_force_kill_tree() {
	local pid="$1"
	local child
	while IFS= read -r child; do
		[[ -n "$child" ]] && _force_kill_tree "$child"
	done < <(pgrep -P "$pid" 2>/dev/null || true)
	kill -9 "$pid" 2>/dev/null || true
	return 0
}

#######################################
# Get process age in seconds
# Arguments:
#   $1 - PID
# Returns: elapsed seconds via stdout
#######################################
_get_process_age() {
	local pid="$1"
	local etime
	# macOS ps etime format: MM:SS or HH:MM:SS or D-HH:MM:SS
	etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ') || etime=""

	if [[ -z "$etime" ]]; then
		echo "0"
		return 0
	fi

	local days=0 hours=0 minutes=0 seconds=0

	# Parse D-HH:MM:SS format
	if [[ "$etime" == *-* ]]; then
		days="${etime%%-*}"
		etime="${etime#*-}"
	fi

	# Count colons to determine format
	local colon_count
	colon_count=$(echo "$etime" | tr -cd ':' | wc -c | tr -d ' ')

	if [[ "$colon_count" -eq 2 ]]; then
		# HH:MM:SS
		IFS=':' read -r hours minutes seconds <<<"$etime"
	elif [[ "$colon_count" -eq 1 ]]; then
		# MM:SS
		IFS=':' read -r minutes seconds <<<"$etime"
	else
		seconds="$etime"
	fi

	# Remove leading zeros to avoid octal interpretation
	days=$((10#${days}))
	hours=$((10#${hours}))
	minutes=$((10#${minutes}))
	seconds=$((10#${seconds}))

	echo $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
	return 0
}

#######################################
# Pre-fetch state for ALL pulse-enabled repos
#
# Runs gh pr list + gh issue list for each repo in parallel, formats
# a compact summary, and writes it to STATE_FILE. This is injected
# into the pulse prompt so the agent sees all repos from the start —
# preventing the "only processes first repo" problem.
#
# This is a deterministic data-fetch utility. The intelligence about
# what to DO with this data stays in pulse.md.
#######################################
prefetch_state() {
	local repos_json="$REPOS_JSON"

	if [[ ! -f "$repos_json" ]]; then
		echo "[pulse-wrapper] repos.json not found at $repos_json — skipping prefetch" >>"$LOGFILE"
		echo "ERROR: repos.json not found" >"$STATE_FILE"
		return 1
	fi

	echo "[pulse-wrapper] Pre-fetching state for all pulse-enabled repos..." >>"$LOGFILE"

	# Extract pulse-enabled, non-local-only repos as slug|path pairs
	local repo_entries
	repo_entries=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json")

	if [[ -z "$repo_entries" ]]; then
		echo "[pulse-wrapper] No pulse-enabled repos found" >>"$LOGFILE"
		echo "No pulse-enabled repos found in repos.json" >"$STATE_FILE"
		return 1
	fi

	# Temp dir for parallel fetches
	local tmpdir
	tmpdir=$(mktemp -d)

	# Launch parallel gh fetches for each repo
	local pids=()
	local idx=0
	while IFS='|' read -r slug path; do
		(
			local outfile="${tmpdir}/${idx}.txt"
			{
				echo "## ${slug} (${path})"
				echo ""

				# PRs
				local pr_json
				pr_json=$(gh pr list --repo "$slug" --state open \
					--json number,title,reviewDecision,statusCheckRollup,updatedAt,headRefName \
					--limit 20 2>/dev/null) || pr_json="[]"

				local pr_count
				pr_count=$(echo "$pr_json" | jq 'length')

				if [[ "$pr_count" -gt 0 ]]; then
					echo "### Open PRs ($pr_count)"
					echo "$pr_json" | jq -r '.[] | "- PR #\(.number): \(.title) [checks: \(if .statusCheckRollup == null or (.statusCheckRollup | length) == 0 then "none" elif (.statusCheckRollup | all((.conclusion // .state) == "SUCCESS")) then "PASS" elif (.statusCheckRollup | any((.conclusion // .state) == "FAILURE")) then "FAIL" else "PENDING" end)] [review: \(if .reviewDecision == null or .reviewDecision == "" then "NONE" else .reviewDecision end)] [branch: \(.headRefName)] [updated: \(.updatedAt)]"'
				else
					echo "### Open PRs (0)"
					echo "- None"
				fi

				echo ""

				# Issues
				local issue_json
				issue_json=$(gh issue list --repo "$slug" --state open \
					--json number,title,labels,updatedAt \
					--limit 20 2>/dev/null) || issue_json="[]"

				local issue_count
				issue_count=$(echo "$issue_json" | jq 'length')

				if [[ "$issue_count" -gt 0 ]]; then
					echo "### Open Issues ($issue_count)"
					echo "$issue_json" | jq -r '.[] | "- Issue #\(.number): \(.title) [labels: \(if (.labels | length) == 0 then "none" else (.labels | map(.name) | join(", ")) end)] [updated: \(.updatedAt)]"'
				else
					echo "### Open Issues (0)"
					echo "- None"
				fi

				echo ""
			} >"$outfile"
		) &
		pids+=($!)
		idx=$((idx + 1))
	done <<<"$repo_entries"

	# Wait for all parallel fetches
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done

	# Assemble state file in repo order
	{
		echo "# Pre-fetched Repo State ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
		echo ""
		echo "This state was fetched by pulse-wrapper.sh BEFORE the pulse started."
		echo "Do NOT re-fetch — act on this data directly. See pulse.md Step 2."
		echo ""
		local i=0
		while [[ -f "${tmpdir}/${i}.txt" ]]; do
			cat "${tmpdir}/${i}.txt"
			i=$((i + 1))
		done
	} >"$STATE_FILE"

	# Clean up
	rm -rf "$tmpdir"

	# Append mission state
	prefetch_missions "$repo_entries" >>"$STATE_FILE"

	local repo_count
	repo_count=$(echo "$repo_entries" | wc -l | tr -d ' ')
	echo "[pulse-wrapper] Pre-fetched state for $repo_count repos → $STATE_FILE" >>"$LOGFILE"
	return 0
}

#######################################
# Pre-fetch active mission state files
#
# Scans todo/missions/ and ~/.aidevops/missions/ for mission.md files
# with status: active|paused|blocked|validating. Extracts a compact
# summary (id, status, current milestone, pending features) so the
# pulse agent can act on missions without reading full state files.
#
# Arguments:
#   $1 - repo_entries (slug|path pairs, one per line)
# Output: mission summary to stdout (appended to STATE_FILE by caller)
#######################################
prefetch_missions() {
	local repo_entries="$1"
	local found_any=false

	# Collect mission files from repo-attached locations
	local mission_files=()
	while IFS='|' read -r slug path; do
		local missions_dir="${path}/todo/missions"
		if [[ -d "$missions_dir" ]]; then
			while IFS= read -r mfile; do
				[[ -n "$mfile" ]] && mission_files+=("${slug}|${path}|${mfile}")
			done < <(find "$missions_dir" -name "mission.md" -type f 2>/dev/null || true)
		fi
	done <<<"$repo_entries"

	# Also check homeless missions
	local homeless_dir="${HOME}/.aidevops/missions"
	if [[ -d "$homeless_dir" ]]; then
		while IFS= read -r mfile; do
			[[ -n "$mfile" ]] && mission_files+=("|homeless|${mfile}")
		done < <(find "$homeless_dir" -name "mission.md" -type f 2>/dev/null || true)
	fi

	if [[ ${#mission_files[@]} -eq 0 ]]; then
		return 0
	fi

	local active_count=0

	for entry in "${mission_files[@]}"; do
		local slug path mfile
		IFS='|' read -r slug path mfile <<<"$entry"

		# Extract frontmatter status — look for status: in YAML frontmatter
		local status
		status=$(_extract_frontmatter_field "$mfile" "status")

		# Only include active/paused/blocked/validating missions
		case "$status" in
		active | paused | blocked | validating) ;;
		*) continue ;;
		esac

		if [[ "$found_any" == false ]]; then
			echo ""
			echo "# Active Missions"
			echo ""
			echo "Mission state files detected by pulse-wrapper.sh. See pulse.md Step 3.5."
			echo ""
			found_any=true
		fi

		local mission_id
		mission_id=$(_extract_frontmatter_field "$mfile" "id")
		local title
		title=$(_extract_frontmatter_field "$mfile" "title")
		local mode
		mode=$(_extract_frontmatter_field "$mfile" "mode")
		local mission_dir
		mission_dir=$(dirname "$mfile")

		echo "## Mission: ${mission_id} — ${title}"
		echo ""
		echo "- **Status:** ${status}"
		echo "- **Mode:** ${mode}"
		echo "- **Repo:** ${slug:-homeless}"
		echo "- **Path:** ${mfile}"
		echo ""

		# Extract milestone summaries — find lines matching "### Milestone N:"
		# and their status lines
		_extract_milestone_summary "$mfile"

		echo ""
		active_count=$((active_count + 1))
	done

	if [[ "$active_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Found $active_count active mission(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Extract a field value from YAML frontmatter
# Arguments:
#   $1 - file path
#   $2 - field name
# Output: field value to stdout (trimmed, comments stripped)
#######################################
_extract_frontmatter_field() {
	local file="$1"
	local field="$2"

	# Read frontmatter (between first --- and second ---)
	local in_frontmatter=false
	local value=""
	while IFS= read -r line; do
		if [[ "$line" == "---" ]]; then
			if [[ "$in_frontmatter" == true ]]; then
				break
			fi
			in_frontmatter=true
			continue
		fi
		if [[ "$in_frontmatter" == true ]]; then
			# Match field: value (strip inline comments and quotes)
			if [[ "$line" =~ ^${field}:[[:space:]]*(.*) ]]; then
				value="${BASH_REMATCH[1]}"
				# Strip inline comments (# ...)
				value="${value%%#*}"
				# Trim whitespace
				value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
				# Strip surrounding quotes
				value="${value#\"}"
				value="${value%\"}"
				break
			fi
		fi
	done <"$file"

	echo "$value"
	return 0
}

#######################################
# Extract milestone summary from a mission state file
# Outputs a compact table of milestones and their feature statuses
# Arguments:
#   $1 - mission.md file path
# Output: milestone summary to stdout
#######################################
_extract_milestone_summary() {
	local file="$1"
	local current_milestone=""
	local milestone_status=""

	while IFS= read -r line; do
		# Detect milestone headers: ### Milestone N: Name
		if [[ "$line" =~ ^###[[:space:]]+Milestone[[:space:]]+([0-9]+):[[:space:]]+(.*) ]]; then
			current_milestone="${BASH_REMATCH[1]}: ${BASH_REMATCH[2]}"
		fi

		# Detect milestone status: **Status:** value
		if [[ -n "$current_milestone" && "$line" =~ \*\*Status:\*\*[[:space:]]*(.*) ]]; then
			milestone_status="${BASH_REMATCH[1]}"
			# Strip HTML comments
			milestone_status="${milestone_status%%<!--*}"
			milestone_status=$(echo "$milestone_status" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
			echo "- **Milestone ${current_milestone}** — ${milestone_status}"
			current_milestone=""
		fi

		# Detect feature rows in tables: | N.N | Feature | tNNN | status | ...
		if [[ "$line" =~ ^\|[[:space:]]*([0-9]+\.[0-9]+)[[:space:]]*\|[[:space:]]*(.*)\|[[:space:]]*(t[0-9.]+)[[:space:]]*\|[[:space:]]*([a-z]+)[[:space:]]*\| ]]; then
			local feat_num="${BASH_REMATCH[1]}"
			local feat_name="${BASH_REMATCH[2]}"
			local task_id="${BASH_REMATCH[3]}"
			local feat_status="${BASH_REMATCH[4]}"
			# Trim feature name
			feat_name=$(echo "$feat_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
			echo "  - F${feat_num}: ${feat_name} (${task_id}) — ${feat_status}"
		fi
	done <"$file"
	return 0
}

#######################################
# Run the pulse — no hard timeout
#
# The pulse runs until opencode exits naturally. If opencode enters its
# idle-state bug (file watcher keeps process alive after session completes),
# the NEXT launchd invocation's check_dedup() will detect the stale process
# (age > PULSE_STALE_THRESHOLD) and kill it. This is correct because:
#   - Active pulses doing real work are never interrupted
#   - Stuck pulses are detected by the next invocation (120s later)
#   - The stale threshold (30 min) is generous enough for any real workload
#######################################
run_pulse() {
	local start_epoch
	start_epoch=$(date +%s)
	echo "[pulse-wrapper] Starting pulse at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOGFILE"

	# Build the prompt: /pulse + pre-fetched state
	local prompt="/pulse"
	if [[ -f "$STATE_FILE" ]]; then
		local state_content
		state_content=$(cat "$STATE_FILE")
		prompt="/pulse

--- PRE-FETCHED STATE (from pulse-wrapper.sh) ---
${state_content}
--- END PRE-FETCHED STATE ---"
	fi

	# Run opencode — blocks until it exits (or is killed by next invocation's stale check)
	"$OPENCODE_BIN" run "$prompt" \
		--dir "$PULSE_DIR" \
		-m "$PULSE_MODEL" \
		--title "Supervisor Pulse" \
		>>"$LOGFILE" 2>&1 &

	local opencode_pid=$!
	echo "$opencode_pid" >"$PIDFILE"

	echo "[pulse-wrapper] opencode PID: $opencode_pid" >>"$LOGFILE"

	# Wait for natural exit
	wait "$opencode_pid" 2>/dev/null || true

	# Clean up PID file
	rm -f "$PIDFILE"

	local end_epoch
	end_epoch=$(date +%s)
	local duration=$((end_epoch - start_epoch))
	echo "[pulse-wrapper] Pulse completed at $(date -u +%Y-%m-%dT%H:%M:%SZ) (ran ${duration}s)" >>"$LOGFILE"
	return 0
}

#######################################
# Clean up worktrees for merged/closed PRs across ALL managed repos
#
# Iterates repos.json and runs worktree-helper.sh clean --auto --force-merged
# in each repo directory. This prevents stale worktrees from accumulating
# on disk after PR merges — including squash merges that git branch --merged
# cannot detect.
#
# --force-merged: uses gh pr list to detect squash merges and force-removes
# dirty worktrees when the PR is confirmed merged (dirty state = abandoned WIP).
#
# Safety: skips worktrees owned by active sessions (handled by worktree-helper.sh).
#######################################
cleanup_worktrees() {
	local helper="${HOME}/.aidevops/agents/scripts/worktree-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_removed=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		# Iterate all repos, skip local_only (no GitHub remote for PR detection)
		local repo_paths
		repo_paths=$(jq -r '.[] | select(.local_only != true) | .path' "$repos_json" 2>/dev/null || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			local cleaned_output
			cleaned_output=$(git -C "$repo_path" worktree list 2>/dev/null | wc -l)
			# Skip repos with only 1 worktree (the main one) — nothing to clean
			if [[ "$cleaned_output" -le 1 ]]; then
				continue
			fi

			# Run helper in a subshell cd'd to the repo (it uses git rev-parse --show-toplevel)
			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" clean --auto --force-merged 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Removing' || echo "0")
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Worktree cleanup ($repo_name): $count worktree(s) removed" >>"$LOGFILE"
				total_removed=$((total_removed + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo (legacy behaviour)
		local cleaned_output
		cleaned_output=$(bash "$helper" clean --auto --force-merged 2>&1) || true
		if echo "$cleaned_output" | grep -q "Removing\|removed"; then
			echo "[pulse-wrapper] Worktree cleanup: $(echo "$cleaned_output" | grep -c 'Removing') worktree(s) removed" >>"$LOGFILE"
		fi
	fi

	return 0
}

#######################################
# Main
#######################################
main() {
	if ! check_dedup; then
		return 0
	fi

	cleanup_orphans
	cleanup_worktrees
	calculate_max_workers
	prefetch_state
	run_pulse
	return 0
}

#######################################
# Kill orphaned opencode processes
#
# Criteria (ALL must be true):
#   - No TTY (headless — not a user's terminal tab)
#   - Not a current worker (/full-loop not in command)
#   - Not the supervisor pulse (Supervisor Pulse not in command)
#   - Not a strategic review (Strategic Review not in command)
#   - Older than ORPHAN_MAX_AGE seconds
#
# These are completed headless sessions where opencode entered idle
# state with a file watcher and never exited.
#######################################
cleanup_orphans() {
	local killed=0
	local total_mb=0

	while IFS= read -r line; do
		local pid tty etime rss cmd
		pid=$(echo "$line" | awk '{print $1}')
		tty=$(echo "$line" | awk '{print $2}')
		etime=$(echo "$line" | awk '{print $3}')
		rss=$(echo "$line" | awk '{print $4}')
		cmd=$(echo "$line" | cut -d' ' -f5-)

		# Skip interactive sessions (has a real TTY)
		if [[ "$tty" != "??" ]]; then
			continue
		fi

		# Skip active workers, pulse, strategic reviews, and language servers
		if echo "$cmd" | grep -qE '/full-loop|Supervisor Pulse|Strategic Review|language-server|eslintServer'; then
			continue
		fi

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]]; then
			continue
		fi

		# This is an orphan — kill it
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep '\.opencode' | grep -v grep | grep -v 'bash-language-server')

	# Also kill orphaned node launchers (parent of .opencode processes)
	while IFS= read -r line; do
		local pid tty etime rss cmd
		pid=$(echo "$line" | awk '{print $1}')
		tty=$(echo "$line" | awk '{print $2}')
		etime=$(echo "$line" | awk '{print $3}')
		rss=$(echo "$line" | awk '{print $4}')
		cmd=$(echo "$line" | cut -d' ' -f5-)

		[[ "$tty" != "??" ]] && continue
		echo "$cmd" | grep -qE '/full-loop|Supervisor Pulse|Strategic Review|language-server|eslintServer' && continue

		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		[[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]] && continue

		kill "$pid" 2>/dev/null || true
		local mb=$((rss / 1024))
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep 'node.*opencode' | grep -v grep | grep -v '\.opencode')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed orphaned opencode processes (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Calculate max workers from available RAM
#
# Formula: (free_ram - RAM_RESERVE_MB) / RAM_PER_WORKER_MB
# Clamped to [1, MAX_WORKERS_CAP]
#
# Writes MAX_WORKERS to a file that pulse.md reads via bash.
#######################################
calculate_max_workers() {
	local free_mb
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: use vm_stat for free + inactive (reclaimable) pages
		local page_size free_pages inactive_pages
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
		free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		inactive_pages=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		free_mb=$(((free_pages + inactive_pages) * page_size / 1024 / 1024))
	else
		# Linux: use MemAvailable from /proc/meminfo
		free_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)
	fi

	local available_mb=$((free_mb - RAM_RESERVE_MB))
	local max_workers=$((available_mb / RAM_PER_WORKER_MB))

	# Clamp to [1, MAX_WORKERS_CAP]
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	elif [[ "$max_workers" -gt "$MAX_WORKERS_CAP" ]]; then
		max_workers="$MAX_WORKERS_CAP"
	fi

	# Write to a file that pulse.md can read
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	echo "$max_workers" >"$max_workers_file"

	echo "[pulse-wrapper] Available RAM: ${free_mb}MB, reserve: ${RAM_RESERVE_MB}MB, max workers: ${max_workers}" >>"$LOGFILE"
	return 0
}

main "$@"
