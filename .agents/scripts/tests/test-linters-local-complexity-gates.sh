#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-linters-local-complexity-gates.sh — local complexity gate classification tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

# shellcheck source=../shared-constants.sh
source "${REPO_ROOT}/.agents/scripts/shared-constants.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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

setup_repo() {
	TEST_ROOT=$(mktemp -d)
	git -C "$TEST_ROOT" init -q
	git -C "$TEST_ROOT" config user.email "test@example.invalid"
	git -C "$TEST_ROOT" config user.name "Test Runner"
	git -C "$TEST_ROOT" config commit.gpgsign false
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

make_sh_function() {
	local file="$1"
	local function_name="$2"
	local lines="$3"
	local i=0

	printf '%s() {\n' "$function_name" >>"$file"
	while [[ "$i" -lt "$lines" ]]; do
		printf '  : # line %d\n' "$i" >>"$file"
		i=$((i + 1))
	done
	printf '}\n' >>"$file"
	return 0
}

make_sh_function_compact() {
	local file="$1"
	local function_name="$2"
	local lines="$3"
	local i=0

	printf '%s(){\n' "$function_name" >>"$file"
	while [[ "$i" -lt "$lines" ]]; do
		printf '  : # line %d\n' "$i" >>"$file"
		i=$((i + 1))
	done
	printf '}\n' >>"$file"
	return 0
}

make_deep_nesting() {
	local file="$1"
	local depth="$2"
	local i=0
	local indent=""

	printf '#!/usr/bin/env bash\n' >"$file"
	while [[ "$i" -lt "$depth" ]]; do
		printf '%sif true; then\n' "$indent" >>"$file"
		indent="${indent}  "
		i=$((i + 1))
	done
	printf '%s:\n' "$indent" >>"$file"
	while [[ "$i" -gt 0 ]]; do
		i=$((i - 1))
		indent="${indent#  }"
		printf '%sfi\n' "$indent" >>"$file"
	done
	return 0
}

source_linter_analysis() {
	SCRIPT_DIR="${REPO_ROOT}/.agents/scripts"
	MAX_FUNCTION_LENGTH_WARN=50
	MAX_FUNCTION_LENGTH_BLOCK=100
	MAX_FUNCTION_LENGTH_VIOLATIONS=1
	MAX_NESTING_DEPTH_WARN=5
	MAX_NESTING_DEPTH_BLOCK=8
	MAX_NESTING_VIOLATIONS=1
	MAX_FILE_LINES_WARN=800
	MAX_FILE_LINES_BLOCK=1500
	# shellcheck source=../linters-local-analysis.sh
	source "${REPO_ROOT}/.agents/scripts/linters-local-analysis.sh"
	return 0
}

mark_origin_main() {
	git -C "$TEST_ROOT" add .
	git -C "$TEST_ROOT" commit -q -m "baseline"
	git -C "$TEST_ROOT" branch -M main
	git -C "$TEST_ROOT" update-ref refs/remotes/origin/main HEAD
	return 0
}

test_historical_function_debt_is_advisory() {
	setup_repo
	printf '#!/usr/bin/env bash\n' >"${TEST_ROOT}/a.sh"
	make_sh_function "${TEST_ROOT}/a.sh" "big_one" 105
	make_sh_function "${TEST_ROOT}/a.sh" "big_two" 105
	mark_origin_main
	source_linter_analysis
	(
		cd "$TEST_ROOT" || exit 1
		ALL_SH_FILES=(a.sh)
		check_function_complexity >"${TEST_ROOT}/linters-local-function-advisory.out" 2>&1
	)
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "historical function debt is advisory" 0
	else
		print_result "historical function debt is advisory" 1 "got exit $rc"
	fi
	teardown
	return 0
}

test_changed_function_regression_blocks() {
	setup_repo
	printf '#!/usr/bin/env bash\n' >"${TEST_ROOT}/a.sh"
	make_sh_function "${TEST_ROOT}/a.sh" "small" 10
	mark_origin_main
	make_sh_function "${TEST_ROOT}/a.sh" "new_big" 105
	source_linter_analysis
	local rc=0
	(
		cd "$TEST_ROOT" || exit 1
		ALL_SH_FILES=(a.sh)
		check_function_complexity >"${TEST_ROOT}/linters-local-function-regression.out" 2>&1
	) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "changed function complexity regression blocks" 0
	else
		print_result "changed function complexity regression blocks" 1 "got exit $rc"
	fi
	teardown
	return 0
}

test_function_brace_spacing_change_is_not_regression() {
	setup_repo
	printf '#!/usr/bin/env bash\n' >"${TEST_ROOT}/a.sh"
	make_sh_function "${TEST_ROOT}/a.sh" "format_sensitive" 105
	mark_origin_main
	printf '#!/usr/bin/env bash\n' >"${TEST_ROOT}/a.sh"
	make_sh_function_compact "${TEST_ROOT}/a.sh" "format_sensitive" 105
	source_linter_analysis
	local rc=0
	(
		cd "$TEST_ROOT" || exit 1
		ALL_SH_FILES=(a.sh)
		check_function_complexity >"${TEST_ROOT}/linters-local-function-spacing.out" 2>&1
	) || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "function brace spacing change is not regression" 0
	else
		print_result "function brace spacing change is not regression" 1 "got exit $rc"
	fi
	teardown
	return 0
}

test_historical_nesting_debt_is_advisory() {
	setup_repo
	make_deep_nesting "${TEST_ROOT}/a.sh" 9
	cp "${TEST_ROOT}/a.sh" "${TEST_ROOT}/b.sh"
	mark_origin_main
	source_linter_analysis
	(
		cd "$TEST_ROOT" || exit 1
		ALL_SH_FILES=(a.sh b.sh)
		check_nesting_depth >"${TEST_ROOT}/linters-local-nesting-advisory.out" 2>&1
	)
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "historical nesting debt is advisory" 0
	else
		print_result "historical nesting debt is advisory" 1 "got exit $rc"
	fi
	teardown
	return 0
}

test_changed_nesting_regression_blocks() {
	setup_repo
	printf '#!/usr/bin/env bash\n:\n' >"${TEST_ROOT}/a.sh"
	mark_origin_main
	make_deep_nesting "${TEST_ROOT}/a.sh" 9
	source_linter_analysis
	local rc=0
	(
		cd "$TEST_ROOT" || exit 1
		ALL_SH_FILES=(a.sh)
		check_nesting_depth >"${TEST_ROOT}/linters-local-nesting-regression.out" 2>&1
	) || rc=$?
	if [[ "$rc" -eq 1 ]]; then
		print_result "changed nesting-depth regression blocks" 0
	else
		print_result "changed nesting-depth regression blocks" 1 "got exit $rc"
	fi
	teardown
	return 0
}

main() {
	test_historical_function_debt_is_advisory
	test_changed_function_regression_blocks
	test_function_brace_spacing_change_is_not_regression
	test_historical_nesting_debt_is_advisory
	test_changed_nesting_regression_blocks

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
