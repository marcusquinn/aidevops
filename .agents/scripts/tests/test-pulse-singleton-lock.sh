#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for pulse-wrapper singleton lock under racy conditions
# (GH#21433 / t3002).
#
# Background: pulse-instance-lock.sh's mkdir-based singleton lock had a
# real race between mkdir success and the subsequent `echo $$ >LOCKDIR/pid`
# write. _handle_existing_lock treated an empty PID file as "stale" and
# rm -rf'd LOCKDIR — destroying a freshly-acquired-but-not-yet-stamped
# owner's lock and letting a second instance acquire its own. Symptom: 4
# concurrent pulse-wrapper.sh PIDs, each logging "Instance lock acquired
# via mkdir" simultaneously.
#
# This test covers the two defences added in t3002:
#   1. _handle_existing_lock grace period: empty PID file is retried
#      briefly before treating as stale.
#   2. acquire_instance_lock post-write verification: re-read PID file
#      after writing $$ and confirm we still own the lock.
#
# Asserts:
#   T1. _handle_existing_lock with an empty PID file waits for the PID
#       to appear (grace period) and treats the live owner as live.
#   T2. _handle_existing_lock with an empty PID file that NEVER appears
#       eventually times out and proceeds to the stale-clear path.
#   T3. acquire_instance_lock detects ownership loss when LOCKDIR/pid
#       is mutated between write and verify (simulates the race winner).
#   T4. Singleton invariant: when two acquire_instance_lock attempts run
#       concurrently, only one returns 0 and ends up in the PID file.

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

# Source pulse-instance-lock.sh with a minimal stub environment, mirroring
# test-pulse-instance-lock-mkdir-only.sh.
setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"

	LOCKDIR="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
	WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
	_LOCK_OWNED=false
	PULSE_STALE_THRESHOLD=3600
	export LOCKDIR WRAPPER_LOGFILE LOGFILE PIDFILE _LOCK_OWNED PULSE_STALE_THRESHOLD

	_get_process_age() { echo "42"; }
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
	if [[ -n "${LOCKDIR:-}" && -d "$LOCKDIR" ]]; then
		rm -rf "$LOCKDIR"
	fi
	_LOCK_OWNED=false
	return 0
}

reset_state() {
	if [[ -n "${LOCKDIR:-}" && -d "$LOCKDIR" ]]; then
		rm -rf "$LOCKDIR"
	fi
	_LOCK_OWNED=false
	return 0
}

#######################################
# T1: Grace period — _handle_existing_lock with an empty PID file waits
# for the PID to appear before declaring stale.
#
# Setup: pre-create LOCKDIR (simulating mkdir-succeeded-but-PID-not-written
# state), then schedule a background task to write a live pulse-wrapper PID
# 500ms later. _handle_existing_lock must wait through its grace window,
# read the appearing PID, and return 1 (owner is live, do not reclaim).
#######################################
test_grace_period_empty_pid_file() {
	reset_state

	# Background pulse-wrapper-like process (so PID-reuse guard sees a
	# pulse-wrapper command name). NOTE: do NOT use `exec sleep` here —
	# exec replaces the bash process and ps -o command= then shows
	# "sleep N" without "pulse-wrapper" in argv, tripping the PID-reuse
	# force-reclaim path. Plain `sleep N` keeps bash alive with the
	# original argv intact.
	local fake_script="${TEST_ROOT}/pulse-wrapper.sh"
	cat >"$fake_script" <<'FAKEOF'
#!/usr/bin/env bash
sleep 60
FAKEOF
	chmod +x "$fake_script"
	"$fake_script" &
	local fake_pid=$!

	# Pre-create LOCKDIR with NO PID file (the race state).
	mkdir -p "$LOCKDIR"

	# Schedule a delayed PID write to simulate the racy owner stamping
	# their PID 500ms after mkdir.
	(
		sleep 0.5
		echo "$fake_pid" >"${LOCKDIR}/pid"
	) &
	local writer_pid=$!

	# _handle_existing_lock should see empty PID file, wait through grace,
	# read the now-stamped fake_pid, see it is alive + pulse-wrapper, and
	# return 1.
	local rc=0
	_handle_existing_lock || rc=$?
	assert_equals "T1: grace period waited for late PID write — returns 1 (live owner)" "1" "$rc"

	# LOCKDIR must NOT have been removed (live owner case preserves it).
	if [[ -d "$LOCKDIR" ]]; then
		print_result "T1: LOCKDIR preserved after grace-detected live owner" 0
	else
		print_result "T1: LOCKDIR preserved after grace-detected live owner" 1
	fi

	# Cleanup
	wait "$writer_pid" 2>/dev/null || true
	kill "$fake_pid" 2>/dev/null || true
	wait "$fake_pid" 2>/dev/null || true
	rm -rf "$LOCKDIR"
	return 0
}

#######################################
# T2: Grace period times out — when the PID never appears (true SIGKILL/
# OOM mid-mkdir orphan), _handle_existing_lock proceeds to clear and
# re-acquire after the grace window.
#######################################
test_grace_period_timeout() {
	reset_state

	# Pre-create LOCKDIR with NO PID file. No background writer — this
	# simulates a process killed between mkdir and PID stamp.
	mkdir -p "$LOCKDIR"

	# _handle_existing_lock should grace, time out, then clear and
	# re-acquire (returns 0).
	local rc=0
	_handle_existing_lock || rc=$?
	assert_equals "T2: grace period times out → clears and re-acquires (returns 0)" "0" "$rc"

	# LOCKDIR must exist (we re-acquired it).
	if [[ -d "$LOCKDIR" ]]; then
		print_result "T2: LOCKDIR re-created after grace timeout" 0
	else
		print_result "T2: LOCKDIR re-created after grace timeout" 1
	fi

	rm -rf "$LOCKDIR"
	return 0
}

#######################################
# T3: Post-write verification — acquire_instance_lock detects when the
# PID file is mutated between write and verify (race winner overwrote
# our PID with theirs).
#######################################
test_post_write_verification() {
	reset_state

	# Override the verify-step sleep to be longer so we have a window to
	# mutate the PID file. sleep is a builtin via /bin/sleep; we shadow
	# it as a function in our subshell context. Then mutate during the
	# sleep.
	#
	# To inject the mutation without modifying the function, we use a
	# background process that watches LOCKDIR/pid and overwrites it.
	#
	# Wait for the file to exist, then overwrite with a foreign PID.
	local foreign_pid=99999998
	(
		# Wait for our PID to appear, then immediately overwrite.
		while [[ ! -f "${LOCKDIR}/pid" ]]; do sleep 0.01 2>/dev/null || sleep 1; done
		echo "$foreign_pid" >"${LOCKDIR}/pid"
	) &
	local mutator_pid=$!

	local rc=0
	acquire_instance_lock || rc=$?
	assert_equals "T3: post-write verify detects PID mutation → returns 1" "1" "$rc"

	# _LOCK_OWNED must remain false (we never owned it).
	assert_equals "T3: _LOCK_OWNED remains false on verify failure" "false" "$_LOCK_OWNED"

	wait "$mutator_pid" 2>/dev/null || true
	rm -rf "$LOCKDIR"
	return 0
}

#######################################
# T4: Singleton invariant under concurrent acquire — spawn two real
# pulse-wrapper.sh-named processes that each attempt acquire_instance_lock,
# and verify exactly ONE ends up as the recorded lock holder.
#
# Note on test architecture: subshells `( ... ) &` inherit the parent test
# script's argv, so `ps -o command=` for them shows "bash test-pulse-...".
# That fails the PID-reuse guard inside _handle_existing_lock (which
# requires "pulse-wrapper" in the owner command) and triggers force-reclaim.
# To model the real production race we therefore spawn external bash
# processes via scripts physically named `pulse-wrapper.sh`. Each child
# sources pulse-instance-lock.sh, calls acquire_instance_lock, and writes
# its rc to a tagged file.
#######################################
test_concurrent_acquire_singleton() {
	reset_state

	# Worker script template — physically named pulse-wrapper.sh so the
	# PID-reuse guard sees "pulse-wrapper" in argv via ps.
	local worker_dir="${TEST_ROOT}/workers"
	mkdir -p "$worker_dir"

	# Helper writes a tagged worker that imports our test stubs + sources
	# the lock module, then calls acquire_instance_lock and reports rc.
	# The parent provides LOCKDIR/WRAPPER_LOGFILE/etc via env export.
	local _worker_template="${TEST_ROOT}/worker-template.sh"
	cat >"$_worker_template" <<EOF_TPL
#!/usr/bin/env bash
set -u
TAG="\$1"
RC_FILE="\$2"
LOCKDIR="${LOCKDIR}"
WRAPPER_LOGFILE="${WRAPPER_LOGFILE}"
LOGFILE="${LOGFILE}"
PIDFILE="${PIDFILE}"
PULSE_STALE_THRESHOLD=3600
_LOCK_OWNED=false
export LOCKDIR WRAPPER_LOGFILE LOGFILE PIDFILE PULSE_STALE_THRESHOLD _LOCK_OWNED

_get_process_age() { echo "1"; }
_kill_tree() { return 0; }
_force_kill_tree() { return 0; }
get_max_workers_target() { echo "1"; }
count_active_workers() { echo "0"; }

# shellcheck source=/dev/null
source "${PULSE_SCRIPTS_DIR}/pulse-instance-lock.sh"

_rc=0
acquire_instance_lock || _rc=\$?
echo "\$_rc" >"\$RC_FILE"

# If we acquired it, hold briefly so the contender observes the live
# owner before exiting.
if [[ "\$_rc" == "0" ]]; then
	sleep 0.5
	release_instance_lock
fi
exit 0
EOF_TPL
	chmod +x "$_worker_template"

	# Two concrete pulse-wrapper.sh-named worker scripts that exec the
	# template. Their physical filename satisfies the "pulse-wrapper"-in-
	# command check inside _handle_existing_lock.
	local worker_A="${worker_dir}/pulse-wrapper.sh"
	cat >"$worker_A" <<EOF_A
#!/usr/bin/env bash
exec bash "${_worker_template}" "\$@"
EOF_A
	chmod +x "$worker_A"

	# Spawn two contenders simultaneously.
	"$worker_A" "A" "${TEST_ROOT}/rc-A" &
	local pid_A=$!
	"$worker_A" "B" "${TEST_ROOT}/rc-B" &
	local pid_B=$!

	wait "$pid_A" 2>/dev/null || true
	wait "$pid_B" 2>/dev/null || true

	local rc_A rc_B
	rc_A=$(cat "${TEST_ROOT}/rc-A" 2>/dev/null || echo "missing")
	rc_B=$(cat "${TEST_ROOT}/rc-B" 2>/dev/null || echo "missing")

	# Exactly one of {A, B} must have returned 0; the other must have
	# returned non-zero.
	local zero_count=0
	[[ "$rc_A" == "0" ]] && zero_count=$((zero_count + 1))
	[[ "$rc_B" == "0" ]] && zero_count=$((zero_count + 1))

	if [[ "$zero_count" -eq 1 ]]; then
		print_result "T4: exactly one concurrent acquire returns 0 (singleton)" 0
	else
		print_result "T4: exactly one concurrent acquire returns 0 (singleton)" 1 \
			"rc-A=${rc_A} rc-B=${rc_B} zero_count=${zero_count}"
	fi

	# After both workers exit, LOCKDIR should be cleaned up by the
	# winner's release_instance_lock. The loser never owned it.
	if [[ ! -d "$LOCKDIR" ]]; then
		print_result "T4: LOCKDIR cleaned up after winner releases" 0
	else
		print_result "T4: LOCKDIR cleaned up after winner releases" 1 \
			"residual LOCKDIR=${LOCKDIR}"
		rm -rf "$LOCKDIR"
	fi
	return 0
}

#######################################
# Main
#######################################
main() {
	printf '%b==> pulse singleton lock race tests (GH#21433 / t3002)%b\n' \
		"$TEST_YELLOW" "$TEST_RESET"
	printf '    PULSE_SCRIPTS_DIR=%s\n' "$PULSE_SCRIPTS_DIR"

	setup_sandbox

	test_grace_period_empty_pid_file
	test_grace_period_timeout
	test_post_write_verification
	test_concurrent_acquire_singleton

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
