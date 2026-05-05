#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-linters-local-ratchet-timeout.sh — ratchet progress/timeout diagnostics.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
RATCHET_SCRIPT="${SCRIPT_DIR}/../linters-local-ratchet.sh"
RATCHET_SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [ "$passed" -eq 0 ]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [ -n "$message" ]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

source_ratchet_helpers() {
	SCRIPT_DIR="$RATCHET_SCRIPT_DIR"
	# shellcheck disable=SC1090  # test intentionally sources the helper under test
	source "$RATCHET_SCRIPT"
	return 0
}

slow_ratchet_counter() {
	sleep 3
	echo "1"
	return 0
}

fast_ratchet_counter() {
	echo "7"
	return 0
}

test_ratchet_counter_times_out_with_diagnostic() {
	source_ratchet_helpers
	local out ret=0
	RATCHET_STEP_TIMEOUT_SECONDS=1 out=$(_ratchet_count_with_progress "slow_test" "slow_ratchet_counter" "" 2>&1) || ret=$?

	if [ "$ret" -ne 0 ] && printf '%s' "$out" | grep -q 'slow_test timed out after 1s'; then
		print_result "ratchet timeout: counter failure includes pattern name and timeout" 0
	else
		print_result "ratchet timeout: counter failure includes pattern name and timeout" 1 \
			"expected timeout diagnostic, got exit=$ret output=[$out]"
	fi
	return 0
}

test_ratchet_counter_reports_progress_and_value() {
	source_ratchet_helpers
	local out ret=0
	RATCHET_STEP_TIMEOUT_SECONDS=5 out=$(_ratchet_count_with_progress "fast_test" "fast_ratchet_counter" "" 2>&1) || ret=$?

	if [ "$ret" -eq 0 ] && printf '%s' "$out" | grep -q 'Ratchets: counting fast_test' && printf '%s' "$out" | grep -q '7'; then
		print_result "ratchet progress: counter emits start diagnostic and preserves count" 0
	else
		print_result "ratchet progress: counter emits start diagnostic and preserves count" 1 \
			"expected progress diagnostic and count, got exit=$ret output=[$out]"
	fi
	return 0
}

main() {
	test_ratchet_counter_times_out_with_diagnostic
	test_ratchet_counter_reports_progress_and_value

	echo ""
	if [ "$TESTS_FAILED" -eq 0 ]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		return 0
	fi

	printf '%b%d/%d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	return 1
}

main "$@"
