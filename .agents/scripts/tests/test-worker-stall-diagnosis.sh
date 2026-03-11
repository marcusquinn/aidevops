#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
WATCHDOG_SCRIPT="${SCRIPT_DIR}/../worker-watchdog.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	export OPENCODE_DB_PATH="${HOME}/opencode.db"
	export WORKER_PROGRESS_TIMEOUT=120
	export WORKER_WATCHDOG_NOTIFY=false
	export WORKER_DRY_RUN=true
	mkdir -p "${HOME}/.aidevops/.agent-workspace/tmp/worker-idle-tracking"
	mkdir -p "${HOME}/.aidevops/logs"
	# shellcheck source=/dev/null
	source "$WATCHDOG_SCRIPT"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

reset_fixture() {
	rm -f "$OPENCODE_DB_PATH"
	rm -f "${IDLE_STATE_DIR}"/* 2>/dev/null || true
	return 0
}

seed_session_fixture() {
	local title="$1"
	local recent_message_age="$2"
	local tail_text="$3"
	local tail_age="$4"

	FIXTURE_DB_PATH="$OPENCODE_DB_PATH" \
		FIXTURE_TITLE="$title" \
		FIXTURE_RECENT_AGE="$recent_message_age" \
		FIXTURE_TAIL_TEXT="$tail_text" \
		FIXTURE_TAIL_AGE="$tail_age" \
		python3 - <<'PY'
import json
import os
import sqlite3
import time

db_path = os.environ["FIXTURE_DB_PATH"]
title = os.environ["FIXTURE_TITLE"]
recent_age = int(os.environ["FIXTURE_RECENT_AGE"])
tail_text = os.environ["FIXTURE_TAIL_TEXT"]
tail_age = int(os.environ["FIXTURE_TAIL_AGE"])
now = int(time.time())

conn = sqlite3.connect(db_path)
conn.executescript(
    """
    CREATE TABLE session (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        parent_id TEXT,
        slug TEXT NOT NULL,
        directory TEXT NOT NULL,
        title TEXT NOT NULL,
        version TEXT NOT NULL,
        share_url TEXT,
        summary_additions INTEGER,
        summary_deletions INTEGER,
        summary_files INTEGER,
        summary_diffs TEXT,
        revert TEXT,
        permission TEXT,
        time_created INTEGER NOT NULL,
        time_updated INTEGER NOT NULL,
        time_compacting INTEGER,
        time_archived INTEGER,
        workspace_id TEXT
    );
    CREATE TABLE message (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL,
        time_updated INTEGER NOT NULL,
        data TEXT NOT NULL
    );
    CREATE TABLE part (
        id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        time_created INTEGER NOT NULL,
        time_updated INTEGER NOT NULL,
        data TEXT NOT NULL
    );
    """
)
conn.execute(
    "INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ("session-1", "project-1", None, "session-1", "/tmp/aidevops", title, "0", now - 600, now),
)
conn.execute(
    "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
    ("message-tail", "session-1", now - tail_age, now - tail_age, json.dumps({"role": "assistant"})),
)
conn.execute(
    "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
    ("part-tail", "message-tail", "session-1", now - tail_age, now - tail_age, json.dumps({"type": "text", "text": tail_text})),
)
if recent_age >= 0:
    conn.execute(
        "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
        ("message-recent", "session-1", now - recent_age, now - recent_age, json.dumps({"role": "assistant"})),
    )
conn.commit()
conn.close()
PY
	return 0
}

assert_file_missing() {
	local path="$1"
	[[ ! -f "$path" ]]
	return 0
}

test_recent_message_clears_stall() {
	reset_fixture
	local cmd='opencode run --title "Issue #4136: Diagnose stalls" --dir /tmp/aidevops "/full-loop Implement issue #4136"'
	local pid="4101"
	local now
	now=$(date +%s)
	seed_session_fixture 'Issue #4136: Diagnose stalls' 30 'Still working through the issue.' 30
	echo $((now - 240)) >"${IDLE_STATE_DIR}/stall-${pid}"
	echo $((now - 120)) >"${IDLE_STATE_DIR}/stall-grace-${pid}"

	if check_progress_stall "$pid" "$cmd" 1800; then
		print_result "recent messages prevent stall kills" 1 "Expected in-progress result, got stalled"
		return 0
	fi

	if [[ -f "${IDLE_STATE_DIR}/stall-${pid}" || -f "${IDLE_STATE_DIR}/stall-grace-${pid}" ]]; then
		print_result "recent messages prevent stall kills" 1 "Expected stall tracking files to be cleared"
		return 0
	fi

	print_result "recent messages prevent stall kills" 0
	return 0
}

test_provider_waiting_gets_grace_window() {
	reset_fixture
	local cmd='opencode run --title "Issue #4136: Diagnose stalls" --dir /tmp/aidevops "/full-loop Implement issue #4136"'
	local pid="4102"
	local now
	now=$(date +%s)
	seed_session_fixture 'Issue #4136: Diagnose stalls' -1 'Retrying after provider rate limit response.' 240
	echo $((now - 240)) >"${IDLE_STATE_DIR}/stall-${pid}"

	if check_progress_stall "$pid" "$cmd" 1800; then
		print_result "provider waiting evidence gets one grace window" 1 "Expected grace deferral, got stalled"
		return 0
	fi

	if [[ "$STALL_EVIDENCE_CLASS" != "provider-waiting" || ! -f "${IDLE_STATE_DIR}/stall-grace-${pid}" ]]; then
		print_result "provider waiting evidence gets one grace window" 1 "Expected provider-waiting class with grace file"
		return 0
	fi

	print_result "provider waiting evidence gets one grace window" 0
	return 0
}

test_provider_waiting_kills_after_grace_expires() {
	reset_fixture
	local cmd='opencode run --title "Issue #4136: Diagnose stalls" --dir /tmp/aidevops "/full-loop Implement issue #4136"'
	local pid="4103"
	local now
	now=$(date +%s)
	seed_session_fixture 'Issue #4136: Diagnose stalls' -1 'Retrying after provider rate limit response.' 240
	echo $((now - 360)) >"${IDLE_STATE_DIR}/stall-${pid}"
	echo $((now - 240)) >"${IDLE_STATE_DIR}/stall-grace-${pid}"

	if ! check_progress_stall "$pid" "$cmd" 1800; then
		print_result "provider waiting evidence eventually kills after grace" 1 "Expected stalled result after grace expiry"
		return 0
	fi

	if [[ "$STALL_EVIDENCE_CLASS" != "provider-waiting" ]]; then
		print_result "provider waiting evidence eventually kills after grace" 1 "Expected provider-waiting classification"
		return 0
	fi

	print_result "provider waiting evidence eventually kills after grace" 0
	return 0
}

test_stalled_tail_is_reported() {
	reset_fixture
	local cmd='opencode run --title "Issue #4136: Diagnose stalls" --dir /tmp/aidevops "/full-loop Implement issue #4136"'
	local pid="4104"
	local now
	now=$(date +%s)
	seed_session_fixture 'Issue #4136: Diagnose stalls' -1 'Last visible update from the worker.' 300
	echo $((now - 300)) >"${IDLE_STATE_DIR}/stall-${pid}"

	if ! check_progress_stall "$pid" "$cmd" 1800; then
		print_result "generic stalled tails still kill" 1 "Expected stalled result for non-provider evidence"
		return 0
	fi

	if [[ "$STALL_EVIDENCE_CLASS" != "stalled" || "$STALL_EVIDENCE_SUMMARY" != *'Last visible update from the worker.'* ]]; then
		print_result "generic stalled tails still kill" 1 "Expected stalled evidence summary to include transcript tail"
		return 0
	fi

	print_result "generic stalled tails still kill" 0
	return 0
}

main() {
	setup_test_env
	test_recent_message_clears_stall
	test_provider_waiting_gets_grace_window
	test_provider_waiting_kills_after_grace_expires
	test_stalled_tail_is_reported
	teardown_test_env

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
