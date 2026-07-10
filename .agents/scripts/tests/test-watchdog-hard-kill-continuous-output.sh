#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-watchdog-hard-kill-continuous-output.sh — GH#26469 regression test.
#
# Verifies HARD_KILL_SECONDS applies only to confirmed stalls. Continuous output
# remains alive past the threshold, then the same worker is killed after output
# stops and STALL_TIMEOUT is reached.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCHDOG_SCRIPT="${SCRIPT_DIR}/worker-activity-watchdog.sh"
TEST_ROOT=""
WORKER_PID=""
WRITER_PID=""
WATCHDOG_PID=""

cleanup() {
	if [[ -n "$WORKER_PID" ]]; then
		kill "$WORKER_PID" >/dev/null 2>&1 || true
		kill -9 "$WORKER_PID" >/dev/null 2>&1 || true
	fi
	if [[ -n "$WRITER_PID" ]]; then
		kill "$WRITER_PID" >/dev/null 2>&1 || true
		wait "$WRITER_PID" 2>/dev/null || true
	fi
	if [[ -n "$WATCHDOG_PID" ]]; then
		kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
		wait "$WATCHDOG_PID" 2>/dev/null || true
	fi
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

assert_file_exists() {
	local path="$1"
	local label="$2"
	if [[ -e "$path" ]]; then
		return 0
	fi
	fail "missing ${label}: ${path}"
	return 1
}

assert_file_contains() {
	local path="$1"
	local needle="$2"
	local label="$3"
	if grep -qF -- "$needle" "$path" 2>/dev/null; then
		return 0
	fi
	fail "${label} did not contain ${needle}"
	return 1
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT

	local output_file="${TEST_ROOT}/worker.out"
	local exit_code_file="${TEST_ROOT}/worker.exit"
	local lifecycle_log="${TEST_ROOT}/lifecycle.log"

	: >"$output_file"
	(trap 'exit 0' TERM; while true; do sleep 1; done) 2>/dev/null &
	WORKER_PID=$!
	(while true; do printf 'tick %s\n' "$(date +%s%N)" >>"$output_file"; sleep 0.2; done) 2>/dev/null &
	WRITER_PID=$!

	WORKER_LIFECYCLE_LOG="$lifecycle_log" "$WATCHDOG_SCRIPT" \
		--output-file "$output_file" \
		--worker-pid "$WORKER_PID" \
		--exit-code-file "$exit_code_file" \
		--phase1-timeout 1 \
		--poll-interval 1 \
		--stall-timeout 2 \
		--hard-kill-seconds 2 &
	WATCHDOG_PID=$!

	# The wall-clock threshold alone must not kill an output-active worker.
	sleep 3
	if [[ -e "${exit_code_file}.watchdog_killed" ]] || ! kill -0 "$WORKER_PID" 2>/dev/null; then
		fail "output-active worker was killed at the wall-clock threshold"
	fi

	# Stop output while leaving the worker alive. The confirmed stall is already
	# beyond the threshold, so it should now take the hard-kill path.
	kill "$WRITER_PID" >/dev/null 2>&1 || true
	wait "$WRITER_PID" 2>/dev/null || true
	WRITER_PID=""
	wait "$WATCHDOG_PID"
	WATCHDOG_PID=""

	assert_file_exists "${exit_code_file}.watchdog_killed" "watchdog kill sentinel"
	assert_file_exists "${exit_code_file}.watchdog_stall_killed" "hard-kill sentinel"
	assert_file_contains "$exit_code_file" "124" "exit code file"
	assert_file_contains "$output_file" "[WATCHDOG_KILL]" "worker output"
	assert_file_contains "$output_file" "hard_kill:" "worker output kill reason"
	assert_file_contains "$lifecycle_log" "reason=hard_kill_stall" "lifecycle log"

	printf 'PASS: hard-kill cap applies only after confirmed output stall\n'
	return 0
}

main "$@"
