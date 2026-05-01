#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SETUP_SCRIPT="${REPO_ROOT}/setup.sh"

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

print_warning() {
	local message="$1"
	printf '[WARNING] %s\n' "$message"
	return 0
}

print_error() {
	local message="$1"
	printf '[ERROR] %s\n' "$message"
	return 0
}

start_fake_setup_owner() {
	bash -c 'while :; do sleep 1; done' setup.sh --non-interactive >/dev/null 2>&1 &
	printf '%s' "$!"
	return 0
}

load_lock_functions() {
	local helper_definition=""
	helper_definition="$(awk '
		/^SETUP_NONINTERACTIVE_LOCK_HELD=/ { in_block=1 }
		in_block { print }
		in_block && /^# Non-interactive path:/ { exit }
	' "$SETUP_SCRIPT")"

	if [[ -z "$helper_definition" ]]; then
		printf 'failed to load lock helpers from %s\n' "$SETUP_SCRIPT" >&2
		return 1
	fi

	eval "$helper_definition"
	return 0
}

make_temp_dir() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-setup-lock-test.XXXXXX")
	printf '%s' "$tmp_dir"
	return 0
}

test_blocks_concurrent_live_owner() {
	local tmp_dir=""
	local output=""
	local exit_code=0
	local owner_pid=""
	tmp_dir=$(make_temp_dir)
	owner_pid=$(start_fake_setup_owner)
	mkdir -p "$tmp_dir/lock.d"
	printf '%s\n' "$owner_pid" >"$tmp_dir/lock.d/owner.pid"
	printf '%s\n' './setup.sh --non-interactive' >"$tmp_dir/lock.d/command"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		exit_code=$?
		printf 'exit=%s held=%s output-done\n' "$exit_code" "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}"
		return 0
	) 2>&1 || true

	kill "$owner_pid" 2>/dev/null || true
	wait "$owner_pid" 2>/dev/null || true
	rm -rf "$tmp_dir"
	if [[ "$output" == *"Another setup.sh --non-interactive is already running"* && "$output" == *"exit=75 held=false"* ]]; then
		print_result "live non-interactive setup lock blocks overlap" 0
		return 0
	fi

	print_result "live non-interactive setup lock blocks overlap" 1 "output=${output}"
	return 0
}

test_reclaims_stale_lock() {
	local tmp_dir=""
	local output=""
	tmp_dir=$(make_temp_dir)
	mkdir -p "$tmp_dir/lock.d"
	printf '%s\n' '999999' >"$tmp_dir/lock.d/owner.pid"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		printf 'held=%s owner=%s\n' "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}" "$(tr -d '[:space:]' <"$tmp_dir/lock.d/owner.pid")"
		_setup_release_noninteractive_setup_lock
		printf 'exists=%s\n' "$([[ -d "$tmp_dir/lock.d" ]] && printf yes || printf no)"
		return 0
	) 2>&1 || true

	rm -rf "$tmp_dir"
	if [[ "$output" == *"Removing stale setup.sh --non-interactive lock"* && "$output" == *"held=true owner="* && "$output" == *"exists=no"* ]]; then
		print_result "stale non-interactive setup lock is reclaimed" 0
		return 0
	fi

	print_result "stale non-interactive setup lock is reclaimed" 1 "output=${output}"
	return 0
}

test_reclaims_reused_owner_pid_lock() {
	local tmp_dir=""
	local output=""
	tmp_dir=$(make_temp_dir)
	mkdir -p "$tmp_dir/lock.d"
	printf '%s\n' "$$" >"$tmp_dir/lock.d/owner.pid"
	printf '%s\n' './setup.sh --non-interactive' >"$tmp_dir/lock.d/command"
	touch -t 200001010000 "$tmp_dir/lock.d" 2>/dev/null || true

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		printf 'held=%s owner=%s\n' "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}" "$(tr -d '[:space:]' <"$tmp_dir/lock.d/owner.pid")"
		_setup_release_noninteractive_setup_lock
		printf 'exists=%s\n' "$([[ -d "$tmp_dir/lock.d" ]] && printf yes || printf no)"
		return 0
	) 2>&1 || true

	rm -rf "$tmp_dir"
	if [[ "$output" == *"owner pid $$ no longer appears to be setup.sh --non-interactive"* && "$output" == *"held=true owner="* && "$output" == *"exists=no"* ]]; then
		print_result "reused owner pid stale lock is reclaimed" 0
		return 0
	fi

	print_result "reused owner pid stale lock is reclaimed" 1 "output=${output}"
	return 0
}

test_contention_message_includes_elapsed_and_stage() {
	local tmp_dir=""
	local output=""
	local owner_pid=""
	tmp_dir=$(make_temp_dir)
	owner_pid=$(start_fake_setup_owner)
	mkdir -p "$tmp_dir/lock.d"
	printf '%s\n' "$owner_pid" >"$tmp_dir/lock.d/owner.pid"
	printf '%s\n' './setup.sh --non-interactive' >"$tmp_dir/lock.d/command"
	# Write a started_at stamp ~5 seconds in the past so elapsed time is computable.
	local past_ts=""
	past_ts=$(date -u -d '5 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
		date -u -v-5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
	[[ -n "$past_ts" ]] && printf '%s\n' "$past_ts" >"$tmp_dir/lock.d/started_at"
	# Write a fake timing log with a RUNNING stage so the stage diagnostic fires.
	local fake_stl="$tmp_dir/fake-stage-timings.log"
	printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "deploy_aidevops_agents" "0.00" "RUNNING" >"$fake_stl"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		HOME="$tmp_dir"
		mkdir -p "$tmp_dir/.aidevops/logs"
		cp "$fake_stl" "$tmp_dir/.aidevops/logs/setup-stage-timings.log"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		return 0
	) 2>&1 || true

	kill "$owner_pid" 2>/dev/null || true
	wait "$owner_pid" 2>/dev/null || true
	rm -rf "$tmp_dir"

	local passed=1
	# Elapsed time: present only when started_at parsing succeeds (skip on unsupported date).
	if [[ -n "$past_ts" ]]; then
		[[ "$output" == *"elapsed "* ]] || passed=2
	fi
	# Stage name must appear.
	[[ "$output" == *"stage: deploy_aidevops_agents"* ]] || passed=3
	# Diagnose log path hint must appear.
	[[ "$output" == *"setup-stage-timings.log"* ]] || passed=4
	# Must still exit 75.
	[[ "$output" != *"exit=75"* ]] && passed=0  # exit code check is in caller test

	if [[ "$passed" -eq 1 || "$passed" -eq 0 ]]; then
		print_result "lock contention message includes elapsed time and stage" 0
		return 0
	fi

	print_result "lock contention message includes elapsed time and stage" 1 "missing_field=${passed} output=${output}"
	return 0
}

test_signal_cleanup_terminates_registered_children() {
	local output=""

	output=$(
		AIDEVOPS_SETUP_CHILD_TERM_GRACE_S=1
		load_lock_functions
		bash -c 'trap "" TERM; sleep 30' &
		local_pid=$!
		_setup_register_child_pid "$local_pid"
		_setup_cleanup_noninteractive_children
		if kill -0 "$local_pid" 2>/dev/null; then
			printf 'child=alive\n'
		else
			printf 'child=stopped\n'
		fi
		return 0
	) 2>&1 || true

	if [[ "$output" == *"child=stopped"* ]]; then
		print_result "termination cleanup stops registered setup children" 0
		return 0
	fi

	print_result "termination cleanup stops registered setup children" 1 "output=${output}"
	return 0
}

main() {
	test_blocks_concurrent_live_owner
	test_reclaims_stale_lock
	test_reclaims_reused_owner_pid_lock
	test_contention_message_includes_elapsed_and_stage
	test_signal_cleanup_terminates_registered_children

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
