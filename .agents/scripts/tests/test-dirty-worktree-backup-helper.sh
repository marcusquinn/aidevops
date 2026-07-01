#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../dirty-worktree-backup-helper.sh"

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$detail"
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

setup_repo() {
	local repo_dir="$1"
	mkdir -p "$repo_dir"
	(
		cd "$repo_dir" || exit 1
		git init -q -b main
		git config user.email test@example.invalid
		git config user.name Test
		printf 'base\n' >README.md
		git add README.md
		git commit -q -m init
	)
	return 0
}

test_backup_preserves_dirty_without_mutation() {
	local repo_dir="${TEST_ROOT}/repo"
	local backup_root="${TEST_ROOT}/backups"
	local output=""
	local backup_dir=""
	local rc=0

	setup_repo "$repo_dir" || return 1
	(
		cd "$repo_dir" || exit 1
		printf 'edit\n' >>README.md
		mkdir -p todo/tasks
		printf 'brief\n' >todo/tasks/t1-brief.md
	)

	output=$(AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" "$HELPER" backup --repo "$repo_dir" --reason test --task t1 2>/dev/null) || rc=1
	backup_dir="$output"

	[[ "$rc" -eq 0 ]] || return 1
	[[ -s "$backup_dir/tracked.patch" ]] || rc=1
	[[ -f "$backup_dir/untracked/todo/tasks/t1-brief.md" ]] || rc=1
	[[ -f "$backup_dir/manifest.tsv" ]] || rc=1
	(
		cd "$repo_dir" || exit 1
		git status --short | grep -q 'README.md' && git status --short | grep -q 'todo/'
	) || rc=1

	print_result "backup preserves tracked and untracked dirt without mutating repo" "$rc" "backup_dir=$backup_dir"
	return 0
}

test_prune_removes_terminal_pr_backup() {
	local backup_root="${TEST_ROOT}/prune-backups"
	local backup_dir="${backup_root}/sample"
	local bin_dir="${TEST_ROOT}/bin"
	local rc=0
	mkdir -p "$backup_dir" "$bin_dir"
	{
		printf 'schema\tdirty-worktree-backup-v1\n'
		printf 'repo_slug\towner/repo\n'
		printf 'pr\t123\n'
		printf 'state\topen\n'
	} >"$backup_dir/manifest.tsv"
	cat >"$bin_dir/gh" <<'GH'
#!/usr/bin/env bash
printf 'MERGED\n'
GH
	chmod +x "$bin_dir/gh"

	PATH="$bin_dir:$PATH" AIDEVOPS_DIRTY_BACKUP_ROOT="$backup_root" "$HELPER" prune --force >/dev/null 2>&1 || rc=1
	[[ ! -d "$backup_dir" ]] || rc=1
	print_result "prune removes backups linked to terminal PRs" "$rc"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dirty-backup-test.XXXXXX") || exit 1
	trap teardown EXIT

	test_backup_preserves_dirty_without_mutation
	test_prune_removes_terminal_pr_backup

	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
