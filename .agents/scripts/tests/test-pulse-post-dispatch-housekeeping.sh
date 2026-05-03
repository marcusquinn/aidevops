#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for t3055 async post-dispatch housekeeping.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${TEST_SCRIPT_DIR}/../../.." && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
LOGFILE=""
STAGE_LOG=""
ENGINE_SOURCED=0

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

_record_stage() {
	local stage_name="$1"
	if [[ "$stage_name" == "coderabbit" && "${TEST_STAGE_SLEEP_ONCE:-0}" =~ ^[0-9]+$ && "${TEST_STAGE_SLEEP_ONCE:-0}" -gt 0 ]]; then
		sleep "$TEST_STAGE_SLEEP_ONCE"
		TEST_STAGE_SLEEP_ONCE=0
	fi
	printf '%s\n' "$stage_name" >>"$STAGE_LOG"
	return 0
}

run_daily_codebase_review() { _record_stage "coderabbit"; return 0; }
_run_post_merge_review_scanner() { _record_stage "post_merge"; return 0; }
_run_auto_decomposer_scanner() { _record_stage "auto_decomposer"; return 0; }
run_simplification_dedup_cleanup() { _record_stage "dedup_cleanup"; return 0; }
fast_fail_prune_expired() { _record_stage "fast_fail_prune"; return 0; }
_preflight_ownership_reconcile() { _record_stage "ownership_reconcile"; return 0; }

_pulse_run_optional_stage_with_timeout() {
	local stage_name="$1"
	local stage_timeout="$2"
	shift 2
	printf 'optional:%s:%s\n' "$stage_name" "$stage_timeout" >>"$STAGE_LOG"
	"$@"
	return 0
}

run_stage_with_timeout() {
	local stage_name="$1"
	local stage_timeout="$2"
	shift 2
	printf 'stage:%s:%s\n' "$stage_name" "$stage_timeout" >>"$STAGE_LOG"
	"$@"
	return 0
}

install_stage_stubs() {
	run_daily_codebase_review() { _record_stage "coderabbit"; return 0; }
	_run_post_merge_review_scanner() { _record_stage "post_merge"; return 0; }
	_run_auto_decomposer_scanner() { _record_stage "auto_decomposer"; return 0; }
	run_simplification_dedup_cleanup() { _record_stage "dedup_cleanup"; return 0; }
	fast_fail_prune_expired() { _record_stage "fast_fail_prune"; return 0; }
	_preflight_ownership_reconcile() { _record_stage "ownership_reconcile"; return 0; }

	_pulse_run_optional_stage_with_timeout() {
		local stage_name="$1"
		local stage_timeout="$2"
		shift 2
		printf 'optional:%s:%s\n' "$stage_name" "$stage_timeout" >>"$STAGE_LOG"
		"$@"
		return 0
	}

	run_stage_with_timeout() {
		local stage_name="$1"
		local stage_timeout="$2"
		shift 2
		printf 'stage:%s:%s\n' "$stage_name" "$stage_timeout" >>"$STAGE_LOG"
		"$@"
		return 0
	}
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d -t t3055-housekeeping.XXXXXX)"
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/cache"
	LOGFILE="${TEST_ROOT}/pulse.log"
	STAGE_LOG="${TEST_ROOT}/stages.log"
	: >"$LOGFILE"
	: >"$STAGE_LOG"
	export LOGFILE STAGE_LOG
	export PRE_RUN_STAGE_TIMEOUT=9
	export PREFLIGHT_GROUP_TIMEOUT=9
	export STOP_FLAG="${TEST_ROOT}/stop.flag"
	export _PULSE_RATE_LIMIT_CB_LOADED=1
	if [[ "$ENGINE_SOURCED" -eq 0 ]]; then
		unset _PULSE_DISPATCH_ENGINE_LOADED
		# shellcheck disable=SC1091
		source "${REPO_ROOT}/.agents/scripts/pulse-dispatch-engine.sh"
		ENGINE_SOURCED=1
	fi
	install_stage_stubs
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	LOGFILE=""
	STAGE_LOG=""
	unset TEST_STAGE_SLEEP_ONCE AIDEVOPS_PULSE_ASYNC_POST_DISPATCH_HOUSEKEEPING
	unset _PULSE_RATE_LIMIT_CB_LOADED
	return 0
}

_wait_for_housekeeping_complete() {
	local lockdir="$1"
	local attempts=0
	while [[ "$attempts" -lt 12 ]]; do
		if [[ ! -d "$lockdir" ]] && grep -q '^ownership_reconcile$' "$STAGE_LOG" 2>/dev/null; then
			return 0
		fi
		sleep 1
		attempts=$((attempts + 1))
	done
	return 1
}

test_sync_housekeeping_runs_all_stages() {
	setup_test_env
	export AIDEVOPS_PULSE_ASYNC_POST_DISPATCH_HOUSEKEEPING=0
	_pulse_start_post_dispatch_housekeeping 7

	local failures=0 failmsg=""
	local expected
	for expected in coderabbit post_merge auto_decomposer dedup_cleanup fast_fail_prune ownership_reconcile; do
		if ! grep -q "^${expected}$" "$STAGE_LOG" 2>/dev/null; then
			failures=$((failures + 1))
			failmsg="${failmsg} | missing ${expected}"
		fi
	done
	if [[ "$failures" -eq 0 ]]; then
		print_result "post-dispatch housekeeping sync fallback runs all stages" 0
	else
		print_result "post-dispatch housekeeping sync fallback runs all stages" 1 "$failmsg"
	fi
	teardown_test_env
	return 0
}

test_async_housekeeping_returns_before_slow_stage() {
	setup_test_env
	export AIDEVOPS_PULSE_ASYNC_POST_DISPATCH_HOUSEKEEPING=1
	export TEST_STAGE_SLEEP_ONCE=2
	local lockdir
	lockdir="$(_pulse_post_dispatch_housekeeping_lockdir)"
	local start_seconds="$SECONDS"
	_pulse_start_post_dispatch_housekeeping 7
	local elapsed=$((SECONDS - start_seconds))

	local failures=0 failmsg=""
	if [[ "$elapsed" -ge 2 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | launch blocked for ${elapsed}s"
	fi
	if ! _wait_for_housekeeping_complete "$lockdir"; then
		failures=$((failures + 1))
		failmsg="${failmsg} | async stages did not complete"
	fi
	if ! grep -q 'Async post-dispatch housekeeping: launched pid=' "$LOGFILE" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | launch log missing"
	fi

	if [[ "$failures" -eq 0 ]]; then
		print_result "post-dispatch housekeeping async launch does not block pulse" 0
	else
		print_result "post-dispatch housekeeping async launch does not block pulse" 1 "$failmsg"
	fi
	teardown_test_env
	return 0
}

test_housekeeping_lock_skips_live_duplicate() {
	setup_test_env
	local lockdir
	lockdir="$(_pulse_post_dispatch_housekeeping_lockdir)"
	mkdir -p "$lockdir"
	printf '%s\n' "$$" >"${lockdir}/pid"
	_pulse_run_post_dispatch_housekeeping_stages 7

	local failures=0 failmsg=""
	if [[ -s "$STAGE_LOG" ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | stages ran despite live lock"
	fi
	if ! grep -q 'already running' "$LOGFILE" 2>/dev/null; then
		failures=$((failures + 1))
		failmsg="${failmsg} | duplicate skip log missing"
	fi

	if [[ "$failures" -eq 0 ]]; then
		print_result "post-dispatch housekeeping live lock skips duplicate" 0
	else
		print_result "post-dispatch housekeeping live lock skips duplicate" 1 "$failmsg"
	fi
	teardown_test_env
	return 0
}

main() {
	test_sync_housekeeping_runs_all_stages
	test_async_housekeeping_returns_before_slow_stage
	test_housekeeping_lock_skips_live_duplicate

	printf '\n============================================\n'
	printf 'Tests run:    %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	printf '============================================\n'

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
