#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# opencode-db-archive.sh — Archive old OpenCode sessions to reduce active DB
# size and write contention for concurrent headless workers.
#
# The active opencode.db grows large over time (millions of part rows). With
# WAL mode and busy_timeout=0, concurrent writers hit SQLITE_BUSY. Archiving
# old sessions to a separate file reduces the active DB size.
#
# Usage:
#   opencode-db-archive.sh archive [--retention-days N] [--keep-sessions N] [--dry-run] [--max-duration-seconds N]
#   opencode-db-archive.sh stats
#   opencode-db-archive.sh help
#
# Environment:
#   OPENCODE_DB_PATH     — active DB path override used by aidevops/OpenCode helpers
#   OPENCODE_DB          — active DB path override (fallback)
#   XDG_DATA_HOME        — default data root (default: ~/.local/share)
#   OPENCODE_ARCHIVE_DB  — archive DB path (default: next to active opencode.db)
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# Source shared-constants.sh for portable stat functions
_oda_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=shared-constants.sh
[[ -f "${_oda_dir}/shared-constants.sh" ]] && source "${_oda_dir}/shared-constants.sh"
# shellcheck source=opencode-db-safety-lib.sh
if [[ -f "${_oda_dir}/opencode-db-safety-lib.sh" ]]; then
	source "${_oda_dir}/opencode-db-safety-lib.sh"
else
	printf 'opencode-db-archive: missing safety library\n' >&2
	exit 1
fi

# --- Configuration -----------------------------------------------------------

readonly SCRIPT_NAME="opencode-db-archive"
if [[ -n "${XDG_DATA_HOME:-}" ]]; then
	readonly DEFAULT_DATA_DIR="${XDG_DATA_HOME}/opencode"
elif [[ -n "${HOME:-}" ]]; then
	readonly DEFAULT_DATA_DIR="${HOME}/.local/share/opencode"
else
	readonly DEFAULT_DATA_DIR="opencode"
fi
readonly DEFAULT_DB="${DEFAULT_DATA_DIR}/opencode.db"
readonly DEFAULT_RETENTION_DAYS=30
readonly DEFAULT_BATCH_SIZE=500
readonly DEFAULT_MAX_DURATION=60
readonly EVENT_TABLE_NAME="event"
readonly SESSION_TABLE_NAME="session"
readonly ARCHIVE_TEXT_COLUMN_DEFINITION="text"
readonly ARCHIVE_INTEGER_COLUMN_DEFINITION="integer DEFAULT 0 NOT NULL"

ARCHIVE_BATCH_SIZE="${OPENCODE_DB_ARCHIVE_BATCH_SIZE:-$DEFAULT_BATCH_SIZE}"
ARCHIVE_BATCH_DELAY_SECONDS="${OPENCODE_DB_ARCHIVE_BATCH_DELAY_SECONDS:-0}"
DB_HOLDER_COMMAND="${OPENCODE_DB_HOLDER_COMMAND:-lsof}"
WAL_STABILITY_DELAY_SECONDS="${OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS:-1}"

ACTIVE_DB="${OPENCODE_DB_PATH:-${OPENCODE_DB:-$DEFAULT_DB}}"
_archive_default_dir="${ACTIVE_DB%/*}"
if [[ "$_archive_default_dir" == "$ACTIVE_DB" ]]; then
	_archive_default_dir="."
fi
ARCHIVE_DB="${OPENCODE_ARCHIVE_DB:-${_archive_default_dir}/opencode-archive.db}"
unset _archive_default_dir

# --- Output helpers -----------------------------------------------------------

print_info() {
	local msg="$1"
	echo -e "\033[0;34m[INFO]\033[0m $msg"
	return 0
}

print_success() {
	local msg="$1"
	echo -e "\033[0;32m[OK]\033[0m $msg"
	return 0
}

print_warning() {
	local msg="$1"
	echo -e "\033[1;33m[WARN]\033[0m $msg"
	return 0
}

print_error() {
	local msg="$1"
	echo -e "\033[0;31m[ERROR]\033[0m $msg" >&2
	return 0
}

# --- Utility ------------------------------------------------------------------

check_sqlite3() {
	if ! command -v sqlite3 &>/dev/null; then
		print_error "sqlite3 not found. Install it first."
		return 1
	fi
	return 0
}

check_active_db() {
	if [[ ! -f "$ACTIVE_DB" ]]; then
		print_error "Active DB not found: $ACTIVE_DB"
		return 1
	fi
	return 0
}

# Get the current epoch in milliseconds
now_ms() {
	local ms
	# Try GNU date first (Linux/coreutils); macOS date does not support %3N
	ms=$(date +%s%3N 2>/dev/null)
	if [[ "$ms" =~ ^[0-9]{13,}$ ]]; then
		echo "$ms"
		return 0
	fi
	# Fall back to python3 or perl for sub-second precision on macOS
	python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null ||
		perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null ||
		echo "$(($(date +%s) * 1000))"
	return 0
}

# Get session IDs that have an active worker (pulse log <1h old)
get_active_worker_sessions() {
	local active_sessions=""
	local one_hour_ago
	one_hour_ago=$(($(date +%s) - 3600))

	# Check per-user pulse worker logs modified within the last hour.
	local pulse_tmp_root=""
	pulse_tmp_root=$(aidevops_pulse_tmp_root 2>/dev/null || true)
	[[ -n "$pulse_tmp_root" ]] || return 0
	for logfile in "$pulse_tmp_root"/pulse-*.log; do
		[[ -f "$logfile" ]] || continue
		local file_mtime
		file_mtime=$(_file_mtime_epoch "$logfile")
		if ((file_mtime > one_hour_ago)); then
			# Extract session IDs from log content (UUIDs)
			local found
			found=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$logfile" 2>/dev/null || true)
			if [[ -n "$found" ]]; then
				active_sessions="${active_sessions}${active_sessions:+$'\n'}${found}"
			fi
		fi
	done

	# Deduplicate
	if [[ -n "$active_sessions" ]]; then
		echo "$active_sessions" | sort -u
	fi
	return 0
}

# Format bytes to human-readable
format_bytes() {
	local bytes="$1"
	if ((bytes >= 1073741824)); then
		printf "%.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc)"
	elif ((bytes >= 1048576)); then
		printf "%.1f MB" "$(echo "scale=1; $bytes / 1048576" | bc)"
	elif ((bytes >= 1024)); then
		printf "%.1f KB" "$(echo "scale=1; $bytes / 1024" | bc)"
	else
		printf "%d B" "$bytes"
	fi
	return 0
}

# Get file size in bytes (cross-platform)
file_size_bytes() {
	local filepath="$1"
	if [[ ! -f "$filepath" ]]; then
		echo "0"
		return 0
	fi
	_file_size_bytes "$filepath"
	return 0
}

_wal_is_stable() {
	local db="$1"
	local wal_state=""
	wal_state=$(opencode_db_wal_state "$db" "$WAL_STABILITY_DELAY_SECONDS")
	[[ "$wal_state" == "stable" ]]
	return $?
}

_db_holder_count() {
	local db="$1"
	opencode_db_holder_count "$db" "$DB_HOLDER_COMMAND"
	return 0
}

_archive_validate_active_schema() {
	local diagnostic=""

	if ! opencode_archive_schema_supported "$ACTIVE_DB" optional; then
		diagnostic=$(opencode_archive_schema_diagnostic)
		print_error "Unsupported or unavailable OpenCode session schema: ${diagnostic}; active data was left untouched."
		return 1
	fi
	return 0
}

_archive_mutation_preflight() {
	local holder_count=""

	holder_count=$(_db_holder_count "$ACTIVE_DB")
	if [[ "$holder_count" == "$OPENCODE_DB_STATE_UNKNOWN" ]]; then
		print_warning "Archive deferred — active DB holder state is unavailable."
		return 2
	fi
	if [[ "$holder_count" -gt 0 ]]; then
		print_warning "Archive deferred — ${holder_count} process(es) hold the active DB open."
		return 2
	fi
	if ! _wal_is_stable "$ACTIVE_DB"; then
		print_warning "Archive deferred — active WAL changed during the safety observation window."
		return 2
	fi
	if ! _archive_validate_active_schema; then
		return 3
	fi
	return 0
}

# Checkpoint the archive WAL — called on normal exit and via trap on early return.
# Uses a global flag to prevent double-run when the fast-path calls it explicitly.
_ARCHIVE_CHECKPOINT_DONE=0
_ARCHIVE_CLEANUP_ENABLED=0
_checkpoint_archive_db() {
	local archive_db="$1"
	if ((_ARCHIVE_CHECKPOINT_DONE)); then return 0; fi
	_ARCHIVE_CHECKPOINT_DONE=1
	sqlite3 "$archive_db" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
	return 0
}

_archive_cleanup() {
	if ((_ARCHIVE_CLEANUP_ENABLED)) && [[ -f "$ARCHIVE_DB" ]]; then
		_checkpoint_archive_db "$ARCHIVE_DB"
	fi
	return 0
}

_archive_interrupt() {
	local exit_code="$1"
	print_warning "Archive interrupted; committed batches remain queryable and the active transaction will roll back."
	exit "$exit_code"
	return 1
}

# --- Schema creation in archive DB -------------------------------------------

_archive_add_column_if_missing() {
	local archive_db="$1"
	local table_name="$2"
	local column_name="$3"
	local column_definition="$4"
	local column_count=""

	column_count=$(sqlite3 "$archive_db" \
		"SELECT COUNT(*) FROM pragma_table_info('${table_name}') WHERE name='${column_name}';") || return 1
	if [[ "$column_count" -eq 0 ]]; then
		sqlite3 "$archive_db" "ALTER TABLE \`${table_name}\` ADD COLUMN \`${column_name}\` ${column_definition};" || return 1
		print_info "Migrated archive.${table_name} schema: added ${column_name} column"
	fi
	return 0
}

create_archive_schema() {
	local archive_db="$1"

	sqlite3 "$archive_db" <<'SCHEMA_SQL'
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

CREATE TABLE IF NOT EXISTS `session_context_epoch` (
	`session_id` text PRIMARY KEY,
	`baseline` text NOT NULL,
	`snapshot` text NOT NULL,
	`baseline_seq` integer NOT NULL,
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
	`data` text NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS `event_aggregate_seq_idx` ON `event` (`aggregate_id`,`seq`);
CREATE INDEX IF NOT EXISTS `event_aggregate_type_seq_idx` ON `event` (`aggregate_id`,`type`,`seq`);

COMMIT;
SCHEMA_SQL

	# CREATE TABLE IF NOT EXISTS does not evolve persisted archives. Add columns
	# in canonical order so legacy archives converge on the OpenCode 1.18.3
	# contract without rebuilding or discarding archived rows.
	_archive_add_column_if_missing "$archive_db" project icon_url_override "$ARCHIVE_TEXT_COLUMN_DEFINITION" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" path "$ARCHIVE_TEXT_COLUMN_DEFINITION" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" agent "$ARCHIVE_TEXT_COLUMN_DEFINITION" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" model "$ARCHIVE_TEXT_COLUMN_DEFINITION" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" cost "real DEFAULT 0 NOT NULL" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" tokens_input "$ARCHIVE_INTEGER_COLUMN_DEFINITION" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" tokens_output "$ARCHIVE_INTEGER_COLUMN_DEFINITION" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" tokens_reasoning "$ARCHIVE_INTEGER_COLUMN_DEFINITION" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" tokens_cache_read "$ARCHIVE_INTEGER_COLUMN_DEFINITION" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" tokens_cache_write "$ARCHIVE_INTEGER_COLUMN_DEFINITION" || return 1
	_archive_add_column_if_missing "$archive_db" "$SESSION_TABLE_NAME" metadata "$ARCHIVE_TEXT_COLUMN_DEFINITION" || return 1

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

	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "path"; then
		select_columns="${select_columns}, path"
	else
		select_columns="${select_columns}, NULL AS path"
	fi
	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "agent"; then
		select_columns="${select_columns}, agent"
	else
		select_columns="${select_columns}, NULL AS agent"
	fi
	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "model"; then
		select_columns="${select_columns}, model"
	else
		select_columns="${select_columns}, NULL AS model"
	fi
	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "cost"; then
		select_columns="${select_columns}, cost"
	else
		select_columns="${select_columns}, 0 AS cost"
	fi
	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "tokens_input"; then
		select_columns="${select_columns}, tokens_input"
	else
		select_columns="${select_columns}, 0 AS tokens_input"
	fi
	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "tokens_output"; then
		select_columns="${select_columns}, tokens_output"
	else
		select_columns="${select_columns}, 0 AS tokens_output"
	fi
	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "tokens_reasoning"; then
		select_columns="${select_columns}, tokens_reasoning"
	else
		select_columns="${select_columns}, 0 AS tokens_reasoning"
	fi
	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "tokens_cache_read"; then
		select_columns="${select_columns}, tokens_cache_read"
	else
		select_columns="${select_columns}, 0 AS tokens_cache_read"
	fi
	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "tokens_cache_write"; then
		select_columns="${select_columns}, tokens_cache_write"
	else
		select_columns="${select_columns}, 0 AS tokens_cache_write"
	fi
	if _sqlite_has_column "$ACTIVE_DB" "$SESSION_TABLE_NAME" "metadata"; then
		select_columns="${select_columns}, metadata"
	else
		select_columns="${select_columns}, NULL AS metadata"
	fi
	printf '%s\n' "$select_columns"
	return 0
}

_validate_nonnegative_integer() {
	local value="$1"
	local option_name="$2"

	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		print_error "${option_name} must be a non-negative integer: ${value}"
		return 1
	fi
	return 0
}

_format_cutoff_time() {
	local cutoff_ms="$1"
	local cutoff_s=$((cutoff_ms / 1000))

	date -r "$cutoff_s" '+%Y-%m-%d %H:%M' 2>/dev/null ||
		date -d "@$cutoff_s" '+%Y-%m-%d %H:%M' 2>/dev/null ||
		echo 'N/A'
	return 0
}

# _check_wal_post_archive <db>
# After a successful archive pass, checks whether the WAL is still large
# because active readers are blocking the checkpoint.  Emits a warning with
# the number of blocking processes and a deterministic next step.
# Silent no-op when WAL is within the threshold or does not exist.
_check_wal_post_archive() {
	local db="$1"
	local wal_path="${db}-wal"
	[[ -f "$wal_path" ]] || return 0
	local wal_bytes wal_mb
	wal_bytes=$(file_size_bytes "$wal_path")
	wal_mb=$((wal_bytes / 1048576))
	local threshold="${WAL_LARGE_THRESHOLD_MB:-500}"
	[[ "$wal_mb" -ge "$threshold" ]] || return 0
	print_warning "WAL still large after archive: $(format_bytes "$wal_bytes") (${wal_path})"
	# Probe checkpoint state: PASSIVE does not block writers — safe with live sessions.
	local ckpt_out blocked log_pages ckpt_pages
	ckpt_out=$(sqlite3 "$db" "PRAGMA wal_checkpoint(PASSIVE);" 2>/dev/null || echo "0|0|0")
	IFS='|' read -r blocked log_pages ckpt_pages <<<"$ckpt_out"
	if [[ "${blocked:-0}" == "1" ]] && [[ "${log_pages:-0}" -gt "${ckpt_pages:-0}" ]]; then
		local unckpt=$((${log_pages:-0} - ${ckpt_pages:-0}))
		print_warning "WAL checkpoint busy: ${unckpt} frame(s) still held by active readers"
		local n_holders=0
		if command -v lsof >/dev/null 2>&1 && [[ -f "$db" ]]; then
			n_holders=$(lsof "$db" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | wc -l | tr -d ' ')
		fi
		n_holders="${n_holders:-0}"
		if [[ "$n_holders" -gt 0 ]]; then
			print_warning "${n_holders} process(es) holding DB open — WAL cannot be truncated until they close"
		fi
		print_info "Next step: close all OpenCode sessions, then run:"
		print_info "  opencode-db-maintenance-helper.sh maintain"
	else
		print_info "WAL will be truncated on next maintenance run (no active readers blocking)"
	fi
	return 0
}

_checkpoint_active_db_truncate() {
	local checkpoint_output=""
	local blocked=""
	local log_pages=""
	local checkpointed_pages=""

	checkpoint_output=$(sqlite3 "$ACTIVE_DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null) || return 1
	IFS='|' read -r blocked log_pages checkpointed_pages <<<"$checkpoint_output"
	if [[ "${blocked:-1}" != "0" ]]; then
		return 1
	fi
	return 0
}

# Compact only with positive idle-holder, stable-WAL, and checkpoint evidence.
# This reclaims SQLite free pages; it never selects logical sessions by size.
_archive_compact_active_db() {
	local freelist_count=""
	local holder_count=""
	local quick_check=""

	freelist_count=$(sqlite3 "$ACTIVE_DB" "PRAGMA freelist_count;" 2>/dev/null || true)
	if [[ ! "$freelist_count" =~ ^[0-9]+$ ]]; then
		print_warning "VACUUM deferred — freelist state is unavailable."
		return 2
	fi
	if [[ "$freelist_count" -eq 0 ]]; then
		print_info "VACUUM not needed — active DB has no free pages."
		return 0
	fi

	holder_count=$(_db_holder_count "$ACTIVE_DB")
	if [[ "$holder_count" == "$OPENCODE_DB_STATE_UNKNOWN" ]]; then
		print_warning "VACUUM deferred — active DB holder state is unavailable."
		return 2
	fi
	if [[ "$holder_count" -gt 0 ]]; then
		print_warning "VACUUM deferred — ${holder_count} process(es) hold the active DB open."
		return 2
	fi
	if ! _wal_is_stable "$ACTIVE_DB"; then
		print_warning "VACUUM deferred — active WAL changed during the safety observation window."
		return 2
	fi

	print_info "Running pre-VACUUM wal_checkpoint(TRUNCATE)..."
	if ! _checkpoint_active_db_truncate; then
		print_warning "VACUUM deferred — pre-VACUUM checkpoint was busy or unavailable."
		return 2
	fi
	holder_count=$(_db_holder_count "$ACTIVE_DB")
	if [[ "$holder_count" == "$OPENCODE_DB_STATE_UNKNOWN" || "$holder_count" -gt 0 ]]; then
		print_warning "VACUUM deferred — active DB holder state changed after checkpoint."
		return 2
	fi

	print_info "Running VACUUM on active DB..."
	if ! sqlite3 "$ACTIVE_DB" "VACUUM;" 2>/dev/null; then
		print_warning "VACUUM deferred — exclusive access was lost. Will retry next cycle."
		return 2
	fi
	print_info "Running post-VACUUM wal_checkpoint(TRUNCATE)..."
	if ! _checkpoint_active_db_truncate; then
		print_warning "Post-VACUUM checkpoint was busy or unavailable; maintenance remains incomplete."
		return 2
	fi
	quick_check=$(sqlite3 "$ACTIVE_DB" "PRAGMA quick_check;" 2>/dev/null || true)
	if [[ "$quick_check" != "ok" ]]; then
		print_error "Active DB quick_check failed after VACUUM."
		return 1
	fi
	return 0
}

_archive_candidate_filter() {
	local retention_enabled="$1"
	local cutoff_ms="$2"
	local keep_enabled="$3"
	local keep_sessions="$4"
	local exclude_clause="$5"
	local filter="1=1"

	if ((retention_enabled)); then
		filter="${filter} AND time_updated < ${cutoff_ms}"
	fi
	if ((keep_enabled)); then
		filter="${filter} AND id NOT IN (SELECT id FROM session ORDER BY time_updated DESC, time_created DESC, id DESC LIMIT ${keep_sessions})"
	fi
	if [[ -n "$exclude_clause" ]]; then
		filter="${filter} ${exclude_clause}"
	fi

	printf '%s\n' "$filter"
	return 0
}

# --- Archive command ----------------------------------------------------------

cmd_archive() {
	local retention_days="$DEFAULT_RETENTION_DAYS"
	local retention_enabled=1
	local retention_explicit=0
	local keep_sessions=0
	local keep_enabled=0
	local dry_run=0
	local max_duration="$DEFAULT_MAX_DURATION"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		local option="$1"
		local option_value="${2:-}"
		case "$option" in
		--retention-days)
			retention_days="$option_value"
			retention_enabled=1
			retention_explicit=1
			shift 2
			;;
		--keep-sessions)
			keep_sessions="$option_value"
			keep_enabled=1
			if ((retention_explicit == 0)); then
				retention_enabled=0
			fi
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		--max-duration-seconds)
			max_duration="$option_value"
			shift 2
			;;
		*)
			print_error "Unknown option: $option"
			cmd_help
			return 1
			;;
		esac
	done

	check_sqlite3 || return 1
	check_active_db || return 1
	_validate_nonnegative_integer "$retention_days" "--retention-days" || return 1
	_validate_nonnegative_integer "$keep_sessions" "--keep-sessions" || return 1
	_validate_nonnegative_integer "$max_duration" "--max-duration-seconds" || return 1
	_validate_nonnegative_integer "$ARCHIVE_BATCH_SIZE" "OPENCODE_DB_ARCHIVE_BATCH_SIZE" || return 1
	if [[ "$ARCHIVE_BATCH_SIZE" -eq 0 ]]; then
		print_error "OPENCODE_DB_ARCHIVE_BATCH_SIZE must be greater than zero."
		return 1
	fi
	if [[ ! "$ARCHIVE_BATCH_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		print_error "OPENCODE_DB_ARCHIVE_BATCH_DELAY_SECONDS must be a non-negative number."
		return 1
	fi
	if [[ ! "$WAL_STABILITY_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		print_error "OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS must be a non-negative number."
		return 1
	fi

	local preflight_rc=0
	_archive_mutation_preflight || preflight_rc=$?
	if [[ "$preflight_rc" -ne 0 ]]; then
		return "$preflight_rc"
	fi

	local cutoff_ms
	cutoff_ms=$(($(date +%s) * 1000 - retention_days * 86400 * 1000))

	if ((retention_enabled)); then
		print_info "Retention: ${retention_days} days since last update (cutoff: $(_format_cutoff_time "$cutoff_ms"))"
	fi
	if ((keep_enabled)); then
		print_info "Retention: keep newest ${keep_sessions} active sessions by last update"
	fi
	if ((retention_enabled && keep_enabled)); then
		print_info "Combined retention: archiving only sessions inactive beyond both targets"
	fi
	print_info "Active DB: $ACTIVE_DB"
	print_info "Archive DB: $ARCHIVE_DB"

	# Get active worker sessions to exclude
	local active_sessions
	active_sessions=$(get_active_worker_sessions)
	local exclude_count=0
	if [[ -n "$active_sessions" ]]; then
		exclude_count=$(echo "$active_sessions" | wc -l | tr -d ' ')
		print_warning "Excluding $exclude_count session(s) with active workers"
	fi

	# Build exclusion clause for SQL
	local exclude_clause=""
	if [[ -n "$active_sessions" ]]; then
		# Build a comma-separated quoted list
		local exclude_list=""
		while IFS= read -r sid; do
			exclude_list="${exclude_list}${exclude_list:+,}'${sid}'"
		done <<<"$active_sessions"
		exclude_clause="AND id NOT IN ($exclude_list)"
	fi

	local candidate_filter
	candidate_filter=$(_archive_candidate_filter "$retention_enabled" "$cutoff_ms" "$keep_enabled" "$keep_sessions" "$exclude_clause")

	# Count eligible sessions
	local total_eligible
	total_eligible=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE $candidate_filter;")

	if ((total_eligible == 0)); then
		print_success "No sessions match the archive retention target."
		_archive_compact_active_db
		return $?
	fi

	print_info "Found $total_eligible sessions eligible for archiving"
	local has_session_message_table=0
	local has_session_input_table=0
	local has_session_context_epoch_table=0
	local has_event_sequence_table=0
	local has_event_table=0
	if _sqlite_has_table "$ACTIVE_DB" session_message; then
		has_session_message_table=1
	fi
	if _sqlite_has_table "$ACTIVE_DB" session_input; then
		has_session_input_table=1
	fi
	if _sqlite_has_table "$ACTIVE_DB" session_context_epoch; then
		has_session_context_epoch_table=1
	fi
	if _sqlite_has_table "$ACTIVE_DB" event_sequence; then
		has_event_sequence_table=1
	fi
	if _sqlite_has_table "$ACTIVE_DB" "$EVENT_TABLE_NAME"; then
		has_event_table=1
	fi

	if ((dry_run)); then
		# Show what would be archived
		local msg_count part_count todo_count share_count event_count event_bytes
		local session_message_count=0 session_input_count=0 context_epoch_count=0 event_sequence_count=0
		msg_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM message WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		part_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM part WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		todo_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM todo WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		share_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session_share WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		if ((has_session_message_table)); then
			session_message_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session_message WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		fi
		if ((has_session_input_table)); then
			session_input_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session_input WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		fi
		if ((has_session_context_epoch_table)); then
			context_epoch_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session_context_epoch WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		fi
		if ((has_event_sequence_table)); then
			event_sequence_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM event_sequence WHERE aggregate_id IN (SELECT id FROM session WHERE $candidate_filter);")
		fi
		event_count=$(sqlite3 "$ACTIVE_DB" "$(_archive_event_count_sql "$candidate_filter" "$has_event_table")")
		event_bytes=$(sqlite3 "$ACTIVE_DB" "$(_archive_event_bytes_sql "$candidate_filter" "$has_event_table")")

		echo ""
		echo "=== DRY RUN — would archive: ==="
		echo "  Sessions:       $total_eligible"
		echo "  Messages:       $msg_count"
		echo "  Parts:          $part_count"
		echo "  Todos:          $todo_count"
		echo "  Session shares: $share_count"
		echo "  Session msgs:   $session_message_count"
		echo "  Session inputs: $session_input_count"
		echo "  Context epochs: $context_epoch_count"
		echo "  Event sequences: $event_sequence_count"
		echo "  Events:         $event_count ($(format_bytes "$event_bytes"))"
		echo ""
		print_info "Run without --dry-run to proceed."
		return 0
	fi

	# Create archive DB and schema
	create_archive_schema "$ARCHIVE_DB"
	if ! opencode_archive_schema_supported "$ARCHIVE_DB" required; then
		local archive_schema_diagnostic=""
		archive_schema_diagnostic=$(opencode_archive_schema_diagnostic)
		print_error "Archive schema is unavailable or unsupported: ${archive_schema_diagnostic}; active data was left untouched."
		return 3
	fi

	local project_insert_columns project_select_columns
	local session_insert_columns session_select_columns
	project_insert_columns=$(_archive_project_insert_columns)
	project_select_columns=$(_archive_project_select_columns)
	session_insert_columns=$(_archive_session_insert_columns)
	session_select_columns=$(_archive_session_select_columns)

	local size_before
	size_before=$(file_size_bytes "$ACTIVE_DB")

	# Cleanup scope: checkpoint the archive WAL on every process exit. SQLite rolls
	# back an interrupted in-flight batch; already committed batches stay queryable.
	_ARCHIVE_CHECKPOINT_DONE=0
	_ARCHIVE_CLEANUP_ENABLED=1
	trap '_archive_cleanup' EXIT
	trap '_archive_interrupt 130' INT
	trap '_archive_interrupt 143' TERM

	local start_time
	start_time=$(date +%s)
	local archived_total=0
	local batch_num=0
	local first_batch=1

	while ((archived_total < total_eligible)); do
		# Check time budget
		local elapsed
		elapsed=$(($(date +%s) - start_time))
		if ((elapsed >= max_duration)); then
			print_warning "Time budget exhausted (${elapsed}s >= ${max_duration}s). Archived $archived_total/$total_eligible sessions. Will resume next cycle."
			break
		fi

		batch_num=$((batch_num + 1))
		local batch_limit="$ARCHIVE_BATCH_SIZE"
		local remaining=$((total_eligible - archived_total))
		if ((remaining < batch_limit)); then
			batch_limit=$remaining
		fi

		# Collect batch session IDs
		local session_ids
		session_ids=$(sqlite3 "$ACTIVE_DB" "SELECT id FROM session WHERE $candidate_filter ORDER BY time_updated ASC, time_created ASC, id ASC LIMIT $batch_limit;")

		if [[ -z "$session_ids" ]]; then
			break
		fi

		local batch_count
		batch_count=$(echo "$session_ids" | wc -l | tr -d ' ')

		# Build the IN clause for this batch.
		# macOS BSD paste -s does not accept pipe input — only file args.
		# Use tr + sed instead, which works portably on both macOS and Linux.
		# The previous `paste -sd,` silently failed on macOS, preventing
		# archival and bloating the DB to multi-GB (3232+ sessions).
		local in_clause=""
		in_clause=$(printf '%s\n' "$session_ids" | sed "s/.*/'&'/" | tr '\n' ',' | sed 's/,$//')

		local session_message_copy_sql="" session_message_delete_sql=""
		local session_input_copy_sql="" session_input_delete_sql=""
		local context_epoch_copy_sql="" context_epoch_delete_sql=""
		local event_sequence_copy_sql="" event_sequence_delete_sql=""
		local event_copy_sql="" event_delete_sql=""
		if ((has_session_message_table)); then
			session_message_copy_sql="INSERT OR IGNORE INTO archive.session_message SELECT * FROM session_message WHERE session_id IN ($in_clause);"
			session_message_delete_sql="DELETE FROM session_message WHERE session_id IN ($in_clause);"
		fi
		if ((has_session_input_table)); then
			session_input_copy_sql="INSERT OR IGNORE INTO archive.session_input SELECT * FROM session_input WHERE session_id IN ($in_clause);"
			session_input_delete_sql="DELETE FROM session_input WHERE session_id IN ($in_clause);"
		fi
		if ((has_session_context_epoch_table)); then
			context_epoch_copy_sql="INSERT OR IGNORE INTO archive.session_context_epoch SELECT * FROM session_context_epoch WHERE session_id IN ($in_clause);"
			context_epoch_delete_sql="DELETE FROM session_context_epoch WHERE session_id IN ($in_clause);"
		fi
		if ((has_event_sequence_table)); then
			event_sequence_copy_sql="INSERT OR IGNORE INTO archive.event_sequence SELECT * FROM event_sequence WHERE aggregate_id IN ($in_clause);"
			event_sequence_delete_sql="DELETE FROM event_sequence WHERE aggregate_id IN ($in_clause);"
		fi
		if ((has_event_table)); then
			event_copy_sql="INSERT OR IGNORE INTO archive.event SELECT * FROM event WHERE aggregate_id IN ($in_clause);"
			event_delete_sql="DELETE FROM event WHERE aggregate_id IN ($in_clause);"
		fi

		# Single transaction: copy to archive then delete from active.
		# ATTACH and DETACH are within the same sqlite3 invocation — the attachment
		# is released automatically when the process exits. The trap above ensures
		# the archive WAL is checkpointed on any exit path between batches.
		# Foreign-key mode is connection-local. Enable it explicitly and still use
		# dependency-safe manual deletes so behavior never depends on OpenCode's
		# separate connection configuration.
		sqlite3 "$ACTIVE_DB" <<BATCH_SQL
PRAGMA foreign_keys = ON;
ATTACH DATABASE '$ARCHIVE_DB' AS archive;

BEGIN IMMEDIATE;

-- Copy referenced project rows (INSERT OR IGNORE — projects may already exist)
INSERT OR IGNORE INTO archive.project (${project_insert_columns})
SELECT ${project_select_columns} FROM project p
WHERE p.id IN (SELECT DISTINCT project_id FROM session WHERE id IN ($in_clause));

-- Copy sessions
INSERT OR IGNORE INTO archive.session (${session_insert_columns})
SELECT ${session_select_columns} FROM session WHERE id IN ($in_clause);

-- Copy messages
INSERT OR IGNORE INTO archive.message
SELECT * FROM message WHERE session_id IN ($in_clause);

-- Copy parts
INSERT OR IGNORE INTO archive.part
SELECT * FROM part WHERE session_id IN ($in_clause);

-- Copy todos
INSERT OR IGNORE INTO archive.todo
SELECT * FROM todo WHERE session_id IN ($in_clause);

-- Copy session_shares
INSERT OR IGNORE INTO archive.session_share
SELECT * FROM session_share WHERE session_id IN ($in_clause);

-- Copy OpenCode 1.18.3 session-owned rows when present.
${session_message_copy_sql}
${session_input_copy_sql}
${context_epoch_copy_sql}

-- Copy event sequence parents before their event rows.
${event_sequence_copy_sql}

-- Copy event stream rows when the active DB has OpenCode's event table.
-- OpenCode stores session-scoped event history with aggregate_id=session.id.
-- This table is often the largest object in opencode.db, so leaving it behind
-- defeats archiving.
${event_copy_sql}

-- Delete from active (child tables first since FK CASCADE is not enforced)
DELETE FROM part WHERE session_id IN ($in_clause);
DELETE FROM todo WHERE session_id IN ($in_clause);
DELETE FROM session_share WHERE session_id IN ($in_clause);
${session_message_delete_sql}
${session_input_delete_sql}
${context_epoch_delete_sql}
DELETE FROM message WHERE session_id IN ($in_clause);
${event_delete_sql}
${event_sequence_delete_sql}
DELETE FROM session WHERE id IN ($in_clause);

COMMIT;

DETACH DATABASE archive;
BATCH_SQL

		archived_total=$((archived_total + batch_count))

		# Verify archive integrity after first batch
		if ((first_batch)); then
			local integrity
			integrity=$(sqlite3 "$ARCHIVE_DB" "PRAGMA integrity_check;" 2>&1)
			[[ "$integrity" == "ok" ]] || {
				print_error "Archive integrity check FAILED after first batch: $integrity"
				print_error "Aborting. Data was already copied — manual review needed."
				return 1
			}
			first_batch=0
		fi

		local size_current
		size_current=$(file_size_bytes "$ACTIVE_DB")
		local freed=$((size_before - size_current))
		# freed can be negative before vacuum; show 0 in that case
		if ((freed < 0)); then freed=0; fi

		print_info "Archived $archived_total/$total_eligible sessions [batch $batch_num] ($(format_bytes "$freed") freed)"
		if [[ "$ARCHIVE_BATCH_DELAY_SECONDS" != "0" ]]; then
			sleep "$ARCHIVE_BATCH_DELAY_SECONDS"
		fi
	done

	# Fast-path explicit cleanup: checkpoint archive WAL before vacuum.
	# Marks done so the RETURN trap does not double-run.
	_checkpoint_archive_db "$ARCHIVE_DB"

	local compact_rc=0
	_archive_compact_active_db || compact_rc=$?
	local archive_quick_check=""
	archive_quick_check=$(sqlite3 "$ARCHIVE_DB" "PRAGMA quick_check;" 2>/dev/null || true)
	if [[ "$archive_quick_check" != "ok" ]]; then
		print_error "Archive DB quick_check failed after archive pass."
		return 1
	fi

	local size_after
	size_after=$(file_size_bytes "$ACTIVE_DB")
	local total_freed=$((size_before - size_after))
	if ((total_freed < 0)); then total_freed=0; fi

	echo ""
	print_success "Archive complete: $archived_total sessions moved"
	print_success "Active DB: $(format_bytes "$size_before") → $(format_bytes "$size_after") ($(format_bytes "$total_freed") freed)"
	print_success "Archive DB: $(format_bytes "$(file_size_bytes "$ARCHIVE_DB")")"
	# Surface large WAL that remains after archiving (active readers may be blocking truncation).
	_check_wal_post_archive "$ACTIVE_DB"
	_ARCHIVE_CLEANUP_ENABLED=0
	trap - EXIT INT TERM
	if [[ "$compact_rc" -ne 0 ]]; then
		return "$compact_rc"
	fi
	return 0
}

# --- Stats command ------------------------------------------------------------

cmd_stats() {
	check_sqlite3 || return 1
	check_active_db || return 1

	local now_s
	now_s=$(date +%s)
	local seven_days_ms=$(((now_s - 7 * 86400) * 1000))
	local thirty_days_ms=$(((now_s - 30 * 86400) * 1000))

	echo ""
	echo "=== Active DB: $ACTIVE_DB ==="
	echo "  Size: $(format_bytes "$(file_size_bytes "$ACTIVE_DB")")"

	local session_count msg_count part_count todo_count share_count event_count event_bytes
	session_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session;")
	msg_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM message;")
	part_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM part;")
	todo_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM todo;")
	share_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session_share;")
	event_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM event;" 2>/dev/null || echo "0")
	event_bytes=$(sqlite3 "$ACTIVE_DB" "SELECT COALESCE(SUM(LENGTH(data)), 0) FROM event;" 2>/dev/null || echo "0")

	echo "  Sessions:       $session_count"
	echo "  Messages:       $msg_count"
	echo "  Parts:          $part_count"
	echo "  Todos:          $todo_count"
	echo "  Session shares: $share_count"
	echo "  Events:         $event_count ($(format_bytes "$event_bytes"))"

	# Last-update distribution
	local last_7d last_30d older
	last_7d=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $seven_days_ms;")
	last_30d=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $thirty_days_ms AND time_updated < $seven_days_ms;")
	older=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated < $thirty_days_ms;")

	echo ""
	echo "  Last-update distribution:"
	echo "    Last 7 days:   $last_7d"
	echo "    7–30 days:     $last_30d"
	echo "    Older than 30: $older"

	if [[ -f "$ARCHIVE_DB" ]]; then
		echo ""
		echo "=== Archive DB: $ARCHIVE_DB ==="
		echo "  Size: $(format_bytes "$(file_size_bytes "$ARCHIVE_DB")")"

		local arch_session arch_msg arch_part arch_todo arch_share arch_event arch_event_bytes
		arch_session=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session;" 2>/dev/null || echo "0")
		arch_msg=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM message;" 2>/dev/null || echo "0")
		arch_part=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM part;" 2>/dev/null || echo "0")
		arch_todo=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM todo;" 2>/dev/null || echo "0")
		arch_share=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session_share;" 2>/dev/null || echo "0")
		arch_event=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM event;" 2>/dev/null || echo "0")
		arch_event_bytes=$(sqlite3 "$ARCHIVE_DB" "SELECT COALESCE(SUM(LENGTH(data)), 0) FROM event;" 2>/dev/null || echo "0")

		echo "  Sessions:       $arch_session"
		echo "  Messages:       $arch_msg"
		echo "  Parts:          $arch_part"
		echo "  Todos:          $arch_todo"
		echo "  Session shares: $arch_share"
		echo "  Events:         $arch_event ($(format_bytes "$arch_event_bytes"))"

		# Last-update distribution in archive
		local arch_7d arch_30d arch_older
		arch_7d=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $seven_days_ms;" 2>/dev/null || echo "0")
		arch_30d=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $thirty_days_ms AND time_updated < $seven_days_ms;" 2>/dev/null || echo "0")
		arch_older=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated < $thirty_days_ms;" 2>/dev/null || echo "0")

		echo ""
		echo "  Last-update distribution:"
		echo "    Last 7 days:   $arch_7d"
		echo "    7–30 days:     $arch_30d"
		echo "    Older than 30: $arch_older"
	else
		echo ""
		echo "=== Archive DB: (not yet created) ==="
	fi

	echo ""
	return 0
}

# --- Help command -------------------------------------------------------------

cmd_help() {
	cat <<'HELP'
opencode-db-archive.sh — Archive old OpenCode sessions

COMMANDS:
  archive   Move old sessions from active DB to archive DB
  stats     Show row counts and sizes (active + archive databases)
  help      Show this help message

ARCHIVE OPTIONS:
  --retention-days N        Sessions inactive for N days are archived (default: 30)
  --keep-sessions N         Keep newest N active sessions by last update; archive older sessions beyond the budget
  --dry-run                 Show what would be archived without doing it
  --max-duration-seconds N  Stop after N seconds even when not done (default: 60)

ENVIRONMENT:
  XDG_DATA_HOME             Data root for default DB path (default: ~/.local/share)
  OPENCODE_DB_PATH          Active DB path override used by aidevops/OpenCode helpers
  OPENCODE_DB               Active DB path override (fallback)
  OPENCODE_ARCHIVE_DB       Archive DB path (default: next to active opencode.db)

EXAMPLES:
  # Show current stats
  opencode-db-archive.sh stats

  # Preview what would be archived (30-day retention)
  opencode-db-archive.sh archive --retention-days 30 --dry-run

  # Keep the 500 most recently updated active sessions, archive older sessions
  opencode-db-archive.sh archive --keep-sessions 500

  # Archive with defaults (30 days, 60s time budget)
  opencode-db-archive.sh archive

  # Archive as pulse pre-flight (short time budget)
  opencode-db-archive.sh archive --max-duration-seconds 30
HELP
	return 0
}

# --- Main dispatch ------------------------------------------------------------

main() {
	local command="${1:-help}"
	local rc=0
	shift || true

	case "$command" in
	archive)
		cmd_archive "$@" || rc=$?
		;;
	stats)
		cmd_stats "$@" || rc=$?
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return "$rc"
}

main "$@"
