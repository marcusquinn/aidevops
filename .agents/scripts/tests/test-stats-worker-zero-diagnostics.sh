#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1

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
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	[[ -n "$message" ]] && printf '     %s\n' "$message"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	export OPENCODE_AUTH_FILE="${HOME}/.local/share/opencode/auth.json"
	unset OPENAI_API_KEY ANTHROPIC_API_KEY
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.local/share/opencode"
	# shellcheck source=/dev/null
	source "${SCRIPTS_DIR}/shared-constants.sh"
	# shellcheck source=/dev/null
	source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
	# shellcheck source=/dev/null
	source "${SCRIPTS_DIR}/stats-health-dashboard-data.sh"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	unset OPENCODE_AUTH_FILE
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

test_zero_worker_diagnostics_show_auth_and_launch_failure() {
	printf '{"openai":{"type":"oauth","access":"test-openai"}}\n' >"${HOME}/.local/share/opencode/auth.json"
	printf '{"role":"worker","model":"openai/gpt-5.5","exit_code":1}\n' >"${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl"
	printf '2026-05-02T00:00:00Z\tdispatch_max\tcompleted\n' >"${HOME}/.aidevops/logs/dispatch-stages.tsv"
	printf '[pulse-wrapper] Launch validation failed for issue #1 (owner/repo) — no active worker process within 35s\n' >"$LOGFILE"

	local output
	output=$(_gather_worker_zero_diagnostics 0 6 2 10 20 "low (8192MB free)")
	if [[ "$output" == *"worker launch failure"* && "$output" == *"OpenAI: oauth"* && "$output" == *"Last Launch Failure"* ]]; then
		print_result "zero-worker diagnostics include launch and auth signals" 0
		return 0
	fi
	print_result "zero-worker diagnostics include launch and auth signals" 1 "$output"
	return 0
}

test_nonzero_workers_skip_zero_diagnostics() {
	local output
	output=$(_gather_worker_zero_diagnostics 2 6 2 10 20 "low (8192MB free)")
	if [[ "$output" == "_Workers are active; zero-worker diagnostics not needed._" ]]; then
		print_result "active workers suppress zero-worker diagnostics" 0
		return 0
	fi
	print_result "active workers suppress zero-worker diagnostics" 1 "$output"
	return 0
}

main() {
	setup_test_env
	test_zero_worker_diagnostics_show_auth_and_launch_failure
	test_nonzero_workers_skip_zero_diagnostics
	teardown_test_env
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
