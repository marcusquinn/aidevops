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
	unregister_worktree() { return 0; }
	assert_git_available() { return 0; }
	assert_main_worktree_sane() { return 0; }
	gh_pr_list() { return 0; }

	# shellcheck source=/dev/null
	source "$AUDIT_HELPER_PATH" || return 1
	# shellcheck source=/dev/null
	source "$CLEAN_LIB_PATH" || return 1
	_branch_has_active_interactive_claim() { return 1; }
	worktree_is_in_grace_period() { return 1; }
	branch_has_zero_commits_ahead() { return 1; }
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

test_squash_merged_pr_without_ancestor_proof_classifies() {
	local repo_path="${TEST_ROOT}/repo-unproven"
	local wt_path="${TEST_ROOT}/wt-unproven"
	local log_file="${TEST_ROOT}/squash-merged-cleanup.log"
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

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "squash-merged PR metadata does not require ancestor proof" "$rc" \
		"Expected squash-merged classification with GitHub PR-state proof"
	return 0
}

test_prefetched_merged_pr_metadata_skips_exact_head_lookup() {
	local repo_path="${TEST_ROOT}/repo-prefetched-squash-pr"
	local wt_path="${TEST_ROOT}/wt-prefetched-squash-pr"
	local log_file="${TEST_ROOT}/prefetched-squash-pr-cleanup.log"
	local branch="feature/gh-99027-prefetched-squash-pr"
	local gh_called_marker="${TEST_ROOT}/prefetched-gh-called"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'prefetched squash merge head\n' >"$repo_path/prefetched-squash-pr.txt" || rc=1
	git -C "$repo_path" add prefetched-squash-pr.txt || rc=1
	git -C "$repo_path" commit -q -m "prefetched squash-merged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		gh_pr_list() {
			printf 'called\n' >"$gh_called_marker"
			printf '0\n'
			return 0
		}
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "$branch" "" "false" ""
	) || rc=1

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ ! -e "$gh_called_marker" ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "prefetched merged PR metadata skips exact-head lookup" "$rc" \
		"Expected prefetched merged PR list to avoid redundant gh_pr_list lookup"
	return 0
}

test_merged_pr_list_passes_explicit_repo_slug() {
	local repo_path="${TEST_ROOT}/repo-explicit-slug"
	local args_file="${TEST_ROOT}/explicit-slug-args"
	local output=""
	local rc=0
	setup_repo "$repo_path" || rc=1

	output=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		gh_pr_list() {
			printf '%s' "$*" >"$args_file"
			printf 'feature/explicit-repo\n'
			return 0
		}
		_clean_build_merged_pr_branches
	) || rc=1

	[[ "$output" == *"feature/explicit-repo"* ]] || rc=1
	grep -q -- '--repo testowner/testrepo' "$args_file" 2>/dev/null || rc=1
	print_result "merged PR list passes explicit repo slug" "$rc" \
		"Expected --repo testowner/testrepo in gh_pr_list args"
	return 0
}

test_deleted_squash_merged_pr_metadata_wins_over_remote_deleted() {
	local repo_path="${TEST_ROOT}/repo-deleted-squash-pr"
	local wt_path="${TEST_ROOT}/wt-deleted-squash-pr"
	local log_file="${TEST_ROOT}/deleted-squash-pr-cleanup.log"
	local branch="feature/gh-99025-deleted-squash-pr"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'deleted squash merge head\n' >"$repo_path/deleted-squash-pr.txt" || rc=1
	git -C "$repo_path" add deleted-squash-pr.txt || rc=1
	git -C "$repo_path" commit -q -m "deleted squash-merged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "$branch" "" "false" ""
	) || rc=1

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ "$classification" != *"remote deleted"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "deleted squash-merged PR metadata wins over remote-deleted classification" "$rc" \
		"Expected exact merged PR branch metadata to bypass remote-deleted ancestry proof"
	return 0
}

test_exact_head_merged_pr_proof_wins_when_global_list_misses() {
	local repo_path="${TEST_ROOT}/repo-exact-head-pr"
	local wt_path="${TEST_ROOT}/wt-exact-head-pr"
	local log_file="${TEST_ROOT}/exact-head-pr-cleanup.log"
	local branch="feature/gh-99026-exact-head-pr"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'exact head merged proof\n' >"$repo_path/exact-head-pr.txt" || rc=1
	git -C "$repo_path" add exact-head-pr.txt || rc=1
	git -C "$repo_path" commit -q -m "exact head merged branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		gh_pr_list() {
			local args="$*"
			[[ "$args" == *"--state merged"* ]] || return 1
			[[ "$args" == *"--json number"* ]] || return 1
			printf '1\n'
			return 0
		}
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" ""
	) || rc=1

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ "$classification" != *"remote deleted"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "exact-head merged PR proof wins when global merged list misses branch" "$rc" \
		"Expected exact-head merged PR lookup to bypass remote-deleted ancestry proof"
	return 0
}

test_exact_merged_pr_proof_recovers_unproven_traditional_merge() {
	local repo_path="${TEST_ROOT}/repo-unproven-traditional"
	local wt_path="${TEST_ROOT}/wt-unproven-traditional"
	local log_file="${TEST_ROOT}/unproven-traditional-cleanup.log"
	local branch="feature/gh-99028-unproven-traditional"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'traditional false positive\n' >"$repo_path/unproven-traditional.txt" || rc=1
	git -C "$repo_path" add unproven-traditional.txt || rc=1
	git -C "$repo_path" commit -q -m "traditional false-positive branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		git() {
			if [[ "${1:-}" == "branch" && "${2:-}" == "--merged" ]]; then
				printf '  %s\n' "$branch"
				return 0
			fi
			command git "$@"
		}
		gh_pr_list() {
			local args="$*"
			[[ "$args" == *"--state merged"* ]] || return 1
			[[ "$args" == *"--json number"* ]] || return 1
			printf '1\n'
			return 0
		}
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" ""
	) || rc=1

	[[ "$classification" == *"squash-merged PR"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "exact merged PR proof recovers unproven traditional merge" "$rc" \
		"Expected exact merged PR lookup to override branch-merged-unproven"
	return 0
}

test_closed_pr_without_ancestor_proof_classifies() {
	local repo_path="${TEST_ROOT}/repo-closed-pr"
	local wt_path="${TEST_ROOT}/wt-closed-pr"
	local log_file="${TEST_ROOT}/closed-pr-cleanup.log"
	local branch="feature/gh-99024-closed-pr"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'abandoned closed pr\n' >"$repo_path/closed-pr.txt" || rc=1
	git -C "$repo_path" add closed-pr.txt || rc=1
	git -C "$repo_path" commit -q -m "abandoned branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" "$branch"
	) || rc=1

	[[ "$classification" == *"closed PR"* ]] || rc=1
	[[ "$classification" == *"merge_proof=github-merged-pr-state"* ]] || rc=1
	[[ "$classification" == *"merge_proof_result=github-merged-pr"* ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	print_result "closed PR metadata does not require ancestor proof" "$rc" \
		"Expected closed PR classification with GitHub PR-state proof"
	return 0
}

test_remote_deleted_without_ancestor_proof_skips() {
	local repo_path="${TEST_ROOT}/repo-remote-deleted"
	local wt_path="${TEST_ROOT}/wt-remote-deleted"
	local log_file="${TEST_ROOT}/remote-deleted-cleanup.log"
	local branch="feature/gh-99023-remote-deleted"
	local classification=""
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'not ancestor remote deleted\n' >"$repo_path/remote-deleted.txt" || rc=1
	git -C "$repo_path" add remote-deleted.txt || rc=1
	git -C "$repo_path" commit -q -m "unmerged remote-deleted branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	classification=$(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		_clean_classify_worktree "$wt_path" "$branch" "main" "false" "" "" "false" ""
	) || rc=1

	[[ -z "$classification" ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*branch-merged-unproven.*mode=skipped.*merge_proof_result=not-ancestor" || rc=1
	print_result "remote-deleted metadata without ancestor proof skips" "$rc" \
		"Expected empty classification, surviving worktree, and unproven audit entry"
	return 0
}

test_closed_issue_unproven_branch_removes_worktree_preserves_branch() {
	local repo_path="${TEST_ROOT}/repo-closed-issue-unproven"
	local wt_path="${TEST_ROOT}/wt-closed-issue-unproven"
	local log_file="${TEST_ROOT}/closed-issue-unproven-cleanup.log"
	local branch="feature/auto-20260520-gh99029"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'closed issue unproven\n' >"$repo_path/closed-issue-unproven.txt" || rc=1
	git -C "$repo_path" add closed-issue-unproven.txt || rc=1
	git -C "$repo_path" commit -q -m "closed issue unproven branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		gh() {
			if [[ "${1:-}" == "issue" && "${2:-}" == "view" && "${3:-}" == "99029" ]]; then
				printf '%s\n' "CLOSED"
				return 0
			fi
			return 1
		}
		_clean_remove_merged "main" "$repo_path" "false" "" "" "false" ""
	) || rc=1

	local branch_exists=1
	git -C "$repo_path" rev-parse --verify "refs/heads/${branch}" >/dev/null 2>&1 && branch_exists=0
	[[ ! -d "$wt_path" ]] || rc=1
	[[ "$branch_exists" -eq 0 ]] || rc=1
	assert_file_contains "$log_file" "worktree-removed.*closed-issue-branch-preserved.*mode=branch-preserved.*recovery_path=branch-preserved-closed-issue" || rc=1
	print_result "closed issue unproven branch removes worktree and preserves branch" "$rc" \
		"Expected removed worktree, preserved branch, and branch-preserved audit entry"
	return 0
}

test_closed_issue_dirty_unproven_branch_stashes_and_preserves_branch() {
	local repo_path="${TEST_ROOT}/repo-closed-issue-dirty-unproven"
	local wt_path="${TEST_ROOT}/wt-closed-issue-dirty-unproven"
	local log_file="${TEST_ROOT}/closed-issue-dirty-unproven-cleanup.log"
	local branch="feature/auto-20260520-gh99030"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	setup_repo "$repo_path" || rc=1
	git -C "$repo_path" checkout -q -b "$branch" || rc=1
	printf 'closed issue dirty unproven\n' >"$repo_path/closed-issue-dirty-unproven.txt" || rc=1
	git -C "$repo_path" add closed-issue-dirty-unproven.txt || rc=1
	git -C "$repo_path" commit -q -m "closed issue dirty unproven branch" || rc=1
	git -C "$repo_path" checkout -q main || rc=1
	git -C "$repo_path" worktree add -q "$wt_path" "$branch" || rc=1
	printf 'dirty archived state\n' >>"$wt_path/closed-issue-dirty-unproven.txt" || rc=1

	(
		cd "$repo_path" || exit 1
		source_clean_lib_with_stubs || exit 1
		branch_was_pushed() { return 0; }
		_branch_exists_on_any_remote() { return 1; }
		worktree_has_changes() { git -C "$1" status --porcelain 2>/dev/null | grep -q .; return $?; }
		gh() {
			if [[ "${1:-}" == "issue" && "${2:-}" == "view" && "${3:-}" == "99030" ]]; then
				printf '%s\n' "CLOSED"
				return 0
			fi
			return 1
		}
		_clean_remove_merged "main" "$repo_path" "false" "" "" "false" ""
	) || rc=1

	local branch_exists=1 stash_count=0
	git -C "$repo_path" rev-parse --verify "refs/heads/${branch}" >/dev/null 2>&1 && branch_exists=0
	stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ') || stash_count=0
	[[ ! -d "$wt_path" ]] || rc=1
	[[ "$branch_exists" -eq 0 ]] || rc=1
	[[ "$stash_count" -gt 0 ]] || rc=1
	assert_file_contains "$log_file" "worktree-removed.*closed-issue-branch-preserved.*mode=branch-preserved.*recovery_path=branch-preserved-closed-issue" || rc=1
	print_result "closed issue dirty unproven branch stashes and preserves branch" "$rc" \
		"Expected removed worktree, preserved branch, stash archive, and audit entry"
	return 0
}

echo "=== test-worktree-cleanup-branch-merged-owned-skip.sh ==="
test_protected_pass_set_blocks_branch_merged_removal
test_squash_merged_pr_without_ancestor_proof_classifies
test_prefetched_merged_pr_metadata_skips_exact_head_lookup
test_merged_pr_list_passes_explicit_repo_slug
test_deleted_squash_merged_pr_metadata_wins_over_remote_deleted
test_exact_head_merged_pr_proof_wins_when_global_list_misses
test_exact_merged_pr_proof_recovers_unproven_traditional_merge
test_closed_pr_without_ancestor_proof_classifies
test_remote_deleted_without_ancestor_proof_skips
test_closed_issue_unproven_branch_removes_worktree_preserves_branch
test_closed_issue_dirty_unproven_branch_stashes_and_preserves_branch

printf '\nResults: %d/%d passed, %d failed.\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
