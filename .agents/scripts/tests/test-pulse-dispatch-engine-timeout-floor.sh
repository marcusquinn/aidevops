#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-pulse-dispatch-engine-timeout-floor.sh — regression guard for t3026
#
# Verifies that _dff_dispatch_with_timeout in pulse-dispatch-engine.sh applies
# a floor to the adaptive per-candidate timeout, so the dispatch ceremony
# (~75-160s baseline, +20-40s under backpressure) cannot be killed by a
# learned-low timeout from the EWMA+p95 recommender.
#
# Background: 2026-04-28 production failure — adaptive timeout collapsed to
# 180s after a sequence of "fast" cycles that included dedup-skip outcomes
# in the EWMA window. Every fill_floor_candidate stage subsequently timed
# out at rc=124, yielding `dispatched=0/148` for multiple cycles. Pulse
# could not maintain 24-worker concurrency.
#
# Contract pinned by this test:
#   1. The function declares a `floor_seconds` local sourced from
#      FILL_FLOOR_PER_CANDIDATE_TIMEOUT_FLOOR with a default of 360.
#   2. The floor block runs AFTER the adaptive helper has populated
#      timeout_seconds — i.e., it sits between the `dispatch-timing-helper.sh
#      recommend` block and the run_stage_with_timeout call.
#   3. The floor mutates BOTH timeout_seconds (used by run_stage_with_timeout)
#      and timeout_ms (recorded back to the helper for learning) so the
#      learning loop also sees the floored value.

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

# Verify the floor block appears AFTER the helper recommend block AND BEFORE
# run_stage_with_timeout. We confirm ordering by line numbers.
assert_block_ordering() {
	local label="$1" file="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	local helper_line floor_line stage_line
	helper_line=$(grep -nE 'dispatch-timing-helper\.sh recommend' "$file" | head -1 | cut -d: -f1)
	floor_line=$(grep -nE 'FILL_FLOOR_PER_CANDIDATE_TIMEOUT_FLOOR' "$file" | head -1 | cut -d: -f1)
	stage_line=$(grep -nE 'run_stage_with_timeout "fill_floor_candidate_' "$file" | head -1 | cut -d: -f1)
	if [[ -z "$helper_line" || -z "$floor_line" || -z "$stage_line" ]]; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  could not locate one or more anchors:"
		echo "    helper recommend line: ${helper_line:-NOT FOUND}"
		echo "    floor block line:      ${floor_line:-NOT FOUND}"
		echo "    run_stage line:        ${stage_line:-NOT FOUND}"
		return 0
	fi
	if ((helper_line < floor_line && floor_line < stage_line)); then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label (helper@${helper_line} < floor@${floor_line} < stage@${stage_line})"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  block ordering wrong: helper=${helper_line} floor=${floor_line} stage=${stage_line}"
	fi
	return 0
}

# Resolve paths relative to this test file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$SCRIPT_DIR/pulse-dispatch-engine.sh"

echo "=== t3026: per-candidate timeout floor regression tests ==="
echo "Engine: $ENGINE"
echo ""

assert_grep \
	"1: env var FILL_FLOOR_PER_CANDIDATE_TIMEOUT_FLOOR is consulted with default 360" \
	'\$\{FILL_FLOOR_PER_CANDIDATE_TIMEOUT_FLOOR:-360\}' \
	"$ENGINE"

assert_grep \
	"2: floor compares against timeout_seconds (post-adaptive value)" \
	'timeout_seconds < floor_seconds' \
	"$ENGINE"

assert_grep \
	"3: floor mutates timeout_seconds when below floor" \
	'timeout_seconds="\$floor_seconds"' \
	"$ENGINE"

assert_grep \
	"4: floor also recomputes timeout_ms so the learning loop sees the floored value" \
	'timeout_ms=\$\(\(floor_seconds \* 1000\)\)' \
	"$ENGINE"

assert_grep \
	"5: floor block is integer-validated (defensive against malformed env)" \
	'floor_seconds.*=~.*\^\[0-9\]\+\$' \
	"$ENGINE"

assert_block_ordering \
	"6: floor block runs AFTER helper recommend AND BEFORE run_stage_with_timeout" \
	"$ENGINE"

echo ""
echo "Tests run: $TESTS_RUN, failed: $TESTS_FAILED"
if ((TESTS_FAILED > 0)); then
	exit 1
fi
exit 0
