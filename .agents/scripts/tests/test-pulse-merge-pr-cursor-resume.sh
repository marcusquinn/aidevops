#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-pr-cursor-resume.sh — GH#26708/GH#29456 regression guard.
#
# Verifies a long single-repo merge backlog can pause before the outer hard
# timeout, persist an in-repo PR cursor, and resume at the tail PRs next pass.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
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
PROCESS_FILE="${SCRIPTS_DIR}/pulse-merge-process.sh"
TMPDIR_TEST=$(mktemp -d "${TMPDIR:-/tmp}/pulse-merge-pr-cursor-test-XXXXXX") || exit 1
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export HOME="$TMPDIR_TEST/home"
mkdir -p "$HOME/.aidevops/logs" || exit 1
export LOGFILE="$HOME/.aidevops/logs/pulse.log"
export STOP_FLAG="$HOME/.aidevops/logs/pulse-session.stop"
export PULSE_MERGE_CHECKPOINT_FILE="$HOME/.aidevops/logs/pulse-merge-checkpoint"
export PULSE_MERGE_PR_CURSOR_FILE="$HOME/.aidevops/logs/pulse-merge-pr-cursor"
export PULSE_MERGE_ENRICHMENT_CACHE_FILE="$HOME/.aidevops/logs/pulse-merge-enrichment-cache"
export PULSE_MERGE_ENRICHMENT_CURSOR_FILE="$HOME/.aidevops/logs/pulse-merge-enrichment-cursor"
export PULSE_MERGE_BATCH_LIMIT=10

# shellcheck disable=SC1090
source "$PROCESS_FILE"
set +e
set +o pipefail 2>/dev/null || true

FAKE_NOW=100
PROCESSED_PRS=""
PR102_CHECK_STATE="FAILURE"
ENRICH_TRIGGER_PHASE=""
REST_BLOCK_AFTER_PHASE=""
ENRICH_PHASE_LOG="${TMPDIR_TEST}/enrichment-phases.log"
ENRICH_PHASE_STATE="${TMPDIR_TEST}/enrichment-phase.state"

_pmp_now_epoch() {
	local current_phase=""
	if [[ -f "$ENRICH_PHASE_STATE" ]]; then
		current_phase=$(<"$ENRICH_PHASE_STATE")
	fi
	if [[ -n "$ENRICH_TRIGGER_PHASE" && "$current_phase" == "$ENRICH_TRIGGER_PHASE" ]]; then
		printf '200'
		return 0
	fi
	printf '%s' "$FAKE_NOW"
	return 0
}

pulse_pr_list_get() {
	printf '%s\n' '[{"number":101,"state":"OPEN","title":"pending","isDraft":false,"labels":[],"headRefOid":"sha101"},{"number":102,"state":"OPEN","title":"failing","isDraft":false,"labels":[],"headRefOid":"sha102"},{"number":103,"state":"OPEN","title":"ready","isDraft":false,"labels":[],"headRefOid":"sha103"},{"number":104,"state":"OPEN","title":"blocked","isDraft":false,"labels":[],"headRefOid":"sha104"}]'
	return 0
}

_pulse_merge_ready_pr_json_fields() {
	printf '%s' 'number,state,author,title,isDraft,labels,updatedAt,headRefOid,headRefName,baseRefName,createdAt'
	return 0
}

record_enrichment_phase() {
	local phase="$1"
	printf '%s ' "$phase" >>"$ENRICH_PHASE_LOG"
	printf '%s' "$phase" >"$ENRICH_PHASE_STATE"
	return 0
}

pulse_rest_core_priority_allows_next() {
	local priority="$1"
	local context="$2"
	local current_phase=""
	[[ "$priority" == "progress" || "$priority" == "deferrable" ]] || return 0
	if [[ -f "$ENRICH_PHASE_STATE" ]]; then
		current_phase=$(<"$ENRICH_PHASE_STATE")
	fi
	if [[ -n "$REST_BLOCK_AFTER_PHASE" && "$current_phase" == "$REST_BLOCK_AFTER_PHASE" && "$context" == merge_enrichment_* ]]; then
		return 1
	fi
	return 0
}

require_single_pr_enrichment_input() {
	local pr_json="$1"
	local pr_count=""
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || return 1
	[[ "$pr_count" -eq 1 ]] || return 1
	return 0
}

_pmp_enrich_prs_with_mergeability() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	require_single_pr_enrichment_input "$pr_json" || return 1
	record_enrichment_phase mergeability
	printf '%s' "$pr_json" | jq -c 'map(. + {mergeable:(if .number == 104 then "CONFLICTING" else "MERGEABLE" end)})'
	return 0
}

_pmp_enrich_prs_with_rest_check_status() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	require_single_pr_enrichment_input "$pr_json" || return 1
	record_enrichment_phase checks
	printf '%s' "$pr_json" | jq -c --arg c102 "$PR102_CHECK_STATE" 'map(. + {statusCheckRollup:(if .number == 101 then [{status:"IN_PROGRESS",conclusion:null,state:"PENDING"}] elif .number == 102 then [{status:"COMPLETED",conclusion:$c102,state:$c102}] else [{status:"COMPLETED",conclusion:"SUCCESS",state:"SUCCESS"}] end)})'
	return 0
}

_pmp_enrich_prs_with_review_decisions() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	require_single_pr_enrichment_input "$pr_json" || return 1
	record_enrichment_phase reviews
	printf '%s' "$pr_json" | jq -c 'map(. + {reviewDecision:(if .number == 104 then "CHANGES_REQUESTED" else "APPROVED" end)})'
	return 0
}

_pmp_log_pr_backlog_counts() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug$pr_json" ]] || return 1
	return 0
}

_pmp_consolidate_duplicate_pr_groups() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug$pr_json" ]] || return 1
	return 0
}

_process_single_ready_pr() {
	local repo_slug="$1"
	local pr_obj="$2"
	local timing_prefix="${3:-}"
	local pr_number=""
	[[ -n "$repo_slug$timing_prefix" ]] || return 1
	pr_number=$(printf '%s' "$pr_obj" | jq -r '.number // empty') || pr_number=""
	PROCESSED_PRS="${PROCESSED_PRS}${pr_number} "
	FAKE_NOW=$((FAKE_NOW + 1))
	return 4
}

printf '%s=== GH#26708/GH#29456: pulse merge PR cursor resume tests ===%s\n' "$TEST_BLUE" "$TEST_NC"

merged=0 closed=0 failed=0 pr_count=0
export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=2
_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || first_rc=$?
assert_eq "first pass pauses when graceful budget is exhausted" "5" "${first_rc:-0}"
# GH#39281: the failing PR has no CI-repair lease, so the CI-repair lane runs
# it ahead of merge-ready work.
assert_eq "production-shaped backlog runs the CI-repair lane, then ready PRs" "102 103 " "$PROCESSED_PRS"
assert_eq "cursor records next sorted tail PR" "org/repo|2|103|101" "$(tr -d '\n' <"$PULSE_MERGE_PR_CURSOR_FILE")"

# Losing advisory enrichment state must rebuild safely, then resume the
# authoritative processing cursor rather than repeating completed PRs.
rm -f "$PULSE_MERGE_ENRICHMENT_CACHE_FILE"

PROCESSED_PRS=""
FAKE_NOW=200
export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=0
_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || second_rc=$?
assert_eq "second pass completes normally" "0" "${second_rc:-0}"
assert_eq "second pass resumes at saved sorted tail PR after cache loss" "101 104 " "$PROCESSED_PRS"
if [[ ! -f "$PULSE_MERGE_PR_CURSOR_FILE" ]]; then
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%sPASS%s: cursor clears after repo completes\n' "$TEST_GREEN" "$TEST_NC"
else
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s: cursor clears after repo completes\n' "$TEST_RED" "$TEST_NC"
fi

# GH#38248: a PR the paused walk passed while failing becomes merge-ready at
# the same head. The advisory cache still holds the failing state, so the
# resumed walk refreshes the passed-over PR, evaluates it ahead of the tail
# instead of after the walk wraps, and never repeats PRs already evaluated
# merge-ready.
rm -f "$PULSE_MERGE_ENRICHMENT_CACHE_FILE" "$PULSE_MERGE_ENRICHMENT_CURSOR_FILE"
PROCESSED_PRS=""
FAKE_NOW=100
export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=2
_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
lane_first_rc=0
_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || lane_first_rc=$?
assert_eq "lane setup pauses after the failing and ready PRs" "5|102 103 " "${lane_first_rc}|${PROCESSED_PRS}"
assert_eq "lane setup retains the stale advisory failure for PR 102" "FAILURE" "$(jq -r '.prs[] | select(.number == 102) | .statusCheckRollup[0].conclusion' "$PULSE_MERGE_ENRICHMENT_CACHE_FILE")"
PR102_CHECK_STATE="SUCCESS"
PROCESSED_PRS=""
FAKE_NOW=200
export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=0
_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
lane_second_rc=0
_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || lane_second_rc=$?
# GH#39281: the resume item runs first, then the lane item, then the tail.
assert_eq "resume lane evaluates the resume item, then the newly ready PR, before the tail" "0|101 102 104 " "${lane_second_rc}|${PROCESSED_PRS}"
assert_eq "resume lane is logged" "1" "$(grep -c 'resume priority lane for org/repo moved 1 ' "$LOGFILE")"
assert_eq "completed walk clears the lane records" "false" "$([[ -f "${PULSE_MERGE_PR_CURSOR_FILE}.lane-served" || -f "${PULSE_MERGE_PR_CURSOR_FILE}.lane-refreshed" || -f "${PULSE_MERGE_PR_CURSOR_FILE}.lane-ci-served" ]] && printf true || printf false)"

# GH#39281: a PR that starts failing after the walk passed it joins the
# CI-repair lane on the next resume and runs right after the resume item.
rm -f "$PULSE_MERGE_ENRICHMENT_CACHE_FILE" "$PULSE_MERGE_ENRICHMENT_CURSOR_FILE"
PROCESSED_PRS=""
FAKE_NOW=100
export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=2
_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
ci_first_rc=0
_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || ci_first_rc=$?
assert_eq "CI lane setup evaluates both ready PRs, then pauses" "5|102 103 " "${ci_first_rc}|${PROCESSED_PRS}"
PR102_CHECK_STATE="FAILURE"
rm -f "$PULSE_MERGE_ENRICHMENT_CACHE_FILE" "$PULSE_MERGE_ENRICHMENT_CURSOR_FILE"
: >"$LOGFILE"
PROCESSED_PRS=""
FAKE_NOW=200
export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=0
_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
ci_second_rc=0
_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || ci_second_rc=$?
assert_eq "resume evaluates the resume item, then the newly failing PR, before the tail" "0|101 102 104 " "${ci_second_rc}|${PROCESSED_PRS}"
assert_eq "resume CI-repair lane is logged" "1" "$(grep -c 'moved 0 merge-ready PR(s) and 1 CI-repair PR(s) behind resume item index=2 next_pr=101' "$LOGFILE")"

assert_budget_pause_after_phase() {
	local phase="$1"
	local expected_phases="$2"
	local pass_rc=0
	PROCESSED_PRS=""
	ENRICH_TRIGGER_PHASE="$phase"
	FAKE_NOW=100
	rm -f "$ENRICH_PHASE_LOG" "$ENRICH_PHASE_STATE" "$PULSE_MERGE_PR_CURSOR_FILE" "$PULSE_MERGE_ENRICHMENT_CACHE_FILE" "$PULSE_MERGE_ENRICHMENT_CURSOR_FILE"
	_PMP_MERGE_PASS_DEADLINE_EPOCH=200
	_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || pass_rc=$?
	assert_eq "budget pause after ${phase} enrichment returns resumable status" "5" "$pass_rc"
	assert_eq "budget pause after ${phase} enrichment processes no incomplete PR" "" "$PROCESSED_PRS"
	assert_eq "budget pause after ${phase} enrichment persists the current PR" "org/repo|0||101" "$(tr -d '\n' <"$PULSE_MERGE_ENRICHMENT_CURSOR_FILE")"
	assert_eq "budget pause stops after ${phase} enrichment" "$expected_phases" "$(<"$ENRICH_PHASE_LOG")"
	return 0
}

assert_budget_pause_after_phase mergeability "mergeability "
assert_budget_pause_after_phase checks "mergeability checks "
assert_budget_pause_after_phase reviews "mergeability checks reviews "

assert_rest_pause_after_phase() {
	local phase="$1"
	local expected_phases="$2"
	local pass_rc=0
	PROCESSED_PRS=""
	ENRICH_TRIGGER_PHASE=""
	REST_BLOCK_AFTER_PHASE="$phase"
	FAKE_NOW=100
	rm -f "$ENRICH_PHASE_LOG" "$ENRICH_PHASE_STATE" "$PULSE_MERGE_PR_CURSOR_FILE" "$PULSE_MERGE_ENRICHMENT_CACHE_FILE" "$PULSE_MERGE_ENRICHMENT_CURSOR_FILE"
	_PMP_MERGE_PASS_DEADLINE_EPOCH=0
	_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || pass_rc=$?
	assert_eq "REST pause after ${phase} enrichment returns resumable status" "5" "$pass_rc"
	assert_eq "REST pause after ${phase} enrichment processes no incomplete PR" "" "$PROCESSED_PRS"
	assert_eq "REST pause after ${phase} enrichment persists the current PR" "org/repo|0||101" "$(tr -d '\n' <"$PULSE_MERGE_ENRICHMENT_CURSOR_FILE")"
	assert_eq "REST pause stops after ${phase} enrichment" "$expected_phases" "$(<"$ENRICH_PHASE_LOG")"
	return 0
}

assert_rest_pause_after_phase mergeability "mergeability "
assert_rest_pause_after_phase checks "mergeability checks "
assert_rest_pause_after_phase reviews "mergeability checks reviews "
REST_BLOCK_AFTER_PHASE=""

# The next cycle starts from the durable current-PR cursor and re-enriches from
# the fresh list response. No partial enrichment cache is required for progress.
PROCESSED_PRS=""
ENRICH_TRIGGER_PHASE=""
FAKE_NOW=300
rm -f "$ENRICH_PHASE_LOG" "$ENRICH_PHASE_STATE"
rm -f "$PULSE_MERGE_ENRICHMENT_CACHE_FILE"
_PMP_MERGE_PASS_DEADLINE_EPOCH=0
resume_after_enrichment_rc=0
_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || resume_after_enrichment_rc=$?
assert_eq "cycle after enrichment pause completes without cached partial JSON" "0" "$resume_after_enrichment_rc"
assert_eq "cycle after enrichment pause makes forward progress in backlog priority order" "102 103 101 104 " "$PROCESSED_PRS"
assert_eq "successful resumed cycle clears the current-PR cursor" "false" "$([[ -f "$PULSE_MERGE_PR_CURSOR_FILE" ]] && printf true || printf false)"
assert_eq "successful resumed cycle clears enrichment state" "false" "$([[ -f "$PULSE_MERGE_ENRICHMENT_CACHE_FILE" || -f "$PULSE_MERGE_ENRICHMENT_CURSOR_FILE" ]] && printf true || printf false)"

# Cached scheduling fields are advisory. Authoritative per-item processing must
# remove them before calling enrichers that refresh only missing values.
_pmp_enrich_prs_with_mergeability() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	printf '%s' "$pr_json" | jq -c 'map(if has("mergeable") then . else . + {mergeable:"MERGEABLE"} end)'
	return 0
}
_pmp_enrich_prs_with_rest_check_status() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	printf '%s' "$pr_json" | jq -c 'map(if has("statusCheckRollup") then . else . + {statusCheckRollup:[{status:"COMPLETED",conclusion:"SUCCESS",state:"SUCCESS"}]} end)'
	return 0
}
_pmp_enrich_prs_with_review_decisions() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	printf '%s' "$pr_json" | jq -c 'map(if has("reviewDecision") then . else . + {reviewDecision:"CHANGES_REQUESTED"} end)'
	return 0
}
authoritative_pr=""
_PMP_MERGE_PASS_DEADLINE_EPOCH=0
_pmp_prepare_pr_at_cursor "org/repo" '[{"number":201,"headRefOid":"same-head","mergeable":"CONFLICTING","reviewDecision":"APPROVED","statusCheckRollup":[]}]' 0 authoritative_pr merged closed failed 0 0 0 "" "" || exit 1
assert_eq "authoritative processing ignores stale cached mergeability" "MERGEABLE" "$(printf '%s' "$authoritative_pr" | jq -r '.mergeable')"
assert_eq "authoritative processing ignores stale cached review state" "CHANGES_REQUESTED" "$(printf '%s' "$authoritative_pr" | jq -r '.reviewDecision')"

# Resume scans the fresh list from zero and skips only exact cached number/head
# pairs, so reordered, inserted, and head-changed items cannot bypass enrichment.
reconcile_fresh='[{"number":105,"headRefOid":"sha105"},{"number":101,"headRefOid":"sha101"},{"number":102,"headRefOid":"sha102-new"}]'
reconcile_cache='[{"number":101,"headRefOid":"sha101","mergeable":"MERGEABLE","reviewDecision":"APPROVED","statusCheckRollup":[]},{"number":102,"headRefOid":"sha102-old","mergeable":"CONFLICTING","reviewDecision":"APPROVED","statusCheckRollup":[]}]'
_pmp_write_merge_enrichment_cache "$PULSE_MERGE_ENRICHMENT_CACHE_FILE" "org/repo" "$reconcile_cache" || exit 1
_pmp_write_merge_pr_cursor "$PULSE_MERGE_ENRICHMENT_CURSOR_FILE" "org/repo" 2 102 ""
reconciled_backlog=""
_pmp_prepare_enriched_pr_backlog "org/repo" "$reconcile_fresh" reconciled_backlog || exit 1
assert_eq "reordered and changed fresh items all receive advisory enrichment" "true" "$(printf '%s' "$reconciled_backlog" | jq -r 'all(.[]; has("mergeable") and has("reviewDecision") and has("statusCheckRollup"))')"
_pmp_clear_merge_enrichment_state

# GH#38508: four guardrail-counted worker PRs are visited `not ready` while
# their checks run, then go CLEAN at the same head. With the base resume lane
# (2) only two drain before the tail; while the dispatch PR backlog guardrail
# marker is fresh, all four are refreshed and evaluated CLEAN ahead of the
# cursor in the very next pass. Non-counted PRs keep the base ordering.
export PULSE_PR_BACKLOG_GUARDRAIL_STATE_DIR="${TMPDIR_TEST}/guardrail-state"
GUARDRAIL_PENDING_KEYS=""
pulse_pr_list_get() {
	jq -cn '[range(301; 307) | {number: ., state: "OPEN", title: "worker", isDraft: false, labels: [{name: "origin:worker"}], headRefOid: "sha\(.)"}]
		+ [{number: 307, state: "OPEN", title: "conflicting", isDraft: false, labels: [{name: "origin:interactive"}], headRefOid: "sha307"}]'
	return 0
}
_pmp_enrich_prs_with_mergeability() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	printf '%s' "$pr_json" | jq -c 'map(. + {mergeable: (if .number == 307 then "CONFLICTING" else "MERGEABLE" end)})'
	return 0
}
_pmp_enrich_prs_with_rest_check_status() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	printf '%s' "$pr_json" | jq -c --arg pending "$GUARDRAIL_PENDING_KEYS" 'map(.number as $n | . + {statusCheckRollup: (if ($pending | contains("|\($n)|"))
		then [{status: "IN_PROGRESS", conclusion: null, state: "PENDING"}]
		else [{status: "COMPLETED", conclusion: "SUCCESS", state: "SUCCESS"}] end)})'
	return 0
}
_pmp_enrich_prs_with_review_decisions() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	printf '%s' "$pr_json" | jq -c 'map(. + {reviewDecision: "APPROVED"})'
	return 0
}
# Record what the evaluator saw for each PR: CLEAN (merge-ready) or not ready.
_process_single_ready_pr() {
	local repo_slug="$1"
	local pr_obj="$2"
	local pr_number="" state=""
	pr_number=$(printf '%s' "$pr_obj" | jq -r '.number // empty') || pr_number=""
	state=$(_pmp_classify_pr_backlog_state "$pr_obj" "$repo_slug")
	PROCESSED_PRS="${PROCESSED_PRS}${pr_number}:${state} "
	FAKE_NOW=$((FAKE_NOW + 1))
	return 4
}

run_guardrail_lane_scenario() {
	local with_marker="$1"
	local first_rc=0 second_rc=0
	rm -rf "$PULSE_PR_BACKLOG_GUARDRAIL_STATE_DIR"
	rm -f "$PULSE_MERGE_PR_CURSOR_FILE" "${PULSE_MERGE_PR_CURSOR_FILE}.lane-served" "${PULSE_MERGE_PR_CURSOR_FILE}.lane-refreshed" \
		"$PULSE_MERGE_ENRICHMENT_CACHE_FILE" "$PULSE_MERGE_ENRICHMENT_CURSOR_FILE" "$ENRICH_PHASE_STATE"
	: >"$LOGFILE"
	# Pass 1: the walk visits 301-304 while their checks are in flight, then
	# pauses at the tail PR 307.
	GUARDRAIL_PENDING_KEYS="|301|302|303|304|"
	PROCESSED_PRS=""
	FAKE_NOW=100
	export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=6
	_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
	_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || first_rc=$?
	GUARDRAIL_LANE_FIRST="${first_rc}|${PROCESSED_PRS}"
	# The checks finish; the dispatch guardrail applied in between.
	GUARDRAIL_PENDING_KEYS=""
	if [[ "$with_marker" == "1" ]]; then
		mkdir -p "$PULSE_PR_BACKLOG_GUARDRAIL_STATE_DIR"
		printf '%s\t%s\n' 150 "|301|302|303|304|305|306|" >"${PULSE_PR_BACKLOG_GUARDRAIL_STATE_DIR}/org--repo"
	fi
	PROCESSED_PRS=""
	FAKE_NOW=200
	export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=0
	_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
	_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || second_rc=$?
	GUARDRAIL_LANE_SECOND="${second_rc}|${PROCESSED_PRS}"
	return 0
}

run_guardrail_lane_scenario 0
assert_eq "guardrail lane setup visits the in-flight PRs not ready, then pauses" \
	"5|305:merge-ready 306:merge-ready 301:checks-in-progress 302:checks-in-progress 303:checks-in-progress 304:checks-in-progress " "$GUARDRAIL_LANE_FIRST"
# 303 and 304 stay behind the cursor until the next revolution (the bug).
# GH#39281: the resume item (307) always runs before the lane items.
assert_eq "without the guardrail the base lane drains only two CLEAN PRs after the resume item" \
	"0|307:dirty-conflicted 301:merge-ready 302:merge-ready " "$GUARDRAIL_LANE_SECOND"
run_guardrail_lane_scenario 1
assert_eq "guardrail lane setup is unchanged by the marker" \
	"5|305:merge-ready 306:merge-ready 301:checks-in-progress 302:checks-in-progress 303:checks-in-progress 304:checks-in-progress " "$GUARDRAIL_LANE_FIRST"
assert_eq "active guardrail drains every counted PR that went CLEAN in the next pass" \
	"0|307:dirty-conflicted 301:merge-ready 302:merge-ready 303:merge-ready 304:merge-ready " "$GUARDRAIL_LANE_SECOND"
assert_eq "guardrail lane promotion is logged" "1" "$(grep -c 'moved 4 merge-ready PR(s) and 0 CI-repair PR(s) behind resume item index=6 next_pr=307 guardrail_counted=4' "$LOGFILE")"

# GH#39281: cursor progress guarantee. Slow lane items used to exhaust the
# slice before the resume item ran, so every resume paused at the same PR.
# The resume item now runs first; a pause during the lane persists the tail
# with the resume item as predecessor, and a pause before it keeps it.
# Original order [1,2,3,9,4] resumed at 9 (index 3) with lane [2,3] becomes
# [1,9,2,3,4]: resume item at index 1, last lane item at index 3.
progress_json='[{"number":1},{"number":9},{"number":2},{"number":3},{"number":4}]'
_PMP_RESUME_LANE_START=1 _PMP_RESUME_LANE_END=3 _PMP_RESUME_LANE_ITEM_PR=9 _PMP_RESUME_LANE_LAST_PR=3
rm -f "$PULSE_MERGE_PR_CURSOR_FILE"
_pmp_pause_merge_pr_cursor "org/progress" "$progress_json" 1 budget merged closed failed 0 0 0 "" ""
assert_eq "pause before the resume item keeps it with its original predecessor" "org/progress|3|3|9" "$(tr -d '\n' <"$PULSE_MERGE_PR_CURSOR_FILE")"
pr_json="$progress_json"
progress_index="" progress_next="" progress_last=""
_pmp_lane_clamped_cursor "org/progress" 2 progress_index progress_next "" progress_last 9
assert_eq "after the resume item the cursor persists the tail behind it" "4|4|9" "${progress_index}|${progress_next}|${progress_last}"
_pmp_lane_clamped_cursor "org/progress" 4 progress_index progress_next "" progress_last 3
assert_eq "after the last lane item the cursor still names the resume item as predecessor" "4|4|9" "${progress_index}|${progress_next}|${progress_last}"
_pmp_write_merge_pr_cursor "$PULSE_MERGE_PR_CURSOR_FILE" "org/progress" 4 9 4
_pmp_pause_merge_pr_cursor "org/progress" "$progress_json" 2 budget merged closed failed 0 0 0 "" ""
assert_eq "pause during the lane advances past the resume item" "org/progress|4|9|4" "$(tr -d '\n' <"$PULSE_MERGE_PR_CURSOR_FILE")"
_PMP_RESUME_LANE_START=0 _PMP_RESUME_LANE_END=0 _PMP_RESUME_LANE_ITEM_PR="" _PMP_RESUME_LANE_LAST_PR=""
rm -f "$PULSE_MERGE_PR_CURSOR_FILE"

# Lane refreshes stop while time remains to evaluate a promoted PR.
_PMP_MERGE_PASS_DEADLINE_EPOCH=$((FAKE_NOW + 10))
assert_eq "lane refreshes stop inside the evaluation reserve" "0" "$(_pmp_lane_refresh_reserve_reached; printf '%s' "$?")"
_PMP_MERGE_PASS_DEADLINE_EPOCH=$((FAKE_NOW + 100))
assert_eq "lane refreshes continue outside the evaluation reserve" "1" "$(_pmp_lane_refresh_reserve_reached; printf '%s' "$?")"
_PMP_MERGE_PASS_DEADLINE_EPOCH=0
assert_eq "unbounded passes never reserve" "1" "$(_pmp_lane_refresh_reserve_reached; printf '%s' "$?")"

# A stale or foreign marker leaves the base ordering untouched.
mkdir -p "$PULSE_PR_BACKLOG_GUARDRAIL_STATE_DIR"
printf '%s\t%s\n' 100 "|301|" >"${PULSE_PR_BACKLOG_GUARDRAIL_STATE_DIR}/org--repo"
FAKE_NOW=1000
assert_eq "stale guardrail marker is ignored" "" "$(_pmp_guardrail_counted_pr_keys org/repo)"
FAKE_NOW=200
assert_eq "fresh guardrail marker yields counted keys" "|301|" "$(_pmp_guardrail_counted_pr_keys org/repo)"
assert_eq "guardrail marker is per repository" "" "$(_pmp_guardrail_counted_pr_keys org/other)"
# Counted actionable PRs sort ahead of other work; held/conflicting ones do not.
sort_input='[{"number":401,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","state":"SUCCESS"}]},
	{"number":402,"mergeable":"CONFLICTING","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[]},
	{"number":403,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null,"state":"PENDING"}]}]'
assert_eq "uncounted backlog sort keeps bucket order" "401,403,402" "$(_pmp_sort_prs_by_backlog_priority "$sort_input" org/repo | jq -r 'map(.number) | join(",")')"
printf '%s\t%s\n' 150 "|402|403|" >"${PULSE_PR_BACKLOG_GUARDRAIL_STATE_DIR}/org--repo"
assert_eq "active guardrail sorts counted actionable PRs first" "403,401,402" "$(_pmp_sort_prs_by_backlog_priority "$sort_input" org/repo | jq -r 'map(.number) | join(",")')"
unset PULSE_PR_BACKLOG_GUARDRAIL_STATE_DIR

# A cycle deadline earlier than the merge-pass grace budget pauses the same
# cursor machinery before the instance lock can be reclaimed.
# shellcheck source=../pulse-watchdog.sh
source "${SCRIPTS_DIR}/pulse-watchdog.sh"
PULSE_START_EPOCH=0 PULSE_STALE_THRESHOLD=1800 PULSE_LOCK_MAX_AGE_S=1100
date() { [[ "${1:-}" == '+%s' ]] && printf '1000\n'; }
assert_eq "merge-pass deadline capped at cycle budget" "1010" "$(_pmp_merge_pass_budget_deadline 1000)"
unset -f date
unset PULSE_START_EPOCH PULSE_STALE_THRESHOLD PULSE_LOCK_MAX_AGE_S

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\n%sAll %d PR cursor resume tests passed.%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
fi

printf '\n%s%d/%d PR cursor resume tests failed.%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
exit 1
