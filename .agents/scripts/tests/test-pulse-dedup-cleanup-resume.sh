#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38171: dedup cleanup resumes across short housekeeping slices instead of
# restarting at the first repo and never recording a completed traversal.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)" || exit 1

unset PULSE_STAGE_DEADLINE_EPOCH

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT="$(mktemp -d -t gh38171-dedup.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

print_result() {
	local test_name="$1"
	local failed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$failed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s %s\n' "$test_name" "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

CLOCK_FILE="${TEST_ROOT}/clock"
CALLS_LOG="${TEST_ROOT}/calls.log"

# Fake clock: each repo listing costs 5 seconds of stage time.
date() {
	if [[ "${1:-}" == "+%s" ]]; then
		cat "$CLOCK_FILE"
		return 0
	fi
	command date "$@"
	return $?
}

_pulse_enabled_repo_slugs() {
	local repos_json="$1"
	printf '%s\n' "o/a" "o/b" "o/c" "o/d"
	return 0
}

get_repo_role_by_slug() {
	local slug="$1"
	printf 'maintainer\n'
	return 0
}

gh_issue_list() {
	local slug="$2"
	printf '%s\n' "$slug" >>"$CALLS_LOG"
	printf '%s\n' "$(($(cat "$CLOCK_FILE") + 5))" >"$CLOCK_FILE"
	[[ "$slug" == "o/a" ]] && printf '11\n'
	[[ "$slug" == "o/c" && "${DEDUP_TEST_SATURATE_C:-0}" == "1" ]] && printf '31\n32\n'
	return 0
}

gh() {
	printf 'gh %s\n' "$*" >>"${TEST_ROOT}/gh.log"
	# Model a close GitHub has applied while the caller has not accounted for
	# it yet: signal the parent, then park until it delivers SIGKILL. Bash 3.2
	# has no BASHPID, so the parent kills this background job via its $!.
	if [[ -n "${DEDUP_TEST_KILL_AFTER_CLOSE:-}" && "$*" == "issue close ${DEDUP_TEST_KILL_AFTER_CLOSE} "* ]]; then
		: >"${TEST_ROOT}/close-applied"
		local parked=0
		while [[ "$parked" -lt 100 ]]; do
			sleep 0.1
			parked=$((parked + 1))
		done
	fi
	[[ "${DEDUP_TEST_CLOSE_FAILS:-0}" == "1" ]] && return 1
	return 0
}

LOGFILE="${TEST_ROOT}/pulse.log"
REPOS_JSON="${TEST_ROOT}/repos.json"
DEDUP_CLEANUP_LAST_RUN="${TEST_ROOT}/dedup-cleanup-last-run"
DEDUP_CLEANUP_INTERVAL=86400
DEDUP_CLEANUP_BATCH_SIZE=50
SCRIPT_DIR="$SCRIPTS_DIR"
printf '{}\n' >"$REPOS_JSON"
: >"$LOGFILE"

# shellcheck source=../pulse-simplification-review.sh
source "${SCRIPTS_DIR}/pulse-simplification-review.sh"
# shellcheck source=../pulse-simplification-orchestration.sh
source "${SCRIPTS_DIR}/pulse-simplification-orchestration.sh"

calls() {
	tr '\n' ' ' <"$CALLS_LOG"
	return 0
}

test_short_slice_resumes_and_completes() {
	local failed=0 detail=""
	local cursor_file="${DEDUP_CLEANUP_LAST_RUN}.cursor"
	: >"$CALLS_LOG"
	# 12s slice: reserve min(5, 12/4)=3s, so the third repo (t=1010) yields.
	printf '1000\n' >"$CLOCK_FILE"
	PULSE_STAGE_DEADLINE_EPOCH=1012 run_simplification_dedup_cleanup
	[[ "$(calls)" == "o/a o/b " ]] || { failed=1; detail="slice1=$(calls)"; }
	[[ "$(sed -n '1p' "$cursor_file" 2>/dev/null)" == "o/b" ]] || { failed=1; detail="${detail} cursor"; }
	[[ ! -f "$DEDUP_CLEANUP_LAST_RUN" ]] || { failed=1; detail="${detail} last-run-early"; }
	grep -q 'issue close 11 --repo o/a' "${TEST_ROOT}/gh.log" || { failed=1; detail="${detail} no-close"; }

	: >"$CALLS_LOG"
	printf '2000\n' >"$CLOCK_FILE"
	PULSE_STAGE_DEADLINE_EPOCH=2100 run_simplification_dedup_cleanup
	[[ "$(calls)" == "o/c o/d " ]] || { failed=1; detail="${detail} slice2=$(calls)"; }
	[[ ! -f "$cursor_file" ]] || { failed=1; detail="${detail} cursor-left"; }
	[[ "$(cat "$DEDUP_CLEANUP_LAST_RUN" 2>/dev/null)" == "2000" ]] || { failed=1; detail="${detail} last-run"; }
	print_result "short slices resume after the last started repo and record completion once" "$failed" "$detail"
	return 0
}

test_interval_gate_after_completion() {
	local failed=0
	: >"$CALLS_LOG"
	printf '2050\n' >"$CLOCK_FILE"
	run_simplification_dedup_cleanup
	[[ ! -s "$CALLS_LOG" ]] || failed=1
	print_result "completed traversal is interval-gated" "$failed" "calls=$(calls)"
	return 0
}

test_batch_exhaustion_keeps_cursor() {
	local failed=0 detail=""
	local cursor_file="${DEDUP_CLEANUP_LAST_RUN}.cursor"
	: >"$CALLS_LOG"
	rm -f "$DEDUP_CLEANUP_LAST_RUN"
	printf 'o/b\n' >"$cursor_file"
	printf '3000\n' >"$CLOCK_FILE"
	# Resumed past o/b; o/c closes the whole batch (2), so o/d is unvisited.
	DEDUP_CLEANUP_BATCH_SIZE=2 DEDUP_TEST_SATURATE_C=1 PULSE_STAGE_DEADLINE_EPOCH=3100 run_simplification_dedup_cleanup
	[[ "$(calls)" == "o/c " ]] || { failed=1; detail="calls=$(calls)"; }
	[[ "$(sed -n '1p' "$cursor_file" 2>/dev/null)" == "o/c" ]] || { failed=1; detail="${detail} cursor"; }
	[[ "$(cat "$DEDUP_CLEANUP_LAST_RUN" 2>/dev/null)" == "3000" ]] || { failed=1; detail="${detail} last-run"; }

	# Next interval starts after the saturating repo, then completes.
	: >"$CALLS_LOG"
	printf '%s\n' "$((3000 + DEDUP_CLEANUP_INTERVAL))" >"$CLOCK_FILE"
	PULSE_STAGE_DEADLINE_EPOCH=$((3100 + DEDUP_CLEANUP_INTERVAL)) run_simplification_dedup_cleanup
	[[ "$(calls)" == "o/d " ]] || { failed=1; detail="${detail} next=$(calls)"; }
	[[ ! -f "$cursor_file" ]] || { failed=1; detail="${detail} cursor-left"; }
	print_result "batch exhaustion honours the interval and resumes after the saturating repo" "$failed" "$detail"
	return 0
}

test_yield_carries_interval_budget() {
	local failed=0 detail=""
	local cursor_file="${DEDUP_CLEANUP_LAST_RUN}.cursor"
	rm -f "$DEDUP_CLEANUP_LAST_RUN" "$cursor_file" "${cursor_file}.closed"
	: >"$CALLS_LOG"
	: >"${TEST_ROOT}/gh.log"
	# Slice 1 closes #11 in o/a, then yields at o/c with the budget 1 of 2 spent.
	printf '4000\n' >"$CLOCK_FILE"
	DEDUP_CLEANUP_BATCH_SIZE=2 DEDUP_TEST_SATURATE_C=1 PULSE_STAGE_DEADLINE_EPOCH=4012 run_simplification_dedup_cleanup
	[[ "$(sed -n '1p' "${cursor_file}.closed" 2>/dev/null)" == "1" ]] || { failed=1; detail="carried"; }

	# Slice 2 may close only one more (31, not 32), then the interval ends.
	printf '5000\n' >"$CLOCK_FILE"
	DEDUP_CLEANUP_BATCH_SIZE=2 DEDUP_TEST_SATURATE_C=1 PULSE_STAGE_DEADLINE_EPOCH=5100 run_simplification_dedup_cleanup
	grep -q 'issue close 31 --repo o/c' "${TEST_ROOT}/gh.log" || { failed=1; detail="${detail} no-31"; }
	! grep -q 'issue close 32 ' "${TEST_ROOT}/gh.log" || { failed=1; detail="${detail} over-budget"; }
	[[ "$(cat "$DEDUP_CLEANUP_LAST_RUN" 2>/dev/null)" == "5000" ]] || { failed=1; detail="${detail} last-run"; }
	[[ ! -f "${cursor_file}.closed" ]] || { failed=1; detail="${detail} budget-left"; }
	print_result "deadline yields carry the interval close budget into the resumed slice" "$failed" "$detail"
	return 0
}

test_kill_mid_repo_keeps_spent_budget() {
	local failed=0 detail="" count_file="${TEST_ROOT}/kill.closed"
	local out_file="${TEST_ROOT}/kill.out" pid="" waited=0 rc=0
	rm -f "$count_file" "${TEST_ROOT}/close-applied"
	: >"${TEST_ROOT}/gh.log"
	# One close already spent; GitHub applies #31, then SIGKILL lands before
	# the helper can account for it.
	DEDUP_TEST_SATURATE_C=1 DEDUP_TEST_KILL_AFTER_CLOSE=31 \
		_dedup_cleanup_close_repo_dupes o/c 5 "$count_file" 1 >"$out_file" 2>/dev/null &
	pid=$!
	while [[ ! -f "${TEST_ROOT}/close-applied" && "$waited" -lt 100 ]]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	kill -KILL "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || rc=$?
	[[ "$rc" -eq 137 ]] || { failed=1; detail="rc=${rc}"; }
	[[ ! -s "$out_file" ]] || { failed=1; detail="${detail} not-killed=$(cat "$out_file")"; }
	grep -q 'issue close 31 --repo o/c' "${TEST_ROOT}/gh.log" || { failed=1; detail="${detail} no-31"; }
	! grep -q 'issue close 32 ' "${TEST_ROOT}/gh.log" || { failed=1; detail="${detail} ran-32"; }
	[[ "$(sed -n '1p' "$count_file" 2>/dev/null)" == "2" ]] || { failed=1; detail="${detail} count=$(sed -n '1p' "$count_file" 2>/dev/null)"; }
	print_result "a kill after the remote close, before accounting, keeps the close charged" "$failed" "$detail"
	return 0
}

test_reservation_failure_skips_close() {
	local failed=0 detail="" out="" rc=0
	local count_file="${TEST_ROOT}/missing-dir/unwritable.closed"
	: >"${TEST_ROOT}/gh.log"
	# The budget cannot be persisted, so no close may run at all.
	out=$(DEDUP_TEST_SATURATE_C=1 _dedup_cleanup_close_repo_dupes o/c 5 "$count_file" 0) || rc=$?
	[[ "$rc" -eq 1 ]] || { failed=1; detail="rc=${rc}"; }
	[[ "$out" == "0" ]] || { failed=1; detail="${detail} out=${out}"; }
	! grep -q 'issue close' "${TEST_ROOT}/gh.log" || { failed=1; detail="${detail} closed"; }
	grep -q 'budget reservation write failed' "$LOGFILE" || { failed=1; detail="${detail} no-log"; }
	print_result "an unpersisted budget reservation stops the batch before any close" "$failed" "$detail"
	return 0
}

test_reservation_failure_keeps_interval_open() {
	local failed=0 detail=""
	local cursor_file="${DEDUP_CLEANUP_LAST_RUN}.cursor"
	rm -f "$DEDUP_CLEANUP_LAST_RUN" "$cursor_file" "${cursor_file}.closed"
	: >"$CALLS_LOG"
	: >"${TEST_ROOT}/gh.log"
	# A directory in place of the count file makes every reservation fail.
	mkdir -p "${cursor_file}.closed"
	printf '6000\n' >"$CLOCK_FILE"
	PULSE_STAGE_DEADLINE_EPOCH=6100 run_simplification_dedup_cleanup
	[[ "$(calls)" == "o/a " ]] || { failed=1; detail="calls=$(calls)"; }
	! grep -q 'issue close' "${TEST_ROOT}/gh.log" || { failed=1; detail="${detail} closed"; }
	[[ ! -f "$DEDUP_CLEANUP_LAST_RUN" ]] || { failed=1; detail="${detail} last-run"; }
	[[ "$(sed -n '1p' "$cursor_file" 2>/dev/null)" == "o/a" ]] || { failed=1; detail="${detail} cursor"; }
	rm -rf "${cursor_file}.closed"
	print_result "a reservation failure stops the traversal without recording the interval" "$failed" "$detail"
	return 0
}

test_failed_close_is_charged() {
	local failed=0 detail="" out="" count_file="${TEST_ROOT}/fail.closed"
	rm -f "$count_file"
	: >"${TEST_ROOT}/gh.log"
	# An errored close may still have been applied, so it consumes budget:
	# limit 1 stops after #31 even though the close reported failure.
	out=$(DEDUP_TEST_SATURATE_C=1 DEDUP_TEST_CLOSE_FAILS=1 _dedup_cleanup_close_repo_dupes o/c 1 "$count_file" 0) || true
	[[ "$out" == "1" ]] || { failed=1; detail="out=${out}"; }
	! grep -q 'issue close 32 ' "${TEST_ROOT}/gh.log" || { failed=1; detail="${detail} over-budget"; }
	[[ "$(sed -n '1p' "$count_file" 2>/dev/null)" == "1" ]] || { failed=1; detail="${detail} count"; }
	print_result "an uncertain (failed) close is charged to the interval budget" "$failed" "$detail"
	return 0
}

test_short_slice_resumes_and_completes
test_interval_gate_after_completion
test_batch_exhaustion_keeps_cursor
test_yield_carries_interval_budget
test_kill_mid_repo_keeps_spent_budget
test_failed_close_is_charged
test_reservation_failure_skips_close
test_reservation_failure_keeps_interval_open

printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
