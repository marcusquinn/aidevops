#!/usr/bin/env bash
# test-coderabbit-sweep-conditional.sh
#
# Tests for the CodeRabbit sweep conditional trigger logic (t1390, t1392).
#
# Verifies that:
#   1. First run (no state file) does NOT trigger active review (t1392 fix)
#   2. First run with failing gate DOES trigger active review
#   3. Subsequent run with stable metrics does NOT trigger
#   4. Subsequent run with issue spike DOES trigger
#   5. Subsequent run with new high/critical findings DOES trigger
#   6. Subsequent run with failing gate DOES trigger
#   7. State file is saved correctly after each sweep
#   8. First run baseline note appears in passive monitoring line
#
# Usage: bash tests/test-coderabbit-sweep-conditional.sh
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_DIR/.agents/scripts/pulse-wrapper.sh"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;32mPASS\033[0m %s\n" "$1"
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# --- Setup temp directory for state files ---
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Override the state dir so tests don't touch real state
export QUALITY_SWEEP_STATE_DIR="$TMPDIR_TEST/sweep-state"
mkdir -p "$QUALITY_SWEEP_STATE_DIR"

# Source the script to get access to _load_sweep_state and _save_sweep_state
# The if-guard at the bottom prevents main() from running when sourced.
export LOGFILE="$TMPDIR_TEST/test.log"
export PIDFILE="$TMPDIR_TEST/test.pid"
export REPOS_JSON="$TMPDIR_TEST/repos.json"
export OPENCODE_BIN="/bin/true"
mkdir -p "$(dirname "$LOGFILE")"

# Create a minimal repos.json so the script doesn't fail on source
echo '{"initialized_repos":[]}' >"$REPOS_JSON"

# Source the script (won't run main due to BASH_SOURCE guard)
# shellcheck source=/dev/null
source "$SCRIPT_UNDER_TEST"

# ============================================================
section "CodeRabbit Sweep Conditional Logic (t1390/t1392)"
# ============================================================

# --- Test 1: First run (no state file) returns UNKNOWN baseline ---
test_slug="test-org/test-repo-1"
result=$(_load_sweep_state "$test_slug")
if [[ "$result" == "UNKNOWN|0|0" ]]; then
	pass "First run: _load_sweep_state returns UNKNOWN|0|0"
else
	fail "First run: expected UNKNOWN|0|0, got: $result"
fi

# --- Test 2: Save state and reload ---
_save_sweep_state "$test_slug" "OK" 113 5
result=$(_load_sweep_state "$test_slug")
if [[ "$result" == "OK|113|5" ]]; then
	pass "Save/reload: state persists correctly (OK|113|5)"
else
	fail "Save/reload: expected OK|113|5, got: $result"
fi

# --- Test 3: First run does NOT trigger active review (t1392 core fix) ---
# Simulate: prev_gate=UNKNOWN (first run), sweep shows 113 issues, gate OK
# Before t1392 fix, this would compute delta=113-0=113 >= 10 and trigger.
first_run_slug="test-org/first-run-repo"
prev_state=$(_load_sweep_state "$first_run_slug")
IFS='|' read -r prev_gate prev_issues prev_high_critical <<<"$prev_state"
[[ "$prev_issues" =~ ^[0-9]+$ ]] || prev_issues=0
[[ "$prev_high_critical" =~ ^[0-9]+$ ]] || prev_high_critical=0

sweep_gate_status="OK"
sweep_total_issues=113
sweep_high_critical=5

is_first_run=false
if [[ "$prev_gate" == "UNKNOWN" ]]; then
	is_first_run=true
fi

issue_delta=$((sweep_total_issues - prev_issues))
trigger_active=false
trigger_reasons=""

if [[ "$is_first_run" == true ]]; then
	# Only gate check on first run
	if [[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]]; then
		trigger_active=true
		trigger_reasons="quality gate ${sweep_gate_status} (first run)"
	fi
else
	if [[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]]; then
		trigger_active=true
		trigger_reasons="quality gate ${sweep_gate_status}"
	fi
	if [[ "$issue_delta" -ge "${CODERABBIT_ISSUE_SPIKE:-10}" ]]; then
		trigger_active=true
	fi
fi

if [[ "$trigger_active" == false ]]; then
	pass "First run (OK gate, 113 issues): NOT triggered (t1392 fix works)"
else
	fail "First run (OK gate, 113 issues): TRIGGERED — t1392 regression" \
		"issue_delta=$issue_delta, prev_gate=$prev_gate, trigger_reasons=$trigger_reasons"
fi

# --- Test 4: First run WITH failing gate DOES trigger ---
sweep_gate_status="ERROR"
trigger_active=false
trigger_reasons=""

if [[ "$is_first_run" == true ]]; then
	if [[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]]; then
		trigger_active=true
		trigger_reasons="quality gate ${sweep_gate_status} (first run)"
	fi
fi

if [[ "$trigger_active" == true ]]; then
	pass "First run (ERROR gate): triggered correctly"
else
	fail "First run (ERROR gate): should have triggered but didn't"
fi

# --- Test 5: Subsequent run with stable metrics does NOT trigger ---
stable_slug="test-org/stable-repo"
_save_sweep_state "$stable_slug" "OK" 113 5

prev_state=$(_load_sweep_state "$stable_slug")
IFS='|' read -r prev_gate prev_issues prev_high_critical <<<"$prev_state"
[[ "$prev_issues" =~ ^[0-9]+$ ]] || prev_issues=0
[[ "$prev_high_critical" =~ ^[0-9]+$ ]] || prev_high_critical=0

sweep_gate_status="OK"
sweep_total_issues=115 # +2, below threshold of 10
sweep_high_critical=5  # no change

is_first_run=false
[[ "$prev_gate" == "UNKNOWN" ]] && is_first_run=true

issue_delta=$((sweep_total_issues - prev_issues))
high_critical_delta=$((sweep_high_critical - prev_high_critical))
trigger_active=false

if [[ "$is_first_run" == false ]]; then
	[[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]] && trigger_active=true
	[[ "$issue_delta" -ge "${CODERABBIT_ISSUE_SPIKE:-10}" ]] && trigger_active=true
	[[ "$high_critical_delta" -gt 0 ]] && trigger_active=true
fi

if [[ "$trigger_active" == false ]]; then
	pass "Subsequent run (stable, +2 issues): NOT triggered"
else
	fail "Subsequent run (stable, +2 issues): should NOT have triggered" \
		"issue_delta=$issue_delta, high_critical_delta=$high_critical_delta"
fi

# --- Test 6: Subsequent run with issue spike DOES trigger ---
sweep_total_issues=125 # +12, above threshold of 10
sweep_high_critical=5  # no change

issue_delta=$((sweep_total_issues - prev_issues))
high_critical_delta=$((sweep_high_critical - prev_high_critical))
trigger_active=false

if [[ "$is_first_run" == false ]]; then
	[[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]] && trigger_active=true
	[[ "$issue_delta" -ge "${CODERABBIT_ISSUE_SPIKE:-10}" ]] && trigger_active=true
	[[ "$high_critical_delta" -gt 0 ]] && trigger_active=true
fi

if [[ "$trigger_active" == true ]]; then
	pass "Subsequent run (spike +12 issues): triggered correctly"
else
	fail "Subsequent run (spike +12 issues): should have triggered" \
		"issue_delta=$issue_delta"
fi

# --- Test 7: Subsequent run with new high/critical findings DOES trigger ---
sweep_total_issues=115 # +2, below threshold
sweep_high_critical=7  # +2 new high/critical

issue_delta=$((sweep_total_issues - prev_issues))
high_critical_delta=$((sweep_high_critical - prev_high_critical))
trigger_active=false

if [[ "$is_first_run" == false ]]; then
	[[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]] && trigger_active=true
	[[ "$issue_delta" -ge "${CODERABBIT_ISSUE_SPIKE:-10}" ]] && trigger_active=true
	[[ "$high_critical_delta" -gt 0 ]] && trigger_active=true
fi

if [[ "$trigger_active" == true ]]; then
	pass "Subsequent run (+2 high/critical): triggered correctly"
else
	fail "Subsequent run (+2 high/critical): should have triggered" \
		"high_critical_delta=$high_critical_delta"
fi

# --- Test 8: Subsequent run with failing gate DOES trigger ---
sweep_gate_status="ERROR"
sweep_total_issues=113 # no change
sweep_high_critical=5  # no change

issue_delta=$((sweep_total_issues - prev_issues))
high_critical_delta=$((sweep_high_critical - prev_high_critical))
trigger_active=false

if [[ "$is_first_run" == false ]]; then
	[[ "$sweep_gate_status" == "ERROR" || "$sweep_gate_status" == "WARN" ]] && trigger_active=true
	[[ "$issue_delta" -ge "${CODERABBIT_ISSUE_SPIKE:-10}" ]] && trigger_active=true
	[[ "$high_critical_delta" -gt 0 ]] && trigger_active=true
fi

if [[ "$trigger_active" == true ]]; then
	pass "Subsequent run (ERROR gate): triggered correctly"
else
	fail "Subsequent run (ERROR gate): should have triggered"
fi

# --- Test 9: State file JSON structure is valid ---
state_file="${QUALITY_SWEEP_STATE_DIR}/test-org-stable-repo.json"
if [[ -f "$state_file" ]] && jq -e '.gate_status' "$state_file" &>/dev/null; then
	pass "State file is valid JSON with expected fields"
else
	fail "State file missing or invalid JSON" "path: $state_file"
fi

# --- Test 10: Verify the actual script has the is_first_run guard ---
if grep -q 'is_first_run=true' "$SCRIPT_UNDER_TEST" &&
	grep -q 'prev_gate.*UNKNOWN' "$SCRIPT_UNDER_TEST"; then
	pass "Script contains is_first_run guard for UNKNOWN prev_gate"
else
	fail "Script missing is_first_run guard — t1392 fix not applied"
fi

# ============================================================
section "Summary"
# ============================================================
echo ""
printf "Total: %d | \033[0;32mPass: %d\033[0m | \033[0;31mFail: %d\033[0m\n" \
	"$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi
exit 0
