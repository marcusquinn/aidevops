#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#23932: stale/no_work recovery must not relabel an
# issue status:available when its declared blocked-by dependencies are still
# open or unknown.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

TEST_ROOT="$(mktemp -d -t stale-blocked-by.XXXXXX)" || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

LOGFILE="${TEST_ROOT}/pulse.log"
STATUS_LOG="${TEST_ROOT}/status.log"
COMMENT_LOG="${TEST_ROOT}/comments.log"
TEST_ISSUE_BODY=""
TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

reset_logs() {
	: >"$LOGFILE"
	: >"$STATUS_LOG"
	: >"$COMMENT_LOG"
	return 0
}

gh() {
	local resource="${1:-}"
	local action="${2:-}"
	if [[ "$resource" == "issue" && "$action" == "view" ]]; then
		printf '%s\n' "$TEST_ISSUE_BODY"
		return 0
	fi
	return 0
}

gh_issue_comment() {
	printf '%s\n' "$*" >>"$COMMENT_LOG"
	return 0
}

set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local status="$3"
	shift 3
	printf '%s|%s|%s|%s\n' "$issue_number" "$repo_slug" "$status" "$*" >>"$STATUS_LOG"
	return 0
}

is_blocked_by_unresolved() {
	local issue_body="$1"
	local repo_slug="$2"
	local issue_number="$3"
	: "$repo_slug" "$issue_number"
	[[ "$issue_body" == *"blocked-by:"* ]] && return 0
	return 1
}

# shellcheck source=../dispatch-dedup-stale.sh
source "${SCRIPT_DIR}/dispatch-dedup-stale.sh"

test_blocked_by_dependency_keeps_issue_blocked() {
	reset_logs
	TEST_ISSUE_BODY="blocked-by:t1000"
	local output=""
	output=$(_stale_recovery_apply "123" "owner/repo" "runner-a" "no_work")

	if [[ "$output" == *"STALE_BLOCKED_BY_DEPENDENCY"* ]]; then
		pass "blocked-by stale recovery emits dependency-blocked marker"
	else
		fail "blocked-by stale recovery emits dependency-blocked marker" "output=${output}"
	fi
	if grep -q '^123|owner/repo|blocked|' "$STATUS_LOG" && ! grep -q '^123|owner/repo|available|' "$STATUS_LOG"; then
		pass "blocked-by stale recovery keeps issue status:blocked"
	else
		fail "blocked-by stale recovery keeps issue status:blocked" "status=$(tr '\n' ' ' <"$STATUS_LOG")"
	fi
	if grep -q 'stale-recovery-blocked-by-unresolved' "$COMMENT_LOG"; then
		pass "blocked-by stale recovery posts dependency hold comment"
	else
		fail "blocked-by stale recovery posts dependency hold comment" "comments=$(tr '\n' ' ' <"$COMMENT_LOG")"
	fi
	return 0
}

test_clear_dependency_state_requeues_available() {
	reset_logs
	TEST_ISSUE_BODY="No blockers here"
	local output=""
	output=$(_stale_recovery_apply "124" "owner/repo" "runner-a" "stale_timeout")

	if [[ "$output" == *"STALE_RECOVERED"* ]]; then
		pass "clear stale recovery emits normal recovered marker"
	else
		fail "clear stale recovery emits normal recovered marker" "output=${output}"
	fi
	if grep -q '^124|owner/repo|available|' "$STATUS_LOG"; then
		pass "clear stale recovery requeues status:available"
	else
		fail "clear stale recovery requeues status:available" "status=$(tr '\n' ' ' <"$STATUS_LOG")"
	fi
	return 0
}

test_blocked_by_dependency_keeps_issue_blocked
test_clear_dependency_state_requeues_available

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
