#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker -- Worker lifecycle, invocation support & preparation
# =============================================================================
# Worker-specific helpers: auth rotation, rate-limit monitoring, Claude CLI
# invocation, output preservation, output classification, orphan handling,
# run preparation/retry/finish, detach, and stall-cap checks.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-worker.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, etc.)
#   - headless-runtime-lib.sh (extract_provider, append_runtime_metric, etc.)
#   - shared-claim-lifecycle.sh (_attempt_orphan_recovery_pr, _release_dispatch_claim, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_WORKER_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_LIB_LOADED=1

# Module-local string constants (avoid ratchet repeated-literal violations)
_HRW_STATUS_FAIL="fail"
_HRW_STATUS_FAILED="failed"
_HRW_STATUS_ESCALATED="escalated"
_HRW_STATUS_UNKNOWN="unknown"
_HRW_STATUS_PERMISSION_REQUIRED="permission_required"
_HRW_STATUS_POST_MERGE_CLEANUP="post_merge_cleanup_deferred"
_HRW_GIT_HEAD="HEAD"
_HRW_CRASH_NO_WORK="no_work"
_HRW_CRASH_OVERWHELMED="overwhelmed"
_HRW_REASON_WORKER_COMPLETE="worker_complete"
_HRW_REASON_NOT_LAUNCHED="worker_not_launched"
_HRW_TELEMETRY_SUCCESS="success"
_HRW_TELEMETRY_FAILED="failed"
_HRW_TELEMETRY_DEFERRED="deferred"
_HRW_STATUS_CHECKPOINTED="checkpointed"
_HRW_STATUS_BLOCKED="blocked"
_HRW_REASON_DRAFT_CHECKPOINT="worker_draft_checkpoint"
_HRW_REASON_DRAFT_ESCALATION_FAILED="worker_draft_checkpoint_escalation_failed"
# GH#33545: a ready partial PR merged during the session; no draft remains and
# the issue stays open for continuation from the brief ledger.
_HRW_REASON_MERGED_PARTIAL="worker_merged_partial"
_HRW_REASON_MERGED_NO_PROGRESS="worker_merged_partial_no_progress"
_HRW_REASON_READY_MISSING_LINKAGE="worker_ready_missing_linkage"
_HRW_REASON_READY_LINKAGE_HANDOFF_FAILED="worker_ready_missing_linkage_transition_failed"
_HRW_REASON_READY_MISSING_SUMMARY="worker_ready_missing_summary"
_HRW_REASON_READY_HANDOFF_FAILED="worker_ready_missing_summary_transition_failed"
_HRW_REASON_CLOSED_UNMERGED="worker_closed_unmerged_pr"
_HRW_REASON_UNVERIFIED_HANDOFF="worker_post_pr_handoff_unverified"
# GH#36171: exact-head handoff evidence stayed unreadable (transport deferral).
_HRW_REASON_HANDOFF_VERIFICATION_DEFERRED="worker_post_pr_handoff_verification_deferred"
_HRW_HANDOFF_CONFIRMED_ON_RETRY=2
_HRW_HANDOFF_ROUTED=3
_HRW_REASON_ORIGIN_RECONCILIATION_FAILED="worker_origin_reconciliation_failed"
_HRW_ORIGIN_WORKER_LABEL="origin:worker"
_HRW_ORIGIN_STATE_MISSING="missing"
_HRW_ORIGIN_STATE_VERIFIED="verified"
_HRW_HANDOFF_READY="ready"
_HRW_REASON_WORKTREE_CONTINUATION_STATE_REJECTED="worker_worktree_continuation_state_rejected"
_HRW_REASON_WORKTREE_CONTINUATION_OWNER_ABSENT="worker_worktree_continuation_owner_absent"
_HRW_REASON_WORKTREE_OWNER_CONCURRENT_MUTATION="worker_worktree_owner_concurrent_mutation"
_HRW_WORKTREE_RECLAIM_TRANSFERRED="transferred"
_HRW_WORKTREE_RECLAIM_VACATED="vacated"
_HRW_WORKTREE_RECLAIM_OUTCOME=""
_HRW_REASON_OWNERSHIP_LOST="worker_ownership_lost"
# GH#37984: a watchdog hard-kill records no worker decision, so its release
# must stay stall-class (watchdog_kill:*) for checkpoint approval/stall routes.
_HRW_RESULT_WATCHDOG_STALL_KILLED="watchdog_stall_killed"
_HRW_REASON_WATCHDOG_HARD_KILL_STALL="watchdog_kill:hard_kill_stall"
_HRW_REASON_SENSITIVE_TEMP_PREFLIGHT="worker_sensitive_temp_preflight_failed"
_HRW_EVENT_FAILED="worker.failed"
_HRW_EVENT_DEFERRED="worker.deferred"
_HRW_PERMISSION_PERSISTENCE_FAILED="permission_request_persistence_failed"
_HRW_SPOTLIGHT_MARKER=".metadata_never_index"
# GH#37597: runtime-only marker full-loop-helper.sh merge writes on
# CLEANUP_DEFERRED; lifecycle state, never task output.
_HRW_DEFERRED_CLEANUP_EXCLUDE_PATHSPEC=":(top,exclude,literal).agents/.full-loop-cleanup-deferred"
_HRW_RECOVERY_CLASSIFICATION=""
_HRW_CLAIM_RELEASE_PERSISTENCE_FAILED=0

# Defensive SCRIPT_DIR fallback (test harnesses may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# shellcheck source=shared-runner-identity.sh
source "${SCRIPT_DIR}/shared-runner-identity.sh"

# Post-merge permission classification reuses the same exact merge and durable
# cleanup evidence as full-loop finalization instead of inventing weaker proof.
# shellcheck source=./full-loop-helper-evidence.sh
source "${SCRIPT_DIR}/full-loop-helper-evidence.sh"
# shellcheck source=./full-loop-cleanup-receipt.sh
source "${SCRIPT_DIR}/full-loop-cleanup-receipt.sh"

# shellcheck source=./headless-runtime-worker-prepare.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-worker-prepare.sh"

#######################################
# Release a claim without allowing a GitHub comment persistence failure to
# bypass later terminal-lease emission and local cleanup. The underlying
# helper still returns non-zero to direct callers so the write is observable
# and retryable; worker lifecycle callers record the failure and continue.
#######################################
_hrw_release_dispatch_claim() {
	local session_key="$1"
	local reason="${2:-worker_failed}"
	local exit_code_arg="${3:-}"
	local session_count_arg="${4:-}"

	if _release_dispatch_claim "$session_key" "$reason" "$exit_code_arg" "$session_count_arg"; then
		return 0
	fi
	_HRW_CLAIM_RELEASE_PERSISTENCE_FAILED=1
	print_warning "[lifecycle] claim_release_persistence_failed session=${session_key} reason=${reason}; terminal lease/event cleanup remains active"
	return 0
}

# shellcheck source=./headless-runtime-worker-invocation.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-worker-invocation.sh"

# shellcheck source=./headless-runtime-worker-output.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-worker-output.sh"

# shellcheck source=./headless-runtime-worker-orphan.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-worker-orphan.sh"

#######################################
# _handle_worker_dirty_worktree — preserve uncommitted worker edits after crash.
#
# Local runtime failures can interrupt OpenCode after file edits but before the
# worker commits or opens a PR. Do not redispatch blindly; publish a structured
# ops marker so maintainers can inspect the runner-local worktree and recover the
# edits before cleanup or duplicate workers overwrite context.
#
# Args: $1=session_key, $2=work_dir
#######################################
_handle_worker_dirty_worktree() {
	local session_key="$1"
	local work_dir="$2"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""
	if declare -F _scl_worker_issue_number >/dev/null 2>&1; then
		issue_number=$(_scl_worker_issue_number "$session_key")
	fi

	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	local status_summary=""
	status_summary=$(git -C "$work_dir" status --short 2>/dev/null | sed -n '1,50p' || true)
	[[ -n "$status_summary" ]] || status_summary="<dirty state unavailable>"
	local runner_key=""
	runner_key=$(runner_identity_key)

	# Persist the full runner-local recovery context before any GitHub write.
	# The ledger retains the private worktree path; the public marker below uses
	# only a non-identifying runner key and repository-relative changed paths.
	if [[ -x "${DISPATCH_LEDGER_HELPER:-}" ]]; then
		"$DISPATCH_LEDGER_HELPER" record-recovery \
			--session-key "$session_key" \
			--runner-key "$runner_key" \
			--worktree "$work_dir" \
			--branch "$branch_name" \
			--changed-paths "$status_summary" \
			--recoverability "same-runner" 2>/dev/null || true
	fi

	print_info "[lifecycle] worker_dirty_worktree session=${session_key} branch=${branch_name:-<none>} work_dir_present=$([[ -d "$work_dir" ]] && printf 1 || printf 0)"

	# The finish path can classify dirty work before the EXIT trap runs. Give the
	# owning runner two bounded opportunities to checkpoint, push, and open the
	# recovery PR now instead of globally pausing all dispatchers.
	local previous_worktree_path="${_WORKER_WORKTREE_PATH:-}"
	local recovered=0
	_WORKER_WORKTREE_PATH="$work_dir"
	if declare -F _push_wip_commits_on_exit >/dev/null 2>&1 && declare -F _recover_dirty_worker_pr >/dev/null 2>&1; then
		local recovery_attempt=1
		while [[ "$recovery_attempt" -le 2 ]]; do
			_push_wip_commits_on_exit
			if _recover_dirty_worker_pr "$session_key"; then
				recovered=1
				break
			fi
			recovery_attempt=$((recovery_attempt + 1))
		done
	fi
	_WORKER_WORKTREE_PATH="$previous_worktree_path"

	if [[ "$recovered" -eq 1 ]]; then
		if [[ -x "${DISPATCH_LEDGER_HELPER:-}" ]]; then
			"$DISPATCH_LEDGER_HELPER" record-recovery \
				--session-key "$session_key" \
				--runner-key "$runner_key" \
				--worktree "$work_dir" \
				--branch "$branch_name" \
				--changed-paths "$status_summary" \
				--recoverability "$_HRW_STATUS_CHECKPOINTED" 2>/dev/null || true
		fi
		_escalate_worker_pr_checkpoint "$session_key" "$repo_slug" "draft_checkpoint"
		if [[ "$_HRW_RECOVERY_CLASSIFICATION" == "$_HRW_REASON_DRAFT_CHECKPOINT" ]]; then
			_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
			_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
			_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_CHECKPOINTED"
			_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_REASON_DRAFT_CHECKPOINT"
			print_info "[lifecycle] worker_dirty_worktree_checkpointed session=${session_key} branch=${branch_name:-<none>}"
		else
			_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_RECOVERY_CLASSIFICATION"
		fi
		return 0
	fi

	_hrw_release_dispatch_claim "$session_key" "worker_dirty_worktree"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"

	if [[ -n "$issue_number" && -n "$repo_slug" ]]; then
		local _ops_comment
		local _dirty_key="${repo_slug}#${issue_number}#${branch_name:-unknown}#worker_dirty_worktree"
		local _comments_endpoint="repos/${repo_slug}/issues/${issue_number}/com""ments"
		# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
		_ops_comment=$(printf '<!-- ops:start -->\n<!-- worker-dirty-worktree:key=%s -->\nWORKER_DIRTY_WORKTREE branch=%s session=%s runner_key=%s recoverability=same-runner ts=%s\n\nThe owning runner could not create a pushed checkpoint during bounded teardown recovery. Its dispatch ledger retains the private worktree path. Prefer same-runner resume while that worktree exists; cross-runner takeover is allowed only after the bounded recovery hold expires.\n\nChanged paths reported by git status on the owning runner:\n\n```\n%s\n```\n<!-- ops:end -->' \
			"$_dirty_key" \
			"${branch_name:-unknown}" "$session_key" "$runner_key" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$status_summary")
		local existing_marker_count="0"
		existing_marker_count=$(gh api "${_comments_endpoint}?per_page=100" 2>/dev/null | jq -r --arg key "worker-dirty-worktree:key=${_dirty_key}" '[.[] | select((.body // "") | contains($key))] | length' 2>/dev/null || printf '0')
		if [[ "$existing_marker_count" == "0" ]]; then
			gh api "$_comments_endpoint" \
				--method POST \
				--field body="$_ops_comment" \
				>/dev/null 2>&1 || true
		fi
	fi
	return 0
}

#######################################
# Classify exact PR metadata for worker-origin reconciliation.
#
# Args: repo slug, PR number, branch, head SHA, expected author.
# Stdout: verified|missing. Returns non-zero for unavailable, mismatched, or
# conflicting provenance.
#######################################
_hrw_worker_handoff_origin_state() {
	local repo_slug="$1"
	local pr_number="$2"
	local branch_name="$3"
	local expected_head="$4"
	local expected_author="$5"
	local pr_json=""

	pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json number,state,isDraft,isCrossRepository,headRefName,headRefOid,author,labels 2>/dev/null) || return 1
	printf '%s' "$pr_json" | jq -e --argjson pr "$pr_number" \
		--arg branch "$branch_name" --arg head "$expected_head" --arg author "$expected_author" '
		(.number == $pr) and (.state == "OPEN") and (.isDraft == false) and (.isCrossRepository == false) and
		(.headRefName == $branch) and (.headRefOid == $head) and
		((.author.login // "") == $author)
	' >/dev/null 2>&1 || return 1
	if ! printf '%s' "$pr_json" | jq -e --arg worker_origin "$_HRW_ORIGIN_WORKER_LABEL" '
		[.labels[]?.name | select(startswith("origin:") and . != $worker_origin)] | length == 0
	' >/dev/null 2>&1; then
		return 1
	fi
	if printf '%s' "$pr_json" | jq -e --arg worker_origin "$_HRW_ORIGIN_WORKER_LABEL" \
		'[.labels[]?.name] | index($worker_origin) != null' >/dev/null 2>&1; then
		printf '%s' "$_HRW_ORIGIN_STATE_VERIFIED"
	else
		printf '%s' "$_HRW_ORIGIN_STATE_MISSING"
	fi
	return 0
}

#######################################
# Restore missing worker provenance only while this exact issue worker still
# owns the dispatch and its exact-head, linked, summarized PR. User-controlled
# body markers are deliberately excluded from the proof chain.
#
# Args: session key, worktree path.
# Returns: 0 when origin:worker was already present or was added and verified.
#######################################
_hrw_reconcile_worker_handoff_origin() {
	local session_key="$1"
	local work_dir="$2"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local runner_login="${WORKER_GITHUB_LOGIN:-${AIDEVOPS_WORKER_GITHUB_LOGIN:-}}"
	local issue_number="${session_key#issue-}"
	local branch_name=""
	local local_head=""
	local handoff_state=""
	local pr_number=""
	local origin_state=""

	[[ "$session_key" == issue-* && "$issue_number" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ "${WORKER_SESSION_KEY:-}" == "$session_key" ]] || return 1
	[[ "${WORKER_ISSUE_NUMBER:-}" == "$issue_number" ]] || return 1
	[[ "$repo_slug" == */* && -n "$runner_login" ]] || return 1
	[[ -n "$work_dir" && -d "$work_dir" ]] || return 1
	command -v gh >/dev/null 2>&1 || return 1

	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	local_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null || true)
	[[ -n "$branch_name" && "$branch_name" != "$_HRW_GIT_HEAD" && -n "$local_head" ]] || return 1
	handoff_state=$(_pr_handoff_state_for_branch_or_issue \
		"$branch_name" "$issue_number" "$repo_slug" "head-only" "$local_head" "1") || return 1
	[[ "${handoff_state%%|*}" == "$_HRW_HANDOFF_READY" ]] || return 1
	pr_number="${handoff_state#*|}"
	[[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 1

	_hrw_verify_dispatch_ownership || return 1
	origin_state=$(_hrw_worker_handoff_origin_state \
		"$repo_slug" "$pr_number" "$branch_name" "$local_head" "$runner_login") || return 1
	[[ "$origin_state" == "$_HRW_ORIGIN_STATE_MISSING" ]] || {
		[[ "$origin_state" == "$_HRW_ORIGIN_STATE_VERIFIED" ]]
		return $?
	}
	# Recheck live issue ownership immediately before mutating trust metadata.
	_hrw_verify_dispatch_ownership || return 1
	gh pr edit "$pr_number" --repo "$repo_slug" --add-label "$_HRW_ORIGIN_WORKER_LABEL" >/dev/null 2>&1 || return 1
	origin_state=$(_hrw_worker_handoff_origin_state \
		"$repo_slug" "$pr_number" "$branch_name" "$local_head" "$runner_login") || return 1
	[[ "$origin_state" == "$_HRW_ORIGIN_STATE_VERIFIED" ]] || return 1
	# Retain the claim if ownership changed while GitHub applied the label.
	_hrw_verify_dispatch_ownership || return 1
	print_info "[pulse-wrapper] Reconciled missing origin:worker label for PR #${pr_number} after worker recovery"
	return 0
}

#######################################
# Recover tangible worker output on failure paths.
#
# Watchdog/SIGKILL exits can happen after a worker has already pushed a branch
# or opened a PR. The historical failure path released those as worker_failed,
# causing duplicate redispatch even though recoverable output existed. This
# helper mirrors the success-path output classifier, but only treats confirmed
# signals as recovered so fail-open/unknown checks still fall through to normal
# failure handling.
#
# Args: $1=session_key, $2=work_dir
# Returns: 0 if recovery released the claim, 1 if caller should continue failure.
#######################################
_recover_worker_output_on_failure() {
	local session_key="$1"
	local work_dir="$2"

	[[ -n "$work_dir" && -d "$work_dir" ]] || return 1
	[[ "$session_key" == issue-* ]] || return 1

	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local branch_name=""
	local issue_number=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)

	local default_branch=""
	default_branch=$(_hrw_resolve_default_branch "$work_dir")
	[[ -z "$default_branch" ]] && default_branch="${DISPATCH_REPO_DEFAULT_BRANCH:-main}"

	_HRW_RECOVERY_CLASSIFICATION=""
	if [[ -n "$repo_slug" && -n "$issue_number" && -n "$branch_name" && "$branch_name" != "$_HRW_GIT_HEAD" && "$branch_name" != "$default_branch" ]] && \
		declare -F _pr_handoff_state_for_branch_or_issue >/dev/null 2>&1; then
		local pr_handoff="unknown|"
		local local_head=""
		local_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null || true)
		[[ -n "$local_head" ]] || local_head="missing-local-head"
		pr_handoff=$(_pr_handoff_state_for_branch_or_issue "$branch_name" "$issue_number" "$repo_slug" \
			"branch-or-issue" "$local_head" 1)
		local pr_state="${pr_handoff%%|*}"
		if [[ "$pr_state" == "$_HRW_HANDOFF_READY" || "$pr_state" == "merged" ]]; then
			if [[ "$pr_state" == "$_HRW_HANDOFF_READY" ]] && ! _hrw_reconcile_worker_handoff_origin "$session_key" "$work_dir"; then
				_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_ORIGIN_RECONCILIATION_FAILED"
				print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — provenance ambiguous or write unverified; retaining claim"
				return 0
			fi
			print_info "[lifecycle] worker_failure_recovered_existing_pr session=${session_key} branch=${branch_name}"
			_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_WORKER_COMPLETE"
			_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_WORKER_COMPLETE"
			return 0
		fi
		if [[ "$pr_state" == "draft_checkpoint" ]]; then
			_escalate_worker_pr_checkpoint "$session_key" "$repo_slug" "$pr_state"
			return 0
		fi
		if [[ "$pr_state" == "protected_draft" || "$pr_state" == "unverified_open_pr" || \
			"$pr_state" == "head_mismatch" || "$pr_state" == "ready_missing_linkage" || \
			"$pr_state" == "merged_missing_linkage" || "$pr_state" == "ready_missing_summary" || \
			"$pr_state" == "merged_missing_summary" ]]; then
			_HRW_RECOVERY_CLASSIFICATION="worker_${pr_state}"
			print_warning "[lifecycle] ${_HRW_RECOVERY_CLASSIFICATION} session=${session_key} — not completion evidence; retaining claim"
			return 0
		fi
	fi

	local output_class=""
	output_class=$(_worker_produced_output "$session_key" "$work_dir")
	if [[ "$output_class" == "branch_orphan" ]]; then
		print_info "[lifecycle] worker_failure_recovering_branch_orphan session=${session_key} branch=${branch_name:-<none>}"
		_handle_worker_branch_orphan "$session_key" "$work_dir"
		return 0
	fi
	if [[ "$output_class" == "local_branch_unpushed" ]]; then
		print_info "[lifecycle] worker_failure_recovering_local_branch_unpushed session=${session_key} branch=${branch_name:-<none>}"
		_handle_worker_local_branch_unpushed "$session_key" "$work_dir"
		return 0
	fi
	if [[ "$output_class" == "dirty_worktree" ]]; then
		print_info "[lifecycle] worker_failure_preserving_dirty_worktree session=${session_key} branch=${branch_name:-<none>}"
		_handle_worker_dirty_worktree "$session_key" "$work_dir"
		return 0
	fi

	return 1
}

# shellcheck source=./headless-runtime-worker-terminal.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-worker-terminal.sh"

# =============================================================================
# Run lifecycle — prepare, finish, retry, detach
# =============================================================================

# shellcheck source=./headless-runtime-worker-ownership.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-worker-ownership.sh"

# shellcheck source=./headless-runtime-worker-finish.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-worker-finish.sh"

_cmd_run_finish() {
	local session_key="$1"
	local ledger_status="$2"
	# work_dir is optional ($3). When present and ledger_status != "fail",
	# _worker_produced_output() classifies tangible output to distinguish
	# worker_complete, worker_branch_orphan, and worker_noop (GH#20721, GH#20819).
	local work_dir="${3:-${_WORKER_WORKTREE_PATH:-}}"
	# Optional $4 carries a terminal-state proof already confirmed at a retry
	# boundary. Reusing it avoids a second GitHub query that could fail after the
	# first query already proved the issue and matching PR are terminal.
	local external_terminal_confirmed="${4:-0}"
	local finish_status=0
	if _headless_private_workload_enabled; then
		_private_workload_exit_trap "$session_key" "${_PRIVATE_WORKLOAD_LOCK_KEY:-}" \
			|| finish_status=$?
		_WORKER_WORKTREE_PATH=""
		WORKER_TARGET_BRANCH=""
		return "$finish_status"
	fi
	local runtime_role="${_CMD_RUN_ROLE:-worker}"
	if [[ "$runtime_role" != "worker" ]]; then
		_hrw_cleanup_non_worker_run "$session_key"
		return $?
	fi
	_HRW_FINAL_RUNTIME_EVENT="worker.completed"
	_HRW_FINAL_RUNTIME_STATUS="${_run_result_label:-$ledger_status}"
	_HRW_FINAL_RUNTIME_CLASSIFICATION="${_run_failure_reason:-}"
	_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
	_HRW_RECOVERY_CLASSIFICATION=""

	# Release the dispatch claim so the issue is immediately available for
	# re-dispatch (next 2-min pulse cycle) instead of waiting for the
	# 30-min DISPATCH_COMMENT_MAX_AGE TTL to expire.
	#
	# Both success and failure paths post CLAIM_RELEASED — completion signal
	# consistency matters (GH#19836 follow-up). On success, the worker may
	# have exited without creating a PR (e.g., premise falsified and issue
	# closed, or worker completed an out-of-PR action). Relying only on
	# "PR with Closes #" or MERGE_SUMMARY to clear the claim leaves a 30-min
	# dead-zone where the issue is stuck with no audit trail. The
	# dispatch-dedup guard already treats any CLAIM_RELEASED as authoritative
	# (dispatch-dedup-helper.sh:1044), so this is safe — if a worker DID
	# create a PR with Closes, the PR-based dedup signal still wins and the
	# CLAIM_RELEASED comment is redundant operational metadata.
	if [[ "$ledger_status" == "$_HRW_STATUS_FAIL" && "${_run_failure_reason:-}" == "$_HRW_REASON_OWNERSHIP_LOST" ]]; then
		# Another owner took the issue after dispatch. Terminalize only this
		# worker's lease; do not run recovery or mutate the new owner's issue state.
		_hrw_release_dispatch_claim "$session_key" "$_HRW_REASON_OWNERSHIP_LOST"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_FAILED"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_FAILED"
		_HRW_FINAL_RUNTIME_STATUS="$_HRW_STATUS_FAILED"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="$_HRW_REASON_OWNERSHIP_LOST"
	elif [[ "$ledger_status" == "$_HRW_STATUS_FAIL" ]]; then
		_hrw_finish_failed_run "$session_key" "$work_dir" "$external_terminal_confirmed"
	elif [[ "$ledger_status" == "rate_limit_fast" ]]; then
		_hrw_finish_rate_limit_fast_run "$session_key"
		_HRW_FINAL_RUNTIME_EVENT="$_HRW_EVENT_DEFERRED"
		_HRW_FINAL_RUNTIME_STATUS="rate_limit_fast"
		_HRW_FINAL_RUNTIME_CLASSIFICATION="rate_limit"
		_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_DEFERRED"
	elif [[ "$ledger_status" == "$_HRW_STATUS_PERMISSION_REQUIRED" ]]; then
		if ! _hrw_finish_permission_required_run "$session_key" "$work_dir"; then
			_run_failure_reason="$_HRW_PERMISSION_PERSISTENCE_FAILED"
			_hrw_finish_failed_run "$session_key" "$work_dir" "$external_terminal_confirmed"
			finish_status=1
			ledger_status="$_HRW_STATUS_FAIL"
		fi
		if [[ ! "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ ]]; then
			_hrw_reconcile_session_permission_blockers "$session_key" \
				"${_run_failure_reason:-permission_session_terminal}"
		fi
	else
		if ! _hrw_finish_success_run "$session_key" "$work_dir"; then
			finish_status=1
			ledger_status="$_HRW_STATUS_FAIL"
		fi
	fi
	_hrw_record_terminal_outcome "$session_key" "$_HRW_TERMINAL_OUTCOME" \
		"$_HRW_FINAL_RUNTIME_CLASSIFICATION"
	_emit_worker_runtime_event "$_HRW_FINAL_RUNTIME_EVENT" \
		"$_HRW_FINAL_RUNTIME_STATUS" "$_HRW_FINAL_RUNTIME_CLASSIFICATION"
	_hrw_record_reconciled_outcome "$session_key" "${_run_result_label:-$ledger_status}" \
		"$_HRW_TERMINAL_OUTCOME" "$_HRW_FINAL_RUNTIME_STATUS" "$_HRW_FINAL_RUNTIME_CLASSIFICATION"
	_hrw_write_external_final_outcome "$session_key" "$ledger_status"

	_hrw_finish_cleanup "$session_key" "$ledger_status" "$work_dir"
	return "$finish_status"
}
