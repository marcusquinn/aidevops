#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# SQLite Backup-Before-Modify Pattern (t188)
# Provides safety net for non-git state (SQLite DBs, config files).
# Git workflow protects code files, but SQLite DBs, memory stores, and config
# files aren't version-controlled. This pattern: before any destructive
# operation (schema migration, bulk prune, consolidate), create a timestamped
# backup, verify the operation succeeded, and clean up old backups.
#
# Extracted from shared-constants.sh to keep that file < 2000 lines.
# Source shared-constants.sh (which sources this file) rather than sourcing
# this file directly — the include guard prevents double-loading.
#
# Usage:
#   backup_sqlite_db "$db_path" "pre-migrate-v2"     # Create backup
#   verify_sqlite_backup "$db_path" "$backup" "tasks" # Verify row counts
#   rollback_sqlite_db "$db_path" "$backup"           # Restore from backup
#   cleanup_sqlite_backups "$db_path" 5               # Keep last N backups
#
# The backup file path is echoed to stdout on success.

# cool — include guard prevents errors when sourced multiple times
[[ -n "${_SHARED_SQLITE_BACKUP_LOADED:-}" ]] && return 0
_SHARED_SQLITE_BACKUP_LOADED=1

# =============================================================================
# SQLite Backup-Before-Modify Pattern (t188)
# =============================================================================

# Default number of backups to retain per database
SQLITE_BACKUP_RETAIN_COUNT="${SQLITE_BACKUP_RETAIN_COUNT:-5}"

# Create a timestamped backup of a SQLite database.
# Uses SQLite .backup command for WAL-safe consistency, with cp fallback.
# Arguments:
#   $1 - database file path (required)
#   $2 - reason/label for the backup (default: "manual")
# Output: backup file path on stdout
# Returns: 0 on success, 1 on failure
backup_sqlite_db() {
	local db_path="$1"
	local reason="${2:-manual}"

	if [[ ! -f "$db_path" ]]; then
		echo "[backup] No database to backup at: $db_path" >&2
		return 1
	fi

	local db_dir
	db_dir="$(dirname "$db_path")"
	local db_name
	db_name="$(basename "$db_path" .db)"
	local timestamp
	timestamp=$(date -u +%Y%m%dT%H%M%SZ)
	local backup_file="${db_dir}/${db_name}-backup-${timestamp}-${reason}.db"

	# Use SQLite .backup for WAL-safe consistency
	if sqlite3 "$db_path" ".backup '$backup_file'" 2>/dev/null; then
		echo "$backup_file"
		return 0
	fi

	# Fallback to file copy if .backup fails
	if cp "$db_path" "$backup_file" 2>/dev/null; then
		# Also copy WAL/SHM if present for consistency
		[[ -f "${db_path}-wal" ]] && cp "${db_path}-wal" "${backup_file}-wal" 2>/dev/null || true
		[[ -f "${db_path}-shm" ]] && cp "${db_path}-shm" "${backup_file}-shm" 2>/dev/null || true
		echo "$backup_file"
		return 0
	fi

	echo "[backup] Failed to backup database: $db_path" >&2
	return 1
}

# Verify a SQLite backup by comparing row counts for specified tables.
# Arguments:
#   $1 - original database path (required)
#   $2 - backup database path (required)
#   $3 - space-separated list of table names to verify (required)
# Returns: 0 if all row counts match, 1 if mismatch or error
verify_sqlite_backup() {
	local db_path="$1"
	local backup_path="$2"
	local tables="$3"

	if [[ ! -f "$db_path" || ! -f "$backup_path" ]]; then
		echo "[backup] Cannot verify: missing database or backup file" >&2
		return 1
	fi

	local table
	for table in $tables; do
		local orig_count backup_count
		orig_count=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT count(*) FROM $table;" 2>/dev/null || echo "-1")
		backup_count=$(sqlite3 -cmd ".timeout 5000" "$backup_path" "SELECT count(*) FROM $table;" 2>/dev/null || echo "-1")

		if [[ "$orig_count" == "-1" || "$backup_count" == "-1" ]]; then
			echo "[backup] Cannot read table '$table' from database or backup" >&2
			return 1
		fi

		if [[ "$orig_count" -lt "$backup_count" ]]; then
			echo "[backup] Row count DECREASED for '$table': was $backup_count, now $orig_count" >&2
			return 1
		fi
	done

	return 0
}

# Verify a migration preserved row counts (compare current DB against backup).
# Unlike verify_sqlite_backup which checks backup integrity, this checks that
# the migration didn't lose data.
# Arguments:
#   $1 - database path (post-migration)
#   $2 - backup path (pre-migration)
#   $3 - space-separated list of table names to verify
# Returns: 0 if row counts match or increased, 1 if any decreased
verify_migration_rowcounts() {
	local db_path="$1"
	local backup_path="$2"
	local tables="$3"

	if [[ ! -f "$db_path" || ! -f "$backup_path" ]]; then
		echo "[backup] Cannot verify migration: missing database or backup file" >&2
		return 1
	fi

	local table
	for table in $tables; do
		local post_count pre_count
		post_count=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT count(*) FROM $table;" 2>/dev/null || echo "-1")
		pre_count=$(sqlite3 -cmd ".timeout 5000" "$backup_path" "SELECT count(*) FROM $table;" 2>/dev/null || echo "-1")

		if [[ "$post_count" == "-1" ]]; then
			echo "[backup] MIGRATION FAILURE: Cannot read table '$table' after migration" >&2
			return 1
		fi

		if [[ "$pre_count" == "-1" ]]; then
			# Backup table might not exist (new table added by migration)
			continue
		fi

		if [[ "$post_count" -lt "$pre_count" ]]; then
			echo "[backup] MIGRATION FAILURE: Row count DECREASED for '$table': was $pre_count, now $post_count" >&2
			return 1
		fi
	done

	return 0
}

# Restore a SQLite database from a backup file.
# Creates a safety backup of the current state before overwriting.
# Arguments:
#   $1 - database path to restore (required)
#   $2 - backup file to restore from (required)
# Returns: 0 on success, 1 on failure
rollback_sqlite_db() {
	local db_path="$1"
	local backup_path="$2"

	if [[ ! -f "$backup_path" ]]; then
		echo "[backup] Backup file not found: $backup_path" >&2
		return 1
	fi

	# Verify backup is valid SQLite
	if ! sqlite3 "$backup_path" "SELECT 1;" >/dev/null 2>&1; then
		echo "[backup] Backup file is not a valid SQLite database: $backup_path" >&2
		return 1
	fi

	# Safety: backup current state before overwriting (in case rollback itself is wrong)
	if [[ -f "$db_path" ]]; then
		backup_sqlite_db "$db_path" "pre-rollback" >/dev/null 2>&1 || true
	fi

	cp "$backup_path" "$db_path"
	[[ -f "${backup_path}-wal" ]] && cp "${backup_path}-wal" "${db_path}-wal" 2>/dev/null || true
	[[ -f "${backup_path}-shm" ]] && cp "${backup_path}-shm" "${db_path}-shm" 2>/dev/null || true

	# Remove stale WAL/SHM if backup didn't have them
	[[ ! -f "${backup_path}-wal" && -f "${db_path}-wal" ]] && rm -f "${db_path}-wal" 2>/dev/null || true
	[[ ! -f "${backup_path}-shm" && -f "${db_path}-shm" ]] && rm -f "${db_path}-shm" 2>/dev/null || true

	echo "[backup] Database restored from: $backup_path" >&2
	return 0
}

# Clean up old backups, keeping the most recent N.
# Arguments:
#   $1 - database path (used to derive backup file pattern)
#   $2 - number of backups to keep (default: SQLITE_BACKUP_RETAIN_COUNT)
# Returns: 0 always
cleanup_sqlite_backups() {
	local db_path="$1"
	local keep_count="${2:-$SQLITE_BACKUP_RETAIN_COUNT}"

	local db_dir
	db_dir="$(dirname "$db_path")"
	local db_name
	db_name="$(basename "$db_path" .db)"
	local pattern="${db_dir}/${db_name}-backup-*.db"

	# Count existing backups (glob in $pattern is intentional)
	local backup_count
	# shellcheck disable=SC2012,SC2086
	backup_count=$(ls -1 $pattern 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$backup_count" -gt "$keep_count" ]]; then
		local to_remove
		to_remove=$((backup_count - keep_count))
		# shellcheck disable=SC2012,SC2086
		ls -1t $pattern 2>/dev/null | tail -n "$to_remove" | while IFS= read -r old_backup; do
			rm -f "$old_backup" "${old_backup}-wal" "${old_backup}-shm" 2>/dev/null || true
		done
	fi

	return 0
}
