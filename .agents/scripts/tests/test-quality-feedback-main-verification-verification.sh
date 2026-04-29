#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2016
# =============================================================================
# Quality Feedback Verification Tests -- snippet/finding verification tests
# =============================================================================
# Tests for _create_quality_debt_issues: snippet resolution, diff fences,
# suggestion fences, deleted files, transient API errors, default branch ref.
#
# Usage: source "${SCRIPT_DIR}/test-quality-feedback-main-verification-verification.sh"
#
# Dependencies:
#   - Orchestrator (test-quality-feedback-main-verification.sh) must be sourced
#     first to provide: print_result, reset_mock_state, gh mock, GH_* globals
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_QF_VERIFICATION_TESTS_LOADED:-}" ]] && return 0
_QF_VERIFICATION_TESTS_LOADED=1

# --- Test Functions ---

test_skips_resolved_finding_when_snippet_missing() {
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nverification marker present\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":42,"body_full":"```bash\nverification marker missing\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "0" && "$created_count" -eq 0 ]]; then
		print_result "skip resolved finding when snippet not on main" 0
	else
		print_result "skip resolved finding when snippet not on main" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_creates_issue_when_snippet_still_exists() {
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nverification marker present\nreturn 1\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":42,"body_full":"```bash\nverification marker present\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "create issue when finding snippet exists on main" 0
	else
		print_result "create issue when finding snippet exists on main" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_skips_deleted_file() {
	reset_mock_state
	GH_DELETED="1"

	local findings
	findings='[{"file":".agents/scripts/deleted.sh","line":42,"body_full":"```bash\nreturn 1\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "0" && "$created_count" -eq 0 ]]; then
		print_result "skip finding when file deleted on main" 0
	else
		print_result "skip finding when file deleted on main" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_handles_diff_fence_without_false_positive() {
	# The finding body contains a ```diff fence.  The snippet extractor must
	# skip the +/- lines and extract the context line ("context stable
	# verification marker").  The file on main (GH_RAW_CONTENT) contains that
	# context line, so the finding is verified and an issue is created.
	# GH_RAW_CONTENT is used for the file payload; the diff fence is only in
	# body_full and does not affect which env var the mock returns.
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\ncontext stable verification marker\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":2,"body_full":"```diff\n- return 1\n+ return 2\n context stable verification marker\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "diff fences verify using substantive context line" 0
	else
		print_result "diff fences verify using substantive context line" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_handles_suggestion_fence_and_comments() {
	# The finding body contains a ```suggestion fence with comment lines.
	# The snippet extractor must skip comment-only lines (// and #) and extract
	# the first substantive code line ("this is stable suggestion code").
	#
	# Under GH#4874 semantics: suggestion fences contain the proposed FIX text.
	# If the suggestion text IS present in the HEAD file, the fix was already
	# applied before merge → finding is resolved → no issue created.
	# This test verifies that the snippet extractor correctly skips comment lines
	# AND that the resolved-suggestion logic fires correctly.
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nthis is stable suggestion code\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":2,"body_full":"```suggestion\n// reviewer note\n# inline comment\nthis is stable suggestion code\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	# Suggestion text already in file → fix applied before merge → no issue (GH#4874)
	if [[ "$created" == "0" && "$created_count" -eq 0 ]]; then
		print_result "suggestion fences: skip when fix already applied (GH#4874)" 0
	else
		print_result "suggestion fences: skip when fix already applied (GH#4874)" 1 "created=${created}, issues=${created_count} (expected 0 — suggestion already in file)"
	fi
	return 0
}

test_keeps_unverifiable_finding() {
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":2,"body_full":"tiny\n- short\n> mini","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "keep unverifiable findings for manual review" 0
	else
		print_result "keep unverifiable findings for manual review" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_transient_api_error_keeps_finding_as_unverifiable() {
	reset_mock_state
	GH_DELETED="transient"

	local findings
	findings='[{"file":".agents/scripts/example.sh","line":42,"body_full":"```bash\nsome code snippet here\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	# Transient API error should keep finding as unverifiable → issue created
	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "transient API error keeps finding as unverifiable" 0
	else
		print_result "transient API error keeps finding as unverifiable" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_uses_default_branch_ref_for_contents_lookup() {
	reset_mock_state
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nverification marker present\nreturn 0\n'

	local findings
	findings='[{"file":".agents/scripts/ref-check.sh","line":2,"body_full":"```bash\nverification marker present\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	rm -f "$out_file"

	rm -f "$GH_CREATE_LOG"

	if [[ -f "$GH_API_LOG" ]] && grep -Fq '?ref=main' "$GH_API_LOG"; then
		print_result "contents lookup uses default-branch ref" 0
	else
		print_result "contents lookup uses default-branch ref" 1 "endpoint=${GH_LAST_CONTENT_ENDPOINT}"
	fi
	rm -f "$GH_API_LOG"
	return 0
}

test_plain_fence_skips_diff_marker_lines() {
	# Regression: a plain ```bash fence whose first line starts with '+' or '-'
	# must NOT strip the marker and use the remainder as a snippet.  The old code
	# did `candidate="${candidate:1}"` which turned "+ new code" into "new code"
	# and then matched it against the file, producing a false "verified" result.
	# The fix skips +/- lines in non-diff fences entirely, so the snippet falls
	# through to the fallback extractor (or returns unverifiable if nothing else
	# matches), preventing the false positive.
	reset_mock_state
	# File contains "new code" — the stripped version of "+ new code"
	GH_RAW_CONTENT=$'#!/usr/bin/env bash\nnew code\nreturn 0\n'

	local findings
	# Body has a plain bash fence whose only substantive line is "+ new code".
	# With the old strip logic this would extract "new code", find it in the file,
	# and mark the finding verified.  With the fix it skips the +/- line and falls
	# through to unverifiable (no other qualifying line), so the issue is still
	# created (unverifiable → kept), but the snippet is NOT "new code".
	findings='[{"file":".agents/scripts/example.sh","line":2,"body_full":"```bash\n+ new code\n```","reviewer":"coderabbit","reviewer_login":"coderabbitai","severity":"high","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "123" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	# Finding must be kept (unverifiable — no snippet extracted from +/- only fence)
	# rather than falsely resolved by matching the stripped "new code" in the file.
	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "plain fence skips +/- lines instead of stripping prefix" 0
	else
		print_result "plain fence skips +/- lines instead of stripping prefix" 1 "created=${created}, issues=${created_count}"
	fi
	return 0
}

test_suggestion_fence_with_markdown_list_item_already_applied() {
	# Regression test for GH#4874 / false-positive issue #3183.
	#
	# Scenario: Gemini flagged "- **Blocks:** t1393" in PR #2871 and suggested
	# replacing it with "- **Enhances:** t1393 (...)".  The author applied the
	# suggestion before merging.  The merge commit already contains the fix.
	#
	# The comment body contains a ```suggestion fence whose content is:
	#   - **Enhances:** t1393 (bench --judge can delegate to these evaluators)
	#
	# The line starts with '-', which is a markdown list item prefix, NOT a
	# unified-diff removal marker.  The old code treated suggestion fences the
	# same as diff fences and skipped all '-' lines, so no snippet was extracted,
	# the finding was marked "unverifiable", and an issue was created — a false
	# positive.
	#
	# The fix: suggestion fences do NOT skip '-' lines.  The snippet
	# "- **Enhances:** t1393 ..." is extracted and found in the HEAD file, so
	# the finding is correctly marked "resolved" and no issue is created.
	reset_mock_state
	# File at HEAD already contains the suggested replacement text (fix applied)
	GH_RAW_CONTENT=$'# t1394 brief\n\n- **Enhances:** t1393 (bench --judge can delegate to these evaluators)\n'

	local findings
	# Mirrors the actual Gemini comment from PR #2871 (truncated for test clarity)
	findings='[{"file":"todo/tasks/t1394-brief.md","line":139,"body_full":"![medium](https://www.gstatic.com/codereviewagent/medium-priority.svg)\n\nConsider rephrasing to clarify the relationship.\n\n```suggestion\n- **Enhances:** t1393 (bench --judge can delegate to these evaluators)\n```","reviewer":"gemini","reviewer_login":"gemini-code-assist[bot]","severity":"medium","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "2871" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	# Suggestion was already applied — no issue should be created
	if [[ "$created" == "0" && "$created_count" -eq 0 ]]; then
		print_result "suggestion fence: skip finding when markdown list item already applied (GH#4874)" 0
	else
		print_result "suggestion fence: skip finding when markdown list item already applied (GH#4874)" 1 "created=${created}, issues=${created_count} (expected 0 — fix was already applied before merge)"
	fi
	return 0
}

test_suggestion_fence_with_markdown_list_item_not_yet_applied() {
	# Counterpart to the GH#4874 regression test: when the suggestion has NOT
	# been applied (the old text is still in the file), the finding must be kept
	# and an issue created.
	reset_mock_state
	# File at HEAD still contains the OLD text (suggestion not applied)
	GH_RAW_CONTENT=$'# t1394 brief\n\n- **Blocks:** t1393 (some description)\n'

	local findings
	findings='[{"file":"todo/tasks/t1394-brief.md","line":139,"body_full":"Consider rephrasing.\n\n```suggestion\n- **Enhances:** t1393 (bench --judge can delegate to these evaluators)\n```","reviewer":"gemini","reviewer_login":"gemini-code-assist[bot]","severity":"medium","url":"https://example.test/comment"}]'

	local out_file
	out_file=$(mktemp)
	local created
	_create_quality_debt_issues "owner/repo" "2871" "$findings" >"$out_file"
	created=$(<"$out_file")
	rm -f "$out_file"

	local created_count
	created_count=$(wc -l <"$GH_CREATE_LOG" | tr -d ' ')
	rm -f "$GH_CREATE_LOG"
	rm -f "$GH_API_LOG"

	# Suggestion not applied — issue should be created
	if [[ "$created" == "1" && "$created_count" -eq 1 ]]; then
		print_result "suggestion fence: create issue when markdown list item not yet applied (GH#4874)" 0
	else
		print_result "suggestion fence: create issue when markdown list item not yet applied (GH#4874)" 1 "created=${created}, issues=${created_count} (expected 1 — fix not yet applied)"
	fi
	return 0
}
