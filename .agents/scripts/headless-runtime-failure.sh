#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Failure — Dispatch Claim & Fast-Fail (GH#19699)
# =============================================================================
# Failure reporting functions extracted from headless-runtime-lib.sh to reduce
# file size. Handles dispatch claim release and fast-fail counter management.
#
# Covers:
#   1. Dispatch claim release — post CLAIM_RELEASED comments to unblock re-dispatch
#   2. Fast-fail state      — acquire locks, read/write counter state, report
#                              failures with exponential backoff and tier escalation
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-failure.sh"
#
# Dependencies:
#   - shared-constants.sh (print_warning, print_info)
#   - worker-lifecycle-common.sh (escalate_issue_tier)
#   - gh CLI, jq
#   - bash 3.2+
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_FAILURE_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_FAILURE_LOADED=1

# Fallback exit reason — backward-compatible value used when classify_worker_exit
# cannot determine the actual cause (missing sqlite3, corrupt DB, unexpected format).
# Recognised by dispatch-dedup-helper.sh: any CLAIM_RELEASED is treated as
# authoritative regardless of reason value.
readonly _HRFF_FALLBACK_EXIT="process_exit"

#######################################
# Release a dispatch claim by posting a CLAIM_RELEASED comment.
# The dedup guard recognises this and allows immediate re-dispatch
# instead of waiting for the 30-min TTL to expire.
#
# Args:
#   $1 = session_key (contains issue number and repo slug)
#   $2 = reason (logged in the comment for debugging)
#   $3 = exit_code (optional — included in comment when provided by exit trap)
#   $4 = session_count (optional — session_count from worker DB for exit trap)
#######################################
_release_dispatch_claim() {
	local session_key="$1"
	local reason="${2:-worker_failed}"
	local exit_code_arg="${3:-}"
	local session_count_arg="${4:-}"

	# Extract issue number and repo slug from session key
	# Format: pulse-{login}-{repo}-{issue} or similar
	local issue_number=""
	local repo_slug=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	# Try to get repo slug from the dispatch ledger or env
	repo_slug="${DISPATCH_REPO_SLUG:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		print_warning "Cannot release claim: missing issue=$issue_number repo=$repo_slug"
		return 0
	fi

	local comment_body
	comment_body="CLAIM_RELEASED reason=${reason} runner=$(whoami) ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	if [[ -n "$exit_code_arg" ]]; then
		comment_body="${comment_body} exit=${exit_code_arg}"
	fi
	if [[ -n "$session_count_arg" ]]; then
		comment_body="${comment_body} session_count=${session_count_arg}"
	fi

	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST \
		--field body="$comment_body" \
		>/dev/null 2>&1 || {
		print_warning "Failed to post CLAIM_RELEASED on #${issue_number} (non-fatal)"
	}
	print_info "Released claim on #${issue_number} (reason: ${reason})"

	# t2420: clear active-lifecycle status labels + worker assignment so the
	# pulse's combined-signal dedup guard (t1996) doesn't treat the issue
	# as active after release. Without this, orphan labels pin the issue
	# as "active" for the full 30-min TTL even though no worker holds the
	# claim, blocking re-dispatch. Preserves terminal states (done, blocked)
	# set by authoritative paths. Defensive skip if origin:interactive.
	# Non-fatal: failure does not block the release comment path.
	if declare -F clear_active_status_on_release >/dev/null 2>&1; then
		clear_active_status_on_release "$issue_number" "$repo_slug" "$(whoami)" \
			|| print_warning "Failed to clear active status on #${issue_number} (non-fatal)"
	fi
	return 0
}

#######################################
# Classify worker termination reason for CLAIM_RELEASED audit lines.
# Called from _exit_trap_handler before posting the claim release.
#
# Args:
#   $1 = wait_status  (bash exit status; >128 means signal N = wait_status - 128)
#   $2 = start_epoch_ms (milliseconds epoch when worker was prepared; 0 = unknown)
#
# Globals (optional, set by _invoke_opencode / _cmd_run_prepare):
#   _WORKER_ISOLATED_DB_PATH  — path to isolated worker opencode.db (if active)
#
# Returns classification string via stdout:
#   "clean"                   — exit status 0 (unexpected in EXIT trap context)
#   "signal_killed:<signum>"  — received signal N (wait_status > 128)
#   "crash_during_startup"    — non-zero exit, no OpenCode session found in DB
#   "crash_during_execution"  — non-zero exit, session(s) present in worker DB
#   "process_exit"            — fallback when classifier cannot determine reason
#
# Exit: always 0
#######################################
classify_worker_exit() {
	local wait_status="$1"
	local start_epoch_ms="${2:-0}"

	# Signal detection: bash encodes signal N as exit status 128+N
	if [[ "$wait_status" =~ ^[0-9]+$ ]] && (( wait_status > 128 )); then
		printf '%s' "signal_killed:$((wait_status - 128))"
		return 0
	fi

	# Clean exit (unusual in EXIT trap context — trap is normally cleared on success)
	if [[ "$wait_status" == "0" ]]; then
		printf '%s' "clean"
		return 0
	fi

	# Session creation check: count sessions created since worker started.
	# Primary: isolated worker DB (still present when EXIT fires during _invoke_opencode).
	# Fallback: shared DB (~/.local/share/opencode/opencode.db) after merge completes.
	local session_count=0
	local shared_db_path="${HOME}/.local/share/opencode/opencode.db"
	local isolated_db="${_WORKER_ISOLATED_DB_PATH:-}"
	local active_db=""

	if [[ -n "$isolated_db" && -f "$isolated_db" ]]; then
		active_db="$isolated_db"
	elif [[ -f "$shared_db_path" ]]; then
		active_db="$shared_db_path"
	fi

	if ! command -v sqlite3 >/dev/null 2>&1 || [[ -z "$active_db" ]]; then
		# sqlite3 unavailable or no DB found — cannot classify by session
		print_warning "[exit-classifier] sqlite3 unavailable or DB missing (isolated=${isolated_db:-none} shared=${shared_db_path}) — using ${_HRFF_FALLBACK_EXIT} fallback"
		printf '%s' "$_HRFF_FALLBACK_EXIT"
		return 0
	fi

	local query=""
	if [[ "$start_epoch_ms" =~ ^[0-9]+$ ]] && (( start_epoch_ms > 0 )); then
		# Count sessions created at or after worker start time (ms epoch)
		query="SELECT count(*) FROM session WHERE time_created >= ${start_epoch_ms}"
	else
		# No start time: count all sessions (crude fallback — may over-count)
		query="SELECT count(*) FROM session"
	fi

	local raw_count=""
	raw_count=$(sqlite3 "$active_db" "$query" 2>/dev/null) || raw_count=""

	if [[ ! "$raw_count" =~ ^[0-9]+$ ]]; then
		# sqlite3 returned non-numeric output (e.g. error or corrupt DB)
		print_warning "[exit-classifier] sqlite3 query failed for ${active_db} — using ${_HRFF_FALLBACK_EXIT} fallback"
		printf '%s' "$_HRFF_FALLBACK_EXIT"
		return 0
	fi
	session_count="$raw_count"

	if (( session_count == 0 )); then
		printf '%s' "crash_during_startup"
	else
		printf '%s' "crash_during_execution"
	fi
	return 0
}

#######################################
# EXIT trap handler — classify worker termination and post CLAIM_RELEASED.
# Replaces the inline 'process_exit' reason in the EXIT trap with a
# classified reason from classify_worker_exit. Falls back to process_exit
# if classification fails, preserving backward compatibility.
#
# Args:
#   $1 = session_key (baked in at trap-set time via SC2064-disabled trap)
#
# Globals consumed:
#   _WORKER_START_EPOCH_MS   — ms epoch set by _cmd_run_prepare
#   _WORKER_ISOLATED_DB_PATH — isolated DB path set by _invoke_opencode
#######################################
_exit_trap_handler() {
	local session_key="$1"
	# Capture exit status immediately — any subsequent command will overwrite $?
	local exit_status=$?

	local reason="$_HRFF_FALLBACK_EXIT"
	local session_count=0

	if declare -F classify_worker_exit >/dev/null 2>&1; then
		local _start_ms="${_WORKER_START_EPOCH_MS:-0}"
		local _classified=""
		_classified=$(classify_worker_exit "$exit_status" "$_start_ms" 2>/dev/null) || true
		if [[ -n "$_classified" ]]; then
			reason="$_classified"
		else
			print_warning "[exit-trap] classify_worker_exit returned empty — using process_exit fallback"
		fi

		# Re-read session count for the enriched comment (best-effort)
		local _db="${_WORKER_ISOLATED_DB_PATH:-}"
		local _shared="${HOME}/.local/share/opencode/opencode.db"
		[[ -z "$_db" || ! -f "$_db" ]] && _db="$_shared"
		if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db" && "$_start_ms" =~ ^[0-9]+$ ]] && (( _start_ms > 0 )); then
			local _cnt=""
			_cnt=$(sqlite3 "$_db" \
				"SELECT count(*) FROM session WHERE time_created >= ${_start_ms}" \
				2>/dev/null) || _cnt=""
			[[ "$_cnt" =~ ^[0-9]+$ ]] && session_count="$_cnt"
		fi
	else
		print_warning "[exit-trap] classify_worker_exit not available — using process_exit fallback"
	fi

	print_info "[exit-trap] session=$session_key exit=$exit_status reason=$reason session_count=$session_count"
	_release_dispatch_claim "$session_key" "$reason" "$exit_status" "$session_count"
	_release_session_lock "$session_key"
	_update_dispatch_ledger "$session_key" "fail"
	return 0
}

#######################################
# Acquire the fast-fail mkdir lock with retries.
#
# Args:
#   $1 - lock_dir path
#   $2 - issue_number (for warning message)
#   $3 - repo_slug (for warning message)
# Returns: 0=acquired, 1=timed out
#######################################
_fast_fail_acquire_lock() {
	local lock_dir="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			print_warning "[fast-fail] lock timeout for #${issue_number} (${repo_slug})"
			return 1
		fi
		sleep 0.1
	done
	return 0
}

#######################################
# Read existing count and backoff from fast-fail state file.
# Stale entries (older than expiry_secs) are treated as absent.
#
# Args:
#   $1 - state_file path
#   $2 - key (repo_slug/issue_number)
#   $3 - now (epoch seconds)
#   $4 - expiry_secs
# Sets globals: _FAST_FAIL_EXISTING_COUNT, _FAST_FAIL_EXISTING_BACKOFF
#######################################
_fast_fail_read_state() {
	local state_file="$1"
	local key="$2"
	local now="$3"
	local expiry_secs="$4"
	_FAST_FAIL_EXISTING_COUNT=0
	_FAST_FAIL_EXISTING_BACKOFF=0
	if [[ ! -f "$state_file" ]]; then
		return 0
	fi
	local entry=""
	entry=$(jq -r --arg k "$key" '.[$k] // empty' "$state_file" 2>/dev/null) || entry=""
	if [[ -z "$entry" ]]; then
		return 0
	fi
	local entry_ts=""
	entry_ts=$(printf '%s' "$entry" | jq -r '.ts // 0' 2>/dev/null) || entry_ts=0
	# Expire stale entries
	if [[ $((now - entry_ts)) -ge "$expiry_secs" ]]; then
		return 0
	fi
	_FAST_FAIL_EXISTING_COUNT=$(printf '%s' "$entry" | jq -r '.count // 0' 2>/dev/null) || _FAST_FAIL_EXISTING_COUNT=0
	_FAST_FAIL_EXISTING_BACKOFF=$(printf '%s' "$entry" | jq -r '.backoff_secs // 0' 2>/dev/null) || _FAST_FAIL_EXISTING_BACKOFF=0
	return 0
}

#######################################
# Write updated fast-fail state atomically via tmp+mv.
#
# Args:
#   $1  - state_file path
#   $2  - state_dir path
#   $3  - key (repo_slug/issue_number)
#   $4  - new_count
#   $5  - now (epoch seconds)
#   $6  - reason
#   $7  - retry_after (epoch seconds)
#   $8  - new_backoff (seconds)
#   $9  - crash_type (may be empty)
#######################################
_fast_fail_write_state() {
	local state_file="$1"
	local state_dir="$2"
	local key="$3"
	local new_count="$4"
	local now="$5"
	local reason="$6"
	local retry_after="$7"
	local new_backoff="$8"
	local crash_type="$9"
	local updated_state=""
	if [[ -f "$state_file" ]]; then
		updated_state=$(jq --arg k "$key" \
			--argjson count "$new_count" \
			--argjson ts "$now" \
			--arg reason "$reason" \
			--argjson retry_after "$retry_after" \
			--argjson backoff_secs "$new_backoff" \
			--arg crash_type "${crash_type:-}" \
			'.[$k] = {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type}' \
			"$state_file") || {
			echo "Error: Failed to update $state_file" >&2
			updated_state=""
		}
	else
		updated_state=$(printf '{}' | jq --arg k "$key" \
			--argjson count "$new_count" \
			--argjson ts "$now" \
			--arg reason "$reason" \
			--argjson retry_after "$retry_after" \
			--argjson backoff_secs "$new_backoff" \
			--arg crash_type "${crash_type:-}" \
			'.[$k] = {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type}' \
			2>/dev/null) || updated_state=""
	fi
	if [[ -z "$updated_state" ]]; then
		return 0
	fi
	local tmp_file=""
	tmp_file=$(mktemp "${state_dir}/.fast-fail-counter.XXXXXX" 2>/dev/null) || tmp_file=""
	if [[ -z "$tmp_file" ]]; then
		return 0
	fi
	printf '%s\n' "$updated_state" >"$tmp_file" 2>/dev/null &&
		mv "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
	return 0
}

#######################################
# Report worker failure to the shared fast-fail counter and trigger
# tier escalation when threshold is reached.
#
# Previously, only the pulse (recover_failed_launch_state) and launchd
# watchdog wrote to the counter -- both asynchronous, discovering failures
# 10-30 minutes after the worker died. This function lets the worker
# self-report immediately on exit, so escalation fires within seconds
# instead of 60-90+ minutes. The pulse path remains as a backup for
# workers that crash hard before reaching this function.
#
# Uses the same state file and locking as pulse-wrapper.sh and
# worker-watchdog.sh (fast-fail-counter.json + mkdir lock).
#
# Args:
#   $1 - session_key (e.g., "issue-marcusquinn-aidevops-17642")
#   $2 - failure reason (premature_exit, rate_limit, etc.)
#   $3 - crash_type (optional, e.g., "overwhelmed")
#######################################
_report_failure_to_fast_fail() {
	local session_key="$1"
	local reason="${2:-worker_failed}"
	local crash_type="${3:-}"

	# Extract issue number from session key (last numeric segment)
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		return 0
	fi

	# Only report for worker role (not pulse/triage sessions)
	if [[ "$session_key" != issue-* ]]; then
		return 0
	fi

	local state_file="${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json"
	local state_dir
	state_dir=$(dirname "$state_file")
	mkdir -p "$state_dir" 2>/dev/null || true

	# Acquire lock (shared with pulse-wrapper.sh and worker-watchdog.sh)
	local lock_dir="${state_file}.lockdir"
	_fast_fail_acquire_lock "$lock_dir" "$issue_number" "$repo_slug" || return 0

	local key now
	key="${repo_slug}/${issue_number}"
	now=$(date +%s)

	local initial_backoff="${FAST_FAIL_INITIAL_BACKOFF_SECS:-600}"
	local max_backoff="${FAST_FAIL_MAX_BACKOFF_SECS:-604800}"
	local expiry_secs="${FAST_FAIL_EXPIRY_SECS:-604800}"

	# Read current state -- sets _FAST_FAIL_EXISTING_COUNT and _FAST_FAIL_EXISTING_BACKOFF
	_fast_fail_read_state "$state_file" "$key" "$now" "$expiry_secs"
	local existing_count="$_FAST_FAIL_EXISTING_COUNT"
	local existing_backoff="$_FAST_FAIL_EXISTING_BACKOFF"

	# Non-rate-limit failures: increment + exponential backoff
	local new_count=$((existing_count + 1))
	local new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : initial_backoff))
	[[ "$new_backoff" -gt "$max_backoff" ]] && new_backoff="$max_backoff"
	local retry_after=$((now + new_backoff))

	# Write updated state atomically (tmp + mv)
	_fast_fail_write_state "$state_file" "$state_dir" "$key" "$new_count" "$now" \
		"$reason" "$retry_after" "$new_backoff" "$crash_type"

	# Release lock
	rmdir "$lock_dir" 2>/dev/null || true

	print_info "[fast-fail] #${issue_number} (${repo_slug}) count=${new_count} backoff=${new_backoff}s reason=${reason} crash_type=${crash_type:-unclassified}"

	# Trigger tier escalation (escalate_issue_tier from worker-lifecycle-common.sh)
	# Only fires when new_count == threshold -- not on every failure.
	# Pass crash_type so escalation uses crash-type-aware thresholds:
	# "overwhelmed" escalates immediately (threshold=1).
	if [[ "$new_count" -gt "$existing_count" ]]; then
		escalate_issue_tier "$issue_number" "$repo_slug" "$new_count" "$reason" "$crash_type" || true
	fi

	return 0
}
