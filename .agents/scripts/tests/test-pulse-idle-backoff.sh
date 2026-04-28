#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-pulse-idle-backoff.sh — Unit tests for pulse-idle-backoff-helper.sh (t3027)
# =============================================================================
#
# Covers:
#   1. Initial state (no state file) — should-skip exits 1, state synthesises
#      empty record.
#   2. record-cycle idle increments counter; record-cycle active resets to 0.
#   3. Backoff schedule: 0/4/5/9/10/19/20/29/30 idle counts → expected
#      effective intervals.
#   4. should-skip behaviour: elapsed < interval → exit 0 (skip), elapsed >=
#      interval → exit 1 (proceed). Base interval (no backoff) → always proceed.
#   5. AIDEVOPS_SKIP_PULSE_IDLE_BACKOFF=1 disables gate (always proceed).
#   6. reset clears state.
#   7. State file is valid JSON after each write.
#
# Run: bash .agents/scripts/tests/test-pulse-idle-backoff.sh
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${SCRIPT_DIR}/pulse-idle-backoff-helper.sh"

# Isolated state file per test run (in $TMPDIR, not $HOME).
TEST_STATE_DIR="$(mktemp -d -t pulse-idle-backoff-test.XXXXXX)"
export AIDEVOPS_PULSE_IDLE_STATE_FILE="${TEST_STATE_DIR}/state.json"

# Predictable schedule (matches helper defaults).
export AIDEVOPS_PULSE_IDLE_BASE_INTERVAL_S=90
export AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_5=5
export AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_5_S=180
export AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_10=10
export AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_10_S=300
export AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_20=20
export AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_20_S=600
export AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_30=30
export AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_30_S=1800
unset AIDEVOPS_SKIP_PULSE_IDLE_BACKOFF

cleanup() {
	rm -rf "$TEST_STATE_DIR" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

PASS=0
FAIL=0
FAIL_DETAIL=""

assert_eq() {
	local _label="$1" _expected="$2" _actual="$3"
	if [[ "$_expected" == "$_actual" ]]; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$_label"
	else
		FAIL=$((FAIL + 1))
		FAIL_DETAIL+="    ${_label}: expected='${_expected}' actual='${_actual}'\n"
		printf '  FAIL: %s — expected=%q actual=%q\n' "$_label" "$_expected" "$_actual"
	fi
	return 0
}

assert_exit() {
	local _label="$1" _expected="$2" _actual="$3"
	if [[ "$_expected" == "$_actual" ]]; then
		PASS=$((PASS + 1))
		printf '  PASS: %s (exit=%s)\n' "$_label" "$_actual"
	else
		FAIL=$((FAIL + 1))
		FAIL_DETAIL+="    ${_label}: expected_exit=${_expected} actual_exit=${_actual}\n"
		printf '  FAIL: %s — expected_exit=%s actual_exit=%s\n' "$_label" "$_expected" "$_actual"
	fi
	return 0
}

# Reset helper state at start of each test group.
reset_state() {
	"$HELPER" reset >/dev/null 2>&1 || true
	return 0
}

# -----------------------------------------------------------------------------
# Test 1: Initial state (no state file)
# -----------------------------------------------------------------------------
echo "Test 1: Initial state (no state file)"
reset_state

# state should print synthesized empty record with _state_file_missing flag.
state_json=$("$HELPER" state)
missing_flag=$(echo "$state_json" | jq -r '._state_file_missing // false')
assert_eq "state file missing flag set" "true" "$missing_flag"

initial_count=$(echo "$state_json" | jq -r '.consecutive_idle')
assert_eq "initial consecutive_idle is 0" "0" "$initial_count"

# should-skip with last_run=now-30s should PROCEED (no backoff yet, elapsed < 90s but no backoff active).
now=$(date +%s)
last_run=$((now - 30))
rc=0
"$HELPER" should-skip "$last_run" >/dev/null 2>&1 || rc=$?
assert_exit "no_backoff: should-skip exits 1 (proceed)" "1" "$rc"

# -----------------------------------------------------------------------------
# Test 2: record-cycle increments and resets
# -----------------------------------------------------------------------------
echo ""
echo "Test 2: record-cycle increments idle, resets on active"
reset_state

"$HELPER" record-cycle idle >/dev/null 2>&1
"$HELPER" record-cycle idle >/dev/null 2>&1
"$HELPER" record-cycle idle >/dev/null 2>&1
count=$("$HELPER" state | jq -r '.consecutive_idle')
assert_eq "3 idle cycles → count=3" "3" "$count"

"$HELPER" record-cycle active >/dev/null 2>&1
count=$("$HELPER" state | jq -r '.consecutive_idle')
assert_eq "active cycle resets count to 0" "0" "$count"

last_outcome=$("$HELPER" state | jq -r '.last_cycle_outcome')
assert_eq "last_cycle_outcome reflects most recent" "active" "$last_outcome"

# -----------------------------------------------------------------------------
# Test 3: Backoff schedule
# -----------------------------------------------------------------------------
echo ""
echo "Test 3: Backoff schedule maps idle count to interval"

assert_interval_for_count() {
	local _expected_interval="$1" _idle_count="$2"
	reset_state
	local _i=0
	while [[ "$_i" -lt "$_idle_count" ]]; do
		"$HELPER" record-cycle idle >/dev/null 2>&1
		_i=$((_i + 1))
	done
	local _actual
	_actual=$("$HELPER" state | jq -r '.current_effective_interval_s')
	assert_eq "idle=${_idle_count} → interval=${_expected_interval}s" "$_expected_interval" "$_actual"
	return 0
}

# Boundary cases — 0,4 → base; 5 → step-1; 9 → step-1; 10 → step-2; 19 → step-2; etc.
assert_interval_for_count 90 0
assert_interval_for_count 90 4
assert_interval_for_count 180 5
assert_interval_for_count 180 9
assert_interval_for_count 300 10
assert_interval_for_count 300 19
assert_interval_for_count 600 20
assert_interval_for_count 600 29
assert_interval_for_count 1800 30
assert_interval_for_count 1800 50

# -----------------------------------------------------------------------------
# Test 4: should-skip respects effective interval
# -----------------------------------------------------------------------------
echo ""
echo "Test 4: should-skip respects effective interval"
reset_state

# Build state at 10 idle cycles (interval = 300s).
i=0
while [[ "$i" -lt 10 ]]; do
	"$HELPER" record-cycle idle >/dev/null 2>&1
	i=$((i + 1))
done

now=$(date +%s)

# Elapsed < 300 → SKIP (exit 0)
rc=0
"$HELPER" should-skip "$((now - 100))" >/dev/null 2>&1 || rc=$?
assert_exit "elapsed=100s < 300s interval → skip (exit 0)" "0" "$rc"

# Elapsed > 300 → PROCEED (exit 1)
rc=0
"$HELPER" should-skip "$((now - 400))" >/dev/null 2>&1 || rc=$?
assert_exit "elapsed=400s > 300s interval → proceed (exit 1)" "1" "$rc"

# Elapsed = exactly 300 → PROCEED (>= boundary)
rc=0
"$HELPER" should-skip "$((now - 300))" >/dev/null 2>&1 || rc=$?
assert_exit "elapsed=300s == 300s interval → proceed (exit 1)" "1" "$rc"

# last_run=0 (cold start) → PROCEED
rc=0
"$HELPER" should-skip 0 >/dev/null 2>&1 || rc=$?
assert_exit "last_run=0 (cold start) → proceed (exit 1)" "1" "$rc"

# -----------------------------------------------------------------------------
# Test 5: should-skip with no backoff active always proceeds
# -----------------------------------------------------------------------------
echo ""
echo "Test 5: should-skip with no backoff active always proceeds"
reset_state

# 0 idle cycles → interval = base (90s). Elapsed < 90s should still PROCEED
# because the upstream PULSE_MIN_INTERVAL_S gate handles the base case.
now=$(date +%s)
rc=0
"$HELPER" should-skip "$((now - 30))" >/dev/null 2>&1 || rc=$?
assert_exit "no_backoff_active: elapsed=30s → proceed (exit 1)" "1" "$rc"

# -----------------------------------------------------------------------------
# Test 6: AIDEVOPS_SKIP_PULSE_IDLE_BACKOFF disables gate
# -----------------------------------------------------------------------------
echo ""
echo "Test 6: AIDEVOPS_SKIP_PULSE_IDLE_BACKOFF=1 disables gate"
reset_state

# Build deep idle backoff (50 cycles → interval=1800s).
i=0
while [[ "$i" -lt 50 ]]; do
	"$HELPER" record-cycle idle >/dev/null 2>&1
	i=$((i + 1))
done

now=$(date +%s)
# Without flag — should SKIP (deep backoff, recent last-run).
rc=0
"$HELPER" should-skip "$((now - 100))" >/dev/null 2>&1 || rc=$?
assert_exit "deep backoff without flag → skip (exit 0)" "0" "$rc"

# With flag — should PROCEED.
rc=0
AIDEVOPS_SKIP_PULSE_IDLE_BACKOFF=1 "$HELPER" should-skip "$((now - 100))" >/dev/null 2>&1 || rc=$?
assert_exit "deep backoff with disable flag → proceed (exit 1)" "1" "$rc"

# -----------------------------------------------------------------------------
# Test 7: state file is always valid JSON after writes
# -----------------------------------------------------------------------------
echo ""
echo "Test 7: state file is valid JSON after operations"
reset_state

"$HELPER" record-cycle idle >/dev/null 2>&1
if jq -e . "$AIDEVOPS_PULSE_IDLE_STATE_FILE" >/dev/null 2>&1; then
	PASS=$((PASS + 1))
	echo "  PASS: state file is valid JSON after record-cycle"
else
	FAIL=$((FAIL + 1))
	FAIL_DETAIL+="    state file is not valid JSON\n"
	echo "  FAIL: state file is not valid JSON"
fi

"$HELPER" record-cycle active >/dev/null 2>&1
if jq -e . "$AIDEVOPS_PULSE_IDLE_STATE_FILE" >/dev/null 2>&1; then
	PASS=$((PASS + 1))
	echo "  PASS: state file is valid JSON after reset-via-active"
else
	FAIL=$((FAIL + 1))
	FAIL_DETAIL+="    state file invalid after active\n"
	echo "  FAIL: state file invalid after active"
fi

# -----------------------------------------------------------------------------
# Test 8: reset removes state file
# -----------------------------------------------------------------------------
echo ""
echo "Test 8: reset removes state file"
"$HELPER" record-cycle idle >/dev/null 2>&1
[[ -f "$AIDEVOPS_PULSE_IDLE_STATE_FILE" ]] && pre_exists="yes" || pre_exists="no"
assert_eq "state file exists pre-reset" "yes" "$pre_exists"

"$HELPER" reset >/dev/null 2>&1
[[ -f "$AIDEVOPS_PULSE_IDLE_STATE_FILE" ]] && post_exists="yes" || post_exists="no"
assert_eq "state file removed post-reset" "no" "$post_exists"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "============================================="

if [[ "$FAIL" -gt 0 ]]; then
	printf '\nFailure detail:\n%b' "$FAIL_DETAIL"
	exit 1
fi
exit 0
