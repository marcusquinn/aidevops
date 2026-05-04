#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for awardsapp/awardsapp#4044.
#
# Canary-preflight and worktree-precreation skips occur before the worker
# worktree exists and before the model can read the brief. If those launch
# control outcomes are later forwarded as crash_type=no_work, they must not
# trip the t2769 no_work NMR breaker. Legitimate no_work failures that happen
# after worker launch must keep the existing breaker path.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1
LIFECYCLE_SCRIPT="${SCRIPTS_DIR}/worker-lifecycle-common.sh"

TESTS_RUN=0
TESTS_FAILED=0
APPLY_CALLS=0
LAST_APPLY_REASON=""

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

# shellcheck source=../worker-lifecycle-common.sh
source "$LIFECYCLE_SCRIPT"

_apply_no_work_nmr_breaker() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local nmr_threshold="$4"
	local reason="$5"
	: "$issue_number" "$repo_slug" "$failure_count" "$nmr_threshold"
	APPLY_CALLS=$((APPLY_CALLS + 1))
	LAST_APPLY_REASON="$reason"
	return 0
}

reset_observations() {
	APPLY_CALLS=0
	LAST_APPLY_REASON=""
	return 0
}

test_prelaunch_canary_skip_does_not_apply_breaker() {
	reset_observations
	_log_no_work_skip_escalation "4044" "awardsapp/awardsapp" "4" \
		"worker canary preflight failed before worktree pre-creation; will retry next cycle"
	if [[ "$APPLY_CALLS" -ne 0 ]]; then
		fail "prelaunch canary skip does not apply no_work breaker" \
			"breaker called ${APPLY_CALLS} time(s), reason=${LAST_APPLY_REASON}"
		return 0
	fi
	pass "prelaunch canary skip does not apply no_work breaker"
	return 0
}

test_precreation_skip_does_not_apply_breaker() {
	reset_observations
	_log_no_work_skip_escalation "4044" "awardsapp/awardsapp" "4" \
		"worktree pre-creation failed for issue; will retry next cycle"
	if [[ "$APPLY_CALLS" -ne 0 ]]; then
		fail "precreation skip does not apply no_work breaker" \
			"breaker called ${APPLY_CALLS} time(s), reason=${LAST_APPLY_REASON}"
		return 0
	fi
	pass "precreation skip does not apply no_work breaker"
	return 0
}

test_legitimate_no_work_still_applies_breaker() {
	reset_observations
	_log_no_work_skip_escalation "4044" "awardsapp/awardsapp" "4" \
		"worker_noop_zero_output"
	if [[ "$APPLY_CALLS" -ne 1 ]]; then
		fail "legitimate no_work still applies breaker" \
			"expected 1 breaker call, got ${APPLY_CALLS}"
		return 0
	fi
	if [[ "$LAST_APPLY_REASON" != "worker_noop_zero_output" ]]; then
		fail "legitimate no_work preserves reason" \
			"reason=${LAST_APPLY_REASON}"
		return 0
	fi
	pass "legitimate no_work still applies breaker"
	return 0
}

test_prelaunch_canary_skip_does_not_apply_breaker
test_precreation_skip_does_not_apply_breaker
test_legitimate_no_work_still_applies_breaker

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
