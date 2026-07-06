#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-pr-cursor-resume.sh — GH#26708 regression guard.
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
export PULSE_MERGE_BATCH_LIMIT=10

# shellcheck disable=SC1090
source "$PROCESS_FILE"
set +e
set +o pipefail 2>/dev/null || true

FAKE_NOW=100
PROCESSED_PRS=""

_pmp_now_epoch() {
	printf '%s' "$FAKE_NOW"
	return 0
}

pulse_pr_list_get() {
	printf '%s\n' '[{"number":101,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]},{"number":102,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]},{"number":103,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]},{"number":104,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"labels":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}]'
	return 0
}

_pulse_merge_ready_pr_json_fields() {
	printf '%s' 'number,mergeable,reviewDecision,isDraft,labels,statusCheckRollup'
	return 0
}

_pmp_enrich_prs_with_rest_check_status() {
	local repo_slug="$1"
	local pr_json="$2"
	[[ -n "$repo_slug" ]] || return 1
	printf '%s' "$pr_json"
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

printf '%s=== GH#26708: pulse merge PR cursor resume tests ===%s\n' "$TEST_BLUE" "$TEST_NC"

merged=0 closed=0 failed=0 pr_count=0
export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=2
_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || first_rc=$?
assert_eq "first pass pauses when graceful budget is exhausted" "5" "${first_rc:-0}"
assert_eq "first pass processes only PRs before the budget edge" "101 102 " "$PROCESSED_PRS"
assert_eq "cursor records next tail PR" "org/repo|2|102|103" "$(tr -d '\n' <"$PULSE_MERGE_PR_CURSOR_FILE")"

PROCESSED_PRS=""
FAKE_NOW=200
export PULSE_MERGE_GRACEFUL_BUDGET_SECONDS=0
_PMP_MERGE_PASS_DEADLINE_EPOCH=$(_pmp_merge_pass_budget_deadline "$FAKE_NOW")
_merge_ready_prs_for_repo "org/repo" merged closed failed pr_count "" || second_rc=$?
assert_eq "second pass completes normally" "0" "${second_rc:-0}"
assert_eq "second pass resumes at saved tail PR" "103 104 " "$PROCESSED_PRS"
if [[ ! -f "$PULSE_MERGE_PR_CURSOR_FILE" ]]; then
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%sPASS%s: cursor clears after repo completes\n' "$TEST_GREEN" "$TEST_NC"
else
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s: cursor clears after repo completes\n' "$TEST_RED" "$TEST_NC"
fi

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\n%sAll %d PR cursor resume tests passed.%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
fi

printf '\n%s%d/%d PR cursor resume tests failed.%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
exit 1
