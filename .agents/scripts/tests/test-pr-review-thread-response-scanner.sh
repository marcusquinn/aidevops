#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)/pr-review-thread-response-scanner.sh"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0
export TEST_HEAD_OID_1="1111111111111111111111111111111111111111"
export TEST_HEAD_OID_2="2222222222222222222222222222222222222222"

# Load definitions before running tests; modules never execute test cases.
# shellcheck source=./test-pr-review-thread-response-scanner-fixtures.sh
# shellcheck disable=SC1091 # Sibling module resolved via TEST_SCRIPT_DIR at runtime
source "${TEST_SCRIPT_DIR}/test-pr-review-thread-response-scanner-fixtures.sh"
# shellcheck source=./test-pr-review-thread-response-scanner-worktrees.sh
# shellcheck disable=SC1091 # Sibling module resolved via TEST_SCRIPT_DIR at runtime
source "${TEST_SCRIPT_DIR}/test-pr-review-thread-response-scanner-worktrees.sh"
# shellcheck source=./test-pr-review-thread-response-scanner-dispatch.sh
# shellcheck disable=SC1091 # Sibling module resolved via TEST_SCRIPT_DIR at runtime
source "${TEST_SCRIPT_DIR}/test-pr-review-thread-response-scanner-dispatch.sh"
# shellcheck source=./test-pr-review-thread-response-scanner-lifecycle.sh
# shellcheck disable=SC1091 # Sibling module resolved via TEST_SCRIPT_DIR at runtime
source "${TEST_SCRIPT_DIR}/test-pr-review-thread-response-scanner-lifecycle.sh"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

test_scan_pr_bounds_hanging_graphql_read() {
	setup_test_env
	export STUB_THREADS_MODE="hang"
	export STUB_HANG_SECONDS=5
	export AIDEVOPS_GH_READ_TIMEOUT=1
	local started_at="" elapsed=0 scan_rc=0
	started_at=$(date +%s)
	$SCANNER scan-pr owner/repo 1 >/dev/null 2>&1 || scan_rc=$?
	elapsed=$(($(date +%s) - started_at))
	if [[ "$scan_rc" -eq 2 && "$elapsed" -le 3 ]]; then
		print_result "scan-pr bounds a hanging GraphQL review-thread read" 0
	else
		print_result "scan-pr bounds a hanging GraphQL review-thread read" 1 "rc=${scan_rc}, elapsed=${elapsed}s"
	fi
	unset AIDEVOPS_GH_READ_TIMEOUT
	teardown_test_env
	return 0
}

test_release_label_is_rechecked_before_launch() {
	local label_result="" result=0
	for label_result in release lookup-failed; do
		setup_test_env
		export TEST_ROOT
		export STUB_PR_VIEW="Release"$'\t'"chore/release-v1.2.3-provenance"$'\t'"${TEST_HEAD_OID_1}"$'\t'"worker-bot"
		printf '%s\n' "$label_result" >"${TEST_ROOT}/label-result"
		mv "${TEST_ROOT}/bin/gh" "${TEST_ROOT}/bin/gh-original"
		cat >"${TEST_ROOT}/bin/gh" <<'GH_RELEASE_RACE'
#!/usr/bin/env bash
if [[ "$1" == pr && "$2" == view && "$*" == *"--json labels"* ]]; then
	if [[ ! -f "${TEST_ROOT}/label-checked" ]]; then
		: >"${TEST_ROOT}/label-checked"
		exit 0
	fi
	: >"${TEST_ROOT}/label-rechecked"
	[[ "$(<"${TEST_ROOT}/label-result")" == release ]] || exit 1
	printf 'release\n'
	exit 0
fi
exec "${TEST_ROOT}/bin/gh-original" "$@"
GH_RELEASE_RACE
		chmod +x "${TEST_ROOT}/bin/gh"
		result=0
		$SCANNER dispatch-pr owner/repo "${TEST_ROOT}/repo" 1 || result=$?
		if [[ "$result" -ne 0 && -f "${TEST_ROOT}/label-rechecked" && ! -s "$HEADLESS_LOG" ]]; then
			print_result "Prelaunch release-label recheck blocks ${label_result}" 0
		else
			print_result "Prelaunch release-label recheck blocks ${label_result}" 1 "rc=${result}; log=$(<"$LOGFILE")"
		fi
		teardown_test_env
	done
	return 0
}

test_protected_release_dispatch_is_skipped() {
	setup_test_env
	export STUB_PR_LIST="1"$'\t'"Release"$'\t'"false"$'\t'"origin:worker,release"$'\t'"chore/release-v1.2.3-provenance"$'\t'"${TEST_HEAD_OID_1}"$'\t'"worker-bot"
	export STUB_PR_VIEW="Release"$'\t'"chore/release-v1.2.3-provenance"$'\t'"${TEST_HEAD_OID_1}"$'\t'"worker-bot"$'\t'"release"
	local output="" result=0
	output=$($SCANNER scan owner/repo)
	$SCANNER dispatch-pr owner/repo "$TEST_ROOT" 1 || result=$?
	if [[ -z "$output" && "$result" -eq 11 ]] &&
		grep -q 'scan: owner/repo#1 skipped — protected release PR' "$LOGFILE" &&
		grep -q 'dispatch-pr: owner/repo#1 skipped — protected release PR' "$LOGFILE"; then
		print_result "Protected release PR is skipped by scan and dispatch-pr" 0
	else
		print_result "Protected release PR is skipped by scan and dispatch-pr" 1 "rc=${result}, output=${output}"
	fi
	unset STUB_PR_LIST STUB_PR_VIEW
	teardown_test_env
	return 0
}

main_mutations() {
	test_reply_and_resolve_use_graphql_mutations
	test_reply_rejects_impossible_mutation_responses
	test_resolve_rejects_impossible_mutation_responses
	test_reply_auto_prepends_thread_author
	test_reply_sends_author_mention_body_as_raw_field
	test_reply_does_not_double_prepend_thread_author
	test_reply_falls_back_when_thread_author_missing
	test_reply_skips_duplicate_marker
	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_rereview() {
	test_mark_complete_requests_trusted_rereview_once_per_changed_head
	test_mark_complete_skips_rereview_without_changed_head
	test_mark_complete_fails_closed_on_unknown_reviewer_identity
	test_mark_complete_defers_rereview_until_all_threads_converge
	test_mark_complete_preserves_incomplete_state_when_rereview_write_fails
	test_mark_blocked_never_requests_rereview
	test_mark_blocked_publishes_continuation_finding
	return 0
}

main_scan() {
	test_protected_release_dispatch_is_skipped
	test_release_label_is_rechecked_before_launch
	test_scan_finds_unresolved_bot_thread
	test_scan_skips_draft_prs
	test_scan_includes_outdated_unresolved_threads
	test_scan_fails_closed_without_graphql_cost
	test_scan_pr_excludes_human_threads_by_default
	test_scan_pr_can_include_human_threads_with_opt_in
	return 0
}

main() {
	main_scan
	test_dispatch_launches_worker_and_writes_state
	test_dispatch_batches_prompt_and_preserves_full_state
	test_dispatch_defaults_invalid_batch_limit
	test_dispatch_resolves_worker_github_login
	test_dispatch_uses_graphql_worker_login_fallback
	test_dispatch_fails_closed_without_authenticated_worker_login
	test_dispatch_pr_defers_at_atomic_global_capacity
	test_dispatch_repo_shares_atomic_global_capacity
	test_dispatch_preserves_expired_matching_live_capacity_lease
	test_dispatch_removes_expired_pid_reused_capacity_lease
	test_dispatch_detaches_worker_from_parent_process_group
	test_dispatch_preserves_head_fields_when_labels_are_empty
	test_dispatch_uses_linked_pr_branch_worktree
	test_dispatch_fetches_head_from_linked_worktree_context
	test_dispatch_bootstraps_fetch_context_without_linked_worktree
	test_dispatch_exports_worktree_ownership_context
	test_dispatch_registers_created_worktree_as_transferable_precreate_owner
	test_dispatch_preserves_reused_same_task_owner_snapshot
	test_dispatch_rejects_reused_other_task_owner
	test_dispatch_rejects_reused_unverified_owner
	test_dispatch_blocks_cross_repository_head
	test_dispatch_blocks_remote_head_drift
	test_dispatch_fast_forwards_clean_behind_existing_worktree
	test_dispatch_preserves_and_recovers_dirty_existing_worktree_reconcile
	test_dispatch_fails_closed_when_dirty_backup_no_longer_matches
	test_dispatch_rejects_diverged_existing_worktree_reconcile
	test_dispatch_rejects_live_owned_existing_worktree_reconcile
	test_dispatch_cleans_up_failed_exact_head_worktree
	test_dispatch_prompt_includes_full_thread_command_signatures
	test_dispatch_prompt_uses_stable_deployed_scanner_path
	test_dispatch_prompt_mentions_graphql_only_thread_operations
	test_dispatch_prompt_requires_machine_readable_completion_state
	test_dispatch_prompt_requires_contract_v11_remediation_role_and_praise_only_resolution
	test_dispatch_prompt_requires_exactly_one_terminal_call
	test_dispatch_prompt_explains_shell_redirection_constraint
	test_dispatch_prompt_declares_precreated_worktree_contract
	test_dispatch_prompt_marks_dynamic_metadata_untrusted
	test_dispatch_prompt_includes_change_request_reviewer_comments
	test_dispatch_pr_launches_targeted_worker_with_human_opt_in
	test_dispatch_pr_reports_no_match_as_converged
	test_dispatch_pr_reports_fetch_failure_as_retryable
	test_dispatch_is_idempotent_for_same_fingerprint
	test_dispatch_preserves_immediate_worker_terminal_state
	test_dispatch_retries_zero_session_infrastructure_failure_after_short_cooldown
	test_dispatch_defers_zero_session_infrastructure_failure_during_short_cooldown
	test_dispatch_retries_session_bearing_typed_infrastructure_outcome
	test_dispatch_retries_legacy_auth_error_remediation_outcome
	test_dispatch_stops_on_typed_maintainer_gate_outcome
	test_dispatch_applies_bounded_infrastructure_circuit_breaker
	test_dispatch_preserves_full_cooldown_after_model_session
	test_dispatch_rejects_mismatched_or_future_outcomes
	test_dispatch_skips_mixed_fingerprint_during_inflight_window
	test_dispatch_escalates_repeated_same_fingerprint_without_worker_loop
	test_dispatch_retries_escalated_previous_worker_contract
	test_new_head_sha_resets_repeated_fingerprint_attempts
	test_mark_blocked_skips_same_fingerprint_without_retry
	test_dispatch_retries_stale_branch_validation_blocker_once
	test_dispatch_retries_stale_branch_unavailable_blocker_once
	test_dispatch_retries_transient_head_fetch_failure_once
	test_dispatch_retries_generic_infrastructure_launch_failure
	test_dispatch_does_not_repeat_branch_validation_recovery
	test_no_marker_retry_behavior_is_preserved
	test_old_state_file_without_completion_fields_still_retries
	test_mark_blocked_sanitizes_reason_and_details
	main_rereview
	test_dispatch_pr_skips_when_pr_lock_held
	test_dispatch_pr_reports_deduplicated_dispatch
	test_dispatch_pr_reports_active_worker_as_deferred
	test_dispatch_pr_reclaims_stale_lock
	test_dispatch_pr_reclaims_dead_young_lock
	test_dispatch_pr_reclaims_pid_reused_young_lock
	test_dispatch_pr_preserves_malformed_young_lock_until_age_fallback
	test_dispatch_pr_preserves_indeterminate_young_lock_until_age_fallback
	test_dispatch_reports_graphql_budget_exhaustion_when_scan_blind
	test_dispatch_reports_fetch_errors_when_scan_blind
	test_scan_pr_bounds_hanging_graphql_read
	test_dispatch_rotates_candidates_with_repo_cursor
	test_dispatch_stale_cursor_falls_back_to_original_order
	test_reply_and_resolve_use_graphql_mutations
	test_reply_rejects_impossible_mutation_responses
	test_resolve_rejects_impossible_mutation_responses
	test_reply_auto_prepends_thread_author
	test_reply_sends_author_mention_body_as_raw_field
	test_reply_does_not_double_prepend_thread_author
	test_reply_falls_back_when_thread_author_missing
	test_reply_skips_duplicate_marker

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

if [[ "${PRRTS_TEST_MUTATIONS_ONLY:-0}" == "1" ]]; then
	main_mutations "$@"
else
	main "$@"
fi
