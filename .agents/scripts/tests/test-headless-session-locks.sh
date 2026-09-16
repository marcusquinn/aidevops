#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Focused regression coverage for GH#31988 session-lock reconciliation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT=""
SLEEP_PIDS=""
STARTED_PID=""

cleanup() {
	local pid=""
	for pid in $SLEEP_PIDS; do
		kill "$pid" 2>/dev/null || true
	done
	[[ -z "$TEST_ROOT" || ! -d "$TEST_ROOT" ]] || rm -rf "$TEST_ROOT"
	return 0
}

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

assert_file() {
	[[ -f "$1" ]] || fail "expected file: $1"
}

assert_absent() {
	[[ ! -e "$1" ]] || fail "expected absent path: $1"
}

start_sleep() {
	sleep 30 &
	STARTED_PID=$!
	SLEEP_PIDS="${SLEEP_PIDS} ${STARTED_PID}"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	export HOME="$TEST_ROOT"
	export AIDEVOPS_HEADLESS_RUNTIME_DIR="${TEST_ROOT}/runtime"
	export AIDEVOPS_SESSION_LOCK_MALFORMED_GRACE_SECONDS=60
	export LOGFILE="${TEST_ROOT}/pulse.log"
	LOCK_DIR="${AIDEVOPS_HEADLESS_RUNTIME_DIR}/locks"
	mkdir -p "$LOCK_DIR"

	# shellcheck source=../shared-constants.sh
	source "${SCRIPT_DIR}/../shared-constants.sh"
	# shellcheck source=../headless-session-locks.sh
	source "${SCRIPT_DIR}/../headless-session-locks.sh"
	WORKER_PROCESS_PATTERN='test-headless-session-locks|bash|sleep'

	local own_lock="${LOCK_DIR}/issue-own.pid"
	_acquire_session_lock "issue-own" || fail "initial acquisition failed"
	assert_file "$own_lock"
	if _acquire_session_lock "issue-own"; then
		fail "duplicate acquisition was not blocked"
	fi
	_release_session_lock "issue-own" || fail "owner release failed"
	assert_absent "$own_lock"

	local dead_lock="${LOCK_DIR}/issue-dead.pid"
	printf '99999999|000000000000' >"$dead_lock"
	cleanup_stale_session_locks || fail "dead-owner sweep failed"
	assert_absent "$dead_lock"

	local live_pid="" live_hash="" live_lock="${LOCK_DIR}/issue-live.pid"
	start_sleep
	live_pid="$STARTED_PID"
	live_hash=$(_compute_argv_hash "$live_pid")
	printf '%s|%s' "$live_pid" "$live_hash" >"$live_lock"
	cleanup_stale_session_locks || fail "live-owner sweep failed"
	assert_file "$live_lock"

	local reused_lock="${LOCK_DIR}/issue-reused.pid"
	printf '%s|000000000000' "$live_pid" >"$reused_lock"
	cleanup_stale_session_locks || fail "recycled-owner sweep failed"
	assert_absent "$reused_lock"

	local legacy_lock="${LOCK_DIR}/issue-legacy.pid"
	printf '%s' "$live_pid" >"$legacy_lock"
	cleanup_stale_session_locks || fail "legacy-owner sweep failed"
	assert_file "$legacy_lock"

	local malformed_lock="${LOCK_DIR}/issue-malformed.pid"
	printf 'not-a-pid' >"$malformed_lock"
	cleanup_stale_session_locks || fail "young malformed sweep failed"
	assert_file "$malformed_lock"
	touch -t 200001010000 "$malformed_lock"
	cleanup_stale_session_locks || fail "aged malformed sweep failed"
	assert_absent "$malformed_lock"

	local active_malformed_lock="${LOCK_DIR}/issue-active-malformed.pid"
	printf '%s|invalid-hash' "$live_pid" >"$active_malformed_lock"
	touch -t 200001010000 "$active_malformed_lock"
	cleanup_stale_session_locks || fail "active malformed sweep failed"
	assert_file "$active_malformed_lock"

	local changed_lock="${LOCK_DIR}/issue-changed.pid"
	printf '111|aaaaaaaaaaaa' >"$changed_lock"
	if _session_lock_remove_snapshot "$changed_lock" '222|bbbbbbbbbbbb'; then
		fail "snapshot mismatch removed replacement lock"
	else
		[[ "$?" -eq 2 ]] || fail "snapshot mismatch returned wrong status"
	fi
	assert_file "$changed_lock"

	local bounded_dir="${TEST_ROOT}/bounded-locks"
	mkdir -p "$bounded_dir"
	local index=""
	for index in 1 2 3; do
		printf '9999999%s|000000000000' "$index" >"${bounded_dir}/bounded-${index}.pid"
	done
	AIDEVOPS_SESSION_LOCK_SWEEP_MAX=2 cleanup_stale_session_locks "$bounded_dir" || fail "bounded sweep failed"
	local remaining=0
	for changed_lock in "${bounded_dir}"/bounded-*.pid; do
		[[ -f "$changed_lock" ]] || continue
		remaining=$((remaining + 1))
	done
	[[ "$remaining" -eq 1 ]] || fail "bounded sweep removed ${remaining} complement files; expected one remaining"
	AIDEVOPS_SESSION_LOCK_SWEEP_MAX=2 cleanup_stale_session_locks "$bounded_dir" || fail "bounded follow-up sweep failed"
	for changed_lock in "${bounded_dir}"/bounded-*.pid; do
		[[ ! -f "$changed_lock" ]] || fail "cursor did not reach remaining bounded lock"
	done
	cleanup_stale_session_locks "$bounded_dir" || fail "idempotent follow-up sweep failed"

	# A temporary hash read failure must preserve an otherwise matching live owner.
	(
		_compute_argv_hash() { return 1; }
		cleanup_stale_session_locks
	) || fail "hash-unavailable sweep failed closed"
	assert_file "$live_lock"

	printf 'PASS: headless session locks reconcile stale owners and preserve live ownership\n'
	return 0
}

main "$@"
