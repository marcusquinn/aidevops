#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../pre-edit-check.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
TEST_REGISTRY_DIR=""
TEST_REGISTRY_DB=""

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
	TEST_REGISTRY_DIR="${TEST_ROOT}/.registry"
	TEST_REGISTRY_DB="${TEST_REGISTRY_DIR}/worktree-registry.db"
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
		WORKTREE_REGISTRY_DIR="$TEST_REGISTRY_DIR" \
			WORKTREE_REGISTRY_DB="$TEST_REGISTRY_DB" \
			"$HELPER" "$@"
	)
	return $?
}

ensure_registry_schema() {
	mkdir -p "$TEST_REGISTRY_DIR"
	sqlite3 "$TEST_REGISTRY_DB" "
        CREATE TABLE IF NOT EXISTS worktree_owners (
            worktree_path TEXT PRIMARY KEY,
            branch        TEXT,
            owner_pid     INTEGER,
            owner_session TEXT DEFAULT '',
            owner_batch   TEXT DEFAULT '',
            task_id       TEXT DEFAULT '',
            created_at    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );
    " >/dev/null 2>&1
	return 0
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

test_blocks_when_linked_worktree_owned_by_another_live_process() {
	local worktree_path="${TEST_ROOT}/owned-worktree"
	git -C "$TEST_ROOT" worktree add "$worktree_path" -b bugfix/owned-worktree >/dev/null 2>&1

	ensure_registry_schema
	sqlite3 "$TEST_REGISTRY_DB" "
        INSERT OR REPLACE INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_session)
        VALUES
            ('$worktree_path',
             'bugfix/owned-worktree',
             $$,
             'other-session');
    " >/dev/null 2>&1

	local output=""
	local exit_code=0
	local claim_pid=""
	sleep 30 >/dev/null 2>&1 &
	claim_pid=$!
	output=$(PRE_EDIT_OWNER_PID="$claim_pid" run_helper "$worktree_path" 2>&1) || exit_code=$?
	kill "$claim_pid" >/dev/null 2>&1 || true
	wait "$claim_pid" 2>/dev/null || true

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"WORKTREE_OWNERSHIP_CONFLICT=true"* ]] && [[ "$output" == *"WORKTREE_OWNER_PID=$$"* ]] && [[ "$output" == *"ACTION_REQUIRED=create_worktree"* ]]; then
		print_result "blocks linked worktree edits when owned by another live process" 0
		return 0
	fi

	print_result "blocks linked worktree edits when owned by another live process" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_allowlisted_path_allows_edit_on_main() {
	# Ensure repo is on main for this test
	git -C "$TEST_ROOT" switch main >/dev/null 2>&1 || true

	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --file "README.md" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 0 ]] && [[ "$output" == *"LOOP_DECISION=stay"* ]]; then
		print_result "allowlisted path (README.md) allows edit on main in loop mode" 0
		return 0
	fi

	print_result "allowlisted path (README.md) allows edit on main in loop mode" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_path_traversal_blocked_on_main() {
	# Ensure repo is on main for this test
	git -C "$TEST_ROOT" switch main >/dev/null 2>&1 || true

	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --file "todo/../secret.py" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"LOOP_DECISION=worktree"* ]]; then
		print_result "path traversal (todo/../secret.py) blocked on main" 0
		return 0
	fi

	print_result "path traversal (todo/../secret.py) blocked on main" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_absolute_path_outside_repo_blocked_on_main() {
	# Ensure repo is on main for this test
	git -C "$TEST_ROOT" switch main >/dev/null 2>&1 || true

	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --file "/etc/passwd" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 2 ]] && [[ "$output" == *"LOOP_DECISION=worktree"* ]]; then
		print_result "absolute path outside repo (/etc/passwd) blocked on main" 0
		return 0
	fi

	print_result "absolute path outside repo (/etc/passwd) blocked on main" 1 "exit=${exit_code} output=${output}"
	return 0
}

test_todo_subdir_path_allows_edit_on_main() {
	# Ensure repo is on main for this test
	git -C "$TEST_ROOT" switch main >/dev/null 2>&1 || true
	mkdir -p "${TEST_ROOT}/todo"

	local output=""
	local exit_code=0
	output=$(FULL_LOOP_HEADLESS=true run_helper "$TEST_ROOT" --loop-mode --file "todo/tasks/t001-brief.md" 2>&1) || exit_code=$?

	if [[ "$exit_code" -eq 0 ]] && [[ "$output" == *"LOOP_DECISION=stay"* ]]; then
		print_result "todo/ subdir path allows edit on main in loop mode" 0
		return 0
	fi

	print_result "todo/ subdir path allows edit on main in loop mode" 1 "exit=${exit_code} output=${output}"
	return 0
}

main() {
	trap teardown_test_repo EXIT
	setup_test_repo

	test_blocks_headless_edits_on_main_with_worktree_guidance
	test_allows_linked_worktree_edits
	test_warns_when_canonical_repo_is_off_main
	test_blocks_when_linked_worktree_owned_by_another_live_process
	test_allowlisted_path_allows_edit_on_main
	test_path_traversal_blocked_on_main
	test_absolute_path_outside_repo_blocked_on_main
	test_todo_subdir_path_allows_edit_on_main

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
