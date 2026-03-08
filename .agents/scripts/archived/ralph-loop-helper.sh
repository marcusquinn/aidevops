#!/usr/bin/env bash
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
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly SCRIPT_NAME="ralph-loop-helper.sh"

# Source shared loop infrastructure
# shellcheck source=loop-common.sh
if [[ -f "$SCRIPT_DIR/loop-common.sh" ]]; then
	source "$SCRIPT_DIR/loop-common.sh"
fi

# State directories
readonly RALPH_STATE_DIR=".agents/loop-state"
readonly RALPH_STATE_FILE="${RALPH_STATE_DIR}/ralph-loop.local.state"

# Legacy state directory (for backward compatibility during migration)
readonly RALPH_LEGACY_STATE_DIR=".claude"
# shellcheck disable=SC2034  # Defined for documentation, used in status checks
readonly RALPH_LEGACY_STATE_FILE="${RALPH_LEGACY_STATE_DIR}/ralph-loop.local.state"

# Adaptive timing constants (evidence-based from PR #19 analysis)
readonly RALPH_DELAY_BASE="${RALPH_DELAY_BASE:-2}"
readonly RALPH_DELAY_MAX="${RALPH_DELAY_MAX:-30}"
readonly RALPH_DELAY_MULTIPLIER="${RALPH_DELAY_MULTIPLIER:-1.5}"

# v2 defaults
readonly DEFAULT_MAX_ITERATIONS=50
readonly DEFAULT_MAX_ATTEMPTS=5

# Colors (fallback if loop-common.sh not loaded)
readonly BOLD='\033[1m'

# Output file for tool capture (shared with EXIT trap)
output_file=""

# =============================================================================
# Helper Functions
# =============================================================================

print_step() {
	local message="$1"
	echo -e "${CYAN}[ralph]${NC} ${message}"
	return 0
}

show_help() {
	cat <<'EOF'
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

# Custom tool runner for opencode with --format json and optional --model
# Used as callback for loop_run_external's tool_runner_func parameter.
# Arguments:
#   $1 - output_file (path to write tool output)
#   $2 - prompt (full re-anchor prompt)
# Returns: tool exit code
_ralph_opencode_runner() {
	local out_file="$1"
	local prompt_text="$2"

	local opencode_args=("run" "$prompt_text" "--format" "json")
	if [[ -n "${RALPH_MODEL:-}" ]]; then
		opencode_args+=("--model" "$RALPH_MODEL")
	fi
	opencode "${opencode_args[@]}" >"$out_file" 2>&1
}

# Run v2 loop with fresh sessions per iteration
# Thin wrapper: parses arguments, initializes state, then delegates to
# loop_run_external (loop-common.sh) for the core loop logic.
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

	# Parse arguments (with validation for required values)
	while [[ $# -gt 0 ]]; do
		case $1 in
		--max-iterations)
			if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
				print_error "--max-iterations requires a numeric argument"
				return 1
			fi
			max_iterations="$2"
			shift 2
			;;
		--completion-promise)
			if [[ -z "${2:-}" ]]; then
				print_error "--completion-promise requires an argument"
				return 1
			fi
			completion_promise="$2"
			shift 2
			;;
		--tool)
			if [[ -z "${2:-}" ]]; then
				print_error "--tool requires an argument"
				return 1
			fi
			tool="$2"
			shift 2
			;;
		--max-attempts)
			if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
				print_error "--max-attempts requires a numeric argument"
				return 1
			fi
			max_attempts="$2"
			shift 2
			;;
		--task-id)
			if [[ -z "${2:-}" ]]; then
				print_error "--task-id requires an argument"
				return 1
			fi
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

	# Calculate adaptive delay for first iteration (used as base delay)
	local delay_seconds
	delay_seconds=$(calculate_delay 1)

	# Determine tool runner: use custom callback for opencode (--format json + --model)
	local tool_runner_func=""
	if [[ "$tool" == "opencode" ]]; then
		tool_runner_func="_ralph_opencode_runner"
	fi

	# Delegate to shared loop infrastructure (DRY: core loop logic in loop-common.sh)
	if type loop_run_external &>/dev/null; then
		loop_run_external "$tool" "$prompt" "$max_iterations" "$completion_promise" \
			"$max_attempts" "$delay_seconds" "$tool_runner_func"
	else
		print_error "loop-common.sh not loaded — cannot run v2 loop"
		return 1
	fi
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

	cat >"$RALPH_STATE_FILE" <<EOF
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
		--all | -a)
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
			local v2_state="$worktree_path/.agents/loop-state/loop-state.json"
			local v2_state_legacy="$worktree_path/.claude/loop-state.json"
			local legacy_state="$worktree_path/.agents/loop-state/ralph-loop.local.state"
			local legacy_state_old="$worktree_path/.claude/ralph-loop.local.state"

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
			local v2_state="$worktree_path/.agents/loop-state/loop-state.json"
			local v2_state_legacy="$worktree_path/.claude/loop-state.json"
			local legacy_state="$worktree_path/.agents/loop-state/ralph-loop.local.state"
			local legacy_state_old="$worktree_path/.claude/ralph-loop.local.state"

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

	# Whitespace-tolerant matching: allow spaces/newlines inside promise tags
	if grep -qP "<promise>\s*\Q$completion_promise\E\s*</promise>" <<<"$output" 2>/dev/null ||
		grep -q "<promise>$completion_promise</promise>" <<<"$output" 2>/dev/null; then
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
	sed "s/^iteration: .*/iteration: $next_iteration/" "$RALPH_STATE_FILE" >"$temp_file"
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
	check | check-completion)
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
	help | --help | -h)
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
