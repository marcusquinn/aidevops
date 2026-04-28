#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
# =============================================================================
# Worktree Clean Library — Merged-branch worktree cleanup helpers
# =============================================================================
# Functions for detecting and removing worktrees whose branches have been
# merged, squash-merged, remote-deleted, or abandoned (closed PR).
#
# Extracted from worktree-helper.sh (GH#21409) to reduce the orchestrator
# below the 2000-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/worktree-clean-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (colour vars, register/unregister_worktree, etc.)
#   - audit-worktree-removal-helper.sh (log_worktree_removal_event, _WTAR_*)
#     Must be sourced by the orchestrator before this library is loaded.
#   - worktree-helper.sh helper functions (resolved at call time):
#       worktree_has_changes, trash_path, branch_was_pushed,
#       _branch_exists_on_any_remote, get_default_branch,
#       localdev_auto_branch_rm, assert_git_available,
#       assert_main_worktree_sane
#   - _WTAR_WH_CALLER must be set in the orchestrator before calling any
#     function in this library.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKTREE_CLEAN_LIB_LOADED:-}" ]] && return 0
_WORKTREE_CLEAN_LIB_LOADED=1

# SCRIPT_DIR fallback — covers sourcing from test harnesses or direct invocation
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

get_validated_grace_hours() {
	local grace_hours="${WORKTREE_CLEAN_GRACE_HOURS:-4}"

	# Check if it's a valid positive integer
	if [[ "$grace_hours" =~ ^[0-9]+$ ]] && [[ "$grace_hours" -gt 0 ]]; then
		echo "$grace_hours"
		return 0
	fi

	# Invalid value - warn and use default
	echo -e "${YELLOW}Warning: WORKTREE_CLEAN_GRACE_HOURS='$grace_hours' is invalid, using default 4 hours${NC}" >&2
	echo "4"
	return 0
}

# Check if a worktree directory is younger than the grace period.
# Returns 0 (true) if the worktree is within the grace period, 1 (false) if old enough to clean.
# Grace period defaults to WORKTREE_CLEAN_GRACE_HOURS (default: 4 hours).
# Uses directory mtime as a proxy for creation time (set at worktree creation).
# Bash 3.2 compatible — no associative arrays, no bash 4+ features.
worktree_is_in_grace_period() {
	local wt_path="${1:-}"
	local grace_hours
	grace_hours=$(get_validated_grace_hours)
	[[ -z "$wt_path" ]] && return 1
	[[ ! -d "$wt_path" ]] && return 1

	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || return 1

	local dir_mtime
	# macOS: stat -f %m; Linux: stat -c %Y
	if stat -f %m "$wt_path" >/dev/null 2>&1; then
		dir_mtime=$(stat -f %m "$wt_path" 2>/dev/null) || return 1
	elif stat -c %Y "$wt_path" >/dev/null 2>&1; then
		dir_mtime=$(stat -c %Y "$wt_path" 2>/dev/null) || return 1
	else
		# Cannot determine mtime — fail safe (treat as in grace period)
		return 0
	fi

	local age_seconds=$((now_epoch - dir_mtime))
	local grace_seconds=$((grace_hours * 3600))

	if [[ "$age_seconds" -lt "$grace_seconds" ]]; then
		return 0 # Within grace period
	fi
	return 1 # Outside grace period
}

# Check if a branch has an open PR on any remote.
# Returns 0 (true) if an open PR exists, 1 (false) otherwise.
# Requires gh CLI. Returns 0 (skip deletion) if gh is unavailable or fails.
branch_has_open_pr() {
	local branch="${1:-}"
	[[ -z "$branch" ]] && return 1
	command -v gh &>/dev/null || return 0

	local open_count
	if ! open_count=$(gh pr list --state open --head "$branch" --json number --jq 'length' 2>/dev/null); then
		# gh command failed - return 0 to skip deletion (safety-first)
		return 0
	fi
	[[ "$open_count" -gt 0 ]] && return 0
	return 1
}

# Check if a branch has zero commits ahead of the default branch.
# A branch with 0 commits ahead looks "merged" to git branch --merged but may
# just be a freshly created worktree with no commits yet.
# Returns 0 (true) if zero commits ahead, 1 (false) if has commits.
branch_has_zero_commits_ahead() {
	local branch="${1:-}"
	local default_br="${2:-}"
	[[ -z "$branch" ]] && return 1
	[[ -z "$default_br" ]] && return 1

	local ahead_count
	ahead_count=$(git rev-list --count "refs/heads/$default_br..refs/heads/$branch" 2>/dev/null || echo "1")
	[[ "$ahead_count" -eq 0 ]] && return 0
	return 1
}

# Check if a worktree should be skipped during cleanup due to safety constraints.
# Returns 0 (true) if worktree should be skipped, 1 (false) if safe to remove.
# Args: $1=worktree_path, $2=worktree_branch, $3=default_branch, $4=open_pr_branches, $5=force_merged
# Prints skip reason to stdout if skipping.
should_skip_cleanup() {
	local wt_path="$1"
	local wt_branch="$2"
	local default_br="$3"
	local open_pr_list="$4"
	local force_merged_flag="$5"

	# Ownership check (t189): skip if owned by another active session
	if is_worktree_owned_by_others "$wt_path"; then
		local owner_info
		owner_info=$(check_worktree_owner "$wt_path")
		local owner_pid
		owner_pid="${owner_info%%|*}"
		echo -e "  ${RED}$wt_branch${NC} (owned by active session PID $owner_pid - skipping)"
		echo "    $wt_path"
		echo ""
		# t2976: audit log — cleanup skipped, registry owner is alive
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "owned-skip"
		return 0
	fi

	# GH#5694 Safety check A: Grace period
	# Skip worktrees younger than WORKTREE_CLEAN_GRACE_HOURS (default 4h).
	# A freshly created worktree with 0 commits looks "merged" to git branch --merged.
	# The grace period prevents deletion of in-progress work that hasn't been committed yet.
	if worktree_is_in_grace_period "$wt_path"; then
		local grace_hours
		grace_hours=$(get_validated_grace_hours)
		echo -e "  ${RED}$wt_branch${NC} (within grace period ${grace_hours}h - skipping)"
		echo "    $wt_path"
		echo ""
		# t2976: audit log — cleanup skipped, within grace period
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "grace-period"
		return 0
	fi

	# GH#5694 Safety check B: Open PR
	# Skip worktrees whose branch has an open PR — active work in progress.
	# This applies even with --force-merged: an open PR means the work is not done.
	if [[ -n "$open_pr_list" ]] && echo "$open_pr_list" | grep -Fxq "$wt_branch"; then
		echo -e "  ${RED}$wt_branch${NC} (has open PR - skipping)"
		echo "    $wt_path"
		echo ""
		# t2976: audit log — cleanup skipped, open PR exists
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "open-pr"
		return 0
	fi

	# GH#5694 Safety check C: Zero-commit + dirty
	# A branch with 0 commits ahead of default AND uncommitted changes is in-progress,
	# not truly merged. git branch --merged treats 0-commit branches as merged because
	# they share the same HEAD as the default branch.
	if worktree_has_changes "$wt_path" && branch_has_zero_commits_ahead "$wt_branch" "$default_br"; then
		echo -e "  ${RED}$wt_branch${NC} (0 commits ahead + dirty files = in-progress, not merged - skipping)"
		echo "    $wt_path"
		echo ""
		# t2976: audit log — cleanup skipped, zero-commit+dirty safety check
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "zero-commit-dirty"
		return 0
	fi

	# Dirty check: behaviour depends on --force-merged flag
	# Only reached if the three safety checks above did not trigger.
	if worktree_has_changes "$wt_path"; then
		if [[ "$force_merged_flag" != "true" ]]; then
			echo -e "  ${RED}$wt_branch${NC} (has uncommitted changes - skipping)"
			echo "    $wt_path"
			echo ""
			# t2976: audit log — cleanup skipped, uncommitted changes present
			log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$wt_path" "dirty-skip"
			return 0
		fi
		# force_merged=true: dirty state is abandoned WIP, safe to force-remove
	fi

	# All safety checks passed
	return 1
}

# Fetch and prune all remotes. Sets remote_state_unknown=true in caller's scope on failure.
# Prints warnings for failed remotes. Returns 0 always (failures are non-fatal).
# Args: none. Modifies caller's remote_state_unknown variable via echo to a temp file.
# Usage: remote_state_unknown=$(_clean_fetch_remotes)
_clean_fetch_remotes() {
	local state_unknown=false
	local remote
	# GH#18979: Apply a 10-second timeout per remote fetch. In pulse cleanup
	# context, git fetch --prune can hang indefinitely on network I/O or
	# slow remote negotiation with many branches, stalling the entire pulse
	# cycle. 10s is generous for a prune-only fetch; if it exceeds that,
	# the remote is unreachable and we should treat state as unknown.
	local fetch_timeout_cmd=""
	if command -v gtimeout &>/dev/null; then
		fetch_timeout_cmd="gtimeout 10"
	elif command -v timeout &>/dev/null; then
		fetch_timeout_cmd="timeout 10"
	fi
	for remote in $(git remote 2>/dev/null); do
		if [[ -n "$fetch_timeout_cmd" ]]; then
			if ! $fetch_timeout_cmd git fetch --prune "$remote" 2>/dev/null; then
				echo -e "${YELLOW}Warning: failed to refresh $remote; skipping remote-deleted cleanup checks${NC}" >&2
				state_unknown=true
			fi
		else
			# No timeout command available — run unguarded but with a background kill
			git fetch --prune "$remote" 2>/dev/null &
			local _fetch_pid=$!
			local _fetch_waited=0
			while kill -0 "$_fetch_pid" 2>/dev/null && [[ "$_fetch_waited" -lt 10 ]]; do
				sleep 1
				_fetch_waited=$((_fetch_waited + 1))
			done
			if kill -0 "$_fetch_pid" 2>/dev/null; then
				kill "$_fetch_pid" 2>/dev/null || true
				wait "$_fetch_pid" 2>/dev/null || true
				echo -e "${YELLOW}Warning: fetch timed out for $remote; skipping remote-deleted cleanup checks${NC}" >&2
				state_unknown=true
			else
				wait "$_fetch_pid" 2>/dev/null || state_unknown=true
			fi
		fi
	done
	echo "$state_unknown"
	return 0
}

# Build newline-delimited lists of merged and open PR branch names via gh CLI.
# Outputs two lines: merged_branches and open_branches (each may be empty).
# Caller splits on a delimiter. Returns 0 always.
# Usage: _clean_build_pr_lists; merged_pr_branches=...; open_pr_branches=...
_clean_build_merged_pr_branches() {
	if command -v gh &>/dev/null; then
		gh pr list --state merged --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null || true
	fi
	return 0
}

_clean_build_open_pr_branches() {
	if command -v gh &>/dev/null; then
		gh pr list --state open --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null || true
	fi
	return 0
}

# Build newline-delimited list of CLOSED (abandoned, not merged) PR branch names.
# These are PRs that were closed without merging — the work is abandoned and the
# worktree is safe to remove. The remote branch may still exist if auto-delete
# only fires on merge.
_clean_build_closed_pr_branches() {
	if command -v gh &>/dev/null; then
		gh pr list --state closed --limit 200 --json headRefName,mergedAt --jq '[.[] | select(.mergedAt == null)] | .[].headRefName' 2>/dev/null || true
	fi
	return 0
}

# Determine if a worktree entry is merged, and print it if so.
# Args: $1=wt_path, $2=wt_branch, $3=default_branch, $4=remote_state_unknown,
#       $5=merged_pr_branches, $6=open_pr_branches, $7=force_merged,
#       $8=closed_pr_branches
# Outputs the merge_type to stdout if merged (caller checks non-empty).
_clean_classify_worktree() {
	local wt_path="$1"
	local wt_branch="$2"
	local default_br="$3"
	local remote_unknown="$4"
	local merged_prs="$5"
	local open_prs="$6"
	local force_merged="$7"
	local closed_prs="${8:-}"

	local is_merged=false
	local merge_type=""

	# Check 1: Traditional merge detection
	if git branch --merged "$default_br" 2>/dev/null | grep -q "^\s*$wt_branch$"; then
		is_merged=true
		merge_type="merged"
	# Check 2: Remote branch deleted (indicates squash merge or PR closed)
	# ONLY check this if the branch was previously pushed - unpushed branches should NOT be flagged
	# Check all remotes, not just origin (consistent with branch_was_pushed)
	# Skip if fetch failed — stale refs could cause false-positive deletion
	elif [[ "$remote_unknown" == "false" ]] && branch_was_pushed "$wt_branch" && ! _branch_exists_on_any_remote "$wt_branch"; then
		is_merged=true
		merge_type="remote deleted"
	# Check 3: Squash-merge detection via GitHub PR state
	# GitHub squash merges create a new commit — the original branch is NOT
	# an ancestor of the target, so git branch --merged misses it. The remote
	# branch may still exist if "auto-delete head branches" is off.
	# grep -Fxq: exact fixed-string line match (no regex injection risk).
	elif [[ -n "$merged_prs" ]] && echo "$merged_prs" | grep -Fxq "$wt_branch"; then
		is_merged=true
		merge_type="squash-merged PR"
	# Check 4: Closed (abandoned) PR — PR was closed without merging.
	# The remote branch may still exist (auto-delete only fires on merge).
	# Work is abandoned; worktree is safe to remove.
	elif [[ -n "$closed_prs" ]] && echo "$closed_prs" | grep -Fxq "$wt_branch"; then
		is_merged=true
		merge_type="closed PR"
	fi

	if [[ "$is_merged" == "false" ]]; then
		return 0
	fi

	# Apply safety checks using shared helper
	if should_skip_cleanup "$wt_path" "$wt_branch" "$default_br" "$open_prs" "$force_merged"; then
		return 0
	fi

	if worktree_has_changes "$wt_path" && [[ "$force_merged" == "true" ]]; then
		# PR is confirmed merged — dirty state is abandoned WIP, safe to force-remove
		merge_type="$merge_type, dirty (force)"
	fi

	echo "$merge_type"
	return 0
}

# Scan worktrees and print those eligible for cleanup. Returns 0 if any found, 1 if none.
# Args: $1=default_branch, $2=main_worktree_path, $3=remote_state_unknown,
#       $4=merged_pr_branches, $5=open_pr_branches, $6=force_merged,
#       $7=closed_pr_branches
_clean_scan_merged() {
	local default_br="$1"
	local main_wt_path="$2"
	local remote_unknown="$3"
	local merged_prs="$4"
	local open_prs="$5"
	local force_merged="$6"
	local closed_prs="${7:-}"

	local found_any=false
	local worktree_path=""
	local worktree_branch=""

	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			worktree_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			worktree_branch="${BASH_REMATCH[1]}"
		elif [[ -z "$line" ]]; then
			if [[ -n "$worktree_branch" ]] && [[ "$worktree_branch" != "$default_br" ]] && [[ "$worktree_path" != "$main_wt_path" ]]; then
				local merge_type
				merge_type=$(_clean_classify_worktree "$worktree_path" "$worktree_branch" "$default_br" "$remote_unknown" "$merged_prs" "$open_prs" "$force_merged" "$closed_prs")
				if [[ -n "$merge_type" ]]; then
					found_any=true
					echo -e "  ${YELLOW}$worktree_branch${NC} ($merge_type)" >&2
					echo "    $worktree_path" >&2
					echo "" >&2
				fi
			fi
			worktree_path=""
			worktree_branch=""
		fi
	done < <(
		git worktree list --porcelain
		echo ""
	)

	[[ "$found_any" == "true" ]] && return 0
	return 1
}

# Remove worktrees that are eligible for cleanup (second pass after user confirmation).
# Args: $1=default_branch, $2=main_worktree_path, $3=remote_state_unknown,
#       $4=merged_pr_branches, $5=open_pr_branches, $6=force_merged,
#       $7=closed_pr_branches
_clean_remove_merged() {
	local default_br="$1"
	local main_wt_path="$2"
	local remote_unknown="$3"
	local merged_prs="$4"
	local open_prs="$5"
	local force_merged="$6"
	local closed_prs="${7:-}"

	local worktree_path=""
	local worktree_branch=""

	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			worktree_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			worktree_branch="${BASH_REMATCH[1]}"
		elif [[ -z "$line" ]]; then
			if [[ -n "$worktree_branch" ]] && [[ "$worktree_branch" != "$default_br" ]] && [[ "$worktree_path" != "$main_wt_path" ]]; then
				local merge_type
				merge_type=$(_clean_classify_worktree "$worktree_path" "$worktree_branch" "$default_br" "$remote_unknown" "$merged_prs" "$open_prs" "$force_merged" "$closed_prs")
				if [[ -n "$merge_type" ]]; then
					local use_force=false
					if worktree_has_changes "$worktree_path" && [[ "$force_merged" == "true" ]]; then
						use_force=true
					fi
				echo -e "${BLUE}Removing $worktree_branch...${NC}" >&2
				# Clean up heavy reproducible directories first to speed up removal
					# (node_modules, .next, .turbo can have 100k+ files — rm -rf is faster than trash)
					rm -rf "$worktree_path/node_modules" 2>/dev/null || true
					rm -rf "$worktree_path/.next" 2>/dev/null || true
					rm -rf "$worktree_path/.turbo" 2>/dev/null || true
					# Move entire worktree to trash for recoverability, then prune git's registry.
					# Falls back to git worktree remove if trash is unavailable.
					local removed=false
					if trash_path "$worktree_path"; then
						git worktree prune 2>/dev/null || true
						removed=true
					else
						local remove_flag=""
						if [[ "$use_force" == "true" ]]; then
							remove_flag="--force"
						fi
						# shellcheck disable=SC2086
						if git worktree remove $remove_flag "$worktree_path" 2>/dev/null; then
							removed=true
						fi
					fi
				if [[ "$removed" != "true" ]]; then
					echo -e "${RED}Failed to remove $worktree_branch - may have uncommitted changes${NC}" >&2
				else
						# Unregister ownership (t189)
						unregister_worktree "$worktree_path"
						# t2976: audit log — merged/closed branch worktree removed
						log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_WH_CALLER" "$worktree_path" "branch-merged"
						# Localdev integration (t1224.8): auto-remove branch route
						localdev_auto_branch_rm "$worktree_branch"
						# Also delete the local branch
						git branch -D "$worktree_branch" 2>/dev/null || true
					fi
				fi
			fi
			worktree_path=""
			worktree_branch=""
		fi
	done < <(
		git worktree list --porcelain
		echo ""
	)

	return 0
}

# Clean up worktrees whose branches have been merged, remote-deleted, or squash-merged.
# Supports --auto (non-interactive) and --force-merged (skip confirmation for merged).
# Safety checks (GH#5694):
#   - Grace period: worktrees younger than WORKTREE_CLEAN_GRACE_HOURS (default 4h) are skipped
#   - Open PR check: worktrees with an open PR are skipped (active work in progress)
#   - Zero-commit + dirty check: branch with 0 commits ahead AND dirty files = in-progress, not merged
# t2559: preflight guard for cmd_clean. Combines L1 (empty-derivation),
# L2 (sane main-worktree-path), and L3 (git-in-PATH) into a single entry point.
# On success, prints the validated main_worktree_path to stdout and returns 0.
# On any failure, prints the reason to stderr and returns 1 so cmd_clean can
# refuse to touch any filesystem state.
#
# Extracted to keep cmd_clean body under the 100-line complexity threshold
# while preserving all four defensive layers from the 2026-04-20 incident.
_clean_preflight_main_worktree() {
	# L3: refuse to run cleanup at all if git is missing from PATH.
	# Without git, the worktree-list derivation below returns empty, and the
	# downstream `[[ "$worktree_path" != "$main_wt_path" ]]` guard reduces to
	# "!= empty" — always true for real paths — and canonical gets swept.
	if command -v assert_git_available >/dev/null 2>&1; then
		if ! assert_git_available; then
			echo -e "${RED}Refusing worktree cleanup — git not in PATH${NC}" >&2
			return 1
		fi
	fi

	# L1: derive main worktree path from porcelain; fail loud on empty output.
	# The first entry in `git worktree list --porcelain` is always the main
	# worktree. Avoid piping through head — with set -o pipefail and many
	# worktrees, head closes the pipe early → git SIGPIPE (exit 141) →
	# pipefail → set -e abort.
	local _porcelain main_worktree_path
	_porcelain=$(git worktree list --porcelain)
	if [[ -z "$_porcelain" ]]; then
		echo -e "${RED}FATAL: 'git worktree list --porcelain' returned empty — refusing cleanup${NC}" >&2
		return 1
	fi
	main_worktree_path="${_porcelain%%$'\n'*}"           # first line
	main_worktree_path="${main_worktree_path#worktree }" # strip prefix

	# L2: validate the extracted path is sane (non-empty, absolute) before
	# handing it to cleanup loops as the "never trash this" anchor.
	if command -v assert_main_worktree_sane >/dev/null 2>&1; then
		if ! assert_main_worktree_sane "$main_worktree_path"; then
			echo -e "${RED}Refusing worktree cleanup — main_worktree_path derivation is not sane${NC}" >&2
			return 1
		fi
	elif [[ -z "$main_worktree_path" || "${main_worktree_path:0:1}" != "/" ]]; then
		# Fallback when canonical-guard-helper is missing: still refuse to run.
		echo -e "${RED}FATAL: derived main_worktree_path is empty or non-absolute: '$main_worktree_path'${NC}" >&2
		return 1
	fi

	printf '%s\n' "$main_worktree_path"
	return 0
}

cmd_clean() {
	local auto_mode=false
	local force_merged=false
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--auto) auto_mode=true ;;
		--force-merged) force_merged=true ;;
		*) break ;;
		esac
		shift
	done

	# t2559: run the combined L1+L2+L3 preflight. On any refusal, bail before
	# touching filesystem state. This is the primary defence against the
	# 2026-04-20 canonical-trash incident (see _clean_preflight_main_worktree).
	local main_worktree_path
	if ! main_worktree_path=$(_clean_preflight_main_worktree); then
		return 1
	fi

	echo -e "${BOLD}Checking for worktrees with merged branches...${NC}" >&2
	echo "" >&2

	local default_branch
	default_branch=$(get_default_branch)

	# Fetch to get current remote branch state (detects deleted branches)
	# Prune all remotes, not just origin (GH#3797)
	local remote_state_unknown
	remote_state_unknown=$(_clean_fetch_remotes)

	# Build PR branch lists for squash-merge detection and open-PR safety check.
	# NOTE: bash 3.2 (macOS default) lacks declare -A — do NOT use associative arrays.
	local merged_pr_branches
	merged_pr_branches=$(_clean_build_merged_pr_branches)

	local open_pr_branches
	open_pr_branches=$(_clean_build_open_pr_branches)

	# Closed (abandoned) PRs: closed without merging. Remote branch may linger
	# because auto-delete only fires on merge.
	local closed_pr_branches
	closed_pr_branches=$(_clean_build_closed_pr_branches)

	# First pass: scan and display merged worktrees
	if ! _clean_scan_merged "$default_branch" "$main_worktree_path" "$remote_state_unknown" "$merged_pr_branches" "$open_pr_branches" "$force_merged" "$closed_pr_branches"; then
		echo -e "${GREEN}No merged worktrees to clean up${NC}" >&2
		return 0
	fi

	local response="n"
	if [[ "$auto_mode" == "true" ]]; then
		response="y"
	else
		echo "" >&2
		echo -e "${YELLOW}Remove these worktrees? [y/N]${NC}" >&2
		read -r response
	fi

	if [[ "$response" =~ ^[Yy]$ ]]; then
		# Second pass: remove merged worktrees
		_clean_remove_merged "$default_branch" "$main_worktree_path" "$remote_state_unknown" "$merged_pr_branches" "$open_pr_branches" "$force_merged" "$closed_pr_branches"
		echo -e "${GREEN}Cleanup complete${NC}" >&2
	else
		echo "Cancelled" >&2
	fi

	return 0
}
