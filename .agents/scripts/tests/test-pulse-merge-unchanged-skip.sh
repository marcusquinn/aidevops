#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-unchanged-skip.sh — GH#33569 regression guard.
#
# Verifies the in-cycle merge pass skips enrichment and per-PR evaluation only
# for an unchanged PR set that recently evaluated to a no-op, and evaluates in
# full after any list change, progress, age expiry, due retry or paused cursor.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected: %s\n' "$expected"
		printf '  actual:   %s\n' "$actual"
	fi
	return 0
}

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
TMPDIR_TEST=$(mktemp -d "${TMPDIR:-/tmp}/pulse-merge-unchanged-skip-XXXXXX") || exit 1
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export HOME="$TMPDIR_TEST/home"
mkdir -p "$HOME/.aidevops/logs" || exit 1
export LOGFILE="$HOME/.aidevops/logs/pulse.log"
export STOP_FLAG="$HOME/.aidevops/logs/pulse-session.stop"
export PULSE_MERGE_CHECKPOINT_FILE="$HOME/.aidevops/logs/pulse-merge-checkpoint"
export PULSE_MERGE_PR_CURSOR_FILE="$HOME/.aidevops/logs/pulse-merge-pr-cursor"
export PULSE_MERGE_ENRICHMENT_CACHE_FILE="$HOME/.aidevops/logs/pulse-merge-enrichment-cache"
export PULSE_MERGE_ENRICHMENT_CURSOR_FILE="$HOME/.aidevops/logs/pulse-merge-enrichment-cursor"
export PULSE_MERGE_UNCHANGED_STATE_DIR="$HOME/.aidevops/logs/pulse-merge-unchanged"
export PULSE_MERGE_BATCH_LIMIT=10

# shellcheck disable=SC1090,SC1091
source "${SCRIPTS_DIR}/pulse-merge-process.sh"
set +e
set +o pipefail 2>/dev/null || true

FAKE_NOW=1000
PROCESSED_PRS=""
PR_RESULT=4
HEAD_102="sha102"
DEFERRED_RETRY=false

_pmp_now_epoch() {
	printf '%s' "$FAKE_NOW"
	return 0
}

pulse_pr_list_get() {
	jq -cn --arg head "$HEAD_102" --argjson retry "$DEFERRED_RETRY" '[
		{number:101,state:"OPEN",isDraft:false,labels:[{name:"origin:worker"}],headRefOid:"sha101",baseRefName:"main",updatedAt:"2026-10-04T10:00:00Z"},
		{number:102,state:"OPEN",isDraft:false,labels:[],headRefOid:$head,baseRefName:"main",updatedAt:"2026-10-04T10:00:00Z"}
	] | if $retry then .[0] += {_pulseDeferredRetry:true} else . end'
	return 0
}

_pulse_merge_ready_pr_json_fields() {
	printf '%s' 'number,state,author,title,isDraft,labels,updatedAt,headRefOid,headRefName,baseRefName,createdAt'
	return 0
}

_pmp_include_queued_pr_targets_or_fallback() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	printf '%s' "$pr_json"
	return 0
}

_pmp_prepare_enriched_pr_backlog_timed() {
	local repo_slug="$1"
	local backlog_json="$2"
	local out_var="$3"
	[[ -n "$repo_slug" ]] || return 1
	printf -v "$out_var" '%s' "$backlog_json"
	return 0
}

ENRICH_FAILS=0
_pmp_enrich_single_pr_for_processing() {
	local repo_slug="$1"
	local pr_obj="$2"
	[[ -n "$repo_slug" && "$ENRICH_FAILS" -eq 0 ]] || return 1
	printf '%s' "$pr_obj"
	return 0
}

_pmp_log_pr_backlog_counts() { return 0; }
_pmp_consolidate_duplicate_pr_groups() { return 0; }
_pmp_sort_prs_by_backlog_priority() {
	local pr_json="$1"
	printf '%s' "$pr_json"
	return 0
}

_process_single_ready_pr() {
	local repo_slug="$1"
	local pr_obj="$2"
	local pr_number=""
	[[ -n "$repo_slug" ]] || return 1
	pr_number=$(printf '%s' "$pr_obj" | jq -r '.number // empty') || pr_number=""
	PROCESSED_PRS="${PROCESSED_PRS}${pr_number} "
	return "$PR_RESULT"
}

run_pass() {
	local merged=0 closed=0 failed=0 pr_count=0
	PROCESSED_PRS=""
	_PMP_MERGE_PASS_DEADLINE_EPOCH=0
	_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || return 1
	return 0
}

state_streak() {
	local state_file="${PULSE_MERGE_UNCHANGED_STATE_DIR}/org--repo"
	local fingerprint="" streak="" last_full=""
	[[ -f "$state_file" ]] || { printf 'none'; return 0; }
	IFS=$'\t' read -r fingerprint streak last_full <"$state_file"
	: "$fingerprint" "$last_full"
	printf '%s' "$streak"
	return 0
}

printf '=== GH#33569: unchanged no-op merge evaluation skip ===\n'

# The standalone routine (no opt-in) always evaluates and records the streak.
export PULSE_MERGE_UNCHANGED_SKIP=0
run_pass
assert_eq "non-opted pass evaluates every PR" "101 102 " "$PROCESSED_PRS"
assert_eq "first no-op evaluation starts the streak" "1" "$(state_streak)"
FAKE_NOW=1100
run_pass
assert_eq "non-opted pass never skips" "101 102 " "$PROCESSED_PRS"
assert_eq "unchanged no-op evaluation extends the streak" "2" "$(state_streak)"

# The in-cycle pass skips the unchanged no-op set.
export PULSE_MERGE_UNCHANGED_SKIP=1
FAKE_NOW=1200
run_pass
assert_eq "opted-in pass skips an unchanged no-op PR set" "" "$PROCESSED_PRS"
assert_eq "skip decision is logged" "1" "$(grep -c 'PR set unchanged after 2 no-op evaluations' "$LOGFILE")"
assert_eq "skipped pass leaves the evaluated streak intact" "2" "$(state_streak)"

# Age bound: a stale full evaluation forces a fresh one.
FAKE_NOW=$((1100 + 1800))
run_pass
assert_eq "expired full evaluation is redone" "101 102 " "$PROCESSED_PRS"

# A due exact retry target is never skipped and resets the streak.
DEFERRED_RETRY=true
FAKE_NOW=3000
run_pass
assert_eq "due retry target forces evaluation" "101 102 " "$PROCESSED_PRS"
assert_eq "due retry target clears the streak" "none" "$(state_streak)"
DEFERRED_RETRY=false

# Rebuild the streak, then change one head SHA: the set is evaluated again.
run_pass
FAKE_NOW=3010
run_pass
FAKE_NOW=3020
run_pass
assert_eq "rebuilt streak skips again" "" "$PROCESSED_PRS"
HEAD_102="sha102-new"
run_pass
assert_eq "changed head SHA forces evaluation" "101 102 " "$PROCESSED_PRS"
assert_eq "changed PR set restarts the streak" "1" "$(state_streak)"

# A paused cursor for this repo resumes instead of skipping.
FAKE_NOW=3030
run_pass
printf '%s\n' 'org/repo|1|101|102' >"$PULSE_MERGE_PR_CURSOR_FILE"
FAKE_NOW=3040
run_pass
assert_eq "paused cursor resumes rather than skipping" "102 " "$PROCESSED_PRS"
assert_eq "cursor-resumed partial evaluation does not record evidence" "none" "$(state_streak)"

# Progress (a merge) clears the evidence so the next pass evaluates.
run_pass
FAKE_NOW=3050
run_pass
PR_RESULT=0
FAKE_NOW=3060
PULSE_MERGE_UNCHANGED_SKIP=0 run_pass
assert_eq "merge progress clears the streak" "none" "$(state_streak)"
PR_RESULT=4
FAKE_NOW=3070
run_pass
assert_eq "pass after progress evaluates in full" "101 102 " "$PROCESSED_PRS"

# Fail-closed enrichment is not authoritative no-op evidence.
ENRICH_FAILS=1
FAKE_NOW=3080
run_pass
assert_eq "degraded enrichment clears the streak" "none" "$(state_streak)"
ENRICH_FAILS=0

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\n%sAll %d unchanged-skip tests passed.%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
fi
printf '\n%s%d/%d unchanged-skip tests failed.%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
exit 1
