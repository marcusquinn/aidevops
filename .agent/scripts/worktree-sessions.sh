#!/bin/bash
# shellcheck disable=SC2034,SC2155

# =============================================================================
# Worktree Session Mapper
# =============================================================================
# Maps git worktrees to likely OpenCode sessions based on:
# - Session titles matching branch names
# - Session timestamps near worktree creation
# - Commit history correlation
#
# Usage:
#   worktree-sessions.sh [command]
#
# Commands:
#   list       List worktrees with likely sessions (default)
#   open       Interactive: select worktree and open session
#   help       Show this help
# =============================================================================

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# OpenCode session storage
readonly SESSION_BASE="$HOME/.local/share/opencode/storage/session"
readonly PROJECT_BASE="$HOME/.local/share/opencode/storage/project"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

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

# Get project ID hash for a directory
get_project_id() {
    local dir="$1"
    # OpenCode uses a hash of the directory path
    # We need to find it by matching the directory in project files
    for project_file in "$PROJECT_BASE"/*.json; do
        if [[ -f "$project_file" ]]; then
            local project_dir
            project_dir=$(jq -r '.worktree // .path // .directory // ""' "$project_file" 2>/dev/null)
            if [[ "$project_dir" == "$dir" ]]; then
                basename "$project_file" .json
                return 0
            fi
        fi
    done
    echo ""
}

# Convert epoch seconds to readable date (portable)
epoch_sec_to_date() {
    local epoch_sec="$1"
    if [[ -n "$epoch_sec" ]] && [[ "$epoch_sec" != "0" ]]; then
        # Portable date formatting (BSD: -r, GNU: -d @)
        if date --version &>/dev/null 2>&1; then
            # GNU date
            date -d "@$epoch_sec" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown"
        else
            # BSD date (macOS)
            date -r "$epoch_sec" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

# Convert epoch milliseconds to readable date (portable)
epoch_to_date() {
    local epoch_ms="$1"
    if [[ -n "$epoch_ms" ]] && [[ "$epoch_ms" != "null" ]]; then
        epoch_sec_to_date "$((epoch_ms/1000))"
    else
        echo "unknown"
    fi
}

# Get the default branch (main or master)
get_default_branch() {
    local worktree_path="${1:-.}"
    # Try to get from remote HEAD
    local default_branch
    default_branch=$(git -C "$worktree_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    
    if [[ -n "$default_branch" ]]; then
        echo "$default_branch"
        return 0
    fi
    
    # Fallback: check if main or master exists
    if git -C "$worktree_path" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
        echo "main"
    elif git -C "$worktree_path" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
        echo "master"
    else
        echo "main"
    fi
}

# Get first commit date on branch (divergence from default branch)
get_branch_start_date() {
    local worktree_path="$1"
    local branch="$2"
    
    # Detect default branch
    local default_branch
    default_branch=$(get_default_branch "$worktree_path")
    
    # Get the first commit unique to this branch (non-fatal if fails)
    local first_commit_date
    first_commit_date=$(git -C "$worktree_path" log "$default_branch..$branch" --format="%ct" --reverse 2>/dev/null | head -1) || true
    
    if [[ -n "$first_commit_date" ]]; then
        echo "$first_commit_date"
    else
        # No unique commits, use worktree creation time (directory mtime)
        # Portable stat (BSD: -f "%m", GNU: -c "%Y")
        if stat --version &>/dev/null 2>&1; then
            stat -c "%Y" "$worktree_path" 2>/dev/null || echo ""
        else
            stat -f "%m" "$worktree_path" 2>/dev/null || echo ""
        fi
    fi
}

# Search sessions for matches
find_matching_sessions() {
    local branch="$1"
    local project_id="$2"
    local branch_start_epoch="$3"
    local worktree_path="$4"
    
    local session_dir="$SESSION_BASE/$project_id"
    
    if [[ ! -d "$session_dir" ]]; then
        return
    fi
    
    # Normalize branch name for matching
    local branch_slug
    branch_slug=$(echo "$branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
    local branch_parts
    IFS='/' read -ra branch_parts <<< "$branch"
    local branch_name="${branch_parts[${#branch_parts[@]}-1]}"
    
    # Search criteria weights
    local matches=()
    
    for session_file in "$session_dir"/ses_*.json; do
        if [[ ! -f "$session_file" ]]; then
            continue
        fi
        
        local session_id
        local session_title
        local session_updated
        local session_created
        local score=0
        
        session_id=$(jq -r '.id // ""' "$session_file" 2>/dev/null)
        session_title=$(jq -r '.title // ""' "$session_file" 2>/dev/null)
        session_updated=$(jq -r '.time.updated // 0' "$session_file" 2>/dev/null)
        session_created=$(jq -r '.time.created // 0' "$session_file" 2>/dev/null)
        
        # Skip empty sessions
        if [[ -z "$session_title" ]] || [[ "$session_title" == "null" ]]; then
            continue
        fi
        
        # Scoring: exact branch name match (highest)
        if [[ "$session_title" == "$branch" ]]; then
            score=$((score + 100))
        fi
        
        # Scoring: branch slug in title (case-insensitive)
        if echo "$session_title" | grep -qi "$branch_slug"; then
            score=$((score + 80))
        fi
        
        # Scoring: branch name (without type prefix) in title
        if echo "$session_title" | grep -qi "$branch_name"; then
            score=$((score + 60))
        fi
        
        # Scoring: key terms from branch name
        for part in "${branch_parts[@]}"; do
            if [[ ${#part} -gt 3 ]] && echo "$session_title" | grep -qi "$part"; then
                score=$((score + 20))
            fi
        done
        
        # Scoring: temporal proximity (within 1 hour of branch creation)
        if [[ -n "$branch_start_epoch" ]] && [[ "$branch_start_epoch" != "0" ]]; then
            local branch_start_ms=$((branch_start_epoch * 1000))
            local time_diff
            
            # Check created time
            if [[ "$session_created" != "0" ]] && [[ "$session_created" != "null" ]]; then
                time_diff=$((session_created - branch_start_ms))
                if [[ $time_diff -lt 0 ]]; then
                    time_diff=$((time_diff * -1))
                fi
                # Within 1 hour
                if [[ $time_diff -lt 3600000 ]]; then
                    score=$((score + 40))
                # Within 4 hours
                elif [[ $time_diff -lt 14400000 ]]; then
                    score=$((score + 20))
                fi
            fi
        fi
        
        # Only include if score > 0
        if [[ $score -gt 0 ]]; then
            local updated_str
            updated_str=$(epoch_to_date "$session_updated")
            matches+=("$score|$session_id|$session_title|$updated_str")
        fi
    done
    
    # Sort by score descending and output top 3
    printf '%s\n' "${matches[@]}" 2>/dev/null | sort -t'|' -k1 -rn | head -3
}

# =============================================================================
# COMMANDS
# =============================================================================

cmd_list() {
    echo -e "${BOLD}Worktree Session Mapping${NC}"
    echo ""
    
    local repo_root
    repo_root=$(get_repo_root)
    
    if [[ -z "$repo_root" ]]; then
        echo -e "${RED}Error: Not in a git repository${NC}"
        return 1
    fi
    
    # Get project ID for main repo
    local main_project_id
    main_project_id=$(get_project_id "$repo_root")
    
    if [[ -z "$main_project_id" ]]; then
        echo -e "${YELLOW}Warning: No OpenCode project found for this repository${NC}"
        echo "Sessions may be stored under a different project ID"
        echo ""
    fi
    
    # Parse worktrees
    local worktree_path=""
    local worktree_branch=""
    local count=0
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
            worktree_path="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
            worktree_branch="${BASH_REMATCH[1]}"
        elif [[ -z "$line" ]]; then
            # End of entry
            if [[ -n "$worktree_path" ]] && [[ -n "$worktree_branch" ]]; then
                # Skip main branch
                if [[ "$worktree_branch" == "main" ]] || [[ "$worktree_branch" == "master" ]]; then
                    worktree_path=""
                    worktree_branch=""
                    continue
                fi
                
                count=$((count + 1))
                
                echo -e "${BOLD}[$count] $worktree_branch${NC}"
                echo -e "    ${DIM}Path: $worktree_path${NC}"
                
                # Get branch start time
                local branch_start
                branch_start=$(get_branch_start_date "$worktree_path" "$worktree_branch")
                
                if [[ -n "$branch_start" ]]; then
                    local start_date
                    start_date=$(epoch_sec_to_date "$branch_start")
                    echo -e "    ${DIM}Branch started: $start_date${NC}"
                fi
                
                # Get last commit info
                local last_commit
                last_commit=$(git -C "$worktree_path" log -1 --format="%s" 2>/dev/null | head -c 60)
                local last_commit_date
                last_commit_date=$(git -C "$worktree_path" log -1 --format="%ci" 2>/dev/null | cut -d' ' -f1,2)
                
                if [[ -n "$last_commit" ]]; then
                    echo -e "    ${DIM}Last commit: $last_commit_date${NC}"
                fi
                
                echo ""
                
                # Find matching sessions
                if [[ -n "$main_project_id" ]]; then
                    local matches
                    matches=$(find_matching_sessions "$worktree_branch" "$main_project_id" "$branch_start" "$worktree_path")
                    
                    if [[ -n "$matches" ]]; then
                        echo -e "    ${CYAN}Likely sessions:${NC}"
                        while IFS='|' read -r score session_id title updated; do
                            local confidence
                            if [[ $score -ge 80 ]]; then
                                confidence="${GREEN}high${NC}"
                            elif [[ $score -ge 40 ]]; then
                                confidence="${YELLOW}medium${NC}"
                            else
                                confidence="${DIM}low${NC}"
                            fi
                            echo -e "    - ${BOLD}$title${NC}"
                            echo -e "      ID: $session_id"
                            echo -e "      Updated: $updated | Confidence: $confidence"
                        done <<< "$matches"
                    else
                        echo -e "    ${DIM}No matching sessions found${NC}"
                    fi
                fi
                
                echo ""
                echo -e "    ${DIM}─────────────────────────────────────────${NC}"
                echo ""
            fi
            worktree_path=""
            worktree_branch=""
        fi
    done < <(git worktree list --porcelain; echo "")
    
    if [[ $count -eq 0 ]]; then
        echo -e "${GREEN}No linked worktrees found (only main)${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${BOLD}To resume work:${NC}"
    echo "  1. cd <worktree-path>" || exit
    echo "  2. Open OpenCode (it will show recent sessions)"
    echo "  3. Use Ctrl+P to browse sessions by title"
    echo ""
    echo -e "${DIM}Tip: Session names sync with branch names when using session-rename_sync_branch${NC}"
    
    return 0
}

cmd_open() {
    echo -e "${BOLD}Interactive Worktree Session Opener${NC}"
    echo ""
    
    local repo_root
    repo_root=$(get_repo_root)
    
    if [[ -z "$repo_root" ]]; then
        echo -e "${RED}Error: Not in a git repository${NC}"
        return 1
    fi
    
    # Collect worktrees
    local worktrees=()
    local branches=()
    local worktree_path=""
    local worktree_branch=""
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
            worktree_path="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
            worktree_branch="${BASH_REMATCH[1]}"
        elif [[ -z "$line" ]]; then
            if [[ -n "$worktree_path" ]] && [[ -n "$worktree_branch" ]]; then
                if [[ "$worktree_branch" != "main" ]] && [[ "$worktree_branch" != "master" ]]; then
                    worktrees+=("$worktree_path")
                    branches+=("$worktree_branch")
                fi
            fi
            worktree_path=""
            worktree_branch=""
        fi
    done < <(git worktree list --porcelain; echo "")
    
    if [[ ${#worktrees[@]} -eq 0 ]]; then
        echo -e "${GREEN}No linked worktrees to open${NC}"
        return 0
    fi
    
    # Display options
    echo "Select a worktree to open:"
    echo ""
    for i in "${!branches[@]}"; do
        echo "  $((i+1)). ${branches[$i]}"
        echo "     ${worktrees[$i]}"
    done
    echo ""
    echo "  0. Cancel"
    echo ""
    
    read -rp "Enter number: " choice
    
    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        echo "Cancelled"
        return 0
    fi
    
    # Validate input is a number
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input: please enter a number${NC}"
        return 1
    fi
    
    local index=$((choice - 1))
    if [[ $index -lt 0 ]] || [[ $index -ge ${#worktrees[@]} ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return 1
    fi
    
    local selected_path="${worktrees[$index]}"
    local selected_branch="${branches[$index]}"
    
    echo ""
    echo -e "${BLUE}Opening worktree: $selected_branch${NC}"
    echo ""
    
    # Try to launch OpenCode (CLI first, then app bundle)
    if command -v opencode &>/dev/null; then
        echo "Launching OpenCode via CLI..."
        (cd "$selected_path" && opencode .) & || exit
    elif [[ "$(uname)" == "Darwin" ]] && { [[ -d "/Applications/OpenCode.app" ]] || [[ -d "$HOME/Applications/OpenCode.app" ]]; }; then
        echo "Launching OpenCode..."
        open -a "OpenCode" "$selected_path"
    elif command -v xdg-open &>/dev/null; then
        echo "Opening with default application..."
        xdg-open "$selected_path"
    else
        echo "OpenCode not found. To open manually:"
        echo "  cd $selected_path" || exit
        echo "  opencode .  # or launch your preferred editor"
    fi
    
    return 0
}

cmd_help() {
    cat << 'EOF'
Worktree Session Mapper - Find OpenCode sessions for worktrees

OVERVIEW
  Maps git worktrees to likely OpenCode sessions by analyzing:
  - Session titles matching branch names
  - Temporal proximity to branch creation
  - Keyword matching from branch names

COMMANDS
  list       List all worktrees with likely matching sessions (default)
  open       Interactive selection to open a worktree in OpenCode
  help       Show this help

EXAMPLES
  # See all worktrees and their likely sessions
  worktree-sessions.sh list
  
  # Interactively open a worktree
  worktree-sessions.sh open

HOW MATCHING WORKS
  Sessions are scored based on:
  - Exact branch name in title: +100 points
  - Branch slug in title: +80 points  
  - Branch name (without type/) in title: +60 points
  - Key terms from branch: +20 points each
  - Created within 1 hour of branch: +40 points
  - Created within 4 hours of branch: +20 points

  Confidence levels:
  - High (80+): Very likely the correct session
  - Medium (40-79): Probably related
  - Low (<40): Possible match

TIPS
  - Use session-rename_sync_branch tool after creating branches
  - Session titles that match branch names are easier to find
  - OpenCode stores sessions per-project, not per-worktree

EOF
    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local command="${1:-list}"
    shift || true
    
    case "$command" in
        list|ls)
            cmd_list "$@"
            ;;
        open|o)
            cmd_open "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}"
            echo "Run 'worktree-sessions.sh help' for usage"
            return 1
            ;;
    esac
}

main "$@"
