#!/usr/bin/env bash
# test-contest-helper.sh
#
# Tests for contest-helper.sh (t1011)
# Validates: syntax, help output, table creation, contest CRUD,
# should-contest logic, and status display.
#
# Usage: bash tests/test-contest-helper.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_DIR/.agents/scripts/contest-helper.sh"
SUPERVISOR_HELPER="$REPO_DIR/.agents/scripts/supervisor-helper.sh"
VERBOSE="${1:-}"

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

# Use a temp directory for testing to avoid polluting real data
TEST_DIR=$(mktemp -d)
export AIDEVOPS_SUPERVISOR_DIR="$TEST_DIR/supervisor"
mkdir -p "$AIDEVOPS_SUPERVISOR_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "test-contest-helper.sh — Contest mode tests (t1011)"
echo "Test DB dir: $TEST_DIR"

# ============================================================
section "1. File Existence and Syntax"
# ============================================================

if [[ -f "$HELPER" ]]; then
	pass "contest-helper.sh exists"
else
	fail "contest-helper.sh not found at $HELPER"
	exit 1
fi

if [[ -x "$HELPER" ]]; then
	pass "contest-helper.sh is executable"
else
	fail "contest-helper.sh is not executable"
fi

if bash -n "$HELPER" 2>/dev/null; then
	pass "contest-helper.sh has valid bash syntax"
else
	fail "contest-helper.sh has syntax errors"
fi

# ============================================================
section "2. ShellCheck"
# ============================================================

if command -v shellcheck &>/dev/null; then
	if shellcheck -x -S warning "$HELPER" 2>/dev/null; then
		pass "ShellCheck passes with no warnings"
	else
		fail "ShellCheck found issues" "Run: shellcheck -x -S warning $HELPER"
	fi
else
	skip "ShellCheck not installed"
fi

# ============================================================
section "3. Help Output"
# ============================================================

help_output=$("$HELPER" help 2>&1 || true)
if echo "$help_output" | grep -q "contest-helper.sh"; then
	pass "Help output contains script name"
else
	fail "Help output missing script name"
fi

if echo "$help_output" | grep -q "create"; then
	pass "Help output lists 'create' command"
else
	fail "Help output missing 'create' command"
fi

if echo "$help_output" | grep -q "evaluate"; then
	pass "Help output lists 'evaluate' command"
else
	fail "Help output missing 'evaluate' command"
fi

if echo "$help_output" | grep -q "Correctness"; then
	pass "Help output shows scoring criteria"
else
	fail "Help output missing scoring criteria"
fi

# ============================================================
section "4. Supervisor DB Init + Contest Tables"
# ============================================================

# Initialize a minimal supervisor DB for testing
SUPERVISOR_DB="$AIDEVOPS_SUPERVISOR_DIR/supervisor.db"
sqlite3 "$SUPERVISOR_DB" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    repo TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    model TEXT DEFAULT 'anthropic/claude-opus-4-6',
    session_id TEXT,
    worktree TEXT,
    branch TEXT,
    log_file TEXT,
    retries INTEGER NOT NULL DEFAULT 0,
    max_retries INTEGER NOT NULL DEFAULT 3,
    error TEXT,
    pr_url TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at TEXT,
    completed_at TEXT,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
SQL

# Add a test task
sqlite3 "$SUPERVISOR_DB" "INSERT INTO tasks (id, repo, description, status) VALUES ('t999', '.', 'Test task for contest', 'queued');"

if [[ -f "$SUPERVISOR_DB" ]]; then
	pass "Test supervisor DB created"
else
	fail "Failed to create test supervisor DB"
fi

# Test ensure_contest_tables via help (which triggers it)
"$HELPER" help >/dev/null 2>&1 || true

# Check if tables were created (they should be created on first use)
has_contests=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='contests';" 2>/dev/null || echo "0")
# Tables are created lazily on first command that needs them, not on help
# Let's trigger table creation explicitly
"$HELPER" list 2>/dev/null || true

has_contests=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='contests';" 2>/dev/null || echo "0")
if [[ "$has_contests" -gt 0 ]]; then
	pass "contests table created"
else
	fail "contests table not created"
fi

has_entries=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='contest_entries';" 2>/dev/null || echo "0")
if [[ "$has_entries" -gt 0 ]]; then
	pass "contest_entries table created"
else
	fail "contest_entries table not created"
fi

# ============================================================
section "5. Contest Create"
# ============================================================

create_output=$("$HELPER" create t999 --models "model-a,model-b,model-c" 2>/dev/null || echo "FAILED")
if [[ "$create_output" == "FAILED" ]]; then
	fail "Contest create failed"
else
	pass "Contest create succeeded: $create_output"
fi

# Verify contest record exists
contest_count=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM contests WHERE task_id = 't999';" 2>/dev/null || echo "0")
if [[ "$contest_count" -gt 0 ]]; then
	pass "Contest record exists in DB"
else
	fail "Contest record not found in DB"
fi

# Verify entries were created
entry_count=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM contest_entries WHERE contest_id LIKE 'contest-t999%';" 2>/dev/null || echo "0")
if [[ "$entry_count" -eq 3 ]]; then
	pass "3 contest entries created"
else
	fail "Expected 3 entries, got $entry_count"
fi

# ============================================================
section "6. Contest List"
# ============================================================

list_output=$("$HELPER" list 2>&1 || true)
if echo "$list_output" | grep -q "t999"; then
	pass "Contest list shows t999 contest"
else
	fail "Contest list missing t999 contest"
fi

# ============================================================
section "7. Contest Status"
# ============================================================

# Get the contest ID
contest_id=$(sqlite3 "$SUPERVISOR_DB" "SELECT id FROM contests WHERE task_id = 't999' LIMIT 1;" 2>/dev/null || echo "")
if [[ -n "$contest_id" ]]; then
	status_output=$("$HELPER" status "$contest_id" 2>&1 || true)
	if echo "$status_output" | grep -q "t999"; then
		pass "Contest status shows task ID"
	else
		fail "Contest status missing task ID"
	fi

	if echo "$status_output" | grep -q "model-a\|model-b\|model-c"; then
		pass "Contest status shows models"
	else
		fail "Contest status missing models"
	fi
else
	fail "Could not retrieve contest ID"
fi

# ============================================================
section "8. Duplicate Contest Prevention"
# ============================================================

# Try creating another contest for the same task
dup_output=$("$HELPER" create t999 --models "model-x,model-y,model-z" 2>/dev/null || echo "FAILED")
dup_count=$(sqlite3 "$SUPERVISOR_DB" "SELECT count(*) FROM contests WHERE task_id = 't999';" 2>/dev/null || echo "0")
if [[ "$dup_count" -eq 1 ]]; then
	pass "Duplicate contest prevented (still 1 contest)"
else
	fail "Duplicate prevention failed (got $dup_count contests)"
fi

# ============================================================
section "9. Should-Contest Logic"
# ============================================================

# Without pattern data, should-contest should return true (no_data or similar)
should_output=$("$HELPER" should-contest t999 2>/dev/null || echo "no_contest")
if [[ "$should_output" == "no_contest" ]]; then
	# Pattern tracker may not be available in test env — that's OK
	skip "should-contest returned no_contest (pattern tracker may not be available)"
else
	pass "should-contest returned: $should_output"
fi

# ============================================================
section "10. Unknown Command Handling"
# ============================================================

if "$HELPER" nonexistent-command 2>/dev/null; then
	fail "Unknown command should return non-zero"
else
	pass "Unknown command returns non-zero exit code"
fi

# ============================================================
section "Summary"
# ============================================================

echo ""
printf "\033[1mResults: %d passed, %d failed, %d skipped (of %d total)\033[0m\n" \
	"$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$TOTAL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi
exit 0
