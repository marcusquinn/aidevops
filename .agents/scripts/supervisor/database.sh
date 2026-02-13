#!/usr/bin/env bash
# database.sh - Database initialization, migration, and backup functions
#
# Functions for database schema management, migrations, and backups


#######################################
# Backup supervisor database before destructive operations (t162, t188)
# Delegates to shared backup_sqlite_db() from shared-constants.sh.
# Usage: backup_db [reason]
#######################################
backup_db() {
	local reason="${1:-manual}"
	local backup_file

	backup_file=$(backup_sqlite_db "$SUPERVISOR_DB" "$reason")
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		log_error "Failed to backup database"
		return 1
	fi

	log_success "Database backed up: $backup_file"

	# Prune old backups: keep last 5
	cleanup_sqlite_backups "$SUPERVISOR_DB" 5

	echo "$backup_file"
	return 0
}

#######################################
# Run a schema migration with backup, verification, and rollback (t188)
# Wraps the backup-migrate-verify pattern to prevent silent data loss.
# Reads migration SQL from stdin to avoid quoting issues with heredocs.
#
# Usage:
#   safe_migrate "t180" "tasks" <<'SQL'
#   ALTER TABLE tasks ADD COLUMN new_col TEXT;
#   SQL
#
# Arguments:
#   $1 - migration label (e.g., "t180", "t128.8")
#   $2 - space-separated list of tables to verify row counts for
#   stdin - migration SQL
#
# Returns: 0 on success, 1 on failure (with automatic rollback)
#######################################
safe_migrate() {
	local label="$1"
	local verify_tables="$2"
	local migration_sql
	migration_sql=$(cat)

	log_info "Migrating database schema ($label)..."

	# Step 1: Backup before migration
	local backup_file
	backup_file=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-${label}")
	if [[ $? -ne 0 || -z "$backup_file" ]]; then
		log_error "Backup failed for migration $label — aborting migration"
		return 1
	fi
	log_info "Pre-migration backup: $backup_file"

	# Step 2: Run the migration
	if ! db "$SUPERVISOR_DB" "$migration_sql"; then
		log_error "Migration $label FAILED — rolling back from backup"
		rollback_sqlite_db "$SUPERVISOR_DB" "$backup_file"
		return 1
	fi

	# Step 3: Verify row counts didn't decrease
	if ! verify_migration_rowcounts "$SUPERVISOR_DB" "$backup_file" "$verify_tables"; then
		log_error "Migration $label VERIFICATION FAILED — row counts decreased, rolling back"
		rollback_sqlite_db "$SUPERVISOR_DB" "$backup_file"
		return 1
	fi

	log_success "Database schema migrated ($label) — row counts verified"
	cleanup_sqlite_backups "$SUPERVISOR_DB" 5
	return 0
}

#######################################
# Restore supervisor database from backup (t162)
# Usage: restore_db [backup_file]
# If no file specified, lists available backups
#######################################
restore_db() {
	local backup_file="${1:-}"

	if [[ -z "$backup_file" ]]; then
		log_info "Available backups:"
		# shellcheck disable=SC2012
		ls -1t "$SUPERVISOR_DIR"/supervisor-backup-*.db 2>/dev/null | while IFS= read -r f; do
			local size
			size=$(du -h "$f" 2>/dev/null | cut -f1)
			local task_count
			task_count=$(sqlite3 "$f" "SELECT count(*) FROM tasks;" 2>/dev/null || echo "?")
			echo "  $f ($size, $task_count tasks)"
		done
		return 0
	fi

	if [[ ! -f "$backup_file" ]]; then
		log_error "Backup file not found: $backup_file"
		return 1
	fi

	# Verify backup is valid SQLite
	if ! sqlite3 "$backup_file" "SELECT count(*) FROM tasks;" >/dev/null 2>&1; then
		log_error "Backup file is not a valid supervisor database: $backup_file"
		return 1
	fi

	# Backup current DB before overwriting
	if [[ -f "$SUPERVISOR_DB" ]]; then
		backup_db "pre-restore" >/dev/null 2>&1 || true
	fi

	cp "$backup_file" "$SUPERVISOR_DB"
	[[ -f "${backup_file}-wal" ]] && cp "${backup_file}-wal" "${SUPERVISOR_DB}-wal" 2>/dev/null || true
	[[ -f "${backup_file}-shm" ]] && cp "${backup_file}-shm" "${SUPERVISOR_DB}-shm" 2>/dev/null || true

	local task_count
	task_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")
	local batch_count
	batch_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM batches;")

	log_success "Database restored from: $backup_file"
	log_info "Tasks: $task_count | Batches: $batch_count"
	return 0
}

#######################################
# Ensure supervisor directory and DB exist
#######################################
ensure_db() {
	if [[ ! -d "$SUPERVISOR_DIR" ]]; then
		mkdir -p "$SUPERVISOR_DIR"
	fi

	if [[ ! -f "$SUPERVISOR_DB" ]]; then
		init_db
		return 0
	fi

	# Check if schema needs upgrade
	local has_tasks
	has_tasks=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='tasks';")
	if [[ "$has_tasks" -eq 0 ]]; then
		init_db
	fi

	# Migrate: add post-PR lifecycle states if CHECK constraint is outdated (t128.8)
	# SQLite doesn't support ALTER CHECK, so we recreate the constraint via a temp table
	# Note: uses dynamic column lists so cannot use safe_migrate() directly (t188)
	local check_sql
	check_sql=$(db "$SUPERVISOR_DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks';" 2>/dev/null || echo "")
	if [[ -n "$check_sql" ]] && ! echo "$check_sql" | grep -q 'pr_review'; then
		log_info "Migrating database schema for post-PR lifecycle states (t128.8)..."

		# Backup before migration (t188: fail-safe — abort if backup fails)
		local t128_backup
		t128_backup=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-t128.8")
		if [[ $? -ne 0 || -z "$t128_backup" ]]; then
			log_error "Backup failed for t128.8 migration — aborting"
			return 1
		fi

		# Detect which optional columns exist in the old table to preserve data (t162)
		local has_issue_url_col has_diagnostic_of_col has_triage_result_col
		has_issue_url_col=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='issue_url';" 2>/dev/null || echo "0")
		has_diagnostic_of_col=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='diagnostic_of';" 2>/dev/null || echo "0")
		has_triage_result_col=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='triage_result';" 2>/dev/null || echo "0")

		# Build column lists dynamically based on what exists
		local insert_cols="id, repo, description, status, session_id, worktree, branch, log_file, retries, max_retries, model, error, pr_url, created_at, started_at, completed_at, updated_at"
		local select_cols="$insert_cols"
		[[ "$has_issue_url_col" -gt 0 ]] && {
			insert_cols="$insert_cols, issue_url"
			select_cols="$select_cols, issue_url"
		}
		[[ "$has_diagnostic_of_col" -gt 0 ]] && {
			insert_cols="$insert_cols, diagnostic_of"
			select_cols="$select_cols, diagnostic_of"
		}
		[[ "$has_triage_result_col" -gt 0 ]] && {
			insert_cols="$insert_cols, triage_result"
			select_cols="$select_cols, triage_result"
		}

		db "$SUPERVISOR_DB" <<MIGRATE
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
ALTER TABLE tasks RENAME TO tasks_old;
CREATE TABLE tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','verifying','verified','verify_failed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    issue_url       TEXT,
    diagnostic_of   TEXT,
    triage_result   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO tasks ($insert_cols)
SELECT $select_cols
FROM tasks_old;
DROP TABLE tasks_old;
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);
CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);
COMMIT;
PRAGMA foreign_keys=ON;
MIGRATE

		# Verify row counts after migration (t188)
		if ! verify_migration_rowcounts "$SUPERVISOR_DB" "$t128_backup" "tasks"; then
			log_error "t128.8 migration VERIFICATION FAILED — rolling back"
			rollback_sqlite_db "$SUPERVISOR_DB" "$t128_backup"
			return 1
		fi
		log_success "Database schema migrated for post-PR lifecycle states (verified)"
	fi

	# Backup before ALTER TABLE migrations if any are needed (t162, t188)
	local needs_alter_migration=false
	local has_max_load has_release_on_complete has_diagnostic_of has_issue_url has_max_concurrency
	has_max_load=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='max_load_factor';" 2>/dev/null || echo "0")
	has_release_on_complete=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='release_on_complete';" 2>/dev/null || echo "0")
	has_diagnostic_of=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='diagnostic_of';" 2>/dev/null || echo "0")
	has_issue_url=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='issue_url';" 2>/dev/null || echo "0")
	has_max_concurrency=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='max_concurrency';" 2>/dev/null || echo "0")
	if [[ "$has_max_load" -eq 0 || "$has_release_on_complete" -eq 0 || "$has_diagnostic_of" -eq 0 || "$has_issue_url" -eq 0 || "$has_max_concurrency" -eq 0 ]]; then
		needs_alter_migration=true
	fi
	if [[ "$needs_alter_migration" == "true" ]]; then
		local alter_backup
		alter_backup=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-alter-columns")
		if [[ $? -ne 0 || -z "$alter_backup" ]]; then
			log_warn "Backup failed for ALTER TABLE migrations, proceeding cautiously"
		fi
	fi

	# Migrate: add max_load_factor column to batches if missing (t135.15.4)
	if [[ "$has_max_load" -eq 0 ]]; then
		log_info "Migrating batches table: adding max_load_factor column (t135.15.4)..."
		if ! log_cmd "db-migrate" db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN max_load_factor INTEGER NOT NULL DEFAULT 2;"; then
			log_warn "Failed to add max_load_factor column (may already exist)"
		else
			log_success "Added max_load_factor column to batches"
		fi
	fi

	# Migrate: add max_concurrency column to batches if missing (adaptive scaling cap)
	if [[ "$has_max_concurrency" -eq 0 ]]; then
		log_info "Migrating batches table: adding max_concurrency column..."
		db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN max_concurrency INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
		log_success "Added max_concurrency column to batches (0 = auto-detect from cpu_cores)"
	fi

	# Migrate: add release_on_complete and release_type columns to batches if missing (t128.10)
	if [[ "$has_release_on_complete" -eq 0 ]]; then
		log_info "Migrating batches table: adding release columns (t128.10)..."
		db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN release_on_complete INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
		db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN release_type TEXT NOT NULL DEFAULT 'patch';" 2>/dev/null || true
		log_success "Added release_on_complete and release_type columns to batches"
	fi

	# Migrate: add diagnostic_of column to tasks if missing (t150)
	if [[ "$has_diagnostic_of" -eq 0 ]]; then
		log_info "Migrating tasks table: adding diagnostic_of column (t150)..."
		db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN diagnostic_of TEXT;" 2>/dev/null || true
		db "$SUPERVISOR_DB" "CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);" 2>/dev/null || true
		log_success "Added diagnostic_of column to tasks"
	fi

	# Migrate: add issue_url column (t149)
	if [[ "$has_issue_url" -eq 0 ]]; then
		log_info "Migrating tasks table: adding issue_url column (t149)..."
		db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN issue_url TEXT;" 2>/dev/null || true
		log_success "Added issue_url column to tasks"
	fi

	# Migrate: add triage_result column to tasks if missing (t148)
	local has_triage_result
	has_triage_result=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='triage_result';" 2>/dev/null || echo "0")
	if [[ "$has_triage_result" -eq 0 ]]; then
		log_info "Migrating tasks table: adding triage_result column (t148)..."
		db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN triage_result TEXT;" 2>/dev/null || true
		log_success "Added triage_result column to tasks"
	fi

	# Migrate: add review_triage to CHECK constraint if missing (t148)
	local check_sql_t148
	check_sql_t148=$(db "$SUPERVISOR_DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks';" 2>/dev/null || echo "")
	if [[ -n "$check_sql_t148" ]] && ! echo "$check_sql_t148" | grep -q 'review_triage'; then
		log_info "Migrating database schema for review_triage state (t148)..."

		# Backup before migration (t188: fail-safe — abort if backup fails)
		local t148_backup
		t148_backup=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-t148")
		if [[ $? -ne 0 || -z "$t148_backup" ]]; then
			log_error "Backup failed for t148 migration — aborting"
			return 1
		fi

		db "$SUPERVISOR_DB" <<'MIGRATE_T148'
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
ALTER TABLE tasks RENAME TO tasks_old_t148;
CREATE TABLE tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','verifying','verified','verify_failed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    issue_url       TEXT,
    diagnostic_of   TEXT,
    triage_result   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO tasks (id, repo, description, status, session_id, worktree, branch,
    log_file, retries, max_retries, model, error, pr_url, issue_url, diagnostic_of,
    created_at, started_at, completed_at, updated_at)
SELECT id, repo, description, status, session_id, worktree, branch,
    log_file, retries, max_retries, model, error, pr_url, issue_url, diagnostic_of,
    created_at, started_at, completed_at, updated_at
FROM tasks_old_t148;
DROP TABLE tasks_old_t148;
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);
CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);
COMMIT;
PRAGMA foreign_keys=ON;
MIGRATE_T148

		# Verify row counts after migration (t188)
		if ! verify_migration_rowcounts "$SUPERVISOR_DB" "$t148_backup" "tasks"; then
			log_error "t148 migration VERIFICATION FAILED — rolling back"
			rollback_sqlite_db "$SUPERVISOR_DB" "$t148_backup"
			return 1
		fi
		log_success "Database schema migrated for review_triage state (verified)"
	fi

	# Migration: add verifying/verified/verify_failed states to CHECK constraint (t180)
	# Check if the current schema already supports verify states
	# NOTE: This migration originally used "INSERT INTO tasks SELECT * FROM tasks_old_t180"
	# which silently fails if column counts don't match. Fixed in t188 to use explicit
	# column lists and row-count verification with automatic rollback.
	local has_verify_states
	has_verify_states=$(db "$SUPERVISOR_DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks';" 2>/dev/null || echo "")
	if [[ -n "$has_verify_states" ]] && ! echo "$has_verify_states" | grep -q "verifying"; then
		log_info "Migrating database schema for post-merge verification states (t180)..."

		# Backup before migration (t188: fail-safe — abort if backup fails)
		local t180_backup
		t180_backup=$(backup_sqlite_db "$SUPERVISOR_DB" "pre-migrate-t180")
		if [[ $? -ne 0 || -z "$t180_backup" ]]; then
			log_error "Backup failed for t180 migration — aborting"
			return 1
		fi

		db "$SUPERVISOR_DB" <<'MIGRATE_T180'
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
ALTER TABLE tasks RENAME TO tasks_old_t180;
CREATE TABLE tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','verifying','verified','verify_failed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    issue_url       TEXT,
    diagnostic_of   TEXT,
    triage_result   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO tasks (id, repo, description, status, session_id, worktree, branch,
    log_file, retries, max_retries, model, error, pr_url, issue_url, diagnostic_of,
    triage_result, created_at, started_at, completed_at, updated_at)
SELECT id, repo, description, status, session_id, worktree, branch,
    log_file, retries, max_retries, model, error, pr_url, issue_url, diagnostic_of,
    triage_result, created_at, started_at, completed_at, updated_at
FROM tasks_old_t180;
DROP TABLE tasks_old_t180;
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);
COMMIT;
PRAGMA foreign_keys=ON;
MIGRATE_T180

		# Verify row counts after migration (t188)
		if ! verify_migration_rowcounts "$SUPERVISOR_DB" "$t180_backup" "tasks"; then
			log_error "t180 migration VERIFICATION FAILED — rolling back"
			rollback_sqlite_db "$SUPERVISOR_DB" "$t180_backup"
			return 1
		fi
		log_success "Database schema migrated for post-merge verification states"
	fi

	# Migrate: add escalation_depth and max_escalation columns to tasks (t132.6)
	local has_escalation_depth
	has_escalation_depth=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='escalation_depth';" 2>/dev/null || echo "0")
	if [[ "$has_escalation_depth" -eq 0 ]]; then
		log_info "Migrating tasks table: adding escalation columns (t132.6)..."
		db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN escalation_depth INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
		db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN max_escalation INTEGER NOT NULL DEFAULT 2;" 2>/dev/null || true
		log_success "Added escalation_depth and max_escalation columns to tasks"
	fi

	# Migrate: add skip_quality_gate column to batches (t132.6)
	local has_skip_quality_gate
	has_skip_quality_gate=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('batches') WHERE name='skip_quality_gate';" 2>/dev/null || echo "0")
	if [[ "$has_skip_quality_gate" -eq 0 ]]; then
		log_info "Migrating batches table: adding skip_quality_gate column (t132.6)..."
		db "$SUPERVISOR_DB" "ALTER TABLE batches ADD COLUMN skip_quality_gate INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
		log_success "Added skip_quality_gate column to batches"
	fi

	# Migrate: add proof_logs table if missing (t218)
	local has_proof_logs
	has_proof_logs=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='proof_logs';" 2>/dev/null || echo "0")
	if [[ "$has_proof_logs" -eq 0 ]]; then
		log_info "Migrating database: adding proof_logs table (t218)..."
		db "$SUPERVISOR_DB" <<'MIGRATE_T218'
CREATE TABLE IF NOT EXISTS proof_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         TEXT NOT NULL,
    event           TEXT NOT NULL,
    stage           TEXT,
    decision        TEXT,
    evidence        TEXT,
    decision_maker  TEXT,
    pr_url          TEXT,
    duration_secs   INTEGER,
    metadata        TEXT,
    timestamp       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_proof_logs_task ON proof_logs(task_id);
CREATE INDEX IF NOT EXISTS idx_proof_logs_event ON proof_logs(event);
CREATE INDEX IF NOT EXISTS idx_proof_logs_timestamp ON proof_logs(timestamp);
MIGRATE_T218
		log_success "Added proof_logs table (t218)"
	fi

	# Migrate: add deploying_recovery_attempts column to tasks (t263)
	local has_deploying_recovery
	has_deploying_recovery=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='deploying_recovery_attempts';" 2>/dev/null || echo "0")
	if [[ "$has_deploying_recovery" -eq 0 ]]; then
		log_info "Migrating tasks table: adding deploying_recovery_attempts column (t263)..."
		db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN deploying_recovery_attempts INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
		log_success "Added deploying_recovery_attempts column to tasks (t263)"
	fi

	# Migrate: add rebase_attempts column to tasks (t298)
	local has_rebase_attempts
	has_rebase_attempts=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='rebase_attempts';" 2>/dev/null || echo "0")
	if [[ "$has_rebase_attempts" -eq 0 ]]; then
		log_info "Migrating tasks table: adding rebase_attempts column (t298)..."
		db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN rebase_attempts INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
		log_success "Added rebase_attempts column to tasks (t298)"
	fi

	# Migrate: create contest tables if missing (t1011)
	local has_contests
	has_contests=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='contests';" 2>/dev/null || echo "0")
	if [[ "$has_contests" -eq 0 ]]; then
		log_info "Creating contest tables (t1011)..."
		local contest_helper="${SCRIPT_DIR}/contest-helper.sh"
		if [[ -x "$contest_helper" ]]; then
			"$contest_helper" help >/dev/null 2>&1 || true
			# contest-helper.sh ensure_contest_tables creates them on first use
			# but we can also create them here for immediate availability
			db "$SUPERVISOR_DB" <<'CONTEST_SQL'
CREATE TABLE IF NOT EXISTS contests (
    id              TEXT PRIMARY KEY,
    task_id         TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','dispatching','running','evaluating','scoring','complete','failed','cancelled')),
    winner_model    TEXT,
    winner_entry_id TEXT,
    winner_score    REAL,
    models          TEXT NOT NULL,
    batch_id        TEXT,
    repo            TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    completed_at    TEXT,
    metadata        TEXT
);
CREATE TABLE IF NOT EXISTS contest_entries (
    id              TEXT PRIMARY KEY,
    contest_id      TEXT NOT NULL,
    model           TEXT NOT NULL,
    task_id         TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    pr_url          TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','dispatched','running','complete','failed','cancelled')),
    output_summary  TEXT,
    score_correctness   REAL DEFAULT 0,
    score_completeness  REAL DEFAULT 0,
    score_code_quality  REAL DEFAULT 0,
    score_clarity       REAL DEFAULT 0,
    weighted_score      REAL DEFAULT 0,
    cross_rank_scores   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    completed_at    TEXT,
    FOREIGN KEY (contest_id) REFERENCES contests(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_contests_task ON contests(task_id);
CREATE INDEX IF NOT EXISTS idx_contests_status ON contests(status);
CREATE INDEX IF NOT EXISTS idx_contest_entries_contest ON contest_entries(contest_id);
CREATE INDEX IF NOT EXISTS idx_contest_entries_status ON contest_entries(status);
CONTEST_SQL
			log_success "Created contest tables (t1011)"
		fi
	fi

	# Migrate: add last_main_sha column to tasks (t1029)
	local has_last_main_sha
	has_last_main_sha=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM pragma_table_info('tasks') WHERE name='last_main_sha';" 2>/dev/null || echo "0")
	if [[ "$has_last_main_sha" -eq 0 ]]; then
		log_info "Migrating tasks table: adding last_main_sha column (t1029)..."
		db "$SUPERVISOR_DB" "ALTER TABLE tasks ADD COLUMN last_main_sha TEXT;" 2>/dev/null || true
		log_success "Added last_main_sha column to tasks (t1029)"
	fi

	# Ensure WAL mode for existing databases created before t135.3
	local current_mode
	current_mode=$(db "$SUPERVISOR_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		log_cmd "db-wal" db "$SUPERVISOR_DB" "PRAGMA journal_mode=WAL;" || log_warn "Failed to enable WAL mode"
	fi

	return 0
}

#######################################
# Initialize SQLite database with schema
#######################################
init_db() {
	mkdir -p "$SUPERVISOR_DIR"

	db "$SUPERVISOR_DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS tasks (
    id              TEXT PRIMARY KEY,
    repo            TEXT NOT NULL,
    description     TEXT,
    status          TEXT NOT NULL DEFAULT 'queued'
                    CHECK(status IN ('queued','dispatched','running','evaluating','retrying','complete','pr_review','review_triage','merging','merged','deploying','deployed','verifying','verified','verify_failed','blocked','failed','cancelled')),
    session_id      TEXT,
    worktree        TEXT,
    branch          TEXT,
    log_file        TEXT,
    retries         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    deploying_recovery_attempts INTEGER NOT NULL DEFAULT 0,
    model           TEXT DEFAULT 'anthropic/claude-opus-4-6',
    error           TEXT,
    pr_url          TEXT,
    issue_url       TEXT,
    diagnostic_of   TEXT,
    triage_result   TEXT,
    escalation_depth INTEGER NOT NULL DEFAULT 0,
    max_escalation  INTEGER NOT NULL DEFAULT 2,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at      TEXT,
    completed_at    TEXT,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repo);
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at);
CREATE INDEX IF NOT EXISTS idx_tasks_diagnostic ON tasks(diagnostic_of);

CREATE TABLE IF NOT EXISTS batches (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    concurrency     INTEGER NOT NULL DEFAULT 4,
    max_concurrency INTEGER NOT NULL DEFAULT 0,
    max_load_factor INTEGER NOT NULL DEFAULT 2,
    release_on_complete INTEGER NOT NULL DEFAULT 0,
    release_type    TEXT NOT NULL DEFAULT 'patch'
                    CHECK(release_type IN ('major','minor','patch')),
    skip_quality_gate INTEGER NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK(status IN ('active','paused','complete','cancelled')),
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_batches_status ON batches(status);

CREATE TABLE IF NOT EXISTS batch_tasks (
    batch_id        TEXT NOT NULL,
    task_id         TEXT NOT NULL,
    position        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (batch_id, task_id),
    FOREIGN KEY (batch_id) REFERENCES batches(id) ON DELETE CASCADE,
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_batch_tasks_batch ON batch_tasks(batch_id);
CREATE INDEX IF NOT EXISTS idx_batch_tasks_task ON batch_tasks(task_id);

CREATE TABLE IF NOT EXISTS state_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         TEXT NOT NULL,
    from_state      TEXT NOT NULL,
    to_state        TEXT NOT NULL,
    reason          TEXT,
    timestamp       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_state_log_task ON state_log(task_id);
CREATE INDEX IF NOT EXISTS idx_state_log_timestamp ON state_log(timestamp);

-- Proof-logs: structured audit trail for task completion trust (t218)
-- Each row is an immutable evidence record capturing what happened, what
-- evidence was used, and who/what made the decision. Enables:
--   - Trust verification: "why was this task marked complete?"
--   - Pipeline latency analysis: stage-level timing (t219 prep)
--   - Audit export: JSON/CSV for compliance or retrospective
CREATE TABLE IF NOT EXISTS proof_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         TEXT NOT NULL,
    event           TEXT NOT NULL,
    stage           TEXT,
    decision        TEXT,
    evidence        TEXT,
    decision_maker  TEXT,
    pr_url          TEXT,
    duration_secs   INTEGER,
    metadata        TEXT,
    timestamp       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_proof_logs_task ON proof_logs(task_id);
CREATE INDEX IF NOT EXISTS idx_proof_logs_event ON proof_logs(event);
CREATE INDEX IF NOT EXISTS idx_proof_logs_timestamp ON proof_logs(timestamp);
SQL

	log_success "Initialized supervisor database: $SUPERVISOR_DB"
	return 0
}

#######################################
# Initialize database (explicit command)
#######################################
cmd_init() {
	ensure_db
	log_success "Supervisor database ready at: $SUPERVISOR_DB"

	local task_count
	task_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks;")
	local batch_count
	batch_count=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM batches;")

	log_info "Tasks: $task_count | Batches: $batch_count"
	return 0
}

#######################################
# Backup supervisor database (t162)
#######################################
cmd_backup() {
	local reason="${1:-manual}"
	backup_db "$reason"
}

#######################################
# Restore supervisor database from backup (t162)
#######################################
cmd_restore() {
	local backup_file="${1:-}"
	restore_db "$backup_file"
}

#######################################
# Direct SQLite access for debugging
#######################################
cmd_db() {
	ensure_db

	if [[ $# -eq 0 ]]; then
		log_info "Opening interactive SQLite shell: $SUPERVISOR_DB"
		db -column -header "$SUPERVISOR_DB"
	else
		db -column -header "$SUPERVISOR_DB" "$*"
	fi

	return 0
}
