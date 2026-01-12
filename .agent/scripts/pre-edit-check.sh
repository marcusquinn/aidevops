#!/bin/bash
# =============================================================================
# Pre-Edit Git Branch Check
# =============================================================================
# Run this BEFORE any file edit to enforce the git workflow.
# Returns exit code 1 if on main/master branch (should create branch first).
#
# Usage:
#   ~/.aidevops/agents/scripts/pre-edit-check.sh
#   ~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "description"
#
# Exit codes:
#   0 - OK to proceed (on feature branch, or docs-only on main in loop mode)
#   1 - STOP (on protected branch, interactive mode)
#   2 - Create worktree (loop mode detected code task on main)
#
# AI assistants should call this before any Edit/Write tool and STOP if it
# returns a warning about being on main branch.
# =============================================================================

set -euo pipefail

# =============================================================================
# Loop Mode Support
# =============================================================================
# When --loop-mode is passed, the script auto-decides based on task description:
# - Docs-only tasks (README, CHANGELOG, docs/) -> stay on main (exit 0)
# - Code tasks (feature, fix, implement, etc.) -> signal worktree needed (exit 2)

LOOP_MODE=false
TASK_DESC=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --loop-mode)
            LOOP_MODE=true
            shift
            ;;
        --task)
            TASK_DESC="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Function to detect if task is docs-only
is_docs_only() {
    local task="$1"
    # Use tr for lowercase (portable across bash versions including macOS default bash 3.x)
    local task_lower
    task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')
    
    # Code change indicators (negative match - if present, NOT docs-only)
    # These take precedence over docs patterns
    local code_patterns="feature|fix|bug|implement|refactor|add.*function|update.*code|create.*script|modify.*config|change.*logic|new.*api|endpoint|enhance|port|ssl|helper"
    
    # Docs-only indicators (positive match)
    local docs_patterns="^readme|^changelog|^documentation|docs/|typo|spelling|comment only|license only|^update readme|^update changelog|^update docs"
    
    # Check for code patterns first (takes precedence)
    if echo "$task_lower" | grep -qE "$code_patterns"; then
        return 1  # Not docs-only
    fi
    
    # Check for docs patterns
    if echo "$task_lower" | grep -qE "$docs_patterns"; then
        return 0  # Is docs-only
    fi
    
    # Default: not docs-only (safer to create branch)
    return 1
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Check if we're in a git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo -e "${YELLOW}Not in a git repository - no branch check needed${NC}"
    exit 0
fi

# Get current branch
current_branch=$(git branch --show-current 2>/dev/null || echo "")

if [[ -z "$current_branch" ]]; then
    echo -e "${YELLOW}Detached HEAD state - consider creating a branch${NC}"
    exit 0
fi

# Check if on main or master
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
    # Loop mode: auto-decide based on task description
    if [[ "$LOOP_MODE" == "true" ]]; then
        if is_docs_only "$TASK_DESC"; then
            echo -e "${YELLOW}LOOP-AUTO${NC}: Docs-only task detected, staying on $current_branch"
            echo "LOOP_DECISION=stay"
            exit 0
        else
            # Auto-create worktree for code changes
            echo -e "${YELLOW}LOOP-AUTO${NC}: Code task detected, worktree required"
            echo "LOOP_DECISION=worktree"
            exit 2  # Special exit code for "create worktree"
        fi
    fi
    
    # Interactive mode: show warning and exit
    echo ""
    echo -e "${RED}${BOLD}======================================================${NC}"
    echo -e "${RED}${BOLD}  STOP - ON PROTECTED BRANCH: $current_branch${NC}"
    echo -e "${RED}${BOLD}======================================================${NC}"
    echo ""
    echo -e "${YELLOW}You must create a branch before making changes.${NC}"
    echo ""
    echo "Suggested branch names based on change type:"
    echo "  feature/description  - New functionality"
    echo "  bugfix/description   - Bug fixes"
    echo "  chore/description    - Maintenance, docs, config"
    echo "  hotfix/description   - Urgent production fixes"
    echo "  refactor/description - Code restructuring"
    echo ""
    echo -e "${BOLD}Create a worktree (keeps main repo on main):${NC}"
    echo ""
    echo "    ~/.aidevops/agents/scripts/worktree-helper.sh add {type}/{description}"
    echo "    cd ../{repo}-{type}-{description}"
    echo ""
    echo -e "${YELLOW}Why worktrees? The main repo directory should ALWAYS stay on main.${NC}"
    echo -e "${YELLOW}Using 'git checkout -b' here leaves the repo on a feature branch,${NC}"
    echo -e "${YELLOW}which breaks parallel sessions and causes merge conflicts.${NC}"
    echo ""
    echo -e "${RED}DO NOT proceed with edits until on a feature branch.${NC}"
    echo ""
    exit 1
else
    # Check if this is the main repo directory (not a worktree) on a feature branch
    # This is a warning - the main repo should stay on main
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    git_dir=$(git rev-parse --git-dir 2>/dev/null)
    
    # If git-dir equals git-common-dir, this is the main worktree (not a linked worktree)
    is_main_worktree=false
    if [[ "$git_dir" == "$git_common_dir" ]] || [[ "$git_dir" == ".git" ]]; then
        is_main_worktree=true
    fi
    
    if [[ "$is_main_worktree" == "true" ]]; then
        echo -e "${YELLOW}WARNING${NC} - Main repo is on feature branch: ${BOLD}$current_branch${NC}"
        echo -e "${YELLOW}The main repo directory should stay on 'main' for parallel safety.${NC}"
        echo -e "${YELLOW}Consider using a worktree instead, or switch back to main when done.${NC}"
        echo ""
    else
        echo -e "${GREEN}OK${NC} - On branch: ${BOLD}$current_branch${NC}"
    fi
    
    # Sync terminal tab title with repo/branch (silent, non-blocking)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
    if [[ -x "$SCRIPT_DIR/terminal-title-helper.sh" ]]; then
        "$SCRIPT_DIR/terminal-title-helper.sh" sync 2>/dev/null || true
    fi
    
    exit 0
fi
