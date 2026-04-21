#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-rate-limit-circuit-breaker.sh — t2690 / GH#20310 regression guard.
#
# Asserts the pulse-level GraphQL rate-limit circuit breaker:
#   1. Trips when remaining <= threshold (e.g. 4/5000 at 5% threshold)
#   2. Does NOT trip when remaining > threshold (e.g. 1000/5000)
#   3. Fails open on API error (gh api rate_limit unreachable)
#   4. Emergency bypass via AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1
#   5. Disabled when threshold=0
#   6. Status output includes correct state
#   7. Custom threshold works (e.g. 10% = 500/5000)
#   8. Stats counter increments on trip
#
# Stub strategy: define `gh` as a shell function. Shell functions take
# precedence over PATH binaries, so the stub captures all `gh` invocations
# without PATH mutation. STUB_GH_REMAINING controls the remaining value;
# STUB_GH_FAIL=1 simulates API failure.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2690.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export LOGFILE="${TMP}/test-pulse.log"
export HOME="${TMP}/home"
mkdir -p "${HOME}/.aidevops/logs"

# Stub pulse-stats-helper.sh — track counter increments.
STATS_COUNTER_FILE="${TMP}/stats-counter.log"
pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}
pulse_stats_get_24h() {
	local counter_name="$1"
	if [[ -f "$STATS_COUNTER_FILE" ]]; then
		grep -c "^${counter_name}$" "$STATS_COUNTER_FILE" 2>/dev/null || printf '0\n'
	else
		printf '0\n'
	fi
	return 0
}
export -f pulse_stats_increment pulse_stats_get_24h

# Configurable stub behaviour per test via env vars:
#   STUB_GH_REMAINING — GraphQL remaining value (default 5000)
#   STUB_GH_LIMIT     — GraphQL limit value (default 5000)
#   STUB_GH_RESET     — GraphQL reset epoch (default: now+3600)
#   STUB_GH_FAIL      — 1 to make gh api rate_limit fail entirely
gh() {
	if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
		if [[ "${STUB_GH_FAIL:-0}" == "1" ]]; then
			return 1
		fi
		local remaining="${STUB_GH_REMAINING:-5000}"
		local limit="${STUB_GH_LIMIT:-5000}"
		local reset="${STUB_GH_RESET:-$(($(date +%s) + 3600))}"
		# Handle --jq flag for direct extraction
		if [[ "${3:-}" == "--jq" ]]; then
			local jq_expr="${4:-}"
			if [[ "$jq_expr" == ".resources.graphql.remaining" ]]; then
				printf '%s\n' "$remaining"
				return 0
			fi
		fi
		# Full JSON response
		printf '{"resources":{"graphql":{"remaining":%s,"limit":%s,"reset":%s}}}\n' \
			"$remaining" "$limit" "$reset"
		return 0
	fi
	# Default: succeed silently for unknown calls
	return 0
}
export -f gh

# Source the circuit breaker helper.
# shellcheck source=../pulse-rate-limit-circuit-breaker.sh
source "${SCRIPTS_DIR}/pulse-rate-limit-circuit-breaker.sh"

# Re-override pulse_stats_* AFTER sourcing — the circuit breaker sources
# the real pulse-stats-helper.sh which replaces our capturing stubs.
# shellcheck disable=SC2317
pulse_stats_increment() {
	local counter_name="$1"
	printf '%s\n' "$counter_name" >>"$STATS_COUNTER_FILE"
	return 0
}
# shellcheck disable=SC2317
pulse_stats_get_24h() {
	local counter_name="$1"
	if [[ -f "$STATS_COUNTER_FILE" ]]; then
		grep -c "^${counter_name}$" "$STATS_COUNTER_FILE" 2>/dev/null || printf '0\n'
	else
		printf '0\n'
	fi
	return 0
}

# =============================================================================
# Reset test state between tests
# =============================================================================
reset_test_state() {
	: >"$LOGFILE"
	: >"$STATS_COUNTER_FILE"
	rm -f "${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state"
	unset AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER 2>/dev/null || true
	unset STUB_GH_FAIL 2>/dev/null || true
	STUB_GH_REMAINING=5000
	STUB_GH_LIMIT=5000
	export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD="0.05"
	return 0
}

# =============================================================================
# Test cases
# =============================================================================
printf 'test-rate-limit-circuit-breaker.sh (t2690)\n'
printf '============================================\n'

# --- Test 1: Breaker trips at 4/5000 (below 5% = 250 threshold) ---
test_breaker_trips_below_threshold() {
	reset_test_state
	STUB_GH_REMAINING=4
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "breaker trips when remaining=4 (below threshold=250)"
	else
		fail "breaker should trip when remaining=4 (rc=$rc, expected 1)"
	fi
	return 0
}

# --- Test 2: Breaker trips at exactly threshold (250/5000) ---
test_breaker_trips_at_threshold() {
	reset_test_state
	STUB_GH_REMAINING=250
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "breaker trips when remaining=250 (at threshold=250)"
	else
		fail "breaker should trip when remaining=250 (rc=$rc, expected 1)"
	fi
	return 0
}

# --- Test 3: Breaker does NOT trip at 1000/5000 ---
test_breaker_passes_above_threshold() {
	reset_test_state
	STUB_GH_REMAINING=1000
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "breaker passes when remaining=1000 (above threshold=250)"
	else
		fail "breaker should pass when remaining=1000 (rc=$rc, expected 0)"
	fi
	return 0
}

# --- Test 4: Breaker does NOT trip at 251/5000 (one above threshold) ---
test_breaker_passes_just_above_threshold() {
	reset_test_state
	STUB_GH_REMAINING=251
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "breaker passes when remaining=251 (just above threshold=250)"
	else
		fail "breaker should pass when remaining=251 (rc=$rc, expected 0)"
	fi
	return 0
}

# --- Test 5: Fail-open on API error ---
test_fail_open_on_api_error() {
	reset_test_state
	STUB_GH_FAIL=1
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		pass "fails open on API error (rc=2)"
	else
		fail "should fail open on API error (rc=$rc, expected 2)"
	fi
	return 0
}

# --- Test 6: Emergency bypass ---
test_emergency_bypass() {
	reset_test_state
	STUB_GH_REMAINING=0
	export AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "emergency bypass allows dispatch when remaining=0"
	else
		fail "emergency bypass should allow dispatch (rc=$rc, expected 0)"
	fi
	return 0
}

# --- Test 7: Disabled when threshold=0 ---
test_disabled_at_zero_threshold() {
	reset_test_state
	STUB_GH_REMAINING=0
	export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD="0"
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "disabled when threshold=0 (remaining=0 still passes)"
	else
		fail "should be disabled when threshold=0 (rc=$rc, expected 0)"
	fi
	return 0
}

# --- Test 8: Custom threshold 10% = 500/5000 ---
test_custom_threshold_10_percent() {
	reset_test_state
	export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD="0.10"
	STUB_GH_REMAINING=499
	local rc=0
	is_graphql_budget_sufficient || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		pass "trips at custom threshold 10% when remaining=499 (threshold=500)"
	else
		fail "should trip at 10% threshold when remaining=499 (rc=$rc, expected 1)"
	fi
	return 0
}

# --- Test 9: Stats counter increments on trip ---
test_stats_counter_increments() {
	reset_test_state
	STUB_GH_REMAINING=4
	is_graphql_budget_sufficient || true
	local count
	count=$(grep -c "^pulse_dispatch_circuit_broken$" "$STATS_COUNTER_FILE" 2>/dev/null) || count=0
	if [[ "$count" -eq 1 ]]; then
		pass "pulse_dispatch_circuit_broken counter incremented on trip"
	else
		fail "counter should increment once (got $count)"
	fi
	return 0
}

# --- Test 10: Stats counter does NOT increment when passing ---
test_stats_counter_no_increment_on_pass() {
	reset_test_state
	STUB_GH_REMAINING=1000
	is_graphql_budget_sufficient || true
	local count
	count=$(grep -c "^pulse_dispatch_circuit_broken$" "$STATS_COUNTER_FILE" 2>/dev/null) || count=0
	if [[ "$count" -eq 0 ]]; then
		pass "counter not incremented when budget is sufficient"
	else
		fail "counter should not increment on pass (got $count)"
	fi
	return 0
}

# --- Test 11: State file created on trip, cleared on recovery ---
test_state_file_lifecycle() {
	reset_test_state
	local state_file="${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state"

	# Trip the breaker.
	STUB_GH_REMAINING=4
	is_graphql_budget_sufficient || true
	if [[ -f "$state_file" ]]; then
		pass "state file created on trip"
	else
		fail "state file should be created on trip"
		return 0
	fi

	# Recover.
	STUB_GH_REMAINING=1000
	is_graphql_budget_sufficient || true
	if [[ ! -f "$state_file" ]]; then
		pass "state file cleared on recovery"
	else
		fail "state file should be cleared on recovery"
	fi
	return 0
}

# --- Test 12: Status output when OK ---
test_status_output_ok() {
	reset_test_state
	STUB_GH_REMAINING=4500
	local output
	output=$(_circuit_breaker_status 2>/dev/null)
	if printf '%s' "$output" | grep -q "^OK:"; then
		pass "status output shows OK when budget sufficient"
	else
		fail "status should show OK (got: $output)"
	fi
	return 0
}

# --- Test 13: Status output when TRIPPED ---
test_status_output_tripped() {
	reset_test_state
	STUB_GH_REMAINING=4
	# Trip the breaker first to create the state file.
	is_graphql_budget_sufficient || true
	local output
	output=$(_circuit_breaker_status 2>/dev/null)
	if printf '%s' "$output" | grep -q "^TRIPPED:"; then
		pass "status output shows TRIPPED when budget exhausted"
	else
		fail "status should show TRIPPED (got: $output)"
	fi
	return 0
}

# --- Test 14: Log message on trip ---
test_log_message_on_trip() {
	reset_test_state
	STUB_GH_REMAINING=4
	is_graphql_budget_sufficient || true
	if grep -q "GraphQL budget EXHAUSTED" "$LOGFILE" 2>/dev/null; then
		pass "log message emitted on trip"
	else
		fail "should emit 'GraphQL budget EXHAUSTED' log message on trip"
	fi
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================
test_breaker_trips_below_threshold
test_breaker_trips_at_threshold
test_breaker_passes_above_threshold
test_breaker_passes_just_above_threshold
test_fail_open_on_api_error
test_emergency_bypass
test_disabled_at_zero_threshold
test_custom_threshold_10_percent
test_stats_counter_increments
test_stats_counter_no_increment_on_pass
test_state_file_lifecycle
test_status_output_ok
test_status_output_tripped
test_log_message_on_trip

# =============================================================================
# Summary
# =============================================================================
printf '\n%s/%s tests passed' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf ' (%s%s FAILED%s)\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_NC"
	exit 1
else
	printf ' %s(all passed)%s\n' "$TEST_GREEN" "$TEST_NC"
	exit 0
fi
