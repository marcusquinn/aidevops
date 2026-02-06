#!/bin/bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329,SC2016,SC2181,SC1091,SC2154,SC2015,SC2086,SC2129,SC2030,SC2031,SC2119,SC2120,SC2001,SC2162,SC2088,SC2089,SC2090,SC2029,SC2006,SC2153

# Test Both Stagehand JavaScript and Python Integration
# Comprehensive testing script for both Stagehand versions

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
readonly TEST_RESULTS_DIR="${HOME}/.agent/tmp/stagehand-both-tests"
readonly TEST_LOG="${TEST_RESULTS_DIR}/test-results.log"

# Create test directory
setup_test_environment() {
    mkdir -p "$TEST_RESULTS_DIR"
    echo "=== Stagehand Both (JS + Python) Integration Test Started: $(date) ===" > "$TEST_LOG"
    print_info "Test environment created at: $TEST_RESULTS_DIR"
    return 0
}

# Test JavaScript integration
test_javascript_integration() {
    print_info "Testing JavaScript integration..."
    
    if bash "${SCRIPT_DIR}/test-stagehand-integration.sh" all > "${TEST_RESULTS_DIR}/js-test.log" 2>&1; then
        print_success "✅ JavaScript integration tests passed"
        echo "PASS: JavaScript integration" >> "$TEST_LOG"
        return 0
    else
        print_error "❌ JavaScript integration tests failed"
        echo "FAIL: JavaScript integration" >> "$TEST_LOG"
        return 1
    fi
    return 0
}

# Test Python integration
test_python_integration() {
    print_info "Testing Python integration..."
    
    if bash "${SCRIPT_DIR}/test-stagehand-python-integration.sh" all > "${TEST_RESULTS_DIR}/python-test.log" 2>&1; then
        print_success "✅ Python integration tests passed"
        echo "PASS: Python integration" >> "$TEST_LOG"
        return 0
    else
        print_error "❌ Python integration tests failed"
        echo "FAIL: Python integration" >> "$TEST_LOG"
        return 1
    fi
    return 0
}

# Test MCP integration for both
test_both_mcp_integration() {
    print_info "Testing MCP integration for both versions..."
    
    local mcp_script="${SCRIPT_DIR}/setup-mcp-integrations.sh"
    
    if [[ -f "$mcp_script" ]]; then
        # Check if all Stagehand options are available
        local stagehand_options=("stagehand" "stagehand-python" "stagehand-both")
        local all_found=true
        
        for option in "${stagehand_options[@]}"; do
            if grep -q "$option" "$mcp_script"; then
                print_success "✅ MCP option '$option' found"
                echo "PASS: MCP option $option found" >> "$TEST_LOG"
            else
                print_error "❌ MCP option '$option' not found"
                echo "FAIL: MCP option $option missing" >> "$TEST_LOG"
                all_found=false
            fi
        done
        
        if $all_found; then
            return 0
        else
            return 1
        fi
    else
        print_error "❌ MCP integrations script not found"
        echo "FAIL: MCP script missing" >> "$TEST_LOG"
        return 1
    fi
    return 0
}

# Test documentation completeness
test_documentation_completeness() {
    print_info "Testing documentation completeness..."
    
    local docs=(
        "${SCRIPT_DIR}/../../.agent/STAGEHAND.md"
        "${SCRIPT_DIR}/../../.agent/STAGEHAND-PYTHON.md"
        "${SCRIPT_DIR}/../../.agent/BROWSER-AUTOMATION.md"
        "${SCRIPT_DIR}/../../README.md"
    )
    
    local all_found=true
    
    for doc in "${docs[@]}"; do
        if [[ -f "$doc" ]]; then
            # Check if the document mentions both versions
            if grep -q -i "javascript\|python" "$doc"; then
                print_success "✅ Documentation complete: $(basename "$doc")"
                echo "PASS: Documentation $(basename "$doc") complete" >> "$TEST_LOG"
            else
                print_warning "⚠️  Documentation may be incomplete: $(basename "$doc")"
                echo "WARN: Documentation $(basename "$doc") may be incomplete" >> "$TEST_LOG"
            fi
        else
            print_error "❌ Documentation missing: $(basename "$doc")"
            echo "FAIL: Documentation $(basename "$doc") missing" >> "$TEST_LOG"
            all_found=false
        fi
    done
    
    if $all_found; then
        return 0
    else
        return 1
    fi
    return 0
}

# Test helper script consistency
test_helper_consistency() {
    print_info "Testing helper script consistency..."
    
    local js_helper="${SCRIPT_DIR}/../../.agent/scripts/stagehand-helper.sh"
    local python_helper="${SCRIPT_DIR}/../../.agent/scripts/stagehand-python-helper.sh"
    
    if [[ -f "$js_helper" ]] && [[ -f "$python_helper" ]]; then
        # Check if both have similar command structure
        local js_commands python_commands
        js_commands=$(bash "$js_helper" help 2>/dev/null | grep -E "^\s+[a-z-]+\s+" | awk '{print $_arg1}' | sort)
        python_commands=$(bash "$python_helper" help 2>/dev/null | grep -E "^\s+[a-z-]+\s+" | awk '{print $_arg1}' | sort)
        
        # Check for common commands
        local common_commands=("help" "install" "setup" "status" "clean")
        local all_consistent=true
        
        for cmd in "${common_commands[@]}"; do
            if echo "$js_commands" | grep -q "^$cmd$" && echo "$python_commands" | grep -q "^$cmd$"; then
                print_success "✅ Command '$cmd' available in both helpers"
                echo "PASS: Command $cmd consistent" >> "$TEST_LOG"
            else
                print_error "❌ Command '$cmd' not consistent between helpers"
                echo "FAIL: Command $cmd inconsistent" >> "$TEST_LOG"
                all_consistent=false
            fi
        done
        
        if $all_consistent; then
            return 0
        else
            return 1
        fi
    else
        print_error "❌ One or both helper scripts missing"
        echo "FAIL: Helper scripts missing" >> "$TEST_LOG"
        return 1
    fi
    return 0
}

# Generate comprehensive test report
generate_comprehensive_report() {
    print_info "Generating comprehensive test report..."
    
    local report_file="${TEST_RESULTS_DIR}/comprehensive-integration-test-report.md"
    
    cat > "$report_file" << EOF
# Stagehand Comprehensive Integration Test Report

**Test Date**: $(date)
**Framework Version**: $(bash "${SCRIPT_DIR}/version-manager.sh" get 2>/dev/null || echo "Unknown")
**Tested Versions**: JavaScript + Python

## Test Results Summary

$(cat "$TEST_LOG")

## Detailed Test Results

### JavaScript Integration
$(if [[ -f "${TEST_RESULTS_DIR}/js-test.log" ]]; then echo "See: js-test.log"; else echo "No detailed log available"; fi)

### Python Integration
$(if [[ -f "${TEST_RESULTS_DIR}/python-test.log" ]]; then echo "See: python-test.log"; else echo "No detailed log available"; fi)

## Summary Statistics

- **JavaScript Tests**: $(grep -c "PASS.*JavaScript" "$TEST_LOG" || echo 0) passed, $(grep -c "FAIL.*JavaScript" "$TEST_LOG" || echo 0) failed
- **Python Tests**: $(grep -c "PASS.*Python" "$TEST_LOG" || echo 0) passed, $(grep -c "FAIL.*Python" "$TEST_LOG" || echo 0) failed
- **MCP Integration**: $(grep -c "PASS.*MCP" "$TEST_LOG" || echo 0) passed, $(grep -c "FAIL.*MCP" "$TEST_LOG" || echo 0) failed
- **Documentation**: $(grep -c "PASS.*Documentation" "$TEST_LOG" || echo 0) passed, $(grep -c "FAIL.*Documentation" "$TEST_LOG" || echo 0) failed
- **Helper Consistency**: $(grep -c "PASS.*Command" "$TEST_LOG" || echo 0) passed, $(grep -c "FAIL.*Command" "$TEST_LOG" || echo 0) failed

## Next Steps

### JavaScript Setup
1. Run: \`bash .agent/scripts/stagehand-helper.sh setup\`
2. Test: \`bash .agent/scripts/setup-mcp-integrations.sh stagehand\`

### Python Setup
1. Run: \`bash .agent/scripts/stagehand-python-helper.sh setup\`
2. Test: \`bash .agent/scripts/setup-mcp-integrations.sh stagehand-python\`

### Both Versions
1. Run: \`bash .agent/scripts/setup-mcp-integrations.sh stagehand-both\`

## Files Created

- Test results: $TEST_LOG
- JavaScript detailed log: ${TEST_RESULTS_DIR}/js-test.log
- Python detailed log: ${TEST_RESULTS_DIR}/python-test.log
- This report: $report_file
EOF

    print_success "Comprehensive test report generated: $report_file"
    return 0
}

# Main test function
main() {
    local command="${1:-all}"
    
    case "$command" in
        "all")
            setup_test_environment
            test_javascript_integration
            test_python_integration
            test_both_mcp_integration
            test_documentation_completeness
            test_helper_consistency
            generate_comprehensive_report
            print_success "All comprehensive integration tests completed!"
            ;;
        "js")
            setup_test_environment && test_javascript_integration
            ;;
        "python")
            setup_test_environment && test_python_integration
            ;;
        "mcp")
            setup_test_environment && test_both_mcp_integration
            ;;
        "docs")
            setup_test_environment && test_documentation_completeness
            ;;
        "consistency")
            setup_test_environment && test_helper_consistency
            ;;
        "help")
            cat << EOF
Stagehand Comprehensive Integration Test Script

USAGE:
    $0 [COMMAND]

COMMANDS:
    all             Run all tests (default)
    js              Test JavaScript integration only
    python          Test Python integration only
    mcp             Test MCP integration only
    docs            Test documentation completeness only
    consistency     Test helper script consistency only
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
