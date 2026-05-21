#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression checks for pulse dispatch blocked-by reference parsing.
#
# Usage: bash .agents/tests/test-pulse-dep-graph-blocked-by.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TARGET="${SCRIPT_DIR}/../scripts/pulse-dep-graph.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TEST_REPO="example/repo"
TEST_GH_ISSUE_LIST_STATE=""
TEST_GH_VIEW_STATE=""

# shellcheck source=/dev/null
source "$TARGET"

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1"
	local reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — ${reason}}"
	return 0
}

_assert_lines_equal() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		_pass "$name"
		return 0
	fi
	_fail "$name" "expected [${expected//$'\n'/,}] got [${actual//$'\n'/,}]"
	return 0
}

_assert_blocked_result() {
	local name="$1"
	local expected_rc="$2"
	local body="$3"
	local actual_rc=1

	if is_blocked_by_unresolved "$body" "$TEST_REPO" "200"; then
		actual_rc=0
	else
		actual_rc=1
	fi
	if [[ "$actual_rc" -eq "$expected_rc" ]]; then
		_pass "$name"
		return 0
	fi
	_fail "$name" "expected rc ${expected_rc} got ${actual_rc}"
	return 0
}

_write_test_cache() {
	local cache_json="$1"
	DEP_GRAPH_CACHE_FILE="${TEST_TMPDIR}/dep-graph-cache.json"
	printf '%s\n' "$cache_json" >"$DEP_GRAPH_CACHE_FILE"
	return 0
}

gh_issue_list() {
	local ignored_args=("$@")
	if [[ -z "$TEST_GH_ISSUE_LIST_STATE" ]]; then
		return 1
	fi
	printf '%s\n' "$TEST_GH_ISSUE_LIST_STATE"
	return 0
}

gh() {
	local command_name="${1:-}"
	local subcommand_name="${2:-}"
	if [[ "$command_name" == "issue" && "$subcommand_name" == "view" ]]; then
		if [[ -z "$TEST_GH_VIEW_STATE" ]]; then
			return 1
		fi
		printf '%s\n' "$TEST_GH_VIEW_STATE"
		return 0
	fi
	return 1
}

test_task_id_blocker_parsing() {
	printf '\n=== blocked-by task IDs ===\n'
	_assert_lines_equal "compact comma-separated task IDs" $'001\n002\n003' \
		"$(_blocked_by_extract_tids 'blocked-by:t001,t002,t003')"
	_assert_lines_equal "spaced comma-separated task IDs" $'001\n002\n003' \
		"$(_blocked_by_extract_tids 'Blocked by: t001, t002, t003')"
	_assert_lines_equal "prose task IDs" $'001\n002' \
		"$(_blocked_by_extract_tids 'Blocked by t001 and t002')"
	_assert_lines_equal "one task blocker per line" $'001\n002\n003' \
		"$(_blocked_by_extract_tids $'blocked-by:t001\nblocked-by:t002\nblocked-by:t003')"
	_assert_lines_equal "decimal subtask suffixes" $'325.1\n325.2a' \
		"$(_blocked_by_extract_tids 'blocked-by:t325.1,t325.2a')"
	return 0
}

test_issue_number_blocker_parsing() {
	printf '\n=== blocked-by issue numbers ===\n'
	_assert_lines_equal "compact comma-separated issue numbers" $'123\n456' \
		"$(_blocked_by_extract_nums 'blocked-by:#123,#456')"
	_assert_lines_equal "spaced issue numbers" $'123\n456' \
		"$(_blocked_by_extract_nums 'Blocked by: #123, #456')"
	_assert_lines_equal "mixed prose issue numbers" $'123\n456' \
		"$(_blocked_by_extract_nums 'Blocked by #123 and #456')"
	return 0
}

test_unresolved_task_blocker_fails_closed() {
	printf '\n=== unresolved blocked-by task IDs ===\n'
	_write_test_cache '{"repos":{"example/repo":{"open_issues":[42],"task_to_issue":{"42":42}}}}'
	TEST_GH_ISSUE_LIST_STATE=""
	_assert_blocked_result "missing task ID in fresh cache and live miss blocks dispatch" 0 \
		'blocked-by:t1000'
	if grep -q 'blocked-by-unresolved-reference' "$LOGFILE"; then
		_pass "unresolved task ID logs distinct reason"
	else
		_fail "unresolved task ID logs distinct reason" "missing blocked-by-unresolved-reference log"
	fi
	TEST_GH_ISSUE_LIST_STATE="CLOSED"
	_assert_blocked_result "live closed task ID clears dispatch" 1 \
		'blocked-by:t1000'
	TEST_GH_ISSUE_LIST_STATE="OPEN"
	_assert_blocked_result "live open task ID blocks dispatch" 0 \
		'blocked-by:t1000'
	return 0
}

test_unresolved_issue_blocker_fails_closed() {
	printf '\n=== unresolved blocked-by issue numbers ===\n'
	_write_test_cache '{"repos":{"example/repo":{"open_issues":[42],"task_to_issue":{"42":42}}}}'
	TEST_GH_VIEW_STATE=""
	_assert_blocked_result "issue reference live miss blocks dispatch" 0 \
		'blocked-by:#1000'
	TEST_GH_VIEW_STATE="CLOSED"
	_assert_blocked_result "live closed issue reference clears dispatch" 1 \
		'blocked-by:#1000'
	TEST_GH_VIEW_STATE="OPEN"
	_assert_blocked_result "live open issue reference blocks dispatch" 0 \
		'blocked-by:#1000'
	return 0
}

main() {
	TEST_TMPDIR=$(mktemp -d)
	LOGFILE="${TEST_TMPDIR}/pulse.log"
	DEP_GRAPH_CACHE_TTL_SECS=300
	export LOGFILE DEP_GRAPH_CACHE_FILE DEP_GRAPH_CACHE_TTL_SECS

	test_task_id_blocker_parsing
	test_issue_number_blocker_parsing
	test_unresolved_task_blocker_fails_closed
	test_unresolved_issue_blocker_fails_closed

	printf '\nSummary: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
	rm -rf "$TEST_TMPDIR"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
