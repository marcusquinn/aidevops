#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2155,SC2317
set -euo pipefail

# Code Review Monitoring and Auto-Fix Script (Enhanced Version)
# Monitors external code review tools and applies automatic fixes
#
# Author: AI DevOps Framework
# Version: 1.1.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

print_header() { local msg="$1"; echo -e "${PURPLE}[MONITOR]${NC} $msg"; return 0; }

# Configuration
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly MONITOR_LOG="$REPO_ROOT/.agents/tmp/code-review-monitor.log"
readonly STATUS_FILE="$REPO_ROOT/.agents/tmp/quality-status.json"

# Create directories
mkdir -p "$REPO_ROOT/.agents/tmp"

# Initialize monitoring log
init_monitoring() {
    print_header "Initializing Code Review Monitoring"
    echo "$(date): Code review monitoring started" >> "$MONITOR_LOG"
    return 0
}

# Check SonarCloud status
check_sonarcloud() {
    print_info "Checking SonarCloud status..."
    
    local api_url="https://sonarcloud.io/api/measures/component?component=marcusquinn_aidevops&metricKeys=bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density"
    local response
    
    if response=$(curl -s "$api_url"); then
        local bugs
        bugs=$(echo "$response" | jq -r '.component.measures[] | select(.metric=="bugs") | .value')
        local vulnerabilities
        vulnerabilities=$(echo "$response" | jq -r '.component.measures[] | select(.metric=="vulnerabilities") | .value')
        local code_smells
        code_smells=$(echo "$response" | jq -r '.component.measures[] | select(.metric=="code_smells") | .value')
        
        print_success "SonarCloud Status: Bugs: $bugs, Vulnerabilities: $vulnerabilities, Code Smells: $code_smells"
        
        # Log status
        echo "$(date): SonarCloud - Bugs: $bugs, Vulnerabilities: $vulnerabilities, Code Smells: $code_smells" >> "$MONITOR_LOG"
        
        # Store in status file
        jq -n --arg bugs "$bugs" --arg vulns "$vulnerabilities" --arg smells "$code_smells" \
           '{sonarcloud: {bugs: $bugs, vulnerabilities: $vulns, code_smells: $smells, timestamp: now}}' > "$STATUS_FILE"
        
        return 0
    else
        print_error "Failed to fetch SonarCloud status"
        return 1
    fi
    return 0
}

# Run Qlty analysis and auto-fix
run_qlty_analysis() {
    print_info "Running Qlty analysis and auto-fixes..."
    
    # Run analysis with sample to get quick feedback
    if bash "$REPO_ROOT/.agents/scripts/qlty-cli.sh" check 5 > "$REPO_ROOT/.agents/tmp/qlty-results.txt" 2>&1; then
        local issues
        issues=$(grep -o "ISSUES: [0-9]*" "$REPO_ROOT/.agents/tmp/qlty-results.txt" | grep -o "[0-9]*" || echo "0")
        print_success "Qlty Analysis: $issues issues found"
        
        # Apply auto-formatting
        if bash "$REPO_ROOT/.agents/scripts/qlty-cli.sh" fmt --all > "$REPO_ROOT/.agents/tmp/qlty-fmt.txt" 2>&1; then
            print_success "Qlty auto-formatting completed"
        fi
        
        echo "$(date): Qlty - $issues issues found, auto-formatting applied" >> "$MONITOR_LOG"
        return 0
    else
        print_warning "Qlty analysis completed with warnings (API key may not be configured)"
        return 0
    fi
    return 0
}

# Run Codacy analysis
run_codacy_analysis() {
    print_info "Running Codacy analysis (timeout: 5m)..."
    
    local log_file="$REPO_ROOT/.agents/tmp/codacy-results.txt"
    
    # Run in background
    bash "$REPO_ROOT/.agents/scripts/codacy-cli.sh" analyze --fix > "$log_file" 2>&1 &
    local pid=$!
    
    # Wait loop with timeout (300 seconds)
    local timeout=300
    local interval=2
    local elapsed=0
    
    while kill -0 $pid 2>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            print_error "Codacy analysis timed out after ${timeout}s"
            kill $pid 2>/dev/null
            return 1
        fi
        
        # Show progress
        if [[ $((elapsed % 10)) -eq 0 ]]; then
            echo -n "."
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    echo "" # New line
    
    # Check exit status
    wait $pid
    local status=$?
    
    if [[ $status -eq 0 ]]; then
        print_success "Codacy analysis completed with auto-fixes"
        echo "$(date): Codacy analysis completed with auto-fixes" >> "$MONITOR_LOG"
        
        # Check for issues in the log
        if grep -q "Issues found" "$log_file"; then
            print_warning "Issues found during analysis. Check $log_file for details."
        fi
        return 0
    else
        print_warning "Codacy analysis completed with warnings or failed (status: $status)"
        # Show last few lines of log for context
        if [[ -f "$log_file" ]]; then
            echo "Last 5 lines of log:"
            tail -n 5 "$log_file" | sed 's/^/  /'
        fi
        return 0 # Don't fail the whole monitor script
    fi
    return 0
}

# Apply automatic fixes based on common patterns
apply_automatic_fixes() {
    # DISABLED: The cd || exit sed regex is too broad and introduces invalid syntax
    # when cd appears inside subshells within if conditions, e.g.:
    #   if (cd "$dir" && cmd); then  →  if (cd "$dir" && cmd); then || exit
    # This caused ShellCheck SC1073/SC1072 regressions (PR #435, commit aa276b3).
    # Safe auto-fixes should validate with shellcheck before committing.
    print_info "Automatic fixes disabled (see monitor-code-review.sh for details)"
    return 0
}

# Generate monitoring report
generate_report() {
    print_header "Code Review Monitoring Report"
    echo ""
    
    if [[ -f "$STATUS_FILE" ]]; then
        print_info "Latest Quality Status:"
        jq -r '.sonarcloud | "SonarCloud: \(.bugs) bugs, \(.vulnerabilities) vulnerabilities, \(.code_smells) code smells"' "$STATUS_FILE" 2>/dev/null || echo "Status data not available"
    fi
    
    echo ""
    print_info "Recent monitoring activity:"
    
    if [[ -f "$MONITOR_LOG" ]]; then
        tail -10 "$MONITOR_LOG"
    else
        echo "No monitoring log available"
    fi
    
    return 0
}

# Add wrapper functions for workflow compatibility
monitor() {
    echo "Running code review status in real-time..."
    init_monitoring
    check_sonarcloud
    run_qlty_analysis
    run_codacy_analysis
    apply_automatic_fixes
    generate_report
    return 0
}

fix() {
    echo "Applying automatic fixes..."
    apply_automatic_fixes
    return 0
}

report() {
    generate_report
    return 0
}

# Main function
main() {
    local command="${1:-monitor}"
    
    case "$command" in
        "monitor")
            monitor
            ;;
        "fix")
            fix
            ;;
        "report")
            report
            ;;
        *)
            echo "Usage: $0 {monitor|fix|report}"
            exit 1
            ;;
    esac
    return 0
}

main "$@"
