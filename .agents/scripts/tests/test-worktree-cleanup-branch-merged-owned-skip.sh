#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#23076: branch-merged cleanup must not remove a
# worktree already classified as protected in the same cleanup pass, and PR or
# branch metadata must not produce permanent deletion without merge-base proof.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEAN_LIB_PATH="${TEST_SCRIPTS_DIR}/worktree-clean-lib.sh"
AUDIT_HELPER_PATH="${TEST_SCRIPTS_DIR}/audit-worktree-removal-helper.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME/.aidevops/logs"

TESTS_RUN=0
TESTS_FAILED=0
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

assert_file_contains() {
	local file_path="$1"
	local pattern="$2"
	grep -Eq "$pattern" "$file_path" 2>/dev/null
	return $?
}

setup_repo() {
	local repo_path="$1"
	mkdir -p "$repo_path" || return 1
	git -C "$repo_path" init -q -b main || return 1
	git -C "$repo_path" config user.email "test@test.local" || return 1
	git -C "$repo_path" config user.name "Test" || return 1
	git -C "$repo_path" remote add origin "https://github.com/testowner/testrepo.git" || return 1
	printf 'init\n' >"$repo_path/README.md" || return 1
	git -C "$repo_path" add README.md || return 1
	git -C "$repo_path" commit -q -m "init" || return 1
	return 0
}

source_clean_lib_with_stubs() {
	: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${BOLD:=}" "${NC:=}"
	_WTAR_REMOVED="${_WTAR_REMOVED:-removed}"
	_WTAR_SKIPPED="${_WTAR_SKIPPED:-skipped}"
	_WTAR_WH_CALLER="${_WTAR_WH_CALLER:-worktree-helper.sh}"
	
	is_registered_canonical() { return 1; }
	_branch_has_active_interactive_claim() { return 1; }
	is_worktree_owned_by_others() { return 1; }
	check_worktree_owner() { printf '\n'; return 0; }
	worktree_is_in_grace_period() { return 1; }
	worktree_has_changes() { return 1; }
	branch_has_zero_commits_ahead() { return 1; }
	branch_was_pushed() { return 1; }
	_branch_exists_on_any_remote() { return 0; }
	trash_path() { return 0; }
	get_default_branch() { printf '%s\n' "main"; return 0; }
	localdev_auto_branch_rm() { return 0; }
	assert_git_available() { return 0; }
	assert_main_worktree_sane() { return 0; }
	gh_pr_list() { return 0; }

	# shellcheck source=/dev/null
	source "$AUDIT_HELPER_PATH" || return 1
	# shellcheck source=/dev/null
	source "$CLEAN_LIB_PATH" || return 1
	return 0
}

test_protected_pass_set_blocks_branch_merged_removal() {
	local repo_path="${TEST_ROOT}/repo-protected"
	local wt_path="${TEST_ROOT}/wt-protected"
	local log_file="${TEST_ROOT}/protected-cleanup.log"
	local branch="feature/gh-99021-protected"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'merged\n' >"$repo_path/merged.txt" || rc=1
	git -C "$repo_path" add merged.txt || rc=1
	git -C "$repo_path" commit -q -m "merged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" merge -q --no-ff "$branch" -m "merge branch" || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_protected_mark "$wt_path"
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" "" >/dev/null
	) || rc=1

	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*protected-pass-skip.*mode=skipped.*protected_status=pass-local" || rc=1
	print_result "protected pass-local set blocks branch-merged removal" "$rc" \
		"Expected worktree to survive and protected audit entry in $log_file"
	return 0
}

test_merged_pr_without_ancestor_proof_skips() {
	local repo_path="${TEST_ROOT}/repo-unproven"
	local wt_path="${TEST_ROOT}/wt-unproven"
	local log_file="${TEST_ROOT}/unproven-cleanup.log"
	local branch="feature/gh-99022-unproven"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'not ancestor\n' >"$repo_path/unproven.txt" || rc=1
	git -C "$repo_path" add unproven.txt || rc=1
	git -C "$repo_path" commit -q -m "unmerged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "$branch" "" "false" ""
	) || rc=1

	[[ -z "$classification" ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*branch-merged-unproven.*mode=skipped.*merge_proof_result=not-ancestor" || rc=1
	print_result "merged PR metadata without ancestor proof skips" "$rc" \
		"Expected empty classification, surviving worktree, and unproven audit entry"
	return 0
}

echo "=== test-worktree-cleanup-branch-merged-owned-skip.sh ==="
test_protected_pass_set_blocks_branch_merged_removal
test_merged_pr_without_ancestor_proof_skips

printf '\nResults: %d/%d passed, %d failed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
