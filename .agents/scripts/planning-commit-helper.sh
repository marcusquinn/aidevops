#!/usr/bin/env bash
# shellcheck disable=SC2310
# =============================================================================
# Planning File Auto-Commit Helper
# =============================================================================
# Commits and pushes changes to TODO.md and todo/ without branch ceremony.
# Called automatically by Plan+ agent after planning file modifications.
#
# Usage:
#   planning-commit-helper.sh "plan: add new task"
#   planning-commit-helper.sh --check  # Just check if changes exist
#   planning-commit-helper.sh --status # Show planning file status
#
# Exit codes:
#   0 - Success (or no changes to commit)
#   1 - Error (not in git repo, etc.)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Planning file patterns
readonly PLANNING_PATTERNS="^TODO\.md$|^todo/"

log_info() {
    echo -e "${BLUE}[plan]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[plan]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[plan]${NC} $1"
}

log_error() {
    echo -e "${RED}[plan]${NC} $1" >&2
}

# Check if we're in a git repository
check_git_repo() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        log_error "Not in a git repository"
        return 1
    fi
    return 0
}

# Check if there are planning file changes
has_planning_changes() {
    # Check both staged and unstaged changes
    if git diff --name-only HEAD 2>/dev/null | grep -qE "$PLANNING_PATTERNS"; then
        return 0
    fi
    if git diff --name-only --cached 2>/dev/null | grep -qE "$PLANNING_PATTERNS"; then
        return 0
    fi
    # Also check untracked files in todo/
    if git ls-files --others --exclude-standard 2>/dev/null | grep -qE "$PLANNING_PATTERNS"; then
        return 0
    fi
    return 1
}

# List planning file changes
list_planning_changes() {
    local changes=""
    
    # Staged changes
    local staged
    staged=$(git diff --name-only --cached 2>/dev/null | grep -E "$PLANNING_PATTERNS" || true)
    
    # Unstaged changes
    local unstaged
    unstaged=$(git diff --name-only 2>/dev/null | grep -E "$PLANNING_PATTERNS" || true)
    
    # Untracked
    local untracked
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null | grep -E "$PLANNING_PATTERNS" || true)
    
    # Combine unique
    changes=$(echo -e "${staged}\n${unstaged}\n${untracked}" | sort -u | grep -v '^$' || true)
    echo "$changes"
}

# Show status of planning files
show_status() {
    check_git_repo || return 1
    
    echo "Planning file status:"
    echo "====================="
    
    if has_planning_changes; then
        echo -e "${YELLOW}Modified planning files:${NC}"
        list_planning_changes | while read -r file; do
            [[ -n "$file" ]] && echo "  - $file"
        done
    else
        echo -e "${GREEN}No planning file changes${NC}"
    fi
    
    return 0
}

# Main commit function
commit_planning_files() {
    local commit_msg="${1:-plan: update planning files}"
    
    check_git_repo || return 1
    
    # Check for changes
    if ! has_planning_changes; then
        log_info "No planning file changes to commit"
        return 0
    fi
    
    # Show what we're committing
    log_info "Planning files to commit:"
    list_planning_changes | while read -r file; do
        [[ -n "$file" ]] && echo "  - $file"
    done
    
    # Pull latest to avoid conflicts (rebase to keep history clean)
    local current_branch
    current_branch=$(git branch --show-current)
    if git remote get-url origin &>/dev/null; then
        log_info "Pulling latest changes..."
        if ! git pull --rebase origin "$current_branch" 2>/dev/null; then
            log_warning "Pull failed (may be offline or new branch)"
        fi
    fi
    
    # Stage only planning files
    git add TODO.md 2>/dev/null || true
    git add todo/ 2>/dev/null || true
    
    # Check if anything was staged
    if git diff --cached --quiet 2>/dev/null; then
        log_info "No changes staged after adding planning files"
        return 0
    fi
    
    # Commit (skip hooks - planning commits don't need full linting)
    log_info "Committing: $commit_msg"
    if ! git commit -m "$commit_msg" --no-verify; then
        log_error "Commit failed"
        return 1
    fi
    
    # Push (silent fail if offline or no permissions)
    if git remote get-url origin &>/dev/null; then
        log_info "Pushing to remote..."
        if git push origin HEAD 2>/dev/null; then
            log_success "Planning files committed and pushed"
        else
            log_warning "Committed locally (push failed - will retry later)"
        fi
    else
        log_success "Committed locally (no remote configured)"
    fi
    
    return 0
}

# Main
main() {
    case "${1:-}" in
        --check)
            check_git_repo || exit 1
            if has_planning_changes; then
                echo "PLANNING_CHANGES=true"
                exit 0
            else
                echo "PLANNING_CHANGES=false"
                exit 0
            fi
            ;;
        --status)
            show_status
            exit $?
            ;;
        --help|-h)
            echo "Usage: planning-commit-helper.sh [OPTIONS] [COMMIT_MESSAGE]"
            echo ""
            echo "Options:"
            echo "  --check   Check if planning files have changes"
            echo "  --status  Show planning file status"
            echo "  --help    Show this help"
            echo ""
            echo "Examples:"
            echo "  planning-commit-helper.sh 'plan: add new task'"
            echo "  planning-commit-helper.sh --check"
            exit 0
            ;;
        *)
            commit_planning_files "$@"
            exit $?
            ;;
    esac
}

main "$@"
