#!/usr/bin/env bash
# shellcheck disable=SC2034

# =============================================================================
# Test Script for circuit-breaker-helper.sh (t1331)
# =============================================================================
# Tests circuit breaker logic without requiring GitHub API or supervisor DB.
# Focuses on: state transitions, threshold tripping, auto-reset, manual reset,
# success counter reset, CLI subcommands.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../circuit-breaker-helper.sh"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RESET='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Temp dir for test isolation
TEST_DIR=""

#######################################
# Print test result
# Arguments:
#   $1 - Test name
#   $2 - Result (0=pass, 1=fail)
#   $3 - Optional message
# Returns:
#   0 always
#######################################
print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$result" -eq 0 ]]; then
		echo -e "${GREEN}PASS${RESET} $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${RED}FAIL${RESET} $test_name"
		if [[ -n "$message" ]]; then
			echo "       $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

#######################################
# Setup test environment
# Creates isolated temp directory for state files
# Returns:
#   0 on success
#######################################
setup() {
	TEST_DIR=$(mktemp -d)
	export SUPERVISOR_DIR="$TEST_DIR"
	# Disable GitHub issue creation in tests
	export CB_SKIP_GITHUB="true"
	# Use default threshold of 3
	export SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD=3
	# Long cooldown for most tests (prevents accidental auto-reset)
	export SUPERVISOR_CIRCUIT_BREAKER_COOLDOWN_SECS=3600
	return 0
}

#######################################
# Teardown test environment
# Removes temp directory
# Returns:
#   0 on success
#######################################
teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

# =============================================================================
# TESTS
# =============================================================================

test_helper_exists() {
	if [[ -x "$HELPER" ]]; then
		print_result "helper script exists and is executable" 0
	else
		print_result "helper script exists and is executable" 1 "Not found or not executable: $HELPER"
	fi
	return 0
}

test_help_command() {
	local output
	output=$("$HELPER" help 2>&1) || true
	if echo "$output" | grep -q "circuit-breaker-helper.sh"; then
		print_result "help command shows usage" 0
	else
		print_result "help command shows usage" 1 "Output: $output"
	fi
	return 0
}

test_initial_state_closed() {
	setup
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "initial state is CLOSED (dispatch allowed)" 0
	else
		print_result "initial state is CLOSED (dispatch allowed)" 1 "Exit code: $rc"
	fi
	teardown
	return 0
}

test_initial_status_shows_closed() {
	setup
	local output
	output=$("$HELPER" status 2>/dev/null) || true
	if echo "$output" | grep -q "CLOSED"; then
		print_result "initial status shows CLOSED" 0
	else
		print_result "initial status shows CLOSED" 1 "Output: $output"
	fi
	teardown
	return 0
}

test_single_failure_does_not_trip() {
	setup
	"$HELPER" record-failure "t001" "test failure" 2>/dev/null || true
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "single failure does not trip breaker" 0
	else
		print_result "single failure does not trip breaker" 1 "Exit code: $rc"
	fi
	teardown
	return 0
}

test_two_failures_does_not_trip() {
	setup
	"$HELPER" record-failure "t001" "failure 1" 2>/dev/null || true
	"$HELPER" record-failure "t002" "failure 2" 2>/dev/null || true
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "two failures does not trip breaker (threshold=3)" 0
	else
		print_result "two failures does not trip breaker (threshold=3)" 1 "Exit code: $rc"
	fi
	teardown
	return 0
}

test_three_failures_trips_breaker() {
	setup
	"$HELPER" record-failure "t001" "failure 1" 2>/dev/null || true
	"$HELPER" record-failure "t002" "failure 2" 2>/dev/null || true
	"$HELPER" record-failure "t003" "failure 3" 2>/dev/null || true
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "three failures trips breaker" 0
	else
		print_result "three failures trips breaker" 1 "Expected exit 1, got: $rc"
	fi
	teardown
	return 0
}

test_status_shows_open_after_trip() {
	setup
	"$HELPER" record-failure "t001" "f1" 2>/dev/null || true
	"$HELPER" record-failure "t002" "f2" 2>/dev/null || true
	"$HELPER" record-failure "t003" "f3" 2>/dev/null || true
	local output
	output=$("$HELPER" status 2>/dev/null) || true
	if echo "$output" | grep -q "OPEN"; then
		print_result "status shows OPEN after trip" 0
	else
		print_result "status shows OPEN after trip" 1 "Output: $output"
	fi
	teardown
	return 0
}

test_success_resets_counter() {
	setup
	"$HELPER" record-failure "t001" "f1" 2>/dev/null || true
	"$HELPER" record-failure "t002" "f2" 2>/dev/null || true
	# Record success — should reset counter to 0
	"$HELPER" record-success 2>/dev/null || true
	# Now record 2 more failures — should NOT trip (counter was reset)
	"$HELPER" record-failure "t003" "f3" 2>/dev/null || true
	"$HELPER" record-failure "t004" "f4" 2>/dev/null || true
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "success resets failure counter" 0
	else
		print_result "success resets failure counter" 1 "Expected exit 0, got: $rc"
	fi
	teardown
	return 0
}

test_success_resets_tripped_breaker() {
	setup
	# Trip the breaker
	"$HELPER" record-failure "t001" "f1" 2>/dev/null || true
	"$HELPER" record-failure "t002" "f2" 2>/dev/null || true
	"$HELPER" record-failure "t003" "f3" 2>/dev/null || true
	# Verify tripped
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	[[ "$rc" -eq 1 ]] || {
		print_result "success resets tripped breaker" 1 "Breaker not tripped before success"
		teardown
		return 0
	}
	# Record success — should reset the breaker
	"$HELPER" record-success 2>/dev/null || true
	rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "success resets tripped breaker" 0
	else
		print_result "success resets tripped breaker" 1 "Expected exit 0 after success, got: $rc"
	fi
	teardown
	return 0
}

test_manual_reset() {
	setup
	# Trip the breaker
	"$HELPER" trip "t001" "test" 2>/dev/null || true
	# Verify tripped
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	[[ "$rc" -eq 1 ]] || {
		print_result "manual reset resumes dispatch" 1 "Breaker not tripped after trip command"
		teardown
		return 0
	}
	# Reset
	"$HELPER" reset "test_reset" 2>/dev/null || true
	rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "manual reset resumes dispatch" 0
	else
		print_result "manual reset resumes dispatch" 1 "Expected exit 0 after reset, got: $rc"
	fi
	teardown
	return 0
}

test_manual_trip() {
	setup
	"$HELPER" trip "manual-test" "testing" 2>/dev/null || true
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "manual trip pauses dispatch" 0
	else
		print_result "manual trip pauses dispatch" 1 "Expected exit 1, got: $rc"
	fi
	teardown
	return 0
}

test_auto_reset_after_cooldown() {
	setup
	# Set short cooldown (2 seconds) — must be long enough that the trip
	# command + first check complete before the cooldown expires
	export SUPERVISOR_CIRCUIT_BREAKER_COOLDOWN_SECS=2
	# Trip the breaker using record-failure (3x) instead of trip command
	# to test the full failure path
	"$HELPER" record-failure "t001" "f1" 2>/dev/null || true
	"$HELPER" record-failure "t002" "f2" 2>/dev/null || true
	"$HELPER" record-failure "t003" "f3" 2>/dev/null || true
	# Verify tripped
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -ne 1 ]]; then
		print_result "auto-reset after cooldown" 1 "Breaker not tripped (rc=$rc)"
		teardown
		return 0
	fi
	# Wait for cooldown to expire
	sleep 3
	# Check again — should auto-reset
	rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "auto-reset after cooldown" 0
	else
		print_result "auto-reset after cooldown" 1 "Expected exit 0 after cooldown, got: $rc"
	fi
	teardown
	return 0
}

test_configurable_threshold() {
	setup
	export SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD=5
	# Record 4 failures — should NOT trip (threshold=5)
	"$HELPER" record-failure "t001" "f1" 2>/dev/null || true
	"$HELPER" record-failure "t002" "f2" 2>/dev/null || true
	"$HELPER" record-failure "t003" "f3" 2>/dev/null || true
	"$HELPER" record-failure "t004" "f4" 2>/dev/null || true
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "configurable threshold (4/5 does not trip)" 0
	else
		print_result "configurable threshold (4/5 does not trip)" 1 "Expected exit 0, got: $rc"
	fi
	# 5th failure should trip
	"$HELPER" record-failure "t005" "f5" 2>/dev/null || true
	rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "configurable threshold (5/5 trips)" 0
	else
		print_result "configurable threshold (5/5 trips)" 1 "Expected exit 1, got: $rc"
	fi
	teardown
	return 0
}

test_status_shows_failure_details() {
	setup
	"$HELPER" record-failure "t042" "API rate limit exceeded" 2>/dev/null || true
	local output
	output=$("$HELPER" status 2>/dev/null) || true
	local pass=true
	if ! echo "$output" | grep -q "t042"; then
		pass=false
	fi
	if ! echo "$output" | grep -q "1 / 3"; then
		pass=false
	fi
	if [[ "$pass" == "true" ]]; then
		print_result "status shows failure details" 0
	else
		print_result "status shows failure details" 1 "Output: $output"
	fi
	teardown
	return 0
}

test_state_file_created() {
	setup
	"$HELPER" record-failure "t001" "test" 2>/dev/null || true
	local state_file="$TEST_DIR/circuit-breaker.state"
	if [[ -f "$state_file" ]]; then
		# Verify it's valid JSON
		if jq empty "$state_file" 2>/dev/null; then
			print_result "state file is valid JSON" 0
		else
			print_result "state file is valid JSON" 1 "Invalid JSON in $state_file"
		fi
	else
		print_result "state file is valid JSON" 1 "State file not created"
	fi
	teardown
	return 0
}

test_unknown_command_fails() {
	local rc=0
	"$HELPER" nonexistent-command 2>/dev/null || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		print_result "unknown command returns non-zero" 0
	else
		print_result "unknown command returns non-zero" 1 "Expected non-zero exit"
	fi
	return 0
}

test_idempotent_success_on_clean_state() {
	setup
	# record-success on clean state should be a no-op (no state file yet)
	"$HELPER" record-success 2>/dev/null || true
	local rc=0
	"$HELPER" check 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "record-success on clean state is safe" 0
	else
		print_result "record-success on clean state is safe" 1 "Exit code: $rc"
	fi
	teardown
	return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
	echo "=== Circuit Breaker Helper Tests (t1331) ==="
	echo ""

	# Prerequisite check
	if ! command -v jq &>/dev/null; then
		echo -e "${RED}SKIP${RESET} jq not found — required for circuit breaker"
		exit 1
	fi

	test_helper_exists
	test_help_command
	test_initial_state_closed
	test_initial_status_shows_closed
	test_single_failure_does_not_trip
	test_two_failures_does_not_trip
	test_three_failures_trips_breaker
	test_status_shows_open_after_trip
	test_success_resets_counter
	test_success_resets_tripped_breaker
	test_manual_reset
	test_manual_trip
	test_auto_reset_after_cooldown
	test_configurable_threshold
	test_status_shows_failure_details
	test_state_file_created
	test_unknown_command_fails
	test_idempotent_success_on_clean_state

	echo ""
	echo "=== Results ==="
	echo "Total:  $TESTS_RUN"
	echo -e "Passed: ${GREEN}$TESTS_PASSED${RESET}"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		echo -e "Failed: ${RED}$TESTS_FAILED${RESET}"
		return 1
	else
		echo -e "Failed: $TESTS_FAILED"
		echo -e "${GREEN}All tests passed!${RESET}"
		return 0
	fi
}

main "$@"
