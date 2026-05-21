#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

TEST_ROOT=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		printf 'FAIL %s\n' "$test_name"
		[[ -n "$message" ]] && printf '  %s\n' "$message"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

setup_fixture() {
	TEST_ROOT=$(mktemp -d)
	trap teardown EXIT
	export HOME="$TEST_ROOT/home"
	export LOGFILE="$TEST_ROOT/cleanup.log"
	export AIDEVOPS_ORPHAN_TRASH_ROOT="$TEST_ROOT/trash"
	export ORPHAN_WORKTREE_GRACE_SECS=0
	mkdir -p "$HOME/.config/aidevops" "$TEST_ROOT/Git" "$AIDEVOPS_ORPHAN_TRASH_ROOT"

	local repo="$TEST_ROOT/Git/aidevops"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name 'Aidevops Test'
	printf 'base\n' >"$repo/README.md"
	git -C "$repo" add README.md
	git -C "$repo" commit -q -m 'init'

	cat >"$HOME/.config/aidevops/repos.json" <<JSON
{"initialized_repos":[{"path":"$repo","slug":"example/aidevops","local_only":false}]}
JSON

	# Registered valid worktree: matches worker naming but must be preserved.
	git -C "$repo" worktree add -q "$TEST_ROOT/Git/aidevops-feature-auto-registered" -b feature/auto-registered

	# Broken unregistered gitfile worktree-like directory: screenshot outlier class.
	mkdir -p "$TEST_ROOT/Git/aidevops-feature-auto-20260416-154130-gh19261"
	printf 'gitdir: %s\n' "$TEST_ROOT/missing/gitdir" >"$TEST_ROOT/Git/aidevops-feature-auto-20260416-154130-gh19261/.git"

	# Non-git worker-looking leftover directory: screenshot outlier class.
	mkdir -p "$TEST_ROOT/Git/aidevops-feature-auto-20260505-gh22927-dispatch-recovery"
	printf 'leftover\n' >"$TEST_ROOT/Git/aidevops-feature-auto-20260505-gh22927-dispatch-recovery/NOTE.txt"

	# Standalone repo: must not be trashed automatically.
	mkdir -p "$TEST_ROOT/Git/aidevops-cloudron-app"
	git -C "$TEST_ROOT/Git/aidevops-cloudron-app" init -q

	return 0
}

load_subject() {
	# shellcheck source=../shared-constants.sh
	source "$ROOT_DIR/.agents/scripts/shared-constants.sh"
	# shellcheck source=../pulse-cleanup.sh
	source "$ROOT_DIR/.agents/scripts/pulse-cleanup.sh"
	return 0
}

test_orphan_sibling_dirs_move_to_trash_only() {
	local repo_json="$HOME/.config/aidevops/repos.json"
	local moved_count
	moved_count=$(_pc_cleanup_orphan_sibling_dirs "$repo_json" "$(date +%s)")

	if [[ "$moved_count" -ne 2 ]]; then
		print_result "orphan sibling cleanup moves only eligible outliers" 1 "expected 2 moved, got $moved_count"
		return 0
	fi

	if [[ -d "$TEST_ROOT/Git/aidevops-feature-auto-registered" ]]; then
		print_result "registered worktree is preserved" 0
	else
		print_result "registered worktree is preserved" 1 "registered worktree was removed"
	fi

	if [[ -d "$TEST_ROOT/Git/aidevops-cloudron-app/.git" ]]; then
		print_result "standalone git repo is preserved" 0
	else
		print_result "standalone git repo is preserved" 1 "standalone repo was removed"
	fi

	local trashed_count
	trashed_count=0
	local trash_bucket trashed_dir
	for trash_bucket in "$AIDEVOPS_ORPHAN_TRASH_ROOT"/*; do
		[[ -d "$trash_bucket" ]] || continue
		for trashed_dir in "$trash_bucket"/*; do
			[[ -d "$trashed_dir" ]] || continue
			trashed_count=$((trashed_count + 1))
		done
	done
	if [[ "$trashed_count" -eq 2 ]]; then
		print_result "eligible outliers are recoverable in trash bucket" 0
	else
		print_result "eligible outliers are recoverable in trash bucket" 1 "expected 2 trashed dirs, got $trashed_count"
	fi
	return 0
}

main() {
	if ! command -v jq >/dev/null 2>&1; then
		printf 'SKIP jq unavailable\n'
		return 0
	fi
	setup_fixture
	load_subject
	test_orphan_sibling_dirs_move_to_trash_only
	printf '\n%d/%d tests passed\n' "$TESTS_PASSED" "$TESTS_RUN"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
