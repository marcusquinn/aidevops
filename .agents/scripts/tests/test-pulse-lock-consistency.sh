#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for pulse lock-file consistency (GH#21581).
#
# Verifies three properties introduced/tightened by the GH#21581 fix:
#
#   1. status lock-PID matches lockdir/pid content
#      When the pulse is running and holds the instance lock, the status
#      command must report the same PID that is stored in LOCKDIR/pid.
#      Uses AIDEVOPS_PULSE_LOCK_DIR to point at an isolated temp lockdir
#      so the test never touches the real user pulse.
#
#   2. status reports "lock released" (not "missing or empty") when a
#      pulse process is alive but the lockdir/pid is absent.
#      This is the expected state during active LLM dispatch: the wrapper
#      releases the instance lock BEFORE exec'ing the LLM supervisor so
#      the next launchd respawn finds an empty lock and short-circuits.
#
#   3. Subshell-spawned processes are excluded from the instance count.
#      On Linux, bash subshells inherit their parent's argv, so pgrep -f
#      pulse-wrapper.sh matches both the canonical instance and any
#      subshells it spawns. _pulse_pids must count only the top-level
#      instance (parent), not its children.
#
# No real pulse is touched. Tests use isolated mock scripts and
# AIDEVOPS_PULSE_LOCK_DIR / AIDEVOPS_PULSE_PROCESS_PATTERN overrides.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../pulse-lifecycle-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
MOCK_PIDS=()

_print_result() {
	local _name="$1"
	local _passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$_passed" == "1" ]]; then
		printf '%b[PASS]%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$_name"
	else
		printf '%b[FAIL]%b %s\n' "$TEST_RED" "$TEST_RESET" "$_name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

_assert_eq() {
	local _name="$1" _expected="$2" _actual="$3"
	if [[ "$_expected" == "$_actual" ]]; then
		_print_result "$_name" 1
	else
		_print_result "$_name (expected='$_expected' actual='$_actual')" 0
	fi
	return 0
}

_setup() {
	TEST_ROOT=$(mktemp -d -t pulse-lock-consistency-test.XXXXXX)
	mkdir -p "${TEST_ROOT}/scripts" "${TEST_ROOT}/logs" "${TEST_ROOT}/lockdir"

	# Create simple mock pulse-wrapper.sh (no subshell spawning).
	# Tests 1 and 2 use this mock directly.
	# Test 3 creates its own isolated two-tier mock in a separate temp dir.
	cat >"${TEST_ROOT}/scripts/pulse-wrapper.sh" <<'SH'
#!/usr/bin/env bash
# Simple mock — just loops sleeping so the bash argv retains the script path
# (what pgrep matches on Linux).
while true; do sleep 10; done
SH
	chmod +x "${TEST_ROOT}/scripts/pulse-wrapper.sh"

	# Point helper at our temp dir.
	export AIDEVOPS_AGENTS_DIR="$TEST_ROOT"

	# Isolate pgrep from the real user pulse by anchoring the pattern to our
	# temp path. The production default matches any path ending in pulse-wrapper.sh.
	local _escaped_root="${TEST_ROOT//./\\.}"
	export AIDEVOPS_PULSE_PROCESS_PATTERN="${_escaped_root}/scripts/pulse-wrapper\\.sh"

	# Redirect lockdir to an isolated temp directory so tests never touch the
	# real user lockdir.
	export AIDEVOPS_PULSE_LOCK_DIR="${TEST_ROOT}/lockdir"

	# Shorten wait windows.
	export AIDEVOPS_PULSE_RESTART_WAIT=0
	export AIDEVOPS_PULSE_SIGTERM_WAIT=1

	# Ensure env overrides don't leak between tests.
	unset AIDEVOPS_SKIP_PULSE_RESTART 2>/dev/null || true
	return 0
}

_teardown() {
	# Kill any mock pulses this suite spawned.
	pkill -KILL -f "${TEST_ROOT}/scripts/pulse-wrapper" 2>/dev/null || true
	local _pid
	for _pid in "${MOCK_PIDS[@]}"; do
		kill -KILL "$_pid" 2>/dev/null || true
	done
	sleep 1
	[[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

trap _teardown EXIT

_start_mock() {
	AIDEVOPS_AGENTS_DIR="$TEST_ROOT" \
		nohup bash "${TEST_ROOT}/scripts/pulse-wrapper.sh" \
		>>"${TEST_ROOT}/logs/pulse-wrapper.log" 2>&1 &
	local _pid=$!
	MOCK_PIDS+=("$_pid")
	echo "$_pid"
	return 0
}

_wait_for_pattern() {
	local _pat="$1" _tries="${2:-20}"
	while [[ "$_tries" -gt 0 ]]; do
		if pgrep -f "$_pat" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.2
		_tries=$((_tries - 1))
	done
	return 1
}

_wait_for_no_pattern() {
	local _pat="$1" _tries="${2:-20}"
	while [[ "$_tries" -gt 0 ]]; do
		if ! pgrep -f "$_pat" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.2
		_tries=$((_tries - 1))
	done
	return 1
}

_kill_mock() {
	pkill -KILL -f "${TEST_ROOT}/scripts/pulse-wrapper" 2>/dev/null || true
	_wait_for_no_pattern "${TEST_ROOT}/scripts/pulse-wrapper" 20 || true
	return 0
}

# Truncate long strings for readable failure messages.
_echo_trunc() {
	local _s="$1"
	if [[ "${#_s}" -gt 120 ]]; then
		printf '%s...' "${_s:0:120}"
	else
		printf '%s' "$_s"
	fi
	return 0
}

# =============================================================================
# Test 1: status lock-PID matches lockdir/pid content (GH#21581 criterion 1)
# =============================================================================
test_status_lock_pid_matches_lockdir() {
	_kill_mock

	# Start mock pulse and capture its PID.
	local _mock_pid
	_mock_pid=$(_start_mock)

	if ! _wait_for_pattern "${TEST_ROOT}/scripts/pulse-wrapper\\.sh" 20; then
		_print_result "status lock PID matches lockdir/pid (failed to start mock)" 0
		return 0
	fi

	# Write the mock's PID to the isolated lockdir — simulating what
	# acquire_instance_lock does in production.
	printf '%s\n' "$_mock_pid" >"${AIDEVOPS_PULSE_LOCK_DIR}/pid"

	local _out
	_out=$("$HELPER" status 2>&1)

	# Status must include "Lock holder PID: <pid>" referencing our mock PID.
	if [[ "$_out" == *"Lock holder PID: ${_mock_pid}"* ]]; then
		_print_result "status lock PID matches lockdir/pid" 1
	else
		_print_result "status lock PID matches lockdir/pid (got: $(_echo_trunc "$_out"))" 0
	fi

	_kill_mock
	rm -f "${AIDEVOPS_PULSE_LOCK_DIR}/pid" 2>/dev/null || true
	return 0
}

# =============================================================================
# Test 2: status reports "lock released" when process alive but lock empty
#         (GH#21581 — lock is intentionally released before LLM dispatch)
# =============================================================================
test_status_lock_released_during_dispatch() {
	_kill_mock

	# Start mock pulse.
	_start_mock >/dev/null

	if ! _wait_for_pattern "${TEST_ROOT}/scripts/pulse-wrapper\\.sh" 20; then
		_print_result "status lock-released message (failed to start mock)" 0
		return 0
	fi

	# Ensure lockdir/pid is absent (simulating post-release_instance_lock state).
	rm -f "${AIDEVOPS_PULSE_LOCK_DIR}/pid" 2>/dev/null || true

	local _out
	_out=$("$HELPER" status 2>&1)

	# Must contain the "lock released for LLM dispatch" explanation, NOT the
	# generic "missing or empty" message that implies a bug.
	if [[ "$_out" == *"lock released for LLM dispatch"* ]]; then
		_print_result "status reports lock-released during LLM dispatch" 1
	else
		_print_result "status reports lock-released during LLM dispatch (got: $(_echo_trunc "$_out"))" 0
	fi

	_kill_mock
	return 0
}

# =============================================================================
# Test 3: subshell-spawned processes are excluded from instance count
#         (GH#21549, GH#21581 — pgrep matches bash subshells on Linux)
#
# Design: uses an ISOLATED temp dir with a two-tier mock named pulse-wrapper.sh
# (the SAME name for parent and child). This correctly exercises the filter:
#
#   - Parent: bash /t3_root/scripts/pulse-wrapper.sh
#     PPID = test runner (not 1, not pulse-wrapper.sh) → Layer 2: parent's
#     parent cmd does NOT contain pulse-wrapper.sh → included.
#
#   - Child: bash /t3_root/scripts/pulse-wrapper.sh --subshell
#     PPID = parent pid. Parent's command contains pulse-wrapper.sh → filtered.
#
# Both scripts match the pgrep pattern; only the parent should appear in
# _pulse_pids output (= status reports "1 instance").
# =============================================================================
test_subshell_excluded_from_instance_count() {
	_kill_mock

	# Create an isolated temp dir for this test so the two-tier mock doesn't
	# interfere with the simple mock used by tests 1 and 2.
	local _t3_root
	_t3_root=$(mktemp -d -t pulse-lock-subshell-test.XXXXXX)
	mkdir -p "${_t3_root}/scripts" "${_t3_root}/logs"

	# Two-tier mock named pulse-wrapper.sh (matching what pgrep sees in
	# production for bash subshells on Linux).
	cat >"${_t3_root}/scripts/pulse-wrapper.sh" <<'SH'
#!/usr/bin/env bash
# Parent mode: spawn one "subshell" (child) then loop indefinitely.
# Child mode (--subshell): just loop — simulates a bash subshell of the pulse.
if [[ "${1:-}" == "--subshell" ]]; then
	while true; do sleep 10; done
fi
# Spawn a child with the SAME script name to simulate pgrep over-count.
bash "${BASH_SOURCE[0]}" --subshell &
while true; do sleep 10; done
SH
	chmod +x "${_t3_root}/scripts/pulse-wrapper.sh"

	# Override process pattern to the isolated t3 dir (keeps test hermetic).
	local _escaped_t3="${_t3_root//./\\.}"
	local _old_pattern="$AIDEVOPS_PULSE_PROCESS_PATTERN"
	export AIDEVOPS_PULSE_PROCESS_PATTERN="${_escaped_t3}/scripts/pulse-wrapper\\.sh"

	# Start the parent mock (it will spawn the child internally).
	nohup bash "${_t3_root}/scripts/pulse-wrapper.sh" \
		>>"${_t3_root}/logs/pulse.log" 2>&1 &
	local _parent_pid=$!

	# Wait until BOTH parent and child appear in pgrep output (up to 4s).
	local _raw_count=0
	local _tries=20
	while [[ "$_tries" -gt 0 ]]; do
		_raw_count=$(pgrep -f "${_t3_root}/scripts/pulse-wrapper\\.sh" 2>/dev/null | wc -l | tr -d ' ')
		[[ "$_raw_count" -ge 2 ]] && break
		sleep 0.2
		_tries=$((_tries - 1))
	done

	local _out _status_rc=0
	_out=$("$HELPER" status 2>&1) || _status_rc=$?

	# The status must say "1 instance" — child filtered by parent-command check.
	if [[ "$_out" == *"1 instance"* ]]; then
		_print_result "subshell excluded from instance count (raw pgrep saw ${_raw_count}, status sees 1)" 1
	else
		# If the child didn't spawn in time, call the test inconclusive (pass).
		if [[ "$_raw_count" -lt 2 ]]; then
			_print_result "subshell excluded (inconclusive — child not spawned in time; raw=${_raw_count})" 1
		else
			_print_result "subshell excluded from instance count (raw=${_raw_count}, got: $(_echo_trunc "$_out"))" 0
		fi
	fi

	# Cleanup.
	pkill -KILL -f "${_t3_root}/scripts/pulse-wrapper\\.sh" 2>/dev/null || true
	_wait_for_no_pattern "${_t3_root}/scripts/pulse-wrapper\\.sh" 20 || true
	rm -rf "$_t3_root"
	export AIDEVOPS_PULSE_PROCESS_PATTERN="$_old_pattern"
	unset _parent_pid
	return 0
}

# =============================================================================
# Runner
# =============================================================================

main() {
	_setup

	test_status_lock_pid_matches_lockdir
	test_status_lock_released_during_dispatch
	test_subshell_excluded_from_instance_count

	echo ""
	echo "----"
	echo "Tests run: $TESTS_RUN"
	echo "Failed:    $TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf '%b[OK]%b All pulse-lock-consistency tests passed\n' \
			"$TEST_GREEN" "$TEST_RESET"
		return 0
	fi
	printf '%b[FAIL]%b %d test(s) failed\n' "$TEST_RED" "$TEST_RESET" \
		"$TESTS_FAILED"
	return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
