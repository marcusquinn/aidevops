#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Session restore SQL and command for opencode-db-archive.sh.
# The entry point supplies configuration, schema/query and output helpers.
# Importing this module defines functions only; it never opens a database.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_OPENCODE_DB_ARCHIVE_RESTORE_LOADED:-}" ]] && return 0
_OPENCODE_DB_ARCHIVE_RESTORE_LOADED=1

# _archive_restore_column_list <table>
# Prints active-DB-ordered quoted columns shared by active and archive tables.
# Fails when the active table needs a NOT NULL/PK column the archive lacks.
_archive_restore_column_list() {
	local table_name="$1"
	local result columns missing
	result=$(sqlite3 -cmd '.timeout 5000' "$ACTIVE_DB" "
ATTACH DATABASE $(_archive_sql_quote "$ARCHIVE_DB") AS archive;
SELECT COALESCE((SELECT group_concat(quoted, ',') FROM (
  SELECT '\"' || a.name || '\"' AS quoted FROM pragma_table_info('${table_name}') a
  JOIN pragma_table_info('${table_name}', 'archive') b ON b.name = a.name ORDER BY a.cid)), '')
  || '|' || COALESCE((SELECT group_concat(a.name, ',') FROM pragma_table_info('${table_name}') a
  LEFT JOIN pragma_table_info('${table_name}', 'archive') b ON b.name = a.name
  WHERE b.name IS NULL AND (a.pk > 0 OR (a.\"notnull\" = 1 AND a.dflt_value IS NULL))), '');" 2>/dev/null) || return 1
	columns="${result%%|*}"
	missing="${result#*|}"
	[[ -n "$columns" && -z "$missing" ]] || return 1
	printf '%s\n' "$columns"
	return 0
}

# _archive_restore_tables
# Session-owned tables present in both DBs, in dependency-safe copy order.
_archive_restore_tables() {
	local table_name
	for table_name in message part todo session_share session_message session_input session_context_epoch; do
		_sqlite_has_table "$ACTIVE_DB" "$table_name" || continue
		_sqlite_has_table "$ARCHIVE_DB" "$table_name" || continue
		printf '%s\n' "$table_name"
	done
	return 0
}

# _archive_restore_sql <session_id_sql>
# Builds the copy-then-delete SQL for one archived session and its subagent
# children. Copies use INSERT OR IGNORE so rows already active win.
_archive_restore_sql() {
	local sid="$1"
	local ids="SELECT id FROM archive.session WHERE id = ${sid} OR parent_id = ${sid}"
	local copy_sql="" delete_sql="" table_name columns
	# Legacy active DBs cannot represent newer epoch values. Default values
	# can be omitted, but never delete a non-default archive-only value.
	local epoch_column epoch_default epoch_nondefault
	if _sqlite_has_table "$ACTIVE_DB" session_context_epoch && _sqlite_has_table "$ARCHIVE_DB" session_context_epoch; then
		while IFS='|' read -r epoch_column epoch_default; do
			_sqlite_has_column "$ARCHIVE_DB" session_context_epoch "$epoch_column" || continue
			_sqlite_has_column "$ACTIVE_DB" session_context_epoch "$epoch_column" && continue
			epoch_nondefault=$(sqlite3 -readonly "$ARCHIVE_DB" "SELECT COUNT(*) FROM session_context_epoch WHERE session_id IN (SELECT id FROM session WHERE id = ${sid} OR parent_id = ${sid}) AND ${epoch_column} IS NOT ${epoch_default};") || return 1
			[[ "$epoch_nondefault" == 0 ]] || return 1
		done <<'EPOCH_DEFAULTS'
replacement_seq|NULL
revision|0
agent|'build'
EPOCH_DEFAULTS
	fi
	columns=$(_archive_restore_column_list project) || return 1
	copy_sql="INSERT OR IGNORE INTO main.project (${columns}) SELECT ${columns} FROM archive.project WHERE id IN (SELECT project_id FROM archive.session WHERE id = ${sid});"$'\n'
	columns=$(_archive_restore_column_list "$SESSION_TABLE_NAME") || return 1
	copy_sql="${copy_sql}INSERT OR IGNORE INTO main.session (${columns}) SELECT ${columns} FROM archive.session WHERE id IN (${ids}) ORDER BY parent_id IS NOT NULL;"$'\n'
	while IFS= read -r table_name; do
		[[ -n "$table_name" ]] || continue
		columns=$(_archive_restore_column_list "$table_name") || return 1
		copy_sql="${copy_sql}INSERT OR IGNORE INTO main.${table_name} (${columns}) SELECT ${columns} FROM archive.${table_name} WHERE session_id IN (${ids});"$'\n'
		delete_sql="DELETE FROM archive.${table_name} WHERE session_id IN (${ids});"$'\n'"${delete_sql}"
	done <<<"$(_archive_restore_tables)"
	for table_name in event_sequence "$EVENT_TABLE_NAME"; do
		_sqlite_has_table "$ACTIVE_DB" "$table_name" || continue
		_sqlite_has_table "$ARCHIVE_DB" "$table_name" || continue
		columns=$(_archive_restore_column_list "$table_name") || return 1
		copy_sql="${copy_sql}INSERT OR IGNORE INTO main.${table_name} (${columns}) SELECT ${columns} FROM archive.${table_name} WHERE aggregate_id IN (${ids});"$'\n'
		delete_sql="DELETE FROM archive.${table_name} WHERE aggregate_id IN (${ids});"$'\n'"${delete_sql}"
	done
	printf '%s%sDELETE FROM archive.session WHERE id IN (%s);\n' "$copy_sql" "$delete_sql" "$ids"
	return 0
}

# cmd_restore --session ID [--dry-run]
# Move one archived session (plus subagent children) back into the active DB so
# OpenCode can resume it. Safe with live holders: it is a short write
# transaction, like the headless worker merge. Exit 0 restored/already active,
# 4 not found in the archive, 3 incompatible schema, 1 other failure.
cmd_restore() {
	local session_id="" dry_run=0 sid active_count archived_count restore_sql archive_sql
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--session)
			session_id="${2:-}"
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		*)
			print_error "Unknown restore option: $option"
			return 1
			;;
		esac
	done
	if [[ ! "$session_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
		print_error "restore requires --session <id> (letters, digits, '_' or '-')"
		return 1
	fi
	check_sqlite3 || return 1
	check_active_db || return 1
	sid=$(_archive_sql_quote "$session_id")
	active_count=$(sqlite3 -cmd '.timeout 5000' "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE id = ${sid};") || return 1
	if [[ "$active_count" == "1" ]]; then
		print_info "Session ${session_id} is already in the active DB"
		return 0
	fi
	if [[ ! -f "$ARCHIVE_DB" ]] || [[ "$ARCHIVE_DB" -ef "$ACTIVE_DB" ]]; then
		print_warning "No archive DB for ${ACTIVE_DB}; session ${session_id} not found"
		return 4
	fi
	archived_count=$(sqlite3 -readonly -cmd '.timeout 5000' "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE id = ${sid} OR parent_id = ${sid};") || return 1
	if [[ "$archived_count" == "0" ]] || [[ -z "$archived_count" ]]; then
		print_warning "Session ${session_id} not found in archive ${ARCHIVE_DB}"
		return 4
	fi
	if ! restore_sql=$(_archive_restore_sql "$sid"); then
		print_error "Archive and active schemas are incompatible for restore; nothing changed"
		return 3
	fi
	if ((dry_run)); then
		print_info "DRY RUN — would restore ${archived_count} session(s) (${session_id} and subagent children) from ${ARCHIVE_DB}"
		return 0
	fi
	archive_sql=$(_archive_sql_quote "$ARCHIVE_DB")
	if ! sqlite3 "$ACTIVE_DB" <<RESTORE_SQL >/dev/null; then
.bail on
.timeout 5000
ATTACH DATABASE ${archive_sql} AS archive;
BEGIN IMMEDIATE;
${restore_sql}
COMMIT;
DETACH DATABASE archive;
RESTORE_SQL
		print_error "Restore of ${session_id} failed; the archive copy was left in place"
		return 1
	fi
	print_success "Restored ${archived_count} session(s) (${session_id} and subagent children) to ${ACTIVE_DB}"
	return 0
}
