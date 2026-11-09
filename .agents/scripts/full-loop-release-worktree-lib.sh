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

# GH#37365: control, preparation and reconcile-tag trees are named by, removed
# for and reaped against this executor's PID, so declare it as their lifecycle
# owner in place of an inherited runtime identity. Under an inherited
# interactive owner every release tree stayed waiting-for-runs until that
# long-lived runtime exited, refusing the EXIT trap, the stale reaper and
# registry cleanup alike. The executor's exit now ends the owning run.
# Excluded or unavailable lifecycle hosts clear the declaration (GH#36494).
_full_loop_release_declare_lifecycle_owner() {
	local executor_pid="$$"
	local started_epoch=""
	unset AIDEVOPS_LIFECYCLE_RUNTIME_PID AIDEVOPS_LIFECYCLE_SESSION_ID
	if [[ "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" == 1 || "${AIDEVOPS_PRIVATE_WORKLOAD:-0}" == 1 ]]; then
		return 0
	fi
	command -v python3 >/dev/null 2>&1 || return 0
	# shellcheck source=./worker-lifecycle-state.sh
	source "${BASH_SOURCE[0]%/*}/worker-lifecycle-state.sh" 2>/dev/null || return 0
	[[ -n "$(worker_lifecycle_state_dir 2>/dev/null)" ]] || return 0
	started_epoch=$(date +%s) || return 0
	export AIDEVOPS_LIFECYCLE_RUNTIME_PID="$executor_pid"
	export AIDEVOPS_LIFECYCLE_SESSION_ID="release:${started_epoch}:${executor_pid}"
	return 0
}

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

# GH#37365: this executor owns its tag checkouts until it exits, so lifecycle
# retirement refuses a mid-run reset (waiting-for-caller). The reset retains
# the tree for post-exit retirement; re-preparing the same PID-named path
# re-points that retained tree instead of requiring its removal. Only a linked
# tree of this repository with no tracked, untracked or ignored changes moves.
# Args: $1=repo root, $2=retained worktree path, $3=target commit
_full_loop_release_repoint_tag_worktree() {
	local repo_root="$1"
	local wt_path="$2"
	local target_commit="$3"
	local wt_common="" repo_common="" dirty_state="" head_commit=""
	[[ -f "$wt_path/.git" && ! -L "$wt_path" ]] || return 1
	wt_common=$(cd -- "$wt_path" && cd -- "$(git rev-parse --git-common-dir)" && pwd -P) || return 1
	repo_common=$(cd -- "$repo_root" && cd -- "$(git rev-parse --git-common-dir)" && pwd -P) || return 1
	[[ "$wt_common" == "$repo_common" ]] || return 1
	dirty_state=$(git -C "$wt_path" status --porcelain --ignored) || return 1
	[[ -z "$dirty_state" ]] || return 1
	git -C "$wt_path" checkout --quiet --detach "$target_commit" || return 1
	head_commit=$(git -C "$wt_path" rev-parse HEAD) || return 1
	[[ "$head_commit" == "$target_commit" ]] || return 1
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
	local stale_path="" name="" owner_pid="" reason="" idle_match="" dirty_state=""
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
		# A failed scan or status probe proves nothing, so the tree is kept.
		idle_match=$(find "$stale_path" -mmin -30 -print -quit 2>/dev/null) || continue
		[[ -z "$idle_match" ]] || continue
		# Preserve trees with tracked or untracked changes; never rely on force.
		dirty_state=$(git -C "$stale_path" status --porcelain 2>/dev/null) || continue
		[[ -z "$dirty_state" ]] || continue
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
