#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../sandbox-exec-helper.sh"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$GREEN" "$RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$RED" "$RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d)"
	export HOME="${TEST_ROOT}/home"
	mkdir -p "$HOME"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

test_blocks_risky_env_print_command() {
	local output
	local exit_code

	set +e
	output="$($HELPER run "echo \$SHOPIFY_CLIENT_SECRET" 2>&1)"
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 126 ]] && [[ "$output" == *"Blocked command due to secret leak risk"* ]]; then
		print_result "blocks risky env var print command" 0
	else
		print_result "blocks risky env var print command" 1 "exit=$exit_code output=$output"
	fi
	return 0
}

test_allows_safe_command() {
	local output
	local exit_code

	set +e
	output="$($HELPER run "printf safe" 2>&1)"
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]] && [[ "$output" == *"safe"* ]]; then
		print_result "allows safe command" 0
	else
		print_result "allows safe command" 1 "exit=$exit_code output=$output"
	fi
	return 0
}

test_override_flag_allows_blocked_pattern() {
	local output
	local exit_code

	set +e
	output="$($HELPER run --allow-secret-io "echo \$SHOPIFY_CLIENT_SECRET" 2>&1)"
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]]; then
		print_result "allow-secret-io bypass works" 0
	else
		print_result "allow-secret-io bypass works" 1 "exit=$exit_code output=$output"
	fi
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT

	test_blocks_risky_env_print_command
	test_allows_safe_command
	test_override_flag_allows_blocked_pattern

	echo ""
	printf 'Tests run: %d\n' "$TESTS_RUN"
	printf 'Failures:  %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi

	return 0
}

main "$@"
