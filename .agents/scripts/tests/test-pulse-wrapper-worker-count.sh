#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
PS_MOCK_OUTPUT=""
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
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

ps() {
	printf '%s\n' "$PS_MOCK_OUTPUT"
	return 0
}

run_count() {
	local mock_output="$1"
	PS_MOCK_OUTPUT="$mock_output"
	count_active_workers
	return 0
}

test_counts_workers_and_ignores_supervisor_session() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101 mentions /pulse\" \"/full-loop Implement issue #101 -- pulse reliability\"
/usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse state includes /full-loop markers\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Routine\" \"/routine check\"")

	if [[ "$output" == "2" ]]; then
		print_result "counts full-loop workers without broad /pulse exclusions" 0
		return 0
	fi

	print_result "counts full-loop workers without broad /pulse exclusions" 1 "Expected 2 active workers, got '${output}'"
	return 0
}

test_returns_zero_when_no_full_loop_workers() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Routine\" \"/routine check\"")

	if [[ "$output" == "0" ]]; then
		print_result "returns zero when no matching workers exist" 0
		return 0
	fi

	print_result "returns zero when no matching workers exist" 1 "Expected 0 active workers, got '${output}'"
	return 0
}

test_does_not_exclude_non_supervisor_role_pulse_commands() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --role pulse --session-key another-session --dir /repo-a --title \"Issue #200\" \"/full-loop Implement issue #200\"")

	if [[ "$output" == "1" ]]; then
		print_result "keeps non-supervisor role pulse commands countable" 0
		return 0
	fi

	print_result "keeps non-supervisor role pulse commands countable" 1 "Expected 1 active worker, got '${output}'"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_counts_workers_and_ignores_supervisor_session
	test_returns_zero_when_no_full_loop_workers
	test_does_not_exclude_non_supervisor_role_pulse_commands

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
