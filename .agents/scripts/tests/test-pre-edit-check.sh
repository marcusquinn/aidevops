#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../pre-edit-check.sh"

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

setup_test_repo() {
	TEST_ROOT=$(mktemp -d)
	git -C "$TEST_ROOT" init -b main >/dev/null 2>&1 || {
		git -C "$TEST_ROOT" init >/dev/null 2>&1
		git -C "$TEST_ROOT" checkout -b main >/dev/null 2>&1
	}
	git -C "$TEST_ROOT" config user.name "Aidevops Test"
	git -C "$TEST_ROOT" config user.email "test@example.com"
	printf 'test\n' >"${TEST_ROOT}/README.md"
	git -C "$TEST_ROOT" add README.md
	git -C "$TEST_ROOT" commit -m "test: seed repo" >/dev/null 2>&1
	return 0
}

teardown_test_repo() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

run_helper() {
	local target_dir="$1"
	shift
	(
		cd "$target_dir" || exit 1
		"$HELPER" "$@"
	)
	return $?
}

test_blocks_headless_edits_on_main_with_worktree_guidance() {
	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"Canonical repo directory is on protected 'main'; move code edits into a linked worktree."* ]] && [[ "$output" == *"HEADLESS_BLOCKED=true"* ]] && [[ "$output" == *"ACTION_REQUIRED=create_worktree"* ]]; then
		print_result "blocks headless edits on main with worktree guidance" 0
		return 0
	fi

	print_result "blocks headless edits on main with worktree guidance" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_allows_linked_worktree_edits() {
	local worktree_path="${TEST_ROOT}/linked-worktree"
	git -C "$TEST_ROOT" worktree add "$worktree_path" -b bugfix/test-linked-worktree >/dev/null 2>&1

	local output=""
	local exit_code=0
	output=$(run_helper "$worktree_path" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 0 ]] && [[ "$output" == *"OK"* ]] && [[ "$output" == *"In linked worktree on ref: "* ]]; then
		print_result "allows edits from linked worktree paths" 0
		return 0
	fi

	print_result "allows edits from linked worktree paths" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_warns_when_canonical_repo_is_off_main() {
	git -C "$TEST_ROOT" switch -c bugfix/off-main >/dev/null 2>&1

	local output=""
	local exit_code=0
	output=$(run_helper "$TEST_ROOT" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 3 ]] && [[ "$output" == *"WARNING - MAIN REPO DIRECTORY IS OFF MAIN"* ]] && [[ "$output" == *"MAIN_REPO_OFF_MAIN_WARNING=bugfix/off-main"* ]]; then
		print_result "warns when canonical repo directory is off main" 0
		return 0
	fi

	print_result "warns when canonical repo directory is off main" 1 "exit=${exit_code} output=${output}"
	return 0
}

main() {
	trap teardown_test_repo EXIT
	setup_test_repo

	test_blocks_headless_edits_on_main_with_worktree_guidance
	test_allows_linked_worktree_edits
	test_warns_when_canonical_repo_is_off_main

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
