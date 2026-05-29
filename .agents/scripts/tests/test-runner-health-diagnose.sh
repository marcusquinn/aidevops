#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Unit tests for `pulse-runner-health-helper.sh diagnose` (t3198 / GH#21893).
#
# The diagnose subcommand is read-only — it cross-checks the recorded
# breaker state against the observed evidence in pulse-wrapper.log and
# emits an actionable finding:
#
#   HEALTHY          — counter at zero, no recent zero-attempt events
#   BUILDING         — counter > 0 and matches log evidence (or breaker
#                      recently tripped and not yet verified)
#   RECOVERABLE_TRIPPED
#                    — tripped, update ran, deployed artifacts match repo
#   WIRING_GAP       — log shows zero-attempt events the counter never saw
#   TRIGGER_MISSED   — counter reached threshold but breaker stayed closed
#   STUCK_TRIPPED    — breaker tripped >24h, last update failed
#
# Each test builds a synthetic state file + pulse log under a sandbox HOME,
# calls `diagnose --json`, and asserts the `finding` field. JSON path makes
# the assertions deterministic; the human path is exercised separately.
#
# Sandbox model copied from test-pulse-runner-health-helper.sh — sets
# RUNNER_HEALTH_CACHE_DIR, RUNNER_HEALTH_PULSE_LOG, and HOME so no system
# state is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
AGENT_SCRIPT_DIR="${SCRIPT_DIR}/.."
HELPER="${AGENT_SCRIPT_DIR}/pulse-runner-health-helper.sh"

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

# Build a fresh sandbox with isolated cache + log paths.
_setup_sandbox() {
	SANDBOX=$(mktemp -d -t rh-diag-XXXXXX)
	export RUNNER_HEALTH_CACHE_DIR="$SANDBOX/cache"
	export RUNNER_HEALTH_ADVISORY_DIR="$SANDBOX/advisories"
	export RUNNER_HEALTH_STATE_FILE="$RUNNER_HEALTH_CACHE_DIR/runner-health.json"
	export RUNNER_HEALTH_PULSE_LOG="$SANDBOX/logs/pulse-wrapper.log"
	export RUNNER_HEALTH_DEPLOYED_VERSION_FILE="$SANDBOX/deployed/VERSION"
	export RUNNER_HEALTH_DEPLOYED_SHA_FILE="$SANDBOX/deployed/.deployed-sha"
	export RUNNER_HEALTH_FAILURE_THRESHOLD=10
	export RUNNER_HEALTH_WINDOW_HOURS=6
	# Pin "now" so STUCK_TRIPPED age math is deterministic.
	export RUNNER_HEALTH_TEST_NOW='2026-04-30T12:00:00Z'
	export HOME_BACKUP="${HOME:-/tmp}"
	export HOME="$SANDBOX/home"
	mkdir -p "$HOME" "$RUNNER_HEALTH_CACHE_DIR" "$RUNNER_HEALTH_ADVISORY_DIR" \
		"$SANDBOX/logs" "$SANDBOX/deployed"
	return 0
}

_teardown_sandbox() {
	rm -rf "$SANDBOX" 2>/dev/null || true
	SANDBOX=""
	[[ -n "${HOME_BACKUP:-}" ]] && export HOME="$HOME_BACKUP"
	return 0
}

# Write a state file with the given values. Empty args produce nulls.
# Args: $1 counter $2 state $3 tripped_at $4 last_update_outcome $5 reason
_write_state() {
	local counter="${1:-0}"
	local state="${2:-closed}"
	local tripped_at="${3:-}"
	local update_outcome="${4:-}"
	local reason="${5:-}"
	local trip_field='null'
	[[ -n "$tripped_at" ]] && trip_field="\"$tripped_at\""
	local upd_field='null'
	[[ -n "$update_outcome" ]] && upd_field="\"$update_outcome\""
	local reason_field='null'
	[[ -n "$reason" ]] && reason_field="\"$reason\""
	cat >"$RUNNER_HEALTH_STATE_FILE" <<EOF
{
  "version": 1,
  "self_login": "test",
  "consecutive_zero_attempts": $counter,
  "window_started_at": "2026-04-30T06:00:00Z",
  "last_outcomes": [],
  "circuit_breaker": {
    "state": "$state",
    "tripped_at": $trip_field,
    "last_update_attempt_at": null,
    "last_update_outcome": $upd_field,
    "reason": $reason_field
  }
}
EOF
	return 0
}

# Append N synthetic "no_worker_process" log lines (matches the regex used
# by _rh_count_log_no_worker_events).
# Args: $1 = count
_write_log_events() {
	local n="${1:-0}"
	: >"$RUNNER_HEALTH_PULSE_LOG"
	local i=0
	while [[ "$i" -lt "$n" ]]; do
		printf '[pulse-wrapper] Launch recovery reset #%s (owner/repo) after no_worker_process crash_type=launch_failure\n' \
			"$((i + 1))" >>"$RUNNER_HEALTH_PULSE_LOG"
		i=$((i + 1))
	done
	return 0
}

# Mark the sandbox deployment as aligned with the checked-out repo.
_mark_deploy_healthy() {
	local repo_root
	repo_root=$(cd "${AGENT_SCRIPT_DIR}/../.." && pwd) || return 1
	tr -d '[:space:]' <"${repo_root}/VERSION" >"$RUNNER_HEALTH_DEPLOYED_VERSION_FILE"
	if [[ -e "${repo_root}/.git" ]]; then
		git -C "$repo_root" rev-parse HEAD >"$RUNNER_HEALTH_DEPLOYED_SHA_FILE" 2>/dev/null || true
	fi
	return 0
}

# Run diagnose --json and pull the finding field. Empty on failure.
_finding() {
	bash "$HELPER" diagnose --json 2>/dev/null | jq -r '.finding // empty' 2>/dev/null || true
	return 0
}

echo "Tests for pulse-runner-health-helper.sh diagnose:"

# Sanity check.
if [[ ! -x "$HELPER" ]]; then
	print_result "helper exists and executable" "FAIL" "missing at $HELPER"
	exit 1
fi
print_result "helper exists and executable" "PASS"

# --- Test 1: HEALTHY (no state file, no log) ---
_setup_sandbox
got=$(_finding)
if [[ "$got" == "HEALTHY" ]]; then
	print_result "fresh sandbox (no state, no log) → HEALTHY" "PASS"
else
	print_result "fresh sandbox (no state, no log) → HEALTHY" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 2: BUILDING (counter < threshold, log matches counter) ---
_setup_sandbox
_write_state 3 closed
_write_log_events 3
got=$(_finding)
if [[ "$got" == "BUILDING" ]]; then
	print_result "counter=3 + 3 log events → BUILDING" "PASS"
else
	print_result "counter=3 + 3 log events → BUILDING" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 3: WIRING_GAP (log has many events, counter is zero) ---
_setup_sandbox
_write_state 0 closed
_write_log_events 8
got=$(_finding)
if [[ "$got" == "WIRING_GAP" ]]; then
	print_result "counter=0 + 8 log events → WIRING_GAP" "PASS"
else
	print_result "counter=0 + 8 log events → WIRING_GAP" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 4: TRIGGER_MISSED (counter at threshold, state still closed) ---
_setup_sandbox
_write_state 10 closed
_write_log_events 10
got=$(_finding)
if [[ "$got" == "TRIGGER_MISSED" ]]; then
	print_result "counter=10 + state=closed → TRIGGER_MISSED" "PASS"
else
	print_result "counter=10 + state=closed → TRIGGER_MISSED" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 5: STUCK_TRIPPED (tripped >24h ago, update failed) ---
_setup_sandbox
# tripped_at = 30h before the pinned RUNNER_HEALTH_TEST_NOW (2026-04-30T12:00:00Z)
# → 2026-04-29T06:00:00Z
_write_state 10 tripped '2026-04-29T06:00:00Z' failed 'consecutive_zero_attempts=10'
_write_log_events 10
got=$(_finding)
if [[ "$got" == "STUCK_TRIPPED" ]]; then
	print_result "tripped 30h ago + update=failed → STUCK_TRIPPED" "PASS"
else
	print_result "tripped 30h ago + update=failed → STUCK_TRIPPED" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 6: BUILDING when tripped recently (not stuck) ---
_setup_sandbox
# tripped_at = 1h before TEST_NOW → recent trip, age 1h, not stuck.
_write_state 10 tripped '2026-04-30T11:00:00Z' ran 'consecutive_zero_attempts=10'
_write_log_events 10
got=$(_finding)
if [[ "$got" == "BUILDING" ]]; then
	print_result "tripped 1h ago + update=ran → BUILDING" "PASS"
else
	print_result "tripped 1h ago + update=ran → BUILDING" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 7: RECOVERABLE_TRIPPED when update ran and deployment is healthy ---
_setup_sandbox
_write_state 10 tripped '2026-04-29T06:00:00Z' ran 'consecutive_zero_attempts=10'
_mark_deploy_healthy
_write_log_events 10
got=$(_finding)
if [[ "$got" == "RECOVERABLE_TRIPPED" ]]; then
	print_result "tripped 30h ago + update=ran + healthy deploy → RECOVERABLE_TRIPPED" "PASS"
else
	print_result "tripped 30h ago + update=ran + healthy deploy → RECOVERABLE_TRIPPED" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 7b: stale tripped + successful healthy update auto-resumes is-paused ---
_setup_sandbox
_write_state 10 tripped '2026-04-29T06:00:00Z' ran 'consecutive_zero_attempts=10'
_mark_deploy_healthy
rc=0
bash "$HELPER" is-paused >/dev/null 2>&1 || rc=$?
state=$(jq -r '.circuit_breaker.state' <"$RUNNER_HEALTH_STATE_FILE")
counter=$(jq -r '.consecutive_zero_attempts' <"$RUNNER_HEALTH_STATE_FILE")
if [[ "$rc" -eq 1 && "$state" == "closed" && "$counter" == "0" ]]; then
	print_result "is-paused auto-resumes stale tripped breaker after healthy update" "PASS"
else
	print_result "is-paused auto-resumes stale tripped breaker after healthy update" "FAIL" \
		"rc=$rc state=$state counter=$counter"
fi
_teardown_sandbox

# --- Test 7c: stale tripped + failed update remains paused/protected ---
_setup_sandbox
_write_state 10 tripped '2026-04-29T06:00:00Z' failed 'consecutive_zero_attempts=10'
rc=0
bash "$HELPER" is-paused >/dev/null 2>&1 || rc=$?
state=$(jq -r '.circuit_breaker.state' <"$RUNNER_HEALTH_STATE_FILE")
if [[ "$rc" -eq 0 && "$state" == "tripped" ]]; then
	print_result "is-paused keeps failed-update tripped breaker protected" "PASS"
else
	print_result "is-paused keeps failed-update tripped breaker protected" "FAIL" \
		"rc=$rc state=$state"
fi
_teardown_sandbox

# --- Test 7d: normal closed state is not paused ---
_setup_sandbox
_write_state 0 closed
rc=0
bash "$HELPER" is-paused >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then
	print_result "is-paused returns safe-to-dispatch for normal closed state" "PASS"
else
	print_result "is-paused returns safe-to-dispatch for normal closed state" "FAIL" "rc=$rc"
fi
_teardown_sandbox

# --- Test 8: WIRING_GAP precedence over TRIGGER_MISSED ---
# When the log shows many events AND the counter sits at threshold but the
# state is closed, BOTH categories could apply. WIRING_GAP wins (deeper bug
# — the recorder isn't even being called, so counter==threshold is a fluke).
_setup_sandbox
_write_state 10 closed
_write_log_events 50
got=$(_finding)
if [[ "$got" == "WIRING_GAP" ]]; then
	print_result "counter=10 + 50 log events → WIRING_GAP wins over TRIGGER_MISSED" "PASS"
else
	print_result "counter=10 + 50 log events → WIRING_GAP wins over TRIGGER_MISSED" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 9: small delta (<=2) does NOT trigger WIRING_GAP ---
# Two-event window of slack absorbs benign timing skew between the recorder
# (writes counter atomically) and the log writer (line buffered).
_setup_sandbox
_write_state 5 closed
_write_log_events 7
got=$(_finding)
if [[ "$got" == "BUILDING" ]]; then
	print_result "counter=5 + 7 log events (delta=2) → BUILDING (within slack)" "PASS"
else
	print_result "counter=5 + 7 log events (delta=2) → BUILDING (within slack)" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 10: missing log file does not crash diagnose ---
_setup_sandbox
_write_state 2 closed
# No log file written.
got=$(_finding)
if [[ "$got" == "BUILDING" ]]; then
	print_result "missing pulse log → expected_counter=0, finding stays BUILDING" "PASS"
else
	print_result "missing pulse log → expected_counter=0, finding stays BUILDING" "FAIL" "got: $got"
fi
_teardown_sandbox

# --- Test 11: human output emits the finding line ---
_setup_sandbox
_write_state 0 closed
out=$(bash "$HELPER" diagnose 2>&1 || true)
if echo "$out" | grep -q '^finding: *HEALTHY$'; then
	print_result "human output starts with 'finding: HEALTHY'" "PASS"
else
	print_result "human output starts with 'finding: HEALTHY'" "FAIL" "got: $out"
fi
_teardown_sandbox

# --- Test 12: JSON output is valid and contains required keys ---
_setup_sandbox
_write_state 5 closed
_write_log_events 5
out=$(bash "$HELPER" diagnose --json 2>&1 || true)
ok=1
echo "$out" | jq -e '.finding, .state, .recorded_counter, .expected_counter, .delta, .threshold, .advice' >/dev/null 2>&1 || ok=0
if [[ "$ok" -eq 1 ]]; then
	print_result "JSON output contains all required keys" "PASS"
else
	print_result "JSON output contains all required keys" "FAIL" "got: $out"
fi
_teardown_sandbox

# --- Test 13: log counter ignores unrelated lines ---
_setup_sandbox
_write_state 0 closed
{
	printf '[pulse-wrapper] some unrelated line\n'
	printf '[pulse-wrapper] Launch recovery reset #1 (owner/repo) after low_token_usage crash_type=launch_failure\n'
	printf '[pulse-wrapper] Launch recovery reset #2 (owner/repo) after no_worker_process crash_type=launch_failure\n'
} >"$RUNNER_HEALTH_PULSE_LOG"
out=$(bash "$HELPER" diagnose --json 2>&1 || true)
expected=$(echo "$out" | jq -r '.expected_counter // -1' 2>/dev/null || echo "-1")
if [[ "$expected" == "1" ]]; then
	print_result "log counter ignores other failure_reason lines (expected_counter=1)" "PASS"
else
	print_result "log counter ignores other failure_reason lines (expected_counter=1)" "FAIL" "got: $expected"
fi
_teardown_sandbox

# --- Test 14: dispatcher routes 'diagnose' subcommand ---
# Regression test for main()/case wiring — calling `diagnose` should not
# fall through to "Unknown subcommand".
_setup_sandbox
out=$(bash "$HELPER" diagnose 2>&1 || true)
if echo "$out" | grep -q "^finding:"; then
	print_result "main() dispatcher routes 'diagnose' to cmd_diagnose" "PASS"
else
	print_result "main() dispatcher routes 'diagnose' to cmd_diagnose" "FAIL" "got: $out"
fi
_teardown_sandbox

# --- Test 15: help text mentions diagnose ---
out=$(bash "$HELPER" help 2>&1 || true)
if echo "$out" | grep -q 'diagnose \[--json\]'; then
	print_result "help text documents diagnose subcommand" "PASS"
else
	print_result "help text documents diagnose subcommand" "FAIL"
fi

echo ""
echo "Tests run: $TESTS_RUN, failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
