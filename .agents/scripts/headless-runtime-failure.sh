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

_HRFF_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
if [[ -r "${_HRFF_SCRIPT_DIR}/lib/version.sh" ]]; then
	# shellcheck source=lib/version.sh
	source "${_HRFF_SCRIPT_DIR}/lib/version.sh"
fi
if [[ -r "${_HRFF_SCRIPT_DIR}/gh-signature-helper-detect.sh" ]]; then
	# shellcheck source=gh-signature-helper-detect.sh
	source "${_HRFF_SCRIPT_DIR}/gh-signature-helper-detect.sh"
fi
unset _HRFF_SCRIPT_DIR
: "${AIDEVOPS_UNKNOWN_VERSION:=unknown}"

# Fallback exit reason — backward-compatible value used when classify_worker_exit
# cannot determine the actual cause (missing sqlite3, corrupt DB, unexpected format).
# Recognised by dispatch-dedup-helper.sh: any CLAIM_RELEASED is treated as
# authoritative regardless of reason value.
readonly _HRFF_FALLBACK_EXIT="process_exit"

#######################################
# Unlock the issue once a worker releases its dispatch claim.
#
# Worker dispatch locks the issue before launch. Release paths already clear
# active labels/assignees; they must also clear the conversation lock so the
# public issue state matches the released claim and future workers/maintainers
# do not see `status:available` on a locked issue.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_unlock_issue_after_dispatch_release() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0
	gh issue unlock "$issue_number" --repo "$repo_slug" >/dev/null 2>&1 || {
		print_warning "Failed to unlock released issue #${issue_number} (non-fatal)"
	}
	return 0
}

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

	local aidevops_version="$AIDEVOPS_UNKNOWN_VERSION" opencode_version="$AIDEVOPS_UNKNOWN_VERSION"
	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "$AIDEVOPS_UNKNOWN_VERSION")
	fi
	if declare -F _detect_opencode_version >/dev/null 2>&1; then
		opencode_version=$(_detect_opencode_version 2>/dev/null || printf '%s' "")
		opencode_version="${opencode_version:-$AIDEVOPS_UNKNOWN_VERSION}"
	fi

	local runner_name=""
	runner_name=$(whoami)
	local release_ts=""
	release_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local machine_readable_part="CLAIM_RELEASED reason=${reason} runner=${runner_name} ts=${release_ts} aidevops_version=${aidevops_version} opencode_version=${opencode_version}"
	if [[ -n "$exit_code_arg" ]]; then
		machine_readable_part+=" exit=${exit_code_arg}"
	fi
	if [[ -n "$session_count_arg" ]]; then
		machine_readable_part+=" session_count=${session_count_arg}"
	fi

	local comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
${machine_readable_part}
<!-- ops:end -->"

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
		clear_active_status_on_release "$issue_number" "$repo_slug" "$runner_name" \
			|| print_warning "Failed to clear active status on #${issue_number} (non-fatal)"
	fi
	_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
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
		local _shared_db_zo="${HOME}/.local/share/opencode/opencode.db"
		local _db_zo="${_WORKER_ISOLATED_DB_PATH:-}"
		[[ -z "$_db_zo" || ! -f "$_db_zo" ]] && _db_zo="$_shared_db_zo"
		if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db_zo" \
			&& "$start_epoch_ms" =~ ^[0-9]+$ && "$start_epoch_ms" -gt 0 ]]; then
			local _cnt_zo=""
			_cnt_zo=$(sqlite3 "$_db_zo" \
				"SELECT count(*) FROM session WHERE time_created >= ${start_epoch_ms}" \
				2>/dev/null) || _cnt_zo=""
			if [[ "$_cnt_zo" =~ ^[0-9]+$ && "$_cnt_zo" -eq 0 ]]; then
				printf '%s' "worker_noop_zero_output"
				return 0
			fi
		fi
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

#######################################
# Preserve and push any worker WIP before worker exits.
# Best-effort, fail-open — never blocks claim release or shutdown.
#
# t2923: Prevents workers dying mid-implementation from abandoning
# unreachable commits. Next dispatch can continue from the pushed branch
# instead of rewriting the same code from scratch.
#
# GH#22965: Dirty worktrees with no local-only commits must also be
# preserved. Create a normal WIP commit from tracked/untracked work and push it;
# if commit/push cannot complete, archive a binary patch locally and mark the
# failure as worker_dirty_work_preserved so zero-output retry holds do not
# misclassify the issue as a malformed brief.
#
# Globals consumed:
#   _WORKER_WORKTREE_PATH  — set by _cmd_run_prepare in headless-runtime-helper.sh
#   WORKER_NO_EXIT_PUSH    — escape hatch: set to "1" to disable push
#######################################
_push_wip_commits_on_exit() {
	# Escape hatch: WORKER_NO_EXIT_PUSH=1 disables the push (e.g. in tests)
	[[ "${WORKER_NO_EXIT_PUSH:-0}" == "1" ]] && return 0
	_WORKER_DIRTY_WORK_PRESERVED=0

	local work_dir="${_WORKER_WORKTREE_PATH:-}"
	if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
		return 0
	fi

	# Get the branch name — skip if detached HEAD or default branch
	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
	case "$branch_name" in
	HEAD | main | master | "")
		return 0
		;;
	esac

	local dirty_status=""
	dirty_status=$(git -C "$work_dir" status --porcelain 2>/dev/null || true)
	if [[ -n "$dirty_status" ]]; then
		print_info "[lifecycle] worker_exit_preserving_dirty_work branch=${branch_name}"
		git -C "$work_dir" add -A >/dev/null 2>&1 || true
		if ! git -C "$work_dir" diff --cached --quiet --exit-code >/dev/null 2>&1; then
			if git -C "$work_dir" commit -m "wip: preserve worker changes on abnormal exit" >/dev/null 2>&1; then
				_WORKER_DIRTY_WORK_PRESERVED=1
				print_info "[lifecycle] worker_exit_committed_dirty_work branch=${branch_name}"
			else
				_worker_archive_dirty_worktree_patch "$work_dir" "$branch_name"
			fi
		else
			_worker_archive_dirty_worktree_patch "$work_dir" "$branch_name"
		fi
	fi

	# Count commits ahead of origin/main (or origin/master) — fail-open
	local ahead_count=0
	ahead_count=$(git -C "$work_dir" rev-list --count "origin/main..HEAD" 2>/dev/null || true)
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0
	if [[ "$ahead_count" -eq 0 ]]; then
		ahead_count=$(git -C "$work_dir" rev-list --count "origin/master..HEAD" 2>/dev/null || true)
		[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0
	fi
	if [[ "$ahead_count" -eq 0 ]]; then
		return 0
	fi

	# Push best-effort — never block exit on push failure
	print_info "[lifecycle] worker_exit_pushing_wip branch=${branch_name} ahead=${ahead_count}"
	if git -C "$work_dir" push -u origin "${branch_name}" 2>/dev/null; then
		print_info "[lifecycle] worker_exit_pushed_wip branch=${branch_name} ahead=${ahead_count}"
	else
		print_warning "[lifecycle] worker_exit_push_failed branch=${branch_name} ahead=${ahead_count}"
		_worker_archive_dirty_worktree_patch "$work_dir" "$branch_name"
	fi
	return 0
}

#######################################
# Archive dirty worktree changes as a local binary patch.
# Best-effort fallback when exit-time commit/push cannot preserve the work.
#
# Args:
#   $1 = worktree path
#   $2 = branch name
# Globals updated:
#   _WORKER_DIRTY_WORK_PRESERVED — set to 1 when an archive is written
#######################################
_worker_archive_dirty_worktree_patch() {
	local work_dir="$1"
	local branch_name="$2"
	local archive_root="${AIDEVOPS_WORKER_DIRTY_ARCHIVE_DIR:-${HOME}/.aidevops/.agent-workspace/work/dirty-worktrees}"
	local safe_branch="${branch_name//[^A-Za-z0-9._-]/_}"
	local stamp=""
	stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "unknown-time")
	local archive_dir="${archive_root}/${safe_branch}-${stamp}"

	mkdir -p "$archive_dir" 2>/dev/null || return 0
	git -C "$work_dir" status --short --branch >"${archive_dir}/status.txt" 2>/dev/null || true
	if git -C "$work_dir" diff --binary --cached >"${archive_dir}/changes.patch" 2>/dev/null \
		&& [[ -s "${archive_dir}/changes.patch" ]]; then
		_WORKER_DIRTY_WORK_PRESERVED=1
		print_warning "[lifecycle] worker_dirty_work_preserved archive=${archive_dir}"
		return 0
	fi
	if git -C "$work_dir" diff --binary >"${archive_dir}/changes.patch" 2>/dev/null \
		&& [[ -s "${archive_dir}/changes.patch" ]]; then
		_WORKER_DIRTY_WORK_PRESERVED=1
		print_warning "[lifecycle] worker_dirty_work_preserved archive=${archive_dir}"
		return 0
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
#   _WORKER_WORKTREE_PATH    — worktree path set by _cmd_run_prepare (t2923)
#   _WORKER_EXIT_CODE_FILE   — exit_code_file path set by _invoke_opencode
#                              (t3050); .wait_status sentinel persisted
#                              alongside it preserves the worker subshell
#                              wait_status across the EXIT trap boundary.
#######################################
_exit_trap_handler() {
	local session_key="$1"
	# Capture exit status immediately — any subsequent command will overwrite $?
	local exit_status=$?

	# t3050: prefer the worker's actual wait_status (persisted by _invoke_opencode
	# at ${exit_code_file}.wait_status) over $?. By the time EXIT fires, the
	# wrapper functions have cleanly returned 0 even when the worker subshell
	# was SIGTERM'd. Without this override, classify_worker_exit reads $?=0
	# from the trap and emits reason=clean for SIGTERM/SIGKILL kills (canonical
	# failure: GH#21707 — 6+ workers all reported reason=clean session_count=0
	# despite wait_status=143).
	local _wait_file="${_WORKER_EXIT_CODE_FILE:-}.wait_status"
	if [[ -n "${_WORKER_EXIT_CODE_FILE:-}" && -f "$_wait_file" ]]; then
		local _w=""
		_w=$(<"$_wait_file") || _w=""
		# Trim CR/LF/whitespace (bash 3.2 compatible).
		_w="${_w//$'\r'/}"
		_w="${_w//$'\n'/}"
		_w="${_w#"${_w%%[![:space:]]*}"}"
		_w="${_w%"${_w##*[![:space:]]}"}"
		if [[ "$_w" =~ ^[0-9]+$ && "$_w" -gt 0 ]]; then
			exit_status="$_w"
		fi
		rm -f "$_wait_file" 2>/dev/null || true
	fi

	local reason="$_HRFF_FALLBACK_EXIT"
	local session_count=0
	if [[ -n "${_WORKER_PRELAUNCH_FAILURE_REASON:-}" ]]; then
		reason="$_WORKER_PRELAUNCH_FAILURE_REASON"
		print_info "[exit-trap] using prelaunch failure reason: $reason"
	else
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
	fi

	print_info "[exit-trap] session=$session_key exit=$exit_status reason=$reason session_count=$session_count"
	# t2923/GH#22965: Preserve WIP before releasing the claim so re-dispatch can
	# continue from the pushed branch instead of starting over. Dirty preserved
	# work is reported distinctly to avoid zero-output brief-rewrite holds.
	_push_wip_commits_on_exit
	if [[ "${_WORKER_DIRTY_WORK_PRESERVED:-0}" == "1" ]]; then
		reason="worker_dirty_work_preserved"
	fi
	if declare -F _cleanup_headless_runtime_temp_paths >/dev/null 2>&1; then
		_cleanup_headless_runtime_temp_paths
	fi
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

	# Launch/preflight aborts happen before a worker reaches the brief. They are
	# useful launch diagnostics, but they must not accrue as per-issue fast-fail
	# / no_work circuit-breaker evidence.
	if declare -F _worker_failure_reason_is_launch_preflight >/dev/null 2>&1; then
		if _worker_failure_reason_is_launch_preflight "$reason"; then
			print_info "[fast-fail] skipped launch/preflight failure #${issue_number} (${repo_slug}) reason=${reason}"
			return 0
		fi
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
