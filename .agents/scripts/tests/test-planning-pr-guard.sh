#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-planning-pr-guard.sh — t2252 regression guard.
#
# Validates that planning-only PRs (containing only brief/planning files)
# do NOT trigger auto-completion of referenced issues in the
# sync-on-pr-merge workflow. Tests three cases from the acceptance criteria:
#
#   1. Planning-only PR with Ref/For keywords → NO auto-completion
#   2. PR with Resolves/Closes keywords → auto-completion proceeds
#   3. Mixed PR (brief + implementation) → closing-keyword signal used
#
# Failure history: GH#19782 — PR #19781 filed 3 briefs using Ref #NNN
# but the title-fallback match in sync-on-pr-merge falsely marked
# issue #19778 as status:done, silently blocking pulse dispatch.
#
# The test extracts the decision logic from issue-sync.yml and runs it
# in isolation (no GitHub API calls required).

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# =============================================================================
# Helper: extract closing keywords from PR body (mirrors extract step)
# =============================================================================
extract_linked_issues() {
	local pr_body="$1"
	echo "$pr_body" | grep -oiE '(closes?|fixes?|resolves?)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true
	return 0
}

# =============================================================================
# Helper: extract non-closing references from PR body (t2252)
# =============================================================================
extract_non_closing_refs() {
	local pr_body="$1"
	echo "$pr_body" | grep -oiE '(for|ref)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true
	return 0
}

# =============================================================================
# Helper: detect planning-only PR from file list (t2252)
# =============================================================================
is_planning_only_pr() {
	local changed_files="$1"
	local is_planning=true
	while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		if ! echo "$file" | grep -qE '^(todo/tasks/.*-brief\.md|todo/PLANS\.md|TODO\.md)$'; then
			is_planning=false
			break
		fi
	done <<< "$changed_files"
	echo "$is_planning"
	return 0
}

# =============================================================================
# Helper: decide if title-fallback found issue should be auto-completed (t2252)
# Returns: "skip" or "proceed"
# =============================================================================
should_skip_title_fallback() {
	local found_issue_num="$1"
	local non_closing_refs="$2"
	local planning_only="$3"

	# Planning-only PRs never use the title-fallback path
	if [[ "$planning_only" == "true" ]]; then
		echo "skip"
		return 0
	fi

	# Issue explicitly referenced with For/Ref in PR body — author chose
	# not to close it
	if echo " $non_closing_refs " | grep -q " $found_issue_num "; then
		echo "skip"
		return 0
	fi

	echo "proceed"
	return 0
}

# =============================================================================
# Part 1 — Planning-only PR detection
# =============================================================================
echo "--- Part 1: Planning-only PR detection ---"

# Case 1a: Only brief files → planning-only
FILES_BRIEF_ONLY="todo/tasks/t2349-brief.md
todo/tasks/t2350-brief.md
todo/tasks/t2351-brief.md"
RESULT=$(is_planning_only_pr "$FILES_BRIEF_ONLY")
if [[ "$RESULT" == "true" ]]; then
	print_result "brief-only files detected as planning-only" 0
else
	print_result "brief-only files detected as planning-only" 1 "(got: $RESULT)"
fi

# Case 1b: Brief + implementation files → NOT planning-only
FILES_MIXED="todo/tasks/t2349-brief.md
.agents/scripts/issue-sync-helper.sh
.github/workflows/issue-sync.yml"
RESULT=$(is_planning_only_pr "$FILES_MIXED")
if [[ "$RESULT" == "false" ]]; then
	print_result "mixed files NOT detected as planning-only" 0
else
	print_result "mixed files NOT detected as planning-only" 1 "(got: $RESULT)"
fi

# Case 1c: Only implementation files → NOT planning-only
FILES_IMPL_ONLY=".agents/scripts/issue-sync-helper.sh
.github/workflows/issue-sync.yml"
RESULT=$(is_planning_only_pr "$FILES_IMPL_ONLY")
if [[ "$RESULT" == "false" ]]; then
	print_result "implementation-only files NOT detected as planning-only" 0
else
	print_result "implementation-only files NOT detected as planning-only" 1 "(got: $RESULT)"
fi

# Case 1d: Brief + TODO.md + PLANS.md → planning-only
FILES_PLANNING="todo/tasks/t2349-brief.md
TODO.md
todo/PLANS.md"
RESULT=$(is_planning_only_pr "$FILES_PLANNING")
if [[ "$RESULT" == "true" ]]; then
	print_result "brief+TODO+PLANS detected as planning-only" 0
else
	print_result "brief+TODO+PLANS detected as planning-only" 1 "(got: $RESULT)"
fi

# =============================================================================
# Part 2 — Non-closing reference extraction
# =============================================================================
echo ""
echo "--- Part 2: Non-closing reference extraction ---"

# Case 2a: Ref #NNN extracted
BODY_REF="Some description. Ref #19778, Ref #19779, Ref #19780"
RESULT=$(extract_non_closing_refs "$BODY_REF")
if echo "$RESULT" | grep -q "19778" && echo "$RESULT" | grep -q "19779" && echo "$RESULT" | grep -q "19780"; then
	print_result "Ref #NNN references extracted" 0
else
	print_result "Ref #NNN references extracted" 1 "(got: '$RESULT')"
fi

# Case 2b: For #NNN extracted
BODY_FOR="For #12345 planning brief"
RESULT=$(extract_non_closing_refs "$BODY_FOR")
if echo "$RESULT" | grep -q "12345"; then
	print_result "For #NNN reference extracted" 0
else
	print_result "For #NNN reference extracted" 1 "(got: '$RESULT')"
fi

# Case 2c: Closing keywords NOT extracted as non-closing
BODY_CLOSES="Closes #99999 and Resolves #88888"
RESULT=$(extract_non_closing_refs "$BODY_CLOSES")
RESULT_TRIMMED=$(echo "$RESULT" | tr -d '[:space:]')
if [[ -z "$RESULT_TRIMMED" ]]; then
	print_result "Closes/Resolves NOT extracted as non-closing" 0
else
	print_result "Closes/Resolves NOT extracted as non-closing" 1 "(got: '$RESULT')"
fi

# Case 2d: Mixed body — only For/Ref extracted as non-closing
BODY_MIXED="Resolves #11111. Ref #22222, For #33333"
RESULT_NC=$(extract_non_closing_refs "$BODY_MIXED")
RESULT_CL=$(extract_linked_issues "$BODY_MIXED")
if echo "$RESULT_NC" | grep -q "22222" && echo "$RESULT_NC" | grep -q "33333" && ! echo "$RESULT_NC" | grep -q "11111"; then
	print_result "mixed body: non-closing refs correct" 0
else
	print_result "mixed body: non-closing refs correct" 1 "(got NC: '$RESULT_NC')"
fi
if echo "$RESULT_CL" | grep -q "11111" && ! echo "$RESULT_CL" | grep -q "22222"; then
	print_result "mixed body: closing refs correct" 0
else
	print_result "mixed body: closing refs correct" 1 "(got CL: '$RESULT_CL')"
fi

# =============================================================================
# Part 3 — Title-fallback skip decision
# =============================================================================
echo ""
echo "--- Part 3: Title-fallback skip decision ---"

# Case 3a: Planning-only PR → always skip title-fallback
RESULT=$(should_skip_title_fallback "19778" "" "true")
if [[ "$RESULT" == "skip" ]]; then
	print_result "planning-only PR skips title-fallback" 0
else
	print_result "planning-only PR skips title-fallback" 1 "(got: $RESULT)"
fi

# Case 3b: Found issue in non-closing refs → skip
RESULT=$(should_skip_title_fallback "19778" "19778 19779 19780 " "false")
if [[ "$RESULT" == "skip" ]]; then
	print_result "non-closing ref issue skips title-fallback" 0
else
	print_result "non-closing ref issue skips title-fallback" 1 "(got: $RESULT)"
fi

# Case 3c: Found issue NOT in non-closing refs, not planning-only → proceed
RESULT=$(should_skip_title_fallback "19778" "99999 " "false")
if [[ "$RESULT" == "proceed" ]]; then
	print_result "unrelated non-closing refs: title-fallback proceeds" 0
else
	print_result "unrelated non-closing refs: title-fallback proceeds" 1 "(got: $RESULT)"
fi

# Case 3d: No non-closing refs at all, not planning-only → proceed (existing behaviour)
RESULT=$(should_skip_title_fallback "19778" "" "false")
if [[ "$RESULT" == "proceed" ]]; then
	print_result "no refs at all: title-fallback proceeds (existing behaviour)" 0
else
	print_result "no refs at all: title-fallback proceeds (existing behaviour)" 1 "(got: $RESULT)"
fi

# =============================================================================
# Part 4 — End-to-end scenario simulation (GH#19782 reproduction)
# =============================================================================
echo ""
echo "--- Part 4: End-to-end scenario simulation ---"

# Scenario A: The GH#19782 bug — planning-only PR with Ref keywords
# PR title: "t2349+t2350+t2351: briefs for self-healing pulse framework improvements"
# PR body: "Ref #19778, Ref #19779, Ref #19780"
# Changed files: todo/tasks/t2349-brief.md, t2350-brief.md, t2351-brief.md
# Expected: NO auto-completion of any issue
PR_TITLE_A="t2349+t2350+t2351: briefs for self-healing pulse framework improvements"
PR_BODY_A="Filed briefs for self-healing pulse improvements.

Ref #19778, Ref #19779, Ref #19780"
FILES_A="todo/tasks/t2349-brief.md
todo/tasks/t2350-brief.md
todo/tasks/t2351-brief.md"

TASK_ID_A=$(echo "$PR_TITLE_A" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
LINKED_A=$(extract_linked_issues "$PR_BODY_A")
NON_CLOSING_A=$(extract_non_closing_refs "$PR_BODY_A")
PLANNING_A=$(is_planning_only_pr "$FILES_A")

# LINKED_A should be empty (no Closes/Fixes/Resolves)
LINKED_A_TRIMMED=$(echo "$LINKED_A" | tr -d '[:space:]')
if [[ -z "$LINKED_A_TRIMMED" ]]; then
	print_result "scenario A: no closing keywords detected" 0
else
	print_result "scenario A: no closing keywords detected" 1 "(got: '$LINKED_A')"
fi

# Planning-only check should fire
if [[ "$PLANNING_A" == "true" ]]; then
	print_result "scenario A: detected as planning-only" 0
else
	print_result "scenario A: detected as planning-only" 1 "(got: $PLANNING_A)"
fi

# Title-fallback for issue 19778 should be skipped
SKIP_A=$(should_skip_title_fallback "19778" "$NON_CLOSING_A" "$PLANNING_A")
if [[ "$SKIP_A" == "skip" ]]; then
	print_result "scenario A: issue #19778 NOT auto-completed (bug fixed)" 0
else
	print_result "scenario A: issue #19778 NOT auto-completed (bug fixed)" 1 "(got: $SKIP_A)"
fi

# Scenario B: Implementation PR with Resolves keyword
# PR body: "Resolves #19778"
# Changed files: .agents/scripts/fix.sh
# Expected: auto-completion proceeds
PR_BODY_B="Implemented the fix.

Resolves #19778"
FILES_B=".agents/scripts/fix.sh
.agents/scripts/tests/test-fix.sh"

LINKED_B=$(extract_linked_issues "$PR_BODY_B")
PLANNING_B=$(is_planning_only_pr "$FILES_B")

# Linked issues should include 19778
if echo "$LINKED_B" | grep -q "19778"; then
	print_result "scenario B: Resolves #19778 detected as closing keyword" 0
else
	print_result "scenario B: Resolves #19778 detected as closing keyword" 1 "(got: '$LINKED_B')"
fi
# NOT planning-only
if [[ "$PLANNING_B" == "false" ]]; then
	print_result "scenario B: implementation files NOT planning-only" 0
else
	print_result "scenario B: implementation files NOT planning-only" 1 "(got: $PLANNING_B)"
fi

# Scenario C: Mixed PR (brief + implementation) with selective keywords
# PR body: "Resolves #11111. Ref #22222"
# Changed files: todo/tasks/t123-brief.md, .agents/scripts/impl.sh
# Expected: #11111 auto-completed (closing keyword), #22222 NOT (For/Ref)
PR_BODY_C="Implemented task and filed a related brief.

Resolves #11111
Ref #22222"
FILES_C="todo/tasks/t123-brief.md
.agents/scripts/impl.sh"

LINKED_C=$(extract_linked_issues "$PR_BODY_C")
NON_CLOSING_C=$(extract_non_closing_refs "$PR_BODY_C")
PLANNING_C=$(is_planning_only_pr "$FILES_C")

# Not planning-only (has implementation files)
if [[ "$PLANNING_C" == "false" ]]; then
	print_result "scenario C: mixed PR NOT planning-only" 0
else
	print_result "scenario C: mixed PR NOT planning-only" 1 "(got: $PLANNING_C)"
fi

# #11111 in LINKED (closing keyword path — always processed)
if echo "$LINKED_C" | grep -q "11111"; then
	print_result "scenario C: #11111 auto-completed via Resolves" 0
else
	print_result "scenario C: #11111 auto-completed via Resolves" 1 "(got: '$LINKED_C')"
fi

# #22222 in NON_CLOSING (would be skipped by title-fallback guard)
SKIP_C=$(should_skip_title_fallback "22222" "$NON_CLOSING_C" "$PLANNING_C")
if [[ "$SKIP_C" == "skip" ]]; then
	print_result "scenario C: #22222 NOT auto-completed via Ref (non-closing)" 0
else
	print_result "scenario C: #22222 NOT auto-completed via Ref (non-closing)" 1 "(got: $SKIP_C)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Summary: $TESTS_RUN tests, $TESTS_FAILED failures ==="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
