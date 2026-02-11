#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# CodeRabbit Daily Pulse - Full Codebase Review Trigger
#
# Triggers a full codebase review via CodeRabbit CLI or GitHub API,
# stores results in structured format for downstream processing.
#
# Usage: ./coderabbit-pulse-helper.sh [command] [options]
# Commands:
#   run         - Run a full codebase review (default)
#   status      - Show last review status and timing
#   results     - Show latest review results
#   install     - Install CodeRabbit CLI if missing
#   help        - Show this help message
#
# Options:
#   --repo <path>   - Repository path (default: current directory)
#   --force         - Run even if a recent review exists
#   --quiet         - Minimal output (for cron/supervisor)
#
# Integration:
#   - Cron: */1440 * * * * coderabbit-pulse-helper.sh run --quiet
#   - Supervisor: Add to pulse Phase 8 (quality)
#
# Author: AI DevOps Framework
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# Colors
readonly CR_GREEN='\033[0;32m'
readonly CR_BLUE='\033[0;34m'
readonly CR_YELLOW='\033[1;33m'
readonly CR_RED='\033[0;31m'
readonly CR_NC='\033[0m'

# Configuration
readonly REVIEWS_DIR="${HOME}/.aidevops/.agent-workspace/reviews"
readonly REVIEW_COOLDOWN=86400  # 24 hours between reviews (seconds)

print_info() { local msg="$1"; echo -e "${CR_BLUE}[PULSE]${CR_NC} $msg"; return 0; }
print_success() { local msg="$1"; echo -e "${CR_GREEN}[PULSE]${CR_NC} $msg"; return 0; }
print_warning() { local msg="$1"; echo -e "${CR_YELLOW}[PULSE]${CR_NC} $msg"; return 0; }
print_error() { local msg="$1"; echo -e "${CR_RED}[PULSE]${CR_NC} $msg"; return 0; }

# Get repo identifier (owner/name) from git remote
get_repo_id() {
    local repo_path="${1:-.}"
    local remote_url
    remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
    if [[ -z "$remote_url" ]]; then
        echo "unknown"
        return 1
    fi
    # Extract owner/repo from various URL formats
    # Remove .git suffix and protocol prefix, then get last two path segments
    local cleaned
    cleaned="${remote_url%.git}"
    # Remove protocol (https://github.com/ or git@github.com:)
    cleaned="${cleaned#*://*/}"  # https://host/owner/repo -> owner/repo
    if [[ "$cleaned" == "$remote_url"* ]]; then
        # SSH format: git@host:owner/repo
        cleaned="${cleaned#*:}"
    fi
    echo "$cleaned"
    return 0
}

# Get safe filename from repo id
get_repo_slug() {
    local repo_id="$1"
    echo "$repo_id" | tr '/' '-'
    return 0
}

# Check if a review was run recently (within cooldown period)
is_review_recent() {
    local repo_slug="$1"
    local last_review_file="$REVIEWS_DIR/${repo_slug}/last-review.json"

    if [[ ! -f "$last_review_file" ]]; then
        return 1
    fi

    local last_timestamp
    last_timestamp=$(jq -r '.timestamp // "0"' "$last_review_file" 2>/dev/null || echo "0")
    local now
    now=$(date +%s)
    local age=$(( now - last_timestamp ))

    if [[ "$age" -lt "$REVIEW_COOLDOWN" ]]; then
        return 0
    fi
    return 1
}

# Run review via CodeRabbit CLI
run_cli_review() {
    local repo_path="$1"
    local output_file="$2"

    if ! command -v coderabbit &>/dev/null; then
        return 1
    fi

    print_info "Running CodeRabbit CLI full review..."
    local review_output
    if review_output=$(cd "$repo_path" && coderabbit --plain --type all 2>&1); then
        echo "$review_output" > "$output_file"
        print_success "CLI review complete ($(wc -l < "$output_file") lines)"
        return 0
    else
        print_warning "CLI review failed (exit $?)"
        echo "$review_output" > "${output_file}.error" 2>/dev/null || true
        return 1
    fi
}

# Run review via GitHub API (trigger @coderabbitai on a tracking issue)
run_gh_api_review() {
    local output_file="$2"

    if ! command -v gh &>/dev/null; then
        print_error "Neither CodeRabbit CLI nor gh CLI available"
        return 1
    fi

    # Check if gh is authenticated
    if ! gh auth status &>/dev/null 2>&1; then
        print_error "gh CLI not authenticated"
        return 1
    fi

    print_info "Triggering CodeRabbit review via GitHub API..."

    # Strategy: Find or create a tracking issue for daily reviews
    local tracking_label="coderabbit-pulse"
    local tracking_issue

    # Look for existing open tracking issue
    tracking_issue=$(gh issue list --repo "$repo_id" --label "$tracking_label" --state open --json number --jq '.[0].number // empty' 2>/dev/null || echo "")

    if [[ -z "$tracking_issue" ]]; then
        # Create the tracking label if it doesn't exist
        gh label create "$tracking_label" --repo "$repo_id" --description "Daily CodeRabbit pulse review tracking" --color "7057ff" 2>/dev/null || true

        # Create tracking issue (gh issue create returns URL, extract number)
        local issue_url
        issue_url=$(gh issue create --repo "$repo_id" \
            --title "Daily CodeRabbit Pulse Review" \
            --body "This issue tracks daily full codebase reviews by CodeRabbit.
Each comment triggers a review cycle. Results are collected by the aidevops supervisor.

**Do not close this issue** - it is used for ongoing quality monitoring." \
            --label "$tracking_label" 2>/dev/null || echo "")
        tracking_issue="${issue_url##*/}"

        if [[ -z "$tracking_issue" ]]; then
            print_error "Failed to create tracking issue"
            return 1
        fi
        print_success "Created tracking issue #$tracking_issue"
    fi

    # Post a comment to trigger CodeRabbit review
    local review_date
    review_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local comment_body="@coderabbitai Please perform a full codebase review.

**Pulse timestamp**: $review_date
**Triggered by**: aidevops supervisor daily pulse

Focus areas:
- Shell script quality (ShellCheck compliance, error handling)
- Security (credential handling, input validation)
- Code duplication and dead code
- Documentation accuracy
- Performance concerns"

    if gh issue comment "$tracking_issue" --repo "$repo_id" --body "$comment_body" &>/dev/null; then
        print_success "Triggered review on issue #$tracking_issue"

        # Store the trigger info (actual review results come async via webhook/polling)
        cat > "$output_file" << EOF
{
  "method": "gh_api",
  "tracking_issue": $tracking_issue,
  "trigger_time": "$review_date",
  "repo": "$repo_id",
  "status": "triggered",
  "note": "Review results will appear as CodeRabbit comments on issue #$tracking_issue"
}
EOF
        return 0
    else
        print_error "Failed to post review trigger comment"
        return 1
    fi
}

# Collect review results from GitHub (for gh_api method)
collect_gh_results() {
    local repo_id="$1"
    local repo_slug="$2"
    local output_file="$REVIEWS_DIR/${repo_slug}/latest-results.json"

    local tracking_label="coderabbit-pulse"
    local tracking_issue
    tracking_issue=$(gh issue list --repo "$repo_id" --label "$tracking_label" --state open --json number --jq '.[0].number // empty' 2>/dev/null || echo "")

    if [[ -z "$tracking_issue" ]]; then
        print_warning "No tracking issue found"
        return 1
    fi

    # Get CodeRabbit bot comments from the tracking issue
    local comments
    comments=$(gh api "repos/${repo_id}/issues/${tracking_issue}/comments" \
        --jq '[.[] | select(.user.login == "coderabbitai[bot]" or .user.login == "coderabbitai") | {id: .id, created_at: .created_at, body: .body}] | sort_by(.created_at) | reverse | .[0:3]' 2>/dev/null || echo "[]")

    if [[ "$comments" == "[]" || -z "$comments" ]]; then
        print_info "No CodeRabbit responses yet on issue #$tracking_issue"
        return 0
    fi

    echo "$comments" > "$output_file"
    local count
    count=$(echo "$comments" | jq 'length' 2>/dev/null || echo "0")
    print_success "Collected $count CodeRabbit response(s) from issue #$tracking_issue"
    return 0
}

# Main run command
cmd_run() {
    local repo_path="."
    local force=false
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo_path="$2"; shift 2 ;;
            --force) force=true; shift ;;
            --quiet) quiet=true; shift ;;
            *) shift ;;
        esac
    done

    local repo_id
    repo_id=$(get_repo_id "$repo_path")
    local repo_slug
    repo_slug=$(get_repo_slug "$repo_id")

    # Create reviews directory
    mkdir -p "$REVIEWS_DIR/${repo_slug}"

    # Check cooldown
    if [[ "$force" != "true" ]] && is_review_recent "$repo_slug"; then
        local last_file="$REVIEWS_DIR/${repo_slug}/last-review.json"
        local last_time
        last_time=$(jq -r '.timestamp' "$last_file" 2>/dev/null || echo "0")
        local age=$(( $(date +%s) - last_time ))
        local hours=$(( age / 3600 ))
        if [[ "$quiet" != "true" ]]; then
            print_info "Review ran ${hours}h ago (cooldown: $((REVIEW_COOLDOWN / 3600))h). Use --force to override."
        fi
        return 0
    fi

    if [[ "$quiet" != "true" ]]; then
        print_info "Starting full codebase review for $repo_id..."
    fi

    local output_file
    output_file="$REVIEWS_DIR/${repo_slug}/review-$(date +%Y%m%d-%H%M%S).txt"
    local method="none"
    local success=false

    # Try CodeRabbit CLI first
    if run_cli_review "$repo_path" "$output_file" 2>/dev/null; then
        method="cli"
        success=true
    # Fall back to GitHub API
    elif run_gh_api_review "$repo_path" "$output_file" "$repo_id"; then
        method="gh_api"
        success=true
    else
        print_error "No review method available"
        print_info "Install CodeRabbit CLI: bash ~/.aidevops/agents/scripts/coderabbit-cli.sh install"
        print_info "Or ensure gh CLI is authenticated: gh auth login"
        return 1
    fi

    if [[ "$success" == "true" ]]; then
        # Record last review metadata
        cat > "$REVIEWS_DIR/${repo_slug}/last-review.json" << EOF
{
  "timestamp": $(date +%s),
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repo": "$repo_id",
  "method": "$method",
  "output_file": "$output_file"
}
EOF
        if [[ "$quiet" != "true" ]]; then
            print_success "Review complete (method: $method)"
            print_info "Results: $output_file"
        fi
    fi

    return 0
}

# Status command
cmd_status() {
    local repo_path="${1:-.}"
    local repo_id
    repo_id=$(get_repo_id "$repo_path")
    local repo_slug
    repo_slug=$(get_repo_slug "$repo_id")

    echo "CodeRabbit Pulse Status"
    echo "======================"
    echo ""
    echo "Repository: $repo_id"
    echo "Reviews dir: $REVIEWS_DIR/${repo_slug}/"
    echo ""

    # CLI status
    if command -v coderabbit &>/dev/null; then
        echo "CodeRabbit CLI: installed ($(coderabbit --version 2>/dev/null || echo 'unknown version'))"
    else
        echo "CodeRabbit CLI: not installed"
    fi

    # gh status
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        echo "GitHub CLI: authenticated"
    else
        echo "GitHub CLI: not available or not authenticated"
    fi

    echo ""

    # Last review
    local last_file="$REVIEWS_DIR/${repo_slug}/last-review.json"
    if [[ -f "$last_file" ]]; then
        local last_date
        last_date=$(jq -r '.date' "$last_file" 2>/dev/null || echo "unknown")
        local last_method
        last_method=$(jq -r '.method' "$last_file" 2>/dev/null || echo "unknown")
        local last_ts
        last_ts=$(jq -r '.timestamp' "$last_file" 2>/dev/null || echo "0")
        local age=$(( $(date +%s) - last_ts ))
        local hours=$(( age / 3600 ))
        echo "Last review: $last_date ($hours hours ago, method: $last_method)"
    else
        echo "Last review: never"
    fi

    # Review count
    local review_count
    review_count=$(find "$REVIEWS_DIR/${repo_slug}" -name "review-*.txt" 2>/dev/null | wc -l | tr -d ' ')
    echo "Total reviews: $review_count"

    return 0
}

# Results command
cmd_results() {
    local repo_path="${1:-.}"
    local repo_id
    repo_id=$(get_repo_id "$repo_path")
    local repo_slug
    repo_slug=$(get_repo_slug "$repo_id")

    local last_file="$REVIEWS_DIR/${repo_slug}/last-review.json"
    if [[ ! -f "$last_file" ]]; then
        print_warning "No reviews found. Run: $0 run"
        return 1
    fi

    local output_file
    output_file=$(jq -r '.output_file' "$last_file" 2>/dev/null || echo "")
    local method
    method=$(jq -r '.method' "$last_file" 2>/dev/null || echo "")

    if [[ "$method" == "gh_api" ]]; then
        # For gh_api method, try to collect latest results
        collect_gh_results "$repo_id" "$repo_slug"
        local results_file="$REVIEWS_DIR/${repo_slug}/latest-results.json"
        if [[ -f "$results_file" ]]; then
            echo "=== Latest CodeRabbit Responses ==="
            jq -r '.[] | "--- Response (\(.created_at)) ---\n\(.body)\n"' "$results_file" 2>/dev/null || cat "$results_file"
        else
            print_info "No CodeRabbit responses collected yet"
            if [[ -f "$output_file" ]]; then
                echo ""
                echo "=== Trigger Info ==="
                cat "$output_file"
            fi
        fi
    elif [[ -f "$output_file" ]]; then
        echo "=== Latest Review Output ==="
        cat "$output_file"
    else
        print_warning "Review output file not found: $output_file"
        return 1
    fi

    return 0
}

# Install command
cmd_install() {
    if command -v coderabbit &>/dev/null; then
        print_success "CodeRabbit CLI already installed"
        coderabbit --version 2>/dev/null || true
        return 0
    fi

    print_info "Installing CodeRabbit CLI..."
    if [[ -f "$SCRIPT_DIR/coderabbit-cli.sh" ]]; then
        bash "$SCRIPT_DIR/coderabbit-cli.sh" install
    else
        print_error "coderabbit-cli.sh not found"
        print_info "Install manually: curl -fsSL https://cli.coderabbit.ai/install.sh | bash"
        return 1
    fi
    return 0
}

# Help command
cmd_help() {
    echo "CodeRabbit Daily Pulse - Full Codebase Review"
    echo ""
    echo "Usage: $(basename "$0") [command] [options]"
    echo ""
    echo "Commands:"
    echo "  run         Run a full codebase review (default)"
    echo "  status      Show last review status and timing"
    echo "  results     Show latest review results"
    echo "  install     Install CodeRabbit CLI if missing"
    echo "  help        Show this help message"
    echo ""
    echo "Options:"
    echo "  --repo <path>   Repository path (default: current directory)"
    echo "  --force         Run even if a recent review exists"
    echo "  --quiet         Minimal output (for cron/supervisor)"
    echo ""
    echo "Integration:"
    echo "  Cron:       0 6 * * * ~/.aidevops/agents/scripts/coderabbit-pulse-helper.sh run --quiet"
    echo "  Supervisor: Add to pulse quality phase"
    echo ""
    echo "Review results stored in: $REVIEWS_DIR/<repo-slug>/"
    return 0
}

# Main dispatch
main() {
    local command="${1:-run}"
    shift 2>/dev/null || true

    case "$command" in
        run)        cmd_run "$@" ;;
        status)     cmd_status "$@" ;;
        results)    cmd_results "$@" ;;
        install)    cmd_install "$@" ;;
        help|-h|--help) cmd_help ;;
        *)
            print_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
