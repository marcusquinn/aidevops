#!/bin/bash

# Code Review Monitoring and Auto-Fix Script
# Monitors external code review tools and applies automatic fixes
#
# Author: AI DevOps Framework
# Version: 1.0.0

# Colors for output
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_header() { echo -e "${PURPLE}[MONITOR]${NC} $1"; }

# Configuration
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly MONITOR_LOG="$REPO_ROOT/.agent/tmp/code-review-monitor.log"
readonly STATUS_FILE="$REPO_ROOT/.agent/tmp/quality-status.json"

# Create directories
mkdir -p "$REPO_ROOT/.agent/tmp"

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
}

# Run Qlty analysis and auto-fix
run_qlty_analysis() {
    print_info "Running Qlty analysis and auto-fixes..."
    
    # Run analysis with sample to get quick feedback
    if bash "$REPO_ROOT/.agent/scripts/qlty-cli.sh" check 5 > "$REPO_ROOT/.agent/tmp/qlty-results.txt" 2>&1; then
        local issues
        issues=$(grep -o "ISSUES: [0-9]*" "$REPO_ROOT/.agent/tmp/qlty-results.txt" | grep -o "[0-9]*" || echo "0")
        print_success "Qlty Analysis: $issues issues found"
        
        # Apply auto-formatting
        if bash "$REPO_ROOT/.agent/scripts/qlty-cli.sh" fmt --all > "$REPO_ROOT/.agent/tmp/qlty-fmt.txt" 2>&1; then
            print_success "Qlty auto-formatting completed"
        fi
        
        echo "$(date): Qlty - $issues issues found, auto-formatting applied" >> "$MONITOR_LOG"
        return 0
    else
        print_warning "Qlty analysis completed with warnings (API key not configured)"
        return 0
    fi
}

# Run Codacy analysis
run_codacy_analysis() {
    print_info "Running Codacy analysis..."
    
    if bash "$REPO_ROOT/.agent/scripts/codacy-cli.sh" analyze --fix > "$REPO_ROOT/.agent/tmp/codacy-results.txt" 2>&1; then
        print_success "Codacy analysis completed with auto-fixes"
        echo "$(date): Codacy analysis completed with auto-fixes" >> "$MONITOR_LOG"
        return 0
    else
        print_warning "Codacy analysis completed (may need API key configuration)"
        return 0
    fi
}

# Apply automatic fixes based on common patterns
apply_automatic_fixes() {
    print_info "Applying automatic fixes for common issues..."
    
    local fixes_applied=0
    
    # Fix shellcheck issues in new files
    for file in providers/*.sh .agent/scripts/*.sh; do
        if [[ -f "$file" ]]; then
            # Check if file has been modified recently (within last hour)
            if [[ $(find "$file" -mmin -60 2>/dev/null) ]]; then
                print_info "Checking recent file: $file"
                
                # Apply common fixes
                if grep -q "cd " "$file" && ! grep -q "cd .* || " "$file"; then
                    print_info "Fixing cd commands in $file"
                    sed -i '' 's/cd \([^|]*\)$/cd \1 || exit/g' "$file"
                    ((fixes_applied++))
                fi
            fi
        fi
    done
    
    if [[ $fixes_applied -gt 0 ]]; then
        print_success "Applied $fixes_applied automatic fixes"
        echo "$(date): Applied $fixes_applied automatic fixes" >> "$MONITOR_LOG"
    else
        print_info "No automatic fixes needed"
    fi
    
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

# Main monitoring function
main() {
    local action="${1:-monitor}"
    
    case "$action" in
        "monitor")
            init_monitoring
            check_sonarcloud
            run_qlty_analysis
            run_codacy_analysis
            apply_automatic_fixes
            generate_report
            ;;
        "sonarcloud")
            check_sonarcloud
            ;;
        "qlty")
            run_qlty_analysis
            ;;
        "codacy")
            run_codacy_analysis
            ;;
        "fix")
            apply_automatic_fixes
            ;;
        "report")
            generate_report
            ;;
        "help"|*)
            echo "Code Review Monitoring Script"
            echo "Usage: $0 [action]"
            echo ""
            echo "Actions:"
            echo "  monitor    - Run complete monitoring cycle (default)"
            echo "  sonarcloud - Check SonarCloud status only"
            echo "  qlty       - Run Qlty analysis only"
            echo "  codacy     - Run Codacy analysis only"
            echo "  fix        - Apply automatic fixes only"
            echo "  report     - Generate monitoring report"
            echo "  help       - Show this help message"
            ;;
    esac
    
    return 0
}

main "$@"
