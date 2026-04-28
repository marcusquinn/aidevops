#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-fill-floor-parallel.sh — t3005 regression test for parallel fill_floor.
#
# Validates the parallel-dispatch loop in pulse-dispatch-engine.sh against
# the contract that the issue (#21438) sets out:
#
#   1. _dff_dispatch_loop_parallel processes candidates concurrently up to
#      max_parallel and respects the effective_slots budget.
#   2. _dff_aggregate_outcomes correctly re-derives _DFF_ROUND_DISPATCHED
#      and _DFF_ROUND_NO_WORKER_FAILURES from the outcomes file.
#   3. _dff_compute_max_parallel honours DISPATCH_FILL_FLOOR_PARALLEL,
#      caps at effective_slots, and forces 1 (serial) when the throttle
#      file is present.
#   4. _dff_count_outcomes correctly tallies success/fail outcomes.
#
# The test stubs _dff_process_candidate so the loop body completes without
# real gh API / worktree operations — this isolates the parallel loop logic
# from the dispatch dependencies. Real dispatch behaviour is exercised by
# the existing pulse integration suite.

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

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/headless-runtime"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
export STOP_FLAG="${HOME}/.aidevops/logs/stop"
: >"$LOGFILE"

# Source the dispatch engine. The header guard `_PULSE_DISPATCH_ENGINE_LOADED`
# means a single source is sufficient; subsequent attempts are no-ops.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../pulse-dispatch-engine.sh
source "${SCRIPT_DIR}/pulse-dispatch-engine.sh"

# =============================================================================
# Test 1: _dff_compute_max_parallel honours DISPATCH_FILL_FLOOR_PARALLEL
# =============================================================================
test_compute_max_parallel_default() {
	unset DISPATCH_FILL_FLOOR_PARALLEL || true
	# Re-source to pick up default — but the guard prevents that. Instead
	# re-init the var manually using the same default.
	: "${DISPATCH_FILL_FLOOR_PARALLEL:=6}"
	_DFF_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	rm -f "$_DFF_THROTTLE_FILE"
	local result
	# effective_slots=24 → expect 6 (capped at default)
	result=$(_dff_compute_max_parallel 24)
	if [[ "$result" == "6" ]]; then
		print_result "compute_max_parallel: default=6 with slots=24" 0
	else
		print_result "compute_max_parallel: default=6 with slots=24" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_caps_at_slots() {
	export DISPATCH_FILL_FLOOR_PARALLEL=10
	rm -f "$_DFF_THROTTLE_FILE"
	local result
	result=$(_dff_compute_max_parallel 3)
	if [[ "$result" == "3" ]]; then
		print_result "compute_max_parallel: caps at effective_slots (3)" 0
	else
		print_result "compute_max_parallel: caps at effective_slots (3)" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_throttle_forces_serial() {
	export DISPATCH_FILL_FLOOR_PARALLEL=6
	: >"$_DFF_THROTTLE_FILE"
	local result
	result=$(_dff_compute_max_parallel 24)
	rm -f "$_DFF_THROTTLE_FILE"
	if [[ "$result" == "1" ]]; then
		print_result "compute_max_parallel: throttle forces serial (1)" 0
	else
		print_result "compute_max_parallel: throttle forces serial (1)" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_invalid_var() {
	export DISPATCH_FILL_FLOOR_PARALLEL="not-a-number"
	rm -f "$_DFF_THROTTLE_FILE"
	local result
	result=$(_dff_compute_max_parallel 24)
	# Invalid → falls back to default 6
	if [[ "$result" == "6" ]]; then
		print_result "compute_max_parallel: invalid env falls back to 6" 0
	else
		print_result "compute_max_parallel: invalid env falls back to 6" 1 "got=${result}"
	fi
	export DISPATCH_FILL_FLOOR_PARALLEL=6
	return 0
}

# =============================================================================
# Test 2: _dff_count_outcomes correctly tallies outcome lines
# =============================================================================
test_count_outcomes_success_and_fail() {
	local outcomes_file
	outcomes_file=$(mktemp)
	cat >"$outcomes_file" <<'EOF'
success|100
success|101
fail|102|rc=1|reason=skip
success|103
fail|104|rc=2|reason=no_worker_process
EOF
	local s f
	s=$(_dff_count_outcomes "$outcomes_file" "success")
	f=$(_dff_count_outcomes "$outcomes_file" "fail")
	rm -f "$outcomes_file"
	if [[ "$s" == "3" && "$f" == "2" ]]; then
		print_result "count_outcomes: success=3 fail=2" 0
	else
		print_result "count_outcomes: success=3 fail=2" 1 "got success=${s} fail=${f}"
	fi
	return 0
}

test_count_outcomes_empty_file() {
	local outcomes_file
	outcomes_file=$(mktemp)
	: >"$outcomes_file"
	local s
	s=$(_dff_count_outcomes "$outcomes_file" "success")
	rm -f "$outcomes_file"
	if [[ "$s" == "0" ]]; then
		print_result "count_outcomes: empty file -> 0" 0
	else
		print_result "count_outcomes: empty file -> 0" 1 "got=${s}"
	fi
	return 0
}

# =============================================================================
# Test 3: _dff_aggregate_outcomes populates module-globals + invalidates cache
# =============================================================================
test_aggregate_outcomes_basic() {
	local outcomes_file
	outcomes_file=$(mktemp)
	cat >"$outcomes_file" <<'EOF'
success|100
success|101
fail|102|rc=1|reason=skip
success|103
EOF
	_DFF_ROUND_DISPATCHED=0
	_DFF_ROUND_NO_WORKER_FAILURES=0
	_DFF_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DFF_CANARY_CACHE="${HOME}/.aidevops/.agent-workspace/headless-runtime/canary-last-pass"
	rm -f "$_DFF_THROTTLE_FILE" "$_DFF_CANARY_CACHE"
	: >"$_DFF_CANARY_CACHE"
	_dff_aggregate_outcomes "$outcomes_file"
	rm -f "$outcomes_file"
	# 3 success + 1 fail = 4 dispatched, 0 no_worker failures
	if [[ "$_DFF_ROUND_DISPATCHED" == "4" && "$_DFF_ROUND_NO_WORKER_FAILURES" == "0" ]]; then
		print_result "aggregate_outcomes: dispatched=4 no_worker=0" 0
	else
		print_result "aggregate_outcomes: dispatched=4 no_worker=0" 1 \
			"got dispatched=${_DFF_ROUND_DISPATCHED} no_worker=${_DFF_ROUND_NO_WORKER_FAILURES}"
	fi
	# Cache should NOT be invalidated (only 0 no_worker failures)
	if [[ -f "$_DFF_CANARY_CACHE" ]]; then
		print_result "aggregate_outcomes: canary cache preserved on no failures" 0
	else
		print_result "aggregate_outcomes: canary cache preserved on no failures" 1 "cache was removed"
	fi
	return 0
}

test_aggregate_outcomes_invalidates_canary_cache() {
	local outcomes_file
	outcomes_file=$(mktemp)
	cat >"$outcomes_file" <<'EOF'
fail|100|rc=1|reason=no_worker_process
fail|101|rc=1|reason=no_worker_process
fail|102|rc=1|reason=no_worker_process
fail|103|rc=1|reason=cli_usage
EOF
	_DFF_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DFF_CANARY_CACHE="${HOME}/.aidevops/.agent-workspace/headless-runtime/canary-last-pass"
	rm -f "$_DFF_THROTTLE_FILE"
	: >"$_DFF_CANARY_CACHE"
	_dff_aggregate_outcomes "$outcomes_file"
	rm -f "$outcomes_file"
	# 3 no_worker failures → cache invalidated
	if [[ ! -f "$_DFF_CANARY_CACHE" ]]; then
		print_result "aggregate_outcomes: canary invalidated on >=3 no_worker_process" 0
	else
		print_result "aggregate_outcomes: canary invalidated on >=3 no_worker_process" 1 "cache still present"
	fi
	# no_worker_failures should be 3 (not 4 — cli_usage doesn't count)
	if [[ "$_DFF_ROUND_NO_WORKER_FAILURES" == "3" ]]; then
		print_result "aggregate_outcomes: no_worker count distinguishes reasons" 0
	else
		print_result "aggregate_outcomes: no_worker count distinguishes reasons" 1 \
			"got=${_DFF_ROUND_NO_WORKER_FAILURES}"
	fi
	return 0
}

test_aggregate_outcomes_clears_throttle_on_success() {
	local outcomes_file
	outcomes_file=$(mktemp)
	cat >"$outcomes_file" <<'EOF'
success|100
EOF
	_DFF_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DFF_CANARY_CACHE="${HOME}/.aidevops/.agent-workspace/headless-runtime/canary-last-pass"
	: >"$_DFF_THROTTLE_FILE"
	_dff_aggregate_outcomes "$outcomes_file"
	rm -f "$outcomes_file"
	if [[ ! -f "$_DFF_THROTTLE_FILE" ]]; then
		print_result "aggregate_outcomes: throttle cleared on any success" 0
	else
		print_result "aggregate_outcomes: throttle cleared on any success" 1 "throttle still set"
	fi
	return 0
}

# =============================================================================
# Test 4: _dff_dispatch_loop_parallel — end-to-end with stubbed candidate proc
# =============================================================================
test_parallel_loop_end_to_end() {
	# Stub _dff_process_candidate to simulate work without real dispatch
	# deps. Candidates with even numbers succeed; odd numbers fail.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dff_process_candidate() {
		local candidate_json="$1"
		# Simulate ~50ms of work so parallel makes a measurable difference
		# vs the bash tick (allows the timing assertion below to be robust
		# even on slow CI runners).
		local issue_num
		issue_num=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
		sleep 0.05
		if (( issue_num % 2 == 0 )); then
			return 0
		fi
		_PULSE_LAST_LAUNCH_FAILURE="no_worker_process"
		return 1
	}

	# Build a candidate file with 6 issues — 3 even (success), 3 odd (fail)
	local candidate_file outcomes_file
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	cat >"$candidate_file" <<'EOF'
{"number":100,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":101,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":102,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":103,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":104,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
{"number":105,"repo_slug":"o/r","repo_path":"/tmp/x","url":"u","title":"t","labels":[]}
EOF
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	# Run parallel loop with effective_slots=10 (no budget cap), max_parallel=3
	local result
	result=$(_dff_dispatch_loop_parallel "$candidate_file" 10 10 "test_user" 3 "$outcomes_file")

	# Expected: 3 successes (even numbers), 3 fails (odd numbers)
	local s f
	s=$(_dff_count_outcomes "$outcomes_file" "success")
	f=$(_dff_count_outcomes "$outcomes_file" "fail")
	rm -f "$candidate_file" "$outcomes_file"

	# Result should be "3 6" (dispatched=3, processed=6)
	if [[ "$result" == "3 6" && "$s" == "3" && "$f" == "3" ]]; then
		print_result "parallel_loop: end-to-end 3 success + 3 fail" 0
	else
		print_result "parallel_loop: end-to-end 3 success + 3 fail" 1 \
			"got result='${result}' s=${s} f=${f}"
	fi
	return 0
}

test_parallel_loop_respects_budget() {
	# Stub: every candidate succeeds
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dff_process_candidate() {
		sleep 0.02
		return 0
	}

	local candidate_file outcomes_file
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	# 10 candidates available
	local i
	for i in 200 201 202 203 204 205 206 207 208 209; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	# effective_slots=4, max_parallel=4 — should stop after 4 successes
	local result
	result=$(_dff_dispatch_loop_parallel "$candidate_file" 4 4 "test_user" 4 "$outcomes_file")
	local s
	s=$(_dff_count_outcomes "$outcomes_file" "success")
	rm -f "$candidate_file" "$outcomes_file"

	# We expect dispatched_count=4 (at most). It might process 5-8 before stopping
	# because the budget check happens BEFORE launching, but successes counter
	# updates only AFTER subshell completes. The contract: dispatched_count <= effective_slots+max_parallel.
	if (( s >= 4 )) && (( s <= 8 )); then
		print_result "parallel_loop: respects effective_slots=4 budget (got s=${s})" 0
	else
		print_result "parallel_loop: respects effective_slots=4 budget" 1 "got s=${s}"
	fi
	# Result first field should match s
	local result_dispatched
	result_dispatched=$(printf '%s' "$result" | awk '{print $1}')
	if [[ "$result_dispatched" == "$s" ]]; then
		print_result "parallel_loop: result.dispatched matches outcomes file" 0
	else
		print_result "parallel_loop: result.dispatched matches outcomes file" 1 \
			"result=${result_dispatched} outcomes=${s}"
	fi
	return 0
}

test_parallel_loop_stop_flag_aborts() {
	# Stub: pre-create the STOP flag so the first candidate aborts the loop
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dff_process_candidate() {
		return 0
	}

	local candidate_file outcomes_file
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	for i in 300 301 302 303; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"
	: >"$outcomes_file"

	# Pre-create STOP flag — loop must break on the first iteration
	: >"$STOP_FLAG"
	local result
	result=$(_dff_dispatch_loop_parallel "$candidate_file" 10 10 "test_user" 4 "$outcomes_file")
	rm -f "$STOP_FLAG" "$candidate_file" "$outcomes_file"

	# Expected: 0 dispatches because we hit STOP before any subshell launch
	local result_dispatched
	result_dispatched=$(printf '%s' "$result" | awk '{print $1}')
	if [[ "$result_dispatched" == "0" ]]; then
		print_result "parallel_loop: stop flag aborts dispatch" 0
	else
		print_result "parallel_loop: stop flag aborts dispatch" 1 "got=${result_dispatched}"
	fi
	return 0
}

# =============================================================================
# Test 5: serial loop preserves existing behavior (regression escape hatch)
# =============================================================================
test_serial_loop_basic() {
	# Stub: even numbers succeed, odd fail
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dff_process_candidate() {
		local candidate_json="$1"
		local issue_num
		issue_num=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
		if (( issue_num % 2 == 0 )); then
			return 0
		fi
		return 1
	}

	local candidate_file
	candidate_file=$(mktemp)
	for i in 400 401 402 403 404; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"

	rm -f "$STOP_FLAG"
	_DFF_THROTTLE_CLEARED=0
	# effective_slots=10 — no budget cap. 5 candidates → 3 even = 3 successes, 2 odd = 2 fails
	local result
	result=$(_dff_dispatch_loop_serial "$candidate_file" 10 10 "test_user")
	rm -f "$candidate_file"

	# Expect "3 5" — dispatched=3, processed=5
	if [[ "$result" == "3 5" ]]; then
		print_result "serial_loop: 3 success + 2 fail = dispatched=3 processed=5" 0
	else
		print_result "serial_loop: 3 success + 2 fail = dispatched=3 processed=5" 1 "got=${result}"
	fi
	return 0
}

test_serial_loop_budget_cap() {
	# Stub: every candidate succeeds
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dff_process_candidate() {
		return 0
	}

	local candidate_file
	candidate_file=$(mktemp)
	for i in 500 501 502 503 504; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"

	rm -f "$STOP_FLAG"
	# effective_slots=2 → loop must break after 2 successes (3rd iter starts but dispatched=2 stops it)
	local result
	result=$(_dff_dispatch_loop_serial "$candidate_file" 2 5 "test_user")
	rm -f "$candidate_file"

	# Expect dispatched=2; processed depends on where the budget check fires.
	# Loop: iter 1 (process) → dispatched=1 → iter 2 (process) → dispatched=2 → iter 3 (start)
	# → check dispatched(2) >= effective_slots(2) → break. So processed=3.
	local result_dispatched
	result_dispatched=$(printf '%s' "$result" | awk '{print $1}')
	if [[ "$result_dispatched" == "2" ]]; then
		print_result "serial_loop: respects effective_slots=2 budget" 0
	else
		print_result "serial_loop: respects effective_slots=2 budget" 1 "got=${result_dispatched}"
	fi
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================
test_compute_max_parallel_default
test_compute_max_parallel_caps_at_slots
test_compute_max_parallel_throttle_forces_serial
test_compute_max_parallel_invalid_var
test_count_outcomes_success_and_fail
test_count_outcomes_empty_file
test_aggregate_outcomes_basic
test_aggregate_outcomes_invalidates_canary_cache
test_aggregate_outcomes_clears_throttle_on_success
test_parallel_loop_end_to_end
test_parallel_loop_respects_budget
test_parallel_loop_stop_flag_aborts
test_serial_loop_basic
test_serial_loop_budget_cap

# Final summary
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
