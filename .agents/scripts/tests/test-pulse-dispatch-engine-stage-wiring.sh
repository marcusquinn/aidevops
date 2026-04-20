#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-pulse-dispatch-engine-stage-wiring.sh — regression guard for t2443
#
# Verifies that daily scan stages are registered as independent top-level
# stages in _run_preflight_stages() with their own run_stage_with_timeout
# calls, not wrapped in a shared-budget group.
#
# Background: _preflight_daily_scans() wrapped 4+ children under a single
# 600s timeout. A slow complexity_scan (200-340s) would exhaust the budget
# before auto_decomposer_scanner could run. t2443 promoted each scanner to
# an independent top-level stage so each gets its own timeout budget.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
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

assert_not_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  pattern should NOT match: $pattern"
		echo "  in file:                  $file"
	fi
	return 0
}

# Resolve paths relative to this test file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$SCRIPT_DIR/pulse-dispatch-engine.sh"

echo "=== t2443: pulse-dispatch-engine stage wiring regression tests ==="
echo "Engine: $ENGINE"
echo ""

# --- Each daily scanner has its own independent run_stage_with_timeout ---

assert_grep \
	"1: complexity_scan has independent run_stage_with_timeout" \
	'run_stage_with_timeout "complexity_scan".*run_weekly_complexity_scan' \
	"$ENGINE"

assert_grep \
	"2: coderabbit_review has independent run_stage_with_timeout" \
	'run_stage_with_timeout "coderabbit_review".*run_daily_codebase_review' \
	"$ENGINE"

assert_grep \
	"3: post_merge_scanner has independent run_stage_with_timeout" \
	'run_stage_with_timeout "post_merge_scanner".*_run_post_merge_review_scanner' \
	"$ENGINE"

assert_grep \
	"4: auto_decomposer_scanner has independent run_stage_with_timeout" \
	'run_stage_with_timeout "auto_decomposer_scanner".*_run_auto_decomposer_scanner' \
	"$ENGINE"

assert_grep \
	"5: dedup_cleanup has independent run_stage_with_timeout" \
	'run_stage_with_timeout "dedup_cleanup".*run_simplification_dedup_cleanup' \
	"$ENGINE"

assert_grep \
	"6: fast_fail_prune_expired is called directly (lightweight, no stage timeout needed)" \
	'fast_fail_prune_expired \|\| true' \
	"$ENGINE"

# --- The shared-budget wrapper must NOT exist ---

assert_not_grep \
	"7: _preflight_daily_scans() function wrapper removed (no shared budget)" \
	'^_preflight_daily_scans\(\)' \
	"$ENGINE"

assert_not_grep \
	"8: no run_stage_with_timeout wrapping preflight_daily_scans as a group" \
	'run_stage_with_timeout "preflight_daily_scans"' \
	"$ENGINE"

# --- All daily stages use the same timeout variable as peer preflight groups ---

assert_grep \
	"9: complexity_scan uses _pflt_timeout (same as other preflight groups)" \
	'run_stage_with_timeout "complexity_scan" "\$_pflt_timeout"' \
	"$ENGINE"

assert_grep \
	"10: auto_decomposer_scanner uses _pflt_timeout" \
	'run_stage_with_timeout "auto_decomposer_scanner" "\$_pflt_timeout"' \
	"$ENGINE"

# --- Summary ---

echo ""
echo "=== Results: $TESTS_RUN tests, $TESTS_FAILED failures ==="

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
