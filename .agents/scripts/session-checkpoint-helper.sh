#!/usr/bin/env bash
# session-checkpoint-helper.sh - Persist session state to survive context compaction
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   session-checkpoint-helper.sh [command] [options]
#
# Commands:
#   save              Save current session checkpoint
#   load              Load and display current checkpoint
#   clear             Remove checkpoint file
#   status            Show checkpoint age and summary
#   help              Show this help
#
# Options:
#   --task <id>       Current task ID (e.g., t135.9)
#   --next <ids>      Comma-separated next task IDs
#   --worktree <path> Active worktree path
#   --branch <name>   Active branch name
#   --batch <name>    Batch/PR name
#   --note <text>     Free-form context note
#   --elapsed <mins>  Minutes elapsed in session
#   --target <mins>   Target session duration in minutes
#
# The checkpoint file is written to:
#   ~/.aidevops/.agent-workspace/tmp/session-checkpoint.md
#
# Design: AI agent writes checkpoint after each task completion and reads it
# before starting the next task. Survives context compaction because state
# is on disk, not in context window.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly CHECKPOINT_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
readonly CHECKPOINT_FILE="${CHECKPOINT_DIR}/session-checkpoint.md"

readonly BOLD='\033[1m'
readonly DIM='\033[2m'

ensure_dir() {
    if [[ ! -d "$CHECKPOINT_DIR" ]]; then
        mkdir -p "$CHECKPOINT_DIR"
    fi
    return 0
}

cmd_save() {
    local current_task=""
    local next_tasks=""
    local worktree_path=""
    local branch_name=""
    local batch_name=""
    local note=""
    local elapsed_mins=""
    local target_mins=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task) [[ $# -lt 2 ]] && { print_error "--task requires a value"; return 1; }; current_task="$2"; shift 2 ;;
            --next) [[ $# -lt 2 ]] && { print_error "--next requires a value"; return 1; }; next_tasks="$2"; shift 2 ;;
            --worktree) [[ $# -lt 2 ]] && { print_error "--worktree requires a value"; return 1; }; worktree_path="$2"; shift 2 ;;
            --branch) [[ $# -lt 2 ]] && { print_error "--branch requires a value"; return 1; }; branch_name="$2"; shift 2 ;;
            --batch) [[ $# -lt 2 ]] && { print_error "--batch requires a value"; return 1; }; batch_name="$2"; shift 2 ;;
            --note) [[ $# -lt 2 ]] && { print_error "--note requires a value"; return 1; }; note="$2"; shift 2 ;;
            --elapsed) [[ $# -lt 2 ]] && { print_error "--elapsed requires a value"; return 1; }; elapsed_mins="$2"; shift 2 ;;
            --target) [[ $# -lt 2 ]] && { print_error "--target requires a value"; return 1; }; target_mins="$2"; shift 2 ;;
            *) print_error "Unknown option: $1"; return 1 ;;
        esac
    done

    ensure_dir

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Auto-detect git state if not provided
    if [[ -z "$branch_name" ]]; then
        branch_name="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    fi

    # Build checkpoint file
    cat > "$CHECKPOINT_FILE" <<EOF
# Session Checkpoint

Updated: ${timestamp}

## Current State

| Field | Value |
|-------|-------|
| Current Task | ${current_task:-none} |
| Branch | ${branch_name} |
| Worktree | ${worktree_path:-not set} |
| Batch/PR | ${batch_name:-not set} |
| Elapsed | ${elapsed_mins:-unknown} min |
| Target | ${target_mins:-unknown} min |

## Next Tasks

${next_tasks:-No next tasks specified}

## Context Note

${note:-No additional context}

## Git Status

$(git status --short 2>/dev/null || echo "Not in a git repo")

## Recent Commits (this branch)

$(git log --oneline -5 2>/dev/null || echo "No commits")

## Open Worktrees

$(git worktree list 2>/dev/null || echo "No worktrees")
EOF

    print_success "Checkpoint saved: ${CHECKPOINT_FILE}"
    print_info "Task: ${current_task:-none} | Branch: ${branch_name} | ${timestamp}"
    return 0
}

cmd_load() {
    if [[ ! -f "$CHECKPOINT_FILE" ]]; then
        print_warning "No checkpoint found at ${CHECKPOINT_FILE}"
        print_info "Run: session-checkpoint-helper.sh save --task <id> --next <ids>"
        return 1
    fi

    cat "$CHECKPOINT_FILE"
    return 0
}

cmd_clear() {
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        rm "$CHECKPOINT_FILE"
        print_success "Checkpoint cleared"
    else
        print_info "No checkpoint to clear"
    fi
    return 0
}

cmd_status() {
    if [[ ! -f "$CHECKPOINT_FILE" ]]; then
        print_warning "No active checkpoint"
        return 1
    fi

    local file_age_seconds
    local now
    local file_mtime

    now="$(date +%s)"
    if [[ "$(uname)" == "Darwin" ]]; then
        file_mtime="$(stat -f %m "$CHECKPOINT_FILE")"
    else
        file_mtime="$(stat -c %Y "$CHECKPOINT_FILE")"
    fi
    file_age_seconds=$(( now - file_mtime ))

    local age_display
    if [[ $file_age_seconds -lt 60 ]]; then
        age_display="${file_age_seconds}s ago"
    elif [[ $file_age_seconds -lt 3600 ]]; then
        age_display="$(( file_age_seconds / 60 ))m ago"
    else
        age_display="$(( file_age_seconds / 3600 ))h $(( (file_age_seconds % 3600) / 60 ))m ago"
    fi

    # Extract key fields
    local current_task
    current_task="$(awk -F'|' '/Current Task/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit}' "$CHECKPOINT_FILE" || echo "unknown")"
    local branch
    branch="$(awk -F'|' '/Branch/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit}' "$CHECKPOINT_FILE" || echo "unknown")"

    printf '%b\n' "${BOLD}Checkpoint Status${NC}"
    printf "  Age:    %s\n" "$age_display"
    printf "  Task:   %s\n" "$current_task"
    printf "  Branch: %s\n" "$branch"
    printf "  File:   %s\n" "$CHECKPOINT_FILE"

    if [[ $file_age_seconds -gt 1800 ]]; then
        print_warning "  Warning: Checkpoint is stale (>30min). Consider updating."
    fi
    return 0
}

cmd_help() {
    # Extract header comment block as help text
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    return 0
}

# Main dispatch
main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        save)    cmd_save "$@" ;;
        load)    cmd_load ;;
        clear)   cmd_clear ;;
        status)  cmd_status ;;
        help|-h|--help) cmd_help ;;
        *)
            print_error "Unknown command: ${command}"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
