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
#   OPENCODE_DB          — active DB path (default: ~/.local/share/opencode/opencode.db)
#   OPENCODE_ARCHIVE_DB  — archive DB path (default: ~/.local/share/opencode/opencode-archive.db)
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# Source shared-constants.sh for portable stat functions
_oda_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=shared-constants.sh
[[ -f "${_oda_dir}/shared-constants.sh" ]] && source "${_oda_dir}/shared-constants.sh"

# --- Configuration -----------------------------------------------------------

readonly SCRIPT_NAME="opencode-db-archive"
readonly DEFAULT_DB="$HOME/.local/share/opencode/opencode.db"
readonly DEFAULT_ARCHIVE_DB="$HOME/.local/share/opencode/opencode-archive.db"
readonly DEFAULT_RETENTION_DAYS=14
readonly DEFAULT_BATCH_SIZE=500
readonly DEFAULT_MAX_DURATION=60

ACTIVE_DB="${OPENCODE_DB:-$DEFAULT_DB}"
ARCHIVE_DB="${OPENCODE_ARCHIVE_DB:-$DEFAULT_ARCHIVE_DB}"

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

# Checkpoint the archive WAL — called on normal exit and via trap on early return.
# Uses a global flag to prevent double-run when the fast-path calls it explicitly.
_ARCHIVE_CHECKPOINT_DONE=0
_checkpoint_archive_db() {
	local archive_db="$1"
	if ((_ARCHIVE_CHECKPOINT_DONE)); then return 0; fi
	_ARCHIVE_CHECKPOINT_DONE=1
	sqlite3 "$archive_db" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
	return 0
}

# --- Schema creation in archive DB -------------------------------------------

create_archive_schema() {
	local archive_db="$1"

	sqlite3 "$archive_db" <<'SCHEMA_SQL'
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

-- WAL mode for the archive too (better read concurrency)
PRAGMA journal_mode=WAL;
SCHEMA_SQL

	# Migrate existing archive DBs that predate the icon_url_override column.
	# CREATE TABLE IF NOT EXISTS won't update an already-existing table, so we
	# use ALTER TABLE ADD COLUMN guarded by a column-existence check.
	local has_icon_url_override
	has_icon_url_override=$(sqlite3 "$archive_db" \
		"SELECT COUNT(*) FROM pragma_table_info('project') WHERE name='icon_url_override';")
	if [[ "$has_icon_url_override" -eq 0 ]]; then
		sqlite3 "$archive_db" "ALTER TABLE project ADD COLUMN icon_url_override text;"
		print_info "Migrated archive.project schema: added icon_url_override column"
	fi

	# Migrate existing archive DBs that predate OpenCode's session.path column.
	# Without this, INSERT ... SELECT across active/archive schemas fails with:
	# "table archive.session has 19 columns but 20 values were supplied".
	local has_session_path
	has_session_path=$(sqlite3 "$archive_db" \
		"SELECT COUNT(*) FROM pragma_table_info('session') WHERE name='path';")
	if [[ "$has_session_path" -eq 0 ]]; then
		sqlite3 "$archive_db" "ALTER TABLE session ADD COLUMN path text;"
		print_info "Migrated archive.session schema: added path column"
	fi

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
	printf '%s\n' "id, project_id, parent_id, slug, directory, title, version, share_url, summary_additions, summary_deletions, summary_files, summary_diffs, revert, permission, time_created, time_updated, time_compacting, time_archived, workspace_id, path"
	return 0
}

_archive_session_select_columns() {
	local base_columns="id, project_id, parent_id, slug, directory, title, version, share_url, summary_additions, summary_deletions, summary_files, summary_diffs, revert, permission, time_created, time_updated, time_compacting, time_archived, workspace_id"

	if _sqlite_has_column "$ACTIVE_DB" "session" "path"; then
		printf '%s\n' "${base_columns}, path"
	else
		printf '%s\n' "${base_columns}, NULL AS path"
	fi
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
	wal_mb=$(( wal_bytes / 1048576 ))
	local threshold="${WAL_LARGE_THRESHOLD_MB:-500}"
	[[ "$wal_mb" -ge "$threshold" ]] || return 0
	print_warning "WAL still large after archive: $(format_bytes "$wal_bytes") (${wal_path})"
	# Probe checkpoint state: PASSIVE does not block writers — safe with live sessions.
	local ckpt_out blocked log_pages ckpt_pages
	ckpt_out=$(sqlite3 "$db" "PRAGMA wal_checkpoint(PASSIVE);" 2>/dev/null || echo "0|0|0")
	IFS='|' read -r blocked log_pages ckpt_pages <<<"$ckpt_out"
	if [[ "${blocked:-0}" == "1" ]] && [[ "${log_pages:-0}" -gt "${ckpt_pages:-0}" ]]; then
		local unckpt=$(( ${log_pages:-0} - ${ckpt_pages:-0} ))
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
		return 0
	fi

	print_info "Found $total_eligible sessions eligible for archiving"

	if ((dry_run)); then
		# Show what would be archived
		local msg_count part_count todo_count share_count
		msg_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM message WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		part_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM part WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		todo_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM todo WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		share_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session_share WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")

		echo ""
		echo "=== DRY RUN — would archive: ==="
		echo "  Sessions:       $total_eligible"
		echo "  Messages:       $msg_count"
		echo "  Parts:          $part_count"
		echo "  Todos:          $todo_count"
		echo "  Session shares: $share_count"
		echo ""
		print_info "Run without --dry-run to proceed."
		return 0
	fi

	# Create archive DB and schema
	create_archive_schema "$ARCHIVE_DB"

	local project_insert_columns project_select_columns
	local session_insert_columns session_select_columns
	project_insert_columns=$(_archive_project_insert_columns)
	project_select_columns=$(_archive_project_select_columns)
	session_insert_columns=$(_archive_session_insert_columns)
	session_select_columns=$(_archive_session_select_columns)

	local size_before
	size_before=$(file_size_bytes "$ACTIVE_DB")

	# Cleanup scope: checkpoint the archive WAL on any exit path (normal or signal).
	# _checkpoint_archive_db uses a global flag to prevent double-run; the trap
	# ensures it runs on early return between batches, and the fast-path call below
	# (before vacuum) runs it explicitly on normal completion.
	_ARCHIVE_CHECKPOINT_DONE=0
	trap '_checkpoint_archive_db "$ARCHIVE_DB"' RETURN

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
		local batch_limit="$DEFAULT_BATCH_SIZE"
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

		# Single transaction: copy to archive then delete from active.
		# ATTACH and DETACH are within the same sqlite3 invocation — the attachment
		# is released automatically when the process exits. The trap above ensures
		# the archive WAL is checkpointed on any exit path between batches.
		# Note: FK enforcement is OFF in opencode.db, so we must delete child rows manually.
		sqlite3 "$ACTIVE_DB" <<BATCH_SQL
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

-- Delete from active (child tables first since FK CASCADE is not enforced)
DELETE FROM part WHERE session_id IN ($in_clause);
DELETE FROM todo WHERE session_id IN ($in_clause);
DELETE FROM session_share WHERE session_id IN ($in_clause);
DELETE FROM message WHERE session_id IN ($in_clause);
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
	done

	# Fast-path explicit cleanup: checkpoint archive WAL before vacuum.
	# Marks done so the RETURN trap does not double-run.
	_checkpoint_archive_db "$ARCHIVE_DB"

	# Reclaim space — VACUUM works regardless of auto_vacuum setting.
	# PRAGMA incremental_vacuum is a no-op when auto_vacuum=0 (the SQLite default
	# used by OpenCode), so VACUUM is required here. VACUUM needs exclusive access;
	# if another connection holds the DB (interactive session), skip gracefully and
	# retry on the next archive cycle.
	print_info "Running VACUUM on active DB..."
	if ! sqlite3 "$ACTIVE_DB" "VACUUM;" 2>/dev/null; then
		print_warning "VACUUM skipped — database is in use by another process. Will retry next cycle."
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
	return 0
}

# --- Stats command ------------------------------------------------------------

cmd_stats() {
	check_sqlite3 || return 1
	check_active_db || return 1

	local now_s
	now_s=$(date +%s)
	local seven_days_ms=$(((now_s - 7 * 86400) * 1000))
	local fourteen_days_ms=$(((now_s - 14 * 86400) * 1000))

	echo ""
	echo "=== Active DB: $ACTIVE_DB ==="
	echo "  Size: $(format_bytes "$(file_size_bytes "$ACTIVE_DB")")"

	local session_count msg_count part_count todo_count share_count
	session_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session;")
	msg_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM message;")
	part_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM part;")
	todo_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM todo;")
	share_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session_share;")

	echo "  Sessions:       $session_count"
	echo "  Messages:       $msg_count"
	echo "  Parts:          $part_count"
	echo "  Todos:          $todo_count"
	echo "  Session shares: $share_count"

	# Last-update distribution
	local last_7d last_14d older
	last_7d=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $seven_days_ms;")
	last_14d=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $fourteen_days_ms AND time_updated < $seven_days_ms;")
	older=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated < $fourteen_days_ms;")

	echo ""
	echo "  Last-update distribution:"
	echo "    Last 7 days:   $last_7d"
	echo "    7–14 days:     $last_14d"
	echo "    Older than 14: $older"

	if [[ -f "$ARCHIVE_DB" ]]; then
		echo ""
		echo "=== Archive DB: $ARCHIVE_DB ==="
		echo "  Size: $(format_bytes "$(file_size_bytes "$ARCHIVE_DB")")"

		local arch_session arch_msg arch_part arch_todo arch_share
		arch_session=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session;" 2>/dev/null || echo "0")
		arch_msg=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM message;" 2>/dev/null || echo "0")
		arch_part=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM part;" 2>/dev/null || echo "0")
		arch_todo=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM todo;" 2>/dev/null || echo "0")
		arch_share=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session_share;" 2>/dev/null || echo "0")

		echo "  Sessions:       $arch_session"
		echo "  Messages:       $arch_msg"
		echo "  Parts:          $arch_part"
		echo "  Todos:          $arch_todo"
		echo "  Session shares: $arch_share"

		# Last-update distribution in archive
		local arch_7d arch_14d arch_older
		arch_7d=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $seven_days_ms;" 2>/dev/null || echo "0")
		arch_14d=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $fourteen_days_ms AND time_updated < $seven_days_ms;" 2>/dev/null || echo "0")
		arch_older=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated < $fourteen_days_ms;" 2>/dev/null || echo "0")

		echo ""
		echo "  Last-update distribution:"
		echo "    Last 7 days:   $arch_7d"
		echo "    7–14 days:     $arch_14d"
		echo "    Older than 14: $arch_older"
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
  --retention-days N        Sessions inactive for N days are archived (default: 14)
  --keep-sessions N         Keep newest N active sessions by last update; archive older sessions beyond the budget
  --dry-run                 Show what would be archived without doing it
  --max-duration-seconds N  Stop after N seconds even when not done (default: 60)

ENVIRONMENT:
  OPENCODE_DB               Active DB path (default: ~/.local/share/opencode/opencode.db)
  OPENCODE_ARCHIVE_DB       Archive DB path (default: ~/.local/share/opencode/opencode-archive.db)

EXAMPLES:
  # Show current stats
  opencode-db-archive.sh stats

  # Preview what would be archived (30-day retention)
  opencode-db-archive.sh archive --retention-days 30 --dry-run

  # Keep the 500 most recently updated active sessions, archive older sessions
  opencode-db-archive.sh archive --keep-sessions 500

  # Archive with defaults (14 days, 60s time budget)
  opencode-db-archive.sh archive

  # Archive as pulse pre-flight (short time budget)
  opencode-db-archive.sh archive --max-duration-seconds 30
HELP
	return 0
}

# --- Main dispatch ------------------------------------------------------------

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	archive)
		cmd_archive "$@"
		;;
	stats)
		cmd_stats "$@"
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
	return 0
}

main "$@"
