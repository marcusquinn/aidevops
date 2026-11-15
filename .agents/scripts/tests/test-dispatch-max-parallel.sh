#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-max-parallel.sh — t3005 regression test for parallel fill_floor.
#
# Validates the parallel-dispatch loop in pulse-dispatch-engine.sh against
# the contract that the issue (#21438) sets out:
#
#   1. _dispatch_max_loop processes candidates concurrently up to
#      max_parallel and respects the effective_slots budget.
#   2. _dispatch_max_aggregate_outcomes correctly re-derives _DISPATCH_ROUND_DISPATCHED
#      and _DISPATCH_ROUND_NO_WORKER_FAILURES from the outcomes file.
#   3. _dispatch_max_compute_parallel honours DISPATCH_MAX_PARALLEL,
#      caps at effective_slots, and forces 1 (serial) when the throttle
#      file is present.
#   4. _dispatch_max_count_outcomes correctly tallies success/fail outcomes.
#
# The test stubs _dispatch_process_candidate so the loop body completes without
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

# Keep REST launch checks isolated from live GitHub evidence. Dedicated cases
# below override these stubs to exercise reserve serialization and loop stops.
pulse_rest_core_priority_snapshot() {
	printf 'disabled ? ? 0 0 0 ?\n'
	return 0
}
_dispatch_rest_core_progress_allows_next() {
	return 0
}

# Keep loop tests isolated from live API budget evidence. The dedicated budget
# gate case below overrides this helper to verify the stop path explicitly.
_dispatch_graphql_budget_allows_next() {
	return 0
}

# =============================================================================
# Test 1: _dispatch_max_compute_parallel honours DISPATCH_MAX_PARALLEL
# =============================================================================
test_compute_max_parallel_default() {
	# GH#29234: unset defaults to the conservative ceremony cap of 6 rather
	# than treating the full worker-slot budget as safe launch parallelism.
	unset DISPATCH_MAX_PARALLEL || true
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	# effective_slots=24 → expect the default ceremony cap of 6.
	result=$(_dispatch_max_compute_parallel 24)
	if [[ "$result" == "6" ]]; then
		print_result "compute_max_parallel: default=6 when unset" 0
	else
		print_result "compute_max_parallel: default=6 when unset" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_default_caps_at_slots() {
	unset DISPATCH_MAX_PARALLEL || true
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 3)
	if [[ "$result" == "3" ]]; then
		print_result "compute_max_parallel: default caps at effective_slots (3)" 0
	else
		print_result "compute_max_parallel: default caps at effective_slots (3)" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_override() {
	export DISPATCH_MAX_PARALLEL=10
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 24)
	if [[ "$result" == "10" ]]; then
		print_result "compute_max_parallel: explicit positive override wins" 0
	else
		print_result "compute_max_parallel: explicit positive override wins" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_caps_at_slots() {
	export DISPATCH_MAX_PARALLEL=10
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 3)
	if [[ "$result" == "3" ]]; then
		print_result "compute_max_parallel: caps at effective_slots (3)" 0
	else
		print_result "compute_max_parallel: caps at effective_slots (3)" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_throttle_forces_serial() {
	export DISPATCH_MAX_PARALLEL=6
	: >"$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 24)
	rm -f "$_DISPATCH_THROTTLE_FILE"
	if [[ "$result" == "1" ]]; then
		print_result "compute_max_parallel: throttle forces serial (1)" 0
	else
		print_result "compute_max_parallel: throttle forces serial (1)" 1 "got=${result}"
	fi
	return 0
}

test_compute_max_parallel_invalid_var() {
	# Invalid input follows the same conservative default as unset input.
	export DISPATCH_MAX_PARALLEL="not-a-number"
	rm -f "$_DISPATCH_THROTTLE_FILE"
	local result
	result=$(_dispatch_max_compute_parallel 24)
	if [[ "$result" == "6" ]]; then
		print_result "compute_max_parallel: invalid env falls back to 6" 0
	else
		print_result "compute_max_parallel: invalid env falls back to 6" 1 "got=${result}"
	fi
	unset DISPATCH_MAX_PARALLEL || true
	return 0
}

test_compute_max_parallel_rest_reserve_forces_serial() {
	export DISPATCH_MAX_PARALLEL=6
	rm -f "$_DISPATCH_THROTTLE_FILE"
	# These fixtures use the documented 250-point allowance, independently of
	# the runner's configured allowance. Restore the real helper afterwards.
	local saved_allowance=""
	saved_allowance=$(declare -f _cb_rest_core_in_flight_allowance) || true
	_cb_rest_core_in_flight_allowance() { printf '250\n'; return 0; }
	pulse_rest_core_priority_snapshot() {
		printf 'normal 700 5000 200 500 100 9999999999\n'
		return 0
	}
	local reserve_result healthy_result
	reserve_result=$(_dispatch_max_compute_parallel 24)
	pulse_rest_core_priority_snapshot() {
		printf 'normal 751 5000 200 500 100 9999999999\n'
		return 0
	}
	healthy_result=$(_dispatch_max_compute_parallel 24)
	unset -f _cb_rest_core_in_flight_allowance
	[[ -z "$saved_allowance" ]] || eval "$saved_allowance"
	pulse_rest_core_priority_snapshot() {
		printf 'disabled ? ? 0 0 0 ?\n'
		return 0
	}
	if [[ "$reserve_result" == "1" && "$healthy_result" == "6" ]]; then
		print_result "compute_max_parallel: REST reserve-adjacent zone forces serial" 0
	else
		print_result "compute_max_parallel: REST reserve-adjacent zone forces serial" 1 "reserve=${reserve_result} healthy=${healthy_result}"
	fi
	return 0
}

# =============================================================================
# Test 2: _dispatch_max_count_outcomes correctly tallies outcome lines
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
	s=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	f=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
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
	s=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	rm -f "$outcomes_file"
	if [[ "$s" == "0" ]]; then
		print_result "count_outcomes: empty file -> 0" 0
	else
		print_result "count_outcomes: empty file -> 0" 1 "got=${s}"
	fi
	return 0
}

test_wait_tracked_pids_suppresses_stale_child() {
	local stale_pid stderr_file rc stderr_output
	stderr_file=$(mktemp)
	(
		exit 0
	) &
	stale_pid=$!
	wait "$stale_pid" 2>/dev/null || true
	rc=0
	_dispatch_max_wait_tracked_pids "$stale_pid" 2>"$stderr_file" || rc=$?
	stderr_output=$(cat "$stderr_file" 2>/dev/null || true)
	rm -f "$stderr_file"
	if [[ "$rc" -eq 0 && -z "$stderr_output" ]]; then
		print_result "wait_tracked_pids: suppresses stale child stderr" 0
	else
		print_result "wait_tracked_pids: suppresses stale child stderr" 1 "rc=${rc} stderr=${stderr_output}"
	fi
	return 0
}

# GH#35698: output/status must retain command-substitution semantics, including
# budget deferral and candidate timeout; only the calling supervisor heartbeats.
test_owner_capture_contract() {
	local rc=0
	(
		local owner="$BASHPID" captured="" status=0 expected
		local calls="${TEST_ROOT}/owner-heartbeats"
		_pulse_cycle_state_stage_heartbeat() {
			[[ "$BASHPID" == "$owner" ]] || return 1
			printf '%s\n' "$BASHPID" >>"$calls"
			return 1 # Rejected health writes must not change dispatch status.
		}
		capture_candidate() {
			local result="$1" argument="$2" input=""
			[[ "$BASHPID" != "$owner" && "$argument" == skip ]] || return 99
			read -r input
			[[ "$input" == capture-input ]] || return 98
			printf '2\n\n'
			return "$result"
		}
		for expected in 0 1 3 124 127; do
			status=0
			_dispatch_capture_with_owner_liveness captured capture_candidate "$expected" skip <<<capture-input || status=$?
			[[ "$captured" == 2 && "$status" == "$expected" ]] || exit 1
		done
		[[ -s "$calls" ]] || exit 1
	) || rc=1
	print_result "owner_capture: child execution, output, wait/deadline statuses and rejected heartbeats preserved" "$rc"
	return 0
}

test_parallel_wait_failure_contract() {
	local rc=0
	(
		local pids=(99999999) refreshed=0
		wait() { return 127; }
		sleep() { return 0; }
		_dispatch_max_refresh_pids() {
			refreshed=$((refreshed + 1))
			return 0
		}
		_dispatch_max_wait_for_capacity pids 1
		[[ "${#pids[@]}" == 0 && "$refreshed" -gt 0 ]] || exit 1
		refreshed=0
		_dispatch_max_wait_for_reservation pids
		[[ "$refreshed" == 1 ]] || exit 1
		_dispatch_max_wait_tracked_pids 99999999 || exit 1
	) || rc=1
	print_result "parallel_waits: capacity failure purges, reservation reconciles and final drain suppresses stale child" "$rc"
	return 0
}

# =============================================================================
# Test 3: _dispatch_max_aggregate_outcomes populates module-globals + invalidates cache
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
	_DISPATCH_ROUND_DISPATCHED=0
	_DISPATCH_ROUND_NO_WORKER_FAILURES=0
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DISPATCH_CANARY_CACHE="${HOME}/.aidevops/.agent-workspace/headless-runtime/canary-last-pass"
	rm -f "$_DISPATCH_THROTTLE_FILE" "$_DISPATCH_CANARY_CACHE"
	: >"$_DISPATCH_CANARY_CACHE"
	_dispatch_max_aggregate_outcomes "$outcomes_file"
	rm -f "$outcomes_file"
	# 3 success + 1 fail = 4 dispatched, 0 no_worker failures
	if [[ "$_DISPATCH_ROUND_DISPATCHED" == "4" && "$_DISPATCH_ROUND_NO_WORKER_FAILURES" == "0" ]]; then
		print_result "aggregate_outcomes: dispatched=4 no_worker=0" 0
	else
		print_result "aggregate_outcomes: dispatched=4 no_worker=0" 1 \
			"got dispatched=${_DISPATCH_ROUND_DISPATCHED} no_worker=${_DISPATCH_ROUND_NO_WORKER_FAILURES}"
	fi
	# Cache should NOT be invalidated (only 0 no_worker failures)
	if [[ -f "$_DISPATCH_CANARY_CACHE" ]]; then
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
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DISPATCH_CANARY_CACHE="${HOME}/.aidevops/.agent-workspace/headless-runtime/canary-last-pass"
	rm -f "$_DISPATCH_THROTTLE_FILE"
	: >"$_DISPATCH_CANARY_CACHE"
	_dispatch_max_aggregate_outcomes "$outcomes_file"
	rm -f "$outcomes_file"
	# 3 no_worker failures → cache invalidated
	if [[ ! -f "$_DISPATCH_CANARY_CACHE" ]]; then
		print_result "aggregate_outcomes: canary invalidated on >=3 no_worker_process" 0
	else
		print_result "aggregate_outcomes: canary invalidated on >=3 no_worker_process" 1 "cache still present"
	fi
	# no_worker_failures should be 3 (not 4 — cli_usage doesn't count)
	if [[ "$_DISPATCH_ROUND_NO_WORKER_FAILURES" == "3" ]]; then
		print_result "aggregate_outcomes: no_worker count distinguishes reasons" 0
	else
		print_result "aggregate_outcomes: no_worker count distinguishes reasons" 1 \
			"got=${_DISPATCH_ROUND_NO_WORKER_FAILURES}"
	fi
	return 0
}

test_aggregate_outcomes_clears_throttle_on_success() {
	local outcomes_file
	outcomes_file=$(mktemp)
	cat >"$outcomes_file" <<'EOF'
success|100
EOF
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DISPATCH_CANARY_CACHE="${HOME}/.aidevops/.agent-workspace/headless-runtime/canary-last-pass"
	: >"$_DISPATCH_THROTTLE_FILE"
	_dispatch_max_aggregate_outcomes "$outcomes_file"
	rm -f "$outcomes_file"
	if [[ ! -f "$_DISPATCH_THROTTLE_FILE" ]]; then
		print_result "aggregate_outcomes: throttle cleared on any success" 0
	else
		print_result "aggregate_outcomes: throttle cleared on any success" 1 "throttle still set"
	fi
	return 0
}

# =============================================================================
# Test 4: _dispatch_max_loop — end-to-end with stubbed candidate proc
# =============================================================================
test_parallel_loop_end_to_end() {
	# Stub _dispatch_process_candidate to simulate work without real dispatch
	# deps. Candidates with even numbers succeed; odd numbers fail.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
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
	result=$(_dispatch_max_loop "$candidate_file" 10 10 "test_user" 3 "$outcomes_file")

	# Expected: 3 successes (even numbers), 3 fails (odd numbers)
	local s f
	s=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	f=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
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
	_dispatch_process_candidate() {
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
	result=$(_dispatch_max_loop "$candidate_file" 4 4 "test_user" 4 "$outcomes_file")
	local s
	s=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	rm -f "$candidate_file" "$outcomes_file"

	# Pending ceremonies reserve capacity, so a successful four-slot wave launches
	# exactly four workers rather than overshooting while outcomes are in flight.
	if [[ "$s" == "4" ]]; then
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

test_parallel_loop_refills_rejected_reservation() {
	# The first success and slow rejection consume both reservations. The final
	# candidate must be retried after the rejection frees its slot.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		local candidate_json="$1" issue_num
		issue_num=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
		if [[ "$issue_num" == "801" ]]; then
			sleep 0.15
			_PULSE_LAST_LAUNCH_FAILURE="no_worker_process"
			return 1
		fi
		sleep 0.02
		return 0
	}

	local candidate_file outcomes_file result successes failures
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	cat >"$candidate_file" <<'EOF'
{"number":800,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
{"number":801,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
{"number":802,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
EOF
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	result=$(_dispatch_max_loop "$candidate_file" 2 2 "test_user" 2 "$outcomes_file")
	successes=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	failures=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
	rm -f "$candidate_file" "$outcomes_file"

	if [[ "$result" == "2 3" && "$successes" == "2" && "$failures" == "1" ]]; then
		print_result "parallel_loop: refills a rejected reservation in the same round" 0
	else
		print_result "parallel_loop: refills a rejected reservation in the same round" 1 \
			"result=${result} successes=${successes} failures=${failures}"
	fi
	return 0
}

test_parallel_loop_all_rejections_finish() {
	# Reconciliation must consume a finite queue of rejected ceremonies without
	# spinning after each reservation is released.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		sleep 0.02
		_PULSE_LAST_LAUNCH_FAILURE="no_worker_process"
		return 1
	}

	local candidate_file outcomes_file result failures
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	cat >"$candidate_file" <<'EOF'
{"number":810,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
{"number":811,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
{"number":812,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}
EOF
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	result=$(_dispatch_max_loop "$candidate_file" 2 2 "test_user" 2 "$outcomes_file")
	failures=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
	rm -f "$candidate_file" "$outcomes_file"

	if [[ "$result" == "0 3" && "$failures" == "3" ]]; then
		print_result "parallel_loop: all rejected candidates finish without spinning" 0
	else
		print_result "parallel_loop: all rejected candidates finish without spinning" 1 \
			"result=${result} failures=${failures}"
	fi
	return 0
}

test_parallel_loop_stop_flag_aborts() {
	# Stub: pre-create the STOP flag so the first candidate aborts the loop
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
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
	result=$(_dispatch_max_loop "$candidate_file" 10 10 "test_user" 4 "$outcomes_file")
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

test_parallel_loop_graphql_budget_aborts() {
	# Stub: every candidate would succeed if the budget gate allowed launch.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		return 0
	}
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_graphql_budget_allows_next() {
		return 1
	}

	local candidate_file outcomes_file
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	for i in 320 321 322 323; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	local result
	result=$(_dispatch_max_loop "$candidate_file" 10 10 "test_user" 4 "$outcomes_file")
	rm -f "$candidate_file" "$outcomes_file"
	# Restore the default test isolation stub for later loop cases.
	_dispatch_graphql_budget_allows_next() {
		return 0
	}

	if [[ "$result" == "0 1" ]]; then
		print_result "parallel_loop: GraphQL budget gate aborts before launch" 0
	else
		print_result "parallel_loop: GraphQL budget gate aborts before launch" 1 "got=${result}"
	fi
	return 0
}

test_parallel_loop_rest_budget_aborts() {
	_dispatch_process_candidate() {
		return 0
	}
	_dispatch_rest_core_progress_allows_next() {
		return 1
	}

	local candidate_file outcomes_file result
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	printf '%s\n' '{"number":325,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}' >"$candidate_file"
	: >"$outcomes_file"
	rm -f "$STOP_FLAG"
	result=$(_dispatch_max_loop "$candidate_file" 10 10 "test_user" 4 "$outcomes_file")
	rm -f "$candidate_file" "$outcomes_file"
	_dispatch_rest_core_progress_allows_next() {
		return 0
	}

	if [[ "$result" == "0 1" ]]; then
		print_result "parallel_loop: REST launch gate aborts before launch" 0
	else
		print_result "parallel_loop: REST launch gate aborts before launch" 1 "got=${result}"
	fi
	return 0
}

test_dispatch_with_timeout_noop_outcome() {
	local capture_dir old_path rc capture
	capture_dir=$(mktemp -d)
	old_path="$PATH"
	cat >"${capture_dir}/dispatch-timing-helper.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DISPATCH_TIMING_CAPTURE}"
exit 0
EOF
	chmod +x "${capture_dir}/dispatch-timing-helper.sh"
	export PATH="${capture_dir}:$PATH"
	export DISPATCH_TIMING_CAPTURE="${capture_dir}/capture.txt"
	export DISPATCH_TIMING_ADAPTIVE=0
	export DISPATCH_PER_CANDIDATE_TIMEOUT=5
	export DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR=1
	# shellcheck disable=SC2317  # called via _dispatch_with_timeout
	dispatch_with_dedup() {
		return 2
	}
	# shellcheck disable=SC2317  # called via _dispatch_with_timeout
	run_stage_with_timeout() {
		shift 2
		"$@"
		return $?
	}

	rc=0
	_dispatch_with_timeout 330 "o/r" "Issue #330" "title" "me" "/tmp/repo" "prompt" "issue-330" "" || rc=$?
	capture=$(cat "$DISPATCH_TIMING_CAPTURE" 2>/dev/null || true)
	PATH="$old_path"
	export PATH
	unset DISPATCH_TIMING_CAPTURE DISPATCH_TIMING_ADAPTIVE DISPATCH_PER_CANDIDATE_TIMEOUT DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR
	unset -f dispatch_with_dedup run_stage_with_timeout
	rm -rf "$capture_dir"

	if [[ "$rc" -eq 2 && "$capture" == *"--outcome noop"* ]]; then
		print_result "dispatch_with_timeout: rc=2 records noop outcome" 0
	else
		print_result "dispatch_with_timeout: rc=2 records noop outcome" 1 "rc=${rc} capture=${capture}"
	fi
	return 0
}

# GH#34428: run one cycle-floor scenario. Called in a subshell so the real
# watchdog helpers and the stubs below do not leak into later tests.
# Args: cycle seconds remaining after the finalise reserve, capture directory
_run_dispatch_cycle_floor_scenario() {
	local remaining="$1" capture_dir="$2" rc=0
	# shellcheck source=../pulse-watchdog.sh
	source "${SCRIPT_DIR}/pulse-watchdog.sh"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/timing.txt"\nexit 0\n' "$capture_dir" >"${capture_dir}/dispatch-timing-helper.sh"
	chmod +x "${capture_dir}/dispatch-timing-helper.sh"
	export PATH="${capture_dir}:$PATH"
	export DISPATCH_TIMING_ADAPTIVE=0 DISPATCH_PER_CANDIDATE_TIMEOUT=30 DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR=600
	export AIDEVOPS_PULSE_CYCLE_FINALISE_RESERVE_S=90 PULSE_STALE_THRESHOLD=$((remaining + 90)) PULSE_LOCK_MAX_AGE_S=86400
	export PULSE_START_EPOCH
	PULSE_START_EPOCH=$(date +%s)
	# shellcheck disable=SC2317  # called via _dispatch_with_timeout
	dispatch_with_dedup() {
		printf 'called\n' >>"${capture_dir}/calls.txt"
		return 0
	}
	# shellcheck disable=SC2317  # called via _dispatch_with_timeout
	run_stage_with_timeout() {
		printf '%s\n' "$2" >"${capture_dir}/stage-timeout.txt"
		shift 2
		"$@"
		return $?
	}
	# shellcheck disable=SC2317  # called via _dispatch_stats_increment
	pulse_stats_increment() {
		printf '%s\n' "$1" >>"${capture_dir}/counters.txt"
		return 0
	}
	_dispatch_with_timeout 340 "o/r" "Issue #340" "title" "me" "/tmp/repo" "prompt" "issue-340" "" || rc=$?
	printf '%s\n' "$rc" >"${capture_dir}/rc.txt"
	: >"${capture_dir}/outcomes.txt"
	_dispatch_record_candidate_outcome '{"number":340,"repo_slug":"o/r"}' "$rc" "${capture_dir}/outcomes.txt" || true
	_dispatch_max_aggregate_outcomes "${capture_dir}/outcomes.txt"
	printf '%s\n' "$_DISPATCH_ROUND_DISPATCHED" >"${capture_dir}/round.txt"
	return 0
}

# GH#34428: the per-candidate floor is re-checked where the stage starts.
# Args: cycle seconds remaining after the finalise reserve, expected result
# ("defer" or "run").
test_dispatch_with_timeout_cycle_floor() {
	local remaining="$1" expected="$2" capture_dir rc="" stage_timeout="" calls="" counters="" timing=""
	local outcome_line="" fails=""
	capture_dir=$(mktemp -d)
	: >"$LOGFILE"
	(_run_dispatch_cycle_floor_scenario "$remaining" "$capture_dir")
	rc=$(cat "${capture_dir}/rc.txt" 2>/dev/null || true)
	outcome_line=$(cat "${capture_dir}/outcomes.txt" 2>/dev/null || true)
	fails=$(cat "${capture_dir}/round.txt" 2>/dev/null || true)
	stage_timeout=$(cat "${capture_dir}/stage-timeout.txt" 2>/dev/null || true)
	calls=$(cat "${capture_dir}/calls.txt" 2>/dev/null || true)
	counters=$(cat "${capture_dir}/counters.txt" 2>/dev/null || true)
	timing=$(cat "${capture_dir}/timing.txt" 2>/dev/null || true)
	rm -rf "$capture_dir"
	[[ "$rc" =~ ^[0-9]+$ ]] || rc=999
	[[ "$fails" =~ ^[0-9]+$ ]] || fails=999
	[[ "$stage_timeout" =~ ^[0-9]+$ ]] || stage_timeout=0

	local name="dispatch_with_timeout: ${remaining}s remaining -> ${expected}"
	if [[ "$expected" == defer ]]; then
		if [[ "$rc" -eq "$_DISPATCH_CYCLE_BUDGET_DEFER_RC" && -z "$calls" && "$stage_timeout" -eq 0 && -z "$timing" &&
			"$counters" == "dispatch_candidate_deferred_cycle_budget" && "$fails" -eq 0 &&
			"$outcome_line" == "defer|340|rc=75|reason=cycle_budget_floor|"* ]] &&
			grep -Eq "deferring #340 \(o/r\) — cycle budget 5[0-9]{2}s below per-candidate floor 600s" "$LOGFILE"; then
			print_result "$name" 0
		else
			print_result "$name" 1 "rc=${rc} calls=${calls} stage=${stage_timeout} counters=${counters} timing=${timing} round=${fails} outcome=${outcome_line}"
		fi
	elif [[ "$rc" -eq 0 && "$calls" == called && "$stage_timeout" -ge 600 && "$outcome_line" == "success|340|"* ]] &&
		! grep -q "deferring #340" "$LOGFILE"; then
		print_result "$name" 0
	else
		print_result "$name" 1 "rc=${rc} calls=${calls} stage=${stage_timeout} outcome=${outcome_line}"
	fi
	return 0
}

# GH#34428: no failure classifier/cache or later phase sees a deferred attempt.
test_dispatch_cycle_deferral_accounting() {
	local rc=0
	(
		local candidate='{"number":340,"repo_slug":"o/r","repo_priority":"product"}'
		local outcomes="${TEST_ROOT}/deferred.outcomes" candidates="${TEST_ROOT}/deferred.candidates"
		local classified=0 cached=0 cleared=0 result=0 product_result=""
		_dispatch_record_nonzero_dispatch_result() { classified=$((classified + 1)); return 0; }
		_dispatch_cache_confirmed_block() { cached=$((cached + 1)); return 0; }
		_dispatch_attempt_recency_clear() { cleared=$((cleared + 1)); return 0; }
		_dispatch_record_and_cache_block "$candidate" 340 o/r "$_DISPATCH_CYCLE_BUDGET_DEFER_RC" || result=$?
		[[ "$result" -eq 75 && "$classified" -eq 0 && "$cached" -eq 0 && "$cleared" -eq 1 ]] || exit 1
		printf '%s\n' "$candidate" >"$candidates"
		: >"$outcomes"
		_dispatch_record_candidate_outcome "$candidate" "$result" "$outcomes" || exit 1
		[[ -z "$(_dispatch_priority_phase_candidates "$candidates" "$outcomes" remainder)" ]] || exit 1
		product_result=$(_dispatch_priority_product_outcomes "$outcomes")
		[[ "$product_result" == '0 0' ]] || exit 1
		_dispatch_max_aggregate_outcomes "$outcomes"
		[[ "$_DISPATCH_ROUND_DISPATCHED" -eq 0 && "$_DISPATCH_ROUND_NO_WORKER_FAILURES" -eq 0 ]] || exit 1
		# Empty next-cycle outcomes restore eligibility without a backoff cache.
		: >"$outcomes"
		[[ "$(_dispatch_priority_phase_candidates "$candidates" "$outcomes" remainder)" == "$candidate" ]] || exit 1
	) || rc=1
	print_result "cycle deferral: no failure/cache, no same-cycle retry, eligible next cycle" "$rc"
	return 0
}

test_dispatch_cycle_floor_clock_fallback() {
	local rc=0
	(
		local DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR=600
		unset -f _pulse_cycle_remaining_seconds
		_dispatch_cycle_budget_defers_candidate 340 o/r && exit 1
		_pulse_cycle_remaining_seconds() { return 1; }
		_dispatch_cycle_budget_defers_candidate 340 o/r && exit 1
		_pulse_cycle_remaining_seconds() { printf 'invalid\n'; return 0; }
		_dispatch_cycle_budget_defers_candidate 340 o/r && exit 1
		_pulse_cycle_remaining_seconds() { printf '600\n'; return 0; }
		_dispatch_cycle_budget_defers_candidate 340 o/r && exit 1
		DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR=601
		_dispatch_cycle_budget_defers_candidate 340 o/r && exit 1
		_pulse_cycle_remaining_seconds() { printf '599\n'; return 0; }
		_dispatch_cycle_budget_defers_candidate 340 o/r || exit 1
		return 0
	) || rc=1
	print_result "cycle floor: unavailable/failed/invalid clocks fail open, configured boundary honoured" "$rc"
	return 0
}

# =============================================================================
# Test 5: serial loop preserves existing behavior (regression escape hatch)
# =============================================================================
test_serial_loop_basic() {
	# Stub: even numbers succeed, odd fail
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
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
	_DISPATCH_THROTTLE_CLEARED=0
	# effective_slots=10 — no budget cap. 5 candidates → 3 even = 3 successes, 2 odd = 2 fails
	local result
	result=$(_dispatch_floor_loop "$candidate_file" 10 10 "test_user")
	rm -f "$candidate_file"

	# Expect "3 5" — dispatched=3, processed=5
	if [[ "$result" == "3 5" ]]; then
		print_result "serial_loop: 3 success + 2 fail = dispatched=3 processed=5" 0
	else
		print_result "serial_loop: 3 success + 2 fail = dispatched=3 processed=5" 1 "got=${result}"
	fi
	return 0
}

test_serial_loop_isolates_candidate_stdout() {
	# Stub: simulate noisy lower helpers before a successful launch. The serial
	# loop must log that output instead of corrupting the count-only stdout
	# consumed by pulse-dispatch-engine.sh.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		local candidate_json="$1"
		printf 'lower-helper stdout before count for %s\n' "$candidate_json"
		return 0
	}

	local candidate_file
	candidate_file=$(mktemp)
	printf '%s\n' '{"number":600,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}' >"$candidate_file"

	rm -f "$STOP_FLAG"
	_DISPATCH_THROTTLE_CLEARED=0
	local result
	result=$(_dispatch_floor_loop "$candidate_file" 10 10 "test_user")
	rm -f "$candidate_file"

	if [[ "$result" == "1 1" ]]; then
		print_result "serial_loop: isolates candidate stdout from count output" 0
	else
		print_result "serial_loop: isolates candidate stdout from count output" 1 "got=${result}"
	fi
	return 0
}

test_serial_loop_budget_cap() {
	# Stub: every candidate succeeds
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
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
	result=$(_dispatch_floor_loop "$candidate_file" 2 5 "test_user")
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

test_serial_loop_allows_unset_stop_flag() {
	# Stub: every candidate succeeds. The serial loop must treat an unset
	# STOP_FLAG as "no stop flag" under set -u, matching the parallel loop and
	# capacity pre-check guards.
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		return 0
	}

	local candidate_file old_stop_flag result
	candidate_file=$(mktemp)
	printf '%s\n' '{"number":700,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}' >"$candidate_file"

	old_stop_flag="$STOP_FLAG"
	unset STOP_FLAG || true
	_DISPATCH_THROTTLE_CLEARED=0
	result=$(_dispatch_floor_loop "$candidate_file" 10 10 "test_user")
	export STOP_FLAG="$old_stop_flag"
	rm -f "$candidate_file"

	if [[ "$result" == "1 1" ]]; then
		print_result "serial_loop: unset STOP_FLAG defaults to no stop flag" 0
	else
		print_result "serial_loop: unset STOP_FLAG defaults to no stop flag" 1 "got=${result}"
	fi
	return 0
}

# GH#37907: a deploy drain request that appears while candidate 1 runs stops
# the serial loop before candidate 2, and skips the next dispatch_max census.
# A marker naming another owner is ignored.
test_serial_loop_cooperative_drain() {
	local LOCKDIR="${TEST_ROOT}/drain-lock"
	rm -rf "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		printf 'owner=%s\nbundle=bundle-next\n' "$$" >"${LOCKDIR}/drain_requested"
		return 0
	}

	local candidate_file result capacity_rc=0
	candidate_file=$(mktemp)
	for i in 710 711 712; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"
	rm -f "$STOP_FLAG"
	_DISPATCH_THROTTLE_CLEARED=0
	result=$(_dispatch_floor_loop "$candidate_file" 10 10 "test_user")
	_dispatch_compute_capacity >/dev/null || capacity_rc=$?
	if [[ "$result" == "1 2" && "$capacity_rc" -ne 0 ]] &&
		grep -q 'cooperative drain requested for activated bundle bundle-next during serial loop' "$LOGFILE" &&
		grep -q 'Dispatch_max skipped: cooperative drain requested' "$LOGFILE"; then
		print_result "serial_loop: cooperative drain stops within one candidate and skips the next census" 0
	else
		print_result "serial_loop: cooperative drain stops within one candidate and skips the next census" 1 \
			"got=${result} capacity_rc=${capacity_rc}"
	fi

	printf 'owner=1\nbundle=bundle-next\n' >"${LOCKDIR}/drain_requested"
	_dispatch_process_candidate() {
		return 0
	}
	result=$(_dispatch_floor_loop "$candidate_file" 10 10 "test_user")
	if [[ "$result" == "3 3" ]]; then
		print_result "serial_loop: drain marker for another lock owner is ignored" 0
	else
		print_result "serial_loop: drain marker for another lock owner is ignored" 1 "got=${result}"
	fi
	rm -rf "$LOCKDIR" "$candidate_file"
	return 0
}

# GH#38033: a serial round caused only by the REST-core reserve resumes the
# bounded parallel loop once the reserve clears; throttle-file and persistent
# reserve rounds stay serial. Arguments: scenario (recover|throttle|persistent)
test_serial_loop_rest_reserve_recovery() {
	local scenario="$1"
	local ACTIVE_DIR="${TEST_ROOT}/rest-recovery-active-${scenario}"
	local PROCESSED_FILE="${TEST_ROOT}/rest-recovery-processed-${scenario}"
	local MAX_FILE="${TEST_ROOT}/rest-recovery-max-${scenario}"
	local candidate_file="" result="" rc=0 max_seen=0 i=0
	rm -rf "$ACTIVE_DIR"
	mkdir -p "$ACTIVE_DIR"
	: >"$PROCESSED_FILE"
	printf '0\n' >"$MAX_FILE"
	candidate_file=$(mktemp)
	for i in 800 801 802 803 804 805 806 807; do
		printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","labels":[]}\n' "$i"
	done >"$candidate_file"
	# shellcheck disable=SC2317 # called via name resolution from the loops
	_dispatch_process_candidate() {
		local issue="" active=0 seen=0
		issue=$(jq -r '.number' <<<"$1")
		: >"${ACTIVE_DIR}/${issue}"
		active=$(find "$ACTIVE_DIR" -type f | wc -l | tr -d ' ')
		seen=$(<"$MAX_FILE")
		[[ "$seen" =~ ^[0-9]+$ ]] || seen=0
		((active > seen)) && printf '%s\n' "$active" >"$MAX_FILE"
		sleep 0.2
		printf '%s\n' "$issue" >>"$PROCESSED_FILE"
		rm -f "${ACTIVE_DIR}/${issue}"
		return 0
	}
	# Reserve-adjacent until two candidates have run (recover); always
	# reserve-adjacent (persistent). The throttle case is healthy throughout.
	# shellcheck disable=SC2317 # called via _dispatch_rest_core_requires_serial
	pulse_rest_core_priority_snapshot() {
		local done_count=0
		done_count=$(wc -l <"$PROCESSED_FILE" | tr -d ' ')
		if [[ "$scenario" == persistent ]] || { [[ "$scenario" == recover ]] && ((done_count < 2)); }; then
			printf 'reserve 300 5000 200 500 100 9999999999\n'
		else
			printf 'normal 4790 5000 200 500 100 9999999999\n'
		fi
		return 0
	}
	export DISPATCH_MAX_PARALLEL=4 DISPATCH_REST_SERIAL_RECHECK_ITERATIONS=3 DISPATCH_REST_SERIAL_RECHECK_SECONDS=0
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	rm -f "$_DISPATCH_THROTTLE_FILE" "$STOP_FLAG"
	[[ "$scenario" == throttle ]] && : >"$_DISPATCH_THROTTLE_FILE"
	_DISPATCH_THROTTLE_CLEARED=0
	: >"$LOGFILE"
	result=$(_dispatch_floor_loop "$candidate_file" 10 10 "test_user")
	max_seen=$(<"$MAX_FILE")
	[[ "$result" == "8 8" ]] || rc=1
	case "$scenario" in
	recover)
		# Entry check plus iterations 1-3 run serially; the recheck before
		# iteration 4 sees the healthy budget and hands off candidates 4-8.
		grep -q 'REST-core recovered; resuming parallel launch ceremony at iter=4 ' "$LOGFILE" || rc=1
		[[ "$(grep -c 'Dispatch_max: loop iter=.*_dispatch_process_candidate rc=0' "$LOGFILE")" == 3 ]] || rc=1
		[[ "$(grep -c 'Dispatch_max: parallel iter=.*entering body' "$LOGFILE")" == 5 ]] || rc=1
		((max_seen > 1)) || rc=1
		;;
	throttle | persistent)
		grep -q 'resuming parallel launch ceremony' "$LOGFILE" && rc=1
		((max_seen == 1)) || rc=1
		;;
	esac
	rm -f "$candidate_file" "$PROCESSED_FILE" "$MAX_FILE" "$_DISPATCH_THROTTLE_FILE"
	rm -rf "$ACTIVE_DIR"
	unset DISPATCH_MAX_PARALLEL DISPATCH_REST_SERIAL_RECHECK_ITERATIONS DISPATCH_REST_SERIAL_RECHECK_SECONDS
	pulse_rest_core_priority_snapshot() {
		printf 'disabled ? ? 0 0 0 ?\n'
		return 0
	}
	print_result "serial_loop: REST-reserve serial round recovery (${scenario})" "$rc" \
		"result=${result} max_concurrent=${max_seen}"
	return 0
}

# GH#38033: a priority round that started serial on the REST reserve runs a
# later phase in parallel once the reserve has cleared before that phase.
test_priority_phase_rest_reserve_recovery() {
	local candidate_file="" outcomes="" result="" rc=0 i=0
	candidate_file=$(mktemp)
	outcomes=$(mktemp)
	for i in 1 2 3 4; do
		printf '{"number":%d,"repo_slug":"o/r","repo_priority":"tooling","labels":[]}\n' "$i"
	done >"$candidate_file"
	# shellcheck disable=SC2317 # called via name resolution from the loops
	_dispatch_process_candidate() {
		_DISPATCH_CANDIDATE_ELIGIBILITY=eligible
		return 0
	}
	# shellcheck disable=SC2317 # called via _dispatch_rest_core_requires_serial
	pulse_rest_core_priority_snapshot() {
		printf 'normal 4790 5000 200 500 100 9999999999\n'
		return 0
	}
	export DISPATCH_MAX_PARALLEL=4
	rm -f "$_DISPATCH_THROTTLE_FILE" "$STOP_FLAG"
	: >"$LOGFILE"
	(
		local _DISPATCH_REST_SERIAL_ROUND=1
		_dispatch_run_priority_phase "$candidate_file" 4 test_user 1 "$outcomes"
	) >"${TEST_ROOT}/priority-rest-phase.result"
	result=$(<"${TEST_ROOT}/priority-rest-phase.result")
	[[ "$result" == "4 4" ]] || rc=1
	grep -q 'resuming parallel launch ceremony at phase start (max_parallel=4' "$LOGFILE" || rc=1
	grep -q 'Dispatch_max: parallel iter=1' "$LOGFILE" || rc=1
	# Without the round marker (ordinary serial caller), the phase stays serial.
	: >"$LOGFILE"
	: >"$outcomes"
	result=$(_dispatch_run_priority_phase "$candidate_file" 4 test_user 1 "$outcomes")
	[[ "$result" == "4 4" ]] || rc=1
	grep -q 'resuming parallel launch ceremony' "$LOGFILE" && rc=1
	rm -f "$candidate_file" "$outcomes" "${TEST_ROOT}/priority-rest-phase.result"
	unset DISPATCH_MAX_PARALLEL
	pulse_rest_core_priority_snapshot() {
		printf 'disabled ? ? 0 0 0 ?\n'
		return 0
	}
	print_result "priority_phase: REST-reserve serial round resumes parallel at phase start" "$rc" "result=${result}"
	return 0
}

# Exercise reservation admission through the real serial and parallel loops.
test_priority_reservations() {
	local mode="$1" parallel="$2" expected_product="$3" expected_total="$4"
	local candidate_file="" outcomes="" result="" products=0 total=0 complete=true
	local TOOLING_STARTED="${TEST_ROOT}/tooling-${mode}-${parallel}.ready"
	local ACTIVITY="${TEST_ROOT}/priority-${mode}-${parallel}.activity"
	rm -f "$TOOLING_STARTED"
	: >"$ACTIVITY"
	candidate_file=$(mktemp)
	outcomes=$(mktemp)
	jq -nc --arg mode "$mode" '
		[range(1;5) | {number:., repo_slug:"o/tooling", repo_priority:"tooling", labels:
			(if $mode == "urgent" then ["priority:high"] else [] end), simulated_outcome:"success"}] +
		(if $mode == "empty" or $mode == "incomplete" then [] else
		 [range(1;5) | {number:., repo_slug:"o/product", repo_priority:"product", labels:[], simulated_outcome:
			(if $mode == "ineligible" or $mode == "unknown" then $mode
			 elif $mode == "mixed" and . == 1 then "ineligible" else "success" end)}] end) | .[]
	' >"$candidate_file"
	# shellcheck disable=SC2317 # called through the real phase/dispatch loops
	_dispatch_process_candidate() {
		local candidate_json="$1" outcome="" priority="" waits=0
		_DISPATCH_THROTTLE_CLEARED=0
		printf 'start\n' >>"$ACTIVITY"
		outcome=$(jq -r '.simulated_outcome' <<<"$candidate_json")
		priority=$(jq -r '.repo_priority' <<<"$candidate_json")
		if [[ "$mode" == concurrent && "$priority" == product ]]; then
			while [[ ! -f "$TOOLING_STARTED" && "$waits" -lt 300 ]]; do
				sleep 0.01
				waits=$((waits + 1))
			done
			[[ -f "$TOOLING_STARTED" ]] || outcome=unknown
		elif [[ "$priority" == tooling ]]; then
			: >"$TOOLING_STARTED"
		fi
		_DISPATCH_CANDIDATE_ELIGIBILITY="$outcome"
		printf 'end\n' >>"$ACTIVITY"
		[[ "$outcome" == success ]] && return 0
		return 1
	}
	[[ "$mode" != incomplete ]] || complete=false
	result=$(_dispatch_priority_loop "$candidate_file" 4 test_user "$parallel" "$outcomes" 2 "$complete")
	read -r products _ < <(_dispatch_priority_product_outcomes "$outcomes")
	total=$(_dispatch_max_count_outcomes "$outcomes")
	if [[ "$products" == "$expected_product" && "$total" == "$expected_total" && "${result%% *}" == "$total" ]]; then
		print_result "priority_loop: ${mode} parallel=${parallel} product=${products} total=${total}" 0
	else
		print_result "priority_loop: ${mode} parallel=${parallel}" 1 "result=${result} product=${products} total=${total}"
	fi
	local duplicate=0
	duplicate=$(awk -F'|' '{ repo=""; for(i=3;i<=NF;i++) if($i ~ /^repo=/) repo=$i; if(seen[repo "|" $2]++) n++ } END { print n+0 }' "$outcomes")
	if [[ "$duplicate" == 0 ]]; then
		print_result "priority_loop: ${mode} preserves repository identity without duplicate attempts" 0
	else
		print_result "priority_loop: ${mode} duplicate attempts" 1 "duplicates=${duplicate}"
	fi
	local peak=0
	peak=$(awk '$0=="start" { n++; if(n>peak) peak=n } $0=="end" { n-- } END { print peak+0 }' "$ACTIVITY")
	((peak <= parallel)) && print_result "priority_loop: ${mode} combined concurrency is bounded" 0 ||
		print_result "priority_loop: ${mode} exceeded shared parallelism" 1 "peak=${peak} cap=${parallel}"
	rm -f "$candidate_file" "$outcomes"
	return 0
}

# GH#36722: under product reservations, fresh urgent work leads, then urgent
# retries share the unreserved pool with fresh ordinary work; held product
# slots are never lent to the retry backlog.
test_priority_urgent_retry_backlog() {
	local parallel="$1"
	local candidate_file="" outcomes="" result="" products=0 total=0 n=""
	# Keep the 60-second-old retry fixtures recent regardless of runner config.
	local _DISPATCH_ATTEMPT_RECENCY_WINDOW_SECONDS=86400
	local stamp_dir="${HOME}/.aidevops/cache/dispatch-attempt-recency"
	candidate_file=$(mktemp)
	outcomes=$(mktemp)
	mkdir -p "$stamp_dir"
	for n in 1 2 3 4; do
		printf '%s\n' "$(($(date +%s) - 60))" >"${stamp_dir}/o--tooling--${n}"
	done
	# GH#37103: a nonurgent product retry must not take a reserved slot
	# ahead of fresh product work, even when it ranks first in that stream.
	printf '%s\n' "$(($(date +%s) - 60))" >"${stamp_dir}/o--product--3"
	jq -nc '
		[range(1;5) | {number:., repo_slug:"o/tooling", repo_priority:"tooling", labels:["priority:high"]}] +
		[range(5;7) | {number:., repo_slug:"o/tooling", repo_priority:"tooling", labels:[]}] +
		[{number:7, repo_slug:"o/tooling", repo_priority:"tooling", labels:["priority:critical"]}] +
		[{number:3, repo_slug:"o/product", repo_priority:"product", labels:[]}] +
		[range(1;3) | {number:., repo_slug:"o/product", repo_priority:"product", labels:[]}] | .[]
	' >"$candidate_file"
	# shellcheck disable=SC2317 # called through the real phase/dispatch loops
	_dispatch_process_candidate() {
		_DISPATCH_THROTTLE_CLEARED=0
		_DISPATCH_CANDIDATE_ELIGIBILITY=success
		return 0
	}
	result=$(_dispatch_priority_loop "$candidate_file" 5 test_user "$parallel" "$outcomes" 2 true)
	read -r products _ < <(_dispatch_priority_product_outcomes "$outcomes")
	total=$(_dispatch_max_count_outcomes "$outcomes")
	local launched_ids="" retries=0 duplicate=0
	launched_ids=$(awk -F'|' '$1 == "success" { repo=""; for(i=3;i<=NF;i++) if($i ~ /^repo=/) repo=substr($i,6); print repo "#" $2 }' "$outcomes" | sort | tr '\n' ' ')
	retries=$(awk -F'|' '$1 == "success" && $3 == "repo=o/tooling" && $2 <= 4 { n++ } END { print n+0 }' "$outcomes")
	duplicate=$(awk -F'|' '{ repo=""; for(i=3;i<=NF;i++) if($i ~ /^repo=/) repo=$i; if(seen[repo "|" $2]++) n++ } END { print n+0 }' "$outcomes")
	if [[ "$products" == 2 && "$total" == 5 && "${result%% *}" == 5 && "$retries" == 1 && "$duplicate" == 0 &&
		"$launched_ids" != *"o/product#3 "* &&
		"$launched_ids" == *"o/tooling#7 "* && "$launched_ids" == *"o/tooling#5 "* ]]; then
		print_result "priority_loop: urgent retry backlog parallel=${parallel} shares unreserved slots, holds product" 0
	else
		print_result "priority_loop: urgent retry backlog parallel=${parallel}" 1 \
			"result=${result} product=${products} total=${total} retries=${retries} dup=${duplicate} launched=${launched_ids}"
	fi
	rm -rf "$stamp_dir"
	rm -f "$candidate_file" "$outcomes"
	return 0
}

test_priority_verified_occupancy() {
	local REPOS_JSON="${TEST_ROOT}/priority-repos.json"
	local AIDEVOPS_DISPATCH_LEDGER_DIR="${TEST_ROOT}/priority-ledger"
	local PRODUCT_RESERVATION_PCT=60
	mkdir -p "$AIDEVOPS_DISPATCH_LEDGER_DIR"
	printf '%s\n' '{"initialized_repos":[{"slug":"o/product","pulse":true,"priority":"product"}]}' >"$REPOS_JSON"
	jq -nc --argjson pid "$$" --argjson expires "$(($(date +%s) + 600))" '
		{session_key:"active",pid:$pid,owner_process_start:"fixture-start",status:"in-flight",lease_phase:"ready",lease_expires_at:$expires,repo_slug:"o/product"} as $row |
		$row, ($row + {session_key:"duplicate-pid"}), ($row + {session_key:"reused-pid",owner_process_start:"wrong"}),
		($row + {session_key:"dead",pid:99999999}), ($row + {session_key:"finished",status:"completed"})
	' >"$AIDEVOPS_DISPATCH_LEDGER_DIR/dispatch-ledger.jsonl"
	_process_start_token() { local pid="$1"; : "$pid"; printf 'fixture-start\n'; return 0; }
	local slots=""
	slots=$(_dispatch_product_reservation_slots 10 3 7)
	if [[ "$slots" == 5 ]]; then
		print_result "priority_capacity: subtracts verified distinct live product workers only" 0
	else
		print_result "priority_capacity: verified occupancy" 1 "slots=${slots} expected=5"
	fi
	slots=$(_dispatch_product_reservation_slots 10 0 4)
	[[ "$slots" == 4 ]] && print_result "priority_capacity: clamps reservations to available capacity" 0 ||
		print_result "priority_capacity: available clamp" 1 "slots=${slots}"
	PRODUCT_RESERVATION_PCT=0
	slots=$(_dispatch_product_reservation_slots 10 3 7)
	[[ "$slots" == 0 ]] && print_result "priority_capacity: honours disabled reservation" 0 ||
		print_result "priority_capacity: zero percent" 1 "slots=${slots}"
	return 0
}

# GH#33538: a deterministic maintainer gate is persisted only from exact attempt
# evidence, keyed to updatedAt; transient verifier results are never cached.
test_maintainer_gate_cache_records_only_deterministic_evidence() {
	local stale='{"number":701,"repo_slug":"o/r","updatedAt":"2026-10-04T01:00:00Z","labels":[],"assignees":[]}'
	local transient='{"number":702,"repo_slug":"o/r","updatedAt":"2026-10-04T01:00:00Z","labels":[],"assignees":[]}'
	local cost='{"number":703,"repo_slug":"o/r","updatedAt":"2026-10-04T01:00:00Z","labels":[],"assignees":[]}'
	{
		printf '[pulse-wrapper] DISPATCH_CANDIDATE_ATTEMPT #701 (o/r)\n'
		printf '[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=permission_grant_unverified signal=STALE_APPROVAL issue=#701 repo=o/r\n'
		printf '[pulse-wrapper] DISPATCH_CANDIDATE_ATTEMPT #702 (o/r)\n'
		printf '[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=permission_grant_unverified signal=API_ERROR issue=#702 repo=o/r\n'
		printf '[pulse-wrapper] DISPATCH_CANDIDATE_ATTEMPT #703 (o/r)\n'
		printf '[pulse-wrapper] Dedup: #703 in o/r already assigned — DISPATCH_BLOCK_REASON reason=cost_budget_exceeded signal=COST_BUDGET_EXCEEDED (spent=900K budget=800K tier=standard attempts=2)\n'
	} >>"$LOGFILE"
	_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_INELIGIBLE"
	_dispatch_cache_confirmed_block "$stale" 701 o/r
	_dispatch_cache_confirmed_block "$transient" 702 o/r
	_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_UNKNOWN"
	_dispatch_cache_confirmed_block "$cost" 703 o/r

	local stale_reason="" transient_reason="" cost_reason="" bumped_reason=""
	stale_reason=$(_dispatch_negative_cache_reason "$stale") || stale_reason=""
	transient_reason=$(_dispatch_negative_cache_reason "$transient") || transient_reason=""
	cost_reason=$(_dispatch_negative_cache_reason "$cost") || cost_reason=""
	bumped_reason=$(_dispatch_negative_cache_reason "${stale/01:00:00/02:00:00}") || bumped_reason=""
	if [[ "$stale_reason" == permission_grant_unverified && -z "$transient_reason" &&
		"$cost_reason" == cost_budget_exceeded && -z "$bumped_reason" ]]; then
		print_result "maintainer_gate_cache: deterministic gates cached, transient and updated issues re-checked" 0
	else
		print_result "maintainer_gate_cache: deterministic evidence only" 1 \
			"stale=${stale_reason} transient=${transient_reason} cost=${cost_reason} bumped=${bumped_reason}"
	fi
	return 0
}

# GH#33538: with budget for exactly one wave, six cached maintainer-gated
# candidates ahead of a dispatchable one must not consume that wave.
test_parallel_loop_skips_cached_blocks_before_wave() {
	local attempts_file="${TEST_ROOT}/hol-attempts"
	: >"$attempts_file"
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_process_candidate() {
		local candidate_json="$1" issue_num
		issue_num=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
		printf '%s\n' "$issue_num" >>"$attempts_file"
		[[ "$issue_num" == 716 ]] && return 0
		sleep 0.05
		return 1
	}
	# The cycle budget admits exactly one wave of max_parallel spawn decisions.
	local budget_calls=0
	# shellcheck disable=SC2317  # called via name resolution from loop
	_dispatch_graphql_budget_allows_next() {
		budget_calls=$((budget_calls + 1))
		((budget_calls <= 6))
		return $?
	}

	local candidate_file outcomes_file candidate i
	candidate_file=$(mktemp)
	outcomes_file=$(mktemp)
	for i in 710 711 712 713 714 715 716; do
		candidate=$(printf '{"number":%d,"repo_slug":"o/r","repo_path":"/t","url":"u","title":"t","updatedAt":"2026-10-04T01:00:00Z","labels":[],"assignees":[]}' "$i")
		printf '%s\n' "$candidate" >>"$candidate_file"
		[[ "$i" == 716 ]] || _dispatch_negative_cache_record "$candidate" permission_grant_unverified
	done
	: >"$outcomes_file"

	rm -f "$STOP_FLAG"
	local result="" s="" ineligible=""
	result=$(_dispatch_max_loop "$candidate_file" 6 6 "test_user" 6 "$outcomes_file")
	s=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	ineligible=$(grep -c 'eligibility=ineligible' "$outcomes_file")
	_dispatch_graphql_budget_allows_next() {
		return 0
	}

	if [[ "$s" == 1 && "$ineligible" == 6 && "$(<"$attempts_file")" == 716 ]] &&
		grep -q 'skipping #710 (o/r) — cross-cycle block:permission_grant_unverified (no wave slot spent)' "$LOGFILE"; then
		print_result "parallel_loop: cached maintainer gates skip before the single wave; dispatchable #716 launches" 0
	else
		print_result "parallel_loop: head-of-line cached blocks" 1 \
			"result=${result} s=${s} ineligible=${ineligible} attempts=$(tr '\n' ',' <"$attempts_file")"
	fi
	rm -f "$candidate_file" "$outcomes_file" "$attempts_file"
	return 0
}

# GH#33560: isolate clocks and cache writes in subshells, without live API calls.
# GH#36603: admission needs floor (600) + pre-stage margin (60) [+ enumeration].
test_elastic_dispatch_lease() {
	local rc=0
	(
		set -e
		source "${SCRIPT_DIR}/pulse-watchdog.sh"
		source "${SCRIPT_DIR}/pulse-instance-lock.sh"
		local LOCKDIR="${TEST_ROOT}/elastic-lock" WRAPPER_LOGFILE="$LOGFILE"
		local PULSE_LOCK_MAX_AGE_S=1800 PULSE_STALE_THRESHOLD=3600 PULSE_START_EPOCH=1
		local _PULSE_ELASTIC_DISPATCH=1 killed=0
		mkdir "$LOCKDIR"
		printf '%s\n' "$$" >"${LOCKDIR}/pid"
		date +%s >"${LOCKDIR}/supervisor_heartbeat_epoch"
		_get_process_age() { printf '7200\n'; return 0; }
		ps() { printf 'bash pulse-wrapper.sh\n'; return 0; }
		_kill_tree() { killed=$((killed + 1)); return 0; }
		_force_kill_tree() { return 0; }
		sleep() { return 0; }
		_pulse_dispatch_lease_active
		[[ "$(_dispatch_round_budget_plan before)" == 'full 0' ]] || exit 1
		_pulse_cycle_remaining_seconds 0 && exit 1
		_handle_existing_lock && exit 1
		[[ "$killed" == 0 ]] || exit 1
		unset _PULSE_DISPATCH_CANDIDATES_LIB_LOADED
		source "${SCRIPT_DIR}/pulse-dispatch-lib-candidates.sh"
		is_graphql_budget_sufficient() { return 0; }
		_dispatch_process_candidate() { return 0; }
		local candidates="${TEST_ROOT}/elastic-candidates" outcomes="${TEST_ROOT}/elastic-outcomes" i=0 result=""
		for ((i=1; i<=50; i++)); do
			printf '{"number":%s,"repo_slug":"o/r"}\n' "$i"
		done >"$candidates"
		: >"$outcomes"
		result=$(_dispatch_max_loop "$candidates" 10 10 test_user 6 "$outcomes")
		[[ "${result%% *}" == 10 ]] || exit 1
		# A dead heartbeat retains the old hung-owner reclaim ceiling.
		printf '1\n' >"${LOCKDIR}/supervisor_heartbeat_epoch"
		_pulse_dispatch_lease_active && exit 1
		_handle_existing_lock || exit 1
		[[ "$killed" == 1 ]] || exit 1
		rm -rf "$LOCKDIR"
	) || rc=1
	print_result "elastic lease: old fresh owner preserved, stale heartbeat reclaimed" "$rc"
	return 0
}

test_observed_ceremony_reserve() {
	local rc=0
	(
		set -e
		local AIDEVOPS_DISPATCH_STAGES_LOG="${TEST_ROOT}/ceremony.tsv" i=0 DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR=600
		for ((i=1; i<=10; i++)); do
			printf 'now\t#1\to/r\tdedup.ceremony_total\t%s\tcomplete\n' "$((i * 10000))"
		done >"$AIDEVOPS_DISPATCH_STAGES_LOG"
		printf 'now\t#1\to/r\tdedup.ceremony_total\t0\tstart\n' >>"$AIDEVOPS_DISPATCH_STAGES_LOG"
		[[ "$(_dispatch_ceremony_reserve_seconds)" == 90 ]] || exit 1
		_pulse_cycle_remaining_seconds() { printf '150\n'; return 0; }
		[[ "$(_dispatch_round_budget_plan after)" == 'full 0 150 90 60 0 0' ]] || exit 1
		_dispatch_cycle_budget_defers_candidate 1 o/r && exit 1
		[[ "$DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR" == 600 ]] || exit 1
	) || rc=1
	print_result "observed reserve: p90 excludes starts and leaves execution timeout unchanged" "$rc"
	return 0
}

test_enumeration_budget_admission() {
	local rc=0
	(
		local test_remaining=959
		_pulse_cycle_remaining_seconds() { printf '%s\n' "$test_remaining"; return 0; }
		_DISPATCH_TEST_CACHE="${HOME}/.aidevops/cache/pulse-dispatch-enumeration-seconds"
		mkdir -p "${HOME}/.aidevops/cache"
		rm -f "$_DISPATCH_TEST_CACHE"
		[[ "$(_dispatch_enumeration_expected_seconds)" == 300 ]] || exit 1
		# GH#37623: below the full-census reserve, 120s+ of slack beyond
		# floor + margin admits a bounded census (half the slack, <=180s).
		[[ "$(_dispatch_round_budget_plan before)" == "bounded 149 959 600 60 300 1" ]] || exit 1
		_dispatch_cycle_budget_admits_round test before || exit 1
		AIDEVOPS_PULSE_BOUNDED_ENUMERATION_MIN_S=0 _dispatch_cycle_budget_admits_round test before && exit 1
		test_remaining=779
		_dispatch_cycle_budget_admits_round test before && exit 1
		test_remaining=780
		[[ "$(_dispatch_round_budget_plan before)" == "bounded 60 780 600 60 300 1" ]] || exit 1
		test_remaining=960
		[[ "$(_dispatch_round_budget_plan before)" == "full 0 960 600 60 300 1" ]] || exit 1
		printf '400\n' >"$_DISPATCH_TEST_CACHE"
		[[ "$(_dispatch_round_budget_plan before)" == "bounded 150 960 600 60 400 1" ]] || exit 1
		test_remaining=1060
		_dispatch_cycle_budget_admits_round test before || exit 1
		[[ "$(_dispatch_round_budget_plan before)" == "full 0 1060 600 60 400 1" ]] || exit 1
		test_remaining=1500
		[[ "$(_dispatch_bounded_enumeration_budget_seconds 1500 600 60)" == 180 ]] || exit 1
		test_remaining=660
		_dispatch_cycle_budget_admits_round test after || exit 1
		test_remaining=659
		_dispatch_cycle_budget_admits_round test after && exit 1
		# Rollback knob restores the bare floor; invalid values keep the default.
		DISPATCH_PRESTAGE_MARGIN_SECONDS=0 _dispatch_cycle_budget_admits_round test after || exit 1
		[[ "$(DISPATCH_PRESTAGE_MARGIN_SECONDS=bogus _dispatch_prestage_margin_seconds)" == 60 ]] || exit 1
		printf 'corrupt\n' >"$_DISPATCH_TEST_CACHE"
		[[ "$(_dispatch_enumeration_expected_seconds)" == 300 ]] || exit 1
		unset -f _pulse_cycle_remaining_seconds
		_dispatch_cycle_budget_admits_round test before || exit 1
		_pulse_cycle_remaining_seconds() { return 1; }
		_dispatch_cycle_budget_admits_round test after || exit 1
		_pulse_cycle_remaining_seconds() { printf 'invalid\n'; return 0; }
		_dispatch_cycle_budget_admits_round test before || exit 1
		rm -f "$_DISPATCH_TEST_CACHE"
	) || rc=1
	print_result "enumeration_budget: fallback, learned reserve, exact floor and missing clocks" "$rc"
	return 0
}

test_enumeration_timing_persists_average() {
	local rc=0
	(
		local timing_file="${HOME}/.aidevops/cache/pulse-dispatch-enumeration-seconds"
		rm -f "$timing_file"
		_dispatch_now_ms() { printf '1400000\n'; return 0; }
		_dispatch_record_enumeration_seconds 1000000
		[[ "$(_dispatch_enumeration_expected_seconds)" == 325 ]] || exit 1
		_dispatch_record_enumeration_seconds 1000000
		[[ "$(_dispatch_enumeration_expected_seconds)" == 344 ]] || exit 1
		_dispatch_record_enumeration_seconds 1500000
		_dispatch_record_enumeration_seconds invalid
		[[ "$(_dispatch_enumeration_expected_seconds)" == 344 ]] || exit 1
		rm -f "$timing_file"
	) || rc=1
	print_result "enumeration_timing: persists moving average and ignores invalid/backward clocks" "$rc"
	return 0
}

test_enumeration_overrun_retains_refill() {
	local stage="$1" rc=0
	(
		local remaining_file="${TEST_ROOT}/remaining" clock_file="${TEST_ROOT}/clock" enumerated="${TEST_ROOT}/enumerated"
		local trigger="${TEST_ROOT}/refill.trigger"
		export PULSE_EVENT_REFILL_TRIGGER_FILE="$trigger"
		export PULSE_DISPATCH_CANDIDATE_SCAN_LIMIT=50
		export AIDEVOPS_PULSE_DISPATCH_BUDGET_RESERVE=1
		: >"$LOGFILE"
		: >"$trigger"
		rm -f "$enumerated" "${HOME}/.aidevops/cache/pulse-dispatch-enumeration-seconds"
		printf '1000000\n' >"$clock_file"
		# GH#36603: before-enumeration admission needs 600 floor + 60 margin + 300;
		# GH#37623: a bounded census needs 120s of slack beyond floor + margin.
		if [[ "$stage" == before ]]; then
			printf '779\n' >"$remaining_file"
		else
			printf '1010\n' >"$remaining_file"
		fi
		_pulse_cycle_remaining_seconds() { read -r value <"$remaining_file"; printf '%s\n' "$value"; return 0; }
		_dispatch_now_ms() { read -r value <"$clock_file"; printf '%s\n' "$value"; return 0; }
		_dispatch_compute_capacity() { printf '2 0 2\n'; return 0; }
		_dispatch_ranked_candidates_json() {
			: >"$enumerated"
			printf '550\n' >"$remaining_file"
			printf '1400000\n' >"$clock_file"
			printf '[{"number":1}]\n'
			return 0
		}
		_dispatch_begin_benign_blocks_cycle() { return 0; }
		_dispatch_cleanup_benign_blocks_cycle() { return 0; }
		count_active_workers() { printf '0\n'; return 0; }
		get_max_workers_target() { printf '2\n'; return 0; }
		# shellcheck source=../pulse-event-refill.sh
		source "${SCRIPT_DIR}/pulse-event-refill.sh"
		pulse_event_refill_is_enabled() { return 0; }
		pulse_event_refill_recover_processing() { return 0; }
		_pulse_event_refill_dispatch_gate() { return 0; }
		local expected_stage="$stage"
		if [[ "$stage" == refill ]]; then
			expected_stage=before
			export AIDEVOPS_MIN_WORKER_CONCURRENCY=2
			pulse_apply_provider_load_capacity_cap() { printf '2 1\n'; return 0; }
			_dispatch_apply_current_state_guardrails() { printf '2 1 1\n'; return 0; }
			_adaptive_launch_settle_wait() { return 0; }
			# One successful launch, then the real floor-refill orchestrator must
			# propagate a budget-deferred round rather than swallowing its status.
			dispatch_max() {
				if ! _dispatch_cycle_budget_admits_round "Dispatch_max" before; then
					printf '0\n'
					return 3
				fi
				: >"$enumerated"
				printf '550\n' >"$remaining_file"
				printf '1\n'
				return 0
			}
		fi
		pulse_event_refill_drain test
		[[ -f "$trigger" ]] || exit 1
		grep -q "skipped ${expected_stage} candidate enumeration.*refill trigger retained" "$LOGFILE" || exit 1
		grep -q 'stopping early\|entering candidate loop' "$LOGFILE" && exit 1
		if [[ "$stage" == before ]]; then
			[[ ! -f "$enumerated" ]] || exit 1
		elif [[ "$stage" == refill ]]; then
			[[ -f "$enumerated" ]] || exit 1
			grep -q 'Minimum worker floor refill:' "$LOGFILE" || exit 1
		else
			[[ -f "$enumerated" && "$(_dispatch_enumeration_expected_seconds)" == 325 ]] || exit 1
		fi
		rm -f "$trigger" "$remaining_file" "$clock_file" "$enumerated" "${HOME}/.aidevops/cache/pulse-dispatch-enumeration-seconds"
	) || rc=1
	print_result "enumeration_budget: ${stage}-enumeration deferral restores real refill trigger" "$rc"
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================
test_elastic_dispatch_lease
test_observed_ceremony_reserve
test_enumeration_budget_admission
test_enumeration_timing_persists_average
test_enumeration_overrun_retains_refill before
test_enumeration_overrun_retains_refill after
test_enumeration_overrun_retains_refill refill
test_compute_max_parallel_default
test_compute_max_parallel_default_caps_at_slots
test_compute_max_parallel_override
test_compute_max_parallel_caps_at_slots
test_compute_max_parallel_throttle_forces_serial
test_compute_max_parallel_invalid_var
test_compute_max_parallel_rest_reserve_forces_serial
test_count_outcomes_success_and_fail
test_count_outcomes_empty_file
test_wait_tracked_pids_suppresses_stale_child
test_owner_capture_contract
test_parallel_wait_failure_contract
test_aggregate_outcomes_basic
test_aggregate_outcomes_invalidates_canary_cache
test_aggregate_outcomes_clears_throttle_on_success
test_parallel_loop_end_to_end
test_parallel_loop_respects_budget
test_parallel_loop_refills_rejected_reservation
test_parallel_loop_all_rejections_finish
test_parallel_loop_stop_flag_aborts
test_parallel_loop_graphql_budget_aborts
test_parallel_loop_rest_budget_aborts
test_dispatch_with_timeout_noop_outcome
test_dispatch_with_timeout_cycle_floor 580 defer
test_dispatch_with_timeout_cycle_floor 700 run
test_dispatch_cycle_deferral_accounting
test_dispatch_cycle_floor_clock_fallback
test_serial_loop_basic
test_serial_loop_isolates_candidate_stdout
test_serial_loop_budget_cap
test_serial_loop_allows_unset_stop_flag
test_serial_loop_cooperative_drain
test_serial_loop_rest_reserve_recovery recover
test_serial_loop_rest_reserve_recovery throttle
test_serial_loop_rest_reserve_recovery persistent
test_priority_phase_rest_reserve_recovery
test_priority_reservations normal 1 2 4
test_priority_reservations normal 3 2 4
test_priority_reservations concurrent 3 2 4
test_priority_reservations mixed 3 2 4
test_priority_reservations ineligible 3 0 4
test_priority_reservations unknown 3 0 2
test_priority_reservations empty 3 0 4
test_priority_reservations incomplete 3 0 2
test_priority_reservations urgent 3 0 4
test_priority_urgent_retry_backlog 1
test_priority_urgent_retry_backlog 3
test_priority_verified_occupancy
test_maintainer_gate_cache_records_only_deterministic_evidence
test_parallel_loop_skips_cached_blocks_before_wave

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
