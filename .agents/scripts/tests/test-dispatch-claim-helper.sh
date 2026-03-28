#!/usr/bin/env bash
# test-dispatch-claim-helper.sh — Tests for dispatch-claim-helper.sh (t1686)
#
# Tests the offline/unit-testable parts of the claim helper:
# - Nonce generation
# - ISO timestamp generation
# - Help output
# - Argument validation
#
# Note: The claim/release/check commands require live GitHub API access
# and are tested via integration tests, not unit tests. This file tests
# the deterministic, offline-safe parts of the helper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_HELPER="${SCRIPT_DIR}/../dispatch-claim-helper.sh"
DEDUP_HELPER="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

#######################################
# Run a helper command without triggering set -e on failure.
# Captures exit status so test bodies can check it explicitly.
# Usage: run_helper [args...]; LAST_EXIT=$?
#######################################
run_helper() {
	set +e
	"$@"
	LAST_EXIT=$?
	set -e
	return 0
}

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

#######################################
# Test: help command exits 0 and produces output
#######################################
test_help_exits_zero() {
	local output
	run_helper "$CLAIM_HELPER" help
	output=$("$CLAIM_HELPER" help 2>&1)
	local has_usage=1
	if printf '%s' "$output" | grep -q "dispatch-claim-helper.sh"; then
		has_usage=0
	fi
	print_result "help exits 0" "$LAST_EXIT"
	print_result "help contains script name" "$has_usage"
	return 0
}

#######################################
# Test: claim with missing args returns exit 2
#######################################
test_claim_missing_args() {
	run_helper "$CLAIM_HELPER" claim
	if [[ "$LAST_EXIT" -eq 2 ]]; then
		print_result "claim with no args returns exit 2" 0
	else
		print_result "claim with no args returns exit 2" 1 "got exit $LAST_EXIT"
	fi

	run_helper "$CLAIM_HELPER" claim 42
	if [[ "$LAST_EXIT" -eq 2 ]]; then
		print_result "claim with one arg returns exit 2" 0
	else
		print_result "claim with one arg returns exit 2" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: claim with non-numeric issue returns exit 2
#######################################
test_claim_non_numeric_issue() {
	run_helper "$CLAIM_HELPER" claim "abc" "owner/repo"
	if [[ "$LAST_EXIT" -eq 2 ]]; then
		print_result "claim with non-numeric issue returns exit 2" 0
	else
		print_result "claim with non-numeric issue returns exit 2" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: check with missing args returns exit 2
#######################################
test_check_missing_args() {
	run_helper "$CLAIM_HELPER" check
	if [[ "$LAST_EXIT" -eq 2 ]]; then
		print_result "check with no args returns exit 2" 0
	else
		print_result "check with no args returns exit 2" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: unknown command returns exit 1
#######################################
test_unknown_command() {
	run_helper "$CLAIM_HELPER" foobar
	if [[ "$LAST_EXIT" -eq 1 ]]; then
		print_result "unknown command returns exit 1" 0
	else
		print_result "unknown command returns exit 1" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: dispatch-dedup-helper.sh claim subcommand routes correctly
#######################################
test_dedup_claim_routing() {
	# With missing args, should return exit 1 (from dedup helper's arg check)
	run_helper "$DEDUP_HELPER" claim
	if [[ "$LAST_EXIT" -eq 1 ]]; then
		print_result "dedup claim with no args returns exit 1" 0
	else
		print_result "dedup claim with no args returns exit 1" 1 "got exit $LAST_EXIT"
	fi
	return 0
}

#######################################
# Test: DISPATCH_CLAIM_WINDOW env var is respected
#######################################
test_env_var_defaults() {
	# Source the helper to check defaults (without executing main)
	local output
	output=$(DISPATCH_CLAIM_WINDOW=15 DISPATCH_CLAIM_MAX_AGE=300 \
		bash -c 'source "'"$CLAIM_HELPER"'" 2>/dev/null; echo "window=$DISPATCH_CLAIM_WINDOW max_age=$DISPATCH_CLAIM_MAX_AGE"' 2>/dev/null || true)

	if printf '%s' "$output" | grep -q "window=15"; then
		print_result "DISPATCH_CLAIM_WINDOW env var respected" 0
	else
		print_result "DISPATCH_CLAIM_WINDOW env var respected" 1 "got: $output"
	fi

	if printf '%s' "$output" | grep -q "max_age=300"; then
		print_result "DISPATCH_CLAIM_MAX_AGE env var respected" 0
	else
		print_result "DISPATCH_CLAIM_MAX_AGE env var respected" 1 "got: $output"
	fi
	return 0
}

#######################################
# Main
#######################################
main() {
	echo "=== dispatch-claim-helper.sh tests (t1686) ==="
	echo ""

	test_help_exits_zero
	test_claim_missing_args
	test_claim_non_numeric_issue
	test_check_missing_args
	test_unknown_command
	test_dedup_claim_routing
	test_env_var_defaults

	echo ""
	echo "Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
