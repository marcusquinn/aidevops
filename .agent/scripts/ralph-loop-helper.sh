#!/bin/bash
# =============================================================================
# Ralph Loop Helper v2 - Cross-Tool Iterative AI Development
# =============================================================================
# Implementation of the Ralph Wiggum technique for iterative AI development.
# Works with Claude Code, OpenCode, and other AI CLI tools.
#
# v2 Architecture (based on flow-next):
# - Fresh context per iteration (external bash loop)
# - File I/O as state (JSON-based, not transcript)
# - Re-anchor from source of truth every iteration
# - Receipt-based verification
# - Memory integration for cross-session learning
#
# Usage:
#   ralph-loop-helper.sh setup "<prompt>" [--max-iterations N] [--completion-promise "TEXT"]
#   ralph-loop-helper.sh run "<prompt>" [options] --tool <tool>  # v2: fresh sessions
#   ralph-loop-helper.sh external "<prompt>" [options] --tool <tool>  # legacy alias
#   ralph-loop-helper.sh cancel
#   ralph-loop-helper.sh status [--all]
#   ralph-loop-helper.sh reanchor  # Generate re-anchor prompt
#
# Reference: https://github.com/gmickel/gmickel-claude-marketplace/tree/main/plugins/flow-next
# Original: https://ghuntley.com/ralph/
#
# Author: AI DevOps Framework
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly SCRIPT_NAME="ralph-loop-helper.sh"

# Source shared loop infrastructure
# shellcheck source=loop-common.sh
if [[ -f "$SCRIPT_DIR/loop-common.sh" ]]; then
    source "$SCRIPT_DIR/loop-common.sh"
fi

# State directories
readonly RALPH_STATE_DIR=".agent/loop-state"
readonly RALPH_STATE_FILE="${RALPH_STATE_DIR}/ralph-loop.local.md"

# Legacy state directory (for backward compatibility during migration)
readonly RALPH_LEGACY_STATE_DIR=".claude"
# shellcheck disable=SC2034  # Defined for documentation, used in status checks
readonly RALPH_LEGACY_STATE_FILE="${RALPH_LEGACY_STATE_DIR}/ralph-loop.local.md"

# Adaptive timing constants (evidence-based from PR #19 analysis)
readonly RALPH_DELAY_BASE="${RALPH_DELAY_BASE:-2}"
readonly RALPH_DELAY_MAX="${RALPH_DELAY_MAX:-30}"
readonly RALPH_DELAY_MULTIPLIER="${RALPH_DELAY_MULTIPLIER:-1.5}"

# v2 defaults
readonly DEFAULT_MAX_ITERATIONS=50
readonly DEFAULT_MAX_ATTEMPTS=5

# Colors (fallback if loop-common.sh not loaded)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

print_error() {
    local message="$1"
    echo -e "${RED}[ralph] Error:${NC} ${message}" >&2
    return 0
}

print_success() {
    local message="$1"
    echo -e "${GREEN}[ralph]${NC} ${message}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[ralph]${NC} ${message}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}[ralph]${NC} ${message}"
    return 0
}

print_step() {
    local message="$1"
    echo -e "${CYAN}[ralph]${NC} ${message}"
    return 0
}

show_help() {
    cat << 'EOF'
Ralph Loop Helper v2 - Cross-Tool Iterative AI Development

USAGE:
  ralph-loop-helper.sh <command> [options]

COMMANDS:
  setup       Create state file to start a Ralph loop (legacy mode)
  run         Run external loop with fresh sessions per iteration (v2)
  external    Alias for 'run' (backward compatibility)
  cancel      Cancel the active Ralph loop
  status      Show current loop status (use --all for all worktrees)
  reanchor    Generate re-anchor prompt for current state
  check       Check if output contains completion promise
  increment   Increment iteration counter (legacy)
  help        Show this help message

RUN OPTIONS (v2 - Recommended):
  --tool <name>                  AI CLI tool (opencode, claude, aider)
  --max-iterations <n>           Maximum iterations (default: 50)
  --completion-promise '<text>'  Promise phrase to detect completion
  --max-attempts <n>             Block task after N failed attempts (default: 5)
  --task-id <id>                 Task ID for tracking (auto-generated if omitted)

SETUP OPTIONS (Legacy):
  --max-iterations <n>           Maximum iterations (default: 0 = unlimited)
  --completion-promise '<text>'  Promise phrase to detect completion

STATUS OPTIONS:
  --all, -a                      Show loops across all git worktrees

EXAMPLES:
  # v2: Fresh sessions per iteration (recommended)
  ralph-loop-helper.sh run "Build a REST API" --tool opencode --max-iterations 20

  # Legacy: Same-session loop (for tools with hook support)
  ralph-loop-helper.sh setup "Build a REST API" --max-iterations 20

  # Check status
  ralph-loop-helper.sh status --all

  # Generate re-anchor prompt
  ralph-loop-helper.sh reanchor

v2 ARCHITECTURE:
  - Fresh context per iteration (no transcript accumulation)
  - Re-anchor from files at start of every iteration
  - Receipt-based verification (proof of work)
  - Memory integration (stores learnings across sessions)
  - Auto-block after N failed attempts

COMPLETION:
  To signal completion, the AI must output: <promise>YOUR_PHRASE</promise>
  The promise must be TRUE - do not output false promises to escape.

ENVIRONMENT VARIABLES:
  RALPH_DELAY_BASE        Initial delay between iterations (default: 2s)
  RALPH_DELAY_MAX         Maximum delay between iterations (default: 30s)
  RALPH_DELAY_MULTIPLIER  Backoff multiplier (default: 1.5)

LEARN MORE:
  Original technique: https://ghuntley.com/ralph/
  flow-next reference: https://github.com/gmickel/gmickel-claude-marketplace
  Documentation: ~/.aidevops/agents/workflows/ralph-loop.md
EOF
    return 0
}

# =============================================================================
# v2 Functions (Fresh Context Architecture)
# =============================================================================

# Run v2 loop with fresh sessions per iteration
# Arguments:
#   $@ - Prompt and options
# Returns: 0 on completion, 1 on error/max iterations
run_v2_loop() {
    local prompt=""
    local max_iterations=$DEFAULT_MAX_ITERATIONS
    local completion_promise="TASK_COMPLETE"
    local tool="opencode"
    local max_attempts=$DEFAULT_MAX_ATTEMPTS
    local task_id=""
    local prompt_parts=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --max-iterations)
                max_iterations="$2"
                shift 2
                ;;
            --completion-promise)
                completion_promise="$2"
                shift 2
                ;;
            --tool)
                tool="$2"
                shift 2
                ;;
            --max-attempts)
                max_attempts="$2"
                shift 2
                ;;
            --task-id)
                task_id="$2"
                shift 2
                ;;
            *)
                prompt_parts+=("$1")
                shift
                ;;
        esac
    done

    prompt="${prompt_parts[*]}"

    if [[ -z "$prompt" ]]; then
        print_error "No prompt provided"
        echo "Usage: $SCRIPT_NAME run \"<prompt>\" --tool <tool> [options]"
        return 1
    fi

    # Validate tool
    if ! command -v "$tool" &>/dev/null; then
        print_error "Tool '$tool' not found. Install it or use --tool to specify another."
        print_info "Available tools: opencode, claude, aider"
        return 1
    fi

    # Check for jq (required for v2)
    if ! command -v jq &>/dev/null; then
        print_error "jq is required for v2 loops. Install with: brew install jq"
        return 1
    fi

    # Initialize state using shared infrastructure
    if type loop_create_state &>/dev/null; then
        loop_create_state "ralph" "$prompt" "$max_iterations" "$completion_promise" "$task_id"
    else
        print_warning "loop-common.sh not loaded, using basic state"
        mkdir -p "$RALPH_STATE_DIR"
    fi

    print_info "Starting Ralph loop v2 with $tool"
    print_info "Architecture: Fresh context per iteration"
    echo ""
    echo "Prompt: $prompt"
    echo "Max iterations: $max_iterations"
    echo "Completion promise: $completion_promise"
    echo "Max attempts before block: $max_attempts"
    echo ""

    local iteration=1
    local output_file
    output_file=$(mktemp)
    trap 'rm -f "$output_file"' EXIT

    while [[ $iteration -le $max_iterations ]]; do
        print_step "=== Iteration $iteration/$max_iterations ==="

        # Update state
        if type loop_set_state &>/dev/null; then
            loop_set_state ".iteration" "$iteration"
            loop_set_state ".last_iteration_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        fi

        # Generate re-anchor prompt (key v2 feature)
        local reanchor_prompt=""
        if type loop_generate_reanchor &>/dev/null; then
            print_info "Generating re-anchor context..."
            reanchor_prompt=$(loop_generate_reanchor "$prompt")
        else
            # Fallback: basic prompt with iteration
            reanchor_prompt="[Ralph iteration $iteration/$max_iterations]

$prompt

To complete, output: <promise>$completion_promise</promise> (ONLY when TRUE)"
        fi

        # Run tool with fresh session
        local exit_code=0
        print_info "Spawning fresh $tool session..."
        
        case "$tool" in
            opencode)
                echo "$reanchor_prompt" | opencode --print > "$output_file" 2>&1 || exit_code=$?
                ;;
            claude)
                echo "$reanchor_prompt" | claude --print > "$output_file" 2>&1 || exit_code=$?
                ;;
            aider)
                aider --yes --message "$reanchor_prompt" > "$output_file" 2>&1 || exit_code=$?
                ;;
            *)
                print_error "Unknown tool: $tool"
                return 1
                ;;
        esac

        if [[ $exit_code -ne 0 ]]; then
            print_warning "Tool exited with code $exit_code (continuing)"
        fi

        # Check for completion promise
        if grep -q "<promise>$completion_promise</promise>" "$output_file" 2>/dev/null; then
            print_success "Completion promise detected!"
            
            # Create success receipt
            if type loop_create_receipt &>/dev/null; then
                loop_create_receipt "task" "success" '{"promise_fulfilled": true}'
            fi
            
            # Store success in memory
            if type loop_store_success &>/dev/null; then
                loop_store_success "Task completed after $iteration iterations"
            fi
            
            print_success "Ralph loop completed successfully after $iteration iterations"
            return 0
        fi

        # Track attempt and check for blocking
        if type loop_track_attempt &>/dev/null; then
            local attempts
            attempts=$(loop_track_attempt)
            
            if type loop_should_block &>/dev/null && loop_should_block "$max_attempts"; then
                print_error "Task blocked after $attempts failed attempts"
                
                if type loop_block_task &>/dev/null; then
                    loop_block_task "Max attempts ($max_attempts) reached without completion"
                fi
                
                if type loop_store_failure &>/dev/null; then
                    loop_store_failure "Task blocked" "Exceeded $max_attempts attempts"
                fi
                
                return 1
            fi
        fi

        # Create retry receipt
        if type loop_create_receipt &>/dev/null; then
            loop_create_receipt "task" "retry" "{\"iteration\": $iteration, \"exit_code\": $exit_code}"
        fi

        iteration=$((iteration + 1))

        # Adaptive delay
        local delay
        delay=$(calculate_delay "$iteration")
        print_info "Waiting ${delay}s before next iteration..."
        sleep "$delay"
    done

    print_warning "Max iterations ($max_iterations) reached without completion"
    
    if type loop_block_task &>/dev/null; then
        loop_block_task "Max iterations reached"
    fi
    
    return 1
}

# Calculate adaptive delay with exponential backoff
# Arguments:
#   $1 - iteration number
# Returns: 0
# Output: delay in seconds
calculate_delay() {
    local iteration="$1"
    local delay

    if command -v bc &>/dev/null; then
        delay=$(echo "scale=0; $RALPH_DELAY_BASE * ($RALPH_DELAY_MULTIPLIER ^ ($iteration - 1))" | bc 2>/dev/null || echo "$RALPH_DELAY_BASE")
        if [[ $(echo "$delay > $RALPH_DELAY_MAX" | bc 2>/dev/null || echo "0") -eq 1 ]]; then
            delay=$RALPH_DELAY_MAX
        fi
    else
        delay=$RALPH_DELAY_BASE
        local i=1
        while [[ $i -lt $iteration ]] && [[ $delay -lt $RALPH_DELAY_MAX ]]; do
            delay=$((delay * 2))
            ((i++))
        done
        [[ $delay -gt $RALPH_DELAY_MAX ]] && delay=$RALPH_DELAY_MAX
    fi

    echo "$delay"
    return 0
}

# =============================================================================
# Legacy Functions (Backward Compatibility)
# =============================================================================

# Setup a new Ralph loop (legacy mode - same session)
setup_loop() {
    local prompt=""
    local max_iterations=0
    local completion_promise="null"
    local prompt_parts=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --max-iterations)
                max_iterations="$2"
                shift 2
                ;;
            --completion-promise)
                completion_promise="$2"
                shift 2
                ;;
            *)
                prompt_parts+=("$1")
                shift
                ;;
        esac
    done

    prompt="${prompt_parts[*]}"

    if [[ -z "$prompt" ]]; then
        print_error "No prompt provided"
        echo "Usage: $SCRIPT_NAME setup \"<prompt>\" [--max-iterations N] [--completion-promise \"TEXT\"]"
        return 1
    fi

    mkdir -p "$RALPH_STATE_DIR"

    local completion_promise_yaml
    if [[ -n "$completion_promise" ]] && [[ "$completion_promise" != "null" ]]; then
        completion_promise_yaml="\"$completion_promise\""
    else
        completion_promise_yaml="null"
    fi

    cat > "$RALPH_STATE_FILE" << EOF
---
active: true
iteration: 1
max_iterations: $max_iterations
completion_promise: $completion_promise_yaml
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mode: legacy
---

$prompt
EOF

    check_other_loops

    echo ""
    print_success "Ralph loop activated (legacy mode)"
    print_warning "Note: Consider using 'run' command for v2 fresh-context architecture"
    echo ""
    echo "Iteration: 1"
    echo "Max iterations: $(if [[ $max_iterations -gt 0 ]]; then echo "$max_iterations"; else echo "unlimited"; fi)"
    echo "Completion promise: $(if [[ "$completion_promise" != "null" ]]; then echo "$completion_promise"; else echo "none"; fi)"
    echo ""
    echo "State file: $RALPH_STATE_FILE"

    if [[ "$completion_promise" != "null" ]]; then
        echo ""
        echo "================================================================"
        echo "To complete this loop, output: <promise>$completion_promise</promise>"
        echo "================================================================"
    fi

    echo ""
    echo "$prompt"

    return 0
}

# Cancel the active Ralph loop
cancel_loop() {
    local cancelled=false

    # Cancel v2 state
    if type loop_cancel &>/dev/null && [[ -f "${RALPH_STATE_DIR}/loop-state.json" ]]; then
        loop_cancel
        cancelled=true
    fi

    # Cancel legacy state
    if [[ -f "$RALPH_STATE_FILE" ]]; then
        local iteration
        iteration=$(grep '^iteration:' "$RALPH_STATE_FILE" | sed 's/iteration: *//' || echo "unknown")
        rm "$RALPH_STATE_FILE"
        print_success "Cancelled legacy Ralph loop (was at iteration $iteration)"
        cancelled=true
    fi

    if [[ "$cancelled" == "false" ]]; then
        print_warning "No active Ralph loop found"
    fi

    return 0
}

# Show status
show_status() {
    local show_all=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --all|-a)
                show_all=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ "$show_all" == "true" ]]; then
        show_status_all
        return 0
    fi

    # Check v2 state first
    if type loop_show_status &>/dev/null && [[ -f "${RALPH_STATE_DIR}/loop-state.json" ]]; then
        echo "=== Ralph Loop v2 Status ==="
        loop_show_status
        return 0
    fi

    # Fall back to legacy state
    if [[ -f "$RALPH_STATE_FILE" ]]; then
        echo "=== Ralph Loop Status (Legacy) ==="
        echo ""

        local frontmatter
        frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")

        local iteration max_iterations completion_promise started_at
        iteration=$(echo "$frontmatter" | grep '^iteration:' | sed 's/iteration: *//')
        max_iterations=$(echo "$frontmatter" | grep '^max_iterations:' | sed 's/max_iterations: *//')
        completion_promise=$(echo "$frontmatter" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')
        started_at=$(echo "$frontmatter" | grep '^started_at:' | sed 's/started_at: *//' | sed 's/^"\(.*\)"$/\1/')

        echo "Mode: legacy (same-session)"
        echo "Active: yes"
        echo "Iteration: $iteration"
        echo "Max iterations: $(if [[ "$max_iterations" == "0" ]]; then echo "unlimited"; else echo "$max_iterations"; fi)"
        echo "Completion promise: $(if [[ "$completion_promise" == "null" ]]; then echo "none"; else echo "$completion_promise"; fi)"
        echo "Started: $started_at"
        echo ""
        print_warning "Consider migrating to v2: ralph-loop-helper.sh run ..."
        return 0
    fi

    echo "No active Ralph loop in current directory."
    echo ""
    echo "Tip: Use 'status --all' to check all worktrees"
    return 0
}

# Show status across all worktrees
show_status_all() {
    echo "Ralph Loop Status - All Worktrees"
    echo "=================================="
    echo ""

    if ! git rev-parse --git-dir &>/dev/null; then
        print_error "Not in a git repository"
        return 1
    fi

    local found_any=false
    local current_dir
    current_dir=$(pwd)

    while IFS= read -r line; do
        if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
            local worktree_path="${BASH_REMATCH[1]}"
            
            # Check for v2 state (new location first, then legacy)
            local v2_state="$worktree_path/.agent/loop-state/loop-state.json"
            local v2_state_legacy="$worktree_path/.claude/loop-state.json"
            local legacy_state="$worktree_path/.agent/loop-state/ralph-loop.local.md"
            local legacy_state_old="$worktree_path/.claude/ralph-loop.local.md"
            
            # Check any of the state file locations
            if [[ -f "$v2_state" ]] || [[ -f "$v2_state_legacy" ]] || [[ -f "$legacy_state" ]] || [[ -f "$legacy_state_old" ]]; then
                found_any=true
                
                local branch
                branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "unknown")
                
                local marker=""
                if [[ "$worktree_path" == "$current_dir" ]]; then
                    marker=" ${GREEN}(current)${NC}"
                fi
                
                echo -e "${BOLD}$branch${NC}$marker"
                echo "  Path: $worktree_path"
                
                # Determine which state file to read (prefer new location)
                local active_v2_state=""
                local active_legacy_state=""
                [[ -f "$v2_state" ]] && active_v2_state="$v2_state"
                [[ -z "$active_v2_state" && -f "$v2_state_legacy" ]] && active_v2_state="$v2_state_legacy"
                [[ -f "$legacy_state" ]] && active_legacy_state="$legacy_state"
                [[ -z "$active_legacy_state" && -f "$legacy_state_old" ]] && active_legacy_state="$legacy_state_old"
                
                if [[ -n "$active_v2_state" ]]; then
                    local iteration max_iterations
                    iteration=$(jq -r '.iteration // 0' "$active_v2_state" 2>/dev/null || echo "?")
                    max_iterations=$(jq -r '.max_iterations // 0' "$active_v2_state" 2>/dev/null || echo "?")
                    echo "  Mode: v2 (fresh context)"
                    echo "  Iteration: $iteration / $max_iterations"
                elif [[ -n "$active_legacy_state" ]]; then
                    local iteration max_iterations
                    iteration=$(grep '^iteration:' "$active_legacy_state" | sed 's/iteration: *//')
                    max_iterations=$(grep '^max_iterations:' "$active_legacy_state" | sed 's/max_iterations: *//')
                    echo "  Mode: legacy (same session)"
                    echo "  Iteration: $iteration / $(if [[ "$max_iterations" == "0" ]]; then echo "unlimited"; else echo "$max_iterations"; fi)"
                fi
                echo ""
            fi
        fi
    done < <(git worktree list --porcelain)

    if [[ "$found_any" == "false" ]]; then
        echo -e "${GREEN}No active Ralph loops in any worktree${NC}"
    fi

    return 0
}

# Check for other active loops
check_other_loops() {
    if ! git rev-parse --git-dir &>/dev/null; then
        return 0
    fi

    local current_dir
    current_dir=$(pwd)
    local other_loops=()

    while IFS= read -r line; do
        if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
            local worktree_path="${BASH_REMATCH[1]}"
            
            if [[ "$worktree_path" == "$current_dir" ]]; then
                continue
            fi

            # Check all possible state file locations (new and legacy)
            local v2_state="$worktree_path/.agent/loop-state/loop-state.json"
            local v2_state_legacy="$worktree_path/.claude/loop-state.json"
            local legacy_state="$worktree_path/.agent/loop-state/ralph-loop.local.md"
            local legacy_state_old="$worktree_path/.claude/ralph-loop.local.md"

            if [[ -f "$v2_state" ]] || [[ -f "$v2_state_legacy" ]] || [[ -f "$legacy_state" ]] || [[ -f "$legacy_state_old" ]]; then
                local branch
                branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "unknown")
                local iteration="?"
                
                if [[ -f "$v2_state" ]]; then
                    iteration=$(jq -r '.iteration // 0' "$v2_state" 2>/dev/null || echo "?")
                elif [[ -f "$v2_state_legacy" ]]; then
                    iteration=$(jq -r '.iteration // 0' "$v2_state_legacy" 2>/dev/null || echo "?")
                elif [[ -f "$legacy_state" ]]; then
                    iteration=$(grep '^iteration:' "$legacy_state" | sed 's/iteration: *//')
                elif [[ -f "$legacy_state_old" ]]; then
                    iteration=$(grep '^iteration:' "$legacy_state_old" | sed 's/iteration: *//')
                fi
                
                other_loops+=("$branch (iteration $iteration)")
            fi
        fi
    done < <(git worktree list --porcelain)

    if [[ ${#other_loops[@]} -gt 0 ]]; then
        echo ""
        print_warning "Other active Ralph loops detected:"
        for loop in "${other_loops[@]}"; do
            echo "  - $loop"
        done
        echo ""
    fi

    return 0
}

# Generate re-anchor prompt
generate_reanchor() {
    if type loop_generate_reanchor &>/dev/null; then
        local keywords="${1:-}"
        loop_generate_reanchor "$keywords"
    else
        print_error "loop-common.sh not loaded"
        return 1
    fi
}

# Check completion (legacy)
check_completion() {
    local output="$1"
    local completion_promise="${2:-}"

    if [[ -z "$completion_promise" ]] || [[ "$completion_promise" == "null" ]]; then
        echo "NO_PROMISE"
        return 0
    fi

    if grep -q "<promise>$completion_promise</promise>" <<< "$output" 2>/dev/null; then
        echo "COMPLETE"
        return 0
    fi

    echo "NOT_COMPLETE"
    return 0
}

# Increment iteration (legacy)
increment_iteration() {
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        print_error "No active Ralph loop to increment"
        return 1
    fi

    local current_iteration
    current_iteration=$(grep '^iteration:' "$RALPH_STATE_FILE" | sed 's/iteration: *//')

    if [[ ! "$current_iteration" =~ ^[0-9]+$ ]]; then
        print_error "State file corrupted"
        return 1
    fi

    local next_iteration=$((current_iteration + 1))

    local temp_file
    temp_file=$(mktemp)
    sed "s/^iteration: .*/iteration: $next_iteration/" "$RALPH_STATE_FILE" > "$temp_file"
    mv "$temp_file" "$RALPH_STATE_FILE"

    echo "$next_iteration"
    return 0
}

# Get prompt (legacy)
get_prompt() {
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        print_error "No active Ralph loop"
        return 1
    fi

    awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE"
    return 0
}

# Get completion promise (legacy)
get_completion_promise() {
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        echo "null"
        return 0
    fi

    local frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
    echo "$frontmatter" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/'
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        run)
            run_v2_loop "$@"
            ;;
        external)
            # Legacy alias for 'run'
            run_v2_loop "$@"
            ;;
        setup)
            setup_loop "$@"
            ;;
        cancel)
            cancel_loop
            ;;
        status)
            show_status "$@"
            ;;
        reanchor)
            generate_reanchor "$@"
            ;;
        check|check-completion)
            if [[ $# -lt 1 ]]; then
                print_error "check requires output text as argument"
                return 1
            fi
            local output="$1"
            local promise="${2:-$(get_completion_promise)}"
            check_completion "$output" "$promise"
            ;;
        increment)
            increment_iteration
            ;;
        get-prompt)
            get_prompt
            ;;
        get-completion-promise)
            get_completion_promise
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_help
            return 1
            ;;
    esac
}

main "$@"
