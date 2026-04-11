#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155

# =============================================================================
# Git Worktree Helper Script
# =============================================================================
# Manage multiple working directories for parallel branch work.
# Each worktree is an independent directory on a different branch,
# sharing the same git database.
#
# Usage:
#   worktree-helper.sh <command> [options]
#
# Commands:
#   add <branch> [path]    Create worktree for branch (auto-names path)
#   list                   List all worktrees with status
#   remove <path|branch>   Remove a worktree
#   status                 Show current worktree info
#   switch <branch>        Open/create worktree for branch (prints path)
#   clean [--auto] [--force-merged]  Remove worktrees for merged branches
#   help                   Show this help
#
# Examples:
#   worktree-helper.sh add feature/auth
#   worktree-helper.sh switch bugfix/login
#   worktree-helper.sh list
#   worktree-helper.sh remove feature/auth
#   worktree-helper.sh clean
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly BOLD='\033[1m'

# nice — ownership registry functions are centralised in shared-constants.sh (t189):
#   register_worktree, unregister_worktree, check_worktree_owner,
#   is_worktree_owned_by_others, prune_worktree_registry

# =============================================================================
# Localdev Integration (t1224.8)
# =============================================================================
# When a worktree is created for a localdev-registered project, auto-create
# a branch subdomain route (e.g., feature-xyz.myapp.local) and output the URL.
# When a worktree is removed, auto-clean the corresponding branch route.

readonly LOCALDEV_PORTS_FILE="$HOME/.local-dev-proxy/ports.json"
readonly LOCALDEV_HELPER="${SCRIPT_DIR}/localdev-helper.sh"

# Detect if the current repo is registered as a localdev project.
# Matches repo directory name against registered app names in ports.json.
# Outputs the app name if found, empty string otherwise.
detect_localdev_project() {
	local repo_root="${1:-}"
	[[ -z "$repo_root" ]] && repo_root="$(get_repo_root)"
	[[ -z "$repo_root" ]] && return 1

	# ports.json must exist
	[[ ! -f "$LOCALDEV_PORTS_FILE" ]] && return 1

	# localdev-helper.sh must exist
	[[ ! -x "$LOCALDEV_HELPER" ]] && return 1

	local repo_name
	repo_name="$(basename "$repo_root")"

	# Strip worktree suffix to get the base repo name
	# Worktree paths: ~/Git/{repo}-{branch-slug} → extract {repo}
	# Main repo paths: ~/Git/{repo} → use as-is
	local base_name="$repo_name"
	# If this is a worktree (has .git file, not directory), find the main repo name
	if [[ -f "$repo_root/.git" ]]; then
		local main_worktree
		main_worktree="$(git -C "$repo_root" worktree list --porcelain | head -1 | cut -d' ' -f2-)"
		if [[ -n "$main_worktree" ]]; then
			base_name="$(basename "$main_worktree")"
		fi
	fi

	# Check if this repo name is registered in ports.json
	if command -v jq >/dev/null 2>&1; then
		local match
		match="$(jq -r --arg n "$base_name" '.apps[$n] // empty | .domain // empty' "$LOCALDEV_PORTS_FILE" 2>/dev/null)"
		if [[ -n "$match" ]]; then
			echo "$base_name"
			return 0
		fi
	else
		# Fallback: grep-based check
		if grep -qF "\"$base_name\"" "$LOCALDEV_PORTS_FILE" 2>/dev/null; then
			echo "$base_name"
			return 0
		fi
	fi

	return 1
}

# Auto-create localdev branch route after worktree creation.
# Called from cmd_add after successful worktree creation.
# If the project is not registered, auto-registers it first (t1424.1).
localdev_auto_branch() {
	local branch="$1"
	local project

	# Check if localdev-helper.sh exists
	[[ ! -x "$LOCALDEV_HELPER" ]] && return 0

	if ! project="$(detect_localdev_project)" || [[ -z "$project" ]]; then
		# Project not registered — try to auto-register (t1424.1)
		# Delegate name inference to localdev-helper.sh to avoid logic duplication
		local inferred_name=""
		inferred_name="$("$LOCALDEV_HELPER" infer-name "$(get_repo_root)" 2>/dev/null)" || true
		[[ -z "$inferred_name" ]] && return 0

		echo ""
		echo -e "${BLUE}Localdev integration: auto-registering project '$inferred_name'...${NC}"
		if "$LOCALDEV_HELPER" add "$inferred_name" 2>&1; then
			project="$inferred_name"
		else
			echo -e "${YELLOW}Localdev auto-registration failed (non-fatal)${NC}"
			return 0
		fi
	fi

	echo ""
	echo -e "${BLUE}Localdev integration: creating branch route for $project...${NC}"
	if "$LOCALDEV_HELPER" branch "$project" "$branch" 2>&1; then
		return 0
	else
		echo -e "${YELLOW}Localdev branch route creation failed (non-fatal)${NC}"
		return 0
	fi
}

# Auto-remove localdev branch route when worktree is removed.
# Called from cmd_remove after successful worktree removal.
localdev_auto_branch_rm() {
	local branch="$1"
	local project
	project="$(detect_localdev_project)" || return 0

	echo ""
	echo -e "${BLUE}Localdev integration: removing branch route for $project/$branch...${NC}"
	"$LOCALDEV_HELPER" branch rm "$project" "$branch" 2>&1 ||
		echo -e "${YELLOW}Localdev branch route removal failed (non-fatal)${NC}"
	return 0
}

# Get repo info
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
		ref=$(git for-each-ref --format='%(refname)' "refs/remotes/*/$branch" | head -1)
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
	git for-each-ref --format='%(refname)' "refs/remotes/*/$branch" | grep -q .
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
	if git for-each-ref --format='%(refname)' "refs/remotes/*/$branch" | grep -q .; then
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
	ref=$(git for-each-ref --format='%(refname)' "refs/remotes/*/$branch" | head -1)
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

# Check if worktree has uncommitted changes (GH#3797)
# Excludes aidevops runtime directories that are safe to discard.
# Returns 0 (true) if changes exist OR if git status fails (safety-first:
# treat unknown state as "has changes" to prevent data loss on cleanup).
worktree_has_changes() {
	local worktree_path="$1"
	if [[ -d "$worktree_path" ]]; then
		local status_output
		# Capture git status; if it fails, treat as "has changes" (safety-first)
		if ! status_output=$(git -C "$worktree_path" status --porcelain 2>&1); then
			return 0
		fi
		local changes
		# Exclude aidevops runtime files: .agents/loop-state/, .agents/tmp/, .DS_Store
		# Use literal '??' (not '\?\?') to match git status untracked prefix.
		# Append '|| true' so the pipeline doesn't fail under pipefail when all lines are filtered.
		changes=$(echo "$status_output" |
			grep -v '^?? \.agents/loop-state/' |
			grep -v '^?? \.agents/tmp/' |
			grep -v '^?? \.agents/$' |
			grep -v '^?? \.DS_Store' |
			head -1 || true)
		[[ -n "$changes" ]]
	else
		return 1
	fi
}

# Move a path to the system trash instead of permanently deleting it.
# Prefers: trash (CLI utility, e.g. installed via Homebrew), gio trash (Linux), rm -rf fallback.
# Args: $1=path to trash
# Returns 0 on success, 1 on failure.
trash_path() {
	local target="$1"
	[[ -z "$target" ]] && return 1
	[[ ! -e "$target" ]] && return 0 # Already gone — not an error

	if command -v trash >/dev/null 2>&1; then
		trash "$target" 2>/dev/null && return 0
	fi
	if command -v gio >/dev/null 2>&1; then
		gio trash "$target" 2>/dev/null && return 0
	fi
	# Fallback: permanent delete
	rm -rf "$target" 2>/dev/null && return 0
	return 1
}

# Generate worktree path from branch name
# Pattern: ~/Git/{repo}-{branch-slug}
generate_worktree_path() {
	local branch="$1"
	local repo_name
	repo_name=$(get_repo_name)

	# Convert branch to slug: feature/auth-system -> feature-auth-system
	local slug
	slug=$(echo "$branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')

	# Get parent directory of main repo
	local parent_dir
	parent_dir=$(dirname "$(get_repo_root)")

	echo "${parent_dir}/${repo_name}-${slug}"
}

# Check if branch exists
branch_exists() {
	local branch="$1"
	git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null
}

# Check if worktree exists for branch
worktree_exists_for_branch() {
	local branch="$1"
	git worktree list --porcelain | grep -q "branch refs/heads/$branch$"
}

# Get worktree path for branch
get_worktree_path_for_branch() {
	local branch="$1"
	git worktree list --porcelain | grep -B2 "branch refs/heads/$branch$" | grep "^worktree " | cut -d' ' -f2-
}

# =============================================================================
# COMMANDS
# =============================================================================

# Resolve a remove target (path or branch name) to an absolute worktree path.
# Prints the resolved path on success. Returns 1 with an error message on failure.
_remove_resolve_path() {
	local target="$1"

	if [[ -d "$target" ]]; then
		echo "$target"
		return 0
	fi

	if worktree_exists_for_branch "$target"; then
		get_worktree_path_for_branch "$target"
		return 0
	fi

	echo -e "${RED}Error: No worktree found for '$target'${NC}" >&2
	return 1
}

# Print the ownership error block for cmd_remove when another session owns the worktree.
# Args: $1=path_to_remove
_remove_show_owner_error() {
	local path_to_remove="$1"
	local owner_info
	owner_info=$(check_worktree_owner "$path_to_remove")
	local owner_pid owner_session owner_batch owner_task _
	IFS='|' read -r owner_pid owner_session owner_batch owner_task _ <<<"$owner_info"
	echo -e "${RED}Error: Worktree is owned by another active session${NC}"
	echo -e "  Owner PID:     $owner_pid"
	[[ -n "$owner_session" ]] && echo -e "  Session:       $owner_session"
	[[ -n "$owner_batch" ]] && echo -e "  Batch:         $owner_batch"
	[[ -n "$owner_task" ]] && echo -e "  Task:          $owner_task"
	echo ""
	echo "Use --force to override, or wait for the owning session to finish."
	return 0
}

cmd_add() {
	local branch="${1:-}"
	local path="${2:-}"

	if [[ -z "$branch" ]]; then
		echo -e "${RED}Error: Branch name required${NC}"
		echo "Usage: worktree-helper.sh add <branch> [path]"
		return 1
	fi

	# Check if we're in a git repo
	if [[ -z "$(get_repo_root)" ]]; then
		echo -e "${RED}Error: Not in a git repository${NC}"
		return 1
	fi

	# Check if worktree already exists for this branch
	if worktree_exists_for_branch "$branch"; then
		local existing_path
		existing_path=$(get_worktree_path_for_branch "$branch")
		echo -e "${YELLOW}Worktree already exists for branch '$branch'${NC}"
		echo -e "Path: ${BOLD}$existing_path${NC}"
		echo ""
		echo "To use it:"
		echo "  cd $existing_path" || exit
		return 0
	fi

	# Generate path if not provided
	if [[ -z "$path" ]]; then
		path=$(generate_worktree_path "$branch")
	fi

	# Check if path already exists
	if [[ -d "$path" ]]; then
		echo -e "${RED}Error: Path already exists: $path${NC}"
		return 1
	fi

	# Create worktree
	if branch_exists "$branch"; then
		# Branch exists, check it out
		echo -e "${BLUE}Creating worktree for existing branch '$branch'...${NC}"
		git worktree add "$path" "$branch"
	else
		# Branch doesn't exist locally — check for stale remote ref (t1060)
		handle_stale_remote_branch "$branch" || return 1

		# Create new branch
		echo -e "${BLUE}Creating worktree with new branch '$branch'...${NC}"
		git worktree add -b "$branch" "$path"
	fi

	# Register ownership (t189)
	register_worktree "$path" "$branch"

	echo ""
	echo -e "${GREEN}Worktree created successfully!${NC}"
	echo ""
	echo -e "Path: ${BOLD}$path${NC}"
	echo -e "Branch: ${BOLD}$branch${NC}"
	echo ""
	echo "To start working:"
	echo "  cd $path" || exit
	echo ""
	echo "Or open in a new terminal/editor:"
	echo "  code $path        # VS Code"
	echo "  cursor $path      # Cursor"
	echo "  opencode $path    # OpenCode"

	# Localdev integration (t1224.8): auto-create branch subdomain route
	localdev_auto_branch "$branch"

	return 0
}

# List all worktrees with branch names, merge status, and current marker.
cmd_list() {
	echo -e "${BOLD}Git Worktrees:${NC}"
	echo ""

	local current_path
	current_path=$(pwd)

	# Parse worktree list
	local worktree_path=""
	local worktree_branch=""
	local is_bare=""

	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			worktree_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			worktree_branch="${BASH_REMATCH[1]}"
		elif [[ "$line" == "bare" ]]; then
			is_bare="true"
		elif [[ -z "$line" ]]; then
			# End of entry, print it
			if [[ -n "$worktree_path" ]]; then
				local marker=""
				if [[ "$worktree_path" == "$current_path" ]]; then
					marker=" ${GREEN}← current${NC}"
				fi

				if [[ "$is_bare" == "true" ]]; then
					echo -e "  ${YELLOW}(bare)${NC} $worktree_path"
				else
					# Check if branch is merged into default branch
					local merged_marker=""
					local default_branch
					default_branch=$(get_default_branch)
					if [[ -n "$worktree_branch" ]] && git branch --merged "$default_branch" 2>/dev/null | grep -q "^\s*$worktree_branch$"; then
						merged_marker=" ${YELLOW}(merged)${NC}"
					fi

					echo -e "  ${BOLD}$worktree_branch${NC}$merged_marker$marker"
					echo -e "    $worktree_path"
				fi
				echo ""
			fi
			worktree_path=""
			worktree_branch=""
			is_bare=""
		fi
	done < <(
		git worktree list --porcelain
		echo ""
	)

	return 0
}

# Validate that a resolved worktree path is safe to remove.
# Checks: not main worktree, not current directory, ownership.
# Args: $1=path_to_remove
# Returns 0 if safe to remove, 1 if blocked.
_remove_validate_path() {
	local path_to_remove="$1"

	# Don't allow removing main worktree
	# NOTE: avoid piping git worktree list through head — with set -o pipefail
	# and many worktrees, head closes the pipe early, git gets SIGPIPE (exit 141),
	# and pipefail propagates the failure causing set -e to abort the script.
	local _porcelain main_worktree
	_porcelain=$(git worktree list --porcelain)
	main_worktree="${_porcelain%%$'\n'*}"      # first line
	main_worktree="${main_worktree#worktree }" # strip prefix
	if [[ "$path_to_remove" == "$main_worktree" ]]; then
		echo -e "${RED}Error: Cannot remove main worktree${NC}"
		return 1
	fi

	# Check if we're currently in the worktree to remove
	if [[ "$(pwd)" == "$path_to_remove"* ]]; then
		echo -e "${RED}Error: Cannot remove worktree while inside it${NC}"
		echo "First: cd $(get_repo_root)" || exit
		return 1
	fi

	# Ownership check (t189): refuse to remove worktrees owned by other sessions
	if is_worktree_owned_by_others "$path_to_remove"; then
		_remove_show_owner_error "$path_to_remove"
		if [[ "${WORKTREE_FORCE_REMOVE:-}" != "true" ]]; then
			return 1
		fi
		echo -e "${YELLOW}--force specified, proceeding with removal${NC}"
	fi

	return 0
}

# Clean up aidevops runtime files and execute the git worktree remove.
# Also handles unregistration and localdev cleanup.
# Args: $1=path_to_remove
# Returns 0 on success, 1 on failure.
_remove_cleanup_and_execute() {
	local path_to_remove="$1"

	# Clean up aidevops runtime files before removal (prevents "contains untracked files" error)
	# Use trash_path for recoverable deletion; fall back to rm -rf if trash unavailable.
	trash_path "$path_to_remove/.agents/loop-state" || true
	trash_path "$path_to_remove/.agents/tmp" || true
	rm -f "$path_to_remove/.agents/.DS_Store" 2>/dev/null || true
	rmdir "$path_to_remove/.agent" 2>/dev/null || true # Only removes if empty

	# Capture branch name before removal for localdev cleanup (t1224.8)
	local removed_branch=""
	removed_branch="$(git -C "$path_to_remove" branch --show-current 2>/dev/null || echo "")"

	echo -e "${BLUE}Removing worktree: $path_to_remove${NC}"
	git worktree remove "$path_to_remove"

	# Unregister ownership (t189)
	unregister_worktree "$path_to_remove"

	echo -e "${GREEN}Worktree removed successfully${NC}"

	# Localdev integration (t1224.8): auto-remove branch subdomain route
	if [[ -n "$removed_branch" ]]; then
		localdev_auto_branch_rm "$removed_branch"
	fi

	return 0
}

# Remove a worktree by branch name or path, with optional --force.
cmd_remove() {
	local target=""
	local force_remove=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force | -f)
			force_remove=true
			shift
			;;
		*)
			target="$1"
			shift
			;;
		esac
	done

	if [[ -z "$target" ]]; then
		echo -e "${RED}Error: Path or branch name required${NC}"
		echo "Usage: worktree-helper.sh remove <path|branch> [--force]"
		return 1
	fi

	# Export for ownership check
	if [[ "$force_remove" == "true" ]]; then
		export WORKTREE_FORCE_REMOVE="true"
	fi

	# Resolve target to an absolute path
	local path_to_remove
	if ! path_to_remove=$(_remove_resolve_path "$target"); then
		return 1
	fi

	# Validate path is safe to remove
	_remove_validate_path "$path_to_remove" || return 1

	# Clean up runtime files and execute removal
	_remove_cleanup_and_execute "$path_to_remove" || return 1

	return 0
}

# Show status of the current worktree (repo, branch, type, total count).
cmd_status() {
	local repo_root
	repo_root=$(get_repo_root)

	if [[ -z "$repo_root" ]]; then
		echo -e "${RED}Error: Not in a git repository${NC}"
		return 1
	fi

	local current_branch
	current_branch=$(get_current_branch)

	echo -e "${BOLD}Current Worktree Status:${NC}"
	echo ""
	echo -e "  Repository: ${BOLD}$(get_repo_name)${NC}"
	echo -e "  Branch:     ${BOLD}$current_branch${NC}"
	echo -e "  Path:       $(pwd)"

	if is_main_worktree; then
		echo -e "  Type:       ${BLUE}Main worktree${NC}"
	else
		echo -e "  Type:       ${GREEN}Linked worktree${NC}"
	fi

	# Count total worktrees
	local count
	count=$(git worktree list | wc -l | tr -d ' ')
	echo ""
	echo -e "  Total worktrees: $count"

	if [[ "$count" -gt 1 ]]; then
		echo ""
		echo "Run 'worktree-helper.sh list' to see all worktrees"
	fi

	return 0
}

# Switch to a worktree for the given branch, creating one if needed.
cmd_switch() {
	local branch="${1:-}"

	if [[ -z "$branch" ]]; then
		echo -e "${RED}Error: Branch name required${NC}"
		echo "Usage: worktree-helper.sh switch <branch>"
		return 1
	fi

	# Check if worktree exists for this branch
	if worktree_exists_for_branch "$branch"; then
		local path
		path=$(get_worktree_path_for_branch "$branch")
		echo -e "${GREEN}Worktree exists for '$branch'${NC}"
		echo ""
		echo "Path: $path"
		echo ""
		echo "To switch:"
		echo "  cd $path" || exit
		return 0
	fi

	# Create new worktree
	echo -e "${BLUE}No worktree for '$branch', creating one...${NC}"
	cmd_add "$branch"
	return $?
}

# Validate and get the grace hours setting.
# Returns a valid integer grace hours value, defaulting to 4 if invalid.
# Prints warning to stderr if WORKTREE_CLEAN_GRACE_HOURS is invalid.
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
		return 0
	fi

	# GH#5694 Safety check B: Open PR
	# Skip worktrees whose branch has an open PR — active work in progress.
	# This applies even with --force-merged: an open PR means the work is not done.
	if [[ -n "$open_pr_list" ]] && echo "$open_pr_list" | grep -Fxq "$wt_branch"; then
		echo -e "  ${RED}$wt_branch${NC} (has open PR - skipping)"
		echo "    $wt_path"
		echo ""
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
		return 0
	fi

	# Dirty check: behaviour depends on --force-merged flag
	# Only reached if the three safety checks above did not trigger.
	if worktree_has_changes "$wt_path"; then
		if [[ "$force_merged_flag" != "true" ]]; then
			echo -e "  ${RED}$wt_branch${NC} (has uncommitted changes - skipping)"
			echo "    $wt_path"
			echo ""
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
	for remote in $(git remote 2>/dev/null); do
		if ! git fetch --prune "$remote" 2>/dev/null; then
			echo -e "${YELLOW}Warning: failed to refresh $remote; skipping remote-deleted cleanup checks${NC}" >&2
			state_unknown=true
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
					echo -e "  ${YELLOW}$worktree_branch${NC} ($merge_type)"
					echo "    $worktree_path"
					echo ""
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
					echo -e "${BLUE}Removing $worktree_branch...${NC}"
					# Clean up heavy reproducible directories first to speed up removal
					# (node_modules, .next, .turbo can have 100k+ files — rm -rf is faster than trash)
					rm -rf "$worktree_path/node_modules" 2>/dev/null || true
					rm -rf "$worktree_path/.next" 2>/dev/null || true
					rm -rf "$worktree_path/.turbo" 2>/dev/null || true
					# Clean up aidevops runtime files (use trash for recoverability)
					trash_path "$worktree_path/.agents/loop-state" || true
					trash_path "$worktree_path/.agents/tmp" || true
					rm -f "$worktree_path/.agents/.DS_Store" 2>/dev/null || true
					rmdir "$worktree_path/.agent" 2>/dev/null || true

					local remove_flag=""
					if [[ "$use_force" == "true" ]]; then
						remove_flag="--force"
					fi
					# shellcheck disable=SC2086
					if ! git worktree remove $remove_flag "$worktree_path"; then
						echo -e "${RED}Failed to remove $worktree_branch - may have uncommitted changes${NC}"
					else
						# Unregister ownership (t189)
						unregister_worktree "$worktree_path"
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

	echo -e "${BOLD}Checking for worktrees with merged branches...${NC}"
	echo ""

	local default_branch
	default_branch=$(get_default_branch)

	# Identify the main worktree path — must never be cleaned up.
	# The first entry in `git worktree list --porcelain` is always the main worktree.
	# NOTE: avoid piping through head — with set -o pipefail and many worktrees,
	# head closes the pipe early → git SIGPIPE (exit 141) → pipefail → set -e abort.
	local _porcelain main_worktree_path
	_porcelain=$(git worktree list --porcelain)
	main_worktree_path="${_porcelain%%$'\n'*}"           # first line
	main_worktree_path="${main_worktree_path#worktree }" # strip prefix

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
		echo -e "${GREEN}No merged worktrees to clean up${NC}"
		return 0
	fi

	local response="n"
	if [[ "$auto_mode" == "true" ]]; then
		response="y"
	else
		echo ""
		echo -e "${YELLOW}Remove these worktrees? [y/N]${NC}"
		read -r response
	fi

	if [[ "$response" =~ ^[Yy]$ ]]; then
		# Second pass: remove merged worktrees
		_clean_remove_merged "$default_branch" "$main_worktree_path" "$remote_state_unknown" "$merged_pr_branches" "$open_pr_branches" "$force_merged" "$closed_pr_branches"
		echo -e "${GREEN}Cleanup complete${NC}"
	else
		echo "Cancelled"
	fi

	return 0
}

# Manage the worktree ownership registry (list or prune stale entries).
cmd_registry() {
	local subcmd="${1:-list}"

	case "$subcmd" in
	list | ls)
		[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && {
			echo "No registry entries"
			return 0
		}
		echo -e "${BOLD}Worktree Ownership Registry:${NC}"
		echo ""
		local entries
		entries=$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
                SELECT worktree_path, branch, owner_pid, owner_session, owner_batch, task_id, created_at
                FROM worktree_owners ORDER BY created_at DESC;
            " 2>/dev/null || echo "")
		if [[ -z "$entries" ]]; then
			echo "  (empty)"
			return 0
		fi
		while IFS='|' read -r wt_path branch pid session batch task created; do
			local alive_status="${RED}dead${NC}"
			if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
				alive_status="${GREEN}alive${NC}"
			fi
			echo -e "  ${BOLD}$branch${NC}"
			echo -e "    Path:    $wt_path"
			echo -e "    PID:     $pid ($alive_status)"
			[[ -n "$session" ]] && echo -e "    Session: $session"
			[[ -n "$batch" ]] && echo -e "    Batch:   $batch"
			[[ -n "$task" ]] && echo -e "    Task:    $task"
			echo -e "    Created: $created"
			echo ""
		done <<<"$entries"
		;;
	prune)
		shift # Remove 'prune' from args
		local verbose=""
		if [[ "${1:-}" == "-v" ]] || [[ "${1:-}" == "--verbose" ]]; then
			verbose="true"
			export VERBOSE="true"
		fi

		[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && {
			echo "No registry entries to prune"
			return 0
		}

		# Count before pruning
		local before_count
		before_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners;" 2>/dev/null || echo "0")

		echo -e "${BLUE}Pruning stale registry entries...${NC}"
		[[ -n "$verbose" ]] && echo ""
		prune_worktree_registry

		# Count after pruning
		local after_count
		after_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners;" 2>/dev/null || echo "0")
		local pruned=$((before_count - after_count))

		echo -e "${GREEN}Done: pruned $pruned of $before_count entries ($after_count remaining)${NC}"
		;;
	*)
		echo "Usage: worktree-helper.sh registry [list|prune]"
		;;
	esac
	return 0
}

# Print the overview and commands section of the help output.
_help_print_overview_and_commands() {
	cat <<'EOF'
Git Worktree Helper - Parallel Branch Development

OVERVIEW
  Git worktrees allow multiple working directories, each on a different branch,
  sharing the same git database. Perfect for:
  - Multiple terminal tabs on different branches
  - Parallel AI sessions without branch conflicts
  - Quick context switching without stashing

COMMANDS
  add <branch> [path]    Create worktree for branch
                         Path auto-generated as ~/Git/{repo}-{branch-slug}

  list                   List all worktrees with status

  remove <path|branch> [--force]
                         Remove a worktree (keeps branch)
                         Refuses if owned by another active session (t189)
                         Use --force to override ownership check

  status                 Show current worktree info

  switch <branch>        Get/create worktree for branch (prints path)

  clean [--auto] [--force-merged]
                         Remove worktrees for merged branches
                         --auto: skip confirmation prompt (for automated cleanup)
                         --force-merged: force-remove dirty worktrees when PR is
                           confirmed merged (dirty state = abandoned WIP). Also
                           detects squash merges via gh pr list.
                         Skips worktrees owned by other active sessions (t189)

  registry [list|prune]  View or prune the ownership registry (t189, t197)
                         list: Show all registered worktrees with ownership info
                         prune [-v|--verbose]: Clean dead/corrupted entries:
                           - Dead PIDs with missing directories
                           - Paths with ANSI escape codes
                           - Test artifacts in /tmp or /var/folders

  help                   Show this help

OWNERSHIP SAFETY (t189)
  Worktrees are registered to the creating session's PID. Removal is blocked
  if another session's process is still alive. This prevents cross-session
  worktree removal that destroys another agent's working directory.

  Registry: ~/.aidevops/.agent-workspace/worktree-registry.db

EOF
	return 0
}

# Print the examples, directory structure, and notes sections of the help output.
_help_print_examples_and_notes() {
	cat <<'EOF'
EXAMPLES
  # Start work on a feature (creates worktree)
  worktree-helper.sh add feature/user-auth
  cd ~/Git/myrepo-feature-user-auth || exit

  # Open another terminal for a bugfix
  worktree-helper.sh add bugfix/login-timeout
  cd ~/Git/myrepo-bugfix-login-timeout || exit

  # List all worktrees
  worktree-helper.sh list

  # After merging, clean up
  worktree-helper.sh clean

  # View ownership registry
  worktree-helper.sh registry list

DIRECTORY STRUCTURE
  ~/Git/myrepo/                      # Main worktree (main branch)
  ~/Git/myrepo-feature-user-auth/    # Linked worktree (feature/user-auth)
  ~/Git/myrepo-bugfix-login/         # Linked worktree (bugfix/login)

STALE REMOTE DETECTION (t1060, GH#3797)
  When creating a new branch, the script checks for stale remote refs
  on all configured remotes (not just origin).

  Interactive mode:
    - Merged stale: offers to delete (recommended) or continue
    - Unmerged stale: warns and defaults to abort (data safety)

  Headless mode (no tty):
    - Merged stale: auto-deletes the remote ref and continues
    - Unmerged stale: warns but proceeds without deleting

LOCALDEV INTEGRATION (t1224.8)
  For projects registered with 'localdev add', worktree creation auto-runs
  'localdev branch <project> <branch>' to create a subdomain route
  (e.g., feature-auth.myapp.local). Worktree removal auto-cleans the route.

  Detection: matches repo name against ~/.local-dev-proxy/ports.json
  Requires: localdev-helper.sh in the same scripts directory

NOTES
  - All worktrees share the same .git database (commits, stashes, refs)
  - Each worktree is independent - no branch switching affects others
  - Removing a worktree does NOT delete the branch
  - Main worktree cannot be removed

EOF
	return 0
}

# Display usage information and available commands.
cmd_help() {
	_help_print_overview_and_commands
	_help_print_examples_and_notes
	return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	add)
		cmd_add "$@"
		;;
	list | ls)
		cmd_list "$@"
		;;
	remove | rm)
		cmd_remove "$@"
		;;
	status | st)
		cmd_status "$@"
		;;
	switch | sw)
		cmd_switch "$@"
		;;
	clean)
		cmd_clean "$@"
		;;
	registry | reg)
		cmd_registry "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo -e "${RED}Unknown command: $command${NC}"
		echo "Run 'worktree-helper.sh help' for usage"
		return 1
		;;
	esac
}

main "$@"
