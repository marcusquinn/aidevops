#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-contribution-watch-pid-guard.sh
#
# Unit tests for contribution-watch-helper.sh PID guard (GH#17415):
# - stop with no PID file
# - stop with stale PID file
# - stop with invalid PID file
# - scan duplicate prevention (PID guard)
# - stale PID file allows new scan
# - restart with no running scan
#
# Uses isolated temp directories to avoid touching production data.
#
# Usage: bash tests/test-contribution-watch-pid-guard.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_DIR/.agents/scripts/contribution-watch-helper.sh"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;32mPASS\033[0m %s\n" "$1"
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
	return 0
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
	return 0
}

# --- Isolated Test Environment ---
TEST_DIR=$(mktemp -d)
HOME_BACKUP="$HOME"
export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.aidevops/.pid"
mkdir -p "$HOME/.aidevops/logs"
mkdir -p "$HOME/.aidevops/cache"
mkdir -p "$HOME/.config/aidevops"

# Minimal repos.json so the script doesn't error on missing file
echo '{"initialized_repos":[],"git_parent_dirs":[]}' >"$HOME/.config/aidevops/repos.json"

# Minimal state file so scan doesn't fail on missing state
echo '{"last_scan":"2026-01-01T00:00:00Z","items":{}}' >"$HOME/.aidevops/cache/contribution-watch.json"

PID_FILE_PATH="$HOME/.aidevops/.pid/contribution-watch.pid"

trap 'HOME="$HOME_BACKUP"; rm -rf "$TEST_DIR"' EXIT

# --- Prerequisite Check ---
if [[ ! -x "$SCRIPT_UNDER_TEST" ]]; then
	echo "ERROR: Script not found or not executable: $SCRIPT_UNDER_TEST"
	exit 1
fi

# ============================================================================
section "Scan PID File Guard (GH#17415)"
# ============================================================================

test_stop_no_pid_file() {
	# stop with no PID file should exit 1 with an error message
	rm -f "$PID_FILE_PATH"
	local exit_code=0
	bash "$SCRIPT_UNDER_TEST" stop 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 1 ]]; then
		pass "stop with no PID file exits 1"
	else
		fail "stop with no PID file exits 1" "Got exit code $exit_code"
	fi
	return 0
}

test_stop_stale_pid_file() {
	# stop with a stale PID file (process gone) should clean up and exit 0
	# Use a PID that is guaranteed not to exist
	echo "999999999" >"$PID_FILE_PATH"
	local exit_code=0
	bash "$SCRIPT_UNDER_TEST" stop >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 0 ]]; then
		pass "stop with stale PID exits 0 and cleans up"
	else
		fail "stop with stale PID exits 0 and cleans up" "Got exit code $exit_code"
	fi
	# PID file should be removed
	if [[ ! -f "$PID_FILE_PATH" ]]; then
		pass "stop removes stale PID file"
	else
		fail "stop removes stale PID file" "PID file still exists"
		rm -f "$PID_FILE_PATH"
	fi
	return 0
}

test_stop_invalid_pid_file() {
	# stop with a non-numeric PID file should exit 1 and clean up
	echo "not-a-pid" >"$PID_FILE_PATH"
	local exit_code=0
	bash "$SCRIPT_UNDER_TEST" stop >/dev/null 2>&1 || exit_code=$?
	if [[ "$exit_code" -eq 1 ]]; then
		pass "stop with invalid PID file exits 1"
	else
		fail "stop with invalid PID file exits 1" "Got exit code $exit_code"
	fi
	# PID file should be removed
	if [[ ! -f "$PID_FILE_PATH" ]]; then
		pass "stop removes invalid PID file"
	else
		fail "stop removes invalid PID file" "PID file still exists"
		rm -f "$PID_FILE_PATH"
	fi
	return 0
}

test_scan_duplicate_prevention() {
	# Simulate a running scan by writing our own PID to the PID file
	echo $$ >"$PID_FILE_PATH"

	# Attempting to start another scan should fail with exit 1
	local exit_code=0
	local output
	output=$(bash "$SCRIPT_UNDER_TEST" scan 2>&1) || exit_code=$?
	if [[ "$exit_code" -eq 1 ]]; then
		pass "scan exits 1 when scan already running"
	else
		fail "scan exits 1 when scan already running" "Got exit code $exit_code"
	fi
	if echo "$output" | grep -q "already running"; then
		pass "scan prints 'already running' message"
	else
		fail "scan prints 'already running' message" "Output: $output"
	fi

	# Clean up
	rm -f "$PID_FILE_PATH"
	return 0
}

test_stale_pid_allows_new_scan() {
	# A stale PID file (process gone) should not block a new scan.
	# We verify the stale-file cleanup path: stop clears it.
	echo "999999999" >"$PID_FILE_PATH"

	# stop should clean up the stale file
	bash "$SCRIPT_UNDER_TEST" stop >/dev/null 2>&1 || true

	if [[ ! -f "$PID_FILE_PATH" ]]; then
		pass "Stale PID file cleared by stop, allowing new scan start"
	else
		fail "Stale PID file cleared by stop" "PID file still exists"
		rm -f "$PID_FILE_PATH"
	fi
	return 0
}

test_stop_no_pid_file
test_stop_stale_pid_file
test_stop_invalid_pid_file
test_scan_duplicate_prevention
test_stale_pid_allows_new_scan

# ============================================================================
section "Restart Command"
# ============================================================================

test_restart_no_running_scan() {
	# restart with no running scan should not error on the stop phase
	# (stop_rc=1 is tolerated). We can't run a full blocking scan in tests,
	# so we verify restart doesn't fail when no scan is running.
	rm -f "$PID_FILE_PATH"

	# restart calls stop (which will exit 1 — no PID file) then scan.
	# scan will fail because gh is not available in test env, but the
	# important thing is it doesn't fail due to the stop phase.
	local output
	output=$(bash "$SCRIPT_UNDER_TEST" restart 2>&1) || true

	# The output should NOT contain "already running" (that would mean
	# the stop phase failed to clear a stale PID)
	if ! echo "$output" | grep -q "already running"; then
		pass "restart does not report 'already running' when no scan is running"
	else
		fail "restart does not report 'already running'" "Output: $output"
	fi

	# Clean up any PID file left by the restart attempt
	rm -f "$PID_FILE_PATH"
	return 0
}

test_restart_no_running_scan

# ============================================================================
section "Help Output"
# ============================================================================

test_help_includes_stop_restart() {
	local output
	output=$(bash "$SCRIPT_UNDER_TEST" help 2>&1)
	if echo "$output" | grep -q "stop"; then
		pass "help output includes 'stop' command"
	else
		fail "help output includes 'stop' command" "Output missing 'stop'"
	fi
	if echo "$output" | grep -q "restart"; then
		pass "help output includes 'restart' command"
	else
		fail "help output includes 'restart' command" "Output missing 'restart'"
	fi
	return 0
}

test_help_includes_stop_restart

# ============================================================================
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped (${TOTAL_COUNT} total)"
echo ""

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi
exit 0
