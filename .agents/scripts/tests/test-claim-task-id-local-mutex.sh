#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-local-mutex.sh — Unit tests for Phase 2 (t2568 / GH#20001)
#
# Tests the machine-local mkdir-based mutex added to claim-task-id-counter.sh:
#
#   1. Lock acquire/release round-trip succeeds.
#   2. Stale-lock reclaim: lock dir with dead-PID file is cleared and acquired.
#   3. Timeout fallthrough: if lock is held, blocked caller gives up after
#      CAS_LOCAL_LOCK_TIMEOUT_S and returns 1 (proceeds unlocked in allocate_online).
#
# Requires: bash 4+, the claim-task-id-counter.sh sub-library.
#
# Usage: bash .agents/scripts/tests/test-claim-task-id-local-mutex.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
COUNTER_LIB="${SCRIPT_DIR}/../claim-task-id-counter.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# ---------------------------------------------------------------------------
# Guard: library must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$COUNTER_LIB" ]]; then
	printf '%s[FAIL]%s counter library not found: %s\n' "$RED" "$NC" "$COUNTER_LIB"
	exit 1
fi

# ---------------------------------------------------------------------------
# Minimal stubs for shared-constants.sh dependencies that may not be sourced.
# These cover the log_* functions used by the counter lib.
# ---------------------------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
	log_info()    { return 0; }
	log_warn()    { return 0; }
	log_error()   { printf '[ERROR] %s\n' "$*" >&2; return 0; }
	log_success() { return 0; }
fi

# Provide minimal globals that the counter lib references at source time.
REMOTE_NAME="${REMOTE_NAME:-origin}"
COUNTER_BRANCH="${COUNTER_BRANCH:-main}"
COUNTER_FILE="${COUNTER_FILE:-.task-counter}"
CAS_MAX_RETRIES="${CAS_MAX_RETRIES:-3}"
CAS_WALL_TIMEOUT_S="${CAS_WALL_TIMEOUT_S:-10}"
CAS_GIT_CMD_TIMEOUT_S="${CAS_GIT_CMD_TIMEOUT_S:-15}"
CAS_EXHAUSTION_FATAL="${CAS_EXHAUSTION_FATAL:-1}"
OFFLINE_OFFSET="${OFFLINE_OFFSET:-1000}"

# ---------------------------------------------------------------------------
# Isolated lock directory for all tests in this run
# ---------------------------------------------------------------------------
TEST_LOCK_BASE="$(mktemp -d "/tmp/claim-mutex-test.XXXXXX")"
export CAS_LOCAL_LOCK_DIR="$TEST_LOCK_BASE"
export CAS_LOCAL_LOCK_TIMEOUT_S=2   # Short timeout so tests run fast

# Source the library (functions only, no side effects — include guard fires)
# shellcheck source=/dev/null
source "$COUNTER_LIB"

cleanup() {
	rm -rf "$TEST_LOCK_BASE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test 1: Basic acquire / release round-trip
# ---------------------------------------------------------------------------
test_acquire_release() {
	local name="acquire/release round-trip"

	# Acquire should succeed on clean state
	if ! _cas_acquire_local_lock; then
		fail "$name" "_cas_acquire_local_lock returned non-zero on clean lock dir"
		return 0
	fi

	local lock_dir
	lock_dir=$(_cas_local_lock_path)

	# Lock dir must exist after acquire
	if [[ ! -d "$lock_dir" ]]; then
		fail "$name" "lock dir not created: $lock_dir"
		_cas_release_local_lock
		return 0
	fi

	# PID file must exist and contain our PID
	local pid_file="${lock_dir}/pid"
	if [[ ! -f "$pid_file" ]]; then
		fail "$name" "pid file missing: $pid_file"
		_cas_release_local_lock
		return 0
	fi

	local stored_pid
	stored_pid=$(cat "$pid_file" 2>/dev/null || echo "")
	if [[ "$stored_pid" != "${BASHPID:-$$}" && "$stored_pid" != "$$" ]]; then
		fail "$name" "pid file contains '$stored_pid', expected '${BASHPID:-$$}' or '$$'"
		_cas_release_local_lock
		return 0
	fi

	# Release must remove the lock dir
	_cas_release_local_lock

	if [[ -d "$lock_dir" ]]; then
		fail "$name" "lock dir still exists after release: $lock_dir"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: Stale-lock reclaim — dead PID in pidfile
# ---------------------------------------------------------------------------
test_stale_lock_reclaim() {
	local name="stale-lock reclaim (dead PID)"

	local lock_dir
	lock_dir=$(_cas_local_lock_path)

	# Create a lock dir with a dead-process PID (PID 1 is always alive on Linux,
	# but we pick a very high PID that is almost certainly not running, and if
	# it is alive, we skip gracefully rather than fail.)
	mkdir -p "$lock_dir"
	local dead_pid=999999
	printf '%s' "$dead_pid" > "${lock_dir}/pid"

	# Confirm the PID is actually dead — if it's alive, skip the test (edge case)
	if kill -0 "$dead_pid" 2>/dev/null; then
		rm -rf "$lock_dir"
		printf '[SKIP] %s — PID %s happened to be alive; skipping\n' "$name" "$dead_pid"
		return 0
	fi

	# _cas_acquire_local_lock must detect the dead PID and reclaim the lock
	if ! _cas_acquire_local_lock; then
		fail "$name" "_cas_acquire_local_lock failed to reclaim stale lock (dead PID $dead_pid)"
		rm -rf "$lock_dir"
		return 0
	fi

	# Verify we now own the lock
	if [[ ! -d "$lock_dir" ]]; then
		fail "$name" "lock dir missing after stale-lock reclaim"
		return 0
	fi

	_cas_release_local_lock
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: Timeout fallthrough — lock held by live process
# ---------------------------------------------------------------------------
test_timeout_fallthrough() {
	local name="timeout fallthrough (lock held by live process)"

	local lock_dir
	lock_dir=$(_cas_local_lock_path)

	# Hold the lock in a background subshell for longer than the timeout.
	# The subshell releases the lock when killed.
	mkdir -p "$lock_dir"
	printf '%s' "$$" > "${lock_dir}/pid"

	# Background holder: keeps the lock until killed
	(
		# Re-acquire under a live PID (us) so stale reclaim never fires
		while true; do
			sleep 0.1
		done
	) &
	local holder_pid=$!

	# Record start time; _cas_acquire_local_lock should fail within ~CAS_LOCAL_LOCK_TIMEOUT_S
	local t_start
	t_start=$(date +%s)

	local acquired=0
	_cas_acquire_local_lock && acquired=1

	local t_end
	t_end=$(date +%s)
	local elapsed=$(( t_end - t_start ))

	# Clean up holder and lock dir
	kill "$holder_pid" 2>/dev/null || true
	wait "$holder_pid" 2>/dev/null || true
	rm -rf "$lock_dir"

	# The acquire must have failed (returned 1)
	if [[ "$acquired" -eq 1 ]]; then
		fail "$name" "_cas_acquire_local_lock returned 0 while lock was held by live PID $$"
		return 0
	fi

	# Must have waited at least CAS_LOCAL_LOCK_TIMEOUT_S and not hugely longer
	if [[ "$elapsed" -lt "$CAS_LOCAL_LOCK_TIMEOUT_S" ]]; then
		fail "$name" "timeout elapsed in ${elapsed}s, expected >= ${CAS_LOCAL_LOCK_TIMEOUT_S}s"
		return 0
	fi

	local max_acceptable=$(( CAS_LOCAL_LOCK_TIMEOUT_S + 3 ))
	if [[ "$elapsed" -gt "$max_acceptable" ]]; then
		fail "$name" "timeout took ${elapsed}s (> max acceptable ${max_acceptable}s) — possible deadlock"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: Lock path is deterministic and repo-scoped
# ---------------------------------------------------------------------------
test_lock_path_deterministic() {
	local name="lock path is deterministic and safe"

	REMOTE_NAME="origin" COUNTER_BRANCH="main"
	local path1
	path1=$(_cas_local_lock_path)

	local path2
	path2=$(_cas_local_lock_path)

	if [[ "$path1" != "$path2" ]]; then
		fail "$name" "lock path is non-deterministic: '$path1' vs '$path2'"
		return 0
	fi

	# Path must be under CAS_LOCAL_LOCK_DIR
	if [[ "$path1" != "${CAS_LOCAL_LOCK_DIR}/"* ]]; then
		fail "$name" "lock path '$path1' is not under CAS_LOCAL_LOCK_DIR='${CAS_LOCAL_LOCK_DIR}'"
		return 0
	fi

	# Path must not contain characters that break shell quoting or mkdir
	if printf '%s' "$path1" | grep -qE '[[:space:]$`]'; then
		fail "$name" "lock path contains unsafe chars: '$path1'"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Lock path differs across remote+branch combinations
# ---------------------------------------------------------------------------
test_lock_path_scoped_per_remote_branch() {
	local name="lock path is scoped per remote+branch"

	local old_remote="$REMOTE_NAME"
	local old_branch="$COUNTER_BRANCH"

	REMOTE_NAME="origin"  COUNTER_BRANCH="main"
	local path_origin_main; path_origin_main=$(_cas_local_lock_path)

	REMOTE_NAME="upstream" COUNTER_BRANCH="main"
	local path_upstream_main; path_upstream_main=$(_cas_local_lock_path)

	REMOTE_NAME="origin"  COUNTER_BRANCH="dev"
	local path_origin_dev; path_origin_dev=$(_cas_local_lock_path)

	REMOTE_NAME="$old_remote"
	COUNTER_BRANCH="$old_branch"

	if [[ "$path_origin_main" == "$path_upstream_main" ]]; then
		fail "$name" "origin/main and upstream/main share a lock path: '$path_origin_main'"
		return 0
	fi

	if [[ "$path_origin_main" == "$path_origin_dev" ]]; then
		fail "$name" "origin/main and origin/dev share a lock path: '$path_origin_main'"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
printf '\n=== test-claim-task-id-local-mutex.sh ===\n\n'

test_acquire_release
test_stale_lock_reclaim
test_timeout_fallthrough
test_lock_path_deterministic
test_lock_path_scoped_per_remote_branch

printf '\n'
if [[ "$FAIL" -eq 0 ]]; then
	printf '%s[OK]%s %d passed, %d failed\n' "$GREEN" "$NC" "$PASS" "$FAIL"
	exit 0
else
	printf '%s[FAIL]%s %d passed, %d failed\n' "$RED" "$NC" "$PASS" "$FAIL"
	printf '%b\n' "$ERRORS"
	exit 1
fi
