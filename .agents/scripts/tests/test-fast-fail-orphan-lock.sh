#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-fast-fail-orphan-lock.sh — t2953 regression guard.
#
# Asserts that _ff_with_lock() detects and cleans empty lockdirs (no owner.pid)
# whose mtime exceeds FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS, preserving existing
# t2421 stale-pid detection and not cleaning young lockdirs (race protection).
#
# Production incident (GH#21197, t2953):
#   2026-04-27: An empty fast-fail-counter.json.lockdir with no owner.pid
#   reduced dispatch from 24 workers/cycle to 0-2 for ~50 minutes. The t2421
#   stale-pid detector never fired because _ff_owner_pid was empty (missing
#   file). Manual rmdir immediately restored full dispatch. This test prevents
#   regression of that fix.
#
# Tests (4):
#   1. Empty lockdir older than threshold → cleaned (lock acquired, rc=0)
#   2. Empty lockdir younger than threshold → NOT cleaned (race-protection,
#      lockdir still exists after short wait; then manually released so test
#      exits cleanly)
#   3. Lockdir with stale owner.pid → cleaned by t2421 path (existing behaviour)
#   4. Lockdir with live owner.pid → NOT cleaned (lock blocks until released)
#
# Stub strategy:
#   - Set FAST_FAIL_STATE_FILE to a tmpdir path so tests are hermetic.
#   - Set FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS=3 (short but safe for mtime tests).
#   - Stub _is_process_alive_and_matches via a flag variable for cases 3 & 4.
#   - Stub _compute_argv_hash and other helpers to silence noise.
#   - Set LOGFILE to a tmp path to capture log output.

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

# Use a 3s orphan age threshold: small enough to make "old" lockdirs easy to
# create (set mtime to now-10), large enough to protect young lockdirs.
export FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS=3

# Fast-fail state file — lockdir will be "${FAST_FAIL_STATE_FILE}.lockdir"
FAST_FAIL_STATE_FILE="${TMP}/fast-fail-counter.json"
export FAST_FAIL_STATE_FILE

# Required constants (unused by _ff_with_lock but sourced from pulse-fast-fail)
export FAST_FAIL_SKIP_THRESHOLD=5
export FAST_FAIL_EXPIRY_SECS=604800
export FAST_FAIL_INITIAL_BACKOFF_SECS=600
export FAST_FAIL_MAX_BACKOFF_SECS=604800
export FAST_FAIL_AGE_OUT_SECONDS=86400
export FAST_FAIL_AGE_OUT_MIN_COUNT=5
export FAST_FAIL_AGE_OUT_MAX_RESETS=3

# =============================================================================
# Stubs — defined before sourcing so the include guard doesn't prevent override
# =============================================================================

# Stub print_* to silence noise
print_info() { :; return 0; }
print_warning() { :; return 0; }
print_error() { :; return 0; }
print_success() { :; return 0; }
log_verbose() { :; return 0; }
export -f print_info print_warning print_error print_success log_verbose

# _STUB_IS_ALIVE: controls _is_process_alive_and_matches return value.
#   "true"  → returns 0 (process alive — do NOT clean the lock)
#   "false" → returns 1 (process dead — clean the stale lock)
_STUB_IS_ALIVE="false"

_is_process_alive_and_matches() {
	if [[ "$_STUB_IS_ALIVE" == "true" ]]; then
		return 0
	fi
	return 1
}
export -f _is_process_alive_and_matches

# Stub _compute_argv_hash — called on successful lock acquisition
_compute_argv_hash() {
	echo "stub-hash"
	return 0
}
export -f _compute_argv_hash

# Stub escalate_issue_tier (used by _fast_fail_record_locked)
escalate_issue_tier() {
	return 0
}
export -f escalate_issue_tier

# Stub gh (used by fast_fail_age_out etc.)
gh() {
	return 0
}
export -f gh

# Source shared-constants.sh for jq helpers, then pulse-fast-fail.sh
# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

# Re-define stubs AFTER shared-constants.sh so our stubs override any real
# definitions that shared-constants.sh provides (e.g. _is_process_alive_and_matches).
_is_process_alive_and_matches() {
	if [[ "$_STUB_IS_ALIVE" == "true" ]]; then
		return 0
	fi
	return 1
}
export -f _is_process_alive_and_matches

# shellcheck source=../pulse-fast-fail.sh
source "${SCRIPTS_DIR}/pulse-fast-fail.sh" >/dev/null 2>&1 || {
	printf '%sFATAL%s Could not source pulse-fast-fail.sh\n' "$TEST_RED" "$TEST_NC"
	exit 1
}

LOCK_DIR="${FAST_FAIL_STATE_FILE}.lockdir"

printf '%sRunning _ff_with_lock orphan-lock tests (t2953)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1 — Empty lockdir older than threshold → cleaned, lock acquired (rc=0)
# =============================================================================
# Create an empty lockdir (no owner.pid), then set its mtime to 10 seconds ago
# (> 3s threshold). _ff_with_lock should detect the orphan, clean it, acquire
# the lock, and return 0.
rm -rf "$LOCK_DIR"
mkdir "$LOCK_DIR"
python3 -c "
import os, time
path = '${LOCK_DIR}'
t = time.time() - 10
os.utime(path, (t, t))
" 2>/dev/null || true

lock_rc=0
_ff_with_lock true 2>/dev/null || lock_rc=$?

log_content=$(cat "$LOGFILE" 2>/dev/null || true)

if [[ "$lock_rc" -eq 0 ]]; then
	pass "empty lockdir older than threshold (10s > 3s) → lock acquired (rc=0)"
else
	fail "empty lockdir older than threshold (10s > 3s) → lock acquired (rc=0)" \
		"expected rc=0, got rc=${lock_rc}"
fi

if printf '%s' "$log_content" | grep -q "clearing orphan lock"; then
	pass "orphan cleanup logged (t2953 message present)"
else
	fail "orphan cleanup logged (t2953 message present)" \
		"expected 'clearing orphan lock' in log; log=${log_content}"
fi

# Lockdir should be gone (cleaned up after successful lock release)
if [[ ! -d "$LOCK_DIR" ]]; then
	pass "lockdir removed after lock release"
else
	fail "lockdir removed after lock release" "lockdir still exists after successful _ff_with_lock"
	rmdir "$LOCK_DIR" 2>/dev/null || true
fi

# =============================================================================
# Test 2 — Empty lockdir younger than threshold → NOT cleaned (race protection)
# =============================================================================
# Create an empty lockdir with mtime=now (fresh). _ff_with_lock should NOT clean
# it immediately. We verify by running the function in background, checking the
# lockdir still exists after 0.3s, then manually removing it so the background
# function can acquire the lock and exit.
: >"$LOGFILE"
rm -rf "$LOCK_DIR"
mkdir "$LOCK_DIR"
# mtime defaults to now — no touch needed

bg_rc=0
_ff_with_lock true 2>/dev/null &
bg_pid=$!

sleep 0.3

# Lockdir should still exist (young orphan not cleaned)
if [[ -d "$LOCK_DIR" ]]; then
	pass "empty lockdir younger than threshold → NOT cleaned (race protection intact)"
else
	fail "empty lockdir younger than threshold → NOT cleaned (race protection intact)" \
		"lockdir was prematurely removed (young orphan should not be cleaned)"
fi

log_content=$(cat "$LOGFILE" 2>/dev/null || true)
if ! printf '%s' "$log_content" | grep -q "clearing orphan lock"; then
	pass "no premature orphan-cleanup log for young lockdir"
else
	fail "no premature orphan-cleanup log for young lockdir" \
		"orphan cleanup fired for a young lockdir: ${log_content}"
fi

# Release the lockdir so the background function can proceed (avoids hung test)
rmdir "$LOCK_DIR" 2>/dev/null || true
wait "$bg_pid" 2>/dev/null || true

# =============================================================================
# Test 3 — Lockdir with stale owner.pid → cleaned by t2421 path (existing)
# =============================================================================
# Write a non-existent PID to owner.pid. _is_process_alive_and_matches is
# stubbed to return 1 (dead). The t2421 path should clear the lock.
: >"$LOGFILE"
rm -rf "$LOCK_DIR"
mkdir "$LOCK_DIR"
printf '%s|%s\n' "99999999" "stub-hash" >"${LOCK_DIR}/owner.pid"
_STUB_IS_ALIVE="false"

lock_rc=0
_ff_with_lock true 2>/dev/null || lock_rc=$?

log_content=$(cat "$LOGFILE" 2>/dev/null || true)

if [[ "$lock_rc" -eq 0 ]]; then
	pass "lockdir with stale owner.pid → t2421 path clears lock, rc=0"
else
	fail "lockdir with stale owner.pid → t2421 path clears lock, rc=0" \
		"expected rc=0, got rc=${lock_rc}"
fi

if printf '%s' "$log_content" | grep -q "clearing stale lock"; then
	pass "t2421 stale-lock message logged (existing behaviour preserved)"
else
	fail "t2421 stale-lock message logged (existing behaviour preserved)" \
		"expected 'clearing stale lock' in log; log=${log_content}"
fi

# =============================================================================
# Test 4 — Lockdir with live owner.pid → NOT cleaned (lock held until release)
# =============================================================================
# Write $$ to owner.pid and stub _is_process_alive_and_matches to return 0
# (alive). _ff_with_lock should block. We run it in background, verify the
# lockdir still exists after 0.3s (i.e., the function is blocking), then
# remove the lockdir to let the function acquire and release.
: >"$LOGFILE"
rm -rf "$LOCK_DIR"
mkdir "$LOCK_DIR"
printf '%s|%s\n' "$$" "stub-hash" >"${LOCK_DIR}/owner.pid"
_STUB_IS_ALIVE="true"

bg_rc=0
_ff_with_lock true 2>/dev/null &
bg_pid=$!

sleep 0.3

# Lockdir must still exist (live lock not cleaned)
if [[ -d "$LOCK_DIR" ]]; then
	pass "lockdir with live owner.pid → NOT cleaned (lock held)"
else
	fail "lockdir with live owner.pid → NOT cleaned (lock held)" \
		"lockdir was unexpectedly removed while owner PID appears alive"
fi

log_content=$(cat "$LOGFILE" 2>/dev/null || true)
if ! printf '%s' "$log_content" | grep -q "clearing"; then
	pass "no stale/orphan cleanup log for live-owner lockdir"
else
	fail "no stale/orphan cleanup log for live-owner lockdir" \
		"unexpected cleanup log: ${log_content}"
fi

# Release: remove owner.pid and lockdir so background function can proceed
rm -f "${LOCK_DIR}/owner.pid" 2>/dev/null || true
rmdir "$LOCK_DIR" 2>/dev/null || true
wait "$bg_pid" 2>/dev/null || true

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
