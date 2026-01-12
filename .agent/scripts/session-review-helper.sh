#!/usr/bin/env bash
# session-review-helper.sh - Gather session context for AI review
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   session-review-helper.sh [command] [options]
#
# Commands:
#   gather    Collect session context (default)
#   summary   Quick summary only
#   json      Output as JSON for programmatic use
#
# Options:
#   --focus <area>  Focus on: objectives, workflow, knowledge, all (default: all)

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Find project root (look for .git or TODO.md)
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.git" ]] || [[ -f "$dir/TODO.md" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    echo "$PWD"
    return 0
}

# Get current branch
get_branch() {
    git branch --show-current 2>/dev/null || echo "not-a-git-repo"
    return 0
}

# Check if on protected branch
is_protected_branch() {
    local branch
    branch=$(get_branch)
    [[ "$branch" == "main" || "$branch" == "master" ]]
    return 0
}

# Get recent commits
get_recent_commits() {
    local count="${1:-10}"
    git log --oneline -"$count" 2>/dev/null || echo "No commits"
    return 0
}

# Get uncommitted changes count
get_uncommitted_changes() {
    local staged unstaged
    staged=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d '[:space:]')
    unstaged=$(git diff --name-only 2>/dev/null | wc -l | tr -d '[:space:]')
    echo "staged:${staged:-0},unstaged:${unstaged:-0}"
    return 0
}

# Get TODO.md status
get_todo_status() {
    local project_root="$1"
    local todo_file="$project_root/TODO.md"
    
    if [[ ! -f "$todo_file" ]]; then
        echo "no-todo-file"
        return
    fi
    
    local completed incomplete in_progress
    completed=$(grep -cE '^\s*- \[x\]' "$todo_file" 2>/dev/null) || completed=0
    incomplete=$(grep -cE '^\s*- \[ \]' "$todo_file" 2>/dev/null) || incomplete=0
    in_progress=$(grep -cE '^\s*- \[>\]' "$todo_file" 2>/dev/null) || in_progress=0
    
    echo "completed:$completed,incomplete:$incomplete,in_progress:$in_progress"
}

# Check for Ralph loop
get_ralph_status() {
    local project_root="$1"
    local ralph_file="$project_root/.claude/ralph-loop.local.md"
    
    if [[ -f "$ralph_file" ]]; then
        local iteration max_iter
        iteration=$(grep '^iteration:' "$ralph_file" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "0")
        max_iter=$(grep '^max_iterations:' "$ralph_file" 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "unlimited")
        echo "active:true,iteration:$iteration,max:$max_iter"
    else
        echo "active:false"
    fi
    return 0
}

# Get open PRs
get_pr_status() {
    if command -v gh &>/dev/null; then
        local open_prs
        open_prs=$(gh pr list --state open --limit 5 --json number,title 2>/dev/null || echo "[]")
        if [[ "$open_prs" == "[]" ]]; then
            echo "no-open-prs"
        else
            echo "$open_prs" | jq -r '.[] | "\(.number):\(.title)"' 2>/dev/null | head -3 || echo "error-parsing"
        fi
    else
        echo "gh-not-installed"
    fi
    return 0
}

# Check workflow adherence
check_workflow_adherence() {
    local project_root="$1"
    local issues=""
    local passed=""
    
    # Check if we're in a git repo
    local is_git_repo=true
    if ! git rev-parse --git-dir &>/dev/null; then
        is_git_repo=false
        issues+="not-a-git-repo,"
    fi
    
    if [[ "$is_git_repo" == "true" ]]; then
        # Check 1: Not on main
        if is_protected_branch; then
            issues+="on-protected-branch,"
        else
            passed+="feature-branch,"
        fi
        
        # Check 2: Recent commits have good messages
        local short_messages
        short_messages=$(git log --oneline -5 2>/dev/null | awk 'length($0) < 15' | wc -l | tr -d ' ' || echo "0")
        short_messages="${short_messages:-0}"
        if [[ "$short_messages" -gt 0 ]]; then
            issues+="short-commit-messages,"
        else
            passed+="good-commit-messages,"
        fi
        
        # Check 3: No secrets in staged files
        if git diff --cached --name-only 2>/dev/null | grep -qE '\.(env|key|pem|secret)$'; then
            issues+="potential-secrets-staged,"
        else
            passed+="no-secrets-staged,"
        fi
    fi
    
    # Check 4: TODO.md exists (works in any directory)
    if [[ -f "$project_root/TODO.md" ]]; then
        passed+="todo-exists,"
    else
        issues+="no-todo-file,"
    fi
    
    echo "passed:${passed%,}|issues:${issues%,}"
    return 0
}

# Gather all context
gather_context() {
    local project_root="$1"
    local focus="${2:-all}"
    
    echo -e "${BOLD}${BLUE}=== Session Review Context ===${NC}"
    echo ""
    
    # Basic info
    echo -e "${CYAN}## Environment${NC}"
    echo "Project: $project_root"
    echo "Branch: $(get_branch)"
    echo "Date: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    
    if [[ "$focus" == "all" || "$focus" == "objectives" ]]; then
        echo -e "${CYAN}## Objective Status${NC}"
        echo "Recent commits:"
        get_recent_commits 5 | sed 's/^/  /'
        echo ""
        echo "Uncommitted: $(get_uncommitted_changes)"
        echo "TODO status: $(get_todo_status "$project_root")"
        echo ""
    fi
    
    if [[ "$focus" == "all" || "$focus" == "workflow" ]]; then
        echo -e "${CYAN}## Workflow Adherence${NC}"
        local adherence
        adherence=$(check_workflow_adherence "$project_root")
        local passed issues
        passed=$(echo "$adherence" | cut -d'|' -f1 | cut -d: -f2)
        issues=$(echo "$adherence" | cut -d'|' -f2 | cut -d: -f2)
        
        if [[ -n "$passed" ]]; then
            echo -e "${GREEN}Passed:${NC}"
            echo "$passed" | tr ',' '\n' | sed 's/^/  - /' | grep -v '^  - $'
        fi
        
        if [[ -n "$issues" ]]; then
            echo -e "${YELLOW}Issues:${NC}"
            echo "$issues" | tr ',' '\n' | sed 's/^/  - /' | grep -v '^  - $'
        fi
        echo ""
    fi
    
    if [[ "$focus" == "all" || "$focus" == "knowledge" ]]; then
        echo -e "${CYAN}## Session Context${NC}"
        echo "Ralph loop: $(get_ralph_status "$project_root")"
        echo "Open PRs: $(get_pr_status)"
        echo ""
    fi
    
    # Recommendations
    echo -e "${CYAN}## Quick Recommendations${NC}"
    
    if is_protected_branch; then
        echo -e "${RED}! Create feature branch before making changes${NC}"
    fi
    
    local todo_status
    todo_status=$(get_todo_status "$project_root")
    # Only show TODO stats if we have a valid TODO file
    if [[ "$todo_status" != "no-todo-file" ]]; then
        local incomplete
        incomplete=$(echo "$todo_status" | grep -oE 'incomplete:[0-9]+' | cut -d: -f2 || echo "0")
        incomplete="${incomplete:-0}"
        if [[ "$incomplete" -gt 0 ]]; then
            echo "- $incomplete incomplete tasks in TODO.md"
        fi
    fi
    
    local changes
    changes=$(get_uncommitted_changes)
    local staged unstaged
    # Extract staged count (match 'staged:N' at start, before comma)
    staged=$(echo "$changes" | sed -n 's/^staged:\([0-9]*\),.*/\1/p')
    # Extract unstaged count (match 'unstaged:N' after comma)
    unstaged=$(echo "$changes" | sed -n 's/.*,unstaged:\([0-9]*\)$/\1/p')
    staged="${staged:-0}"
    unstaged="${unstaged:-0}"
    if [[ "$staged" -gt 0 ]] || [[ "$unstaged" -gt 0 ]]; then
        echo "- Uncommitted changes: $staged staged, $unstaged unstaged"
    fi
    
    echo ""
    echo -e "${BOLD}Run /session-review in AI assistant for full analysis${NC}"
    return 0
}

# Output as JSON
output_json() {
    local project_root="$1"
    
    local branch todo_status ralph_status adherence changes
    branch=$(get_branch)
    todo_status=$(get_todo_status "$project_root")
    ralph_status=$(get_ralph_status "$project_root")
    adherence=$(check_workflow_adherence "$project_root")
    changes=$(get_uncommitted_changes)
    
    # Extract values using sed for reliable parsing
    local completed incomplete in_progress staged unstaged
    completed=$(echo "$todo_status" | sed -n 's/.*completed:\([0-9]*\).*/\1/p')
    incomplete=$(echo "$todo_status" | sed -n 's/.*incomplete:\([0-9]*\).*/\1/p')
    in_progress=$(echo "$todo_status" | sed -n 's/.*in_progress:\([0-9]*\).*/\1/p')
    staged=$(echo "$changes" | sed -n 's/^staged:\([0-9]*\),.*/\1/p')
    unstaged=$(echo "$changes" | sed -n 's/.*,unstaged:\([0-9]*\)$/\1/p')
    
    cat <<EOF
{
  "project": "$project_root",
  "branch": "$branch",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "todo": {
    "completed": ${completed:-0},
    "incomplete": ${incomplete:-0},
    "in_progress": ${in_progress:-0}
  },
  "changes": {
    "staged": ${staged:-0},
    "unstaged": ${unstaged:-0}
  },
  "ralph_loop": {
    "active": $(echo "$ralph_status" | grep -q 'active:true' && echo "true" || echo "false")
  },
  "workflow": {
    "on_protected_branch": $(is_protected_branch && echo "true" || echo "false")
  }
}
EOF
    return 0
}

# Quick summary
output_summary() {
    local project_root="$1"
    
    echo "Branch: $(get_branch)"
    echo "TODO: $(get_todo_status "$project_root")"
    echo "Changes: $(get_uncommitted_changes)"
    
    if is_protected_branch; then
        echo -e "${RED}WARNING: On protected branch${NC}"
    fi
    
    return 0
}

# Show help
show_help() {
    cat <<EOF
session-review-helper.sh - Gather session context for AI review

Usage:
  session-review-helper.sh [command] [options]

Commands:
  gather    Collect session context (default)
  summary   Quick summary only
  json      Output as JSON for programmatic use
  help      Show this help

Options:
  --focus <area>  Focus on: objectives, workflow, knowledge, all (default: all)

Examples:
  session-review-helper.sh                    # Full context gathering
  session-review-helper.sh summary            # Quick summary
  session-review-helper.sh json               # JSON output
  session-review-helper.sh gather --focus workflow  # Focus on workflow

EOF
    return 0
}

# Main
main() {
    local command="gather"
    local focus="all"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            gather|summary|json|help)
                command="$1"
                ;;
            --focus)
                shift
                focus="${1:-all}"
                ;;
            --help|-h)
                command="help"
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_help
                exit 1
                ;;
        esac
        shift
    done
    
    local project_root
    project_root=$(find_project_root)
    
    case "$command" in
        gather)
            gather_context "$project_root" "$focus"
            ;;
        summary)
            output_summary "$project_root"
            ;;
        json)
            output_json "$project_root"
            ;;
        help)
            show_help
            ;;
        *)
            gather_context "$project_root" "$focus"
            ;;
    esac
    
    return 0
}

main "$@"
exit $?
