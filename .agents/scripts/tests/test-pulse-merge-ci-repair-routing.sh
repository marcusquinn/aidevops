#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for CI repair routing from the deterministic merge pass.
# A red/pending trusted PR must pass the normal merge gates first, then route
# exactly one repair action for the same PR/head SHA instead of silently
# accumulating in the open PR backlog.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"
FINALIZER_SCRIPT="${SCRIPT_DIR}/../pulse-merge-feedback-finalizer.sh"
FEEDBACK_REVIEW_SCRIPT="${SCRIPT_DIR}/../pulse-merge-feedback-review.sh"
FEEDBACK_CI_REPAIR_SCRIPT="${SCRIPT_DIR}/../pulse-merge-feedback-ci-repair.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""
TEST_PR_HEAD_SHA=""

# shellcheck source=./test-pulse-merge-ci-repair-routing-mocks.sh
# shellcheck disable=SC1091 # Sibling module resolved at runtime via SCRIPT_DIR.
source "${SCRIPT_DIR}/test-pulse-merge-ci-repair-routing-mocks.sh"
# shellcheck source=./test-pulse-merge-ci-repair-routing-cases.sh
# shellcheck disable=SC1091 # Sibling module resolved at runtime via SCRIPT_DIR.
source "${SCRIPT_DIR}/test-pulse-merge-ci-repair-routing-cases.sh"

main() {
	test_red_pr_passes_gates_before_repair_route
	test_rebase_success_defers_ci_repair_route
	test_ci_drift_ledger_routing
	test_ci_drift_unavailable_classification
	test_ci_drift_context_names
	test_converged_changes_requested_prefers_strict_rebase_before_ci_repair
	test_converged_changes_requested_routes_terminal_ci_after_rebase_noop
	test_converged_changes_requested_never_falls_through_to_merge
	test_ci_rebase_only_gate_stops_before_review_bot_boundary
	test_ci_repair_only_gate_requires_review_bot_boundary
	test_preflight_terminal_blocker_routes_supplied_evidence
	test_changes_requested_unknown_routes_before_mergeable_skip
	test_rest_missing_review_decision_refreshes_before_ci_route
	test_coderabbit_nits_ok_dismissed_once_before_late_gate
	test_changes_requested_empty_labels_refresh_current_metadata
	test_ci_repair_resolves_authenticated_runner_identity
	test_ci_repair_dedupes_identical_evidence_for_same_head
	test_ci_repair_dedupes_changed_evidence_for_same_head
	test_ci_repair_respects_live_legacy_lease
	test_ci_repair_session_keys_are_repository_scoped
	test_ci_repair_worktree_paths_are_repository_scoped
	test_ci_repair_fetches_absent_head_through_scratch_context
	test_ci_repair_fetches_absent_head_through_sibling_worktree
	test_ci_repair_rejects_head_superseded_by_descendant
	test_ci_feedback_skips_pending_only_checks
	test_ci_feedback_skips_mixed_pending_pass_checks
	test_ci_feedback_classifies_qlty_evidence_roles
	test_ci_feedback_filters_qlty_billing_only
	test_ci_repair_archives_trusted_terminal_outcome
	test_ci_feedback_emits_terminal_failure_with_conclusion_and_url
	test_ci_repair_uses_merge_required_contexts
	test_ci_feedback_preserves_supplied_nonrequired_baseline_evidence
	test_ci_feedback_defers_when_head_changes_during_collection
	test_ci_feedback_defers_without_initial_head_snapshot
	test_ci_feedback_skips_infra_timeout_checks
	test_ci_feedback_skips_failed_check_with_exit_143_log
	test_ci_feedback_skips_registry_rate_limit_failure
	test_ci_feedback_skips_dockerhub_pull_rate_limit_failure
	test_ci_feedback_skips_github_api_rate_limit_failure
	test_ci_feedback_skips_billing_blocked_check
	test_ci_feedback_keeps_zero_step_check_without_billing_annotation
	test_ci_feedback_owner_arrives_during_routing
	test_ci_repair_preserves_pr_until_launch_retries_exhausted
	test_ci_repair_fallback_preserves_non_closing_linkage
	test_ci_repair_recovers_one_stale_lease_then_exhausts
	test_ci_repair_consumes_abandoned_append_only_claim
	test_ci_repair_waits_for_prelock_startup_before_retry
	test_ci_feedback_skips_advisory_failure_when_required_clean
	test_missing_merge_gate_dependency_fails_harness

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
