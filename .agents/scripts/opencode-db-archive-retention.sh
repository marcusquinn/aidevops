#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Retention configuration and opt-in session pruning for opencode-db-archive.sh.
# Source only through the entry point, which supplies configuration, SQLite
# helpers, output functions and idle/WAL safety checks. No work runs on import.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_OPENCODE_DB_ARCHIVE_RETENTION_LOADED:-}" ]] && return 0
_OPENCODE_DB_ARCHIVE_RETENTION_LOADED=1

# Resolve sibling configuration helpers when sourced without the entry point.
if [[ -z "${_oda_dir:-}" ]]; then
	_oda_dir="${BASH_SOURCE[0]%/*}"
	[[ "$_oda_dir" == "${BASH_SOURCE[0]}" ]] && _oda_dir="."
fi

# Resolve storage.opencode_session_retention_days (env override first). Prints a
# non-negative integer; 0 means keep everything. Invalid values never delete.
_prune_resolve_retention_days() {
	local raw="${AIDEVOPS_OPENCODE_SESSION_RETENTION_DAYS:-}"

	if [[ -z "$raw" ]]; then
		if ! declare -F config_get >/dev/null 2>&1 && [[ -f "${_oda_dir}/config-helper.sh" ]]; then
			# shellcheck source=config-helper.sh
			source "${_oda_dir}/config-helper.sh" >/dev/null 2>&1 || true
		fi
		if declare -F config_get >/dev/null 2>&1; then
			raw=$(config_get "storage.opencode_session_retention_days" "0" 2>/dev/null) || raw=""
		fi
	fi
	raw="${raw:-0}"
	if [[ ! "$raw" =~ ^[0-9]{1,5}$ ]]; then
		printf '[WARN] Invalid storage.opencode_session_retention_days=%q; treating as 0 (keep all sessions)\n' "$raw" >&2
		raw=0
	fi
	printf '%s\n' "$((10#$raw))"
	return 0
}

cmd_retention_days() {
	_prune_resolve_retention_days
	return 0
}

# Exclusion clause for sessions with an active worker (empty when none).
_prune_exclude_clause() {
	local active_sessions="" exclude_list="" sid=""

	active_sessions=$(get_active_worker_sessions)
	[[ -n "$active_sessions" ]] || return 0
	while IFS= read -r sid; do
		exclude_list="${exclude_list}${exclude_list:+,}'${sid}'"
	done <<<"$active_sessions"
	printf 'AND id NOT IN (%s)\n' "$exclude_list"
	return 0
}

# Sum of payload bytes owned by sessions matching the filter in a DB.
_prune_bytes_sql() {
	local db="$1"
	local filter="$2"
	local sql="SELECT (SELECT COALESCE(SUM(LENGTH(data)), 0) FROM message WHERE session_id IN (SELECT id FROM session WHERE ${filter}))"

	sql="${sql} + (SELECT COALESCE(SUM(LENGTH(data)), 0) FROM part WHERE session_id IN (SELECT id FROM session WHERE ${filter}))"
	if _sqlite_has_table "$db" session_message; then
		sql="${sql} + (SELECT COALESCE(SUM(LENGTH(data)), 0) FROM session_message WHERE session_id IN (SELECT id FROM session WHERE ${filter}))"
	fi
	if _sqlite_has_table "$db" "$EVENT_TABLE_NAME"; then
		sql="${sql} + (SELECT COALESCE(SUM(LENGTH(data)), 0) FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE ${filter}))"
	fi
	printf '%s;\n' "$sql"
	return 0
}

# Positive evidence the DB is idle: no holders, stable WAL, supported schema.
# Returns 0 ready, 2 protected skip, 3 unsupported schema.
_prune_preflight() {
	local db="$1"
	local schema_mode="$2"
	local label="$3"
	local holder_count=""

	holder_count=$(_db_holder_count "$db")
	if [[ "$holder_count" == "$OPENCODE_DB_STATE_UNKNOWN" ]]; then
		print_warning "Prune deferred (${label}) — DB holder state is unavailable."
		return 2
	fi
	if [[ "$holder_count" -gt 0 ]]; then
		print_warning "Prune deferred (${label}) — ${holder_count} process(es) hold the DB open."
		return 2
	fi
	if ! _wal_is_stable "$db"; then
		print_warning "Prune deferred (${label}) — WAL changed during the safety observation window."
		return 2
	fi
	if ! opencode_archive_schema_supported "$db" "$schema_mode"; then
		print_error "Unsupported or unavailable OpenCode session schema in ${label} DB: $(opencode_archive_schema_diagnostic); data was left untouched."
		return 3
	fi
	return 0
}

# VACUUM needs room for a compacted copy; defer rather than fill the disk.
_prune_vacuum_headroom_ok() {
	local db="$1"
	local page_count="" free_count="" page_size="" avail_kb="" live_kb=0

	page_count=$(sqlite3 "$db" "PRAGMA page_count;" 2>/dev/null || true)
	free_count=$(sqlite3 "$db" "PRAGMA freelist_count;" 2>/dev/null || true)
	page_size=$(sqlite3 "$db" "PRAGMA page_size;" 2>/dev/null || true)
	[[ "$page_count" =~ ^[0-9]+$ && "$free_count" =~ ^[0-9]+$ && "$page_size" =~ ^[0-9]+$ ]] || return 1
	live_kb=$(((page_count - free_count) * page_size / 1024 + 1))
	avail_kb=$(df -Pk "${db%/*}" 2>/dev/null | awk 'NR==2 {print $4}')
	[[ "$avail_kb" =~ ^[0-9]+$ ]] || return 1
	((avail_kb > live_kb))
	return $?
}

# Compact the archive DB (nothing reads it live) after rows were deleted.
_prune_vacuum_archive_db() {
	local holder_count=""

	if ! _prune_vacuum_headroom_ok "$ARCHIVE_DB"; then
		print_warning "Archive VACUUM deferred — not enough free disk space for a compacted copy."
		return 2
	fi
	holder_count=$(_db_holder_count "$ARCHIVE_DB")
	if [[ "$holder_count" == "$OPENCODE_DB_STATE_UNKNOWN" || "$holder_count" -gt 0 ]]; then
		print_warning "Archive VACUUM deferred — archive DB holder is active or unknown."
		return 2
	fi
	sqlite3 "$ARCHIVE_DB" "$SQL_CHECKPOINT_TRUNCATE" >/dev/null 2>&1 || true
	print_info "Running VACUUM on archive DB..."
	if ! sqlite3 "$ARCHIVE_DB" "VACUUM;" 2>/dev/null; then
		print_warning "Archive VACUUM deferred — exclusive access was lost. Will retry next cycle."
		return 2
	fi
	sqlite3 "$ARCHIVE_DB" "$SQL_CHECKPOINT_TRUNCATE" >/dev/null 2>&1 || true
	if [[ "$(sqlite3 "$ARCHIVE_DB" "$SQL_QUICK_CHECK" 2>/dev/null || true)" != "ok" ]]; then
		print_error "Archive DB quick_check failed after VACUUM."
		return 1
	fi
	return 0
}

# Delete one batch of sessions (and every dependent row) in one transaction.
_prune_delete_batch() {
	local db="$1"
	local in_clause="$2"
	local session_message_sql="" session_input_sql="" context_epoch_sql=""
	local event_sequence_sql="" event_sql=""

	_sqlite_has_table "$db" session_message && session_message_sql="DELETE FROM session_message WHERE session_id IN ($in_clause);"
	_sqlite_has_table "$db" session_input && session_input_sql="DELETE FROM session_input WHERE session_id IN ($in_clause);"
	_sqlite_has_table "$db" session_context_epoch && context_epoch_sql="DELETE FROM session_context_epoch WHERE session_id IN ($in_clause);"
	_sqlite_has_table "$db" event_sequence && event_sequence_sql="DELETE FROM event_sequence WHERE aggregate_id IN ($in_clause);"
	_sqlite_has_table "$db" "$EVENT_TABLE_NAME" && event_sql="DELETE FROM event WHERE aggregate_id IN ($in_clause);"

	# Dependency-safe order (children first); mirrors the archive delete path.
	sqlite3 -cmd '.timeout 5000' "$db" <<PRUNE_SQL >/dev/null
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
DELETE FROM part WHERE session_id IN ($in_clause);
DELETE FROM todo WHERE session_id IN ($in_clause);
DELETE FROM session_share WHERE session_id IN ($in_clause);
${session_message_sql}
${session_input_sql}
${context_epoch_sql}
DELETE FROM message WHERE session_id IN ($in_clause);
${event_sql}
${event_sequence_sql}
DELETE FROM session WHERE id IN ($in_clause);
COMMIT;
PRUNE_SQL
	return $?
}

# Prune one DB. Prints a summary; returns 0, 1 failure, 2 protected skip, 3 schema.
_prune_one_db() {
	local db="$1"
	local label="$2"
	local schema_mode="$3"
	local filter="$4"
	local dry_run="$5"
	local max_duration="$6"
	local eligible="" bytes="" rc=0

	if [[ ! -f "$db" ]]; then
		return 0
	fi
	if ((dry_run)); then
		if ! opencode_archive_schema_supported "$db" "$schema_mode"; then
			print_error "Unsupported or unavailable OpenCode session schema in ${label} DB: $(opencode_archive_schema_diagnostic)"
			return 3
		fi
		eligible=$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM session WHERE ${filter};") || return 1
		bytes=$(sqlite3 -readonly "$db" "$(_prune_bytes_sql "$db" "$filter")") || return 1
		print_info "DRY RUN — would permanently delete ${eligible} session(s) from ${label} DB (~$(format_bytes "$bytes") of payload): ${db}"
		return 0
	fi

	_prune_preflight "$db" "$schema_mode" "$label" || {
		rc=$?
		return "$rc"
	}

	local size_before size_after start_time deleted=0 session_ids="" in_clause="" batch_count=0
	size_before=$(file_size_bytes "$db")
	start_time=$(date +%s)
	while true; do
		if (($(date +%s) - start_time >= max_duration)); then
			print_warning "Prune time budget exhausted (${max_duration}s) for ${label} DB after ${deleted} session(s). Will resume next cycle."
			break
		fi
		session_ids=$(sqlite3 "$db" "SELECT id FROM session WHERE ${filter} ORDER BY time_updated ASC, id ASC LIMIT ${ARCHIVE_BATCH_SIZE};") || return 1
		[[ -n "$session_ids" ]] || break
		batch_count=$(printf '%s\n' "$session_ids" | wc -l | tr -d ' ')
		in_clause=$(printf '%s\n' "$session_ids" | sed "s/.*/'&'/" | tr '\n' ',' | sed 's/,$//')
		if ! _prune_delete_batch "$db" "$in_clause"; then
			print_error "Prune batch failed on ${label} DB; committed batches remain deleted."
			return 1
		fi
		deleted=$((deleted + batch_count))
		print_info "Pruned ${deleted} session(s) from ${label} DB"
		if [[ "$ARCHIVE_BATCH_DELAY_SECONDS" != "0" ]]; then
			sleep "$ARCHIVE_BATCH_DELAY_SECONDS"
		fi
	done

	if ((deleted == 0)); then
		print_success "No ${label} sessions older than the retention cutoff."
		return 0
	fi

	local compact_rc=0
	if [[ "$label" == "archive" ]]; then
		_prune_vacuum_archive_db || compact_rc=$?
	elif ! _prune_vacuum_headroom_ok "$db"; then
		print_warning "Active VACUUM deferred — not enough free disk space for a compacted copy."
		compact_rc=2
	else
		_archive_compact_active_db || compact_rc=$?
	fi
	size_after=$(file_size_bytes "$db")
	print_success "Pruned ${deleted} session(s) from ${label} DB: $(format_bytes "$size_before") → $(format_bytes "$size_after")"
	return "$compact_rc"
}

cmd_prune() {
	local older_than_days=""
	local dry_run=1
	local max_duration="$DEFAULT_MAX_DURATION"

	while [[ $# -gt 0 ]]; do
		local option="$1"
		local option_value="${2:-}"
		case "$option" in
		--older-than-days)
			[[ $# -ge 2 ]] || {
				print_error "--older-than-days requires a value"
				return 1
			}
			older_than_days="$option_value"
			shift 2
			;;
		--max-duration-seconds)
			[[ $# -ge 2 ]] || {
				print_error "--max-duration-seconds requires a value"
				return 1
			}
			max_duration="$option_value"
			shift 2
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		--apply)
			dry_run=0
			shift
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
	if [[ -z "$older_than_days" ]]; then
		print_error "prune requires --older-than-days N (N >= 1); nothing was deleted."
		return 1
	fi
	_validate_nonnegative_integer "$older_than_days" "--older-than-days" || return 1
	if [[ ! "$older_than_days" =~ ^[0-9]{1,5}$ || "$((10#$older_than_days))" -lt 1 ]]; then
		print_error "--older-than-days must be between 1 and 99999; nothing was deleted."
		return 1
	fi
	older_than_days=$((10#$older_than_days))
	_validate_nonnegative_integer "$max_duration" "--max-duration-seconds" || return 1
	_validate_nonnegative_integer "$ARCHIVE_BATCH_SIZE" "OPENCODE_DB_ARCHIVE_BATCH_SIZE" || return 1
	if [[ "$ARCHIVE_BATCH_SIZE" -eq 0 ]]; then
		print_error "OPENCODE_DB_ARCHIVE_BATCH_SIZE must be greater than zero."
		return 1
	fi
	if [[ -f "$ARCHIVE_DB" && "$ARCHIVE_DB" -ef "$ACTIVE_DB" ]]; then
		print_error "Prune refused — active and archive DB are the same file"
		return 1
	fi

	local cutoff_ms exclude_clause filter
	cutoff_ms=$(($(date +%s) * 1000 - older_than_days * 86400 * 1000))
	exclude_clause=$(_prune_exclude_clause)
	filter="time_updated < ${cutoff_ms}${exclude_clause:+ }${exclude_clause}"
	print_info "Session retention: delete sessions last updated more than ${older_than_days} days ago (cutoff: $(_format_cutoff_time "$cutoff_ms"))"
	print_info "Active DB: $ACTIVE_DB"
	print_info "Archive DB: $ARCHIVE_DB"

	local result=0 rc=0
	_prune_one_db "$ARCHIVE_DB" archive required "$filter" "$dry_run" "$max_duration" || rc=$?
	if [[ "$rc" -ne 0 ]]; then result="$rc"; fi
	rc=0
	_prune_one_db "$ACTIVE_DB" active optional "$filter" "$dry_run" "$max_duration" || rc=$?
	# Failure (1) outranks schema (3), which outranks a protected skip (2).
	if [[ "$rc" -eq 1 || ("$rc" -ne 0 && "$result" -eq 0) || ("$rc" -eq 3 && "$result" -eq 2) ]]; then result="$rc"; fi
	return "$result"
}
