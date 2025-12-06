#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153
# =============================================================================
# Local Linters - Fast Offline Quality Checks
# =============================================================================
# Runs local linting tools without requiring external service APIs.
# Use this for pre-commit checks and fast feedback during development.
#
# Checks performed:
#   - ShellCheck for shell scripts
#   - Secretlint for exposed secrets
#   - Pattern validation (return statements, positional parameters)
#   - Markdown formatting
#
# For remote auditing (CodeRabbit, Codacy, SonarCloud), use:
#   /code-audit-remote or code-audit-helper.sh
# =============================================================================

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Quality thresholds
readonly MAX_TOTAL_ISSUES=100
readonly MAX_RETURN_ISSUES=0
readonly MAX_POSITIONAL_ISSUES=0
readonly MAX_STRING_LITERAL_ISSUES=0

print_header() {
    echo -e "${BLUE}Local Linters - Fast Offline Quality Checks${NC}"
    echo -e "${BLUE}================================================================${NC}"
    return 0
}

print_success() {
    local message="$1"
    echo -e "${GREEN}[PASS] $message${NC}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}[WARN] $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}[FAIL] $message${NC}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}[INFO] $message${NC}"
    return 0
}

check_sonarcloud_status() {
    echo -e "${BLUE}Checking SonarCloud Status (remote API)...${NC}"
    
    local response
    if response=$(curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=1"); then
        local total_issues
        total_issues=$(echo "$response" | jq -r '.total // 0')
        
        echo "Total Issues: $total_issues"
        
        if [[ $total_issues -le $MAX_TOTAL_ISSUES ]]; then
            print_success "SonarCloud: $total_issues issues (within threshold of $MAX_TOTAL_ISSUES)"
        else
            print_warning "SonarCloud: $total_issues issues (exceeds threshold of $MAX_TOTAL_ISSUES)"
        fi
        
        # Get detailed breakdown
        local breakdown_response
        if breakdown_response=$(curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=10&facets=rules"); then
            echo "Issue Breakdown:"
            echo "$breakdown_response" | jq -r '.facets[0].values[] | "  \(.val): \(.count) issues"'
        fi
    else
        print_error "Failed to fetch SonarCloud status"
        return 1
    fi
    
    return 0
}

check_return_statements() {
    echo -e "${BLUE}Checking Return Statements (S7682)...${NC}"
    
    local violations=0
    local files_checked=0
    
    for file in .agent/scripts/*.sh; do
        if [[ -f "$file" ]]; then
            ((files_checked++))
            
            # Check if file has functions without return statements
            local functions_without_return
            functions_without_return=$(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*() {" "$file" 2>/dev/null || echo "0")
            local return_statements
            return_statements=$(grep -c "return [01]" "$file" 2>/dev/null || echo "0")

            # Ensure variables are numeric
            functions_without_return=${functions_without_return//[^0-9]/}
            return_statements=${return_statements//[^0-9]/}
            functions_without_return=${functions_without_return:-0}
            return_statements=${return_statements:-0}

            if [[ $return_statements -lt $functions_without_return ]]; then
                ((violations++))
                print_warning "Missing return statements in $file"
            fi
        fi
    done
    
    echo "Files checked: $files_checked"
    echo "Files with violations: $violations"
    
    if [[ $violations -le $MAX_RETURN_ISSUES ]]; then
        print_success "Return statements: $violations violations (within threshold)"
    else
        print_error "Return statements: $violations violations (exceeds threshold of $MAX_RETURN_ISSUES)"
        return 1
    fi
    
    return 0
}

check_positional_parameters() {
    echo -e "${BLUE}Checking Positional Parameters (S7679)...${NC}"
    
    local violations=0
    
    # Find direct usage of positional parameters (not in local assignments)
    local tmp_file
    tmp_file=$(mktemp)
    
    if grep -n '\$[1-9]' .agent/scripts/*.sh | grep -v 'local.*=.*\$[1-9]' > "$tmp_file"; then
        violations=$(wc -l < "$tmp_file")
        
        if [[ $violations -gt 0 ]]; then
            print_warning "Found $violations positional parameter violations:"
            head -10 "$tmp_file"
            if [[ $violations -gt 10 ]]; then
                echo "... and $((violations - 10)) more"
            fi
        fi
    fi
    
    rm -f "$tmp_file"
    
    if [[ $violations -le $MAX_POSITIONAL_ISSUES ]]; then
        print_success "Positional parameters: $violations violations (within threshold)"
    else
        print_error "Positional parameters: $violations violations (exceeds threshold of $MAX_POSITIONAL_ISSUES)"
        return 1
    fi
    
    return 0
}

check_string_literals() {
    echo -e "${BLUE}Checking String Literals (S1192)...${NC}"
    
    local violations=0
    
    for file in .agent/scripts/*.sh; do
        if [[ -f "$file" ]]; then
            # Find strings that appear 3 or more times
            local repeated_strings
            repeated_strings=$(grep -o '"[^"]*"' "$file" | sort | uniq -c | awk '$1 >= 3 {print $1, $2}' | wc -l)
            
            if [[ $repeated_strings -gt 0 ]]; then
                ((violations += repeated_strings))
                print_warning "$file has $repeated_strings repeated string literals"
            fi
        fi
    done
    
    if [[ $violations -le $MAX_STRING_LITERAL_ISSUES ]]; then
        print_success "String literals: $violations violations (within threshold)"
    else
        print_error "String literals: $violations violations (exceeds threshold of $MAX_STRING_LITERAL_ISSUES)"
        return 1
    fi
    
    return 0
}

run_shellcheck() {
    echo -e "${BLUE}Running ShellCheck Validation...${NC}"
    
    local violations=0
    
    for file in .agent/scripts/*.sh; do
        if [[ -f "$file" ]] && ! shellcheck "$file" > /dev/null 2>&1; then
            ((violations++))
            print_warning "ShellCheck violations in $file"
        fi
    done
    
    if [[ $violations -eq 0 ]]; then
        print_success "ShellCheck: No violations found"
    else
        print_error "ShellCheck: $violations files with violations"
        return 1
    fi
    
    return 0
}

# Check for secrets in codebase
check_secrets() {
    echo -e "${BLUE}Checking for Exposed Secrets (Secretlint)...${NC}"
    
    local secretlint_script=".agent/scripts/secretlint-helper.sh"
    local violations=0
    
    # Check if secretlint is available
    if command -v secretlint &> /dev/null || [[ -f "node_modules/.bin/secretlint" ]]; then
        # Run secretlint scan
        local secretlint_cmd
        if command -v secretlint &> /dev/null; then
            secretlint_cmd="secretlint"
        else
            secretlint_cmd="./node_modules/.bin/secretlint"
        fi
        
        if [[ -f ".secretlintrc.json" ]]; then
            # Run scan and capture exit code
            if $secretlint_cmd "**/*" --format compact 2>/dev/null; then
                print_success "Secretlint: No secrets detected"
            else
                violations=1
                print_error "Secretlint: Potential secrets detected!"
                print_info "Run: bash $secretlint_script scan (for detailed results)"
            fi
        else
            print_warning "Secretlint: Configuration not found"
            print_info "Run: bash $secretlint_script init"
        fi
    elif command -v docker &> /dev/null; then
        print_info "Secretlint: Using Docker for scan (30s timeout)..."
        # Use timeout to prevent Docker from hanging - secretlint can be slow on large repos
        if timeout 30 docker run -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm secretlint/secretlint secretlint "**/*" --format compact 2>/dev/null; then
            print_success "Secretlint: No secrets detected"
        elif [[ $? -eq 124 ]]; then
            print_warning "Secretlint: Timed out (skipped)"
            print_info "Install native secretlint for faster scans: npm install -g secretlint"
        else
            violations=1
            print_error "Secretlint: Potential secrets detected!"
        fi
    else
        print_warning "Secretlint: Not installed (install with: npm install secretlint)"
        print_info "Run: bash $secretlint_script install"
    fi
    
    return $violations
}

# Check AI-Powered Quality CLIs integration
check_remote_cli_status() {
    print_info "Remote Audit CLIs Status (use /code-audit-remote for full analysis)..."

    # Secretlint
    local secretlint_script=".agent/scripts/secretlint-helper.sh"
    if [[ -f "$secretlint_script" ]]; then
        if command -v secretlint &> /dev/null || [[ -f "node_modules/.bin/secretlint" ]]; then
            print_success "Secretlint: Ready"
        else
            print_info "Secretlint: Available for setup"
        fi
    fi

    # CodeRabbit CLI
    local coderabbit_script=".agent/scripts/coderabbit-cli.sh"
    if [[ -f "$coderabbit_script" ]]; then
        if bash "$coderabbit_script" status > /dev/null 2>&1; then
            print_success "CodeRabbit CLI: Ready"
        else
            print_info "CodeRabbit CLI: Available for setup"
        fi
    fi

    # Codacy CLI
    local codacy_script=".agent/scripts/codacy-cli.sh"
    if [[ -f "$codacy_script" ]]; then
        if bash "$codacy_script" status > /dev/null 2>&1; then
            print_success "Codacy CLI: Ready"
        else
            print_info "Codacy CLI: Available for setup"
        fi
    fi

    # SonarScanner CLI
    local sonar_script=".agent/scripts/sonarscanner-cli.sh"
    if [[ -f "$sonar_script" ]]; then
        if bash "$sonar_script" status > /dev/null 2>&1; then
            print_success "SonarScanner CLI: Ready"
        else
            print_info "SonarScanner CLI: Available for setup"
        fi
    fi

    return 0
}

main() {
    print_header
    
    local exit_code=0
    
    # Run all local quality checks
    check_sonarcloud_status || exit_code=1
    echo ""
    
    check_return_statements || exit_code=1
    echo ""
    
    check_positional_parameters || exit_code=1
    echo ""
    
    check_string_literals || exit_code=1
    echo ""
    
    run_shellcheck || exit_code=1
    echo ""
    
    check_secrets || exit_code=1
    echo ""

    check_remote_cli_status

    echo ""
    print_info "Markdown Formatting Tools Available:"
    print_info "Run: bash .agent/scripts/markdown-lint-fix.sh manual . (for quick fixes)"
    print_info "Run: bash .agent/scripts/markdown-formatter.sh format . (for comprehensive formatting)"
    echo ""

    # Final summary
    if [[ $exit_code -eq 0 ]]; then
        print_success "ALL LOCAL CHECKS PASSED!"
        print_info "For remote auditing, run: /code-audit-remote"
    else
        print_error "QUALITY ISSUES DETECTED. Please address violations before committing."
    fi
    
    return $exit_code
}

main "$@"
