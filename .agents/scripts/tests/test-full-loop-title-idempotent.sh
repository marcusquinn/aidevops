#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-title-idempotent.sh — t2825/RC3 regression tests.
#
# Verifies _compose_pr_title() is idempotent: when the commit_message
# already starts with a task-ID prefix (tNNN: or GH#NNN:), the helper
# must return it verbatim instead of double-prefixing.
#
# Canonical failure this guards: PR #20817 was created with title
# "t2799: t2799: split RATE_LIMIT_PATTERNS..." because an interactive
# `commit-and-pr --message "t2799: ..."` call unconditionally prepended
# another tNNN: via the previous _derive_pr_title_prefix call site.
#
# Test cases:
#   Case 1: tNNN-prefixed message → verbatim (the RC3 bug)
#   Case 2: GH#NNN-prefixed message → verbatim
#   Case 3: unprefixed message + matching TODO entry → tNNN: prefix prepended
#   Case 4: unprefixed message + no TODO match → GH#NNN: prefix prepended
#   Case 5: prefix-like substring mid-line must NOT short-circuit
#           (e.g. "follow-up to t2799: extend coverage" → fresh prefix prepended)
#   Case 6: capitalised "T2799:" must NOT short-circuit (regex is case-sensitive)
#   Case 7: missing colon after the token must NOT short-circuit
#           (e.g. "t2799 fix something" → fresh prefix prepended)

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

# Extract _derive_pr_title_prefix and _compose_pr_title from the helper
# (same eval-extract pattern as test-full-loop-title-prefix.sh).
# Each function ends on a column-0 `}`.
eval "$(sed -n '/^_derive_pr_title_prefix()/,/^}/p' "${TEST_SCRIPTS_DIR}/full-loop-helper.sh")"
eval "$(sed -n '/^_compose_pr_title()/,/^}/p' "${TEST_SCRIPTS_DIR}/full-loop-helper.sh")"

# Shared TODO fixture used by cases that need a TODO match.
TODO_MAIN="${TEST_ROOT}/TODO-main.md"
cat >"$TODO_MAIN" <<'EOF'
# TODO

- [ ] t2825 Idempotent task-ID prefix in commit-and-pr @marcus #framework ref:GH#20836 #auto-dispatch
- [ ] t2826 Unrelated entry @marcus ref:GH#20900
EOF

# ============================================================================
# Case 1: tNNN-prefixed message → verbatim (the RC3 bug)
# ============================================================================
result=$(_compose_pr_title "20836" "t2825: idempotent task-ID prefix in commit-and-pr" "$TODO_MAIN")
expected="t2825: idempotent task-ID prefix in commit-and-pr"
if [[ "$result" == "$expected" ]]; then
	print_result "Case 1: tNNN-prefixed message → verbatim" 0
else
	print_result "Case 1: tNNN-prefixed message → verbatim" 1 "(got: ${result})"
fi

# ============================================================================
# Case 2: GH#NNN-prefixed message → verbatim
# ============================================================================
result=$(_compose_pr_title "12455" "GH#12455: tighten hashline-edit-format.md" "$TODO_MAIN")
expected="GH#12455: tighten hashline-edit-format.md"
if [[ "$result" == "$expected" ]]; then
	print_result "Case 2: GH#NNN-prefixed message → verbatim" 0
else
	print_result "Case 2: GH#NNN-prefixed message → verbatim" 1 "(got: ${result})"
fi

# ============================================================================
# Case 3: unprefixed message + matching TODO entry → tNNN: prefix prepended
# ============================================================================
result=$(_compose_pr_title "20836" "idempotent task-ID prefix in commit-and-pr" "$TODO_MAIN")
expected="t2825: idempotent task-ID prefix in commit-and-pr"
if [[ "$result" == "$expected" ]]; then
	print_result "Case 3: unprefixed + TODO match → tNNN prepended" 0
else
	print_result "Case 3: unprefixed + TODO match → tNNN prepended" 1 "(got: ${result})"
fi

# ============================================================================
# Case 4: unprefixed message + no TODO match → GH#NNN: prefix prepended
# ============================================================================
result=$(_compose_pr_title "99999" "fix something obscure" "$TODO_MAIN")
expected="GH#99999: fix something obscure"
if [[ "$result" == "$expected" ]]; then
	print_result "Case 4: unprefixed + no TODO match → GH#NNN prepended" 0
else
	print_result "Case 4: unprefixed + no TODO match → GH#NNN prepended" 1 "(got: ${result})"
fi

# ============================================================================
# Case 5: prefix-like substring mid-line must NOT short-circuit
# ============================================================================
result=$(_compose_pr_title "20836" "follow-up to t2799: extend coverage" "$TODO_MAIN")
expected="t2825: follow-up to t2799: extend coverage"
if [[ "$result" == "$expected" ]]; then
	print_result "Case 5: mid-line tNNN must not short-circuit" 0
else
	print_result "Case 5: mid-line tNNN must not short-circuit" 1 "(got: ${result})"
fi

# ============================================================================
# Case 6: capitalised "T2799:" must NOT short-circuit (case-sensitive regex)
# ============================================================================
result=$(_compose_pr_title "20836" "T2799: edge case capitalisation" "$TODO_MAIN")
expected="t2825: T2799: edge case capitalisation"
if [[ "$result" == "$expected" ]]; then
	print_result "Case 6: capital T must not short-circuit" 0
else
	print_result "Case 6: capital T must not short-circuit" 1 "(got: ${result})"
fi

# ============================================================================
# Case 7: missing colon after the token must NOT short-circuit
# ============================================================================
result=$(_compose_pr_title "20836" "t2799 fix something" "$TODO_MAIN")
expected="t2825: t2799 fix something"
if [[ "$result" == "$expected" ]]; then
	print_result "Case 7: missing colon must not short-circuit" 0
else
	print_result "Case 7: missing colon must not short-circuit" 1 "(got: ${result})"
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
