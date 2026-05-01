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
	tmp_dir=$(make_temp_dir)
	mkdir -p "$tmp_dir/lock.d"
	printf '%s\n' "$$" >"$tmp_dir/lock.d/owner.pid"
	printf '%s\n' './setup.sh --non-interactive' >"$tmp_dir/lock.d/command"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		exit_code=$?
		printf 'exit=%s held=%s output-done\n' "$exit_code" "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}"
		return 0
	) 2>&1 || true

	rm -rf "$tmp_dir"
	if [[ "$output" == *"Another setup.sh --non-interactive process is already running"* && "$output" == *"exit=75 held=false"* ]]; then
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

test_signal_cleanup_terminates_registered_children() {
	local output=""

	output=$(
		load_lock_functions
		sleep 30 &
		local_pid=$!
		_setup_register_child_pid "$local_pid"
		SETUP_NONINTERACTIVE_TERMINATING=true
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
	test_signal_cleanup_terminates_registered_children

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
