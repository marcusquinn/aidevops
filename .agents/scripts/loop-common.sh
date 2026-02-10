#!/usr/bin/env bash
# =============================================================================
# Loop Common - Shared Infrastructure for All Loop Components
# =============================================================================
# Provides shared functions for ralph-loop, quality-loop, and full-loop:
# - State management (JSON-based, survives session restart)
# - Re-anchor prompt generation
# - Receipt verification
# - Memory integration
#
# Based on flow-next architecture: fresh context per iteration, file I/O as state
# Reference: https://github.com/gmickel/gmickel-claude-marketplace/tree/main/plugins/flow-next
#
# Usage:
#   source ~/.aidevops/agents/scripts/loop-common.sh
#
# Author: AI DevOps Framework
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

# Resolve script directory for sibling script references
LOOP_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly LOOP_COMMON_DIR

# Source shared constants for cleanup stack utilities (t196)
# shellcheck source=shared-constants.sh
source "${LOOP_COMMON_DIR}/shared-constants.sh"

readonly LOOP_MAIL_HELPER="${LOOP_COMMON_DIR}/mail-helper.sh"
readonly LOOP_MEMORY_HELPER="${LOOP_COMMON_DIR}/memory-helper.sh"

readonly LOOP_STATE_DIR="${LOOP_STATE_DIR:-.agents/loop-state}"
readonly LOOP_STATE_FILE="${LOOP_STATE_DIR}/loop-state.json"
readonly LOOP_RECEIPTS_DIR="${LOOP_STATE_DIR}/receipts"
readonly LOOP_REANCHOR_FILE="${LOOP_STATE_DIR}/re-anchor.md"

# Context-remaining guard thresholds (t247.1)
# Iteration-based: trigger guard when iteration >= max * threshold
readonly LOOP_CONTEXT_ITER_THRESHOLD="${LOOP_CONTEXT_ITER_THRESHOLD:-80}"
# Output shrinkage: trigger when output drops below this % of rolling average
readonly LOOP_CONTEXT_SHRINK_THRESHOLD="${LOOP_CONTEXT_SHRINK_THRESHOLD:-20}"
# Minimum iterations before shrinkage detection activates (need baseline)
readonly LOOP_CONTEXT_SHRINK_MIN_ITERS="${LOOP_CONTEXT_SHRINK_MIN_ITERS:-3}"
# Minimum output bytes to consider an iteration "productive"
readonly LOOP_CONTEXT_MIN_OUTPUT_BYTES="${LOOP_CONTEXT_MIN_OUTPUT_BYTES:-100}"

# Legacy state directory (for backward compatibility during migration)
# shellcheck disable=SC2034  # Exported for use by sourcing scripts
readonly LOOP_LEGACY_STATE_DIR=".claude"

# Colors (exported for use by sourcing scripts)
export LC_RED='\033[0;31m'
export LC_GREEN='\033[0;32m'
export LC_YELLOW='\033[1;33m'
export LC_BLUE='\033[0;34m'
export LC_CYAN='\033[0;36m'
export LC_BOLD='\033[1m'
export LC_NC='\033[0m'

# =============================================================================
# Logging Functions
# =============================================================================

loop_log_error() {
    local message="$1"
    echo -e "${LC_RED}[loop] Error:${LC_NC} ${message}" >&2
    return 0
}

loop_log_success() {
    local message="$1"
    echo -e "${LC_GREEN}[loop]${LC_NC} ${message}"
    return 0
}

loop_log_warn() {
    local message="$1"
    echo -e "${LC_YELLOW}[loop]${LC_NC} ${message}"
    return 0
}

loop_log_info() {
    local message="$1"
    echo -e "${LC_BLUE}[loop]${LC_NC} ${message}"
    return 0
}

loop_log_step() {
    local message="$1"
    echo -e "${LC_CYAN}[loop]${LC_NC} ${message}"
    return 0
}

# =============================================================================
# State Management (JSON-based)
# =============================================================================

# Initialize loop state directory
# Arguments: none
# Returns: 0
loop_init_state_dir() {
    mkdir -p "$LOOP_STATE_DIR"
    mkdir -p "$LOOP_RECEIPTS_DIR"
    return 0
}

# Create new loop state
# Arguments:
#   $1 - loop_type (ralph|preflight|pr-review|postflight|full)
#   $2 - prompt/task description
#   $3 - max_iterations (default: 50)
#   $4 - completion_promise (default: TASK_COMPLETE)
#   $5 - task_id (optional)
# Returns: 0 on success, 1 on error
loop_create_state() {
    local loop_type="$1"
    local prompt="$2"
    local max_iterations="${3:-50}"
    local completion_promise="${4:-TASK_COMPLETE}"
    local task_id="${5:-}"
    
    loop_init_state_dir
    
    # Generate task_id if not provided
    if [[ -z "$task_id" ]]; then
        task_id="loop_$(date +%Y%m%d%H%M%S)"
    fi
    
    local started_at
    started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Create JSON state file
    cat > "$LOOP_STATE_FILE" << EOF
{
  "loop_type": "$loop_type",
  "prompt": $(echo "$prompt" | jq -Rs .),
  "iteration": 1,
  "max_iterations": $max_iterations,
  "phase": "task",
  "task_id": "$task_id",
  "started_at": "$started_at",
  "last_iteration_at": "$started_at",
  "completion_promise": "$completion_promise",
  "attempts": {},
  "receipts": [],
  "blocked_tasks": [],
  "active": true
}
EOF
    
    loop_log_success "Loop state created: $LOOP_STATE_FILE"
    return 0
}

# Read loop state value
# Arguments:
#   $1 - JSON key path (e.g., ".iteration", ".task_id")
# Returns: 0
# Output: Value to stdout
loop_get_state() {
    local key="$1"
    
    if [[ ! -f "$LOOP_STATE_FILE" ]]; then
        echo ""
        return 0
    fi
    
    jq -r "$key // empty" "$LOOP_STATE_FILE" 2>/dev/null || echo ""
    return 0
}

# Update loop state value
# Arguments:
#   $1 - JSON key path (e.g., ".iteration")
#   $2 - New value (will be auto-typed: number, string, bool)
# Returns: 0 on success, 1 on error
loop_set_state() {
    local key="$1"
    local value="$2"
    
    if [[ ! -f "$LOOP_STATE_FILE" ]]; then
        loop_log_error "No active loop state"
        return 1
    fi
    
    local temp_file
    temp_file=$(mktemp)
    _save_cleanup_scope; trap '_run_cleanups' RETURN
    push_cleanup "rm -f '${temp_file}'"
    
    # Determine value type and update
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        # Integer
        jq "$key = $value" "$LOOP_STATE_FILE" > "$temp_file"
    elif [[ "$value" == "true" || "$value" == "false" ]]; then
        # Boolean
        jq "$key = $value" "$LOOP_STATE_FILE" > "$temp_file"
    elif [[ "$value" == "null" ]]; then
        # Null
        jq "$key = null" "$LOOP_STATE_FILE" > "$temp_file"
    else
        # String
        jq "$key = \"$value\"" "$LOOP_STATE_FILE" > "$temp_file"
    fi
    
    mv "$temp_file" "$LOOP_STATE_FILE"
    return 0
}

# Increment iteration counter
# Arguments: none
# Returns: 0
# Output: New iteration number
loop_increment_iteration() {
    local current
    current=$(loop_get_state ".iteration")
    local next=$((current + 1))
    
    loop_set_state ".iteration" "$next"
    loop_set_state ".last_iteration_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    
    echo "$next"
    return 0
}

# Check if loop is active
# Arguments: none
# Returns: 0 if active, 1 if not
loop_is_active() {
    if [[ ! -f "$LOOP_STATE_FILE" ]]; then
        return 1
    fi
    
    local active
    active=$(loop_get_state ".active")
    [[ "$active" == "true" ]]
}

# Cancel loop
# Arguments: none
# Returns: 0
loop_cancel() {
    if [[ -f "$LOOP_STATE_FILE" ]]; then
        loop_set_state ".active" "false"
        loop_log_success "Loop cancelled"
    else
        loop_log_warn "No active loop to cancel"
    fi
    return 0
}

# Clean up loop state
# Arguments: none
# Returns: 0
loop_cleanup() {
    rm -f "$LOOP_STATE_FILE"
    rm -f "$LOOP_REANCHOR_FILE"
    # Keep receipts for audit trail
    loop_log_info "Loop state cleaned up (receipts preserved)"
    return 0
}

# =============================================================================
# Guardrails System (Signs)
# =============================================================================

# Generate guardrails from recent failures
# Transforms FAILED_APPROACH memories into actionable "signs" that prevent
# repeating the same mistakes. Limited to N most recent to control token cost.
#
# Arguments:
#   $1 - max_signs (default: 5)
# Returns: 0
# Output: Guardrails markdown to stdout
loop_generate_guardrails() {
    local max_signs="${1:-5}"
    local task_id
    task_id=$(loop_get_state ".task_id")
    
    # Check if memory helper is available
    if ! command -v "$LOOP_MEMORY_HELPER" &>/dev/null; then
        echo "No guardrails (memory system unavailable)"
        return 0
    fi
    
    # Query memory for FAILED_APPROACH entries from this loop
    local failures
    failures=$("$LOOP_MEMORY_HELPER" recall \
        "failure retry loop $task_id" \
        --limit "$max_signs" \
        --format json 2>/dev/null || echo "[]")
    
    # Check if we have any failures
    local count
    count=$(echo "$failures" | jq 'length' 2>/dev/null || echo "0")
    
    if [[ "$count" == "0" || "$count" == "null" ]]; then
        echo "No guardrails yet (no recorded failures)."
        return 0
    fi
    
    # Transform failures to guardrail format
    # Format: "Failed: X. Reason: Y" -> sign with trigger and instruction
    echo "$failures" | jq -r '
        .[] | 
        "### Sign: " + (
            .content // .memory // "" | 
            gsub("^Failed: "; "") | 
            split(". Reason:")[0] // "unknown issue"
        ) + "\n" +
        "- **Trigger**: Before similar operation\n" +
        "- **Instruction**: " + (
            .content // .memory // "" | 
            split(". Reason:")[1] // "Avoid this approach" |
            gsub("^ "; "")
        ) + "\n"
    ' 2>/dev/null || echo "No guardrails (parse error)."
    
    return 0
}

# =============================================================================
# Re-Anchor System
# =============================================================================

# Generate re-anchor prompt for fresh context
# Arguments:
#   $1 - task_keywords (for memory recall)
# Returns: 0
# Output: Re-anchor prompt to stdout and file
loop_generate_reanchor() {
    local task_keywords="${1:-}"
    local task_id
    task_id=$(loop_get_state ".task_id")
    local iteration
    iteration=$(loop_get_state ".iteration")
    local prompt
    prompt=$(loop_get_state ".prompt")
    
    loop_init_state_dir
    
    # Get git state
    local git_status
    git_status=$(git status --short 2>/dev/null || echo "Not a git repo")
    local git_log
    git_log=$(git log -5 --oneline 2>/dev/null || echo "No git history")
    local git_branch
    git_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    
    # Detect headless worker mode (t173: workers must not interact with TODO.md)
    local is_headless="false"
    if [[ "${FULL_LOOP_HEADLESS:-false}" == "true" ]]; then
        is_headless="true"
    fi

    # Get TODO.md in-progress tasks (read-only context, skip in headless mode - t173)
    local todo_in_progress=""
    if [[ "$is_headless" == "false" && -f "TODO.md" ]]; then
        todo_in_progress=$(grep -A10 "## In Progress" TODO.md 2>/dev/null | head -15 || echo "No tasks in progress")
    fi
    
    # Extract single next task (the "pin" concept from Loom)
    # Focus on ONE task per iteration to reduce context drift
    # Skip in headless mode — workers work on their assigned task only (t173)
    local next_task=""
    if [[ "$is_headless" == "false" && -f "TODO.md" ]]; then
        # Get first unchecked task from In Progress section, or first from Backlog
        next_task=$(awk '
            /^## In Progress/,/^##/ { if (/^- \[ \]/) { print; exit } }
        ' TODO.md 2>/dev/null || echo "")
        
        if [[ -z "$next_task" ]]; then
            next_task=$(awk '
                /^## Backlog/,/^##/ { if (/^- \[ \]/) { print; exit } }
            ' TODO.md 2>/dev/null || echo "")
        fi
    fi
    
    # Get relevant memories
    local memories=""
    if [[ -n "$task_keywords" ]] && command -v "$LOOP_MEMORY_HELPER" &>/dev/null; then
        memories=$("$LOOP_MEMORY_HELPER" recall "$task_keywords" --limit 5 --format text 2>/dev/null || echo "No relevant memories")
    fi
    
    # Check mailbox for pending messages
    local mailbox_messages=""
    if [[ -x "$LOOP_MAIL_HELPER" ]]; then
        mailbox_messages=$("$LOOP_MAIL_HELPER" check --unread-only 2>/dev/null || echo "No mailbox messages")
    fi
    
    # Generate guardrails from failures (the "signs" concept)
    # These are actionable rules derived from past failures - "same mistake never happens twice"
    local guardrails
    guardrails=$(loop_generate_guardrails 5)
    
    # Get latest receipt
    local latest_receipt=""
    local latest_receipt_file
    latest_receipt_file=$(find "$LOOP_RECEIPTS_DIR" -name "*.json" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || echo "")
    if [[ -n "$latest_receipt_file" && -f "$latest_receipt_file" ]]; then
        latest_receipt=$(cat "$latest_receipt_file")
    fi
    
    # Build headless worker restriction block (t173)
    local headless_restriction=""
    if [[ "$is_headless" == "true" ]]; then
        headless_restriction="
## MANDATORY Worker Restrictions (t173 - Headless Mode)

- **Do NOT edit, commit, or push TODO.md** — the supervisor owns all TODO.md updates.
- **Do NOT edit todo/PLANS.md or todo/tasks/*** — these are supervisor-managed.
- Report status via exit code, log output, and PR creation only.
- Put task notes in commit messages or PR body, never in TODO.md.
- Work ONLY on the assigned task described above. Do not pick tasks from TODO.md.
- **ShellCheck before push (t234)**: Before every \`git push\`, if any committed .sh files changed, run \`shellcheck -x -S warning\` on them. Fix violations before pushing. Skip if shellcheck is not installed.
"
    fi

    # Build TODO.md section (omitted in headless mode - t173)
    local todo_section=""
    if [[ "$is_headless" == "false" ]]; then
        todo_section="### TODO.md In Progress
\`\`\`
$todo_in_progress
\`\`\`"
    fi

    # Generate re-anchor prompt with single-task focus
    cat > "$LOOP_REANCHOR_FILE" << EOF
# Re-Anchor Context (MANDATORY - Read Before Any Work)

**Loop:** $task_id | **Iteration:** $iteration | **Branch:** $git_branch
${headless_restriction}
## Original Task

$prompt

## FOCUS: Single Next Task

Choose the single most important next action. Do NOT try to do everything at once.

${next_task:-"Work on the original task above."}

## Current State

### Git Status
\`\`\`
$git_status
\`\`\`

### Recent Commits
\`\`\`
$git_log
\`\`\`

${todo_section}

## Guardrails (Do Not Repeat These Mistakes)

$guardrails

## Mailbox (Unread Messages)

$mailbox_messages

## Relevant Memories

$memories

## Previous Iteration Receipt

\`\`\`json
${latest_receipt:-"First iteration - no previous receipt"}
\`\`\`

---

**IMPORTANT:** Re-read this context before proceeding. Do NOT rely on conversation history.
Focus on ONE task per iteration. When the overall task is complete, output: <promise>$(loop_get_state ".completion_promise")</promise>

**CONTEXT GUARD:** If you sense your context window is running low (e.g., you are losing
track of earlier instructions, your responses are getting shorter, or you feel you cannot
complete the next step), IMMEDIATELY: (1) \`git add -A && git commit -m "wip: context low"\`,
(2) \`git push\`, (3) output: <promise>$(loop_get_state ".completion_promise")</promise>.
Do NOT attempt complex work when context is low — preserve what you have.
EOF
    
    cat "$LOOP_REANCHOR_FILE"
    return 0
}

# =============================================================================
# Receipt System
# =============================================================================

# Create a receipt for completed work
# Arguments:
#   $1 - type (task|preflight|pr-review|postflight)
#   $2 - outcome (success|retry|blocked)
#   $3 - evidence (JSON object as string, optional)
# Returns: 0
# Output: Receipt file path
loop_create_receipt() {
    local receipt_type="$1"
    local outcome="$2"
    local evidence="${3:-{}}"
    
    local task_id
    task_id=$(loop_get_state ".task_id")
    local iteration
    iteration=$(loop_get_state ".iteration")
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    loop_init_state_dir
    
    local receipt_file="${LOOP_RECEIPTS_DIR}/${receipt_type}-${task_id}-iter${iteration}.json"
    
    # Get commit hash if available
    local commit_hash
    commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "none")
    
    cat > "$receipt_file" << EOF
{
  "type": "$receipt_type",
  "id": "$task_id",
  "iteration": $iteration,
  "timestamp": "$timestamp",
  "outcome": "$outcome",
  "commit_hash": "$commit_hash",
  "evidence": $evidence
}
EOF
    
    # Add receipt to state
    local receipts
    receipts=$(loop_get_state ".receipts")
    if [[ -z "$receipts" || "$receipts" == "null" ]]; then
        receipts="[]"
    fi
    
    local temp_file
    temp_file=$(mktemp)
    jq ".receipts += [\"$(basename "$receipt_file")\"]" "$LOOP_STATE_FILE" > "$temp_file"
    mv "$temp_file" "$LOOP_STATE_FILE"
    
    loop_log_success "Receipt created: $receipt_file"
    echo "$receipt_file"
    return 0
}

# Verify receipt exists for current iteration
# Arguments:
#   $1 - type (task|preflight|pr-review|postflight)
# Returns: 0 if receipt exists, 1 if not
loop_verify_receipt() {
    local receipt_type="$1"
    local task_id
    task_id=$(loop_get_state ".task_id")
    local iteration
    iteration=$(loop_get_state ".iteration")
    
    local receipt_file="${LOOP_RECEIPTS_DIR}/${receipt_type}-${task_id}-iter${iteration}.json"
    
    if [[ -f "$receipt_file" ]]; then
        loop_log_success "Receipt verified: $receipt_file"
        return 0
    else
        loop_log_warn "Missing receipt: $receipt_file"
        return 1
    fi
}

# Get latest receipt for a type
# Arguments:
#   $1 - type (task|preflight|pr-review|postflight)
# Returns: 0
# Output: Receipt JSON to stdout
loop_get_latest_receipt() {
    local receipt_type="$1"
    
    local latest
    latest=$(find "$LOOP_RECEIPTS_DIR" -name "${receipt_type}-*.json" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || echo "")
    
    if [[ -n "$latest" && -f "$latest" ]]; then
        cat "$latest"
    else
        echo "{}"
    fi
    return 0
}

# =============================================================================
# Memory Integration
# =============================================================================

# Store learning from loop iteration
# Arguments:
#   $1 - type (WORKING_SOLUTION|FAILED_APPROACH|CODEBASE_PATTERN)
#   $2 - content
#   $3 - tags (comma-separated)
# Returns: 0
loop_store_memory() {
    local memory_type="$1"
    local content="$2"
    local tags="${3:-loop}"
    
    local task_id
    task_id=$(loop_get_state ".task_id")
    
    if command -v "$LOOP_MEMORY_HELPER" &>/dev/null; then
        "$LOOP_MEMORY_HELPER" store \
            --type "$memory_type" \
            --content "$content" \
            --tags "$tags,loop,$task_id" \
            --session-id "$task_id" 2>/dev/null || true
        loop_log_info "Memory stored: $memory_type"
    fi
    return 0
}

# Store failed approach (called on retry)
# Arguments:
#   $1 - what failed
#   $2 - why it failed (optional)
# Returns: 0
loop_store_failure() {
    local what_failed="$1"
    local why="${2:-Unknown reason}"
    
    loop_store_memory "FAILED_APPROACH" "Failed: $what_failed. Reason: $why" "failure,retry"
    return 0
}

# Store successful solution (called on completion)
# Arguments:
#   $1 - what worked
# Returns: 0
loop_store_success() {
    local what_worked="$1"
    
    loop_store_memory "WORKING_SOLUTION" "Success: $what_worked" "success,solution"
    return 0
}

# =============================================================================
# Task Blocking
# =============================================================================

# Track attempt for a task
# Arguments:
#   $1 - task_id (optional, uses current if not provided)
# Returns: 0
# Output: New attempt count
loop_track_attempt() {
    local task_id="${1:-$(loop_get_state ".task_id")}"
    
    local attempts
    attempts=$(jq -r ".attempts[\"$task_id\"] // 0" "$LOOP_STATE_FILE" 2>/dev/null || echo "0")
    local new_attempts=$((attempts + 1))
    
    local temp_file
    temp_file=$(mktemp)
    jq ".attempts[\"$task_id\"] = $new_attempts" "$LOOP_STATE_FILE" > "$temp_file"
    mv "$temp_file" "$LOOP_STATE_FILE"
    
    echo "$new_attempts"
    return 0
}

# Check if task should be blocked (gutter detection)
# When the same task fails repeatedly, it's likely "in the gutter" - 
# adding more iterations won't help, need a different approach.
#
# Arguments:
#   $1 - max_attempts (default: 5)
#   $2 - task_id (optional)
# Returns: 0 if should block, 1 if not
loop_should_block() {
    local max_attempts="${1:-5}"
    local task_id="${2:-$(loop_get_state ".task_id")}"
    
    local attempts
    attempts=$(jq -r ".attempts[\"$task_id\"] // 0" "$LOOP_STATE_FILE" 2>/dev/null || echo "0")
    
    # Warn at 80% of max attempts (gutter warning)
    local warn_threshold=$(( (max_attempts * 4) / 5 ))
    if [[ "$attempts" -ge "$warn_threshold" && "$attempts" -lt "$max_attempts" ]]; then
        loop_log_warn "Possible gutter: $attempts/$max_attempts attempts on task $task_id"
        loop_log_warn "Consider: different approach, smaller scope, or human review"
    fi
    
    [[ "$attempts" -ge "$max_attempts" ]]
}

# Block a task
# Arguments:
#   $1 - reason
#   $2 - task_id (optional)
# Returns: 0
loop_block_task() {
    local reason="$1"
    local task_id="${2:-$(loop_get_state ".task_id")}"
    
    local temp_file
    temp_file=$(mktemp)
    jq ".blocked_tasks += [{\"id\": \"$task_id\", \"reason\": \"$reason\", \"blocked_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}]" "$LOOP_STATE_FILE" > "$temp_file"
    mv "$temp_file" "$LOOP_STATE_FILE"
    
    loop_store_failure "Task blocked after multiple attempts" "$reason"
    loop_log_warn "Task $task_id blocked: $reason"
    return 0
}

# =============================================================================
# Context-Remaining Guard (t247.1)
# =============================================================================
# Detects when an AI tool session is approaching context exhaustion and
# proactively emits FULL_LOOP_COMPLETE + pushes uncommitted work. This
# prevents the "clean_exit_no_signal" retry pattern where workers exhaust
# their context window and exit gracefully without signaling completion.
#
# Detection heuristics (any one triggers the guard):
# 1. Iteration threshold: iteration >= max_iterations * 80%
# 2. Output shrinkage: output size drops below 20% of rolling average
# 3. Explicit signals: tool output contains context exhaustion markers
# 4. Empty output: tool produced no meaningful output (< 100 bytes)

# Check tool output for context exhaustion indicators
# Arguments:
#   $1 - output_file (path to captured tool output)
#   $2 - iteration (current iteration number)
#   $3 - max_iterations
#   $4 - output_sizes_file (path to file tracking output sizes per iteration)
# Returns: 0 if context exhaustion detected, 1 if not
# Output: Reason string to stdout if exhaustion detected
loop_check_context_exhaustion() {
    local output_file="$1"
    local iteration="$2"
    local max_iterations="$3"
    local output_sizes_file="$4"

    local output_size=0
    if [[ -f "$output_file" ]]; then
        output_size=$(wc -c < "$output_file" 2>/dev/null | tr -d ' ')
    fi

    # Track output size for rolling average
    echo "$output_size" >> "$output_sizes_file"

    # Heuristic 1: Iteration threshold (approaching max iterations)
    local iter_threshold
    iter_threshold=$(( (max_iterations * LOOP_CONTEXT_ITER_THRESHOLD) / 100 ))
    if [[ "$iteration" -ge "$iter_threshold" ]]; then
        echo "iteration_threshold:${iteration}/${max_iterations}"
        return 0
    fi

    # Heuristic 2: Explicit context exhaustion markers in output
    # These are strings that AI tools emit when hitting context limits
    if [[ -f "$output_file" ]]; then
        if grep -qiE \
            'context.*(window|limit|length).*(exceed|reach|exhaust|full)|token.*(limit|budget).*(exceed|reach)|maximum.*context.*length|conversation.*too.*long|context.*truncat|running.*out.*of.*(context|tokens)' \
            "$output_file" 2>/dev/null; then
            echo "explicit_context_signal"
            return 0
        fi
    fi

    # Heuristic 3: Empty or near-empty output (tool couldn't produce work)
    if [[ "$output_size" -lt "$LOOP_CONTEXT_MIN_OUTPUT_BYTES" ]]; then
        # Only trigger after first iteration (first might legitimately be short)
        if [[ "$iteration" -gt 1 ]]; then
            echo "empty_output:${output_size}bytes"
            return 0
        fi
    fi

    # Heuristic 4: Output shrinkage (dramatic drop from rolling average)
    if [[ "$iteration" -ge "$LOOP_CONTEXT_SHRINK_MIN_ITERS" ]]; then
        local total_size=0
        local count=0
        while IFS= read -r size; do
            total_size=$((total_size + size))
            count=$((count + 1))
        done < "$output_sizes_file"

        if [[ "$count" -gt 1 ]]; then
            # Exclude current iteration from average (compare against prior)
            local prior_total=$((total_size - output_size))
            local prior_count=$((count - 1))
            local avg_size=$((prior_total / prior_count))

            if [[ "$avg_size" -gt 0 ]]; then
                local shrink_pct=$(( (output_size * 100) / avg_size ))
                if [[ "$shrink_pct" -lt "$LOOP_CONTEXT_SHRINK_THRESHOLD" ]]; then
                    echo "output_shrinkage:${shrink_pct}%_of_avg(${avg_size}bytes)"
                    return 0
                fi
            fi
        fi
    fi

    return 1
}

# Emergency push: commit and push any uncommitted work before exit
# Called when context exhaustion is detected to preserve work.
# Arguments: none
# Returns: 0 on success, 1 on failure (non-fatal)
loop_emergency_push() {
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "")

    if [[ -z "$branch" ]]; then
        loop_log_warn "Context guard: not in a git repo, skipping emergency push"
        return 1
    fi

    # Check for uncommitted changes
    if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet HEAD 2>/dev/null; then
        # No uncommitted changes — just push existing commits
        if git log --oneline "origin/${branch}..HEAD" 2>/dev/null | grep -q .; then
            loop_log_info "Context guard: pushing unpushed commits on $branch"
            git push origin "$branch" 2>/dev/null || {
                loop_log_warn "Context guard: push failed, trying with --force-with-lease"
                git push --force-with-lease origin "$branch" 2>/dev/null || true
            }
        fi
        return 0
    fi

    # Stage and commit uncommitted work
    loop_log_info "Context guard: committing uncommitted work before exit"
    git add -A 2>/dev/null || true

    local task_id
    task_id=$(loop_get_state ".task_id" 2>/dev/null || echo "unknown")
    git commit -m "wip: emergency commit before context exhaustion ($task_id)" \
        --no-verify 2>/dev/null || {
        loop_log_warn "Context guard: commit failed"
        return 1
    }

    # Push
    loop_log_info "Context guard: pushing to $branch"
    git push origin "$branch" 2>/dev/null || {
        git push -u origin "$branch" 2>/dev/null || {
            loop_log_warn "Context guard: push failed, trying with --force-with-lease"
            git push --force-with-lease origin "$branch" 2>/dev/null || true
        }
    }

    return 0
}

# Emit completion signal to stdout (captured in worker log for supervisor)
# Arguments:
#   $1 - reason (why the guard triggered)
# Returns: 0
loop_emit_completion_signal() {
    local reason="$1"

    loop_log_warn "Context guard triggered: $reason"
    loop_log_info "Emitting FULL_LOOP_COMPLETE signal to prevent clean_exit_no_signal retry"

    # This is the signal the supervisor's extract_log_metadata() looks for
    echo "<promise>FULL_LOOP_COMPLETE</promise>"

    return 0
}

# Full context guard: check, push, and signal in one call
# Designed to be called after each iteration in the loop runner.
# Arguments:
#   $1 - output_file
#   $2 - iteration
#   $3 - max_iterations
#   $4 - output_sizes_file
# Returns: 0 if guard triggered (caller should exit), 1 if safe to continue
loop_context_guard() {
    local output_file="$1"
    local iteration="$2"
    local max_iterations="$3"
    local output_sizes_file="$4"

    local reason
    reason=$(loop_check_context_exhaustion "$output_file" "$iteration" "$max_iterations" "$output_sizes_file") || return 1

    # Guard triggered — save work and signal
    loop_log_warn "=== CONTEXT GUARD ACTIVATED (t247.1) ==="
    loop_log_warn "Reason: $reason"

    # Create receipt documenting the guard activation
    if type loop_create_receipt &>/dev/null; then
        loop_create_receipt "task" "context_guard" \
            "{\"reason\": \"$reason\", \"iteration\": $iteration, \"max_iterations\": $max_iterations}"
    fi

    # Store in memory for pattern tracking
    if type loop_store_memory &>/dev/null; then
        loop_store_memory "CODEBASE_PATTERN" \
            "Context guard triggered at iteration $iteration/$max_iterations: $reason" \
            "context_guard,reliability"
    fi

    # Emergency push to preserve work
    loop_emergency_push

    # Emit the signal
    loop_emit_completion_signal "$reason"

    return 0
}

# =============================================================================
# External Loop Runner
# =============================================================================

# Run external loop with fresh sessions
# Arguments:
#   $1 - tool (opencode|claude|aider)
#   $2 - prompt
#   $3 - max_iterations
#   $4 - completion_promise
# Returns: 0 on completion, 1 on max iterations
loop_run_external() {
    local tool="$1"
    local prompt="$2"
    local max_iterations="${3:-50}"
    local completion_promise="${4:-TASK_COMPLETE}"
    
    # Validate tool
    if ! command -v "$tool" &>/dev/null; then
        loop_log_error "Tool not found: $tool"
        return 1
    fi
    
    loop_log_info "Starting external loop with $tool"
    loop_log_info "Max iterations: $max_iterations"
    loop_log_info "Completion promise: $completion_promise"
    
    # Register agent in mailbox system (if available)
    if [[ -x "$LOOP_MAIL_HELPER" ]]; then
        "$LOOP_MAIL_HELPER" register \
            --role "worker" \
            --branch "$(git branch --show-current 2>/dev/null || echo unknown)" \
            2>/dev/null || true
    fi
    
    local iteration=1
    local output_file
    output_file=$(mktemp)
    local output_sizes_file
    output_sizes_file=$(mktemp)
    trap 'rm -f "$output_file" "$output_sizes_file"' EXIT
    
    while [[ $iteration -le $max_iterations ]]; do
        loop_log_step "=== Iteration $iteration/$max_iterations ==="
        
        # Update state
        loop_set_state ".iteration" "$iteration"
        loop_set_state ".last_iteration_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        
        # Generate re-anchor prompt
        local reanchor
        reanchor=$(loop_generate_reanchor "$prompt")
        
        # Build full prompt with re-anchor
        local full_prompt="$reanchor"
        
        # Run tool (fresh session each time)
        local exit_code=0
        case "$tool" in
            opencode)
                echo "$full_prompt" | opencode --print > "$output_file" 2>&1 || exit_code=$?
                ;;
            claude)
                echo "$full_prompt" | claude --print > "$output_file" 2>&1 || exit_code=$?
                ;;
            aider)
                aider --yes --message "$full_prompt" > "$output_file" 2>&1 || exit_code=$?
                ;;
            *)
                loop_log_error "Unknown tool: $tool"
                return 1
                ;;
        esac
        
        # Check for completion promise
        if grep -q "<promise>$completion_promise</promise>" "$output_file" 2>/dev/null; then
            loop_log_success "Completion promise detected!"
            loop_create_receipt "task" "success" '{"promise_fulfilled": true}'
            loop_store_success "Task completed after $iteration iterations"
            
            # Send status report via mailbox (if available)
            if [[ -x "$LOOP_MAIL_HELPER" ]]; then
                local agent_id
                # Identify current agent by matching worktree path in registry
                local current_dir
                current_dir=$(pwd)
                agent_id=$("$LOOP_MAIL_HELPER" agents 2>/dev/null | grep "$current_dir" | cut -d',' -f1 | head -1 || echo "")
                # Fallback: use first registered agent if no worktree match
                if [[ -z "$agent_id" ]]; then
                    agent_id=$("$LOOP_MAIL_HELPER" agents 2>/dev/null | grep -o '^[^,]*' | head -1 || echo "")
                fi
                if [[ -n "$agent_id" ]]; then
                    "$LOOP_MAIL_HELPER" send \
                        --to "coordinator" \
                        --type status_report \
                        --payload "Task completed: $(loop_get_state ".prompt" | head -c 100). Iterations: $iteration. Branch: $(git branch --show-current 2>/dev/null || echo unknown)" \
                        2>/dev/null || true
                fi
            fi
            
            return 0
        fi
        
        # Context-remaining guard (t247.1): detect approaching context
        # exhaustion and proactively signal + push before the tool exits
        # silently. This prevents the clean_exit_no_signal retry pattern.
        if loop_context_guard "$output_file" "$iteration" "$max_iterations" "$output_sizes_file"; then
            loop_log_success "Context guard: work preserved, signal emitted"
            return 0
        fi
        
        # Track attempt and check for blocking
        local attempts
        attempts=$(loop_track_attempt)
        if loop_should_block 5; then
            loop_block_task "Max attempts reached after $attempts tries"
            return 1
        fi
        
        # Create retry receipt
        loop_create_receipt "task" "retry" "{\"iteration\": $iteration, \"exit_code\": $exit_code}"
        
        iteration=$((iteration + 1))
        
        # Brief delay between iterations
        sleep 2
    done
    
    loop_log_warn "Max iterations ($max_iterations) reached without completion"
    loop_block_task "Max iterations reached"
    return 1
}

# =============================================================================
# Status Display
# =============================================================================

# Show loop status
# Arguments: none
# Returns: 0
loop_show_status() {
    if [[ ! -f "$LOOP_STATE_FILE" ]]; then
        echo "No active loop"
        return 0
    fi
    
    echo ""
    echo "=== Loop Status ==="
    echo ""
    
    local loop_type
    loop_type=$(loop_get_state ".loop_type")
    local task_id
    task_id=$(loop_get_state ".task_id")
    local iteration
    iteration=$(loop_get_state ".iteration")
    local max_iterations
    max_iterations=$(loop_get_state ".max_iterations")
    local phase
    phase=$(loop_get_state ".phase")
    local started_at
    started_at=$(loop_get_state ".started_at")
    local active
    active=$(loop_get_state ".active")
    local completion_promise
    completion_promise=$(loop_get_state ".completion_promise")
    
    echo "Type: $loop_type"
    echo "Task ID: $task_id"
    echo "Phase: $phase"
    echo "Iteration: $iteration / $max_iterations"
    echo "Active: $active"
    echo "Started: $started_at"
    echo "Promise: $completion_promise"
    echo ""
    
    # Show receipts
    local receipt_count
    receipt_count=$(find "$LOOP_RECEIPTS_DIR" -name "*.json" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "Receipts: $receipt_count"
    
    # Show blocked tasks
    local blocked
    blocked=$(jq -r '.blocked_tasks | length' "$LOOP_STATE_FILE" 2>/dev/null || echo "0")
    if [[ "$blocked" -gt 0 ]]; then
        echo ""
        echo "Blocked tasks:"
        jq -r '.blocked_tasks[] | "  - \(.id): \(.reason)"' "$LOOP_STATE_FILE" 2>/dev/null
    fi
    
    echo ""
    return 0
}
