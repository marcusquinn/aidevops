#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Isolated feedback-routing tests. Keep the original entry point and test order;
# the sourced modules only define the stateful gh fixture and test cases.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-feedback.sh"

# shellcheck source=./test-pulse-merge-fix-worker-dispatch-mocks.sh
# shellcheck disable=SC1091 # Sibling module resolved through SCRIPT_DIR at runtime
source "${SCRIPT_DIR}/test-pulse-merge-fix-worker-dispatch-mocks.sh"
# shellcheck source=./test-pulse-merge-fix-worker-dispatch-cases.sh
# shellcheck disable=SC1091 # Sibling module resolved through SCRIPT_DIR at runtime
source "${SCRIPT_DIR}/test-pulse-merge-fix-worker-dispatch-cases.sh"

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi
	if [[ $# -gt 0 ]]; then
		run_selected_tests "$@"
		return $?
	fi

	test_build_section_includes_marker_and_citations
	test_build_section_bounds_total_output
	test_build_section_empty_when_no_content
	test_dispatch_preserves_ready_changed_head_and_rerequests_reviewer
	test_dispatch_routes_when_review_threads_remain_unresolved
	test_dispatch_routes_when_required_checks_fail
	test_dispatch_routes_body_only_with_unrelated_missing_commit_id
	test_dispatch_defers_while_required_checks_are_pending
	test_dispatch_defers_when_required_checks_are_cancelled
	test_dispatch_requests_only_missing_trusted_reviewers
	test_dispatch_defers_head_drift_before_reviewer_mutation
	test_dispatch_preserves_when_threads_converge_at_preclose
	test_dispatch_preserves_ready_pr_without_required_checks
	test_dispatch_defers_unverified_reviewer_mutation
	test_dispatch_defers_multilabel_ownership_blocker
	test_dispatch_defers_when_worker_origin_disappears
	test_dispatch_appends_to_issue_body_and_closes_pr
	test_dispatch_wraps_paginated_feedback_reads
	test_paginated_feedback_pages_are_merged
	test_dispatch_timeout_fails_open_without_routing_empty_feedback
	test_dispatch_preserves_ambiguous_legacy_marker
	test_dispatch_retries_after_transition_failure
	test_dispatch_preserves_maintainer_hold_racing_transition
	test_dispatch_retries_after_close_failure
	test_dispatch_reopens_when_close_verification_fails
	test_dispatch_keeps_closed_after_completion_write_deferral
	test_dispatch_reopens_after_nontransient_completion_write_failure
	test_dispatch_recovers_terminal_label_failure
	test_dispatch_preserves_human_readded_hold_generation
	test_dispatch_restores_hold_when_generation_changes_before_transition
	test_terminal_label_cleanup_restores_changed_hold_generation
	test_dispatch_restores_hold_readded_during_clear
	test_dispatch_restores_hold_after_clear_transition_failure
	test_feedback_route_accepts_bot_actor_identity
	test_dispatch_holds_on_head_drift
	test_dispatch_holds_when_ownership_changes_during_transition
	test_dispatch_holds_incomplete_prior_ci_head_evidence
	test_dispatch_supersedes_completed_automation_ci_head_evidence
	test_dispatch_does_not_transition_started_merged_route
	test_terminal_guard_rechecks_current_label
	test_dispatch_holds_reopened_completed_route
	test_dispatch_skips_identical_evidence_on_same_head
	test_dispatch_skips_identical_evidence_on_changed_head
	test_dispatch_routes_edited_evidence_on_same_head
	test_dispatch_dry_run_has_no_writes
	test_conflict_dispatch_uses_shared_finalizer
	test_dispatch_noop_when_no_substantive_feedback
	test_dispatch_noop_on_invalid_inputs
	test_dispatch_clears_in_progress_labels_as_fallback
	test_ci_dispatch_dedupes_by_pr_head_marker
	test_feedback_release_reconciles_cross_runner_duplicates
	test_dispatch_skips_body_edit_on_issue_view_failure

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
