#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38171: dedup cleanup resumes across short housekeeping slices instead of
# restarting at the first repo and never recording a completed traversal.

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)" || exit 1

unset PULSE_STAGE_DEADLINE_EPOCH

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT="$(mktemp -d -t gh38171-dedup.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

print_result() {
	local test_name="$1"
	local failed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$failed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s %s\n' "$test_name" "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

CLOCK_FILE="${TEST_ROOT}/clock"
CALLS_LOG="${TEST_ROOT}/calls.log"

# Fake clock: each repo listing costs 5 seconds of stage time.
date() {
	if [[ "${1:-}" == "+%s" ]]; then
		cat "$CLOCK_FILE"
		return 0
	fi
	command date "$@"
	return $?
}

_pulse_enabled_repo_slugs() {
	local repos_json="$1"
	printf '%s\n' "o/a" "o/b" "o/c" "o/d"
	return 0
}

get_repo_role_by_slug() {
	local slug="$1"
	printf 'maintainer\n'
	return 0
}

gh_issue_list() {
	local slug="$2"
	printf '%s\n' "$slug" >>"$CALLS_LOG"
	printf '%s\n' "$(($(cat "$CLOCK_FILE") + 5))" >"$CLOCK_FILE"
	[[ "$slug" == "o/a" ]] && printf '11\n'
	return 0
}

gh() {
	printf 'gh %s\n' "$*" >>"${TEST_ROOT}/gh.log"
	return 0
}

LOGFILE="${TEST_ROOT}/pulse.log"
REPOS_JSON="${TEST_ROOT}/repos.json"
DEDUP_CLEANUP_LAST_RUN="${TEST_ROOT}/dedup-cleanup-last-run"
DEDUP_CLEANUP_INTERVAL=86400
DEDUP_CLEANUP_BATCH_SIZE=50
SCRIPT_DIR="$SCRIPTS_DIR"
printf '{}\n' >"$REPOS_JSON"
: >"$LOGFILE"

# shellcheck source=../pulse-simplification-review.sh
source "${SCRIPTS_DIR}/pulse-simplification-review.sh"
# shellcheck source=../pulse-simplification-orchestration.sh
source "${SCRIPTS_DIR}/pulse-simplification-orchestration.sh"

calls() {
	tr '\n' ' ' <"$CALLS_LOG"
	return 0
}

test_short_slice_resumes_and_completes() {
	local failed=0 detail=""
	local cursor_file="${DEDUP_CLEANUP_LAST_RUN}.cursor"
	: >"$CALLS_LOG"
	# 12s slice: reserve min(5, 12/4)=3s, so the third repo (t=1010) yields.
	printf '1000\n' >"$CLOCK_FILE"
	PULSE_STAGE_DEADLINE_EPOCH=1012 run_simplification_dedup_cleanup
	[[ "$(calls)" == "o/a o/b " ]] || { failed=1; detail="slice1=$(calls)"; }
	[[ "$(sed -n '1p' "$cursor_file" 2>/dev/null)" == "o/b" ]] || { failed=1; detail="${detail} cursor"; }
	[[ ! -f "$DEDUP_CLEANUP_LAST_RUN" ]] || { failed=1; detail="${detail} last-run-early"; }
	grep -q 'issue close 11 --repo o/a' "${TEST_ROOT}/gh.log" || { failed=1; detail="${detail} no-close"; }

	: >"$CALLS_LOG"
	printf '2000\n' >"$CLOCK_FILE"
	PULSE_STAGE_DEADLINE_EPOCH=2100 run_simplification_dedup_cleanup
	[[ "$(calls)" == "o/c o/d " ]] || { failed=1; detail="${detail} slice2=$(calls)"; }
	[[ ! -f "$cursor_file" ]] || { failed=1; detail="${detail} cursor-left"; }
	[[ "$(cat "$DEDUP_CLEANUP_LAST_RUN" 2>/dev/null)" == "2000" ]] || { failed=1; detail="${detail} last-run"; }
	print_result "short slices resume after the last started repo and record completion once" "$failed" "$detail"
	return 0
}

test_interval_gate_after_completion() {
	local failed=0
	: >"$CALLS_LOG"
	printf '2050\n' >"$CLOCK_FILE"
	run_simplification_dedup_cleanup
	[[ ! -s "$CALLS_LOG" ]] || failed=1
	print_result "completed traversal is interval-gated" "$failed" "calls=$(calls)"
	return 0
}

test_short_slice_resumes_and_completes
test_interval_gate_after_completion

printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
