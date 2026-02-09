#!/usr/bin/env bash
# test-backup-safety.sh
#
# Unit tests for the backup-before-modify pattern (t188):
# - backup_sqlite_db: creates timestamped backups
# - verify_sqlite_backup: checks row counts
# - verify_migration_rowcounts: detects data loss after migration
# - rollback_sqlite_db: restores from backup
# - cleanup_sqlite_backups: prunes old backups
# - Integration: supervisor, memory, mail helpers use backup pattern
#
# Uses isolated temp directories to avoid touching production data.
#
# Usage: bash tests/test-backup-safety.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
VERBOSE="${1:-}"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;32mPASS\033[0m %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        printf "       %s\n" "$2"
    fi
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
}

section() {
    echo ""
    printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# --- Setup ---
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Source shared-constants.sh to get the backup functions
source "$SCRIPTS_DIR/shared-constants.sh"

# Create a test database with sample data
create_test_db() {
    local db_path="$1"
    local row_count="${2:-10}"

    sqlite3 "$db_path" <<SQL
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    description TEXT,
    status TEXT DEFAULT 'queued'
);
CREATE TABLE IF NOT EXISTS batches (
    id TEXT PRIMARY KEY,
    name TEXT
);
SQL

    local i
    for ((i = 1; i <= row_count; i++)); do
        sqlite3 "$db_path" "INSERT OR IGNORE INTO tasks (id, description, status) VALUES ('t$i', 'Task $i', 'queued');"
    done
    sqlite3 "$db_path" "INSERT OR IGNORE INTO batches (id, name) VALUES ('b1', 'test-batch');"

    return 0
}

# ============================================================
section "backup_sqlite_db"
# ============================================================

# Test 1: Basic backup creation
test_db="$TEMP_DIR/test1.db"
create_test_db "$test_db" 5
backup_file=$(backup_sqlite_db "$test_db" "test-reason")
if [[ -f "$backup_file" ]]; then
    pass "backup_sqlite_db creates backup file"
else
    fail "backup_sqlite_db creates backup file" "File not found: $backup_file"
fi

# Test 2: Backup filename contains reason
if echo "$backup_file" | grep -q "test-reason"; then
    pass "backup filename contains reason label"
else
    fail "backup filename contains reason label" "Got: $backup_file"
fi

# Test 3: Backup contains same data
orig_count=$(sqlite3 "$test_db" "SELECT count(*) FROM tasks;")
backup_count=$(sqlite3 "$backup_file" "SELECT count(*) FROM tasks;")
if [[ "$orig_count" == "$backup_count" ]]; then
    pass "backup contains same row count ($orig_count)"
else
    fail "backup contains same row count" "Original: $orig_count, Backup: $backup_count"
fi

# Test 4: Backup of non-existent file fails
if backup_sqlite_db "$TEMP_DIR/nonexistent.db" "test" >/dev/null 2>&1; then
    fail "backup of non-existent file returns error"
else
    pass "backup of non-existent file returns error"
fi

# ============================================================
section "verify_sqlite_backup"
# ============================================================

# Test 5: Verification passes when counts match
if verify_sqlite_backup "$test_db" "$backup_file" "tasks batches"; then
    pass "verify_sqlite_backup passes when counts match"
else
    fail "verify_sqlite_backup passes when counts match"
fi

# Test 6: Verification fails when original has fewer rows
sqlite3 "$test_db" "DELETE FROM tasks WHERE id = 't1';"
if verify_sqlite_backup "$test_db" "$backup_file" "tasks" 2>/dev/null; then
    fail "verify_sqlite_backup detects row count decrease"
else
    pass "verify_sqlite_backup detects row count decrease"
fi

# Restore the deleted row for subsequent tests
sqlite3 "$test_db" "INSERT INTO tasks (id, description, status) VALUES ('t1', 'Task 1', 'queued');"

# ============================================================
section "verify_migration_rowcounts"
# ============================================================

# Test 7: Migration verification passes when counts match
if verify_migration_rowcounts "$test_db" "$backup_file" "tasks batches"; then
    pass "verify_migration_rowcounts passes when counts match"
else
    fail "verify_migration_rowcounts passes when counts match"
fi

# Test 8: Migration verification passes when counts increase
sqlite3 "$test_db" "INSERT INTO tasks (id, description, status) VALUES ('t99', 'Extra task', 'queued');"
if verify_migration_rowcounts "$test_db" "$backup_file" "tasks"; then
    pass "verify_migration_rowcounts passes when counts increase"
else
    fail "verify_migration_rowcounts passes when counts increase"
fi

# Test 9: Migration verification fails when counts decrease
sqlite3 "$test_db" "DELETE FROM tasks WHERE id IN ('t1', 't2', 't3');"
if verify_migration_rowcounts "$test_db" "$backup_file" "tasks" 2>/dev/null; then
    fail "verify_migration_rowcounts detects data loss"
else
    pass "verify_migration_rowcounts detects data loss"
fi

# ============================================================
section "rollback_sqlite_db"
# ============================================================

# Test 10: Rollback restores data
rollback_sqlite_db "$test_db" "$backup_file" 2>/dev/null
restored_count=$(sqlite3 "$test_db" "SELECT count(*) FROM tasks;")
if [[ "$restored_count" == "5" ]]; then
    pass "rollback_sqlite_db restores original data ($restored_count rows)"
else
    fail "rollback_sqlite_db restores original data" "Expected 5, got $restored_count"
fi

# Test 11: Rollback creates pre-rollback safety backup
pre_rollback_count=$(ls -1 "$TEMP_DIR"/test1-backup-*-pre-rollback.db 2>/dev/null | wc -l | tr -d ' ')
if [[ "$pre_rollback_count" -ge 1 ]]; then
    pass "rollback creates pre-rollback safety backup"
else
    fail "rollback creates pre-rollback safety backup" "Found $pre_rollback_count pre-rollback backups"
fi

# Test 12: Rollback of non-existent backup fails
if rollback_sqlite_db "$test_db" "$TEMP_DIR/nonexistent.db" 2>/dev/null; then
    fail "rollback of non-existent backup returns error"
else
    pass "rollback of non-existent backup returns error"
fi

# ============================================================
section "cleanup_sqlite_backups"
# ============================================================

# Test 13: Create multiple backups and verify cleanup
cleanup_db="$TEMP_DIR/cleanup-test.db"
create_test_db "$cleanup_db" 3
for i in 1 2 3 4 5 6 7; do
    sleep 1  # Ensure unique timestamps
    backup_sqlite_db "$cleanup_db" "test-$i" >/dev/null 2>&1
done

pre_cleanup_count=$(ls -1 "$TEMP_DIR"/cleanup-test-backup-*.db 2>/dev/null | wc -l | tr -d ' ')
cleanup_sqlite_backups "$cleanup_db" 3
post_cleanup_count=$(ls -1 "$TEMP_DIR"/cleanup-test-backup-*.db 2>/dev/null | wc -l | tr -d ' ')

if [[ "$post_cleanup_count" -le 3 ]]; then
    pass "cleanup_sqlite_backups keeps at most N backups ($pre_cleanup_count -> $post_cleanup_count)"
else
    fail "cleanup_sqlite_backups keeps at most N backups" "Expected <=3, got $post_cleanup_count (was $pre_cleanup_count)"
fi

# ============================================================
section "End-to-end: simulated migration with rollback"
# ============================================================

# Test 14: Simulate a migration that loses data, verify rollback works
e2e_db="$TEMP_DIR/e2e-test.db"
create_test_db "$e2e_db" 20

# Backup
e2e_backup=$(backup_sqlite_db "$e2e_db" "pre-migrate-e2e")

# Simulate a bad migration (table recreation that loses data)
sqlite3 "$e2e_db" <<'SQL'
ALTER TABLE tasks RENAME TO tasks_old;
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    description TEXT,
    status TEXT DEFAULT 'queued'
);
-- Intentionally DON'T copy data (simulates the t180 bug)
DROP TABLE tasks_old;
SQL

post_migrate_count=$(sqlite3 "$e2e_db" "SELECT count(*) FROM tasks;")
if [[ "$post_migrate_count" -eq 0 ]]; then
    pass "simulated bad migration empties table (count: $post_migrate_count)"
else
    fail "simulated bad migration empties table" "Expected 0, got $post_migrate_count"
fi

# Verify detects the problem
if verify_migration_rowcounts "$e2e_db" "$e2e_backup" "tasks" 2>/dev/null; then
    fail "verify_migration_rowcounts catches empty table"
else
    pass "verify_migration_rowcounts catches empty table"
fi

# Rollback
rollback_sqlite_db "$e2e_db" "$e2e_backup" 2>/dev/null
final_count=$(sqlite3 "$e2e_db" "SELECT count(*) FROM tasks;")
if [[ "$final_count" -eq 20 ]]; then
    pass "rollback restores all 20 rows after bad migration"
else
    fail "rollback restores all 20 rows after bad migration" "Expected 20, got $final_count"
fi

# ============================================================
section "Integration: supervisor-helper.sh backup command"
# ============================================================

# Test 15: supervisor backup command works
export AIDEVOPS_SUPERVISOR_DIR="$TEMP_DIR/supervisor"
mkdir -p "$AIDEVOPS_SUPERVISOR_DIR"
sup_db="$AIDEVOPS_SUPERVISOR_DIR/supervisor.db"

# Create a minimal supervisor DB
sqlite3 "$sup_db" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    repo TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'queued'
);
CREATE TABLE IF NOT EXISTS batches (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    concurrency INTEGER NOT NULL DEFAULT 4,
    status TEXT NOT NULL DEFAULT 'active'
);
CREATE TABLE IF NOT EXISTS batch_tasks (
    batch_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (batch_id, task_id)
);
CREATE TABLE IF NOT EXISTS state_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL,
    from_state TEXT NOT NULL,
    to_state TEXT NOT NULL,
    reason TEXT,
    timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO tasks (id, repo, description) VALUES ('t001', '/tmp/test', 'Test task');
INSERT INTO tasks (id, repo, description) VALUES ('t002', '/tmp/test', 'Another task');
SQL

sup_output=$("$SCRIPTS_DIR/supervisor-helper.sh" backup "test-t188" 2>&1)
if echo "$sup_output" | grep -q "backed up"; then
    pass "supervisor backup command succeeds"
else
    fail "supervisor backup command succeeds" "Output: $sup_output"
fi

# Verify backup file exists
sup_backup_count=$(ls -1 "$AIDEVOPS_SUPERVISOR_DIR"/supervisor-backup-*.db 2>/dev/null | wc -l | tr -d ' ')
if [[ "$sup_backup_count" -ge 1 ]]; then
    pass "supervisor backup creates file ($sup_backup_count backups)"
else
    fail "supervisor backup creates file" "Found $sup_backup_count backups"
fi

# ============================================================
# Summary
# ============================================================
echo ""
printf "\033[1m=== Results ===\033[0m\n"
printf "  Total: %d | \033[0;32mPass: %d\033[0m | \033[0;31mFail: %d\033[0m | \033[0;33mSkip: %d\033[0m\n" \
    "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    printf "\033[0;31mFAILED\033[0m\n"
    exit 1
fi

echo ""
printf "\033[0;32mALL TESTS PASSED\033[0m\n"
exit 0
