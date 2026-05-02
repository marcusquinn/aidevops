#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for pulse cleanup permanent removal guards:
# - current-cwd worktrees are skipped before deletion
# - eligible orphan worktrees are removed permanently and unregistered

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

LOGFILE="${TEST_ROOT}/pulse.log"
export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup_worktrees.log"
UNREGISTER_LOG="${TEST_ROOT}/unregister.log"

# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

is_worktree_owned_by_others() { return 1; }
unregister_worktree() {
	local wt_path="$1"
	printf '%s\n' "$wt_path" >>"$UNREGISTER_LOG"
	return 0
}

# shellcheck source=../pulse-cleanup.sh
source "${SCRIPT_DIR}/pulse-cleanup.sh"

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	exit 1
	return 1
}

pass() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

make_repo_with_worktree() {
	local repo_path="$1"
	local wt_path="$2"
	local branch="$3"

	mkdir -p "$repo_path"
	git -C "$repo_path" init -q -b main
	printf 'base\n' >"${repo_path}/README.md"
	git -C "$repo_path" add README.md
	git -C "$repo_path" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m init
	git -C "$repo_path" worktree add -q -b "$branch" "$wt_path" main
	touch -t 202001010000 "${wt_path}/.git"
	return 0
}

test_current_cwd_skip() {
	local repo_path="${TEST_ROOT}/repo-cwd"
	local wt_path="${TEST_ROOT}/wt-cwd"
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/cwd"

	(
		cd "$wt_path"
		if _cleanup_single_worktree "$repo_path" "$wt_path" "feature/cwd" "$(date +%s)" "" "main"; then
			exit 1
		fi
	)

	[[ -d "$wt_path" ]] || fail "current cwd worktree was removed"
	grep -q 'current-worktree.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" || fail "current-cwd skip was not audited"
	pass "pulse cleanup skips current cwd worktree"
	return 0
}

test_orphan_removal_unregisters() {
	local repo_path="${TEST_ROOT}/repo-remove"
	local wt_path="${TEST_ROOT}/wt-remove"
	make_repo_with_worktree "$repo_path" "$wt_path" "feature/remove"

	_cleanup_single_worktree "$repo_path" "$wt_path" "feature/remove" "$(date +%s)" "" "main" \
		|| fail "eligible orphan worktree was not removed"

	[[ ! -e "$wt_path" ]] || fail "eligible orphan worktree still exists"
	grep -Fxq "$wt_path" "$UNREGISTER_LOG" || fail "worktree unregister was not called"
	grep -q 'age-eligible.*mode=permanent' "$AIDEVOPS_CLEANUP_LOG" || fail "permanent removal was not audited"
	pass "pulse cleanup permanently removes and unregisters eligible orphan"
	return 0
}

test_current_cwd_skip
test_orphan_removal_unregisters

exit 0
