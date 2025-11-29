#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Test Stagehand Integration with AI DevOps Framework
# Comprehensive testing script for Stagehand setup and functionality

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/../../.agent/scripts/shared-constants.sh"

# Colors for output
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# Print functions
print_info() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    return 0
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    return 0
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    return 0
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    return 0
}

# Test configuration
readonly TEST_RESULTS_DIR="${HOME}/.agent/tmp/stagehand-tests"
readonly TEST_LOG="${TEST_RESULTS_DIR}/test-results.log"

# Create test directory
setup_test_environment() {
    mkdir -p "$TEST_RESULTS_DIR"
    echo "=== Stagehand Integration Test Started: $(date) ===" > "$TEST_LOG"
    print_info "Test environment created at: $TEST_RESULTS_DIR"
    return 0
}

# Test 1: Check if Stagehand helper exists and is executable
test_helper_script() {
    print_info "Testing Stagehand helper script..."
    
    local helper_script="${SCRIPT_DIR}/../../.agent/scripts/stagehand-helper.sh"
    
    if [[ -f "$helper_script" ]]; then
        print_success "✅ Stagehand helper script exists"
        echo "PASS: Helper script exists" >> "$TEST_LOG"
    else
        print_error "❌ Stagehand helper script not found"
        echo "FAIL: Helper script missing" >> "$TEST_LOG"
        return 1
    fi
    
    if [[ -x "$helper_script" ]]; then
        print_success "✅ Stagehand helper script is executable"
        echo "PASS: Helper script executable" >> "$TEST_LOG"
    else
        print_error "❌ Stagehand helper script is not executable"
        echo "FAIL: Helper script not executable" >> "$TEST_LOG"
        return 1
    fi
    
    return 0
}

# Test 2: Check if documentation exists
test_documentation() {
    print_info "Testing Stagehand documentation..."
    
    local docs=(
        "${SCRIPT_DIR}/../../.agent/STAGEHAND.md"
        "${SCRIPT_DIR}/../../.agent/mcp-examples/stagehand-automation-examples.md"
    )
    
    for doc in "${docs[@]}"; do
        if [[ -f "$doc" ]]; then
            print_success "✅ Documentation exists: $(basename "$doc")"
            echo "PASS: Documentation $(basename "$doc") exists" >> "$TEST_LOG"
        else
            print_error "❌ Documentation missing: $(basename "$doc")"
            echo "FAIL: Documentation $(basename "$doc") missing" >> "$TEST_LOG"
            return 1
        fi
    done
    
    return 0
}

# Test 3: Check MCP integration setup
test_mcp_integration() {
    print_info "Testing MCP integration setup..."
    
    local mcp_script="${SCRIPT_DIR}/setup-mcp-integrations.sh"
    
    if [[ -f "$mcp_script" ]]; then
        # Check if stagehand is in the MCP list
        if grep -q "stagehand" "$mcp_script"; then
            print_success "✅ Stagehand found in MCP integrations script"
            echo "PASS: Stagehand in MCP script" >> "$TEST_LOG"
        else
            print_error "❌ Stagehand not found in MCP integrations script"
            echo "FAIL: Stagehand not in MCP script" >> "$TEST_LOG"
            return 1
        fi
    else
        print_error "❌ MCP integrations script not found"
        echo "FAIL: MCP script missing" >> "$TEST_LOG"
        return 1
    fi
    
    return 0
}

# Test 4: Test helper script commands
test_helper_commands() {
    print_info "Testing Stagehand helper commands..."
    
    local helper_script="${SCRIPT_DIR}/../../.agent/scripts/stagehand-helper.sh"
    
    # Test help command
    if bash "$helper_script" help > /dev/null 2>&1; then
        print_success "✅ Help command works"
        echo "PASS: Help command" >> "$TEST_LOG"
    else
        print_error "❌ Help command failed"
        echo "FAIL: Help command" >> "$TEST_LOG"
        return 1
    fi
    
    # Test status command (should work even without installation)
    if bash "$helper_script" status > /dev/null 2>&1; then
        print_success "✅ Status command works"
        echo "PASS: Status command" >> "$TEST_LOG"
    else
        print_info "ℹ️  Status command indicates Stagehand not installed (expected)"
        echo "INFO: Status command - not installed" >> "$TEST_LOG"
    fi
    
    return 0
}

# Test 5: Check Node.js and npm availability
test_prerequisites() {
    print_info "Testing prerequisites..."
    
    if command -v node &> /dev/null; then
        local node_version
        node_version=$(node --version)
        print_success "✅ Node.js available: $node_version"
        echo "PASS: Node.js $node_version" >> "$TEST_LOG"
    else
        print_error "❌ Node.js not found (required for Stagehand)"
        echo "FAIL: Node.js missing" >> "$TEST_LOG"
        return 1
    fi
    
    if command -v npm &> /dev/null; then
        local npm_version
        npm_version=$(npm --version)
        print_success "✅ npm available: $npm_version"
        echo "PASS: npm $npm_version" >> "$TEST_LOG"
    else
        print_error "❌ npm not found (required for Stagehand)"
        echo "FAIL: npm missing" >> "$TEST_LOG"
        return 1
    fi
    
    return 0
}

# Test 6: Validate example scripts
test_example_scripts() {
    print_info "Testing example script templates..."
    
    local setup_script="${SCRIPT_DIR}/stagehand-setup.sh"
    
    if [[ -f "$setup_script" ]]; then
        print_success "✅ Stagehand setup script exists"
        echo "PASS: Setup script exists" >> "$TEST_LOG"
        
        if [[ -x "$setup_script" ]]; then
            print_success "✅ Setup script is executable"
            echo "PASS: Setup script executable" >> "$TEST_LOG"
        else
            print_error "❌ Setup script is not executable"
            echo "FAIL: Setup script not executable" >> "$TEST_LOG"
            return 1
        fi
    else
        print_error "❌ Stagehand setup script not found"
        echo "FAIL: Setup script missing" >> "$TEST_LOG"
        return 1
    fi
    
    return 0
}

# Generate test report
generate_report() {
    print_info "Generating test report..."
    
    local report_file="${TEST_RESULTS_DIR}/integration-test-report.md"
    
    cat > "$report_file" << EOF
# Stagehand Integration Test Report

**Test Date**: $(date)
**Framework Version**: $(bash "${SCRIPT_DIR}/version-manager.sh" get 2>/dev/null || echo "Unknown")

## Test Results

$(cat "$TEST_LOG")

## Summary

- **Helper Script**: $(grep -c "PASS.*Helper" "$TEST_LOG" || echo 0) tests passed
- **Documentation**: $(grep -c "PASS.*Documentation" "$TEST_LOG" || echo 0) tests passed  
- **MCP Integration**: $(grep -c "PASS.*MCP" "$TEST_LOG" || echo 0) tests passed
- **Prerequisites**: $(grep -c "PASS.*Node\|PASS.*npm" "$TEST_LOG" || echo 0) tests passed
- **Commands**: $(grep -c "PASS.*command" "$TEST_LOG" || echo 0) tests passed

## Next Steps

1. Run full installation: \`bash .agent/scripts/stagehand-helper.sh setup\`
2. Test MCP integration: \`bash .agent/scripts/setup-mcp-integrations.sh stagehand\`
3. Try examples: \`cd ~/.aidevops/stagehand && npm run search-products\` || exit

## Files Created

- Test results: $TEST_LOG
- This report: $report_file
EOF

    print_success "Test report generated: $report_file"
    return 0
}

# Main test function
main() {
    local command="${1:-all}"
    
    case "$command" in
        "all")
            setup_test_environment
            test_helper_script
            test_documentation
            test_mcp_integration
            test_helper_commands
            test_prerequisites
            test_example_scripts
            generate_report
            print_success "All integration tests completed!"
            ;;
        "helper")
            setup_test_environment && test_helper_script
            ;;
        "docs")
            setup_test_environment && test_documentation
            ;;
        "mcp")
            setup_test_environment && test_mcp_integration
            ;;
        "prereqs")
            setup_test_environment && test_prerequisites
            ;;
        "help")
            cat << EOF
Stagehand Integration Test Script

USAGE:
    $0 [COMMAND]

COMMANDS:
    all         Run all tests (default)
    helper      Test helper script only
    docs        Test documentation only
    mcp         Test MCP integration only
    prereqs     Test prerequisites only
    help        Show this help

EOF
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            return 1
            ;;
    esac
    
    return 0
}

# Execute main function
main "$@"
