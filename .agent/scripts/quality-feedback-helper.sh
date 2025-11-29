#!/usr/bin/env bash
# quality-feedback-helper.sh - Retrieve code quality feedback via GitHub API
# Consolidates feedback from Codacy, CodeRabbit, SonarCloud, CodeFactor, etc.
#
# Usage:
#   quality-feedback-helper.sh [command] [options]
#
# Commands:
#   status      Show status of all quality checks for current commit/PR
#   failed      Show only failed checks with details
#   annotations Get line-level annotations from all check runs
#   codacy      Get Codacy-specific feedback
#   coderabbit  Get CodeRabbit review comments
#   sonar       Get SonarCloud feedback
#   watch       Watch for check completion (polls every 30s)
#
# Examples:
#   quality-feedback-helper.sh status
#   quality-feedback-helper.sh failed --pr 4
#   quality-feedback-helper.sh annotations --commit abc123
#   quality-feedback-helper.sh watch --pr 4

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Get repository info
get_repo() {
    local repo
    repo="${GITHUB_REPOSITORY:-}"
    if [[ -z "$repo" ]]; then
        repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
            echo "Error: Not in a GitHub repository or gh CLI not configured" >&2
            exit 1
        }
    fi
    echo "$repo"
}

# Get commit SHA (from PR or current HEAD)
get_sha() {
    local pr_number="${1:-}"
    if [[ -n "$pr_number" ]]; then
        gh pr view "$pr_number" --json headRefOid -q .headRefOid
    else
        git rev-parse HEAD
    fi
}

# Show status of all checks
cmd_status() {
    local pr_number="${1:-}"
    local repo
    local sha
    
    repo=$(get_repo)
    sha=$(get_sha "$pr_number")
    
    echo -e "${BLUE}=== Quality Check Status ===${NC}"
    echo -e "Repository: ${repo}"
    echo -e "Commit: ${sha:0:8}"
    [[ -n "$pr_number" ]] && echo -e "PR: #${pr_number}"
    echo ""
    
    gh api "repos/${repo}/commits/${sha}/check-runs" \
        --jq '.check_runs[] | "\(.conclusion // .status)\t\(.name)"' | \
    while IFS=$'\t' read -r conclusion name; do
        case "$conclusion" in
            success)
                echo -e "${GREEN}✓${NC} ${name}"
                ;;
            failure|action_required)
                echo -e "${RED}✗${NC} ${name}"
                ;;
            in_progress|queued|pending)
                echo -e "${YELLOW}○${NC} ${name} (${conclusion})"
                ;;
            neutral|skipped)
                echo -e "${BLUE}–${NC} ${name} (${conclusion})"
                ;;
            *)
                echo -e "? ${name} (${conclusion:-unknown})"
                ;;
        esac
    done | sort
}

# Show only failed checks with details
cmd_failed() {
    local pr_number="${1:-}"
    local repo
    local sha
    
    repo=$(get_repo)
    sha=$(get_sha "$pr_number")
    
    echo -e "${RED}=== Failed Quality Checks ===${NC}"
    echo -e "Commit: ${sha:0:8}"
    echo ""
    
    local failed_count=0
    
    while IFS=$'\t' read -r name summary url; do
        ((failed_count++)) || true
        echo -e "${RED}✗ ${name}${NC}"
        [[ -n "$summary" && "$summary" != "null" ]] && echo "  Summary: ${summary}"
        [[ -n "$url" && "$url" != "null" ]] && echo "  Details: ${url}"
        echo ""
    done < <(gh api "repos/${repo}/commits/${sha}/check-runs" \
        --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "action_required") | "\(.name)\t\(.output.summary)\t\(.html_url)"')
    
    if [[ $failed_count -eq 0 ]]; then
        echo -e "${GREEN}No failed checks!${NC}"
    else
        echo -e "${RED}Total failed: ${failed_count}${NC}"
    fi
}

# Get line-level annotations from all check runs
cmd_annotations() {
    local pr_number="${1:-}"
    local repo
    local sha
    
    repo=$(get_repo)
    sha=$(get_sha "$pr_number")
    
    echo -e "${BLUE}=== Annotations (Line-Level Issues) ===${NC}"
    echo -e "Commit: ${sha:0:8}"
    echo ""
    
    # Get all check run IDs
    local check_ids
    check_ids=$(gh api "repos/${repo}/commits/${sha}/check-runs" --jq '.check_runs[].id')
    
    local total_annotations=0
    
    for check_id in $check_ids; do
        local check_name
        check_name=$(gh api "repos/${repo}/check-runs/${check_id}" --jq '.name')
        
        local annotations
        annotations=$(gh api "repos/${repo}/check-runs/${check_id}/annotations" 2>/dev/null || echo "[]")
        
        local count
        count=$(echo "$annotations" | jq 'length')
        
        if [[ "$count" -gt 0 ]]; then
            echo -e "${YELLOW}--- ${check_name} (${count} annotations) ---${NC}"
            echo "$annotations" | jq -r '.[] | "  \(.path):\(.start_line) [\(.annotation_level)] \(.message)"'
            echo ""
            total_annotations=$((total_annotations + count))
        fi
    done
    
    if [[ $total_annotations -eq 0 ]]; then
        echo "No annotations found."
    else
        echo -e "${YELLOW}Total annotations: ${total_annotations}${NC}"
    fi
}

# Get Codacy-specific feedback
cmd_codacy() {
    local pr_number="${1:-}"
    local repo
    local sha
    
    repo=$(get_repo)
    sha=$(get_sha "$pr_number")
    
    echo -e "${BLUE}=== Codacy Feedback ===${NC}"
    
    local codacy_check
    codacy_check=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
        --jq '.check_runs[] | select(.app.slug == "codacy-production" or .name | contains("Codacy"))' 2>/dev/null)
    
    if [[ -z "$codacy_check" ]]; then
        echo "No Codacy check found for this commit."
        return
    fi
    
    local conclusion
    local summary
    local url
    local check_id
    
    conclusion=$(echo "$codacy_check" | jq -r '.conclusion // .status')
    summary=$(echo "$codacy_check" | jq -r '.output.summary // "No summary"')
    url=$(echo "$codacy_check" | jq -r '.html_url')
    check_id=$(echo "$codacy_check" | jq -r '.id')
    
    echo "Status: ${conclusion}"
    echo "Summary: ${summary}"
    echo "Details: ${url}"
    echo ""
    
    # Get annotations if available
    local annotations
    annotations=$(gh api "repos/${repo}/check-runs/${check_id}/annotations" 2>/dev/null || echo "[]")
    local count
    count=$(echo "$annotations" | jq 'length')
    
    if [[ "$count" -gt 0 ]]; then
        echo -e "${YELLOW}Issues found:${NC}"
        echo "$annotations" | jq -r '.[] | "  \(.path):\(.start_line) [\(.annotation_level)] \(.message)"'
    fi
}

# Get CodeRabbit review comments
cmd_coderabbit() {
    local pr_number="${1:-}"
    local repo
    
    repo=$(get_repo)
    
    if [[ -z "$pr_number" ]]; then
        pr_number=$(gh pr view --json number -q .number 2>/dev/null) || {
            echo "Error: Please specify a PR number with --pr" >&2
            exit 1
        }
    fi
    
    echo -e "${BLUE}=== CodeRabbit Review Comments ===${NC}"
    echo -e "PR: #${pr_number}"
    echo ""
    
    # Get review comments from CodeRabbit
    local comments
    comments=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
        --jq '[.[] | select(.user.login | contains("coderabbit"))]' 2>/dev/null || echo "[]")
    
    local count
    count=$(echo "$comments" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
        echo "No CodeRabbit comments found."
        
        # Check for review body
        local reviews
        reviews=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
            --jq '[.[] | select(.user.login | contains("coderabbit"))]' 2>/dev/null || echo "[]")
        
        local review_count
        review_count=$(echo "$reviews" | jq 'length')
        
        if [[ "$review_count" -gt 0 ]]; then
            echo ""
            echo -e "${YELLOW}CodeRabbit Reviews:${NC}"
            echo "$reviews" | jq -r '.[] | "State: \(.state)\n\(.body)\n---"'
        fi
    else
        echo -e "${YELLOW}Inline Comments (${count}):${NC}"
        echo "$comments" | jq -r '.[] | "\(.path):\(.line // .original_line)\n  \(.body)\n"'
    fi
}

# Get SonarCloud feedback
cmd_sonar() {
    local pr_number="${1:-}"
    local repo
    local sha
    
    repo=$(get_repo)
    sha=$(get_sha "$pr_number")
    
    echo -e "${BLUE}=== SonarCloud Feedback ===${NC}"
    
    local sonar_check
    sonar_check=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
        --jq '.check_runs[] | select(.name | contains("SonarCloud") or .name | contains("sonar"))' 2>/dev/null)
    
    if [[ -z "$sonar_check" ]]; then
        echo "No SonarCloud check found for this commit."
        return
    fi
    
    local conclusion
    local summary
    local details_url
    
    conclusion=$(echo "$sonar_check" | jq -r '.conclusion // .status')
    summary=$(echo "$sonar_check" | jq -r '.output.summary // "No summary"')
    details_url=$(echo "$sonar_check" | jq -r '.details_url // .html_url')
    
    echo "Status: ${conclusion}"
    echo "Summary: ${summary}"
    echo "Dashboard: ${details_url}"
}

# Watch for check completion
cmd_watch() {
    local pr_number="${1:-}"
    local repo
    local sha
    local interval="${2:-30}"
    
    repo=$(get_repo)
    sha=$(get_sha "$pr_number")
    
    echo -e "${BLUE}=== Watching Quality Checks ===${NC}"
    echo -e "Commit: ${sha:0:8}"
    echo -e "Polling every ${interval} seconds..."
    echo ""
    
    while true; do
        local pending
        pending=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
            --jq '[.check_runs[] | select(.status == "in_progress" or .status == "queued" or .status == "pending")] | length')
        
        local failed
        failed=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
            --jq '[.check_runs[] | select(.conclusion == "failure")] | length')
        
        local total
        total=$(gh api "repos/${repo}/commits/${sha}/check-runs" --jq '.check_runs | length')
        
        local completed
        completed=$((total - pending))
        
        echo -e "[$(date '+%H:%M:%S')] Completed: ${completed}/${total}, Pending: ${pending}, Failed: ${failed}"
        
        if [[ "$pending" -eq 0 ]]; then
            echo ""
            if [[ "$failed" -eq 0 ]]; then
                echo -e "${GREEN}All checks passed!${NC}"
            else
                echo -e "${RED}${failed} check(s) failed.${NC}"
                cmd_failed "$pr_number"
            fi
            break
        fi
        
        sleep "$interval"
    done
}

# Show help
show_help() {
    cat << 'EOF'
Quality Feedback Helper - Retrieve code quality feedback via GitHub API

Usage: quality-feedback-helper.sh [command] [options]

Commands:
  status         Show status of all quality checks
  failed         Show only failed checks with details
  annotations    Get line-level annotations from all check runs
  codacy         Get Codacy-specific feedback
  coderabbit     Get CodeRabbit review comments
  sonar          Get SonarCloud feedback
  watch          Watch for check completion (polls every 30s)
  help           Show this help message

Options:
  --pr NUMBER    Specify PR number (otherwise uses current commit)
  --commit SHA   Specify commit SHA (otherwise uses HEAD)

Examples:
  quality-feedback-helper.sh status
  quality-feedback-helper.sh failed --pr 4
  quality-feedback-helper.sh annotations
  quality-feedback-helper.sh coderabbit --pr 4
  quality-feedback-helper.sh watch --pr 4

Requirements:
  - GitHub CLI (gh) installed and authenticated
  - jq for JSON parsing
  - Inside a Git repository linked to GitHub
EOF
}

# Parse arguments
main() {
    local command="${1:-status}"
    shift || true
    
    local pr_number=""
    local commit_sha=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr)
                pr_number="$2"
                shift 2
                ;;
            --commit)
                commit_sha="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done
    
    # If commit SHA provided, use it directly
    if [[ -n "$commit_sha" ]]; then
        get_sha() { echo "$commit_sha"; }
    fi
    
    case "$command" in
        status)
            cmd_status "$pr_number"
            ;;
        failed)
            cmd_failed "$pr_number"
            ;;
        annotations)
            cmd_annotations "$pr_number"
            ;;
        codacy)
            cmd_codacy "$pr_number"
            ;;
        coderabbit)
            cmd_coderabbit "$pr_number"
            ;;
        sonar)
            cmd_sonar "$pr_number"
            ;;
        watch)
            cmd_watch "$pr_number"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "Unknown command: $command" >&2
            show_help
            exit 1
            ;;
    esac
}

main "$@"
