#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Review-thread scanner exact-head validation and owned worktree preparation.
# Source from pr-review-thread-response-scanner.sh after its shared configuration.
# Depends on shared-constants.sh, scratch-worktree-helper.sh and scanner utilities.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PRRTS_WORKTREE_LOADED:-}" ]] && return 0
_PRRTS_WORKTREE_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_prrts_worktree_path="${BASH_SOURCE[0]%/*}"
	[[ "$_prrts_worktree_path" == "${BASH_SOURCE[0]}" ]] && _prrts_worktree_path="."
	SCRIPT_DIR="$(cd "$_prrts_worktree_path" && pwd)"
	unset _prrts_worktree_path
fi

_prrts_worktree_path_for_branch() {
	local repo_path="$1"
	local head_ref="$2"
	local line="" worktree_path=""

	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		"worktree "*) worktree_path="${line#worktree }" ;;
		"branch refs/heads/${head_ref}")
			[[ -n "$worktree_path" ]] || return 1
			printf '%s' "$worktree_path"
			return 0
			;;
		"") worktree_path="" ;;
		esac
	done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
	return 1
}

_prrts_validate_worker_head() {
	local repo_slug="$1"
	local repo_path="$2"
	local pr_number="$3"
	local head_ref="$4"
	local head_oid="$5"
	local is_cross_repository="" pr_repo_json=""

	[[ -n "$head_ref" ]] || {
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — PR head branch is unavailable"
		PRRTS_WORKTREE_FAILURE_BLOCKED_BY="$PRRTS_BLOCKED_BY_CODE"
		PRRTS_WORKTREE_FAILURE_REASON="pr_head_branch_unavailable"
		return 1
	}
	if ! git -C "$repo_path" check-ref-format --branch "$head_ref" >/dev/null 2>&1; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — PR head branch is invalid"
		PRRTS_WORKTREE_FAILURE_BLOCKED_BY="$PRRTS_BLOCKED_BY_CODE"
		PRRTS_WORKTREE_FAILURE_REASON="pr_head_branch_invalid"
		return 1
	fi
	if [[ ! "$head_oid" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — PR head SHA is unavailable or invalid"
		PRRTS_WORKTREE_FAILURE_BLOCKED_BY="$PRRTS_BLOCKED_BY_CODE"
		PRRTS_WORKTREE_FAILURE_REASON="pr_head_sha_invalid"
		return 1
	fi
	pr_repo_json=$(AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS=1 \
		AIDEVOPS_GH_ROUTE_DECISION="review-thread-head-repository-rest" \
		_prrts_gh_call read gh api "repos/${repo_slug}/pulls/${pr_number}" 2>/dev/null) || {
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — could not verify PR head repository"
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_HEAD_REPOSITORY_UNVERIFIED"
		return 1
	}
	is_cross_repository=$(printf '%s' "$pr_repo_json" | jq -er '
		if ((.head.repo.full_name // "") | length) > 0 and ((.base.repo.full_name // "") | length) > 0
		then (.head.repo.full_name != .base.repo.full_name) | tostring
		else error("missing PR repository identity")
		end' 2>/dev/null) || {
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — could not verify PR head repository"
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_HEAD_REPOSITORY_UNVERIFIED"
		return 1
	}
	if [[ "$is_cross_repository" == "$PRRTS_BOOL_TRUE" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — fork PR head is not writable through the base repository remote"
		PRRTS_WORKTREE_FAILURE_BLOCKED_BY="$PRRTS_BLOCKED_BY_CODE"
		PRRTS_WORKTREE_FAILURE_REASON="cross_repository_head_unwritable"
		return 1
	fi
	if [[ "$is_cross_repository" != "$PRRTS_BOOL_FALSE" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — PR head repository response was indeterminate"
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_HEAD_REPOSITORY_UNVERIFIED"
		return 1
	fi
	return 0
}

_prrts_fetch_exact_worker_head() {
	local repo_slug="$1"
	local repo_path="$2"
	local pr_number="$3"
	local head_ref="$4"
	local head_oid="$5"
	local remote_head=""
	local canonical_root=""
	local fetch_cwd=""
	local worktree_line=""
	local worktree_path=""
	local resolved_path=""
	local bootstrap_path=""
	local fetch_rc=0

	canonical_root=$(cd "$repo_path" 2>/dev/null && pwd -P) || canonical_root=""
	while IFS= read -r worktree_line || [[ -n "$worktree_line" ]]; do
		case "$worktree_line" in
		"worktree "*)
			worktree_path="${worktree_line#worktree }"
			[[ -d "$worktree_path" ]] || continue
			resolved_path=$(cd "$worktree_path" 2>/dev/null && pwd -P) || resolved_path=""
			[[ -n "$resolved_path" && "$resolved_path" != "$canonical_root" ]] || continue
			fetch_cwd="$resolved_path"
			break
			;;
		esac
	done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null)

	if [[ -z "$fetch_cwd" ]]; then
		# GH#35024: owned, locked scratch context; removed only while still ours.
		if ! scratch_worktree_add "$repo_path" "$PR_REVIEW_THREAD_RESPONSE_WORKTREE_BASE_DIR" fetch HEAD; then
			_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — could not create a linked PR head fetch context"
			PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_HEAD_FETCH_FAILED"
			return 1
		fi
		bootstrap_path="$SCRATCH_WORKTREE_PATH"
		fetch_cwd="$bootstrap_path"
	fi

	git -C "$fetch_cwd" fetch --no-tags --quiet origin \
		"+refs/heads/${head_ref}:refs/remotes/origin/${head_ref}" >/dev/null 2>&1 || fetch_rc=$?
	if [[ -n "$bootstrap_path" ]]; then
		scratch_worktree_remove "$bootstrap_path" "pr-review-thread-response-scanner.sh" || true
	fi
	if [[ "$fetch_rc" -ne 0 ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — PR head fetch failed from linked-worktree context"
		PRRTS_WORKTREE_FAILURE_BLOCKED_BY="$PRRTS_BLOCKED_BY_INFRASTRUCTURE"
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_HEAD_FETCH_FAILED"
		return 1
	fi
	remote_head=$(git -C "$repo_path" rev-parse "refs/remotes/origin/${head_ref}" 2>/dev/null) || remote_head=""
	if [[ "$remote_head" != "$head_oid" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — PR head changed during dispatch (expected ${head_oid}, got ${remote_head:-unknown})"
		PRRTS_WORKTREE_FAILURE_REASON="pr_head_changed_during_dispatch"
		return 1
	fi
	if ! git -C "$repo_path" cat-file -e "${head_oid}^{commit}" 2>/dev/null; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — exact PR head commit is unavailable locally"
		PRRTS_WORKTREE_FAILURE_REASON="pr_head_commit_unavailable"
		return 1
	fi
	return 0
}

_prrts_reset_worktree_transfer_context() {
	PRRTS_WORKTREE_TRANSFER_MODE=""
	PRRTS_WORKTREE_EXPECTED_OWNER_PID=""
	PRRTS_WORKTREE_EXPECTED_OWNER_SESSION=""
	PRRTS_WORKTREE_EXPECTED_OWNER_BATCH=""
	PRRTS_WORKTREE_EXPECTED_OWNER_TASK=""
	PRRTS_WORKTREE_EXPECTED_OWNER_CREATED_AT=""
	PRRTS_WORKTREE_EXPECTED_OWNER_PROCESS_START=""
	return 0
}

# Extension points for bounded PR workflows. Ordinary review repair uses the PR
# number as its worker task and has no separate linked-issue contract.
_prrts_worker_task_id() {
	local pr_number="$1"
	printf '%s' "$pr_number"
	return 0
}

_prrts_dispatch_precreate_session() {
	local pr_number="$1"
	printf 'dispatch-precreate-%s' "$pr_number"
	return 0
}

_prrts_repair_linked_issue() {
	local pr_number="$1"
	: "$pr_number"
	return 0
}

_prrts_checkpoint_author() {
	# Ordinary review repair has no checkpoint author contract.
	return 0
}

_prrts_checkpoint_lease() {
	# Never inherit a caller's unrelated issue lease into a direct PR worker.
	return 0
}

_prrts_checkpoint_session() {
	return 0
}

_prrts_worker_login() {
	local pr_number="$1"
	local worker_login=""
	: "$pr_number"

	# #aidevops:trust-boundary — ordinary PR repair binds ownership to the
	# authenticated gh viewer. Checkpoint continuation overrides this function
	# with its independently verified linked-issue assignee contract.
	worker_login=$(_prrts_gh_call read gh api user --jq '.login // ""' 2>/dev/null || true)
	if [[ "$worker_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		printf '%s' "$worker_login"
		return 0
	fi

	worker_login=$(_prrts_gh_call read gh api graphql \
		-f 'query=query { viewer { login } }' \
		--jq '.data.viewer.login // ""' 2>/dev/null || true)
	if [[ "$worker_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		printf '%s' "$worker_login"
		return 0
	fi

	return 1
}

_prrts_prelaunch_target_fence() {
	local repo_slug="$1"
	local pr_number="$2"
	local head_ref="$3"
	local head_oid="$4"
	: "$repo_slug" "$pr_number" "$head_ref" "$head_oid"
	return 0
}

_prrts_read_worktree_owner_snapshot() {
	local worktree_path="$1"
	local owner_pid_var="$2"
	local owner_session_var="$3"
	local owner_batch_var="$4"
	local owner_task_var="$5"
	local owner_created_at_var="$6"
	local owner_process_start_var="$7"
	local owner_info=""
	local parsed_pid="" parsed_session="" parsed_batch="" parsed_task="" parsed_created_at="" parsed_process_start=""

	declare -F check_worktree_owner_snapshot >/dev/null 2>&1 || return 1
	owner_info=$(check_worktree_owner_snapshot "$worktree_path" 2>/dev/null || true)
	[[ -n "$owner_info" ]] || return 1
	IFS='|' read -r parsed_pid parsed_session parsed_batch parsed_task parsed_created_at parsed_process_start <<<"$owner_info"
	printf -v "$owner_pid_var" '%s' "$parsed_pid"
	printf -v "$owner_session_var" '%s' "$parsed_session"
	printf -v "$owner_batch_var" '%s' "$parsed_batch"
	printf -v "$owner_task_var" '%s' "$parsed_task"
	printf -v "$owner_created_at_var" '%s' "$parsed_created_at"
	printf -v "$owner_process_start_var" '%s' "$parsed_process_start"
	return 0
}

_prrts_apply_expected_worktree_owner() {
	local repo_slug="$1"
	local pr_number="$2"
	local worktree_path="$3"
	local owner_pid="$4"
	local owner_session="$5"
	local owner_batch="$6"
	local owner_task="$7"
	local owner_created_at="$8"
	local owner_process_start="$9"
	local required_session="${10}"
	local worker_task=""
	worker_task=$(_prrts_worker_task_id "$pr_number") || worker_task=""

	if [[ -z "$owner_task" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
	elif [[ -z "$worker_task" || "$owner_task" != "$worker_task" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNED_BY_OTHER_TASK"
	elif [[ ! "$owner_pid" =~ ^[0-9]+$ || -z "$owner_session" || -z "$owner_created_at" || -z "$owner_process_start" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
	elif [[ -n "$required_session" && "$owner_session" != "$required_session" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
	else
		PRRTS_WORKTREE_TRANSFER_MODE="continuation"
		PRRTS_WORKTREE_EXPECTED_OWNER_PID="$owner_pid"
		PRRTS_WORKTREE_EXPECTED_OWNER_SESSION="$owner_session"
		PRRTS_WORKTREE_EXPECTED_OWNER_BATCH="$owner_batch"
		PRRTS_WORKTREE_EXPECTED_OWNER_TASK="$owner_task"
		PRRTS_WORKTREE_EXPECTED_OWNER_CREATED_AT="$owner_created_at"
		PRRTS_WORKTREE_EXPECTED_OWNER_PROCESS_START="$owner_process_start"
		return 0
	fi

	_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — worktree ownership cannot be transferred safely (${PRRTS_WORKTREE_FAILURE_REASON}, path=${worktree_path})"
	return 1
}

_prrts_capture_expected_worktree_owner() {
	local repo_slug="$1"
	local pr_number="$2"
	local worktree_path="$3"
	local required_session="${4:-}"
	local owner_pid=""
	local owner_session=""
	local owner_batch=""
	local owner_task=""
	local owner_created_at=""
	local owner_process_start=""

	if ! _prrts_read_worktree_owner_snapshot "$worktree_path" owner_pid owner_session owner_batch owner_task owner_created_at owner_process_start; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — worktree has no verifiable ownership record (${worktree_path})"
		return 1
	fi
	_prrts_apply_expected_worktree_owner "$repo_slug" "$pr_number" "$worktree_path" \
		"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$owner_created_at" "$owner_process_start" "$required_session" || return 1
	return 0
}

_prrts_claim_dispatch_precreate_owner() {
	local repo_slug="$1"
	local pr_number="$2"
	local worktree_path="$3"
	local head_ref="$4"
	local precreate_session=""
	precreate_session=$(_prrts_dispatch_precreate_session "$pr_number")
	local worker_task=""
	worker_task=$(_prrts_worker_task_id "$pr_number") || worker_task=""
	[[ -n "$worker_task" ]] || return 1

	if ! declare -F claim_worktree_ownership >/dev/null 2>&1; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — atomic worktree ownership claim is unavailable"
		return 1
	fi
	if ! claim_worktree_ownership "$worktree_path" "$head_ref" \
		--task "$worker_task" --session "$precreate_session" --owner-pid "$$" 2>/dev/null; then
		PRRTS_WORKTREE_FAILURE_REASON="review_worktree_ownership_conflict"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — atomic worktree ownership claim was rejected (${worktree_path})"
		return 1
	fi
	_prrts_capture_expected_worktree_owner "$repo_slug" "$pr_number" "$worktree_path" "$precreate_session" || return 1
	return 0
}

_prrts_prepare_reused_worktree_owner() {
	local repo_slug="$1"
	local pr_number="$2"
	local worktree_path="$3"
	local head_ref="$4"
	local owner_pid=""
	local owner_session=""
	local owner_batch=""
	local owner_task=""
	local owner_created_at=""
	local owner_process_start=""

	if ! _prrts_read_worktree_owner_snapshot "$worktree_path" owner_pid owner_session owner_batch owner_task owner_created_at owner_process_start; then
		_prrts_claim_dispatch_precreate_owner "$repo_slug" "$pr_number" "$worktree_path" "$head_ref" || return 1
		return 0
	fi
	_prrts_apply_expected_worktree_owner "$repo_slug" "$pr_number" "$worktree_path" \
		"$owner_pid" "$owner_session" "$owner_batch" "$owner_task" "$owner_created_at" "$owner_process_start" "" || return 1
	_prrts_log "dispatch: ${repo_slug}#${pr_number} preserved reused worktree owner for exact continuation transfer (${worktree_path})"
	return 0
}

_prrts_prepare_created_worktree_owner() {
	local repo_slug="$1"
	local pr_number="$2"
	local worktree_path="$3"
	local head_ref="$4"
	local precreate_session=""
	precreate_session=$(_prrts_dispatch_precreate_session "$pr_number")
	local owner_pid=""
	local owner_session=""
	local owner_batch=""
	local owner_task=""
	local owner_created_at=""
	local owner_process_start=""
	local worker_task=""
	worker_task=$(_prrts_worker_task_id "$pr_number") || worker_task=""

	if ! _prrts_read_worktree_owner_snapshot "$worktree_path" owner_pid owner_session owner_batch owner_task owner_created_at owner_process_start; then
		_prrts_claim_dispatch_precreate_owner "$repo_slug" "$pr_number" "$worktree_path" "$head_ref" || return 1
		return 0
	fi
	# worktree-helper can register outside a runtime session. The exact PID,
	# task, and timestamp still authorize this CAS; the resulting precreate
	# snapshot captured below must have a non-empty session before worker launch.
	if [[ -z "$owner_task" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
	elif [[ -z "$worker_task" || "$owner_task" != "$worker_task" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNED_BY_OTHER_TASK"
	elif [[ ! "$owner_pid" =~ ^[0-9]+$ || -z "$owner_created_at" || -z "$owner_process_start" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
	else
		PRRTS_WORKTREE_FAILURE_REASON=""
	fi
	if [[ -n "$PRRTS_WORKTREE_FAILURE_REASON" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — created worktree ownership cannot be transferred safely (${PRRTS_WORKTREE_FAILURE_REASON}, path=${worktree_path})"
		return 1
	fi
	if ! declare -F transfer_worktree_ownership_if_expected >/dev/null 2>&1; then
		PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — atomic worktree ownership transfer is unavailable"
		return 1
	fi
	if ! transfer_worktree_ownership_if_expected "$worktree_path" "$head_ref" \
		--task "$worker_task" --session "$precreate_session" --owner-pid "$$" \
		--expected-owner-pid "$owner_pid" --expected-session "$owner_session" \
		--expected-batch "$owner_batch" --expected-task "$owner_task" \
		--expected-created-at "$owner_created_at" \
		--expected-process-start "$owner_process_start" 2>/dev/null; then
		PRRTS_WORKTREE_FAILURE_REASON="review_worktree_ownership_concurrent_mutation"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — created worktree owner changed before transfer (${worktree_path})"
		return 1
	fi
	_prrts_capture_expected_worktree_owner "$repo_slug" "$pr_number" "$worktree_path" "$precreate_session" || return 1
	return 0
}

_prrts_claim_existing_worktree_for_reconcile() {
	local repo_slug="$1"
	local pr_number="$2"
	local worktree_path="$3"
	local head_ref="$4"
	local owner_pid="" owner_session="" owner_batch="" owner_task="" owner_created_at=""
	local owner_process_start=""
	local worker_task=""
	local precreate_session=""
	precreate_session=$(_prrts_dispatch_precreate_session "$pr_number")
	worker_task=$(_prrts_worker_task_id "$pr_number") || worker_task=""
	[[ -n "$worker_task" ]] || return 1

	if _prrts_read_worktree_owner_snapshot "$worktree_path" owner_pid owner_session owner_batch owner_task owner_created_at owner_process_start; then
		if [[ "$owner_task" != "$worker_task" ]]; then
			PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNED_BY_OTHER_TASK"
			_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — mismatched review worktree belongs to another task (${worktree_path})"
			return 1
		fi
		if [[ ! "$owner_pid" =~ ^[0-9]+$ || -z "$owner_process_start" ]]; then
			PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
			return 1
		fi
		if kill -0 "$owner_pid" 2>/dev/null; then
			PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_live_owner"
			_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — existing review worktree head mismatch has a live owner pid=${owner_pid}"
			return 1
		fi
		if ! declare -F _wt_pid_is_definitely_absent >/dev/null 2>&1 ||
			! _wt_pid_is_definitely_absent "$owner_pid"; then
			PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
			_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — owner PID absence is unverified (${worktree_path})"
			return 1
		fi
		if ! declare -F transfer_worktree_ownership_if_expected >/dev/null 2>&1; then
			PRRTS_WORKTREE_FAILURE_REASON="$PRRTS_REASON_WORKTREE_OWNERSHIP_UNVERIFIED"
			return 1
		fi
		if ! transfer_worktree_ownership_if_expected "$worktree_path" "$head_ref" \
			--task "$worker_task" --session "$precreate_session" --owner-pid "$$" \
			--expected-owner-pid "$owner_pid" --expected-session "$owner_session" \
			--expected-batch "$owner_batch" --expected-task "$owner_task" \
			--expected-created-at "$owner_created_at" \
			--expected-process-start "$owner_process_start" 2>/dev/null; then
			PRRTS_WORKTREE_FAILURE_REASON="review_worktree_ownership_concurrent_mutation"
			return 1
		fi
		_prrts_capture_expected_worktree_owner "$repo_slug" "$pr_number" "$worktree_path" "$precreate_session" || return 1
		return 0
	fi

	_prrts_claim_dispatch_precreate_owner "$repo_slug" "$pr_number" "$worktree_path" "$head_ref" || return 1
	return 0
}

_prrts_preserve_dirty_existing_worktree() {
	local repo_slug="$1"
	local pr_number="$2"
	local worktree_path="$3"
	local initial_head="$4"
	local worker_task=""
	local backup_output=""
	local backup_id=""
	local backup_dir=""
	local status_output=""
	local operation_id="pr-review-reconcile-${pr_number}-${initial_head:-unknown}"

	if [[ ! -x "$PR_REVIEW_THREAD_RESPONSE_DIRTY_BACKUP_HELPER" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_backup_helper_unavailable"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — dirty-worktree backup helper is unavailable"
		return 1
	fi
	worker_task=$(_prrts_worker_task_id "$pr_number") || worker_task=""
	[[ -n "$worker_task" ]] || return 1
	if ! backup_output=$("$PR_REVIEW_THREAD_RESPONSE_DIRTY_BACKUP_HELPER" backup \
		--repo "$worktree_path" \
		--reason "preserve dirty PR review worktree before head reconciliation" \
		--pr "$pr_number" --task "$worker_task" \
		--operation-id "$operation_id" --machine 2>>"$LOGFILE"); then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_backup_failed"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — dirty review worktree backup failed"
		return 1
	fi
	IFS='|' read -r backup_id backup_dir <<<"$backup_output"
	if [[ ! "$backup_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || -z "$backup_dir" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_backup_output_invalid"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — dirty review worktree backup returned invalid evidence"
		return 1
	fi
	if ! "$PR_REVIEW_THREAD_RESPONSE_DIRTY_BACKUP_HELPER" verify \
		--repo "$worktree_path" --backup "$backup_id" >>"$LOGFILE" 2>&1; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_backup_unverified"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — dirty review worktree backup could not be verified (backup=${backup_id})"
		return 1
	fi
	if ! "$PR_REVIEW_THREAD_RESPONSE_DIRTY_BACKUP_HELPER" matches \
		--repo "$worktree_path" --backup "$backup_id" >>"$LOGFILE" 2>&1; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_backup_mismatch"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — dirty review worktree changed after backup (backup=${backup_id})"
		return 1
	fi
	if ! "$PR_REVIEW_THREAD_RESPONSE_DIRTY_BACKUP_HELPER" clean \
		--repo "$worktree_path" --backup "$backup_id" \
		--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP >>"$LOGFILE" 2>&1; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_clean_failed"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — verified dirty review worktree cleanup failed (backup=${backup_id})"
		return 1
	fi
	status_output=$(git -C "$worktree_path" status --porcelain 2>/dev/null) || {
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_clean_unverified"
		return 1
	}
	if [[ -n "$status_output" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_clean_unverified"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — preserved review worktree is still dirty after guarded cleanup (backup=${backup_id})"
		return 1
	fi
	_prrts_log "dispatch: ${repo_slug}#${pr_number} preserved and cleaned exclusively claimed dirty review worktree (backup=${backup_id})"
	return 0
}

_prrts_reconcile_existing_worktree_head() {
	local repo_slug="$1"
	local repo_path="$2"
	local pr_number="$3"
	local worktree_path="$4"
	local head_ref="$5"
	local head_oid="$6"
	local initial_head="$7"
	local actual_head="$initial_head"
	local current_branch=""
	local status_output=""

	current_branch=$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	if [[ "$current_branch" != "$head_ref" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_branch_mismatch"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — existing review worktree branch mismatch (expected ${head_ref}, got ${current_branch:-detached})"
		return 1
	fi
	status_output=$(git -C "$worktree_path" status --porcelain 2>/dev/null) || {
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_status_unavailable"
		return 1
	}
	_prrts_claim_existing_worktree_for_reconcile "$repo_slug" "$pr_number" "$worktree_path" "$head_ref" || return 1
	if [[ -n "$status_output" ]]; then
		_prrts_preserve_dirty_existing_worktree "$repo_slug" "$pr_number" "$worktree_path" "$initial_head" || return 1
	fi
	_prrts_fetch_exact_worker_head "$repo_slug" "$repo_path" "$pr_number" "$head_ref" "$head_oid" || return 1

	status_output=$(git -C "$worktree_path" status --porcelain 2>/dev/null) || {
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_status_unavailable"
		return 1
	}
	current_branch=$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	actual_head=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null) || actual_head=""
	if [[ -n "$status_output" || "$current_branch" != "$head_ref" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_changed_during_reconcile"
		return 1
	fi
	if ! git -C "$worktree_path" merge-base --is-ancestor "$actual_head" "$head_oid" >/dev/null 2>&1; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_diverged"
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — existing review worktree cannot fast-forward to verified PR head"
		return 1
	fi
	if ! git -C "$worktree_path" merge --ff-only "$head_oid" >/dev/null 2>&1; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_fast_forward_failed"
		return 1
	fi
	actual_head=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null) || actual_head=""
	if [[ "$actual_head" != "$head_oid" ]]; then
		PRRTS_WORKTREE_FAILURE_REASON="existing_review_worktree_fast_forward_unverified"
		return 1
	fi
	_prrts_log "dispatch: ${repo_slug}#${pr_number} fast-forwarded exclusively claimed review worktree from ${initial_head} to verified PR head ${head_oid}"
	return 0
}

_prrts_prepare_worker_worktree() {
	local repo_slug="$1"
	local repo_path="$2"
	local pr_number="$3"
	local head_ref="$4"
	local head_oid="$5"
	local output_var="$6"
	local existing_path="" repo_name="" safe_ref="" worktree_path="" resolved_path=""
	local actual_head=""
	local worker_task=""
	worker_task=$(_prrts_worker_task_id "$pr_number") || worker_task=""
	[[ -n "$worker_task" ]] || return 1

	_prrts_reset_worktree_transfer_context
	PRRTS_WORKTREE_FAILURE_BLOCKED_BY="$PRRTS_BLOCKED_BY_INFRASTRUCTURE"
	PRRTS_WORKTREE_FAILURE_REASON="review_worktree_preparation_failed"
	_prrts_validate_worker_head "$repo_slug" "$repo_path" "$pr_number" "$head_ref" "$head_oid" || return 1
	if existing_path="$(_prrts_worktree_path_for_branch "$repo_path" "$head_ref")" && [[ -d "$existing_path" ]]; then
		if [[ "$(cd "$existing_path" 2>/dev/null && pwd -P)" == "$(cd "$repo_path" 2>/dev/null && pwd -P)" ]]; then
			_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — PR branch ${head_ref} is checked out in the canonical repository"
			PRRTS_WORKTREE_FAILURE_BLOCKED_BY="$PRRTS_BLOCKED_BY_CODE"
			PRRTS_WORKTREE_FAILURE_REASON="pr_head_checked_out_in_canonical"
			return 1
		fi
		actual_head=$(git -C "$existing_path" rev-parse HEAD 2>/dev/null) || actual_head=""
		if [[ "$actual_head" != "$head_oid" ]]; then
			_prrts_reconcile_existing_worktree_head "$repo_slug" "$repo_path" "$pr_number" "$existing_path" "$head_ref" "$head_oid" "$actual_head" || return 1
			printf -v "$output_var" '%s' "$existing_path"
			return 0
		fi
		_prrts_prepare_reused_worktree_owner "$repo_slug" "$pr_number" "$existing_path" "$head_ref" || return 1
		printf -v "$output_var" '%s' "$existing_path"
		return 0
	fi

	if [[ ! -x "$PR_REVIEW_THREAD_RESPONSE_WORKTREE_HELPER" ]]; then
		_prrts_log "dispatch: worktree-helper missing or not executable: ${PR_REVIEW_THREAD_RESPONSE_WORKTREE_HELPER}"
		return 1
	fi
	repo_name="$(basename "$repo_path")"
	safe_ref="$(printf '%s' "$head_ref" | tr -c '[:alnum:].-' '-')"
	worktree_path="${PR_REVIEW_THREAD_RESPONSE_WORKTREE_BASE_DIR}/${repo_name}-pr${pr_number}-review-${safe_ref}-${head_oid:0:12}"
	mkdir -p "$PR_REVIEW_THREAD_RESPONSE_WORKTREE_BASE_DIR" 2>/dev/null || return 1
	if [[ -e "$worktree_path" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — expected review worktree path already exists but is not registered (${worktree_path})"
		return 1
	fi
	_prrts_fetch_exact_worker_head "$repo_slug" "$repo_path" "$pr_number" "$head_ref" "$head_oid" || return 1
	if ! (cd "$repo_path" && AIDEVOPS_SKIP_AUTO_CLAIM=1 AIDEVOPS_WORKTREE_BASE_DIR="$PR_REVIEW_THREAD_RESPONSE_WORKTREE_BASE_DIR" \
		"$PR_REVIEW_THREAD_RESPONSE_WORKTREE_HELPER" add "$head_ref" "$worktree_path" --base "$head_oid" --issue "$worker_task") >>"$LOGFILE" 2>&1; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — could not create linked worktree for ${head_ref}"
		return 1
	fi
	resolved_path="$(_prrts_worktree_path_for_branch "$repo_path" "$head_ref")" || resolved_path="$worktree_path"
	actual_head=$(git -C "$resolved_path" rev-parse HEAD 2>/dev/null) || actual_head=""
	if [[ ! -d "$resolved_path" || "$actual_head" != "$head_oid" || "$(cd "$resolved_path" 2>/dev/null && pwd -P)" == "$(cd "$repo_path" 2>/dev/null && pwd -P)" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — linked worktree verification failed for ${head_ref}"
		(cd "$repo_path" && "$PR_REVIEW_THREAD_RESPONSE_WORKTREE_HELPER" remove "$resolved_path" --force) >>"$LOGFILE" 2>&1 || true
		PRRTS_WORKTREE_FAILURE_REASON="review_worktree_exact_head_verification_failed"
		return 1
	fi
	_prrts_prepare_created_worktree_owner "$repo_slug" "$pr_number" "$resolved_path" "$head_ref" || return 1
	printf -v "$output_var" '%s' "$resolved_path"
	return 0
}
