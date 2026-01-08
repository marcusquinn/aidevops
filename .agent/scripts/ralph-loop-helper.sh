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

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

print_error() {
    local message="$1"
    echo -e "${RED}Error:${NC} ${message}" >&2
    return 0
}

print_success() {
    local message="$1"
    echo -e "${GREEN}${message}${NC}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}${message}${NC}"
    return 0
}

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
  status    Show current loop status
  check     Check if output contains completion promise
  increment Increment iteration counter
  external  Run external bash loop (for tools without hook support)
  help      Show this help message

SETUP OPTIONS:
  --max-iterations <n>           Maximum iterations (default: 0 = unlimited)
  --completion-promise '<text>'  Promise phrase to detect completion

EXTERNAL OPTIONS:
  --tool <name>                  AI CLI tool to use (opencode, claude, aider)
  --max-iterations <n>           Maximum iterations
  --completion-promise '<text>'  Promise phrase

EXAMPLES:
  # Start a loop (for tools with hook support)
  ralph-loop-helper.sh setup "Build a REST API" --max-iterations 20 --completion-promise "DONE"

  # Check status
  ralph-loop-helper.sh status

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

LEARN MORE:
  Original technique: https://ghuntley.com/ralph/
  Documentation: ~/.aidevops/agents/workflows/ralph-loop.md
EOF
    return 0
}

# =============================================================================
# Core Functions
# =============================================================================

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

show_status() {
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        echo "No active Ralph loop."
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

check_completion() {
    local output="$1"
    local completion_promise="${2:-}"

    # If no completion promise, can't complete
    if [[ -z "$completion_promise" ]] || [[ "$completion_promise" == "null" ]]; then
        echo "NO_PROMISE"
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
    local temp_file="${RALPH_STATE_FILE}.tmp.$$"
    sed "s/^iteration: .*/iteration: $next_iteration/" "$RALPH_STATE_FILE" > "$temp_file"
    mv "$temp_file" "$RALPH_STATE_FILE"

    echo "$next_iteration"
    return 0
}

get_prompt() {
    if [[ ! -f "$RALPH_STATE_FILE" ]]; then
        print_error "No active Ralph loop"
        return 1
    fi

    # Extract prompt (everything after the closing ---)
    awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE"
    return 0
}

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

        # Run the AI tool
        case "$tool" in
            opencode)
                echo "$full_prompt" | opencode --print > "$output_file" 2>&1 || true
                ;;
            claude)
                echo "$full_prompt" | claude --print > "$output_file" 2>&1 || true
                ;;
            aider)
                echo "$full_prompt" | aider --message "$full_prompt" > "$output_file" 2>&1 || true
                ;;
            *)
                print_error "Unknown tool: $tool"
                return 1
                ;;
        esac

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

        # Small delay between iterations
        sleep 2
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
            show_status
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
