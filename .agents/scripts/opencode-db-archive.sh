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
#   opencode-db-archive.sh archive [--retention-days N] [--dry-run] [--max-duration-seconds N]
#   opencode-db-archive.sh stats
#   opencode-db-archive.sh help
#
# Environment:
#   OPENCODE_DB          — active DB path (default: ~/.local/share/opencode/opencode.db)
#   OPENCODE_ARCHIVE_DB  — archive DB path (default: ~/.local/share/opencode/opencode-archive.db)
# -----------------------------------------------------------------------------

set -Eeuo pipefail

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

	# Check /tmp/pulse-*.log files modified within the last hour
	for logfile in /tmp/pulse-*.log; do
		[[ -f "$logfile" ]] || continue
		local file_mtime
		# Linux stat -c first (stat -f '%m' on Linux outputs filesystem info to stdout)
		file_mtime=$(stat -c '%Y' "$logfile" 2>/dev/null || stat -f '%m' "$logfile" 2>/dev/null || echo "0")
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
	# Linux stat -c first (stat -f '%z' on Linux outputs filesystem info to stdout, not file size)
	stat -c '%s' "$filepath" 2>/dev/null || stat -f '%z' "$filepath" 2>/dev/null || echo "0"
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
	`commands` text
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
	return 0
}

# --- Archive command ----------------------------------------------------------

cmd_archive() {
	local retention_days="$DEFAULT_RETENTION_DAYS"
	local dry_run=0
	local max_duration="$DEFAULT_MAX_DURATION"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--retention-days)
			retention_days="$2"
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		--max-duration-seconds)
			max_duration="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			cmd_help
			return 1
			;;
		esac
	done

	check_sqlite3 || return 1
	check_active_db || return 1

	local cutoff_ms
	cutoff_ms=$(($(date +%s) * 1000 - retention_days * 86400 * 1000))

	print_info "Retention: ${retention_days} days (cutoff: $(date -r "$((cutoff_ms / 1000))" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$((cutoff_ms / 1000))" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'N/A'))"
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

	# Count eligible sessions
	local total_eligible
	total_eligible=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_created < $cutoff_ms $exclude_clause;")

	if ((total_eligible == 0)); then
		print_success "No sessions older than $retention_days days to archive."
		return 0
	fi

	print_info "Found $total_eligible sessions eligible for archiving"

	if ((dry_run)); then
		# Show what would be archived
		local msg_count part_count todo_count share_count
		msg_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM message WHERE session_id IN (SELECT id FROM session WHERE time_created < $cutoff_ms $exclude_clause);")
		part_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM part WHERE session_id IN (SELECT id FROM session WHERE time_created < $cutoff_ms $exclude_clause);")
		todo_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM todo WHERE session_id IN (SELECT id FROM session WHERE time_created < $cutoff_ms $exclude_clause);")
		share_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session_share WHERE session_id IN (SELECT id FROM session WHERE time_created < $cutoff_ms $exclude_clause);")

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
		session_ids=$(sqlite3 "$ACTIVE_DB" "SELECT id FROM session WHERE time_created < $cutoff_ms $exclude_clause ORDER BY time_created ASC LIMIT $batch_limit;")

		if [[ -z "$session_ids" ]]; then
			break
		fi

		local batch_count
		batch_count=$(echo "$session_ids" | wc -l | tr -d ' ')

		# Build the IN clause for this batch
		local in_clause=""
		in_clause=$(printf '%s\n' "$session_ids" | sed "s/.*/'&'/" | paste -sd,)

		# Single transaction: copy to archive then delete from active.
		# ATTACH and DETACH are within the same sqlite3 invocation — the attachment
		# is released automatically when the process exits. The trap above ensures
		# the archive WAL is checkpointed on any exit path between batches.
		# Note: FK enforcement is OFF in opencode.db, so we must delete child rows manually.
		sqlite3 "$ACTIVE_DB" <<BATCH_SQL
ATTACH DATABASE '$ARCHIVE_DB' AS archive;

BEGIN IMMEDIATE;

-- Copy referenced project rows (INSERT OR IGNORE — projects may already exist)
INSERT OR IGNORE INTO archive.project
SELECT p.* FROM project p
WHERE p.id IN (SELECT DISTINCT project_id FROM session WHERE id IN ($in_clause));

-- Copy sessions
INSERT OR IGNORE INTO archive.session
SELECT * FROM session WHERE id IN ($in_clause);

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

	# Reclaim space
	print_info "Running incremental vacuum on active DB..."
	sqlite3 "$ACTIVE_DB" "PRAGMA incremental_vacuum;"

	local size_after
	size_after=$(file_size_bytes "$ACTIVE_DB")
	local total_freed=$((size_before - size_after))
	if ((total_freed < 0)); then total_freed=0; fi

	echo ""
	print_success "Archive complete: $archived_total sessions moved"
	print_success "Active DB: $(format_bytes "$size_before") → $(format_bytes "$size_after") ($(format_bytes "$total_freed") freed)"
	print_success "Archive DB: $(format_bytes "$(file_size_bytes "$ARCHIVE_DB")")"
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

	# Age distribution
	local last_7d last_14d older
	last_7d=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_created >= $seven_days_ms;")
	last_14d=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_created >= $fourteen_days_ms AND time_created < $seven_days_ms;")
	older=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_created < $fourteen_days_ms;")

	echo ""
	echo "  Age distribution:"
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

		# Age distribution in archive
		local arch_7d arch_14d arch_older
		arch_7d=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_created >= $seven_days_ms;" 2>/dev/null || echo "0")
		arch_14d=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_created >= $fourteen_days_ms AND time_created < $seven_days_ms;" 2>/dev/null || echo "0")
		arch_older=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_created < $fourteen_days_ms;" 2>/dev/null || echo "0")

		echo ""
		echo "  Age distribution:"
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
  --retention-days N        Sessions older than N days are archived (default: 14)
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
