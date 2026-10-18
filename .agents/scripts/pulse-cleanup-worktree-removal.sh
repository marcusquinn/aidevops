#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Cleanup Worktree Removal Library
# =============================================================================
# Stable entry point for pulse-cleanup.sh. Dependencies and configuration are
# provided by the pulse-wrapper orchestrator; sourcing this file only loads APIs.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_CLEANUP_WORKTREE_REMOVAL_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_WORKTREE_REMOVAL_LOADED=1

# Keep the cleanup-specific directory: callers may use SCRIPT_DIR themselves.
if [[ -z "${_PULSE_CLEANUP_SCRIPT_DIR:-}" ]]; then
	_pulse_cleanup_worktree_removal_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pulse_cleanup_worktree_removal_path" == "${BASH_SOURCE[0]}" ]] && _pulse_cleanup_worktree_removal_path="."
	_PULSE_CLEANUP_SCRIPT_DIR="$(cd "$_pulse_cleanup_worktree_removal_path" && pwd)"
	unset _pulse_cleanup_worktree_removal_path
fi

# Explicitly clearing the public guard has historically reloaded every function
# and reset library state (including fixture overrides). Keep that contract;
# ordinary repeated sourcing still returns at the public guard above.
unset _PULSE_CLEANUP_WORKTREE_REMOVAL_LIFECYCLE_LOADED \
	_PULSE_CLEANUP_WORKTREE_REMOVAL_CENTRAL_LOADED \
	_PULSE_CLEANUP_WORKTREE_REMOVAL_PROFILE_LOADED

# Lifecycle operations initialize the shared removal/archive constants first.
# shellcheck source=./pulse-cleanup-worktree-removal-lifecycle.sh
# shellcheck disable=SC1091 # Sibling library resolved at runtime
source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-worktree-removal-lifecycle.sh"

# shellcheck source=./pulse-cleanup-worktree-removal-central.sh
# shellcheck disable=SC1091 # Sibling library resolved at runtime
source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-worktree-removal-central.sh"

# shellcheck source=./pulse-cleanup-worktree-removal-profile.sh
# shellcheck disable=SC1091 # Sibling library resolved at runtime
source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-worktree-removal-profile.sh"

# Retain the public pass orchestrator here for source-location contract checks.
cleanup_worktrees() {
	# The caller still owns the hard watchdog. Bounded invocations persist fair
	# progress before each guarded operation so interruption cannot pin the queue.
	local cleanup_budget="${1:-}"
	if [[ -n "$cleanup_budget" ]]; then
		# shellcheck source=./pulse-cleanup-progress.sh
		source "${_PULSE_CLEANUP_SCRIPT_DIR}/pulse-cleanup-progress.sh"
		_pc_cleanup_resumable "$cleanup_budget"
		return $?
	fi
	CLEANUP_WORKTREES_SKIPPED=0
	CLEANUP_WORKTREES_REMOVED_COUNT=0
	CLEANUP_WORKTREES_ARCHIVED_COUNT=0
	CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT=0
	local total_removed=0
	total_removed=$(_pc_cleanup_fixture_passes)
	CLEANUP_WORKTREES_REMOVED_COUNT="$total_removed"
	# GH#18979: Skip cleanup when API rate limit is low — both passes call
	# `gh pr list` per repo/worktree, and blocking rate-limit waits cause
	# the cleanup stage to hang for 10+ minutes, stalling the entire pulse
	# cycle. The cost of skipping one cleanup pass is negligible (worktrees
	# accumulate slowly); the cost of hanging is total pipeline stall.
	local _rl_remaining=""
	_rl_remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null) || _rl_remaining=""
	if [[ "$_rl_remaining" =~ ^[0-9]+$ ]] && [[ "$_rl_remaining" -lt 100 ]]; then
		echo "[pulse-wrapper] Worktree cleanup: skipped — GraphQL rate limit low (${_rl_remaining} remaining)" >>"$LOGFILE"
		CLEANUP_WORKTREES_SKIPPED=1
		return 0
	fi

	# Pass 1: remove worktrees for merged PRs
	local merged_removed
	merged_removed=$(_pc_cleanup_merged_passes)
	total_removed=$((total_removed + merged_removed))

	# Pass 2: age-based orphan cleanup
	local now_epoch
	now_epoch=$(date +%s)

	local repos_json="${HOME}/.config/aidevops/repos.json"
	[[ -f "$repos_json" ]] && command -v jq &>/dev/null || return 0
	_pc_log_local_only_worktree_skips "$repos_json"

	local repo_paths_age
	repo_paths_age=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path // ""' "$repos_json" || echo "")

	local rp_age
	while IFS= read -r rp_age; do
		[[ -z "$rp_age" ]] && continue
		[[ ! -d "$rp_age/.git" ]] && continue

		local main_branch
		main_branch=$(git -C "$rp_age" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || main_branch="main"

		local repo_slug_age
		repo_slug_age=$(git -C "$rp_age" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||') || repo_slug_age=""

		# Parse worktree list — non-porcelain: "path  hash [branch]" per line.
		# Using process substitution (not pipe) so total_removed propagates.
		local wt_line_age
		while IFS= read -r wt_line_age; do
			local wt_path_age
			wt_path_age=$(printf '%s' "$wt_line_age" | awk '{print $1}')
			[[ -z "$wt_path_age" ]] && continue
			[[ "$wt_path_age" == "$rp_age" ]] && continue
			[[ ! -d "$wt_path_age" ]] && continue

			local wt_branch_age=""
			if [[ "$wt_line_age" == *"["*"]"* ]]; then
				wt_branch_age=$(printf '%s' "$wt_line_age" | sed 's/.*\[//;s/\]//')
			fi

			if _cleanup_single_worktree "$rp_age" "$wt_path_age" "$wt_branch_age" \
				"$now_epoch" "$repo_slug_age" "$main_branch"; then
				total_removed=$((total_removed + 1))
			fi
		done < <(git -C "$rp_age" worktree list 2>/dev/null)
		_pc_cleanup_stale_profile_publication_intents "$rp_age" "$now_epoch" || true
	done <<<"$repo_paths_age"
	# Pass 3: registered linked worktrees accidentally created beside canonical
	# repos are moved into the central worktree base instead of cluttering the
	# canonical repo parent.
	local registered_moved
	registered_moved=$(_pc_relocate_registered_worktrees "$repos_json")
	if [[ "$registered_moved" -gt 0 ]]; then
		echo "[pulse-wrapper] Worktree relocation total: $registered_moved worktree(s) moved to central base" >>"$LOGFILE"
	fi

	# Passes 4-5: filesystem outliers, then localdev registration reclaim.
	local orphan_dirs_moved
	orphan_dirs_moved=$(_pc_cleanup_outlier_passes "$repos_json" "$now_epoch")
	total_removed=$((total_removed + orphan_dirs_moved))

	if [[ "$total_removed" -gt 0 ]]; then
		echo "[pulse-wrapper] Worktree cleanup total: $total_removed worktree(s) removed across all repos" >>"$LOGFILE"
	fi
	CLEANUP_WORKTREES_REMOVED_COUNT="$total_removed"

	return 0
}
