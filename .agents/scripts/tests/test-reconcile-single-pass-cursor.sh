#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reconcile-single-pass-cursor.sh — GH#34299 regression test.
#
# reconcile_issues_single_pass used to restart at the first repo and issue on
# every cycle, so a budget abort or stage-timeout kill starved every issue past
# the abort point. This drives the real orchestrator with stubbed per-issue
# stages that advance Bash's SECONDS to simulate cost, and asserts:
#   1. a budget abort records the next unprocessed position;
#   2. the next pass resumes there and rotates repos, so coverage completes;
#   3. a pass that reaches the end of the rotated list clears the cursor;
#   4. an issue resumed repeatedly without finishing is skipped;
#   5. a malformed cursor falls back to the original order;
#   6. GH#37939: the preflight stage clamps the cooperative budget to
#      min(configured, stage - 20), so the pass yields at its cursor before
#      the stage watchdog, without leaking the clamp to later stages.
#
# Usage: bash .agents/scripts/tests/test-reconcile-single-pass-cursor.sh

# shellcheck disable=SC2155
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RECONCILE_SRC="${TEST_DIR}/../pulse-issue-reconcile.sh"

pass=0
fail=0
_pass() { echo "PASS: $1"; pass=$((pass + 1)); return 0; }
_fail() { echo "FAIL: $1"; fail=$((fail + 1)); return 0; }

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-reconcile-sp-cursor.XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT

export LOGFILE="${TEST_TMPDIR}/pulse.log"
: >"$LOGFILE"
export REPOS_JSON="${TEST_TMPDIR}/repos.json"
cat >"$REPOS_JSON" <<'JSON'
{"initialized_repos": [
  {"slug": "test/a", "pulse": true, "local_only": false},
  {"slug": "test/b", "pulse": true, "local_only": false}
]}
JSON
export AIDEVOPS_RECONCILE_SP_CURSOR_FILE="${TEST_TMPDIR}/state/reconcile-single-pass.cursor"
CURSOR="$AIDEVOPS_RECONCILE_SP_CURSOR_FILE"
VISITS="${TEST_TMPDIR}/visits"
INFLIGHT="${TEST_TMPDIR}/inflight"

set_issue_status() { return 0; }
# shellcheck disable=SC1090
source "$RECONCILE_SRC"

# Stubs (defined after sourcing so they shadow the module's functions).
# shellcheck disable=SC2317
_repair_pending_planning_publications() { return 0; }
# shellcheck disable=SC2317
_repair_recently_closed_parents_cycle() { _PIR_RECENT_PARENT_CYCLE_REOPENED=0; return 0; }
# shellcheck disable=SC2317
_pir_reconcile_objective_ledger() { return 0; }
# shellcheck disable=SC2317
_build_oimp_lookup_for_slug() { return 0; }
# shellcheck disable=SC2317
_read_cache_issues_for_slug() {
	local slug="$1"
	case "$slug" in
	test/a) printf '%s' '[{"number":1,"title":"a1","labels":[],"body":""},{"number":2,"title":"a2","labels":[],"body":""},{"number":3,"title":"a3","labels":[],"body":""}]' ;;
	test/b) printf '%s' '[{"number":4,"title":"b4","labels":[],"body":""},{"number":5,"title":"b5","labels":[],"body":""}]' ;;
	*) return 1 ;;
	esac
	return 0
}
# Each issue "costs" 100 seconds of budget. slug/issue_num are the caller's
# loop locals (Bash dynamic scope), as in the real stage function.
# shellcheck disable=SC2317,SC2154
_pir_reconcile_issue_stages() {
	printf '%s#%s\n' "$slug" "$issue_num" >>"$VISITS"
	# Snapshot the in-flight cursor, i.e. what a stage-timeout kill would leave.
	tr '\t' ',' <"$CURSOR" >"$INFLIGHT" 2>/dev/null || true
	SECONDS=$((SECONDS + ${ISSUE_COST:-100}))
	return 0
}

_run_pass() {
	: >"$VISITS"
	RECONCILE_TIME_BUDGET_SECS="$1" reconcile_issues_single_pass >/dev/null 2>&1
	tr '\n' ' ' <"$VISITS" | sed 's/ $//'
	return 0
}

_cursor() {
	if [[ -f "$CURSOR" ]]; then
		tr '\t' ',' <"$CURSOR" | tr -d '\n'
	else
		printf 'none'
	fi
	return 0
}

_expect() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		_pass "$name"
	else
		_fail "${name}: expected '${expected}', got '${actual}'"
	fi
	return 0
}

rm -f "$CURSOR"
_expect "pass 1 stops at budget" "test/a#1 test/a#2 test/a#3" "$(_run_pass 250)"
_expect "pass 1 records next repo" "test/b,,0" "$(_cursor)"
_expect "pass 2 resumes and rotates" "test/b#4 test/b#5 test/a#1" "$(_run_pass 250)"
_expect "pass 2 records next issue" "test/a,2,0" "$(_cursor)"
_expect "pass 3 resumes mid-repo" "test/a#2 test/a#3 test/b#4" "$(_run_pass 250)"
_expect "pass 3 records next issue" "test/b,5,0" "$(_cursor)"

_expect "unbudgeted pass resumes then wraps" "test/b#5 test/a#1 test/a#2 test/a#3" "$(_run_pass 0)"
_expect "completed pass clears cursor" "none" "$(_cursor)"
_expect "cleared cursor restarts at top" "test/a#1 test/a#2 test/a#3 test/b#4 test/b#5" "$(_run_pass 0)"

# A stage-timeout kill leaves the in-flight issue as the cursor.
mkdir -p "${CURSOR%/*}"
printf 'test/a\t2\t1\n' >"$CURSOR"
# The resume repo's earlier issues are left for the next (top-down) pass.
_expect "killed issue is retried" "test/a#2 test/a#3 test/b#4 test/b#5" "$(_run_pass 0)"
printf 'test/a\t2\t2\n' >"$CURSOR"
_expect "repeatedly unfinished issue is skipped" "test/a#3 test/b#4 test/b#5" "$(_run_pass 0)"
if grep -q 'skipping test/a#2' "$LOGFILE"; then
	_pass "skip is logged"
else
	_fail "skip is logged"
fi

# A resumed in-flight issue is recorded with an incremented attempt count.
printf 'test/a\t2\t0\n' >"$CURSOR"
_expect "resumed issue runs first" "test/a#2" "$(_run_pass 50)"
_expect "resumed in-flight issue increments attempts" "test/a,2,1" "$(tr -d '\n' <"$INFLIGHT")"
_expect "budget abort records next issue with fresh attempts" "test/a,3,0" "$(_cursor)"

printf 'garbage\n' >"$CURSOR"
_expect "malformed cursor uses original order" "test/a#1 test/a#2 test/a#3 test/b#4 test/b#5" "$(_run_pass 0)"
printf 'test/gone\t9\t0\n' >"$CURSOR"
_expect "unknown repo cursor uses original order" "test/a#1 test/a#2 test/a#3 test/b#4 test/b#5" "$(_run_pass 0)"
printf 'test/b\t99\t0\n' >"$CURSOR"
_expect "closed cursor issue restarts its repo" "test/b#4 test/b#5 test/a#1 test/a#2 test/a#3" "$(_run_pass 0)"

# GH#37949: expensive repairs must not starve the issue loop or reset the cursor.
REPAIR_RUNS="${TEST_TMPDIR}/repair-runs"
MARKER="${CURSOR}.issues-first"
# shellcheck disable=SC2317
_repair_pending_planning_publications() {
	printf 'r\n' >>"$REPAIR_RUNS"
	SECONDS=$((SECONDS + ${REPAIR_COST:-0}))
	return 0
}
_repairs() { wc -l <"$REPAIR_RUNS" 2>/dev/null | tr -d ' ' || printf 0; return 0; }
rm -f "$CURSOR" "$MARKER"
: >"$REPAIR_RUNS"
printf 'test/a\t2\t0\n' >"$CURSOR"
export REPAIR_COST=300; _expect "repairs-first pass yields before issues" "" "$(_run_pass 250)"
_expect "repairs-first pass keeps saved position" "test/a,2,0" "$(_cursor)"
_expect "marker written for next pass" "yes" "$([[ -e "$MARKER" ]] && echo yes || echo no)"
export REPAIR_COST=300; _expect "next pass runs issues first from saved issue" "test/a#2 test/a#3 test/b#4" "$(_run_pass 250)"
_expect "issues-first aborted pass skips repairs" "1" "$(_repairs)"
rm -f "$CURSOR"
export REPAIR_COST=0; _expect "following pass runs repairs again" "test/a#1 test/a#2 test/a#3" "$(_run_pass 250)"
_expect "repairs ran on alternate pass" "2" "$(_repairs)"
rm -f "$CURSOR" "$MARKER"
: >"$REPAIR_RUNS"
printf '1\n' >"$MARKER"
_run_pass 1000 >/dev/null
_expect "completed issues-first pass runs repairs after loop" "1" "$(_repairs)"
rm -f "$CURSOR" "$MARKER"
: >"$REPAIR_RUNS"
_run_pass 0 >/dev/null
_expect "unbudgeted pass keeps repairs first, no marker" "1/no" "$(_repairs)/$([[ -e "$MARKER" ]] && echo yes || echo no)"
rm -f "$MARKER"

# Direct callers keep the 360s default (100s issues: abort before b#5).
rm -f "$CURSOR"
_expect "direct caller defaults to 360s" "test/a#1 test/a#2 test/a#3 test/b#4" "$(_run_pass "")"

# GH#37939: the preflight stage clamps the child's cooperative budget to
# min(configured, stage - 20), floor 1, so it yields before the watchdog.
unset PULSE_STAGE_DEADLINE_EPOCH RECONCILE_TIME_BUDGET_SECS
# shellcheck source=../pulse-dispatch-preflight-lib.sh
source "${TEST_DIR}/../pulse-dispatch-preflight-lib.sh"
STAGES="${TEST_TMPDIR}/stages"
# shellcheck disable=SC2317
prefetch_contribution_watch() { return 0; }
# shellcheck disable=SC2317
_log_substage_timing() { return 0; }
# shellcheck disable=SC2317
reconcile_new_external_issues() { return 0; }
# shellcheck disable=SC2317
normalize_active_issue_assignments() { return 0; }
# shellcheck disable=SC2317
run_stage_with_timeout() {
	local stage_name="$1" timeout_seconds="$2"
	shift 2
	printf '%s:%s:%s\n' "$stage_name" "$timeout_seconds" "${RECONCILE_TIME_BUDGET_SECS-unset}" >>"$STAGES"
	"$@" >/dev/null 2>&1
	return 0
}

_cooperative() {
	local configured="$1" stage_budget="$2"
	if [[ "$configured" == "unset" ]]; then
		_preflight_reconcile_cooperative_budget "$stage_budget"
	else
		RECONCILE_TIME_BUDGET_SECS="$configured" _preflight_reconcile_cooperative_budget "$stage_budget"
	fi
	return 0
}
_expect "160s stage clamps default to 140s" "140" "$(_cooperative unset 160)"
_expect "380s stage keeps the 360s default" "360" "$(_cooperative unset 380)"
_expect "shorter configured budget is kept" "50" "$(_cooperative 50 160)"
_expect "configured 0 (unbounded) is clamped" "140" "$(_cooperative 0 160)"
_expect "invalid configured budget is clamped" "140" "$(_cooperative abc 160)"
_expect "tiny stage floors at 1s" "1" "$(_cooperative unset 10)"

# Outer 228s - 8s reserve = 220s; 60s normalize floor leaves a 160s stage.
rm -f "$CURSOR" "$STAGES"
: >"$VISITS"
: >"$LOGFILE"
ISSUE_COST=50
_preflight_ownership_reconcile 228 >/dev/null 2>&1
unset ISSUE_COST
_expect "stage child sees clamped budget" "reconcile_issues_single_pass:160:140" \
	"$(grep '^reconcile_issues_single_pass:' "$STAGES")"
_expect "pass yields before the 160s watchdog" "test/a#1 test/a#2 test/a#3" \
	"$(tr '\n' ' ' <"$VISITS" | sed 's/ $//')"
# Simulated cost is 150s; real wall-clock seconds may add a little.
abort_at=$(sed -n 's/.*time-budget abort at \([0-9]*\)s (budget=140s).*/\1/p' "$LOGFILE")
if [[ "$abort_at" =~ ^[0-9]+$ && "$abort_at" -lt 160 ]]; then
	_pass "cooperative abort is logged inside the stage budget"
else
	_fail "cooperative abort is logged inside the stage budget: '${abort_at}'"
fi
_expect "cooperative yield saves the resume cursor" "test/b,,0" "$(_cursor)"
_expect "later stage does not inherit the clamp" "normalize_active_issue_assignments:unset" \
	"$(grep '^normalize_active_issue_assignments:' "$STAGES" | cut -d: -f1,3)"
_expect "caller does not inherit the clamp" "unset" "${RECONCILE_TIME_BUDGET_SECS-unset}"
_expect "next pass resumes from the saved cursor" "test/b#4 test/b#5 test/a#1 test/a#2 test/a#3" "$(_run_pass 0)"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
