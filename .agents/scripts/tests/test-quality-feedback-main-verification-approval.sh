#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Quality Feedback Approval Tests -- approval/sentiment detection tests
# =============================================================================
# Tests for the approval-detection jq filter used in _scan_single_pr:
# LGTM, positive summaries, no-further-comments, actionable review detection,
# --include-positive flag behaviour, merge/CI-status comment filtering.
#
# Usage: source "${SCRIPT_DIR}/test-quality-feedback-main-verification-approval.sh"
#
# Dependencies:
#   - Orchestrator (test-quality-feedback-main-verification.sh) must be sourced
#     first to provide: print_result, reset_mock_state, gh mock, GH_* globals
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_QF_APPROVAL_TESTS_LOADED:-}" ]] && return 0
_QF_APPROVAL_TESTS_LOADED=1

# --- Helper Functions ---

# Helper: run the approval-detection jq filter against a review body.
# Returns "skip" if the review would be skipped, "keep" if it would be kept.
# Mirrors the $approval_only + $actionable logic in _scan_single_pr.
_test_approval_filter() {
	local body="$1"
	local state="${2:-COMMENTED}"
	local reviewer="${3:-coderabbit}"

	# Replicate the jq filter from _scan_single_pr review_findings block
	local result
	result=$(jq -rn \
		--arg body "$body" \
		--arg state "$state" \
		--arg reviewer "$reviewer" '
		($body | test(
			"^[\\s\\n]*(lgtm|looks good( to me)?|ship it|shipit|:shipit:|:\\+1:|👍|" +
			"approved?|great (work|job|change|pr|patch)|nice (work|job|change|pr|patch)|" +
			"good (work|job|change|pr|patch|catch|call|stuff)|well done|" +
			"no (further |more )?(comments?|issues?|concerns?|feedback|changes? (needed|required))|" +
			"nothing (further|else|more) (to (add|comment|say|note))?|" +
			"(all |everything )?(looks?|seems?) (good|fine|correct|great|solid|clean)|" +
			"(this |the )?(pr|patch|change|diff|code) (looks?|seems?) (good|fine|correct|great|solid|clean)|" +
			"(i have )?no (objections?|issues?|concerns?|comments?)|" +
			"(thanks?|thank you)[,.]?\\s*(for the (pr|patch|fix|change|contribution))?[.!]?)[\\s\\n]*$"; "i")) as $approval_only |

		($body | test(
			"\\bno (further )?recommendations?\\b|" +
			"\\bno additional recommendations?\\b|" +
			"\\bnothing (further|more) to recommend\\b"; "i")) as $no_actionable_recommendation |

		($body | test(
			"\\bno (further |more )?suggestions?\\b|" +
			"\\bno additional suggestions?\\b|" +
			"\\bno suggestions? (at this time|for now|currently|for improvement)?\\b|" +
			"\\bwithout suggestions?\\b|" +
			"\\bhas no suggestions?\\b"; "i")) as $no_actionable_suggestions |

		($body | test(
			"\\blgtm\\b|\\blooks good( to me)?\\b|\\bgood work\\b|" +
			"\\bno (further |more )?(comments?|issues?|concerns?|feedback)\\b|" +
			"\\beverything (looks?|seems?) (good|fine|correct|great|solid|clean)\\b"; "i")) as $no_actionable_sentiment |

		($body | test(
			"\\bsuccessfully addresses?\\b|\\beffectively\\b|\\bimproves?\\b|\\benhances?\\b|" +
			"\\bconsistent\\b|\\brobust(ness)?\\b|\\buser experience\\b|" +
			"\\breduces? (external )?requirements?\\b|\\bwell-implemented\\b"; "i")) as $summary_praise_only |

		($body | test(
			"\\bshould\\b|\\bconsider\\b|\\binstead\\b|\\bsuggest|\\brecommend(ed|ing)?\\b|" +
			"\\bwarning\\b|\\bcaution\\b|\\bavoid\\b|\\b(don ?'"'"'?t|do not)\\b|" +
			"\\bvulnerab|\\binsecure|\\binjection\\b|\\bxss\\b|\\bcsrf\\b|" +
			"\\bbug\\b|\\berror\\b|\\bproblem\\b|\\bfail\\b|\\bincorrect\\b|\\bwrong\\b|\\bmissing\\b|\\bbroken\\b|" +
			"\\bnit:|\\btodo:|\\bfixme|\\bhardcoded|\\bdeprecated|" +
			"\\brace.condition|\\bdeadlock|\\bleak|\\boverflow|" +
			"\\bworkaround\\b|\\bhack\\b|" +
			"```\\s*(suggestion|diff)"; "i")) as $actionable_raw |

		($actionable_raw and ($no_actionable_recommendation | not) and ($no_actionable_suggestions | not)) as $actionable |

		# GH#5668: merge/CI-status comments are not actionable review feedback
		($body | test(
			"\\bmerging\\.?$|\\bmerge (this|the) pr\\b|" +
			"\\bci (checks? )?(green|pass(ed)?|ok)\\b|" +
			"\\ball (checks?|tests?) (green|pass(ed)?|ok)\\b|" +
			"\\breview.bot.gate (pass|ok)\\b|" +
			"\\bpulse supervisor\\b"; "i")) as $merge_status_only |

		# skip = approval-only/no-recommendation/no-suggestions/no-actionable sentiment
		# or summary praise with no actionable critique, or merge/CI-status comment
		if (($approval_only or $no_actionable_recommendation or $no_actionable_suggestions or $no_actionable_sentiment or $summary_praise_only or $merge_status_only) and ($actionable | not)) then "skip"
		else "keep"
		end
	')
	echo "$result"
	return 0
}

# Helper: run the approval-detection jq filter with include_positive=true.
# Returns "keep" for all reviews when include_positive bypasses filters.
_test_approval_filter_include_positive() {
	local body="$1"

	# With include_positive=true the filter always returns "keep"
	local result
	result=$(jq -rn \
		--arg body "$body" \
		--argjson include_positive 'true' '
		if $include_positive then "keep"
		else
			($body | test("\\bshould\\b|\\bconsider\\b"; "i")) as $actionable |
			if $actionable then "keep" else "skip" end
		end
	')
	echo "$result"
	return 0
}

# --- Test Functions ---

test_skips_lgtm_review() {
	local result
	result=$(_test_approval_filter "LGTM")
	if [[ "$result" == "skip" ]]; then
		print_result "skip LGTM review" 0
	else
		print_result "skip LGTM review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_further_comments_review() {
	local result
	result=$(_test_approval_filter "I've reviewed the changes and have no further comments. Good work.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no further comments' review" 0
	else
		print_result "skip 'no further comments' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_further_feedback_review() {
	local result
	result=$(_test_approval_filter "The implementation is sound and I have no further feedback.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no further feedback' review" 0
	else
		print_result "skip 'no further feedback' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_gemini_no_further_comments_summary_review() {
	local result
	result=$(_test_approval_filter '## Code Review

This pull request correctly adds blocked-by dependencies to subtasks in TODO.md, establishing a sequential chain t1120.1 -> t1120.2 -> t1120.4. This change prevents the subtasks from being dispatched in parallel, which could lead to wasted CI cycles. The modification is minimal, accurate, and adheres to the task dependency format used in the project. The implementation is sound and I have no further comments.')
	if [[ "$result" == "skip" ]]; then
		print_result "skip Gemini summary with 'no further comments'" 0
	else
		print_result "skip Gemini summary with 'no further comments'" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_looks_good_review() {
	local result
	result=$(_test_approval_filter "Looks good to me!")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'looks good to me' review" 0
	else
		print_result "skip 'looks good to me' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_good_work_review() {
	local result
	result=$(_test_approval_filter "Good work on this PR.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'good work' review" 0
	else
		print_result "skip 'good work' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_issues_review() {
	local result
	result=$(_test_approval_filter "No issues found. Everything looks good.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no issues' review" 0
	else
		print_result "skip 'no issues' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_found_no_issues_long_review() {
	local result
	result=$(_test_approval_filter "This pull request enhances the AI supervisor's reasoning capabilities by introducing self-improvement and efficiency analysis. It adds two new action types, create_improvement and escalate_model, along with corresponding analysis frameworks and examples in the system prompt. The updates to the prompt are clear and consistent with the stated goals. I've reviewed the changes and found no issues. The new capabilities are a strong step toward a more intelligent supervisor.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip long summary review with 'found no issues'" 0
	else
		print_result "skip long summary review with 'found no issues'" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_further_recommendations_review() {
	local result
	result=$(_test_approval_filter "The pull request is well-documented and the fixes are implemented correctly. I have no further recommendations.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no further recommendations' review" 0
	else
		print_result "skip 'no further recommendations' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_gemini_style_positive_summary_review() {
	local result
	result=$(_test_approval_filter "This pull request successfully addresses the issue by removing an external dependency and improves robustness. The addition of no-data messaging enhances user experience.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip Gemini-style positive summary review" 0
	else
		print_result "skip Gemini-style positive summary review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_suggestions_at_this_time_review() {
	local result
	result=$(_test_approval_filter "Review completed. No suggestions at this time.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no suggestions at this time' review" 0
	else
		print_result "skip 'no suggestions at this time' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_suggestions_for_improvement_review() {
	local result
	result=$(_test_approval_filter "The code is clear and consistent with the style guide. I have no suggestions for improvement.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no suggestions for improvement' review" 0
	else
		print_result "skip 'no suggestions for improvement' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_keeps_actionable_approved_review() {
	# APPROVED review that also contains actionable critique — must be kept
	local result
	result=$(_test_approval_filter "Looks good overall, but you should consider adding error handling for the null case." "APPROVED")
	if [[ "$result" == "keep" ]]; then
		print_result "keep APPROVED review with actionable critique" 0
	else
		print_result "keep APPROVED review with actionable critique" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_changes_requested_review() {
	# CHANGES_REQUESTED review — must always be kept
	local result
	result=$(_test_approval_filter "This looks wrong. The function is missing error handling." "CHANGES_REQUESTED")
	if [[ "$result" == "keep" ]]; then
		print_result "keep CHANGES_REQUESTED review with critique" 0
	else
		print_result "keep CHANGES_REQUESTED review with critique" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_review_with_bug_report() {
	# Review mentioning a bug — must be kept even if it starts positively
	local result
	result=$(_test_approval_filter "Good work overall, but there's a bug in the error handler — it fails when input is null.")
	if [[ "$result" == "keep" ]]; then
		print_result "keep review with bug report despite positive opener" 0
	else
		print_result "keep review with bug report despite positive opener" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_review_with_suggestion_fence() {
	# Review with a suggestion code fence — must be kept
	local result
	result=$(_test_approval_filter 'Looks good, but consider this change:
```suggestion
return nil, fmt.Errorf("invalid input: %w", err)
```')
	if [[ "$result" == "keep" ]]; then
		print_result "keep review with suggestion fence" 0
	else
		print_result "keep review with suggestion fence" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_include_positive_keeps_lgtm_review() {
	# With --include-positive, a pure LGTM review must be kept (not filtered)
	local result
	result=$(_test_approval_filter_include_positive "LGTM")
	if [[ "$result" == "keep" ]]; then
		print_result "--include-positive keeps LGTM review" 0
	else
		print_result "--include-positive keeps LGTM review" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_include_positive_keeps_gemini_positive_summary() {
	# With --include-positive, a Gemini-style positive summary must be kept
	local result
	result=$(_test_approval_filter_include_positive "This pull request successfully addresses the issue by removing an external dependency and improves robustness.")
	if [[ "$result" == "keep" ]]; then
		print_result "--include-positive keeps Gemini positive summary" 0
	else
		print_result "--include-positive keeps Gemini positive summary" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_include_positive_keeps_no_suggestions_review() {
	# With --include-positive, a "no suggestions" review must be kept
	local result
	result=$(_test_approval_filter_include_positive "Review completed. No suggestions at this time.")
	if [[ "$result" == "keep" ]]; then
		print_result "--include-positive keeps 'no suggestions' review" 0
	else
		print_result "--include-positive keeps 'no suggestions' review" 1 "expected keep, got ${result}"
	fi
	return 0
}
