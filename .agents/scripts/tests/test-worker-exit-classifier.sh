#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# test-worker-exit-classifier.sh — Exercise classify_worker_exit (GH#20564)
# =============================================================================
# Covers all four classification paths:
#   1. signal_killed:<signum>   — wait_status > 128
#   2. crash_during_startup     — non-zero exit, no session in DB
#   3. crash_during_execution   — non-zero exit, session exists in DB
#   4. process_exit (fallback)  — classifier fails (corrupt/missing DB)
# And: clean exit (wait_status == 0)
#
# Usage: bash tests/test-worker-exit-classifier.sh

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

assert_eq() {
	local test_name="$1"
	local got="$2"
	local want="$3"
	if [[ "$got" == "$want" ]]; then
		print_result "$test_name" 0
	else
		print_result "$test_name" 1 "got='${got}' want='${want}'"
	fi
	return 0
}

setup() {
	TMPDIR_TEST=$(mktemp -d)
	# Provide stub shared-constants.sh functions (print_warning/print_info)
	# so headless-runtime-failure.sh can be sourced without shared-constants.sh
	print_warning() { return 0; }
	print_info()    { return 0; }
	export -f print_warning print_info

	# Source the target file
	# shellcheck source=../headless-runtime-failure.sh
	source "${AGENTS_SCRIPTS}/headless-runtime-failure.sh"
	return 0
}

teardown() {
	[[ -n "$TMPDIR_TEST" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST" || true
	return 0
}

_make_db() {
	local db_path="$1"
	sqlite3 "$db_path" \
		"CREATE TABLE IF NOT EXISTS session (id TEXT, title TEXT, time_created INTEGER);" \
		2>/dev/null
	return 0
}

_insert_session() {
	local db_path="$1"
	local ts_ms="$2"
	sqlite3 "$db_path" \
		"INSERT INTO session VALUES ('test-id-$(date +%s%N)', 'test session', ${ts_ms});" \
		2>/dev/null
	return 0
}

_now_ms() {
	python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0"
	return 0
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_signal_killed_sigterm() {
	# SIGTERM = 15; bash exit status = 128 + 15 = 143
	local result
	result=$(classify_worker_exit 143 0)
	assert_eq "signal_killed:SIGTERM (status=143)" "$result" "signal_killed:15"
	return 0
}

test_signal_killed_sigkill() {
	# SIGKILL = 9; bash exit status = 128 + 9 = 137
	local result
	result=$(classify_worker_exit 137 0)
	assert_eq "signal_killed:SIGKILL (status=137)" "$result" "signal_killed:9"
	return 0
}

test_signal_killed_sighup() {
	# SIGHUP = 1; bash exit status = 128 + 1 = 129
	local result
	result=$(classify_worker_exit 129 0)
	assert_eq "signal_killed:SIGHUP (status=129)" "$result" "signal_killed:1"
	return 0
}

test_clean_exit() {
	local result
	result=$(classify_worker_exit 0 0)
	assert_eq "clean exit (status=0)" "$result" "clean"
	return 0
}

test_crash_during_startup_empty_db() {
	# Non-zero exit, DB exists but has no sessions
	local db_path="${TMPDIR_TEST}/empty.db"
	_make_db "$db_path"
	local start_ms
	start_ms=$(_now_ms)

	_WORKER_ISOLATED_DB_PATH="$db_path"
	local result
	result=$(classify_worker_exit 1 "$start_ms")
	unset _WORKER_ISOLATED_DB_PATH

	assert_eq "crash_during_startup (empty DB)" "$result" "crash_during_startup"
	return 0
}

test_crash_during_startup_no_db() {
	# Non-zero exit, no DB at all — sqlite3 cannot find any DB
	local nonexistent_db="${TMPDIR_TEST}/nonexistent/opencode.db"
	_WORKER_ISOLATED_DB_PATH="$nonexistent_db"
	# Also shadow shared DB by using HOME pointing at non-existent dir
	local result
	result=$(HOME="${TMPDIR_TEST}/nohome" classify_worker_exit 1 0)
	unset _WORKER_ISOLATED_DB_PATH

	# When neither isolated nor shared DB exist, falls back to process_exit
	assert_eq "crash_during_startup fallback (no DB → process_exit)" "$result" "process_exit"
	return 0
}

test_crash_during_execution_session_in_db() {
	# Non-zero exit, session created after worker start → crash_during_execution
	local db_path="${TMPDIR_TEST}/execution.db"
	_make_db "$db_path"

	local start_ms
	start_ms=$(_now_ms)
	# Insert a session AFTER start time
	_insert_session "$db_path" "$start_ms"

	_WORKER_ISOLATED_DB_PATH="$db_path"
	local result
	result=$(classify_worker_exit 1 "$start_ms")
	unset _WORKER_ISOLATED_DB_PATH

	assert_eq "crash_during_execution (session after start)" "$result" "crash_during_execution"
	return 0
}

test_crash_during_startup_session_before_start() {
	# Non-zero exit, session EXISTS but was created BEFORE this worker started
	# → should be crash_during_startup (session_count == 0 for this worker's window)
	local db_path="${TMPDIR_TEST}/before-start.db"
	_make_db "$db_path"

	# Insert session with timestamp 10 seconds in the past
	local old_ts=$(( $(_now_ms) - 10000 ))
	_insert_session "$db_path" "$old_ts"

	# Worker "start" is now (after the old session)
	local start_ms
	start_ms=$(_now_ms)

	_WORKER_ISOLATED_DB_PATH="$db_path"
	local result
	result=$(classify_worker_exit 1 "$start_ms")
	unset _WORKER_ISOLATED_DB_PATH

	assert_eq "crash_during_startup (session before worker start)" "$result" "crash_during_startup"
	return 0
}

test_classifier_failure_corrupt_db() {
	# Corrupt DB → sqlite3 returns error → process_exit fallback
	local bad_db="${TMPDIR_TEST}/corrupt.db"
	printf 'not a database\n' >"$bad_db"

	local start_ms
	start_ms=$(_now_ms)

	_WORKER_ISOLATED_DB_PATH="$bad_db"
	local result
	result=$(classify_worker_exit 1 "$start_ms")
	unset _WORKER_ISOLATED_DB_PATH

	assert_eq "classifier_failure (corrupt DB → process_exit)" "$result" "process_exit"
	return 0
}

test_no_start_time_empty_db() {
	# start_epoch_ms == 0 → uses count-all query (no time filter)
	# DB is empty → crash_during_startup
	local db_path="${TMPDIR_TEST}/no-start.db"
	_make_db "$db_path"

	_WORKER_ISOLATED_DB_PATH="$db_path"
	local result
	result=$(classify_worker_exit 1 0)
	unset _WORKER_ISOLATED_DB_PATH

	assert_eq "crash_during_startup (no start_ms, empty DB)" "$result" "crash_during_startup"
	return 0
}

test_no_start_time_with_sessions() {
	# start_epoch_ms == 0 → uses count-all query
	# DB has a session → crash_during_execution
	local db_path="${TMPDIR_TEST}/no-start-sessions.db"
	_make_db "$db_path"
	_insert_session "$db_path" "$(_now_ms)"

	_WORKER_ISOLATED_DB_PATH="$db_path"
	local result
	result=$(classify_worker_exit 1 0)
	unset _WORKER_ISOLATED_DB_PATH

	assert_eq "crash_during_execution (no start_ms, session in DB)" "$result" "crash_during_execution"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	setup
	trap teardown EXIT

	test_signal_killed_sigterm
	test_signal_killed_sigkill
	test_signal_killed_sighup
	test_clean_exit
	test_crash_during_startup_empty_db
	test_crash_during_startup_no_db
	test_crash_during_execution_session_in_db
	test_crash_during_startup_session_before_start
	test_classifier_failure_corrupt_db
	test_no_start_time_empty_db
	test_no_start_time_with_sessions

	printf '\n%d tests: %d passed, %d failed\n' \
		"$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
