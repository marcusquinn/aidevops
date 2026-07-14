#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-watchdog-stall-cap.sh — Unit tests for GH#20681 per-session stall caps
#
# Tests the _stall_session_cap_exceeded helper and the stall-cap logic in cmd_run:
#   1. Count cap fires after N stall events (WORKER_STALL_CONTINUE_MAX)
#   2. Cumulative time cap fires when total stall seconds >= limit
#   3. Defaults are respected when env vars are unset
#   4. Invalid env var values fall back to defaults

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

# ──────────────────────────────────────────────────────────────────────────────
# Tests for _stall_session_cap_exceeded
# ──────────────────────────────────────────────────────────────────────────────

test_count_cap_not_exceeded_at_limit() {
	# count=3 with max=3: NOT exceeded (3 is not > 3)
	if ! _stall_session_cap_exceeded 3 0 3 99999; then
		print_result "count cap not exceeded when count equals max" 0
		return 0
	fi
	print_result "count cap not exceeded when count equals max" 1 "Expected cap not exceeded for count=3 max=3"
	return 0
}

test_count_cap_exceeded_at_n_plus_1() {
	# count=4 with max=3: cap exceeded (4 > 3)
	if _stall_session_cap_exceeded 4 0 3 99999; then
		print_result "count cap exceeded when count exceeds max" 0
		return 0
	fi
	print_result "count cap exceeded when count exceeds max" 1 "Expected cap exceeded for count=4 max=3"
	return 0
}

test_cumulative_cap_not_exceeded_below_limit() {
	# cumulative=1799 with max=1800: NOT exceeded (1799 < 1800)
	if ! _stall_session_cap_exceeded 1 1799 99999 1800; then
		print_result "cumulative cap not exceeded when below limit" 0
		return 0
	fi
	print_result "cumulative cap not exceeded when below limit" 1 "Expected cap not exceeded for cumulative=1799 max=1800"
	return 0
}

test_cumulative_cap_exceeded_at_limit() {
	# cumulative=1800 with max=1800: cap exceeded (1800 >= 1800)
	if _stall_session_cap_exceeded 1 1800 99999 1800; then
		print_result "cumulative cap exceeded when at limit" 0
		return 0
	fi
	print_result "cumulative cap exceeded when at limit" 1 "Expected cap exceeded for cumulative=1800 max=1800"
	return 0
}

test_cumulative_cap_exceeded_above_limit() {
	# cumulative=2400 with max=1800: cap exceeded
	if _stall_session_cap_exceeded 1 2400 99999 1800; then
		print_result "cumulative cap exceeded when above limit" 0
		return 0
	fi
	print_result "cumulative cap exceeded when above limit" 1 "Expected cap exceeded for cumulative=2400 max=1800"
	return 0
}

test_neither_cap_exceeded() {
	# count=1 cumulative=600: neither cap exceeded
	if ! _stall_session_cap_exceeded 1 600 3 1800; then
		print_result "neither cap exceeded (typical first stall)" 0
		return 0
	fi
	print_result "neither cap exceeded (typical first stall)" 1 "Expected no cap exceeded for count=1 cumulative=600 max=3/1800"
	return 0
}

test_defaults_applied_when_args_omitted() {
	# When max_count and max_cumulative_s args omitted, defaults (3, 1800) apply.
	# count=4 with default max=3: should exceed
	if _stall_session_cap_exceeded 4 0; then
		print_result "count cap uses default max=3 when args omitted" 0
		return 0
	fi
	print_result "count cap uses default max=3 when args omitted" 1 "Expected cap exceeded with count=4 and default max=3"
	return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Integration-style test: cmd_run kills after exactly N stall events
#
# Simulates 4 stall events (exit 78) to confirm the cap fires at N=3.
# Strategy:
#   - WORKER_STALL_CONTINUE_MAX=3 (cap fires when count > 3, i.e., at 4th stall)
#   - HEADLESS_WATCHDOG_CONTINUE_MAX_RETRIES=1 (1 per-attempt continuation)
#   - max_attempts=3 (hardcoded in cmd_run)
# Event trace (4 _execute_run_attempt calls → 4 stalls):
#   attempt=1, run 1: stall#1 (≤3, no cap) → per-attempt continue (watchdog_count=1)
#   attempt=1, run 2: stall#2 (≤3, no cap) → no more per-attempt → provider rotation
#   attempt=2, run 3: stall#3 (≤3, no cap) → no per-attempt (count=1 not < 1) → rotation
#   attempt=3, run 4: stall#4 (4 > 3, CAP!) → records watchdog_stall_killed, returns 1
#
# This test stubs all external dependencies so no real processes are launched.
# ──────────────────────────────────────────────────────────────────────────────

test_cmd_run_finishes_confirmed_terminal_worker_before_continuation() {
	local execute_calls=0
	local external_checks=0
	local released_reason=""
	local fast_fail_calls=0
	local recorded_outcome=""
	local runtime_status=""

	_execute_run_attempt() {
		execute_calls=$((execute_calls + 1))
		_run_result_label="signal_killed_continue"
		_run_failure_reason="signal_killed_continue"
		_run_activity_detected="1"
		return 78
	}
	_worker_external_terminal_complete() {
		external_checks=$((external_checks + 1))
		return 0
	}
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_recover_worker_output_on_failure() { return 1; }
	_report_failure_to_fast_fail() { fast_fail_calls=$((fast_fail_calls + 1)); return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }
	_emit_worker_runtime_event() { runtime_status="$2"; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_hrw_release_worker_worktree() { return 0; }
	_cleanup_headless_runtime_temp_paths() { return 0; }
	_cmd_run_prepare() { return 0; }
	choose_model() { printf '%s' "anthropic/claude-sonnet-4-6"; return 0; }
	_enforce_opencode_version_pin() { return 0; }
	_run_canary_test() { return 0; }
	append_worker_headless_contract() { printf '%s' "$1"; return 0; }
	resolve_headless_variant() { printf '%s' "default"; return 0; }
	extract_provider() { printf '%s' "anthropic"; return 0; }

	export AIDEVOPS_HEADLESS_APPEND_CONTRACT=0
	local cmd_exit=0
	cmd_run --role worker --session-key "test-terminal-recovery" \
		--dir "/tmp" --title "test" --prompt "test prompt" 2>/dev/null || cmd_exit=$?

	local passed=1
	local msg=""
	if [[ "$cmd_exit" -eq 0 && "$execute_calls" -eq 1 && "$external_checks" -eq 1 && \
		"$released_reason" == "worker_complete" && "$fast_fail_calls" -eq 0 && \
		"$recorded_outcome" == "success" && "$runtime_status" == "recovered" ]]; then
		passed=0
	else
		msg="exit=${cmd_exit} execute=${execute_calls} checks=${external_checks} release=${released_reason:-<empty>} fast_fail=${fast_fail_calls} outcome=${recorded_outcome:-<empty>} status=${runtime_status:-<empty>}"
	fi
	print_result "exit 78 finishes externally terminal worker before continuation" "$passed" "$msg"
	return 0
}

test_cmd_run_kills_after_stall_cap() {
	# Stub heavy functions so cmd_run doesn't spin up real processes.
	local _metric_result=""
	local _finish_status=""
	local _execute_calls=0

	# Always return exit 78 (watchdog stall with activity).
	# Also set the variables cmd_run inspects after _execute_run_attempt.
	_execute_run_attempt() {
		_execute_calls=$((_execute_calls + 1))
		_run_result_label="watchdog_stall_continue"
		_run_failure_reason="watchdog_stall_continue"
		_run_activity_detected="1"
		_run_should_retry=0
		return 78
	}
	_worker_external_terminal_complete() { return 1; }

	append_runtime_metric() {
		# Capture the result field (argument $5)
		_metric_result="${5:-}"
		return 0
	}

	# Stubs for infrastructure calls — all no-ops or minimal returns.
	_cmd_run_prepare() { return 0; }
	_cmd_run_finish() { _finish_status="${2:-}"; return 0; }
	choose_model() { echo "anthropic/claude-sonnet-4-6"; return 0; }
	_enforce_opencode_version_pin() { return 0; }
	_run_canary_test() { return 0; }
	append_worker_headless_contract() { printf '%s' "$1"; return 0; }
	resolve_headless_variant() { echo "default"; return 0; }
	extract_provider() { echo "anthropic"; return 0; }

	# _cmd_run_prepare_retry: return 0 and set cmd_run_action="retry" so the
	# outer while loop continues (bash dynamic scoping allows modifying
	# cmd_run's local variable from within a called function).
	_cmd_run_prepare_retry() {
		cmd_run_action="retry"
		return 0
	}

	# Configure: max 3 stalls (count cap), 1 per-attempt watchdog continuation,
	# very high cumulative cap so only the count cap fires.
	export WORKER_STALL_CONTINUE_MAX=3
	export WORKER_STALL_CUMULATIVE_MAX_S=99999
	export HEADLESS_WATCHDOG_CONTINUE_MAX_RETRIES=1
	export HEADLESS_ACTIVITY_TIMEOUT_SECONDS=600
	export AIDEVOPS_HEADLESS_APPEND_CONTRACT=0

	local cmd_exit=0
	cmd_run --role worker --session-key "test-stall-cap" \
		--dir "/tmp" --title "test" --prompt "test prompt" 2>/dev/null || cmd_exit=$?

	local passed=1
	local msg=""

	# The stall cap should have fired and recorded watchdog_stall_killed.
	if [[ "$_metric_result" == "watchdog_stall_killed" && "$_execute_calls" -eq 4 ]]; then
		passed=0
	else
		msg="metric_result='${_metric_result}' expected 'watchdog_stall_killed'; execute_calls=${_execute_calls}"
	fi

	print_result "cmd_run records watchdog_stall_killed after 4 stall events (cap N=3)" "$passed" "$msg"
	return 0
}

test_cmd_run_does_not_duplicate_exit_79_metric() {
	local metric_calls=0
	local finish_status=""

	append_runtime_metric() {
		metric_calls=$((metric_calls + 1))
		return 0
	}
	_execute_run_attempt() {
		_run_result_label="watchdog_stall_killed"
		_run_failure_reason="watchdog_stall_killed"
		_run_activity_detected="1"
		append_runtime_metric worker test-stall-cap anthropic/claude-sonnet-4-6 anthropic \
			watchdog_stall_killed 79 watchdog_stall_killed 1 100
		return 79
	}
	_worker_external_terminal_complete() { return 1; }
	_cmd_run_finish() { finish_status="${2:-}"; return 0; }

	local cmd_exit=0
	cmd_run --role worker --session-key "test-stall-cap" \
		--dir "/tmp" --title "test" --prompt "test prompt" 2>/dev/null || cmd_exit=$?

	local passed=1
	local msg=""
	if [[ "$metric_calls" -eq 1 && "$finish_status" == "fail" && "$cmd_exit" -eq 1 ]]; then
		passed=0
	else
		msg="metric_calls=${metric_calls} finish_status=${finish_status} cmd_exit=${cmd_exit}"
	fi
	print_result "cmd_run records one context-rich metric for exit 79" "$passed" "$msg"
	return 0
}

main() {
	setup_test_env

	# _stall_session_cap_exceeded unit tests
	test_count_cap_not_exceeded_at_limit
	test_count_cap_exceeded_at_n_plus_1
	test_cumulative_cap_not_exceeded_below_limit
	test_cumulative_cap_exceeded_at_limit
	test_cumulative_cap_exceeded_above_limit
	test_neither_cap_exceeded
	test_defaults_applied_when_args_omitted

	# cmd_run integration test
	test_cmd_run_finishes_confirmed_terminal_worker_before_continuation
	test_cmd_run_kills_after_stall_cap
	test_cmd_run_does_not_duplicate_exit_79_metric

	teardown_test_env

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi

	return 1
}

main "$@"
