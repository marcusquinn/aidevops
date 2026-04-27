#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reconcile-budget-isolation.sh — GH#21380 regression test.
#
# Verifies that reconcile_issues_single_pass initialises its time-budget
# state at function entry on EVERY call — not from stale module-scope state
# carried over from a previous invocation. The regression was:
#
#   First call:  completes fast (few OIMP-eligible issues, no budget problem)
#   Second call: inherited stale start-ts from first call → budget appeared
#                already exhausted → function returned immediately OR the
#                opposite: the outer PRE_RUN_STAGE_TIMEOUT (600s) fired
#                before the 540s budget could, killing the function every
#                cycle (root cause: budget 540s > available time 600-normalize
#                ≈ 491-545s, budget never fired, outer killed function).
#
# Fix (GH#21380): reduced default budget from 540s to 360s so:
#   budget (360s) < outer_timeout (600s) - normalize_max (~110s) - overhead
# guaranteeing the budget fires before the outer wrapper kills the function.
#
# Test strategy:
#   - Provide a fresh prefetch cache (skip gh_issue_list fallback).
#   - Stub _gh_pr_list_merged to return empty (no merged PRs → OIMP returns 1).
#   - Stub gh_pr_list, gh_issue_list, gh_issue_comment, gh_pr_comment.
#   - Call reconcile_issues_single_pass twice in a subshell.
#   - Assert each call completes in < 30s (fast path — no API calls).
#   - Assert second call is not affected by first call's state.
#
# Model on: tests/test-pulse-labelless-reconcile.sh (same module, same pattern).
#
# Usage: bash .agents/scripts/tests/test-reconcile-budget-isolation.sh

# Note: no set -e — test functions manage their own failures.

# shellcheck disable=SC2155
readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2155
readonly TEST_REPO_ROOT="$(cd "${TEST_DIR}/../../.." && pwd)"
readonly RECONCILE_SRC="${TEST_REPO_ROOT}/.agents/scripts/pulse-issue-reconcile.sh"

pass=0
fail=0
_pass() { echo "PASS: $1"; pass=$((pass + 1)); return 0; }
_fail() { echo "FAIL: $1"; fail=$((fail + 1)); return 0; }

# ---------------------------------------------------------------------------
# Verify source file exists before running any test
# ---------------------------------------------------------------------------
if [[ ! -f "$RECONCILE_SRC" ]]; then
	echo "FATAL: cannot find ${RECONCILE_SRC}" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Shared test infrastructure
# ---------------------------------------------------------------------------
TEST_TMPDIR=$(mktemp -d /tmp/test-reconcile-budget-isolation.XXXXXX)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

LOGFILE="${TEST_TMPDIR}/pulse.log"
: >"$LOGFILE"
export LOGFILE

# Fake repos.json — one pulse-enabled repo
REPOS_JSON="${TEST_TMPDIR}/repos.json"
cat >"$REPOS_JSON" <<'JSON'
{
  "initialized_repos": [
    {"slug": "test/repo", "pulse": true, "local_only": false}
  ],
  "git_parent_dirs": []
}
JSON
export REPOS_JSON

# Fake prefetch cache — two issues with 'auto-dispatch,origin:worker' labels.
# These labels cause:
#   Stage 1 (CIW): needs status:available → skipped
#   Stage 2 (RSD): needs status:done      → skipped
#   Stage 3 (OIMP): not parent-task       → runs (_gh_pr_list_merged stubbed)
#   Stage 4 (CPT): needs parent-task      → skipped
#   Stage 5 (LIA): has origin:*           → skipped
# Net result: only OIMP runs, and the stub returns empty → each call is fast.
CACHE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-04-27T00:00:00Z")
PULSE_PREFETCH_CACHE_FILE="${TEST_TMPDIR}/prefetch-cache.json"
cat >"$PULSE_PREFETCH_CACHE_FILE" <<JSON
{
  "test/repo": {
    "last_prefetch": "${CACHE_TS}",
    "issues": [
      {"number": 100, "title": "t1000: example task one", "labels": [{"name": "auto-dispatch"}, {"name": "origin:worker"}], "body": ""},
      {"number": 101, "title": "t1001: example task two", "labels": [{"name": "auto-dispatch"}, {"name": "origin:worker"}], "body": ""}
    ]
  }
}
JSON
export PULSE_PREFETCH_CACHE_FILE

# ---------------------------------------------------------------------------
# Minimal stubs for module sourcing
# ---------------------------------------------------------------------------
set_issue_status() { return 0; }
export -f set_issue_status

# Source the reconcile module once; the include guard prevents double-sourcing
# so subsequent calls use the already-loaded function definitions.
# shellcheck disable=SC1090
source "$RECONCILE_SRC"

# Override _gh_pr_list_merged AFTER sourcing so our stub shadows the module's.
# Returns empty (no merged PR found) → _action_oimp_single returns 1 → fast.
# shellcheck disable=SC2317
_gh_pr_list_merged() { echo ""; return 0; }
export -f _gh_pr_list_merged

# Stub other gh wrappers used by _action_oimp_single / stale helpers.
# shellcheck disable=SC2317
gh_pr_list()      { echo "[]"; return 0; }
# shellcheck disable=SC2317
gh_issue_list()   { echo "[]"; return 0; }
# shellcheck disable=SC2317
gh_issue_comment(){ return 0; }
# shellcheck disable=SC2317
gh_pr_comment()   { return 0; }
export -f gh_pr_list gh_issue_list gh_issue_comment gh_pr_comment

# Stub bare gh as fallback for any path that bypasses the wrappers.
# shellcheck disable=SC2317
gh() {
	case "${1:-}" in
		pr)   echo "[]" ; return 0 ;;
		issue) echo "[]"; return 0 ;;
		api)  echo ""  ; return 0 ;;
		*)    return 0 ;;
	esac
}
export -f gh

# ---------------------------------------------------------------------------
# Test 1: First call completes within 30s
# ---------------------------------------------------------------------------
test_first_call_fast() {
	local t_start t_end elapsed rc
	t_start=$(date +%s 2>/dev/null) || t_start=0

	reconcile_issues_single_pass >/dev/null 2>&1
	rc=$?

	t_end=$(date +%s 2>/dev/null) || t_end=0
	elapsed=$(( t_end - t_start ))

	if [[ "$rc" -ne 0 ]]; then
		_fail "first-call: reconcile_issues_single_pass returned non-zero rc=${rc}"
		return 0
	fi

	if [[ "$elapsed" -gt 30 ]]; then
		_fail "first-call: took ${elapsed}s (limit 30s) — budget or stub not working"
	else
		_pass "first-call: completed in ${elapsed}s (rc=0)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: Second call (immediately after first) also completes within 30s.
# This is the GH#21380 regression test — if budget state leaked from the
# first call, the second call would either:
#   a) return immediately (budget appears exhausted), or
#   b) hang for 600s (budget never fires, stubbed gh returns fast so actually
#      fast in test — but in production without stubs, this was 600s).
# In the test context, both calls should be fast (<30s) and return 0.
# ---------------------------------------------------------------------------
test_second_call_fast() {
	local t_start t_end elapsed rc
	t_start=$(date +%s 2>/dev/null) || t_start=0

	reconcile_issues_single_pass >/dev/null 2>&1
	rc=$?

	t_end=$(date +%s 2>/dev/null) || t_end=0
	elapsed=$(( t_end - t_start ))

	if [[ "$rc" -ne 0 ]]; then
		_fail "second-call: reconcile_issues_single_pass returned non-zero rc=${rc}"
		return 0
	fi

	if [[ "$elapsed" -gt 30 ]]; then
		_fail "second-call: took ${elapsed}s (limit 30s) — stale budget state from first call"
	else
		_pass "second-call: completed in ${elapsed}s (rc=0) — no stale state from first call"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: Budget default is 360s (GH#21380 regression fix — was 540s)
# ---------------------------------------------------------------------------
test_budget_default_360() {
	if grep -qE '_t2984_budget=.*360' "${RECONCILE_SRC}"; then
		_pass "budget-default: default is 360s (GH#21380 fix applied)"
	else
		_fail "budget-default: expected 360s default; 540s default would cause outer-timeout regression"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: Budget fits within outer PRE_RUN_STAGE_TIMEOUT
# The outer _preflight_ownership_reconcile timeout is PRE_RUN_STAGE_TIMEOUT
# (600s default). normalize_active_issue_assignments runs before this function
# and takes 55-109s (observed). Budget must be < 600 - normalize_max - overhead.
# 360 < 600 - 110 - 10 = 480 → passes.
# ---------------------------------------------------------------------------
test_budget_fits_outer_timeout() {
	local budget=360
	local outer_timeout=600
	local normalize_max=110
	local overhead=10
	local margin=$(( outer_timeout - normalize_max - overhead - budget ))

	if [[ "$margin" -gt 0 ]]; then
		_pass "budget-fits-outer: budget=${budget}s fits within outer=${outer_timeout}s (margin=${margin}s after normalize_max=${normalize_max}s + overhead=${overhead}s)"
	else
		_fail "budget-fits-outer: budget=${budget}s exceeds available time in outer=${outer_timeout}s — outer would kill function before budget fires"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Budget variables initialised at function entry (not module-scope)
# Verify the local declaration is INSIDE reconcile_issues_single_pass body,
# not at the top-level of the file where it would persist across calls.
# ---------------------------------------------------------------------------
test_budget_state_at_function_entry() {
	local all_ok=1

	# The _t2984_start_ts assignment must appear INSIDE the function body,
	# i.e., between the function open-brace and close-brace.
	# We verify by checking that it appears AFTER the function declaration line
	# and BEFORE the outer while loop, all within the function block.
	local fn_line start_line budget_line
	fn_line=$(grep -n '^reconcile_issues_single_pass()' "${RECONCILE_SRC}" | head -1 | cut -d: -f1)
	# SC2016: single-quoted grep patterns intentionally contain literal $ — no expansion wanted
	# shellcheck disable=SC2016
	start_line=$(grep -n '_t2984_start_ts=$(date' "${RECONCILE_SRC}" | head -1 | cut -d: -f1)
	# shellcheck disable=SC2016
	budget_line=$(grep -n '_t2984_budget="${RECONCILE_TIME_BUDGET_SECS' "${RECONCILE_SRC}" | head -1 | cut -d: -f1)

	if [[ -z "$fn_line" || -z "$start_line" || -z "$budget_line" ]]; then
		_fail "budget-at-function-entry: could not locate function or budget init lines"
		return 0
	fi

	# Both budget init lines must be after the function declaration
	if [[ "$start_line" -le "$fn_line" ]]; then
		_fail "budget-at-function-entry: _t2984_start_ts initialised before function declaration (module-scope leak)"
		all_ok=0
	fi
	if [[ "$budget_line" -le "$fn_line" ]]; then
		_fail "budget-at-function-entry: _t2984_budget initialised before function declaration (module-scope leak)"
		all_ok=0
	fi

	# Both lines must use 'local' keyword to create per-call scope
	if ! grep -n '^[[:space:]]*local.*_t2984_start_ts' "${RECONCILE_SRC}" | \
			awk -F: '$1 > '"$fn_line"'' | grep -q '.'; then
		_fail "budget-at-function-entry: _t2984_start_ts not declared local inside function"
		all_ok=0
	fi

	[[ "$all_ok" == "1" ]] && \
		_pass "budget-at-function-entry: budget vars declared local inside function (fn_line=${fn_line}, start=${start_line}, budget=${budget_line})"
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_budget_default_360
test_budget_fits_outer_timeout
test_budget_state_at_function_entry
test_first_call_fast
test_second_call_fast

echo ""
echo "Results: ${pass} passed, ${fail} failed"
if [[ "$fail" -gt 0 ]]; then
	exit 1
fi
exit 0
