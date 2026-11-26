#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# opencode-db-archive-migrate-lib.sh - split a legacy archive into monthly
# segments (GH#40419 phase 3). Sourced after opencode-db-archive-seal-lib.sh.
#
# opencode_archive_migrate <legacy-archive-path> [--apply]
#   Groups sessions by UTC month of time_updated (time_created fallback) and
#   copies each session's rows into opencode-archive-YYYY-MM.db using the
#   legacy schema. Verifies quick_check and per-table row counts against the
#   source, then moves the original to a trash directory (never rm). Dry run
#   by default. Refuses when any target segment already exists. Completed
#   months are then sealed by `opencode-db-archive.sh seal`.

if [[ -n "${_OPENCODE_ARCHIVE_MIGRATE_LIB_LOADED:-}" ]]; then
	return 0
fi
_OPENCODE_ARCHIVE_MIGRATE_LIB_LOADED=1

# _opencode_archive_migrate_filter <table> <legacy-db> <month-session-subquery>
# Prints the WHERE clause that assigns a table's rows to a month, or nothing
# (return 1) when the table has no session linkage.
_opencode_archive_migrate_filter() {
	local table="$1"
	local legacy="$2"
	local subq="$3"
	local cols=""
	cols=$(sqlite3 -readonly "$legacy" "SELECT name FROM pragma_table_info('${table}');") || return 1
	case "$table" in
	session) printf 'id IN (%s)\n' "$subq" ;;
	project) printf 'id IN (SELECT project_id FROM src.session WHERE id IN (%s))\n' "$subq" ;;
	*)
		if grep -Fxq session_id <<<"$cols"; then
			printf 'session_id IN (%s)\n' "$subq"
		elif grep -Fxq aggregate_id <<<"$cols"; then
			printf 'aggregate_id IN (%s)\n' "$subq"
		else
			return 1
		fi
		;;
	esac
	return 0
}

# _opencode_archive_migrate_count <db> <table>
_opencode_archive_migrate_count() {
	local db="$1"
	local table="$2"
	sqlite3 -readonly "$db" "SELECT COUNT(*) FROM \"${table}\";" || return 1
	return 0
}

# opencode_archive_migrate <legacy-archive-path> [--apply]
opencode_archive_migrate() {
	local legacy="$1"
	local mode="${2:-}"
	local seg_n=0
	local apply=0 dir="${legacy%/*}" months month seg subq table filter src_n dst_n check
	local tables="" unassigned="" trash=""
	[[ "$mode" == "--apply" ]] && apply=1
	[[ "$dir" == "$legacy" ]] && dir="."
	[[ -f "$legacy" && ! -L "$legacy" ]] || {
		printf 'migrate: no legacy archive at %s\n' "$legacy" >&2
		return 4
	}
	months=$(sqlite3 -readonly "$legacy" "SELECT DISTINCT strftime('%Y-%m', COALESCE(time_updated, time_created)/1000, 'unixepoch') FROM session ORDER BY 1;") || return 1
	tables=$(sqlite3 -readonly "$legacy" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;") || return 1
	for month in $months; do
		[[ "$month" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || {
			printf 'migrate: invalid session time bucket %s\n' "$month" >&2
			return 1
		}
		seg=$(opencode_archive_segment_path "$legacy" "$month")
		if [[ -e "$seg" ]]; then
			printf 'migrate: target segment already exists: %s\n' "${seg##*/}" >&2
			return 1
		fi
	done
	for table in $tables; do
		[[ "$table" == session ]] && continue
		filter=$(_opencode_archive_migrate_filter "$table" "$legacy" "SELECT 1") || {
			src_n=$(_opencode_archive_migrate_count "$legacy" "$table") || return 1
			[[ "$src_n" == 0 ]] || unassigned="${unassigned} ${table}"
		}
	done
	if [[ -n "$unassigned" ]]; then
		printf 'migrate: populated tables without session linkage:%s; nothing changed\n' "$unassigned" >&2
		return 1
	fi
	if ((!apply)); then
		for month in $months; do
			printf 'would create opencode-archive-%s.db\n' "$month"
		done
		return 0
	fi
	_opencode_archive_migrate_locked "$legacy" "$months" "$tables"
	return $?
}

# _opencode_archive_migrate_missing_projects <legacy> <months>
# Prints source project ids absent from every segment (identity, not counts).
_opencode_archive_migrate_missing_projects() {
	local legacy="$1"
	local months="$2"
	local month seg have="" ids=""
	for month in $months; do
		seg=$(opencode_archive_segment_path "$legacy" "$month")
		ids=$(sqlite3 -readonly "$seg" "SELECT id FROM project;") || return 1
		have="${have}${ids}"$'\n'
	done
	comm -23 <(sqlite3 -readonly "$legacy" "SELECT id FROM project;" | LC_ALL=C sort -u) <(printf '%s' "$have" | LC_ALL=C sort -u)
	return 0
}

# _opencode_archive_migrate_locked <legacy> <months> <tables>
# Subshell holding the manifest lock (same lock as archive writes) across copy,
# verification and source move. Removes only this attempt's segments on
# failure so a retry is not blocked by partial outputs.
_opencode_archive_migrate_locked() (
	local legacy="$1"
	local months="$2"
	local tables="$3"
	local seg_n=0 month seg subq table filter src_n dst_n check missing
	local trash="" lock="" attempt=0 rc=1 f
	local -a created=()
	lock="$(opencode_archive_manifest_path "$legacy").lock"
	until mkdir "$lock" 2>/dev/null; do
		attempt=$((attempt + 1))
		if ((attempt >= 300)); then
			printf 'migrate: manifest lock busy; nothing changed\n' >&2
			return 1
		fi
		sleep 0.1
	done
	_opencode_archive_migrate_release() {
		# Delete only before the source is retired; once it has moved, the
		# segments are the only live copy and must be kept.
		if ((rc != 0)) && [[ -e "$legacy" ]]; then
			for f in ${created[@]+"${created[@]}"}; do
				rm -f "$f" "${f}-wal" "${f}-shm"
			done
		fi
		rmdir "$lock" 2>/dev/null
		return 0
	}
	trap _opencode_archive_migrate_release EXIT
	trap 'exit 1' HUP INT TERM
	# Re-check source and targets under the lock (another run may have
	# finished while we waited), before recording any output as ours.
	[[ -f "$legacy" && ! -L "$legacy" ]] || {
		printf 'migrate: no legacy archive at %s\n' "$legacy" >&2
		return 4
	}
	for month in $months; do
		seg=$(opencode_archive_segment_path "$legacy" "$month")
		if [[ -e "$seg" ]]; then
			printf 'migrate: target segment already exists: %s\n' "${seg##*/}" >&2
			return 1
		fi
	done
	for month in $months; do
		seg=$(opencode_archive_segment_path "$legacy" "$month")
		subq="SELECT id FROM src.session WHERE strftime('%Y-%m', COALESCE(time_updated, time_created)/1000, 'unixepoch') = '${month}'"
		created+=("$seg")
		sqlite3 -readonly "$legacy" ".schema" | sqlite3 "$seg" || return 1
		for table in $tables; do
			filter=$(_opencode_archive_migrate_filter "$table" "$legacy" "$subq") || continue
			sqlite3 "$seg" "ATTACH DATABASE '${legacy//\'/\'\'}' AS src; INSERT OR IGNORE INTO main.\"${table}\" SELECT * FROM src.\"${table}\" WHERE ${filter};" || return 1
		done
		check=$(sqlite3 "$seg" "PRAGMA quick_check;") || return 1
		[[ "$check" == "ok" ]] || {
			printf 'migrate: quick_check failed for %s\n' "${seg##*/}" >&2
			return 1
		}
	done
	# Row counts: every table's source rows must be present across segments
	# (project rows may repeat per segment, so check source ids are covered).
	for table in $tables; do
		src_n=$(_opencode_archive_migrate_count "$legacy" "$table") || return 1
		dst_n=0
		for month in $months; do
			seg=$(opencode_archive_segment_path "$legacy" "$month")
			seg_n=$(_opencode_archive_migrate_count "$seg" "$table") || return 1
			dst_n=$((dst_n + seg_n))
		done
		if [[ "$table" == project ]]; then
			missing=$(_opencode_archive_migrate_missing_projects "$legacy" "$months") || return 1
			[[ -z "$missing" ]] || {
				printf 'migrate: project rows missing from segments; original kept\n' >&2
				return 1
			}
		elif ((dst_n != src_n)); then
			printf 'migrate: row count mismatch for %s (%s != %s); original kept\n' "$table" "$dst_n" "$src_n" >&2
			return 1
		fi
	done
	trash="${OPENCODE_ARCHIVE_TRASH_DIR:-${HOME:-.}/.Trash}/opencode-archive-migrated-$(date -u +%Y%m%dT%H%M%SZ)"
	mkdir -p "$trash" || return 1
	mv "$legacy" "$trash/" || return 1
	[[ -f "${legacy}-wal" ]] && mv "${legacy}-wal" "$trash/"
	[[ -f "${legacy}-shm" ]] && mv "${legacy}-shm" "$trash/"
	rc=0
	printf 'migrated into %s segment(s); original moved to %s\n' "$(grep -c . <<<"$months")" "$trash"
	return 0
)
