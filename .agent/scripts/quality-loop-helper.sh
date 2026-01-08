#!/bin/bash
# =============================================================================
# Quality Loop Helper - Iterative Quality Workflows
# =============================================================================
# Applies Ralph Wiggum technique to preflight, PR review, and postflight.
# Loops until quality checks pass or max iterations reached.
#
# Usage:
#   quality-loop-helper.sh preflight [--auto-fix] [--max-iterations N]
#   quality-loop-helper.sh pr-review [--wait-for-ci] [--max-iterations N]
#   quality-loop-helper.sh postflight [--monitor-duration Nm]
#   quality-loop-helper.sh status
#   quality-loop-helper.sh cancel
#
# Author: AI DevOps Framework
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly STATE_DIR=".claude"
readonly STATE_FILE="${STATE_DIR}/quality-loop.local.md"

# Default settings
readonly DEFAULT_MAX_ITERATIONS=10
readonly DEFAULT_MONITOR_DURATION=300  # 5 minutes in seconds

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

print_error() {
    local message="$1"
    echo -e "${RED}[quality-loop] Error:${NC} ${message}" >&2
    return 0
}

print_success() {
    local message="$1"
    echo -e "${GREEN}[quality-loop]${NC} ${message}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[quality-loop]${NC} ${message}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}[quality-loop]${NC} ${message}"
    return 0
}

print_step() {
    local message="$1"
    echo -e "${CYAN}[quality-loop]${NC} ${message}"
    return 0
}

# =============================================================================
# State Management
# =============================================================================

create_state() {
    local loop_type="$1"
    local max_iterations="$2"
    local options="$3"
    
    mkdir -p "$STATE_DIR"
    
    cat > "$STATE_FILE" << EOF
---
type: $loop_type
iteration: 1
max_iterations: $max_iterations
status: running
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
options: "$options"
checks_passed: []
checks_failed: []
fixes_applied: 0
---
EOF
    return 0
}

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

run_preflight_checks() {
    local auto_fix="$1"
    local results=""
    local all_passed=true
    
    print_step "Running preflight checks..."
    
    # Check 1: ShellCheck
    print_info "  Checking ShellCheck..."
    if find .agent/scripts -name "*.sh" -exec shellcheck {} \; >/dev/null 2>&1; then
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
    
    # Check 2: Secretlint
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
    
    # Return results
    if [[ "$all_passed" == "true" ]]; then
        echo "PASS"
    else
        echo "FAIL"
    fi
    return 0
}

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
        
        local result
        result=$(run_preflight_checks "$auto_fix")
        
        if [[ "$result" == "PASS" ]]; then
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
        local pending_count failed_count
        pending_count=$(echo "$pr_info" | jq '[.statusCheckRollup[] | select(.status == "PENDING" or .status == "IN_PROGRESS")] | length')
        failed_count=$(echo "$pr_info" | jq '[.statusCheckRollup[] | select(.conclusion == "FAILURE")] | length')
        
        print_info "  CI Checks: $check_count total, $pending_count pending, $failed_count failed"
        
        [[ "$pending_count" -gt 0 ]] && checks_pending=true
        [[ "$failed_count" -gt 0 ]] && checks_failed=true
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

get_pr_feedback() {
    local pr_number="$1"
    
    print_step "Getting PR feedback..."
    
    # Get CodeRabbit comments
    local coderabbit_comments
    coderabbit_comments=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" --jq '.[] | select(.user.login | contains("coderabbit")) | .body' 2>/dev/null | head -10 || echo "")
    
    if [[ -n "$coderabbit_comments" ]]; then
        print_info "CodeRabbit feedback found"
        echo "$coderabbit_comments"
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

pr_review_loop() {
    local wait_for_ci=false
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
            echo "Usage: quality-loop-helper.sh pr-review [--pr NUMBER] [--wait-for-ci] [--max-iterations N]"
            return 1
        fi
    fi
    
    print_info "Starting PR review loop for PR #${pr_number} (max iterations: $max_iterations)"
    
    create_state "pr-review" "$max_iterations" "pr=$pr_number,wait_for_ci=$wait_for_ci"
    
    local iteration=1
    while [[ $iteration -le $max_iterations ]]; do
        echo ""
        print_info "=== PR Review Iteration $iteration / $max_iterations ==="
        
        local status
        status=$(check_pr_status "$pr_number" "$wait_for_ci")
        
        case "$status" in
            MERGED)
                print_success "PR has been merged!"
                rm -f "$STATE_FILE"
                echo "<promise>PR_MERGED</promise>"
                return 0
                ;;
            READY)
                print_success "PR is approved and ready to merge!"
                rm -f "$STATE_FILE"
                echo "<promise>PR_APPROVED</promise>"
                return 0
                ;;
            PENDING)
                print_info "CI checks still running, waiting..."
                sleep 30
                ;;
            CI_FAILED)
                print_warning "CI checks failed. Getting feedback..."
                get_pr_feedback "$pr_number"
                print_info "Fix the issues and push updates."
                ;;
            CHANGES_REQUESTED)
                print_warning "Changes requested. Getting feedback..."
                get_pr_feedback "$pr_number"
                print_info "Address the feedback and push updates."
                ;;
            WAITING)
                print_info "Waiting for review..."
                ;;
        esac
        
        iteration=$(increment_iteration)
        
        if [[ $iteration -le $max_iterations ]]; then
            print_info "Waiting before next check..."
            sleep 60
        fi
    done
    
    print_warning "Max iterations reached. PR not yet approved."
    update_state "status" "max_iterations_reached"
    return 1
}

# =============================================================================
# Postflight Loop
# =============================================================================

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

postflight_loop() {
    local monitor_duration=$DEFAULT_MONITOR_DURATION
    local max_iterations=5
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --monitor-duration)
                # Parse duration (e.g., 5m, 10m, 1h)
                local duration_str="$2"
                if [[ "$duration_str" =~ ^([0-9]+)m$ ]]; then
                    monitor_duration=$((BASH_REMATCH[1] * 60))
                elif [[ "$duration_str" =~ ^([0-9]+)h$ ]]; then
                    monitor_duration=$((BASH_REMATCH[1] * 3600))
                elif [[ "$duration_str" =~ ^([0-9]+)$ ]]; then
                    monitor_duration="$duration_str"
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
