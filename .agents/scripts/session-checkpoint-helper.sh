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
#   continuation      Generate structured continuation prompt for new sessions
#   auto-save         Auto-detect state and save (no manual flags needed)
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
    
    # Auto-recall relevant memories after loading checkpoint
    local memory_helper="$HOME/.aidevops/agents/scripts/memory-helper.sh"
    if [[ -x "$memory_helper" ]]; then
        echo ""
        echo "## Relevant Memories (from prior sessions)"
        echo ""
        
        # Recall recent memories to provide context for resumed session
        local memories
        memories=$("$memory_helper" recall --recent --limit 5 --format text 2>/dev/null || echo "")
        
        if [[ -n "$memories" && "$memories" != *"No memories found"* ]]; then
            echo "$memories"
        else
            echo "No recent memories found."
        fi
    fi
    
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

cmd_continuation() {
    # Generate a structured continuation prompt that can be fed to a new session
    # to fully reconstruct operational state. This is the single highest-impact
    # factor for session continuity through context compaction.

    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")"
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    local repo_name
    repo_name="$(basename "$repo_root")"

    # Gather git state
    local uncommitted
    uncommitted="$(git status --short 2>/dev/null || echo "")"
    local recent_commits
    recent_commits="$(git log --oneline -5 2>/dev/null || echo "none")"
    local worktrees
    worktrees="$(git worktree list 2>/dev/null || echo "none")"

    # Gather open PRs for this branch
    local open_prs
    open_prs="$(gh pr list --state open --json number,title,headRefName --jq '.[] | "#\(.number) [\(.headRefName)] \(.title)"' 2>/dev/null || echo "none")"

    # Gather supervisor batch state (if supervisor DB exists)
    local batch_state="none"
    local supervisor_helper="${SCRIPT_DIR}/supervisor-helper.sh"
    if [[ -x "$supervisor_helper" ]]; then
        batch_state="$(bash "$supervisor_helper" list --active 2>/dev/null || echo "none")"
    fi

    # Gather TODO.md in-progress tasks
    local todo_tasks="none"
    local todo_file
    for todo_file in "${repo_root}/TODO.md" "$(pwd)/TODO.md"; do
        if [[ -f "$todo_file" ]]; then
            todo_tasks="$(grep -E '^\s*- \[ \] ' "$todo_file" 2>/dev/null | head -10 || echo "none")"
            break
        fi
    done

    # Load existing checkpoint note if available
    local checkpoint_note="none"
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        checkpoint_note="$(awk '/^## Context Note$/,/^## /' "$CHECKPOINT_FILE" | sed '1d;/^## /d' | sed '/^$/d' || echo "none")"
    fi

    # Gather memory recall for recent session context
    local recent_memories="none"
    local memory_helper="${SCRIPT_DIR}/memory-helper.sh"
    if [[ -x "$memory_helper" ]]; then
        recent_memories="$(bash "$memory_helper" recall --recent --limit 3 2>/dev/null || echo "none")"
    fi

    # Output the continuation prompt
    cat <<CONTINUATION_EOF
## Session Continuation Prompt

**Generated**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Repository**: ${repo_name} (${repo_root})
**Branch**: ${branch}

### Operational State

**Active tasks (from TODO.md)**:
${todo_tasks}

**Supervisor batch state**:
${batch_state}

**Open PRs**:
${open_prs}

### Git State

**Uncommitted changes**:
${uncommitted:-clean working tree}

**Recent commits**:
${recent_commits}

**Active worktrees**:
${worktrees}

### Context

**Last checkpoint note**:
${checkpoint_note}

**Recent memories**:
${recent_memories}

### Instructions

Resume work from the state above. Read TODO.md for the full task list.
Run \`session-checkpoint-helper.sh load\` for the last checkpoint.
Run \`pre-edit-check.sh\` before any file modifications.
CONTINUATION_EOF

    # Note: output goes to stdout for piping/capture. Status messages go to stderr.
    print_success "Continuation prompt generated" >&2
    return 0
}

cmd_auto_save() {
    # Auto-detect state and save checkpoint without requiring manual flags.
    # Designed for use in autonomous loops where the agent calls this after
    # each task completion without needing to know the exact flags.

    local current_task=""
    local next_tasks=""
    local note=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task) [[ $# -lt 2 ]] && { print_error "--task requires a value"; return 1; }; current_task="$2"; shift 2 ;;
            --next) [[ $# -lt 2 ]] && { print_error "--next requires a value"; return 1; }; next_tasks="$2"; shift 2 ;;
            --note) [[ $# -lt 2 ]] && { print_error "--note requires a value"; return 1; }; note="$2"; shift 2 ;;
            *) print_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Auto-detect branch and worktree
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    local worktree
    worktree="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

    # Auto-detect batch from supervisor if not provided
    local batch=""
    local supervisor_helper="${SCRIPT_DIR}/supervisor-helper.sh"
    if [[ -x "$supervisor_helper" ]]; then
        batch="$(bash "$supervisor_helper" list --active --format=id 2>/dev/null | head -1 || echo "")"
    fi

    # Auto-detect next tasks from TODO.md if not provided
    if [[ -z "$next_tasks" ]]; then
        local todo_file
        for todo_file in "$(pwd)/TODO.md" "${worktree}/TODO.md"; do
            if [[ -f "$todo_file" ]]; then
                next_tasks="$(grep -E '^\s*- \[ \] t[0-9]' "$todo_file" 2>/dev/null | head -3 | sed 's/.*\(t[0-9][0-9]*[^ ]*\).*/\1/' | tr '\n' ',' | sed 's/,$//' || echo "")"
                break
            fi
        done
    fi

    # Build save command args
    local -a save_args=()
    [[ -n "$current_task" ]] && save_args+=(--task "$current_task")
    [[ -n "$next_tasks" ]] && save_args+=(--next "$next_tasks")
    [[ -n "$worktree" ]] && save_args+=(--worktree "$worktree")
    [[ -n "$branch" ]] && save_args+=(--branch "$branch")
    [[ -n "$batch" ]] && save_args+=(--batch "$batch")
    [[ -n "$note" ]] && save_args+=(--note "$note")

    cmd_save "${save_args[@]}"
    return $?
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
        save)         cmd_save "$@" ;;
        load)         cmd_load ;;
        continuation) cmd_continuation ;;
        auto-save)    cmd_auto_save "$@" ;;
        clear)        cmd_clear ;;
        status)       cmd_status ;;
        help|-h|--help) cmd_help ;;
        *)
            print_error "Unknown command: ${command}"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
