#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-worker-lifecycle-exit-emit.sh — Regression for t3055 / GH#21870
# =============================================================================
# Verifies that `_dlw_spawn_lifecycle_exit_monitor` (in
# pulse-dispatch-worker-launch.sh) emits a `[lifecycle] worker_exited` line
# to LOGFILE when a dispatched worker PID disappears, regardless of how
# the worker terminated. Closes the gap that caused PID 88900 to vanish
# from pulse.log without a forensic exit trail on 2026-04-29.
#
# Strategy: spawn a synthetic short-lived worker (`sleep 0.5; exit 7`),
# point the monitor at its PID with a tight polling interval, and assert
# the LOGFILE accumulates the canonical exit line within 30s.
#
# Usage: bash tests/test-worker-lifecycle-exit-emit.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_SCRIPTS="$(cd "${SCRIPT_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TMPDIR_TEST=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '  %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TMPDIR_TEST=$(mktemp -d)
	# LOGFILE is the target for the monitor's emit. The function reads it
	# from the environment, so set it before sourcing the helper.
	export LOGFILE="${TMPDIR_TEST}/pulse.log"
	: >"$LOGFILE"
	return 0
}

teardown() {
	[[ -n "$TMPDIR_TEST" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST" || true
	return 0
}

# Source the launcher script so we can call the monitor function directly.
# pulse-dispatch-worker-launch.sh expects shared-constants.sh to be sourced
# first, but the monitor only uses LOGFILE (which we set above). Stub the
# dependency-source guards so we can test in isolation.
load_function() {
	# Extract just the monitor function — avoids pulling in the full
	# dispatch surface (which depends on shared-constants.sh, gh, etc.).
	# The function is self-contained and only references LOGFILE.
	local launcher="${AGENTS_SCRIPTS}/pulse-dispatch-worker-launch.sh"
	if [[ ! -r "$launcher" ]]; then
		printf 'FATAL: launcher not found at %s\n' "$launcher" >&2
		return 1
	fi
	# Run a sub-bash that sources the launcher with stubbed deps. Define
	# the function in a fresh shell that only requires LOGFILE.
	# We use eval+sed to extract the monitor function source since the
	# full source has top-level guard `[[ -n "${_PULSE..._LOADED:-}" ]] && return 0`
	# meant for `source` from a parent shell that already sources deps.
	# Easier: skip the include guard by setting it false in a sub-shell
	# that sources shared-constants.sh first.
	# shellcheck disable=SC1091
	source "${AGENTS_SCRIPTS}/shared-constants.sh" 2>/dev/null || true
	# shellcheck source=../pulse-dispatch-worker-launch.sh
	# shellcheck disable=SC1091
	source "$launcher"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Synthetic worker exits with code 7; monitor emits worker_exited line
# ---------------------------------------------------------------------------
test_synthetic_worker_exit_emits_lifecycle_line() {
	# Spawn a synthetic short-lived worker. We use bash -c "exit 7" wrapped
	# in setsid so it runs in a separate process group (mimics the real
	# dispatch path's setsid detachment). The worker dies fast (~0.5s).
	local worker_pid
	(
		# Worker stays alive for 0.5s then exits 7.
		bash -c 'sleep 0.5; exit 7' &
		printf '%s\n' "$!" >"${TMPDIR_TEST}/worker_pid"
		wait
	) >/dev/null 2>&1 &
	# Wait briefly for the synthetic worker to register its PID.
	local wait_iter=0
	while [[ "$wait_iter" -lt 20 && ! -s "${TMPDIR_TEST}/worker_pid" ]]; do
		sleep 0.1
		wait_iter=$((wait_iter + 1))
	done
	worker_pid=$(cat "${TMPDIR_TEST}/worker_pid" 2>/dev/null || printf '0')
	if [[ ! "$worker_pid" =~ ^[0-9]+$ ]] || [[ "$worker_pid" == "0" ]]; then
		print_result "synthetic worker spawned with PID" 1 "got PID='$worker_pid'"
		return 0
	fi
	print_result "synthetic worker spawned with PID" 0

	# Tight poll interval so the test finishes quickly (~5s wall).
	# Window kept short — we expect the worker to die within 1s.
	export DLW_LIFECYCLE_MONITOR_POLL_SECONDS=1
	export DLW_LIFECYCLE_MONITOR_WINDOW_SECONDS=15

	# Invoke the monitor — it forks a detached watcher and returns.
	_dlw_spawn_lifecycle_exit_monitor "$worker_pid" "21870"

	# Wait up to 25s for the watcher to detect exit and write the line.
	# Poll the LOGFILE every 0.5s and exit early on first match.
	local wait_max=25 wait_elapsed=0 found=0
	while [[ "$wait_elapsed" -lt "$wait_max" ]]; do
		if grep -qE "\[lifecycle\] worker_exited pid=${worker_pid} " "$LOGFILE" 2>/dev/null; then
			found=1
			break
		fi
		sleep 1
		wait_elapsed=$((wait_elapsed + 1))
	done

	if [[ "$found" -eq 1 ]]; then
		print_result "lifecycle worker_exited line emitted to LOGFILE" 0
	else
		print_result "lifecycle worker_exited line emitted to LOGFILE" 1 \
			"LOGFILE contents: $(cat "$LOGFILE" 2>/dev/null || printf '<empty>')"
		return 0
	fi

	# Structural check: line carries kill_reason=parent_observed marker.
	if grep -qE "\[lifecycle\] worker_exited pid=${worker_pid} wait_status=[a-z0-9]+ kill_reason=parent_observed" "$LOGFILE"; then
		print_result "worker_exited line has wait_status= and kill_reason=parent_observed" 0
	else
		print_result "worker_exited line has wait_status= and kill_reason=parent_observed" 1 \
			"line: $(grep "worker_exited" "$LOGFILE" | head -1)"
	fi

	# Structural check: line carries the issue=#NNN marker.
	if grep -qE "\[lifecycle\] worker_exited.*issue=#21870" "$LOGFILE"; then
		print_result "worker_exited line has issue=#NNN marker" 0
	else
		print_result "worker_exited line has issue=#NNN marker" 1 \
			"line: $(grep "worker_exited" "$LOGFILE" | head -1)"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Test: Non-numeric PID is rejected silently (defensive guard)
# ---------------------------------------------------------------------------
test_non_numeric_pid_is_silent_noop() {
	local before_log_size after_log_size
	before_log_size=$(wc -c <"$LOGFILE" 2>/dev/null || printf '0')
	_dlw_spawn_lifecycle_exit_monitor "not-a-pid" "21870"
	# Should not fork or emit anything; give it a moment to be sure.
	sleep 1
	after_log_size=$(wc -c <"$LOGFILE" 2>/dev/null || printf '0')
	if [[ "$before_log_size" == "$after_log_size" ]]; then
		print_result "non-numeric PID is silent no-op" 0
	else
		print_result "non-numeric PID is silent no-op" 1 \
			"LOGFILE grew from ${before_log_size} to ${after_log_size} bytes"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: Missing LOGFILE env is silent no-op (defensive guard)
# ---------------------------------------------------------------------------
test_missing_logfile_is_silent_noop() {
	# Save and unset LOGFILE for this test.
	local saved_logfile="$LOGFILE"
	unset LOGFILE
	# Should return 0 without forking. We can't easily detect the absence
	# of a fork, but we can confirm the function returns cleanly and
	# doesn't error.
	if _dlw_spawn_lifecycle_exit_monitor "12345" "21870"; then
		print_result "missing LOGFILE returns cleanly" 0
	else
		print_result "missing LOGFILE returns cleanly" 1 \
			"function returned non-zero"
	fi
	# Restore.
	export LOGFILE="$saved_logfile"
	return 0
}

# ---------------------------------------------------------------------------
# Test: Function exists in the launcher source (smoke contract)
# ---------------------------------------------------------------------------
test_function_exists_in_source() {
	local launcher="${AGENTS_SCRIPTS}/pulse-dispatch-worker-launch.sh"
	if grep -qE "^_dlw_spawn_lifecycle_exit_monitor\(\)" "$launcher"; then
		print_result "_dlw_spawn_lifecycle_exit_monitor defined in launcher" 0
	else
		print_result "_dlw_spawn_lifecycle_exit_monitor defined in launcher" 1 \
			"function definition not found in $launcher"
	fi
	# And it's invoked from _dlw_exec_detached.
	# shellcheck disable=SC2016
	if grep -qE '_dlw_spawn_lifecycle_exit_monitor "\$worker_pid"' "$launcher"; then
		print_result "_dlw_spawn_lifecycle_exit_monitor invoked from _dlw_exec_detached" 0
	else
		print_result "_dlw_spawn_lifecycle_exit_monitor invoked from _dlw_exec_detached" 1 \
			"invocation not found in $launcher"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	setup
	trap teardown EXIT

	load_function || return 1

	test_function_exists_in_source
	test_non_numeric_pid_is_silent_noop
	test_missing_logfile_is_silent_noop
	test_synthetic_worker_exit_emits_lifecycle_line

	printf '\n%s tests run: %d passed, %d failed\n' \
		"$(basename "$0")" "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
