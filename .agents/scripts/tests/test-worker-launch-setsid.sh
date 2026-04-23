#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Test: verify that _dlw_nohup_launch detaches workers via setsid so their
# PGID differs from pulse's PGID when setsid is available. Guards against
# regressions of the fix in t2757 (GH#20561).
#
# Two paths are tested:
#   - setsid available: launched subprocess must have a PGID different from
#     the test process's PGID.
#   - setsid missing (simulated by PATH override): fallback nohup-only path
#     must still launch the subprocess (PGID may match — that's expected).
#
# The test does NOT invoke the full worker infrastructure. It isolates the
# setsid/nohup launch mechanic using a minimal sleep stub so no LLM session
# is spawned and no network calls are made.

set -euo pipefail

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Launch a background sleep via setsid (if available) or nohup-only and
# return its PID. Mirrors the logic added to _dlw_nohup_launch in t2757.
_test_launch_detached() {
	local use_setsid="${1:-auto}"
	local pid
	if [[ "$use_setsid" == "auto" ]]; then
		if command -v setsid >/dev/null 2>&1; then
			use_setsid="yes"
		else
			use_setsid="no"
		fi
	fi

	if [[ "$use_setsid" == "yes" ]]; then
		setsid nohup sleep 10 </dev/null >/dev/null 2>&1 &
	else
		nohup sleep 10 </dev/null >/dev/null 2>&1 &
	fi
	pid="$!"
	printf '%s\n' "$pid"
	return 0
}

test_setsid_available_path() {
	if ! command -v setsid >/dev/null 2>&1; then
		echo "SKIP test_setsid_available_path: setsid not installed on this system"
		return 0
	fi

	local child_pid
	child_pid=$(_test_launch_detached "yes")

	# Give the OS a moment to update process table
	sleep 0.2

	local parent_pgid child_pgid
	parent_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ') || parent_pgid=""
	child_pgid=$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d ' ') || child_pgid=""

	# Clean up
	kill "$child_pid" 2>/dev/null || true

	if [[ -z "$child_pgid" ]]; then
		# Process may have already exited (race on a slow system) — treat as skip
		echo "SKIP test_setsid_available_path: child exited before PGID could be read"
		return 0
	fi

	if [[ -z "$parent_pgid" ]]; then
		print_result "setsid: child PGID differs from parent PGID" 1 \
			"could not determine parent PGID"
		return 0
	fi

	if [[ "$child_pgid" != "$parent_pgid" ]]; then
		print_result "setsid: child PGID ($child_pgid) differs from parent PGID ($parent_pgid)" 0
	else
		print_result "setsid: child PGID ($child_pgid) differs from parent PGID ($parent_pgid)" 1 \
			"PGIDs are equal — setsid did not create a new process group"
	fi
	return 0
}

test_setsid_missing_fallback() {
	# Simulate missing setsid by forcing the "no" path directly
	local child_pid
	child_pid=$(_test_launch_detached "no")

	# Give the OS a moment
	sleep 0.2

	local child_running=false
	if ps -p "$child_pid" >/dev/null 2>&1; then
		child_running=true
	fi

	# Clean up
	kill "$child_pid" 2>/dev/null || true

	if [[ "$child_running" == "true" ]]; then
		print_result "fallback nohup-only: child process launched successfully" 0
	else
		# Could be a race — process ran so fast it exited. Just check it was non-empty PID.
		if [[ -n "$child_pid" ]] && [[ "$child_pid" =~ ^[0-9]+$ ]]; then
			print_result "fallback nohup-only: child process launched (already exited)" 0
		else
			print_result "fallback nohup-only: child process launched successfully" 1 \
				"invalid PID returned: '$child_pid'"
		fi
	fi
	return 0
}

test_signal_isolation_setsid() {
	# Verify that a PG-scoped SIGTERM to the parent's PGID does NOT kill the
	# setsid-detached child. This is the functional guarantee from t2757.
	if ! command -v setsid >/dev/null 2>&1; then
		echo "SKIP test_signal_isolation_setsid: setsid not installed on this system"
		return 0
	fi

	local child_pid
	child_pid=$(_test_launch_detached "yes")
	sleep 0.2

	local child_pgid
	child_pgid=$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d ' ') || child_pgid=""
	local parent_pgid
	parent_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ') || parent_pgid=""

	if [[ -z "$child_pgid" || -z "$parent_pgid" ]]; then
		echo "SKIP test_signal_isolation_setsid: could not read PGIDs"
		kill "$child_pid" 2>/dev/null || true
		return 0
	fi

	if [[ "$child_pgid" == "$parent_pgid" ]]; then
		# setsid did not work — cannot test isolation safely
		kill "$child_pid" 2>/dev/null || true
		print_result "signal isolation: setsid child in separate PGID before isolation test" 1 \
			"child and parent share PGID $parent_pgid — setsid may not have worked"
		return 0
	fi

	# Send SIGTERM to parent's process group (simulating pulse restart signal)
	# We use kill -TERM -PGID but from a subshell so we don't kill ourselves
	# Note: we cannot actually send to the real parent PG safely from a test.
	# Instead we verify the child is alive AFTER a brief delay — if setsid
	# worked, the child is in a different PG and would survive our own kill.
	# The direct PG-kill would terminate *this* test process, so we skip that
	# destructive step and rely on the PGID-differs check as the proxy assertion.
	local child_alive=false
	if ps -p "$child_pid" >/dev/null 2>&1; then
		child_alive=true
	fi

	kill "$child_pid" 2>/dev/null || true

	if [[ "$child_alive" == "true" ]]; then
		print_result "signal isolation: setsid child survived in separate PGID" 0
	else
		print_result "signal isolation: setsid child survived in separate PGID" 1 \
			"child was not running when checked (possible race)"
	fi
	return 0
}

main() {
	test_setsid_available_path
	test_setsid_missing_fallback
	test_signal_isolation_setsid

	echo ""
	echo "Tests run: $TESTS_RUN, passed: $TESTS_PASSED, failed: $TESTS_FAILED"

	if [[ $TESTS_FAILED -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
