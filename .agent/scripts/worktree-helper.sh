#!/bin/bash
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
#   clean                  Remove worktrees for merged branches
#   help                   Show this help
#
# Examples:
#   worktree-helper.sh add feature/auth
#   worktree-helper.sh switch bugfix/login
#   worktree-helper.sh list
#   worktree-helper.sh remove feature/auth
#   worktree-helper.sh clean
# =============================================================================

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

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

# Check if worktree has uncommitted changes
# Excludes aidevops runtime directories that are safe to discard
worktree_has_changes() {
    local worktree_path="$1"
    if [[ -d "$worktree_path" ]]; then
        local changes
        # Exclude aidevops runtime files: .agent/loop-state/, .agent/tmp/, .DS_Store
        changes=$(git -C "$worktree_path" status --porcelain 2>/dev/null | \
            grep -v '^\?\? \.agent/loop-state/' | \
            grep -v '^\?\? \.agent/tmp/' | \
            grep -v '^\?\? \.agent/$' | \
            grep -v '^\?\? \.DS_Store' | \
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
        # Branch doesn't exist, create it
        echo -e "${BLUE}Creating worktree with new branch '$branch'...${NC}"
        git worktree add -b "$branch" "$path"
    fi
    
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
    done < <(git worktree list --porcelain; echo "")
    
    return 0
}

cmd_remove() {
    local target="${1:-}"
    
    if [[ -z "$target" ]]; then
        echo -e "${RED}Error: Path or branch name required${NC}"
        echo "Usage: worktree-helper.sh remove <path|branch>"
        return 1
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
    
    # Clean up aidevops runtime files before removal (prevents "contains untracked files" error)
    rm -rf "$path_to_remove/.agent/loop-state" 2>/dev/null || true
    rm -rf "$path_to_remove/.agent/tmp" 2>/dev/null || true
    rm -f "$path_to_remove/.agent/.DS_Store" 2>/dev/null || true
    rmdir "$path_to_remove/.agent" 2>/dev/null || true  # Only removes if empty
    
    echo -e "${BLUE}Removing worktree: $path_to_remove${NC}"
    git worktree remove "$path_to_remove"
    
    echo -e "${GREEN}Worktree removed successfully${NC}"
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
    echo -e "${BOLD}Checking for worktrees with merged branches...${NC}"
    echo ""
    
    local found_any=false
    local worktree_path=""
    local worktree_branch=""
    
    local default_branch
    default_branch=$(get_default_branch)
    
    # Fetch to get current remote branch state (detects deleted branches)
    git fetch --prune origin 2>/dev/null || true
    
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
                elif branch_was_pushed "$worktree_branch" && \
                     ! git show-ref --verify --quiet "refs/remotes/origin/$worktree_branch" 2>/dev/null; then
                    is_merged=true
                    merge_type="remote deleted"
                fi
                
                # Safety check: skip if worktree has uncommitted changes
                if [[ "$is_merged" == "true" ]] && worktree_has_changes "$worktree_path"; then
                    echo -e "  ${RED}$worktree_branch${NC} (has uncommitted changes - skipping)"
                    echo "    $worktree_path"
                    echo ""
                    is_merged=false
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
    done < <(git worktree list --porcelain; echo "")
    
    if [[ "$found_any" == "false" ]]; then
        echo -e "${GREEN}No merged worktrees to clean up${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}Remove these worktrees? [y/N]${NC}"
    read -r response
    
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
                    
                    # Safety check: never remove worktrees with uncommitted changes
                    if worktree_has_changes "$worktree_path"; then
                        echo -e "${RED}Skipping $worktree_branch - has uncommitted changes${NC}"
                        should_remove=false
                    # Check 1: Traditional merge
                    elif git branch --merged "$default_branch" 2>/dev/null | grep -q "^\s*$worktree_branch$"; then
                        should_remove=true
                    # Check 2: Remote branch deleted - ONLY if branch was previously pushed
                    elif branch_was_pushed "$worktree_branch" && \
                         ! git show-ref --verify --quiet "refs/remotes/origin/$worktree_branch" 2>/dev/null; then
                        should_remove=true
                    fi
                    
                    if [[ "$should_remove" == "true" ]]; then
                        echo -e "${BLUE}Removing $worktree_branch...${NC}"
                        # Clean up aidevops runtime files before removal
                        rm -rf "$worktree_path/.agent/loop-state" 2>/dev/null || true
                        rm -rf "$worktree_path/.agent/tmp" 2>/dev/null || true
                        rm -f "$worktree_path/.agent/.DS_Store" 2>/dev/null || true
                        rmdir "$worktree_path/.agent" 2>/dev/null || true
                        # Don't use --force to prevent data loss
                        if ! git worktree remove "$worktree_path" 2>/dev/null; then
                            echo -e "${RED}Failed to remove $worktree_branch - may have uncommitted changes${NC}"
                        else
                            # Also delete the local branch
                            git branch -D "$worktree_branch" 2>/dev/null || true
                        fi
                    fi
                fi
                worktree_path=""
                worktree_branch=""
            fi
        done < <(git worktree list --porcelain; echo "")
        
        echo -e "${GREEN}Cleanup complete${NC}"
    else
        echo "Cancelled"
    fi
    
    return 0
}

cmd_help() {
    cat << 'EOF'
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
  
  remove <path|branch>   Remove a worktree (keeps branch)
  
  status                 Show current worktree info
  
  switch <branch>        Get/create worktree for branch (prints path)
  
  clean                  Remove worktrees for merged branches
  
  help                   Show this help

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

DIRECTORY STRUCTURE
  ~/Git/myrepo/                      # Main worktree (main branch)
  ~/Git/myrepo-feature-user-auth/    # Linked worktree (feature/user-auth)
  ~/Git/myrepo-bugfix-login/         # Linked worktree (bugfix/login)

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
        list|ls)
            cmd_list "$@"
            ;;
        remove|rm)
            cmd_remove "$@"
            ;;
        status|st)
            cmd_status "$@"
            ;;
        switch|sw)
            cmd_switch "$@"
            ;;
        clean)
            cmd_clean "$@"
            ;;
        help|--help|-h)
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
