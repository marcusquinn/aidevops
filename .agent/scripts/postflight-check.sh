#!/bin/bash
# shellcheck disable=SC2034,SC2155
# Postflight Verification Script
# Verifies release health after tag creation and GitHub release publication
#
# Usage: ./postflight-check.sh [--quick|--full|--ci-only|--security-only]
#
# Author: AI DevOps Framework
# Version: 1.0.0

set -euo pipefail

# Configuration
readonly TIMEOUT_CI=600        # 10 minutes for CI/CD
readonly TIMEOUT_TOOLS=300     # 5 minutes for code review tools
readonly POLL_INTERVAL=30      # Check every 30 seconds
readonly MAX_ATTEMPTS=20       # Maximum polling attempts

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Repository info
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SONAR_PROJECT_KEY="marcusquinn_aidevops"

# Counters
PASSED=0
FAILED=0
WARNINGS=0
SKIPPED=0

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Postflight Verification${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Started: $(date)"
    echo ""
    return 0
}

print_success() {
    local message="$1"
    echo -e "${GREEN}PASSED${NC} $message"
    ((PASSED++))
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}WARNING${NC} $message"
    ((WARNINGS++))
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}FAILED${NC} $message"
    ((FAILED++))
    return 0
}

print_skip() {
    local message="$1"
    echo -e "${BLUE}SKIPPED${NC} $message"
    ((SKIPPED++))
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}INFO${NC} $message"
    return 0
}

print_section() {
    local title="$1"
    echo ""
    echo -e "${BLUE}--- $title ---${NC}"
    return 0
}

# Check if gh CLI is available and authenticated
check_gh_cli() {
    if ! command -v gh &> /dev/null; then
        print_error "GitHub CLI (gh) not installed"
        return 1
    fi
    
    if ! gh auth status &> /dev/null; then
        print_error "GitHub CLI not authenticated. Run: gh auth login"
        return 1
    fi
    
    return 0
}

# Get repository owner and name
get_repo_info() {
    local remote_url
    remote_url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")
    
    if [[ -z "$remote_url" ]]; then
        echo ""
        return 1
    fi
    
    # Extract owner/repo from various URL formats
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        return 0
    fi
    
    echo ""
    return 1
}

# Check GitHub Actions CI/CD status
check_cicd_status() {
    print_section "CI/CD Pipeline Status"
    
    if ! check_gh_cli; then
        return 1
    fi
    
    local repo
    repo=$(get_repo_info)
    if [[ -z "$repo" ]]; then
        print_error "Could not determine repository"
        return 1
    fi
    
    print_info "Repository: $repo"
    
    # Get latest workflow run
    local latest_run
    latest_run=$(gh run list --repo "$repo" --limit=1 --json databaseId,status,conclusion,name 2>/dev/null || echo "")
    
    if [[ -z "$latest_run" || "$latest_run" == "[]" ]]; then
        print_warning "No workflow runs found"
        return 0
    fi
    
    local run_id status conclusion name
    run_id=$(echo "$latest_run" | jq -r '.[0].databaseId')
    status=$(echo "$latest_run" | jq -r '.[0].status')
    conclusion=$(echo "$latest_run" | jq -r '.[0].conclusion')
    name=$(echo "$latest_run" | jq -r '.[0].name')
    
    print_info "Latest run: $name (#$run_id)"
    print_info "Status: $status, Conclusion: $conclusion"
    
    # If still running, wait for completion
    if [[ "$status" == "in_progress" || "$status" == "queued" ]]; then
        print_info "Waiting for workflow to complete (timeout: ${TIMEOUT_CI}s)..."
        
        local attempt=0
        while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
            sleep "$POLL_INTERVAL"
            ((attempt++))
            
            local current_status
            current_status=$(gh run view "$run_id" --repo "$repo" --json status,conclusion 2>/dev/null || echo "")
            
            if [[ -z "$current_status" ]]; then
                continue
            fi
            
            status=$(echo "$current_status" | jq -r '.status')
            conclusion=$(echo "$current_status" | jq -r '.conclusion')
            
            if [[ "$status" == "completed" ]]; then
                break
            fi
            
            print_info "Still waiting... (attempt $attempt/$MAX_ATTEMPTS)"
        done
    fi
    
    # Check final status
    if [[ "$status" != "completed" ]]; then
        print_error "Workflow did not complete within timeout"
        return 1
    fi
    
    if [[ "$conclusion" == "success" ]]; then
        print_success "CI/CD pipeline: $name"
    elif [[ "$conclusion" == "failure" ]]; then
        print_error "CI/CD pipeline failed: $name"
        print_info "View logs: gh run view $run_id --repo $repo --log-failed"
        return 1
    else
        print_warning "CI/CD pipeline conclusion: $conclusion"
    fi
    
    # Check all recent workflows
    print_info "Checking all recent workflows..."
    local all_runs
    all_runs=$(gh run list --repo "$repo" --limit=5 --json name,conclusion,status 2>/dev/null || echo "[]")
    
    local failed_count
    failed_count=$(echo "$all_runs" | jq '[.[] | select(.conclusion == "failure")] | length')
    
    if [[ "$failed_count" -gt 0 ]]; then
        print_warning "$failed_count workflow(s) failed recently"
        echo "$all_runs" | jq -r '.[] | select(.conclusion == "failure") | "  - \(.name): \(.conclusion)"'
    fi
    
    return 0
}

# Check SonarCloud quality gate
check_sonarcloud() {
    print_section "SonarCloud Analysis"
    
    # Check quality gate status
    local qg_response
    qg_response=$(curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=$SONAR_PROJECT_KEY" 2>/dev/null || echo "")
    
    if [[ -z "$qg_response" ]]; then
        print_skip "Could not reach SonarCloud API"
        return 0
    fi
    
    local qg_status
    qg_status=$(echo "$qg_response" | jq -r '.projectStatus.status // "UNKNOWN"')
    
    if [[ "$qg_status" == "OK" ]]; then
        print_success "SonarCloud quality gate: PASSED"
    elif [[ "$qg_status" == "ERROR" ]]; then
        print_error "SonarCloud quality gate: FAILED"
        
        # Get failing conditions
        echo "$qg_response" | jq -r '.projectStatus.conditions[] | select(.status == "ERROR") | "  - \(.metricKey): \(.actualValue) (threshold: \(.errorThreshold))"'
    elif [[ "$qg_status" == "WARN" ]]; then
        print_warning "SonarCloud quality gate: WARNING"
    else
        print_warning "SonarCloud quality gate status: $qg_status"
    fi
    
    # Get current metrics
    local metrics_response
    metrics_response=$(curl -s "https://sonarcloud.io/api/measures/component?component=$SONAR_PROJECT_KEY&metricKeys=bugs,vulnerabilities,code_smells,security_hotspots" 2>/dev/null || echo "")
    
    if [[ -n "$metrics_response" ]]; then
        print_info "Current metrics:"
        echo "$metrics_response" | jq -r '.component.measures[] | "  - \(.metric): \(.value)"' 2>/dev/null || true
    fi
    
    # Check for new issues
    local issues_response
    issues_response=$(curl -s "https://sonarcloud.io/api/issues/search?componentKeys=$SONAR_PROJECT_KEY&resolved=false&severities=BLOCKER,CRITICAL&ps=5" 2>/dev/null || echo "")
    
    if [[ -n "$issues_response" ]]; then
        local critical_count
        critical_count=$(echo "$issues_response" | jq -r '.total // 0')
        
        if [[ "$critical_count" -gt 0 ]]; then
            print_warning "$critical_count blocker/critical issues found"
            echo "$issues_response" | jq -r '.issues[] | "  - [\(.severity)] \(.message)"' 2>/dev/null | head -5 || true
        fi
    fi
    
    return 0
}

# Check Codacy status
check_codacy() {
    print_section "Codacy Analysis"
    
    local codacy_script="$REPO_ROOT/.agent/scripts/codacy-cli.sh"
    
    if [[ -f "$codacy_script" ]]; then
        if bash "$codacy_script" status &> /dev/null; then
            print_success "Codacy CLI: Available"
            print_info "Run 'bash $codacy_script analyze' for detailed analysis"
        else
            print_skip "Codacy CLI not configured"
        fi
    else
        print_skip "Codacy CLI script not found"
    fi
    
    # Check via dashboard link
    print_info "Dashboard: https://app.codacy.com/gh/marcusquinn/aidevops"
    
    return 0
}

# Check security with Snyk
check_snyk() {
    print_section "Security Scanning (Snyk)"
    
    if ! command -v snyk &> /dev/null; then
        print_skip "Snyk CLI not installed"
        print_info "Install: brew tap snyk/tap && brew install snyk-cli"
        return 0
    fi
    
    # Check authentication
    if ! snyk auth check &> /dev/null 2>&1; then
        print_skip "Snyk not authenticated"
        print_info "Run: snyk auth"
        return 0
    fi
    
    print_info "Running Snyk security scan..."
    
    local snyk_output
    local snyk_exit=0
    snyk_output=$(snyk test --severity-threshold=high --json 2>/dev/null) || snyk_exit=$?
    
    if [[ $snyk_exit -eq 0 ]]; then
        print_success "Snyk: No high/critical vulnerabilities"
    elif [[ $snyk_exit -eq 1 ]]; then
        local vuln_count
        vuln_count=$(echo "$snyk_output" | jq -r '.vulnerabilities | length // 0')
        print_error "Snyk: $vuln_count vulnerabilities found"
        
        # Show top vulnerabilities
        echo "$snyk_output" | jq -r '.vulnerabilities[:5][] | "  - [\(.severity)] \(.title) in \(.packageName)"' 2>/dev/null || true
    else
        print_warning "Snyk scan completed with warnings"
    fi
    
    return 0
}

# Check for exposed secrets
check_secrets() {
    print_section "Secret Detection (Secretlint)"
    
    if command -v secretlint &> /dev/null; then
        print_info "Running Secretlint scan..."
        
        if secretlint "**/*" --format compact 2>/dev/null; then
            print_success "Secretlint: No secrets detected"
        else
            print_error "Secretlint: Potential secrets found"
            return 1
        fi
    elif [[ -f "$REPO_ROOT/node_modules/.bin/secretlint" ]]; then
        print_info "Running Secretlint (local)..."
        
        if "$REPO_ROOT/node_modules/.bin/secretlint" "**/*" --format compact 2>/dev/null; then
            print_success "Secretlint: No secrets detected"
        else
            print_error "Secretlint: Potential secrets found"
            return 1
        fi
    else
        print_skip "Secretlint not installed"
        print_info "Install: npm install -g secretlint @secretlint/secretlint-rule-preset-recommend"
    fi
    
    return 0
}

# Check npm audit (if applicable)
check_npm_audit() {
    print_section "Dependency Audit"
    
    if [[ -f "$REPO_ROOT/package.json" ]]; then
        if command -v npm &> /dev/null; then
            print_info "Running npm audit..."
            
            local audit_output
            local audit_exit=0
            audit_output=$(npm audit --audit-level=high --json 2>/dev/null) || audit_exit=$?
            
            if [[ $audit_exit -eq 0 ]]; then
                print_success "npm audit: No high/critical vulnerabilities"
            else
                local vuln_count
                vuln_count=$(echo "$audit_output" | jq -r '.metadata.vulnerabilities.high + .metadata.vulnerabilities.critical // 0')
                print_warning "npm audit: $vuln_count high/critical vulnerabilities"
            fi
        else
            print_skip "npm not available"
        fi
    else
        print_skip "No package.json found"
    fi
    
    return 0
}

# Run local quality checks
check_local_quality() {
    print_section "Local Quality Checks"
    
    local quality_script="$REPO_ROOT/.agent/scripts/quality-check.sh"
    
    if [[ -f "$quality_script" ]]; then
        print_info "Running quality-check.sh..."
        
        if bash "$quality_script" &> /dev/null; then
            print_success "Local quality checks passed"
        else
            print_warning "Local quality checks reported issues"
            print_info "Run: bash $quality_script (for details)"
        fi
    else
        print_skip "quality-check.sh not found"
    fi
    
    return 0
}

# Print summary
print_summary() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Finished: $(date)"
    echo ""
    echo -e "  ${GREEN}Passed:${NC}   $PASSED"
    echo -e "  ${RED}Failed:${NC}   $FAILED"
    echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
    echo -e "  ${BLUE}Skipped:${NC}  $SKIPPED"
    echo ""
    
    if [[ $FAILED -gt 0 ]]; then
        echo -e "${RED}POSTFLIGHT VERIFICATION FAILED${NC}"
        echo ""
        echo "Recommended actions:"
        echo "  1. Review failed checks above"
        echo "  2. Consider rollback if critical issues found"
        echo "  3. See: .agent/workflows/postflight.md#rollback-procedures"
        return 1
    elif [[ $WARNINGS -gt 0 ]]; then
        echo -e "${YELLOW}POSTFLIGHT VERIFICATION PASSED WITH WARNINGS${NC}"
        echo ""
        echo "Review warnings above and address in next release if needed."
        return 0
    else
        echo -e "${GREEN}POSTFLIGHT VERIFICATION PASSED${NC}"
        return 0
    fi
}

# Show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --quick         Run quick checks only (CI/CD + SonarCloud)"
    echo "  --full          Run all checks (default)"
    echo "  --ci-only       Run CI/CD checks only"
    echo "  --security-only Run security checks only"
    echo "  --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Run full postflight verification"
    echo "  $0 --quick      # Quick check after minor release"
    echo "  $0 --security   # Security-focused verification"
    return 0
}

# Main function
main() {
    local mode="full"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick)
                mode="quick"
                shift
                ;;
            --full)
                mode="full"
                shift
                ;;
            --ci-only)
                mode="ci-only"
                shift
                ;;
            --security-only)
                mode="security-only"
                shift
                ;;
            --help|-h)
                show_usage
                return 0
                ;;
            *)
                echo "Unknown option: $1"
                show_usage
                return 1
                ;;
        esac
    done
    
    print_header
    
    cd "$REPO_ROOT"
    
    case "$mode" in
        quick)
            check_cicd_status || true
            check_sonarcloud || true
            ;;
        ci-only)
            check_cicd_status || true
            ;;
        security-only)
            check_snyk || true
            check_secrets || true
            check_npm_audit || true
            ;;
        full)
            check_cicd_status || true
            check_sonarcloud || true
            check_codacy || true
            check_snyk || true
            check_secrets || true
            check_npm_audit || true
            check_local_quality || true
            ;;
    esac
    
    print_summary
    return $?
}

main "$@"
