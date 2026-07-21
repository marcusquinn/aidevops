#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Root CLI parsing and delegation tests for `aidevops schedule`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AIDEVOPS_SH="${REPO_ROOT}/aidevops.sh"
# shellcheck source=../shared-constants.sh
source "${REPO_ROOT}/.agents/scripts/shared-constants.sh"

TEST_ROOT=""
TEST_HOME=""
STATE_DIR=""
PROMPT_FILE=""
TESTS_RUN=0
TESTS_FAILED=0

result() {
	local name="$1"
	local failed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$failed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name" >&2
	[[ -z "$detail" ]] || printf '     %s\n' "$detail" >&2
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

teardown() {
	[[ -z "$TEST_ROOT" ]] || rm -rf "$TEST_ROOT"
	return 0
}

setup_suite() {
	TEST_ROOT=$(mktemp -d)
	TEST_HOME="${TEST_ROOT}/home"
	STATE_DIR="${TEST_ROOT}/scheduled"
	PROMPT_FILE="${TEST_ROOT}/prompt.md"
	mkdir -p "$TEST_HOME" "${TEST_ROOT}/work"
	printf 'scheduled fixture\n' >"$PROMPT_FILE"
	trap teardown EXIT
	return 0
}

run_cli() {
	HOME="$TEST_HOME" AIDEVOPS_DEFERRED_JOB_DIR="$STATE_DIR" \
		AIDEVOPS_DEFERRED_NOW_EPOCH=1784678400 bash "$AIDEVOPS_SH" "$@"
	return $?
}

test_help_surfaces_schedule() {
	local output=""
	local rc=0
	output=$(run_cli help 2>&1) || rc=$?
	if [[ "$rc" -eq 0 && "$output" == *"schedule <cmd>"* ]]; then
		result "root help lists schedule command" 0
	else
		result "root help lists schedule command" 1 "rc=$rc"
	fi
	return 0
}

test_schedule_help_delegates() {
	local output=""
	local rc=0
	output=$(run_cli schedule --help 2>&1) || rc=$?
	if [[ "$rc" -eq 0 && "$output" == *"aidevops schedule once"* && "$output" == *"schedule cancel JOB_ID"* ]]; then
		result "schedule help delegates to deferred helper" 0
	else
		result "schedule help delegates to deferred helper" 1 "rc=$rc output=$output"
	fi
	return 0
}

test_once_and_status_delegation() {
	local output=""
	local status_json=""
	local job_id=""
	output=$(run_cli schedule once --after 5m --name cli-fixture --dir "${TEST_ROOT}/work" --prompt-file "$PROMPT_FILE")
	job_id=$(printf '%s\n' "$output" | awk '/Queued dj-/{print $2; exit}')
	status_json=$(run_cli schedule status "$job_id" --json)
	if [[ "$job_id" == dj-* && "$(printf '%s\n' "$status_json" | jq -r '.status')" == "queued" ]]; then
		result "once and status arguments pass through root CLI" 0
	else
		result "once and status arguments pass through root CLI" 1 "$output $status_json"
	fi
	return 0
}

test_invalid_once_propagates_exit() {
	local rc=0
	run_cli schedule once --after 5m --at 2026-07-22T00:00:00Z --name invalid \
		--dir "${TEST_ROOT}/work" --prompt-file "$PROMPT_FILE" >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		result "root CLI preserves schedule validation exit code" 0
	else
		result "root CLI preserves schedule validation exit code" 1 "rc=$rc"
	fi
	return 0
}

main() {
	setup_suite
	test_help_surfaces_schedule
	test_schedule_help_delegates
	test_once_and_status_delegation
	test_invalid_once_propagates_exit
	printf '\n%s/%s tests passed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
