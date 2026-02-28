#!/usr/bin/env bash
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

# Ownership registry functions are in shared-constants.sh (t189):
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
localdev_auto_branch() {
	local branch="$1"
	local project
	project="$(detect_localdev_project)" || return 0

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
	"$LOCALDEV_HELPER" branch rm "$project" "$branch" 2>&1 || true
	return 0
}

# Get repo info
get_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || echo ""
}

get_repo_name() {
	local root
	root=$(get_repo_root)
	if [[ -n "$root" ]]; then
		basename "$root"
	fi
}

get_current_branch() {
	git branch --show-current 2>/dev/null || echo ""
}

# Get the default branch (main or master)
get_default_branch() {
	# Try to get from remote HEAD
	local default_branch
	default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')

	if [[ -n "$default_branch" ]]; then
		echo "$default_branch"
		return 0
	fi

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

is_main_worktree() {
	local git_dir
	git_dir=$(git rev-parse --git-dir 2>/dev/null)
	# Main worktree has .git as a directory, linked worktrees have .git as a file
	[[ -d "$git_dir" ]] && [[ "$git_dir" == ".git" || "$git_dir" == "$(get_repo_root)/.git" ]]
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
	# Has remote tracking branch
	if git show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
		return 0
	fi
	return 1
}

# Check if a stale remote branch exists for a branch name (t1060)
# A "stale remote" means refs/remotes/origin/$branch exists but no local branch does.
# This typically happens when a branch was merged via PR (remote deleted) but the
# local remote-tracking ref wasn't pruned, or when re-using a branch name.
# Returns 0 if stale remote exists, 1 otherwise.
# Outputs: "merged" if the remote branch is merged into default, "unmerged" otherwise.
check_stale_remote_branch() {
	local branch="$1"

	# Only relevant if no local branch exists but remote ref does
	if branch_exists "$branch"; then
		return 1
	fi

	if ! git show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
		return 1
	fi

	# Remote ref exists without a local branch — check if it's merged
	local default_branch
	default_branch=$(get_default_branch)
	if git branch -r --merged "$default_branch" 2>/dev/null | grep -q "origin/$branch$"; then
		echo "merged"
	else
		echo "unmerged"
	fi
	return 0
}

# Delete a stale remote ref and prune local tracking ref
# Internal helper to avoid repeating the same 3-line pattern
_delete_stale_remote_ref() {
	local branch="$1"
	local message="$2"

	echo -e "${BLUE}${message}${NC}"
	git push origin --delete "$branch" 2>/dev/null || true
	git fetch --prune origin 2>/dev/null || true
	echo -e "${GREEN}Deleted origin/$branch${NC}"
}

# Handle stale remote branch before creating a new local branch (t1060)
# In interactive mode: warns user and offers to delete.
# In headless mode (no tty): auto-deletes if merged, warns and proceeds if unmerged.
# Returns 0 to proceed with branch creation, 1 to abort.
handle_stale_remote_branch() {
	local branch="$1"
	local stale_status

	stale_status=$(check_stale_remote_branch "$branch") || return 0

	local remote_commit
	remote_commit=$(git rev-parse --short "refs/remotes/origin/$branch" 2>/dev/null || echo "unknown")

	if [[ "$stale_status" == "merged" ]]; then
		echo -e "${YELLOW}Stale remote branch detected: origin/$branch (already merged)${NC}"
		echo -e "  Last commit: $remote_commit"

		if [[ -t 0 ]]; then
			# Interactive: ask user
			echo ""
			echo -e "Options:"
			echo -e "  1) Delete stale remote ref and continue (recommended)"
			echo -e "  2) Continue without deleting"
			echo -e "  3) Abort"
			read -rp "Choice [1]: " choice
			choice="${choice:-1}"
			case "$choice" in
			1)
				_delete_stale_remote_ref "$branch" "Deleting stale remote ref..."
				;;
			2)
				echo -e "${YELLOW}Proceeding without deleting stale remote${NC}"
				;;
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
			# Headless: auto-delete merged stale refs
			_delete_stale_remote_ref "$branch" "Headless mode: auto-deleting merged stale remote ref..."
		fi
	else
		# Unmerged stale remote
		echo -e "${RED}Stale remote branch detected: origin/$branch (NOT merged)${NC}"
		echo -e "  Last commit: $remote_commit"

		if [[ -t 0 ]]; then
			# Interactive: ask user
			echo ""
			echo -e "Options:"
			echo -e "  1) Delete stale remote ref and continue (${RED}unmerged changes will be lost on remote${NC})"
			echo -e "  2) Continue without deleting (new branch will diverge from stale remote)"
			echo -e "  3) Abort"
			read -rp "Choice [3]: " choice
			choice="${choice:-3}"
			case "$choice" in
			1)
				_delete_stale_remote_ref "$branch" "Deleting stale remote ref..."
				;;
			2)
				echo -e "${YELLOW}Proceeding without deleting stale remote${NC}"
				;;
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
	fi

	return 0
}

# Check if worktree has uncommitted changes
# Excludes aidevops runtime directories that are safe to discard
worktree_has_changes() {
	local worktree_path="$1"
	if [[ -d "$worktree_path" ]]; then
		local changes
		# Exclude aidevops runtime files: .agents/loop-state/, .agents/tmp/, .DS_Store
		changes=$(git -C "$worktree_path" status --porcelain 2>/dev/null |
			grep -v '^\?\? \.agents/loop-state/' |
			grep -v '^\?\? \.agents/tmp/' |
			grep -v '^\?\? \.agents/$' |
			grep -v '^\?\? \.DS_Store' |
			head -1)
		[[ -n "$changes" ]]
	else
		return 1
	fi
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

	local path_to_remove=""

	# Check if target is a path
	if [[ -d "$target" ]]; then
		path_to_remove="$target"
	else
		# Assume it's a branch name
		if worktree_exists_for_branch "$target"; then
			path_to_remove=$(get_worktree_path_for_branch "$target")
		else
			echo -e "${RED}Error: No worktree found for '$target'${NC}"
			return 1
		fi
	fi

	# Don't allow removing main worktree
	local main_worktree
	main_worktree=$(git worktree list --porcelain | head -1 | cut -d' ' -f2-)
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
		# Allow --force override
		if [[ "${WORKTREE_FORCE_REMOVE:-}" != "true" ]]; then
			return 1
		fi
		echo -e "${YELLOW}--force specified, proceeding with removal${NC}"
	fi

	# Clean up aidevops runtime files before removal (prevents "contains untracked files" error)
	rm -rf "$path_to_remove/.agents/loop-state" 2>/dev/null || true
	rm -rf "$path_to_remove/.agents/tmp" 2>/dev/null || true
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

	local found_any=false
	local worktree_path=""
	local worktree_branch=""

	local default_branch
	default_branch=$(get_default_branch)

	# Fetch to get current remote branch state (detects deleted branches)
	git fetch --prune origin 2>/dev/null || true

	# Build a lookup of merged PR branches for squash-merge detection.
	# gh pr list only returns squash-merged PRs that git branch --merged misses.
	local merged_pr_branches=""
	if command -v gh &>/dev/null; then
		merged_pr_branches=$(gh pr list --state merged --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null || echo "")
	fi

	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			worktree_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			worktree_branch="${BASH_REMATCH[1]}"
		elif [[ -z "$line" ]]; then
			# End of entry, check if merged (skip default branch)
			if [[ -n "$worktree_branch" ]] && [[ "$worktree_branch" != "$default_branch" ]]; then
				local is_merged=false
				local merge_type=""

				# Check 1: Traditional merge detection
				if git branch --merged "$default_branch" 2>/dev/null | grep -q "^\s*$worktree_branch$"; then
					is_merged=true
					merge_type="merged"
				# Check 2: Remote branch deleted (indicates squash merge or PR closed)
				# ONLY check this if the branch was previously pushed - unpushed branches should NOT be flagged
				elif branch_was_pushed "$worktree_branch" &&
					! git show-ref --verify --quiet "refs/remotes/origin/$worktree_branch" 2>/dev/null; then
					is_merged=true
					merge_type="remote deleted"
				# Check 3: Squash-merge detection via GitHub PR state
				# GitHub squash merges create a new commit — the original branch is NOT
				# an ancestor of the target, so git branch --merged misses it. The remote
				# branch may still exist if "auto-delete head branches" is off.
				elif [[ -n "$merged_pr_branches" ]] && echo "$merged_pr_branches" | grep -qx "$worktree_branch"; then
					is_merged=true
					merge_type="squash-merged PR"
				fi

				# Ownership check (t189): skip if owned by another active session
				if [[ "$is_merged" == "true" ]] && is_worktree_owned_by_others "$worktree_path"; then
					local clean_owner_info
					clean_owner_info=$(check_worktree_owner "$worktree_path")
					local clean_owner_pid
					clean_owner_pid="${clean_owner_info%%|*}"
					echo -e "  ${RED}$worktree_branch${NC} (owned by active session PID $clean_owner_pid - skipping)"
					echo "    $worktree_path"
					echo ""
					is_merged=false
				fi

				# Dirty check: behaviour depends on --force-merged flag
				if [[ "$is_merged" == "true" ]] && worktree_has_changes "$worktree_path"; then
					if [[ "$force_merged" == "true" ]]; then
						# PR is confirmed merged — dirty state is abandoned WIP, safe to force-remove
						merge_type="$merge_type, dirty (force)"
					else
						echo -e "  ${RED}$worktree_branch${NC} (has uncommitted changes - skipping)"
						echo "    $worktree_path"
						echo ""
						is_merged=false
					fi
				fi

				if [[ "$is_merged" == "true" ]]; then
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

	if [[ "$found_any" == "false" ]]; then
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
		# Re-iterate and remove
		while IFS= read -r line; do
			if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
				worktree_path="${BASH_REMATCH[1]}"
			elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
				worktree_branch="${BASH_REMATCH[1]}"
			elif [[ -z "$line" ]]; then
				if [[ -n "$worktree_branch" ]] && [[ "$worktree_branch" != "$default_branch" ]]; then
					local should_remove=false
					local use_force=false

					# Ownership check (t189): never remove worktrees owned by other sessions
					if is_worktree_owned_by_others "$worktree_path"; then
						local rm_owner_info
						rm_owner_info=$(check_worktree_owner "$worktree_path")
						local rm_owner_pid
						rm_owner_pid="${rm_owner_info%%|*}"
						echo -e "${RED}Skipping $worktree_branch - owned by active session PID $rm_owner_pid${NC}"
						should_remove=false
					# Check 1: Traditional merge
					elif git branch --merged "$default_branch" 2>/dev/null | grep -q "^\s*$worktree_branch$"; then
						should_remove=true
					# Check 2: Remote branch deleted - ONLY if branch was previously pushed
					elif branch_was_pushed "$worktree_branch" &&
						! git show-ref --verify --quiet "refs/remotes/origin/$worktree_branch" 2>/dev/null; then
						should_remove=true
					# Check 3: Squash-merged PR
					elif [[ -n "$merged_pr_branches" ]] && echo "$merged_pr_branches" | grep -qx "$worktree_branch"; then
						should_remove=true
					fi

					# If should_remove but has changes, need --force-merged to proceed
					if [[ "$should_remove" == "true" ]] && worktree_has_changes "$worktree_path"; then
						if [[ "$force_merged" == "true" ]]; then
							use_force=true
						else
							echo -e "${RED}Skipping $worktree_branch - has uncommitted changes${NC}"
							should_remove=false
						fi
					fi

					if [[ "$should_remove" == "true" ]]; then
						echo -e "${BLUE}Removing $worktree_branch...${NC}"
						# Clean up heavy directories first to speed up removal
						# (node_modules, .next, .turbo can have 100k+ files)
						rm -rf "$worktree_path/node_modules" 2>/dev/null || true
						rm -rf "$worktree_path/.next" 2>/dev/null || true
						rm -rf "$worktree_path/.turbo" 2>/dev/null || true
						# Clean up aidevops runtime files
						rm -rf "$worktree_path/.agents/loop-state" 2>/dev/null || true
						rm -rf "$worktree_path/.agents/tmp" 2>/dev/null || true
						rm -f "$worktree_path/.agents/.DS_Store" 2>/dev/null || true
						rmdir "$worktree_path/.agent" 2>/dev/null || true

						local remove_flag=""
						if [[ "$use_force" == "true" ]]; then
							remove_flag="--force"
						fi
						# shellcheck disable=SC2086
						if ! git worktree remove $remove_flag "$worktree_path" 2>/dev/null; then
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

		echo -e "${GREEN}Cleanup complete${NC}"
	else
		echo "Cancelled"
	fi

	return 0
}

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

cmd_help() {
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

STALE REMOTE DETECTION (t1060)
  When creating a new branch, the script checks for stale remote refs
  (refs/remotes/origin/<branch> exists but no local branch does).
  
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
