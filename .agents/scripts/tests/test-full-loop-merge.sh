#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression suite for merge transport, readiness, and prospective TODO safety.
# Shared harness and merge cases live in the cases module; planning cases keep
# checkout-free publication and isolated prospective-merge fixtures together.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# shellcheck source=./test-full-loop-merge-cases.sh
# shellcheck disable=SC1091  # Sibling test module resolved at runtime.
source "${SCRIPT_DIR}/test-full-loop-merge-cases.sh"
# shellcheck source=./test-full-loop-merge-planning.sh
# shellcheck disable=SC1091  # Sibling test module resolved at runtime.
source "${SCRIPT_DIR}/test-full-loop-merge-planning.sh"

main() {
	trap teardown_test_env EXIT
	setup_test_env

	echo "=== Admin merge fallback signaling tests (t2247) ==="
	echo ""

	test_admin_fallback_signals
	test_admin_fallback_native_review_handoff
	test_admin_timeout_reconciles_without_replay
	test_admin_fallback_blocks_needs_maintainer_review_issue
	test_admin_fallback_blocks_pending_required_checks
	test_explicit_admin_no_signaling
	test_other_error_no_fallback
	test_late_review_blocks_every_merge_transport
	test_graphql_rate_limit_rest_fallback
	test_graphql_rate_limit_cmd_merge_phase_autofile
	test_graphql_rate_limit_auto_no_rest_fallback
	test_review_gate_failure_blocks_rest_fallback
	test_cooldown_gate_failure_reports_cooldown
	test_local_admission_gate_failure_reports_retry_deadline
	test_bounded_local_admission_recovery
	test_local_deferral_survives_context_resolution
	test_exact_check_deferral_preserves_retry_deadline
	test_auto_review_required_interactive_admin_fallback
	test_auto_review_required_admin_rejection_handoff
	test_auto_review_required_headless_no_admin_fallback
	test_stale_cache_401_retry
	test_auth_401_detection_avoids_numeric_false_positives
	test_pr_ready_accepts_prefetched_json
	test_pr_ready_blocks_nonpassing_rollup
	test_verified_head_lookup_failure_is_not_reported_as_drift
	test_post_merge_stale_evidence_retries_fresh_read
	test_post_merge_unmerged_evidence_fails_closed
	test_post_merge_api_indeterminate_fails_closed
	test_wip_draft_takeover_uses_reviewed_pr_title
	test_gh_prefixed_feature_inherits_commit_category
	test_gh_prefixed_prose_without_evidence_is_not_guessed
	test_invalid_squash_title_blocks_before_merge
	test_non_squash_skips_subject_override
	test_checkout_free_publication_readiness_handoff
	test_todo_duplicate_report_large_baseline
	test_timeout_sec_fallback_preserves_stdin
	test_prospective_todo_merge_guard
	test_prospective_todo_live_fetch_guard
	test_prospective_todo_crisscross_fetch_guard

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
