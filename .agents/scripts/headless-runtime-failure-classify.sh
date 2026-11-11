#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Failure - Exit Classification and WIP Preservation
# =============================================================================
# Worker exit/kill classification and exit-time WIP staging/push functions,
# split from headless-runtime-failure.sh to keep that file under the 2000-line
# gate (GH#37744).
#
# Usage: sourced by headless-runtime-failure.sh (do not execute directly).
#
# Dependencies: shared-constants.sh (print_warning, print_info), git, jq,
#   bash 3.2+
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_HEADLESS_RUNTIME_FAILURE_CLASSIFY_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_FAILURE_CLASSIFY_LOADED=1

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

#######################################
# Remove the runtime-only deferred-cleanup marker from the index.
#
# The merge lifecycle writes this marker after the final implementation commit.
# A worker exit must not turn that process-local ownership sentinel into product
# history, including when another path staged it before the EXIT trap ran.
#
# Args:
#   $1 = worktree path
#######################################
_hrff_unstage_deferred_cleanup_marker() {
	local work_dir="$1"

	git -C "$work_dir" reset -q HEAD -- "$_HRFF_DEFERRED_CLEANUP_MARKER" >/dev/null 2>&1 || true
	return 0
}

#######################################
# Return dirty status excluding the runtime-only deferred-cleanup marker.
#
# Args:
#   $1 = worktree path
#######################################
_hrff_actionable_dirty_status() {
	local work_dir="$1"

	git -C "$work_dir" status --porcelain --untracked-files=all -- . \
		"$_HRFF_DEFERRED_CLEANUP_EXCLUDE_PATHSPEC" 2>/dev/null || true
	return 0
}

#######################################
# Stage worker-authored changes without the runtime-only cleanup marker.
#
# Args:
#   $1 = worktree path
#######################################
_hrff_stage_actionable_worker_changes() {
	local work_dir="$1"

	git -C "$work_dir" add -A -- . \
		"$_HRFF_DEFERRED_CLEANUP_EXCLUDE_PATHSPEC" >/dev/null 2>&1 || return 1
	_hrff_unstage_new_embedded_repositories "$work_dir"
	return 0
}

#######################################
# Keep repositories cloned inside the worktree out of preservation commits.
#
# GH#36608: `git add -A` records an embedded clone as a gitlink, which carried
# another repository's checkout into this repository's checkpoint PR. Only
# gitlinks already present in HEAD (real submodules) stay staged; new ones are
# unstaged and left on disk for the local archive and cleanup paths.
#
# Args:
#   $1 = worktree path
#######################################
_hrff_unstage_new_embedded_repositories() {
	local work_dir="$1"
	local entry="" mode="" entry_path=""

	while IFS= read -r -d '' entry; do
		mode="${entry%% *}"
		[[ "$mode" == "160000" ]] || continue
		entry_path="${entry#*$'\t'}"
		[[ -n "$entry_path" ]] || continue
		if [[ -n "$(git -C "$work_dir" ls-tree HEAD -- "$entry_path" 2>/dev/null)" ]]; then
			continue
		fi
		# -f: a freshly staged gitlink differs from both HEAD and the work tree.
		git -C "$work_dir" rm -q --cached -f -- "$entry_path" >/dev/null 2>&1 || true
		print_info "[lifecycle] worker_exit_nested_repo_excluded path=${entry_path}"
	done < <(git -C "$work_dir" ls-files -s -z 2>/dev/null)
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
	_WORKER_BASE_UNRESOLVED=0

	local work_dir="${_WORKER_WORKTREE_PATH:-}"
	if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
		return 0
	fi

	# Canonical checkouts are read-only mirrors, regardless of branch name.
	_project_config_is_linked_worktree "$work_dir" || return 0

	# Get the branch name — skip if detached HEAD or default branch
	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
	case "$branch_name" in
	HEAD | main | master | "")
		return 0
		;;
	esac

	local default_ref=""
	default_ref=$(git -C "$work_dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
	# Older clones may not have origin/HEAD. Only use an existing legacy base.
	if [[ -z "$default_ref" ]]; then
		if git -C "$work_dir" show-ref --verify --quiet refs/remotes/origin/main; then
			default_ref="refs/remotes/origin/main"
		elif git -C "$work_dir" show-ref --verify --quiet refs/remotes/origin/master; then
			default_ref="refs/remotes/origin/master"
		fi
	fi
	[[ -n "$default_ref" && "$branch_name" == "${default_ref#refs/remotes/origin/}" ]] && return 0

	_hrff_unstage_deferred_cleanup_marker "$work_dir"
	local dirty_status=""
	dirty_status=$(_hrff_actionable_dirty_status "$work_dir")
	if [[ -n "$dirty_status" ]]; then
		print_info "[lifecycle] worker_exit_preserving_dirty_work branch=${branch_name}"
		_hrff_stage_actionable_worker_changes "$work_dir" || true
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

	# Missing base metadata must not skip local preservation, but cannot allow push.
	if [[ -z "$default_ref" ]]; then
		_WORKER_BASE_UNRESOLVED=1
		return 0
	fi
	# Count against the resolved default only; zero must not select another base.
	local ahead_count=0
	ahead_count=$(git -C "$work_dir" rev-list --count "${default_ref}..HEAD" 2>/dev/null || true)
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0
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
		# GH#34040: committed work has no diff to archive; bundle it instead.
		local bundle_file=""
		if bundle_file=$(_worker_write_recovery_bundle "$work_dir" "$branch_name"); then
			_WORKER_DIRTY_WORK_PRESERVED=1
			print_warning "[lifecycle] worker_dirty_work_preserved bundle=${bundle_file}"
		else
			print_warning "[lifecycle] work_lost branch=${branch_name} ahead=${ahead_count} — push and recovery bundle both failed"
		fi
	fi
	return 0
}
