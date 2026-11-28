#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#40658 (t2769 no_work breaker false trips).
#
# The fast-fail counter passed to escalate_issue_tier is cumulative across all
# non-rate-limit failure classes. The no_work breaker used to compare that total
# with its threshold, so a single no_work failure on an issue with two earlier
# real failures tripped "3 consecutive no_work failures". The breaker must count
# only consecutive no_work failures.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

# shellcheck source=../worker-lifecycle-common.sh
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"

TESTS_RUN=0
TESTS_FAILED=0
BREAKER_CALLS=0
LAST_BREAKER_PAYLOAD=""
TMP_DIR="$(mktemp -d -t no-work-streak.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
export FAST_FAIL_STATE_FILE="${TMP_DIR}/fast-fail-counter.json"
REPO="exampleorg/examplerepo"

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

_count_issue_comments_containing_marker() {
	printf '0'
	return 0
}

_apply_no_work_nmr_breaker() {
	BREAKER_CALLS=$((BREAKER_CALLS + 1))
	LAST_BREAKER_PAYLOAD="$1|$2|$3|$4|$5"
	return 0
}

gh_issue_comment() {
	return 0
}

# No network: tier lookups fail closed, so non-no_work escalation is a no-op.
gh() {
	return 1
}

reset_case() {
	BREAKER_CALLS=0
	LAST_BREAKER_PAYLOAD=""
	_no_work_streak_reset "$1" "$REPO"
	return 0
}

test_single_no_work_after_cumulative_failures_does_not_trip() {
	reset_case 5001
	escalate_issue_tier 5001 "$REPO" 3 "worker_noop_zero_output" "no_work" >/dev/null 2>&1
	if [[ "$BREAKER_CALLS" -ne 0 ]]; then
		fail "one no_work at cumulative count 3 must not trip breaker" "payload: ${LAST_BREAKER_PAYLOAD}"
		return 0
	fi
	pass "one no_work at cumulative count 3 does not trip breaker"
	return 0
}

test_three_consecutive_no_work_trip_with_streak_count() {
	reset_case 5002
	escalate_issue_tier 5002 "$REPO" 4 "worker_noop_zero_output" "no_work" >/dev/null 2>&1
	escalate_issue_tier 5002 "$REPO" 5 "worker_noop_zero_output" "no_work" >/dev/null 2>&1
	if [[ "$BREAKER_CALLS" -ne 0 ]]; then
		fail "two consecutive no_work must not trip breaker" "payload: ${LAST_BREAKER_PAYLOAD}"
		return 0
	fi
	escalate_issue_tier 5002 "$REPO" 6 "worker_noop_zero_output" "no_work" >/dev/null 2>&1
	if [[ "$BREAKER_CALLS" -ne 1 || "$LAST_BREAKER_PAYLOAD" != "5002|${REPO}|3|3|worker_noop_zero_output" ]]; then
		fail "third consecutive no_work trips breaker with streak count" \
			"calls=${BREAKER_CALLS} payload=${LAST_BREAKER_PAYLOAD}"
		return 0
	fi
	pass "three consecutive no_work trip breaker reporting the streak"
	return 0
}

test_other_failure_class_resets_streak() {
	reset_case 5003
	escalate_issue_tier 5003 "$REPO" 1 "worker_noop_zero_output" "no_work" >/dev/null 2>&1
	escalate_issue_tier 5003 "$REPO" 2 "worker_noop_zero_output" "no_work" >/dev/null 2>&1
	escalate_issue_tier 5003 "$REPO" 3 "stale_timeout" "partial" >/dev/null 2>&1
	escalate_issue_tier 5003 "$REPO" 4 "worker_noop_zero_output" "no_work" >/dev/null 2>&1
	if [[ "$BREAKER_CALLS" -ne 0 ]]; then
		fail "interleaved real failure resets no_work streak" "payload: ${LAST_BREAKER_PAYLOAD}"
		return 0
	fi
	local streak=""
	streak=$(_no_work_streak_get 5003 "$REPO")
	if [[ "$streak" != "1" ]]; then
		fail "streak restarts at 1 after reset" "streak: ${streak}"
		return 0
	fi
	pass "a non-no_work failure resets the consecutive no_work streak"
	return 0
}

test_prelaunch_reason_does_not_bump_streak() {
	reset_case 5004
	escalate_issue_tier 5004 "$REPO" 1 "worker_launch_rc_2" "no_work" >/dev/null 2>&1
	local streak=""
	streak=$(_no_work_streak_get 5004 "$REPO")
	if [[ "$streak" != "0" ]]; then
		fail "pre-launch reason does not count toward streak" "streak: ${streak}"
		return 0
	fi
	pass "pre-launch reasons do not count toward the no_work streak"
	return 0
}

test_expired_streak_reads_as_zero() {
	reset_case 5005
	_no_work_streak_bump 5005 "$REPO" >/dev/null
	local streak_file=""
	streak_file=$(_no_work_streak_file 5005 "$REPO")
	printf '2 1\n' >"$streak_file"
	local streak=""
	streak=$(_no_work_streak_get 5005 "$REPO")
	if [[ "$streak" != "0" ]]; then
		fail "expired streak reads as zero" "streak: ${streak}"
		return 0
	fi
	pass "expired streak reads as zero"
	return 0
}

test_single_no_work_after_cumulative_failures_does_not_trip
test_three_consecutive_no_work_trip_with_streak_count
test_other_failure_class_resets_streak
test_prelaunch_reason_does_not_bump_streak
test_expired_streak_reads_as_zero

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
