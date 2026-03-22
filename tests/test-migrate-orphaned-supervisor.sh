#!/usr/bin/env bash
# Tests for migrate_orphaned_supervisor() (GH#5147)
# Verifies cleanup of orphaned supervisor-helper.sh and supervisor/ modules

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_SCRIPT="$REPO_DIR/setup-modules/migrations.sh"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	local name="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;32mPASS\033[0m %s\n" "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;31mFAIL\033[0m %s\n" "$name"
	if [[ -n "$detail" ]]; then
		printf "     %s\n" "$detail"
	fi
	return 0
}

section() {
	echo ""
	echo "=== $1 ==="
	return 0
}

# Create a temporary HOME to isolate tests from the real system
TEST_HOME=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TEST_HOME'" EXIT

# Override HOME for the duration of the test
export HOME="$TEST_HOME"

# Create the deployed agents directory structure (simulating pre-migration state)
AGENTS_DIR="$TEST_HOME/.aidevops/agents"
SCRIPTS_DIR="$AGENTS_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"

# Stub functions that migrations.sh expects from setup.sh.
# These are never called directly in this file — they exist so that
# `source "$MIGRATIONS_SCRIPT"` succeeds. SC2329 is expected.
# shellcheck disable=SC2329
print_info() { echo "[INFO] $1"; }
# shellcheck disable=SC2329
print_success() { echo "[SUCCESS] $1"; }
# shellcheck disable=SC2329
print_warning() { echo "[WARNING] $1"; }
# shellcheck disable=SC2329
print_error() { echo "[ERROR] $1"; }
# _launchd_has_agent is defined in setup.sh; stub it for Linux tests
# shellcheck disable=SC2329
_launchd_has_agent() { return 1; }
# Stubs for other functions referenced by migrations.sh
# shellcheck disable=SC2329
find_opencode_config() { return 1; }
# shellcheck disable=SC2329
create_backup_with_rotation() { return 0; }
# shellcheck disable=SC2329
should_overwrite_user_file() { return 0; }
# shellcheck disable=SC2329
resolve_mcp_binary_path() {
	echo ""
	return 1
}
# shellcheck disable=SC2329
update_mcp_paths_in_opencode() { return 0; }
# shellcheck disable=SC2329
sanitize_plugin_namespace() {
	echo "$1"
	return 0
}
# Export stubs so sourced script can find them
export -f print_info print_success print_warning print_error _launchd_has_agent
export -f find_opencode_config create_backup_with_rotation should_overwrite_user_file
export -f resolve_mcp_binary_path update_mcp_paths_in_opencode sanitize_plugin_namespace

# Source the migrations script to get the function
# shellcheck disable=SC1090
source "$MIGRATIONS_SCRIPT"

# ============================================================================
section "Test: removes orphaned supervisor-helper.sh"
# ============================================================================

# Create orphaned file
echo '#!/usr/bin/env bash' >"$SCRIPTS_DIR/supervisor-helper.sh"

if [[ -f "$SCRIPTS_DIR/supervisor-helper.sh" ]]; then
	pass "Setup: orphaned supervisor-helper.sh exists before migration"
else
	fail "Setup: orphaned supervisor-helper.sh should exist"
fi

migrate_orphaned_supervisor >/dev/null 2>&1

if [[ ! -f "$SCRIPTS_DIR/supervisor-helper.sh" ]]; then
	pass "supervisor-helper.sh removed after migration"
else
	fail "supervisor-helper.sh should have been removed"
fi

# ============================================================================
section "Test: removes orphaned supervisor/ module directory"
# ============================================================================

# Create orphaned module directory with recognizable files
mkdir -p "$SCRIPTS_DIR/supervisor"
echo '#!/usr/bin/env bash' >"$SCRIPTS_DIR/supervisor/pulse.sh"
echo '#!/usr/bin/env bash' >"$SCRIPTS_DIR/supervisor/dispatch.sh"
echo '#!/usr/bin/env bash' >"$SCRIPTS_DIR/supervisor/_common.sh"

if [[ -d "$SCRIPTS_DIR/supervisor" ]]; then
	pass "Setup: orphaned supervisor/ directory exists before migration"
else
	fail "Setup: orphaned supervisor/ directory should exist"
fi

migrate_orphaned_supervisor >/dev/null 2>&1

if [[ ! -d "$SCRIPTS_DIR/supervisor" ]]; then
	pass "supervisor/ directory removed after migration"
else
	fail "supervisor/ directory should have been removed"
fi

# ============================================================================
section "Test: does NOT remove supervisor-archived/"
# ============================================================================

mkdir -p "$SCRIPTS_DIR/supervisor-archived"
echo '#!/usr/bin/env bash' >"$SCRIPTS_DIR/supervisor-archived/supervisor-helper.sh"

migrate_orphaned_supervisor >/dev/null 2>&1

if [[ -d "$SCRIPTS_DIR/supervisor-archived" ]]; then
	pass "supervisor-archived/ preserved after migration"
else
	fail "supervisor-archived/ should NOT have been removed"
fi

# ============================================================================
section "Test: does NOT remove unrelated supervisor/ directory"
# ============================================================================

# Create a supervisor/ directory without the expected module files
mkdir -p "$SCRIPTS_DIR/supervisor"
echo 'custom content' >"$SCRIPTS_DIR/supervisor/my-custom-file.txt"

migrate_orphaned_supervisor >/dev/null 2>&1

if [[ -d "$SCRIPTS_DIR/supervisor" ]]; then
	pass "Unrelated supervisor/ directory preserved (no module files)"
else
	fail "Unrelated supervisor/ directory should NOT have been removed"
fi

# Clean up for next test
rm -rf "$SCRIPTS_DIR/supervisor"

# ============================================================================
section "Test: idempotent — no errors when nothing to clean"
# ============================================================================

# Run migration when there's nothing to clean
output=$(migrate_orphaned_supervisor 2>&1)
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
	pass "Migration succeeds when nothing to clean (exit 0)"
else
	fail "Migration should succeed when nothing to clean" "exit code: $exit_code"
fi

# Should NOT print the success message when nothing was cleaned
if [[ "$output" != *"Cleaned up"* ]]; then
	pass "No 'Cleaned up' message when nothing to clean"
else
	fail "Should not print 'Cleaned up' when nothing was cleaned" "$output"
fi

# ============================================================================
section "Test: removes cron entries referencing supervisor-helper.sh"
# ============================================================================

# Install a fake cron entry (only if crontab is available)
if command -v crontab &>/dev/null; then
	# Save current crontab
	original_crontab=$(crontab -l 2>/dev/null) || original_crontab=""

	# Install test crontab with supervisor-helper.sh entry
	{
		echo "# aidevops: test-keep-this"
		echo "*/5 * * * * echo keep-this # aidevops: test-keep"
		echo "*/2 * * * * /bin/bash /home/test/.aidevops/agents/scripts/supervisor-helper.sh pulse >> /tmp/test.log 2>&1 # aidevops: supervisor-pulse"
	} | crontab - 2>/dev/null

	migrate_orphaned_supervisor >/dev/null 2>&1

	new_crontab=$(crontab -l 2>/dev/null) || new_crontab=""

	if echo "$new_crontab" | grep -qF "supervisor-helper.sh"; then
		fail "Cron entry referencing supervisor-helper.sh should have been removed"
	else
		pass "Cron entry referencing supervisor-helper.sh removed"
	fi

	if echo "$new_crontab" | grep -qF "keep-this"; then
		pass "Non-supervisor cron entries preserved"
	else
		fail "Non-supervisor cron entries should have been preserved"
	fi

	# Restore original crontab
	if [[ -n "$original_crontab" ]]; then
		printf '%s\n' "$original_crontab" | crontab - 2>/dev/null || true
	else
		crontab -r 2>/dev/null || true
	fi
else
	pass "Cron test skipped (crontab not available)"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "================================"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $TOTAL_COUNT total"
echo "================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
	exit 1
fi
exit 0
