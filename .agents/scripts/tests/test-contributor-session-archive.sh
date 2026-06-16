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

	sqlite3 "$db_path" <<SQL
INSERT INTO session(id, title, parent_id, directory)
VALUES('${session_id}', '${title}', NULL, '${directory}');
INSERT INTO message(session_id, data, time_created)
VALUES('${session_id}', '{"role":"assistant","time":{"completed":${assistant_completed}}}', ${start_ms});
INSERT INTO message(session_id, data, time_created)
VALUES('${session_id}', '{"role":"user"}', ${user_created});
SQL
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
	'
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

	local all_json repo_json worker_machine total_machine repo_worker_machine
	all_json=$(HOME="${TEST_DIR}/home" session_time --all-dirs --period day --format json)
	repo_json=$(HOME="${TEST_DIR}/home" session_time "${TEST_DIR}/repo" --period day --format json)
	worker_machine=$(echo "$all_json" | jq -r '.worker_machine_hours')
	total_machine=$(echo "$all_json" | jq -r '.total_machine_hours')
	repo_worker_machine=$(echo "$repo_json" | jq -r '.worker_machine_hours')

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
