#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for pulse-lifecycle-helper.sh (t2579).
#
# The helper must NOT operate on the real user pulse. Tests use a mock
# "pulse-wrapper.sh" script in a temp directory and override
# AIDEVOPS_AGENTS_DIR to point there. The mock simply sleeps so it produces
# a live PID that pgrep can match on the process-pattern.
#
# Covers:
#   1. --help emits usage
#   2. Unknown command exits 2 with usage
#   3. is-running exits 1 when no pulse running
#   4. is-running exits 0 when pulse running
#   5. status prints "not running" when stopped
#   6. status prints PID(s) when running
#   7. start launches pulse and is-running flips to 0
#   8. start is idempotent (already-running path)
#   9. stop terminates a running pulse
#   10. stop is idempotent (already-stopped path)
#   11. restart-if-running no-ops when pulse not running
#   12. restart-if-running stops + starts when running (PID changes)
#   13. AIDEVOPS_SKIP_PULSE_RESTART=1 skips restart-if-running
#   14. AIDEVOPS_SKIP_PULSE_RESTART=1 skips restart
#   15. Missing pulse-wrapper.sh → start exits 2
#
# No real pulse is touched. We use a unique mock filename and match pattern
# on pulse-wrapper.sh which we control inside TEST_ROOT.

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
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" == "1" ]]; then
		printf '%b[PASS]%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%b[FAIL]%b %s\n' "$TEST_RED" "$TEST_RESET" "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

_assert_eq() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		_print_result "$name" 1
	else
		_print_result "$name (expected='$expected' actual='$actual')" 0
	fi
	return 0
}

_setup() {
	TEST_ROOT=$(mktemp -d -t pulse-lifecycle-test.XXXXXX)
	mkdir -p "${TEST_ROOT}/scripts" "${TEST_ROOT}/logs"

	# Create mock pulse-wrapper.sh that sleeps long enough to be caught by
	# pgrep. sleep 300 keeps it alive for the life of the test suite.
	cat >"${TEST_ROOT}/scripts/pulse-wrapper.sh" <<'SH'
#!/usr/bin/env bash
# Mock pulse — just sleeps. Using a bash while loop (not exec sleep) so
# the bash argv retains the script path, which is what pgrep matches on.
while true; do sleep 10; done
SH
	chmod +x "${TEST_ROOT}/scripts/pulse-wrapper.sh"

	# Point helper at our temp dir.
	export AIDEVOPS_AGENTS_DIR="$TEST_ROOT"

	# Isolate the helper's pgrep from the user's real pulse by anchoring
	# the pattern to our TEST_ROOT path. The production default pattern
	# is the equivalent without path anchoring — see the helper header.
	# Escape TEST_ROOT for use inside an extended regex: / stays, but
	# . must be escaped. mktemp paths contain only [A-Za-z0-9./] so this
	# is sufficient.
	local _escaped_root="${TEST_ROOT//./\\.}"
	export AIDEVOPS_PULSE_PROCESS_PATTERN="${_escaped_root}/scripts/pulse-wrapper\\.sh"

	# Ensure env overrides don't leak between tests.
	unset AIDEVOPS_SKIP_PULSE_RESTART 2>/dev/null || true
	# Shorten wait windows so tests finish quickly.
	export AIDEVOPS_PULSE_RESTART_WAIT=0
	export AIDEVOPS_PULSE_SIGTERM_WAIT=1
}

_teardown() {
	# Kill any mock pulses this suite spawned.
	if [[ -n "${TEST_ROOT:-}" ]]; then
		pkill -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" 2>/dev/null || true
	fi
	# Also catch any residual mock PIDs we noted.
	local _pid
	for _pid in "${MOCK_PIDS[@]}"; do
		kill -KILL "$_pid" 2>/dev/null || true
	done
	sleep 1
	[[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
}

trap _teardown EXIT

# Returns 0 if a mock pulse from our TEST_ROOT is alive, 1 otherwise.
# Separate from the helper's own pgrep so we independently verify state.
_mock_pulse_alive() {
	pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" >/dev/null 2>&1
}

_wait_for_mock_pulse() {
	local _tries="${1:-10}"
	while [[ "$_tries" -gt 0 ]]; do
		if _mock_pulse_alive; then
			return 0
		fi
		sleep 0.2
		_tries=$((_tries - 1))
	done
	return 1
}

_wait_for_no_mock_pulse() {
	local _tries="${1:-10}"
	while [[ "$_tries" -gt 0 ]]; do
		if ! _mock_pulse_alive; then
			return 0
		fi
		sleep 0.2
		_tries=$((_tries - 1))
	done
	return 1
}

_kill_mocks() {
	pkill -KILL -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" 2>/dev/null || true
	_wait_for_no_mock_pulse 20 || true
}

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

test_help_emits_usage() {
	local out
	out=$("$HELPER" --help 2>&1)
	if [[ "$out" == *"Usage:"* && "$out" == *"restart-if-running"* ]]; then
		_print_result "help emits usage" 1
	else
		_print_result "help emits usage (missing Usage or subcommands)" 0
	fi
	return 0
}

test_unknown_command_exits_2() {
	local rc=0
	"$HELPER" this-is-not-a-command >/dev/null 2>&1 || rc=$?
	_assert_eq "unknown command exits 2" "2" "$rc"
	return 0
}

test_is_running_exit_1_when_stopped() {
	_kill_mocks
	local rc=0
	"$HELPER" is-running >/dev/null 2>&1 || rc=$?
	_assert_eq "is-running exits 1 when stopped" "1" "$rc"
	return 0
}

test_is_running_exit_0_when_running() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	if ! _wait_for_mock_pulse 20; then
		_print_result "is-running exits 0 when running (failed to start mock)" 0
		return 0
	fi
	local rc=0
	"$HELPER" is-running >/dev/null 2>&1 || rc=$?
	_assert_eq "is-running exits 0 when running" "0" "$rc"
	_kill_mocks
	return 0
}

test_status_when_stopped() {
	_kill_mocks
	local out
	out=$("$HELPER" status 2>&1)
	if [[ "$out" == *"not running"* ]]; then
		_print_result "status prints 'not running' when stopped" 1
	else
		_print_result "status when stopped (got: $out)" 0
	fi
	return 0
}

test_status_when_running() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local out
	out=$("$HELPER" status 2>&1)
	if [[ "$out" == *"running"* && "$out" == *"PID"* ]]; then
		_print_result "status prints PID(s) when running" 1
	else
		_print_result "status when running (got: $out)" 0
	fi
	_kill_mocks
	return 0
}

test_start_launches_pulse() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	if _wait_for_mock_pulse 20; then
		_print_result "start launches pulse" 1
	else
		_print_result "start launches pulse (pulse did not appear)" 0
	fi
	_kill_mocks
	return 0
}

test_start_is_idempotent() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local first_pid
	first_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	# Second start should no-op, PID should be unchanged.
	"$HELPER" start >/dev/null 2>&1 || true
	sleep 0.5
	local second_pid
	second_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	_assert_eq "start idempotent (same PID)" "$first_pid" "$second_pid"
	_kill_mocks
	return 0
}

test_stop_terminates_running() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	"$HELPER" stop >/dev/null 2>&1 || true
	if _wait_for_no_mock_pulse 20; then
		_print_result "stop terminates running pulse" 1
	else
		_print_result "stop terminates running pulse (residual PIDs found)" 0
		_kill_mocks
	fi
	return 0
}

test_stop_idempotent_when_stopped() {
	_kill_mocks
	local rc=0
	"$HELPER" stop >/dev/null 2>&1 || rc=$?
	_assert_eq "stop idempotent when stopped" "0" "$rc"
	return 0
}

test_restart_if_running_noop_when_stopped() {
	_kill_mocks
	local rc=0
	"$HELPER" restart-if-running >/dev/null 2>&1 || rc=$?
	_assert_eq "restart-if-running no-op exit 0 when stopped" "0" "$rc"
	# And it must NOT have started a pulse.
	if _mock_pulse_alive; then
		_print_result "restart-if-running did not spuriously start pulse" 0
		_kill_mocks
	else
		_print_result "restart-if-running did not spuriously start pulse" 1
	fi
	return 0
}

test_restart_if_running_replaces_pid() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local first_pid
	first_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	"$HELPER" restart-if-running >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local second_pid
	second_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)

	if [[ -n "$first_pid" && -n "$second_pid" && "$first_pid" != "$second_pid" ]]; then
		_print_result "restart-if-running replaces PID" 1
	else
		_print_result "restart-if-running replaces PID (first=$first_pid second=$second_pid)" 0
	fi
	_kill_mocks
	return 0
}

test_skip_env_honoured_in_restart_if_running() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local first_pid
	first_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	AIDEVOPS_SKIP_PULSE_RESTART=1 "$HELPER" restart-if-running >/dev/null 2>&1 || true
	sleep 0.5
	local second_pid
	second_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	_assert_eq "AIDEVOPS_SKIP_PULSE_RESTART=1 preserves PID (restart-if-running)" \
		"$first_pid" "$second_pid"
	_kill_mocks
	return 0
}

test_skip_env_honoured_in_restart() {
	_kill_mocks
	"$HELPER" start >/dev/null 2>&1 || true
	_wait_for_mock_pulse 20 || true
	local first_pid
	first_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	AIDEVOPS_SKIP_PULSE_RESTART=1 "$HELPER" restart >/dev/null 2>&1 || true
	sleep 0.5
	local second_pid
	second_pid=$(pgrep -f "${TEST_ROOT}/scripts/pulse-wrapper.sh" | head -1)
	_assert_eq "AIDEVOPS_SKIP_PULSE_RESTART=1 preserves PID (restart)" \
		"$first_pid" "$second_pid"
	_kill_mocks
	return 0
}

test_missing_pulse_script_exit_2() {
	_kill_mocks
	# Move the mock away so the helper sees no pulse-wrapper.sh.
	local _saved="${TEST_ROOT}/scripts/pulse-wrapper.sh.hidden"
	mv "${TEST_ROOT}/scripts/pulse-wrapper.sh" "$_saved"
	local rc=0
	"$HELPER" start >/dev/null 2>&1 || rc=$?
	# Restore for subsequent tests.
	mv "$_saved" "${TEST_ROOT}/scripts/pulse-wrapper.sh"
	_assert_eq "start with missing pulse-wrapper.sh exits 2" "2" "$rc"
	return 0
}

# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------

main() {
	_setup

	test_help_emits_usage
	test_unknown_command_exits_2
	test_is_running_exit_1_when_stopped
	test_is_running_exit_0_when_running
	test_status_when_stopped
	test_status_when_running
	test_start_launches_pulse
	test_start_is_idempotent
	test_stop_terminates_running
	test_stop_idempotent_when_stopped
	test_restart_if_running_noop_when_stopped
	test_restart_if_running_replaces_pid
	test_skip_env_honoured_in_restart_if_running
	test_skip_env_honoured_in_restart
	test_missing_pulse_script_exit_2

	echo ""
	echo "----"
	echo "Tests run: $TESTS_RUN"
	echo "Failed:    $TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf '%b[OK]%b All pulse-lifecycle-helper tests passed\n' \
			"$TEST_GREEN" "$TEST_RESET"
		return 0
	fi
	printf '%b[FAIL]%b %d test(s) failed\n' "$TEST_RED" "$TEST_RESET" \
		"$TESTS_FAILED"
	return 1
}

main "$@"
