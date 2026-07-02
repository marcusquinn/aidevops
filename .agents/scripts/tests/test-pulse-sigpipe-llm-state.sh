#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	export PULSE_DIR="${HOME}/.aidevops/.agent-workspace/supervisor"
	export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	export WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
	export REPOS_JSON="${HOME}/.config/aidevops/repos.json"
	export LOCKDIR="${HOME}/.aidevops/.agent-workspace/pulse.lock"
	mkdir -p "$PULSE_DIR" "$(dirname "$LOGFILE")" "$(dirname "$REPOS_JSON")"
	printf '{"initialized_repos":[]}\n' >"$REPOS_JSON"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

test_safe_emit_survives_early_closing_consumer() {
	# shellcheck source=/dev/null
	source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"

	local output rc
	output=$(
		set -euo pipefail
		for i in $(seq 1 20000); do
			_emit_stdout_line_safely "$i"
		done | sed -n '1p'
	) && rc=0 || rc=$?

	if [[ "$rc" -eq 0 && "$output" == "1" ]]; then
		print_result "SIGPIPE-safe emit survives early-closing consumer" 0
	else
		print_result "SIGPIPE-safe emit survives early-closing consumer" 1 "rc=${rc} output=${output}"
	fi
	return 0
}

test_daily_sweep_uses_attempt_cooldown_not_success_suppression() {
	# shellcheck source=/dev/null
	source "${SCRIPTS_DIR}/pulse-dispatch-engine.sh"

	export PULSE_LLM_DAILY_INTERVAL=100
	export PULSE_LLM_FAILURE_RETRY_INTERVAL=60
	local now_epoch old_success recent_attempt old_attempt rc mode
	now_epoch=$(date +%s)
	old_success=$((now_epoch - 1000))
	recent_attempt=$((now_epoch - 10))
	old_attempt=$((now_epoch - 120))
	printf '%s\n' "$old_success" >"${PULSE_DIR}/last_llm_success_epoch"
	printf '%s\n' "$recent_attempt" >"${PULSE_DIR}/last_llm_attempt_epoch"

	_should_run_llm_supervisor && rc=0 || rc=$?
	if [[ "$rc" -eq 1 && ! -f "${PULSE_DIR}/llm_trigger_mode" ]]; then
		print_result "recent failed LLM attempt applies retry cooldown" 0
	else
		print_result "recent failed LLM attempt applies retry cooldown" 1 "rc=${rc} trigger=$(cat "${PULSE_DIR}/llm_trigger_mode" 2>/dev/null || true)"
	fi

	printf '%s\n' "$old_attempt" >"${PULSE_DIR}/last_llm_attempt_epoch"
	_should_run_llm_supervisor && rc=0 || rc=$?
	mode=$(cat "${PULSE_DIR}/llm_trigger_mode" 2>/dev/null || true)
	if [[ "$rc" -eq 0 && "$mode" == "daily_sweep" ]]; then
		print_result "old failed LLM attempt permits daily sweep retry" 0
	else
		print_result "old failed LLM attempt permits daily sweep retry" 1 "rc=${rc} mode=${mode}"
	fi
	return 0
}

test_llm_attempt_failure_and_success_state_are_separate() {
	# shellcheck source=/dev/null
	source "${SCRIPTS_DIR}/pulse-wrapper-cycle.sh"
	rm -f \
		"${PULSE_DIR}/last_llm_attempt_epoch" \
		"${PULSE_DIR}/last_llm_success_epoch" \
		"${PULSE_DIR}/last_llm_run_epoch"

	_pulse_record_llm_attempt "daily_sweep"
	_pulse_record_llm_failure "daily_sweep" "7"
	if [[ -f "${PULSE_DIR}/last_llm_attempt_epoch" && ! -f "${PULSE_DIR}/last_llm_success_epoch" && ! -f "${PULSE_DIR}/last_llm_run_epoch" ]]; then
		print_result "failed LLM attempt does not write success timestamps" 0
	else
		print_result "failed LLM attempt does not write success timestamps" 1 "unexpected success timestamp after failure"
	fi

	_pulse_record_llm_success "daily_sweep"
	if [[ -f "${PULSE_DIR}/last_llm_success_epoch" && -f "${PULSE_DIR}/last_llm_run_epoch" ]]; then
		print_result "successful LLM run writes success and legacy timestamps" 0
	else
		print_result "successful LLM run writes success and legacy timestamps" 1 "missing success timestamp"
	fi
	return 0
}

main() {
	setup_sandbox
	test_safe_emit_survives_early_closing_consumer
	test_daily_sweep_uses_attempt_cooldown_not_success_suppression
	test_llm_attempt_failure_and_success_state_are_separate
	teardown_sandbox

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		printf 'All %d tests passed\n' "$TESTS_RUN"
		return 0
	fi
	printf '%d of %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
	return 1
}

main "$@"
