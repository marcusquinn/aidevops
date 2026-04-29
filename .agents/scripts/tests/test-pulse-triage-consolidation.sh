#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-triage-consolidation.sh — regression tests for t3050
#
# Covers _consolidation_skip_if_resolved: the pre-flight gate that aborts
# _dispatch_issue_consolidation when a parent issue's work is already resolved.
#
# Three abort conditions:
#   1. dispatch-blocked:committed-to-main label on parent
#   2. Parent CLOSED with stateReason=NOT_PLANNED
#   3. ≥80% of child issue/PR refs in parent body are merged PRs
#
# Plus the happy path: no resolved condition → function returns 1 (proceed).
#
# Test strategy:
#   1. Stub `gh` as a bash function that returns controlled JSON based on
#      the arguments passed (issue view or api pulls/{num}).
#   2. Stub `_gh_idempotent_comment` to record whether it was called.
#   3. Export LOGFILE to a temp file so log assertions are possible.
#   4. Source pulse-triage-dispatch.sh (which has no source-time side effects
#      beyond defining functions).
#   5. Run each test, assert return codes and side-effects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
LOGFILE=""

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# ---------------------------------------------------------------------------
# File-based idempotent-comment call counter
# (stub called in subshells — use file to communicate back to parent)
# ---------------------------------------------------------------------------
_IDEMPOTENT_CALL_FILE=""

_init_idempotent_counter() {
	_IDEMPOTENT_CALL_FILE="${TEST_ROOT}/idempotent-calls.txt"
	echo "0" >"$_IDEMPOTENT_CALL_FILE"
	return 0
}

_read_idempotent_count() {
	cat "$_IDEMPOTENT_CALL_FILE" 2>/dev/null || echo "0"
	return 0
}

# ---------------------------------------------------------------------------
# Shared stubs (re-declared after source to override any module-level defs)
# ---------------------------------------------------------------------------

# _STUB_GH_STATE, _STUB_GH_STATE_REASON, _STUB_GH_LABELS, _STUB_GH_BODY,
# _STUB_PR_REFS_MERGED: controlled by each test before running the gate.

gh() {
	local subcmd="${1:-}"
	shift || true

	# Handle: gh issue view NUM --repo SLUG --json state,stateReason,labels,body
	if [[ "$subcmd" == "issue" ]]; then
		local state="${_STUB_GH_STATE:-OPEN}"
		local state_reason="${_STUB_GH_STATE_REASON:-}"
		local labels_json="${_STUB_GH_LABELS_JSON:-[]}"
		local body="${_STUB_GH_BODY:-}"
		printf '{"state":"%s","stateReason":"%s","labels":%s,"body":"%s"}\n' \
			"$state" "$state_reason" "$labels_json" "$body"
		return 0
	fi

	# Handle: gh api repos/SLUG/pulls/NUM --jq '.merged_at // ""'
	if [[ "$subcmd" == "api" ]]; then
		# Parse the path arg to extract the PR number
		local api_path="${1:-}"
		local pr_num
		pr_num=$(printf '%s' "$api_path" | grep -oE '[0-9]+$') || pr_num=""
		# _STUB_PR_REFS_MERGED is a comma-separated list of merged PR numbers
		local merged_list="${_STUB_PR_REFS_MERGED:-}"
		if [[ -n "$pr_num" ]] && printf ',%s,' "$merged_list" \
			| grep -qF ",${pr_num},"; then
			# This PR number is in the merged list — return a timestamp
			printf '2026-04-27T10:00:00Z\n'
		else
			# Not merged (or not a PR) — return empty
			printf '\n'
		fi
		return 0
	fi

	return 0
}

_gh_idempotent_comment() {
	# Record the call
	local c; c=$(cat "$_IDEMPOTENT_CALL_FILE" 2>/dev/null || echo 0)
	[[ "$c" =~ ^[0-9]+$ ]] || c=0
	echo "$((c + 1))" >"$_IDEMPOTENT_CALL_FILE"
	return 0
}

# ---------------------------------------------------------------------------
# Environment setup / teardown
# ---------------------------------------------------------------------------

setup_test_env() {
	TEST_ROOT=$(mktemp -d -t t3050-consolidation.XXXXXX)
	LOGFILE="${TEST_ROOT}/pulse.log"
	export LOGFILE
	: >"$LOGFILE"

	_init_idempotent_counter

	# Prevent loading the dispatch sub-library's include guard from blocking.
	unset _PULSE_TRIAGE_DISPATCH_LIB_LOADED

	# Provide minimal stubs BEFORE sourcing so the module loads cleanly.
	# shellcheck disable=SC2034
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	printf '{"initialized_repos":[]}\n' >"$REPOS_JSON"
	export CONSOLIDATION_LOCK_TTL_HOURS=6
	export CONSOLIDATION_LOCK_TIEBREAK_WAIT_SEC=2

	# Load the module under test.
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/.agents/scripts/pulse-triage-dispatch.sh" || {
		printf 'ERROR: failed to source pulse-triage-dispatch.sh\n' >&2
		return 1
	}

	# Re-declare stubs AFTER source so our versions win over any in the module.
	# (The module defines no `gh` or `_gh_idempotent_comment`, but guard anyway.)
	_init_idempotent_counter

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	LOGFILE=""
	_IDEMPOTENT_CALL_FILE=""
	unset _PULSE_TRIAGE_DISPATCH_LIB_LOADED
	unset _STUB_GH_STATE _STUB_GH_STATE_REASON _STUB_GH_LABELS_JSON
	unset _STUB_GH_BODY _STUB_PR_REFS_MERGED
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: Gate 1 — dispatch-blocked:committed-to-main label → skip
# ---------------------------------------------------------------------------

test_gate1_committed_to_main_label() {
	setup_test_env

	_STUB_GH_STATE="OPEN"
	_STUB_GH_STATE_REASON=""
	_STUB_GH_LABELS_JSON='[{"name":"dispatch-blocked:committed-to-main"},{"name":"auto-dispatch"}]'
	_STUB_GH_BODY="Some issue body with no child refs"
	_STUB_PR_REFS_MERGED=""

	local rc=0
	_consolidation_skip_if_resolved "12345" "owner/repo" || rc=$?

	local calls; calls=$(_read_idempotent_count)
	local failures=0 failmsg=""

	# Must return 0 (skip)
	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected rc=0 (skip), got rc=${rc}"
	fi

	# Must have posted the idempotent comment
	if [[ "$calls" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected 1 idempotent comment call, got ${calls}"
	fi

	# Log must mention the gate
	if ! grep -qF "dispatch-blocked:committed-to-main" "$LOGFILE"; then
		failures=$((failures + 1))
		failmsg="${failmsg} | log missing 'dispatch-blocked:committed-to-main'"
	fi

	print_result "gate1: committed-to-main label → skip" "$failures" "$failmsg"
	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: Gate 2 — CLOSED + NOT_PLANNED → skip
# ---------------------------------------------------------------------------

test_gate2_closed_not_planned() {
	setup_test_env

	_STUB_GH_STATE="CLOSED"
	_STUB_GH_STATE_REASON="NOT_PLANNED"
	_STUB_GH_LABELS_JSON='[{"name":"needs-consolidation"}]'
	_STUB_GH_BODY="Issue body without child refs"
	_STUB_PR_REFS_MERGED=""

	local rc=0
	_consolidation_skip_if_resolved "21055" "owner/repo" || rc=$?

	local calls; calls=$(_read_idempotent_count)
	local failures=0 failmsg=""

	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected rc=0 (skip), got rc=${rc}"
	fi

	if [[ "$calls" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected 1 idempotent comment call, got ${calls}"
	fi

	if ! grep -qF "CLOSED/NOT_PLANNED" "$LOGFILE"; then
		failures=$((failures + 1))
		failmsg="${failmsg} | log missing 'CLOSED/NOT_PLANNED'"
	fi

	print_result "gate2: CLOSED+NOT_PLANNED → skip" "$failures" "$failmsg"
	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: Gate 3 — ≥80% of body child refs are merged PRs → skip
# ---------------------------------------------------------------------------

test_gate3_children_merged() {
	setup_test_env

	_STUB_GH_STATE="OPEN"
	_STUB_GH_STATE_REASON=""
	_STUB_GH_LABELS_JSON='[{"name":"needs-consolidation"}]'
	# Body references #100, #200, #300 — all three are merged PRs (100%)
	_STUB_GH_BODY="Children: #100 (t2974) and #200 (t2976) and #300 (t2977)"
	_STUB_PR_REFS_MERGED="100,200,300"

	local rc=0
	_consolidation_skip_if_resolved "99999" "owner/repo" || rc=$?

	local calls; calls=$(_read_idempotent_count)
	local failures=0 failmsg=""

	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected rc=0 (skip), got rc=${rc}"
	fi

	if [[ "$calls" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected 1 idempotent comment call, got ${calls}"
	fi

	if ! grep -qF "child PRs merged" "$LOGFILE"; then
		failures=$((failures + 1))
		failmsg="${failmsg} | log missing 'child PRs merged'"
	fi

	print_result "gate3: all child refs merged (100%) → skip" "$failures" "$failmsg"
	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: Gate 3 — exactly 80% merged → skip (boundary condition)
# ---------------------------------------------------------------------------

test_gate3_exactly_80pct_merged() {
	setup_test_env

	_STUB_GH_STATE="OPEN"
	_STUB_GH_STATE_REASON=""
	_STUB_GH_LABELS_JSON='[{"name":"needs-consolidation"}]'
	# Body references #100, #200, #300, #400, #500 — 4 of 5 merged = 80%
	_STUB_GH_BODY="Children: #100 #200 #300 #400 #500"
	_STUB_PR_REFS_MERGED="100,200,300,400"

	local rc=0
	_consolidation_skip_if_resolved "77777" "owner/repo" || rc=$?

	local calls; calls=$(_read_idempotent_count)
	local failures=0 failmsg=""

	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected rc=0 (skip at 80%), got rc=${rc}"
	fi

	if [[ "$calls" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected 1 idempotent comment call, got ${calls}"
	fi

	print_result "gate3: exactly 80% child refs merged → skip" "$failures" "$failmsg"
	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Gate 3 — below 80% merged → proceed (do NOT skip)
# ---------------------------------------------------------------------------

test_gate3_below_threshold_proceeds() {
	setup_test_env

	_STUB_GH_STATE="OPEN"
	_STUB_GH_STATE_REASON=""
	_STUB_GH_LABELS_JSON='[{"name":"needs-consolidation"}]'
	# Body references #100, #200, #300 — only 2 of 3 merged = 66%
	_STUB_GH_BODY="Related: #100 #200 #300"
	_STUB_PR_REFS_MERGED="100,200"

	local rc=0
	_consolidation_skip_if_resolved "55555" "owner/repo" || rc=$?

	local calls; calls=$(_read_idempotent_count)
	local failures=0 failmsg=""

	# Must return 1 (proceed)
	if [[ "$rc" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected rc=1 (proceed), got rc=${rc}"
	fi

	# Must NOT have posted a skip comment
	if [[ "$calls" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected 0 idempotent comment calls, got ${calls}"
	fi

	print_result "gate3: 66% merged (below 80%) → proceed" "$failures" "$failmsg"
	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: Happy path — no resolved conditions → proceed
# ---------------------------------------------------------------------------

test_happy_path_proceeds() {
	setup_test_env

	_STUB_GH_STATE="OPEN"
	_STUB_GH_STATE_REASON=""
	_STUB_GH_LABELS_JSON='[{"name":"needs-consolidation"},{"name":"auto-dispatch"}]'
	_STUB_GH_BODY="This issue needs consolidation. It has many comments but no child refs."
	_STUB_PR_REFS_MERGED=""

	local rc=0
	_consolidation_skip_if_resolved "11111" "owner/repo" || rc=$?

	local calls; calls=$(_read_idempotent_count)
	local failures=0 failmsg=""

	# Must return 1 (proceed — normal dispatch flow continues)
	if [[ "$rc" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected rc=1 (proceed), got rc=${rc}"
	fi

	if [[ "$calls" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected 0 idempotent comment calls, got ${calls}"
	fi

	print_result "happy path: no resolved conditions → proceed" "$failures" "$failmsg"
	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: Gate 3 — body has no child refs → proceed (no API spam)
# ---------------------------------------------------------------------------

test_gate3_no_refs_in_body() {
	setup_test_env

	_STUB_GH_STATE="OPEN"
	_STUB_GH_STATE_REASON=""
	_STUB_GH_LABELS_JSON='[{"name":"needs-consolidation"}]'
	_STUB_GH_BODY="This issue body has no hash refs at all."
	_STUB_PR_REFS_MERGED=""

	local rc=0
	_consolidation_skip_if_resolved "22222" "owner/repo" || rc=$?

	local calls; calls=$(_read_idempotent_count)
	local failures=0 failmsg=""

	if [[ "$rc" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected rc=1 (proceed), got rc=${rc}"
	fi

	if [[ "$calls" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected 0 idempotent comment calls (no refs), got ${calls}"
	fi

	print_result "gate3: no refs in body → proceed without API calls" "$failures" "$failmsg"
	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: Gate 2 — CLOSED with COMPLETED (not NOT_PLANNED) → proceed
# ---------------------------------------------------------------------------

test_gate2_closed_completed_proceeds() {
	setup_test_env

	_STUB_GH_STATE="CLOSED"
	_STUB_GH_STATE_REASON="COMPLETED"
	_STUB_GH_LABELS_JSON='[{"name":"needs-consolidation"}]'
	_STUB_GH_BODY="Issue closed as completed (work done)."
	_STUB_PR_REFS_MERGED=""

	local rc=0
	_consolidation_skip_if_resolved "33333" "owner/repo" || rc=$?

	local calls; calls=$(_read_idempotent_count)
	local failures=0 failmsg=""

	# CLOSED+COMPLETED should NOT trigger Gate 2 — only NOT_PLANNED skips.
	# Gate 3 has no refs → proceeds.
	if [[ "$rc" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected rc=1 (proceed — COMPLETED not NOT_PLANNED), got rc=${rc}"
	fi

	if [[ "$calls" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected 0 comment calls, got ${calls}"
	fi

	print_result "gate2: CLOSED+COMPLETED (not NOT_PLANNED) → proceed" "$failures" "$failmsg"
	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: Gate 3 — self-ref excluded (parent body references itself)
# ---------------------------------------------------------------------------

test_gate3_self_ref_excluded() {
	setup_test_env

	_STUB_GH_STATE="OPEN"
	_STUB_GH_STATE_REASON=""
	_STUB_GH_LABELS_JSON='[{"name":"needs-consolidation"}]'
	# Body self-references #44444 (the parent) — must be excluded.
	# Only #100 is a non-self ref, and it IS a merged PR → 1/1 = 100%.
	_STUB_GH_BODY="Tracked in #44444. Implemented in #100."
	_STUB_PR_REFS_MERGED="100,44444"

	local rc=0
	_consolidation_skip_if_resolved "44444" "owner/repo" || rc=$?

	local calls; calls=$(_read_idempotent_count)
	local failures=0 failmsg=""

	# #44444 is excluded as self-ref. #100 is merged → 1/1 = 100% → skip.
	if [[ "$rc" -ne 0 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected rc=0 (skip — #100 merged, self-ref excluded), got rc=${rc}"
	fi

	if [[ "$calls" -ne 1 ]]; then
		failures=$((failures + 1))
		failmsg="${failmsg} | expected 1 comment call, got ${calls}"
	fi

	print_result "gate3: self-ref excluded from child scan" "$failures" "$failmsg"
	teardown_test_env
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	printf 'Running t3050 consolidation pre-flight gate tests\n\n'

	test_gate1_committed_to_main_label
	test_gate2_closed_not_planned
	test_gate3_children_merged
	test_gate3_exactly_80pct_merged
	test_gate3_below_threshold_proceeds
	test_happy_path_proceeds
	test_gate3_no_refs_in_body
	test_gate2_closed_completed_proceeds
	test_gate3_self_ref_excluded

	printf '\n%d/%d tests passed\n' \
		"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		printf '%bFAILED: %d test(s) failed%b\n' \
			"$TEST_RED" "$TESTS_FAILED" "$TEST_RESET"
		return 1
	fi

	printf '%bAll tests passed%b\n' "$TEST_GREEN" "$TEST_RESET"
	return 0
}

main "$@"
