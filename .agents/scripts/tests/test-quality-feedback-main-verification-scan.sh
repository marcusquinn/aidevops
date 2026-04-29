#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2016
# =============================================================================
# Quality Feedback Scan Tests -- _scan_single_pr integration tests
# =============================================================================
# Integration tests for _scan_single_pr: include_positive flag, positive review
# filtering, regression tests for specific issue bodies (GH#3188, GH#3363,
# GH#3303, GH#3173, GH#4814, GH#3325, GH#3323, GH#3158, GH#3145, GH#5668).
#
# Usage: source "${SCRIPT_DIR}/test-quality-feedback-main-verification-scan.sh"
#
# Dependencies:
#   - Orchestrator (test-quality-feedback-main-verification.sh) must be sourced
#     first to provide: print_result, reset_mock_state, gh mock, GH_* globals
#   - Approval sub-library must be sourced for: _test_approval_filter
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_QF_SCAN_TESTS_LOADED:-}" ]] && return 0
_QF_SCAN_TESTS_LOADED=1

# --- Helper: restore the default mock gh after scan tests ---

_restore_mock_gh() {
	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			_mock_gh_api "$@"
			return $?
			;;
		label) return 0 ;;
		issue)
			_mock_gh_issue "$@"
			return $?
			;;
		esac
		echo "unexpected gh call: ${command}" >&2
		return 1
	}
	return 0
}

# --- Test Functions ---

# Integration test: _scan_single_pr with include_positive=true returns findings
# for a purely positive review that would otherwise be filtered.
test_scan_single_pr_include_positive_returns_positive_review() {
	reset_mock_state

	# Mock gh to return a purely positive review (no inline comments, COMMENTED state)
	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			local endpoint=""
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					echo '[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"COMMENTED","body":"This pull request successfully addresses the issue and improves robustness. The changes are well-implemented and consistent with the codebase.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/example/repo/pull/1#pullrequestreview-1"}]'
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "1" "medium" "true" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -gt 0 ]]; then
		print_result "--include-positive: _scan_single_pr returns positive review" 0
	else
		print_result "--include-positive: _scan_single_pr returns positive review" 1 "expected >0 findings, got ${count}"
	fi

	# Restore mock gh
	_restore_mock_gh
	return 0
}

# Integration test: _scan_single_pr without include_positive filters the same review
test_scan_single_pr_default_filters_positive_review() {
	reset_mock_state

	# Same mock as above but include_positive=false (default)
	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					echo '[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"COMMENTED","body":"This pull request successfully addresses the issue and improves robustness. The changes are well-implemented and consistent with the codebase.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/example/repo/pull/1#pullrequestreview-1"}]'
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "1" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		print_result "default (no --include-positive): _scan_single_pr filters positive review" 0
	else
		print_result "default (no --include-positive): _scan_single_pr filters positive review" 1 "expected 0 findings, got ${count}"
	fi

	# Restore mock gh
	_restore_mock_gh
	return 0
}

test_scan_single_pr_filters_issue3188_review_body() {
	# Regression: PR #2887 Gemini approval review — "I approve of this refactoring"
	# with summary praise (improves, consistent, good improvement) must be filtered
	# as non-actionable. The scanner incorrectly created issue #3188 before the
	# summary_praise_only filter was added.
	local result
	result=$(_test_approval_filter '## Code Review

This pull request refactors the CodeRabbit trigger logic in `pulse-wrapper.sh` to reduce code duplication. The changes hoist the `_save_sweep_state()` call and `tool_count` increment out of two conditional branches into a single, common call site. A new boolean flag, `is_baseline_run`, is introduced to improve the readability and intent of the conditional logic that handles the first sweep run. These changes are a good improvement to the code'"'"'s structure and maintainability, and the logic remains functionally equivalent. I approve of this refactoring.')
	if [[ "$result" == "skip" ]]; then
		print_result "issue #3188 PR #2887 Gemini approval review is filtered as non-actionable" 0
	else
		print_result "issue #3188 PR #2887 Gemini approval review is filtered as non-actionable" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_scan_single_pr_filters_issue3363_review_body() {
	reset_mock_state

	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					echo '[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"COMMENTED","body":"This pull request introduces several important fixes to address tasks getting stuck in an '\''evaluating'\'' state. The changes include making the evaluation timeout configurable, adding a heartbeat mechanism to signal that an evaluation is still active, and adding a fast-path to skip AI evaluation if a PR already exists. The changes are well-commented and align with the stated goals.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/example/repo/pull/1#pullrequestreview-1"}]'
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "1" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		print_result "issue #3363 review body is filtered as non-actionable" 0
	else
		print_result "issue #3363 review body is filtered as non-actionable" 1 "expected 0 findings, got ${count}"
	fi

	_restore_mock_gh
	return 0
}

test_scan_single_pr_filters_issue3303_review_body() {
	reset_mock_state

	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					cat <<'JSON'
[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"COMMENTED","body":"## Code Review\n\nThis pull request updates the `TODO.md` file to reflect the completion of the 'Dual-CLI Architecture' parent task (t1160). The changes include marking the task as complete and cleaning up a long, repetitive note for a subtask, improving the file's readability. The changes are accurate and align with the pull request's goal of closing out completed work.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/example/repo/pull/1#pullrequestreview-1"}]
JSON
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "1" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		print_result "issue #3303 review body is filtered as non-actionable" 0
	else
		print_result "issue #3303 review body is filtered as non-actionable" 1 "expected 0 findings, got ${count}"
	fi

	_restore_mock_gh
	return 0
}

test_scan_single_pr_filters_issue3173_positive_review_body() {
	reset_mock_state

	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					printf '%s' '[{"id":1,"user":{"login":"gemini-code-assist"},"state":"COMMENTED","body":"## Code Review\n\nThis pull request correctly removes the suppression of stderr from the version check command in `tool-version-check.sh`. This is a valuable change that improves debuggability by ensuring that error messages from underlying tool commands are no longer hidden. The implementation is correct and aligns with the project\u0027s general rules against blanket error suppression.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/example/repo/pull/1#pullrequestreview-1"}]'
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "1" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		print_result "issue #3173 review body is filtered as non-actionable" 0
	else
		print_result "issue #3173 review body is filtered as non-actionable" 1 "expected 0 findings, got ${count}"
	fi

	_restore_mock_gh
	return 0
}

# Regression test for GH#4814 / incident: issue #3343 filed for PR #2166.
# The exact Gemini review body that triggered the false-positive issue creation.
# Review state: COMMENTED, no inline comments, bot reviewer.
# Expected: filtered by $summary_only (COMMENTED + 0 inline + bot) — 0 findings.
test_scan_single_pr_filters_issue4814_pr2166_exact_body() {
	reset_mock_state

	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					# Exact body from the incident that caused issue #3343 to be filed
					echo '[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"COMMENTED","body":"The changes are well-implemented and improve the script'\''s robustness and quality.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/example/repo/pull/2166#pullrequestreview-1"}]'
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "2166" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		print_result "GH#4814: exact PR #2166 Gemini praise body filtered (0 findings)" 0
	else
		print_result "GH#4814: exact PR #2166 Gemini praise body filtered (0 findings)" 1 "expected 0 findings, got ${count} — would have filed false-positive issue"
	fi

	_restore_mock_gh
	return 0
}

test_scan_single_pr_filters_issue3325_review_body() {
	reset_mock_state

	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					printf '%s\n' '[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"COMMENTED","body":"## Code Review\n\nThis pull request addresses an issue where headless command sessions were incorrectly receiving an interactive greeting. The fix modifies the `generate-opencode-agents.sh` script to add a condition that skips the greeting for non-interactive sessions like `/pulse` and `/full-loop`. The change is clear, targeted, and effectively resolves the described problem. I have no further comments.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/example/repo/pull/1#pullrequestreview-1"}]'
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "1" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		print_result "issue #3325 review body is filtered as non-actionable" 0
	else
		print_result "issue #3325 review body is filtered as non-actionable" 1 "expected 0 findings, got ${count}"
	fi

	_restore_mock_gh
	return 0
}

test_scan_single_pr_filters_pr2647_positive_review_body() {
	reset_mock_state

	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					printf '%s\n' '[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"COMMENTED","body":"## Code Review\n\nThis pull request correctly addresses ShellCheck warning SC2181 by replacing indirect exit code checks with the more idiomatic `if ! cmd;` pattern in `stash-audit-helper.sh`. The changes are applied consistently across four functions, improving code readability and robustness. The implementation is sound and I found no issues with the proposed changes.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/example/repo/pull/1#pullrequestreview-1"}]'
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "1" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		print_result "issue #3323 review body is filtered as non-actionable" 0
	else
		print_result "issue #3323 review body is filtered as non-actionable" 1 "expected 0 findings, got ${count}"
	fi

	_restore_mock_gh
	return 0
}

# Regression: COMMENTED bot review with inline comments present — the review body
# is purely positive but the inline comments may be actionable. The $summary_only
# filter must NOT apply here (inline_count > 0). The body-level filters
# ($approval_only, $summary_praise_only) still apply to the review body itself.
test_scan_single_pr_positive_body_with_inline_comments_not_summary_only() {
	reset_mock_state

	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					# One inline comment with actionable content
					echo '[{"id":10,"user":{"login":"gemini-code-assist[bot]"},"path":"src/foo.sh","line":5,"original_line":5,"position":1,"body":"You should add error handling here.","html_url":"https://github.com/example/repo/pull/1#discussion_r10","created_at":"2024-01-01T00:00:00Z"}]'
					return 0
					;;
				repos/*/pulls/*/reviews)
					# Positive review body but inline comments exist — body should be
					# filtered by $summary_praise_only, inline comment kept separately
					echo '[{"id":1,"user":{"login":"gemini-code-assist[bot]"},"state":"COMMENTED","body":"The changes are well-implemented and improve the script'\''s robustness and quality.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/example/repo/pull/1#pullrequestreview-1"}]'
					return 0
					;;
				repos/*/git/trees/*)
					# Return pre-processed path list (as _scan_single_pr uses --jq '[.tree[].path]')
					echo '["src/foo.sh"]'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "1" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")
	local types
	types=$(printf '%s' "$findings" | jq -r '[.[].type] | unique | sort | join(",")' 2>/dev/null || echo "")

	# Inline comment should be kept (actionable: "should"), review body filtered
	if [[ "$count" -eq 1 && "$types" == "inline" ]]; then
		print_result "positive review body filtered but actionable inline comment kept" 0
	else
		print_result "positive review body filtered but actionable inline comment kept" 1 "expected 1 inline finding, got count=${count} types=${types}"
	fi

	_restore_mock_gh
	return 0
}

test_scan_single_pr_filters_issue3158_review_body() {
	# Regression: PR #3060 Gemini review — "The changes are correct and well-justified."
	# with summary praise (effectively, improves, correct, well-justified) must be filtered
	# as non-actionable. The scanner incorrectly created issue #3158 before the
	# summary_praise_only filter was confirmed to handle this body.
	local result
	result=$(_test_approval_filter '## Code Review

This pull request effectively addresses ShellCheck SC2034 warnings for unused variables across several scripts. The changes involve removing genuinely unused variables and adding appropriate `shellcheck disable` directives for variables that are used indirectly by sourced scripts. These modifications improve code cleanliness and maintainability by eliminating dead code and silencing irrelevant linter warnings. The changes are correct and well-justified.')
	if [[ "$result" == "skip" ]]; then
		print_result "issue #3158 PR #3060 Gemini approval review is filtered as non-actionable" 0
	else
		print_result "issue #3158 PR #3060 Gemini approval review is filtered as non-actionable" 1 "expected skip, got ${result}"
	fi
	return 0
}

# Regression test for issue #3145 / PR #3077:
# Gemini Code Assist posted a summary-only COMMENTED review with no inline
# comments on a ShellCheck fix PR. The review body praised the changes
# ("correctly resolve the linter warnings") with no actionable critique.
# This must be filtered by the summary_only rule (state=COMMENTED, no inline
# comments, bot reviewer) and also by the summary_praise_only heuristic.
# Before the summary_only filter was added, this created a false-positive
# quality-debt issue (#3145).
test_scan_single_pr_filters_issue3145_pr3077_review_body() {
	reset_mock_state

	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					# Exact review body from PR #3077 (gemini-code-assist, COMMENTED, no inline comments)
					# shellcheck disable=SC2028  # \n is literal JSON — jq interprets it, not the shell
					echo '[{"id":3908632650,"user":{"login":"gemini-code-assist[bot]"},"state":"COMMENTED","body":"## Code Review\n\nThis pull request addresses several ShellCheck warnings. In `generate-claude-commands.sh`, a `SC2317` disable has been added with a clear explanation for why ShellCheck incorrectly flags code as unreachable. In `setup.sh`, a comment has been updated to remove stale line number references, making it more robust. The changes are straightforward and correctly resolve the linter warnings.","submitted_at":"2024-01-01T00:00:00Z","html_url":"https://github.com/marcusquinn/aidevops/pull/3077#pullrequestreview-3908632650"}]'
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "3077" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		print_result "issue #3145: PR #3077 Gemini summary-only review is filtered" 0
	else
		print_result "issue #3145: PR #3077 Gemini summary-only review is filtered" 1 "expected 0 findings, got ${count}"
	fi

	_restore_mock_gh
	return 0
}

# Regression test for GH#5668: pulse supervisor merge comment filed as quality-debt.
# The exact review body from PR #5637 (marcusquinn, APPROVED, human reviewer).
# "Pulse supervisor: all CI checks green, review-bot-gate PASS, CodeRabbit approved. Merging."
# This is an operational status message, not actionable review feedback.
# Before the fix: human APPROVED reviews bypassed all filters (elif $reviewer == "human" then true).
# After the fix: human APPROVED reviews require $actionable content, and $merge_status_only
# is added to the non-actionable filter set.
test_skips_pr5637_pulse_supervisor_merge_comment() {
	local result
	result=$(_test_approval_filter "Pulse supervisor: all CI checks green, review-bot-gate PASS, CodeRabbit approved. Merging." "APPROVED" "marcusquinn")
	if [[ "$result" == "skip" ]]; then
		print_result "GH#5668: pulse supervisor merge comment filtered (human APPROVED)" 0
	else
		print_result "GH#5668: pulse supervisor merge comment filtered (human APPROVED)" 1 "expected skip, got ${result}"
	fi
	return 0
}

# Counterpart: human CHANGES_REQUESTED review must always pass through (GH#5668).
# The fix preserves CHANGES_REQUESTED as always-actionable.
test_keeps_human_changes_requested_review_gh5668() {
	local result
	result=$(_test_approval_filter "This function has a bug: the return value is not checked. Please fix before merging." "CHANGES_REQUESTED" "marcusquinn")
	if [[ "$result" == "keep" ]]; then
		print_result "GH#5668: human CHANGES_REQUESTED review kept (not filtered)" 0
	else
		print_result "GH#5668: human CHANGES_REQUESTED review kept (not filtered)" 1 "expected keep, got ${result}"
	fi
	return 0
}

# Integration test: _scan_single_pr with the exact PR #5637 review must return 0 findings.
test_scan_single_pr_filters_pr5637_merge_comment() {
	reset_mock_state

	gh() {
		local command="$1"
		shift
		case "$command" in
		api)
			while [[ $# -gt 0 ]]; do
				case "$1" in
				repos/*/pulls/*/comments)
					echo "[]"
					return 0
					;;
				repos/*/pulls/*/reviews)
					# Exact review from PR #5637 that caused issue #5668
					echo '[{"id":3996148895,"user":{"login":"marcusquinn"},"state":"APPROVED","body":"Pulse supervisor: all CI checks green, review-bot-gate PASS, CodeRabbit approved. Merging.","submitted_at":"2026-03-24T04:24:00Z","html_url":"https://github.com/marcusquinn/aidevops/pull/5637#pullrequestreview-3996148895"}]'
					return 0
					;;
				repos/*/git/trees/*)
					echo '{"tree":[]}'
					return 0
					;;
				repos/*)
					echo "main"
					return 0
					;;
				esac
				shift
			done
			echo "[]"
			return 0
			;;
		label | pr) return 0 ;;
		esac
		echo "[]"
		return 0
	}

	local findings
	findings=$(_scan_single_pr "owner/repo" "5637" "medium" "false" 2>/dev/null)
	local count
	count=$(printf '%s' "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		print_result "GH#5668: PR #5637 pulse supervisor merge comment produces 0 findings" 0
	else
		print_result "GH#5668: PR #5637 pulse supervisor merge comment produces 0 findings" 1 "expected 0 findings, got ${count} — would have filed false-positive issue"
	fi

	_restore_mock_gh
	return 0
}
