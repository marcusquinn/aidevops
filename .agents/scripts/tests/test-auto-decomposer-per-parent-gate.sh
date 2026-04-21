#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-auto-decomposer-per-parent-gate.sh — structural tests for t2573
#
# Verifies the per-parent gating enhancements introduced in t2573:
#   1. Global AUTO_DECOMPOSER_LAST_RUN gate removed from pulse-simplification.sh
#   2. Scanner runs every pulse cycle (no global throttle in wrapper)
#   3. Per-parent state file constants exist (AUTO_DECOMPOSER_PARENT_STATE)
#   4. AUTO_DECOMPOSER_INTERVAL repurposed as per-parent re-file interval (7 days)
#   5. SCANNER_FRESH_PARENT_HOURS env var present in scanner (default 6)
#   6. Fresh-parent threshold logic present in do_scan()
#   7. Per-parent state read/write helpers present (_read_parent_last_filed, _update_parent_state)
#   8. Non-nudge comment counter present (_count_non_nudge_comments)
#   9. Re-file gate check present in do_scan()
#  10. State update called after filing (dry_run guard)
#  11. Help text documents SCANNER_FRESH_PARENT_HOURS and AUTO_DECOMPOSER_INTERVAL
#  12. Shellcheck cleanliness

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$SCRIPT_DIR/auto-decomposer-scanner.sh"
WRAPPER="$SCRIPT_DIR/pulse-simplification.sh"
BOOTSTRAP="$SCRIPT_DIR/pulse-wrapper.sh"

for required in "$SCANNER" "$WRAPPER" "$BOOTSTRAP"; do
	if [[ ! -f "$required" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $required not found"
		exit 1
	fi
done

echo "${TEST_BLUE}=== t2573: auto-decomposer per-parent gate tests ===${TEST_NC}"
echo ""

# --- 1. Global gate removed from pulse-simplification.sh wrapper ---

assert_not_grep_fixed \
	"1a: global AUTO_DECOMPOSER_LAST_RUN write removed from wrapper" \
	'AUTO_DECOMPOSER_LAST_RUN' \
	"$WRAPPER"

assert_not_grep_fixed \
	"1b: global AUTO_DECOMPOSER_LAST_RUN time gate removed from _run_auto_decomposer_scanner" \
	'AUTO_DECOMPOSER_LAST_RUN' \
	"$WRAPPER"

# --- 2. Scanner still wired into wrapper (sanity) ---

assert_grep \
	"2: _run_auto_decomposer_scanner still defined in wrapper" \
	'^_run_auto_decomposer_scanner\(\) \{' \
	"$WRAPPER"

# --- 3. Per-parent state constant in pulse-wrapper.sh bootstrap ---

assert_grep \
	"3a: AUTO_DECOMPOSER_PARENT_STATE constant defined in pulse-wrapper" \
	'^AUTO_DECOMPOSER_PARENT_STATE=' \
	"$BOOTSTRAP"

assert_not_grep_fixed \
	"3b: AUTO_DECOMPOSER_LAST_RUN removed from pulse-wrapper bootstrap" \
	'AUTO_DECOMPOSER_LAST_RUN' \
	"$BOOTSTRAP"

# --- 4. AUTO_DECOMPOSER_INTERVAL repurposed as per-parent re-file interval ---

assert_grep \
	"4a: AUTO_DECOMPOSER_INTERVAL default is 604800 (7 days) in pulse-wrapper" \
	'AUTO_DECOMPOSER_INTERVAL=.*604800' \
	"$BOOTSTRAP"

assert_grep \
	"4b: AUTO_DECOMPOSER_INTERVAL _validate_int min is 86400 (1 day) in pulse-wrapper" \
	'_validate_int AUTO_DECOMPOSER_INTERVAL.*604800.*86400' \
	"$BOOTSTRAP"

assert_grep \
	"4c: AUTO_DECOMPOSER_INTERVAL default 604800 in scanner" \
	'AUTO_DECOMPOSER_INTERVAL.*604800' \
	"$SCANNER"

# --- 5. SCANNER_FRESH_PARENT_HOURS in scanner ---

assert_grep \
	"5a: SCANNER_FRESH_PARENT_HOURS env var defined in scanner (default 6)" \
	'SCANNER_FRESH_PARENT_HOURS.*:-6' \
	"$SCANNER"

# --- 6. Fresh-parent threshold logic in do_scan ---

assert_grep_fixed \
	"6a: fresh-parent threshold applied in do_scan" \
	'SCANNER_FRESH_PARENT_HOURS' \
	"$SCANNER"

assert_grep_fixed \
	"6b: parent_kind variable distinguishes fresh vs aged" \
	'parent_kind="fresh"' \
	"$SCANNER"

assert_grep_fixed \
	"6c: non-nudge comment count drives threshold selection" \
	'"$non_nudge_count" -eq 0' \
	"$SCANNER"

# --- 7. Per-parent state helpers ---

assert_grep \
	"7a: _read_parent_last_filed function defined" \
	'^_read_parent_last_filed\(\) \{' \
	"$SCANNER"

assert_grep \
	"7b: _update_parent_state function defined" \
	'^_update_parent_state\(\) \{' \
	"$SCANNER"

assert_grep_fixed \
	"7c: _update_parent_state uses atomic write-then-rename" \
	'mv "$tmp" "$AUTO_DECOMPOSER_PARENT_STATE"' \
	"$SCANNER"

# --- 8. Non-nudge comment counter ---

assert_grep \
	"8a: _count_non_nudge_comments function defined" \
	'^_count_non_nudge_comments\(\) \{' \
	"$SCANNER"

assert_grep_fixed \
	"8b: counter filters OUT nudge comments" \
	'parent-needs-decomposition -->") | not' \
	"$SCANNER"

# --- 9. Re-file gate check in do_scan ---

assert_grep_fixed \
	"9a: re-file gate reads last-filed epoch from state" \
	'last_filed=$(_read_parent_last_filed' \
	"$SCANNER"

assert_grep_fixed \
	"9b: re-file gate skips if elapsed < AUTO_DECOMPOSER_INTERVAL" \
	'"$elapsed_since_filed" -lt "$AUTO_DECOMPOSER_INTERVAL"' \
	"$SCANNER"

assert_grep_fixed \
	"9c: re-file gate skip is counted in skipped_refiled" \
	'skipped_refiled=$((skipped_refiled + 1))' \
	"$SCANNER"

# --- 10. State update called after successful filing ---

assert_grep_fixed \
	"10a: _update_parent_state called after filing" \
	'_update_parent_state "$repo" "$parent_num" "$now_epoch"' \
	"$SCANNER"

assert_grep_fixed \
	"10b: state update guarded by dry_run check" \
	'if [[ "$dry_run" != true ]]; then' \
	"$SCANNER"

# --- 11. Help text documents new env vars ---

help_output=$("$SCANNER" help 2>&1)
help_rc=$?
assert_rc "11a: help subcommand exits 0" "0" "$help_rc"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$help_output" == *"SCANNER_FRESH_PARENT_HOURS"* ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 11b: help documents SCANNER_FRESH_PARENT_HOURS"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 11b: help missing SCANNER_FRESH_PARENT_HOURS"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$help_output" == *"AUTO_DECOMPOSER_INTERVAL"* ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 11c: help documents AUTO_DECOMPOSER_INTERVAL"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 11c: help missing AUTO_DECOMPOSER_INTERVAL"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$help_output" == *"AUTO_DECOMPOSER_PARENT_STATE"* ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 11d: help documents AUTO_DECOMPOSER_PARENT_STATE"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 11d: help missing AUTO_DECOMPOSER_PARENT_STATE"
fi

# --- 12. Shellcheck cleanliness ---

if command -v shellcheck >/dev/null 2>&1; then
	TESTS_RUN=$((TESTS_RUN + 1))
	if shellcheck "$SCANNER" >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 12: scanner is shellcheck-clean"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 12: scanner has shellcheck violations"
		shellcheck "$SCANNER" || true
	fi
else
	echo "${TEST_BLUE}SKIP${TEST_NC}: 12: shellcheck not installed"
fi

# --- Summary ---
echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
