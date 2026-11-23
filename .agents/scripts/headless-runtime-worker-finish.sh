#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker Finish -- run-finish helpers
# =============================================================================
# Sourced by headless-runtime-worker.sh after its constants and dependencies.
# Function bodies are kept unchanged; _cmd_run_finish stays in the orchestrator.

# Include guard
[[ -n "${_HEADLESS_RUNTIME_WORKER_FINISH_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_FINISH_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback for direct sourcing and test harnesses
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

_hrw_run_finish_crash_type() {
	case "${_run_result_label:-}" in
	premature_exit | watchdog_stall_continue | watchdog_stall_killed)
		# Model attempted real work (read files, created worktree) but couldn't
		# produce commits/PR. This is "overwhelmed" — the model tried and failed
		# due to task complexity, not infra issues.
		printf '%s\n' "$_HRW_CRASH_OVERWHELMED"
		;;
	no_activity)
		# No LLM output at all — infra/setup failure.
		printf '%s\n' "$_HRW_CRASH_NO_WORK"
		;;
	*)
		# Provider errors, rate limits, auth failures — not a model capability
		# issue, don't classify for escalation purposes.
		printf '\n'
		;;
	esac
	return 0
}

# GH#37984: choose the unrecovered-failure release reason from the run
# classification. A watchdog hard-kill (exit 79, watchdog_stall_killed) is a
# stall, not a worker decision: release it as watchdog_kill:hard_kill_stall so
# pr_checkpoint_events.py STALL_RELEASE_PATTERN and
# pr-checkpoint-continuation-helper.sh _PCC_STALL_RELEASE_PATTERN accept it.
# Every other unrecovered failure keeps the generic worker_failed bucket.
_hrw_failed_run_release_reason() {
	local failure_reason="${_run_failure_reason:-}"
	local result_label="${_run_result_label:-}"

	if [[ "$failure_reason" == "$_HRW_RESULT_WATCHDOG_STALL_KILLED" ||
		(-z "$failure_reason" && "$result_label" == "$_HRW_RESULT_WATCHDOG_STALL_KILLED") ]]; then
		printf '%s\n' "$_HRW_REASON_WATCHDOG_HARD_KILL_STALL"
		return 0
	fi
	printf '%s\n' "worker_failed"
	return 0
}

_hrw_finish_failed_run() {
	local session_key="$1"
	local work_dir="$2"
	local external_terminal_confirmed="${3:-0}"
	local failure_recovered=0

	if ! _hrw_runtime_launch_confirmed; then
		_hrw_finish_not_launched "$session_key"
		return 0
	fi
	if [[ "$external_terminal_confirmed" -eq 1 ]] || \
		_worker_external_terminal_complete "$session_key" "$work_dir"; then
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_WORKER_COMPLETE"
		failure_recovered=1
	elif _recover_worker_output_on_failure "$session_key" "$work_dir"; then
		failure_recovered=1
	else
		_hrw_release_dispatch_claim "$session_key" "$(_hrw_failed_run_release_reason)"
	fi
	if [[ "$failure_recovered" -eq 1 && "${_HRW_RECOVERY_CLASSIFICATION:-$_HRW_REASON_WORKER_COMPLETE}" == "$_HRW_REASON_WORKER_COMPLETE" ]]; then
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
		_HRW_FINAL_RUNTIME_EVENT="worker.completed"
		_HRW_FINAL_RUNTIME_STATUS="recovered"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_REASON_WORKER_COMPLETE"
	elif [[ -n "${_HRW_RECOVERY_CLASSIFICATION:-}" ]]; then
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_FAILED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_FAILED"
		if [[ "$_HRW_RECOVERY_CLASSIFICATION" == "$_HRW_REASON_DRAFT_CHECKPOINT" || \
			"$_HRW_RECOVERY_CLASSIFICATION" == "$_HRW_REASON_READY_FAILED" ]]; then
			_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_ESCALATED"
		fi
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_RECOVERY_CLASSIFICATION"
	else
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_FAILED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_FAILED"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="${_run_failure_reason:-worker_failed}"
	fi

	# Classify crash type from worker session state.
	# _run_result_label is set by _handle_run_result:
	#   "premature_exit" = model had activity but no completion signal
	#   "no_activity"    = no LLM output at all
	#   "watchdog_stall_continue" = stall with prior activity (passive kill)
	#   "watchdog_stall_killed"   = stall + elapsed ≥ hard-kill cap (proactive)
	#   other            = provider/infra failures
	local crash_type=""
	crash_type=$(_hrw_run_finish_crash_type)

	# Self-report to the fast-fail counter so tier escalation fires immediately
	# instead of waiting 30+ min for the pulse to discover the orphaned assignment.
	# Uses the failure reason from the retry loop if available, otherwise defaults
	# to "worker_failed".
	if [[ "$failure_recovered" -eq 0 ]]; then
		_report_failure_to_fast_fail "$session_key" "${_run_failure_reason:-worker_failed}" "$crash_type"
	fi

	return 0
}

_hrw_finish_rate_limit_fast_run() {
	local session_key="$1"

	# GH#21578 / t3021: Transient API rate limit detected within first 30s.
	# Release the dispatch claim so the issue re-queues on the next pulse cycle.
	# Do NOT call _report_failure_to_fast_fail — this is a transient API condition
	# (Anthropic 429/overload), not a model capability failure. NMR backoff would
	# incorrectly penalise the issue for an infrastructure blip. Metric already
	# recorded by _execute_run_attempt with result=rate_limit_fast.
	_hrw_release_dispatch_claim "$session_key" "rate_limit_transient"
	return 0
}

_hrw_record_permission_blocker_failure() {
	local session_key="$1"
	local reason="$2"
	local logger="${SCRIPT_DIR}/worker-blocker-log.mjs"
	[[ -f "$logger" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	node "$logger" append \
		--event "$_HRW_PERMISSION_PERSISTENCE_FAILED" \
		--status "blocked" \
		--reason "$reason" \
		--blocking "true" \
		--source "headless-runtime-worker" \
		--session-key "$session_key" \
		--detail "Worker could not persist the maintainer permission handoff" >/dev/null 2>&1 || true
	return 0
}

_hrw_reconcile_session_permission_blockers() {
	local session_key="$1"
	local terminal_reason="$2"
	local logger="${SCRIPT_DIR}/worker-blocker-log.mjs"
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local issue_number="${WORKER_ISSUE_NUMBER:-}"
	[[ -f "$logger" && -n "$session_key" && -n "$repo_slug" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	node "$logger" resolve-session \
		--repo-slug "$repo_slug" \
		--issue-number "$issue_number" \
		--session-key "$session_key" \
		--event "headless_session_terminal_reconciled" \
		--status "resolved" \
		--reason "$terminal_reason" \
		--source "headless-runtime-worker" \
		--detail "Headless runtime ended ownership of this permission blocker identity" >/dev/null 2>&1 || true
	return 0
}

#######################################
# GH#34040: The permission handoff tells the maintainer the work is preserved,
# but cleanup only unregisters the worktree. Prove commit durability (push or
# verified bundle) and archive uncommitted edits before that claim is made.
# Args: $1=session key, $2=worktree path
# Outputs: durability token (none | pushed:<branch> | bundle:<path> | work_lost)
#######################################
_hrw_secure_permission_work() {
	local session_key="$1"
	local work_dir="$2"
	local durability="unverified"
	if declare -F _worker_secure_branch_commits >/dev/null 2>&1; then
		if ! _worker_secure_branch_commits "$work_dir" >&2; then
			_hrw_record_permission_blocker_failure "$session_key" "work_lost"
		fi
		durability="${_WORKER_COMMIT_DURABILITY:-unverified}"
	fi
	if [[ -n "$work_dir" && -d "$work_dir" ]] && declare -F _worker_archive_dirty_worktree_patch >/dev/null 2>&1; then
		local branch_name=""
		branch_name=$(git -C "$work_dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch_name="detached"
		_worker_archive_dirty_worktree_patch "$work_dir" "$branch_name" >&2
	fi
	printf '%s\n' "$durability"
	return 0
}

_hrw_finish_permission_required_run() {
	local session_key="$1"
	local work_dir="$2"
	local helper="${SCRIPT_DIR}/worker-permission-helper.sh"
	local permission_status="$_HRW_STATUS_PERMISSION_REQUIRED"
	local durability=""
	if [[ ! -x "$helper" || -z "${_run_permission_request_file:-}" ]]; then
		_hrw_record_permission_blocker_failure "$session_key" "permission_capture_or_helper_unavailable"
		_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
		return 1
	fi
	durability=$(_hrw_secure_permission_work "$session_key" "$work_dir")
	local helper_rc=0
	"$helper" request \
		--file "$_run_permission_request_file" \
		--issue "${WORKER_ISSUE_NUMBER:-}" \
		--repo "${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}" \
		--session "$session_key" \
		--work-dir "$work_dir" \
		--durability "$durability" || helper_rc=$?
	if [[ "$helper_rc" -eq 3 ]]; then
		# GH#35128: temp/scratch write is an owned recovery (use AIDEVOPS_TEMP_DIR);
		# no maintainer hold. Release the claim so the issue is redispatched.
		_hrw_release_dispatch_claim "$session_key" "temp_dir_recovery"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_CHECKPOINTED"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="temp_dir_owned_recovery"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
		rm -f "$_run_permission_request_file" 2>/dev/null || true
		return 0
	fi
	if [[ "$helper_rc" -ne 0 ]]; then
		_hrw_record_permission_blocker_failure "$session_key" "permission_handoff_failed"
		_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
		return 1
	fi
	# Captured tool-request identities end only after the issue handoff is durable.
	# Keeping them active across a failed label/comment write preserves enough
	# request-specific evidence for the next reconciliation pass.
	_hrw_reconcile_session_permission_blockers "$session_key" "permission_handoff_transition"
	_hrw_release_dispatch_claim "$session_key" "$permission_status"
	_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
	_HRW_FINAL_RUNTIME_STATUS="$permission_status"
	_HRW_FINAL_RUNTIME_CLASSIFICATION="awaiting_maintainer_permission"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
	rm -f "$_run_permission_request_file" 2>/dev/null || true
	return 0
}

_hrw_record_terminal_outcome() {
	local session_key="$1"
	local outcome="$2"
	local reason="$3"
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"

	[[ -x "$ledger_helper" && -n "$outcome" ]] || return 0
	"$ledger_helper" record-outcome \
		--session-key "$session_key" \
		--lease-token "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" \
		--attempt-id "${AIDEVOPS_ATTEMPT_ID:-}" \
		--issue "${WORKER_ISSUE_NUMBER:-}" \
		--repo "${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}" \
		--tier "${AIDEVOPS_DISPATCH_TIER:-}" \
		--model "${AIDEVOPS_ROUTING_MODEL:-}" \
		--variant "${AIDEVOPS_ROUTING_VARIANT:-}" \
		--routing-attempts "${AIDEVOPS_ROUTING_ATTEMPT:-}" \
		--tokens "${_MODEL_REPLAY_TOKENS_TOTAL:-0}" \
		--outcome "$outcome" \
		--reason "$reason" 2>/dev/null || true
	return 0
}

_hrw_record_reconciled_outcome() {
	local session_key="$1"
	local raw_result="$2"
	local outcome="$3"
	local status="$4"
	local classification="$5"
	local helper="${OBJECTIVE_RECONCILIATION_HELPER:-${SCRIPT_DIR}/objective-reconciliation-helper.sh}"
	local issue_number="${WORKER_ISSUE_NUMBER:-}"
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local next_action="narrow_redispatch"
	local write_attempt=1
	local max_write_attempts="${AIDEVOPS_OBJECTIVE_OUTCOME_WRITE_ATTEMPTS:-3}"
	local write_timeout="${AIDEVOPS_OBJECTIVE_OUTCOME_WRITE_TIMEOUT_SECONDS:-10}"
	[[ "$max_write_attempts" =~ ^[1-5]$ ]] || max_write_attempts=3
	[[ "$write_timeout" =~ ^[1-9][0-9]*$ && "$write_timeout" -le 60 ]] || write_timeout=10

	case "$outcome" in
	success)
		if [[ "$status" == "$_HRW_STATUS_POST_MERGE_CLEANUP" ]]; then
			next_action="monitor_cleanup_receipt"
		else
			next_action="monitor_pr"
		fi
		;;
	deferred)
		if [[ "$status" == "$_HRW_STATUS_PERMISSION_REQUIRED" ]]; then
			next_action="await_maintainer_permission"
		else
			next_action="retry_infrastructure"
		fi
		;;
	escalated) next_action="decision_ready_human_packet" ;;
	esac
	[[ -x "$helper" && "$issue_number" =~ ^[1-9][0-9]*$ && -n "$repo_slug" && -n "${AIDEVOPS_ATTEMPT_ID:-}" ]] || return 0
	while [[ "$write_attempt" -le "$max_write_attempts" ]]; do
		if timeout_sec "$write_timeout" "$helper" record-outcome --repo "$repo_slug" --issue "$issue_number" \
			--attempt-id "$AIDEVOPS_ATTEMPT_ID" --run-id "${AIDEVOPS_RUN_ID:-}" \
			--attempt-started-at "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" \
			--raw-result "$raw_result" --outcome "$outcome" --status "$status" \
			--classification "$classification" --next-action "$next_action" >/dev/null 2>&1; then
			return 0
		fi
		write_attempt=$((write_attempt + 1))
		[[ "$write_attempt" -le "$max_write_attempts" ]] && sleep 0.1
	done
	print_warning "[lifecycle] reconciled outcome persistence failed after ${max_write_attempts} attempts session=${session_key} attempt=${AIDEVOPS_ATTEMPT_ID}"
	return 0
}

_hrw_mark_failed_terminal_state() {
	local status="$1"
	local classification="$2"
	_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_FAILED"
	_HRW_FINAL_RUNTIME_STATUS="$status"
	_HRW_FINAL_RUNTIME_CLASSIFICATION="$classification"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
	return 0
}

_hrw_preserve_ready_missing_summary_handoff() {
	local session_key="$1"
	local output_class="$2"
	_escalate_worker_pr_checkpoint "$session_key" "${DISPATCH_REPO_SLUG:-}" "$output_class" \
		"$_HRW_REASON_READY_MISSING_SUMMARY" "$_HRW_REASON_READY_HANDOFF_FAILED"
	if [[ "$_HRW_RECOVERY_CLASSIFICATION" == "$_HRW_REASON_READY_MISSING_SUMMARY" ]]; then
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_CHECKPOINTED"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_REASON_READY_MISSING_SUMMARY"
	else
		_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_RECOVERY_CLASSIFICATION"
	fi
	return 0
}

_hrw_preserve_ready_missing_linkage_handoff() {
	local session_key="$1"
	local output_class="$2"
	_escalate_worker_pr_checkpoint "$session_key" "${DISPATCH_REPO_SLUG:-}" "$output_class" \
		"$_HRW_REASON_READY_MISSING_LINKAGE" "$_HRW_REASON_READY_LINKAGE_HANDOFF_FAILED"
	if [[ "$_HRW_RECOVERY_CLASSIFICATION" == "$_HRW_REASON_READY_MISSING_LINKAGE" ]]; then
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_CHECKPOINTED"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_REASON_READY_MISSING_LINKAGE"
	else
		_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_RECOVERY_CLASSIFICATION"
	fi
	return 0
}

_hrw_preserve_draft_checkpoint_handoff() {
	local session_key="$1"
	local output_class="$2"
	_escalate_worker_pr_checkpoint "$session_key" "${DISPATCH_REPO_SLUG:-}" "$output_class"
	if [[ "$_HRW_RECOVERY_CLASSIFICATION" == "$_HRW_REASON_DRAFT_CHECKPOINT" ]]; then
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_CHECKPOINTED"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_RECOVERY_CLASSIFICATION"
	else
		_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_RECOVERY_CLASSIFICATION"
	fi
	return 0
}

_hrw_preserve_merged_checkpoint_handoff() {
	local session_key="$1"
	local work_dir="${2:-${_WORKER_WORKTREE_PATH:-}}"
	local reason="$_HRW_REASON_MERGED_PARTIAL"
	_HRW_MERGED_DELIVERY_KEY=""
	if [[ -n "$work_dir" ]]; then
		_hrw_merged_checkpoint_delivery "$session_key" "$work_dir" || {
			_hrw_mark_failed_terminal_state "$_HRW_STATUS_BLOCKED" "merged_delivery_unverified"
			return 0
		}
		[[ "$_HRW_MERGED_DELIVERY_REPEATED" != 1 ]] || reason="$_HRW_REASON_MERGED_NO_PROGRESS"
	fi
	# A merged PR no longer owns an in-review issue. Live-state projection
	# preserves its blocker or releases unfinished work, never marks it done.
	# GH#33545: no draft exists, so do not report it as a draft checkpoint.
	_hrw_release_dispatch_claim "$session_key" "$reason"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
	_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
	_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_CHECKPOINTED"
	_HRW_FINAL_RUNTIME_CLASSIFICATION="$reason"
	[[ "$reason" != "$_HRW_REASON_MERGED_NO_PROGRESS" ]] || _HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_BLOCKED"
	return 0
}

# Compare the exact delivered PR/head with the last trusted partial release.
# Comments are repository-scoped durable evidence, including across runners.
_hrw_merged_checkpoint_delivery() {
	local session_key="$1"
	local work_dir="$2"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""
	local head=""
	local handoff=""
	local comments=""
	local previous=""
	local branch=""
	_HRW_MERGED_DELIVERY_REPEATED=0
	issue_number=$(_hrw_issue_number_for_session "$session_key") || return 1
	head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || return 1
	branch=$(git -C "$work_dir" branch --show-current 2>/dev/null) || return 1
	handoff=$(_pr_handoff_state_for_branch_or_issue "$branch" "$issue_number" "$repo_slug" "" "$head" 1) || return 1
	[[ "$handoff" =~ ^merged[^\|]*\|[1-9][0-9]*$ ]] || return 1
	_HRW_MERGED_DELIVERY_KEY="${handoff##*|}:${head}"
	local comments_endpoint=""
	printf -v comments_endpoint 'repos/%s/issues/%s/comments' "$repo_slug" "$issue_number"
	comments=$(gh api --paginate --slurp "$comments_endpoint" 2>/dev/null) || return 1
	previous=$(printf '%s' "$comments" | jq -r --arg trusted '^(OWNER|MEMBER|COLLABORATOR)$' \
		--arg release 'CLAIM_RELEASED reason=worker_merged_partial( |\n|$|_no_progress)' \
		'[.[][] | select((.author_association // "") | test($trusted)) | select((.body // "") | test($release))] | sort_by(.created_at) | last | .body // ""') || return 1
	if [[ "$previous" == *"MERGED_PARTIAL_DELIVERY key=${_HRW_MERGED_DELIVERY_KEY}"* ]]; then
		_HRW_MERGED_DELIVERY_REPEATED=1
	fi
	return 0
}

_hrw_preserve_blocked_outcome() {
	local session_key="$1"
	local work_dir="$2"

	# A structured terminal blocker is meaningful model output, even when it
	# cannot produce a commit or PR. Preserve that classification instead of
	# routing it through zero-output/no_work accounting.
	AIDEVOPS_TERMINAL_BLOCKER_REPO_PATH="$work_dir" \
		_hrw_release_dispatch_claim "$session_key" "${_run_failure_reason:-$_HRW_STATUS_BLOCKED}"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
	_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
	_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_BLOCKED"
	_HRW_FINAL_RUNTIME_CLASSIFICATION="${_run_failure_reason:-$_HRW_STATUS_BLOCKED}"
	return 0
}

#######################################
# Route an unconfirmed POST_PR_HANDOFF whose exact-head PR is durable.
#
# `_worker_post_pr_handoff_confirmed` accepts only a fully linked, summarised
# ready PR. A worker that deliberately delivers part of an issue opens a ready
# PR with a non-closing `For #N` reference (ready_missing_linkage), and a PR can
# also lack its MERGE_SUMMARY or still be a worker draft. Those PRs are durable
# exact-head checkpoints, not failures: route them through the same
# preservation handlers as the output classifier (status:in-review, runner
# assigned, auto-dispatch removed) so they neither escalate the tier nor return
# the issue to the dispatch queue while the PR exists (GH#33115).
#
# GH#36171: a transport deferral is not evidence that no durable PR exists.
# When the exact-head state was unreadable, re-verify a bounded number of
# times; a handoff that then confirms continues the normal success path, and
# one that stays unreadable is deferred with the claim retained.
#
# Every other class keeps the unverified handoff failure path: release,
# fast-fail as overwhelmed, failed terminal.
#
# Args: $1=session key, $2=work dir
# Env:  AIDEVOPS_POST_PR_HANDOFF_VERIFY_ATTEMPTS (1-5, default 3)
#       AIDEVOPS_POST_PR_HANDOFF_VERIFY_DELAY_SECONDS (0-120, default 20)
# Returns: 0 when a durable checkpoint handler ran or verification was
#          deferred, 1 when the run was routed as an unverified-handoff
#          failure, 2 (_HRW_HANDOFF_CONFIRMED_ON_RETRY) when re-verification
#          confirmed the handoff.
#######################################
_hrw_handle_unverified_post_pr_handoff() {
	local session_key="$1"
	local work_dir="$2"
	local output_class=""
	local attempt=1
	local max_attempts="${AIDEVOPS_POST_PR_HANDOFF_VERIFY_ATTEMPTS:-3}"
	local retry_delay="${AIDEVOPS_POST_PR_HANDOFF_VERIFY_DELAY_SECONDS:-20}"
	[[ "$max_attempts" =~ ^[1-5]$ ]] || max_attempts=3
	[[ "$retry_delay" =~ ^[0-9]+$ && "$retry_delay" -le 120 ]] || retry_delay=20

	while :; do
		output_class=""
		[[ -n "$work_dir" ]] && output_class=$(_worker_produced_output "$session_key" "$work_dir")
		case "$output_class" in
		draft_checkpoint) _hrw_preserve_draft_checkpoint_handoff "$session_key" "$output_class"; break ;;
		merged_checkpoint) _hrw_preserve_merged_checkpoint_handoff "$session_key" "$work_dir"; break ;;
		ready_missing_summary) _hrw_preserve_ready_missing_summary_handoff "$session_key" "$output_class"; break ;;
		ready_missing_linkage) _hrw_preserve_ready_missing_linkage_handoff "$session_key" "$output_class"; break ;;
		esac
		if ! _hrw_post_pr_handoff_reverifiable "$output_class"; then
			print_warning "[lifecycle] ${_HRW_REASON_UNVERIFIED_HANDOFF} session=${session_key} output_class=${output_class:-none} handoff_state=${_WORKER_POST_PR_HANDOFF_STATE:-rejected} — exact-head non-draft PR handoff could not be verified; routing as failure"
			_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_UNVERIFIED_HANDOFF"
			_report_failure_to_fast_fail "$session_key" "$_HRW_REASON_UNVERIFIED_HANDOFF" "$_HRW_CRASH_OVERWHELMED"
			_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_REASON_UNVERIFIED_HANDOFF"
			return 1
		fi
		if [[ "$attempt" -ge "$max_attempts" ]]; then
			_hrw_defer_unverified_post_pr_handoff "$session_key" "$output_class" "$attempt"
			return 0
		fi
		attempt=$((attempt + 1))
		print_info "[lifecycle] post_pr_handoff verification indeterminate session=${session_key} output_class=${output_class:-none} handoff_state=${_WORKER_POST_PR_HANDOFF_STATE:-unknown}; re-verifying in ${retry_delay}s (attempt ${attempt}/${max_attempts})"
		sleep "$retry_delay"
		if _worker_post_pr_handoff_confirmed "$session_key" "$work_dir"; then
			print_info "[lifecycle] post_pr_handoff session=${session_key} confirmed on re-verification attempt ${attempt}/${max_attempts}"
			return "$_HRW_HANDOFF_CONFIRMED_ON_RETRY"
		fi
	done
	print_info "[lifecycle] unverified post_pr_handoff session=${session_key} routed to exact-head checkpoint state=${output_class}"
	return 0
}

#######################################
# GH#36171: decide whether an unconfirmed POST_PR_HANDOFF may still verify.
#
# A local transport deferral (quota cooldown/pacing) makes the exact-head
# probe return `unknown`, which `_worker_produced_output` fails open to
# `pr_exists` — the same class it prints for a confirmed ready PR. Retry only
# when the strict probe could not read GitHub, or when the independent
# classifier readback saw `pr_exists` while the strict probe reported missing
# linkage/summary (one of those reads was deferred). Identity/precondition
# rejections (`rejected`) and consistent definitive states stay final.
#
# Args: $1=output class from the latest classifier pass
# Returns: 0 when bounded re-verification may change the outcome, 1 otherwise
#######################################
_hrw_post_pr_handoff_reverifiable() {
	local output_class="$1"
	case "${_WORKER_POST_PR_HANDOFF_STATE:-rejected}" in
	unknown | merged_issue_unreadable) return 0 ;;
	ready_missing_* | merged_missing_*)
		[[ "$output_class" == "pr_exists" ]] && return 0
		;;
	esac
	return 1
}

#######################################
# GH#36171: record an exact-head handoff whose GitHub state stayed unreadable.
#
# Keep the dispatch claim: no CLAIM_RELEASED, fast-fail or tier escalation.
# The pushed PR (if any) remains the dedup signal; Pulse merge and stale-claim
# recovery decide on fresh state once GitHub is readable again. The outcome is
# deferred (retry_infrastructure), never success, so an unverifiable
# handoff still cannot be counted as completion (GH#33115).
#
# Args: $1=session key, $2=last output class, $3=verification attempts made
#######################################
_hrw_defer_unverified_post_pr_handoff() {
	local session_key="$1"
	local output_class="$2"
	local attempts="$3"
	print_warning "[lifecycle] ${_HRW_REASON_HANDOFF_VERIFICATION_DEFERRED} session=${session_key} output_class=${output_class:-none} handoff_state=${_WORKER_POST_PR_HANDOFF_STATE:-unknown} attempts=${attempts} — exact-head PR state stayed unreadable; retaining claim without tier escalation"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
	_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
	_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_CHECKPOINTED"
	_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_REASON_HANDOFF_VERIFICATION_DEFERRED"
	return 0
}

#######################################
# Gate a POST_PR_HANDOFF before the verified-handoff success path.
#
# Never reuses a verification state recorded by an earlier probe. A handoff
# confirmed on bounded re-verification (GH#36171) continues exactly like one
# confirmed by the first probe.
#
# Args: $1=session key, $2=work dir
# Returns: 0 when the verified success path may continue, 1 when the run was
#          routed as an unverified-handoff failure, _HRW_HANDOFF_ROUTED when a
#          checkpoint handler or verification deferral already finished it.
#######################################
_hrw_post_pr_handoff_gate() {
	local session_key="$1"
	local work_dir="$2"
	local handoff_rc=0
	_WORKER_POST_PR_HANDOFF_STATE=""
	if declare -F _worker_post_pr_handoff_confirmed >/dev/null 2>&1 &&
		_worker_post_pr_handoff_confirmed "$session_key" "$work_dir"; then
		return 0
	fi
	_hrw_handle_unverified_post_pr_handoff "$session_key" "$work_dir" || handoff_rc=$?
	case "$handoff_rc" in
	0) return "$_HRW_HANDOFF_ROUTED" ;;
	"$_HRW_HANDOFF_CONFIRMED_ON_RETRY") return 0 ;;
	esac
	return 1
}

_hrw_finish_not_launched() {
	local session_key="$1"
	_hrff_log_prelaunch_abort "$session_key" "${_WORKER_PRELAUNCH_FAILURE_REASON:-worker_runtime_not_invoked}"
	print_warning "[lifecycle] worker_not_launched session=${session_key} attempt_id=${AIDEVOPS_ATTEMPT_ID:-unknown} stage=${_WORKER_PRELAUNCH_LAST_STAGE:-unknown} cause=${_WORKER_PRELAUNCH_FAILURE_REASON:-unknown}; exact-head revision approval remains reusable"
	# GH#38481: records only an evidenced missing runtime binary (exit 127).
	if declare -F _hrff_record_runner_health_failure >/dev/null 2>&1; then
		_hrff_record_runner_health_failure "$session_key" "$_HRW_REASON_NOT_LAUNCHED"
	fi
	_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_NOT_LAUNCHED"
	_report_failure_to_fast_fail "$session_key" "worker_runtime_not_invoked" ""
	_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_REASON_NOT_LAUNCHED"
	return 0
}

_hrw_finish_success_run() {
	local session_key="$1"
	local work_dir="$2"
	local release_needed=1
	local finish_status=0
	local permission_pending_file=""
	_hrw_runtime_launch_confirmed || { _hrw_finish_not_launched "$session_key"; return 0; }
	if [[ "${_run_result_label:-}" == "$_HRW_STATUS_BLOCKED" ]]; then
		_hrw_preserve_blocked_outcome "$session_key" "$work_dir"
		return 0
	fi
	if [[ "${_run_result_label:-}" == "post_pr_handoff" ]]; then
		local handoff_gate_rc=0
		_hrw_post_pr_handoff_gate "$session_key" "$work_dir" || handoff_gate_rc=$?
		[[ "$handoff_gate_rc" -eq "$_HRW_HANDOFF_ROUTED" ]] && return 0
		[[ "$handoff_gate_rc" -eq 0 ]] || return 1
	fi

	# GH#20721 + GH#20819: Classify worker output quality.
	# _worker_produced_output distinguishes exact-head completion from drafts,
	# failed checks, closed PRs, and inconclusive issue-search matches.
	#   noop                  — no commits, no branch, no PR → fast-fail
	#   branch_orphan         — branch pushed but no PR → auto-recover
	#   local_branch_unpushed — local commits but no remote branch/PR → push+recover
	#   dirty_worktree        — local edits exist but no commit/PR → preserve marker
	#   draft_checkpoint      — durable but incomplete PR → exact-head continuation
	#   pr_exists             — PR confirmed, or fail-open → worker_complete
	#
	# Fail-open semantics are preserved: when signals cannot be evaluated (no git
	# repo, no gh, no remote) the classification is "pr_exists", so false-negatives
	# (legit work misclassified) are impossible.
	if [[ "$release_needed" -eq 1 && -n "$work_dir" ]] && \
		! _hrw_terminal_objective_complete "$session_key" "$work_dir"; then
		local output_class="pr_exists"
		output_class=$(_worker_produced_output "$session_key" "$work_dir")
		case "$output_class" in
		noop)
			print_info "[lifecycle] worker_noop session=$session_key — zero commits, no pushed branch, no PR"
			_hrw_release_dispatch_claim "$session_key" "worker_noop"
			_report_failure_to_fast_fail "$session_key" "worker_noop_zero_output" "$_HRW_CRASH_NO_WORK"
			release_needed=0
			_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_CRASH_NO_WORK"
			;;
		branch_orphan)
			_handle_worker_branch_orphan "$session_key" "$work_dir"
			release_needed=0
			;;
		local_branch_unpushed)
			_handle_worker_local_branch_unpushed "$session_key" "$work_dir"
			release_needed=0
			;;
		dirty_worktree)
			_handle_worker_dirty_worktree "$session_key" "$work_dir"
			release_needed=0
			;;
		draft_checkpoint)
			_hrw_preserve_draft_checkpoint_handoff "$session_key" "$output_class"
			release_needed=0
			;;
		merged_checkpoint)
			_hrw_preserve_merged_checkpoint_handoff "$session_key" "$work_dir"
			release_needed=0
			;;
		ready_missing_summary)
			_hrw_preserve_ready_missing_summary_handoff "$session_key" "$output_class"
			release_needed=0
			;;
		ready_missing_linkage)
			_hrw_preserve_ready_missing_linkage_handoff "$session_key" "$output_class"
			release_needed=0
			;;
		closed_unmerged)
			print_warning "[lifecycle] ${_HRW_REASON_CLOSED_UNMERGED} session=${session_key} — closed PR is not completion evidence"
			_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_CLOSED_UNMERGED"
			_report_failure_to_fast_fail "$session_key" "$_HRW_REASON_CLOSED_UNMERGED" "$_HRW_CRASH_OVERWHELMED"
			release_needed=0
			_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_REASON_CLOSED_UNMERGED"
			;;
		protected_draft | unverified_open_pr | head_mismatch | merged_missing_linkage | merged_missing_summary)
			local noncomplete_reason="worker_${output_class}"
			print_warning "[lifecycle] ${noncomplete_reason} session=${session_key} — protected/inconclusive PR state is not completion evidence; retaining claim"
			release_needed=0
			_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$noncomplete_reason"
			;;
		esac
	fi

	if [[ "$release_needed" -eq 1 ]]; then
		# pr_exists or fail-open: normal success path. Post CLAIM_RELEASED with
		# reason=worker_complete so the audit trail shows the full lifecycle even
		# when no PR was created.
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_WORKER_COMPLETE"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
	fi
	if [[ "$_HRW_TERMINAL_OUTCOME" == "$_HRW_TELEMETRY_SUCCESS" ]]; then
		permission_pending_file=$(_hrw_permission_pending_path "$work_dir" || true)
		rm -f "${AIDEVOPS_PERMISSION_GRANT_FILE:-}" "$permission_pending_file" 2>/dev/null || true
	fi

	return "$finish_status"
}

_hrw_finish_cleanup() {
	local session_key="$1"
	local ledger_status="$2"
	local work_dir="$3"

	_update_dispatch_ledger "$session_key" "$ledger_status"
	_release_session_lock "$session_key"
	_hrw_release_worker_worktree "$work_dir" "$session_key"
	cleanup_headless_git_auth
	if declare -F _cleanup_headless_runtime_temp_paths >/dev/null 2>&1; then
		_cleanup_headless_runtime_temp_paths
	fi
	aidevops_runtime_bundle_lease_release || print_warning "Failed to release the worker runtime bundle lease"
	trap - EXIT
	return 0
}

_hrw_write_external_final_outcome() {
	local session_key="$1"
	local ledger_status="$2"
	local external_session_count="0" external_reason="" external_retry_class=""
	[[ "${_WORKER_EXTERNAL_OUTCOME_WRITTEN:-0}" != "1" ]] || return 0
	external_session_count=$(_hrff_worker_session_count)
	external_reason="${_HRW_FINAL_RUNTIME_CLASSIFICATION:-worker_complete}"
	if [[ "$external_reason" == worker_complete ]] && ! _hrw_runtime_launch_confirmed; then
		external_reason="$_HRW_REASON_NOT_LAUNCHED"
	fi
	external_retry_class=$(_hrff_retry_class_for_reason "$external_reason" "$external_session_count")
	if [[ "$ledger_status" == "$_HRW_STATUS_PERMISSION_REQUIRED" ]]; then
		external_reason="$_HRW_STATUS_PERMISSION_REQUIRED"
		external_retry_class="$_HRFF_RETRY_CLASS_MAINTAINER_GATE"
	elif [[ "$external_reason" == "$_HRW_CRASH_NO_WORK" && "$external_session_count" == "0" ]]; then
		external_reason="worker_noop_zero_output"
		external_retry_class="$_HRFF_RETRY_CLASS_INFRASTRUCTURE"
	elif [[ "$external_reason" == "$_HRW_REASON_HANDOFF_VERIFICATION_DEFERRED" || "$external_reason" == "$_HRW_REASON_NOT_LAUNCHED" ]]; then
		external_retry_class="$_HRFF_RETRY_CLASS_INFRASTRUCTURE"
	elif [[ "$_HRW_TERMINAL_OUTCOME" == "$_HRW_TELEMETRY_SUCCESS" ]]; then
		external_reason="${external_reason:-$_HRW_REASON_WORKER_COMPLETE}"
		external_retry_class="$_HRFF_RETRY_CLASS_REMEDIATION"
	elif [[ "$_HRW_FINAL_RUNTIME_STATUS" == "$_HRW_STATUS_CHECKPOINTED" ]]; then
		external_retry_class="$_HRFF_RETRY_CLASS_REMEDIATION"
	fi
	_hrff_write_external_outcome "$session_key" "$external_reason" "$external_session_count" "$external_retry_class" || \
		print_warning "[lifecycle] failed to persist external terminal outcome for session=${session_key}"
	return 0
}
