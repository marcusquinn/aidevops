#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for pulse `is_running` stale-lock breaker (t2829, GH#20867).
#
# Background:
#   pulse-wrapper.sh's `is_running` function has a fast-path short-circuit
#   (added GH#20611) that reads `${LOCKDIR}/pid` and returns 0 (skip cycle)
#   if `kill -0 $PID` succeeds. This was designed as an optimization that
#   should defer to `acquire_instance_lock` → `_handle_existing_lock` for
#   stale-lock cases ("biased toward false negatives").
#
#   However, the alive-but-stale case was missed: `kill -0` cannot
#   distinguish a healthy mid-cycle pulse from one whose internal logic
#   has wedged but whose bash shell is still alive. Real-world wedge
#   (April 25 2026): PID 23092 held the instance lock for 80+ minutes
#   with no log activity; 100+ launchd ticks all returned 0 from is_running
#   without ever attempting reclaim, because kill -0 kept returning true.
#
# Fix (t2829):
#   Add an age check to the short-circuit. If the lock holder is alive
#   AND age > PULSE_LOCK_MAX_AGE_S (default 1800s), fall through (no early
#   return) so acquire_instance_lock's `_handle_existing_lock` runs and
#   force-reclaims the stale lock with a kill.
#
# These tests reproduce the short-circuit boolean logic in isolation
# (sourcing pulse-wrapper.sh with all its dependencies and side effects
# is not viable for a unit test). Asserts:
#   1. Alive + young owner — short-circuit returns 0 (skip)
#   2. Alive + stale owner — short-circuit returns 1 (fall through)
#   3. Dead PID owner — short-circuit returns 1 (fall through)
#   4. No PID file — short-circuit returns 1 (fall through)
#   5. Self-PID owner (this process) — short-circuit returns 1 (fall through)
#   6. Malformed PID — short-circuit returns 1 (fall through)
#   7. PULSE_LOCK_MAX_AGE_S env override changes the ceiling
#   8. Non-numeric process age (defensive) — defaults to fall-through
#   9. Log line format includes ceiling reason (t2829 marker for grep)

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
LOCKDIR=""
WRAPPER_LOGFILE=""

# Stub control variable
STUB_PROCESS_AGE=42

# Track BG PIDs for cleanup
BG_PIDS=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_equals() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "expected='${expected}' actual='${actual}'"
	fi
	return 0
}

# Stub of _get_process_age (canonical impl in worker-lifecycle-common.sh)
# Returns whatever STUB_PROCESS_AGE is set to.
_get_process_age() {
	echo "$STUB_PROCESS_AGE"
	return 0
}

# Reproduces the short-circuit block from pulse-wrapper.sh:1465-1493
# (the `is_running` function's fast-path).
#
# This is a literal extraction of the logic — keep in sync with the
# original. Returns:
#   0 = healthy lock owner detected → caller should skip cycle
#   1 = no lock OR lock holder is dead/stale → caller should fall through
#       to acquire_instance_lock for proper handling
_is_running_short_circuit() {
	# Canary/dry-run modes always fall through (they exercise the full path)
	if [[ "${PULSE_CANARY_MODE:-0}" == "1" || "${PULSE_DRY_RUN:-0}" == "1" ]]; then
		return 1
	fi

	[[ -f "${LOCKDIR}/pid" ]] || return 1

	local _ir_pid
	_ir_pid=$(cat "${LOCKDIR}/pid" 2>/dev/null || true)

	if [[ "$_ir_pid" =~ ^[0-9]+$ ]] && [[ "$_ir_pid" != "$$" ]] && kill -0 "$_ir_pid" 2>/dev/null; then
		# t2829: age check
		local _ir_age _ir_max
		_ir_age=$(_get_process_age "$_ir_pid" 2>/dev/null || echo 0)
		_ir_max="${PULSE_LOCK_MAX_AGE_S:-1800}"
		if [[ "$_ir_age" =~ ^[0-9]+$ ]] && [[ "$_ir_age" -le "$_ir_max" ]]; then
			echo "[pulse-wrapper] Pulse already running (PID: ${_ir_pid}, age ${_ir_age}s), skipping" >>"$WRAPPER_LOGFILE"
			return 0
		fi
		echo "[pulse-wrapper] Lock holder PID ${_ir_pid} age ${_ir_age}s > ceiling ${_ir_max}s — deferring to acquire_instance_lock for reclaim (t2829)" >>"$WRAPPER_LOGFILE"
	fi

	return 1
}

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"

	LOCKDIR="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
	WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	export LOCKDIR WRAPPER_LOGFILE

	BG_PIDS=""
	return 0
}

_cleanup_bg() {
	local pid
	for pid in $BG_PIDS; do
		kill "$pid" 2>/dev/null || true
	done
	BG_PIDS=""
	return 0
}

teardown_sandbox() {
	_cleanup_bg
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

reset_state() {
	_cleanup_bg
	if [[ -n "${LOCKDIR:-}" && -d "$LOCKDIR" ]]; then
		rm -rf "$LOCKDIR"
	fi
	: >"$WRAPPER_LOGFILE" 2>/dev/null || true
	# Reset env vars potentially set by previous tests
	unset PULSE_CANARY_MODE PULSE_DRY_RUN
	PULSE_LOCK_MAX_AGE_S=1800
	return 0
}

# Spawn a real background process to use as a "live PID" target.
# Sets _SPAWNED_PID global (avoids subshell semantics that would block on
# stdout — `$(sleep 60 &)` waits for the background process to release
# stdout, defeating the point).
_SPAWNED_PID=""
_spawn_live_pid() {
	sleep 60 >/dev/null 2>&1 &
	_SPAWNED_PID=$!
	BG_PIDS="$BG_PIDS $_SPAWNED_PID"
	return 0
}

# Find a guaranteed-dead PID (high number not in use).
# Sets _DEAD_PID global (same subshell-avoidance reason as above).
_DEAD_PID=""
_find_dead_pid() {
	local pid=999999
	while ps -p "$pid" >/dev/null 2>&1; do
		pid=$((pid + 1))
	done
	_DEAD_PID="$pid"
	return 0
}

#######################################
# Test 1: Alive + young owner — short-circuit returns 0 (skip)
# This is the legitimate "pulse already running" case.
#######################################
test_alive_young_owner_skips() {
	reset_state

	local live_pid
	_spawn_live_pid
	live_pid="$_SPAWNED_PID"

	mkdir -p "$LOCKDIR"
	echo "$live_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=120
	PULSE_LOCK_MAX_AGE_S=1800

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "alive+young: returns 0 (skip cycle)" "0" "$result"

	if grep -q "Pulse already running.*age 120s" "$WRAPPER_LOGFILE" 2>/dev/null; then
		print_result "alive+young: 'already running' logged with age" 0
	else
		print_result "alive+young: 'already running' logged with age" 1 \
			"no 'already running...age 120s' line in wrapper log"
	fi
	return 0
}

#######################################
# Test 2: Alive + stale owner — short-circuit returns 1 (fall through)
# The t2829 fix: this case used to incorrectly return 0 (skip) and bypass
# the stale-lock reclaim path entirely.
#######################################
test_alive_stale_owner_falls_through() {
	reset_state

	local live_pid
	_spawn_live_pid
	live_pid="$_SPAWNED_PID"

	mkdir -p "$LOCKDIR"
	echo "$live_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=2500  # > 1800s ceiling
	PULSE_LOCK_MAX_AGE_S=1800

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "alive+stale: returns 1 (fall through to reclaim path)" "1" "$result"

	if grep -q "deferring to acquire_instance_lock for reclaim (t2829)" "$WRAPPER_LOGFILE" 2>/dev/null; then
		print_result "alive+stale: t2829 deferral logged" 0
	else
		print_result "alive+stale: t2829 deferral logged" 1 \
			"no 't2829' deferral line in wrapper log"
	fi
	return 0
}

#######################################
# Test 3: Dead PID owner — short-circuit returns 1 (fall through)
# Existing behavior, sanity check that my fix didn't regress it.
#######################################
test_dead_pid_owner_falls_through() {
	reset_state

	local dead_pid
	_find_dead_pid
	dead_pid="$_DEAD_PID"

	mkdir -p "$LOCKDIR"
	echo "$dead_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=0  # irrelevant, kill -0 will fail first

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "dead PID: returns 1 (fall through)" "1" "$result"
	return 0
}

#######################################
# Test 4: No PID file — short-circuit returns 1 (fall through)
#######################################
test_no_pid_file_falls_through() {
	reset_state
	# Do NOT create LOCKDIR or PID file

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "no PID file: returns 1 (fall through)" "1" "$result"
	return 0
}

#######################################
# Test 5: Self-PID owner — short-circuit returns 1 (fall through)
# Defensive — if somehow the PID file points to us, we shouldn't
# self-block (the lock will be picked up by acquire_instance_lock).
#######################################
test_self_pid_falls_through() {
	reset_state

	mkdir -p "$LOCKDIR"
	echo "$$" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=120

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "self-PID: returns 1 (fall through)" "1" "$result"
	return 0
}

#######################################
# Test 6: Malformed PID — short-circuit returns 1 (fall through)
#######################################
test_malformed_pid_falls_through() {
	reset_state

	mkdir -p "$LOCKDIR"
	echo "not-a-pid" >"${LOCKDIR}/pid"

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "malformed PID: returns 1 (fall through)" "1" "$result"
	return 0
}

#######################################
# Test 7: PULSE_LOCK_MAX_AGE_S env override changes the ceiling
# Lowering the ceiling should make a previously-young owner stale.
#######################################
test_env_override_changes_ceiling() {
	reset_state

	local live_pid
	_spawn_live_pid
	live_pid="$_SPAWNED_PID"

	mkdir -p "$LOCKDIR"
	echo "$live_pid" >"${LOCKDIR}/pid"

	# 500s age, normal ceiling 1800s = young (would skip).
	# Lower ceiling to 300s = stale (should fall through).
	STUB_PROCESS_AGE=500
	PULSE_LOCK_MAX_AGE_S=300

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "env override: returns 1 (fall through at lower ceiling)" "1" "$result"

	if grep -q "ceiling 300s" "$WRAPPER_LOGFILE" 2>/dev/null; then
		print_result "env override: log line cites overridden ceiling" 0
	else
		print_result "env override: log line cites overridden ceiling" 1 \
			"no 'ceiling 300s' in log"
	fi
	return 0
}

#######################################
# Test 8: Non-numeric process age (defensive) — defaults to fall-through
# If _get_process_age returns garbage, the [[ =~ ^[0-9]+$ ]] guard kicks
# in and the alive-but-young branch (return 0) is NOT taken — meaning
# we fall through. This is the safer of the two failure modes (worst
# case: a healthy pulse gets reclaimed; better than: a dead pulse is
# never reclaimed).
#######################################
test_nonnumeric_age_falls_through() {
	reset_state

	local live_pid
	_spawn_live_pid
	live_pid="$_SPAWNED_PID"

	mkdir -p "$LOCKDIR"
	echo "$live_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE="garbage"
	PULSE_LOCK_MAX_AGE_S=1800

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "non-numeric age: returns 1 (fall through)" "1" "$result"
	return 0
}

#######################################
# Test 9: Log line format includes ceiling reason (t2829 marker)
# This is a grep-able marker that operators can use to identify
# stale-lock fall-throughs in the wrapper log.
#######################################
test_log_marker_format() {
	reset_state

	local live_pid
	_spawn_live_pid
	live_pid="$_SPAWNED_PID"

	mkdir -p "$LOCKDIR"
	echo "$live_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=3600
	PULSE_LOCK_MAX_AGE_S=1800

	_is_running_short_circuit || true

	# The log line MUST contain the t2829 marker so we can grep for
	# all t2829 fall-throughs across logs.
	if grep -q "(t2829)" "$WRAPPER_LOGFILE" 2>/dev/null; then
		print_result "log marker: '(t2829)' present in fall-through log line" 0
	else
		print_result "log marker: '(t2829)' present in fall-through log line" 1 \
			"no '(t2829)' marker in log"
	fi
	return 0
}

#######################################
# Test 10: Canary mode bypasses short-circuit (returns 1, falls through)
#######################################
test_canary_mode_bypasses() {
	reset_state

	local live_pid
	_spawn_live_pid
	live_pid="$_SPAWNED_PID"

	mkdir -p "$LOCKDIR"
	echo "$live_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=120  # would normally short-circuit
	export PULSE_CANARY_MODE=1

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "canary mode: returns 1 (bypass short-circuit)" "1" "$result"
	return 0
}

#######################################
# Test 11: Dry-run mode bypasses short-circuit
#######################################
test_dry_run_mode_bypasses() {
	reset_state

	local live_pid
	_spawn_live_pid
	live_pid="$_SPAWNED_PID"

	mkdir -p "$LOCKDIR"
	echo "$live_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=120
	export PULSE_DRY_RUN=1

	local result=0
	_is_running_short_circuit || result=$?

	assert_equals "dry-run mode: returns 1 (bypass short-circuit)" "1" "$result"
	return 0
}

#######################################
# Main
#######################################
main() {
	setup_sandbox

	echo ""
	echo "=== Pulse is_running Stale-Lock Breaker Tests (t2829, GH#20867) ==="
	echo ""

	test_alive_young_owner_skips
	test_alive_stale_owner_falls_through
	test_dead_pid_owner_falls_through
	test_no_pid_file_falls_through
	test_self_pid_falls_through
	test_malformed_pid_falls_through
	test_env_override_changes_ceiling
	test_nonnumeric_age_falls_through
	test_log_marker_format
	test_canary_mode_bypasses
	test_dry_run_mode_bypasses

	teardown_sandbox

	echo ""
	printf "Results: %d/%d passed" "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf " (%d FAILED)" "$TESTS_FAILED"
		echo ""
		exit 1
	fi
	echo ""
	exit 0
}

main "$@"
