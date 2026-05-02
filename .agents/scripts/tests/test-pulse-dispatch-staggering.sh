#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-dispatch-staggering.sh — t3482 adaptive launch staggering tests.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/headless-runtime"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export STOP_FLAG="${HOME}/.aidevops/logs/stop"
: >"$LOGFILE"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"

reset_stagger_env() {
	export PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING=5000
	export PULSE_DISPATCH_STAGGER_RECENT_FAILURES=0
	export PULSE_DISPATCH_STAGGER_RECENT_RATE_LIMITS=0
	export PULSE_DISPATCH_STAGGER_LOAD_PER_CPU=0.5
	export PULSE_DISPATCH_PROVIDER_BACKOFF_ACTIVE=0
	export PULSE_DISPATCH_STAGGER_JITTER_MAX_SECONDS=0
	export PULSE_DISPATCH_STAGGER_MAX_SECONDS=20
	return 0
}

delay_for_candidate() {
	local issue_number="$1"
	_dispatch_inter_launch_delay 1 2 "{\"number\":${issue_number}}" 8
	return 0
}

test_low_load_no_delay() {
	reset_stagger_env
	local delay
	delay=$(delay_for_candidate 100)
	if [[ "$delay" == "0" ]]; then
		print_result "staggering: low-load clean cycle has no delay" 0
	else
		print_result "staggering: low-load clean cycle has no delay" 1 "delay=${delay}"
	fi
	return 0
}

test_high_load_delay() {
	reset_stagger_env
	export PULSE_DISPATCH_STAGGER_LOAD_PER_CPU=9.0
	local delay
	delay=$(delay_for_candidate 101)
	if [[ "$delay" -gt 0 ]]; then
		print_result "staggering: high load increases delay" 0
	else
		print_result "staggering: high load increases delay" 1 "delay=${delay}"
	fi
	return 0
}

test_provider_backoff_delay() {
	reset_stagger_env
	export PULSE_DISPATCH_PROVIDER_BACKOFF_ACTIVE=1
	local delay
	delay=$(delay_for_candidate 102)
	if [[ "$delay" -gt 0 ]]; then
		print_result "staggering: provider backoff increases delay" 0
	else
		print_result "staggering: provider backoff increases delay" 1 "delay=${delay}"
	fi
	return 0
}

test_recent_failure_cluster_delay() {
	reset_stagger_env
	export PULSE_DISPATCH_STAGGER_RECENT_FAILURES=3
	local delay
	delay=$(delay_for_candidate 103)
	if [[ "$delay" -gt 0 ]]; then
		print_result "staggering: recent failure cluster increases delay" 0
	else
		print_result "staggering: recent failure cluster increases delay" 1 "delay=${delay}"
	fi
	return 0
}

test_graphql_low_budget_delay() {
	reset_stagger_env
	export PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING=900
	local delay
	delay=$(delay_for_candidate 104)
	if [[ "$delay" -gt 0 ]]; then
		print_result "staggering: low GraphQL budget increases delay" 0
	else
		print_result "staggering: low GraphQL budget increases delay" 1 "delay=${delay}"
	fi
	return 0
}

test_first_launch_never_delayed() {
	reset_stagger_env
	export PULSE_DISPATCH_STAGGER_LOAD_PER_CPU=99
	local delay
	delay=$(_dispatch_inter_launch_delay 0 1 '{"number":105}' 8)
	if [[ "$delay" == "0" ]]; then
		print_result "staggering: first launch remains immediate" 0
	else
		print_result "staggering: first launch remains immediate" 1 "delay=${delay}"
	fi
	return 0
}

test_low_load_no_delay
test_high_load_delay
test_provider_backoff_delay
test_recent_failure_cluster_delay
test_graphql_low_budget_delay
test_first_launch_never_delayed

echo ""
echo "===================="
echo "Tests run: $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"
echo "===================="
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
else
	exit 1
fi
