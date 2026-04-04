#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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
	# Pre-set HEADLESS_RUNTIME_DB so the script picks it up at source time
	# (the variable is set from env on load, not readonly, so tests can override it per-test)
	export HEADLESS_RUNTIME_DB="${TEST_ROOT}/headless-runtime/state.db"
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

set_struggle_stub() {
	local result="$1"
	STUB_STRUGGLE_RESULT="$result"
	# shellcheck disable=SC2317
	_compute_struggle_ratio() {
		printf '%s' "$STUB_STRUGGLE_RESULT"
		return 0
	}
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

test_thrashing_guard_detects_zero_commit_high_message() {
	reset_fixture
	set_struggle_stub "320|0|320|thrashing"
	local cmd='opencode run --title "Issue #4187: thrash" --dir /tmp/aidevops "/full-loop Implement issue #4187"'

	if ! check_zero_commit_thrashing "4301" "$cmd" 8000; then
		print_result "thrash guard detects zero-commit high-message loops" 1 "Expected thrashing detection to trigger"
		return 0
	fi

	if [[ "$THRASH_COMMITS" != "0" || "$THRASH_MESSAGES" != "320" || "$THRASH_FLAG" != "thrashing" ]]; then
		print_result "thrash guard detects zero-commit high-message loops" 1 "Expected thrash metrics to be populated"
		return 0
	fi

	print_result "thrash guard detects zero-commit high-message loops" 0
	return 0
}

test_thrashing_guard_skips_workers_with_commits() {
	reset_fixture
	set_struggle_stub "45|2|90|"
	local cmd='opencode run --title "Issue #4187: thrash" --dir /tmp/aidevops "/full-loop Implement issue #4187"'

	if check_zero_commit_thrashing "4302" "$cmd" 8000; then
		print_result "thrash guard ignores workers with commits" 1 "Expected guardrail to skip workers that produced commits"
		return 0
	fi

	print_result "thrash guard ignores workers with commits" 0
	return 0
}

test_post_kill_marks_thrash_as_blocked() {
	reset_fixture
	local gh_calls_file="${TEST_ROOT}/gh-calls.log"
	: >"$gh_calls_file"

	extract_issue_number() {
		printf '%s' "4187"
		return 0
	}

	extract_repo_slug() {
		printf '%s' "marcusquinn/aidevops"
		return 0
	}

	gh() {
		printf '%s\n' "$*" >>"$gh_calls_file"
		return 0
	}

	post_kill_github_update "worker cmd" "thrash" "2h 13m" "ratio=320 messages=320 commits=0 flag=thrashing"

	local captured_calls=""
	captured_calls=$(<"$gh_calls_file")

	if [[ "$captured_calls" != *"--add-label status:blocked"* ]]; then
		print_result "thrash kills relabel issues as blocked" 1 "Expected status:blocked label on thrash kill"
		return 0
	fi

	if [[ "$captured_calls" != *"Retry guidance:"* ]]; then
		print_result "thrash kills relabel issues as blocked" 1 "Expected retry guidance in watchdog annotation"
		return 0
	fi

	print_result "thrash kills relabel issues as blocked" 0
	return 0
}

test_post_kill_marks_runtime_as_available() {
	reset_fixture
	local gh_calls_file="${TEST_ROOT}/gh-calls-runtime.log"
	: >"$gh_calls_file"

	extract_issue_number() {
		printf '%s' "4188"
		return 0
	}

	extract_repo_slug() {
		printf '%s' "marcusquinn/aidevops"
		return 0
	}

	gh() {
		printf '%s\n' "$*" >>"$gh_calls_file"
		return 0
	}

	post_kill_github_update "worker cmd" "runtime" "3h 0m" "no transcript"

	local captured_calls=""
	captured_calls=$(<"$gh_calls_file")

	if [[ "$captured_calls" != *"--add-label status:available"* ]]; then
		print_result "runtime kills keep issues dispatchable" 1 "Expected status:available label for runtime kill"
		return 0
	fi

	print_result "runtime kills keep issues dispatchable" 0
	return 0
}

test_extract_session_title_handles_unquoted_multiword_titles() {
	reset_fixture
	local cmd='opencode run --dir /tmp/aidevops --title Issue #999: Multi Word Session Title --format json /full-loop "Implement issue #999"'
	local extracted
	local expected='Issue #999: Multi Word Session Title'
	extracted=$(_extract_session_title "$cmd")

	if [[ "$extracted" == "$expected" ]]; then
		print_result "session title parser preserves multiword unquoted title" 0
		return 0
	fi

	print_result "session title parser preserves multiword unquoted title" 1 "Expected '${expected}', got '${extracted}'"
	return 0
}

test_transcript_gate_defers_active_sessions() {
	reset_fixture

	_get_session_tail_evidence() {
		printf '%s' 'active|session="Issue #500"; recent_messages=4; newest_part_age=8s; tail=tool:bash(completed) "Run tests"'
		return 0
	}

	if transcript_allows_intervention "runtime" "cmd" 7200; then
		print_result "transcript gate defers active sessions" 1 "Expected active transcript evidence to defer intervention"
		return 0
	fi

	print_result "transcript gate defers active sessions" 0
	return 0
}

test_transcript_gate_allows_stalled_sessions() {
	reset_fixture

	_get_session_tail_evidence() {
		printf '%s' 'stalled|session="Issue #501"; recent_messages=0; newest_part_age=1210s; tail=text:"No progress"'
		return 0
	}

	if ! transcript_allows_intervention "stall" "cmd" 1900; then
		print_result "transcript gate allows stalled sessions" 1 "Expected stalled transcript evidence to allow intervention"
		return 0
	fi

	print_result "transcript gate allows stalled sessions" 0
	return 0
}

# GH#5650: provider backoff detection tests

seed_backoff_fixture() {
	local db_path="$1"
	local provider="$2"
	local reason="$3"
	local retry_after="$4" # ISO8601 UTC, or "future" / "past" shorthand

	mkdir -p "$(dirname "$db_path")"

	FIXTURE_DB="$db_path" \
		FIXTURE_PROVIDER="$provider" \
		FIXTURE_REASON="$reason" \
		FIXTURE_RETRY_AFTER="$retry_after" \
		python3 - <<'PY'
import os
import sqlite3
import time

db_path = os.environ["FIXTURE_DB"]
provider = os.environ["FIXTURE_PROVIDER"]
reason = os.environ["FIXTURE_REASON"]
retry_after_raw = os.environ["FIXTURE_RETRY_AFTER"]

now = int(time.time())
if retry_after_raw == "future":
    from datetime import datetime, timezone, timedelta
    retry_after = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
elif retry_after_raw == "past":
    from datetime import datetime, timezone, timedelta
    retry_after = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
else:
    retry_after = retry_after_raw

conn = sqlite3.connect(db_path)
conn.executescript("""
    CREATE TABLE IF NOT EXISTS provider_backoff (
        provider       TEXT PRIMARY KEY,
        reason         TEXT NOT NULL,
        retry_after    TEXT,
        auth_signature TEXT,
        details        TEXT,
        updated_at     TEXT NOT NULL
    );
""")
conn.execute(
    "INSERT OR REPLACE INTO provider_backoff (provider, reason, retry_after, auth_signature, details, updated_at) VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))",
    (provider, reason, retry_after, "", "test fixture"),
)
conn.commit()
conn.close()
PY
	return 0
}

test_extract_provider_from_cmd_anthropic() {
	reset_fixture
	local cmd='opencode run --model anthropic/claude-sonnet-4-6 --title "Issue #5650: Fix watchdog" --dir /tmp/aidevops "/full-loop Implement issue #5650"'
	local provider
	provider=$(extract_provider_from_cmd "$cmd")

	if [[ "$provider" == "anthropic" ]]; then
		print_result "extract_provider_from_cmd extracts anthropic" 0
		return 0
	fi

	print_result "extract_provider_from_cmd extracts anthropic" 1 "Expected 'anthropic', got '${provider}'"
	return 0
}

test_extract_provider_from_cmd_openai() {
	reset_fixture
	local cmd='opencode run --model openai/gpt-4o --title "Issue #5650: Fix watchdog" --dir /tmp/aidevops "/full-loop Implement issue #5650"'
	local provider
	provider=$(extract_provider_from_cmd "$cmd")

	if [[ "$provider" == "openai" ]]; then
		print_result "extract_provider_from_cmd extracts openai" 0
		return 0
	fi

	print_result "extract_provider_from_cmd extracts openai" 1 "Expected 'openai', got '${provider}'"
	return 0
}

test_extract_provider_from_cmd_no_model() {
	reset_fixture
	local cmd='opencode run --title "Issue #5650: Fix watchdog" --dir /tmp/aidevops "/full-loop Implement issue #5650"'
	local provider
	provider=$(extract_provider_from_cmd "$cmd")

	if [[ -z "$provider" ]]; then
		print_result "extract_provider_from_cmd returns empty when no model flag" 0
		return 0
	fi

	print_result "extract_provider_from_cmd returns empty when no model flag" 1 "Expected empty, got '${provider}'"
	return 0
}

test_check_provider_backoff_detects_active_backoff() {
	reset_fixture
	local backoff_db="${TEST_ROOT}/headless-runtime/state.db"
	HEADLESS_RUNTIME_DB="$backoff_db"
	seed_backoff_fixture "$backoff_db" "anthropic" "auth_error" "future"

	local cmd='opencode run --model anthropic/claude-sonnet-4-6 --title "Issue #5650: Fix watchdog" --dir /tmp/aidevops "/full-loop Implement issue #5650"'

	if check_provider_backoff "9999" "$cmd" 600; then
		if [[ "$BACKOFF_PROVIDER" == "anthropic" && "$BACKOFF_REASON" == "auth_error" ]]; then
			print_result "check_provider_backoff detects active auth_error backoff" 0
			return 0
		fi
		print_result "check_provider_backoff detects active auth_error backoff" 1 "Backoff detected but wrong fields: provider=${BACKOFF_PROVIDER} reason=${BACKOFF_REASON}"
		return 0
	fi

	print_result "check_provider_backoff detects active auth_error backoff" 1 "Expected backoff to be detected for anthropic auth_error"
	return 0
}

test_check_provider_backoff_ignores_expired_backoff() {
	reset_fixture
	local backoff_db="${TEST_ROOT}/headless-runtime/state-expired.db"
	HEADLESS_RUNTIME_DB="$backoff_db"
	seed_backoff_fixture "$backoff_db" "anthropic" "auth_error" "past"

	local cmd='opencode run --model anthropic/claude-sonnet-4-6 --title "Issue #5650: Fix watchdog" --dir /tmp/aidevops "/full-loop Implement issue #5650"'

	if check_provider_backoff "9998" "$cmd" 600; then
		print_result "check_provider_backoff ignores expired backoff" 1 "Expected expired backoff to be ignored"
		return 0
	fi

	print_result "check_provider_backoff ignores expired backoff" 0
	return 0
}

test_check_provider_backoff_skips_grace_period() {
	reset_fixture
	local backoff_db="${TEST_ROOT}/headless-runtime/state-grace.db"
	HEADLESS_RUNTIME_DB="$backoff_db"
	seed_backoff_fixture "$backoff_db" "anthropic" "auth_error" "future"

	local cmd='opencode run --model anthropic/claude-sonnet-4-6 --title "Issue #5650: Fix watchdog" --dir /tmp/aidevops "/full-loop Implement issue #5650"'

	# elapsed < 300 — should skip check (grace period)
	if check_provider_backoff "9997" "$cmd" 60; then
		print_result "check_provider_backoff skips workers in grace period" 1 "Expected grace period to suppress backoff check"
		return 0
	fi

	print_result "check_provider_backoff skips workers in grace period" 0
	return 0
}

test_post_kill_marks_backoff_as_available() {
	reset_fixture
	local gh_calls_file="${TEST_ROOT}/gh-calls-backoff.log"
	: >"$gh_calls_file"

	extract_issue_number() {
		printf '%s' "5650"
		return 0
	}

	extract_repo_slug() {
		printf '%s' "marcusquinn/aidevops"
		return 0
	}

	gh() {
		printf '%s\n' "$*" >>"$gh_calls_file"
		return 0
	}

	post_kill_github_update "worker cmd" "backoff" "7h 23m" "provider=anthropic reason=auth_error retry_after=2026-03-24T05:58:00Z"

	local captured_calls=""
	captured_calls=$(<"$gh_calls_file")

	if [[ "$captured_calls" != *"--add-label status:available"* ]]; then
		print_result "backoff kills re-queue issues as available" 1 "Expected status:available label for backoff kill"
		return 0
	fi

	if [[ "$captured_calls" == *"--add-label status:blocked"* ]]; then
		print_result "backoff kills re-queue issues as available" 1 "Backoff kills should NOT set status:blocked"
		return 0
	fi

	print_result "backoff kills re-queue issues as available" 0
	return 0
}

test_time_weighted_thrash_catches_low_ratio_long_runtime() {
	reset_fixture
	# ratio=14, commits=0, messages=98, flag="" — below primary threshold (30) but 7h+ elapsed
	set_struggle_stub "14|0|98|"
	local cmd='opencode run --title "Issue #5650: Fix watchdog" --dir /tmp/aidevops "/full-loop Implement issue #5650"'

	# 7h 30m elapsed — should trigger time-weighted check
	if ! check_zero_commit_thrashing "9996" "$cmd" 27000; then
		print_result "time-weighted thrash catches ratio-14 at 7h+ with 0 commits" 1 "Expected time-weighted thrash to trigger at 7h+ with ratio 14"
		return 0
	fi

	if [[ "$THRASH_FLAG" != "time-weighted-thrash" ]]; then
		print_result "time-weighted thrash catches ratio-14 at 7h+ with 0 commits" 1 "Expected flag=time-weighted-thrash, got '${THRASH_FLAG}'"
		return 0
	fi

	print_result "time-weighted thrash catches ratio-14 at 7h+ with 0 commits" 0
	return 0
}

test_time_weighted_thrash_skips_short_runtime() {
	reset_fixture
	# Same ratio but only 1h elapsed — should NOT trigger time-weighted check
	set_struggle_stub "14|0|98|"
	local cmd='opencode run --title "Issue #5650: Fix watchdog" --dir /tmp/aidevops "/full-loop Implement issue #5650"'

	if check_zero_commit_thrashing "9995" "$cmd" 3600; then
		print_result "time-weighted thrash skips workers under 7h" 1 "Expected time-weighted thrash to skip at 1h elapsed"
		return 0
	fi

	print_result "time-weighted thrash skips workers under 7h" 0
	return 0
}

main() {
	setup_test_env
	test_recent_message_clears_stall
	test_provider_waiting_gets_grace_window
	test_provider_waiting_kills_after_grace_expires
	test_stalled_tail_is_reported
	test_thrashing_guard_detects_zero_commit_high_message
	test_thrashing_guard_skips_workers_with_commits
	test_post_kill_marks_thrash_as_blocked
	test_post_kill_marks_runtime_as_available
	test_extract_session_title_handles_unquoted_multiword_titles
	test_transcript_gate_defers_active_sessions
	test_transcript_gate_allows_stalled_sessions
	# GH#5650: provider backoff detection
	test_extract_provider_from_cmd_anthropic
	test_extract_provider_from_cmd_openai
	test_extract_provider_from_cmd_no_model
	test_check_provider_backoff_detects_active_backoff
	test_check_provider_backoff_ignores_expired_backoff
	test_check_provider_backoff_skips_grace_period
	test_post_kill_marks_backoff_as_available
	test_time_weighted_thrash_catches_low_ratio_long_runtime
	test_time_weighted_thrash_skips_short_runtime
	teardown_test_env

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
