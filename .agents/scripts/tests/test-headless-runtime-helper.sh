#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-headless-runtime-helper.sh - Coverage for /full-loop headless contract injection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../headless-runtime-helper.sh"

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
	mkdir -p "${HOME}/.aidevops/logs"
	set +e
	# shellcheck source=/dev/null
	source "$HELPER_SCRIPT" >/dev/null 2>&1
	set -e
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

test_appends_escalation_contract() {
	local prompt='/full-loop Implement issue #14964'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == *'HEADLESS_CONTINUATION_CONTRACT_V5'* ]] &&
		[[ "$output" == *'Read the issue body FIRST. Look for a "Worker Guidance" or "How" section'* ]] &&
		[[ "$output" == *'Never ask for user confirmation, approval, or next steps. No user will respond.'* ]] &&
		[[ "$output" == *'The only valid exit states are FULL_LOOP_COMPLETE or BLOCKED with evidence.'* ]]; then
		print_result "appends escalation-before-blocked contract to full-loop prompts" 0
		return 0
	fi

	print_result "appends escalation-before-blocked contract to full-loop prompts" 1 "Output missing required contract clauses"
	return 0
}

test_non_full_loop_prompt_unchanged() {
	local prompt='Review this file only'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "leaves non-full-loop prompt unchanged" 0
		return 0
	fi

	print_result "leaves non-full-loop prompt unchanged" 1 "Prompt was unexpectedly modified"
	return 0
}

test_does_not_double_append() {
	local prompt='/full-loop Continue issue #14964

[HEADLESS_CONTINUATION_CONTRACT_V5]
This worker run is unattended.'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "does not double-append existing contract" 0
		return 0
	fi

	print_result "does not double-append existing contract" 1 "Existing contract was modified"
	return 0
}

test_extract_session_id_from_output_returns_latest_session_id() {
	local output_file="${TEST_ROOT}/opencode-output.jsonl"
	cat >"$output_file" <<'EOF'
not-json
{"type":"message","sessionID":"ses_early"}
{"type":"tool_use","part":{"sessionID":"ses_latest"}}
EOF

	local session_id
	session_id=$(extract_session_id_from_output "$output_file")

	if [[ "$session_id" == "ses_latest" ]]; then
		print_result "extract_session_id_from_output returns latest session id" 0
		return 0
	fi

	print_result "extract_session_id_from_output returns latest session id" 1 "Expected ses_latest, got ${session_id:-<empty>}"
	return 0
}

main() {
	setup_test_env
	test_appends_escalation_contract
	test_non_full_loop_prompt_unchanged
	test_does_not_double_append
	test_extract_session_id_from_output_returns_latest_session_id
	teardown_test_env

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi

	return 1
}

main "$@"
