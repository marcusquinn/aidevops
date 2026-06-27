#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
PROCESS_FILE="${SCRIPTS_DIR}/pulse-merge-process.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$name"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

assert_equals() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected=[$expected] actual=[$actual]"
	fi
	return 0
}

TMPDIR_TEST=$(mktemp -d "${TMPDIR:-/tmp}/pulse-merge-checkpoint-test-XXXXXX") || exit 1
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export HOME="$TMPDIR_TEST/home"
mkdir -p "$HOME/.aidevops/logs" "$HOME/.config/aidevops" || exit 1
export LOGFILE="$HOME/.aidevops/logs/pulse.log"
export STOP_FLAG="$HOME/.aidevops/logs/pulse-session.stop"
export REPOS_JSON="$HOME/.config/aidevops/repos.json"
export PULSE_MERGE_CHECKPOINT_FILE="$HOME/.aidevops/logs/pulse-merge-checkpoint"

cat >"$REPOS_JSON" <<'JSON'
{
  "initialized_repos": [
    {"slug": "org/one", "path": "/tmp/one", "pulse": true},
    {"slug": "org/two", "path": "/tmp/two", "pulse": true},
    {"slug": "org/three", "path": "/tmp/three", "pulse": true}
  ]
}
JSON

# shellcheck disable=SC1090
source "$PROCESS_FILE"

PROCESSED_REPOS=""
ZERO_PROGRESS_CALLS=""
STOP_AFTER_REPO=""

repo_allows_pulse_write_actions() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	return 0
}

_merge_ready_prs_for_repo() {
	local repo_slug="$1"
	local merged_var="$2"
	local closed_var="$3"
	local failed_var="$4"
	local pr_count_var="${5:-}"

	PROCESSED_REPOS="${PROCESSED_REPOS}${repo_slug} "
	eval "${merged_var}=0; ${closed_var}=0; ${failed_var}=0"
	if [[ -n "$pr_count_var" ]]; then
		printf -v "$pr_count_var" '%s' '0'
	fi
	if [[ "$repo_slug" == "$STOP_AFTER_REPO" ]]; then
		: >"$STOP_FLAG"
	fi
	return 0
}

pulse_merge_stuck_run_pass() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	return 0
}

_pms_count_eligible_unmerged_for_repo() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || return 1
	printf '1'
	return 0
}

pulse_merge_zero_progress_record() {
	local eligible_unmerged="$1"
	local merged="$2"
	local closed="$3"
	ZERO_PROGRESS_CALLS="${ZERO_PROGRESS_CALLS}${eligible_unmerged}:${merged}:${closed} "
	return 0
}

printf '%sRunning pulse merge checkpoint resume tests (GH#25697)%s\n' "$TEST_GREEN" "$TEST_NC"

STOP_AFTER_REPO="org/two"
merge_ready_prs_all_repos
assert_equals "first pass stops after repo two" "org/one org/two " "$PROCESSED_REPOS"
assert_equals "checkpoint records last fully processed repo" "org/two" "$(tr -d '\n' <"$PULSE_MERGE_CHECKPOINT_FILE")"
assert_equals "interrupted partial pass does not record zero-progress aggregate" "" "$ZERO_PROGRESS_CALLS"

rm -f "$STOP_FLAG"
STOP_AFTER_REPO=""
PROCESSED_REPOS=""
merge_ready_prs_all_repos
assert_equals "resumed pass starts after checkpointed repo" "org/three " "$PROCESSED_REPOS"
if [[ ! -f "$PULSE_MERGE_CHECKPOINT_FILE" ]]; then
	pass "checkpoint clears after resumed tail completes"
else
	fail "checkpoint clears after resumed tail completes" "checkpoint still exists"
fi
assert_equals "resumed partial pass skips zero-progress aggregate" "" "$ZERO_PROGRESS_CALLS"

PROCESSED_REPOS=""
merge_ready_prs_all_repos
assert_equals "fresh pass processes all repos" "org/one org/two org/three " "$PROCESSED_REPOS"
assert_equals "fresh full pass records zero-progress aggregate" "3:0:0 " "$ZERO_PROGRESS_CALLS"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '\n%sAll %s tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
fi

printf '\n%s%s/%s tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
exit 1
