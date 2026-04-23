#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-auto-decomposer-scanner-zero-threshold.sh — structural tests for GH#20532
#
# Verifies the zero-delay threshold changes introduced in GH#20532:
#   1. SCANNER_NUDGE_AGE_HOURS default is 0 (aged parents: immediate dispatch)
#   2. SCANNER_FRESH_PARENT_HOURS default is 0 (fresh parents: immediate dispatch)
#   3. AUTO_DECOMPOSER_INTERVAL default is 86400 (1 day, was 604800 / 7 days)
#   4. Comparison uses -lt (strict less-than), so threshold=0 allows any nudge age >= 0
#   5. Re-file gate still suppresses duplicate filings within AUTO_DECOMPOSER_INTERVAL
#   6. Env-var overrides still honoured (backwards-compatible)
#   7. Help text documents new defaults
#   8. AGENTS.md updated to reflect 0h thresholds and 1-day re-file gate
#   9. parent-task-lifecycle.md updated to reflect new defaults
#  10. Shellcheck cleanliness

set -u

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

assert_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected pattern: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

assert_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qF -- "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected literal: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

assert_not_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! grep -qF -- "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  unexpected literal present: $pattern"
		echo "  in file:                    $file"
	fi
	return 0
}

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected rc=$expected, got rc=$actual"
	fi
	return 0
}

assert_true() {
	local label="$1" result="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" == "true" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: true, got: $result"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$SCRIPT_DIR/auto-decomposer-scanner.sh"
AGENTS_MD="$(cd "${SCRIPT_DIR}/.." && pwd)/AGENTS.md"
LIFECYCLE_MD="$(cd "${SCRIPT_DIR}/.." && pwd)/reference/parent-task-lifecycle.md"

if [[ ! -f "$SCANNER" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $SCANNER not found"
	exit 1
fi

echo "${TEST_BLUE}=== GH#20532: auto-decomposer zero-threshold tests ===${TEST_NC}"
echo ""

# --- 1. SCANNER_NUDGE_AGE_HOURS default is 0 ---

assert_grep \
	"1a: SCANNER_NUDGE_AGE_HOURS default is 0 (aged parent: immediate dispatch)" \
	'SCANNER_NUDGE_AGE_HOURS.*:-0[^-9]' \
	"$SCANNER"

assert_not_grep_fixed \
	"1b: old SCANNER_NUDGE_AGE_HOURS:-24 default removed" \
	'SCANNER_NUDGE_AGE_HOURS:-24' \
	"$SCANNER"

# --- 2. SCANNER_FRESH_PARENT_HOURS default is 0 ---

assert_grep \
	"2a: SCANNER_FRESH_PARENT_HOURS default is 0 (fresh parent: immediate dispatch)" \
	'SCANNER_FRESH_PARENT_HOURS.*:-0[^-9]' \
	"$SCANNER"

assert_not_grep_fixed \
	"2b: old SCANNER_FRESH_PARENT_HOURS:-6 default removed" \
	'SCANNER_FRESH_PARENT_HOURS:-6' \
	"$SCANNER"

# --- 3. AUTO_DECOMPOSER_INTERVAL default is 86400 (1 day) ---

assert_grep \
	"3a: AUTO_DECOMPOSER_INTERVAL default is 86400 (1 day)" \
	'AUTO_DECOMPOSER_INTERVAL.*:-86400' \
	"$SCANNER"

assert_not_grep_fixed \
	"3b: old AUTO_DECOMPOSER_INTERVAL:-604800 (7 days) default removed from scanner" \
	'AUTO_DECOMPOSER_INTERVAL:-604800' \
	"$SCANNER"

# --- 4. Comparison uses -lt (strict less-than) so threshold=0 is always satisfied ---
# With -lt: (hours < 0) is always false, so any nudge age >= 0 proceeds.
# With -(eq|gt): threshold=0 would never fire (hours == 0 would be equal, not greater).

assert_grep_fixed \
	"4a: threshold comparison uses -lt (hours < threshold → skip)" \
	'"$hours" -lt "$threshold"' \
	"$SCANNER"

# Verify the -lt guard means threshold=0 works: bash arithmetic check
TESTS_RUN=$((TESTS_RUN + 1))
threshold_zero_result="false"
hours_zero=0
threshold_zero=0
if ! [[ "$hours_zero" -lt "$threshold_zero" ]]; then
	threshold_zero_result="true"
fi
assert_true "4b: threshold=0, hours=0 → condition NOT skipped (0 < 0 is false → proceeds)" "$threshold_zero_result"

TESTS_RUN=$((TESTS_RUN + 1))
threshold_zero_result2="false"
hours_new=5
if ! [[ "$hours_new" -lt "$threshold_zero" ]]; then
	threshold_zero_result2="true"
fi
assert_true "4c: threshold=0, hours=5 → condition NOT skipped (5 < 0 is false → proceeds)" "$threshold_zero_result2"

# --- 5. Re-file gate still active (prevents same-parent duplicate within interval) ---

assert_grep_fixed \
	"5a: re-file gate still checks elapsed_since_filed < AUTO_DECOMPOSER_INTERVAL" \
	'"$elapsed_since_filed" -lt "$AUTO_DECOMPOSER_INTERVAL"' \
	"$SCANNER"

assert_grep_fixed \
	"5b: skipped_refiled counter still incremented" \
	'skipped_refiled=$((skipped_refiled + 1))' \
	"$SCANNER"

# --- 6. Env-var overrides honoured (backwards-compatible) ---
# The scanner uses ${VAR:-default} form, meaning an exported env var takes precedence.

assert_grep \
	"6a: SCANNER_NUDGE_AGE_HOURS uses \${...:-0} override-safe form" \
	'SCANNER_NUDGE_AGE_HOURS=.*\$\{SCANNER_NUDGE_AGE_HOURS' \
	"$SCANNER"

assert_grep \
	"6b: SCANNER_FRESH_PARENT_HOURS uses \${...:-0} override-safe form" \
	'SCANNER_FRESH_PARENT_HOURS=.*\$\{SCANNER_FRESH_PARENT_HOURS' \
	"$SCANNER"

assert_grep \
	"6c: AUTO_DECOMPOSER_INTERVAL uses \${...:-86400} override-safe form" \
	'AUTO_DECOMPOSER_INTERVAL=.*\$\{AUTO_DECOMPOSER_INTERVAL' \
	"$SCANNER"

# --- 7. Help text documents new defaults ---

help_output=$("$SCANNER" help 2>&1)
help_rc=$?
assert_rc "7a: help subcommand exits 0" "0" "$help_rc"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$help_output" == *"SCANNER_NUDGE_AGE_HOURS"* && "$help_output" == *"default 0"* ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 7b: help documents SCANNER_NUDGE_AGE_HOURS with default 0"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 7b: help missing SCANNER_NUDGE_AGE_HOURS default 0"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$help_output" == *"SCANNER_FRESH_PARENT_HOURS"* && "$help_output" == *"default 0"* ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 7c: help documents SCANNER_FRESH_PARENT_HOURS with default 0"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 7c: help missing SCANNER_FRESH_PARENT_HOURS default 0"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$help_output" == *"86400"* ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 7d: help documents AUTO_DECOMPOSER_INTERVAL 86400 (1 day)"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 7d: help missing AUTO_DECOMPOSER_INTERVAL 86400"
fi

# --- 8. AGENTS.md updated to reflect new scanner behavior ---

if [[ -f "$AGENTS_MD" ]]; then
	assert_not_grep_fixed \
		"8a: AGENTS.md no longer says '24h advisory nudge' as scanner threshold" \
		'24h advisory nudge, auto-decomposer' \
		"$AGENTS_MD"

	assert_grep_fixed \
		"8b: AGENTS.md references 0h nudge-age threshold" \
		'0h nudge-age threshold' \
		"$AGENTS_MD"

	assert_grep_fixed \
		"8c: AGENTS.md references 1-day re-file gate" \
		'1-day re-file gate' \
		"$AGENTS_MD"
else
	echo "${TEST_BLUE}SKIP${TEST_NC}: 8: AGENTS.md not found at ${AGENTS_MD}"
fi

# --- 9. parent-task-lifecycle.md updated ---

if [[ -f "$LIFECYCLE_MD" ]]; then
	assert_not_grep_fixed \
		"9a: lifecycle doc no longer shows 'default 6h' for SCANNER_FRESH_PARENT_HOURS" \
		'default 6h' \
		"$LIFECYCLE_MD"

	assert_not_grep_fixed \
		"9b: lifecycle doc no longer shows 'default 24h' for SCANNER_NUDGE_AGE_HOURS" \
		'default 24h' \
		"$LIFECYCLE_MD"

	assert_grep_fixed \
		"9c: lifecycle doc shows 'default 0h' for fresh parents" \
		'default 0h' \
		"$LIFECYCLE_MD"

	assert_not_grep_fixed \
		"9d: lifecycle doc no longer shows 'default 7 days' for AUTO_DECOMPOSER_INTERVAL" \
		'default 7 days' \
		"$LIFECYCLE_MD"

	assert_grep_fixed \
		"9e: lifecycle doc shows '1 day / 86400s' for AUTO_DECOMPOSER_INTERVAL" \
		'1 day / 86400s' \
		"$LIFECYCLE_MD"
else
	echo "${TEST_BLUE}SKIP${TEST_NC}: 9: parent-task-lifecycle.md not found at ${LIFECYCLE_MD}"
fi

# --- 10. Shellcheck cleanliness ---

if command -v shellcheck >/dev/null 2>&1; then
	TESTS_RUN=$((TESTS_RUN + 1))
	if shellcheck "$SCANNER" >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 10: scanner is shellcheck-clean"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 10: scanner has shellcheck violations"
		shellcheck "$SCANNER" || true
	fi
else
	echo "${TEST_BLUE}SKIP${TEST_NC}: 10: shellcheck not installed"
fi

# --- Summary ---
echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
