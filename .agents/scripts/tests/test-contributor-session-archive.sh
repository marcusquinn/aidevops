#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SOURCE_SESSION_LIB="${SCRIPT_DIR}/../contributor-activity-helper-session.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		echo -e "${TEST_GREEN}PASS${RESET} ${test_name}"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${TEST_RED}FAIL${RESET} ${test_name}"
		if [[ -n "$message" ]]; then
			echo "       ${message}"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	mkdir -p "${TEST_DIR}/home/.local/share/opencode"
	mkdir -p "${TEST_DIR}/home/.aidevops/.agent-workspace/work/opencode-interactive/project-test/opencode"
	unset AIDEVOPS_WORK_DIR
	mkdir -p "${TEST_DIR}/home/.aidevops/.agent-workspace/observability"
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	TEST_DIR=""
	return 0
}

create_session_db() {
	local db_path="$1"
	sqlite3 "$db_path" '
		CREATE TABLE session (
			id TEXT PRIMARY KEY,
			title TEXT,
			parent_id TEXT,
			directory TEXT
		);
		CREATE TABLE message (
			session_id TEXT,
			data TEXT,
			time_created INTEGER
		);
	'
	return 0
}

insert_session_fixture() {
	local db_path="$1"
	local session_id="$2"
	local title="$3"
	local start_ms="$4"
	local directory="$5"
	local assistant_completed=$((start_ms + 10000))
	local user_created=$((assistant_completed + 20000))

	python3 - "$db_path" "$session_id" "$title" "$start_ms" "$directory" "$assistant_completed" "$user_created" <<'PY'
import json
import sqlite3
import sys

db_path = sys.argv[1]
session_id = sys.argv[2]
title = sys.argv[3]
start_ms = int(sys.argv[4])
directory = sys.argv[5]
assistant_completed = int(sys.argv[6])
user_created = int(sys.argv[7])

with sqlite3.connect(db_path) as conn:
    conn.execute(
        "INSERT INTO session(id, title, parent_id, directory) VALUES(?, ?, NULL, ?)",
        (session_id, title, directory),
    )
    conn.execute(
        "INSERT INTO message(session_id, data, time_created) VALUES(?, ?, ?)",
        (session_id, json.dumps({"role": "assistant", "time": {"completed": assistant_completed}}), start_ms),
    )
    conn.execute(
        "INSERT INTO message(session_id, data, time_created) VALUES(?, ?, ?)",
        (session_id, '{"role":"user"}', user_created),
    )
PY
	return 0
}

insert_null_directory_session_fixture() {
	local db_path="$1"
	local session_id="$2"
	local title="$3"
	local start_ms="$4"
	local assistant_completed=$((start_ms + 10000))
	local user_created=$((assistant_completed + 20000))

	sqlite3 "$db_path" <<SQL
INSERT INTO session(id, title, parent_id, directory)
VALUES('${session_id}', '${title}', NULL, NULL);
INSERT INTO message(session_id, data, time_created)
VALUES('${session_id}', '{"role":"assistant","time":{"completed":${assistant_completed}}}', ${start_ms});
INSERT INTO message(session_id, data, time_created)
VALUES('${session_id}', '{"role":"user"}', ${user_created});
SQL
	return 0
}

create_observability_db() {
	local db_path="$1"
	sqlite3 "$db_path" '
		CREATE TABLE llm_requests (
			timestamp TEXT,
			session_id TEXT,
			duration_ms INTEGER,
			project_path TEXT
		);
		CREATE INDEX idx_llm_requests_timestamp ON llm_requests(timestamp);
	'
	return 0
}

insert_machine_interval_fixture() {
	local db_path="$1"
	local session_id="$2"
	local start_ms="$3"
	local completed_ms="$4"
	local directory="$5"
	python3 - "$db_path" "$session_id" "$start_ms" "$completed_ms" "$directory" <<'PY'
import json
import sqlite3
import sys

db_path, session_id, start_ms, completed_ms, directory = sys.argv[1:]
with sqlite3.connect(db_path) as conn:
    conn.execute("INSERT INTO session(id,title,parent_id,directory) VALUES(?,?,NULL,?)", (session_id, "Issue #77: partial observability", directory))
    conn.execute("INSERT INTO message(session_id,data,time_created) VALUES(?,?,?)", (session_id, json.dumps({"role":"assistant","time":{"completed":int(completed_ms)}}), int(start_ms)))
PY
	return 0
}

insert_observability_fixture() {
	local db_path="$1"
	local session_id="$2"
	local duration_ms="$3"
	local project_path="$4"

	sqlite3 "$db_path" <<SQL
INSERT INTO llm_requests(timestamp, session_id, duration_ms, project_path)
VALUES(strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), '${session_id}', ${duration_ms}, '${project_path}');
SQL
	return 0
}

insert_overlapping_attention_fixture() {
	local db_path="$1"
	local session_id="$2"
	local start_ms="$3"
	local directory="$4"
	local assistant_completed=$((start_ms + 10000))
	local user_created=$((assistant_completed + 1800000))

	python3 - "$db_path" "$session_id" "$start_ms" "$directory" "$assistant_completed" "$user_created" <<'PY'
import json
import sqlite3
import sys

db_path, session_id, start_ms, directory, completed, user_created = sys.argv[1:]
with sqlite3.connect(db_path) as conn:
    conn.execute("INSERT INTO session(id,title,parent_id,directory) VALUES(?,?,NULL,?)", (session_id, "Interactive overlap", directory))
    conn.execute("INSERT INTO message(session_id,data,time_created) VALUES(?,?,?)", (session_id, json.dumps({"role":"assistant","time":{"completed":int(completed)}}), int(start_ms)))
    conn.execute("INSERT INTO message(session_id,data,time_created) VALUES(?,?,?)", (session_id, '{"role":"user"}', int(user_created)))
PY
	return 0
}

test_session_time_includes_archive_and_dedupes() {
	local test_name="session time includes OpenCode archive and dedupes"
	setup

	# shellcheck source=../contributor-activity-helper-session.sh
	source "$SOURCE_SESSION_LIB"

	local active_db="${TEST_DIR}/home/.local/share/opencode/opencode.db"
	local archive_db="${TEST_DIR}/home/.local/share/opencode/opencode-archive.db"
	local wrapper_db="${TEST_DIR}/home/.aidevops/.agent-workspace/work/opencode-interactive/project-test/opencode/opencode.db"
	create_session_db "$active_db"
	create_session_db "$archive_db"
	create_session_db "$wrapper_db"

	local now_ms old_ms near_month_ms recent_ms
	now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
	recent_ms=$((now_ms - 86400000))
	near_month_ms=$((now_ms - (29 * 86400000)))
	old_ms=$((now_ms - (100 * 86400000)))

	insert_session_fixture "$active_db" "current-interactive" "Current interactive" "$recent_ms" "$TEST_DIR/repo"
	insert_session_fixture "$active_db" "temp-classifier" "NO Issue is a classifier run" "$recent_ms" "/private/tmp/opencode"
	insert_null_directory_session_fixture "$active_db" "global-interactive" "Global interactive" "$recent_ms"
	insert_session_fixture "$archive_db" "current-interactive" "Current interactive duplicate" "$recent_ms" "$TEST_DIR/repo"
	insert_session_fixture "$archive_db" "near-month-interactive" "Near month interactive" "$near_month_ms" "$TEST_DIR/repo"
	insert_session_fixture "$archive_db" "old-worker" "Issue #123: archived worker" "$old_ms" "$TEST_DIR/repo"
	insert_session_fixture "$wrapper_db" "wrapper-interactive" "Wrapper interactive" "$recent_ms" "$TEST_DIR/repo"

	local year_json month_json twenty_eight_json repo_json year_sessions month_sessions twenty_eight_sessions worker_sessions interactive_sessions repo_sessions repo_worker_sessions observed_days
	year_json=$(HOME="${TEST_DIR}/home" session_time --all-dirs --period year --format json)
	month_json=$(HOME="${TEST_DIR}/home" session_time --all-dirs --period month --format json)
	twenty_eight_json=$(HOME="${TEST_DIR}/home" session_time --all-dirs --period 28d --format json)
	repo_json=$(HOME="${TEST_DIR}/home" session_time "${TEST_DIR}/repo" --period year --format json)
	year_sessions=$(echo "$year_json" | jq -r '.total_sessions')
	month_sessions=$(echo "$month_json" | jq -r '.total_sessions')
	twenty_eight_sessions=$(echo "$twenty_eight_json" | jq -r '.total_sessions')
	worker_sessions=$(echo "$year_json" | jq -r '.worker_sessions')
	interactive_sessions=$(echo "$year_json" | jq -r '.interactive_sessions')
	repo_sessions=$(echo "$repo_json" | jq -r '.total_sessions')
	repo_worker_sessions=$(echo "$repo_json" | jq -r '.worker_sessions')
	observed_days=$(echo "$year_json" | jq -r '.observed_days')

	if [[ "$year_sessions" != "6" ]]; then
		print_result "$test_name" 1 "expected 6 year sessions including wrapper DBs, temp workers, and NULL dirs, got ${year_sessions}; JSON: ${year_json}"
		teardown
		return 0
	fi
	if [[ "$month_sessions" != "5" ]]; then
		print_result "$test_name" 1 "expected 5 month sessions in 30-day window, got ${month_sessions}; JSON: ${month_json}"
		teardown
		return 0
	fi
	if [[ "$twenty_eight_sessions" != "4" ]]; then
		print_result "$test_name" 1 "expected 4 sessions in 28-day window, got ${twenty_eight_sessions}; JSON: ${twenty_eight_json}"
		teardown
		return 0
	fi
	if [[ "$worker_sessions" != "2" ]]; then
		print_result "$test_name" 1 "expected archived and temp worker classification, got ${worker_sessions}; JSON: ${year_json}"
		teardown
		return 0
	fi
	if [[ "$interactive_sessions" != "4" ]]; then
		print_result "$test_name" 1 "expected wrapper, NULL-directory, and archive interactive sessions preserved, got ${interactive_sessions}; JSON: ${year_json}"
		teardown
		return 0
	fi
	if [[ "$repo_sessions" != "4" ]]; then
		print_result "$test_name" 1 "expected repo-specific filter to include wrapper repo sessions and exclude temp and NULL dirs, got ${repo_sessions}; JSON: ${repo_json}"
		teardown
		return 0
	fi
	if [[ "$repo_worker_sessions" != "1" ]]; then
		print_result "$test_name" 1 "expected repo-specific worker classification unaffected, got ${repo_worker_sessions}; JSON: ${repo_json}"
		teardown
		return 0
	fi
	if ! awk "BEGIN {exit !(${observed_days} >= 99)}"; then
		print_result "$test_name" 1 "expected observed_days >= 99, got ${observed_days}"
		teardown
		return 0
	fi

	print_result "$test_name" 0
	teardown
	return 0
}

test_session_time_uses_observability_machine_floor() {
	local test_name="session time uses observability as worker machine floor"
	setup

	# shellcheck source=../contributor-activity-helper-session.sh
	source "$SOURCE_SESSION_LIB"

	local active_db="${TEST_DIR}/home/.local/share/opencode/opencode.db"
	local obs_db="${TEST_DIR}/home/.aidevops/.agent-workspace/observability/llm-requests.db"
	create_session_db "$active_db"
	create_observability_db "$obs_db"

	local now_ms recent_ms
	now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
	recent_ms=$((now_ms - 60000))

	insert_session_fixture "$active_db" "current-interactive" "Current interactive" "$recent_ms" "$TEST_DIR/repo"
	insert_observability_fixture "$obs_db" "current-interactive" 10000 "$TEST_DIR/repo"
	insert_observability_fixture "$obs_db" "worker-only" 7200000 "$TEST_DIR/repo-feature-auto-20260616-120000-gh123"

	local all_json repo_json worker_machine total_machine repo_worker_machine total_sessions worker_sessions
	all_json=$(HOME="${TEST_DIR}/home" session_time --all-dirs --period day --format json)
	repo_json=$(HOME="${TEST_DIR}/home" session_time "${TEST_DIR}/repo" --period day --format json)
	worker_machine=$(echo "$all_json" | jq -r '.worker_machine_hours')
	total_machine=$(echo "$all_json" | jq -r '.total_machine_hours')
	repo_worker_machine=$(echo "$repo_json" | jq -r '.worker_machine_hours')
	total_sessions=$(echo "$all_json" | jq -r '.total_sessions')
	worker_sessions=$(echo "$all_json" | jq -r '.worker_sessions')

	if [[ "$worker_machine" != "2" && "$worker_machine" != "2.0" ]]; then
		print_result "$test_name" 1 "expected 2.0 worker machine hours from observability, got ${worker_machine}; JSON: ${all_json}"
		teardown
		return 0
	fi
	if [[ "$total_machine" != "2" && "$total_machine" != "2.0" ]]; then
		print_result "$test_name" 1 "expected total machine hours to include observability floor, got ${total_machine}; JSON: ${all_json}"
		teardown
		return 0
	fi
	if [[ "$repo_worker_machine" != "2" && "$repo_worker_machine" != "2.0" ]]; then
		print_result "$test_name" 1 "expected repo filter to include sibling feature-auto worker path, got ${repo_worker_machine}; JSON: ${repo_json}"
		teardown
		return 0
	fi
	if [[ "$total_sessions" != "2" || "$worker_sessions" != "1" ]]; then
		print_result "$test_name" 1 "observability hours/count population did not reconcile; total=${total_sessions} workers=${worker_sessions}"
		teardown
		return 0
	fi

	print_result "$test_name" 0
	teardown
	return 0
}

test_profile_periods_scan_once_and_union_attention() {
	local test_name="profile periods scan once and union overlapping human attention"
	setup
	# shellcheck source=../contributor-activity-helper-session.sh
	source "$SOURCE_SESSION_LIB"
	local active_db="${TEST_DIR}/home/.local/share/opencode/opencode.db"
	create_session_db "$active_db"
	local now_ms start_ms counter output human scans semantics start_bound end_bound
	now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
	start_ms=$(python3 -c 'import datetime as d,time; today=d.datetime.now().date(); print(int(d.datetime.combine(today-d.timedelta(days=1),d.time(12)).timestamp()*1000))')
	insert_overlapping_attention_fixture "$active_db" "overlap-one" "$start_ms" "$TEST_DIR/repo"
	insert_overlapping_attention_fixture "$active_db" "overlap-two" "$start_ms" "$TEST_DIR/repo"
	counter="${TEST_DIR}/scan-count"
	output=$(HOME="${TEST_DIR}/home" AIDEVOPS_SESSION_SCAN_COUNTER="$counter" session_time --all-dirs --period profile --format json)
	human=$(echo "$output" | jq -r '.day.total_human_hours')
	scans=$(wc -l <"$counter" | tr -d ' ')
	semantics=$(echo "$output" | jq -r '.day.period_semantics')
	start_bound=$(echo "$output" | jq -r '.day.period_start_ms')
	end_bound=$(echo "$output" | jq -r '.day.period_end_ms')
	if [[ "$human" != "0.5" ]]; then
		print_result "$test_name" 1 "expected overlapping 0.5h attention intervals to union to 0.5h, got ${human}"
		teardown
		return 0
	fi
	if [[ "$scans" != "1" ]]; then
		print_result "$test_name" 1 "expected one session DB scan for four profile windows, got ${scans}"
		teardown
		return 0
	fi
	if [[ "$semantics" != "completed-local-calendar-days" || "$start_bound" -ge "$start_ms" || "$end_bound" -le "$start_ms" ]]; then
		print_result "$test_name" 1 "profile day did not expose completed local-calendar-day bounds"
		teardown
		return 0
	fi
	print_result "$test_name" 0
	teardown
	return 0
}

test_session_time_repo_filter_treats_path_metacharacters_literally() {
	local test_name="session time repo filter treats SQL path metacharacters literally"
	setup

	# shellcheck source=../contributor-activity-helper-session.sh
	source "$SOURCE_SESSION_LIB"

	local active_db="${TEST_DIR}/home/.local/share/opencode/opencode.db"
	create_session_db "$active_db"

	local now_ms recent_ms repo_path sibling_path wildcard_path quote_path
	now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
	recent_ms=$((now_ms - 60000))
	repo_path="${TEST_DIR}/repo_100%\\literal"
	sibling_path="${TEST_DIR}/repo_100%\\literal-feature-auto-20260616-120000-gh123"
	wildcard_path="${TEST_DIR}/repoX100Y\\literal"
	quote_path="${TEST_DIR}/repo_100%\\literal' OR 1=1 --"

	insert_session_fixture "$active_db" "exact-special" "Exact special" "$recent_ms" "$repo_path"
	insert_session_fixture "$active_db" "sibling-special" "Issue #123: sibling special" "$recent_ms" "$sibling_path"
	insert_session_fixture "$active_db" "wildcard-looking" "Wildcard looking" "$recent_ms" "$wildcard_path"
	insert_session_fixture "$active_db" "quote-injection-looking" "Quote injection looking" "$recent_ms" "$quote_path"

	local repo_json repo_sessions repo_worker_sessions
	repo_json=$(HOME="${TEST_DIR}/home" session_time "$repo_path" --period day --format json)
	repo_sessions=$(echo "$repo_json" | jq -r '.total_sessions')
	repo_worker_sessions=$(echo "$repo_json" | jq -r '.worker_sessions')

	if [[ "$repo_sessions" != "2" ]]; then
		print_result "$test_name" 1 "expected literal filter to include exact+sibling only, got ${repo_sessions}; JSON: ${repo_json}"
		teardown
		return 0
	fi
	if [[ "$repo_worker_sessions" != "1" ]]; then
		print_result "$test_name" 1 "expected only sibling worker classification, got ${repo_worker_sessions}; JSON: ${repo_json}"
		teardown
		return 0
	fi

	print_result "$test_name" 0
	teardown
	return 0
}

test_partial_observability_unions_with_message_generation() {
	local test_name="partial observability unions with complete message generation"
	setup
	# shellcheck source=../contributor-activity-helper-session.sh
	source "$SOURCE_SESSION_LIB"
	local active_db="${TEST_DIR}/home/.local/share/opencode/opencode.db"
	local obs_db="${TEST_DIR}/home/.aidevops/.agent-workspace/observability/llm-requests.db"
	create_session_db "$active_db"
	create_observability_db "$obs_db"
	local now_ms message_start message_end
	now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
	message_start=$((now_ms - 4 * 3600000))
	message_end=$((now_ms - 1 * 3600000))
	insert_machine_interval_fixture "$active_db" "partial-worker" "$message_start" "$message_end" "$TEST_DIR/repo"
	insert_observability_fixture "$obs_db" "partial-worker" 7200000 "$TEST_DIR/repo"
	local output machine
	output=$(HOME="${TEST_DIR}/home" session_time --all-dirs --period day --format json)
	machine=$(printf '%s' "$output" | jq -r '.worker_machine_hours')
	if [[ "$machine" != "4" && "$machine" != "4.0" ]]; then
		print_result "$test_name" 1 "expected 3h message + 2h observability with 1h overlap to union to 4h, got ${machine}; ${output}"
		teardown
		return 0
	fi
	print_result "$test_name" 0
	teardown
	return 0
}

test_observability_sql_filters_old_and_other_roots() {
	local test_name="observability SQL filters timestamp and root before row conversion"
	setup
	# shellcheck source=../contributor-activity-helper-session.sh
	source "$SOURCE_SESSION_LIB"
	local obs_db="${TEST_DIR}/home/.aidevops/.agent-workspace/observability/llm-requests.db"
	create_observability_db "$obs_db"
	python3 - "$obs_db" "$TEST_DIR/repo" <<'PY'
import datetime as dt
import sqlite3
import sys

db_path, root = sys.argv[1:]
old = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=500)).isoformat().replace("+00:00", "Z")
now = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
with sqlite3.connect(db_path) as conn:
    conn.executemany("INSERT INTO llm_requests VALUES(?,?,?,?)", [(old, f"old-{i}", 1000, root) for i in range(1000)])
    conn.execute("INSERT INTO llm_requests VALUES(?,?,?,?)", (now, "wanted", 60000, root))
    conn.execute("INSERT INTO llm_requests VALUES(?,?,?,?)", (now, "other-root", 60000, root + "X"))
    conn.execute("INSERT INTO llm_requests VALUES(?,?,?,?)", (now, "bad-number", "corrupt", root))
PY
	local counter="${TEST_DIR}/obs-selected-count"
	local plan_file="${TEST_DIR}/obs-query-plan"
	local output selected sessions
	output=$(HOME="${TEST_DIR}/home" AIDEVOPS_OBS_ROW_COUNTER="$counter" AIDEVOPS_OBS_QUERY_PLAN_FILE="$plan_file" session_time "$TEST_DIR/repo" --period day --format json)
	selected=$(awk '{sum += $1} END {print sum + 0}' "$counter")
	sessions=$(printf '%s' "$output" | jq -r '.total_sessions')
	if [[ "$selected" != "1" || "$sessions" != "1" ]] || ! grep -qF 'idx_llm_requests_timestamp' "$plan_file"; then
		print_result "$test_name" 1 "expected indexed SQL range to return one current matching row, selected=${selected} sessions=${sessions} plan=$(<"$plan_file"); ${output}"
		teardown
		return 0
	fi
	print_result "$test_name" 0
	teardown
	return 0
}

test_malformed_numeric_rows_and_invalid_period() {
	local test_name="malformed numeric rows are skipped and invalid periods rejected"
	setup
	# shellcheck source=../contributor-activity-helper-session.sh
	source "$SOURCE_SESSION_LIB"
	local active_db="${TEST_DIR}/home/.local/share/opencode/opencode.db"
	create_session_db "$active_db"
	sqlite3 "$active_db" "
		INSERT INTO session VALUES('bad-created','Bad created',NULL,'${TEST_DIR}/repo');
		INSERT INTO message VALUES('bad-created','{\"role\":\"assistant\",\"time\":{\"completed\":\"broken\"}}','not-a-number');"
	local output skipped
	output=$(HOME="${TEST_DIR}/home" session_time --all-dirs --period day --format json)
	skipped=$(printf '%s' "$output" | jq -r '.skipped_malformed_rows')
	if [[ "$skipped" -lt 1 ]]; then
		print_result "$test_name" 1 "corrupt numeric row was not counted as skipped: ${output}"
		teardown
		return 0
	fi
	if HOME="${TEST_DIR}/home" session_time --all-dirs --period nonsense --format json >/dev/null 2>&1; then
		print_result "$test_name" 1 "invalid period unexpectedly succeeded"
		teardown
		return 0
	fi
	print_result "$test_name" 0
	teardown
	return 0
}

assert_missing_option_fails_cleanly() {
	local function_name="$1"
	local option_name="$2"
	local stderr_file="$3"
	if "$function_name" "$option_name" >"${stderr_file}.out" 2>"$stderr_file"; then
		return 1
	fi
	if grep -qF "Error: ${option_name} requires an argument" "$stderr_file"; then
		return 0
	fi
	return 1
}

test_value_options_validate_before_shift() {
	local test_name="session value options fail cleanly before shift"
	setup
	# shellcheck source=../contributor-activity-helper-session.sh
	source "$SOURCE_SESSION_LIB"
	local stderr_file="${TEST_DIR}/option-error"
	local failed=0
	assert_missing_option_fails_cleanly session_time --period "$stderr_file" || failed=1
	assert_missing_option_fails_cleanly session_time --format "$stderr_file" || failed=1
	assert_missing_option_fails_cleanly session_time --db-path "$stderr_file" || failed=1
	assert_missing_option_fails_cleanly cross_repo_session_time --period "$stderr_file" || failed=1
	assert_missing_option_fails_cleanly cross_repo_session_time --format "$stderr_file" || failed=1
	if [[ "$failed" -ne 0 ]]; then
		print_result "$test_name" 1 "a value-taking option did not return an explicit diagnostic"
		teardown
		return 0
	fi
	print_result "$test_name" 0
	teardown
	return 0
}

test_explicit_db_is_existing_read_only_file_and_cutoff_is_safe() {
	local test_name="explicit session DBs are existing read-only files and cutoffs are bounded"
	setup
	# shellcheck source=../contributor-activity-helper-session.sh
	source "$SOURCE_SESSION_LIB"
	local db_path="${TEST_DIR}/explicit.db"
	local missing_path="${TEST_DIR}/must-not-exist.db"
	create_session_db "$db_path"
	local now_ms
	now_ms=$(($(date +%s) * 1000))
	insert_session_fixture "$db_path" "explicit-session" "Explicit session" "$((now_ms - 60000))" "$TEST_DIR/repo"
	chmod 444 "$db_path"
	local output sessions
	output=$(HOME="${TEST_DIR}/home" session_time --all-dirs --db-path "$db_path" --period day --format json)
	sessions=$(printf '%s' "$output" | jq -r '.total_sessions')
	HOME="${TEST_DIR}/home" session_time --all-dirs --db-path "$missing_path" --period day --format json >/dev/null
	local cutoff_ok=0
	PYTHONPATH="${SCRIPT_DIR}/.." python3 - <<'PY' || cutoff_ok=1
from session_time_db import safe_cutoff

epoch = "1970-01-01T00:00:00.000Z"
assert safe_cutoff(-1) == epoch
assert safe_cutoff("corrupt") == epoch
assert safe_cutoff(10**500) == epoch
PY
	local missing_created="no"
	[[ -e "$missing_path" ]] && missing_created="yes"
	if [[ "$sessions" != "1" || -e "$missing_path" || "$cutoff_ok" -ne 0 ]]; then
		print_result "$test_name" 1 "read-only explicit DB or safe cutoff contract failed: sessions=${sessions} missing_created=${missing_created}"
		teardown
		return 0
	fi
	print_result "$test_name" 0
	teardown
	return 0
}

test_session_engine_sibling_modules_deploy_together() {
	local test_name="session engine loads deployed sibling modules"
	setup
	local deploy_dir="${TEST_DIR}/deployed"
	mkdir -p "$deploy_dir"
	cp "${SCRIPT_DIR}/../session-time-interval-engine.py" "${SCRIPT_DIR}/../session_time_common.py" \
		"${SCRIPT_DIR}/../session_time_db.py" "${SCRIPT_DIR}/../session_time_aggregate.py" "$deploy_dir/"
	local output
	output=$(HOME="${TEST_DIR}/home" python3 "${deploy_dir}/session-time-interval-engine.py" --all-dirs --period day)
	if [[ "$(printf '%s' "$output" | jq -r '.status')" != "unavailable" ]]; then
		print_result "$test_name" 1 "isolated deployed engine did not load sibling modules: ${output}"
		teardown
		return 0
	fi
	print_result "$test_name" 0
	teardown
	return 0
}

main() {
	if [[ ! -f "$SOURCE_SESSION_LIB" ]]; then
		echo "Session library not found: ${SOURCE_SESSION_LIB}" >&2
		return 1
	fi
	if ! command -v sqlite3 >/dev/null 2>&1; then
		echo "sqlite3 not available; skipping"
		return 0
	fi

	test_session_time_includes_archive_and_dedupes
	test_session_time_uses_observability_machine_floor
	test_session_time_repo_filter_treats_path_metacharacters_literally
	test_profile_periods_scan_once_and_union_attention
	test_partial_observability_unions_with_message_generation
	test_observability_sql_filters_old_and_other_roots
	test_malformed_numeric_rows_and_invalid_period
	test_value_options_validate_before_shift
	test_explicit_db_is_existing_read_only_file_and_cutoff_is_safe
	test_session_engine_sibling_modules_deploy_together

	echo ""
	echo "Tests run: ${TESTS_RUN}"
	echo "Passed:    ${TESTS_PASSED}"
	echo "Failed:    ${TESTS_FAILED}"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
