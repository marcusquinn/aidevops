#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-linters-local-cache.sh — cache/time-budget coverage for local linter gates.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

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

source_gate_helpers() {
	# shellcheck disable=SC1091  # test intentionally sources helper under test
	source "${SCRIPT_DIR}/linters-local-gates.sh"
	return 0
}

cache_counter_gate() {
	local counter_file="${LINTERS_LOCAL_TEST_COUNTER_FILE}"
	local count=0
	if [ -f "$counter_file" ]; then
		count=$(cat "$counter_file")
	fi
	count=$((count + 1))
	printf '%s\n' "$count" >"$counter_file"
	printf 'counter gate run %s\n' "$count"
	return 0
}

slow_cache_gate() {
	sleep 3
	printf 'slow gate finished\n'
	return 0
}

test_cache_hit_reuses_gate_output() {
	source_gate_helpers
	local tmp_dir counter_file out1 out2 ret=0
	tmp_dir=$(mktemp -d)
	counter_file="${tmp_dir}/counter"
	export LINTERS_LOCAL_TEST_COUNTER_FILE="$counter_file"
	export LINTERS_LOCAL_CACHE_ENABLED="true"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export TMPDIR="$tmp_dir"

	out1=$(_linters_local_run_cached_gate "unit-cache" "cache_counter_gate" 2>&1) || ret=$?
	out2=$(_linters_local_run_cached_gate "unit-cache" "cache_counter_gate" 2>&1) || ret=$?

	if [ "$ret" -eq 0 ] && grep -q 'cache hit' <<<"$out2" && [ "$(cat "$counter_file")" -eq 1 ]; then
		print_result "linter cache: second unchanged gate call reuses cached result" 0
	else
		print_result "linter cache: second unchanged gate call reuses cached result" 1 \
			"out1=[$out1] out2=[$out2] count=[$(cat "$counter_file" 2>/dev/null || printf '?')] ret=$ret"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_no_cache_reruns_gate() {
	source_gate_helpers
	local tmp_dir counter_file ret=0
	tmp_dir=$(mktemp -d)
	counter_file="${tmp_dir}/counter"
	export LINTERS_LOCAL_TEST_COUNTER_FILE="$counter_file"
	export LINTERS_LOCAL_CACHE_ENABLED="false"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export TMPDIR="$tmp_dir"

	_linters_local_run_cached_gate "unit-nocache" "cache_counter_gate" >/dev/null 2>&1 || ret=$?
	_linters_local_run_cached_gate "unit-nocache" "cache_counter_gate" >/dev/null 2>&1 || ret=$?

	if [ "$ret" -eq 0 ] && [ "$(cat "$counter_file")" -eq 2 ]; then
		print_result "linter cache: --no-cache path reruns eligible broad gates" 0
	else
		print_result "linter cache: --no-cache path reruns eligible broad gates" 1 \
			"count=[$(cat "$counter_file" 2>/dev/null || printf '?')] ret=$ret"
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_timeout_is_advisory_by_default() {
	source_gate_helpers
	local tmp_dir out ret=0
	tmp_dir=$(mktemp -d)
	export LINTERS_LOCAL_CACHE_ENABLED="false"
	export LINTERS_LOCAL_CACHE_DIR_OVERRIDE="${tmp_dir}/cache"
	export LINTERS_LOCAL_BROAD_GATE_TIMEOUT_SECONDS="1"
	export LINTERS_LOCAL_STRICT_BROAD_GATES="false"
	export TMPDIR="$tmp_dir"

	out=$(_linters_local_run_cached_gate "unit-timeout" "slow_cache_gate" 2>&1) || ret=$?

	if [ "$ret" -eq 0 ] && grep -q 'timed out after 1s' <<<"$out"; then
		print_result "linter cache: broad gate timeout is advisory by default" 0
	else
		print_result "linter cache: broad gate timeout is advisory by default" 1 \
			"expected advisory timeout, got exit=$ret output=[$out]"
	fi
	rm -rf "$tmp_dir"
	return 0
}

main() {
	test_cache_hit_reuses_gate_output
	test_no_cache_reruns_gate
	test_timeout_is_advisory_by_default

	printf '\n'
	if [ "$TESTS_FAILED" -eq 0 ]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		return 0
	fi

	printf '%b%d/%d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	return 1
}

main "$@"
