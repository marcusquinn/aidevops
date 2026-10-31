#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Linked-worktree ownership, fetch, and reconciliation tests.
# Sourced by test-pr-review-thread-response-scanner.sh; not a standalone suite.
# The entry point owns strict mode, TEST_SCRIPT_DIR, and shared test state.

[[ -n "${_PRRTS_TEST_WORKTREES_LOADED:-}" ]] && return 0
_PRRTS_TEST_WORKTREES_LOADED=1

register_test_worktree_owner() {
	local worktree_path="$1"
	local branch="$2"
	local task_id="$3"
	local session_id="$4"
	local batch_id="${5:-}"
	local owner_pid="$$"

	if ! bash -c 'source "$1"; register_worktree "$2" "$3" --task "$4" --session "$5" --batch "$6" --owner-pid "$7"' \
		_ "${TEST_SCRIPT_DIR}/../shared-constants.sh" "$worktree_path" "$branch" "$task_id" "$session_id" "$batch_id" "$owner_pid"; then
		return 1
	fi
	return 0
}

read_test_worktree_owner() {
	local worktree_path="$1"
	if ! bash -c 'source "$1"; check_worktree_owner "$2"' \
		_ "${TEST_SCRIPT_DIR}/../shared-constants.sh" "$worktree_path"; then
		return 1
	fi
	return 0
}

read_test_worktree_owner_snapshot() {
	local worktree_path="$1"
	if ! bash -c 'source "$1"; check_worktree_owner_snapshot "$2"' \
		_ "${TEST_SCRIPT_DIR}/../shared-constants.sh" "$worktree_path"; then
		return 1
	fi
	return 0
}

test_dispatch_uses_linked_pr_branch_worktree() {
	setup_test_env
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	local expected_path="${TEST_ROOT}/worktrees/repo-pr1-review-feature-review-${TEST_HEAD_OID_1:0:12}"
	if [[ -d "$expected_path" ]] &&
		grep -Fq "add feature/review ${expected_path} --base ${TEST_HEAD_OID_1} --issue 1" "$WORKTREE_HELPER_LOG" 2>/dev/null &&
		grep -Fq "$expected_path" "$HEADLESS_ARGS_CAPTURE" 2>/dev/null &&
		grep -Fxq "$expected_path" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fq "Local repo path: ${expected_path}" "$HEADLESS_PROMPT_CAPTURE" 2>/dev/null; then
		print_result "dispatch creates and uses linked PR branch worktree" 0
	else
		print_result "dispatch creates and uses linked PR branch worktree" 1 "expected=${expected_path}"
	fi
	teardown_test_env
	return 0
}

test_dispatch_fetches_head_from_linked_worktree_context() {
	local expected_fetch_cwd=""

	setup_test_env
	export STUB_REMOTE_HEAD_INITIAL="missing"
	export STUB_GIT_CANONICAL_FETCH_FAIL="true"
	expected_fetch_cwd=$(cd "${TEST_ROOT}/fetch-worktree" && pwd -P)
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	if [[ -s "$HEADLESS_LOG" ]] &&
		grep -Fxq "$expected_fetch_cwd" "$GIT_FETCH_CWD_LOG" 2>/dev/null &&
		! grep -Fxq "$GIT_CANONICAL_REPO_PATH" "$GIT_FETCH_CWD_LOG" 2>/dev/null; then
		print_result "dispatch fetches a missing PR head from linked-worktree context" 0
	else
		print_result "dispatch fetches a missing PR head from linked-worktree context" 1 \
			"headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0), fetch_cwds=$(tr '\n' ';' <"$GIT_FETCH_CWD_LOG" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_bootstraps_fetch_context_without_linked_worktree() {
	setup_test_env
	export STUB_REMOTE_HEAD_INITIAL="missing"
	rm -rf "${TEST_ROOT}/fetch-worktree"
	: >"$GIT_WORKTREE_REGISTRY"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	if [[ -s "$HEADLESS_LOG" ]] &&
		grep -Eq "${TEST_ROOT}/worktrees/\\.repo-fetch-[0-9]+" "$GIT_FETCH_CWD_LOG" 2>/dev/null &&
		! compgen -G "${TEST_ROOT}/worktrees/.repo-fetch-*" >/dev/null; then
		print_result "dispatch bootstraps and removes a linked fetch context" 0
	else
		print_result "dispatch bootstraps and removes a linked fetch context" 1 \
			"headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0), fetch_cwds=$(tr '\n' ';' <"$GIT_FETCH_CWD_LOG" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_exports_worktree_ownership_context() {
	setup_test_env
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	if grep -Fxq 'WORKER_ISSUE_NUMBER=1' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq 'WORKER_NO_EXIT_PUSH=1' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq 'AIDEVOPS_ALLOW_WORKER_WORKTREE_OWNER_TRANSFER=' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq 'AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE=continuation' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Eq '^AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID=[0-9]+$' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq 'AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION=dispatch-precreate-1' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq 'AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK=1' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Eq '^AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT=.+$' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Eq '^AIDEVOPS_WORKTREE_EXPECTED_OWNER_PROCESS_START=.+$' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq 'AIDEVOPS_PR_REPAIR_NUMBER=1' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq "AIDEVOPS_PR_REPAIR_HEAD_SHA=${TEST_HEAD_OID_1}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq 'AIDEVOPS_PR_REPAIR_HEAD_REF=feature/review' "$HEADLESS_ENV_CAPTURE" 2>/dev/null; then
		print_result "dispatch exports exact owner-transfer and exact-head context" 0
	else
		print_result "dispatch exports exact owner-transfer and exact-head context" 1 "env=$(tr '\n' ';' <"$HEADLESS_ENV_CAPTURE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_registers_created_worktree_as_transferable_precreate_owner() {
	local expected_path=""
	local initial_owner_info="" owner_info=""
	local initial_owner_pid="" initial_owner_session="" initial_owner_batch="" initial_owner_task="" initial_owner_created_at=""
	local owner_pid="" owner_session="" owner_batch="" owner_task="" owner_created_at="" owner_process_start=""

	setup_test_env
	export STUB_WORKTREE_REGISTER_OWNER="true"
	export STUB_WORKTREE_OWNER_PID="$$"
	export STUB_WORKTREE_OWNER_SESSION=""
	expected_path="${TEST_ROOT}/worktrees/repo-pr1-review-feature-review-${TEST_HEAD_OID_1:0:12}"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	initial_owner_info=$(<"$WORKTREE_CREATED_OWNER_CAPTURE")
	IFS='|' read -r initial_owner_pid initial_owner_session initial_owner_batch initial_owner_task initial_owner_created_at <<<"$initial_owner_info"
	owner_info=$(read_test_worktree_owner_snapshot "$expected_path" 2>/dev/null || true)
	IFS='|' read -r owner_pid owner_session owner_batch owner_task owner_created_at owner_process_start <<<"$owner_info"
	if [[ "$initial_owner_pid" == "$$" && -z "$initial_owner_session" && "$initial_owner_task" == "1" && -n "$initial_owner_created_at" ]] &&
		[[ "$owner_pid" =~ ^[0-9]+$ && "$owner_pid" != "$initial_owner_pid" && "$owner_session" == "dispatch-precreate-1" && "$owner_task" == "1" && -n "$owner_created_at" ]] &&
		grep -Fxq "AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID=${owner_pid}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq "AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT=${owner_created_at}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq "AIDEVOPS_WORKTREE_EXPECTED_OWNER_PROCESS_START=${owner_process_start}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null; then
		print_result "dispatch atomically registers a created worktree as an exact transferable owner" 0
	else
		print_result "dispatch atomically registers a created worktree as an exact transferable owner" 1 \
			"initial_owner=${initial_owner_info}, owner=${owner_info}, env=$(tr '\n' ';' <"$HEADLESS_ENV_CAPTURE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_preserves_reused_same_task_owner_snapshot() {
	local existing_path=""
	local owner_before="" owner_after=""
	local owner_pid="" owner_session="" owner_batch="" owner_task="" owner_created_at="" owner_process_start=""

	setup_test_env
	existing_path="${TEST_ROOT}/existing-review-worktree"
	mkdir -p "$existing_path"
	printf '%s\t%s\t%s\n' "$existing_path" 'feature/review' "$TEST_HEAD_OID_1" >"$GIT_WORKTREE_REGISTRY"
	register_test_worktree_owner "$existing_path" 'feature/review' '1' 'existing-review-session' 'existing-review-batch'
	owner_before=$(read_test_worktree_owner_snapshot "$existing_path")
	IFS='|' read -r owner_pid owner_session owner_batch owner_task owner_created_at owner_process_start <<<"$owner_before"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	owner_after=$(read_test_worktree_owner_snapshot "$existing_path")
	if [[ "$owner_after" == "$owner_before" ]] &&
		grep -Fxq 'AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE=continuation' "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq "AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID=${owner_pid}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq "AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION=${owner_session}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq "AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH=${owner_batch}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq "AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK=${owner_task}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq "AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT=${owner_created_at}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		grep -Fxq "AIDEVOPS_WORKTREE_EXPECTED_OWNER_PROCESS_START=${owner_process_start}" "$HEADLESS_ENV_CAPTURE" 2>/dev/null &&
		! grep -q '^add ' "$WORKTREE_HELPER_LOG" 2>/dev/null; then
		print_result "dispatch preserves a reused same-task owner for exact continuation transfer" 0
	else
		print_result "dispatch preserves a reused same-task owner for exact continuation transfer" 1 \
			"before=${owner_before}, after=${owner_after}, env=$(tr '\n' ';' <"$HEADLESS_ENV_CAPTURE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_rejects_reused_other_task_owner() {
	local existing_path=""
	local owner_before="" owner_after=""
	local state_file=""

	setup_test_env
	existing_path="${TEST_ROOT}/existing-review-worktree"
	state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	mkdir -p "$existing_path"
	printf '%s\t%s\t%s\n' "$existing_path" 'feature/review' "$TEST_HEAD_OID_1" >"$GIT_WORKTREE_REGISTRY"
	register_test_worktree_owner "$existing_path" 'feature/review' '999' 'unrelated-session'
	owner_before=$(read_test_worktree_owner "$existing_path")
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo" || true
	owner_after=$(read_test_worktree_owner "$existing_path")
	if [[ ! -s "$HEADLESS_LOG" && "$owner_after" == "$owner_before" ]] &&
		grep -q '^blocker_reason=review_worktree_owned_by_other_task$' "$state_file" 2>/dev/null; then
		print_result "dispatch rejects a reused worktree owned by another task" 0
	else
		print_result "dispatch rejects a reused worktree owned by another task" 1 \
			"before=${owner_before}, after=${owner_after}, state=$(tr '\n' ';' <"$state_file" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_rejects_reused_unverified_owner() {
	local existing_path=""
	local owner_before="" owner_after=""
	local state_file=""

	setup_test_env
	existing_path="${TEST_ROOT}/existing-review-worktree"
	state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	mkdir -p "$existing_path"
	printf '%s\t%s\t%s\n' "$existing_path" 'feature/review' "$TEST_HEAD_OID_1" >"$GIT_WORKTREE_REGISTRY"
	register_test_worktree_owner "$existing_path" 'feature/review' '' 'unverified-session'
	owner_before=$(read_test_worktree_owner "$existing_path")
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo" || true
	owner_after=$(read_test_worktree_owner "$existing_path")
	if [[ ! -s "$HEADLESS_LOG" && "$owner_after" == "$owner_before" ]] &&
		grep -q '^blocker_reason=review_worktree_ownership_unverified$' "$state_file" 2>/dev/null; then
		print_result "dispatch rejects a reused worktree with unverified ownership" 0
	else
		print_result "dispatch rejects a reused worktree with unverified ownership" 1 \
			"before=${owner_before}, after=${owner_after}, state=$(tr '\n' ';' <"$state_file" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_blocks_cross_repository_head() {
	setup_test_env
	export STUB_PR_REPOSITORY_MODE="cross"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	local outcome_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.outcome"
	local old_epoch=""
	old_epoch="$(($(date +%s) - 4000))"
	expire_state_dispatch_time "$state_file" "$old_epoch"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	if [[ ! -s "$HEADLESS_LOG" ]] &&
		grep -q '^analysis_complete=true$' "$state_file" 2>/dev/null &&
		grep -q '^blocked_by=code$' "$state_file" 2>/dev/null &&
		grep -q '^maintainer_attention=true$' "$state_file" 2>/dev/null &&
		grep -q '^blocker_reason=cross_repository_head_unwritable$' "$state_file" 2>/dev/null &&
		[[ ! -f "$outcome_file" ]] &&
		grep -q 'analysis complete and blocked by code' "$LOGFILE" 2>/dev/null; then
		print_result "dispatch blocks an unwritable fork head without retrying" 0
	else
		print_result "dispatch blocks an unwritable fork head without retrying" 1 "state=$(tr '\n' ';' <"$state_file" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_blocks_remote_head_drift() {
	setup_test_env
	export STUB_REMOTE_HEAD="$TEST_HEAD_OID_2"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ ! -s "$HEADLESS_LOG" ]] &&
		grep -q '^blocker_reason=pr_head_changed_during_dispatch$' "$state_file" 2>/dev/null &&
		! grep -q '^add ' "$WORKTREE_HELPER_LOG" 2>/dev/null; then
		print_result "dispatch blocks when the fetched branch no longer matches headRefOid" 0
	else
		print_result "dispatch blocks when the fetched branch no longer matches headRefOid" 1 "state=$(tr '\n' ';' <"$state_file" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_fast_forwards_clean_behind_existing_worktree() {
	setup_test_env
	local existing_path="${TEST_ROOT}/existing-review-worktree"
	mkdir -p "$existing_path"
	printf '%s\t%s\t%s\n' "$existing_path" 'feature/review' "$TEST_HEAD_OID_2" >"$GIT_WORKTREE_REGISTRY"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	local reconciled_head=""
	reconciled_head=$(while IFS=$'\t' read -r path branch oid; do [[ "$path" == "$existing_path" ]] && printf '%s' "$oid"; done <"$GIT_WORKTREE_REGISTRY")
	if [[ -s "$HEADLESS_LOG" && "$reconciled_head" == "$TEST_HEAD_OID_1" ]] &&
		grep -Fq "fast-forwarded exclusively claimed review worktree from ${TEST_HEAD_OID_2} to verified PR head ${TEST_HEAD_OID_1}" "$LOGFILE" 2>/dev/null; then
		print_result "dispatch fast-forwards a clean behind existing review worktree" 0
	else
		print_result "dispatch fast-forwards a clean behind existing review worktree" 1 \
			"head=${reconciled_head:-<empty>} headless=$(wc -c <"$HEADLESS_LOG" 2>/dev/null || printf 0) log=$(tr '\n' ';' <"$LOGFILE" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_preserves_and_recovers_dirty_existing_worktree_reconcile() {
	setup_test_env
	export STUB_GIT_WORKTREE_DIRTY=true
	local existing_path="${TEST_ROOT}/existing-review-worktree-dirty"
	export STUB_DIRTY_BACKUP_REPO="$existing_path"
	mkdir -p "$existing_path"
	printf '%s\t%s\t%s\n' "$existing_path" 'feature/review' "$TEST_HEAD_OID_2" >"$GIT_WORKTREE_REGISTRY"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	wait_for_headless_log || true
	local reconciled_head=""
	reconciled_head=$(while IFS=$'\t' read -r path branch oid; do [[ "$path" == "$existing_path" ]] && printf '%s' "$oid"; done <"$GIT_WORKTREE_REGISTRY")
	if [[ -s "$HEADLESS_LOG" && "$reconciled_head" == "$TEST_HEAD_OID_1" && -f "$DIRTY_BACKUP_CLEANED" ]] &&
		grep -q '^OWNER_TASK=1$' "$DIRTY_BACKUP_OWNER_LOG" 2>/dev/null &&
		grep -q '^OWNER_SESSION=dispatch-precreate-1$' "$DIRTY_BACKUP_OWNER_LOG" 2>/dev/null &&
		grep -q '^backup .*--machine$' "$DIRTY_BACKUP_LOG" 2>/dev/null &&
		grep -q '^verify ' "$DIRTY_BACKUP_LOG" 2>/dev/null &&
		grep -q '^matches ' "$DIRTY_BACKUP_LOG" 2>/dev/null &&
		grep -q '^clean .*--confirm CLEAN_VERIFIED_DIRTY_WORKTREE_BACKUP$' "$DIRTY_BACKUP_LOG" 2>/dev/null &&
		grep -q 'preserved and cleaned exclusively claimed dirty review worktree (backup=test-dirty-backup)' "$LOGFILE" 2>/dev/null; then
		print_result "dispatch preserves and recovers an exclusively claimed dirty review worktree" 0
	else
		print_result "dispatch preserves and recovers an exclusively claimed dirty review worktree" 1 \
			"head=${reconciled_head:-<empty>} backup=$(tr '\n' ';' <"$DIRTY_BACKUP_LOG" 2>/dev/null || printf '') owner=$(tr '\n' ';' <"$DIRTY_BACKUP_OWNER_LOG" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_fails_closed_when_dirty_backup_no_longer_matches() {
	setup_test_env
	export STUB_GIT_WORKTREE_DIRTY=true
	export STUB_DIRTY_BACKUP_MATCH_FAIL=true
	local existing_path="${TEST_ROOT}/existing-review-worktree-dirty-mismatch"
	export STUB_DIRTY_BACKUP_REPO="$existing_path"
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	local outcome_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.outcome"
	local outcome_id="" outcome_reason="" retry_class=""
	mkdir -p "$existing_path"
	printf '%s\t%s\t%s\n' "$existing_path" 'feature/review' "$TEST_HEAD_OID_2" >"$GIT_WORKTREE_REGISTRY"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	outcome_id=$(read_state_value "$state_file" outcome_id)
	outcome_reason=$(awk -F= '$1 == "reason" { print $2 }' "$outcome_file" 2>/dev/null || true)
	retry_class=$(awk -F= '$1 == "retry_class" { print $2 }' "$outcome_file" 2>/dev/null || true)
	if [[ ! -s "$HEADLESS_LOG" && ! -f "$DIRTY_BACKUP_CLEANED" ]] &&
		grep -q '^blocker_reason=existing_review_worktree_backup_mismatch$' "$state_file" 2>/dev/null &&
		[[ -n "$outcome_id" ]] &&
		grep -Fxq "outcome_id=${outcome_id}" "$outcome_file" 2>/dev/null &&
		[[ "$outcome_reason" == "existing_review_worktree_backup_mismatch" && "$retry_class" == "retryable_infrastructure" ]] &&
		! grep -q '^clean ' "$DIRTY_BACKUP_LOG" 2>/dev/null; then
		print_result "dispatch fails closed when preserved dirty state no longer matches" 0
	else
		print_result "dispatch fails closed when preserved dirty state no longer matches" 1 \
			"state=$(tr '\n' ';' <"$state_file" 2>/dev/null || printf ''), outcome=$(tr '\n' ';' <"$outcome_file" 2>/dev/null || printf ''), backup=$(tr '\n' ';' <"$DIRTY_BACKUP_LOG" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_rejects_diverged_existing_worktree_reconcile() {
	setup_test_env
	export STUB_GIT_DIVERGED=true
	local existing_path="${TEST_ROOT}/existing-review-worktree-diverged"
	mkdir -p "$existing_path"
	printf '%s\t%s\t%s\n' "$existing_path" 'feature/review' "$TEST_HEAD_OID_2" >"$GIT_WORKTREE_REGISTRY"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ ! -s "$HEADLESS_LOG" ]] &&
		grep -q '^blocker_reason=existing_review_worktree_diverged$' "$state_file" 2>/dev/null; then
		print_result "dispatch rejects a diverged existing review worktree" 0
	else
		print_result "dispatch rejects a diverged existing review worktree" 1 \
			"state=$(tr '\n' ';' <"$state_file" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_rejects_live_owned_existing_worktree_reconcile() {
	setup_test_env
	local existing_path="${TEST_ROOT}/existing-review-worktree-live"
	mkdir -p "$existing_path"
	printf '%s\t%s\t%s\n' "$existing_path" 'feature/review' "$TEST_HEAD_OID_2" >"$GIT_WORKTREE_REGISTRY"
	register_test_worktree_owner "$existing_path" "feature/review" "1" "existing-review-session" || true
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ ! -s "$HEADLESS_LOG" ]] &&
		grep -q '^blocker_reason=existing_review_worktree_live_owner$' "$state_file" 2>/dev/null; then
		print_result "dispatch never mutates a mismatched worktree with a live owner" 0
	else
		print_result "dispatch never mutates a mismatched worktree with a live owner" 1 \
			"state=$(tr '\n' ';' <"$state_file" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}

test_dispatch_cleans_up_failed_exact_head_worktree() {
	setup_test_env
	export STUB_WORKTREE_ACTUAL_HEAD="$TEST_HEAD_OID_2"
	local expected_path="${TEST_ROOT}/worktrees/repo-pr1-review-feature-review-${TEST_HEAD_OID_1:0:12}"
	$SCANNER dispatch owner/repo "${TEST_ROOT}/repo"
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	if [[ ! -e "$expected_path" && ! -s "$HEADLESS_LOG" ]] &&
		grep -Fq "remove ${expected_path} --force" "$WORKTREE_HELPER_LOG" 2>/dev/null &&
		grep -q '^blocker_reason=review_worktree_exact_head_verification_failed$' "$state_file" 2>/dev/null; then
		print_result "dispatch cleans up a newly created worktree that fails exact-head verification" 0
	else
		print_result "dispatch cleans up a newly created worktree that fails exact-head verification" 1 "state=$(tr '\n' ';' <"$state_file" 2>/dev/null || printf '')"
	fi
	teardown_test_env
	return 0
}
