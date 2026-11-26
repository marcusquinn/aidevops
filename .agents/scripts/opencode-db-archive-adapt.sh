#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Persisted batch adaptation and payload sizing helpers (GH#35510).
# Source only through opencode-db-archive.sh, which supplies configuration,
# SQLite helpers and output functions. No work runs on import.
# shellcheck disable=SC2154 # max_duration/requested_max_duration/dry_run are the calling archive command's locals (dynamic scope)

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_OPENCODE_DB_ARCHIVE_ADAPT_LOADED:-}" ]] && return 0
_OPENCODE_DB_ARCHIVE_ADAPT_LOADED=1

# --- Persisted batch adaptation (GH#38590) -------------------------------------
# A batch killed by the per-DB deadline, SIGTERM or SIGKILL rolls back and the
# next run used to retry the identical batch forever. State lives beside the
# deferral counter (not beside the DB), keyed by a hash of the active DB path:
#   <base>.<kind>.limits    "<row limit> <byte limit>" last committed/halved size
#   <base>.<kind>.inflight  "<row limit> <byte limit> <csv ids>" written before a
#                           write; still present on the next start => no commit
#   <base>.sessions.oversized  one session ID per line, skipped by later runs
# kind is "sessions" (session move) or "events" (worker-event expiry).
readonly ARCHIVE_MIN_BATCH_BYTES=1048576
_ARCHIVE_ADAPT_LIMIT=0
_ARCHIVE_ADAPT_BYTES=0
_ARCHIVE_ADAPT_IDS=""
# Per-phase seconds for the one-line per-DB timing report.
_ARCHIVE_T_EVENT=0
_ARCHIVE_T_WORKER=0
_ARCHIVE_T_PREP=0
_ARCHIVE_T_SIZING=0
_ARCHIVE_T_WRITE=0
_ARCHIVE_OCTET_SUPPORTED=""

# Print the state file prefix for this DB; return 1 when no state dir exists.
_archive_state_base() {
	local kind="$1" dir key
	dir="${OPENCODE_DB_ARCHIVE_STATE_DIR:-}"
	if [[ -z "$dir" ]]; then
		[[ -n "${HOME:-}" ]] || return 1
		dir="${HOME}/.aidevops/logs"
	fi
	key=$(printf '%s' "$ACTIVE_DB" | cksum | awk '{print $1}')
	printf '%s/opencode-db-archive.%s.%s\n' "$dir" "$key" "$kind"
	return 0
}

# _archive_adapt_write <kind> <suffix> <content>
_archive_adapt_write() {
	local kind="$1" suffix="$2" content="$3" base
	base=$(_archive_state_base "$kind") || return 0
	mkdir -p "${base%/*}" 2>/dev/null || return 0
	printf '%s\n' "$content" >"${base}.${suffix}" 2>/dev/null || true
	return 0
}

# _archive_adapt_recover <kind> <floor_rows>
# Sets _ARCHIVE_ADAPT_LIMIT/_BYTES (0 = no persisted limit). A leftover
# in-flight marker means the previous write never committed: halve and clear it,
# and print the marker's IDs so callers can detect a still-failing 1-row batch.
_archive_adapt_recover() {
	local kind="$1" floor_rows="$2" base limit=0 bytes=0 m_limit m_bytes m_pid="" m_ids="" m_floor=0
	_ARCHIVE_ADAPT_LIMIT=0
	_ARCHIVE_ADAPT_BYTES=0
	_ARCHIVE_ADAPT_IDS=""
	base=$(_archive_state_base "$kind") || return 0
	if [[ -f "${base}.limits" ]]; then
		read -r limit bytes <"${base}.limits" || true
	fi
	[[ "$limit" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || {
		limit=0
		bytes=0
	}
	if [[ -f "${base}.inflight" ]]; then
		m_limit=0
		m_bytes=0
		read -r m_limit m_bytes m_pid m_ids <"${base}.inflight" || true
		# A marker owned by a live run is not an interruption: leave it be.
		if [[ "$m_pid" =~ ^[0-9]+$ && "$m_pid" != "$$" ]] && kill -0 "$m_pid" 2>/dev/null; then
			_ARCHIVE_ADAPT_LIMIT="$limit"
			_ARCHIVE_ADAPT_BYTES="$bytes"
			return 0
		fi
		if [[ "$m_limit" =~ ^[0-9]+$ && "$m_bytes" =~ ^[0-9]+$ ]] && ((m_limit > 0 && m_bytes > 0)); then
			# Only a batch that was already at the 1-row floor is "still interrupted".
			((m_limit > 1)) || [[ "$kind" != sessions ]] || m_floor=1
			limit=$((m_limit / 2))
			bytes=$((m_bytes / 2))
			((limit >= floor_rows)) || limit="$floor_rows"
			((bytes >= ARCHIVE_MIN_BATCH_BYTES)) || bytes="$ARCHIVE_MIN_BATCH_BYTES"
			_archive_adapt_write "$kind" limits "$limit $bytes"
			print_warning "Previous ${kind} batch never committed; halving limits to ${limit} row(s) / $(format_bytes "$bytes")."
		fi
		rm -f "${base}.inflight" 2>/dev/null || true
	fi
	_ARCHIVE_ADAPT_LIMIT="$limit"
	_ARCHIVE_ADAPT_BYTES="$bytes"
	((m_floor)) && _ARCHIVE_ADAPT_IDS="$m_ids"
	return 0
}

# _archive_adapt_mark <kind> <rows> <bytes> [csv_ids]
# The marker records this run's PID so a concurrent run never treats a live
# run's marker as an interruption.
_archive_adapt_mark() {
	local kind="$1" rows="$2" bytes="$3" ids="${4:-}"
	_archive_adapt_write "$kind" inflight "$rows $bytes $$ $ids"
	return 0
}

_archive_adapt_clear() {
	local kind="$1" base
	base=$(_archive_state_base "$kind") || return 0
	rm -f "${base}.inflight" 2>/dev/null || true
	return 0
}

# _archive_adapt_commit <kind> <rows> <bytes> <default_rows> <default_bytes>
# Clear the marker and double the limits back toward the defaults.
_archive_adapt_commit() {
	local kind="$1" rows="$2" bytes="$3" max_rows="$4" max_bytes="$5"
	_archive_adapt_clear "$kind"
	rows=$((rows * 2))
	bytes=$((bytes * 2))
	((rows <= max_rows)) || rows="$max_rows"
	((bytes <= max_bytes)) || bytes="$max_bytes"
	_archive_adapt_write "$kind" limits "$rows $bytes"
	return 0
}

# Persist halved limits after an observed timeout (no marker involved).
_archive_adapt_halve() {
	local kind="$1" rows="$2" bytes="$3" floor_rows="$4"
	rows=$((rows / 2))
	bytes=$((bytes / 2))
	((rows >= floor_rows)) || rows="$floor_rows"
	((bytes >= ARCHIVE_MIN_BATCH_BYTES)) || bytes="$ARCHIVE_MIN_BATCH_BYTES"
	_archive_adapt_clear "$kind"
	_archive_adapt_write "$kind" limits "$rows $bytes"
	_ARCHIVE_ADAPT_LIMIT="$rows"
	_ARCHIVE_ADAPT_BYTES="$bytes"
	return 0
}

# Print SQL "AND id NOT IN (...)" for sessions whose 1-session batch was
# interrupted; empty when none (or when the run has a larger budget).
_archive_oversized_exclude_clause() {
	local base sid list=""
	base=$(_archive_state_base sessions) || return 0
	[[ -f "${base}.oversized" ]] || return 0
	# An automatic catch-up raise (GH#40418) is not a requested long run: it
	# must keep the quarantine, or a session too large even for the raised
	# budget would block every catch-up pass at the queue head.
	if ((${requested_max_duration:-$max_duration} > DEFAULT_MAX_DURATION)); then
		# Manual long run: retry deferred sessions; failures are re-recorded.
		# A dry run only previews, so it must not drop the persisted list.
		((dry_run)) || rm -f "${base}.oversized" 2>/dev/null || true
		return 0
	fi
	while IFS= read -r sid; do
		[[ "$sid" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || continue
		list="${list}${list:+,}'${sid}'"
	done <"${base}.oversized"
	[[ -z "$list" ]] || printf ' AND id NOT IN (%s)\n' "$list"
	return 0
}

# _archive_oversized_record <session_id>
_archive_oversized_record() {
	local sid="$1" base
	[[ "$sid" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || return 0
	base=$(_archive_state_base sessions) || return 0
	mkdir -p "${base%/*}" 2>/dev/null || return 0
	if ! grep -qxF -- "$sid" "${base}.oversized" 2>/dev/null; then
		printf '%s\n' "$sid" >>"${base}.oversized" 2>/dev/null || true
	fi
	print_warning "Session ${sid} still interrupted a 1-session batch; deferring it as oversized. Remedy: run the archive manually with a larger --max-duration-seconds while the host is idle."
	return 0
}

# Cached probe: octet_length() (SQLite 3.43+) reads only the record header.
_archive_octet_supported() {
	if [[ -z "$_ARCHIVE_OCTET_SUPPORTED" ]]; then
		if [[ "$(sqlite3 :memory: "SELECT octet_length('ab');" 2>/dev/null)" == "2" ]]; then
			_ARCHIVE_OCTET_SUPPORTED=1
		else
			_ARCHIVE_OCTET_SUPPORTED=0
		fi
	fi
	((_ARCHIVE_OCTET_SUPPORTED))
	return $?
}

# _archive_len_expr <column> — byte length expression for a payload column.
_archive_len_expr() {
	local column="$1"
	if _archive_octet_supported; then
		printf 'octet_length(%s)\n' "$column"
	else
		printf 'LENGTH(CAST(%s AS BLOB))\n' "$column"
	fi
	return 0
}
