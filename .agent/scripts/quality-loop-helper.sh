#!/bin/bash
# =============================================================================
# Quality Loop Helper - Iterative Quality Workflows
# =============================================================================
# Applies Ralph Wiggum technique to preflight, PR review, and postflight.
# Loops until quality checks pass or max iterations reached.
#
# Usage:
#   quality-loop-helper.sh preflight [--auto-fix] [--max-iterations N]
#   quality-loop-helper.sh pr-review [--pr N] [--wait-for-ci] [--max-iterations N] [--no-auto-trigger]
#   quality-loop-helper.sh postflight [--monitor-duration Nm]
#   quality-loop-helper.sh status
#   quality-loop-helper.sh cancel
#
# PR Review Options:
#   --pr N              PR number (auto-detects from current branch if omitted)
#   --wait-for-ci       Wait for CI checks to complete before checking review status
#   --max-iterations N  Maximum check iterations (default: 10)
#   --no-auto-trigger   Disable automatic re-review trigger for stale reviews
#   --auto-trigger-review  Enable auto re-review (default, triggers @coderabbitai review
#                          if no review received within 5 minutes of last push)
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
readonly STATE_FILE="${STATE_DIR}/quality-loop.local.state"

# Legacy state directory (for backward compatibility during migration)
# shellcheck disable=SC2034  # Defined for documentation
readonly LEGACY_STATE_DIR=".claude"

# Default settings
readonly DEFAULT_MAX_ITERATIONS=10
readonly DEFAULT_MONITOR_DURATION=300  # 5 minutes in seconds
readonly DEFAULT_REVIEW_STALE_THRESHOLD=300  # 5 minutes - trigger re-review if no activity

# =============================================================================
# CI/CD Service Timing Constants (Evidence-Based from PR #19 Analysis)
# =============================================================================
# These timings are based on observed completion times:
# - Fast (CodeFactor, Version): ~1-5s → wait 10s, poll every 5s
# - Medium (SonarCloud, Codacy, Qlty): ~43-62s → wait 60s, poll every 15s
# - Slow (CodeRabbit): ~120-180s → wait 120s, poll every 30s

# Service categories for intelligent polling
readonly FAST_SERVICES="codefactor|version|framework"
readonly MEDIUM_SERVICES="sonarcloud|codacy|qlty|code-review-monitoring"
readonly SLOW_SERVICES="coderabbit|coderabbitai"

# AI code reviewers (regex pattern for jq test() - anchored to prevent false positives)
# Supported: CodeRabbit, Gemini Code Assist, Augment Code, GitHub Copilot
readonly AI_REVIEWERS="^coderabbit|^gemini-code-assist\\[bot\\]$|^augment-code\\[bot\\]$|^augmentcode\\[bot\\]$|^copilot\\[bot\\]$"

# Timing constants (seconds)
readonly WAIT_FAST=10
readonly WAIT_MEDIUM=60
readonly WAIT_SLOW=120
readonly POLL_FAST=5
readonly POLL_MEDIUM=15
readonly POLL_SLOW=30

# Exponential backoff settings
readonly BACKOFF_BASE=15
readonly BACKOFF_MAX=120
readonly BACKOFF_MULTIPLIER=2

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

# Print error message to stderr with prefix
# Arguments: $1 - Error message
# Returns: 0
print_error() {
    local message="$1"
    echo -e "${RED}[quality-loop] Error:${NC} ${message}" >&2
    return 0
}

# Print success message in green with prefix
# Arguments: $1 - Success message
# Returns: 0
print_success() {
    local message="$1"
    echo -e "${GREEN}[quality-loop]${NC} ${message}"
    return 0
}

# Print warning message in yellow with prefix
# Arguments: $1 - Warning message
# Returns: 0
print_warning() {
    local message="$1"
    echo -e "${YELLOW}[quality-loop]${NC} ${message}"
    return 0
}

# Print info message in blue with prefix
# Arguments: $1 - Info message
# Returns: 0
print_info() {
    local message="$1"
    echo -e "${BLUE}[quality-loop]${NC} ${message}"
    return 0
}

# Print step message in cyan with prefix
# Arguments: $1 - Step message
# Returns: 0
print_step() {
    local message="$1"
    echo -e "${CYAN}[quality-loop]${NC} ${message}"
    return 0
}

# =============================================================================
# Adaptive Wait Time Functions
# =============================================================================

# Calculate wait time based on pending services
# Arguments:
#   $1 - Comma-separated list of pending service names (e.g., "coderabbit,sonarcloud")
# Returns: 0
# Output: Recommended wait time in seconds
calculate_adaptive_wait() {
    local pending_services="$1"
    local max_wait=0
    
    # Check for slow services first (they dominate wait time)
    if echo "$pending_services" | grep -qiE "$SLOW_SERVICES"; then
        max_wait=$WAIT_SLOW
    elif echo "$pending_services" | grep -qiE "$MEDIUM_SERVICES"; then
        max_wait=$WAIT_MEDIUM
    elif echo "$pending_services" | grep -qiE "$FAST_SERVICES"; then
        max_wait=$WAIT_FAST
    else
        # Unknown service, use medium as default
        max_wait=$WAIT_MEDIUM
    fi
    
    echo "$max_wait"
    return 0
}

# Calculate poll interval based on pending services
# Arguments:
#   $1 - Comma-separated list of pending service names
# Returns: 0
# Output: Recommended poll interval in seconds
calculate_poll_interval() {
    local pending_services="$1"
    local poll_interval=$POLL_MEDIUM
    
    if echo "$pending_services" | grep -qiE "$SLOW_SERVICES"; then
        poll_interval=$POLL_SLOW
    elif echo "$pending_services" | grep -qiE "$MEDIUM_SERVICES"; then
        poll_interval=$POLL_MEDIUM
    elif echo "$pending_services" | grep -qiE "$FAST_SERVICES"; then
        poll_interval=$POLL_FAST
    fi
    
    echo "$poll_interval"
    return 0
}

# Calculate exponential backoff wait time
# Arguments:
#   $1 - Current iteration number (1-based)
# Returns: 0
# Output: Wait time in seconds (capped at BACKOFF_MAX)
calculate_backoff_wait() {
    local iteration="$1"
    local wait_time=$BACKOFF_BASE
    
    # Calculate: base * multiplier^(iteration-1), capped at max
    local i=1
    while [[ $i -lt $iteration ]]; do
        wait_time=$((wait_time * BACKOFF_MULTIPLIER))
        if [[ $wait_time -ge $BACKOFF_MAX ]]; then
            wait_time=$BACKOFF_MAX
            break
        fi
        ((i++))
    done
    
    echo "$wait_time"
    return 0
}

# Get list of pending CI check names from PR
# Arguments:
#   $1 - PR number
# Returns: 0
# Output: Comma-separated list of pending check names (lowercase)
get_pending_checks() {
    local pr_number="$1"
    
    local pr_info
    pr_info=$(gh pr view "$pr_number" --json statusCheckRollup 2>/dev/null || echo '{"statusCheckRollup":[]}')
    
    local pending
    pending=$(echo "$pr_info" | jq -r '[.statusCheckRollup[] | select(.status == "PENDING" or .status == "IN_PROGRESS") | .name] | join(",")' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    
    echo "$pending"
    return 0
}

# =============================================================================
# State Management
# =============================================================================

# Create state file for a new quality loop
# Arguments:
#   $1 - Loop type (preflight, pr-review, postflight)
#   $2 - Max iterations
#   $3 - Options string (key=value pairs separated by commas)
# Returns: 0
# Side effects: Creates .agent/loop-state/quality-loop.local.state
create_state() {
    local loop_type="$1"
    local max_iterations="$2"
    local options_str="$3"

    mkdir -p "$STATE_DIR"

    # Convert options string to YAML object format
    # Input: "auto_fix=true,wait_for_ci=false" -> "  auto_fix: true\n  wait_for_ci: false"
    local options_yaml=""
    if [[ -n "$options_str" ]]; then
        options_yaml=$(echo "$options_str" | tr ',' '\n' | while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            # Handle boolean and numeric values without quotes
            if [[ "$value" == "true" || "$value" == "false" || "$value" =~ ^[0-9]+$ ]]; then
                echo "  $key: $value"
            else
                echo "  $key: \"$value\""
            fi
        done)
    fi

    cat > "$STATE_FILE" << EOF
---
type: $loop_type
iteration: 1
max_iterations: $max_iterations
status: running
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
options:
$options_yaml
checks_passed: []
checks_failed: []
fixes_applied: 0
---
EOF
    return 0
}

# Update a field in the state file
# Arguments:
#   $1 - Field name
#   $2 - New value
# Returns: 0 on success, 1 if no state file
update_state() {
    local field="$1"
    local value="$2"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1
    fi
    
    local temp_file="${STATE_FILE}.tmp.$$"
    sed "s/^${field}: .*/${field}: ${value}/" "$STATE_FILE" > "$temp_file"
    mv "$temp_file" "$STATE_FILE"
    return 0
}

# Get a field value from the state file
# Arguments: $1 - Field name
# Returns: 0
# Output: Field value to stdout (empty if not found)
get_state_field() {
    local field="$1"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        echo ""
        return 0
    fi
    
    local frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
    echo "$frontmatter" | grep "^${field}:" | sed "s/${field}: *//" | sed 's/^"\(.*\)"$/\1/'
    return 0
}

# Increment iteration counter in state file
# Arguments: none
# Returns: 0
# Output: New iteration number to stdout
increment_iteration() {
    local current
    current=$(get_state_field "iteration")
    
    if [[ ! "$current" =~ ^[0-9]+$ ]]; then
        current=0
    fi
    
    local next=$((current + 1))
    update_state "iteration" "$next"
    echo "$next"
    return 0
}

# Increment fixes applied counter in state file
# Arguments: none
# Returns: 0
# Output: New fixes count to stdout
increment_fixes() {
    local current
    current=$(get_state_field "fixes_applied")
    
    if [[ ! "$current" =~ ^[0-9]+$ ]]; then
        current=0
    fi
    
    local next=$((current + 1))
    update_state "fixes_applied" "$next"
    echo "$next"
    return 0
}

# Cancel the active quality loop
# Arguments: none
# Returns: 0
# Side effects: Removes state file if exists
cancel_loop() {
    if [[ ! -f "$STATE_FILE" ]]; then
        print_warning "No active quality loop found."
        return 0
    fi
    
    local loop_type
    local iteration
    loop_type=$(get_state_field "type")
    iteration=$(get_state_field "iteration")
    
    rm -f "$STATE_FILE"
    print_success "Cancelled ${loop_type} loop (was at iteration ${iteration})"
    return 0
}

# Display current quality loop status
# Arguments: none
# Returns: 0
# Output: Status information to stdout
show_status() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "No active quality loop."
        return 0
    fi
    
    echo "Quality Loop Status"
    echo "==================="
    echo ""
    
    local loop_type iteration max_iterations status started_at fixes_applied
    loop_type=$(get_state_field "type")
    iteration=$(get_state_field "iteration")
    max_iterations=$(get_state_field "max_iterations")
    status=$(get_state_field "status")
    started_at=$(get_state_field "started_at")
    fixes_applied=$(get_state_field "fixes_applied")
    
    echo "Type: $loop_type"
    echo "Status: $status"
    echo "Iteration: $iteration / $max_iterations"
    echo "Fixes applied: $fixes_applied"
    echo "Started: $started_at"
    echo ""
    echo "State file: $STATE_FILE"
    return 0
}

# =============================================================================
# Preflight Loop
# =============================================================================

# Run all preflight checks and optionally auto-fix issues
# Arguments: $1 - "true" to enable auto-fix, "false" otherwise
# Returns: 0
# Output: "PASS" or "FAIL" to stdout
run_preflight_checks() {
    local auto_fix="$1"
    local results=""
    local all_passed=true
    
    print_step "Running preflight checks..."
    
    # Check 1: ShellCheck
    print_info "  Checking ShellCheck..."
    # Keep this aligned with linters-local.sh which checks warnings+errors.
    # Otherwise, info-level shellcheck findings can fail preflight even though
    # the repo's accepted local-linter gate passes.
    if find .agent/scripts -name "*.sh" -exec shellcheck --severity=warning {} \; >/dev/null 2>&1; then
        results="${results}shellcheck:pass\n"
        print_success "    ShellCheck: PASS"
    else
        results="${results}shellcheck:fail\n"
        print_warning "    ShellCheck: FAIL"
        all_passed=false
        
        if [[ "$auto_fix" == "true" ]]; then
            print_info "    Auto-fix not available for ShellCheck (manual fixes required)"
        fi
    fi


    
    # Check 2: Secretlint (skip if not installed)
    print_info "  Checking secrets..."
    if command -v secretlint &>/dev/null; then
        if secretlint "**/*" --no-terminalLink 2>/dev/null; then
            results="${results}secretlint:pass\n"
            print_success "    Secretlint: PASS"
        else
            results="${results}secretlint:fail\n"
            print_warning "    Secretlint: FAIL"
            all_passed=false
        fi
    else
        results="${results}secretlint:skip\n"
        print_info "    Secretlint: SKIPPED (not installed)"
    fi
    
    # Check 3: Markdown formatting
    print_info "  Checking markdown..."
    if command -v markdownlint &>/dev/null || command -v markdownlint-cli2 &>/dev/null; then
        local md_cmd="markdownlint"
        command -v markdownlint-cli2 &>/dev/null && md_cmd="markdownlint-cli2"
        
        if $md_cmd "**/*.md" --ignore node_modules 2>/dev/null; then
            results="${results}markdown:pass\n"
            print_success "    Markdown: PASS"
        else
            results="${results}markdown:fail\n"
            print_warning "    Markdown: FAIL"
            all_passed=false
            
            if [[ "$auto_fix" == "true" ]]; then
                print_info "    Attempting auto-fix..."
                $md_cmd "**/*.md" --fix --ignore node_modules 2>/dev/null || true
                increment_fixes > /dev/null
            fi
        fi
    else
        results="${results}markdown:skip\n"
        print_info "    Markdown: SKIPPED (markdownlint not installed)"
    fi
    
    # Check 4: Version consistency
    print_info "  Checking version consistency..."
    if [[ -x "${SCRIPT_DIR}/version-manager.sh" ]]; then
        if "${SCRIPT_DIR}/version-manager.sh" validate &>/dev/null; then
            results="${results}version:pass\n"
            print_success "    Version: PASS"
        else
            results="${results}version:fail\n"
            print_warning "    Version: FAIL"
            all_passed=false
        fi
    else
        results="${results}version:skip\n"
        print_info "    Version: SKIPPED (version-manager.sh not found)"
    fi
    
    # Return results (stdout only)
    if [[ "$all_passed" == "true" ]]; then
        echo "PASS"
    else
        echo "FAIL"
    fi
    return 0
}

# Run preflight checks in a loop until all pass or max iterations
# Arguments: --auto-fix (optional), --max-iterations N (optional)
# Returns: 0 on success, 1 if max iterations reached
# Output: <promise>PREFLIGHT_PASS</promise> on success
preflight_loop() {
    local auto_fix=false
    local max_iterations=$DEFAULT_MAX_ITERATIONS
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto-fix)
                auto_fix=true
                shift
                ;;
            --max-iterations)
                max_iterations="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    print_info "Starting preflight loop (max iterations: $max_iterations, auto-fix: $auto_fix)"
    
    create_state "preflight" "$max_iterations" "auto_fix=$auto_fix"
    
    local iteration=1
    while [[ $iteration -le $max_iterations ]]; do
        echo ""
        print_info "=== Preflight Iteration $iteration / $max_iterations ==="
        
        local result_status
        result_status=$(run_preflight_checks "$auto_fix" 2>/dev/null | tail -n 1 | tr -d '\r')
        
        if [[ "$result_status" == "PASS" ]]; then
            echo ""
            print_success "All preflight checks passed!"
            update_state "status" "completed"
            rm -f "$STATE_FILE"
            
            # Output completion promise for Ralph integration
            echo ""
            echo "<promise>PREFLIGHT_PASS</promise>"
            return 0
        fi
        
        if [[ $iteration -ge $max_iterations ]]; then
            echo ""
            print_warning "Max iterations ($max_iterations) reached. Some checks still failing."
            update_state "status" "max_iterations_reached"
            return 1
        fi
        
        iteration=$(increment_iteration)
        
        if [[ "$auto_fix" == "true" ]]; then
            print_info "Fixes applied, re-running checks..."
            sleep 1
        else
            print_warning "Checks failed. Enable --auto-fix or fix manually."
            return 1
        fi
    done
    
    return 1
}

# =============================================================================
# PR Review Loop
# =============================================================================

# Check PR status including CI, reviews, and mergeability
# Arguments:
#   $1 - PR number
#   $2 - "true" to wait for CI, "false" otherwise
# Returns: 0 on success, 1 on error
# Output: Status string (MERGED, READY, PENDING, CI_FAILED, CHANGES_REQUESTED, WAITING)
check_pr_status() {
    local pr_number="$1"
    local wait_for_ci="$2"
    
    print_step "Checking PR #${pr_number} status..."
    
    # Get PR info
    local pr_info
    if ! pr_info=$(gh pr view "$pr_number" --json state,mergeable,reviewDecision,statusCheckRollup 2>/dev/null); then
        print_error "Failed to get PR info"
        return 1
    fi
    
    local state mergeable review_decision
    state=$(echo "$pr_info" | jq -r '.state')
    mergeable=$(echo "$pr_info" | jq -r '.mergeable')
    review_decision=$(echo "$pr_info" | jq -r '.reviewDecision // "NONE"')
    
    print_info "  State: $state"
    print_info "  Mergeable: $mergeable"
    print_info "  Review: $review_decision"
    
    # Check CI status
    local checks_pending=false
    local checks_failed=false
    
    local check_count
    check_count=$(echo "$pr_info" | jq '.statusCheckRollup | length')
    
    if [[ "$check_count" -gt 0 ]]; then
        local pending_count failed_count action_required_count
        pending_count=$(printf '%s' "$pr_info" | jq '[.statusCheckRollup[] | select(.status == "PENDING" or .status == "IN_PROGRESS")] | length')
        failed_count=$(printf '%s' "$pr_info" | jq '[.statusCheckRollup[] | select(.conclusion == "FAILURE")] | length')
        action_required_count=$(printf '%s' "$pr_info" | jq '[.statusCheckRollup[] | select(.conclusion == "ACTION_REQUIRED")] | length')
        
        print_info "  CI Checks: $check_count total, $pending_count pending, $failed_count failed, $action_required_count action required"
        
        [[ "$pending_count" -gt 0 ]] && checks_pending=true
        [[ "$failed_count" -gt 0 || "$action_required_count" -gt 0 ]] && checks_failed=true
    fi
    
    # Determine overall status
    if [[ "$state" == "MERGED" ]]; then
        echo "MERGED"
    elif [[ "$review_decision" == "APPROVED" ]] && [[ "$checks_failed" == "false" ]] && [[ "$checks_pending" == "false" ]]; then
        echo "READY"
    elif [[ "$checks_pending" == "true" ]] && [[ "$wait_for_ci" == "true" ]]; then
        echo "PENDING"
    elif [[ "$checks_failed" == "true" ]]; then
        echo "CI_FAILED"
    elif [[ "$review_decision" == "CHANGES_REQUESTED" ]]; then
        echo "CHANGES_REQUESTED"
    else
        echo "WAITING"
    fi
    return 0
}

# Get feedback from PR reviews and CI annotations
# Arguments: $1 - PR number
# Returns: 0
# Output: Feedback text to stdout
get_pr_feedback() {
    local pr_number="$1"
    
    print_step "Getting PR feedback..."
    
    # Get AI reviewer comments (CodeRabbit, Gemini Code Assist, Augment Code, Copilot)
    local ai_review_comments api_response
    api_response=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" 2>/dev/null)
    
    if [[ -z "$api_response" ]]; then
        print_warning "Failed to fetch PR comments from GitHub API"
    else
        ai_review_comments=$(printf '%s' "$api_response" | jq -r --arg bots "$AI_REVIEWERS" \
            '.[] | select(.user.login | test($bots; "i")) | "\(.user.login): \(.body)"' \
            2>/dev/null | head -20)
        
        if [[ -n "$ai_review_comments" ]]; then
            print_info "AI reviewer feedback found"
            echo "$ai_review_comments"
        fi
    fi
    
    # Get check run annotations
    local head_sha
    head_sha=$(gh pr view "$pr_number" --json headRefOid -q .headRefOid 2>/dev/null || echo "")
    
    if [[ -n "$head_sha" ]]; then
        local annotations
        annotations=$(gh api "repos/{owner}/{repo}/commits/${head_sha}/check-runs" --jq '.check_runs[].output.annotations[]? | "\(.path):\(.start_line) - \(.message)"' 2>/dev/null | head -20 || echo "")
        
        if [[ -n "$annotations" ]]; then
            print_info "CI annotations found:"
            echo "$annotations"
        fi
    fi
    
    return 0
}

# Check if review is stale and trigger re-review if needed
# Arguments:
#   $1 - PR number
#   $2 - Stale threshold in seconds (default: 300)
# Returns: 0 if re-review triggered, 1 if not needed
# Side effects: Posts @coderabbitai review comment if stale
check_and_trigger_review() {
    local pr_number="$1"
    local stale_threshold="${2:-$DEFAULT_REVIEW_STALE_THRESHOLD}"
    
    # Get last push time
    local last_push_time
    last_push_time=$(gh pr view "$pr_number" --json commits --jq '.commits[-1].committedDate' 2>/dev/null || echo "")
    
    if [[ -z "$last_push_time" ]]; then
        print_warning "Could not determine last push time"
        return 1
    fi
    
    # Get last AI reviewer review time (any supported reviewer)
    local last_review_time api_response
    api_response=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews" 2>/dev/null)
    
    if [[ -n "$api_response" ]]; then
        last_review_time=$(printf '%s' "$api_response" | jq -r --arg bots "$AI_REVIEWERS" \
            '[.[] | select(.user.login | test($bots; "i"))] | sort_by(.submitted_at) | last | .submitted_at // ""' 2>/dev/null)
    else
        last_review_time=""
    fi
    
    # Convert times to epoch for comparison
    local now_epoch last_push_epoch last_review_epoch
    now_epoch=$(date +%s)
    
    # Parse ISO 8601 dates (works on macOS and Linux)
    if [[ -n "$last_push_time" ]]; then
        last_push_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_push_time" +%s 2>/dev/null || \
                         date -d "$last_push_time" +%s 2>/dev/null || echo "0")
    else
        last_push_epoch=0
    fi
    
    if [[ -n "$last_review_time" ]]; then
        last_review_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_review_time" +%s 2>/dev/null || \
                          date -d "$last_review_time" +%s 2>/dev/null || echo "0")
    else
        last_review_epoch=0
    fi
    
    # Check if review is stale (push happened after last review, and threshold exceeded)
    local time_since_push=$((now_epoch - last_push_epoch))
    
    if [[ $last_push_epoch -gt $last_review_epoch ]] && [[ $time_since_push -ge $stale_threshold ]]; then
        print_info "Review appears stale (${time_since_push}s since push, no review since)"
        print_info "Triggering CodeRabbit re-review..."
        
        if gh pr comment "$pr_number" --body "@coderabbitai review" 2>/dev/null; then
            print_success "Re-review triggered for PR #${pr_number}"
            return 0
        else
            print_warning "Failed to trigger re-review"
            return 1
        fi
    fi
    
    return 1
}

# Check for unresolved review threads on a PR using GraphQL
# Arguments: $1 - PR number
# Returns: 0 if no unresolved threads, 1 if unresolved threads exist, 2 on API error
# Output: Warning message if unresolved threads found
check_unresolved_review_comments() {
    local pr_number="$1"
    
    local repo_owner repo_name api_response unresolved_count
    repo_owner=$(gh repo view --json owner -q '.owner.login' 2>/dev/null || echo "")
    repo_name=$(gh repo view --json name -q '.name' 2>/dev/null || echo "")
    
    if [[ -z "$repo_owner" || -z "$repo_name" ]]; then
        print_error "Failed to resolve repo owner/name - cannot verify review status"
        return 2
    fi
    
    # shellcheck disable=SC2016 # GraphQL variables, not shell - single quotes intentional
    api_response=$(gh api graphql -f query='
      query($owner:String!, $repo:String!, $number:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$number) {
            reviewThreads(first:100) { nodes { isResolved } }
          }
        }
      }' -f owner="$repo_owner" -f repo="$repo_name" -F number="$pr_number" 2>/dev/null)
    
    if [[ -z "$api_response" ]]; then
        print_error "Failed to fetch PR review threads from GitHub API - cannot verify review status"
        return 2
    fi
    
    unresolved_count=$(printf '%s' "$api_response" | jq -r \
        '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length' 2>/dev/null)
    
    if ! [[ "$unresolved_count" =~ ^[0-9]+$ ]]; then
        print_error "Failed to parse unresolved thread count - cannot proceed safely"
        return 2
    fi
    
    if [[ "$unresolved_count" -gt 0 ]]; then
        print_warning "Found $unresolved_count unresolved review threads"
        return 1
    fi
    return 0
}

# Monitor PR until approved or merged
# Arguments: --pr NUMBER, --wait-for-ci, --max-iterations N, --auto-trigger-review
# Returns: 0 on approval/merge, 1 if max iterations reached
# Output: <promise>PR_APPROVED</promise> or <promise>PR_MERGED</promise>
pr_review_loop() {
    local wait_for_ci=false
    local auto_trigger_review=true
    local max_iterations=$DEFAULT_MAX_ITERATIONS
    local pr_number=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --wait-for-ci)
                wait_for_ci=true
                shift
                ;;
            --max-iterations)
                max_iterations="$2"
                shift 2
                ;;
            --pr)
                pr_number="$2"
                shift 2
                ;;
            --no-auto-trigger)
                auto_trigger_review=false
                shift
                ;;
            --auto-trigger-review)
                auto_trigger_review=true
                shift
                ;;
            *)
                # Assume it's the PR number
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    pr_number="$1"
                fi
                shift
                ;;
        esac
    done
    
    # Auto-detect PR number if not provided
    if [[ -z "$pr_number" ]]; then
        pr_number=$(gh pr view --json number -q .number 2>/dev/null || echo "")
        
        if [[ -z "$pr_number" ]]; then
            print_error "No PR number provided and no PR found for current branch"
            echo "Usage: quality-loop-helper.sh pr-review [--pr NUMBER] [--wait-for-ci] [--max-iterations N] [--no-auto-trigger]"
            return 1
        fi
    fi
    
    print_info "Starting PR review loop for PR #${pr_number} (max iterations: $max_iterations, auto-trigger: $auto_trigger_review)"
    
    create_state "pr-review" "$max_iterations" "pr=$pr_number,wait_for_ci=$wait_for_ci,auto_trigger=$auto_trigger_review"
    
    local iteration=1
    while [[ $iteration -le $max_iterations ]]; do
        echo ""
        print_info "=== PR Review Iteration $iteration / $max_iterations ==="
        
        local status
        status=$(check_pr_status "$pr_number" "$wait_for_ci" | tail -n 1 | tr -d '\r')
        
        case "$status" in
            MERGED)
                print_success "PR has been merged!"
                rm -f "$STATE_FILE"
                echo "<promise>PR_MERGED</promise>"
                return 0
                ;;
            READY)
                # Check for unresolved AI review comments before declaring ready
                local unresolved_check_result
                check_unresolved_review_comments "$pr_number"
                unresolved_check_result=$?
                
                if [[ $unresolved_check_result -eq 2 ]]; then
                    print_warning "Could not verify AI review status (API error) - proceeding with caution"
                elif [[ $unresolved_check_result -eq 1 ]]; then
                    print_warning "PR approved but has unresolved AI review comments"
                    get_pr_feedback "$pr_number"
                    print_info "Address the AI reviewer feedback and push updates."
                else
                    print_success "PR is approved and ready to merge!"
                    rm -f "$STATE_FILE"
                    echo "<promise>PR_APPROVED</promise>"
                    return 0
                fi
                ;;
            PENDING)
                # Get pending checks and calculate adaptive wait
                local pending_checks
                pending_checks=$(get_pending_checks "$pr_number")
                local wait_time
                wait_time=$(calculate_adaptive_wait "$pending_checks")
                
                if [[ -n "$pending_checks" ]]; then
                    print_info "CI checks still running: $pending_checks"
                    print_info "Waiting ${wait_time}s (adaptive based on slowest pending check)..."
                else
                    print_info "CI checks still running, waiting ${wait_time}s..."
                fi
                sleep "$wait_time"
                ;;
            CI_FAILED)
                print_warning "CI checks failed. Getting feedback..."
                get_pr_feedback "$pr_number"
                print_info "Fix the issues and push updates."
                ;;
            CHANGES_REQUESTED)
                print_warning "Changes requested. Getting feedback..."
                get_pr_feedback "$pr_number"
                print_warning "IMPORTANT: Verify bot suggestions before implementing — AI reviewers can hallucinate (wrong versions, non-existent issues, incorrect paths). Check claims against runtime/docs first."
                print_info "Address verified feedback and push updates."
                ;;
            WAITING)
                print_info "Waiting for review..."
                # Check if review is stale and trigger re-review if enabled
                if [[ "$auto_trigger_review" == "true" ]] && check_and_trigger_review "$pr_number"; then
                    print_info "Re-review triggered, waiting for response..."
                fi
                ;;
            *)
                print_warning "Unknown PR status: $status"
                ;;
        esac
        
        iteration=$(increment_iteration)
        
        if [[ $iteration -le $max_iterations ]]; then
            # Use exponential backoff for general waiting
            local backoff_wait
            backoff_wait=$(calculate_backoff_wait "$iteration")
            
            # But also consider pending checks for smarter waiting
            local pending_checks
            pending_checks=$(get_pending_checks "$pr_number")
            local adaptive_wait
            adaptive_wait=$(calculate_adaptive_wait "$pending_checks")
            
            # Use the larger of backoff or adaptive wait
            local final_wait=$backoff_wait
            if [[ $adaptive_wait -gt $backoff_wait ]]; then
                final_wait=$adaptive_wait
            fi
            
            print_info "Waiting ${final_wait}s before next check (iteration $iteration, backoff: ${backoff_wait}s, adaptive: ${adaptive_wait}s)..."
            sleep "$final_wait"
        fi
    done
    
    print_warning "Max iterations reached. PR not yet approved."
    update_state "status" "max_iterations_reached"
    return 1
}

# =============================================================================
# Postflight Loop
# =============================================================================

# Check release health (CI status, release exists, version consistency)
# Arguments: none
# Returns: 0
# Output: "HEALTHY" or "UNHEALTHY" to stdout
check_release_health() {
    print_step "Checking release health..."
    
    local all_healthy=true
    
    # Check 1: Latest workflow run status
    print_info "  Checking CI status..."
    local latest_run
    latest_run=$(gh run list --limit 1 --json conclusion,status -q '.[0]' 2>/dev/null || echo '{}')
    
    local run_status run_conclusion
    run_status=$(echo "$latest_run" | jq -r '.status // "unknown"')
    run_conclusion=$(echo "$latest_run" | jq -r '.conclusion // "unknown"')
    
    if [[ "$run_status" == "completed" ]] && [[ "$run_conclusion" == "success" ]]; then
        print_success "    CI: PASS (latest run succeeded)"
    elif [[ "$run_status" == "in_progress" ]]; then
        print_info "    CI: PENDING (run in progress)"
        all_healthy=false
    else
        print_warning "    CI: FAIL (conclusion: $run_conclusion)"
        all_healthy=false
    fi
    
    # Check 2: Latest release exists
    print_info "  Checking latest release..."
    local latest_release
    latest_release=$(gh release view --json tagName,publishedAt -q '.tagName' 2>/dev/null || echo "")
    
    if [[ -n "$latest_release" ]]; then
        print_success "    Release: $latest_release exists"
    else
        print_warning "    Release: No releases found"
    fi
    
    # Check 3: Tag matches VERSION
    print_info "  Checking version consistency..."
    local current_version
    current_version=$(cat VERSION 2>/dev/null || echo "unknown")
    
    if [[ "$latest_release" == "v${current_version}" ]] || [[ "$latest_release" == "$current_version" ]]; then
        print_success "    Version: Matches ($current_version)"
    else
        print_warning "    Version: Mismatch (VERSION=$current_version, release=$latest_release)"
        all_healthy=false
    fi
    
    if [[ "$all_healthy" == "true" ]]; then
        echo "HEALTHY"
    else
        echo "UNHEALTHY"
    fi
    return 0
}

# Monitor release health for a specified duration
# Arguments: --monitor-duration Nm/Nh/Ns, --max-iterations N
# Returns: 0 on healthy, 0 on timeout (with warning)
# Output: <promise>RELEASE_HEALTHY</promise> on success
postflight_loop() {
    local monitor_duration=$DEFAULT_MONITOR_DURATION
    local max_iterations=5
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --monitor-duration)
                # Parse duration (e.g., 5m, 10m, 1h, or raw seconds)
                local duration_str="$2"
                if [[ "$duration_str" =~ ^([0-9]+)m$ ]]; then
                    monitor_duration=$((BASH_REMATCH[1] * 60))
                elif [[ "$duration_str" =~ ^([0-9]+)h$ ]]; then
                    monitor_duration=$((BASH_REMATCH[1] * 3600))
                elif [[ "$duration_str" =~ ^([0-9]+)s$ ]]; then
                    monitor_duration="${BASH_REMATCH[1]}"
                elif [[ "$duration_str" =~ ^([0-9]+)$ ]]; then
                    monitor_duration="$duration_str"
                else
                    print_warning "Unrecognized duration format: '$duration_str'. Expected: Nm (minutes), Nh (hours), Ns (seconds), or N (seconds). Using default: ${DEFAULT_MONITOR_DURATION}s"
                fi
                shift 2
                ;;
            --max-iterations)
                max_iterations="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    print_info "Starting postflight monitoring (duration: ${monitor_duration}s, max iterations: $max_iterations)"
    
    create_state "postflight" "$max_iterations" "monitor_duration=$monitor_duration"
    
    local start_time
    start_time=$(date +%s)
    local iteration=1
    
    while [[ $iteration -le $max_iterations ]]; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $elapsed -ge $monitor_duration ]]; then
            print_info "Monitor duration reached."
            break
        fi
        
        echo ""
        print_info "=== Postflight Check $iteration / $max_iterations (${elapsed}s / ${monitor_duration}s) ==="
        
        local status
        status=$(check_release_health)
        
        if [[ "$status" == "HEALTHY" ]]; then
            print_success "Release is healthy!"
            rm -f "$STATE_FILE"
            echo "<promise>RELEASE_HEALTHY</promise>"
            return 0
        fi
        
        iteration=$(increment_iteration)
        
        if [[ $iteration -le $max_iterations ]]; then
            local wait_time=$((monitor_duration / max_iterations))
            print_info "Waiting ${wait_time}s before next check..."
            sleep "$wait_time"
        fi
    done
    
    print_warning "Postflight monitoring complete. Some issues may remain."
    update_state "status" "monitoring_complete"
    rm -f "$STATE_FILE"
    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat << 'EOF'
Quality Loop Helper - Iterative Quality Workflows

USAGE:
  quality-loop-helper.sh <command> [options]

COMMANDS:
  preflight     Run preflight checks in a loop until all pass
  pr-review     Monitor PR until approved or merged
  postflight    Monitor release health after deployment
  status        Show current loop status
  cancel        Cancel active loop
  help          Show this help

PREFLIGHT OPTIONS:
  --auto-fix              Attempt to auto-fix issues
  --max-iterations <n>    Max iterations (default: 10)

PR-REVIEW OPTIONS:
  --pr <number>           PR number (auto-detected if not provided)
  --wait-for-ci           Wait for CI checks to complete
  --max-iterations <n>    Max iterations (default: 10)

POSTFLIGHT OPTIONS:
  --monitor-duration <t>  How long to monitor (e.g., 5m, 10m, 1h)
  --max-iterations <n>    Max checks during monitoring (default: 5)

EXAMPLES:
  # Run preflight with auto-fix
  quality-loop-helper.sh preflight --auto-fix --max-iterations 5

  # Monitor PR until approved
  quality-loop-helper.sh pr-review --pr 123 --wait-for-ci

  # Monitor release for 10 minutes
  quality-loop-helper.sh postflight --monitor-duration 10m

COMPLETION PROMISES:
  preflight:  <promise>PREFLIGHT_PASS</promise>
  pr-review:  <promise>PR_APPROVED</promise> or <promise>PR_MERGED</promise>
  postflight: <promise>RELEASE_HEALTHY</promise>

These can be used with Ralph loops for fully autonomous workflows.

ADAPTIVE TIMING (PR Review):
  The pr-review command uses intelligent timing based on pending CI checks:
  
  Service Category    Typical Time    Initial Wait    Poll Interval
  ─────────────────────────────────────────────────────────────────
  Fast (CodeFactor)   1-5s            10s             5s
  Medium (SonarCloud) 43-62s          60s             15s
  Slow (CodeRabbit)   120-180s        120s            30s
  
  Additionally, exponential backoff is applied:
  - Base wait: 15s, doubles each iteration, max 120s
  - Final wait = max(backoff_wait, adaptive_wait)
  
  This prevents:
  - Waiting too long for fast checks
  - Polling too frequently for slow checks (wastes API calls)
EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        preflight)
            preflight_loop "$@"
            ;;
        pr-review|pr)
            pr_review_loop "$@"
            ;;
        postflight)
            postflight_loop "$@"
            ;;
        status)
            show_status
            ;;
        cancel)
            cancel_loop
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
