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

main() {
	test_task_id_blocker_parsing
	test_issue_number_blocker_parsing

	printf '\nSummary: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
