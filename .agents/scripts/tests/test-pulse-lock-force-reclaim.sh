#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for pulse lock force-reclaim (GH#20025).
#
# Asserts:
#   1. Live pulse owner within age ceiling — do NOT reclaim (normal operation)
#   2. Dead PID owner — reclaim (existing behaviour, sanity check)
#   3. Alive-but-stale owner (age > PULSE_LOCK_MAX_AGE_S) — reclaim after ceiling
#   4. PID reused by unrelated process — reclaim immediately
#   5. AIDEVOPS_PULSE_LOCK_MAX_AGE_S env override adjusts ceiling
#
# This test sources pulse-instance-lock.sh directly with a minimal stub
# environment (same pattern as test-pulse-instance-lock-mkdir-only.sh).

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
PULSE_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly PULSE_SCRIPTS_DIR

# Track _kill_tree calls for verification
KILL_TREE_CALLED=0
KILL_TREE_PID=""

# PIDs of background processes launched by tests (cleaned up in teardown)
BG_PIDS=""

# Configurable stub: _get_process_age returns STUB_PROCESS_AGE
STUB_PROCESS_AGE=42

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

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"

	LOCKDIR="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
	WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
	_LOCK_OWNED=false
	PULSE_STALE_THRESHOLD=3600
	PULSE_LOCK_MAX_AGE_S=1800
	export LOCKDIR WRAPPER_LOGFILE LOGFILE PIDFILE _LOCK_OWNED
	export PULSE_STALE_THRESHOLD PULSE_LOCK_MAX_AGE_S

	KILL_TREE_CALLED=0
	KILL_TREE_PID=""
	BG_PIDS=""

	# Create a fake pulse-wrapper.sh script that tests can launch
	cat >"${TEST_ROOT}/pulse-wrapper.sh" <<'FAKEOF'
#!/usr/bin/env bash
exec sleep 60
FAKEOF
	chmod +x "${TEST_ROOT}/pulse-wrapper.sh"

	# Stub helpers
	_get_process_age() {
		echo "$STUB_PROCESS_AGE"
		return 0
	}
	_kill_tree() {
		KILL_TREE_CALLED=1
		KILL_TREE_PID="$1"
		return 0
	}
	_force_kill_tree() { return 0; }
	get_max_workers_target() { echo "1"; return 0; }
	count_active_workers() { echo "0"; return 0; }
	export -f _get_process_age _kill_tree _force_kill_tree
	export -f get_max_workers_target count_active_workers

	# Force re-source by clearing include guard
	unset _PULSE_INSTANCE_LOCK_LOADED 2>/dev/null || true
	# shellcheck source=/dev/null
	source "${PULSE_SCRIPTS_DIR}/pulse-instance-lock.sh"
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
	if [[ -n "${LOCKDIR:-}" && -d "$LOCKDIR" ]]; then
		rm -rf "$LOCKDIR"
	fi
	_LOCK_OWNED=false
	return 0
}

reset_state() {
	_cleanup_bg
	if [[ -n "${LOCKDIR:-}" && -d "$LOCKDIR" ]]; then
		rm -rf "$LOCKDIR"
	fi
	_LOCK_OWNED=false
	KILL_TREE_CALLED=0
	KILL_TREE_PID=""
	: >"$WRAPPER_LOGFILE" 2>/dev/null || true
	return 0
}

#######################################
# Test 1: Live pulse owner within age ceiling — do NOT reclaim
#######################################
test_live_owner_within_ceiling() {
	reset_state

	# Launch a real background process named "pulse-wrapper.sh"
	"${TEST_ROOT}/pulse-wrapper.sh" &
	local fake_pid=$!
	BG_PIDS="$BG_PIDS $fake_pid"

	mkdir -p "$LOCKDIR"
	echo "$fake_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=120
	PULSE_LOCK_MAX_AGE_S=1800

	local result=0
	_handle_existing_lock || result=$?

	assert_equals "live owner within ceiling: returns 1 (blocked)" "1" "$result"
	assert_equals "live owner within ceiling: _kill_tree NOT called" "0" "$KILL_TREE_CALLED"

	if [[ -d "$LOCKDIR" ]]; then
		print_result "live owner within ceiling: LOCKDIR preserved" 0
	else
		print_result "live owner within ceiling: LOCKDIR preserved" 1 "LOCKDIR was removed"
	fi
	return 0
}

#######################################
# Test 2: Dead PID owner — reclaim (existing behaviour)
#######################################
test_dead_pid_owner() {
	reset_state

	mkdir -p "$LOCKDIR"
	local fake_dead_pid=999999
	while ps -p "$fake_dead_pid" >/dev/null 2>&1; do
		fake_dead_pid=$((fake_dead_pid + 1))
	done
	echo "$fake_dead_pid" >"${LOCKDIR}/pid"

	local result=0
	_handle_existing_lock || result=$?

	if [[ "$result" -eq 0 ]]; then
		print_result "dead PID owner: lock reclaimed (returns 0)" 0
	else
		print_result "dead PID owner: lock reclaimed (returns 0)" 1 "got result=$result"
	fi

	if [[ -d "$LOCKDIR" ]]; then
		print_result "dead PID owner: LOCKDIR recreated" 0
	else
		print_result "dead PID owner: LOCKDIR recreated" 1
	fi
	return 0
}

#######################################
# Test 3: Alive-but-stale owner — reclaim after age ceiling
#######################################
test_alive_but_stale_owner() {
	reset_state

	"${TEST_ROOT}/pulse-wrapper.sh" &
	local fake_pid=$!
	BG_PIDS="$BG_PIDS $fake_pid"

	mkdir -p "$LOCKDIR"
	echo "$fake_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=2500
	PULSE_LOCK_MAX_AGE_S=1800

	local result=0
	_handle_existing_lock || result=$?

	assert_equals "alive-but-stale: returns 0 (reclaimed)" "0" "$result"
	assert_equals "alive-but-stale: _kill_tree called" "1" "$KILL_TREE_CALLED"

	if grep -q "FORCE-RECLAIMED.*ceiling" "$WRAPPER_LOGFILE" 2>/dev/null; then
		print_result "alive-but-stale: force-reclaim logged" 0
	else
		print_result "alive-but-stale: force-reclaim logged" 1 "no FORCE-RECLAIMED line in wrapper log"
	fi
	return 0
}

#######################################
# Test 4: PID reused by unrelated process — reclaim immediately
#######################################
test_pid_reused_by_unrelated() {
	reset_state

	# Launch a plain sleep (NOT pulse-wrapper)
	sleep 60 &
	local non_pulse_pid=$!
	BG_PIDS="$BG_PIDS $non_pulse_pid"

	mkdir -p "$LOCKDIR"
	echo "$non_pulse_pid" >"${LOCKDIR}/pid"

	STUB_PROCESS_AGE=100

	local result=0
	_handle_existing_lock || result=$?

	assert_equals "PID reuse: returns 0 (reclaimed)" "0" "$result"
	assert_equals "PID reuse: _kill_tree NOT called (don't kill unrelated)" "0" "$KILL_TREE_CALLED"

	if grep -q "FORCE-RECLAIMED.*PID reused" "$WRAPPER_LOGFILE" 2>/dev/null; then
		print_result "PID reuse: force-reclaim logged with PID-reuse reason" 0
	else
		print_result "PID reuse: force-reclaim logged with PID-reuse reason" 1 "no PID-reuse FORCE-RECLAIMED line"
	fi
	return 0
}

#######################################
# Test 5: AIDEVOPS_PULSE_LOCK_MAX_AGE_S env override adjusts ceiling
#######################################
test_env_override_adjusts_ceiling() {
	reset_state

	"${TEST_ROOT}/pulse-wrapper.sh" &
	local fake_pid=$!
	BG_PIDS="$BG_PIDS $fake_pid"

	mkdir -p "$LOCKDIR"
	echo "$fake_pid" >"${LOCKDIR}/pid"

	# Age is 500s, default ceiling is 1800s — normally fine.
	# But we lower the ceiling to 300s.
	STUB_PROCESS_AGE=500
	PULSE_LOCK_MAX_AGE_S=300

	local result=0
	_handle_existing_lock || result=$?

	assert_equals "env override: returns 0 (reclaimed at lower ceiling)" "0" "$result"
	assert_equals "env override: _kill_tree called" "1" "$KILL_TREE_CALLED"
	return 0
}

#######################################
# Test 6: Double-release — voluntary pre-LLM release followed by EXIT trap
# must NOT remove a LOCKDIR reacquired by a new instance (GH#20260).
#
# Scenario that the original code got wrong:
#   1. Pulse A acquires lock (_LOCK_OWNED=true, LOCKDIR/pid=$A_PID)
#   2. Pulse A voluntarily releases before LLM: release_instance_lock()
#      → LOCKDIR removed, but OLD CODE left _LOCK_OWNED=true
#   3. Pulse B acquires lock (LOCKDIR/pid=$B_PID)
#   4. Pulse A's EXIT trap fires: release_instance_lock()
#      → OLD CODE: _LOCK_OWNED=true → rm -rf LOCKDIR (B's lock removed!)
#      → NEW CODE: _LOCK_OWNED=false (reset in step 2) → early return
#
# This test simulates step 4 by directly setting _LOCK_OWNED=true and
# planting a LOCKDIR owned by a different PID, then calling
# release_instance_lock() and asserting the LOCKDIR is preserved.
#######################################
test_double_release_preserves_new_owner() {
	reset_state

	# Plant a LOCKDIR owned by a "foreign" PID (not $$)
	# Use a PID known to be dead to avoid any ps side-effects
	local foreign_pid=999988
	while ps -p "$foreign_pid" >/dev/null 2>&1; do
		foreign_pid=$((foreign_pid + 1))
	done
	mkdir -p "$LOCKDIR"
	echo "$foreign_pid" >"${LOCKDIR}/pid"

	# Force _LOCK_OWNED=true to simulate the bug state (voluntary release
	# did not reset it — as the OLD code would leave it)
	_LOCK_OWNED=true

	# Call release_instance_lock as the EXIT trap would
	release_instance_lock

	# With the GH#20260 fix the LOCKDIR must still exist — we did NOT own it
	if [[ -d "$LOCKDIR" ]]; then
		print_result "double-release: LOCKDIR owned by foreign PID preserved" 0
	else
		print_result "double-release: LOCKDIR owned by foreign PID preserved" 1 \
			"EXIT trap incorrectly removed another instance's lock"
	fi

	# _LOCK_OWNED must be false regardless
	assert_equals "double-release: _LOCK_OWNED reset to false" "false" "$_LOCK_OWNED"

	if grep -q "reacquired by PID" "$WRAPPER_LOGFILE" 2>/dev/null; then
		print_result "double-release: skip-removal logged" 0
	else
		print_result "double-release: skip-removal logged" 1 "no skip-removal log line found"
	fi
	return 0
}

#######################################
# Test 7: Legitimate self-release — when LOCKDIR/pid matches $$,
# release_instance_lock DOES remove it (normal exit path).
#######################################
test_self_release_removes_own_lock() {
	reset_state

	acquire_instance_lock >/dev/null

	local pid_before
	pid_before=$(cat "${LOCKDIR}/pid" 2>/dev/null || echo "")
	assert_equals "self-release setup: PID file contains \$\$" "$$" "$pid_before"

	release_instance_lock

	if [[ ! -d "$LOCKDIR" ]]; then
		print_result "self-release: LOCKDIR removed" 0
	else
		print_result "self-release: LOCKDIR removed" 1 "LOCKDIR still exists after self-release"
	fi

	assert_equals "self-release: _LOCK_OWNED reset to false" "false" "$_LOCK_OWNED"
	return 0
}

#######################################
# Main
#######################################
main() {
	setup_sandbox

	echo ""
	echo "=== Pulse Lock Force-Reclaim Tests (GH#20025 + GH#20260) ==="
	echo ""

	test_live_owner_within_ceiling
	test_dead_pid_owner
	test_alive_but_stale_owner
	test_pid_reused_by_unrelated
	test_env_override_adjusts_ceiling
	test_double_release_preserves_new_owner
	test_self_release_removes_own_lock

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
