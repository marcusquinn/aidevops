#!/bin/bash
# =============================================================================
# Ralph Loop Helper - Cross-Tool Iterative AI Development
# =============================================================================
# Implementation of the Ralph Wiggum technique for iterative AI development.
# Works with Claude Code, OpenCode, and other AI CLI tools.
#
# Usage:
#   ralph-loop-helper.sh setup "<prompt>" [--max-iterations N] [--completion-promise "TEXT"]
#   ralph-loop-helper.sh cancel
#   ralph-loop-helper.sh status
#   ralph-loop-helper.sh check-completion "<output>"
#   ralph-loop-helper.sh increment
#   ralph-loop-helper.sh external "<prompt>" [options] --tool <tool>
#
# Author: AI DevOps Framework
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly RALPH_STATE_DIR=".claude"
readonly RALPH_STATE_FILE="${RALPH_STATE_DIR}/ralph-loop.local.md"
readonly SCRIPT_NAME="ralph-loop-helper.sh"

# Adaptive timing constants (evidence-based from PR #19 analysis)
# These can be overridden by environment variables
readonly RALPH_DELAY_BASE="${RALPH_DELAY_BASE:-2}"      # Initial delay between iterations
readonly RALPH_DELAY_MAX="${RALPH_DELAY_MAX:-30}"       # Maximum delay between iterations
readonly RALPH_DELAY_MULTIPLIER="${RALPH_DELAY_MULTIPLIER:-1.5}"  # Backoff multiplier

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

# Print error message to stderr
# Arguments:
#   $1 - Error message to display
# Returns: 0
print_error() {
    local message="$1"
    echo -e "${RED}Error:${NC} ${message}" >&2
    return 0
}

# Print success message in green
# Arguments:
#   $1 - Success message to display
# Returns: 0
print_success() {
    local message="$1"
    echo -e "${GREEN}${message}${NC}"
    return 0
}

# Print warning message in yellow
# Arguments:
#   $1 - Warning message to display
# Returns: 0
print_warning() {
    local message="$1"
    echo -e "${YELLOW}${message}${NC}"
    return 0
}

# Print info message in blue
# Arguments:
#   $1 - Info message to display
# Returns: 0
print_info() {
    local message="$1"
    echo -e "${BLUE}${message}${NC}"
    return 0
}

show_help() {
    cat << 'EOF'
Ralph Loop Helper - Cross-Tool Iterative AI Development

USAGE:
  ralph-loop-helper.sh <command> [options]

COMMANDS:
  setup     Create state file to start a Ralph loop
  cancel    Cancel the active Ralph loop
  status    Show current loop status (use --all for all worktrees)
  check     Check if output contains completion promise
  increment Increment iteration counter
  external  Run external bash loop (for tools without hook support)
  help      Show this help message

SETUP OPTIONS:
  --max-iterations <n>           Maximum iterations (default: 0 = unlimited)
  --completion-promise '<text>'  Promise phrase to detect completion

STATUS OPTIONS:
  --all, -a                      Show loops across all git worktrees

EXTERNAL OPTIONS:
  --tool <name>                  AI CLI tool to use (opencode, claude, aider)
  --max-iterations <n>           Maximum iterations
  --completion-promise '<text>'  Promise phrase

EXAMPLES:
  # Start a loop (for tools with hook support)
  ralph-loop-helper.sh setup "Build a REST API" --max-iterations 20 --completion-promise "DONE"

  # Check status in current directory
  ralph-loop-helper.sh status

  # Check status across all worktrees
  ralph-loop-helper.sh status --all

  # Cancel loop
  ralph-loop-helper.sh cancel

  # External loop (for tools without hook support)
  ralph-loop-helper.sh external "Fix all tests" --tool opencode --max-iterations 10

DESCRIPTION:
  Ralph is a development methodology based on continuous AI agent loops.
  The AI works on a task, and when it tries to exit, the same prompt is
  fed back, allowing it to see its previous work and iterate until done.

  For tools with hook support (Claude Code), use 'setup' to create state.
  For tools without hooks, use 'external' to run a bash loop wrapper.

COMPLETION:
  To signal completion, the AI must output: <promise>YOUR_PHRASE</promise>
  The promise must be TRUE - do not output false promises to escape.

MONITORING:
  # View current iteration
  grep '^iteration:' .claude/ralph-loop.local.md

  # View full state
  head -10 .claude/ralph-loop.local.md

ENVIRONMENT VARIABLES:
  RALPH_DELAY_BASE        Initial delay between iterations (default: 2s)
  RALPH_DELAY_MAX         Maximum delay between iterations (default: 30s)
  RALPH_DELAY_MULTIPLIER  Backoff multiplier (default: 1.5)

LEARN MORE:
  Original technique: https://ghuntley.com/ralph/
  Documentation: ~/.aidevops/agents/workflows/ralph-loop.md
EOF
    return 0
}

# =============================================================================
# Core Functions
# =============================================================================

# Setup a new Ralph loop by creating state file
# Arguments:
#   $@ - Prompt text and options (--max-iterations N, --completion-promise "TEXT")
# Returns: 0 on success, 1 on error
# Side effects: Creates .claude/ralph-loop.local.md state file
setup_loop() {
    local prompt=""
    local max_iterations=0
    local completion_promise="null"
    local prompt_parts=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --max-iterations)
                if [[ -z "${2:-}" ]]; then
                    print_error "--max-iterations requires a number argument"
                    return 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    print_error "--max-iterations must be a positive integer, got: $2"
                    return 1
                fi
                max_iterations="$2"
                shift 2
                ;;
            --completion-promise)
                if [[ -z "${2:-}" ]]; then
                    print_error "--completion-promise requires a text argument"
                    return 1
                fi
                completion_promise="$2"
                shift 2
                ;;
            *)
                prompt_parts+=("$1")
                shift
                ;;
        esac
    done

    # Join prompt parts
    prompt="${prompt_parts[*]}"

    if [[ -z "$prompt" ]]; then
        print_error "No prompt provided"
        echo ""
        echo "Usage: $SCRIPT_NAME setup \"<prompt>\" [--max-iterations N] [--completion-promise \"TEXT\"]"
        return 1
    fi

    # Create state directory
    mkdir -p "$RALPH_STATE_DIR"

    # Quote completion promise for YAML if needed
    local completion_promise_yaml
    if [[ -n "$completion_promise" ]] && [[ "$completion_promise" != "null" ]]; then
        completion_promise_yaml="\"$completion_promise\""
    else
        completion_promise_yaml="null"
    fi

    # Create state file
    cat > "$RALPH_STATE_FILE" << EOF
---
active: true
iteration: 1
max_iterations: $max_iterations
completion_promise: $completion_promise_yaml
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$prompt
EOF

    # Check for other active loops in parallel worktrees
    check_other_loops

    # Output setup message
    echo ""
    print_success "Ralph loop activated!"
    echo ""
    echo "Iteration: 1"
    echo "Max iterations: $(if [[ $max_iterations -gt 0 ]]; then echo "$max_iterations"; else echo "unlimited"; fi)"
    echo "Completion promise: $(if [[ "$completion_promise" != "null" ]]; then echo "${completion_promise} (ONLY output when TRUE)"; else echo "none (runs forever)"; fi)"
    echo ""
    echo "State file: $RALPH_STATE_FILE"
    echo ""

    # Display completion promise requirements if set
    if [[ "$completion_promise" != "null" ]]; then
        echo "================================================================"
        echo "CRITICAL - Ralph Loop Completion Promise"
        echo "================================================================"
        echo ""
        echo "To complete this loop, output this EXACT text:"
        echo "  <promise>$completion_promise</promise>"
        echo ""
        echo "STRICT REQUIREMENTS:"
        echo "  - Use <promise> XML tags EXACTLY as shown"
        echo "  - The statement MUST be completely TRUE"
        echo "  - Do NOT output false statements to exit"
        echo "================================================================"
    fi

    echo ""
    echo "$prompt"

    return 0
}

# Cancel the active Ralph loop
# Arguments: none
# Returns: 0 (always succeeds)
# Side effects: Removes state file if it exists
cancel_loop() {
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        print_warning "No active Ralph loop found."
        return 0
    fi

    # Get iteration count before removing
    local iteration
    iteration=$(grep '^iteration:' "$RALPH_STATE_FILE" | sed 's/iteration: *//' || echo "unknown")

    rm "$RALPH_STATE_FILE"
    print_success "Cancelled Ralph loop (was at iteration $iteration)"
    return 0
}

# Display current Ralph loop status
# Arguments:
#   --all: Show status across all worktrees
# Returns: 0 (always succeeds)
# Output: Status information to stdout
show_status() {
    local show_all=false
    
    # Parse arguments
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
    
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        echo "No active Ralph loop in current directory."
        echo ""
        echo "Tip: Use 'status --all' to check all worktrees"
        return 0
    fi

    echo "Ralph Loop Status"
    echo "================="
    echo ""

    # Parse frontmatter
    local frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")

    local iteration
    local max_iterations
    local completion_promise
    local started_at

    iteration=$(echo "$frontmatter" | grep '^iteration:' | sed 's/iteration: *//')
    max_iterations=$(echo "$frontmatter" | grep '^max_iterations:' | sed 's/max_iterations: *//')
    completion_promise=$(echo "$frontmatter" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')
    started_at=$(echo "$frontmatter" | grep '^started_at:' | sed 's/started_at: *//' | sed 's/^"\(.*\)"$/\1/')

    echo "Active: yes"
    echo "Iteration: $iteration"
    echo "Max iterations: $(if [[ "$max_iterations" == "0" ]]; then echo "unlimited"; else echo "$max_iterations"; fi)"
    echo "Completion promise: $(if [[ "$completion_promise" == "null" ]]; then echo "none"; else echo "$completion_promise"; fi)"
    echo "Started: $started_at"
    echo ""
    echo "State file: $RALPH_STATE_FILE"

    return 0
}

# Display Ralph loop status across all worktrees
# Arguments: none
# Returns: 0 (always succeeds)
# Output: Status table for all worktrees with active loops
show_status_all() {
    echo "Ralph Loop Status - All Worktrees"
    echo "=================================="
    echo ""
    
    # Check if we're in a git repo
    if ! git rev-parse --git-dir &>/dev/null; then
        print_error "Not in a git repository"
        return 1
    fi
    
    local found_any=false
    local current_dir
    current_dir=$(pwd)
    
    # Get all worktrees
    while IFS= read -r line; do
        if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
            local worktree_path="${BASH_REMATCH[1]}"
            local state_file="$worktree_path/$RALPH_STATE_DIR/$RALPH_STATE_FILE"
            
            # Normalize path for comparison
            state_file="$worktree_path/.claude/ralph-loop.local.md"
            
            if [[ -f "$state_file" ]]; then
                found_any=true
                
                # Parse state file
                local frontmatter
                frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file")
                
                local iteration
                local max_iterations
                local started_at
                local branch
                
                iteration=$(echo "$frontmatter" | grep '^iteration:' | sed 's/iteration: *//')
                max_iterations=$(echo "$frontmatter" | grep '^max_iterations:' | sed 's/max_iterations: *//')
                started_at=$(echo "$frontmatter" | grep '^started_at:' | sed 's/started_at: *//' | sed 's/^"\(.*\)"$/\1/')
                
                # Get branch name
                branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "unknown")
                
                # Mark current directory
                local marker=""
                if [[ "$worktree_path" == "$current_dir" ]]; then
                    marker=" ${GREEN}(current)${NC}"
                fi
                
                echo -e "${BOLD}$branch${NC}$marker"
                echo "  Path: $worktree_path"
                echo "  Iteration: $iteration / $(if [[ "$max_iterations" == "0" ]]; then echo "unlimited"; else echo "$max_iterations"; fi)"
                echo "  Started: $started_at"
                echo ""
            fi
        fi
    done < <(git worktree list --porcelain)
    
    if [[ "$found_any" == "false" ]]; then
        echo -e "${GREEN}No active Ralph loops in any worktree${NC}"
    fi
    
    return 0
}

# Check for active loops in other worktrees and warn
# Arguments: none
# Returns: 0 (always succeeds)
# Output: Warning message if other loops are active
check_other_loops() {
    # Check if we're in a git repo
    if ! git rev-parse --git-dir &>/dev/null; then
        return 0
    fi
    
    local current_dir
    current_dir=$(pwd)
    local other_loops=()
    
    # Get all worktrees
    while IFS= read -r line; do
        if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
            local worktree_path="${BASH_REMATCH[1]}"
            
            # Skip current directory
            if [[ "$worktree_path" == "$current_dir" ]]; then
                continue
            fi
            
            local state_file="$worktree_path/.claude/ralph-loop.local.md"
            
            if [[ -f "$state_file" ]]; then
                local branch
                branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null || echo "unknown")
                local iteration
                iteration=$(grep '^iteration:' "$state_file" | sed 's/iteration: *//')
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
        echo "Use 'ralph-loop-helper.sh status --all' to see details"
        echo ""
    fi
    
    return 0
}

# Check if output contains the completion promise
# Arguments:
#   $1 - Output text to check
#   $2 - Completion promise phrase to look for
# Returns: 0 (always succeeds)
# Output: "COMPLETE", "NOT_COMPLETE", or "NO_PROMISE" to stdout
check_completion() {
    local output="$1"
    local completion_promise="${2:-}"

    # If no completion promise, can't complete
    if [[ -z "$completion_promise" ]] || [[ "$completion_promise" == "null" ]]; then
        echo "NO_PROMISE"
        return 0
    fi

    # Check for Perl dependency (required for multiline promise extraction)
    if ! command -v perl &>/dev/null; then
        print_warning "Perl not found - promise extraction may fail. Install perl for reliable completion detection."
        echo "NOT_COMPLETE"
        return 0
    fi

    # Extract text from <promise> tags using Perl for multiline support
    local promise_text
    promise_text=$(echo "$output" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

    # Use = for literal string comparison
    if [[ -n "$promise_text" ]] && [[ "$promise_text" = "$completion_promise" ]]; then
        echo "COMPLETE"
        return 0
    fi

    echo "NOT_COMPLETE"
    return 0
}

# Increment the iteration counter in state file
# Arguments: none
# Returns: 0 on success, 1 if no active loop or corrupted state
# Output: New iteration number to stdout
increment_iteration() {
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        print_error "No active Ralph loop to increment"
        return 1
    fi

    # Get current iteration
    local current_iteration
    current_iteration=$(grep '^iteration:' "$RALPH_STATE_FILE" | sed 's/iteration: *//')

    if [[ ! "$current_iteration" =~ ^[0-9]+$ ]]; then
        print_error "State file corrupted - iteration is not a number"
        return 1
    fi

    local next_iteration=$((current_iteration + 1))

    # Update iteration in frontmatter (portable across macOS and Linux)
    local temp_file
    temp_file=$(mktemp) || { print_error "Failed to create temp file"; return 1; }
    sed "s/^iteration: .*/iteration: $next_iteration/" "$RALPH_STATE_FILE" > "$temp_file"
    mv "$temp_file" "$RALPH_STATE_FILE"

    echo "$next_iteration"
    return 0
}

# Get the prompt from the state file
# Arguments: none
# Returns: 0 on success, 1 if no active loop
# Output: Prompt text to stdout
get_prompt() {
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        print_error "No active Ralph loop"
        return 1
    fi

    # Extract prompt (everything after the closing ---)
    awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE"
    return 0
}

# Get max iterations setting from state file
# Arguments: none
# Returns: 0 (always succeeds)
# Output: Max iterations number to stdout (0 if no active loop)
get_max_iterations() {
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        echo "0"
        return 0
    fi

    local frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
    echo "$frontmatter" | grep '^max_iterations:' | sed 's/max_iterations: *//'
    return 0
}

# Get completion promise from state file
# Arguments: none
# Returns: 0 (always succeeds)
# Output: Completion promise to stdout ("null" if no active loop or not set)
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

# Run an external Ralph loop for tools without hook support
# Arguments:
#   $@ - Prompt and options (--tool NAME, --max-iterations N, --completion-promise "TEXT")
# Returns: 0 on completion, 1 on error
# Side effects: Runs AI tool repeatedly until completion or max iterations
run_external_loop() {
    local prompt=""
    local max_iterations=0
    local completion_promise="null"
    local tool="opencode"
    local prompt_parts=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --max-iterations)
                if [[ -z "${2:-}" ]]; then
                    print_error "--max-iterations requires a number argument"
                    return 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    print_error "--max-iterations must be a positive integer, got: $2"
                    return 1
                fi
                max_iterations="$2"
                shift 2
                ;;
            --completion-promise)
                if [[ -z "${2:-}" ]]; then
                    print_error "--completion-promise requires a text argument"
                    return 1
                fi
                completion_promise="$2"
                shift 2
                ;;
            --tool)
                if [[ -z "${2:-}" ]]; then
                    print_error "--tool requires a tool name argument"
                    return 1
                fi
                tool="$2"
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
        print_error "No prompt provided for external loop"
        return 1
    fi

    # Validate tool availability before starting loop
    if ! command -v "$tool" &>/dev/null; then
        print_error "Tool '$tool' not found. Please install it or use --tool to specify a different tool."
        print_info "Available tools: opencode, claude, aider"
        return 1
    fi

    print_info "Starting external Ralph loop with $tool"
    echo "Prompt: $prompt"
    echo "Max iterations: $(if [[ $max_iterations -gt 0 ]]; then echo "$max_iterations"; else echo "unlimited"; fi)"
    echo "Completion promise: $(if [[ "$completion_promise" != "null" ]]; then echo "$completion_promise"; else echo "none"; fi)"
    echo ""

    local iteration=1
    local output_file
    output_file=$(mktemp)

    # Cleanup on exit
    trap 'rm -f "$output_file"' EXIT

    while true; do
        print_info "Ralph iteration $iteration"

        # Check max iterations
        if [[ $max_iterations -gt 0 ]] && [[ $iteration -gt $max_iterations ]]; then
            print_warning "Max iterations ($max_iterations) reached. Stopping."
            break
        fi

        # Build the full prompt with iteration info
        local full_prompt
        if [[ "$completion_promise" != "null" ]]; then
            full_prompt="[Ralph iteration $iteration] $prompt

To complete, output: <promise>$completion_promise</promise> (ONLY when TRUE)"
        else
            full_prompt="[Ralph iteration $iteration] $prompt"
        fi

        # Run the AI tool (capture exit code, log failures but continue loop)
        local tool_exit_code=0
        case "$tool" in
            opencode)
                echo "$full_prompt" | opencode --print > "$output_file" 2>&1 || tool_exit_code=$?
                ;;
            claude)
                echo "$full_prompt" | claude --print > "$output_file" 2>&1 || tool_exit_code=$?
                ;;
            aider)
                # Aider uses --message flag only (not stdin) to avoid duplicate prompts
                aider --yes --message "$full_prompt" > "$output_file" 2>&1 || tool_exit_code=$?
                ;;
            *)
                print_error "Unknown tool: $tool"
                return 1
                ;;
        esac

        # Log tool failures but continue (AI tools may exit non-zero for various reasons)
        if [[ $tool_exit_code -ne 0 ]]; then
            print_warning "Tool '$tool' exited with code $tool_exit_code (continuing loop)"
        fi

        # Check for completion
        if [[ "$completion_promise" != "null" ]]; then
            local result
            result=$(check_completion "$(cat "$output_file")" "$completion_promise")
            if [[ "$result" == "COMPLETE" ]]; then
                print_success "Completion promise detected! Loop finished."
                break
            fi
        fi

        iteration=$((iteration + 1))

        # Adaptive delay with exponential backoff
        # Starts at RALPH_DELAY_BASE, increases by RALPH_DELAY_MULTIPLIER each iteration
        # Capped at RALPH_DELAY_MAX
        local delay
        # Calculate: base * multiplier^(iteration-1), using bc for floating point
        if command -v bc &>/dev/null; then
            delay=$(echo "scale=0; $RALPH_DELAY_BASE * ($RALPH_DELAY_MULTIPLIER ^ ($iteration - 1))" | bc 2>/dev/null || echo "$RALPH_DELAY_BASE")
            # Cap at max
            if [[ $(echo "$delay > $RALPH_DELAY_MAX" | bc 2>/dev/null || echo "0") -eq 1 ]]; then
                delay=$RALPH_DELAY_MAX
            fi
        else
            # Fallback: simple doubling without bc
            delay=$RALPH_DELAY_BASE
            local i=1
            while [[ $i -lt $iteration ]] && [[ $delay -lt $RALPH_DELAY_MAX ]]; do
                delay=$((delay * 2))
                ((i++))
            done
            [[ $delay -gt $RALPH_DELAY_MAX ]] && delay=$RALPH_DELAY_MAX
        fi
        
        print_info "Waiting ${delay}s before next iteration (backoff: iteration $iteration)"
        sleep "$delay"
    done

    print_success "Ralph loop completed after $iteration iterations"
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        setup)
            setup_loop "$@"
            ;;
        cancel)
            cancel_loop
            ;;
        status)
            show_status "$@"
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
        get-max-iterations)
            get_max_iterations
            ;;
        get-completion-promise)
            get_completion_promise
            ;;
        external)
            run_external_loop "$@"
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
