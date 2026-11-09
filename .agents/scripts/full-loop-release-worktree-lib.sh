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

# GH#37339: reconcile tag checkouts and preparation checkouts leak when the
# creating process is SIGKILLed (the EXIT trap never runs), and detached trees
# are invisible to capacity cleanup. Reap those whose owner PID is dead and that
# have been idle 30+ minutes, except the active release lane's own trees.
# Args: $1=worktree base, $2=protected PID, $3=protected source PR,
#       $4=protected tag version (no leading v), $5=max removal attempts
# Every removal is non-force through _full_loop_release_remove_worktree.
_full_loop_release_reap_stale_release_worktrees() {
	local worktree_base="$1"
	local protected_pid="${2:-}"
	local protected_pr="${3:-}"
	local protected_version="${4:-}"
	local limit="${5:-10}"
	local stale_path="" name="" owner_pid="" reason="" idle_match=""
	local pr="" version="" attempts=0

	[[ "$limit" =~ ^[0-9]+$ ]] || return 1
	[[ -d "$worktree_base" ]] || return 0
	for stale_path in "$worktree_base"/aidevops-release-*; do
		[[ "$attempts" -lt "$limit" ]] || break
		[[ -d "$stale_path" && ! -L "$stale_path" && -f "$stale_path/.git" ]] || continue
		name="${stale_path##*/}"
		pr=""
		version=""
		if [[ "$name" =~ ^aidevops-release-reconcile-([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)$ ]]; then
			version="${BASH_REMATCH[1]}"
			owner_pid="${BASH_REMATCH[2]}"
			reason="release-reconcile-stale"
		elif [[ "$name" =~ ^aidevops-release-([0-9]+)-([0-9]+)$ ]]; then
			pr="${BASH_REMATCH[1]}"
			owner_pid="${BASH_REMATCH[2]}"
			reason="release-preparation-stale"
		else
			continue
		fi
		[[ "$owner_pid" != "$$" ]] || continue
		[[ -z "$protected_pid" || "$owner_pid" != "$protected_pid" ]] || continue
		[[ -z "$pr" || -z "$protected_pr" || "$pr" != "$protected_pr" ]] || continue
		[[ -z "$version" || -z "$protected_version" || "$version" != "$protected_version" ]] || continue
		kill -0 "$owner_pid" 2>/dev/null && continue
		# Any entry modified within 30 minutes (nested files included) means active.
		idle_match=$(find "$stale_path" -mmin -30 -print -quit 2>/dev/null || true)
		[[ -z "$idle_match" ]] || continue
		# Preserve trees with tracked or untracked changes; never rely on force.
		if [[ -n "$(git -C "$stale_path" status --porcelain 2>/dev/null || true)" ]]; then
			continue
		fi
		attempts=$((attempts + 1))
		_full_loop_release_remove_worktree "$stale_path" "$reason" || true
	done
	return 0
}

# Args: $1=repo slug, $2=max removal attempts
# No lane (rc 2) or an inactive lane protects nothing; any other read failure
# reaps nothing so an unreadable lane can never expose its own trees.
_full_loop_release_reap_with_lane() {
	local repo="$1"
	local limit="${2:-10}"
	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}"
	local read_rc=0
	local protected_pid="" protected_pr="" protected_version=""

	release_lane_read "$repo" || read_rc=$?
	case "$read_rc" in
	0)
		if [[ "$(jq -r '.active' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" 2>/dev/null || true)" == "true" ]]; then
			protected_pid=$(jq -r '.executor.pid // empty | select(type == "number") | tostring' \
				<<<"$_AIDEVOPS_RELEASE_LANE_JSON" 2>/dev/null || true)
			protected_pr=$(jq -r '.source_pr // empty | select(type == "number") | tostring' \
				<<<"$_AIDEVOPS_RELEASE_LANE_JSON" 2>/dev/null || true)
			protected_version=$(jq -r '.tag // empty | select(type == "string") | ltrimstr("v")' \
				<<<"$_AIDEVOPS_RELEASE_LANE_JSON" 2>/dev/null || true)
		fi
		;;
	2) ;;
	*) return 0 ;;
	esac
	_full_loop_release_reap_stale_release_worktrees "$worktree_base" "$protected_pid" \
		"$protected_pr" "$protected_version" "$limit"
	return 0
}
