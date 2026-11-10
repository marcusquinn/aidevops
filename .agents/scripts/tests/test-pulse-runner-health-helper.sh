#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Unit tests for pulse-runner-health-helper.sh (t2897).
#
# Coverage:
#   1. Fresh state: status reports uninitialised.
#   2. Counter increments on each zero-attempt signal.
#   3. Counter resets on a real-attempt outcome (any non-zero-attempt signal).
#   4. is-paused returns 1 (closed) below threshold.
#   5. is-paused returns 0 (tripped) when threshold reached.
#   6. Window expiry: counter resets after RUNNER_HEALTH_WINDOW_HOURS pass.
#   7. Pause/resume idempotency: calling twice doesn't break state.
#   8. Advisory dedup: trip→trip without state change emits ONE advisory.
#   9. Advisory regenerates on resume→trip cycle (state change).
#  10. Status --json emits valid JSON.
#  11. RUNNER_HEALTH_DISABLED=1 short-circuits all subcommands.
#  12. Recognised zero-attempt signals (5 listed in the helper).
#  13. Unrecognised signal acts as real-attempt (resets counter).
#  14. Deterministic signing failure trips immediately without changing the
#      ordinary zero-attempt threshold.
#
# All tests run inside an isolated sandbox HOME; no system state is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
AGENT_SCRIPT_DIR="${SCRIPT_DIR}/.."
HELPER="${AGENT_SCRIPT_DIR}/pulse-runner-health-helper.sh"

# Test runtime constants.
TEST_RED='\033[0;31m'
TEST_GREEN='\033[0;32m'
TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
SANDBOX=""

cleanup() {
	[[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

print_result() {
	local test_name="$1"
	local outcome="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$outcome" == "PASS" ]]; then
		printf '  %b%s%b: %s\n' "$TEST_GREEN" "$outcome" "$TEST_RESET" "$test_name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %b%s%b: %s%s\n' "$TEST_RED" "$outcome" "$TEST_RESET" "$test_name" \
			"${detail:+ — $detail}"
	fi
	return 0
}

# Build a fresh sandbox + env, clearing any prior state.
_setup_sandbox() {
	SANDBOX=$(mktemp -d -t rh-test-XXXXXX)
	export RUNNER_HEALTH_CACHE_DIR="$SANDBOX/cache"
	export RUNNER_HEALTH_ADVISORY_DIR="$SANDBOX/advisories"
	export RUNNER_HEALTH_STATE_FILE="$RUNNER_HEALTH_CACHE_DIR/runner-health.json"
	export RUNNER_HEALTH_ADVISORY_FILE="$RUNNER_HEALTH_ADVISORY_DIR/runner-health-degraded.advisory"
	export RUNNER_HEALTH_ADVISORY_STAMP="$RUNNER_HEALTH_CACHE_DIR/runner-health-advisory.stamp"
	export RUNNER_HEALTH_FAILURE_THRESHOLD=3
	export RUNNER_HEALTH_WINDOW_HOURS=1
	# Disable the side-effecting `aidevops update` call by ensuring no helper
	# is reachable; cmd_record_outcome treats this as `helper_missing`.
	export PATH_BACKUP="$PATH"
	# Also redirect HOME so the helper's logs/log dir are sandboxed.
	export HOME_BACKUP="${HOME:-/tmp}"
	export HOME="$SANDBOX/home"
	mkdir -p "$HOME"
	return 0
}

_teardown_sandbox() {
	rm -rf "$SANDBOX" 2>/dev/null || true
	SANDBOX=""
	[[ -n "${HOME_BACKUP:-}" ]] && export HOME="$HOME_BACKUP"
	return 0
}

# Helper: invoke the script with current sandbox env.
_h() {
	bash "$HELPER" "$@"
}

echo "Tests for pulse-runner-health-helper.sh:"

# Sanity check.
if [[ ! -x "$HELPER" ]]; then
	print_result "helper exists and executable" "FAIL" "missing at $HELPER"
	exit 1
fi
print_result "helper exists and executable" "PASS"

# --- Test 1: fresh status reports uninitialised ---
_setup_sandbox
out=$(_h status 2>&1 || true)
if echo "$out" | grep -q "uninitialized"; then
	print_result "fresh status reports uninitialized" "PASS"
else
	print_result "fresh status reports uninitialized" "FAIL" "got: $out"
fi
_teardown_sandbox

# --- Test 2: counter increments on zero-attempt signals ---
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
_h record-outcome no_worker_process owner/repo#2 >/dev/null 2>&1
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "0")
if [[ "$counter" == "2" ]]; then
	print_result "counter increments to 2 after 2 zero-attempts" "PASS"
else
	print_result "counter increments to 2 after 2 zero-attempts" "FAIL" "got: $counter"
fi
_teardown_sandbox

# --- Test 3: counter resets on real-attempt outcome ---
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
_h record-outcome no_worker_process owner/repo#2 >/dev/null 2>&1
_h record-outcome real_attempt_with_commit owner/repo#3 >/dev/null 2>&1
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "x")
if [[ "$counter" == "0" ]]; then
	print_result "counter resets on real-attempt outcome" "PASS"
else
	print_result "counter resets on real-attempt outcome" "FAIL" "got: $counter"
fi
_teardown_sandbox

# --- Test 4: is-paused returns 1 (closed) below threshold ---
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
_h record-outcome no_worker_process owner/repo#2 >/dev/null 2>&1
rc=0
_h is-paused || rc=$?
if [[ "$rc" -eq 1 ]]; then
	print_result "is-paused exits 1 (closed) below threshold" "PASS"
else
	print_result "is-paused exits 1 (closed) below threshold" "FAIL" "got rc=$rc"
fi
_teardown_sandbox

# --- Test 5: is-paused returns 0 (tripped) when threshold reached ---
_setup_sandbox
for i in 1 2 3; do
	_h record-outcome no_worker_process "owner/repo#$i" >/dev/null 2>&1
done
rc=0
_h is-paused || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result "is-paused exits 0 (tripped) at threshold" "PASS"
else
	print_result "is-paused exits 0 (tripped) at threshold" "FAIL" "got rc=$rc"
fi
_teardown_sandbox

# --- Test 6: window expiry resets counter ---
# Record 2 outcomes with window_started_at way in the past, then record one
# more — expectation: counter resets to 1 (window expired clears, then new
# outcome increments by 1).
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
_h record-outcome no_worker_process owner/repo#2 >/dev/null 2>&1
# Manually backdate the window_started_at by 2 hours (>1h threshold).
# Use jq to rewrite atomically.
old_ts=$(date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
	|| date -u -d '-2 hours' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
	|| echo '2020-01-01T00:00:00Z')
jq --arg ts "$old_ts" '.window_started_at = $ts' "$RUNNER_HEALTH_STATE_FILE" \
	>"$RUNNER_HEALTH_STATE_FILE.tmp" && mv "$RUNNER_HEALTH_STATE_FILE.tmp" "$RUNNER_HEALTH_STATE_FILE"
_h record-outcome no_worker_process owner/repo#3 >/dev/null 2>&1
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "x")
if [[ "$counter" == "1" ]]; then
	print_result "window expiry resets counter to 1 (then increments by new outcome)" "PASS"
else
	print_result "window expiry resets counter to 1 (then increments by new outcome)" "FAIL" "got: $counter"
fi
_teardown_sandbox

# --- Test 7: pause/resume idempotency ---
_setup_sandbox
_h pause --reason "test1" >/dev/null 2>&1
_h pause --reason "test2" >/dev/null 2>&1
state=$(jq -r '.circuit_breaker.state' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "x")
reason=$(jq -r '.circuit_breaker.reason' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "x")
if [[ "$state" == "tripped" && "$reason" == "test2" ]]; then
	print_result "pause is idempotent (latest reason wins)" "PASS"
else
	print_result "pause is idempotent (latest reason wins)" "FAIL" \
		"state=$state reason=$reason"
fi
_h resume --reason "fixed" >/dev/null 2>&1
_h resume --reason "fixed-again" >/dev/null 2>&1
state=$(jq -r '.circuit_breaker.state' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "x")
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "x")
if [[ "$state" == "closed" && "$counter" == "0" ]]; then
	print_result "resume is idempotent (clears state + counter)" "PASS"
else
	print_result "resume is idempotent (clears state + counter)" "FAIL" \
		"state=$state counter=$counter"
fi
_teardown_sandbox

# --- Test 8: advisory dedup — trip → trip emits ONE advisory ---
_setup_sandbox
# Trip via threshold breach.
for i in 1 2 3; do
	_h record-outcome no_worker_process "owner/repo#$i" >/dev/null 2>&1
done
[[ -f "$RUNNER_HEALTH_ADVISORY_FILE" ]] && advisory_count=1 || advisory_count=0
# GNU first: on Linux `stat -f` succeeds with filesystem stats (free blocks
# drift between calls), so the BSD form must only be the fallback.
mtime1=$(stat -c '%Y' "$RUNNER_HEALTH_ADVISORY_FILE" 2>/dev/null \
	|| stat -f '%m' "$RUNNER_HEALTH_ADVISORY_FILE" 2>/dev/null \
	|| echo "0")
sleep 1
# Trigger another outcome — but breaker already tripped so trip path
# shouldn't fire again. Record outcome won't re-trip a tripped breaker.
_h record-outcome no_worker_process owner/repo#4 >/dev/null 2>&1
mtime2=$(stat -c '%Y' "$RUNNER_HEALTH_ADVISORY_FILE" 2>/dev/null \
	|| stat -f '%m' "$RUNNER_HEALTH_ADVISORY_FILE" 2>/dev/null \
	|| echo "0")
if [[ "$advisory_count" -eq 1 && "$mtime1" == "$mtime2" ]]; then
	print_result "advisory file written once on trip, not regenerated on subsequent records" "PASS"
else
	print_result "advisory file written once on trip, not regenerated on subsequent records" "FAIL" \
		"count=$advisory_count m1=$mtime1 m2=$mtime2"
fi
_teardown_sandbox

# --- Test 9: status --json emits valid JSON ---
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
out=$(_h status --json 2>&1 || true)
if echo "$out" | jq -e '.consecutive_zero_attempts >= 0' >/dev/null 2>&1; then
	print_result "status --json emits valid JSON" "PASS"
else
	print_result "status --json emits valid JSON" "FAIL" "got: $out"
fi
_teardown_sandbox

# --- Test 10: RUNNER_HEALTH_DISABLED=1 short-circuits ---
_setup_sandbox
RUNNER_HEALTH_DISABLED=1 _h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
# State file should NOT have been created.
if [[ ! -f "$RUNNER_HEALTH_STATE_FILE" ]]; then
	print_result "RUNNER_HEALTH_DISABLED=1 short-circuits record-outcome" "PASS"
else
	print_result "RUNNER_HEALTH_DISABLED=1 short-circuits record-outcome" "FAIL" \
		"state file was created"
fi
rc=0
RUNNER_HEALTH_DISABLED=1 _h is-paused || rc=$?
if [[ "$rc" -eq 1 ]]; then
	print_result "RUNNER_HEALTH_DISABLED=1 makes is-paused exit 1 (closed)" "PASS"
else
	print_result "RUNNER_HEALTH_DISABLED=1 makes is-paused exit 1 (closed)" "FAIL" "got rc=$rc"
fi
_teardown_sandbox

# --- Test 11: all 5 documented zero-attempt signals are recognised ---
_setup_sandbox
local_total=0
for sig in no_worker_process no_branch_created low_token_usage watchdog_killed_no_commit worker_signing_unavailable; do
	_h record-outcome "$sig" "owner/repo#$local_total" >/dev/null 2>&1
	local_total=$((local_total + 1))
done
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "x")
if [[ "$counter" == "5" ]]; then
	print_result "all 5 zero-attempt signals increment counter" "PASS"
else
	print_result "all 5 zero-attempt signals increment counter" "FAIL" "got: $counter"
fi
_teardown_sandbox

# --- Test 12: unrecognised signal resets counter ---
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
_h record-outcome no_worker_process owner/repo#2 >/dev/null 2>&1
_h record-outcome some_random_outcome owner/repo#3 >/dev/null 2>&1
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "x")
if [[ "$counter" == "0" ]]; then
	print_result "unrecognised signal resets counter (real-attempt path)" "PASS"
else
	print_result "unrecognised signal resets counter (real-attempt path)" "FAIL" "got: $counter"
fi
_teardown_sandbox

# --- Test 13: signing failure trips immediately; ordinary signals do not ---
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
ordinary_rc=0
_h is-paused || ordinary_rc=$?
_teardown_sandbox

_setup_sandbox
_h record-outcome worker_signing_unavailable owner/repo#2 >/dev/null 2>&1
signing_rc=0
_h is-paused || signing_rc=$?
reason=$(jq -r '.circuit_breaker.reason' "$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || echo "x")
if [[ "$ordinary_rc" -eq 1 && "$signing_rc" -eq 0 && "$reason" == *"signal=worker_signing_unavailable"* ]]; then
	print_result "signing failure trips immediately while ordinary signal retains threshold" "PASS"
else
	print_result "signing failure trips immediately while ordinary signal retains threshold" "FAIL" \
		"ordinary_rc=$ordinary_rc signing_rc=$signing_rc reason=$reason"
fi
_teardown_sandbox

# --- Test 14: routine signing failure is audit-only, not issue-runner health ---
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
for routine in routine-pulse routine-maintenance routine-pulse; do
	_h record-outcome worker_signing_unavailable "$routine" >/dev/null 2>&1
done
routine_rc=0
_h is-paused || routine_rc=$?
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE")
routine_entries=$(jq '[.last_outcomes[] | select(.issue | startswith("routine-"))] | length' "$RUNNER_HEALTH_STATE_FILE")
if [[ "$routine_rc" -eq 1 && "$counter" -eq 1 && "$routine_entries" -eq 3 ]]; then
	print_result "routine signing failures are audited without changing issue health" "PASS"
else
	print_result "routine signing failures are audited without changing issue health" "FAIL" \
		"paused_rc=$routine_rc counter=$counter ledger_entries=$routine_entries"
fi
# GH#29920 remains intact even after the excluded routine failures.
_h record-outcome worker_signing_unavailable routine-tools/app#2 >/dev/null 2>&1
issue_rc=0
_h is-paused || issue_rc=$?
if [[ "$issue_rc" -eq 0 ]]; then
	print_result "issue signing failure still trips immediately after routine outcomes" "PASS"
else
	print_result "issue signing failure still trips immediately after routine outcomes" "FAIL" "paused_rc=$issue_rc"
fi
_teardown_sandbox

# --- Test 14b: post-activity continuation signing failure is audit-only (GH#37597) ---
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
_h record-outcome worker_signing_unavailable_after_activity owner/repo#1 >/dev/null 2>&1
continuation_rc=0
_h is-paused || continuation_rc=$?
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE")
entries=$(jq '[.last_outcomes[] | select(.signal == "worker_signing_unavailable_after_activity")] | length' "$RUNNER_HEALTH_STATE_FILE")
if [[ "$continuation_rc" -eq 1 && "$counter" -eq 1 && "$entries" -eq 1 ]]; then
	print_result "post-activity continuation signing failure is audited without tripping" "PASS"
else
	print_result "post-activity continuation signing failure is audited without tripping" "FAIL" \
		"paused_rc=$continuation_rc counter=$counter ledger_entries=$entries"
fi
_teardown_sandbox

# Routine signing failures must leave even an expired issue window untouched.
_setup_sandbox
_h record-outcome no_worker_process owner/repo#1 >/dev/null 2>&1
expired_state=$(jq '.window_started_at = "2000-01-01T00:00:00Z"' "$RUNNER_HEALTH_STATE_FILE")
printf '%s\n' "$expired_state" >"$RUNNER_HEALTH_STATE_FILE"
_h record-outcome worker_signing_unavailable routine-pulse >/dev/null 2>&1
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE")
window=$(jq -r '.window_started_at' "$RUNNER_HEALTH_STATE_FILE")
if [[ "$counter" -eq 1 && "$window" == "2000-01-01T00:00:00Z" ]]; then
	print_result "routine signing leaves expired issue counter and window untouched" "PASS"
else
	print_result "routine signing leaves expired issue counter and window untouched" "FAIL" \
		"counter=$counter window=$window"
fi
_h record-outcome no_worker_process owner/repo#2 >/dev/null 2>&1
counter=$(jq -r '.consecutive_zero_attempts' "$RUNNER_HEALTH_STATE_FILE")
window=$(jq -r '.window_started_at' "$RUNNER_HEALTH_STATE_FILE")
if [[ "$counter" -eq 1 && "$window" != "2000-01-01T00:00:00Z" ]]; then
	print_result "next issue outcome still expires and re-anchors stale window" "PASS"
else
	print_result "next issue outcome still expires and re-anchors stale window" "FAIL" \
		"counter=$counter window=$window"
fi
_teardown_sandbox

# A successful update check with unchanged deployment must not resume dispatch.
_setup_sandbox
mkdir -p "$HOME/.aidevops/agents/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$HOME/.aidevops/agents/scripts/auto-update-helper.sh"
chmod +x "$HOME/.aidevops/agents/scripts/auto-update-helper.sh"
printf '%s\n' 'unchanged' >"$HOME/.aidevops/agents/VERSION"
for i in 1 2 3; do
	_h record-outcome no_worker_process "owner/repo#$i" >/dev/null 2>&1
done
rc=0
_h is-paused || rc=$?
outcome=$(jq -r '.circuit_breaker.last_update_outcome' "$RUNNER_HEALTH_STATE_FILE")
if [[ "$rc" -eq 0 && "$outcome" == "no_change" ]]; then
	print_result "no-op update keeps breaker paused" "PASS"
else
	print_result "no-op update keeps breaker paused" "FAIL" "rc=$rc outcome=$outcome"
fi
_teardown_sandbox

# --- Streak tests (t18927): window measures idleness, not streak age ---
_rh_epoch_ts() {
	local epoch="$1"
	date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

# Record zero-attempt outcomes at a fixed gap (minutes); optionally one
# overridden gap at index N and one real-attempt outcome at index M.
_rh_run_streak() {
	local gap_min="$1"
	local count="$2"
	local gap_override_idx="${3:-0}"
	local gap_override_min="${4:-0}"
	local real_idx="${5:-0}"
	local t=1800000000 i signal ts
	for ((i = 1; i <= count; i++)); do
		if [[ "$i" -gt 1 ]]; then
			if [[ "$i" -eq "$gap_override_idx" ]]; then
				t=$((t + gap_override_min * 60))
			else
				t=$((t + gap_min * 60))
			fi
		fi
		signal="no_worker_process"
		[[ "$i" -eq "$real_idx" ]] && signal="real_attempt_with_commit"
		ts=$(_rh_epoch_ts "$t") || return 1
		[[ -n "$ts" ]] || return 1
		RUNNER_HEALTH_TEST_NOW="$ts" _h record-outcome "$signal" "owner/repo#$i" >/dev/null 2>&1
	done
	return 0
}

_setup_sandbox
export RUNNER_HEALTH_FAILURE_THRESHOLD=10 RUNNER_HEALTH_WINDOW_HOURS=6
_rh_run_streak 50 10
if _h is-paused; then
	print_result "10 zero-attempts 50min apart trip the breaker" "PASS"
else
	print_result "10 zero-attempts 50min apart trip the breaker" "FAIL"
fi
_teardown_sandbox

_setup_sandbox
export RUNNER_HEALTH_FAILURE_THRESHOLD=10 RUNNER_HEALTH_WINDOW_HOURS=6
_rh_run_streak 50 10 5 420
if _h is-paused; then
	print_result "idle gap beyond window decays streak (no trip)" "FAIL"
else
	print_result "idle gap beyond window decays streak (no trip)" "PASS"
fi
_teardown_sandbox

_setup_sandbox
export RUNNER_HEALTH_FAILURE_THRESHOLD=10 RUNNER_HEALTH_WINDOW_HOURS=6
_rh_run_streak 50 10 0 0 5
if _h is-paused; then
	print_result "real attempt mid-streak resets it (no trip)" "FAIL"
else
	print_result "real attempt mid-streak resets it (no trip)" "PASS"
fi
_teardown_sandbox

echo ""
echo "Tests run: $TESTS_RUN, failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
