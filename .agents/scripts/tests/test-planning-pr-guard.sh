#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-planning-pr-guard.sh — GH#19782 / t2252 regression guard.
#
# Validates the two code paths that protect planning-only PRs from
# incorrectly marking issues as status:done or TODO entries as [x], while
# allowing blocker provenance after every declared dependency is closed:
#
#   Path 1 — Title-fallback (issue labeling):
#     Fixed in t2219 (PR #19820). When the PR body uses For/Ref #NNN
#     references, the title-fallback search in sync-on-pr-merge skips
#     those issues instead of applying status:done.
#
#   Path 2 — TODO.md proof-log:
#     Fixed in t2252 (this guard's target). When LINKED_ISSUES is empty
#     (no Closes/Fixes/Resolves) and FOR_REF_ISSUES is non-empty (has
#     For/Ref references), the proof-log step exits early instead of
#     marking the task [x] in TODO.md.
#
# Production failure (PR #19781 → GH#19778):
#   PR #19781 had title "t2349+t2350+t2351: briefs for ..." and body
#   "Ref #19778, Ref #19779, Ref #19780". After merge, #19778 incorrectly
#   received status:done + "Completed via PR #19781" comment. The issue
#   became invisible to pulse dispatch until manually reset.
#
# Tests:
#   1. Planning-only PR (For/Ref only, no Closes) → proof-log skipped
#   2. Implementation PR (Closes #NNN) → proof-log proceeds
#   3. Mixed PR (Closes + For/Ref) → proof-log proceeds (closing signal wins)
#   4. No references at all → proof-log skipped (metadata-only title)
#   5. Title-fallback: For/Ref issue in list → title-fallback skipped
#   6. Title-fallback: issue NOT in For/Ref list → title-fallback skipped
#
# Strategy: test the decision logic extracted from issue-sync.yml inline
# bash. The workflow is CI-only; these tests validate the branching
# conditions without requiring a full workflow run.

set -uo pipefail

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	return 0
}

header() {
	local title="$1"
	printf '\n%s=== %s ===%s\n' "$TEST_BLUE" "$title" "$TEST_NC"
	return 0
}

# -------------------------------------------------------------------
# Path 2: TODO.md proof-log guard
# Decision: skip proof-log when LINKED_ISSUES is empty AND
#           FOR_REF_ISSUES is non-empty.
# -------------------------------------------------------------------
#
# Extracted from issue-sync.yml sync-on-pr-merge "Update TODO.md proof-log":
#   if [[ -z "${LINKED_ISSUES:-}" ]] && [[ -n "${FOR_REF_ISSUES:-}" ]]; then
#     exit 0  # skip
#   fi

should_skip_prooflog() {
	local linked_issues="$1"
	local for_ref_issues="$2"
	local task_line="${3:-}"
	local repo="${4:-owner/repo}"
	local task_id="${5:-t900}"
	local issue_task_pairs="${6-19778:t900}"
	local issue_task_pair="" mapped_issue_num="" mapping_count=0 blocker_status=0
	if [[ -z "${linked_issues:-}" ]]; then
		return 0 # skip (no explicit closing intent)
	fi
	if echo "$task_line" | grep -qE '(^|[[:space:]])blocked-by:[^[:space:]]+'; then
		for issue_task_pair in $issue_task_pairs; do
			if [[ "${issue_task_pair#*:}" == "$task_id" ]]; then
				mapped_issue_num="${issue_task_pair%%:*}"
				mapping_count=$((mapping_count + 1))
			fi
		done
		[[ "$mapping_count" -eq 1 && "$mapped_issue_num" =~ ^[0-9]+$ ]] || return 0
		_der_completion_blockers_closed "$repo" "$mapped_issue_num" "$task_line" || blocker_status=$?
		[[ "$blocker_status" -eq 0 ]] || return 0
	fi
	if [[ -z "${linked_issues:-}" ]] && [[ -n "${for_ref_issues:-}" ]]; then
		return 0 # skip (planning-only)
	fi
	return 1 # proceed
}

should_skip_closing_hygiene_for_task() {
	local task_line="$1"
	local repo="${2:-owner/repo}"
	local issue_num="${3:-19778}"
	local blocker_status=0
	if echo "$task_line" | grep -qE '^[[:space:]]*- \[ \] .*blocked-by:[^[:space:]]+'; then
		_der_completion_blockers_closed "$repo" "$issue_num" "$task_line" || blocker_status=$?
		[[ "$blocker_status" -eq 0 ]] || return 0
	fi
	return 1
}

BLOCKER_RESULT="resolved"
LAST_BLOCKER_CALL=""
_der_completion_blockers_closed() {
	local repo="$1"
	local issue_num="$2"
	local task_line="$3"
	LAST_BLOCKER_CALL="${repo}|${issue_num}|${task_line}"
	case "$BLOCKER_RESULT" in
	resolved) return 0 ;;
	open) return 2 ;;
	malformed | api-ambiguous | cross-repository) return 1 ;;
	*) return 1 ;;
	esac
}

header "Path 2: TODO.md proof-log guard (t2252)"

# Test 1: Planning-only PR — For/Ref only, no Closes
if should_skip_prooflog "" "19778 19779 19780"; then
	pass "1. Planning-only PR (For/Ref only) → proof-log skipped"
else
	fail "1. Planning-only PR (For/Ref only) → should skip but didn't"
fi

# Test 2: Implementation PR — Closes #NNN present
if should_skip_prooflog "19778" ""; then
	fail "2. Implementation PR (Closes #NNN) → should proceed but skipped"
else
	pass "2. Implementation PR (Closes #NNN) → proof-log proceeds"
fi

# Test 3: Mixed PR — both Closes and For/Ref
if should_skip_prooflog "19778" "19779"; then
	fail "3. Mixed PR (Closes + For/Ref) → should proceed but skipped"
else
	pass "3. Mixed PR (Closes + For/Ref) → proof-log proceeds"
fi

# Test 4: No references at all — fallback behavior
if should_skip_prooflog "" ""; then
	pass "4. No references → proof-log skipped (metadata-only title)"
else
	fail "4. No references → should skip metadata-only title but proceeded"
fi

# Test 4b: Explicit Closes and positively closed blocker provenance
BLOCKER_RESULT="resolved"
if should_skip_prooflog "19778" "" "- [ ] t900 blocked task tier:standard blocked-by:t899"; then
	fail "4b. Positively closed blocker → proof-log should proceed"
else
	pass "4b. Positively closed blocker → proof-log proceeds"
fi

if should_skip_closing_hygiene_for_task "- [ ] t900 blocked task tier:standard blocked-by:t899"; then
	fail "4c. Positively closed blocker → closing hygiene should proceed"
else
	pass "4c. Positively closed blocker → closing hygiene proceeds"
fi

issue_body_example='Issue reproducer mentions blocked-by:t899 in prose, not on the current TODO task line.'
if should_skip_closing_hygiene_for_task "$issue_body_example"; then
	fail "4d. Issue-body prose blocked-by mention → should not skip closing hygiene"
else
	pass "4d. Issue-body prose blocked-by mention → closing hygiene proceeds"
fi

for blocker_case in open malformed api-ambiguous cross-repository; do
	BLOCKER_RESULT="$blocker_case"
	if should_skip_prooflog "19778" "" "- [ ] t900 blocked task tier:standard blocked-by:t899"; then
		pass "4e. ${blocker_case} blocker result → proof-log fails closed"
	else
		fail "4e. ${blocker_case} blocker result → proof-log should skip"
	fi
	if should_skip_closing_hygiene_for_task "- [ ] t900 blocked task tier:standard blocked-by:t899"; then
		pass "4f. ${blocker_case} blocker result → closing hygiene fails closed"
	else
		fail "4f. ${blocker_case} blocker result → closing hygiene should skip"
	fi
done

BLOCKER_RESULT="resolved"
if should_skip_prooflog "19779" "" "- [ ] t901 second task tier:standard blocked-by:t899" \
	"owner/repo" "t901" "19778:t900 19779:t901"; then
	fail "4g. Multiple task/issue pairs → canonical second mapping should proceed"
elif [[ "$LAST_BLOCKER_CALL" == "owner/repo|19779|"* ]]; then
	pass "4g. Multiple task/issue pairs → canonical second mapping proceeds"
else
	fail "4g. Multiple task/issue pairs → wrong canonical issue passed to resolver"
fi

if should_skip_prooflog "19778" "" "- [ ] t900 blocked task tier:standard blocked-by:t899" \
	"owner/repo" "t900" ""; then
	pass "4h. Missing task/issue mapping → proof-log fails closed"
else
	fail "4h. Missing task/issue mapping → proof-log should skip"
fi
if should_skip_prooflog "19778" "" "- [ ] t900 blocked task tier:standard blocked-by:t899" \
	"owner/repo" "t900" "19778:t900 19779:t900"; then
	pass "4i. Ambiguous task/issue mapping → proof-log fails closed"
else
	fail "4i. Ambiguous task/issue mapping → proof-log should skip"
fi

WORKFLOW_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/.github/workflows/issue-sync-reusable.yml"
if python3 - "$WORKFLOW_FILE" <<'PY'; then
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
closing = text[text.index("- name: Apply closing hygiene to linked issues"):text.index("- name: Nudge parent-task issues with remaining phases")]
proof = text[text.index("- name: Update TODO.md proof-log"):text.index("- name: Sync PLANS.md status")]
assert "source __aidevops/.agents/scripts/dependency-event-reconciler.sh" in closing
assert '_der_completion_blockers_closed "$REPO" "$ISSUE_NUM" "$TASK_LINE"' in closing
assert "ISSUE_TASK_PAIRS:" in proof and "REPO:" in proof
assert "source __aidevops/.agents/scripts/dependency-event-reconciler.sh" in proof
assert '_der_completion_blockers_closed "$REPO" "$MAPPED_ISSUE_NUM" "$TASK_LINE"' in proof
PY
	pass "4j. Both workflow completion consumers use the shared semantic resolver"
else
	fail "4j. Workflow completion consumers are not wired to the shared resolver"
fi

# -------------------------------------------------------------------
# Path 1: Title-fallback guard (t2219)
# Decision: skip title-fallback when the found issue number is in
#           the FOR_REF_ISSUES space-delimited list.
# -------------------------------------------------------------------
#
# Extracted from issue-sync.yml sync-on-pr-merge "Find issue by task ID":
#   elif [[ " $FOR_REF_ISSUES " == *" $FOUND "* ]]; then
#     echo "found_issues=" >> "$GITHUB_OUTPUT"

should_skip_title_fallback() {
	local found="$1"
	local for_ref_issues="$2"
	if [[ -n "$found" ]]; then
		return 0 # skip: title-only fallback is metadata, not completion intent
	fi
	if [[ " $for_ref_issues " == *" $found "* ]]; then
		return 0 # skip
	fi
	return 1 # proceed
}

header "Path 1: Title-fallback guard (t2219)"

# Test 5: Found issue IS in For/Ref list → skip
if should_skip_title_fallback "19778" "19778 19779 19780"; then
	pass "5. Found issue in For/Ref list → title-fallback skipped"
else
	fail "5. Found issue in For/Ref list → should skip but didn't"
fi

# Test 6: Found issue NOT in For/Ref list → proceed
if should_skip_title_fallback "19999" "19778 19779 19780"; then
	pass "6. Found issue not in For/Ref list → title-fallback skipped (metadata-only)"
else
	fail "6. Found issue not in For/Ref list → should skip metadata-only fallback"
fi

# Test 7: Empty For/Ref list → proceed (no planning references)
if should_skip_title_fallback "19778" ""; then
	pass "7. Empty For/Ref list → title-fallback skipped (metadata-only)"
else
	fail "7. Empty For/Ref list → should skip metadata-only fallback"
fi

# -------------------------------------------------------------------
# Path 3: Closing keyword extraction (regression guard for extract step)
# Validates that the grep patterns correctly separate Closes/Fixes/Resolves
# from For/Ref references.
# -------------------------------------------------------------------

extract_linked_issues() {
	local pr_body="$1"
	echo "$pr_body" | grep -oiE '(closes?|fixes?|resolves?)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true
}

extract_for_ref_issues() {
	local pr_body="$1"
	echo "$pr_body" | grep -oiE '(for|ref)[[:space:]]*#[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true
}

header "Path 3: Keyword extraction (regression guard)"

# Test 8: Body with only Ref keywords
BODY_REF_ONLY="Ref #19778, Ref #19779, Ref #19780"
LINKED=$(extract_linked_issues "$BODY_REF_ONLY")
FOR_REF=$(extract_for_ref_issues "$BODY_REF_ONLY")
if [[ -z "${LINKED// /}" ]] && [[ -n "${FOR_REF// /}" ]]; then
	pass "8. Ref-only body → LINKED_ISSUES empty, FOR_REF_ISSUES populated"
else
	fail "8. Ref-only body → LINKED='$LINKED' FOR_REF='$FOR_REF'"
fi

# Test 9: Body with Closes keyword
BODY_CLOSES="Closes #19778"
LINKED=$(extract_linked_issues "$BODY_CLOSES")
FOR_REF=$(extract_for_ref_issues "$BODY_CLOSES")
if [[ -n "${LINKED// /}" ]] && [[ -z "${FOR_REF// /}" ]]; then
	pass "9. Closes body → LINKED_ISSUES populated, FOR_REF_ISSUES empty"
else
	fail "9. Closes body → LINKED='$LINKED' FOR_REF='$FOR_REF'"
fi

# Test 10: Body with mixed keywords
BODY_MIXED="Resolves #19778
For #19779
Ref #19780"
LINKED=$(extract_linked_issues "$BODY_MIXED")
FOR_REF=$(extract_for_ref_issues "$BODY_MIXED")
if [[ -n "${LINKED// /}" ]] && [[ -n "${FOR_REF// /}" ]]; then
	pass "10. Mixed body → both LINKED and FOR_REF populated"
else
	fail "10. Mixed body → LINKED='$LINKED' FOR_REF='$FOR_REF'"
fi

# Test 11: Body with no keywords
BODY_NONE="This PR adds some documentation."
LINKED=$(extract_linked_issues "$BODY_NONE")
FOR_REF=$(extract_for_ref_issues "$BODY_NONE")
if [[ -z "${LINKED// /}" ]] && [[ -z "${FOR_REF// /}" ]]; then
	pass "11. No-keyword body → both empty"
else
	fail "11. No-keyword body → LINKED='$LINKED' FOR_REF='$FOR_REF'"
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
