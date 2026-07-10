#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2016
# test-lint-resource-benchmark.sh — bounded lint profiler regression coverage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../lint-resource-benchmark.sh"

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
	[[ -n "$message" ]] && printf '       %s\n' "$message"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/home"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

run_helper() {
	HOME="${TEST_ROOT}/home" \
		AIDEVOPS_TEST_MODE=1 \
		AIDEVOPS_LINT_BENCHMARK_LOCK_DIR="${TEST_ROOT}/lint-resource-benchmark.lock" \
		"$HELPER_SCRIPT" "$@"
	return $?
}

test_success_schema_and_redaction() {
	local manifest="${TEST_ROOT}/private-manifest.txt"
	local out_file="${TEST_ROOT}/success.jsonl"
	printf '%s\n' '/private/repository/file-b.ts' '/private/repository/file-a.ts' >"$manifest"
	local output=""
	output=$(run_helper run --profile changed-safe --timeout 8 --interval 1 \
		--cache-state cold --coverage-manifest "$manifest" --out "$out_file" -- \
		bash -c 'sleep 2' sensitive-command-marker)

	if ! jq -e 'select(.profile == "changed-safe" and .cache_state == "cold" and .result == "success" and .exit_code == 0 and (.coverage_digest | length == 64) and .peak_process_count >= 1 and .sample_count >= 1)' "$out_file" >/dev/null; then
		print_result "success report has aggregate schema" 1 "Unexpected report: $output"
		return 0
	fi
	if grep -qE 'private/repository|sensitive-command-marker' "$out_file"; then
		print_result "report redacts command and manifest paths" 1 "Sensitive marker found in report"
		return 0
	fi
	print_result "success report has aggregate schema" 0
	print_result "report redacts command and manifest paths" 0
	return 0
}

test_timeout_cleans_descendants() {
	local child_pid_file="${TEST_ROOT}/timeout-child.pid"
	local out_file="${TEST_ROOT}/timeout.jsonl"
	local exit_code=0
	set +e
	run_helper run --profile timeout-cleanup --timeout 2 --interval 1 --out "$out_file" -- \
		bash -c 'sleep 30 & child=$!; printf "%s\n" "$child" >"$1"; wait "$child"' _ "$child_pid_file" >/dev/null
	exit_code=$?
	set -e
	local child_pid=""
	[[ -f "$child_pid_file" ]] && child_pid=$(<"$child_pid_file")
	if [[ "$exit_code" -ne 124 ]]; then
		print_result "timeout returns 124" 1 "exit=${exit_code}"
		return 0
	fi
	if [[ "$child_pid" =~ ^[0-9]+$ ]] && kill -0 "$child_pid" 2>/dev/null; then
		print_result "timeout leaves no descendant" 1 "child PID still alive"
		kill -KILL "$child_pid" 2>/dev/null || true
		return 0
	fi
	print_result "timeout returns 124" 0
	print_result "timeout leaves no descendant" 0
	return 0
}

test_safety_stop_cleans_descendants() {
	local trigger_file="${TEST_ROOT}/safety.trigger"
	local child_pid_file="${TEST_ROOT}/safety-child.pid"
	local out_file="${TEST_ROOT}/safety.jsonl"
	(
		sleep 1
		printf '%s\n' 'memory_pressure' >"$trigger_file"
	) &
	local trigger_pid="$!"
	local exit_code=0
	set +e
	HOME="${TEST_ROOT}/home" AIDEVOPS_TEST_MODE=1 \
		LINT_RESOURCE_TEST_SAFETY_FILE="$trigger_file" \
		AIDEVOPS_LINT_BENCHMARK_LOCK_DIR="${TEST_ROOT}/lint-resource-benchmark.lock" \
		"$HELPER_SCRIPT" run --profile safety-cleanup --timeout 10 --interval 1 --out "$out_file" -- \
		bash -c 'sleep 30 & child=$!; printf "%s\n" "$child" >"$1"; wait "$child"' _ "$child_pid_file" >/dev/null
	exit_code=$?
	set -e
	wait "$trigger_pid" 2>/dev/null || true
	local child_pid=""
	[[ -f "$child_pid_file" ]] && child_pid=$(<"$child_pid_file")
	if [[ "$exit_code" -ne 75 ]] || ! jq -e '.result == "safety_stop" and .stop_reason == "memory_pressure"' "$out_file" >/dev/null; then
		print_result "safety trigger returns redacted stop" 1 "exit=${exit_code}"
		return 0
	fi
	if [[ "$child_pid" =~ ^[0-9]+$ ]] && kill -0 "$child_pid" 2>/dev/null; then
		print_result "safety stop leaves no descendant" 1 "child PID still alive"
		kill -KILL "$child_pid" 2>/dev/null || true
		return 0
	fi
	print_result "safety trigger returns redacted stop" 0
	print_result "safety stop leaves no descendant" 0
	return 0
}

test_concurrent_run_is_rejected() {
	local first_out="${TEST_ROOT}/first.jsonl"
	local second_out="${TEST_ROOT}/second.jsonl"
	local marker="${TEST_ROOT}/second-ran"
	run_helper run --profile first --timeout 8 --interval 1 --out "$first_out" -- bash -c 'sleep 3' >/dev/null &
	local first_pid="$!"
	local attempts=0
	while [[ ! -d "${TEST_ROOT}/lint-resource-benchmark.lock" && "$attempts" -lt 20 ]]; do
		sleep 0.1
		attempts=$((attempts + 1))
	done
	local exit_code=0
	set +e
	run_helper run --profile second --timeout 8 --interval 1 --out "$second_out" -- \
		bash -c 'printf ran >"$1"' _ "$marker" >/dev/null 2>&1
	exit_code=$?
	set -e
	wait "$first_pid"
	if [[ "$exit_code" -eq 73 && ! -e "$marker" ]]; then
		print_result "concurrent benchmark is rejected" 0
		return 0
	fi
	print_result "concurrent benchmark is rejected" 1 "exit=${exit_code}, marker=$([[ -e "$marker" ]] && printf yes || printf no)"
	return 0
}

test_lock_initialization_race_is_rejected() {
	local lock_dir="${TEST_ROOT}/lint-resource-benchmark.lock"
	local out_file="${TEST_ROOT}/lock-race.jsonl"
	local marker="${TEST_ROOT}/lock-race-ran"
	mkdir "$lock_dir"
	(
		sleep 0.2
		printf '%s\n' "$$" >"${lock_dir}/pid"
	) &
	local owner_writer_pid="$!"
	local exit_code=0
	set +e
	run_helper run --profile lock-race --timeout 5 --out "$out_file" -- \
		bash -c 'printf ran >"$1"' _ "$marker" >/dev/null 2>&1
	exit_code=$?
	set -e
	wait "$owner_writer_pid"
	rm -f "${lock_dir}/pid"
	rmdir "$lock_dir"
	if [[ "$exit_code" -eq 73 && ! -e "$marker" ]]; then
		print_result "initializing lock remains exclusive" 0
		return 0
	fi
	print_result "initializing lock remains exclusive" 1 "exit=${exit_code}"
	return 0
}

test_missing_option_values_fail_cleanly() {
	local option=""
	local output=""
	local exit_code=0
	for option in --profile --timeout --interval --cache-state --coverage-manifest --out --memory-free-floor --swap-growth-limit; do
		set +e
		output=$(run_helper run "$option" 2>&1)
		exit_code=$?
		set -e
		if [[ "$exit_code" -ne 1 || "$output" != *"requires an argument"* ]]; then
			print_result "missing benchmark option values fail cleanly" 1 "option=${option}, exit=${exit_code}"
			return 0
		fi
	done
	print_result "missing benchmark option values fail cleanly" 0
	return 0
}

test_snapshot_cleanup_state_is_cleared() {
	local out_file="${TEST_ROOT}/snapshot-state.jsonl"
	local exit_code=0
	set +e
	HOME="${TEST_ROOT}/home" AIDEVOPS_TEST_MODE=1 \
		AIDEVOPS_LINT_BENCHMARK_LOCK_DIR="${TEST_ROOT}/lint-resource-benchmark.lock" \
		bash -c 'source "$1"; run_benchmark --profile state-clear --timeout 5 --out "$2" -- bash -c "sleep 1" >/dev/null; [[ -z "$_LINT_BENCHMARK_PROCESS_SNAPSHOT_FILE" ]]' \
		_ "$HELPER_SCRIPT" "$out_file"
	exit_code=$?
	set -e
	if [[ "$exit_code" -eq 0 ]]; then
		print_result "snapshot cleanup state is single-use" 0
		return 0
	fi
	print_result "snapshot cleanup state is single-use" 1 "exit=${exit_code}"
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_success_schema_and_redaction
	test_timeout_cleans_descendants
	test_safety_stop_cleans_descendants
	test_concurrent_run_is_rejected
	test_lock_initialization_race_is_rejected
	test_missing_option_values_fail_cleanly
	test_snapshot_cleanup_state_is_cleared

	printf '\nTests run: %d\n' "$TESTS_RUN"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf 'Tests failed: %d\n' "$TESTS_FAILED"
		return 1
	fi
	printf 'All tests passed\n'
	return 0
}

main "$@"
