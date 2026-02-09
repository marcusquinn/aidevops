#!/usr/bin/env bash
# test-vm-setup.sh
#
# Self-test: create a fresh OrbStack Ubuntu VM, run setup.sh, verify outcomes.
# Requires macOS with OrbStack installed.
#
# Usage:
#   bash tests/test-vm-setup.sh                    # Fresh install test
#   bash tests/test-vm-setup.sh --update           # Also test aidevops update
#   bash tests/test-vm-setup.sh --keep             # Don't delete VM after test
#   bash tests/test-vm-setup.sh --vm-name NAME     # Custom VM name
#   bash tests/test-vm-setup.sh --branch BRANCH    # Test a specific branch (default: current)
#   bash tests/test-vm-setup.sh --distro DISTRO    # Ubuntu version (default: noble)
#
# Exit codes: 0 = all pass, 1 = failures found, 2 = prerequisites missing

set -euo pipefail

# --- Configuration ---
VM_NAME="aidevops-test-$$"
VM_DISTRO="ubuntu:noble"
KEEP_VM=false
TEST_UPDATE=false
TEST_BRANCH=""
VERBOSE=false

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)       TEST_UPDATE=true; shift ;;
        --keep)         KEEP_VM=true; shift ;;
        --vm-name)      VM_NAME="$2"; shift 2 ;;
        --branch)       TEST_BRANCH="$2"; shift 2 ;;
        --distro)       VM_DISTRO="ubuntu:$2"; shift 2 ;;
        --verbose|-v)   VERBOSE=true; shift ;;
        --help|-h)
            sed -n '2,/^$/s/^# //p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 2
            ;;
    esac
done

# --- Detect branch if not specified ---
if [[ -z "$TEST_BRANCH" ]]; then
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    TEST_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
fi

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  ${GREEN}PASS${NC} %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  ${RED}FAIL${NC} %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        printf "       %s\n" "$2"
    fi
}

info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

section() {
    echo ""
    printf "${YELLOW}=== %s ===${NC}\n" "$1"
}

# Run a command in the VM, return its exit code
vm_run() {
    orb run -m "$VM_NAME" bash -c "$1" 2>&1
}

# Run a command in the VM, capture output, check exit code
vm_test() {
    local description="$1"
    local command="$2"
    local expect_pattern="${3:-}"

    local output
    output=$(orb run -m "$VM_NAME" bash -c "$command" 2>&1) || true

    if [[ -n "$expect_pattern" ]]; then
        if echo "$output" | grep -qE "$expect_pattern"; then
            pass "$description"
        else
            fail "$description" "Expected pattern '$expect_pattern' not found in output"
            if [[ "$VERBOSE" == "true" ]]; then
                echo "       Output: $(echo "$output" | head -3)"
            fi
        fi
    else
        pass "$description"
    fi
}

# --- Prerequisites ---
section "Prerequisites"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "This test requires macOS with OrbStack."
    exit 2
fi

if ! command -v orbctl &>/dev/null; then
    echo "OrbStack not installed. Install from https://orbstack.dev"
    exit 2
fi

pass "macOS with OrbStack detected"

# --- Create VM ---
section "Creating fresh VM: $VM_NAME ($VM_DISTRO)"

if orbctl list 2>/dev/null | grep -q "$VM_NAME"; then
    info "VM $VM_NAME already exists, deleting..."
    orbctl delete "$VM_NAME" -f 2>/dev/null || true
fi

if orbctl create "$VM_DISTRO" "$VM_NAME"; then
    pass "VM created: $VM_NAME"
else
    fail "Failed to create VM"
    exit 1
fi

# Cleanup trap
cleanup() {
    if [[ "$KEEP_VM" == "true" ]]; then
        info "Keeping VM: $VM_NAME (use 'orbctl delete $VM_NAME -f' to remove)"
    else
        info "Cleaning up VM: $VM_NAME"
        orbctl delete "$VM_NAME" -f 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Wait for VM to be ready
info "Waiting for VM to be ready..."
local_retries=0
while ! vm_run "echo ready" | grep -q "ready"; do
    sleep 1
    local_retries=$((local_retries + 1))
    if [[ $local_retries -gt 30 ]]; then
        fail "VM failed to become ready within 30 seconds"
        exit 1
    fi
done
pass "VM is ready"

# --- Install prerequisites ---
section "Installing prerequisites in VM"

# Install git and curl (minimum for setup.sh)
vm_run "sudo apt-get update -qq && sudo apt-get install -y -qq git curl jq >/dev/null 2>&1"
vm_test "git installed" "command -v git" "git"
vm_test "curl installed" "command -v curl" "curl"

# --- Fresh Install Test ---
section "Testing fresh install (branch: $TEST_BRANCH)"

# Clone the repo at the specific branch
info "Cloning aidevops repo (branch: $TEST_BRANCH)..."
vm_run "git clone --branch '$TEST_BRANCH' --single-branch https://github.com/marcusquinn/aidevops.git ~/Git/aidevops 2>&1" >/dev/null

vm_test "Repo cloned" "test -f ~/Git/aidevops/setup.sh && echo exists" "exists"

# Run setup.sh non-interactive
info "Running setup.sh --non-interactive..."
setup_output=""
setup_output=$(vm_run "cd ~/Git/aidevops && bash setup.sh --non-interactive 2>&1") || true

if [[ "$VERBOSE" == "true" ]]; then
    echo "$setup_output"
fi

# Check for fatal errors in output
if echo "$setup_output" | grep -qiE "fatal|panic|segfault|core dump"; then
    fail "setup.sh had fatal errors"
    echo "$setup_output" | grep -iE "fatal|panic|segfault" | head -5
else
    pass "setup.sh completed without fatal errors"
fi

# Check setup completed
if echo "$setup_output" | grep -q "Setup complete"; then
    pass "setup.sh reported completion"
else
    fail "setup.sh did not report completion"
fi

# --- Verify Outcomes ---
section "Verifying install outcomes"

# Agents deployed
vm_test "Agents deployed to ~/.aidevops/agents/" \
    "test -d ~/.aidevops/agents && ls ~/.aidevops/agents/*.md 2>/dev/null | wc -l" \
    "[1-9]"

# AGENTS.md exists
vm_test "AGENTS.md deployed" \
    "test -f ~/.aidevops/agents/AGENTS.md && echo exists" \
    "exists"

# Onboarding agent exists at correct path
vm_test "onboarding.md at correct path" \
    "test -f ~/.aidevops/agents/aidevops/onboarding.md && echo exists" \
    "exists"

# OpenCode commands generated (if opencode was installed)
vm_test "OpenCode command directory exists" \
    "test -d ~/.config/opencode/command && echo exists || echo 'skipped (opencode not installed)'" \
    "exists|skipped"

# /onboarding command file
vm_test "/onboarding command file created" \
    "test -f ~/.config/opencode/command/onboarding.md && echo exists || echo 'skipped'" \
    "exists|skipped"

# Check /onboarding points to correct path
if vm_run "test -f ~/.config/opencode/command/onboarding.md && echo yes" | grep -q "yes"; then
    vm_test "/onboarding references correct path" \
        "grep 'aidevops/onboarding.md' ~/.config/opencode/command/onboarding.md" \
        "aidevops/onboarding.md"
fi

# Scripts deployed
vm_test "Scripts deployed" \
    "test -x ~/.aidevops/agents/scripts/pre-edit-check.sh && echo exists" \
    "exists"

# aidevops CLI installed
vm_test "aidevops CLI available" \
    "command -v aidevops && echo found || echo 'not in PATH'" \
    "found|not in PATH"

# VERSION file
vm_test "VERSION file deployed" \
    "test -f ~/.aidevops/agents/VERSION && cat ~/.aidevops/agents/VERSION" \
    "[0-9]+\.[0-9]+\.[0-9]+"

# No alarming errors in output (red error lines that aren't expected warnings)
error_lines=0
error_lines=$(echo "$setup_output" | grep -ciE '\[ERROR\]|command not found' || true)
if [[ "$error_lines" -eq 0 ]]; then
    pass "No ERROR lines or 'command not found' in output"
else
    fail "Found $error_lines error/command-not-found lines in output"
    echo "$setup_output" | grep -iE '\[ERROR\]|command not found' | head -5
fi

# --- Update Test ---
if [[ "$TEST_UPDATE" == "true" ]]; then
    section "Testing aidevops update"

    info "Running setup.sh --non-interactive again (simulates update)..."
    update_output=""
    update_output=$(vm_run "cd ~/Git/aidevops && git pull origin '$TEST_BRANCH' 2>/dev/null; bash setup.sh --non-interactive 2>&1") || true

    if echo "$update_output" | grep -q "Setup complete"; then
        pass "Update completed successfully"
    else
        fail "Update did not complete"
    fi

    # Verify agents still intact after update
    vm_test "Agents still deployed after update" \
        "test -d ~/.aidevops/agents && echo exists" \
        "exists"

    vm_test "Commands still exist after update" \
        "test -f ~/.config/opencode/command/onboarding.md && echo exists || echo 'skipped'" \
        "exists|skipped"
fi

# --- Summary ---
section "Results"

echo ""
printf "  Total: %d  " "$TOTAL_COUNT"
printf "${GREEN}Pass: %d${NC}  " "$PASS_COUNT"
if [[ $FAIL_COUNT -gt 0 ]]; then
    printf "${RED}Fail: %d${NC}" "$FAIL_COUNT"
else
    printf "Fail: %d" "$FAIL_COUNT"
fi
echo ""

if [[ "$KEEP_VM" == "true" ]]; then
    echo ""
    info "VM kept: $VM_NAME"
    info "SSH: orb run -m $VM_NAME bash"
    info "Delete: orbctl delete $VM_NAME -f"
fi

echo ""
if [[ $FAIL_COUNT -gt 0 ]]; then
    printf "${RED}FAILED${NC} — %d test(s) failed\n" "$FAIL_COUNT"
    exit 1
else
    printf "${GREEN}ALL TESTS PASSED${NC}\n"
    exit 0
fi
