#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the pulse TODO auto-complete keyword semantics (t2391 / GH#19825).
#
# Background: `.github/workflows/issue-sync.yml` `sync-on-pr-merge` job runs
# on PR merge and marks `- [ ] tNNN` → `- [x] tNNN ... pr:#NNN completed:...`
# in TODO.md. Prior to t2391 it extracted `TASK_ID` via `^t[0-9]+` from the PR
# title with no range-syntax awareness. Planning PRs titled `t2259..t2264:
# plan framework observations` would mark ONLY t2259 complete, which is always
# wrong — none of the six tasks shipped code in the planning PR.
#
# The t2252 guard (line 705) already handles the `For/Ref`-only body case.
# The t2391 guard (line 695) handles the range-syntax title case, firing
# BEFORE the t2252 guard so Case D (range-syntax title + Closes body) is
# caught by the belt-and-braces range-syntax check.
#
# Test strategy:
#   - Static inspection: verify both guards exist with their expected regex
#     patterns and fire in the correct order.
#   - Behavioural classification: reimplement the extract-step regexes here
#     and assert the 5 cases (A-E) from the issue body produce the expected
#     classify decision (MARK_COMPLETE vs SKIP_RANGE vs SKIP_FOR_REF).
#
# Cases covered (from issue body):
#   A. body `Resolves #19802`, title `fix(biome): batch-fix JS/MJS`
#      → MARK_COMPLETE (baseline: single-task fix PR).
#   B. body `For #19802`, title `plan: batch-fix JS/MJS`
#      → SKIP_FOR_REF (t2252 guard).
#   C. title `t2259..t2264: plan`, body `For #19802`
#      → SKIP_RANGE (t2391 guard wins; range-syntax detection).
#   D. body `Closes #19802`, title `t2259..t2264: plan`
#      → SKIP_RANGE (t2391 guard wins over closing keyword; belt-and-braces).
#   E. body `Resolves #19802`, title `t2259: fix(biome) implement proper fix`
#      → MARK_COMPLETE (single-task ID title, not range-syntax).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
WORKFLOW="${REPO_ROOT}/.github/workflows/issue-sync.yml"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ $# -ge 2 && -n "$2" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# Reimplementation of the extract-step regexes from issue-sync.yml.
# Must be kept in sync with lines 374-401 of that file. The static inspection
# tests below assert the workflow file still contains these patterns.
classify_pr() {
	local pr_title="$1"
	local pr_body="$2"

	local linked_issues=""
	if [[ -n "$pr_body" ]]; then
		linked_issues=$(echo "$pr_body" | grep -oiE '(closes?|fixes?|resolves?)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true)
	fi

	local for_ref_issues=""
	if [[ -n "$pr_body" ]]; then
		for_ref_issues=$(echo "$pr_body" | grep -oiE '(for|ref)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true)
	fi

	local range_syntax=""
	if echo "$pr_title" | grep -qE '^t[0-9]+\.\.t[0-9]+'; then
		range_syntax="true"
	elif echo "$pr_title" | grep -qE '^t[0-9]+,[[:space:]]*t[0-9]+'; then
		range_syntax="true"
	fi

	# Guard order mirrors the workflow run block:
	#   1. range-syntax (t2391) — fires first, belt-and-braces
	#   2. for/ref-only (t2252) — fires when no Closes/Fixes/Resolves
	#   3. otherwise → mark complete
	if [[ "$range_syntax" == "true" ]]; then
		echo "SKIP_RANGE"
		return 0
	fi
	if [[ -z "$linked_issues" ]] && [[ -n "$for_ref_issues" ]]; then
		echo "SKIP_FOR_REF"
		return 0
	fi
	echo "MARK_COMPLETE"
	return 0
}

# ------------------------------------------------------------
# Static inspection: t2391 range-syntax detection + guard exist
# ------------------------------------------------------------
test_range_syntax_detection_in_extract_step() {
	if ! grep -qE "grep -qE '\^t\[0-9\]\+\\\\\\.\\\\\\.t\[0-9\]\+'" "$WORKFLOW"; then
		fail "extract step contains tNNN..tNNN detection" \
			"Expected '^t[0-9]+\\.\\.t[0-9]+' regex in workflow. The t2391 fix requires range-syntax detection in the extract step."
		return 0
	fi
	if ! grep -qE "grep -qE '\^t\[0-9\]\+,\[\[:space:\]\]\*t\[0-9\]\+'" "$WORKFLOW"; then
		fail "extract step contains tNNN, tNNN detection" \
			"Expected '^t[0-9]+,[[:space:]]*t[0-9]+' regex in workflow."
		return 0
	fi
	if ! grep -q 'echo "range_syntax=' "$WORKFLOW"; then
		fail "extract step emits range_syntax output" \
			"Expected 'range_syntax=' GITHUB_OUTPUT write."
		return 0
	fi
	pass "extract step: range-syntax regex + GITHUB_OUTPUT present"
	return 0
}

test_range_syntax_guard_in_update_step() {
	# shellcheck disable=SC2016  # literal YAML expression intended
	if ! grep -q 'RANGE_SYNTAX: ${{ steps.extract.outputs.range_syntax }}' "$WORKFLOW"; then
		fail "update step: RANGE_SYNTAX env var wired from extract output" \
			"Expected 'RANGE_SYNTAX: \${{ steps.extract.outputs.range_syntax }}' in the update step env block."
		return 0
	fi
	if ! grep -qE '\[\[ "\$\{RANGE_SYNTAX:-\}" == "true" \]\]' "$WORKFLOW"; then
		fail "update step: range-syntax guard condition" \
			"Expected guard '[[ \"\${RANGE_SYNTAX:-}\" == \"true\" ]]' in the update step."
		return 0
	fi
	pass "update step: RANGE_SYNTAX env + guard present"
	return 0
}

# Guard order matters: t2391 must fire BEFORE t2252 so Case D (range-syntax
# title + body `Closes #NNN`) doesn't fall through to the t2252 check (which
# allows through because LINKED_ISSUES is populated) and reach the mark-
# complete code path.
test_range_guard_precedes_for_ref_guard() {
	local range_line for_ref_line
	range_line=$(grep -nE '"\$\{RANGE_SYNTAX:-\}" == "true"' "$WORKFLOW" | head -1 | cut -d: -f1)
	for_ref_line=$(grep -nE '\[\[ -z "\$\{LINKED_ISSUES:-\}" \]\] && \[\[ -n "\$\{FOR_REF_ISSUES:-\}" \]\]' "$WORKFLOW" | head -1 | cut -d: -f1)
	if [[ -z "$range_line" || -z "$for_ref_line" ]]; then
		fail "range guard precedes for/ref guard" \
			"Missing range_line=$range_line or for_ref_line=$for_ref_line"
		return 0
	fi
	if [[ "$range_line" -lt "$for_ref_line" ]]; then
		pass "guard order: range-syntax (line $range_line) precedes for/ref (line $for_ref_line)"
		return 0
	fi
	fail "range guard precedes for/ref guard" \
		"range_line=$range_line is NOT before for_ref_line=$for_ref_line. Case D would fall through to mark-complete."
	return 0
}

# ------------------------------------------------------------
# Behavioural: 5 cases from issue body
# ------------------------------------------------------------
assert_case() {
	local name="$1"
	local title="$2"
	local body="$3"
	local expected="$4"
	local got
	got=$(classify_pr "$title" "$body")
	if [[ "$got" == "$expected" ]]; then
		pass "Case $name: $expected"
		return 0
	fi
	fail "Case $name: expected $expected got $got" \
		"title=$title body=$body"
	return 0
}

test_case_a_baseline_resolves() {
	assert_case "A" \
		"fix(biome): batch-fix JS/MJS" \
		"Resolves #19802" \
		"MARK_COMPLETE"
	return 0
}

test_case_b_for_ref_only() {
	assert_case "B" \
		"plan: batch-fix JS/MJS" \
		"For #19802" \
		"SKIP_FOR_REF"
	return 0
}

test_case_c_range_plus_for() {
	assert_case "C" \
		"t2259..t2264: plan framework observations" \
		"For #19802" \
		"SKIP_RANGE"
	return 0
}

test_case_d_range_plus_closes_belt_and_braces() {
	# This is the whole reason the range guard must precede the for/ref
	# guard. Body has a closing keyword (Closes #19802) — absent the
	# range guard, LINKED_ISSUES would be "19802", t2252 guard wouldn't
	# fire, and the code would proceed to mark t2259 complete.
	assert_case "D" \
		"t2259..t2264: plan framework observations" \
		"Closes #19802" \
		"SKIP_RANGE"
	return 0
}

test_case_e_single_task_id_not_range() {
	assert_case "E" \
		"t2259: fix(biome) implement proper fix" \
		"Resolves #19802" \
		"MARK_COMPLETE"
	return 0
}

# Additional edge case: comma-separated range-syntax (tNNN, tNNN)
test_case_f_comma_range_syntax() {
	assert_case "F (comma range)" \
		"t2259, t2260: plan two tasks" \
		"For #19802" \
		"SKIP_RANGE"
	return 0
}

# PR #19814 real-world replay: this was the merge that motivated the fix.
# Title: "t2259..t2264: plan framework observations from t2249 session"
# Body: "## Summary ... ## For ... For #19802 ..."
# Expected under new logic: SKIP_RANGE (would NOT have marked t2259 [x]).
test_pr_19814_replay() {
	local title="t2259..t2264: plan framework observations from t2249 session"
	local body="## For

- For #19802
- For #19803
- For #19804"
	local got
	got=$(classify_pr "$title" "$body")
	if [[ "$got" == "SKIP_RANGE" ]]; then
		pass "PR #19814 replay: new logic correctly skips (was mark-complete before t2391)"
		return 0
	fi
	fail "PR #19814 replay: expected SKIP_RANGE got $got" ""
	return 0
}

main_test() {
	if [[ ! -f "$WORKFLOW" ]]; then
		printf '%sFAIL%s workflow file not found at %s\n' "$TEST_RED" "$TEST_NC" "$WORKFLOW"
		return 1
	fi

	printf 'Static inspection:\n'
	test_range_syntax_detection_in_extract_step
	test_range_syntax_guard_in_update_step
	test_range_guard_precedes_for_ref_guard

	printf '\nBehavioural cases (A-F + real-world replay):\n'
	test_case_a_baseline_resolves
	test_case_b_for_ref_only
	test_case_c_range_plus_for
	test_case_d_range_plus_closes_belt_and_braces
	test_case_e_single_task_id_not_range
	test_case_f_comma_range_syntax
	test_pr_19814_replay

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
