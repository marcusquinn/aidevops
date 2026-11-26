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

# _archive_restore_select_columns <table> <quoted-column-list>
# Prints the SELECT list for a restore copy. Events archived from a legacy
# active DB have no created value; when the session-inbox generation requires
# one (NOT NULL), INSERT OR IGNORE would silently drop those rows before the
# archive copy is deleted. Fall back to the owning session's time_updated.
_archive_restore_select_columns() {
	local table_name="$1"
	local columns="$2"
	local created_notnull=""
	local created_fallback='COALESCE("created", (SELECT s.time_updated FROM archive.session s WHERE s.id = aggregate_id), 0)'

	if [[ "$table_name" == "$EVENT_TABLE_NAME" && ",${columns}," == *',"created",'* ]]; then
		created_notnull=$(sqlite3 "$ACTIVE_DB" "SELECT \"notnull\" FROM pragma_table_info('${table_name}') WHERE name='created';" 2>/dev/null) || return 1
		if [[ "$created_notnull" == "1" ]]; then
			printf '%s\n' "${columns/\"created\"/$created_fallback}"
			return 0
		fi
	fi
	printf '%s\n' "$columns"
	return 0
}

# _archive_restore_tables
# Session-owned tables present in both DBs, in dependency-safe copy order.
_archive_restore_tables() {
	local table_name
	for table_name in message part todo session_share session_message session_input session_context_epoch $OPENCODE_ARCHIVE_INBOX_SESSION_TABLES; do
		_sqlite_has_table "$ACTIVE_DB" "$table_name" || continue
		_sqlite_has_table "$ARCHIVE_DB" "$table_name" || continue
		printf '%s\n' "$table_name"
	done
	return 0
}

# _archive_restore_sql <session_id_sql> [exact]
# Builds the copy-then-delete SQL for one archived session and its subagent
# children. Copies use INSERT OR IGNORE so rows already active win.
_archive_restore_sql() {
	local sid="$1"
	local exact="${2:-0}"
	local session_filter="id = ${sid}"
	[[ "$exact" == 1 ]] || session_filter="${session_filter} OR parent_id = ${sid}"
	local ids="SELECT id FROM archive.session WHERE ${session_filter}"
	local copy_sql="" delete_sql="" table_name columns select_columns
	# Legacy active DBs cannot represent newer epoch values. Default values
	# can be omitted, but never delete a non-default archive-only value.
	local epoch_column epoch_default epoch_nondefault
	if _sqlite_has_table "$ACTIVE_DB" session_context_epoch && _sqlite_has_table "$ARCHIVE_DB" session_context_epoch; then
		while IFS='|' read -r epoch_column epoch_default; do
			_sqlite_has_column "$ARCHIVE_DB" session_context_epoch "$epoch_column" || continue
			_sqlite_has_column "$ACTIVE_DB" session_context_epoch "$epoch_column" && continue
			epoch_nondefault=$(sqlite3 -readonly "$ARCHIVE_DB" "SELECT COUNT(*) FROM session_context_epoch WHERE session_id IN (SELECT id FROM session WHERE ${session_filter}) AND ${epoch_column} IS NOT ${epoch_default};") || return 1
			[[ "$epoch_nondefault" == 0 ]] || return 1
		done <<'EPOCH_DEFAULTS'
replacement_seq|NULL
revision|0
agent|'build'
EPOCH_DEFAULTS
	fi
	# Session tables absent from the active DB are skipped by the copy; refuse
	# the restore rather than strand populated archive rows for this session.
	local populated
	for table_name in session_input session_context_epoch $OPENCODE_ARCHIVE_INBOX_SESSION_TABLES; do
		_sqlite_has_table "$ARCHIVE_DB" "$table_name" || continue
		_sqlite_has_table "$ACTIVE_DB" "$table_name" && continue
		populated=$(sqlite3 -readonly "$ARCHIVE_DB" "SELECT COUNT(*) FROM ${table_name} WHERE session_id IN (SELECT id FROM session WHERE ${session_filter});") || return 1
		[[ "$populated" == 0 ]] || return 1
	done
	columns=$(_archive_restore_column_list project) || return 1
	copy_sql="INSERT OR IGNORE INTO main.project (${columns}) SELECT ${columns} FROM archive.project WHERE id IN (SELECT project_id FROM archive.session WHERE ${session_filter});"$'\n'
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
		# Legacy active event tables cannot store created; never delete an
		# archive event whose non-null created value would not be copied.
		if [[ "$table_name" == "$EVENT_TABLE_NAME" ]] && _sqlite_has_column "$ARCHIVE_DB" "$table_name" created && ! _sqlite_has_column "$ACTIVE_DB" "$table_name" created; then
			epoch_nondefault=$(sqlite3 -readonly "$ARCHIVE_DB" "SELECT COUNT(*) FROM ${table_name} WHERE created IS NOT NULL AND aggregate_id IN (SELECT id FROM session WHERE ${session_filter});") || return 1
			[[ "$epoch_nondefault" == 0 ]] || return 1
		fi
		select_columns=$(_archive_restore_select_columns "$table_name" "$columns") || return 1
		copy_sql="${copy_sql}INSERT OR IGNORE INTO main.${table_name} (${columns}) SELECT ${select_columns} FROM archive.${table_name} WHERE aggregate_id IN (${ids});"$'\n'
		delete_sql="DELETE FROM archive.${table_name} WHERE aggregate_id IN (${ids});"$'\n'"${delete_sql}"
	done
	# A sealed segment is immutable: copy only, never delete from it.
	if opencode_archive_is_sealed "$ARCHIVE_DB" "$ARCHIVE_LEGACY_DB"; then
		printf '%s' "$copy_sql"
		return 0
	fi
	printf '%s%sDELETE FROM archive.session WHERE id IN (%s);\n' "$copy_sql" "$delete_sql" "$ids"
	return 0
}

# _archive_restore_select_segment <session_id_sql>
# Points ARCHIVE_DB at the newest segment holding this exact session ID.
_archive_restore_select_segment() {
	local sid="$1"
	local segment found="" count
	while IFS= read -r segment; do
		[[ -n "$segment" ]] || continue
		count=$(sqlite3 -readonly -cmd '.timeout 5000' "$segment" "SELECT COUNT(*) FROM session WHERE id = ${sid};" 2>/dev/null) || continue
		[[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] && found="$segment"
	done <<<"$(opencode_archive_segments "$ARCHIVE_LEGACY_DB")"
	[[ -n "$found" ]] || return 1
	ARCHIVE_DB="$found"
	return 0
}

# Collect direct children across all segments, independent of parent location.
_archive_restore_children() {
	local sid="$1"
	local segment=""
	while IFS= read -r segment; do
		[[ -n "$segment" ]] || continue
		sqlite3 -readonly -cmd '.timeout 5000' "$segment" "SELECT id FROM session WHERE parent_id = ${sid} AND id != ${sid};" || return 1
	done <<<"$(opencode_archive_segments "$ARCHIVE_LEGACY_DB")"
	return 0
}

# cmd_restore --session ID [--dry-run]
# Move one archived session (plus subagent children) back into the active DB so
# OpenCode can resume it. Each session uses a short write transaction, parent
# first; retries finish any remaining children. Exit 0 restored/already active,
# 4 not found in the archive, 3 incompatible schema, 1 other failure.
cmd_restore() {
	local session_id="" dry_run=0 sid active_count restore_sql archive_sql
	local children="" child="" restore_id="" index=0
	local restore_segments=() restore_statements=()
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
	if ! _archive_restore_select_segment "$sid" && [[ "$active_count" != 1 ]]; then
		print_warning "Session ${session_id} not found in archive"
		return 4
	fi
	children=$(_archive_restore_children "$sid") || return 1
	children=$(printf '%s\n' "$children" | sort -u)
	# Preflight every selected copy before changing any DB. Parent first permits
	# split families; choosing each ID independently makes newest copies win.
	while IFS= read -r restore_id; do
		[[ -n "$restore_id" ]] || continue
		child=$(_archive_sql_quote "$restore_id")
		_archive_restore_select_segment "$child" || continue
		[[ "$ARCHIVE_DB" -ef "$ACTIVE_DB" ]] && return 1
		if ! restore_sql=$(_archive_restore_sql "$child" 1); then
			print_error "Archive and active schemas are incompatible for restore; nothing changed"
			return 3
		fi
		restore_segments+=("$ARCHIVE_DB")
		restore_statements+=("$restore_sql")
	done <<<"${session_id}
${children}"
	if ((${#restore_segments[@]} == 0)); then
		print_info "Session ${session_id} is already in the active DB"
		return 0
	fi
	if ((dry_run)); then
		print_info "DRY RUN — would restore ${#restore_segments[@]} session(s) (${session_id} and subagent children) across archive segments"
		return 0
	fi
	for ((index = 0; index < ${#restore_segments[@]}; index++)); do
		archive_sql=$(_archive_sql_quote "${restore_segments[index]}")
		restore_sql="${restore_statements[index]}"
		if ! sqlite3 "$ACTIVE_DB" <<RESTORE_SQL >/dev/null; then
.bail on
.timeout 5000
ATTACH DATABASE ${archive_sql} AS archive;
BEGIN IMMEDIATE;
${restore_sql}
COMMIT;
DETACH DATABASE archive;
RESTORE_SQL
			print_error "Restore of ${session_id} failed; remaining archive copies were left in place; retry to complete the family"
			return 1
		fi
	done
	print_success "Restored ${#restore_segments[@]} session(s) (${session_id} and subagent children) to ${ACTIVE_DB}"
	return 0
}
