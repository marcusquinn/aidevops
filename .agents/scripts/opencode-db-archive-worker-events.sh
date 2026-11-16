#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Active-DB event expiry for terminated headless worker sessions (GH#38491).
# Source only through opencode-db-archive.sh, which supplies configuration,
# SQLite helpers, output functions and idle/WAL safety checks. No work runs on
# import.
#
# Why: OpenCode re-serialises a message's full `summary.diffs` into every
# `message.updated` event. One worker that merged its base branch wrote 68
# events of ~152 MiB each (10 GiB). Workers leave the active DB only after the
# 7-day worker retention, and VACUUM is blocked while TUIs hold the DB, so the
# event table grew without bound. The transcript lives in message/part; events
# of a finished worker are expendable (the archive already expires them).
#
# Liveness: headless workers run in an isolated DB and are recorded in the
# headless ledger (worker_sessions) only when that DB is merged back after the
# worker exits. A continuation worker that resumes a recorded session copies its
# events into a fresh isolated DB and replaces them on merge, so expiring the
# shared copy cannot lose its state. The inactivity window (time_updated) and
# the active-worker/held-session exclusions are additional guards. Interactive
# sessions are never in worker_sessions and are never touched.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_OPENCODE_DB_ARCHIVE_WORKER_EVENTS_LOADED:-}" ]] && return 0
_OPENCODE_DB_ARCHIVE_WORKER_EVENTS_LOADED=1

readonly DEFAULT_WORKER_EVENT_EXPIRY_MINUTES=60
# Worker events range from bytes to hundreds of MiB, and a host can hold
# millions of them. Each transaction deletes at most this many rows and this
# many payload bytes (one oversized row is still allowed alone), so the write
# lock and the overflow-chain walk it performs stay short.
readonly DEFAULT_WORKER_EVENT_BATCH_SIZE=500
readonly DEFAULT_WORKER_EVENT_BATCH_BYTES=67108864

# Payload size expression that does not read overflow pages. octet_length()
# (SQLite 3.43+) reads only the record header; older SQLite falls back to a
# row-count-only bound.
_archive_worker_event_size_expr() {
	if [[ "$(sqlite3 :memory: "SELECT octet_length('ab');" 2>/dev/null)" == "2" ]]; then
		printf 'octet_length(data)\n'
		return 0
	fi
	printf '0\n'
	return 0
}

# Print the SQL filter over `session` rows whose events may be expired, or
# return 1 when the headless ledger has no worker_sessions table.
_archive_worker_event_filter() {
	local minutes="$1"
	local ledger_tables cutoff_ms sid list=""
	ledger_tables=$(_archive_ledger_tables)
	grep -qx 'worker_sessions' <<<"$ledger_tables" || return 1
	cutoff_ms=$(($(date +%s) * 1000 - minutes * 60000))
	# Pulse logs name sessions of workers that are still running.
	while IFS= read -r sid; do
		[[ "$sid" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || continue
		list="${list}${list:+,}'${sid}'"
	done < <(get_active_worker_sessions)
	printf 'id IN (SELECT session_id FROM ledger.worker_sessions) AND time_updated < %s%s%s\n' \
		"$cutoff_ms" "${list:+ AND id NOT IN (${list})}" "$(_archive_held_exclude_clause)"
	return 0
}

# Run one ledger-attached statement against the active DB within a time bound.
# Exit 124 when the bound expires; SQLite rolls back the interrupted batch.
_archive_worker_event_sql() {
	local seconds="$1"
	local sql="$2"
	python3 -c 'import subprocess, sys
try:
    result = subprocess.run(["sqlite3", "-cmd", ".timeout 5000", "-cmd", sys.argv[3], sys.argv[2], sys.argv[4]],
                            timeout=int(sys.argv[1]), check=False)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)' "$seconds" "$ACTIVE_DB" "ATTACH DATABASE $(_archive_sql_quote "$HEADLESS_LEDGER_DB") AS ledger;" "$sql"
	return $?
}

_archive_worker_event_dry_run() {
	local filter="$1" minutes="$2" size_expr="$3"
	local sessions count bytes
	[[ "$size_expr" != "0" ]] || size_expr="LENGTH(CAST(data AS BLOB))"
	sessions=$(_archive_active_query "SELECT COUNT(*) FROM session WHERE ${filter} AND id IN (SELECT aggregate_id FROM event);") || return 1
	count=$(_archive_active_query "SELECT COUNT(*) FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE ${filter});") || return 1
	bytes=$(_archive_active_query "SELECT COALESCE(SUM(${size_expr}), 0) FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE ${filter});") || return 1
	print_info "DRY RUN — would expire $count active-DB events of $sessions terminated worker session(s) (inactive ${minutes}+ min), $(format_bytes "$bytes") payload; transcripts preserved"
	return 0
}

# One batch: candidate rows found through the aggregate index (no rescans of
# kept rows), cut at the row cap and at the cumulative byte bound.
_archive_worker_event_batch_sql() {
	local filter="$1" size_expr="$2" row_cap="$3" byte_cap="$4"
	printf 'DELETE FROM event WHERE rowid IN (SELECT r FROM (SELECT r, ROW_NUMBER() OVER (ORDER BY r) AS rn, SUM(b) OVER (ORDER BY r ROWS UNBOUNDED PRECEDING) AS cum FROM (SELECT rowid AS r, %s AS b FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE %s) LIMIT %s)) WHERE rn = 1 OR cum <= %s); SELECT changes();\n' \
		"$size_expr" "$filter" "$row_cap" "$byte_cap"
	return 0
}

# _archive_expire_worker_events <minutes> <dry_run> <budget_seconds>
# Delete event rows of terminated worker sessions from the active DB in small
# batches. Keeps session/message/part/todo and event_sequence (the same split
# as the archived event expiry). Freed pages are reused without VACUUM.
# Callers must have passed _archive_mutation_preflight (holder/WAL/schema).
_archive_expire_worker_events() {
	local minutes="$1" dry_run="$2" budget="$3"
	local filter size_expr batch_sql batch_size batch_bytes start now remaining rc count total=0
	local page_size free_before free_after freed_pages=0
	((minutes > 0 && budget > 0)) || return 0
	_sqlite_has_table "$ACTIVE_DB" "$EVENT_TABLE_NAME" || return 0
	if ! filter=$(_archive_worker_event_filter "$minutes"); then
		print_info "Worker event expiry skipped — headless ledger has no worker_sessions table"
		return 0
	fi
	_ARCHIVE_LEDGER_ATTACH=1
	size_expr=$(_archive_worker_event_size_expr)
	if ((dry_run)); then
		_archive_worker_event_dry_run "$filter" "$minutes" "$size_expr"
		return $?
	fi
	batch_size="${OPENCODE_DB_ARCHIVE_WORKER_EVENT_BATCH_SIZE:-$DEFAULT_WORKER_EVENT_BATCH_SIZE}"
	batch_bytes="${OPENCODE_DB_ARCHIVE_WORKER_EVENT_BATCH_BYTES:-$DEFAULT_WORKER_EVENT_BATCH_BYTES}"
	_validate_nonnegative_integer "$batch_size" "OPENCODE_DB_ARCHIVE_WORKER_EVENT_BATCH_SIZE" || return 1
	_validate_nonnegative_integer "$batch_bytes" "OPENCODE_DB_ARCHIVE_WORKER_EVENT_BATCH_BYTES" || return 1
	((batch_size > 0 && batch_bytes > 0)) || return 1
	# Without a byte bound, keep the row-only batch as small as the held batch.
	if [[ "$size_expr" == "0" ]] && ((batch_size > ARCHIVE_HELD_BATCH_SIZE)); then
		batch_size="$ARCHIVE_HELD_BATCH_SIZE"
	fi
	# GH#38590: a leftover marker or an earlier timeout halved the persisted
	# limits; a committed pass doubles them back toward the defaults.
	local default_size="$batch_size" default_bytes="$batch_bytes" timed_out=0
	_archive_adapt_recover events 10
	if ((_ARCHIVE_ADAPT_LIMIT > 0 && _ARCHIVE_ADAPT_LIMIT < batch_size)); then
		batch_size="$_ARCHIVE_ADAPT_LIMIT"
	fi
	if ((_ARCHIVE_ADAPT_BYTES > 0 && _ARCHIVE_ADAPT_BYTES < batch_bytes)); then
		batch_bytes="$_ARCHIVE_ADAPT_BYTES"
	fi
	batch_sql=$(_archive_worker_event_batch_sql "$filter" "$size_expr" "$batch_size" "$batch_bytes")
	page_size=$(sqlite3 "$ACTIVE_DB" "PRAGMA page_size;") || return 1
	free_before=$(sqlite3 "$ACTIVE_DB" "PRAGMA freelist_count;") || return 1
	start=$(date +%s)
	while true; do
		now=$(date +%s)
		remaining=$((budget - (now - start)))
		((remaining > 0)) || break
		((total == 0)) || _archive_held_gate_recheck || break
		rc=0
		_archive_adapt_mark events "$batch_size" "$batch_bytes"
		count=$(_archive_worker_event_sql "$remaining" "$batch_sql") || rc=$?
		if ((rc == 124)); then
			timed_out=1
			_archive_adapt_halve events "$batch_size" "$batch_bytes" 10
			break
		fi
		((rc == 0)) || {
			_archive_adapt_clear events
			return 1
		}
		[[ "$count" =~ ^[0-9]+$ ]] || return 1
		total=$((total + count))
		((count > 0)) || break
		_archive_adapt_commit events "$batch_size" "$batch_bytes" "$default_size" "$default_bytes"
	done
	((timed_out)) || _archive_adapt_clear events
	if ((timed_out)); then
		print_warning "Worker event expiry timed out after $(($(date +%s) - start))s; ${total} committed; next batch limit ${_ARCHIVE_ADAPT_LIMIT} row(s) / $(format_bytes "$_ARCHIVE_ADAPT_BYTES")"
	fi
	free_after=$(sqlite3 "$ACTIVE_DB" "PRAGMA freelist_count;") || free_after="$free_before"
	# Concurrent OpenCode writes may already reuse freed pages: a lower bound.
	((free_after <= free_before)) || freed_pages=$((free_after - free_before))
	print_info "Worker event expiry pass complete: expired $total active-DB events of terminated worker sessions (inactive ${minutes}+ min); $(format_bytes "$((freed_pages * page_size))") freed for reuse ($freed_pages pages, lower bound); transcripts preserved"
	return 0
}
