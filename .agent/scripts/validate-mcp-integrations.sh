#!/bin/bash

# 🔍 MCP Integrations Validation Script
# Validates and tests all MCP integrations for proper functionality

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

print_header() { echo -e "${PURPLE}🔍 $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# Test results tracking
declare -i total_tests=0
declare -i passed_tests=0
declare -i failed_tests=0

# Test function wrapper
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    ((total_tests++))
    print_info "Testing: $test_name"
    
    if eval "$test_command" &>/dev/null; then
        print_success "$test_name: PASSED"
        ((passed_tests++))
        return 0
    else
        print_error "$test_name: FAILED"
        ((failed_tests++))
        return 1
    fi
}

# Test Node.js and npm
test_prerequisites() {
    print_header "Testing Prerequisites"
    
    run_test "Node.js availability" "command -v node"
    run_test "npm availability" "command -v npm"
    
    if command -v node &>/dev/null; then
        local node_version
        node_version=$(node --version)
        print_info "Node.js version: $node_version"
    fi
    
    if command -v npm &>/dev/null; then
        local npm_version
        npm_version=$(npm --version)
        print_info "npm version: $npm_version"
    fi
    return 0
}

# Test Chrome DevTools MCP
test_chrome_devtools() {
    print_header "Testing Chrome DevTools MCP"
    
    run_test "Chrome DevTools MCP package" "npm list -g chrome-devtools-mcp || npm info chrome-devtools-mcp"
    
    # Test Chrome availability
    local chrome_paths=(
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
        "/usr/bin/google-chrome"
        "/usr/bin/google-chrome-stable"
        "/usr/bin/chromium-browser"
    )
    
    local chrome_found=false
    for chrome_path in "${chrome_paths[@]}"; do
        if [[ -x "$chrome_path" ]]; then
            print_success "Chrome found: $chrome_path"
            chrome_found=true
            break
        fi
    done
    
    if [[ "$chrome_found" == false ]]; then
        print_warning "Chrome not found in standard locations"
    fi
    return 0
}

# Test Playwright MCP
test_playwright() {
    print_header "Testing Playwright MCP"
    
    run_test "Playwright MCP package" "npm list -g playwright-mcp || npm info playwright-mcp"
    run_test "Playwright package" "npm list -g playwright || npm info playwright"
    
    # Test browser installations
    if command -v npx &>/dev/null; then
        print_info "Checking Playwright browser installations..."
        if npx playwright --version &>/dev/null; then
            print_success "Playwright CLI available"
        else
            print_warning "Playwright CLI not available"
        fi
    fi
    return 0
}

# Test API connectivity
test_api_connectivity() {
    print_header "Testing API Connectivity"
    
    # Test Ahrefs API
    if [[ -n "${AHREFS_API_KEY:-}" ]]; then
        run_test "Ahrefs API connectivity" "curl -s -H 'Authorization: Bearer $AHREFS_API_KEY' https://apiv2.ahrefs.com/v2/subscription_info"
        print_success "Ahrefs API key configured"
    else
        print_warning "Ahrefs API key not configured (AHREFS_API_KEY)"
    fi
    
    # Test Perplexity API
    if [[ -n "${PERPLEXITY_API_KEY:-}" ]]; then
        run_test "Perplexity API connectivity" "curl -s -H 'Authorization: Bearer $PERPLEXITY_API_KEY' https://api.perplexity.ai/chat/completions"
        print_success "Perplexity API key configured"
    else
        print_warning "Perplexity API key not configured (PERPLEXITY_API_KEY)"
    fi
    
    # Test Cloudflare API
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
        run_test "Cloudflare API connectivity" "curl -s -H 'Authorization: Bearer $CLOUDFLARE_API_TOKEN' https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID"
        print_success "Cloudflare API credentials configured"
    else
        print_warning "Cloudflare API credentials not configured (CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID)"
    fi
    return 0
}

# Test MCP configurations
test_mcp_configurations() {
    print_header "Testing MCP Configurations"
    
    local config_dir="configs/mcp-templates"
    
    if [[ -d "$config_dir" ]]; then
        print_success "MCP templates directory exists"
        
        # Test each configuration file
        for config_file in "$config_dir"/*.json; do
            if [[ -f "$config_file" ]]; then
                local filename
                filename=$(basename "$config_file")
                run_test "JSON validation: $filename" "python3 -m json.tool '$config_file'"
            fi
        done
    else
        print_error "MCP templates directory not found: $config_dir"
    fi
    return 0
}

# Test network connectivity
test_network() {
    print_header "Testing Network Connectivity"
    
    run_test "Internet connectivity" "curl -s --connect-timeout 5 https://www.google.com"
    run_test "npm registry" "curl -s --connect-timeout 5 https://registry.npmjs.org/"
    run_test "GitHub connectivity" "curl -s --connect-timeout 5 https://api.github.com"
    return 0
}

# Generate validation report
generate_report() {
    print_header "Validation Report"
    
    echo
    print_info "Total tests run: $total_tests"
    print_success "Tests passed: $passed_tests"
    
    if [[ $failed_tests -gt 0 ]]; then
        print_error "Tests failed: $failed_tests"
    else
        print_success "Tests failed: $failed_tests"
    fi
    
    echo
    local success_rate
    success_rate=$((passed_tests * 100 / total_tests))
    
    if [[ $success_rate -ge 90 ]]; then
        print_success "Overall status: EXCELLENT ($success_rate% success rate)"
    elif [[ $success_rate -ge 75 ]]; then
        print_success "Overall status: GOOD ($success_rate% success rate)"
    elif [[ $success_rate -ge 50 ]]; then
        print_warning "Overall status: NEEDS ATTENTION ($success_rate% success rate)"
    else
        print_error "Overall status: CRITICAL ISSUES ($success_rate% success rate)"
    fi
    
    echo
    if [[ $failed_tests -gt 0 ]]; then
        print_info "Next steps:"
        print_info "1. Review failed tests above"
        print_info "2. Check docs/MCP-TROUBLESHOOTING.md for solutions"
        print_info "3. Run setup script: bash .agent/scripts/setup-mcp-integrations.sh"
        print_info "4. Configure missing API keys"
    else
        print_success "All MCP integrations are ready to use!"
        print_info "Check docs/MCP-INTEGRATIONS.md for usage examples"
    fi
    return 0
}

# Main validation function
main() {
    print_header "MCP Integrations Validation"
    echo
    
    test_prerequisites
    echo
    
    test_network
    echo
    
    test_chrome_devtools
    echo
    
    test_playwright
    echo
    
    test_api_connectivity
    echo
    
    test_mcp_configurations
    echo
    
    generate_report
    return 0
}

main "$@"
