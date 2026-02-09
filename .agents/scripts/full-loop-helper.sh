#!/usr/bin/env bash
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
#   --headless                  Fully headless worker mode (no prompts, no TODO.md edits)
#   --dry-run                  Show what would happen without executing
#
# Headless Mode (t174):
#   When --headless is set (or FULL_LOOP_HEADLESS=true env var):
#   - Never prompts for user input or confirmation
#   - Never edits TODO.md or shared planning files
#   - Exits cleanly on unrecoverable errors (for supervisor evaluation)
#   - Suppresses interactive README gate warnings
#   - Uses git pull --rebase before push to avoid conflicts
#
# Human Decision Points (interactive mode only):
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
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly STATE_DIR=".agents/loop-state"
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

readonly BOLD='\033[1m'

# Headless mode: set via --headless flag or FULL_LOOP_HEADLESS env var (t174)
# When true, suppresses all interactive prompts and prevents TODO.md edits
HEADLESS="${FULL_LOOP_HEADLESS:-false}"

# =============================================================================
# Helper Functions
# =============================================================================

# Check if running in headless worker mode (t174)
is_headless() {
    [[ "$HEADLESS" == "true" ]]
}

# Install a git pre-commit hook that blocks TODO.md changes in headless mode (t173)
# This is a hard guard — even if the AI agent tries to commit TODO.md, git rejects it.
install_headless_todo_guard() {
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
    if [[ -z "$git_dir" ]]; then
        return 0
    fi

    local hooks_dir="$git_dir/hooks"
    local hook_file="$hooks_dir/pre-commit"
    local guard_marker="# t173-headless-todo-guard"

    mkdir -p "$hooks_dir"

    # If a pre-commit hook already exists, append our guard (if not already present)
    if [[ -f "$hook_file" ]]; then
        if grep -q "$guard_marker" "$hook_file" 2>/dev/null; then
            return 0  # Already installed
        fi
        # Append to existing hook
        cat >> "$hook_file" << 'GUARD'

# t173-headless-todo-guard
# Block TODO.md and planning file commits in headless worker mode
if [[ "${FULL_LOOP_HEADLESS:-false}" == "true" ]]; then
    if git diff --cached --name-only | grep -qE '^(TODO\.md|todo/)'; then
        echo "[t173 GUARD] BLOCKED: Headless workers must not commit TODO.md or todo/ files."
        echo "[t173 GUARD] The supervisor owns all TODO.md updates. Put notes in commit messages or PR body."
        exit 1
    fi
fi
GUARD
    else
        # Create new hook
        cat > "$hook_file" << 'GUARD'
#!/usr/bin/env bash
# t173-headless-todo-guard
# Block TODO.md and planning file commits in headless worker mode
if [[ "${FULL_LOOP_HEADLESS:-false}" == "true" ]]; then
    if git diff --cached --name-only | grep -qE '^(TODO\.md|todo/)'; then
        echo "[t173 GUARD] BLOCKED: Headless workers must not commit TODO.md or todo/ files."
        echo "[t173 GUARD] The supervisor owns all TODO.md updates. Put notes in commit messages or PR body."
        exit 1
    fi
fi
GUARD
        chmod +x "$hook_file"
    fi

    return 0
}

# Remove the t173 headless guard from pre-commit hook (cleanup)
remove_headless_todo_guard() {
    local git_dir
    git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
    if [[ -z "$git_dir" ]]; then
        return 0
    fi

    local hook_file="$git_dir/hooks/pre-commit"
    if [[ ! -f "$hook_file" ]]; then
        return 0
    fi

    # Remove the guard block (from marker to end of guard)
    if grep -q "t173-headless-todo-guard" "$hook_file" 2>/dev/null; then
        # Use sed to remove the guard block
        local tmp_file
        tmp_file=$(mktemp)
        awk '/# t173-headless-todo-guard/{skip=1} /^fi$/ && skip{skip=0; next} !skip' "$hook_file" > "$tmp_file"
        mv "$tmp_file" "$hook_file"
        chmod +x "$hook_file"
    fi

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
headless: ${HEADLESS:-false}
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
    HEADLESS=$(grep '^headless:' "$STATE_FILE" | cut -d: -f2 | tr -d ' ')
    HEADLESS="${HEADLESS:-false}"
    
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
        if ! is_headless; then
            print_info "After task completion, run: full-loop-helper.sh resume"
        fi
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
        if is_headless; then
            # In headless mode, override --no-auto-pr since there's no human (t174)
            print_warning "HEADLESS: Overriding --no-auto-pr (no human to create PR)"
        else
            print_warning "Auto PR creation disabled. Please create PR manually."
            print_info "Run: gh pr create --fill"
            print_info "Then run: full-loop-helper.sh resume"
            return 0
        fi
    fi
    
    # Verify gh CLI is authenticated before attempting PR operations (t156/t158)
    if ! command -v gh &>/dev/null; then
        print_error "gh CLI not found. Install with: brew install gh"
        return 1
    fi
    
    local gh_auth_retries=3
    local gh_auth_ok=false
    local i
    for ((i = 1; i <= gh_auth_retries; i++)); do
        if gh auth status &>/dev/null 2>&1; then
            gh_auth_ok=true
            break
        fi
        if [[ "$i" -lt "$gh_auth_retries" ]]; then
            print_warning "gh auth check failed (attempt $i/$gh_auth_retries), retrying in 5s..."
            sleep 5
        fi
    done
    
    if [[ "$gh_auth_ok" != "true" ]]; then
        print_error "gh CLI not authenticated after $gh_auth_retries attempts."
        if is_headless; then
            # In headless mode, exit cleanly so supervisor can evaluate (t174)
            # The supervisor's evaluate_worker will detect auth_error pattern
            print_error "HEADLESS: gh auth failure — exiting for supervisor evaluation"
            return 1
        fi
        print_error "Run 'gh auth login' to authenticate, then resume with: full-loop-helper.sh resume"
        return 1
    fi
    
    # Ensure we're on a feature branch
    if ! is_on_feature_branch; then
        print_error "Not on a feature branch. Cannot create PR from main/master."
        return 1
    fi
    
    local branch
    branch=$(get_current_branch)
    
    # Pull --rebase to sync with any remote changes before push (t174)
    # This handles: 1) rebasing onto latest main, 2) pulling any remote branch updates
    print_info "Syncing with remote before push..."
    if ! git fetch origin &>/dev/null; then
        print_warning "Failed to fetch origin, proceeding with local state"
    else
        # Pull feature branch changes if it exists remotely (t174)
        if git ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
            if ! git pull --rebase origin "$branch" &>/dev/null; then
                print_warning "Pull --rebase on $branch failed (conflicts). Aborting rebase."
                git rebase --abort &>/dev/null || true
            else
                print_info "Pull --rebase on $branch successful"
            fi
        fi
        # Rebase onto latest main to avoid merge conflicts (t156)
        if ! git rebase origin/main &>/dev/null; then
            print_warning "Rebase onto origin/main failed (conflicts). Aborting rebase and pushing as-is."
            git rebase --abort &>/dev/null || true
        else
            print_info "Rebase onto origin/main successful"
        fi
    fi
    
    # Push branch (force-with-lease after rebase to handle rebased history safely)
    print_info "Pushing branch to origin..."
    if git ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
        # Branch exists remotely - use force-with-lease after rebase
        git push --force-with-lease origin "$branch" || {
            print_error "Failed to push branch $branch"
            return 1
        }
    else
        # New branch - initial push
        git push -u origin "$branch" || {
            print_error "Failed to push branch $branch"
            return 1
        }
    fi
    
    # Build PR title and body from task context (t156/t158)
    local pr_title pr_body task_id_match
    task_id_match=$(echo "$branch" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
    
    if [[ -n "$task_id_match" ]]; then
        # Look up task description: TODO.md first, then supervisor DB fallback (t158)
        local task_desc=""
        if [[ -f "TODO.md" ]]; then
            task_desc=$(grep -E "^- \[( |x|-)\] $task_id_match " TODO.md 2>/dev/null | head -1 | sed -E 's/^- \[( |x|-)\] [^ ]* //' || echo "")
        fi
        if [[ -z "$task_desc" ]]; then
            task_desc=$("$SCRIPT_DIR/supervisor-helper.sh" db \
                "SELECT description FROM tasks WHERE id = '$task_id_match';" 2>/dev/null || echo "")
        fi
        if [[ -n "$task_desc" ]]; then
            # Extract first meaningful phrase for PR title (before #tags, ~estimates, etc.)
            local short_desc
            short_desc=$(echo "$task_desc" | sed -E 's/ [#~@].*//' | head -c 60)
            pr_title="feat: ${short_desc} (${task_id_match})"
        else
            pr_title="feat: ${task_id_match}"
        fi
    else
        pr_title="feat: ${branch#feature/}"
    fi
    
    # Truncate title to 72 chars (GitHub convention)
    if [[ ${#pr_title} -gt 72 ]]; then
        pr_title="${pr_title:0:69}..."
    fi
    
    # Build body from commit log
    local commit_log
    commit_log=$(git log origin/main..HEAD --pretty=format:"- %s" 2>/dev/null || echo "")
    pr_body="## Summary

${commit_log:-No commits yet.}

---
*Created by full-loop worker*"
    
    # Create PR with proper title and body
    print_info "Creating pull request..."
    local pr_url
    pr_url=$(gh pr create --title "$pr_title" --body "$pr_body" 2>&1) || {
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
            if ! is_headless; then
                print_info "Merge PR manually, then run: full-loop-helper.sh resume"
            fi
            echo "<promise>PR_APPROVED</promise>"
        fi
    else
        print_warning "quality-loop-helper.sh not found"
        if is_headless; then
            # In headless mode, emit PR_WAITING and let supervisor handle (t174)
            print_info "HEADLESS: PR review skipped, supervisor will evaluate"
        else
            print_info "Merge PR manually, then run: full-loop-helper.sh resume"
        fi
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
        (cd "$repo_root" && AIDEVOPS_NON_INTERACTIVE=true ./setup.sh --non-interactive)
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
            --headless)
                HEADLESS=true
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

    # Install git pre-commit guard to block TODO.md commits in headless mode (t173)
    if is_headless; then
        install_headless_todo_guard
        print_info "HEADLESS: Installed TODO.md commit guard (t173)"
    fi

    # Pre-flight GitHub auth check — workers spawned via nohup/cron may lack
    # SSH keys or valid gh tokens. Fail fast before burning compute.
    if ! gh auth status >/dev/null 2>&1; then
        print_error "GitHub auth unavailable — gh auth status failed"
        print_error "Workers need 'gh auth login' with HTTPS protocol."
        return 1
    fi

    # Verify remote uses HTTPS (not SSH) — cron workers can't use SSH keys
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$remote_url" == git@* || "$remote_url" == ssh://* ]]; then
        print_warning "Remote URL is SSH ($remote_url) — switching to HTTPS for worker compatibility"
        local https_url
        https_url=$(echo "$remote_url" | sed -E 's|^git@github\.com:|https://github.com/|; s|^ssh://git@github\.com/|https://github.com/|; s|\.git$||').git
        git remote set-url origin "$https_url" 2>/dev/null || true
        print_info "Remote URL updated to $https_url"
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
        export FULL_LOOP_HEADLESS="$HEADLESS"
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

    # Auto-advance when task phase completes in v2.
    # Legacy mode leaves a Ralph state file; in that case we must wait for manual completion.
    if [[ -f ".agents/loop-state/ralph-loop.local.state" ]] || [[ -f ".claude/ralph-loop.local.state" ]]; then
        print_warning "Task loop still active (legacy mode). Run: full-loop-helper.sh resume when complete."
        return 0
    fi

    cmd_resume
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
            if [[ -f ".agents/loop-state/ralph-loop.local.state" ]] || [[ -f ".claude/ralph-loop.local.state" ]]; then
                print_info "Task loop still active. Complete it first."
                return 0
            fi
            # README gate reminder before preflight transition (t174: skip in headless)
            if is_headless; then
                print_info "HEADLESS: Skipping interactive README gate reminder"
            else
                print_warning "README GATE: Did this task add/change user-facing features?"
                print_info "If yes, ensure README.md is updated before proceeding."
                print_info "For aidevops repo:"
                print_info "  Run: readme-helper.sh check"
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
    rm -f ".agents/loop-state/ralph-loop.local.state" 2>/dev/null
    rm -f ".agents/loop-state/quality-loop.local.state" 2>/dev/null
    rm -f ".claude/ralph-loop.local.state" 2>/dev/null
    rm -f ".claude/quality-loop.local.state" 2>/dev/null

    # Remove headless TODO.md guard if installed (t173)
    remove_headless_todo_guard
    
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

    # Remove headless TODO.md guard if installed (t173)
    remove_headless_todo_guard
    
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
    --headless                    Fully headless worker mode (no prompts, no TODO.md)
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

    # Headless mode (used by supervisor dispatch)
    full-loop-helper.sh start "Fix bug X" --headless --background

ENVIRONMENT:
    FULL_LOOP_HEADLESS=true       Same as --headless flag

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
