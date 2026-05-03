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

print_info() {
	local message="$1"
	printf '[INFO] %s\n' "$message"
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
	# Verify that a live non-stale owner causes the caller to wait and then
	# time out with a clear diagnostic, not hang indefinitely.
	# AIDEVOPS_SETUP_WAIT_TIMEOUT_S=5 so the subshell exits within ~15 s.
	local tmp_dir=""
	local output=""
	local owner_pid=""
	local now_epoch=0
	tmp_dir=$(make_temp_dir)
	owner_pid=$(start_fake_setup_owner)
	mkdir -p "$tmp_dir/lock.d"
	printf '%s\n' "$owner_pid" >"$tmp_dir/lock.d/owner.pid"
	now_epoch=$(date +%s 2>/dev/null || echo "0")
	printf '%s\n' "$now_epoch" >"$tmp_dir/lock.d/started_at_epoch"
	printf '%s\n' './setup.sh --non-interactive' >"$tmp_dir/lock.d/command"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		AIDEVOPS_SETUP_WAIT_TIMEOUT_S=5
		AIDEVOPS_SETUP_STALE_TIMEOUT_S=3600
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		printf 'held=%s output-done\n' "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}"
		return 0
	) 2>&1 || true

	kill "$owner_pid" 2>/dev/null || true
	wait "$owner_pid" 2>/dev/null || true
	rm -rf "$tmp_dir"
	# Expect: info "Waiting up to Ns", error "Timed out", held=false
	if [[ "$output" == *"Waiting up to"* && "$output" == *"Timed out"* && "$output" == *"held=false"* ]]; then
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

test_reclaims_stale_started_at_with_reused_setup_pid() {
	local tmp_dir=""
	local output=""
	local owner_pid=""
	tmp_dir=$(make_temp_dir)
	owner_pid=$(start_fake_setup_owner)
	mkdir -p "$tmp_dir/lock.d"
	printf '%s\n' "$owner_pid" >"$tmp_dir/lock.d/owner.pid"
	printf '%s\n' './setup.sh --non-interactive' >"$tmp_dir/lock.d/command"
	printf '%s\n' '2000-01-01T00:00:00Z' >"$tmp_dir/lock.d/started_at"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		printf 'held=%s owner=%s\n' "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}" "$(tr -d '[:space:]' <"$tmp_dir/lock.d/owner.pid")"
		_setup_release_noninteractive_setup_lock
		printf 'exists=%s\n' "$([[ -d "$tmp_dir/lock.d" ]] && printf yes || printf no)"
		return 0
	) 2>&1 || true

	kill "$owner_pid" 2>/dev/null || true
	wait "$owner_pid" 2>/dev/null || true
	rm -rf "$tmp_dir"
	if [[ "$output" == *"lock age "* && "$output" == *"older than owner pid ${owner_pid} runtime"* && "$output" == *"held=true owner="* && "$output" == *"exists=no"* ]]; then
		print_result "stale started_at with reused setup pid is reclaimed" 0
		return 0
	fi

	print_result "stale started_at with reused setup pid is reclaimed" 1 "output=${output}"
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
	local past_epoch=0
	# Write started_at_epoch ~5 seconds in the past so _setup_lock_owner_age
	# returns a non-zero age.
	past_epoch=$(( $(date +%s 2>/dev/null || echo "0") - 5 ))
	printf '%s\n' "$past_epoch" >"$tmp_dir/lock.d/started_at_epoch"
	# Write a fake timing log with a RUNNING stage so stage diagnostic fires.
	local fake_stl="$tmp_dir/fake-stage-timings.log"
	printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "deploy_aidevops_agents" "0.00" "RUNNING" >"$fake_stl"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		AIDEVOPS_SETUP_WAIT_TIMEOUT_S=5
		AIDEVOPS_SETUP_STALE_TIMEOUT_S=3600
		HOME="$tmp_dir"
		mkdir -p "$tmp_dir/.aidevops/logs"
		cp "$fake_stl" "$tmp_dir/.aidevops/logs/setup-stage-timings.log"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		printf 'exit=%s\n' "$?"
		return 0
	) 2>&1 || true

	kill "$owner_pid" 2>/dev/null || true
	wait "$owner_pid" 2>/dev/null || true
	rm -rf "$tmp_dir"

	local passed=1
	# Owner age must appear as "age Ns".
	[[ "$output" == *"age "* ]] || passed=2
	# Stage name must appear.
	[[ "$output" == *"stage: deploy_aidevops_agents"* ]] || passed=3
	# Diagnose log path hint must appear.
	[[ "$output" == *"setup-stage-timings.log"* ]] || passed=4
	# The contention path must preserve the expected timeout exit code.
	[[ "$output" == *"exit=75"* ]] || passed=5

	if [[ "$passed" -eq 1 ]]; then
		print_result "lock contention message includes age and stage" 0
		return 0
	fi

	print_result "lock contention message includes age and stage" 1 "missing_field=${passed} output=${output}"
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

test_signal_cleanup_terminates_unregistered_child_tree() {
	local output=""

	output=$(
		AIDEVOPS_SETUP_CHILD_TERM_GRACE_S=1
		load_lock_functions
		bash -c 'bash -c '\''trap "" TERM; sleep 30'\'' & wait' &
		local_pid=$!
		sleep 1
		_setup_cleanup_noninteractive_children
		if kill -0 "$local_pid" 2>/dev/null; then
			printf 'child=alive\n'
		else
			printf 'child=stopped\n'
		fi
		return 0
	) 2>&1 || true

	if [[ "$output" == *"child=stopped"* ]]; then
		print_result "termination cleanup stops unregistered setup child tree" 0
		return 0
	fi

	print_result "termination cleanup stops unregistered setup child tree" 1 "output=${output}"
	return 0
}

test_bounded_noncritical_stage_times_out_child_tree() {
	local output=""

	output=$(
		AIDEVOPS_SETUP_CHILD_TERM_GRACE_S=1
		load_lock_functions
		slow_stage() {
			bash -c 'trap "" TERM; sleep 30' &
			wait
			return 0
		}
		_setup_run_noncritical_stage_bounded "test stage" 1 slow_stage
		printf 'bounded=returned\n'
		return 0
	) 2>&1 || true

	if [[ "$output" == *"exceeded 1s"* && "$output" == *"bounded=returned"* ]]; then
		print_result "bounded non-critical stage times out child tree" 0
		return 0
	fi

	print_result "bounded non-critical stage times out child tree" 1 "output=${output}"
	return 0
}

test_stale_live_owner_past_ceiling_is_reclaimed() {
	# Verify that a live owner whose age exceeds stale_ceiling is reclaimed
	# and the waiting process acquires the lock successfully.
	local tmp_dir=""
	local output=""
	local owner_pid=""
	local stale_epoch=0
	tmp_dir=$(make_temp_dir)
	owner_pid=$(start_fake_setup_owner)
	mkdir -p "$tmp_dir/lock.d"

	# Use a fake setup owner so kill -0 reports it alive and the command shape
	# matches setup.sh --non-interactive, then set started_at_epoch far in the
	# past to simulate a hung setup.
	printf '%s\n' "$owner_pid" >"$tmp_dir/lock.d/owner.pid"
	stale_epoch=$(( $(date +%s 2>/dev/null || echo "0") - 10000 ))
	printf '%s\n' "$stale_epoch" >"$tmp_dir/lock.d/started_at_epoch"
	printf '%s\n' './setup.sh --non-interactive (simulated stale)' >"$tmp_dir/lock.d/command"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		AIDEVOPS_SETUP_STALE_TIMEOUT_S=1800
		AIDEVOPS_SETUP_WAIT_TIMEOUT_S=300
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		printf 'held=%s\n' "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}"
		_setup_release_noninteractive_setup_lock
		printf 'exists=%s\n' "$([[ -d "$tmp_dir/lock.d" ]] && printf yes || printf no)"
		return 0
	) 2>&1 || true

	kill "$owner_pid" 2>/dev/null || true
	wait "$owner_pid" 2>/dev/null || true
	rm -rf "$tmp_dir"
	if [[ "$output" == *"stale ceiling"* && "$output" == *"held=true"* && "$output" == *"exists=no"* ]]; then
		print_result "stale live owner past ceiling is reclaimed" 0
		return 0
	fi

	print_result "stale live owner past ceiling is reclaimed" 1 "output=${output}"
	return 0
}

test_wait_ceiling_prevents_indefinite_block() {
	# Start a real background process so kill -0 succeeds and owner is non-stale.
	# Use a very short wait ceiling so the test completes quickly.
	local tmp_dir=""
	local output=""
	local owner_pid=0
	local start_time=0
	local end_time=0
	local elapsed=0
	tmp_dir=$(make_temp_dir)
	mkdir -p "$tmp_dir/lock.d"

	# Fake setup owner acts as the live, non-stale lock owner.
	owner_pid=$(start_fake_setup_owner)
	printf '%s\n' "$owner_pid" >"$tmp_dir/lock.d/owner.pid"
	printf '%s\n' "$(date +%s 2>/dev/null || echo "0")" >"$tmp_dir/lock.d/started_at_epoch"
	printf '%s\n' 'sleep 300 (simulated live setup owner)' >"$tmp_dir/lock.d/command"

	start_time=$(date +%s 2>/dev/null || echo "0")
	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		AIDEVOPS_SETUP_WAIT_TIMEOUT_S=5
		AIDEVOPS_SETUP_STALE_TIMEOUT_S=3600
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		printf 'held=%s\n' "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}"
		return 0
	) 2>&1 || true
	end_time=$(date +%s 2>/dev/null || echo "0")

	kill "$owner_pid" 2>/dev/null || true
	wait "$owner_pid" 2>/dev/null || true
	rm -rf "$tmp_dir"

	elapsed=$(( end_time - start_time ))
	# Expect a timeout error, held=false, and exit within 30 s (one 10 s sleep + overhead).
	if [[ "$output" == *"Timed out"* && "$output" == *"held=false"* && "$elapsed" -le 30 ]]; then
		print_result "wait ceiling prevents indefinite blocking" 0
		return 0
	fi

	print_result "wait ceiling prevents indefinite blocking" 1 "output=${output} elapsed=${elapsed}"
	return 0
}

main() {
	test_blocks_concurrent_live_owner
	test_reclaims_stale_lock
	test_reclaims_reused_owner_pid_lock
	test_reclaims_stale_started_at_with_reused_setup_pid
	test_stale_live_owner_past_ceiling_is_reclaimed
	test_wait_ceiling_prevents_indefinite_block
	test_contention_message_includes_elapsed_and_stage
	test_signal_cleanup_terminates_registered_children
	test_signal_cleanup_terminates_unregistered_child_tree
	test_bounded_noncritical_stage_times_out_child_tree

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
