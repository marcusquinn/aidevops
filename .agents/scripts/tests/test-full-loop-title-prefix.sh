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
eval "$(sed -n '/^_derive_pr_title_prefix()/,/^}/p' "${TEST_SCRIPTS_DIR}/full-loop-helper.sh")"

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
