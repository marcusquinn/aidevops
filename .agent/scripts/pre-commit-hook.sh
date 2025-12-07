#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153
# Pre-commit hook for multi-platform quality validation
# Install with: cp .agent/scripts/pre-commit-hook.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

print_success() {
    local message="$1"
    echo -e "${GREEN}✅ $message${NC}"
    return 0
}

print_warning() {
    local message="$1"
    echo -e "${YELLOW}⚠️  $message${NC}"
    return 0
}

print_error() {
    local message="$1"
    echo -e "${RED}❌ $message${NC}"
    return 0
}

print_info() {
    local message="$1"
    echo -e "${BLUE}ℹ️  $message${NC}"
    return 0
}

# Get list of modified shell files
get_modified_shell_files() {
    git diff --cached --name-only --diff-filter=ACM | grep '\.sh$' || true
    return 0
}

validate_return_statements() {
    local violations=0
    
    print_info "Validating return statements..."
    
    for file in "$@"; do
        if [[ -f "$file" ]]; then
            # Check for functions without return statements
            local functions
            functions=$(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*() {" "$file" || echo "0")
            local returns
            returns=$(grep -c "return [01]" "$file" || echo "0")
            
            if [[ $functions -gt 0 && $returns -lt $functions ]]; then
                print_error "Missing return statements in $file"
                ((violations++))
            fi
        fi
    done
    
    return $violations
}

validate_positional_parameters() {
    local violations=0

    print_info "Validating positional parameters..."

    for file in "$@"; do
        if [[ -f "$file" ]] && grep -n '\$[1-9]' "$file" | grep -v 'local.*=.*\$[1-9]' > /dev/null; then
            print_error "Direct positional parameter usage in $file"
            grep -n '\$[1-9]' "$file" | grep -v 'local.*=.*\$[1-9]' | head -3
            ((violations++))
        fi
    done
    
    return $violations
}

validate_string_literals() {
    local violations=0

    print_info "Validating string literals..."

    for file in "$@"; do
        if [[ -f "$file" ]]; then
            # Check for repeated string literals
            local repeated
            repeated=$(grep -o '"[^"]*"' "$file" | sort | uniq -c | awk '$1 >= 3' | wc -l || echo "0")
            
            if [[ $repeated -gt 0 ]]; then
                print_warning "Repeated string literals in $file (consider using constants)"
                grep -o '"[^"]*"' "$file" | sort | uniq -c | awk '$1 >= 3 {print "  " $1 "x: " $2}' | head -3
                ((violations++))
            fi
        fi
    done
    
    return $violations
}

run_shellcheck() {
    local violations=0

    print_info "Running ShellCheck validation..."

    for file in "$@"; do
        if [[ -f "$file" ]] && ! shellcheck "$file"; then
            print_error "ShellCheck violations in $file"
            ((violations++))
        fi
    done
    
    return $violations
}

check_secrets() {
    local violations=0
    
    print_info "Checking for exposed secrets (Secretlint)..."
    
    # Get staged files
    local staged_files
    staged_files=$(git diff --cached --name-only --diff-filter=ACMR | tr '\n' ' ')
    
    if [[ -z "$staged_files" ]]; then
        print_info "No files to check for secrets"
        return 0
    fi
    
    # Check if secretlint is available
    if command -v secretlint &> /dev/null; then
        if echo "$staged_files" | xargs secretlint --format compact 2>/dev/null; then
            print_success "No secrets detected in staged files"
        else
            print_error "Potential secrets detected in staged files!"
            print_info "Review the findings and either:"
            print_info "  1. Remove the secrets from your code"
            print_info "  2. Add to .secretlintignore if false positive"
            print_info "  3. Use // secretlint-disable-line comment"
            ((violations++))
        fi
    elif [[ -f "node_modules/.bin/secretlint" ]]; then
        if echo "$staged_files" | xargs ./node_modules/.bin/secretlint --format compact 2>/dev/null; then
            print_success "No secrets detected in staged files"
        else
            print_error "Potential secrets detected in staged files!"
            ((violations++))
        fi
    elif command -v npx &> /dev/null && [[ -f ".secretlintrc.json" ]]; then
        if echo "$staged_files" | xargs npx secretlint --format compact 2>/dev/null; then
            print_success "No secrets detected in staged files"
        else
            print_error "Potential secrets detected in staged files!"
            ((violations++))
        fi
    else
        print_warning "Secretlint not available (install: npm install secretlint --save-dev)"
    fi
    
    return $violations
}

check_quality_standards() {
    print_info "Checking current quality standards..."
    
    # Check SonarCloud status if curl is available
    if command -v curl &> /dev/null && command -v jq &> /dev/null; then
        local response
        if response=$(curl -s --max-time 10 "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=1" 2>/dev/null); then
            local total_issues
            total_issues=$(echo "$response" | jq -r '.total // 0' 2>/dev/null || echo "unknown")

            if [[ "$total_issues" != "unknown" ]]; then
                print_info "Current SonarCloud issues: $total_issues"

                if [[ $total_issues -gt 200 ]]; then
                    print_warning "High issue count detected. Consider running quality fixes."
                fi
            fi
        fi
    fi
    return 0
}

main() {
    echo -e "${BLUE}🎯 Pre-commit Quality Validation${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # Get modified shell files
    local modified_files
    mapfile -t modified_files < <(get_modified_shell_files)
    
    if [[ ${#modified_files[@]} -eq 0 ]]; then
        print_info "No shell files modified, skipping quality checks"
        return 0
    fi
    
    print_info "Checking ${#modified_files[@]} modified shell files:"
    printf '  %s\n' "${modified_files[@]}"
    echo ""
    
    local total_violations=0
    
    # Run validation checks
    validate_return_statements "${modified_files[@]}" || ((total_violations += $?))
    echo ""
    
    validate_positional_parameters "${modified_files[@]}" || ((total_violations += $?))
    echo ""
    
    validate_string_literals "${modified_files[@]}" || ((total_violations += $?))
    echo ""
    
    run_shellcheck "${modified_files[@]}" || ((total_violations += $?))
    echo ""
    
    check_secrets || ((total_violations += $?))
    echo ""
    
    check_quality_standards
    echo ""

    # Optional CodeRabbit CLI review (if available)
    if [[ -f ".agent/scripts/coderabbit-cli.sh" ]] && command -v coderabbit &> /dev/null; then
        print_info "🤖 Running CodeRabbit CLI review..."
        if bash .agent/scripts/coderabbit-cli.sh review > /dev/null 2>&1; then
            print_success "CodeRabbit CLI review completed"
        else
            print_info "CodeRabbit CLI review skipped (setup required)"
        fi
        echo ""
    fi

    # Final decision
    if [[ $total_violations -eq 0 ]]; then
        print_success "🎉 All quality checks passed! Commit approved."
        return 0
    else
        print_error "❌ Quality violations detected ($total_violations total)"
        echo ""
        print_info "To fix issues automatically, run:"
        print_info "  ./.agent/scripts/quality-fix.sh"
        echo ""
        print_info "To check current status, run:"
        print_info "  ./.agent/scripts/linters-local.sh"
        echo ""
        print_info "To bypass this check (not recommended), use:"
        print_info "  git commit --no-verify"

        return 1
    fi
}

main "$@"
