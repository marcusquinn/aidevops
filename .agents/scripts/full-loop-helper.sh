#!/usr/bin/env bash
# =============================================================================
# Full Development Loop Orchestrator (Simplified)
# =============================================================================
# Chains the complete development workflow:
#   Task -> Preflight -> PR Create -> PR Review -> Postflight -> Deploy
#
# Per "Intelligence Over Scripts" (architecture.md): This script handles only
# deterministic utilities (state management, background execution, worktree).
# All decision-making logic is in full-loop.md — the AI reads that and acts.
#
# Usage:
#   full-loop-helper.sh start "<prompt>" [options]
#   full-loop-helper.sh status
#   full-loop-helper.sh cancel
#   full-loop-helper.sh resume
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
readonly STATE_DIR=".agents/loop-state"
readonly STATE_FILE="${STATE_DIR}/full-loop.local.state"

# Default settings
readonly DEFAULT_MAX_TASK_ITERATIONS=50
readonly DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
readonly DEFAULT_MAX_PR_ITERATIONS=20

# Phase names
readonly PHASE_TASK="task"
readonly PHASE_PREFLIGHT="preflight"
readonly PHASE_PR_CREATE="pr-create"
readonly PHASE_PR_REVIEW="pr-review"
readonly PHASE_POSTFLIGHT="postflight"
readonly PHASE_DEPLOY="deploy"
readonly PHASE_COMPLETE="complete"

readonly BOLD='\033[1m'

# Headless mode: set via --headless flag or FULL_LOOP_HEADLESS env var
HEADLESS="${FULL_LOOP_HEADLESS:-false}"

# =============================================================================
# Helper Functions
# =============================================================================

is_headless() {
	[[ "$HEADLESS" == "true" ]]
}

print_phase() {
	local phase="$1"
	local description="$2"
	echo ""
	echo -e "${BOLD}${CYAN}=== Phase: ${phase} ===${NC}"
	echo -e "${CYAN}${description}${NC}"
	echo ""
}

# =============================================================================
# State Management
# =============================================================================

init_state_dir() {
	mkdir -p "$STATE_DIR"
}

save_state() {
	local phase="$1"
	local prompt="$2"
	local pr_number="${3:-}"
	local started_at="${4:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

	init_state_dir

	cat >"$STATE_FILE" <<EOF
---
active: true
phase: ${phase}
started_at: "${started_at}"
updated_at: "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
pr_number: "${pr_number}"
max_task_iterations: ${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}
max_preflight_iterations: ${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}
max_pr_iterations: ${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}
skip_preflight: ${SKIP_PREFLIGHT:-false}
skip_postflight: ${SKIP_POSTFLIGHT:-false}
no_auto_pr: ${NO_AUTO_PR:-false}
no_auto_deploy: ${NO_AUTO_DEPLOY:-false}
headless: ${HEADLESS:-false}
---

${prompt}
EOF
}

load_state() {
	if [[ ! -f "$STATE_FILE" ]]; then
		return 1
	fi

	CURRENT_PHASE=$(grep '^phase:' "$STATE_FILE" | cut -d: -f2 | tr -d ' "')
	STARTED_AT=$(grep '^started_at:' "$STATE_FILE" | cut -d: -f2- | tr -d ' "')
	PR_NUMBER=$(grep '^pr_number:' "$STATE_FILE" | cut -d: -f2 | tr -d ' "')
	MAX_TASK_ITERATIONS=$(grep '^max_task_iterations:' "$STATE_FILE" | cut -d: -f2 | tr -d ' ')
	MAX_PREFLIGHT_ITERATIONS=$(grep '^max_preflight_iterations:' "$STATE_FILE" | cut -d: -f2 | tr -d ' ')
	MAX_PR_ITERATIONS=$(grep '^max_pr_iterations:' "$STATE_FILE" | cut -d: -f2 | tr -d ' ')
	SKIP_PREFLIGHT=$(grep '^skip_preflight:' "$STATE_FILE" | cut -d: -f2 | tr -d ' ')
	SKIP_POSTFLIGHT=$(grep '^skip_postflight:' "$STATE_FILE" | cut -d: -f2 | tr -d ' ')
	NO_AUTO_PR=$(grep '^no_auto_pr:' "$STATE_FILE" | cut -d: -f2 | tr -d ' ')
	NO_AUTO_DEPLOY=$(grep '^no_auto_deploy:' "$STATE_FILE" | cut -d: -f2 | tr -d ' ')
	HEADLESS=$(grep '^headless:' "$STATE_FILE" | cut -d: -f2 | tr -d ' ')
	HEADLESS="${HEADLESS:-false}"

	SAVED_PROMPT=$(sed -n '/^---$/,/^---$/d; p' "$STATE_FILE")
}

clear_state() {
	rm -f "$STATE_FILE"
}

is_loop_active() {
	[[ -f "$STATE_FILE" ]] && grep -q '^active: true' "$STATE_FILE"
}

# =============================================================================
# Detection Functions
# =============================================================================

is_aidevops_repo() {
	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	[[ "$repo_root" == *"/aidevops"* ]] || [[ -f "$repo_root/.aidevops-repo" ]]
}

get_current_branch() {
	git branch --show-current 2>/dev/null || echo ""
}

is_on_feature_branch() {
	local branch
	branch=$(get_current_branch)
	[[ -n "$branch" && "$branch" != "main" && "$branch" != "master" ]]
}

# =============================================================================
# Phase Output Functions
# =============================================================================
# These functions emit phase markers that the AI reads. The AI handles
# the actual work based on full-loop.md guidance.

emit_task_phase() {
	local prompt="$1"
	print_phase "Task Development" "AI will iterate on task until TASK_COMPLETE"
	echo "PROMPT: $prompt"
	echo ""
	echo "The AI should now implement the task following full-loop.md guidance."
	echo "When complete, the AI emits: <promise>TASK_COMPLETE</promise>"
}

emit_preflight_phase() {
	print_phase "Preflight" "AI runs quality checks"
	if [[ "${SKIP_PREFLIGHT:-false}" == "true" ]]; then
		print_warning "Preflight skipped by user request"
		echo "<promise>PREFLIGHT_SKIPPED</promise>"
		return 0
	fi
	echo "The AI should run quality checks following full-loop.md guidance."
}

emit_pr_create_phase() {
	print_phase "PR Creation" "AI creates pull request"
	if [[ "${NO_AUTO_PR:-false}" == "true" ]] && ! is_headless; then
		print_warning "Auto PR creation disabled. Create PR manually."
		return 0
	fi
	echo "The AI should create PR following full-loop.md guidance."
}

emit_pr_review_phase() {
	print_phase "PR Review" "AI monitors CI and reviews"
	echo "The AI should monitor PR following full-loop.md guidance."
}

emit_postflight_phase() {
	print_phase "Postflight" "AI verifies release health"
	if [[ "${SKIP_POSTFLIGHT:-false}" == "true" ]]; then
		print_warning "Postflight skipped by user request"
		echo "<promise>POSTFLIGHT_SKIPPED</promise>"
		return 0
	fi
	echo "The AI should verify release following full-loop.md guidance."
}

emit_deploy_phase() {
	print_phase "Deploy" "AI deploys changes"
	if ! is_aidevops_repo; then
		print_info "Not an aidevops repo, skipping deploy phase"
		return 0
	fi
	if [[ "${NO_AUTO_DEPLOY:-false}" == "true" ]]; then
		print_warning "Auto deploy disabled. Run manually: ./setup.sh"
		return 0
	fi
	echo "The AI should run setup.sh following full-loop.md guidance."
}

# =============================================================================
# Main Commands
# =============================================================================

cmd_start() {
	local prompt="$1"
	shift

	local background=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--max-task-iterations) MAX_TASK_ITERATIONS="$2"; shift 2 ;;
		--max-preflight-iterations) MAX_PREFLIGHT_ITERATIONS="$2"; shift 2 ;;
		--max-pr-iterations) MAX_PR_ITERATIONS="$2"; shift 2 ;;
		--skip-preflight) SKIP_PREFLIGHT=true; shift ;;
		--skip-postflight) SKIP_POSTFLIGHT=true; shift ;;
		--no-auto-pr) NO_AUTO_PR=true; shift ;;
		--no-auto-deploy) NO_AUTO_DEPLOY=true; shift ;;
		--headless) HEADLESS=true; shift ;;
		--dry-run) DRY_RUN=true; shift ;;
		--background | --bg) background=true; shift ;;
		*) print_error "Unknown option: $1"; return 1 ;;
		esac
	done

	if [[ -z "$prompt" ]]; then
		print_error "No prompt provided"
		echo "Usage: full-loop-helper.sh start \"<prompt>\" [options]"
		return 1
	fi

	if is_loop_active; then
		print_warning "A loop is already active. Use 'resume' to continue or 'cancel' to stop."
		return 1
	fi

	if ! is_on_feature_branch; then
		print_error "Must be on a feature branch to start full loop"
		print_info "Create a branch first: git checkout -b feature/your-feature"
		return 1
	fi

	echo ""
	echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
	echo -e "${BOLD}${BLUE}║           FULL DEVELOPMENT LOOP - STARTING                 ║${NC}"
	echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
	echo ""
	echo -e "${CYAN}Task:${NC} $prompt"
	echo -e "${CYAN}Branch:${NC} $(get_current_branch)"
	echo -e "${CYAN}Headless:${NC} $HEADLESS"
	echo ""

	if [[ "${DRY_RUN:-false}" == "true" ]]; then
		print_info "Dry run - no changes made"
		return 0
	fi

	save_state "$PHASE_TASK" "$prompt"
	SAVED_PROMPT="$prompt"

	if [[ "$background" == "true" ]]; then
		local log_file="${STATE_DIR}/full-loop.log"
		local pid_file="${STATE_DIR}/full-loop.pid"

		mkdir -p "$STATE_DIR"

		print_info "Starting full loop in background..."

		export MAX_TASK_ITERATIONS MAX_PREFLIGHT_ITERATIONS MAX_PR_ITERATIONS
		export SKIP_PREFLIGHT SKIP_POSTFLIGHT NO_AUTO_PR NO_AUTO_DEPLOY
		export FULL_LOOP_HEADLESS="$HEADLESS"
		export SAVED_PROMPT="$prompt"

		nohup "$0" _run_foreground "$prompt" >"$log_file" 2>&1 &
		local pid=$!
		echo "$pid" >"$pid_file"

		print_success "Full loop started in background (PID: $pid)"
		print_info "Check status: full-loop-helper.sh status"
		print_info "View logs: full-loop-helper.sh logs"
		return 0
	fi

	emit_task_phase "$prompt"
}

cmd_run_foreground() {
	local prompt="$1"
	emit_task_phase "$prompt"
	# In foreground mode, AI continues iterating. This script just emits markers.
}

cmd_resume() {
	if ! is_loop_active; then
		print_error "No active loop to resume"
		return 1
	fi

	load_state

	print_info "Resuming from phase: $CURRENT_PHASE"

	case "$CURRENT_PHASE" in
	"$PHASE_TASK")
		save_state "$PHASE_PREFLIGHT" "$SAVED_PROMPT" "" "$STARTED_AT"
		emit_preflight_phase
		;;
	"$PHASE_PREFLIGHT")
		save_state "$PHASE_PR_CREATE" "$SAVED_PROMPT" "" "$STARTED_AT"
		emit_pr_create_phase
		;;
	"$PHASE_PR_CREATE")
		save_state "$PHASE_PR_REVIEW" "$SAVED_PROMPT" "" "$STARTED_AT"
		emit_pr_review_phase
		;;
	"$PHASE_PR_REVIEW")
		save_state "$PHASE_POSTFLIGHT" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"
		emit_postflight_phase
		;;
	"$PHASE_POSTFLIGHT")
		save_state "$PHASE_DEPLOY" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"
		emit_deploy_phase
		;;
	"$PHASE_DEPLOY")
		save_state "$PHASE_COMPLETE" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"
		cmd_complete
		;;
	"$PHASE_COMPLETE")
		cmd_complete
		;;
	*)
		print_error "Unknown phase: $CURRENT_PHASE"
		return 1
		;;
	esac
}

cmd_status() {
	if ! is_loop_active; then
		echo "No active full loop"
		return 0
	fi

	load_state

	echo ""
	echo -e "${BOLD}Full Development Loop Status${NC}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo -e "Phase:    ${CYAN}$CURRENT_PHASE${NC}"
	echo -e "Started:  $STARTED_AT"
	echo -e "PR:       ${PR_NUMBER:-none}"
	echo -e "Headless: $HEADLESS"
	echo ""
	echo "Prompt:"
	echo "$SAVED_PROMPT" | head -5
	echo ""
}

cmd_cancel() {
	if ! is_loop_active; then
		print_warning "No active loop to cancel"
		return 0
	fi

	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		if kill -0 "$pid" 2>/dev/null; then
			print_info "Stopping background process (PID: $pid)..."
			kill "$pid" 2>/dev/null || true
			sleep 1
			kill -9 "$pid" 2>/dev/null || true
		fi
		rm -f "$pid_file"
	fi

	clear_state

	# Clean up sub-loop state files
	rm -f ".agents/loop-state/ralph-loop.local.state" 2>/dev/null
	rm -f ".agents/loop-state/quality-loop.local.state" 2>/dev/null

	print_success "Full loop cancelled"
}

cmd_logs() {
	local log_file="${STATE_DIR}/full-loop.log"
	local lines="${1:-50}"

	if [[ ! -f "$log_file" ]]; then
		print_warning "No log file found. Start a loop with --background first."
		return 1
	fi

	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		if kill -0 "$pid" 2>/dev/null; then
			print_info "Background process running (PID: $pid)"
		else
			print_warning "Background process not running (was PID: $pid)"
		fi
	fi

	echo ""
	echo -e "${BOLD}Full Loop Logs (last $lines lines)${NC}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	tail -n "$lines" "$log_file"
}

cmd_complete() {
	echo ""
	echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
	echo -e "${BOLD}${GREEN}║           FULL DEVELOPMENT LOOP - COMPLETE                 ║${NC}"
	echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
	echo ""

	load_state 2>/dev/null || true

	echo -e "${GREEN}All phases completed successfully!${NC}"
	echo ""
	echo "Summary:"
	echo "  - Task: Implemented"
	echo "  - Preflight: Passed"
	echo "  - PR: #${PR_NUMBER:-unknown} merged"
	echo "  - Postflight: Healthy"
	if is_aidevops_repo; then
		echo "  - Deploy: Complete"
	fi
	echo ""

	clear_state

	echo "<promise>FULL_LOOP_COMPLETE</promise>"
}

show_help() {
	cat <<'EOF'
Full Development Loop Orchestrator (Simplified)

Per "Intelligence Over Scripts": This script handles state and background
execution. The AI reads full-loop.md for all decision-making guidance.

USAGE:
    full-loop-helper.sh <command> [options]

COMMANDS:
    start "<prompt>"    Start a new full development loop
    resume              Resume from the current phase
    status              Show current loop status
    cancel              Cancel the active loop
    logs [N]            Show last N lines of background logs (default: 50)
    help                Show this help

OPTIONS:
    --max-task-iterations N       Max iterations for task (default: 50)
    --max-preflight-iterations N  Max iterations for preflight (default: 5)
    --max-pr-iterations N         Max iterations for PR review (default: 20)
    --skip-preflight              Skip preflight checks
    --skip-postflight             Skip postflight monitoring
    --no-auto-pr                  Don't auto-create PR
    --no-auto-deploy              Don't auto-run setup.sh
    --headless                    Headless worker mode (no prompts)
    --dry-run                     Show what would happen
    --background, --bg            Run in background

PHASES:
    1. Task Development   - AI implements the task
    2. Preflight          - AI runs quality checks
    3. PR Creation        - AI creates pull request
    4. PR Review          - AI monitors CI and reviews
    5. Postflight         - AI verifies release health
    6. Deploy             - AI runs setup.sh (aidevops only)

EXAMPLES:
    # Start full loop
    full-loop-helper.sh start "Implement feature X"

    # Background mode (recommended for long tasks)
    full-loop-helper.sh start "Fix bug Y" --background

    # Headless mode (used by supervisor)
    full-loop-helper.sh start "Task Z" --headless --background

    # Check status
    full-loop-helper.sh status

ENVIRONMENT:
    FULL_LOOP_HEADLESS=true    Same as --headless flag

EOF
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	start) cmd_start "$@" ;;
	resume) cmd_resume ;;
	status) cmd_status ;;
	cancel) cmd_cancel ;;
	logs) cmd_logs "$@" ;;
	_run_foreground) cmd_run_foreground "$@" ;;
	help | --help | -h) show_help ;;
	*) print_error "Unknown command: $command"; show_help; return 1 ;;
	esac
}

main "$@"
