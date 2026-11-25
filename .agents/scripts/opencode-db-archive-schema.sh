#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Archive DB schema creation, migration and copy-SQL builders (GH#35510).
# Source only through opencode-db-archive.sh, which supplies configuration,
# SQLite helpers and output functions. No work runs on import.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_OPENCODE_DB_ARCHIVE_SCHEMA_LOADED:-}" ]] && return 0
_OPENCODE_DB_ARCHIVE_SCHEMA_LOADED=1

# --- Schema creation in archive DB -------------------------------------------

_archive_column_list_has() {
	local column_list="$1"
	local column_name="$2"

	[[ ",${column_list}," == *",${column_name},"* ]]
	return $?
}

_archive_migrate_schema_columns() {
	local archive_db="$1"
	local project_columns=""
	local session_columns=""
	local epoch_columns=""
	local event_columns=""
	local table_name=""
	local column_name=""
	local column_definition=""
	local table_columns=""
	local migration_sql=""
	local migrated_columns=""

	project_columns=$(opencode_db_table_columns "$archive_db" project) || return 1
	session_columns=$(opencode_db_table_columns "$archive_db" "$SESSION_TABLE_NAME") || return 1
	epoch_columns=$(opencode_db_table_columns "$archive_db" session_context_epoch) || return 1
	event_columns=$(opencode_db_table_columns "$archive_db" "$EVENT_TABLE_NAME") || return 1
	while IFS='|' read -r table_name column_name column_definition; do
		[[ -n "$table_name" && -n "$column_name" && -n "$column_definition" ]] || continue
		case "$table_name" in
		project) table_columns="$project_columns" ;;
		"$SESSION_TABLE_NAME") table_columns="$session_columns" ;;
		session_context_epoch) table_columns="$epoch_columns" ;;
		"$EVENT_TABLE_NAME") table_columns="$event_columns" ;;
		*) return 1 ;;
		esac
		if ! _archive_column_list_has "$table_columns" "$column_name"; then
			migration_sql="${migration_sql}ALTER TABLE ${table_name} ADD COLUMN ${column_name} ${column_definition};"
			migrated_columns="${migrated_columns}${migrated_columns:+,}${table_name}.${column_name}"
		fi
	done <<MIGRATION_COLUMNS
project|icon_url_override|${ARCHIVE_TEXT_COLUMN_DEFINITION}
${SESSION_TABLE_NAME}|path|${ARCHIVE_TEXT_COLUMN_DEFINITION}
${SESSION_TABLE_NAME}|agent|${ARCHIVE_TEXT_COLUMN_DEFINITION}
${SESSION_TABLE_NAME}|model|${ARCHIVE_TEXT_COLUMN_DEFINITION}
${SESSION_TABLE_NAME}|cost|real DEFAULT 0 NOT NULL
${SESSION_TABLE_NAME}|tokens_input|${ARCHIVE_INTEGER_COLUMN_DEFINITION}
${SESSION_TABLE_NAME}|tokens_output|${ARCHIVE_INTEGER_COLUMN_DEFINITION}
${SESSION_TABLE_NAME}|tokens_reasoning|${ARCHIVE_INTEGER_COLUMN_DEFINITION}
${SESSION_TABLE_NAME}|tokens_cache_read|${ARCHIVE_INTEGER_COLUMN_DEFINITION}
${SESSION_TABLE_NAME}|tokens_cache_write|${ARCHIVE_INTEGER_COLUMN_DEFINITION}
${SESSION_TABLE_NAME}|metadata|${ARCHIVE_TEXT_COLUMN_DEFINITION}
session_context_epoch|replacement_seq|integer
session_context_epoch|revision|integer DEFAULT 0 NOT NULL
session_context_epoch|agent|text DEFAULT 'build' NOT NULL
${EVENT_TABLE_NAME}|created|integer
MIGRATION_COLUMNS

	[[ -n "$migration_sql" ]] || return 0
	sqlite3 "$archive_db" <<MIGRATION_SQL
.bail on
BEGIN IMMEDIATE;
${migration_sql}
COMMIT;
MIGRATION_SQL
	print_info "Migrated archive schema columns: ${migrated_columns}"
	return 0
}

# Emit schema fragments into one SQLite connection and transaction.
_archive_core_schema_sql() {
	cat <<'SCHEMA_SQL'
.bail on
PRAGMA journal_mode=WAL;
BEGIN IMMEDIATE;

-- Mirror the active DB schema for archived data
CREATE TABLE IF NOT EXISTS `project` (
	`id` text PRIMARY KEY,
	`worktree` text NOT NULL,
	`vcs` text,
	`name` text,
	`icon_url` text,
	`icon_color` text,
	`time_created` integer NOT NULL,
	`time_updated` integer NOT NULL,
	`time_initialized` integer,
	`sandboxes` text NOT NULL,
	`commands` text,
	`icon_url_override` text
);

CREATE TABLE IF NOT EXISTS `session` (
	`id` text PRIMARY KEY,
	`project_id` text NOT NULL,
	`parent_id` text,
	`slug` text NOT NULL,
	`directory` text NOT NULL,
	`title` text NOT NULL,
	`version` text NOT NULL,
	`share_url` text,
	`summary_additions` integer,
	`summary_deletions` integer,
	`summary_files` integer,
	`summary_diffs` text,
	`revert` text,
	`permission` text,
	`time_created` integer NOT NULL,
	`time_updated` integer NOT NULL,
	`time_compacting` integer,
	`time_archived` integer,
	`workspace_id` text,
	`path` text,
	`agent` text,
	`model` text,
	`cost` real DEFAULT 0 NOT NULL,
	`tokens_input` integer DEFAULT 0 NOT NULL,
	`tokens_output` integer DEFAULT 0 NOT NULL,
	`tokens_reasoning` integer DEFAULT 0 NOT NULL,
	`tokens_cache_read` integer DEFAULT 0 NOT NULL,
	`tokens_cache_write` integer DEFAULT 0 NOT NULL,
	`metadata` text,
	CONSTRAINT `fk_session_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS `session_project_idx` ON `session` (`project_id`);
CREATE INDEX IF NOT EXISTS `session_parent_idx` ON `session` (`parent_id`);
CREATE INDEX IF NOT EXISTS `session_workspace_idx` ON `session` (`workspace_id`);

CREATE TABLE IF NOT EXISTS `message` (
	`id` text PRIMARY KEY,
	`session_id` text NOT NULL,
	`time_created` integer NOT NULL,
	`time_updated` integer NOT NULL,
	`data` text NOT NULL,
	CONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS `message_session_time_created_id_idx` ON `message` (`session_id`,`time_created`,`id`);

CREATE TABLE IF NOT EXISTS `part` (
	`id` text PRIMARY KEY,
	`message_id` text NOT NULL,
	`session_id` text NOT NULL,
	`time_created` integer NOT NULL,
	`time_updated` integer NOT NULL,
	`data` text NOT NULL,
	CONSTRAINT `fk_part_message_id_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `message`(`id`) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS `part_session_idx` ON `part` (`session_id`);
CREATE INDEX IF NOT EXISTS `part_message_id_id_idx` ON `part` (`message_id`,`id`);
SCHEMA_SQL
	return 0
}

_archive_session_schema_sql() {
	cat <<'SCHEMA_SQL'
CREATE TABLE IF NOT EXISTS `todo` (
	`session_id` text NOT NULL,
	`content` text NOT NULL,
	`status` text NOT NULL,
	`priority` text NOT NULL,
	`position` integer NOT NULL,
	`time_created` integer NOT NULL,
	`time_updated` integer NOT NULL,
	CONSTRAINT `todo_pk` PRIMARY KEY(`session_id`, `position`),
	CONSTRAINT `fk_todo_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS `todo_session_idx` ON `todo` (`session_id`);

CREATE TABLE IF NOT EXISTS `session_share` (
	`session_id` text PRIMARY KEY,
	`id` text NOT NULL,
	`secret` text NOT NULL,
	`url` text NOT NULL,
	`time_created` integer NOT NULL,
	`time_updated` integer NOT NULL,
	CONSTRAINT `fk_session_share_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS `session_message` (
	`id` text PRIMARY KEY,
	`session_id` text NOT NULL,
	`type` text NOT NULL,
	`time_created` integer NOT NULL,
	`time_updated` integer NOT NULL,
	`data` text NOT NULL,
	`seq` integer NOT NULL,
	CONSTRAINT `fk_session_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS `session_message_session_seq_idx` ON `session_message` (`session_id`,`seq`);
CREATE INDEX IF NOT EXISTS `session_message_session_time_created_id_idx` ON `session_message` (`session_id`,`time_created`,`id`);
CREATE INDEX IF NOT EXISTS `session_message_session_type_seq_idx` ON `session_message` (`session_id`,`type`,`seq`);
CREATE INDEX IF NOT EXISTS `session_message_time_created_idx` ON `session_message` (`time_created`);

CREATE TABLE IF NOT EXISTS `session_input` (
	`id` text PRIMARY KEY,
	`session_id` text NOT NULL,
	`prompt` text NOT NULL,
	`delivery` text NOT NULL,
	`admitted_seq` integer NOT NULL,
	`promoted_seq` integer,
	`time_created` integer NOT NULL,
	CONSTRAINT `fk_session_input_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS `session_input_session_admitted_seq_idx` ON `session_input` (`session_id`,`admitted_seq`);
CREATE INDEX IF NOT EXISTS `session_input_session_pending_delivery_seq_idx` ON `session_input` (`session_id`,`promoted_seq`,`delivery`,`admitted_seq`);
CREATE UNIQUE INDEX IF NOT EXISTS `session_input_session_promoted_seq_idx` ON `session_input` (`session_id`,`promoted_seq`);
SCHEMA_SQL
	return 0
}

# Session-inbox generation tables (OpenCode migrations 20260812181746_session_inbox
# .. 20260910120000_clear_v1_session_permission). Column constraints beyond keys
# are left permissive so every row the active DB accepts is also accepted here.
_archive_inbox_schema_sql() {
	cat <<'SCHEMA_SQL'
CREATE TABLE IF NOT EXISTS `session_inbox` (
	`id` text PRIMARY KEY,
	`session_id` text NOT NULL,
	`type` text,
	`payload` text,
	`delivery` text,
	`enqueued_seq` integer,
	`time_created` integer,
	CONSTRAINT `fk_session_inbox_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS `session_inbox_session_idx` ON `session_inbox` (`session_id`);

CREATE TABLE IF NOT EXISTS `session_pending` (
	`id` text PRIMARY KEY,
	`session_id` text NOT NULL,
	`type` text,
	`data` text,
	`delivery` text,
	`admitted_seq` integer,
	`time_created` integer,
	CONSTRAINT `fk_session_pending_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS `session_pending_session_idx` ON `session_pending` (`session_id`);

CREATE TABLE IF NOT EXISTS `instruction_entry` (
	`session_id` text NOT NULL,
	`key` text NOT NULL,
	`value` text,
	`removed` integer,
	`time_created` integer,
	`time_updated` integer,
	CONSTRAINT `instruction_entry_pk` PRIMARY KEY(`session_id`, `key`),
	CONSTRAINT `fk_instruction_entry_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS `instruction_state` (
	`session_id` text PRIMARY KEY,
	`epoch_start` integer,
	`through_seq` integer,
	`initial_values` text,
	`current_values` text,
	CONSTRAINT `fk_instruction_state_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);
SCHEMA_SQL
	return 0
}

_archive_event_schema_sql() {
	cat <<'SCHEMA_SQL'
CREATE TABLE IF NOT EXISTS `session_context_epoch` (
	`session_id` text PRIMARY KEY,
	`baseline` text NOT NULL,
	`snapshot` text NOT NULL,
	`baseline_seq` integer NOT NULL,
	`replacement_seq` integer,
	`revision` integer DEFAULT 0 NOT NULL,
	`agent` text DEFAULT 'build' NOT NULL,
	CONSTRAINT `fk_session_context_epoch_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS `event_sequence` (
	`aggregate_id` text PRIMARY KEY,
	`seq` integer NOT NULL,
	`owner_id` text
);

CREATE TABLE IF NOT EXISTS `event` (
	`id` text PRIMARY KEY,
	`aggregate_id` text NOT NULL,
	`seq` integer NOT NULL,
	`type` text NOT NULL,
	`data` text NOT NULL,
	`created` integer
);
CREATE UNIQUE INDEX IF NOT EXISTS `event_aggregate_seq_idx` ON `event` (`aggregate_id`,`seq`);
CREATE INDEX IF NOT EXISTS `event_aggregate_type_seq_idx` ON `event` (`aggregate_id`,`type`,`seq`);

COMMIT;
SCHEMA_SQL
	return 0
}

create_archive_schema() {
	local archive_db="$1"
	{
		_archive_core_schema_sql
		_archive_session_schema_sql
		_archive_inbox_schema_sql
		_archive_event_schema_sql
	} | sqlite3 "$archive_db"

	# CREATE TABLE IF NOT EXISTS does not evolve persisted archives. Add columns
	# in canonical order so legacy archives converge on the OpenCode 1.18.3
	# contract without rebuilding or discarding archived rows.
	_archive_migrate_schema_columns "$archive_db" || return 1

	return 0
}

_sqlite_has_column() {
	local db="$1"
	local table_name="$2"
	local column_name="$3"
	local count

	count=$(sqlite3 "$db" \
		"SELECT COUNT(*) FROM pragma_table_info('${table_name}') WHERE name='${column_name}';" 2>/dev/null || true)
	[[ "$count" == "1" ]]
	return $?
}

_sqlite_has_table() {
	local db="$1"
	local table_name="$2"
	local count

	count=$(sqlite3 "$db" \
		"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${table_name}';" 2>/dev/null || true)
	[[ "$count" == "1" ]]
	return $?
}

_archive_event_count_sql() {
	local candidate_filter="$1"
	local has_event_table="${2:-}"
	if (($# < 2)); then
		if _sqlite_has_table "$ACTIVE_DB" "$EVENT_TABLE_NAME"; then
			has_event_table=1
		else
			has_event_table=0
		fi
	fi

	if ((has_event_table)); then
		printf 'SELECT COUNT(*) FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE %s);\n' "$candidate_filter"
	else
		printf 'SELECT 0;\n'
	fi
	return 0
}

_archive_event_bytes_sql() {
	local candidate_filter="$1"
	local has_event_table="${2:-}"
	if (($# < 2)); then
		if _sqlite_has_table "$ACTIVE_DB" "$EVENT_TABLE_NAME"; then
			has_event_table=1
		else
			has_event_table=0
		fi
	fi

	if ((has_event_table)); then
		printf 'SELECT COALESCE(SUM(LENGTH(data)), 0) FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE %s);\n' "$candidate_filter"
	else
		printf 'SELECT 0;\n'
	fi
	return 0
}

# Both databases have passed schema validation before this is called. Use the
# source's column names for both sides, never the archive's physical order.
_archive_copy_sql() {
	local table_name="$1"
	local row_filter="$2"
	local columns=""
	# Select source columns: older active DBs lack defaulted epoch columns in
	# the evolved archive. Omitting them applies archive defaults without loss.
	columns=$(opencode_db_table_columns "$ACTIVE_DB" "$table_name") || return 1
	[[ -n "$columns" ]] || return 1
	printf 'INSERT OR IGNORE INTO archive.%s (%s) SELECT %s FROM %s WHERE %s;\n' \
		"$table_name" "$columns" "$columns" "$table_name" "$row_filter"
	return 0
}

_archive_project_insert_columns() {
	printf '%s\n' "id, worktree, vcs, name, icon_url, icon_color, time_created, time_updated, time_initialized, sandboxes, commands, icon_url_override"
	return 0
}

_archive_project_select_columns() {
	if _sqlite_has_column "$ACTIVE_DB" "project" "icon_url_override"; then
		printf '%s\n' "p.id, p.worktree, p.vcs, p.name, p.icon_url, p.icon_color, p.time_created, p.time_updated, p.time_initialized, p.sandboxes, p.commands, p.icon_url_override"
	else
		printf '%s\n' "p.id, p.worktree, p.vcs, p.name, p.icon_url, p.icon_color, p.time_created, p.time_updated, p.time_initialized, p.sandboxes, p.commands, NULL AS icon_url_override"
	fi
	return 0
}

_archive_session_insert_columns() {
	printf '%s\n' "id, project_id, parent_id, slug, directory, title, version, share_url, summary_additions, summary_deletions, summary_files, summary_diffs, revert, permission, time_created, time_updated, time_compacting, time_archived, workspace_id, path, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, metadata"
	return 0
}

_archive_session_select_columns() {
	local base_columns="id, project_id, parent_id, slug, directory, title, version, share_url, summary_additions, summary_deletions, summary_files, summary_diffs, revert, permission, time_created, time_updated, time_compacting, time_archived, workspace_id"
	local select_columns="$base_columns"
	local session_columns=""

	session_columns=$(opencode_db_table_columns "$ACTIVE_DB" "$SESSION_TABLE_NAME") || return 1
	if _archive_column_list_has "$session_columns" path; then
		select_columns="${select_columns}, path"
	else
		select_columns="${select_columns}, NULL AS path"
	fi
	if _archive_column_list_has "$session_columns" agent; then
		select_columns="${select_columns}, agent"
	else
		select_columns="${select_columns}, NULL AS agent"
	fi
	if _archive_column_list_has "$session_columns" model; then
		select_columns="${select_columns}, model"
	else
		select_columns="${select_columns}, NULL AS model"
	fi
	if _archive_column_list_has "$session_columns" cost; then
		select_columns="${select_columns}, cost"
	else
		select_columns="${select_columns}, 0 AS cost"
	fi
	if _archive_column_list_has "$session_columns" tokens_input; then
		select_columns="${select_columns}, tokens_input"
	else
		select_columns="${select_columns}, 0 AS tokens_input"
	fi
	if _archive_column_list_has "$session_columns" tokens_output; then
		select_columns="${select_columns}, tokens_output"
	else
		select_columns="${select_columns}, 0 AS tokens_output"
	fi
	if _archive_column_list_has "$session_columns" tokens_reasoning; then
		select_columns="${select_columns}, tokens_reasoning"
	else
		select_columns="${select_columns}, 0 AS tokens_reasoning"
	fi
	if _archive_column_list_has "$session_columns" tokens_cache_read; then
		select_columns="${select_columns}, tokens_cache_read"
	else
		select_columns="${select_columns}, 0 AS tokens_cache_read"
	fi
	if _archive_column_list_has "$session_columns" tokens_cache_write; then
		select_columns="${select_columns}, tokens_cache_write"
	else
		select_columns="${select_columns}, 0 AS tokens_cache_write"
	fi
	if _archive_column_list_has "$session_columns" metadata; then
		select_columns="${select_columns}, metadata"
	else
		select_columns="${select_columns}, NULL AS metadata"
	fi
	printf '%s\n' "$select_columns"
	return 0
}
