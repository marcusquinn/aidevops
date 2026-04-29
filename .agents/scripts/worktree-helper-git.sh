#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155
# =============================================================================
# Worktree Helper -- Git Utilities Sub-Library
# =============================================================================
# Core git query helpers and stale remote branch detection/handling.
# These functions are used across multiple commands (add, list, status, clean).
#
# Usage: source "${SCRIPT_DIR}/worktree-helper-git.sh"
#
# Dependencies:
#   - shared-constants.sh (colour vars, print_* helpers)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKTREE_GIT_LIB_LOADED:-}" ]] && return 0
_WORKTREE_GIT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Git Query Helpers ---

get_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || echo ""
}

# Get the repository name (basename of the repo root directory).
get_repo_name() {
	local root
	root=$(get_repo_root)
	if [[ -n "$root" ]]; then
		basename "$root"
	fi
}

# Get the current branch name, or empty string if detached/unavailable.
get_current_branch() {
	git branch --show-current 2>/dev/null || echo ""
}

# Get the default branch (main or master) (GH#3797)
# Checks all remotes for HEAD, preferring origin first.
get_default_branch() {
	# Try origin first, then any other remote HEAD
	local default_branch=""
	local remote
	default_branch=$(git symbolic-ref "refs/remotes/origin/HEAD" 2>/dev/null | sed 's@^refs/remotes/origin/@@')
	if [[ -n "$default_branch" ]]; then
		echo "$default_branch"
		return 0
	fi
	for remote in $(git remote 2>/dev/null); do
		[[ "$remote" == "origin" ]] && continue
		default_branch=$(git symbolic-ref "refs/remotes/${remote}/HEAD" 2>/dev/null | sed "s@^refs/remotes/${remote}/@@")
		if [[ -n "$default_branch" ]]; then
			echo "$default_branch"
			return 0
		fi
	done

	# Fallback: check if main or master exists
	if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
		echo "main"
	elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
		echo "master"
	else
		# Last resort default
		echo "main"
	fi
}

# Check if the current directory is the main (non-linked) worktree.
# Returns 0 if main worktree, 1 if linked worktree.
is_main_worktree() {
	local git_dir
	git_dir=$(git rev-parse --git-dir 2>/dev/null)
	# Main worktree has .git as a directory, linked worktrees have .git as a file
	[[ -d "$git_dir" ]] && [[ "$git_dir" == ".git" || "$git_dir" == "$(get_repo_root)/.git" ]]
}

# List remote-tracking refs for a branch across all remotes.
# Outputs one refname per line (format: refs/remotes/<remote>/<branch>).
# Centralises the git for-each-ref glob so callers don't repeat the pattern.
_remote_refs_for_branch() {
	local branch="$1"
	git for-each-ref --format='%(refname)' "refs/remotes/*/$branch" 2>/dev/null
}

# Get the remote name for a branch (from git config or remote-tracking refs).
# Outputs the remote name (e.g., "origin", "upstream") or empty string if none.
# Prefers the configured upstream remote; falls back to scanning all remotes.
_get_branch_remote() {
	local branch="$1"
	# Prefer configured upstream
	local configured_remote
	configured_remote=$(git config "branch.$branch.remote" 2>/dev/null || echo "")
	if [[ -n "$configured_remote" ]]; then
		echo "$configured_remote"
		return 0
	fi
	# Fallback: prefer origin before checking other remotes for predictability
	local ref
	ref=$(git for-each-ref --format='%(refname)' "refs/remotes/origin/$branch" 2>/dev/null)
	if [[ -z "$ref" ]]; then
		ref=$(_remote_refs_for_branch "$branch" | head -1)
	fi
	if [[ -n "$ref" ]]; then
		# Extract remote name from refs/remotes/<remote>/<branch>
		local remote_name
		remote_name="${ref#refs/remotes/}"
		remote_name="${remote_name%%/*}"
		echo "$remote_name"
		return 0
	fi
	return 1
}

# Check if a branch exists on any remote.
# Returns 0 (true) if refs/remotes/<any>/<branch> exists, 1 otherwise.
_branch_exists_on_any_remote() {
	local branch="$1"
	_remote_refs_for_branch "$branch" | grep -q .
}

# Check if a branch was ever pushed to remote
# Returns 0 (true) if branch has upstream or remote tracking
# Returns 1 (false) if branch was never pushed
branch_was_pushed() {
	local branch="$1"
	# Has upstream configured
	if git config "branch.$branch.remote" &>/dev/null; then
		return 0
	fi
	# Has remote tracking branch on any remote (not just origin)
	if _remote_refs_for_branch "$branch" | grep -q .; then
		return 0
	fi
	return 1
}

# Check if a stale remote branch exists for a branch name (t1060, GH#3797)
# A "stale remote" means refs/remotes/<remote>/$branch exists but no local branch does.
# This typically happens when a branch was merged via PR (remote deleted) but the
# local remote-tracking ref wasn't pruned, or when re-using a branch name.
# Checks all remotes, not just origin.
# Returns 0 if stale remote exists, 1 otherwise.
# Outputs: "<remote>|merged" or "<remote>|unmerged".
check_stale_remote_branch() {
	local branch="$1"

	# Only relevant if no local branch exists but remote ref does
	if branch_exists "$branch"; then
		return 1
	fi

	# Find the remote that has this branch (check all remotes, not just origin)
	local ref
	ref=$(_remote_refs_for_branch "$branch" | head -1)
	if [[ -z "$ref" ]]; then
		return 1
	fi

	# Extract remote name from refs/remotes/<remote>/<branch>
	local stale_remote
	stale_remote="${ref#refs/remotes/}"
	stale_remote="${stale_remote%%/*}"

	# Remote ref exists without a local branch — check if it's merged
	local default_branch
	default_branch=$(get_default_branch)
	if git branch -r --merged "$default_branch" 2>/dev/null | grep -q "${stale_remote}/$branch$"; then
		echo "${stale_remote}|merged"
	else
		echo "${stale_remote}|unmerged"
	fi
	return 0
}

# Delete a stale remote ref and prune local tracking ref (GH#3797)
# Internal helper to avoid repeating the same 3-line pattern
# Args: $1=branch, $2=message, $3=remote (defaults to "origin")
_delete_stale_remote_ref() {
	local branch="$1"
	local message="$2"
	local remote="${3:-origin}"

	echo -e "${BLUE}${message}${NC}"
	git push "$remote" --delete "$branch" 2>/dev/null || true
	git fetch --prune "$remote" 2>/dev/null || true
	echo -e "${GREEN}Deleted ${remote}/$branch${NC}"
}

# Handle a merged stale remote branch (interactive or headless).
# Args: $1=branch, $2=stale_remote, $3=remote_commit
# Returns 0 to proceed, 1 to abort.
_handle_stale_merged() {
	local branch="$1"
	local stale_remote="$2"
	local remote_commit="$3"

	echo -e "${YELLOW}Stale remote branch detected: ${stale_remote}/$branch (already merged)${NC}"
	echo -e "  Last commit: $remote_commit"

	if [[ -t 0 ]]; then
		echo ""
		echo -e "Options:"
		echo -e "  1) Delete stale remote ref and continue (recommended)"
		echo -e "  2) Continue without deleting"
		echo -e "  3) Abort"
		read -rp "Choice [1]: " choice
		choice="${choice:-1}"
		case "$choice" in
		1) _delete_stale_remote_ref "$branch" "Deleting stale remote ref..." "$stale_remote" ;;
		2) echo -e "${YELLOW}Proceeding without deleting stale remote${NC}" ;;
		3)
			echo -e "${RED}Aborted${NC}"
			return 1
			;;
		*)
			echo -e "${RED}Invalid choice, aborting${NC}"
			return 1
			;;
		esac
	else
		# go for it — headless mode can safely auto-delete merged stale refs
		_delete_stale_remote_ref "$branch" "Headless mode: auto-deleting merged stale remote ref..." "$stale_remote"
	fi

	return 0
}

# Handle an unmerged stale remote branch (interactive or headless).
# Args: $1=branch, $2=stale_remote, $3=remote_commit
# Returns 0 to proceed, 1 to abort.
_handle_stale_unmerged() {
	local branch="$1"
	local stale_remote="$2"
	local remote_commit="$3"

	echo -e "${RED}Stale remote branch detected: ${stale_remote}/$branch (NOT merged)${NC}"
	echo -e "  Last commit: $remote_commit"

	if [[ -t 0 ]]; then
		echo ""
		echo -e "Options:"
		echo -e "  1) Delete stale remote ref and continue (${RED}unmerged changes will be lost on remote${NC})"
		echo -e "  2) Continue without deleting (new branch will diverge from stale remote)"
		echo -e "  3) Abort"
		read -rp "Choice [3]: " choice
		choice="${choice:-3}"
		case "$choice" in
		1) _delete_stale_remote_ref "$branch" "Deleting stale remote ref..." "$stale_remote" ;;
		2) echo -e "${YELLOW}Proceeding without deleting stale remote${NC}" ;;
		3)
			echo -e "${RED}Aborted${NC}"
			return 1
			;;
		*)
			echo -e "${RED}Invalid choice, aborting${NC}"
			return 1
			;;
		esac
	else
		# Headless: warn but proceed — don't delete unmerged work
		echo -e "${YELLOW}Headless mode: proceeding without deleting (unmerged remote preserved)${NC}"
		echo -e "${YELLOW}New local branch will diverge from stale remote ref${NC}"
	fi

	return 0
}

# Handle stale remote branch before creating a new local branch (t1060)
# In interactive mode: warns user and offers to delete.
# In headless mode (no tty): auto-deletes if merged, warns and proceeds if unmerged.
# Returns 0 to proceed with branch creation, 1 to abort.
handle_stale_remote_branch() {
	local branch="$1"
	local stale_result
	stale_result=$(check_stale_remote_branch "$branch") || return 0

	# Parse "remote|status" from check_stale_remote_branch
	local stale_remote="${stale_result%%|*}"
	local stale_status="${stale_result##*|}"

	local remote_commit
	remote_commit=$(git rev-parse --short "refs/remotes/${stale_remote}/$branch" 2>/dev/null || echo "unknown")

	if [[ "$stale_status" == "merged" ]]; then
		_handle_stale_merged "$branch" "$stale_remote" "$remote_commit" || return 1
	else
		_handle_stale_unmerged "$branch" "$stale_remote" "$remote_commit" || return 1
	fi

	return 0
}
