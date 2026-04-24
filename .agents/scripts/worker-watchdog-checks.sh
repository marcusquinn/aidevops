#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Watchdog — Detection Signal Checks
# =============================================================================
# Five detection signals for hung/idle/thrashing headless workers:
#   1. Provider backoff — worker's provider is backed off in headless-runtime DB
#   2. CPU idle — tree CPU below threshold for WORKER_IDLE_TIMEOUT seconds
#   3. Progress stall — no session messages for WORKER_PROGRESS_TIMEOUT seconds
#   4. Zero-commit thrash — high message volume with no commits over long runtime
#   5. Transcript intervention gate — verifies transcript evidence before kills
#
# Usage: source "${SCRIPT_DIR}/worker-watchdog-checks.sh"
#
# Dependencies:
#   - shared-constants.sh (sourced by orchestrator)
#   - worker-lifecycle-common.sh (_get_session_tail_evidence, _compute_struggle_ratio,
#       _resolve_session_id_from_cmd, _opencode_db_path, _sanitize_log_field,
#       _extract_session_title)
#   - worker-watchdog-detect.sh (extract_provider_from_cmd)
#   - Config globals: WORKER_IDLE_TIMEOUT, WORKER_IDLE_CPU_THRESHOLD,
#       WORKER_PROGRESS_TIMEOUT, WORKER_THRASH_*, HEADLESS_RUNTIME_DB,
#       IDLE_STATE_DIR, LOG_FILE
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKER_WATCHDOG_CHECKS_LOADED:-}" ]] && return 0
_WORKER_WATCHDOG_CHECKS_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Provider Backoff Detection (GH#5650)
# =============================================================================

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

# =============================================================================
# CPU Idle Detection
# =============================================================================

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

# =============================================================================
# Progress Stall Detection
# =============================================================================

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

# =============================================================================
# Transcript Intervention Gate
# =============================================================================

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

# =============================================================================
# Zero-Commit Thrash Detection
# =============================================================================

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
