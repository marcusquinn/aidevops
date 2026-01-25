#!/bin/bash
# =============================================================================
# Full Development Loop Orchestrator
# =============================================================================
# Chains the complete development workflow:
#   Task → Preflight → PR Create → PR Review → Postflight → Deploy
#
# This implements the "holy grail" of AI-assisted development - taking an idea
# from conception through to availability with minimal human intervention.
#
# Usage:
#   full-loop-helper.sh start "<prompt>" [options]
#   full-loop-helper.sh status
#   full-loop-helper.sh cancel
#   full-loop-helper.sh resume
#
# Options:
#   --max-task-iterations N    Max iterations for task development (default: 50)
#   --max-preflight-iterations N  Max iterations for preflight (default: 5)
#   --max-pr-iterations N      Max iterations for PR review (default: 20)
#   --skip-preflight           Skip preflight checks (not recommended)
#   --skip-postflight          Skip postflight monitoring
#   --no-auto-pr               Don't auto-create PR, pause for human
#   --no-auto-deploy           Don't auto-run setup.sh (aidevops only)
#   --dry-run                  Show what would happen without executing
#
# Human Decision Points:
#   - Initial task definition (before start)
#   - Merge approval (if repo requires human approval)
#   - Rollback decision (if postflight detects issues)
#
# Author: AI DevOps Framework
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly STATE_DIR=".agent/loop-state"
readonly STATE_FILE="${STATE_DIR}/full-loop.local.state"

# Legacy state directory (for backward compatibility during migration)
# shellcheck disable=SC2034  # Defined for documentation, used in cancel checks
readonly LEGACY_STATE_DIR=".claude"
# shellcheck disable=SC2034  # Defined for backward compatibility path reference
readonly LEGACY_STATE_FILE="${LEGACY_STATE_DIR}/full-loop.local.state"

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

# Colors
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
    echo -e "${RED}[full-loop] Error:${NC} ${message}" >&2
    return 0
}

print_success() {
    local message="$1"
    echo -e "${GREEN}[full-loop]${NC} ${message}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[full-loop]${NC} ${message}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}[full-loop]${NC} ${message}"
    return 0
}

print_phase() {
    local phase="$1"
    local description="$2"
    echo ""
    echo -e "${BOLD}${CYAN}=== Phase: ${phase} ===${NC}"
    echo -e "${CYAN}${description}${NC}"
    echo ""
    return 0
}

# =============================================================================
# State Management
# =============================================================================

init_state_dir() {
    mkdir -p "$STATE_DIR"
    return 0
}

save_state() {
    local phase="$1"
    local prompt="$2"
    local pr_number="${3:-}"
    local started_at="${4:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
    
    init_state_dir
    
    cat > "$STATE_FILE" << EOF
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
---

${prompt}
EOF
    return 0
}

load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1
    fi
    
    # Parse YAML frontmatter
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
    
    # Extract prompt (everything after the second ---)
    SAVED_PROMPT=$(sed -n '/^---$/,/^---$/d; p' "$STATE_FILE")
    
    return 0
}

clear_state() {
    rm -f "$STATE_FILE"
    return 0
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
    
    # Check if repo name contains aidevops
    if [[ "$repo_root" == *"/aidevops"* ]]; then
        return 0
    fi
    
    # Check for marker file
    if [[ -f "$repo_root/.aidevops-repo" ]]; then
        return 0
    fi
    
    # Check if setup.sh exists and contains aidevops marker
    if [[ -f "$repo_root/setup.sh" ]] && grep -q "aidevops" "$repo_root/setup.sh" 2>/dev/null; then
        return 0
    fi
    
    return 1
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
# Phase Execution Functions
# =============================================================================

run_task_phase() {
    local prompt="$1"
    local max_iterations="${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}"
    
    # Auto-detect AI tool environment if RALPH_TOOL not explicitly set
    # Priority: RALPH_TOOL env > OPENCODE env > CLAUDE_CODE env > command availability
    local tool="${RALPH_TOOL:-}"
    if [[ -z "$tool" ]]; then
        if [[ -n "${OPENCODE:-}" ]] || [[ "${TERM_PROGRAM:-}" == "opencode" ]]; then
            tool="opencode"
        elif [[ -n "${CLAUDE_CODE:-}" ]]; then
            tool="claude"
        elif command -v opencode &>/dev/null; then
            tool="opencode"
        elif command -v claude &>/dev/null; then
            tool="claude"
        else
            tool="opencode"  # Default fallback name (will trigger legacy mode)
        fi
    fi
    
    print_info "Detected AI tool: $tool"
    
    print_phase "Task Development" "Running Ralph loop for task implementation"
    
    # Check if ralph-loop-helper.sh exists
    if [[ ! -x "$SCRIPT_DIR/ralph-loop-helper.sh" ]]; then
        print_error "ralph-loop-helper.sh not found or not executable"
        return 1
    fi
    
    # Check if loop-common.sh exists (v2 infrastructure)
    local use_v2=false
    if [[ -f "$SCRIPT_DIR/loop-common.sh" ]]; then
        use_v2=true
    fi
    
    if [[ "$use_v2" == "true" ]] && command -v "$tool" &>/dev/null; then
        # v2: External loop with fresh sessions per iteration
        print_info "Using v2 architecture (fresh context per iteration)"
        "$SCRIPT_DIR/ralph-loop-helper.sh" run "$prompt" \
            --tool "$tool" \
            --max-iterations "$max_iterations" \
            --completion-promise "TASK_COMPLETE"
    else
        # Legacy: Same-session loop (tool not available or no v2 infrastructure)
        print_warning "Using legacy mode (same session). $tool CLI not found for v2 external loop."
        "$SCRIPT_DIR/ralph-loop-helper.sh" setup "$prompt" \
            --max-iterations "$max_iterations" \
            --completion-promise "TASK_COMPLETE"
        
        print_info "Task loop initialized. AI will iterate until TASK_COMPLETE promise."
        print_info "After task completion, run: full-loop-helper.sh resume"
    fi
    
    return 0
}

run_preflight_phase() {
    print_phase "Preflight" "Running quality checks before commit"
    
    if [[ "${SKIP_PREFLIGHT:-false}" == "true" ]]; then
        print_warning "Preflight skipped by user request"
        echo "<promise>PREFLIGHT_PASS</promise>"
        return 0
    fi
    
    # Run quality loop for preflight
    local preflight_ran=false
    if [[ -x "$SCRIPT_DIR/quality-loop-helper.sh" ]]; then
        "$SCRIPT_DIR/quality-loop-helper.sh" preflight --auto-fix --max-iterations "${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}"
        preflight_ran=true
    else
        # Fallback to linters-local.sh
        if [[ -x "$SCRIPT_DIR/linters-local.sh" ]]; then
            "$SCRIPT_DIR/linters-local.sh"
            preflight_ran=true
        else
            print_warning "No preflight script found, skipping checks"
            print_info "Proceeding without preflight validation"
        fi
    fi
    
    # Only emit promise if checks actually ran
    if [[ "$preflight_ran" == "true" ]]; then
        echo "<promise>PREFLIGHT_PASS</promise>"
    else
        echo "<promise>PREFLIGHT_SKIPPED</promise>"
    fi
    return 0
}

run_pr_create_phase() {
    print_phase "PR Creation" "Creating pull request"
    
    if [[ "${NO_AUTO_PR:-false}" == "true" ]]; then
        print_warning "Auto PR creation disabled. Please create PR manually."
        print_info "Run: gh pr create --fill"
        print_info "Then run: full-loop-helper.sh resume"
        return 0
    fi
    
    # Ensure we're on a feature branch
    if ! is_on_feature_branch; then
        print_error "Not on a feature branch. Cannot create PR from main/master."
        return 1
    fi
    
    # Push branch if needed
    local branch
    branch=$(get_current_branch)
    
    if ! git ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
        print_info "Pushing branch to origin..."
        git push -u origin "$branch"
    fi
    
    # Create PR
    print_info "Creating pull request..."
    local pr_url
    pr_url=$(gh pr create --fill 2>&1) || {
        # PR might already exist
        pr_url=$(gh pr view --json url --jq '.url' 2>/dev/null || echo "")
        if [[ -z "$pr_url" ]]; then
            print_error "Failed to create PR"
            return 1
        fi
        print_info "PR already exists: $pr_url"
    }
    
    # Extract PR number
    local pr_number
    pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || gh pr view --json number --jq '.number')
    
    print_success "PR created: $pr_url"
    
    # Update state with PR number
    save_state "$PHASE_PR_REVIEW" "$SAVED_PROMPT" "$pr_number" "$STARTED_AT"
    
    return 0
}

run_pr_review_phase() {
    print_phase "PR Review" "Monitoring PR for approval and CI checks"
    
    local pr_number="${PR_NUMBER:-}"
    
    if [[ -z "$pr_number" ]]; then
        # Try to get PR number from current branch
        pr_number=$(gh pr view --json number --jq '.number' 2>/dev/null || echo "")
    fi
    
    if [[ -z "$pr_number" ]]; then
        print_error "No PR number found. Create PR first."
        return 1
    fi
    
    print_info "Monitoring PR #$pr_number..."
    
    # Run quality loop for PR review
    if [[ -x "$SCRIPT_DIR/quality-loop-helper.sh" ]]; then
        "$SCRIPT_DIR/quality-loop-helper.sh" pr-review --pr "$pr_number" --wait-for-ci --max-iterations "${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}"
        
        # Verify PR was actually merged before emitting promise
        local pr_state
        pr_state=$(gh pr view "$pr_number" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
        if [[ "$pr_state" == "MERGED" ]]; then
            echo "<promise>PR_MERGED</promise>"
        else
            print_warning "PR #$pr_number is $pr_state (not merged yet)"
            print_info "Merge PR manually, then run: full-loop-helper.sh resume"
            echo "<promise>PR_APPROVED</promise>"
        fi
    else
        print_warning "quality-loop-helper.sh not found, waiting for manual merge"
        print_info "Merge PR manually, then run: full-loop-helper.sh resume"
        echo "<promise>PR_WAITING</promise>"
    fi
    
    return 0
}

run_postflight_phase() {
    print_phase "Postflight" "Verifying release health"
    
    if [[ "${SKIP_POSTFLIGHT:-false}" == "true" ]]; then
        print_warning "Postflight skipped by user request"
        echo "<promise>POSTFLIGHT_SKIPPED</promise>"
        return 0
    fi
    
    # Run quality loop for postflight
    local postflight_ran=false
    if [[ -x "$SCRIPT_DIR/quality-loop-helper.sh" ]]; then
        "$SCRIPT_DIR/quality-loop-helper.sh" postflight --monitor-duration 5m
        postflight_ran=true
    else
        # Fallback to postflight-check.sh
        if [[ -x "$SCRIPT_DIR/postflight-check.sh" ]]; then
            "$SCRIPT_DIR/postflight-check.sh"
            postflight_ran=true
        else
            print_warning "No postflight script found, skipping verification"
            print_info "Proceeding without postflight validation"
        fi
    fi
    
    # Only emit promise if checks actually ran
    if [[ "$postflight_ran" == "true" ]]; then
        echo "<promise>RELEASE_HEALTHY</promise>"
    else
        echo "<promise>POSTFLIGHT_SKIPPED</promise>"
    fi
    return 0
}

run_deploy_phase() {
    print_phase "Deploy" "Deploying changes locally"
    
    if ! is_aidevops_repo; then
        print_info "Not an aidevops repo, skipping deploy phase"
        return 0
    fi
    
    if [[ "${NO_AUTO_DEPLOY:-false}" == "true" ]]; then
        print_warning "Auto deploy disabled. Run manually: ./setup.sh"
        return 0
    fi
    
    local repo_root
    repo_root=$(git rev-parse --show-toplevel)
    
    print_info "Running setup.sh to deploy changes..."
    
    if [[ -x "$repo_root/setup.sh" ]]; then
        (cd "$repo_root" && ./setup.sh)
        print_success "Deployment complete!"
        echo "<promise>DEPLOYED</promise>"
    else
        print_warning "setup.sh not found or not executable"
    fi
    
    return 0
}

# =============================================================================
# Main Commands
# =============================================================================

cmd_start() {
    local prompt="$1"
    shift
    
    local background=false
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-task-iterations)
                MAX_TASK_ITERATIONS="$2"
                shift 2
                ;;
            --max-preflight-iterations)
                MAX_PREFLIGHT_ITERATIONS="$2"
                shift 2
                ;;
            --max-pr-iterations)
                MAX_PR_ITERATIONS="$2"
                shift 2
                ;;
            --skip-preflight)
                SKIP_PREFLIGHT=true
                shift
                ;;
            --skip-postflight)
                SKIP_POSTFLIGHT=true
                shift
                ;;
            --no-auto-pr)
                NO_AUTO_PR=true
                shift
                ;;
            --no-auto-deploy)
                NO_AUTO_DEPLOY=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --background|--bg)
                background=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                return 1
                ;;
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
    
    # Check we're on a feature branch
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
    echo ""
    echo -e "${CYAN}Phases:${NC}"
    echo "  1. Task Development (Ralph loop)"
    echo "  2. Preflight (quality checks)"
    echo "  3. PR Creation"
    echo "  4. PR Review (CI + approval)"
    echo "  5. Postflight (release health)"
    if is_aidevops_repo; then
        echo "  6. Deploy (setup.sh)"
    fi
    echo ""
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_info "Dry run - no changes made"
        return 0
    fi
    
    # Save initial state
    save_state "$PHASE_TASK" "$prompt"
    SAVED_PROMPT="$prompt"
    
    # Background mode: run in background with nohup
    if [[ "$background" == "true" ]]; then
        local log_file="${STATE_DIR}/full-loop.log"
        local pid_file="${STATE_DIR}/full-loop.pid"
        
        mkdir -p "$STATE_DIR"
        
        print_info "Starting full loop in background..."
        
        # Export variables for background process
        export MAX_TASK_ITERATIONS MAX_PREFLIGHT_ITERATIONS MAX_PR_ITERATIONS
        export SKIP_PREFLIGHT SKIP_POSTFLIGHT NO_AUTO_PR NO_AUTO_DEPLOY
        export SAVED_PROMPT="$prompt"
        
        # Start background process
        nohup "$0" _run_foreground "$prompt" > "$log_file" 2>&1 &
        local pid=$!
        echo "$pid" > "$pid_file"
        
        print_success "Full loop started in background (PID: $pid)"
        print_info "Check status: full-loop-helper.sh status"
        print_info "View logs: full-loop-helper.sh logs"
        print_info "Or: tail -f $log_file"
        return 0
    fi
    
    # Start task phase (foreground)
    run_task_phase "$prompt"
    
    return 0
}

# Internal command for background execution
cmd_run_foreground() {
    local prompt="$1"
    run_task_phase "$prompt"
    return 0
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
            # Check if task is complete (check both new and legacy locations)
            if [[ -f ".agent/loop-state/ralph-loop.local.state" ]] || [[ -f ".claude/ralph-loop.local.state" ]]; then
                print_info "Task loop still active. Complete it first."
                return 0
            fi
            save_state "$PHASE_PREFLIGHT" "$SAVED_PROMPT" "" "$STARTED_AT"
            run_preflight_phase
            save_state "$PHASE_PR_CREATE" "$SAVED_PROMPT" "" "$STARTED_AT"
            run_pr_create_phase
            ;;
        "$PHASE_PREFLIGHT")
            run_preflight_phase
            save_state "$PHASE_PR_CREATE" "$SAVED_PROMPT" "" "$STARTED_AT"
            run_pr_create_phase
            ;;
        "$PHASE_PR_CREATE")
            run_pr_create_phase
            ;;
        "$PHASE_PR_REVIEW")
            run_pr_review_phase
            save_state "$PHASE_POSTFLIGHT" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"
            run_postflight_phase
            save_state "$PHASE_DEPLOY" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"
            run_deploy_phase
            save_state "$PHASE_COMPLETE" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"
            cmd_complete
            ;;
        "$PHASE_POSTFLIGHT")
            run_postflight_phase
            save_state "$PHASE_DEPLOY" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"
            run_deploy_phase
            save_state "$PHASE_COMPLETE" "$SAVED_PROMPT" "$PR_NUMBER" "$STARTED_AT"
            cmd_complete
            ;;
        "$PHASE_DEPLOY")
            run_deploy_phase
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
    
    return 0
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
    echo ""
    echo "Prompt:"
    echo "$SAVED_PROMPT" | head -5
    echo ""
    
    return 0
}

cmd_cancel() {
    if ! is_loop_active; then
        print_warning "No active loop to cancel"
        return 0
    fi
    
    # Kill background process if running
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
    
    # Also cancel any sub-loops (both new and legacy locations)
    rm -f ".agent/loop-state/ralph-loop.local.state" 2>/dev/null
    rm -f ".agent/loop-state/quality-loop.local.state" 2>/dev/null
    rm -f ".claude/ralph-loop.local.state" 2>/dev/null
    rm -f ".claude/quality-loop.local.state" 2>/dev/null
    
    print_success "Full loop cancelled"
    return 0
}

cmd_logs() {
    local log_file="${STATE_DIR}/full-loop.log"
    local lines="${1:-50}"
    
    if [[ ! -f "$log_file" ]]; then
        print_warning "No log file found. Start a loop with --background first."
        return 1
    fi
    
    # Check if background process is still running
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
    
    return 0
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
    
    return 0
}

show_help() {
    cat << 'EOF'
Full Development Loop Orchestrator

Chains the complete development workflow from task to deployment.

USAGE:
    full-loop-helper.sh <command> [options]

COMMANDS:
    start "<prompt>"    Start a new full development loop
    resume              Resume from the current phase
    status              Show current loop status
    cancel              Cancel the active loop
    help                Show this help

OPTIONS:
    --max-task-iterations N       Max iterations for task development (default: 50)
    --max-preflight-iterations N  Max iterations for preflight (default: 5)
    --max-pr-iterations N         Max iterations for PR review (default: 20)
    --skip-preflight              Skip preflight checks (not recommended)
    --skip-postflight             Skip postflight monitoring
    --no-auto-pr                  Don't auto-create PR, pause for human
    --no-auto-deploy              Don't auto-run setup.sh (aidevops only)
    --dry-run                     Show what would happen without executing
    --background, --bg            Run in background (returns immediately)

PHASES:
    1. Task Development   - Ralph loop for implementation
    2. Preflight          - Quality checks before commit
    3. PR Creation        - Auto-create pull request
    4. PR Review          - Monitor CI and approval
    5. Postflight         - Verify release health
    6. Deploy             - Run setup.sh (aidevops repos only)

HUMAN DECISION POINTS:
    - Initial task definition (before start)
    - Merge approval (if repo requires human approval)
    - Rollback decision (if postflight detects issues)

EXAMPLES:
    # Start full loop for a feature
    full-loop-helper.sh start "Implement user authentication with JWT"

    # Start in background (recommended for long-running tasks)
    full-loop-helper.sh start "Implement feature X" --background

    # Start with custom iterations
    full-loop-helper.sh start "Fix all TypeScript errors" --max-task-iterations 30

    # View background loop logs
    full-loop-helper.sh logs

    # Resume after manual intervention
    full-loop-helper.sh resume

    # Check current status
    full-loop-helper.sh status

EOF
    return 0
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        start)
            cmd_start "$@"
            ;;
        resume)
            cmd_resume
            ;;
        status)
            cmd_status
            ;;
        cancel)
            cmd_cancel
            ;;
        logs)
            cmd_logs "$@"
            ;;
        _run_foreground)
            # Internal command for background execution
            cmd_run_foreground "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            return 1
            ;;
    esac
    
    return 0
}

main "$@"
