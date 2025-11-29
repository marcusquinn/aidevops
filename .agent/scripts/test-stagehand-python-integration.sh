#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Test Stagehand Python Integration with AI DevOps Framework
# Comprehensive testing script for Stagehand Python setup and functionality

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
readonly TEST_RESULTS_DIR="${HOME}/.agent/tmp/stagehand-python-tests"
readonly TEST_LOG="${TEST_RESULTS_DIR}/test-results.log"

# Create test directory
setup_test_environment() {
    mkdir -p "$TEST_RESULTS_DIR"
    echo "=== Stagehand Python Integration Test Started: $(date) ===" > "$TEST_LOG"
    print_info "Test environment created at: $TEST_RESULTS_DIR"
    return 0
}

# Test 1: Check if Stagehand Python helper exists and is executable
test_python_helper_script() {
    print_info "Testing Stagehand Python helper script..."
    
    local helper_script="${SCRIPT_DIR}/../../.agent/scripts/stagehand-python-helper.sh"
    
    if [[ -f "$helper_script" ]]; then
        print_success "✅ Stagehand Python helper script exists"
        echo "PASS: Python helper script exists" >> "$TEST_LOG"
    else
        print_error "❌ Stagehand Python helper script not found"
        echo "FAIL: Python helper script missing" >> "$TEST_LOG"
        return 1
    fi
    
    if [[ -x "$helper_script" ]]; then
        print_success "✅ Stagehand Python helper script is executable"
        echo "PASS: Python helper script executable" >> "$TEST_LOG"
    else
        print_error "❌ Stagehand Python helper script is not executable"
        echo "FAIL: Python helper script not executable" >> "$TEST_LOG"
        return 1
    fi
    
    return 0
}

# Test 2: Check if Python documentation exists
test_python_documentation() {
    print_info "Testing Stagehand Python documentation..."
    
    local docs=(
        "${SCRIPT_DIR}/../../.agent/STAGEHAND-PYTHON.md"
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

# Test 3: Check Python requirements
test_python_requirements() {
    print_info "Testing Python requirements..."
    
    # Check Python 3.8+
    if command -v python3 &> /dev/null; then
        local python_version
        python_version=$(python3 --version | cut -d' ' -f2)
        local major minor
        major=$(echo "$python_version" | cut -d'.' -f1)
        minor=$(echo "$python_version" | cut -d'.' -f2)
        
        if [[ "$major" -ge 3 ]] && [[ "$minor" -ge 8 ]]; then
            print_success "✅ Python version compatible: $python_version"
            echo "PASS: Python $python_version compatible" >> "$TEST_LOG"
        else
            print_error "❌ Python version incompatible: $python_version (need 3.8+)"
            echo "FAIL: Python version incompatible" >> "$TEST_LOG"
            return 1
        fi
    else
        print_error "❌ Python 3 not found"
        echo "FAIL: Python 3 missing" >> "$TEST_LOG"
        return 1
    fi
    
    # Check pip3
    if command -v pip3 &> /dev/null; then
        local pip_version
        pip_version=$(pip3 --version | cut -d' ' -f2)
        print_success "✅ pip3 available: $pip_version"
        echo "PASS: pip3 $pip_version available" >> "$TEST_LOG"
    else
        print_error "❌ pip3 not found"
        echo "FAIL: pip3 missing" >> "$TEST_LOG"
        return 1
    fi
    
    # Check for uv (optional but recommended)
    if command -v uv &> /dev/null; then
        local uv_version
        uv_version=$(uv --version | cut -d' ' -f2)
        print_success "✅ uv available: $uv_version (recommended)"
        echo "PASS: uv $uv_version available" >> "$TEST_LOG"
    else
        print_info "ℹ️  uv not found (optional but recommended for faster installs)"
        echo "INFO: uv not available (optional)" >> "$TEST_LOG"
    fi
    
    return 0
}

# Test 4: Check MCP integration setup
test_python_mcp_integration() {
    print_info "Testing Python MCP integration setup..."
    
    local mcp_script="${SCRIPT_DIR}/setup-mcp-integrations.sh"
    
    if [[ -f "$mcp_script" ]]; then
        # Check if stagehand-python is in the MCP list
        if grep -q "stagehand-python" "$mcp_script"; then
            print_success "✅ Stagehand Python found in MCP integrations script"
            echo "PASS: Stagehand Python in MCP script" >> "$TEST_LOG"
        else
            print_error "❌ Stagehand Python not found in MCP integrations script"
            echo "FAIL: Stagehand Python not in MCP script" >> "$TEST_LOG"
            return 1
        fi
        
        # Check if stagehand-both is in the MCP list
        if grep -q "stagehand-both" "$mcp_script"; then
            print_success "✅ Stagehand Both found in MCP integrations script"
            echo "PASS: Stagehand Both in MCP script" >> "$TEST_LOG"
        else
            print_error "❌ Stagehand Both not found in MCP integrations script"
            echo "FAIL: Stagehand Both not in MCP script" >> "$TEST_LOG"
            return 1
        fi
    else
        print_error "❌ MCP integrations script not found"
        echo "FAIL: MCP script missing" >> "$TEST_LOG"
        return 1
    fi
    
    return 0
}

# Test 5: Test Python helper script commands
test_python_helper_commands() {
    print_info "Testing Stagehand Python helper commands..."
    
    local helper_script="${SCRIPT_DIR}/../../.agent/scripts/stagehand-python-helper.sh"
    
    # Test help command
    if bash "$helper_script" help > /dev/null 2>&1; then
        print_success "✅ Python help command works"
        echo "PASS: Python help command" >> "$TEST_LOG"
    else
        print_error "❌ Python help command failed"
        echo "FAIL: Python help command" >> "$TEST_LOG"
        return 1
    fi
    
    # Test status command (should work even without installation)
    if bash "$helper_script" status > /dev/null 2>&1; then
        print_success "✅ Python status command works"
        echo "PASS: Python status command" >> "$TEST_LOG"
    else
        print_info "ℹ️  Python status command indicates Stagehand Python not installed (expected)"
        echo "INFO: Python status command - not installed" >> "$TEST_LOG"
    fi
    
    return 0
}

# Test 6: Validate Python setup scripts
test_python_setup_scripts() {
    print_info "Testing Python setup script templates..."
    
    local setup_script="${SCRIPT_DIR}/stagehand-python-setup.sh"
    
    if [[ -f "$setup_script" ]]; then
        print_success "✅ Stagehand Python setup script exists"
        echo "PASS: Python setup script exists" >> "$TEST_LOG"
        
        if [[ -x "$setup_script" ]]; then
            print_success "✅ Python setup script is executable"
            echo "PASS: Python setup script executable" >> "$TEST_LOG"
        else
            print_error "❌ Python setup script is not executable"
            echo "FAIL: Python setup script not executable" >> "$TEST_LOG"
            return 1
        fi
    else
        print_error "❌ Stagehand Python setup script not found"
        echo "FAIL: Python setup script missing" >> "$TEST_LOG"
        return 1
    fi
    
    return 0
}

# Generate test report
generate_python_report() {
    print_info "Generating Python test report..."
    
    local report_file="${TEST_RESULTS_DIR}/python-integration-test-report.md"
    
    cat > "$report_file" << EOF
# Stagehand Python Integration Test Report

**Test Date**: $(date)
**Framework Version**: $(bash "${SCRIPT_DIR}/version-manager.sh" get 2>/dev/null || echo "Unknown")

## Test Results

$(cat "$TEST_LOG")

## Summary

- **Python Helper Script**: $(grep -c "PASS.*Python.*helper" "$TEST_LOG" || echo 0) tests passed
- **Documentation**: $(grep -c "PASS.*Documentation" "$TEST_LOG" || echo 0) tests passed  
- **Python Requirements**: $(grep -c "PASS.*Python\|PASS.*pip" "$TEST_LOG" || echo 0) tests passed
- **MCP Integration**: $(grep -c "PASS.*MCP" "$TEST_LOG" || echo 0) tests passed
- **Commands**: $(grep -c "PASS.*command" "$TEST_LOG" || echo 0) tests passed

## Next Steps

1. Run full installation: \`bash .agent/scripts/stagehand-python-helper.sh setup\`
2. Test MCP integration: \`bash .agent/scripts/setup-mcp-integrations.sh stagehand-python\`
3. Try examples: \`source ~/.aidevops/stagehand-python/.venv/bin/activate && python examples/basic_example.py\`

## Files Created

- Test results: $TEST_LOG
- This report: $report_file
EOF

    print_success "Python test report generated: $report_file"
    return 0
}

# Main test function
main() {
    local command="${1:-all}"
    
    case "$command" in
        "all")
            setup_test_environment
            test_python_helper_script
            test_python_documentation
            test_python_requirements
            test_python_mcp_integration
            test_python_helper_commands
            test_python_setup_scripts
            generate_python_report
            print_success "All Python integration tests completed!"
            ;;
        "helper")
            setup_test_environment && test_python_helper_script
            ;;
        "docs")
            setup_test_environment && test_python_documentation
            ;;
        "requirements")
            setup_test_environment && test_python_requirements
            ;;
        "mcp")
            setup_test_environment && test_python_mcp_integration
            ;;
        "help")
            cat << EOF
Stagehand Python Integration Test Script

USAGE:
    $0 [COMMAND]

COMMANDS:
    all             Run all tests (default)
    helper          Test helper script only
    docs            Test documentation only
    requirements    Test Python requirements only
    mcp             Test MCP integration only
    help            Show this help

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
