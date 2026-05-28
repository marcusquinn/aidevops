#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SH="${SCRIPT_DIR}/../report-token-use-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local _test_name="$1"
	local _passed="$2"
	local _message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$_passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$_test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$_test_name"
	if [[ -n "$_message" ]]; then
		printf '       %s\n' "$_message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

create_fixture_dbs() {
	local _opencode_db="${TEST_ROOT}/opencode.db"
	local _obs_db="${TEST_ROOT}/llm-requests.db"
	sqlite3 "$_opencode_db" <<'SQL'
CREATE TABLE session (
  id text PRIMARY KEY,
  parent_id text,
  title text NOT NULL,
  model text,
  tokens_input integer DEFAULT 0,
  tokens_output integer DEFAULT 0,
  tokens_reasoning integer DEFAULT 0,
  tokens_cache_read integer DEFAULT 0,
  tokens_cache_write integer DEFAULT 0,
  cost real DEFAULT 0,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  time_compacting integer,
  directory text,
  path text,
  agent text
);
CREATE TABLE session_message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  type text NOT NULL,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  data text NOT NULL
);
INSERT INTO session VALUES ('ses_root', NULL, 'Root Session', '{"id":"gpt-5.5","providerID":"openai","variant":"high"}', 100, 20, 5, 30, 7, 0.25, 1700000000000, 1700000100000, NULL, '/repo', '/repo', 'Build+');
INSERT INTO session VALUES ('ses_child', 'ses_root', 'Compacted Child', '{"id":"claude-sonnet-4-6","providerID":"anthropic"}', 50, 10, 0, 5, 0, 0.10, 1700000100000, 1700000200000, NULL, '/repo', '/repo', 'Build+');
INSERT INTO session_message VALUES ('msg1', 'ses_root', 'model-switched', 1700000000000, 1700000000000, '{"model":{"id":"gpt-5.5","providerID":"openai","variant":"high"}}');
SQL
	sqlite3 "$_obs_db" <<'SQL'
CREATE TABLE llm_requests (session_id text, model_id text);
CREATE TABLE tool_calls (session_id text, tool_name text);
INSERT INTO llm_requests VALUES ('ses_root', 'gpt-5.5');
INSERT INTO llm_requests VALUES ('ses_child', 'claude-sonnet-4-6');
INSERT INTO tool_calls VALUES ('ses_root', 'context7_lookup');
SQL
	cat >"${TEST_ROOT}/opencode.json" <<'JSON'
{"mcp":{"context7":{"enabled":true}}}
JSON
	return 0
}

assert_json_field() {
	local _json_file="$1"
	local _expr="$2"
	local _expected="$3"
	local _label="$4"
	local _actual
	_actual=$(python3 - "$_json_file" "$_expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)
for part in expr.split('.'):
    if part.endswith(']'):
        name, index = part[:-1].split('[')
        if name:
            value = value[name]
        value = value[int(index)]
    else:
        value = value[part]
print(value)
PY
)
	if [[ "$_actual" == "$_expected" ]]; then
		print_result "$_label" 0
		return 0
	fi
	print_result "$_label" 1 "expected '${_expected}', got '${_actual}'"
	return 0
}

test_report_aggregates_compacted_sessions() {
	create_fixture_dbs
	local _output
	_output=$(AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_DB="${TEST_ROOT}/opencode.db" \
		AIDEVOPS_REPORT_TOKEN_USE_OBS_DB="${TEST_ROOT}/llm-requests.db" \
		AIDEVOPS_REPORT_TOKEN_USE_ROOT="${TEST_ROOT}/reports" \
		AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_CONFIG="${TEST_ROOT}/opencode.json" \
		"$HELPER_SH" report --limit 5 --daily-days 2000 --json)
	local _json_path
	_json_path=$(python3 - <<PY
import json
data = json.loads('''${_output}''')
print(data['report_json'])
PY
)
	assert_json_field "$_json_path" "session_count" "1" "Report groups root and compacted child"
	assert_json_field "$_json_path" "sessions[0].tokens_input" "150" "Report sums input tokens"
	assert_json_field "$_json_path" "sessions[0].tokens_output" "30" "Report sums output tokens"
	assert_json_field "$_json_path" "sessions[0].tokens_cache_read" "35" "Report sums cached-read tokens"
	assert_json_field "$_json_path" "sessions[0].raw_tokens_total" "227" "Report computes raw total"
	assert_json_field "$_json_path" "sessions[0].net_tokens_total" "192" "Report computes net total excluding cache reads"
	assert_json_field "$_json_path" "sessions[0].compaction_count" "1" "Report counts child compaction"
	assert_json_field "$_json_path" "sessions[0].mcps_observed[0]" "context7" "Report infers observed MCP"
	assert_json_field "$_json_path" "daily_usage[0].date" "2023-11-14" "Report includes daily usage date"
	assert_json_field "$_json_path" "daily_usage[0].net_tokens_total" "192" "Report sums daily net tokens"
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_report_aggregates_compacted_sessions
	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
