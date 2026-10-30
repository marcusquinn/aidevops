#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-title-prefix.sh — t2720 regression tests.
#
# Verifies _derive_pr_title_prefix() prefers the tNNN token from TODO.md
# over the GH#NNN fallback so issue-sync.yml's PR-merge auto-completion
# regex (which extracts task_id anchored on ^tNNN) can flip the TODO
# checkbox from [ ] to [x] when the merged PR lands.
#
# Test cases:
#   Case 1: open tNNN entry with matching ref:GH#N → tNNN
#   Case 2: completed [x] tNNN entry → tNNN (still matches)
#   Case 3: tNNN entry with a different ref → GH#N fallback
#   Case 4: TODO.md missing → GH#N fallback
#   Case 5: empty issue_number → "GH#" fallback
#   Case 6: multiple entries for same issue → first in file-order wins
#   Case 7: prefix-collision guard — 1234 must not match 12345

# NOTE: not using `set -e` — negative assertions rely on non-zero exits.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

# Sandbox
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

# Extract _derive_pr_title_prefix from the helper (same pattern as
# test-full-loop-parent-task.sh). Function ends on a column-0 `}`.
eval "$(sed -n '/^_derive_pr_title_prefix()/,/^}/p' "${TEST_SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# ============================================================================
# Case 1: open tNNN entry with matching ref:GH#N → tNNN
# ============================================================================
TODO1="${TEST_ROOT}/TODO-case1.md"
cat >"$TODO1" <<'EOF'
# TODO

- [ ] t2720 Prefer tNNN over GH#N in auto-derived PR title @marcus #framework ref:GH#20395 #auto-dispatch
- [ ] t2721 Unrelated @marcus ref:GH#20400
EOF
result=$(_derive_pr_title_prefix "20395" "$TODO1")
if [[ "$result" == "t2720" ]]; then
	print_result "Case 1: open entry with matching ref → tNNN" 0
else
	print_result "Case 1: open entry with matching ref → tNNN" 1 "(got: ${result})"
fi

# ============================================================================
# Case 2: completed [x] tNNN entry → still tNNN
# ============================================================================
TODO2="${TEST_ROOT}/TODO-case2.md"
cat >"$TODO2" <<'EOF'
- [x] t2717 Completed work @marcus ref:GH#20384 pr:#20387 completed:2026-04-21
EOF
result=$(_derive_pr_title_prefix "20384" "$TODO2")
if [[ "$result" == "t2717" ]]; then
	print_result "Case 2: completed [x] entry → tNNN" 0
else
	print_result "Case 2: completed [x] entry → tNNN" 1 "(got: ${result})"
fi

# ============================================================================
# Case 3: tNNN entry but a different ref → GH#N fallback
# ============================================================================
TODO3="${TEST_ROOT}/TODO-case3.md"
cat >"$TODO3" <<'EOF'
- [ ] t2720 Work ref:GH#20395
EOF
result=$(_derive_pr_title_prefix "99999" "$TODO3")
if [[ "$result" == "GH#99999" ]]; then
	print_result "Case 3: no matching ref → GH#N fallback" 0
else
	print_result "Case 3: no matching ref → GH#N fallback" 1 "(got: ${result})"
fi

# ============================================================================
# Case 4: TODO.md missing → GH#N fallback
# ============================================================================
result=$(_derive_pr_title_prefix "12345" "${TEST_ROOT}/does-not-exist.md")
if [[ "$result" == "GH#12345" ]]; then
	print_result "Case 4: missing TODO.md → GH#N fallback" 0
else
	print_result "Case 4: missing TODO.md → GH#N fallback" 1 "(got: ${result})"
fi

# ============================================================================
# Case 5: empty issue_number → "GH#" fallback (degenerate but defined)
# ============================================================================
result=$(_derive_pr_title_prefix "" "$TODO1")
if [[ "$result" == "GH#" ]]; then
	print_result "Case 5: empty issue_number → GH# fallback" 0
else
	print_result "Case 5: empty issue_number → GH# fallback" 1 "(got: ${result})"
fi

# ============================================================================
# Case 6: multiple entries for same issue → first in file-order wins
# ============================================================================
TODO6="${TEST_ROOT}/TODO-case6.md"
cat >"$TODO6" <<'EOF'
- [ ] t0100 First plan entry ref:GH#555
- [ ] t0200 Second impl entry ref:GH#555
EOF
result=$(_derive_pr_title_prefix "555" "$TODO6")
if [[ "$result" == "t0100" ]]; then
	print_result "Case 6: multiple matches → first wins" 0
else
	print_result "Case 6: multiple matches → first wins" 1 "(got: ${result})"
fi

# ============================================================================
# Case 7: prefix-collision guard — ref:GH#12345 must not match query 1234
# ============================================================================
TODO7="${TEST_ROOT}/TODO-case7.md"
cat >"$TODO7" <<'EOF'
- [ ] t9999 Issue 12345 entry ref:GH#12345
EOF
# Query for 1234 (prefix of 12345) — MUST NOT match
result=$(_derive_pr_title_prefix "1234" "$TODO7")
if [[ "$result" == "GH#1234" ]]; then
	print_result "Case 7: prefix-collision guard (1234 != 12345)" 0
else
	print_result "Case 7: prefix-collision guard (1234 != 12345)" 1 "(got: ${result})"
fi

# Query for 12345 exactly — MUST match
result=$(_derive_pr_title_prefix "12345" "$TODO7")
if [[ "$result" == "t9999" ]]; then
	print_result "Case 7b: exact match 12345 → t9999" 0
else
	print_result "Case 7b: exact match 12345 → t9999" 1 "(got: ${result})"
fi

# Explicit --title validation (GH#36016). No network or real push/PR writes.
eval "$(sed -n '/^_validate_explicit_pr_title()/,/^}/p' "${TEST_SCRIPTS_DIR}/full-loop-helper.sh")"
print_warning() {
	printf 'WARNING: %s\n' "$*" >&2
	return 0
}
print_error() {
	printf 'ERROR: %s\n' "$*" >&2
	return 0
}
ISSUE_TITLE="Issue-only work"
ISSUE_LOOKUP_RC=0
gh() {
	printf '%s\n' "$ISSUE_TITLE"
	if [[ "$ISSUE_LOOKUP_RC" -ne 0 ]]; then
		return 1
	fi
	return 0
}
TITLE_TODO="${TEST_ROOT}/titles.md"
cat >"$TITLE_TODO" <<'EOF'
- [ ] t100 First matching task ref:GH#123
- [x] t456 Another valid task ref:GH#123
- [ ] t789 Wrong issue ref:GH#1234
- [ ] t4560 Longer task ref:GH#124
EOF

check_title() {
	local name="$1" title="$2" expected="$3" expected_rc="$4" expected_warnings="$5"
	local actual="" rc=0 warnings=0
	actual=$(_validate_explicit_pr_title 123 "$title" example/repo "$TITLE_TODO" 2>"${TEST_ROOT}/title-stderr") || rc=$?
	warnings=$(grep -c '^WARNING:' "${TEST_ROOT}/title-stderr" || true)
	if [[ "$actual" == "$expected" && "$rc" -eq "$expected_rc" && "$warnings" -eq "$expected_warnings" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "(got: ${actual}, rc=${rc}, warnings=${warnings})"
	fi
	return 0
}

check_title "Issue-number prefix is corrected once to derived task prefix" "t123: x" "t100: x" 0 1
check_title "Any exact TODO task/issue match is accepted" "t456: x" "t456: x" 0 0
check_title "Different issue ref is not proof" "t789: x" "" 1 0
check_title "Task prefix of a longer TODO ID is not proof" "t45: x" "" 1 0
if grep -q 'Use.*--title t100:' "${TEST_ROOT}/title-stderr"; then
	print_result "Rejected title includes the derived-prefix remedy" 0
else
	print_result "Rejected title includes the derived-prefix remedy" 1
fi
check_title "GH issue prefix stays unchanged" "GH#123: x" "GH#123: x" 0 0
check_title "Unprefixed title stays unchanged" "x" "x" 0 0
TITLE_TODO="${TEST_ROOT}/missing.md"
ISSUE_TITLE="Implement t456: linked task"
check_title "Linked issue title supplies task proof" "t456: x" "t456: x" 0 0
ISSUE_TITLE="Implement t123: same-number claimed task"
check_title "Proven same-number task stays unchanged" "t123: x" "t123: x" 0 0
ISSUE_TITLE="Implement t4560: different task"
check_title "Linked issue task match has a token boundary" "t456: x" "" 1 0
check_title "Unproven task fails with no title output" "t999: x" "" 1 0
check_title "Issue-only t123 is rewritten as GH#123 with one warning" "t123: x" "GH#123: x" 0 1
check_title "Issue-title longer ID does not prove shorter task" "t456: x" "" 1 0
ISSUE_TITLE=""
check_title "Successful empty title does not prove unrelated task" "t456: x" "" 1 0
check_title "Successful empty title permits issue-number rewrite" "t123: x" "GH#123: x" 0 1
ISSUE_LOOKUP_RC=1
check_title "Failed lookup blocks issue-number rewrite" "t123: x" "" 1 0
check_title "Failed lookup rejects unrelated task" "t456: x" "" 1 0
ISSUE_TITLE="Implement t123: partial output from failed lookup"
check_title "Failed lookup cannot supply task proof" "t123: x" "" 1 0
TITLE_TODO="${TEST_ROOT}/titles.md"
check_title "TODO proof does not require issue-title lookup" "t456: x" "t456: x" 0 0

# ============================================================================
# Summary
# ============================================================================
echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%s%d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
