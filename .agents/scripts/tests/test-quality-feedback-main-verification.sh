#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Quality Feedback Main-Branch Verification Tests -- Orchestrator
# =============================================================================
# Test orchestrator for quality-feedback-helper.sh main-branch verification.
# Sources sub-libraries for each test domain and runs all tests via main().
#
# Sub-libraries:
#   - test-quality-feedback-main-verification-verification.sh (snippet/finding)
#   - test-quality-feedback-main-verification-approval.sh (approval filter)
#   - test-quality-feedback-main-verification-scan.sh (scan_single_pr integration)
#
# Usage: bash test-quality-feedback-main-verification.sh
# shellcheck disable=SC1090,SC2016

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../quality-feedback-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

GH_RAW_CONTENT=""
GH_DIFF=""
GH_SUGGESTION=""
GH_DELETED=""
GH_LAST_CONTENT_ENDPOINT=""
GH_ISSUE_CREATE_COUNT=0
GH_CREATE_LOG=""
GH_API_LOG=""

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		[[ -n "$message" ]] && echo "  $message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

reset_mock_state() {
	GH_RAW_CONTENT=""
	GH_DIFF=""
	GH_SUGGESTION=""
	GH_DELETED=""
	GH_LAST_CONTENT_ENDPOINT=""
	GH_ISSUE_CREATE_COUNT=0
	GH_CREATE_LOG=$(mktemp)
	GH_API_LOG=$(mktemp)
	_QF_DEFAULT_BRANCH=""
	_QF_DEFAULT_BRANCH_REPO=""
	return 0
}

gh() {
	local command="$1"
	shift

	case "$command" in
	api)
		_mock_gh_api "$@"
		return $?
		;;
	label)
		return 0
		;;
	issue)
		_mock_gh_issue "$@"
		return $?
		;;
	pr)
		# GH#17916: _create_quality_debt_issues calls `gh pr view` to get the
		# PR author. Return empty JSON so is_maintainer_pr defaults to false.
		echo "{}"
		return 0
		;;
	esac

	echo "unexpected gh call: ${command}" >&2
	return 1
}

_mock_gh_api() {
	local endpoint=""

	while [[ $# -gt 0 ]]; do
		local token="$1"
		case "$1" in
		-H | --jq)
			shift 2
			;;
		repos/*)
			endpoint="$token"
			shift
			;;
		*)
			shift
			;;
		esac
	done

	# contents/* — file fetch used by _finding_still_exists_on_main
	# Route purely by env-var flags, not by endpoint URL, so tests are not
	# accidentally coupled to filenames that happen to contain "diff" or
	# "suggestion".  Priority: GH_DELETED > GH_RAW_CONTENT > GH_DIFF > GH_SUGGESTION
	if [[ "$endpoint" == repos/*/contents/* ]]; then
		GH_LAST_CONTENT_ENDPOINT="$endpoint"
		[[ -n "$GH_API_LOG" ]] && printf '%s\n' "$endpoint" >>"$GH_API_LOG"

		if [[ "$GH_DELETED" == "1" ]]; then
			# Simulate a 404 — write "404" to stderr so the caller can detect it
			echo "404 Not Found" >&2
			return 1
		fi

		if [[ "$GH_DELETED" == "transient" ]]; then
			# Simulate a transient API error (non-404) — no "404" in stderr
			echo "500 Internal Server Error" >&2
			return 1
		fi

		if [[ -n "$GH_RAW_CONTENT" ]]; then
			printf '%s' "$GH_RAW_CONTENT"
			return 0
		fi

		if [[ -n "$GH_DIFF" ]]; then
			printf '%s' "$GH_DIFF"
			return 0
		fi

		if [[ -n "$GH_SUGGESTION" ]]; then
			printf '%s' "$GH_SUGGESTION"
			return 0
		fi

		return 1
	fi

	# repos/* (no sub-path) — default-branch lookup
	if [[ "$endpoint" == repos/* ]]; then
		echo "main"
		return 0
	fi

	echo "[]"
	return 0
}

_mock_gh_issue() {
	local subcommand="$1"
	shift

	case "$subcommand" in
	list)
		echo "[]"
		return 0
		;;
	create)
		GH_ISSUE_CREATE_COUNT=$((GH_ISSUE_CREATE_COUNT + 1))
		if [[ -n "$GH_CREATE_LOG" ]]; then
			echo "create" >>"$GH_CREATE_LOG"
		fi
		echo "https://github.com/example/repo/issues/999"
		return 0
		;;
	comment | edit)
		return 0
		;;
	esac

	return 1
}

# --- Source sub-libraries ---

# shellcheck source=./test-quality-feedback-main-verification-verification.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-quality-feedback-main-verification-verification.sh"

# shellcheck source=./test-quality-feedback-main-verification-approval.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-quality-feedback-main-verification-approval.sh"

# shellcheck source=./test-quality-feedback-main-verification-scan.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-quality-feedback-main-verification-scan.sh"

# --- Main ---

main() {
	source "$HELPER"

	echo "Running quality-feedback main-branch verification tests"
	test_skips_resolved_finding_when_snippet_missing
	test_creates_issue_when_snippet_still_exists
	test_skips_deleted_file
	test_handles_diff_fence_without_false_positive
	test_handles_suggestion_fence_and_comments
	test_keeps_unverifiable_finding
	test_transient_api_error_keeps_finding_as_unverifiable
	test_uses_default_branch_ref_for_contents_lookup
	test_plain_fence_skips_diff_marker_lines

	echo ""
	echo "Running suggestion-fence false-positive regression tests (GH#4874)"
	test_suggestion_fence_with_markdown_list_item_already_applied
	test_suggestion_fence_with_markdown_list_item_not_yet_applied

	echo ""
	echo "Running approval/sentiment detection tests (GH#4604)"
	test_skips_lgtm_review
	test_skips_no_further_comments_review
	test_skips_no_further_feedback_review
	test_skips_gemini_no_further_comments_summary_review
	test_skips_looks_good_review
	test_skips_good_work_review
	test_skips_no_issues_review
	test_skips_found_no_issues_long_review
	test_skips_no_further_recommendations_review
	test_skips_gemini_style_positive_summary_review
	test_skips_no_suggestions_at_this_time_review
	test_skips_no_suggestions_for_improvement_review
	test_keeps_actionable_approved_review
	test_keeps_changes_requested_review
	test_keeps_review_with_bug_report
	test_keeps_review_with_suggestion_fence

	echo ""
	echo "Running --include-positive flag tests (GH#4733)"
	test_include_positive_keeps_lgtm_review
	test_include_positive_keeps_gemini_positive_summary
	test_include_positive_keeps_no_suggestions_review
	test_scan_single_pr_include_positive_returns_positive_review
	test_scan_single_pr_default_filters_positive_review
	test_scan_single_pr_filters_issue3158_review_body
	test_scan_single_pr_filters_issue3188_review_body
	test_scan_single_pr_filters_issue3363_review_body
	test_scan_single_pr_filters_issue3303_review_body
	test_scan_single_pr_filters_issue3173_positive_review_body
	test_scan_single_pr_filters_issue3325_review_body
	test_scan_single_pr_filters_pr2647_positive_review_body
	test_scan_single_pr_filters_issue3145_pr3077_review_body

	echo ""
	echo "Running positive-review filter regression tests (GH#4814)"
	test_scan_single_pr_filters_issue4814_pr2166_exact_body
	test_scan_single_pr_positive_body_with_inline_comments_not_summary_only

	echo ""
	echo "Running merge/CI-status comment filter tests (GH#5668)"
	test_skips_pr5637_pulse_supervisor_merge_comment
	test_keeps_human_changes_requested_review_gh5668
	test_scan_single_pr_filters_pr5637_merge_comment

	echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
