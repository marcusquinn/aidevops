#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-solved-label-attribution.sh — regression guard for GH#22117 / t3376.
#
# Verifies the solved:* attribution dimension stays separate from origin:* and
# that pulse-merge applies solved:worker for worker evidence and
# solved:interactive for interactive PRs.

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

pass() {
	local label="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	return 0
}

fail() {
	local label="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$label"
	else
		fail "$label" "missing: $needle"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t solved-labels.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

GH_LOG="$TMP/gh.log"
export GH_LOG

gh() {
	printf '%s\n' "$*" >>"$GH_LOG"
	return 0
}
export -f gh

source "$SCRIPT_DIR/shared-constants.sh"

set_solved_label 123 owner/repo worker
worker_call="$(<"$GH_LOG")"
assert_contains "worker attribution adds solved:worker" "--add-label solved:worker" "$worker_call"
assert_contains "worker attribution removes solved:interactive" "--remove-label solved:interactive" "$worker_call"

: >"$GH_LOG"
set_solved_label 124 owner/repo interactive
interactive_call="$(<"$GH_LOG")"
assert_contains "interactive attribution adds solved:interactive" "--add-label solved:interactive" "$interactive_call"
assert_contains "interactive attribution removes solved:worker" "--remove-label solved:worker" "$interactive_call"

pulse_source="$(<"$SCRIPT_DIR/pulse-merge.sh")"
# shellcheck disable=SC2016  # Static source assertion; variables are intentionally literal.
literal_solved_call='set_solved_label "$linked_issue" "$repo_slug" "$_solved_actor"'
assert_contains "pulse merge applies solved label on linked issue" \
	"$literal_solved_call" "$pulse_source"
assert_contains "pulse merge treats origin:worker-takeover as worker-solved" \
	"*,origin:worker,* | *,origin:worker-takeover,*) _solved_actor=\"worker\"" "$pulse_source"

if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%sPASS%s: test-solved-label-attribution — %d assertions\n' \
		"$TEST_GREEN" "$TEST_NC" "$TESTS_RUN"
	exit 0
fi

printf '%sFAIL%s: test-solved-label-attribution — %d/%d failed\n' \
	"$TEST_RED" "$TEST_NC" "$TESTS_FAILED" "$TESTS_RUN"
exit 1
