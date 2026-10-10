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
#   5. a malformed cursor falls back to the original order.
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
	SECONDS=$((SECONDS + 100))
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

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
