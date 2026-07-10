#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$TEST_SCRIPT_DIR/../../.." && pwd)" || exit
TEST_ROOT=$(mktemp -d)
export HOME="$TEST_ROOT/home"
export AGENT_TEST_CLI="mock"
mkdir -p "$HOME"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../agent-test-helper.sh
source "$REPO_ROOT/.agents/scripts/agent-test-helper.sh"

run_prompt() {
	local prompt="$1"
	local agent="$2"
	local model="$3"
	local timeout="$4"
	: "$agent" "$model" "$timeout"

	case "$prompt" in
	timeout)
		printf '%s\n' "[TIMEOUT after ${timeout}s]"
		return 1
		;;
	*)
		printf '%s\n' "mock response for ${prompt}"
		return 0
		;;
	esac
}

_cmd_run_sync_pattern_tracker() {
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

direct_stdout="$TEST_ROOT/direct.stdout"
direct_stderr="$TEST_ROOT/direct.stderr"
direct_test='{"id":"direct-call","prompt":"direct","expect_contains":["mock response"]}'
{
	_cmd_run_capture_test "$direct_test" 0 1 "" "" 1 "[]" false
	printf '%s\n' "stdout-still-open"
} >"$direct_stdout" 2>"$direct_stderr"
grep -q '^stdout-still-open$' "$direct_stdout" ||
	fail "capture helper leaked its stdout redirection into the caller"
grep -q '\[1/1\] direct-call' "$direct_stderr" ||
	fail "direct capture omitted human-readable progress"

propagated_status=0
(
	_cmd_run_execute_test() {
		return 7
	}
	_cmd_run_capture_test "$direct_test" 0 1 "" "" 1 "[]" true
) || propagated_status=$?
[[ $propagated_status -eq 7 ]] ||
	fail "capture helper did not propagate the execution status"

errexit_stdout="$TEST_ROOT/errexit.stdout"
errexit_status=0
set +e
TEST_AGENT_HELPER="$REPO_ROOT/.agents/scripts/agent-test-helper.sh" bash -c '
	set -euo pipefail
	source "$TEST_AGENT_HELPER"
	_cmd_run_execute_test() {
		false
		printf "%s\n" "unexpected-continuation" >&3
		return 0
	}
	_cmd_run_capture_test "{}" 0 1 "" "" 1 "[]" true
	printf "%s\n" "errexit-survived"
' >"$errexit_stdout" 2>&1
errexit_status=$?
set -e
[[ $errexit_status -ne 0 ]] ||
	fail "capture helper suppressed errexit inside its subshell"
if grep -q 'unexpected-continuation\|errexit-survived' "$errexit_stdout"; then
	fail "capture helper continued after a command failed under errexit"
fi

pass_suite="$TEST_ROOT/pass-suite.json"
cat >"$pass_suite" <<'JSON'
{
  "name": "output-channel-pass",
  "tests": [
    {"id": "first", "prompt": "first", "expect_contains": ["mock response"]},
    {"id": "second", "prompt": "second", "expect_contains": ["mock response"]}
  ]
}
JSON

human_stdout="$TEST_ROOT/human.stdout"
human_stderr="$TEST_ROOT/human.stderr"
cmd_run "$pass_suite" >"$human_stdout" 2>"$human_stderr" ||
	fail "passing suite returned non-zero"

grep -q '\[1/2\] first' "$human_stderr" ||
	fail "human output omitted first-case progress"
grep -q '\[2/2\] second' "$human_stderr" ||
	fail "human output omitted second-case progress"

pass_result=$(ls -1 "$RESULTS_DIR"/output-channel-pass-*.json)
jq -e '.summary.passed == 2 and .summary.failed == 0 and (.results | length) == 2' \
	"$pass_result" >/dev/null || fail "passing result file is invalid or incomplete"

fail_suite="$TEST_ROOT/fail-suite.json"
cat >"$fail_suite" <<'JSON'
{
  "name": "output-channel-fail",
  "timeout": 1,
  "tests": [
    {"id": "expectation", "prompt": "wrong", "expect_contains": ["missing"]},
    {"id": "timeout", "prompt": "timeout", "expect_contains": ["unused"]}
  ]
}
JSON

human_fail_output="$TEST_ROOT/human-fail.output"
human_fail_status=0
cmd_run "$fail_suite" >"$human_fail_output" 2>&1 || human_fail_status=$?
[[ $human_fail_status -ne 0 ]] || fail "human-mode failing suite returned zero"
grep -q 'Expected to contain: "missing"' "$human_fail_output" ||
	fail "human output omitted expectation failure"
grep -q 'Error/timeout' "$human_fail_output" ||
	fail "human output omitted timeout failure"
rm -f "$RESULTS_DIR"/output-channel-fail-*.json

json_stdout="$TEST_ROOT/json.stdout"
json_stderr="$TEST_ROOT/json.stderr"
fail_status=0
cmd_run "$fail_suite" --json >"$json_stdout" 2>"$json_stderr" || fail_status=$?
[[ $fail_status -ne 0 ]] || fail "failing suite returned zero"
jq -e '.passed == 0 and .failed == 2 and .total == 2' "$json_stdout" >/dev/null ||
	fail "--json stdout contains non-metric output"

fail_result=$(ls -1 "$RESULTS_DIR"/output-channel-fail-*.json)
jq -e '.summary.failed == 2 and (.results | length) == 2 and .results[1].error == "timeout_or_error"' \
	"$fail_result" >/dev/null || fail "failing result file is invalid or incomplete"

printf '%s\n' "PASS: agent test output channels remain parseable across multiple cases"
