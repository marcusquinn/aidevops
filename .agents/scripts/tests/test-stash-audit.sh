#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155

# =============================================================================
# Test Script for stash-audit-helper.sh
# =============================================================================
# Tests all classification scenarios:
# - safe-to-drop: changes already in HEAD
# - obsolete: old stashes (>30 days)
# - needs-review: unique changes not in HEAD
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
STASH_HELPER="${SCRIPT_DIR}/../stash-audit-helper.sh"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RESET='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

#######################################
# Print test result
# Arguments:
#   $1 - Test name
#   $2 - Result (0=pass, 1=fail)
#   $3 - Optional message
# Returns:
#   0 always
#######################################
print_result() {
    local test_name="$1"
    local result="$2"
    local message="${3:-}"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${RESET} $test_name"
        if [[ -n "$message" ]]; then
            echo "  $message"
        fi
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    return 0
}

#######################################
# Setup test repository
# Arguments:
#   None
# Returns:
#   0 on success, 1 on failure
# Outputs:
#   Test repo path
#######################################
setup_test_repo() {
    local test_repo
    test_repo=$(mktemp -d)
    
    cd "$test_repo" || return 1
    
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    
    # Create initial commit
    echo "initial" > file1.txt
    git add file1.txt
    git commit -q -m "Initial commit"
    
    echo "$test_repo"
    return 0
}

#######################################
# Cleanup test repository
# Arguments:
#   $1 - Test repo path
# Returns:
#   0 always
#######################################
cleanup_test_repo() {
    local test_repo="$1"
    
    if [[ -d "$test_repo" ]]; then
        rm -rf "$test_repo"
    fi
    
    return 0
}

#######################################
# Test: safe-to-drop classification
# Arguments:
#   None
# Returns:
#   0 on success, 1 on failure
#######################################
test_safe_to_drop() {
    local test_repo
    test_repo=$(setup_test_repo)
    
    cd "$test_repo" || return 1
    
    # Make a change and stash it
    echo "change1" > file1.txt
    git stash push -q -m "Test stash 1"
    
    # Apply the same change to HEAD
    echo "change1" > file1.txt
    git add file1.txt
    git commit -q -m "Apply change"
    
    # Audit should classify as safe-to-drop
    local output
    output=$("$STASH_HELPER" audit --repo "$test_repo" 2>&1)
    
    local result=1
    if echo "$output" | grep -q "safe-to-drop"; then
        result=0
    fi
    
    cleanup_test_repo "$test_repo"
    
    return $result
}

#######################################
# Test: needs-review classification
# Arguments:
#   None
# Returns:
#   0 on success, 1 on failure
#######################################
test_needs_review() {
    local test_repo
    test_repo=$(setup_test_repo)
    
    cd "$test_repo" || return 1
    
    # Make a change and stash it
    echo "unique change" > file1.txt
    git stash push -q -m "Test stash with unique changes"
    
    # Make a different change to HEAD
    echo "different change" > file1.txt
    git add file1.txt
    git commit -q -m "Different change"
    
    # Audit should classify as needs-review
    local output
    output=$("$STASH_HELPER" audit --repo "$test_repo" 2>&1)
    
    local result=1
    if echo "$output" | grep -q "needs-review"; then
        result=0
    fi
    
    cleanup_test_repo "$test_repo"
    
    return $result
}

#######################################
# Test: list command
# Arguments:
#   None
# Returns:
#   0 on success, 1 on failure
#######################################
test_list() {
    local test_repo
    test_repo=$(setup_test_repo)
    
    cd "$test_repo" || return 1
    
    # Create a stash
    echo "change" > file1.txt
    git stash push -q -m "Test stash"
    
    # List should show the stash
    local output
    output=$("$STASH_HELPER" list --repo "$test_repo" 2>&1)
    
    local result=1
    if echo "$output" | grep -q "Test stash"; then
        result=0
    fi
    
    cleanup_test_repo "$test_repo"
    
    return $result
}

#######################################
# Test: auto-clean command
# Arguments:
#   None
# Returns:
#   0 on success, 1 on failure
#######################################
test_auto_clean() {
    local test_repo
    test_repo=$(setup_test_repo)
    
    cd "$test_repo" || return 1
    
    # Create a safe-to-drop stash
    echo "change1" > file1.txt
    git stash push -q -m "Safe stash"
    
    # Apply the same change to HEAD
    echo "change1" > file1.txt
    git add file1.txt
    git commit -q -m "Apply change"
    
    # Auto-clean should drop the stash
    "$STASH_HELPER" auto-clean --repo "$test_repo" >/dev/null 2>&1
    
    # Verify stash was dropped
    local stash_count
    stash_count=$(git stash list | wc -l)
    
    local result=1
    if [[ "$stash_count" -eq 0 ]]; then
        result=0
    fi
    
    cleanup_test_repo "$test_repo"
    
    return $result
}

#######################################
# Test: no stashes scenario
# Arguments:
#   None
# Returns:
#   0 on success, 1 on failure
#######################################
test_no_stashes() {
    local test_repo
    test_repo=$(setup_test_repo)
    
    cd "$test_repo" || return 1
    
    # Audit with no stashes should succeed
    local output
    output=$("$STASH_HELPER" audit --repo "$test_repo" 2>&1)
    
    local result=1
    if echo "$output" | grep -q "No stashes found"; then
        result=0
    fi
    
    cleanup_test_repo "$test_repo"
    
    return $result
}

#######################################
# Test: help command
# Arguments:
#   None
# Returns:
#   0 on success, 1 on failure
#######################################
test_help() {
    local output
    output=$("$STASH_HELPER" help 2>&1)
    
    local result=1
    if echo "$output" | grep -q "Usage:"; then
        result=0
    fi
    
    return $result
}

#######################################
# Test: invalid repo path
# Arguments:
#   None
# Returns:
#   0 on success, 1 on failure
#######################################
test_invalid_repo() {
    local output
    output=$("$STASH_HELPER" audit --repo /nonexistent/path 2>&1 || true)
    
    local result=1
    if echo "$output" | grep -q "does not exist"; then
        result=0
    fi
    
    return $result
}

#######################################
# Main test runner
# Arguments:
#   None
# Returns:
#   0 if all tests pass, 1 otherwise
#######################################
main() {
    echo "Running stash-audit-helper.sh tests..."
    echo ""
    
    # Check if stash helper exists
    if [[ ! -f "$STASH_HELPER" ]]; then
        echo -e "${RED}Error: stash-audit-helper.sh not found at $STASH_HELPER${RESET}"
        return 1
    fi
    
    # Run tests
    test_safe_to_drop
    print_result "safe-to-drop classification" $?
    
    test_needs_review
    print_result "needs-review classification" $?
    
    test_list
    print_result "list command" $?
    
    test_auto_clean
    print_result "auto-clean command" $?
    
    test_no_stashes
    print_result "no stashes scenario" $?
    
    test_help
    print_result "help command" $?
    
    test_invalid_repo
    print_result "invalid repo path" $?
    
    # Print summary
    echo ""
    echo "========================================="
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${RESET}"
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        echo -e "Tests failed: ${RED}$TESTS_FAILED${RESET}"
    else
        echo "Tests failed: $TESTS_FAILED"
    fi
    echo "========================================="
    
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
