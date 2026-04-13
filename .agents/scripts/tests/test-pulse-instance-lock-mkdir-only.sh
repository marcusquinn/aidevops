#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Characterization tests for pulse-instance-lock.sh (GH#18668).
#
# Purpose: lock in the mkdir-only behaviour after the flock layer was dropped.
# Any future regression that reintroduces persistent FD-based locking in the
# pulse parent will fail here.
#
# Asserts:
#   1. acquire_instance_lock creates LOCKDIR + PID file on first attempt
#   2. A stale lock (dead PID) is cleared and re-acquired
#   3. A live concurrent lock owner blocks acquisition
#   4. release_instance_lock removes LOCKDIR and is idempotent
#   5. NO LOCKFILE is created at the old path — the file-based lock is gone
#   6. FD 9 is NOT open in the parent after acquisition — the persistent FD
#      inheritance vector no longer exists
#   7. After release, a subsequent acquisition succeeds
#
# This test sources pulse-instance-lock.sh directly with a minimal stub
# environment (not the full pulse-wrapper.sh) so the assertions isolate
# the lock module's contract from every other pulse-wrapper concern.
#
# See: .agents/reference/bash-fd-locking.md

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[0;33m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
PULSE_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly PULSE_SCRIPTS_DIR

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

assert_equals() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "expected='${expected}' actual='${actual}'"
	fi
	return 0
}

#######################################
# Source pulse-instance-lock.sh with a minimal stub environment.
#
# The module is normally sourced by pulse-wrapper.sh after shared-constants.sh
# and worker-lifecycle-common.sh have defined constants and helpers. We stub
# the minimum surface the module actually uses:
#   - LOCKDIR, WRAPPER_LOGFILE, LOGFILE, PIDFILE (paths)
#   - _LOCK_OWNED (state flag)
#   - _get_process_age (helper)
#   - _kill_tree, _force_kill_tree (helpers used by check_dedup path)
#######################################
setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"

	# Paths normally set by pulse-wrapper.sh bootstrap
	LOCKDIR="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
	WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
	_LOCK_OWNED=false
	PULSE_STALE_THRESHOLD=3600
	export LOCKDIR WRAPPER_LOGFILE LOGFILE PIDFILE _LOCK_OWNED PULSE_STALE_THRESHOLD

	# Minimal helper stubs used by the lock module
	_get_process_age() {
		# Stub — return a fixed value. Real helper reads /proc or ps.
		echo "42"
	}
	_kill_tree() { return 0; }
	_force_kill_tree() { return 0; }
	get_max_workers_target() { echo "1"; }
	count_active_workers() { echo "0"; }
	export -f _get_process_age _kill_tree _force_kill_tree
	export -f get_max_workers_target count_active_workers

	# shellcheck source=/dev/null
	source "${PULSE_SCRIPTS_DIR}/pulse-instance-lock.sh"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	# Clean any stray LOCKDIR so sequential tests are independent
	if [[ -n "${LOCKDIR:-}" && -d "$LOCKDIR" ]]; then
		rm -rf "$LOCKDIR"
	fi
	_LOCK_OWNED=false
	return 0
}

reset_state() {
	# Between-test reset — remove LOCKDIR and flip _LOCK_OWNED back.
	if [[ -n "${LOCKDIR:-}" && -d "$LOCKDIR" ]]; then
		rm -rf "$LOCKDIR"
	fi
	_LOCK_OWNED=false
	return 0
}

#######################################
# Test 1: clean acquisition — LOCKDIR does not exist, mkdir succeeds, PID
# file written, _LOCK_OWNED set to true.
#######################################
test_clean_acquisition() {
	reset_state

	if acquire_instance_lock; then
		print_result "acquire_instance_lock: first attempt succeeds" 0
	else
		print_result "acquire_instance_lock: first attempt succeeds" 1
		return 0
	fi

	if [[ -d "$LOCKDIR" ]]; then
		print_result "acquire_instance_lock: LOCKDIR created" 0
	else
		print_result "acquire_instance_lock: LOCKDIR created" 1 "LOCKDIR=${LOCKDIR}"
	fi

	if [[ -f "${LOCKDIR}/pid" ]]; then
		local pid_content
		pid_content=$(cat "${LOCKDIR}/pid")
		assert_equals "acquire_instance_lock: PID file contains current PID" "$$" "$pid_content"
	else
		print_result "acquire_instance_lock: PID file exists" 1 "missing ${LOCKDIR}/pid"
	fi

	assert_equals "acquire_instance_lock: _LOCK_OWNED set to true" "true" "$_LOCK_OWNED"

	release_instance_lock
	return 0
}

#######################################
# Test 2: stale lock recovery — a PID file containing a dead PID is cleared
# and re-acquired on the next attempt.
#######################################
test_stale_lock_recovery() {
	reset_state

	# Simulate a stale lock: mkdir the lockdir manually and write a PID
	# that is guaranteed not to exist. PID 2 exists on Linux (kthreadd)
	# so use a high PID in the PID-space far above ps -e output.
	mkdir -p "$LOCKDIR"
	local fake_dead_pid=999999
	# Ensure it's actually dead — on the off chance it exists, bump it
	while ps -p "$fake_dead_pid" >/dev/null 2>&1; do
		fake_dead_pid=$((fake_dead_pid + 1))
	done
	echo "$fake_dead_pid" >"${LOCKDIR}/pid"

	if acquire_instance_lock; then
		print_result "stale lock recovery: re-acquired after dead PID cleared" 0
	else
		print_result "stale lock recovery: re-acquired after dead PID cleared" 1
		return 0
	fi

	# The PID file should now contain OUR PID, not the stale one
	local pid_content
	pid_content=$(cat "${LOCKDIR}/pid")
	assert_equals "stale lock recovery: PID file overwritten with our PID" "$$" "$pid_content"

	release_instance_lock
	return 0
}

#######################################
# Test 3: live concurrent owner blocks acquisition — a PID file containing
# our own PID (which is alive by definition) must block re-acquisition.
#
# This exercises the "lock owner is alive" branch of acquire_instance_lock.
# We cannot easily spawn a real peer bash process that holds the lock and
# stays alive long enough to observe, so we use our own PID as a stand-in
# for "a live process that holds the lock". This is a slight fudge — the
# real contention scenario is another bash PID — but the code path is the
# same: `ps -p "$lock_pid"` returns success for any live PID including
# our own, and acquire_instance_lock returns 1.
#######################################
test_live_concurrent_owner() {
	reset_state

	# Manually create a lock dir owned by our own (live) PID
	mkdir -p "$LOCKDIR"
	echo "$$" >"${LOCKDIR}/pid"
	_LOCK_OWNED=false # we didn't go through acquire_instance_lock

	# acquire_instance_lock should see the PID is alive and return 1
	local rc=0
	acquire_instance_lock || rc=$?
	assert_equals "live owner: acquire_instance_lock returns 1" "1" "$rc"

	# LOCKDIR must still exist (we didn't clear a live owner's lock)
	if [[ -d "$LOCKDIR" ]]; then
		print_result "live owner: LOCKDIR preserved (not cleared)" 0
	else
		print_result "live owner: LOCKDIR preserved (not cleared)" 1
	fi

	# _LOCK_OWNED must still be false (we didn't acquire)
	assert_equals "live owner: _LOCK_OWNED remains false" "false" "$_LOCK_OWNED"

	# Clean up for next test
	rm -rf "$LOCKDIR"
	return 0
}

#######################################
# Test 4: release_instance_lock removes LOCKDIR and is idempotent.
#######################################
test_release_is_idempotent() {
	reset_state

	acquire_instance_lock >/dev/null
	if [[ ! -d "$LOCKDIR" ]]; then
		print_result "release: setup (acquire) created LOCKDIR" 1
		return 0
	fi

	release_instance_lock
	if [[ ! -d "$LOCKDIR" ]]; then
		print_result "release: LOCKDIR removed on first call" 0
	else
		print_result "release: LOCKDIR removed on first call" 1
	fi

	# Second call must not error and must not recreate anything
	release_instance_lock
	if [[ ! -d "$LOCKDIR" ]]; then
		print_result "release: idempotent (safe to call twice)" 0
	else
		print_result "release: idempotent (safe to call twice)" 1
	fi
	return 0
}

#######################################
# Test 5: no LOCKFILE is created — the file-based lock is gone.
#
# Before GH#18668, pulse-wrapper.sh opened `exec 9>"$LOCKFILE"` where
# LOCKFILE=~/.aidevops/logs/pulse-wrapper.lock. After Path A, that line was
# deleted. This test asserts the old file path is never created during
# acquisition or release.
#######################################
test_no_lockfile_created() {
	reset_state
	local legacy_lockfile="${HOME}/.aidevops/logs/pulse-wrapper.lock"
	rm -f "$legacy_lockfile"

	acquire_instance_lock >/dev/null
	if [[ ! -f "$legacy_lockfile" ]]; then
		print_result "no LOCKFILE created during acquisition" 0
	else
		print_result "no LOCKFILE created during acquisition" 1 \
			"unexpected file at ${legacy_lockfile}"
	fi

	release_instance_lock
	if [[ ! -f "$legacy_lockfile" ]]; then
		print_result "no LOCKFILE created during release" 0
	else
		print_result "no LOCKFILE created during release" 1
	fi
	return 0
}

#######################################
# Test 6: FD 9 is NOT open in the parent after acquisition.
#
# This is the key negative test — the whole reason for Path A is that bash
# cannot mark FDs close-on-exec, so any persistent FD 9 leaks into children.
# After GH#18668, FD 9 must NEVER be open in the pulse parent.
#
# We probe FD 9 via /dev/fd/9 (Linux and macOS both provide this). If FD 9
# is closed, [[ -e /dev/fd/9 ]] returns false.
#######################################
test_fd9_not_open() {
	reset_state
	acquire_instance_lock >/dev/null

	# Probe FD 9 without opening it. Bash does not expose an API for
	# "is FD N open" directly, but /dev/fd/N is a symlink to the open
	# file description — it exists iff N is open.
	if [[ -e /dev/fd/9 ]]; then
		print_result "FD 9 not open in parent after acquire_instance_lock" 1 \
			"/dev/fd/9 exists — persistent FD was opened somewhere"
	else
		print_result "FD 9 not open in parent after acquire_instance_lock" 0
	fi

	release_instance_lock
	return 0
}

#######################################
# Test 7: acquire/release cycle — after release, a fresh acquisition from
# the same process succeeds. This is the "back-to-back pulse cycles" case
# that hung in the historical flock incidents.
#######################################
test_acquire_release_cycle() {
	reset_state

	local i
	for i in 1 2 3; do
		if acquire_instance_lock >/dev/null; then
			print_result "cycle ${i}: acquire succeeded" 0
		else
			print_result "cycle ${i}: acquire succeeded" 1
			return 0
		fi
		release_instance_lock
		if [[ -d "$LOCKDIR" ]]; then
			print_result "cycle ${i}: release cleared LOCKDIR" 1
			return 0
		fi
		print_result "cycle ${i}: release cleared LOCKDIR" 0
	done
	return 0
}

#######################################
# Main
#######################################
main() {
	printf '%b==> pulse-instance-lock.sh mkdir-only characterization tests%b\n' \
		"$TEST_YELLOW" "$TEST_RESET"
	printf '    PULSE_SCRIPTS_DIR=%s\n' "$PULSE_SCRIPTS_DIR"

	setup_sandbox

	test_clean_acquisition
	test_stale_lock_recovery
	test_live_concurrent_owner
	test_release_is_idempotent
	test_no_lockfile_created
	test_fd9_not_open
	test_acquire_release_cycle

	teardown_sandbox

	printf '\n'
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		return 0
	fi
	printf '%b%d of %d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	return 1
}

main "$@"
