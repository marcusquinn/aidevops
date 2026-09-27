#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
RUNNER="${SCRIPT_DIR}/../browser-qa-journey.mjs"
TESTS_PASSED=0
TESTS_FAILED=0
JOURNEY_TEST_TEMP_DIR=""

cleanup() {
	rm -rf "${JOURNEY_TEST_TEMP_DIR:-}"
	return 0
}

assert_rejected() {
	local name="$1"
	local config="$2"
	local expected="$3"
	local output exit_code=0
	output=$(node "$RUNNER" "$config" test 2>&1) || exit_code=$?
	if [[ "$exit_code" -ne 0 ]] && [[ "$output" == *"$expected"* ]]; then
		printf 'PASS %s\n' "$name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

main() {
	JOURNEY_TEST_TEMP_DIR=$(mktemp -d)
	trap cleanup EXIT
	printf '%s' '{"version":2,"environments":{},"steps":[]}' >"${JOURNEY_TEST_TEMP_DIR}/version.json"
	printf '%s' '{"version":1,"environments":{"test":{"origin":"https://example.invalid/path","credentials":{"usernameEnv":"QA_USER","passwordEnv":"QA_PASSWORD"},"login":{},"logout":{}}},"steps":[{"type":"visible","selector":"body"}]}' >"${JOURNEY_TEST_TEMP_DIR}/origin.json"
	printf '%s' '{"version":1,"environments":{"test":{"origin":"https://example.invalid","credentials":{"usernameEnv":"QA_USER","passwordEnv":"QA_PASSWORD"},"login":{"path":"/login","method":"POST","successPath":"/home","usernameSelector":"#user","passwordSelector":"#password","submitSelector":"button"},"logout":{"path":"/logout","method":"POST"}}},"steps":[{"type":"visible","selector":"body"}]}' >"${JOURNEY_TEST_TEMP_DIR}/credentials.json"

	assert_rejected "unknown schema version fails before authentication" "${JOURNEY_TEST_TEMP_DIR}/version.json" "version must be 1"
	assert_rejected "origin path fails closed" "${JOURNEY_TEST_TEMP_DIR}/origin.json" "exact http(s) origin"
	assert_rejected "missing credential fails before browser launch" "${JOURNEY_TEST_TEMP_DIR}/credentials.json" "credentials are unavailable"
	printf 'Results: %s passed, %s failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
