#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# full-loop-release-worktree-lib.sh — audited removal for release-owned
# worktrees (GH#35024). Sourced by full-loop-release-helper.sh and
# full-loop-release-reconcile.sh.
#
# Every release, control, stale-control and reconcile-tag worktree removal goes
# through the audited fence in audit-worktree-removal-helper.sh: canonical,
# current-directory, Git-lock, active-CWD and managed-lifetime aware, with native
# non-force removal. A refusal preserves the worktree and is logged to
# cleanup_worktrees.log; callers decide whether a refusal is fatal.

[[ "${_FULL_LOOP_RELEASE_WORKTREE_LIB_LOADED:-}" == "1" ]] && return 0
_FULL_LOOP_RELEASE_WORKTREE_LIB_LOADED=1

# shellcheck source=./audit-worktree-removal-helper.sh
source "${BASH_SOURCE[0]%/*}/audit-worktree-removal-helper.sh"

_FULL_LOOP_RELEASE_CALLER="full-loop-release-helper.sh"

# Args: $1=worktree path, $2=short audit reason
# Returns: 0 when the path is absent afterwards, 1 when preserved
_full_loop_release_remove_worktree() {
	local wt_path="$1"
	local reason="$2"
	[[ -n "$wt_path" ]] || return 1
	[[ -e "$wt_path" || -L "$wt_path" ]] || return 0
	remove_worktree_path_permanently "$wt_path" "$_FULL_LOOP_RELEASE_CALLER" "$reason" \
		"release_worktree=${reason}" || return 1
	return 0
}
