#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# full-loop-release-worktree-lib.sh — audited removal for release-owned
# worktrees (GH#35024). Sourced by full-loop-release-helper.sh and
# full-loop-release-reconcile.sh.
#
# Every release, control, stale-control, stale-release and reconcile-tag removal goes
# through the audited fence in audit-worktree-removal-helper.sh: canonical,
# current-directory, Git-lock, active-CWD and managed-lifetime aware, with native
# non-force removal. A refusal preserves the worktree and is logged to
# cleanup_worktrees.log; callers decide whether a refusal is fatal.

[[ "${_FULL_LOOP_RELEASE_WORKTREE_LIB_LOADED:-}" == "1" ]] && return 0
_FULL_LOOP_RELEASE_WORKTREE_LIB_LOADED=1

# shellcheck source=./audit-worktree-removal-helper.sh
source "${BASH_SOURCE[0]%/*}/audit-worktree-removal-helper.sh"

# shellcheck source=./shared-worktree-create.sh
source "${BASH_SOURCE[0]%/*}/shared-worktree-create.sh"

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

# GH#37339: preparation and reconcile-tag checkouts leak like control trees
# (GH#32528) when SIGKILL skips the EXIT trap, and a failed preparation is kept
# for recovery. Capacity cleanup never sees detached trees, so hundreds held the
# worktree cap closed. Recovery only uses the active lane's trees (executor PID,
# source PR, tag) and rebuilds a missing preparation from its snapshot, so other
# dead, idle trees are disposable. The audited non-force fence still preserves
# dirty, locked or in-use trees.
# Args: $1=worktree base, $2=protected executor PID, $3=protected source PR,
#       $4=protected tag version, $5=maximum removal attempts
_full_loop_release_reap_stale_release_worktrees() {
	local worktree_base="$1"
	local protected_pid="$2"
	local protected_pr="$3"
	local protected_version="$4"
	local limit="$5"
	local stale_path="" name="" owner="" stale_pid="" reason=""
	local attempted=0 removed=0
	[[ "$limit" =~ ^[0-9]+$ && -d "$worktree_base" ]] || return 1
	for stale_path in "$worktree_base"/aidevops-release-*; do
		[[ "$attempted" -lt "$limit" ]] || break
		[[ -d "$stale_path" && ! -L "$stale_path" && -f "$stale_path/.git" ]] || continue
		name="${stale_path##*/}"
		if [[ "$name" =~ ^aidevops-release-reconcile-([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)$ ]]; then
			owner="${BASH_REMATCH[1]}" stale_pid="${BASH_REMATCH[2]}" reason="release-reconcile-stale"
			[[ "$owner" != "$protected_version" ]] || continue
		elif [[ "$name" =~ ^aidevops-release-([0-9]+)-([0-9]+)$ ]]; then
			owner="${BASH_REMATCH[1]}" stale_pid="${BASH_REMATCH[2]}" reason="release-preparation-stale"
			[[ "$owner" != "$protected_pr" ]] || continue
		else
			continue
		fi
		[[ "$stale_pid" != "$$" && "$stale_pid" != "$protected_pid" ]] || continue
		kill -0 "$stale_pid" 2>/dev/null && continue
		[[ -n "$(find "$stale_path" -maxdepth 0 -mmin +30 2>/dev/null)" ]] || continue
		attempted=$((attempted + 1))
		_full_loop_release_remove_worktree "$stale_path" "$reason" && removed=$((removed + 1))
	done
	[[ "$attempted" -eq 0 ]] ||
		printf 'Stale release worktrees: removed=%s preserved=%s\n' "$removed" "$((attempted - removed))" >&2
	return 0
}

# Reap only with a readable lane. No lane or an inactive lane protects nothing;
# an unreadable lane, or an active one without a valid executor, reaps nothing.
# Args: $1=owner/repo, $2=maximum removal attempts
_full_loop_release_reap_with_lane() {
	local repo="$1"
	local limit="$2"
	local lane_rc=0 active="" lane=""
	local protected_pid="" protected_pr="" protected_version=""
	release_lane_read "$repo" || lane_rc=$?
	case "$lane_rc" in
	0)
		lane="$_AIDEVOPS_RELEASE_LANE_JSON"
		active=$(jq -r '.active == true' <<<"$lane") || return 0
		if [[ "$active" == "true" ]]; then
			protected_pid=$(jq -er '.executor.pid | select(type == "number" and . > 0 and floor == .)' <<<"$lane") || return 0
			protected_pr=$(jq -er '.source_pr | select(type == "number" and . > 0)' <<<"$lane") || return 0
			protected_version=$(jq -r '.tag // "" | ltrimstr("v")' <<<"$lane") || return 0
		fi
		;;
	2) ;;
	*) return 0 ;;
	esac
	_full_loop_release_reap_stale_release_worktrees "${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}" \
		"$protected_pid" "$protected_pr" "$protected_version" "$limit"
	return $?
}
