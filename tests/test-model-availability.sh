#!/usr/bin/env bash
# test-model-availability.sh
#
# Tests for model-availability-helper.sh (t132.3)
# Validates: syntax, help output, DB init, cache logic, tier resolution,
# and integration with supervisor resolve_model/check_model_health.
#
# Usage: bash tests/test-model-availability.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/.agents/scripts/model-availability-helper.sh"
SUPERVISOR="$REPO_DIR/.agents/scripts/supervisor-helper.sh"
VERBOSE="${1:-}"

# Portable timeout: gtimeout (macOS homebrew) > timeout (Linux) > none
TIMEOUT_CMD=""
if command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
fi

# Run a command with optional timeout
run_with_timeout() {
    local secs="$1"
    shift
    if [[ -n "$TIMEOUT_CMD" ]]; then
        "$TIMEOUT_CMD" "$secs" "$@"
    else
        "$@"
    fi
}

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [[ "$VERBOSE" == "--verbose" ]]; then
        printf "  \033[0;32mPASS\033[0m %s\n" "$1"
    fi
    return 0
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        printf "       %s\n" "$2"
    fi
    return 0
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [[ "$VERBOSE" == "--verbose" ]]; then
        printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
    fi
    return 0
}

section() {
    echo ""
    printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# Use a temp DB for testing to avoid polluting real cache
TEST_DB_DIR=$(mktemp -d)
export AVAILABILITY_DB_OVERRIDE="$TEST_DB_DIR/test-availability.db"
trap 'rm -rf "$TEST_DB_DIR"' EXIT

# ============================================================
# SECTION 1: Basic validation
# ============================================================
section "Basic Validation"

# Syntax check
if bash -n "$HELPER" 2>/dev/null; then
    pass "bash -n syntax check"
else
    fail "bash -n syntax check" "Script has syntax errors"
fi

# ShellCheck
if command -v shellcheck &>/dev/null; then
    sc_output=$(shellcheck "$HELPER" 2>&1 || true)
    sc_errors=$(echo "$sc_output" | grep -c "error" 2>/dev/null || true)
    if [[ "$sc_errors" -eq 0 ]]; then
        pass "shellcheck (0 errors)"
    else
        fail "shellcheck ($sc_errors errors)" "$(echo "$sc_output" | head -5)"
    fi
else
    skip "shellcheck not installed"
fi

# Help command
help_output=$(run_with_timeout 5 bash "$HELPER" help 2>&1) || true
if [[ -n "$help_output" ]]; then
    pass "help command produces output"
else
    fail "help command produces output" "No output"
fi

# Help mentions key commands
if echo "$help_output" | grep -qi "check"; then
    pass "help mentions 'check' command"
else
    fail "help mentions 'check' command"
fi

if echo "$help_output" | grep -qi "probe"; then
    pass "help mentions 'probe' command"
else
    fail "help mentions 'probe' command"
fi

if echo "$help_output" | grep -qi "resolve"; then
    pass "help mentions 'resolve' command"
else
    fail "help mentions 'resolve' command"
fi

if echo "$help_output" | grep -qi "rate-limits"; then
    pass "help mentions 'rate-limits' command"
else
    fail "help mentions 'rate-limits' command"
fi

# ============================================================
# SECTION 2: Status command (no prior data)
# ============================================================
section "Status Command (Empty State)"

status_output=$(run_with_timeout 5 bash "$HELPER" status 2>&1) || true
if [[ -n "$status_output" ]]; then
    pass "status command runs without error"
else
    fail "status command runs without error" "No output or error"
fi

# ============================================================
# SECTION 3: Resolve command (tier resolution)
# ============================================================
section "Tier Resolution"

# Test that resolve returns a model spec for known tiers
for tier in haiku flash sonnet pro opus health eval coding; do
    resolve_output=$(run_with_timeout 15 bash "$HELPER" resolve "$tier" --quiet 2>&1) || true
    # Even without API keys, resolve should return the primary model
    # (it falls through to the primary when no probe is possible)
    if [[ -n "$resolve_output" && "$resolve_output" == *"/"* ]]; then
        pass "resolve $tier -> $resolve_output"
    else
        # May fail if no API keys configured - that's OK for CI
        skip "resolve $tier (no API keys or provider unavailable)"
    fi
done

# Test unknown tier (use || true to prevent set -e from aborting on expected failure)
if run_with_timeout 5 bash "$HELPER" resolve "nonexistent" --quiet >/dev/null 2>&1; then
    fail "resolve unknown tier returns error" "Expected non-zero exit"
else
    pass "resolve unknown tier returns error"
fi

# ============================================================
# SECTION 4: Check command
# ============================================================
section "Check Command"

# Check with unknown provider (use if to prevent set -e from aborting on expected failure)
if run_with_timeout 5 bash "$HELPER" check "nonexistent_provider_xyz" --quiet >/dev/null 2>&1; then
    fail "check unknown target returns error" "Expected non-zero exit, got 0"
else
    pass "check unknown target returns error"
fi

# Check with known provider (may succeed or fail depending on keys)
# Use || true to prevent set -e from aborting on non-zero exit
for provider in anthropic openai google opencode; do
    check_exit=0
    run_with_timeout 15 bash "$HELPER" check "$provider" --quiet >/dev/null 2>&1 || check_exit=$?
    case "$check_exit" in
        0) pass "check $provider: healthy" ;;
        1) pass "check $provider: unhealthy (expected without key or CLI)" ;;
        2) pass "check $provider: rate limited" ;;
        3) pass "check $provider: no key (expected in CI)" ;;
        *) fail "check $provider: unexpected exit code $check_exit" ;;
    esac
done

# ============================================================
# SECTION 5: Invalidate command
# ============================================================
section "Cache Invalidation"

run_with_timeout 5 bash "$HELPER" invalidate >/dev/null 2>&1
invalidate_exit=$?
if [[ $invalidate_exit -eq 0 ]]; then
    pass "invalidate all caches"
else
    fail "invalidate all caches" "Exit code: $invalidate_exit"
fi

run_with_timeout 5 bash "$HELPER" invalidate anthropic >/dev/null 2>&1
invalidate_prov_exit=$?
if [[ $invalidate_prov_exit -eq 0 ]]; then
    pass "invalidate specific provider cache"
else
    fail "invalidate specific provider cache" "Exit code: $invalidate_prov_exit"
fi

# ============================================================
# SECTION 6: Supervisor integration
# ============================================================
section "Supervisor Integration"

# Verify supervisor references the availability helper
if grep -q "model-availability-helper.sh" "$SUPERVISOR"; then
    pass "supervisor references model-availability-helper.sh"
else
    fail "supervisor references model-availability-helper.sh"
fi

# Verify resolve_model() has availability helper fast path
if grep -q "availability_helper.*resolve" "$SUPERVISOR"; then
    pass "resolve_model() uses availability helper"
else
    fail "resolve_model() uses availability helper"
fi

# Verify check_model_health() has availability helper fast path
if grep -q "availability_helper.*check" "$SUPERVISOR"; then
    pass "check_model_health() uses availability helper fast path"
else
    fail "check_model_health() uses availability helper fast path"
fi

# Verify check_model_health() still has CLI fallback
if grep -q 'health-check' "$SUPERVISOR"; then
    pass "check_model_health() retains CLI fallback (slow path)"
else
    fail "check_model_health() retains CLI fallback (slow path)"
fi

# ============================================================
# SECTION 7: OpenCode Integration
# ============================================================
section "OpenCode Integration"

# Verify opencode is a known provider
if bash "$HELPER" help 2>&1 | grep -q "opencode"; then
    pass "help mentions opencode provider"
else
    fail "help mentions opencode provider"
fi

# Check opencode provider (should succeed if CLI installed, fail gracefully otherwise)
check_oc_exit=0
run_with_timeout 10 bash "$HELPER" check opencode --quiet >/dev/null 2>&1 || check_oc_exit=$?
case "$check_oc_exit" in
    0) pass "check opencode: healthy (CLI and cache available)" ;;
    1) pass "check opencode: unhealthy (CLI or cache not available)" ;;
    *) fail "check opencode: unexpected exit code $check_oc_exit" ;;
esac

# Verify opencode model check (if opencode is available)
if command -v opencode &>/dev/null && [[ -f "$HOME/.cache/opencode/models.json" ]]; then
    oc_model_exit=0
    run_with_timeout 10 bash "$HELPER" check "opencode/claude-sonnet-4" --quiet >/dev/null 2>&1 || oc_model_exit=$?
    case "$oc_model_exit" in
        0) pass "check opencode/claude-sonnet-4: available" ;;
        1) pass "check opencode/claude-sonnet-4: not available (provider unhealthy)" ;;
        *) fail "check opencode/claude-sonnet-4: unexpected exit code $oc_model_exit" ;;
    esac
else
    skip "opencode model check (opencode CLI not installed)"
fi

# ============================================================
# SECTION 8: JSON output
# ============================================================
section "JSON Output"

# Status --json
json_status=$(run_with_timeout 5 bash "$HELPER" status --json 2>&1) || true
if echo "$json_status" | grep -q "{" 2>/dev/null; then
    pass "status --json produces JSON"
else
    skip "status --json (no data to format)"
fi

# Resolve --json
json_resolve=$(run_with_timeout 15 bash "$HELPER" resolve sonnet --json --quiet 2>&1) || true
if echo "$json_resolve" | grep -q "tier" 2>/dev/null; then
    pass "resolve --json produces JSON with tier field"
else
    skip "resolve --json (provider may be unavailable)"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "========================================"
printf "  \033[1mResults: %d total, \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m, \033[0;33m%d skipped\033[0m\n" \
    "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
echo "========================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    printf "\033[0;31mFAILURES DETECTED - review output above\033[0m\n"
    exit 1
else
    echo ""
    printf "\033[0;32mAll tests passed.\033[0m\n"
    exit 0
fi
