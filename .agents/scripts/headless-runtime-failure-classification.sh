#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Worker activity and exit classification, sourced by headless-runtime-failure.sh.

[[ -n "${_HEADLESS_RUNTIME_FAILURE_CLASSIFICATION_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_FAILURE_CLASSIFICATION_LOADED=1

#######################################
# Count attempt-local OpenCode model activity. Fresh runs are scoped to sessions
# created during the attempt, while continuations use the exact persisted
# session whose session.time_created remains old. A boot-only session row is not
# activity; require a completed assistant message or assistant-owned part.
# Args: $1 = DB path, $2 = attempt start epoch ms, $3 = persisted session ID.
# Outputs a non-negative integer, or returns 1 when evidence is unavailable.
#######################################
_hrff_attempt_activity_count() {
	local db_path="$1"
	local start_epoch_ms="$2"
	local persisted_session_id="${3:-}"
	local persisted_session_sql=""
	local session_scope=""
	local query=""
	local count=""

	command -v sqlite3 >/dev/null 2>&1 || return 1
	[[ -f "$db_path" && "$start_epoch_ms" =~ ^[0-9]+$ && "$start_epoch_ms" -gt 0 ]] || return 1
	if [[ -n "$persisted_session_id" ]]; then
		persisted_session_sql="${persisted_session_id//\'/\'\'}"
		session_scope="= '${persisted_session_sql}'"
	else
		session_scope="IN (SELECT id FROM session WHERE time_created >= ${start_epoch_ms})"
	fi
	query="SELECT (SELECT count(*) FROM message m WHERE m.session_id ${session_scope} AND m.time_created >= ${start_epoch_ms} AND json_valid(m.data) AND json_extract(m.data, '$.role') = 'assistant' AND json_extract(m.data, '$.time.completed') IS NOT NULL) + (SELECT count(*) FROM part p JOIN message m ON m.id = p.message_id WHERE m.session_id ${session_scope} AND p.time_created >= ${start_epoch_ms} AND json_valid(m.data) AND json_extract(m.data, '$.role') = 'assistant')"
	count=$(sqlite3 "$db_path" "$query" 2>/dev/null) || return 1
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$count"
	return 0
}

#######################################
# GH#37527: snapshot attempt activity from an isolated DB before finalization
# merges or discards it. Ephemeral roles discard the DB and a failed merge keeps
# the rows out of the shared DB, so a later shared-DB read would report a false
# zero. Snapshots accumulate across invocations bound to one attempt start.
# Args: $1 = isolated DB path. Unreadable evidence records no snapshot.
#######################################
_hrff_snapshot_attempt_activity() {
	local db_path="$1"
	local start_epoch_ms="${_WORKER_START_EPOCH_MS:-0}"
	local count=""
	[[ "$start_epoch_ms" =~ ^[0-9]+$ && "$start_epoch_ms" -gt 0 ]] || return 0
	count=$(_hrff_attempt_activity_count "$db_path" "$start_epoch_ms" "${_WORKER_PERSISTED_SESSION_ID:-}") || return 0
	if [[ "${_WORKER_ATTEMPT_ACTIVITY_START_MS:-}" != "$start_epoch_ms" ||
		! "${_WORKER_ATTEMPT_ACTIVITY_COUNT:-}" =~ ^[0-9]+$ ]]; then
		_WORKER_ATTEMPT_ACTIVITY_COUNT=0
	fi
	_WORKER_ATTEMPT_ACTIVITY_COUNT=$((_WORKER_ATTEMPT_ACTIVITY_COUNT + count))
	_WORKER_ATTEMPT_ACTIVITY_START_MS="$start_epoch_ms"
	return 0
}

#######################################
# Resolve attempt activity: the live isolated DB plus finalized snapshots. The
# shared DB is read only when no isolated DB or snapshot exists for this start.
# Args: $1 = attempt start epoch ms, $2 = persisted session ID.
# Outputs a non-negative integer, or returns 1 when evidence is unavailable.
#######################################
_hrff_resolved_attempt_activity_count() {
	local start_epoch_ms="$1"
	local persisted_session_id="${2:-}"
	local isolated_db="${_WORKER_ISOLATED_DB_PATH:-}"
	local shared_db="${HOME}/.local/share/opencode/opencode.db"
	local snapshot=0
	local has_snapshot=0
	local count=""
	[[ "$start_epoch_ms" =~ ^[0-9]+$ && "$start_epoch_ms" -gt 0 ]] || return 1
	if [[ "${_WORKER_ATTEMPT_ACTIVITY_START_MS:-}" == "$start_epoch_ms" &&
		"${_WORKER_ATTEMPT_ACTIVITY_COUNT:-}" =~ ^[0-9]+$ ]]; then
		snapshot="$_WORKER_ATTEMPT_ACTIVITY_COUNT"
		has_snapshot=1
	fi
	if [[ -n "$isolated_db" && -f "$isolated_db" ]]; then
		count=$(_hrff_attempt_activity_count "$isolated_db" "$start_epoch_ms" "$persisted_session_id") || count=""
	elif [[ "$has_snapshot" -eq 0 ]]; then
		count=$(_hrff_attempt_activity_count "$shared_db" "$start_epoch_ms" "$persisted_session_id") || count=""
	else
		count=0
	fi
	if [[ ! "$count" =~ ^[0-9]+$ ]]; then
		[[ "$has_snapshot" -eq 1 ]] || return 1
		count=0
	fi
	printf '%s\n' "$((count + snapshot))"
	return 0
}

#######################################
# Classify worker termination reason for CLAIM_RELEASED audit lines.
# Called from _exit_trap_handler before posting the claim release.
#
# Args:
#   $1 = wait_status  (bash exit status; >128 means signal N = wait_status - 128)
#   $2 = start_epoch_ms (milliseconds epoch when worker was prepared; 0 = unknown)
#   $3 = persisted_session_id (optional continued-session identity)
#   $4 = exit_code_file (optional sentinel base path)
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
	local persisted_session_id="${3:-${_WORKER_PERSISTED_SESSION_ID:-}}"
	local exit_code_file="${4:-}"
	local kill_reason=""

	# Kill-site sentinels are more authoritative than the recorded wait status.
	# A watchdog can hard-kill a worker while the wrapper still persists status 0;
	# preserve natural/unknown fallbacks so ordinary clean and signal exits retain
	# the existing classifier behaviour.
	if [[ -n "$exit_code_file" ]] && declare -F classify_worker_kill_reason >/dev/null 2>&1; then
		kill_reason=$(classify_worker_kill_reason "$exit_code_file" "$wait_status") || kill_reason=""
		case "$kill_reason" in
		"" | natural | unknown) ;;
		*)
			printf '%s' "$kill_reason"
			return 0
			;;
		esac
	fi

	# Signal detection: bash encodes signal N as exit status 128+N
	if [[ "$wait_status" =~ ^[0-9]+$ ]] && (( wait_status > 128 )); then
		printf '%s' "signal_killed:$((wait_status - 128))"
		return 0
	fi

	# Clean exit (unusual in EXIT trap context — trap is normally cleared on success).
	# t3050: a clean exit with zero opencode sessions means the wrapper returned 0
	# cleanly but the worker never produced model output. This is a startup-phase
	# failure (sandbox crash, OpenCode init failure, prompt parse error before
	# tool use), not a successful run. The worker_noop_zero_output reason is
	# already recognised by _maybe_reclassify_worker_failed_as_no_work in
	# worker-lifecycle-common.sh and by escalate_issue_tier — emitting it
	# directly here ensures the reason is authoritative from the trap rather
	# than inferred later from orphan-worktree state.
	if [[ "$wait_status" == "0" ]]; then
		# GH#37527: finalization may already have discarded or failed to merge
		# the isolated DB; the resolver prefers its pre-finalization snapshot.
		local _cnt_zo=""
		_cnt_zo=$(_hrff_resolved_attempt_activity_count "$start_epoch_ms" "$persisted_session_id") || _cnt_zo=""
		if [[ "$_cnt_zo" =~ ^[0-9]+$ && "$_cnt_zo" -eq 0 ]]; then
			printf '%s' "worker_noop_zero_output"
			return 0
		fi
		printf '%s' "clean"
		return 0
	fi

	_hrff_classify_nonzero_worker_exit "$start_epoch_ms" "$persisted_session_id"
	return 0
}

# Classify an ordinary non-zero exit after sentinel, signal and clean handling.
_hrff_classify_nonzero_worker_exit() {
	local start_epoch_ms="$1"
	local persisted_session_id="${2:-}"

	# Finalization can discard the only DB containing execution evidence.
	# A zero/missing snapshot is inconclusive: a fresh boot-only session still
	# counts as execution for non-zero exits, so retain the session query below.
	if [[ "$start_epoch_ms" =~ ^[0-9]+$ && "$start_epoch_ms" -gt 0 &&
		"${_WORKER_ATTEMPT_ACTIVITY_START_MS:-}" == "$start_epoch_ms" &&
		"${_WORKER_ATTEMPT_ACTIVITY_COUNT:-}" =~ ^[0-9]+$ &&
		"${_WORKER_ATTEMPT_ACTIVITY_COUNT:-0}" -gt 0 ]]; then
		printf '%s' "crash_during_execution"
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

	local raw_count=""
	if [[ "$start_epoch_ms" =~ ^[0-9]+$ ]] && ((start_epoch_ms > 0)); then
		if [[ -n "$persisted_session_id" ]]; then
			raw_count=$(_hrff_attempt_activity_count "$active_db" "$start_epoch_ms" "$persisted_session_id") || raw_count=""
		else
			raw_count=$(sqlite3 "$active_db" "${_HRFF_SESSION_COUNT_QUERY_PREFIX}${start_epoch_ms}" 2>/dev/null) || raw_count=""
		fi
	else
		# No start time: count all sessions (crude fallback — may over-count)
		raw_count=$(sqlite3 "$active_db" "SELECT count(*) FROM session" 2>/dev/null) || raw_count=""
	fi

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
# Classify worker kill_reason for the [lifecycle] worker_exited log line.
#
# t3063: surfaces the kill PATH on the same line as wait_status so Phase 2
# log aggregation finds the reason class without a PID-join across scripts.
# Complementary to classify_worker_exit (which classifies CRASH vs CLEAN);
# this answers "if killed, which kill path fired the SIGTERM/SIGKILL?".
#
# Sentinel precedence (highest to lowest):
#   1. ${exit_code_file}.kill_reason — explicit class written by kill site
#      (PR #21784/t3056 sites: hard_kill_stall, no_output_stall,
#      phase1_zero_output, wall_clock_stale, cold_start_timeout,
#      progress_timeout, idle_timeout, stop_flag, stage_timeout_*,
#      process_guard_*, wait_loop_timeout_*).
#   2. ${exit_code_file}.watchdog_stall_killed → hard_kill_stall
#      (worker exceeded HARD_KILL_SECONDS, t2956 / Issue #21231).
#   3. ${exit_code_file}.watchdog_killed → no_output_stall
#      (legacy passive watchdog kill — output file silent).
#   4. ${exit_code_file}.rate_limit_fast → rate_limit_fast
#      (30s fast-exit monitor caught 429/overload, GH#21578 / t3021).
#   5. wait_status > 128 with no sentinel → unknown
#      (signal-killed but kill path unidentified — acceptance target: 0%).
#   6. otherwise → natural
#      (clean exit or voluntary failure exit).
#
# The .kill_reason sentinel is the forward-compatible extension point: any
# kill site that adds a new class only needs to write its class string to
# ${exit_code_file}.kill_reason; this classifier picks it up without code
# changes here.
#
# Args:
#   $1 = exit_code_file path (sentinel files are checked at ${path}.<class>)
#   $2 = wait_status integer ($? from `wait`)
#
# Returns 0 always; outputs kill_reason class string on stdout.
#######################################
classify_worker_kill_reason() {
	local exit_code_file="${1:-}"
	local wait_status="${2:-0}"

	# Highest-precedence path: explicit class written by a kill site.
	if [[ -n "$exit_code_file" && -f "${exit_code_file}.kill_reason" ]]; then
		local _explicit
		_explicit=$(<"${exit_code_file}.kill_reason")
		# Strip CR/LF; bail to inference path if file is empty or whitespace-only.
		_explicit="${_explicit//$'\r'/}"
		_explicit="${_explicit//$'\n'/}"
		# Trim leading/trailing spaces and tabs (bash 3.2 compatible).
		_explicit="${_explicit#"${_explicit%%[![:space:]]*}"}"
		_explicit="${_explicit%"${_explicit##*[![:space:]]}"}"
		if [[ -n "$_explicit" ]]; then
			printf '%s' "$_explicit"
			return 0
		fi
	fi

	# Inferred classification from existing watchdog sentinels.
	# Precedence: stall_killed (hard kill) → watchdog_killed (passive stall)
	# → rate_limit_fast. The watchdog writes both .watchdog_killed and
	# .watchdog_stall_killed on a hard kill, so stall_killed must be checked first.
	if [[ -n "$exit_code_file" ]]; then
		if [[ -f "${exit_code_file}.watchdog_stall_killed" ]]; then
			printf '%s' "hard_kill_stall"
			return 0
		fi
		if [[ -f "${exit_code_file}.watchdog_killed" ]]; then
			printf '%s' "no_output_stall"
			return 0
		fi
		if [[ -f "${exit_code_file}.rate_limit_fast" ]]; then
			printf '%s' "rate_limit_fast"
			return 0
		fi
	fi

	# No sentinel — signal-killed (wait_status > 128) is "unknown"
	# (acceptance target: 0% of these); voluntary exits are "natural".
	if [[ "$wait_status" =~ ^[0-9]+$ ]] && (( wait_status > 128 )); then
		printf '%s' "unknown"
		return 0
	fi

	printf '%s' "natural"
	return 0
}

