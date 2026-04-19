#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-cleanup.sh — Worktree/stash/zombie-worker cleanup + orphan/stalled worker recovery + stale opencode process cleanup.
#
# Extracted from pulse-wrapper.sh in Phase 5 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants in the bootstrap
# section.
#
# Functions in this module (in source order):
#   Private helpers (called only within this module):
#   - _cleanup_merged_prs_for_all_repos     (Pass 1: merged-PR worktree removal)
#   - _worktree_owner_alive                 (pgrep + registry ownership check)
#   - _worktree_creation_epoch              (stat .git file mtime, with silent-skip logging)
#   - _evaluate_worktree_removal            (age/commit/PR threshold decision)
#   - _record_orphan_crash_classification   (crash type + dedup clearing for orphaned workers)
#   - _cleanup_single_worktree              (per-worktree orchestrator)
#   Public interface (called by pulse-wrapper.sh):
#   - cleanup_worktrees
#   - cleanup_stashes
#   - reap_zombie_workers
#   - recover_failed_launch_state
#   - cleanup_stalled_workers
#   - cleanup_orphans
#   - cleanup_stale_opencode
#
# Phase 12 refactor (t2003 / GH#18451): split cleanup_worktrees() (250 lines)
# into the three private helpers above. Also preserves the GH#18346 fix
# (silent-skip logging) that was applied during Phase 5 extraction — see
# _worktree_owner_alive() and _cleanup_single_worktree() for the two
# previously-silent continue paths that now emit diagnostic log entries.
#
# GH#18704 refactor: split _cleanup_single_worktree() (125 lines) into three
# focused private helpers: _worktree_creation_epoch(),
# _evaluate_worktree_removal(), and _record_orphan_crash_classification().
# The orchestrator now reads as a linear five-step pipeline instead of a
# single flat function. Preserves identical behaviour including the GH#18346
# silent-skip log entry, the GH#16830/t1884 age thresholds, and the crash
# classification rules for "overwhelmed" vs "no_work" workers.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_CLEANUP_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_LOADED=1

#######################################
# Move a path to system trash before permanent deletion (GH#19042).
# Mirrors worktree-helper.sh trash_path() so Pass 2 orphan cleanup gets
# the same recoverability as Pass 1 (which calls worktree-helper.sh clean).
# Prefers: trash CLI (macOS Homebrew), gio trash (Linux), rm -rf fallback.
# Args: $1=path to trash
# Returns 0 on success, 1 on failure.
#######################################
_trash_or_remove() {
	local target="$1"
	[[ -z "$target" ]] && return 1
	[[ ! -e "$target" ]] && return 0

	if command -v trash >/dev/null 2>&1; then
		trash "$target" 2>/dev/null && return 0
	fi
	if command -v gio >/dev/null 2>&1; then
		gio trash "$target" 2>/dev/null && return 0
	fi
	rm -rf "$target" 2>/dev/null && return 0
	return 1
}

#######################################
# Pass 1 helper: remove worktrees for merged/closed PRs across ALL repos
#
# Iterates repos.json (.initialized_repos[]) and runs
# worktree-helper.sh clean --auto --force-merged in each repo directory.
# Echoes the total count of removed worktrees on stdout; returns 0 always.
#
# --force-merged: force-removes dirty worktrees when the PR is confirmed
# merged (dirty state = abandoned WIP from a completed worker).
# Safety: skips worktrees owned by active sessions (handled by
# worktree-helper.sh ownership registry, t189).
#######################################
_cleanup_merged_prs_for_all_repos() {
	local helper="${HOME}/.aidevops/agents/scripts/worktree-helper.sh"
	if [[ ! -x "$helper" ]]; then
		echo 0
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_removed=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		# Iterate all initialized repos — clean worktrees for any repo with
		# a git directory, not just pulse-enabled ones. Workers can create
		# worktrees in any managed repo. Skip local_only repos since
		# worktree-helper.sh uses gh pr list for squash-merge detection.
		local repo_paths
		repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path // ""' "$repos_json" || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			local wt_count
			wt_count=$(git -C "$repo_path" worktree list | wc -l | tr -d ' ')
			# Skip repos with only 1 worktree (the main one) — nothing to clean
			if [[ "${wt_count:-0}" -le 1 ]]; then
				continue
			fi

			# Run helper in a subshell cd'd to the repo (it uses git rev-parse --show-toplevel)
			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" clean --auto --force-merged 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Removing') || count=0
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Worktree cleanup ($repo_name): $count worktree(s) removed" >>"$LOGFILE"
				total_removed=$((total_removed + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo (legacy behaviour)
		local clean_result
		clean_result=$(bash "$helper" clean --auto --force-merged 2>&1) || true
		local fallback_count
		fallback_count=$(echo "$clean_result" | grep -c 'Removing') || fallback_count=0
		if [[ "$fallback_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Worktree cleanup: $fallback_count worktree(s) removed" >>"$LOGFILE"
			total_removed=$((total_removed + fallback_count))
		fi
	fi

	echo "$total_removed"
	return 0
}

#######################################
# Check whether a worktree has an active owner (process or registry).
#
# Two checks in priority order:
#   1. pgrep: any process with the worktree path in its argv.
#   2. Registry: is_worktree_owned_by_others() — covers interactive
#      runtimes (e.g. Claude Code) where the path never appears in argv.
#
# Both silent-skip paths log a diagnostic message (GH#18346 fix):
# previously these paths produced zero log output, making it impossible
# to diagnose why eligible orphan worktrees survived cleanup.
#
# Args:
#   $1 - wt_path: absolute path to the worktree
#   $2 - wt_branch: branch name (for log context; empty = detached)
# Returns: 0 if alive (caller should skip removal), 1 if no active owner
#######################################
_worktree_owner_alive() {
	local wt_path="$1"
	local wt_branch="${2:-}"

	# pgrep check: any process referencing this path in its command line
	if pgrep -f "$wt_path" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Orphan cleanup: skipping ${wt_branch:-detached} ($wt_path) — pgrep matched active process" >>"$LOGFILE"
		return 0
	fi

	# Registry check (GH#18021): covers MCP-dispatch runtimes where the
	# worktree path never appears in process argv.
	if is_worktree_owned_by_others "$wt_path"; then
		echo "[pulse-wrapper] Orphan cleanup: skipping ${wt_branch:-detached} ($wt_path) — registered owner alive in registry" >>"$LOGFILE"
		return 0
	fi

	return 1
}

#######################################
# Get worktree creation epoch from the .git file's mtime.
#
# Linux uses `stat -c '%Y'`; macOS uses `stat -f '%m'`. Writes 0 to stdout
# when the .git file is missing or stat fails, and logs a diagnostic in
# that case (GH#18346: this path was previously a silent continue).
#
# Args:
#   $1 - wt_path: absolute worktree path
#   $2 - wt_branch: branch name (for log context; "" = detached)
# Outputs: epoch seconds on stdout (0 on failure)
# Returns: 0 always (caller inspects the printed value)
#######################################
_worktree_creation_epoch() {
	local wt_path="$1"
	local wt_branch="${2:-}"
	local wt_created=0

	if [[ -f "$wt_path/.git" ]]; then
		wt_created=$(stat -c '%Y' "$wt_path/.git" 2>/dev/null || stat -f '%m' "$wt_path/.git" 2>/dev/null) || wt_created=0
	fi

	if [[ "$wt_created" -eq 0 ]]; then
		# GH#18346: previously a silent skip — now logs the reason
		echo "[pulse-wrapper] Orphan cleanup: skipping ${wt_branch:-detached} ($wt_path) — stat on .git failed (wt_created=0)" >>"$LOGFILE"
	fi

	echo "$wt_created"
	return 0
}

#######################################
# Decide whether a worktree is eligible for orphan cleanup.
#
# Applies the age/commit/PR thresholds from GH#16830 and t1884:
#   0 commits, no open PR, >grace → crashed worker (fast-path)
#   0 commits, clean,      >3h    → empty, safe to remove
#   0 commits, dirty,      >6h    → worker died mid-edit
#   any commits, no PR,    >24h   → abandoned, will be re-dispatched
#
# GitHub queries are only attempted when both repo_slug and branch are
# non-empty. On eligibility the reason string is written to stdout so the
# caller can log it and feed it to crash classification.
#
# Args:
#   $1 - commits_ahead
#   $2 - dirty_count
#   $3 - wt_age_secs
#   $4 - wt_branch_age (may be empty)
#   $5 - repo_slug_age (may be empty)
# Outputs: reason string on stdout when eligible
# Returns: 0 if eligible for removal, 1 otherwise
#######################################
_evaluate_worktree_removal() {
	local commits_ahead="$1"
	local dirty_count="$2"
	local wt_age_secs="$3"
	local wt_branch_age="${4:-}"
	local repo_slug_age="${5:-}"

	# Age thresholds — grace period from config, others hardcoded
	local age_grace="$ORPHAN_WORKTREE_GRACE_SECS"
	local age_3h=$((3 * 3600))
	local age_6h=$((6 * 3600))
	local age_24h=$((24 * 3600))

	# The branches below are mutually exclusive via an elif chain — once the
	# fast-path's outer condition matches (0 commits + past grace), the later
	# branches MUST NOT be checked even if the fast-path decides "not
	# eligible" (e.g. an open PR protects the worktree). Preserving this
	# short-circuit is what keeps worktrees with active PRs alive past 3h.

	# Fast-path: 0 commits + past grace period → crashed worker candidate (t1884)
	if [[ "$commits_ahead" -eq 0 && "$wt_age_secs" -ge "$age_grace" ]]; then
		local has_open_pr=false
		if [[ -n "$repo_slug_age" && -n "$wt_branch_age" ]]; then
			local open_pr_count
			open_pr_count=$(gh pr list --repo "$repo_slug_age" --head "$wt_branch_age" --state open --limit 1 2>/dev/null | wc -l | tr -d ' ') || open_pr_count=0
			[[ "$open_pr_count" -gt 0 ]] && has_open_pr=true
		fi
		if [[ "$has_open_pr" == "false" ]]; then
			echo "0 commits, no open PR, age $((wt_age_secs / 60))m (crashed worker)"
			return 0
		fi
	# 0 commits, clean worktree, >3h → empty (no PR, no dirty state)
	elif [[ "$commits_ahead" -eq 0 && "$dirty_count" -eq 0 && "$wt_age_secs" -ge "$age_3h" ]]; then
		echo "0 commits, clean, age $((wt_age_secs / 3600))h"
		return 0
	# 0 commits, dirty, >6h → worker died mid-edit
	elif [[ "$commits_ahead" -eq 0 && "$dirty_count" -gt 0 && "$wt_age_secs" -ge "$age_6h" ]]; then
		echo "0 commits, ${dirty_count} dirty files, age $((wt_age_secs / 3600))h"
		return 0
	# Has commits, >24h, no PR of any state → abandoned
	elif [[ "$commits_ahead" -gt 0 && "$wt_age_secs" -ge "$age_24h" ]]; then
		local has_pr=false
		if [[ -n "$repo_slug_age" && -n "$wt_branch_age" ]]; then
			local pr_count
			pr_count=$(gh pr list --repo "$repo_slug_age" --head "$wt_branch_age" --state all --limit 1 2>/dev/null | wc -l | tr -d ' ') || pr_count=0
			[[ "$pr_count" -gt 0 ]] && has_pr=true
		fi
		if [[ "$has_pr" == "false" ]]; then
			echo "${commits_ahead} commits, no PR, age $((wt_age_secs / 3600))h"
			return 0
		fi
	fi

	return 1
}

#######################################
# Record crash classification for an orphaned worker worktree.
#
# Extracts the issue number from the branch name (pattern: gh[-]?NNN),
# classifies the crash type, updates failure launch state, logs the
# outcome, and posts a "Worker failed" comment on the issue to clear
# the dispatch dedup guard (t1884, GH#18021).
#
# Classification rules (drive crash-type-aware tier escalation):
#   "overwhelmed": dirty files, OR issue-named branch with no commits.
#                  Model attempted real work but couldn't produce commits.
#                  Pattern: "read files, created worktree, couldn't close the loop".
#   "no_work":     auto-named feature/auto-*-gh<N> branch with clean worktree.
#                  Worker never got past setup — likely infra/transient.
#
# Since GH#19042, feature/auto-* branches include the issue number
# (feature/auto-YYYYMMDD-HHMMSS-gh<N>), so the gh[-]?([0-9]+) regex
# now matches them. Legacy branches without issue numbers are skipped.
#
# Args:
#   $1 - wt_branch_age: branch name (non-empty; caller checks)
#   $2 - dirty_count:   number of dirty files in the worktree
#   $3 - repo_slug_age: owner/repo slug (non-empty; caller checks)
# Returns: 0 always
#######################################
_record_orphan_crash_classification() {
	local wt_branch_age="$1"
	local dirty_count="$2"
	local repo_slug_age="$3"

	local orphan_issue_num=""
	if [[ "$wt_branch_age" =~ gh[-]?([0-9]+) ]]; then
		orphan_issue_num="${BASH_REMATCH[1]}"
	fi
	# Branches without an embedded issue number can't be recovered.
	# Since GH#19042, new feature/auto-* branches include gh<N>, but
	# legacy ones (pre-fix) still lack it — skip those gracefully.
	if [[ -z "$orphan_issue_num" ]]; then
		return 0
	fi

	local orphan_crash_type="no_work"
	if [[ "$dirty_count" -gt 0 ]]; then
		orphan_crash_type="overwhelmed"
	elif [[ "$wt_branch_age" != feature/auto-* ]]; then
		# Issue-named branch = model parsed the issue but produced nothing.
		orphan_crash_type="overwhelmed"
	fi
	# Auto-named branches (feature/auto-*) with 0 dirty files stay as
	# "no_work" — the worker couldn't parse the issue, likely infra.

	recover_failed_launch_state "$orphan_issue_num" "$repo_slug_age" "premature_exit" "$orphan_crash_type"
	echo "[pulse-wrapper] Orphan cleanup: recorded premature_exit for #${orphan_issue_num} (${repo_slug_age}) crash_type=${orphan_crash_type} — triggers fast-fail escalation" >>"$LOGFILE"

	# Post failure comment to clear dedup guard immediately. Without this
	# the dispatch comment blocks re-dispatch for the full TTL even though
	# the worker is dead. "Worker failed" is a recognised completion
	# signal in dispatch-dedup-helper.sh has_dispatch_comment().
	gh issue comment "$orphan_issue_num" --repo "$repo_slug_age" \
		--body "Worker failed: orphan worktree detected (crash_type=${orphan_crash_type}, 0 commits). Cleared for re-dispatch." \
		>/dev/null 2>&1 || true

	return 0
}

#######################################
# Per-worktree age-based orphan cleanup decision and removal.
#
# Thin orchestrator over three private helpers:
#   1. _worktree_creation_epoch      — creation time from .git mtime
#   2. _worktree_owner_alive         — pgrep + registry ownership check
#   3. _evaluate_worktree_removal    — age/commit/PR threshold decision
#   4. _record_orphan_crash_classification — crash type + dedup clearing
#
# On eligible worktrees, performs the git worktree remove + branch delete
# + remote ref delete sequence (t1884, GH#18021).
#
# Args:
#   $1 - rp_age:        repo root path (for git -C commands)
#   $2 - wt_path_age:   absolute worktree path
#   $3 - wt_branch_age: branch name (may be empty for detached HEAD)
#   $4 - now_epoch:     current Unix timestamp (from caller to avoid drift)
#   $5 - repo_slug_age: owner/repo slug for gh API calls (may be empty)
#   $6 - main_branch:   name of the default branch (e.g. "main")
# Returns: 0 if worktree was removed, 1 if skipped
#######################################
_cleanup_single_worktree() {
	local rp_age="$1"
	local wt_path_age="$2"
	local wt_branch_age="$3"
	local now_epoch="$4"
	local repo_slug_age="$5"
	local main_branch="$6"

	# Step 1: creation time (stat .git file mtime; logs on failure)
	local wt_created
	wt_created=$(_worktree_creation_epoch "$wt_path_age" "$wt_branch_age")
	if [[ "$wt_created" -eq 0 ]]; then
		return 1
	fi
	local wt_age_secs=$((now_epoch - wt_created))

	# Step 2: collect commit/dirty state
	local commits_ahead=0
	commits_ahead=$(git -C "$wt_path_age" rev-list --count "HEAD" "^${main_branch}" 2>/dev/null) || commits_ahead=0
	local dirty_count=0
	dirty_count=$(git -C "$wt_path_age" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || dirty_count=0

	# Step 3: skip if an active owner still holds the worktree (GH#18346, GH#18021)
	if _worktree_owner_alive "$wt_path_age" "$wt_branch_age"; then
		return 1
	fi

	# Step 4: evaluate age/commit/PR thresholds for eligibility
	local reason
	if ! reason=$(_evaluate_worktree_removal "$commits_ahead" "$dirty_count" "$wt_age_secs" "$wt_branch_age" "$repo_slug_age"); then
		return 1
	fi
	if [[ -z "$reason" ]]; then
		return 1
	fi

	local repo_name_age
	repo_name_age=$(basename "$rp_age")
	echo "[pulse-wrapper] Orphan cleanup ($repo_name_age): removing ${wt_branch_age:-detached} — $reason" >>"$LOGFILE"

	# Step 5a: crash classification for the fast-path "crashed worker" case
	if [[ "$reason" == *"crashed worker"* && -n "$wt_branch_age" && -n "$repo_slug_age" ]]; then
		_record_orphan_crash_classification "$wt_branch_age" "$dirty_count" "$repo_slug_age"
	fi

	# Step 5b: perform removal (trash worktree dir + deregister + branch cleanup)
	# Move to trash first for recoverability (macOS: trash CLI, Linux: gio trash).
	# Then deregister from git. Falls back to git worktree remove if trash fails.
	_trash_or_remove "$wt_path_age" || git -C "$rp_age" worktree remove --force "$wt_path_age" 2>/dev/null || true
	# Prune git's worktree registry for the now-missing directory
	git -C "$rp_age" worktree prune 2>/dev/null || true
	if [[ -n "$wt_branch_age" ]]; then
		git -C "$rp_age" branch -D "$wt_branch_age" 2>/dev/null || true
		git -C "$rp_age" push origin --delete "$wt_branch_age" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Clean up worktrees for merged/closed PRs and orphaned workers
# across ALL managed repos.
#
# Two-pass approach:
#   Pass 1 (_cleanup_merged_prs_for_all_repos): remove worktrees whose
#           PR has merged. Uses worktree-helper.sh.
#   Pass 2 (_cleanup_single_worktree): age-based orphan cleanup for
#           worktrees that have no PR (crashed/abandoned workers).
#           Age thresholds: >30m no-PR, >3h clean, >6h dirty, >24h commits.
#
# See also: GH#18346 (silent-skip logging fix preserved in helpers above)
#######################################
cleanup_worktrees() {
	# GH#18979: Skip cleanup when API rate limit is low — both passes call
	# `gh pr list` per repo/worktree, and blocking rate-limit waits cause
	# the cleanup stage to hang for 10+ minutes, stalling the entire pulse
	# cycle. The cost of skipping one cleanup pass is negligible (worktrees
	# accumulate slowly); the cost of hanging is total pipeline stall.
	local _rl_remaining=""
	_rl_remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null) || _rl_remaining=""
	if [[ "$_rl_remaining" =~ ^[0-9]+$ ]] && [[ "$_rl_remaining" -lt 100 ]]; then
		echo "[pulse-wrapper] Worktree cleanup: skipped — GraphQL rate limit low (${_rl_remaining} remaining)" >>"$LOGFILE"
		return 0
	fi

	local total_removed=0

	# Pass 1: remove worktrees for merged PRs
	local merged_removed
	merged_removed=$(_cleanup_merged_prs_for_all_repos)
	total_removed=$((total_removed + merged_removed))

	# Pass 2: age-based orphan cleanup
	local now_epoch
	now_epoch=$(date +%s)

	local repos_json="${HOME}/.config/aidevops/repos.json"
	[[ -f "$repos_json" ]] && command -v jq &>/dev/null || return 0

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
	done <<<"$repo_paths_age"

	if [[ "$total_removed" -gt 0 ]]; then
		echo "[pulse-wrapper] Worktree cleanup total: $total_removed worktree(s) removed across all repos" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Clean up safe-to-drop stashes across ALL managed repos (t1417)
#
# Iterates repos.json (.initialized_repos[]) and runs
# stash-audit-helper.sh auto-clean in each repo directory.
# Only drops stashes whose content is already in HEAD — safe
# and deterministic, no judgment needed.
#
# Stashes classified as "needs-review" or "obsolete" are left
# for the LLM hygiene triage (see prefetch_hygiene + pulse.md).
#######################################
cleanup_stashes() {
	local helper="${HOME}/.aidevops/agents/scripts/stash-audit-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_dropped=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local repo_paths
		repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path // ""' "$repos_json" || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			# Skip repos with no stashes
			local stash_count
			stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ')
			if [[ "${stash_count:-0}" -eq 0 ]]; then
				continue
			fi

			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" auto-clean 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Dropped') || count=0
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Stash cleanup ($repo_name): $count stash(es) dropped" >>"$LOGFILE"
				total_dropped=$((total_dropped + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo
		local clean_result
		clean_result=$(bash "$helper" auto-clean 2>&1) || true
		local fallback_count
		fallback_count=$(echo "$clean_result" | grep -c 'Dropped') || fallback_count=0
		if [[ "$fallback_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Stash cleanup: $fallback_count stash(es) dropped" >>"$LOGFILE"
			total_dropped=$((total_dropped + fallback_count))
		fi
	fi

	if [[ "$total_dropped" -gt 0 ]]; then
		echo "[pulse-wrapper] Stash cleanup total: $total_dropped stash(es) dropped across all repos" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Reap zombie workers whose PRs have already been merged (t1751/GH#15489)
#
# Workers don't detect when the deterministic merge pass merges their PR.
# This function runs each pulse cycle (before worker counting) to kill
# workers that are still running after their work is done.
#
# Uses the dispatch ledger session keys (issue-{N}) to find the issue
# number, then checks if a merged PR exists for that issue. If so,
# sends SIGTERM to the worker process tree.
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
reap_zombie_workers() {
	local reaped=0
	local worker_pids worker_key issue_number

	# Get unique session keys from active worker processes
	local session_keys
	session_keys=$(ps aux | grep '[h]eadless-runtime.*--role worker' | grep -v grep |
		sed 's/.*--session-key //' | awk '{print $1}' | sort -u) || return 0

	while IFS= read -r worker_key; do
		[[ -z "$worker_key" ]] && continue
		issue_number="${worker_key#issue-}"
		[[ "$issue_number" =~ ^[0-9]+$ ]] || continue

		# Check dispatch ledger for the repo slug
		local repo_slug=""
		local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
		if [[ -x "$_ledger_helper" ]]; then
			repo_slug=$("$_ledger_helper" get-repo --session-key "$worker_key" 2>/dev/null) || repo_slug=""
		fi
		# Fallback: check all pulse-enabled repos
		if [[ -z "$repo_slug" ]]; then
			repo_slug=$(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false) | .slug // ""' "$REPOS_JSON" | head -1) || continue
		fi
		[[ -n "$repo_slug" ]] || continue

		# Check if a merged PR exists that closes this issue
		local merged_pr
		merged_pr=$(gh pr list --repo "$repo_slug" --state merged --search "closes #${issue_number} OR Closes #${issue_number} OR Resolves #${issue_number} OR resolves #${issue_number}" \
			--limit 1 --json number --jq '.[0].number // ""' 2>/dev/null) || merged_pr=""

		if [[ -n "$merged_pr" ]]; then
			# Kill the worker process tree
			worker_pids=$(ps aux | grep "[h]eadless-runtime.*--session-key ${worker_key}" | grep -v grep | awk '{print $2}')
			if [[ -n "$worker_pids" ]]; then
				echo "[pulse-wrapper] Reaping zombie worker ${worker_key}: PR #${merged_pr} already merged in ${repo_slug}" >>"$LOGFILE"
				echo "$worker_pids" | xargs kill 2>/dev/null || true
				reaped=$((reaped + 1))
			fi
		fi
	done <<<"$session_keys"

	if [[ "$reaped" -gt 0 ]]; then
		echo "[pulse-wrapper] Reaped ${reaped} zombie worker(s) with merged PRs (t1751)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Recover issue state after launch validation failure (t1702)
#
# When launch validation fails, the issue may remain assigned + queued even
# though no worker process exists. This traps capacity by blocking redispatch.
#
# Safety gates:
#   - Only act on OPEN issues
#   - Only act when current GitHub login is assigned on the issue
#   - Only act when issue still has status:queued label
#   - Re-check for a late-started worker before mutating issue state
#
# Actions (best-effort):
#   1. Mark any in-flight ledger entry for this issue as failed
#   2. Remove self assignee and status:queued
#   3. Re-label status:available unless issue is blocked
#
# Args:
#   $1 - issue number
#   $2 - repo slug
#   $3 - failure reason string (for logs)
#######################################
recover_failed_launch_state() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_reason="${3:-launch_validation_failed}"
	local crash_type="${4:-}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 0
	fi

	# Mark in-flight ledger entry as failed even if GitHub claim edits never stuck.
	local ledger_helper
	ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		local ledger_entry session_key
		ledger_entry=$("$ledger_helper" check-issue --issue "$issue_number" --repo "$repo_slug" 2>/dev/null || true)
		session_key=$(printf '%s' "$ledger_entry" | jq -r '.session_key // ""' 2>/dev/null)
		if [[ -n "$session_key" ]]; then
			"$ledger_helper" fail --session-key "$session_key" >/dev/null 2>&1 || true
		fi
	fi

	# For no-worker failures, skip cleanup if a late-started worker appears.
	# For cli_usage_output failures, always continue to clear stale claim state.
	if [[ "$failure_reason" != "cli_usage_output" ]]; then
		if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
			echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): worker appeared after validation failure" >>"$LOGFILE"
			return 0
		fi
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$self_login" ]]; then
		echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): unable to resolve current login" >>"$LOGFILE"
		return 0
	fi

	local issue_meta_json
	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" --json state,labels,assignees 2>/dev/null) || issue_meta_json=""
	if [[ -z "$issue_meta_json" ]]; then
		return 0
	fi

	local issue_state assigned_to_self has_queued is_blocked
	issue_state=$(echo "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null)
	assigned_to_self=$(echo "$issue_meta_json" | jq -r --arg self "$self_login" '([.assignees[].login] | index($self)) != null' 2>/dev/null)
	has_queued=$(echo "$issue_meta_json" | jq -r '([.labels[].name] | index("status:queued")) != null' 2>/dev/null)
	is_blocked=$(echo "$issue_meta_json" | jq -r '([.labels[].name] | index("status:blocked")) != null' 2>/dev/null)

	[[ "$assigned_to_self" == "true" || "$assigned_to_self" == "false" ]] || assigned_to_self="false"
	[[ "$has_queued" == "true" || "$has_queued" == "false" ]] || has_queued="false"
	[[ "$is_blocked" == "true" || "$is_blocked" == "false" ]] || is_blocked="false"

	if [[ "$issue_state" != "OPEN" ]] || [[ "$assigned_to_self" != "true" ]] || [[ "$has_queued" != "true" ]]; then
		return 0
	fi

	# t2033: atomic transitions via set_issue_status. The blocked branch
	# preserves status:blocked (target = "blocked"); the normal branch
	# transitions to status:available.
	if [[ "$is_blocked" == "true" ]]; then
		set_issue_status "$issue_number" "$repo_slug" "blocked" \
			--remove-assignee "$self_login" >/dev/null 2>&1 || true
	else
		set_issue_status "$issue_number" "$repo_slug" "available" \
			--remove-assignee "$self_login" >/dev/null 2>&1 || true
	fi

	# t1934: Unlock issue and linked PRs (locked at dispatch time)
	unlock_issue_after_worker "$issue_number" "$repo_slug"

	# Record the launch failure in the fast-fail counter (t1888)
	# Pass crash_type through to fast_fail_record → escalate_issue_tier
	# for crash-type-aware escalation (overwhelmed = immediate, no_work = default)
	fast_fail_record "$issue_number" "$repo_slug" "$failure_reason" "anthropic" "$crash_type" || true

	# t1959: Wire global circuit breaker for launch-class failures only.
	# Stale timeouts and in-execution failures have their own per-issue backoff
	# and should not trip a global halt. Only true launch failures signal
	# systemic runtime breakage. Recovery happens via record-success on PR merge
	# or issue close (already wired in supervisor) — NEVER reset on launch success.
	case "$failure_reason" in
	no_worker_process | cli_usage_output)
		local cb_helper="${SCRIPT_DIR}/circuit-breaker-helper.sh"
		if [[ -x "$cb_helper" ]]; then
			"$cb_helper" record-failure "${repo_slug}#${issue_number}" "$failure_reason" >/dev/null 2>&1 || true
		fi
		;;
	esac

	echo "[pulse-wrapper] Launch recovery reset #${issue_number} (${repo_slug}) after ${failure_reason} crash_type=${crash_type:-unclassified}: removed self assignee + status:queued" >>"$LOGFILE"
	return 0
}

cleanup_stalled_workers() {
	local killed=0
	local freed_mb=0

	while IFS= read -r line; do
		local pid etime cpu rss cmd
		read -r pid etime cpu rss cmd <<<"$line"

		# Only check headless workers (no TTY, full-loop in command)
		case "$cmd" in
		*"/full-loop"*) ;;
		*) continue ;;
		esac

		# Check process age
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$STALLED_WORKER_MIN_AGE" ]]; then
			continue
		fi

		# Extract issue number and find log file
		local issue_num
		issue_num=$(echo "$cmd" | grep -oE 'issue #[0-9]+' | grep -oE '[0-9]+' | head -1)
		[[ -n "$issue_num" ]] || continue

		local safe_slug log_file log_size
		# Check all pulse-enabled repos for matching log
		local found_log=""
		for safe_slug in $(jq -r '.initialized_repos[] | select(.pulse == true) | .slug // ""' "$REPOS_JSON" | tr '/:' '--'); do
			log_file="/tmp/pulse-${safe_slug}-${issue_num}.log"
			if [[ -f "$log_file" ]]; then
				found_log="$log_file"
				break
			fi
		done
		# Fallback log path
		if [[ -z "$found_log" ]]; then
			log_file="/tmp/pulse-${issue_num}.log"
			[[ -f "$log_file" ]] && found_log="$log_file"
		fi

		if [[ -z "$found_log" ]]; then
			continue
		fi

		# Check log size — stalled workers have ≤500 bytes (just sandbox startup)
		log_size=$(wc -c <"$found_log" 2>/dev/null || echo "0")
		log_size=$(echo "$log_size" | tr -d ' ')
		[[ "$log_size" =~ ^[0-9]+$ ]] || log_size=0

		if [[ "$log_size" -gt "$STALLED_WORKER_MAX_LOG_BYTES" ]]; then
			# Worker has produced real output — it's working, not stalled
			continue
		fi

		# Extract model from the command line for backoff recording
		local worker_model
		worker_model=$(echo "$cmd" | grep -oE '\-m [^ ]+' | head -1 | sed 's/-m //')

		# Kill the stalled worker
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		freed_mb=$((freed_mb + mb))

		# Record provider backoff so next dispatch rotates away
		if [[ -n "$worker_model" ]]; then
			local provider
			provider=$(echo "$worker_model" | cut -d/ -f1)
			local tmp_backoff
			tmp_backoff=$(mktemp)
			printf 'Worker stalled: PID %s, issue #%s, model %s, age %ss, log %s bytes\n' \
				"$pid" "$issue_num" "$worker_model" "$age_seconds" "$log_size" >"$tmp_backoff"

			# Use the headless runtime helper to record backoff properly
			if [[ -x "${SCRIPT_DIR}/headless-runtime-helper.sh" ]]; then
				"${SCRIPT_DIR}/headless-runtime-helper.sh" backoff set "$worker_model" "rate_limit" 900 2>/dev/null || true
			fi
			rm -f "$tmp_backoff"
		fi

		echo "[pulse-wrapper] Killed stalled worker PID $pid (issue #${issue_num}, model=${worker_model:-unknown}, age=${age_seconds}s, log=${log_size}B) — provider likely rate-limited" >>"$LOGFILE"

	done < <(ps axwwo pid,etime,%cpu,rss,command | grep '[.]opencode run' | grep -v grep)

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] cleanup_stalled_workers: killed ${killed} stalled workers (freed ~${freed_mb}MB)" >>"$LOGFILE"
	fi
	# Accumulate into per-cycle health counter (GH#15107)
	_PULSE_HEALTH_STALLED_KILLED=$((_PULSE_HEALTH_STALLED_KILLED + killed))
	return 0
}

cleanup_orphans() {

	local killed=0
	local total_mb=0

	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		# Skip interactive sessions (has a real TTY).
		# Exclude both '?' (Linux headless) and '??' (macOS headless) — only
		# those are headless; anything else (pts/N, ttys00N) is interactive.
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			continue
		fi

		# Skip active workers, pulse, strategic reviews, and language servers.
		# Use case instead of [[ =~ ]] with | alternation — zsh parses the |
		# as a pipe operator inside [[ ]], causing a parse error. See GH#4904.
		case "$cmd" in
		*"/full-loop"* | *"/review-issue-pr"* | *"Supervisor Pulse"* | *"Strategic Review"* | *"language-server"* | *"eslintServer"*)
			continue
			;;
		esac

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]]; then
			continue
		fi

		# This is an orphan — kill it
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axwwo pid,tty,etime,rss,command | grep '[.]opencode' | grep -v 'bash-language-server')

	# Also kill orphaned node launchers (parent of .opencode processes)
	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		[[ "$tty" != "?" && "$tty" != "??" ]] && continue
		# Use case instead of [[ =~ ]] with | alternation — zsh parse error. See GH#4904.
		case "$cmd" in
		*"/full-loop"* | *"/review-issue-pr"* | *"Supervisor Pulse"* | *"Strategic Review"* | *"language-server"* | *"eslintServer"*)
			continue
			;;
		esac

		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		[[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]] && continue

		kill "$pid" 2>/dev/null || true
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axwwo pid,tty,etime,rss,command | grep 'node.*opencode' | grep -v '[.]opencode')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed orphaned opencode processes (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}

cleanup_stale_opencode() {
	local killed=0
	local total_mb=0

	# Get our own PID tree to avoid killing the current session
	local my_pid="$$"
	local my_ppid
	my_ppid=$(ps -p "$my_pid" -o ppid= 2>/dev/null | tr -d ' ') || my_ppid=""

	while IFS= read -r line; do
		local pid cpu rss
		read -r pid cpu rss <<<"$line"

		# Skip our own process tree
		if [[ "$pid" == "$my_pid" || "$pid" == "$my_ppid" ]]; then
			continue
		fi

		# Skip interactive sessions — only kill headless workers.
		# Headless workers are launched via headless-runtime-helper.sh with
		# --format json in the command line. Interactive sessions (user typing
		# in a terminal) never have this flag. Without this guard, any idle
		# interactive session (user stepped away) gets killed along with its
		# parent shell, closing the terminal tab entirely.
		local proc_cmd
		proc_cmd=$(ps -p "$pid" -o command= 2>/dev/null) || proc_cmd=""
		if [[ "$proc_cmd" != *"--format json"* ]]; then
			continue
		fi

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$STALE_OPENCODE_MAX_AGE" ]]; then
			continue
		fi

		# Skip processes with significant CPU usage (actively working)
		# cpu is a float like "0.0" or "40.3" — compare integer part
		local cpu_int
		cpu_int="${cpu%%.*}"
		[[ "$cpu_int" =~ ^[0-9]+$ ]] || cpu_int=0
		if [[ "$cpu_int" -ge "$PULSE_IDLE_CPU_THRESHOLD" ]]; then
			continue
		fi

		# This is a stale headless worker — kill it and its parent chain
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))

		# Kill parent (node launcher) and grandparent (zsh tab) first
		local ppid
		ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || ppid=""
		if [[ -n "$ppid" && "$ppid" != "1" ]]; then
			local gppid
			gppid=$(ps -p "$ppid" -o ppid= 2>/dev/null | tr -d ' ') || gppid=""
			# Kill grandparent zsh (the terminal tab shell)
			if [[ -n "$gppid" && "$gppid" != "1" ]]; then
				local gp_cmd
				gp_cmd=$(ps -p "$gppid" -o command= 2>/dev/null) || gp_cmd=""
				# Only kill if it's a shell that launched opencode
				case "$gp_cmd" in
				*zsh* | *bash* | *sh*)
					kill "$gppid" 2>/dev/null || true
					;;
				esac
			fi
			# Kill parent node launcher
			kill "$ppid" 2>/dev/null || true
		fi

		# Kill the .opencode process — SIGTERM first, SIGKILL fallback.
		# OpenCode's file watcher may ignore SIGTERM.
		kill "$pid" 2>/dev/null || true
		sleep 1
		if kill -0 "$pid" 2>/dev/null; then
			kill -9 "$pid" 2>/dev/null || true
		fi
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axwwo pid,%cpu,rss,command | awk '$0 ~ /[.]opencode/ && $0 !~ /bash-language-server/ { print $1, $2, $3 }')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed stale headless opencode workers (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}
