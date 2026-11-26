#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# opencode-db-archive-index-lib.sh - session_id -> segment index (GH#40419).
#
# opencode-archive-index.db is the only archive-side file that changes after
# sealing. Restore marks sessions restored here, never in a sealed segment;
# re-archiving into the current segment replaces the row, so the newest copy wins.

if [[ -n "${_OPENCODE_ARCHIVE_INDEX_LIB_LOADED:-}" ]]; then
	return 0
fi
_OPENCODE_ARCHIVE_INDEX_LIB_LOADED=1

# _opencode_archive_index_exec <legacy-archive-path> <sql>
_opencode_archive_index_exec() {
	local legacy="$1"
	local sql="$2"
	local index=""
	index=$(opencode_archive_index_path "$legacy")
	sqlite3 -cmd '.timeout 5000' "$index" "CREATE TABLE IF NOT EXISTS archive_index (session_id TEXT PRIMARY KEY, segment TEXT NOT NULL, restored_at INTEGER, updated_at INTEGER NOT NULL); ${sql}" || return 1
	return 0
}

# opencode_archive_index_record <legacy> <segment-path>
# Records every session currently in the segment as living there (clears restored).
opencode_archive_index_record() {
	local legacy="$1"
	local segment="$2"
	local name="${segment##*/}"
	local index="" ids=""
	[[ -f "$segment" ]] || return 1
	index=$(opencode_archive_index_path "$legacy")
	ids=$(sqlite3 -readonly "$segment" "SELECT id FROM session;") || return 1
	[[ -n "$ids" ]] || return 0
	{
		printf 'CREATE TABLE IF NOT EXISTS archive_index (session_id TEXT PRIMARY KEY, segment TEXT NOT NULL, restored_at INTEGER, updated_at INTEGER NOT NULL);\nBEGIN;\n'
		while IFS= read -r id; do
			[[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
			printf "INSERT INTO archive_index VALUES ('%s','%s',NULL,strftime('%%s','now')) ON CONFLICT(session_id) DO UPDATE SET segment=excluded.segment, restored_at=NULL, updated_at=excluded.updated_at;\n" "$id" "$name"
		done <<<"$ids"
		printf 'COMMIT;\n'
	} | sqlite3 -cmd '.timeout 5000' "$index" || return 1
	return 0
}

# opencode_archive_index_mark_restored <legacy> <session-id>
opencode_archive_index_mark_restored() {
	local legacy="$1"
	local sid="$2"
	[[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
	_opencode_archive_index_exec "$legacy" "UPDATE archive_index SET restored_at=strftime('%s','now') WHERE session_id='${sid}';" || return 1
	return 0
}

# opencode_archive_index_lookup <legacy> <session-id>
# Prints the segment filename for a session that is archived and not restored.
# Exit 1 when unknown or restored.
opencode_archive_index_lookup() {
	local legacy="$1"
	local sid="$2"
	local index="" out=""
	[[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
	index=$(opencode_archive_index_path "$legacy")
	[[ -f "$index" ]] || return 1
	out=$(sqlite3 -readonly "$index" "SELECT segment FROM archive_index WHERE session_id='${sid}' AND restored_at IS NULL;" 2>/dev/null) || return 1
	[[ -n "$out" ]] || return 1
	printf '%s\n' "$out"
	return 0
}
