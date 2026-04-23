#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-safe-grep-count.sh — unit tests for safe_grep_count helper (t2763)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=../shared-constants.sh
source "${REPO_ROOT}/.agents/scripts/shared-constants.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# assert_eq <label> <expected> <actual>
assert_eq() {
	local _label="$1"
	local _expected="$2"
	local _actual="$3"
	if [[ "$_actual" == "$_expected" ]]; then
		printf '  [PASS] %s\n' "$_label"
		PASS=$((PASS + 1))
	else
		printf '  [FAIL] %s — expected %q got %q\n' "$_label" "$_expected" "$_actual"
		FAIL=$((FAIL + 1))
		FAILED_TESTS+=("$_label")
	fi
	return 0
}

# assert_single_line <label> <actual>
# Verifies the output is exactly one line (no stacking).
assert_single_line() {
	local _label="$1"
	local _actual="$2"
	local _nlines
	_nlines=$(printf '%s' "$_actual" | wc -l | tr -d ' ')
	# `wc -l` counts newlines; a single-line integer with trailing newline
	# prints as 1. Zero-line (no newline) is 0.
	if [[ "$_nlines" == "0" || "$_nlines" == "1" ]]; then
		printf '  [PASS] %s (single line)\n' "$_label"
		PASS=$((PASS + 1))
	else
		printf '  [FAIL] %s — expected single line, got %s lines: %q\n' \
			"$_label" "$_nlines" "$_actual"
		FAIL=$((FAIL + 1))
		FAILED_TESTS+=("$_label single-line")
	fi
	return 0
}

printf '=== safe_grep_count unit tests ===\n\n'

# Basic counts via stdin
out=$(printf 'a\nb\nc\n' | safe_grep_count .)
assert_eq "match-all: three lines, three matches" "3" "$out"
assert_single_line "match-all output is single line" "$out"

out=$(printf 'a\nb\nc\n' | safe_grep_count 'nope')
assert_eq "no-match: zero count (not stacked)" "0" "$out"
assert_single_line "no-match output is single line" "$out"

out=$(printf '' | safe_grep_count .)
assert_eq "empty-input: zero" "0" "$out"

# Extended regex flag passthrough
out=$(printf 'foo\n123\nbar\nBAZ\n' | safe_grep_count -E '^[a-z]+$')
assert_eq "-E flag: lowercase-only lines" "2" "$out"

# Case-insensitive flag passthrough
out=$(printf 'Foo\nFOO\nbar\n' | safe_grep_count -i 'foo')
assert_eq "-i flag: case-insensitive count" "2" "$out"

# Fixed-string flag passthrough
out=$(printf 'a.b\nabc\n' | safe_grep_count -F 'a.b')
assert_eq "-F flag: fixed-string count" "1" "$out"

# File-based input (file exists)
tmpfile=$(mktemp)
printf 'line-1\nline-2\nline-3\n' >"$tmpfile"
out=$(safe_grep_count 'line-' "$tmpfile")
assert_eq "file input: three lines matching" "3" "$out"
rm -f "$tmpfile"

# File-based input (file does not exist)
out=$(safe_grep_count 'anything' /does/not/exist/at/all)
assert_eq "nonexistent file: zero (stderr suppressed)" "0" "$out"

# The canonical bug reproduction: ensure we don't stack "0\n0"
out=$(printf '' | safe_grep_count .)
# Capture the EXACT bytes to verify no embedded newline in the middle
byte_count=$(printf '%s' "$out" | wc -c | tr -d ' ')
assert_eq "empty-match byte count: exactly 1 (a single '0')" "1" "$byte_count"

# Downstream arithmetic must work (this failed with the old idiom on zero-match)
out=$(printf '' | safe_grep_count .)
if total=$((out + 5)); then
	assert_eq "arithmetic on zero: 0+5=5" "5" "$total"
else
	printf '  [FAIL] arithmetic-on-zero raised error\n'
	FAIL=$((FAIL + 1))
	FAILED_TESTS+=("arithmetic-on-zero")
fi

# Downstream -eq must work (this failed with the old idiom: "0\n0" is not -eq 0)
out=$(printf 'x\n' | safe_grep_count 'nope')
if [[ "$out" -eq 0 ]]; then
	printf '  [PASS] -eq comparison works on zero-match output\n'
	PASS=$((PASS + 1))
else
	printf '  [FAIL] -eq comparison failed on zero-match output: %q\n' "$out"
	FAIL=$((FAIL + 1))
	FAILED_TESTS+=("-eq-on-zero")
fi

# Summary
printf '\n=== Results ===\n'
printf '  Passed: %d\n' "$PASS"
printf '  Failed: %d\n' "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	printf '\nFailed tests:\n'
	for _t in "${FAILED_TESTS[@]}"; do
		printf '  - %s\n' "$_t"
	done
	exit 1
fi
printf 'All tests passed.\n'
exit 0
