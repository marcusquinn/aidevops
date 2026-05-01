#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#22086: setup.sh --non-interactive lock/stall recovery.
# Covers:
#   1. Lock is released when setup exits early (EXIT trap fires)
#   2. Age-based stale lock reclaim kills a hung-but-alive owner process
#   3. Recent live lock is NOT reclaimed prematurely
#   4. Registered background children are killed by the EXIT trap

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

# Minimal print helpers used by the lock functions when loaded via eval.
# These must be defined before load_lock_functions so the subshell eval sees them.
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

print_info() {
	local message="$1"
	printf '[INFO] %s\n' "$message"
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
	tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-setup-lock-recovery-test.XXXXXX")
	printf '%s' "$tmp_dir"
	return 0
}

# Test 1: Lock is released on early exit (EXIT trap fires on set -e failure).
# Simulates a setup process that acquires the lock then exits with code 1
# (as would happen when _time_step returns non-zero on deploy failure).
# The EXIT trap must remove the lock dir.
test_lock_released_on_early_exit() {
	local tmp_dir=""
	local lock_exists="unknown"
	tmp_dir=$(make_temp_dir)

	(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		# Simulate deploy failure — EXIT trap must clean up the lock
		exit 1
	) 2>/dev/null || true

	if [[ -d "$tmp_dir/lock.d" ]]; then
		lock_exists="yes"
	else
		lock_exists="no"
	fi
	rm -rf "$tmp_dir"

	if [[ "$lock_exists" == "no" ]]; then
		print_result "lock is released when setup exits early (EXIT trap)" 0
		return 0
	fi

	print_result "lock is released when setup exits early (EXIT trap)" 1 \
		"lock dir still exists after exit 1 — EXIT trap did not clean it up"
	return 0
}

# Test 2: Age-based stale lock reclaim kills a hung-but-alive owner process.
# Creates a lock dir with a sleeping process as owner and a started_epoch 3600s
# in the past (exceeds 1800s default). Verifies the acquire call kills the
# sleeping process and successfully acquires the new lock.
test_age_based_stale_lock_reclaim() {
	local tmp_dir=""
	local output=""
	tmp_dir=$(make_temp_dir)

	# Start a background sleeper to simulate a hung setup process
	sleep 300 &
	local hung_pid=$!

	# Manufacture a lock held 3600 seconds ago by the sleeper
	mkdir -p "$tmp_dir/lock.d"
	printf '%s\n' "$hung_pid" >"$tmp_dir/lock.d/owner.pid"
	printf '%s\n' "$(($(date +%s) - 3600))" >"$tmp_dir/lock.d/started_epoch"
	printf '%s\n' 'setup.sh --non-interactive' >"$tmp_dir/lock.d/command"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		printf 'held=%s owner=%s\n' "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}" \
			"$(tr -d '[:space:]' <"$tmp_dir/lock.d/owner.pid" 2>/dev/null || echo 'none')"
		_setup_release_noninteractive_setup_lock
		printf 'exists=%s\n' "$([[ -d "$tmp_dir/lock.d" ]] && printf yes || printf no)"
		return 0
	) 2>&1 || true

	# Verify the sleeper was killed (allow a brief grace period)
	local hung_killed="no"
	sleep 0.2 2>/dev/null || sleep 1
	if ! kill -0 "$hung_pid" 2>/dev/null; then
		hung_killed="yes"
	else
		# Clean up if test fails
		kill -KILL "$hung_pid" 2>/dev/null || true
	fi
	rm -rf "$tmp_dir"

	if [[ "$output" == *"killing stale/hung process"* && \
		"$output" == *"held=true"* && \
		"$output" == *"exists=no"* && \
		"$hung_killed" == "yes" ]]; then
		print_result "age-based stale lock reclaims and kills hung process" 0
		return 0
	fi

	print_result "age-based stale lock reclaims and kills hung process" 1 \
		"output=${output} hung_killed=${hung_killed}"
	return 0
}

# Test 3: Recent lock with live owner is NOT reclaimed by age check.
# Creates a lock held only 60 seconds ago (well under 1800s default). Verifies
# that the acquire call blocks (returns 75) instead of killing the owner.
test_recent_live_lock_not_reclaimed() {
	local tmp_dir=""
	local output=""
	tmp_dir=$(make_temp_dir)

	# Use current shell as the "live" owner
	mkdir -p "$tmp_dir/lock.d"
	printf '%s\n' "$$" >"$tmp_dir/lock.d/owner.pid"
	printf '%s\n' "$(($(date +%s) - 60))" >"$tmp_dir/lock.d/started_epoch"
	printf '%s\n' 'setup.sh --non-interactive' >"$tmp_dir/lock.d/command"

	output=$(
		AIDEVOPS_SETUP_LOCK_DIR="$tmp_dir/lock.d"
		load_lock_functions
		_setup_acquire_noninteractive_setup_lock --non-interactive
		_rc=$?
		printf 'exit=%s\n' "$_rc"
		return 0
	) 2>&1 || true

	rm -rf "$tmp_dir"

	if [[ "$output" == *"already running"* && "$output" == *"exit=75"* ]]; then
		print_result "recent live lock is NOT reclaimed prematurely" 0
		return 0
	fi

	print_result "recent live lock is NOT reclaimed prematurely" 1 \
		"output=${output} (expected 'already running' and 'exit=75')"
	return 0
}

# Test 4: Registered background children are killed by the EXIT trap.
# Verifies that _setup_release_noninteractive_setup_lock (the EXIT trap
# handler) kills children registered via _setup_register_child_pid even when
# the exit is not triggered by a signal (i.e. SETUP_NONINTERACTIVE_TERMINATING
# is false, which is the set-e early-exit path).
test_exit_trap_kills_registered_children() {
	local tmp_dir=""
	local output=""
	tmp_dir=$(make_temp_dir)
	mkdir -p "$tmp_dir/fake-lock.d"

	output=$(
		load_lock_functions
		# Start a long sleeper and register it as a background deployment child
		sleep 300 &
		local child_pid=$!
		_setup_register_child_pid "$child_pid"
		# Simulate the EXIT trap firing: set lock held state and a valid lock dir
		SETUP_NONINTERACTIVE_LOCK_HELD=true
		SETUP_NONINTERACTIVE_LOCK_DIR="$tmp_dir/fake-lock.d"
		# Write own PID as owner so the rm path executes
		printf '%s\n' "$$" >"$tmp_dir/fake-lock.d/owner.pid"
		_setup_release_noninteractive_setup_lock
		# Give the signal a moment to reach the child
		sleep 0.2 2>/dev/null || sleep 1
		if kill -0 "$child_pid" 2>/dev/null; then
			printf 'child=alive\n'
			kill -KILL "$child_pid" 2>/dev/null || true
		else
			printf 'child=stopped\n'
		fi
		return 0
	) 2>&1 || true

	rm -rf "$tmp_dir"

	if [[ "$output" == *"child=stopped"* ]]; then
		print_result "EXIT trap kills registered background children" 0
		return 0
	fi

	print_result "EXIT trap kills registered background children" 1 \
		"output=${output} (expected 'child=stopped')"
	return 0
}

main() {
	if [[ ! -f "$SETUP_SCRIPT" ]]; then
		printf 'ERROR: setup.sh not found at %s\n' "$SETUP_SCRIPT" >&2
		exit 1
	fi

	test_lock_released_on_early_exit
	test_age_based_stale_lock_reclaim
	test_recent_live_lock_not_reclaimed
	test_exit_trap_kills_registered_children

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
