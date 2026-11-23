#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Active-DB event expiry for every inactive session (GH#38491, GH#38630).
# Source only through opencode-db-archive.sh, which supplies configuration,
# SQLite helpers, output functions and the active-worker list. No work runs on
# import.
#
# Why: OpenCode re-serialises a message's full `summary.diffs` into every
# `message.updated` event. One worker that merged its base branch wrote 68
# events of ~152 MiB each (10 GiB); interactive sessions do the same. VACUUM and
# the full archive are blocked while TUIs hold the DB, so the event table grew to
# ~78 GB even after the worker-only pass. The transcript lives in message/part;
# events are expendable, so the events of ANY session idle longer than the window
# (default 60 min) are deleted. Sessions inside the window, running workers named
# in pulse logs, and session/message/part/todo/event_sequence are never touched.
#
# The pass is a series of short write transactions, tolerates SQLITE_BUSY (rc 2,
# retried next cycle) and does not require holders to be idle.
#
# OPENCODE_DB_EVENT_MAX_BYTES (default 2 GiB) is the payload ceiling shown by
# `opencode-db-maintenance-helper.sh report|notice`; when the table is above it
# the pass says so. Idle sessions are always expired least recently updated first.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_OPENCODE_DB_ARCHIVE_WORKER_EVENTS_LOADED:-}" ]] && return 0
_OPENCODE_DB_ARCHIVE_WORKER_EVENTS_LOADED=1

readonly DEFAULT_WORKER_EVENT_EXPIRY_MINUTES=60
readonly DEFAULT_EVENT_MAX_BYTES=2147483648
# Sessions picked per batch (oldest first); bounds the scan of the event index.
readonly EVENT_EXPIRY_SESSIONS_PER_BATCH=20
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

# Print the SQL filter over `session` rows whose events may be expired: idle
# past the window and not a running worker. Needs no ledger and no holder idle.
_archive_worker_event_filter() {
	local minutes="$1"
	local cutoff_ms sid list=""
	cutoff_ms=$(($(date +%s) * 1000 - minutes * 60000))
	# Pulse logs name sessions of workers that are still running.
	while IFS= read -r sid; do
		[[ "$sid" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || continue
		list="${list}${list:+,}'${sid}'"
	done < <(get_active_worker_sessions)
	printf 'time_updated < %s%s\n' "$cutoff_ms" "${list:+ AND id NOT IN (${list})}"
	return 0
}

# Run one statement against the active DB within a time bound.
# Exit 124 when the bound expires (SQLite rolls the batch back); exit 5 when the
# database stayed locked past the 5 s busy timeout (SQLITE_BUSY).
_archive_worker_event_sql() {
	local seconds="$1"
	local sql="$2"
	python3 -c 'import subprocess, sys
try:
    r = subprocess.run(["sqlite3", "-cmd", ".timeout 5000", sys.argv[2], sys.argv[3]],
                       timeout=int(sys.argv[1]), check=False, capture_output=True, text=True)
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.stdout.write(r.stdout)
sys.stderr.write(r.stderr)
if r.returncode != 0 and ("locked" in r.stderr or "busy" in r.stderr.lower()):
    sys.exit(5)
sys.exit(r.returncode)' "$seconds" "$ACTIVE_DB" "$sql"
	return $?
}

_archive_worker_event_dry_run() {
	local filter="$1" minutes="$2" size_expr="$3"
	local sessions count bytes
	[[ "$size_expr" != "0" ]] || size_expr="LENGTH(CAST(data AS BLOB))"
	sessions=$(_archive_active_query "SELECT COUNT(*) FROM session WHERE ${filter} AND id IN (SELECT aggregate_id FROM event);") || return 1
	count=$(_archive_active_query "SELECT COUNT(*) FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE ${filter});") || return 1
	bytes=$(_archive_active_query "SELECT COALESCE(SUM(${size_expr}), 0) FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE ${filter});") || return 1
	print_info "DRY RUN — would expire $count active-DB events of $sessions inactive session(s) (idle ${minutes}+ min), $(format_bytes "$bytes") payload; transcripts preserved"
	return 0
}

# One batch: the least recently updated idle sessions that still have events,
# then their rows cut at the row cap and at the cumulative byte bound.
_archive_worker_event_batch_sql() {
	local filter="$1" size_expr="$2" row_cap="$3" byte_cap="$4"
	local picked
	picked="SELECT id FROM session WHERE ${filter} AND EXISTS (SELECT 1 FROM event WHERE aggregate_id = session.id) ORDER BY time_updated, id LIMIT ${EVENT_EXPIRY_SESSIONS_PER_BATCH}"
	printf 'DELETE FROM event WHERE rowid IN (SELECT r FROM (SELECT r, ROW_NUMBER() OVER (ORDER BY r) AS rn, SUM(b) OVER (ORDER BY r ROWS UNBOUNDED PRECEDING) AS cum FROM (SELECT rowid AS r, %s AS b FROM event WHERE aggregate_id IN (%s) LIMIT %s)) WHERE rn = 1 OR cum <= %s); SELECT changes();\n' \
		"$size_expr" "$picked" "$row_cap" "$byte_cap"
	return 0
}

# Print "<rows> <bytes>" of the active-DB event table.
_archive_event_totals() {
	local size_expr="$1"
	[[ "$size_expr" != "0" ]] || size_expr="LENGTH(CAST(data AS BLOB))"
	_archive_active_query "SELECT COUNT(*) || ' ' || COALESCE(SUM(${size_expr}), 0) FROM event;"
	return $?
}

# _archive_expire_worker_events <minutes> <dry_run> <budget_seconds>
# Delete event rows of every session idle past <minutes> from the active DB in
# small batches. Keeps session/message/part/todo and event_sequence (the same
# split as the archived event expiry). Freed pages are reused without VACUUM.
# Needs no holder-idle or WAL preflight: only the schema must be supported.
# Returns 2 when the DB stayed busy (retried next cycle), 3 for an unsupported
# schema.
_archive_expire_worker_events() {
	local minutes="$1" dry_run="$2" budget="$3"
	local max_bytes totals total_rows total_bytes filter size_expr batch_sql batch_size batch_bytes start now remaining rc count total=0
	local page_size free_before free_after freed_pages=0
	((minutes > 0 && budget > 0)) || return 0
	_sqlite_has_table "$ACTIVE_DB" "$EVENT_TABLE_NAME" || return 0
	_archive_validate_active_schema || return 3
	filter=$(_archive_worker_event_filter "$minutes") || return 1
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
	max_bytes="${OPENCODE_DB_EVENT_MAX_BYTES:-$DEFAULT_EVENT_MAX_BYTES}"
	_validate_nonnegative_integer "$max_bytes" "OPENCODE_DB_EVENT_MAX_BYTES" || return 1
	totals=$(_archive_event_totals "$size_expr") || return 1
	read -r total_rows total_bytes <<<"$totals"
	if ((max_bytes > 0 && total_bytes > max_bytes)); then
		print_warning "Active-DB event payload $(format_bytes "$total_bytes") ($total_rows rows) exceeds OPENCODE_DB_EVENT_MAX_BYTES $(format_bytes "$max_bytes"); expiring least recently updated idle sessions first"
	fi
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
		if ((rc == 5)); then
			_archive_adapt_clear events
			print_warning "Event expiry deferred — active DB busy; ${total} committed, the rest resumes next cycle"
			return 2
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
		print_warning "Event expiry timed out after $(($(date +%s) - start))s; ${total} committed; next batch limit ${_ARCHIVE_ADAPT_LIMIT} row(s) / $(format_bytes "$_ARCHIVE_ADAPT_BYTES")"
	fi
	free_after=$(sqlite3 "$ACTIVE_DB" "PRAGMA freelist_count;") || free_after="$free_before"
	# Concurrent OpenCode writes may already reuse freed pages: a lower bound.
	((free_after <= free_before)) || freed_pages=$((free_after - free_before))
	print_info "Event expiry pass complete: expired $total active-DB events of inactive sessions (idle ${minutes}+ min); $(format_bytes "$((freed_pages * page_size))") freed for reuse ($freed_pages pages, lower bound); transcripts preserved"
	return 0
}
