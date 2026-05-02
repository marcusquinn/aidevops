#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-min-concurrency.sh — t3418 regression tests for the minimum
# pulse worker concurrency floor under CPU/load throttling.

set -uo pipefail

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/headless-runtime"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export STOP_FLAG="${HOME}/.aidevops/logs/stop"
: >"$LOGFILE"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"
# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPT_DIR}/pulse-dispatch-worker-launch.sh"

get_max_workers_target() {
	printf '%s\n' "${TEST_MAX_WORKERS:-1}"
	return 0
}

count_active_workers() {
	if [[ -n "${TEST_ACTIVE_WORKERS_SEQUENCE_FILE:-}" && -f "$TEST_ACTIVE_WORKERS_SEQUENCE_FILE" ]]; then
		local next remaining_file
		next=$(awk 'NR==1 {print; exit}' "$TEST_ACTIVE_WORKERS_SEQUENCE_FILE" 2>/dev/null)
		remaining_file="${TEST_ACTIVE_WORKERS_SEQUENCE_FILE}.next"
		awk 'NR>1 {print}' "$TEST_ACTIVE_WORKERS_SEQUENCE_FILE" >"$remaining_file" 2>/dev/null || : >"$remaining_file"
		mv "$remaining_file" "$TEST_ACTIVE_WORKERS_SEQUENCE_FILE"
		[[ -n "$next" ]] || next="${TEST_ACTIVE_WORKERS:-0}"
		printf '%s\n' "$next"
		return 0
	fi
	if [[ -n "${TEST_ACTIVE_WORKERS_SEQUENCE:-}" ]]; then
		local next="${TEST_ACTIVE_WORKERS_SEQUENCE%% *}"
		if [[ "$TEST_ACTIVE_WORKERS_SEQUENCE" == *" "* ]]; then
			TEST_ACTIVE_WORKERS_SEQUENCE="${TEST_ACTIVE_WORKERS_SEQUENCE#* }"
		else
			TEST_ACTIVE_WORKERS_SEQUENCE=""
		fi
		printf '%s\n' "$next"
		return 0
	fi
	printf '%s\n' "${TEST_ACTIVE_WORKERS:-0}"
	return 0
}

test_capacity_raises_soft_cap_to_floor() {
	TEST_MAX_WORKERS=1
	TEST_ACTIVE_WORKERS=2
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	unset _DISPATCH_MIN_WORKER_FLOOR_ACTIVE || true
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "6 2 4" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" == "1" ]]; then
		print_result "capacity: raises max_workers to floor while active below floor" 0
	else
		print_result "capacity: raises max_workers to floor while active below floor" 1 "result=${result} floor_active=${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-unset}"
	fi
	return 0
}

test_capacity_respects_existing_higher_cap() {
	TEST_MAX_WORKERS=10
	TEST_ACTIVE_WORKERS=2
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	unset _DISPATCH_MIN_WORKER_FLOOR_ACTIVE || true
	local result capacity_file
	capacity_file=$(mktemp)
	_dispatch_compute_capacity >"$capacity_file"
	result=$(<"$capacity_file")
	rm -f "$capacity_file"
	if [[ "$result" == "10 2 8" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" == "1" ]]; then
		print_result "capacity: existing max cap still wins above floor" 0
	else
		print_result "capacity: existing max cap still wins above floor" 1 "result=${result} floor_active=${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-unset}"
	fi
	return 0
}

test_throttle_does_not_force_serial_under_floor() {
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	: >"$_DISPATCH_THROTTLE_FILE"
	_DISPATCH_MIN_WORKER_FLOOR_ACTIVE=1
	unset DISPATCH_MAX_PARALLEL || true
	local result
	result=$(_dispatch_max_compute_parallel 6)
	rm -f "$_DISPATCH_THROTTLE_FILE"
	if [[ "$result" == "6" ]]; then
		print_result "parallel: throttle remains soft under minimum floor" 0
	else
		print_result "parallel: throttle remains soft under minimum floor" 1 "got=${result}"
	fi
	return 0
}

test_throttle_forces_serial_above_floor() {
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	: >"$_DISPATCH_THROTTLE_FILE"
	_DISPATCH_MIN_WORKER_FLOOR_ACTIVE=0
	unset DISPATCH_MAX_PARALLEL || true
	local result
	result=$(_dispatch_max_compute_parallel 6)
	rm -f "$_DISPATCH_THROTTLE_FILE"
	if [[ "$result" == "1" ]]; then
		print_result "parallel: throttle still forces serial outside floor" 0
	else
		print_result "parallel: throttle still forces serial outside floor" 1 "got=${result}"
	fi
	return 0
}

test_canary_preflight_bypasses_overload_only_below_floor() {
	local fake_helper worker_log
	fake_helper="${TEST_ROOT}/fake-headless-runtime-helper.sh"
	worker_log="${TEST_ROOT}/worker.log"
	cat >"$fake_helper" <<'EOF'
#!/usr/bin/env bash
if [[ "${AIDEVOPS_SKIP_CANARY_OVERLOAD_CHECK:-}" == "1" ]]; then
	exit 0
fi
exit 42
EOF
	chmod +x "$fake_helper"
	HEADLESS_RUNTIME_HELPER="$fake_helper"
	unset AIDEVOPS_SKIP_CANARY_OVERLOAD_CHECK AIDEVOPS_MIN_WORKER_FLOOR_BYPASS_ACTIVE || true
	TEST_ACTIVE_WORKERS=5
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	if _dlw_canary_preflight 100 "o/r" "$worker_log" "standard" ""; then
		print_result "canary: overload check bypassed below minimum floor" 0
	else
		print_result "canary: overload check bypassed below minimum floor" 1
	fi
	unset AIDEVOPS_SKIP_CANARY_OVERLOAD_CHECK AIDEVOPS_MIN_WORKER_FLOOR_BYPASS_ACTIVE || true
	TEST_ACTIVE_WORKERS=6
	if _dlw_canary_preflight 101 "o/r" "$worker_log" "standard" ""; then
		print_result "canary: overload check enforced at floor" 1 "unexpected success"
	else
		print_result "canary: overload check enforced at floor" 0
	fi
	return 0
}

test_apply_dispatch_refills_until_active_floor_after_partial_launch() {
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	TEST_ACTIVE_WORKERS_SEQUENCE_FILE="${TEST_ROOT}/active-sequence.txt"
	TEST_DISPATCH_CALLS_FILE="${TEST_ROOT}/dispatch-calls.txt"
	TEST_DISPATCH_RETURNS_FILE="${TEST_ROOT}/dispatch-returns.txt"
	printf '%s\n%s\n' 4 6 >"$TEST_ACTIVE_WORKERS_SEQUENCE_FILE"
	printf '%s\n' 0 >"$TEST_DISPATCH_CALLS_FILE"
	printf '%s\n%s\n' 2 2 >"$TEST_DISPATCH_RETURNS_FILE"
	STOP_FLAG="${HOME}/.aidevops/logs/stop"
	# shellcheck disable=SC2329  # Override sourced function for this regression.
	dispatch_max() {
		local calls next remaining_file
		calls=$(<"$TEST_DISPATCH_CALLS_FILE")
		[[ "$calls" =~ ^[0-9]+$ ]] || calls=0
		printf '%s\n' "$((calls + 1))" >"$TEST_DISPATCH_CALLS_FILE"
		next=$(awk 'NR==1 {print; exit}' "$TEST_DISPATCH_RETURNS_FILE" 2>/dev/null)
		remaining_file="${TEST_DISPATCH_RETURNS_FILE}.next"
		awk 'NR>1 {print}' "$TEST_DISPATCH_RETURNS_FILE" >"$remaining_file" 2>/dev/null || : >"$remaining_file"
		mv "$remaining_file" "$TEST_DISPATCH_RETURNS_FILE"
		[[ -n "$next" ]] || next=0
		printf '%s\n' "$next"
		return 0
	}
	# shellcheck disable=SC2329  # Override sourced function to keep the test fast.
	_adaptive_launch_settle_wait() {
		return 0
	}

	apply_dispatch_max

	local dispatch_calls
	dispatch_calls=$(<"$TEST_DISPATCH_CALLS_FILE")
	if [[ "$dispatch_calls" -eq 2 ]]; then
		print_result "apply: refills minimum active-worker floor after partial launch" 0
	else
		print_result "apply: refills minimum active-worker floor after partial launch" 1 "dispatch_calls=${dispatch_calls}"
	fi
	unset TEST_ACTIVE_WORKERS_SEQUENCE_FILE TEST_DISPATCH_CALLS_FILE TEST_DISPATCH_RETURNS_FILE
	return 0
}

write_recent_ledger_evidence() {
	local status="$1"
	local ledger_dir timestamp
	ledger_dir="${HOME}/.aidevops/.agent-workspace/tmp"
	mkdir -p "$ledger_dir"
	timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	printf '{"session_key":"test-canary","issue_number":"100","repo_slug":"o/r","pid":"1","dispatched_at":"%s","status":"%s","updated_at":"%s"}\n' \
		"$timestamp" "$status" "$timestamp" >"${ledger_dir}/dispatch-ledger.jsonl"
	return 0
}

test_soft_canary_failure_bypasses_with_recent_worker_evidence() {
	local fake_helper worker_log state_dir
	fake_helper="${TEST_ROOT}/fake-soft-canary.sh"
	worker_log="${TEST_ROOT}/worker-soft.log"
	state_dir="${HOME}/.aidevops/.agent-workspace/headless-runtime"
	cat >"$fake_helper" <<'EOF'
#!/usr/bin/env bash
state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
mkdir -p "$state_dir"
date +%s >"${state_dir}/canary-last-fail"
printf 'timeout\n' >"${state_dir}/canary-last-fail.reason"
exit 124
EOF
	chmod +x "$fake_helper"
	write_recent_ledger_evidence "in-flight"
	HEADLESS_RUNTIME_HELPER="$fake_helper"
	AIDEVOPS_HEADLESS_RUNTIME_DIR="$state_dir"
	TEST_ACTIVE_WORKERS=6
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	if _dlw_canary_preflight 102 "o/r" "$worker_log" "standard" ""; then
		print_result "canary: soft failure bypassed with recent worker evidence" 0
	else
		print_result "canary: soft failure bypassed with recent worker evidence" 1
	fi
	return 0
}

test_hard_canary_failure_blocks_despite_recent_worker_evidence() {
	local fake_helper worker_log state_dir
	fake_helper="${TEST_ROOT}/fake-hard-canary.sh"
	worker_log="${TEST_ROOT}/worker-hard.log"
	state_dir="${HOME}/.aidevops/.agent-workspace/headless-runtime"
	cat >"$fake_helper" <<'EOF'
#!/usr/bin/env bash
state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
mkdir -p "$state_dir"
date +%s >"${state_dir}/canary-last-fail"
printf 'auth_error\n' >"${state_dir}/canary-last-fail.reason"
exit 1
EOF
	chmod +x "$fake_helper"
	write_recent_ledger_evidence "completed"
	HEADLESS_RUNTIME_HELPER="$fake_helper"
	AIDEVOPS_HEADLESS_RUNTIME_DIR="$state_dir"
	TEST_ACTIVE_WORKERS=6
	AIDEVOPS_MIN_WORKER_CONCURRENCY=6
	if _dlw_canary_preflight 103 "o/r" "$worker_log" "standard" ""; then
		print_result "canary: hard failure blocks despite recent worker evidence" 1 "unexpected success"
	else
		print_result "canary: hard failure blocks despite recent worker evidence" 0
	fi
	return 0
}

test_capacity_raises_soft_cap_to_floor
test_capacity_respects_existing_higher_cap
test_throttle_does_not_force_serial_under_floor
test_throttle_forces_serial_above_floor
test_canary_preflight_bypasses_overload_only_below_floor
test_apply_dispatch_refills_until_active_floor_after_partial_launch
test_soft_canary_failure_bypasses_with_recent_worker_evidence
test_hard_canary_failure_blocks_despite_recent_worker_evidence

echo ""
echo "===================="
echo "Tests run: $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"
echo "===================="
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
else
	exit 1
fi
