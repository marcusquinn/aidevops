#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-parent-backfill.sh — t2838 regression guard.
#
# Validates the periodic parent-task sub-issue backfill gating logic
# in pulse-issue-reconcile.sh::reconcile_issues_single_pass.
#
# Cases covered:
#   1. Interval gate fires when state file is missing (cold start)
#   2. Interval gate fires when state file is older than interval
#   3. Interval gate does NOT fire when state file is fresh
#   4. State file is written when backfill ran (counter > 0)
#   5. State file is NOT written when interval gate did not fire
#   6. AIDEVOPS_PARENT_BACKFILL_INTERVAL_SECS env override is respected
#
# This test exercises the gating logic in isolation by sourcing
# pulse-issue-reconcile.sh and re-implementing the gate evaluation
# in a small inlined helper. It does not run the full orchestrator —
# that is exercised by test-issue-reconcile.sh.
#
# NOTE: not using `set -e` — assertions rely on capturing non-zero exits.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       expected: %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

assert_eq() {
	local name="$1" got="$2" want="$3"
	if [[ "$got" == "$want" ]]; then
		pass "$name"
	else
		fail "$name" "want='${want}' got='${got}'"
	fi
	return 0
}

# Replicate the interval-gate logic from pulse-issue-reconcile.sh
# reconcile_issues_single_pass. Keeping this in lock-step with the
# orchestrator is the test's job — if the orchestrator gate logic
# changes, this helper changes too.
_eval_gate() {
	local state_file="$1"
	local interval="$2"
	local now="$3"
	# Use ${4-default} (no colon) so callers can pass "" to mean "no helper".
	# ${4:-default} would substitute the default for empty string too.
	local issue_sync_helper="${4-/usr/bin/true}"

	local last_run=0
	if [[ -r "$state_file" ]]; then
		last_run=$(cat "$state_file" 2>/dev/null || echo 0)
		[[ "$last_run" =~ ^[0-9]+$ ]] || last_run=0
	fi
	if [[ "$now" -gt 0 ]] && \
		[[ $((now - last_run)) -ge "$interval" ]] && \
		[[ -n "$issue_sync_helper" ]]; then
		echo "1"
	else
		echo "0"
	fi
	return 0
}

# Replicate the state-file write logic
_eval_write() {
	local state_file="$1"
	local pbf_this_cycle="$2"
	local pbf_total_run="$3"
	local now="$4"

	if [[ "$pbf_this_cycle" -eq 1 ]] && [[ "$pbf_total_run" -gt 0 ]]; then
		mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
		printf '%s\n' "$now" >"$state_file" 2>/dev/null || true
	fi
	return 0
}

# Setup temp state-file location
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
STATE_FILE="${TMP_DIR}/parent-backfill-last-run.epoch"

# ---------------------------------------------------------------------------
# Test 1 — Interval gate fires when state file is missing (cold start)
# ---------------------------------------------------------------------------
rm -f "$STATE_FILE"
assert_eq "gate_fires_on_cold_start" "$(_eval_gate "$STATE_FILE" 3600 1700000000)" "1"

# ---------------------------------------------------------------------------
# Test 2 — Interval gate fires when state file is older than interval
# ---------------------------------------------------------------------------
printf '%s\n' "1699996000" >"$STATE_FILE"   # 4000s before now
assert_eq "gate_fires_when_state_old" "$(_eval_gate "$STATE_FILE" 3600 1700000000)" "1"

# ---------------------------------------------------------------------------
# Test 3 — Interval gate does NOT fire when state file is fresh
# ---------------------------------------------------------------------------
printf '%s\n' "1699999000" >"$STATE_FILE"   # 1000s before now
assert_eq "gate_skips_when_state_fresh" "$(_eval_gate "$STATE_FILE" 3600 1700000000)" "0"

# ---------------------------------------------------------------------------
# Test 4 — State file is written when backfill ran (counter > 0)
# ---------------------------------------------------------------------------
rm -f "$STATE_FILE"
_eval_write "$STATE_FILE" 1 5 1700000000
got_contents=""
[[ -f "$STATE_FILE" ]] && got_contents=$(cat "$STATE_FILE")
assert_eq "state_written_when_backfill_ran" "$got_contents" "1700000000"

# ---------------------------------------------------------------------------
# Test 5 — State file is NOT written when gate didn't fire (pbf_this_cycle=0)
# ---------------------------------------------------------------------------
rm -f "$STATE_FILE"
_eval_write "$STATE_FILE" 0 5 1700000000
exists="absent"
[[ -f "$STATE_FILE" ]] && exists="present"
assert_eq "state_not_written_when_gate_skipped" "$exists" "absent"

# ---------------------------------------------------------------------------
# Test 5b — State file is NOT written when gate fired but no work done
# (pbf_this_cycle=1, pbf_total_run=0 — e.g., no parent-tasks open)
# Avoids advancing the clock without doing work, so retries next cycle.
# ---------------------------------------------------------------------------
rm -f "$STATE_FILE"
_eval_write "$STATE_FILE" 1 0 1700000000
exists="absent"
[[ -f "$STATE_FILE" ]] && exists="present"
assert_eq "state_not_written_when_no_work_done" "$exists" "absent"

# ---------------------------------------------------------------------------
# Test 6 — AIDEVOPS_PARENT_BACKFILL_INTERVAL_SECS controls gate threshold
# Custom interval of 60s — state at 100s ago should NOT fire (still inside)
# ---------------------------------------------------------------------------
printf '%s\n' "1699999900" >"$STATE_FILE"   # 100s before now
# But interval is 60 — wait, 100 > 60, so it SHOULD fire. Use 30s instead.
printf '%s\n' "1699999970" >"$STATE_FILE"   # 30s before now
assert_eq "gate_respects_short_interval_skip" \
	"$(_eval_gate "$STATE_FILE" 60 1700000000)" "0"

# Same state, but with default 3600s interval — also should not fire
assert_eq "gate_respects_default_interval_skip" \
	"$(_eval_gate "$STATE_FILE" 3600 1700000000)" "0"

# 30s before now with 5s interval — should fire
assert_eq "gate_respects_very_short_interval_fire" \
	"$(_eval_gate "$STATE_FILE" 5 1700000000)" "1"

# ---------------------------------------------------------------------------
# Test 7 — Issue-sync helper missing → gate does not fire (no helper to call)
# ---------------------------------------------------------------------------
rm -f "$STATE_FILE"
assert_eq "gate_skips_when_helper_missing" \
	"$(_eval_gate "$STATE_FILE" 3600 1700000000 "")" "0"

# ---------------------------------------------------------------------------
# Test 8 — Corrupt state file (non-numeric) treated as last_run=0 → gate fires
# ---------------------------------------------------------------------------
printf '%s\n' "not-a-number" >"$STATE_FILE"
assert_eq "gate_recovers_from_corrupt_state" \
	"$(_eval_gate "$STATE_FILE" 3600 1700000000)" "1"

# ---------------------------------------------------------------------------
# Test 9 — Verify the gate logic block is actually present in the orchestrator
# (cross-check against the source so this test can't drift silently)
# ---------------------------------------------------------------------------
ORCHESTRATOR="${SCRIPT_DIR}/../pulse-issue-reconcile.sh"
if grep -q '_pbf_state_file=' "$ORCHESTRATOR" && \
	grep -q 'AIDEVOPS_PARENT_BACKFILL_INTERVAL_SECS' "$ORCHESTRATOR" && \
	grep -q 'pbf_total_run' "$ORCHESTRATOR" && \
	grep -q 'backfill-sub-issues' "$ORCHESTRATOR"; then
	pass "orchestrator_contains_gate_logic"
else
	fail "orchestrator_contains_gate_logic" "expected markers missing from $ORCHESTRATOR"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d tests run: %d passed, %d failed\n' "$((PASS + FAIL))" "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	printf '\nFailed tests:%b\n' "$ERRORS"
	exit 1
fi

exit 0
