#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-watchdog.sh — Detect and kill hung/idle headless AI workers (t1419)
#
# Solves: Headless workers dispatched manually (outside the pulse supervisor)
# have no monitoring. Workers that crash, hang, or enter the OpenCode idle-state
# bug sit indefinitely consuming resources and blocking issue re-dispatch.
#
# Five failure modes detected:
#   1. CPU idle: Worker completed but sits in file-watcher (OpenCode idle bug).
#      Signal: tree CPU < WORKER_IDLE_CPU_THRESHOLD for WORKER_IDLE_TIMEOUT.
#   2. Progress stall: Worker is running but producing no output (stuck on API,
#      rate-limited, spinning). Signal: no log growth for WORKER_PROGRESS_TIMEOUT,
#      then inspect recent transcript tail evidence before killing.
#   3. Zero-commit thrash: Worker runs for long time with heavy message volume
#      but no commits. Signal: elapsed >= WORKER_THRASH_ELAPSED_THRESHOLD,
#      commits == 0, messages >= WORKER_THRASH_MESSAGE_THRESHOLD.
#   4. Runtime ceiling: Worker has been running too long regardless of activity.
#      Signal: elapsed > WORKER_MAX_RUNTIME. Prevents infinite loops.
#   5. Provider backoff stall (GH#5650): Worker's provider hit auth_error or
#      rate-limit and is backed off in headless-runtime state DB. Worker process
#      stays alive but makes no progress. Signal: provider_backoff table has an
#      active entry for the worker's provider/model with retry_after in the future.
#      Kill immediately — no transcript gate needed (provider won't respond anyway).
#
# On kill:
#   - Posts a comment on the associated GitHub issue explaining the kill reason
#   - Removes the worker's status:in-progress label
#   - Adds status:available for recoverable exits (idle, stall, runtime, backoff)
#   - Adds status:blocked for zero-commit thrash to prevent blind relaunch loops
#   - Logs the action to the watchdog log file
#
# Usage:
#   worker-watchdog.sh                  # Single check (for scheduler)
#   worker-watchdog.sh --check          # Same as above
#   worker-watchdog.sh --status         # Show current worker state
#   worker-watchdog.sh --install        # Install scheduler (launchd on macOS, cron on Linux)
#   worker-watchdog.sh --uninstall      # Remove scheduler entry
#   worker-watchdog.sh --help           # Show usage
#
# Environment:
#   WORKER_IDLE_TIMEOUT          Seconds of low CPU before kill (default: 300)
#   WORKER_IDLE_CPU_THRESHOLD    CPU% below this = idle (default: 5)
#   WORKER_PROGRESS_TIMEOUT      Seconds without log growth = stuck (default: 600)
#   WORKER_THRASH_ELAPSED_THRESHOLD  Minimum runtime before thrash check (default: 3600)
#   WORKER_THRASH_MESSAGE_THRESHOLD  Minimum messages for thrash check (default: 120)
#   WORKER_THRASH_RATIO_THRESHOLD    Struggle ratio threshold for time-weighted check (default: 10)
#   WORKER_THRASH_RATIO_ELAPSED      Minimum elapsed seconds for ratio-only thrash (default: 25200 = 7h)
#   WORKER_MAX_RUNTIME           Hard ceiling in seconds (default: 10800 = 3h)
#   WORKER_DRY_RUN               Set to "true" to log but not kill (default: false)
#   WORKER_WATCHDOG_NOTIFY       Set to "false" to disable macOS notifications
#   WORKER_PROCESS_PATTERN       CLI name to match (default: opencode)
#   HEADLESS_RUNTIME_DB          Path to headless-runtime state.db (auto-detected)

set -euo pipefail

#######################################
# PATH normalisation
#######################################
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

#######################################
# Configuration
#######################################
readonly SCRIPT_NAME="worker-watchdog"
readonly SCRIPT_VERSION="1.0.0"

WORKER_IDLE_TIMEOUT="${WORKER_IDLE_TIMEOUT:-300}"                          # 5 min idle = completed, sitting in file watcher
WORKER_IDLE_CPU_THRESHOLD="${WORKER_IDLE_CPU_THRESHOLD:-5}"                # CPU% below this = idle
WORKER_PROGRESS_TIMEOUT="${WORKER_PROGRESS_TIMEOUT:-600}"                  # 10 min no log output = stuck
WORKER_THRASH_ELAPSED_THRESHOLD="${WORKER_THRASH_ELAPSED_THRESHOLD:-3600}" # 1h minimum runtime before zero-commit thrash checks (GH#4400: lowered from 2h)
WORKER_THRASH_MESSAGE_THRESHOLD="${WORKER_THRASH_MESSAGE_THRESHOLD:-120}"  # ~2 messages/min over 1h before thrash checks (GH#4400: lowered from 180)
WORKER_THRASH_RATIO_THRESHOLD="${WORKER_THRASH_RATIO_THRESHOLD:-10}"       # Struggle ratio threshold for time-weighted check (GH#5650)
WORKER_THRASH_RATIO_ELAPSED="${WORKER_THRASH_RATIO_ELAPSED:-25200}"        # 7h: ratio-only thrash check for long-running zero-commit workers (GH#5650)
WORKER_MAX_RUNTIME="${WORKER_MAX_RUNTIME:-10800}"                          # 3 hour hard ceiling
WORKER_DRY_RUN="${WORKER_DRY_RUN:-false}"
WORKER_WATCHDOG_NOTIFY="${WORKER_WATCHDOG_NOTIFY:-true}"
WORKER_PROCESS_PATTERN="${WORKER_PROCESS_PATTERN:-opencode}" # CLI name to match (update if CLI changes)

# Validate numeric config
WORKER_IDLE_TIMEOUT=$(_validate_int WORKER_IDLE_TIMEOUT "$WORKER_IDLE_TIMEOUT" 300 60)
WORKER_IDLE_CPU_THRESHOLD=$(_validate_int WORKER_IDLE_CPU_THRESHOLD "$WORKER_IDLE_CPU_THRESHOLD" 5)
WORKER_PROGRESS_TIMEOUT=$(_validate_int WORKER_PROGRESS_TIMEOUT "$WORKER_PROGRESS_TIMEOUT" 600 120)
WORKER_THRASH_ELAPSED_THRESHOLD=$(_validate_int WORKER_THRASH_ELAPSED_THRESHOLD "$WORKER_THRASH_ELAPSED_THRESHOLD" 3600 600)
WORKER_THRASH_MESSAGE_THRESHOLD=$(_validate_int WORKER_THRASH_MESSAGE_THRESHOLD "$WORKER_THRASH_MESSAGE_THRESHOLD" 120 30)
WORKER_THRASH_RATIO_THRESHOLD=$(_validate_int WORKER_THRASH_RATIO_THRESHOLD "$WORKER_THRASH_RATIO_THRESHOLD" 10 1)
WORKER_THRASH_RATIO_ELAPSED=$(_validate_int WORKER_THRASH_RATIO_ELAPSED "$WORKER_THRASH_RATIO_ELAPSED" 25200 3600)
WORKER_MAX_RUNTIME=$(_validate_int WORKER_MAX_RUNTIME "$WORKER_MAX_RUNTIME" 10800 600)

# Paths
readonly LOG_DIR="${HOME}/.aidevops/logs"
readonly LOG_FILE="${LOG_DIR}/worker-watchdog.log"
readonly STATE_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
readonly IDLE_STATE_DIR="${STATE_DIR}/worker-idle-tracking"
# headless-runtime state DB — same default as headless-runtime-helper.sh
# Not readonly: must be overridable by HEADLESS_RUNTIME_DB env var and tests
HEADLESS_RUNTIME_DB="${HEADLESS_RUNTIME_DB:-${HOME}/.aidevops/.agent-workspace/headless-runtime/state.db}"

STALL_EVIDENCE_CLASS=""
STALL_EVIDENCE_SUMMARY=""
INTERVENTION_EVIDENCE_CLASS=""
INTERVENTION_EVIDENCE_SUMMARY=""
THRASH_RATIO=""
THRASH_COMMITS=""
THRASH_MESSAGES=""
THRASH_FLAG=""
BACKOFF_PROVIDER=""
BACKOFF_REASON=""
BACKOFF_RETRY_AFTER=""

readonly LAUNCHD_LABEL="sh.aidevops.worker-watchdog"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
readonly CRON_MARKER="# aidevops: worker-watchdog"

#######################################
# Detect scheduler backend for this OS
# Output: "launchd", "cron", or "unsupported"
#######################################
_get_scheduler_backend() {
	case "$(uname -s)" in
	Darwin) echo "launchd" ;;
	Linux) echo "cron" ;;
	*) echo "unsupported" ;;
	esac
}

#######################################
# Silent check: is crontab available?
# Returns: 0 if available, 1 if not
#######################################
_has_crontab() {
	command -v crontab >/dev/null 2>&1
}

#######################################
# Require crontab to be available (with error message)
# Returns: 0 if available, 1 if not
#######################################
_require_crontab() {
	if ! _has_crontab; then
		echo "Error: crontab is not available on this system." >&2
		return 1
	fi
	return 0
}

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
	# macOS notification disabled — Notification Center alert sounds
	# cannot be suppressed per-notification; they cause system beeps.
	# if [[ "$WORKER_WATCHDOG_NOTIFY" == "true" ]] && command -v osascript &>/dev/null; then
	# 	osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null || true
	# fi
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
# Extract provider name from worker command line
#
# Workers are dispatched with a model like "anthropic/claude-sonnet-4-6".
# The provider is the prefix before the first slash.
#
# Arguments:
#   $1 - command line string
# Output: provider name (e.g., "anthropic") or empty string
#######################################
extract_provider_from_cmd() {
	local cmd="$1"
	local model=""

	# Try --model flag first
	if [[ "$cmd" =~ --model[[:space:]]+([^[:space:]]+) ]]; then
		model="${BASH_REMATCH[1]}"
	fi

	# Fall back to AIDEVOPS_HEADLESS_MODELS env var embedded in command
	if [[ -z "$model" && "$cmd" =~ AIDEVOPS_HEADLESS_MODELS=([^[:space:]]+) ]]; then
		model="${BASH_REMATCH[1]}"
		# Take first model if comma-separated list
		model="${model%%,*}"
	fi

	if [[ -z "$model" ]]; then
		echo ""
		return 0
	fi

	# Extract provider prefix (before first slash)
	local provider="${model%%/*}"
	echo "$provider"
	return 0
}

#######################################
# Query the headless-runtime DB for an active backoff row for a provider
#
# Arguments:
#   $1 - provider name (e.g., "anthropic")
# Output: "provider|reason|retry_after" or empty string
#######################################
_backoff_query_db() {
	local provider="$1"

	WATCHDOG_DB="$HEADLESS_RUNTIME_DB" WATCHDOG_PROVIDER="$provider" python3 - <<'PY'
import os
import sqlite3

db_path = os.environ["WATCHDOG_DB"]
provider = os.environ["WATCHDOG_PROVIDER"]

try:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA busy_timeout=3000")
    cursor = conn.cursor()
    # Match provider-level backoff (auth_error) or model-level backoff
    # where the model starts with this provider prefix
    cursor.execute(
        """
        SELECT provider, reason, retry_after
        FROM provider_backoff
        WHERE (provider = ? OR provider LIKE ?)
          AND (
            retry_after IS NULL
            OR retry_after > strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
          )
        ORDER BY
          CASE WHEN provider = ? THEN 0 ELSE 1 END,
          retry_after DESC
        LIMIT 1
        """,
        (provider, provider + "/%", provider),
    )
    row = cursor.fetchone()
    if row:
        matched_key, reason, retry_after = row
        print(f"{matched_key}|{reason or 'unknown'}|{retry_after or 'indefinite'}")
    else:
        print("")
except sqlite3.Error:
    print("")
PY
	return 0
}

#######################################
# Check if a worker's provider is currently backed off in the headless-runtime DB
#
# Reads the provider_backoff table from the headless-runtime state.db.
# A worker whose provider is backed off will make no progress — kill immediately.
# This check bypasses the transcript gate because the provider won't respond.
#
# Arguments:
#   $1 - PID
#   $2 - command line
#   $3 - elapsed seconds
# Returns: 0 if provider is backed off (kill), 1 if not backed off
# Side effects: sets BACKOFF_PROVIDER, BACKOFF_REASON, BACKOFF_RETRY_AFTER
#######################################
check_provider_backoff() {
	local pid="$1"
	local cmd="$2"
	local elapsed_seconds="$3"

	BACKOFF_PROVIDER=""
	BACKOFF_REASON=""
	BACKOFF_RETRY_AFTER=""

	# Only check after a minimum grace period (avoid false positives on startup)
	if [[ "$elapsed_seconds" -lt 300 ]]; then
		return 1
	fi

	# Skip if headless-runtime DB doesn't exist
	if [[ ! -f "$HEADLESS_RUNTIME_DB" ]]; then
		return 1
	fi

	# Extract provider from command line
	local provider
	provider=$(extract_provider_from_cmd "$cmd")
	if [[ -z "$provider" ]]; then
		return 1
	fi

	# Query provider_backoff table for active backoff entries matching this provider
	# A backoff is active if retry_after is in the future (or NULL = indefinite)
	local backoff_row
	backoff_row=$(_backoff_query_db "$provider") 2>/dev/null || backoff_row=""

	if [[ -z "$backoff_row" ]]; then
		return 1
	fi

	IFS='|' read -r BACKOFF_PROVIDER BACKOFF_REASON BACKOFF_RETRY_AFTER <<<"$backoff_row"
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
# Query session DB for recent message activity
#
# Arguments:
#   $1 - command line (to resolve session ID)
# Output: "true" if recent activity found, "false" otherwise
#######################################
_stall_has_recent_session_activity() {
	local cmd="$1"
	local db_path
	db_path=$(_opencode_db_path)

	if [[ ! -f "$db_path" ]]; then
		echo "false"
		return 0
	fi

	local session_id=""
	session_id=$(_resolve_session_id_from_cmd "$cmd")

	if [[ -z "$session_id" ]]; then
		echo "false"
		return 0
	fi

	local recent_count
	recent_count=$(
		SESSION_WATCHDOG_DB_PATH="$db_path" SESSION_WATCHDOG_ID="$session_id" SESSION_WATCHDOG_TIMEOUT="$WORKER_PROGRESS_TIMEOUT" python3 - <<'PY'
import os
import sqlite3

db_path = os.environ["SESSION_WATCHDOG_DB_PATH"]
session_id = os.environ["SESSION_WATCHDOG_ID"]
timeout_seconds = int(os.environ["SESSION_WATCHDOG_TIMEOUT"])

conn = sqlite3.connect(db_path)
conn.execute("PRAGMA busy_timeout=5000")
cursor = conn.cursor()
cursor.execute(
    """
    SELECT COUNT(*)
    FROM message
    WHERE session_id = ?
      AND (CASE WHEN time_created > 20000000000 THEN time_created / 1000 ELSE time_created END) > strftime('%s', 'now') - ?
    """,
    (session_id, timeout_seconds),
)
row = cursor.fetchone()
print(int(row[0] or 0))
PY
	)

	if [[ "$recent_count" -gt 0 ]]; then
		echo "true"
	else
		echo "false"
	fi
	return 0
}

#######################################
# Handle stall grace period for provider-waiting evidence
#
# Arguments:
#   $1 - PID
#   $2 - grace_file path
#   $3 - now (epoch seconds)
#   $4 - sanitized evidence string
# Returns: 0 if grace period expired (proceed to kill), 1 if still in grace
#######################################
_stall_check_grace_period() {
	local pid="$1"
	local grace_file="$2"
	local now="$3"
	local sanitized_evidence="$4"

	if [[ ! -f "$grace_file" ]]; then
		date +%s >"$grace_file"
		log_msg "STALL GRACE: PID=${pid} evidence=${sanitized_evidence}"
		return 1
	fi

	local grace_since
	grace_since=$(cat "$grace_file" 2>/dev/null || echo "0")
	[[ "$grace_since" =~ ^[0-9]+$ ]] || grace_since=0
	local grace_duration=$((now - grace_since))
	if [[ "$grace_duration" -lt "$WORKER_PROGRESS_TIMEOUT" ]]; then
		return 1
	fi
	return 0
}

#######################################
# Evaluate stall evidence and decide whether to kill
#
# Called after stall duration threshold is exceeded.
# Sets STALL_EVIDENCE_CLASS and STALL_EVIDENCE_SUMMARY.
#
# Arguments:
#   $1 - PID
#   $2 - command line
#   $3 - stall_file path
#   $4 - grace_file path
#   $5 - now (epoch seconds)
# Returns: 0 if stall confirmed (kill), 1 if stall cleared or deferred
#######################################
_stall_evaluate_evidence() {
	local pid="$1"
	local cmd="$2"
	local stall_file="$3"
	local grace_file="$4"
	local now="$5"

	local evidence_result
	evidence_result=$(_get_session_tail_evidence "$cmd" "$WORKER_PROGRESS_TIMEOUT")
	IFS='|' read -r STALL_EVIDENCE_CLASS STALL_EVIDENCE_SUMMARY <<<"$evidence_result"
	local sanitized_evidence
	sanitized_evidence=$(_sanitize_log_field "$STALL_EVIDENCE_SUMMARY")

	if [[ "$STALL_EVIDENCE_CLASS" == "active" ]]; then
		log_msg "STALL CLEARED: PID=${pid} evidence=${sanitized_evidence}"
		rm -f "$stall_file" "$grace_file" 2>/dev/null || true
		return 1
	fi

	if [[ "$STALL_EVIDENCE_CLASS" == "provider-waiting" ]]; then
		if ! _stall_check_grace_period "$pid" "$grace_file" "$now" "$sanitized_evidence"; then
			return 1
		fi
	else
		rm -f "$grace_file" 2>/dev/null || true
	fi

	return 0
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
	local grace_file="${IDLE_STATE_DIR}/stall-grace-${pid}"
	STALL_EVIDENCE_CLASS=""
	STALL_EVIDENCE_SUMMARY=""

	# Skip progress check for very young workers (< 10 min)
	if [[ "$elapsed_seconds" -lt 600 ]]; then
		rm -f "$stall_file" "$grace_file" 2>/dev/null || true
		return 1
	fi

	local has_recent_activity
	has_recent_activity=$(_stall_has_recent_session_activity "$cmd")

	if [[ "$has_recent_activity" == "true" ]]; then
		# Activity detected — reset stall tracking
		rm -f "$stall_file" "$grace_file" 2>/dev/null || true
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
		_stall_evaluate_evidence "$pid" "$cmd" "$stall_file" "$grace_file" "$now"
		return $?
	fi
	return 1
}

#######################################
# Transcript-first intervention gate
#
# Every kill action must be justified by transcript evidence. Metrics can
# propose candidates, but transcript evidence decides whether intervention
# is permitted in this cycle.
#
# Arguments:
#   $1 - signal type (runtime|thrash|idle|stall)
#   $2 - worker command line
#   $3 - elapsed seconds
# Returns: 0 if intervention is allowed, 1 if it should be deferred
#######################################
transcript_allows_intervention() {
	local signal_type="$1"
	local cmd="$2"
	local elapsed_seconds="$3"

	INTERVENTION_EVIDENCE_CLASS=""
	INTERVENTION_EVIDENCE_SUMMARY=""

	local evidence_result
	evidence_result=$(_get_session_tail_evidence "$cmd" "$WORKER_PROGRESS_TIMEOUT" 12)
	IFS='|' read -r INTERVENTION_EVIDENCE_CLASS INTERVENTION_EVIDENCE_SUMMARY <<<"$evidence_result"

	local safe_evidence
	safe_evidence=$(_sanitize_log_field "$INTERVENTION_EVIDENCE_SUMMARY")

	if [[ -z "$INTERVENTION_EVIDENCE_CLASS" || "$INTERVENTION_EVIDENCE_CLASS" == "none" ]]; then
		log_msg "TRANSCRIPT DEFER: signal=${signal_type} elapsed=${elapsed_seconds}s reason=no-session-evidence evidence=${safe_evidence}"
		return 1
	fi

	case "$INTERVENTION_EVIDENCE_CLASS" in
	active)
		log_msg "TRANSCRIPT DEFER: signal=${signal_type} elapsed=${elapsed_seconds}s reason=active-session evidence=${safe_evidence}"
		return 1
		;;
	provider-waiting)
		log_msg "TRANSCRIPT DEFER: signal=${signal_type} elapsed=${elapsed_seconds}s reason=provider-wait evidence=${safe_evidence}"
		return 1
		;;
	esac

	return 0
}

#######################################
# Check if a worker is in zero-commit high-message thrash
#
# Uses _compute_struggle_ratio to detect workers that are producing many
# model messages over a long runtime without producing commits.
#
# Arguments:
#   $1 - PID
#   $2 - command line
#   $3 - elapsed seconds
# Returns: 0 if thrashing, 1 otherwise
#######################################
check_zero_commit_thrashing() {
	local pid="$1"
	local cmd="$2"
	local elapsed_seconds="$3"

	THRASH_RATIO=""
	THRASH_COMMITS=""
	THRASH_MESSAGES=""
	THRASH_FLAG=""

	if [[ "$elapsed_seconds" -lt "$WORKER_THRASH_ELAPSED_THRESHOLD" ]]; then
		return 1
	fi

	local sr_result
	sr_result=$(_compute_struggle_ratio "$pid" "$elapsed_seconds" "$cmd")
	IFS='|' read -r THRASH_RATIO THRASH_COMMITS THRASH_MESSAGES THRASH_FLAG <<<"$sr_result"

	[[ "$THRASH_RATIO" =~ ^[0-9]+$ ]] || return 1
	[[ "$THRASH_COMMITS" =~ ^[0-9]+$ ]] || return 1
	[[ "$THRASH_MESSAGES" =~ ^[0-9]+$ ]] || return 1

	if [[ "$THRASH_COMMITS" -ne 0 ]]; then
		return 1
	fi

	# Primary thrash check: high message volume + thrashing flag
	if [[ "$THRASH_MESSAGES" -ge "$WORKER_THRASH_MESSAGE_THRESHOLD" && "$THRASH_FLAG" == "thrashing" ]]; then
		return 0
	fi

	# Time-weighted thrash check (GH#5650): long-running zero-commit workers with
	# any non-trivial struggle ratio. Catches workers with ratio 14 at 7+ hours
	# that the primary check misses (ratio < 30 threshold, flag != "thrashing").
	# Rationale: ratio 14 at 7h with 0 commits = ~98 messages, no output. Clearly stuck.
	if [[ "$elapsed_seconds" -ge "$WORKER_THRASH_RATIO_ELAPSED" && "$THRASH_RATIO" -ge "$WORKER_THRASH_RATIO_THRESHOLD" ]]; then
		THRASH_FLAG="time-weighted-thrash"
		return 0
	fi

	return 1
}

#######################################
# Kill a worker and handle cleanup
#
# Arguments:
#   $1 - PID
#   $2 - reason (idle|stall|thrash|runtime)
#   $3 - command line
#   $4 - elapsed seconds
#   $5 - evidence summary (optional)
#######################################
kill_worker() {
	local pid="$1"
	local reason="$2"
	local cmd="$3"
	local elapsed_seconds="$4"
	local evidence_summary="${5:-}"

	local duration
	duration=$(_format_duration "$elapsed_seconds")
	local sanitized_cmd
	sanitized_cmd=$(_sanitize_log_field "$cmd")
	local sanitized_evidence=""
	if [[ -n "$evidence_summary" ]]; then
		sanitized_evidence=$(_sanitize_log_field "$evidence_summary")
	fi

	if [[ "$WORKER_DRY_RUN" == "true" ]]; then
		log_msg "DRY RUN: Would kill worker PID=${pid} reason=${reason} elapsed=${duration} cmd=${sanitized_cmd}${sanitized_evidence:+ evidence=${sanitized_evidence}}"
		echo "  DRY RUN: Would kill PID ${pid} (${reason}, running ${duration})"
		return 0
	fi

	log_msg "Killing worker PID=${pid} reason=${reason} elapsed=${duration} cmd=${sanitized_cmd}${sanitized_evidence:+ evidence=${sanitized_evidence}}"

	# Graceful kill first
	_kill_tree "$pid" || true
	sleep 2

	# Force kill if still alive
	if kill -0 "$pid" 2>/dev/null; then
		_force_kill_tree "$pid" || true
		log_msg "Force-killed worker PID=${pid}"
	fi

	# Clean up idle/stall tracking files
	rm -f "${IDLE_STATE_DIR}/idle-${pid}" "${IDLE_STATE_DIR}/stall-${pid}" "${IDLE_STATE_DIR}/stall-grace-${pid}" 2>/dev/null || true

	# Post-kill: update GitHub issue labels and comment
	post_kill_github_update "$cmd" "$reason" "$duration" "$evidence_summary"

	# Notify
	notify "Worker Watchdog" "Killed worker (${reason}) after ${duration}"

	return 0
}

#######################################
# Map kill reason to human-readable description and destination status
#
# Arguments:
#   $1 - kill reason (idle|stall|thrash|runtime|backoff|*)
#   $2 - formatted duration
#   $3 - evidence summary
# Output: "reason_desc|destination_status|destination_text" (pipe-separated)
#######################################
_post_kill_map_reason() {
	local reason="$1"
	local duration="$2"
	local evidence_summary="$3"

	local reason_desc=""
	local destination_status="status:available"
	local destination_text="This issue has been re-labeled \`status:available\` for re-dispatch. The next pulse or manual dispatch will pick it up."

	case "$reason" in
	idle) reason_desc="Worker process became idle (CPU below ${WORKER_IDLE_CPU_THRESHOLD}% for ${WORKER_IDLE_TIMEOUT}s) — likely completed or hit the OpenCode idle-state bug." ;;
	stall) reason_desc="Worker stopped producing output for ${WORKER_PROGRESS_TIMEOUT}s — likely stuck on API rate limiting or an unrecoverable error." ;;
	thrash)
		reason_desc="Worker hit zero-commit/high-message thrash guardrail (runtime >= ${WORKER_THRASH_ELAPSED_THRESHOLD}s, commits=0, messages >= ${WORKER_THRASH_MESSAGE_THRESHOLD})."
		destination_status="status:blocked"
		destination_text="This issue has been re-labeled \`status:blocked\` to prevent blind re-dispatch of the same failing strategy."
		;;
	runtime) reason_desc="Worker exceeded the ${duration} runtime ceiling — killed to prevent infinite loops." ;;
	backoff) reason_desc="Worker's provider is backed off in the headless-runtime state DB (${evidence_summary}). Worker was alive but making no progress — killed for immediate re-queue." ;;
	*) reason_desc="Worker killed by watchdog (reason: ${reason})." ;;
	esac

	echo "${reason_desc}|${destination_status}|${destination_text}"
	return 0
}

#######################################
# Post kill comment and update labels on a GitHub issue
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - reason description
#   $4 - formatted duration
#   $5 - evidence summary
#   $6 - destination status label
#   $7 - destination text
#######################################
_post_kill_github_comment_and_labels() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason_desc="$3"
	local duration="$4"
	local evidence_summary="$5"
	local destination_status="$6"
	local destination_text="$7"

	local comment_body="## Worker Watchdog Kill

**Reason:** ${reason_desc}

**Runtime:** ${duration}

**Diagnostic tail:** ${evidence_summary}

${destination_text}

**Retry guidance:** Post a blocker update describing a changed plan (or newly unblocked dependency), then move the issue back to \`status:available\` before re-dispatch.

_Automated by \`worker-watchdog.sh\` (t1419)_"
	comment_body=$(_sanitize_markdown "$comment_body")

	if gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" 2>>"$LOG_FILE"; then
		log_msg "Posted kill comment on ${repo_slug}#${issue_number}"
	else
		log_msg "Failed to post comment on ${repo_slug}#${issue_number}"
	fi

	# Remove stale status labels and add destination status label.
	# For thrash kills destination is status:blocked, otherwise status:available.
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--remove-label "status:in-progress" \
		--remove-label "status:claimed" \
		--remove-label "status:queued" \
		--remove-label "status:available" \
		--remove-label "status:blocked" \
		--add-label "$destination_status" 2>>"$LOG_FILE" || {
		log_msg "Failed to update labels on ${repo_slug}#${issue_number}"
	}

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
#   $4 - evidence summary (optional)
#######################################
post_kill_github_update() {
	local cmd="$1"
	local reason="$2"
	local duration="$3"
	local evidence_summary="${4:-No transcript evidence available.}"

	# Extract issue number and repo slug
	local issue_number
	issue_number=$(extract_issue_number "$cmd")
	local repo_slug
	repo_slug=$(extract_repo_slug "$cmd")

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		log_msg "Cannot update GitHub: issue=${issue_number:-unknown} repo=${repo_slug:-unknown}"
		return 0
	fi

	local mapped_reason
	mapped_reason=$(_post_kill_map_reason "$reason" "$duration" "$evidence_summary")
	local reason_desc destination_status destination_text
	IFS='|' read -r reason_desc destination_status destination_text <<<"$mapped_reason"

	_post_kill_github_comment_and_labels \
		"$issue_number" "$repo_slug" "$reason_desc" \
		"$duration" "$evidence_summary" \
		"$destination_status" "$destination_text"

	# Record failure in the fast-fail counter and escalate tier if threshold reached.
	# The fast-fail state file is shared with pulse-wrapper.sh — both use the same
	# JSON file so pulse can skip issues that the watchdog has flagged. (GH#2076)
	local provider
	provider=$(extract_provider_from_cmd "$cmd")
	_watchdog_record_failure_and_escalate "$issue_number" "$repo_slug" "$reason" "$provider" || true

	return 0
}

#######################################
# Record a watchdog kill in the shared fast-fail state and trigger
# tier escalation when threshold is reached.
#
# Uses the same state file and locking as pulse-wrapper.sh's
# fast_fail_record(). The watchdog writes cause-aware entries with
# the same format: { count, ts, reason, retry_after, backoff_secs }.
#
# Rate-limit kills (reason=backoff) query the account pool to decide
# whether to back off or allow immediate retry with a rotated account.
# Non-rate-limit kills use exponential backoff. (GH#2076, GH#17378)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - kill reason (idle, stall, thrash, runtime, backoff, etc.)
#   $4 - provider (anthropic, openai, cursor, google; default: anthropic)
#######################################
_watchdog_record_failure_and_escalate() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local provider="${4:-anthropic}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local state_file="${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json"
	local state_dir
	state_dir=$(dirname "$state_file")
	mkdir -p "$state_dir" 2>/dev/null || true

	# Acquire lock (shared with pulse-wrapper.sh's _ff_with_lock)
	local lock_dir="${state_file}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			log_msg "Fast-fail lock timeout for #${issue_number} (${repo_slug})"
			return 0
		fi
		sleep 0.1
	done

	local key now state
	key="${repo_slug}/${issue_number}"
	now=$(date +%s)

	# Load state
	if [[ -f "$state_file" ]]; then
		state=$(cat "$state_file" 2>/dev/null) || state="{}"
		printf '%s' "$state" | jq empty 2>/dev/null || state="{}"
	else
		state="{}"
	fi

	local expiry_secs="${FAST_FAIL_EXPIRY_SECS:-604800}"
	local initial_backoff="${FAST_FAIL_INITIAL_BACKOFF_SECS:-600}"
	local max_backoff="${FAST_FAIL_MAX_BACKOFF_SECS:-604800}"

	# Read existing entry
	local existing_ts existing_count existing_backoff
	existing_ts=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].ts // 0' 2>/dev/null) || existing_ts=0
	existing_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].count // 0' 2>/dev/null) || existing_count=0
	existing_backoff=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].backoff_secs // 0' 2>/dev/null) || existing_backoff=0
	[[ "$existing_ts" =~ ^[0-9]+$ ]] || existing_ts=0
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	[[ "$existing_backoff" =~ ^[0-9]+$ ]] || existing_backoff=0

	local age=$((now - existing_ts))
	if [[ "$age" -ge "$expiry_secs" ]]; then
		existing_count=0
		existing_backoff=0
	fi

	# Cause-aware backoff (mirrors pulse-wrapper.sh logic)
	local new_count="$existing_count"
	local new_backoff="$existing_backoff"
	local retry_after=0
	local log_action=""

	case "$reason" in
	backoff | rate_limit*)
		# Rate-limit kill: check account pool
		local pool_file="${HOME}/.aidevops/oauth-pool.json"
		local pool_wait="-1"
		if [[ -f "$pool_file" ]]; then
			pool_wait=$(POOL_FILE="$pool_file" PROVIDER="$provider" python3 -c "
import json, os, time, sys
try:
    pool = json.load(open(os.environ['POOL_FILE']))
    now_ms = int(time.time() * 1000)
    accounts = pool.get(os.environ['PROVIDER'], [])
    if not accounts: print(-1); sys.exit(0)
    min_remaining = None
    for a in accounts:
        cd = a.get('cooldownUntil')
        if cd and int(cd) > now_ms and a.get('status') == 'rate-limited':
            remaining_s = max(1, (int(cd) - now_ms) // 1000)
            min_remaining = min(min_remaining, remaining_s) if min_remaining else remaining_s
        else:
            print(0); sys.exit(0)
    print(min_remaining or 0)
except Exception: print(-1)
" 2>/dev/null) || pool_wait="-1"
		fi
		[[ "$pool_wait" =~ ^-?[0-9]+$ ]] || pool_wait="-1"

		if [[ "$pool_wait" == "0" ]]; then
			retry_after=0
			log_action="rate_limit_rotate (accounts available)"
		elif [[ "$pool_wait" == "-1" ]]; then
			new_count=$((existing_count + 1))
			new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : initial_backoff))
			[[ "$new_backoff" -gt "$max_backoff" ]] && new_backoff="$max_backoff"
			retry_after=$((now + new_backoff))
			log_action="rate_limit_no_pool (backoff=${new_backoff}s)"
		else
			new_count=$((existing_count + 1))
			retry_after=$((now + pool_wait))
			new_backoff="$pool_wait"
			log_action="rate_limit_exhausted (wait=${pool_wait}s)"
		fi
		;;
	*)
		new_count=$((existing_count + 1))
		new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : initial_backoff))
		[[ "$new_backoff" -gt "$max_backoff" ]] && new_backoff="$max_backoff"
		retry_after=$((now + new_backoff))
		log_action="failure_backoff (count=${new_count}, backoff=${new_backoff}s)"
		;;
	esac

	# Write updated state
	local updated_state
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		--argjson count "$new_count" \
		--argjson ts "$now" \
		--arg reason "$reason" \
		--argjson retry_after "$retry_after" \
		--argjson backoff_secs "$new_backoff" \
		'.[$k] = {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs}' 2>/dev/null) || {
		rmdir "$lock_dir" 2>/dev/null || true
		return 0
	}

	local tmp_file
	tmp_file=$(mktemp "${state_dir}/.fast-fail-counter.XXXXXX" 2>/dev/null) || {
		rmdir "$lock_dir" 2>/dev/null || true
		return 0
	}
	if printf '%s\n' "$updated_state" >"$tmp_file"; then
		mv "$tmp_file" "$state_file" || rm -f "$tmp_file"
	else
		rm -f "$tmp_file"
	fi

	# Release lock
	rmdir "$lock_dir" 2>/dev/null || true

	log_msg "Fast-fail: #${issue_number} (${repo_slug}) ${log_action} reason=${reason}"

	# Trigger tier escalation on non-rate-limit failures
	if [[ "$new_count" -gt "$existing_count" ]]; then
		escalate_issue_tier "$issue_number" "$repo_slug" "$new_count" "$reason"
	fi

	return 0
}

#######################################
# Handle thrash detection signal for a single worker
#
# Called when check_zero_commit_thrashing returns 0.
# Applies transcript gate and kills if confirmed.
#
# Arguments:
#   $1 - PID
#   $2 - command line
#   $3 - elapsed seconds
#   $4 - formatted duration
# Returns: 0 if worker was killed, 1 if deferred
#######################################
_check_single_worker_thrash() {
	local pid="$1"
	local cmd="$2"
	local elapsed_seconds="$3"
	local duration="$4"

	if ! transcript_allows_intervention "thrash" "$cmd" "$elapsed_seconds"; then
		return 1
	fi

	local thrash_evidence="ratio=${THRASH_RATIO} messages=${THRASH_MESSAGES} commits=${THRASH_COMMITS} flag=${THRASH_FLAG:-none}"
	local session_title
	session_title=$(_extract_session_title "$cmd")
	if [[ -n "$session_title" ]]; then
		thrash_evidence="${thrash_evidence}; objective=${session_title}"
	fi
	if [[ -n "$INTERVENTION_EVIDENCE_SUMMARY" ]]; then
		thrash_evidence="${thrash_evidence}; transcript=${INTERVENTION_EVIDENCE_SUMMARY}"
	fi

	log_msg "THRASH DETECTED: PID=${pid} elapsed=${duration} ${thrash_evidence}"
	kill_worker "$pid" "thrash" "$cmd" "$elapsed_seconds" "$thrash_evidence"
	return 0
}

#######################################
# Apply all detection signals to a single worker
#
# Arguments:
#   $1 - PID
#   $2 - elapsed seconds
#   $3 - command line
# Returns: 0 if worker was killed, 1 if worker was spared
#######################################
_check_single_worker() {
	local pid="$1"
	local elapsed_seconds="$2"
	local cmd="$3"

	local tree_cpu
	tree_cpu=$(_get_process_tree_cpu "$pid")

	local duration
	duration=$(_format_duration "$elapsed_seconds")

	# Check 1: Provider backoff stall (GH#5650) — kill immediately, no transcript gate.
	# A worker whose provider is backed off will never make progress. The transcript
	# gate is irrelevant — the provider won't respond regardless of what the transcript says.
	if check_provider_backoff "$pid" "$cmd" "$elapsed_seconds"; then
		local backoff_evidence="provider=${BACKOFF_PROVIDER} reason=${BACKOFF_REASON} retry_after=${BACKOFF_RETRY_AFTER}"
		log_msg "PROVIDER BACKOFF: PID=${pid} elapsed=${duration} ${backoff_evidence}"
		kill_worker "$pid" "backoff" "$cmd" "$elapsed_seconds" "$backoff_evidence"
		return 0
	fi

	# Check 2: Runtime ceiling candidate (transcript gate decides kill/defer)
	if [[ "$elapsed_seconds" -ge "$WORKER_MAX_RUNTIME" ]]; then
		if ! transcript_allows_intervention "runtime" "$cmd" "$elapsed_seconds"; then
			return 1
		fi
		log_msg "RUNTIME CEILING: PID=${pid} elapsed=${duration} (max=$(_format_duration "$WORKER_MAX_RUNTIME"))"
		kill_worker "$pid" "runtime" "$cmd" "$elapsed_seconds" "$INTERVENTION_EVIDENCE_SUMMARY"
		return 0
	fi

	# Check 3: zero-commit high-message thrash detection
	if check_zero_commit_thrashing "$pid" "$cmd" "$elapsed_seconds"; then
		_check_single_worker_thrash "$pid" "$cmd" "$elapsed_seconds" "$duration"
		return $?
	fi

	# Check 4: CPU idle detection
	if check_idle "$pid" "$tree_cpu"; then
		if ! transcript_allows_intervention "idle" "$cmd" "$elapsed_seconds"; then
			return 1
		fi
		log_msg "IDLE DETECTED: PID=${pid} cpu=${tree_cpu}% elapsed=${duration}"
		kill_worker "$pid" "idle" "$cmd" "$elapsed_seconds" "$INTERVENTION_EVIDENCE_SUMMARY"
		return 0
	fi

	# Check 5: Progress stall detection
	if check_progress_stall "$pid" "$cmd" "$elapsed_seconds"; then
		if ! transcript_allows_intervention "stall" "$cmd" "$elapsed_seconds"; then
			return 1
		fi
		local sanitized_evidence=""
		if [[ -n "$STALL_EVIDENCE_SUMMARY" ]]; then
			sanitized_evidence=$(_sanitize_log_field "$STALL_EVIDENCE_SUMMARY")
		fi
		log_msg "PROGRESS STALL: PID=${pid} elapsed=${duration}${sanitized_evidence:+ evidence=${sanitized_evidence}}"
		kill_worker "$pid" "stall" "$cmd" "$elapsed_seconds" "$STALL_EVIDENCE_SUMMARY"
		return 0
	fi

	return 1
}

#######################################
# Remove tracking files for PIDs that no longer exist
#######################################
_cleanup_stale_tracking_files() {
	local tracking_file
	for tracking_file in "${IDLE_STATE_DIR}"/idle-* "${IDLE_STATE_DIR}"/stall-* "${IDLE_STATE_DIR}"/stall-grace-*; do
		[[ -f "$tracking_file" ]] || continue
		local tracked_pid
		tracked_pid=$(basename "$tracking_file" | sed 's/^idle-//;s/^stall-//;s/^grace-//')
		if [[ "$tracked_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$tracked_pid" 2>/dev/null; then
			rm -f "$tracking_file" 2>/dev/null || true
		fi
	done
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
		rm -f "${IDLE_STATE_DIR}"/idle-* "${IDLE_STATE_DIR}"/stall-* "${IDLE_STATE_DIR}"/stall-grace-* 2>/dev/null || true
		return 0
	fi

	local worker_count=0
	local killed_count=0

	while IFS='|' read -r pid elapsed_seconds cmd; do
		[[ -z "$pid" ]] && continue
		worker_count=$((worker_count + 1))
		if _check_single_worker "$pid" "$elapsed_seconds" "$cmd"; then
			killed_count=$((killed_count + 1))
		fi
	done <<<"$workers"

	if [[ "$killed_count" -gt 0 ]]; then
		log_msg "Check complete: ${worker_count} workers scanned, ${killed_count} killed"
	fi

	_cleanup_stale_tracking_files

	return 0
}

#######################################
# Print the configuration section of --status
#######################################
_status_print_config() {
	echo "--- Configuration ---"
	echo ""
	echo "  Idle timeout:        $(_format_duration "$WORKER_IDLE_TIMEOUT") (CPU < ${WORKER_IDLE_CPU_THRESHOLD}%)"
	echo "  Progress timeout:    $(_format_duration "$WORKER_PROGRESS_TIMEOUT")"
	echo "  Runtime ceiling:     $(_format_duration "$WORKER_MAX_RUNTIME")"
	echo "  Thrash guardrail:    elapsed >= $(_format_duration "$WORKER_THRASH_ELAPSED_THRESHOLD"), messages >= ${WORKER_THRASH_MESSAGE_THRESHOLD}, commits = 0"
	echo "  Thrash (time-wt):    elapsed >= $(_format_duration "$WORKER_THRASH_RATIO_ELAPSED"), ratio >= ${WORKER_THRASH_RATIO_THRESHOLD}, commits = 0 (GH#5650)"
	echo "  Provider backoff:    DB=${HEADLESS_RUNTIME_DB}"
	echo "  Dry run:             ${WORKER_DRY_RUN}"
	echo "  Notifications:       ${WORKER_WATCHDOG_NOTIFY}"
	return 0
}

#######################################
# Print idle/stall/grace tracking state for a worker in --status output
#
# Arguments:
#   $1 - PID
#######################################
_status_print_worker_tracking() {
	local pid="$1"
	local now
	now=$(date +%s)

	if [[ -f "${IDLE_STATE_DIR}/idle-${pid}" ]]; then
		local idle_since
		idle_since=$(cat "${IDLE_STATE_DIR}/idle-${pid}" 2>/dev/null || echo "0")
		local idle_for=$((now - idle_since))
		echo "    Idle for: $(_format_duration "$idle_for") / $(_format_duration "$WORKER_IDLE_TIMEOUT")"
	fi

	if [[ -f "${IDLE_STATE_DIR}/stall-${pid}" ]]; then
		local stall_since
		stall_since=$(cat "${IDLE_STATE_DIR}/stall-${pid}" 2>/dev/null || echo "0")
		local stall_for=$((now - stall_since))
		echo "    Stalled:  $(_format_duration "$stall_for") / $(_format_duration "$WORKER_PROGRESS_TIMEOUT")"
	fi

	if [[ -f "${IDLE_STATE_DIR}/stall-grace-${pid}" ]]; then
		local grace_since
		grace_since=$(cat "${IDLE_STATE_DIR}/stall-grace-${pid}" 2>/dev/null || echo "0")
		local grace_for=$((now - grace_since))
		echo "    Grace:    $(_format_duration "$grace_for") / $(_format_duration "$WORKER_PROGRESS_TIMEOUT")"
	fi

	return 0
}

#######################################
# Print details for a single worker in --status output
#
# Arguments:
#   $1 - worker index (display number)
#   $2 - PID
#   $3 - elapsed seconds
#   $4 - command line
#######################################
_status_print_worker() {
	local count="$1"
	local pid="$2"
	local elapsed_seconds="$3"
	local cmd="$4"

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

	_status_print_worker_tracking "$pid"

	# Struggle ratio
	local sr_result
	sr_result=$(_compute_struggle_ratio "$pid" "$elapsed_seconds" "$cmd")
	local sr_ratio sr_commits sr_messages sr_flag
	IFS='|' read -r sr_ratio sr_commits sr_messages sr_flag <<<"$sr_result"
	if [[ "$sr_ratio" != "n/a" ]]; then
		echo "    Struggle: ratio=${sr_ratio} commits=${sr_commits} messages=${sr_messages} ${sr_flag:+[${sr_flag}]}"
	fi

	# Provider backoff state
	local status_provider
	status_provider=$(extract_provider_from_cmd "$cmd")
	if [[ -n "$status_provider" ]]; then
		if check_provider_backoff "$pid" "$cmd" 300; then
			echo "    Backoff:  ACTIVE provider=${BACKOFF_PROVIDER} reason=${BACKOFF_REASON} retry_after=${BACKOFF_RETRY_AFTER}"
		else
			echo "    Backoff:  none (provider=${status_provider})"
		fi
	fi

	echo ""
	return 0
}

#######################################
# Print the scheduler section of --status
#
# Arguments:
#   $1 - backend ("launchd", "cron", or "unsupported")
#######################################
_status_print_scheduler() {
	local backend="$1"

	echo "--- Scheduler (${backend}) ---"
	echo ""
	if [[ "$backend" == "launchd" ]]; then
		if [[ -f "${PLIST_PATH}" ]]; then
			# Capture output to avoid SIGPIPE under set -o pipefail
			local launchctl_out
			launchctl_out=$(launchctl list 2>/dev/null) || true
			if echo "$launchctl_out" | grep -q "${LAUNCHD_LABEL}"; then
				echo "  Status: installed and loaded"
			else
				echo "  Status: installed but NOT loaded"
			fi
		else
			echo "  Status: not installed (run --install)"
		fi
	elif [[ "$backend" == "cron" ]]; then
		# Linux: check cron (single crontab -l call)
		if ! _has_crontab; then
			echo "  Status: crontab unavailable"
		else
			local cron_entry
			cron_entry=$(crontab -l 2>/dev/null | grep -F "$CRON_MARKER") || true
			if [[ -n "$cron_entry" ]]; then
				echo "  Status: installed"
				echo "  Entry:  ${cron_entry}"
			else
				echo "  Status: not installed (run --install)"
			fi
		fi
	else
		echo "  Status: unsupported OS ($(uname -s))"
	fi
	return 0
}

#######################################
# Status: show current worker state
#######################################
cmd_status() {
	ensure_dirs

	echo "=== Worker Watchdog Status ==="
	echo ""
	_status_print_config
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
			_status_print_worker "$count" "$pid" "$elapsed_seconds" "$cmd"
		done <<<"$workers"
		echo "  Total: ${count} worker(s)"
	fi

	local backend
	backend="$(_get_scheduler_backend)"

	echo ""
	_status_print_scheduler "$backend"

	echo ""
	return 0
}

#######################################
# Install scheduler (launchd on macOS, cron on Linux)
#######################################
cmd_install() {
	local script_path
	script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
	local installed_path="${HOME}/.aidevops/agents/scripts/${SCRIPT_NAME}.sh"
	if [[ -x "${installed_path}" ]]; then
		script_path="${installed_path}"
	fi

	ensure_dirs

	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "unsupported" ]]; then
		echo "Unsupported OS: $(uname -s). Supported backends: macOS (launchd), Linux (cron)." >&2
		return 1
	fi

	if [[ "$backend" == "launchd" ]]; then
		_install_launchd "$script_path"
	else
		_install_cron "$script_path"
	fi

	return 0
}

#######################################
# Install launchd plist (macOS)
# Arguments:
#   $1 - script path
#######################################
_install_launchd() {
	local script_path="$1"
	local home_escaped="${HOME}"

	mkdir -p "$(dirname "${PLIST_PATH}")"

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
# Install cron entry (Linux)
# Arguments:
#   $1 - script path
#######################################
_install_cron() {
	local script_path="$1"
	_require_crontab || return 1
	local cron_line="*/2 * * * * /bin/bash ${script_path} --check >> ${LOG_FILE} 2>&1 ${CRON_MARKER}"

	# Remove any existing watchdog entry, then add the new one (pipe to crontab -)
	# Note: || true guards against set -e + pipefail when crontab -l has no entries
	(
		crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" || true
		echo "$cron_line"
	) | crontab -

	echo "Installed cron entry for worker-watchdog"
	echo "Schedule: every 2 minutes"
	echo "Log: ${LOG_FILE}"
	echo ""
	echo "  Uninstall with: ${SCRIPT_NAME}.sh --uninstall"
	return 0
}

#######################################
# Uninstall scheduler (launchd on macOS, cron on Linux)
#######################################
cmd_uninstall() {
	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "unsupported" ]]; then
		echo "Unsupported OS: $(uname -s). Supported backends: macOS (launchd), Linux (cron)." >&2
		return 1
	fi

	if [[ "$backend" == "launchd" ]]; then
		if [[ -f "${PLIST_PATH}" ]]; then
			launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
			rm -f "${PLIST_PATH}"
			echo "Uninstalled: ${LAUNCHD_LABEL}"
		else
			echo "Not installed (launchd)"
		fi
	else
		# Linux: remove cron entry (single crontab -l call)
		_require_crontab || return 1
		local current_crontab
		current_crontab=$(crontab -l 2>/dev/null) || true
		if echo "$current_crontab" | grep -qF "$CRON_MARKER"; then
			echo "$current_crontab" | grep -vF "$CRON_MARKER" | crontab -
			echo "Uninstalled cron entry for worker-watchdog"
		else
			echo "Not installed (cron)"
		fi
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
  --check, -c       Single check (default, for scheduler)
  --status, -s      Show current worker state
  --install, -i     Install scheduler (launchd on macOS, cron on Linux)
  --uninstall, -u   Remove scheduler entry and state files
  --help, -h        Show this help

Detection signals:
  Provider backoff: Worker's provider is backed off in headless-runtime DB — kill immediately (GH#5650)
  Zero-commit thrash: elapsed >= $(_format_duration "$WORKER_THRASH_ELAPSED_THRESHOLD"), commits = 0, messages >= ${WORKER_THRASH_MESSAGE_THRESHOLD}
  Thrash (time-wt): elapsed >= $(_format_duration "$WORKER_THRASH_RATIO_ELAPSED"), commits = 0, ratio >= ${WORKER_THRASH_RATIO_THRESHOLD} (GH#5650)
  CPU idle:         Tree CPU < ${WORKER_IDLE_CPU_THRESHOLD}% for $(_format_duration "$WORKER_IDLE_TIMEOUT")
  Progress stall:   No session messages for $(_format_duration "$WORKER_PROGRESS_TIMEOUT"), then inspect transcript tail evidence
  Runtime ceiling:  Hard kill after $(_format_duration "$WORKER_MAX_RUNTIME")

On kill:
  - Posts comment on associated GitHub issue
  - Removes status:in-progress label
  - Adds status:blocked for zero-commit thrash kills
  - Adds status:available for all other kill reasons (including backoff)
  - Logs to ${LOG_FILE}

Environment variables:
  WORKER_IDLE_TIMEOUT              Idle detection window (default: 300s)
  WORKER_IDLE_CPU_THRESHOLD        CPU% idle threshold (default: 5)
  WORKER_PROGRESS_TIMEOUT          Stall detection window (default: 600s)
  WORKER_THRASH_ELAPSED_THRESHOLD  Minimum runtime for thrash guardrail (default: 3600s)
  WORKER_THRASH_MESSAGE_THRESHOLD  Minimum messages for thrash guardrail (default: 120)
  WORKER_THRASH_RATIO_THRESHOLD    Struggle ratio threshold for time-weighted check (default: 10)
  WORKER_THRASH_RATIO_ELAPSED      Minimum elapsed for ratio-only thrash (default: 25200s = 7h)
  WORKER_MAX_RUNTIME               Hard runtime ceiling (default: 10800s = 3h)
  WORKER_DRY_RUN                   Log but don't kill (default: false)
  WORKER_WATCHDOG_NOTIFY           macOS notifications (default: true)
  WORKER_PROCESS_PATTERN           CLI name to match (default: opencode)
  HEADLESS_RUNTIME_DB              Path to headless-runtime state.db (auto-detected)
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
