#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-fast-fail-orphan-lock.sh — t2953 regression guard.
#
# Asserts that _ff_with_lock() detects and clears empty lockdirs (no owner.pid)
# that are older than FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS, while preserving the
# existing t2421 stale-pid path and protecting genuinely-live locks.
#
# Root cause (t2953, observed 2026-04-27):
#   A process SIGKILL'd between mkdir(lockdir) and printf >owner.pid leaves a
#   permanent empty lockdir. Every subsequent _ff_with_lock call times out after
#   50 retries × 0.1s = 5s, suppressing all dispatches. Manual rmdir restores
#   full throughput immediately (4 PRs auto-merged within 8 minutes).
#
#   Empirical impact: ~50 minutes of degraded dispatch (~20+ missing dispatches).
#   Worker capacity dropped from 24/cycle to 0-2/cycle — >90% throughput loss.
#
# Tests (4):
#   1. Empty lockdir older than threshold → cleaned, function succeeds (rc=0)
#   2. Empty lockdir younger than threshold → NOT cleaned (race protection)
#   3. Lockdir with stale owner.pid → cleaned (existing t2421 behaviour preserved)
#   4. Lockdir with live owner.pid → NOT cleaned (existing behaviour preserved)
#
# Stub strategy:
#   - Set FAST_FAIL_STATE_FILE to a tmpdir path so tests are hermetic.
#   - Override FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS to a small value (2s) so we can
#     set mtime in the past and satisfy/fail the age condition without sleeping.
#   - Stub _is_process_alive_and_matches to control liveness outcome for test 3/4.
#   - Set LOGFILE to a tmp path to capture log output.
#   - Use `touch -t` (macOS) / `touch -d` (Linux) to set lockdir mtime.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2953.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
export LOGFILE

# Use a 2-second orphan threshold so we can set mtime 5s in the past (> threshold)
# or 0s in the past (< threshold) without sleeping.
export FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS=2

FAST_FAIL_STATE_FILE="${TMP}/fast-fail-counter.json"
export FAST_FAIL_STATE_FILE

# lock_dir is derived from FAST_FAIL_STATE_FILE in _ff_with_lock
LOCK_DIR="${FAST_FAIL_STATE_FILE}.lockdir"

# =============================================================================
# Stubs — defined before sourcing so include guard doesn't prevent override
# =============================================================================

# Silence noise from shared-constants.sh and pulse-fast-fail.sh print helpers
print_info() { :; return 0; }
print_warning() { :; return 0; }
print_error() { :; return 0; }
print_success() { :; return 0; }
log_verbose() { :; return 0; }
export -f print_info print_warning print_error print_success log_verbose

# _compute_argv_hash stub: return empty string (hash not needed for lock tests)
_compute_argv_hash() { echo ""; return 0; }
export -f _compute_argv_hash

# Source shared-constants.sh to get any required helpers
# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

# gh stub: record calls without hitting the API
gh() {
	printf '%s\n' "$*" >>"${TMP}/gh_calls.log"
	return 0
}
export -f gh

# _is_process_alive_and_matches stub: controlled via IS_PROCESS_ALIVE_RESULT env var
# Default is "alive" (return 0). Set to "dead" to simulate stale-pid condition.
IS_PROCESS_ALIVE_RESULT="${IS_PROCESS_ALIVE_RESULT:-alive}"
_is_process_alive_and_matches() {
	[[ "$IS_PROCESS_ALIVE_RESULT" == "alive" ]]
	return $?
}
export -f _is_process_alive_and_matches

# Source fast-fail module (include guard prevents double-source)
# shellcheck source=../pulse-fast-fail.sh
source "${SCRIPTS_DIR}/pulse-fast-fail.sh" >/dev/null 2>&1 || {
	printf '%sFATAL%s Could not source pulse-fast-fail.sh\n' "$TEST_RED" "$TEST_NC"
	exit 1
}

printf '%sRunning _ff_with_lock orphan-lock tests (t2953)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Helper: set a directory's mtime to N seconds ago
# Supports both macOS (stat -f) and Linux (touch -d).
# =============================================================================
_set_mtime_ago() {
	local dir="$1"
	local seconds_ago="$2"
	# macOS: touch -t YYYYMMDDhhmm.ss
	# Linux: touch -d "N seconds ago"
	if touch -d "${seconds_ago} seconds ago" "$dir" 2>/dev/null; then
		return 0
	fi
	# macOS fallback: compute the timestamp manually
	local ts
	ts=$(date -v "-${seconds_ago}S" '+%Y%m%d%H%M.%S' 2>/dev/null) || {
		# Neither worked — skip mtime adjustment (test may not behave as expected)
		return 1
	}
	touch -t "$ts" "$dir"
	return 0
}

# =============================================================================
# Test 1 — Empty lockdir older than threshold → cleaned, function succeeds
# =============================================================================
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
# No owner.pid written — simulate SIGKILL during mkdir→printf window
# Set mtime to 5 seconds ago (> FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS=2)
if ! _set_mtime_ago "$LOCK_DIR" 5; then
	printf '  %sSKIP%s Test 1 — cannot set mtime on this platform\n' "$TEST_BLUE" "$TEST_NC"
else
	rc=0
	_ff_with_lock true 2>/dev/null || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		pass "Empty lockdir older than threshold → cleaned and lock acquired (rc=0)"
	else
		fail "Empty lockdir older than threshold → cleaned and lock acquired (rc=0)" \
			"got rc=${rc}"
	fi
	# Log should contain the t2953 cleanup message
	log_content=$(cat "$LOGFILE" 2>/dev/null || true)
	if printf '%s' "$log_content" | grep -q "t2953"; then
		pass "Log contains t2953 orphan-cleanup message"
	else
		fail "Log contains t2953 orphan-cleanup message" \
			"LOGFILE content: ${log_content}"
	fi
fi

# =============================================================================
# Test 2 — Empty lockdir younger than threshold → NOT cleaned (race protection)
# =============================================================================
: >"$LOGFILE"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
# No owner.pid — but mtime is NOW (0 seconds old, < 2s threshold)
# Use timeout to avoid the full 50×0.1s=5s retry loop
rc=0
timeout 0.5 bash -c "
	export FAST_FAIL_STATE_FILE='${FAST_FAIL_STATE_FILE}'
	export FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS=${FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS}
	export LOGFILE='${LOGFILE}'
	_compute_argv_hash() { echo ''; return 0; }
	_is_process_alive_and_matches() { return 0; }
	export -f _compute_argv_hash _is_process_alive_and_matches
	print_info() { :; } print_warning() { :; } print_error() { :; }
	print_success() { :; } log_verbose() { :; }
	export -f print_info print_warning print_error print_success log_verbose
	source '${SCRIPTS_DIR}/shared-constants.sh' >/dev/null 2>&1 || true
	source '${SCRIPTS_DIR}/pulse-fast-fail.sh' >/dev/null 2>&1
	_ff_with_lock true
" 2>/dev/null || rc=$?

# The lockdir should still exist — orphan check must not have fired on young lock
if [[ -d "$LOCK_DIR" ]]; then
	pass "Empty lockdir younger than threshold → NOT cleaned (race protection)"
else
	fail "Empty lockdir younger than threshold → NOT cleaned (race protection)" \
		"lockdir was removed when it should have been preserved"
fi
# Cleanup for next test
rm -rf "$LOCK_DIR"

# =============================================================================
# Test 3 — Lockdir with stale owner.pid → cleaned (t2421 behaviour preserved)
# =============================================================================
: >"$LOGFILE"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
# Write a non-existent PID to owner.pid (simulate dead previous owner)
printf '%s|\n' "99999999" >"${LOCK_DIR}/owner.pid"

# Configure stub to report the process as dead
IS_PROCESS_ALIVE_RESULT="dead"
export IS_PROCESS_ALIVE_RESULT

rc=0
_ff_with_lock true 2>/dev/null || rc=$?
if [[ "$rc" -eq 0 ]]; then
	pass "Stale owner.pid → t2421 path clears lock, function succeeds (rc=0)"
else
	fail "Stale owner.pid → t2421 path clears lock, function succeeds (rc=0)" \
		"got rc=${rc}"
fi
log_content=$(cat "$LOGFILE" 2>/dev/null || true)
if printf '%s' "$log_content" | grep -q "t2421"; then
	pass "Log contains t2421 stale-pid cleanup message"
else
	fail "Log contains t2421 stale-pid cleanup message" \
		"LOGFILE content: ${log_content}"
fi

# Reset stub to "alive"
IS_PROCESS_ALIVE_RESULT="alive"
export IS_PROCESS_ALIVE_RESULT

# =============================================================================
# Test 4 — Lockdir with live owner.pid → NOT cleaned (existing behaviour)
# =============================================================================
: >"$LOGFILE"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
# Write current shell's PID as owner (simulate live lock holder)
printf '%s|\n' "$$" >"${LOCK_DIR}/owner.pid"

# IS_PROCESS_ALIVE_RESULT="alive" (default, already reset above)
# Run with timeout — the function should block (lock is held by a "live" owner)
rc=0
timeout 0.5 bash -c "
	export FAST_FAIL_STATE_FILE='${FAST_FAIL_STATE_FILE}'
	export FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS=${FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS}
	export LOGFILE='${LOGFILE}'
	_compute_argv_hash() { echo ''; return 0; }
	_is_process_alive_and_matches() { return 0; }  # live
	export -f _compute_argv_hash _is_process_alive_and_matches
	print_info() { :; } print_warning() { :; } print_error() { :; }
	print_success() { :; } log_verbose() { :; }
	export -f print_info print_warning print_error print_success log_verbose
	source '${SCRIPTS_DIR}/shared-constants.sh' >/dev/null 2>&1 || true
	source '${SCRIPTS_DIR}/pulse-fast-fail.sh' >/dev/null 2>&1
	_ff_with_lock true
" 2>/dev/null || rc=$?

# owner.pid should still exist — live lock must NOT be cleaned
if [[ -f "${LOCK_DIR}/owner.pid" ]]; then
	pass "Live owner.pid → lock NOT cleaned (existing protection preserved)"
else
	fail "Live owner.pid → lock NOT cleaned (existing protection preserved)" \
		"owner.pid was removed — live lock was incorrectly cleared"
fi
# Cleanup
rm -rf "$LOCK_DIR"

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
