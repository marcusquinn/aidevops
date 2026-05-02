#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-resource-metrics-helper.sh - resource metrics sampler coverage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../resource-metrics-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

test_sampler_writes_expected_schema() {
	local out_file="${TEST_ROOT}/resource-metrics.jsonl"
	local stop_file="${TEST_ROOT}/stop"
	"$HELPER_SCRIPT" sample \
		--pid "$$" \
		--role worker \
		--session-key gh-22286 \
		--repo marcusquinn/aidevops \
		--issue 22286 \
		--result success \
		--out "$out_file" \
		--stop-file "$stop_file" \
		--interval 1 &
	local sampler_pid="$!"
	sleep 2
	printf 'done\n' >"$stop_file"
	wait "$sampler_pid"

	if jq -e 'select(.pid and .ppid and .role == "worker" and .session_key == "gh-22286" and .repo == "marcusquinn/aidevops" and .issue == "22286" and (.cpu_seconds | type == "number") and (.rss_kb | type == "number") and (.peak_rss_kb | type == "number") and (.elapsed_s | type == "number") and .timestamp)' "$out_file" >/dev/null; then
		print_result "sampler writes resource metric schema" 0
		return 0
	fi
	print_result "sampler writes resource metric schema" 1 "Unexpected JSONL: $(<"$out_file")"
	return 0
}

test_default_interval_documents_bounded_overhead() {
	if grep -q 'default 30s interval keeps' "$HELPER_SCRIPT" && grep -q '<1% CPU target' "$HELPER_SCRIPT"; then
		print_result "documents bounded sampler overhead" 0
		return 0
	fi
	print_result "documents bounded sampler overhead" 1 "Missing overhead target comment"
	return 0
}

main() {
	setup_test_env
	test_sampler_writes_expected_schema
	test_default_interval_documents_bounded_overhead
	teardown_test_env

	printf '\nTests run: %d\n' "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf 'Tests failed: %d\n' "$TESTS_FAILED"
		return 1
	fi
	printf 'All tests passed\n'
	return 0
}

main "$@"
