#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-safe-grep-count.sh — unit tests for safe_grep_count() (t2763)
# counter-stack-check:disable — this file intentionally contains the anti-pattern
# in comment form to document and test against it.
#
# Verifies the safe_grep_count() helper from shared-constants.sh:
#   - empty stdin → 0
#   - no-match pattern → 0
#   - N matches → N
#   - nonexistent file → 0
#   - mixed grep flags (-E, -i) → correct count
#   - multi-line input → correct count
#   - output is a single integer (no stacking)
#
# Run: bash .agents/scripts/tests/test-safe-grep-count.sh
# Expected: all assertions pass, exit 0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SHARED_CONSTANTS="${REPO_ROOT}/.agents/scripts/shared-constants.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ── test framework ────────────────────────────────────────────────────

assert_eq() {
	local _test_name="$1"
	local _expected="$2"
	local _actual="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$_expected" == "$_actual" ]]; then
		printf 'PASS %s\n' "$_test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$_test_name"
		printf '     expected: %q\n' "$_expected"
		printf '     actual:   %q\n' "$_actual"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_single_line() {
	local _test_name="$1"
	local _value="$2"

	TESTS_RUN=$((TESTS_RUN + 1))
	local _line_count
	_line_count=$(printf '%s' "$_value" | wc -l | tr -d ' ')
	# A single-line result has exactly 0 newlines (the trailing \n from printf '%s\n' is in the output,
	# but the value captured via $(...) has it stripped by the shell).
	# Check that value is a non-negative integer with no embedded newlines.
	if [[ "$_value" =~ ^[0-9]+$ ]]; then
		printf 'PASS %s (value=%s)\n' "$_test_name" "$_value"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s — not a single integer: %q\n' "$_test_name" "$_value"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# ── setup ─────────────────────────────────────────────────────────────

if [[ ! -f "$SHARED_CONSTANTS" ]]; then
	printf 'ERROR: shared-constants.sh not found at %s\n' "$SHARED_CONSTANTS" >&2
	exit 2
fi

# shellcheck source=../shared-constants.sh
source "$SHARED_CONSTANTS"

if ! declare -f safe_grep_count >/dev/null 2>&1; then
	printf 'ERROR: safe_grep_count() not defined after sourcing shared-constants.sh\n' >&2
	exit 2
fi

# ── tests ─────────────────────────────────────────────────────────────

printf 'Running safe_grep_count() unit tests...\n\n'

# 1. Empty stdin → 0
result=$(printf '' | safe_grep_count '.')
assert_eq "empty-stdin-any-pattern" "0" "$result"

# 2. Empty stdin with specific pattern → 0
result=$(printf '' | safe_grep_count 'needle')
assert_eq "empty-stdin-specific-pattern" "0" "$result"

# 3. No match in non-empty input → 0
result=$(printf 'foo\nbar\nbaz\n' | safe_grep_count 'needle')
assert_eq "no-match-returns-zero" "0" "$result"

# 4. Single match → 1
result=$(printf 'foo\nbar\nbaz\n' | safe_grep_count 'bar')
assert_eq "single-match-returns-one" "1" "$result"

# 5. Multiple matches → N
result=$(printf 'a\nb\nc\n' | safe_grep_count '.')
assert_eq "multiple-matches-dot" "3" "$result"

# 6. Nonexistent file → 0 (not error)
result=$(safe_grep_count 'pattern' /nonexistent/file/path)
assert_eq "nonexistent-file-returns-zero" "0" "$result"

# 7. Extended regex (-E flag) — 2 matches out of 3 lines
result=$(printf 'foo\n123\nbar\n' | safe_grep_count -E '^[a-z]+$')
assert_eq "extended-regex-flag" "2" "$result"

# 8. Case-insensitive (-i flag)
result=$(printf 'Hello\nworld\nHELLO\n' | safe_grep_count -i 'hello')
assert_eq "case-insensitive-flag" "2" "$result"

# 9. Output is a single non-negative integer — no stacking
result=$(printf '' | safe_grep_count 'nomatch')
assert_single_line "output-single-integer-on-empty" "$result"

result=$(printf 'a\nb\nc\n' | safe_grep_count '.')
assert_single_line "output-single-integer-on-match" "$result"

# 10. No match in file (not stdin) → 0
tmpfile=$(mktemp /tmp/test-safe-grep-count.XXXXXX)
printf 'foo\nbar\nbaz\n' > "$tmpfile"
result=$(safe_grep_count 'needle' "$tmpfile")
assert_eq "no-match-in-file-returns-zero" "0" "$result"

# 11. Matches in file → correct count
result=$(safe_grep_count 'foo\|bar' "$tmpfile")
# grep -c with alternation: 2 lines match (foo and bar)
assert_eq "matches-in-file-returns-count" "2" "$result"

rm -f "$tmpfile"

# 12. Multiple files, one nonexistent → safe fallback to 0.
# grep -c with multiple files outputs "file:count" format (not a bare integer),
# and with a missing file returns exit code 2. safe_grep_count captures the
# multi-file "file:N" output, which fails the ^[0-9]+$ integer guard and
# falls back to 0. This is the safe/correct behavior: the caller should use
# single-file invocations (or stdin piping) for predictable counts.
tmpfile2=$(mktemp /tmp/test-safe-grep-count2.XXXXXX)
printf 'hello\nhello\nworld\n' > "$tmpfile2"
result=$(safe_grep_count 'hello' /nonexistent/path "$tmpfile2")
# Expect 0: multi-file output "file:N" does not match ^[0-9]+$ guard
assert_eq "multiple-files-one-missing-safe-zero" "0" "$result"
rm -f "$tmpfile2"

# 13. Zero-match scenario — the specific anti-pattern this helper prevents.
# Without safe_grep_count, doing:
#   count=$(grep -c 'nope' /dev/null || echo "0")
# produces "0\n0" (grep outputs "0", then || echo appends "0").
# Verify safe_grep_count avoids this:
result=$(safe_grep_count 'nope' /dev/null)
assert_single_line "anti-pattern-no-stacking" "$result"
assert_eq "anti-pattern-correct-zero" "0" "$result"

# ── summary ───────────────────────────────────────────────────────────

printf '\n--- safe_grep_count() Unit Test Summary ---\n'
printf 'Tests run:    %d\n' "$TESTS_RUN"
printf 'Tests passed: %d\n' "$TESTS_PASSED"
printf 'Tests failed: %d\n' "$TESTS_FAILED"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '\nFAILED: %d test(s) failed.\n' "$TESTS_FAILED"
	exit 1
fi

printf '\nAll %d tests passed.\n' "$TESTS_PASSED"
exit 0
