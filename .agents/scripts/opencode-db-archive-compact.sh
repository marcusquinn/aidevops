#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Archive DB compaction helpers (GH#35510).
# Source only through opencode-db-archive.sh, which supplies configuration,
# SQLite helpers and output functions. No work runs on import.
# shellcheck disable=SC2154 # _oda_dir is set by the sourcing entry point

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_OPENCODE_DB_ARCHIVE_COMPACT_LOADED:-}" ]] && return 0
_OPENCODE_DB_ARCHIVE_COMPACT_LOADED=1

# --- Archive compaction (GH#40302) ---------------------------------------------

# Exact-file holders: the archive plus its -wal/-shm sidecars. Archives are not
# held open by TUIs, so this replaces the global opencode process-count gate.
_archive_file_holder_count() {
	local db="$1" total=0 count="" file=""
	for file in "$db" "${db}-wal" "${db}-shm"; do
		[[ -e "$file" ]] || continue
		count=$(_db_holder_count "$file")
		if [[ "$count" == "$OPENCODE_DB_STATE_UNKNOWN" ]]; then
			printf '%s' "$OPENCODE_DB_STATE_UNKNOWN"
			return 0
		fi
		total=$((total + count))
	done
	printf '%s' "$total"
	return 0
}

_archive_archive_checkpoint() {
	local out="" blocked=""
	out=$(sqlite3 "$ARCHIVE_DB" "$SQL_CHECKPOINT_TRUNCATE" 2>/dev/null) || return 1
	blocked="${out%%|*}"
	[[ "${blocked:-1}" == "0" ]]
	return $?
}

# Free-space guard, mirroring _maintain_vacuum_capacity (3x DB size).
_archive_compact_capacity_ok() {
	local bytes="$1" required_kb=0 lib="${_oda_dir}/disk-capacity-lib.sh"
	required_kb=$((((bytes + 1023) / 1024) * 3))
	if ! declare -f aidevops_disk_capacity_snapshot >/dev/null 2>&1 && [[ -f "$lib" ]]; then
		# shellcheck source=disk-capacity-lib.sh
		source "$lib"
	fi
	if ! declare -f aidevops_disk_capacity_snapshot >/dev/null 2>&1 || ! aidevops_disk_capacity_snapshot "$ARCHIVE_DB"; then
		print_warning "Archive VACUUM deferred — free-space state is unavailable."
		return 2
	fi
	if [[ "$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB" -lt "$required_kb" ]]; then
		print_warning "Archive VACUUM deferred — insufficient capacity (available ${AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB} KiB, required ${required_kb} KiB)."
		return 2
	fi
	return 0
}

# Checkpoint -> VACUUM -> checkpoint -> quick_check on ARCHIVE_DB when its
# freelist reaches VACUUM_FREELIST_THRESHOLD and no process holds the exact file.
# rc: 0 compacted or not needed, 1 failure, 2 deferred (holder/capacity/busy).
_archive_compact_archive_db() {
	local threshold="${VACUUM_FREELIST_THRESHOLD:-0.10}"
	local freelist="" pages="" holders="" before=0 after=0 met="" check=""
	[[ -f "$ARCHIVE_DB" ]] || return 0
	if [[ "$ARCHIVE_DB" -ef "$ACTIVE_DB" ]]; then
		print_error "Archive VACUUM refused — active and archive DB are the same file"
		return 1
	fi
	[[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] || threshold="0.10"
	freelist=$(sqlite3 -readonly "$ARCHIVE_DB" "PRAGMA freelist_count;" 2>/dev/null || true)
	pages=$(sqlite3 -readonly "$ARCHIVE_DB" "PRAGMA page_count;" 2>/dev/null || true)
	if [[ ! "$freelist" =~ ^[0-9]+$ || ! "$pages" =~ ^[0-9]+$ ]]; then
		print_warning "Archive VACUUM deferred — freelist state is unavailable for ${ARCHIVE_DB}."
		return 2
	fi
	met=$(awk -v f="$freelist" -v p="$pages" -v t="$threshold" 'BEGIN { if (p <= 0) { print 0; exit } print ((f / p) >= t) ? 1 : 0 }' </dev/null)
	if [[ "$met" != "1" ]]; then
		print_info "Archive VACUUM not needed — ${freelist}/${pages} free pages in ${ARCHIVE_DB}."
		return 0
	fi
	holders=$(_archive_file_holder_count "$ARCHIVE_DB")
	if [[ "$holders" == "$OPENCODE_DB_STATE_UNKNOWN" ]]; then
		print_warning "Archive VACUUM skipped — holder state is unavailable for ${ARCHIVE_DB}."
		return 2
	fi
	if [[ "$holders" -gt 0 ]]; then
		print_warning "Archive VACUUM skipped — ${holders} process(es) hold ${ARCHIVE_DB} open."
		return 2
	fi
	_wal_is_stable "$ARCHIVE_DB" || {
		print_warning "Archive VACUUM skipped — WAL changed during the safety observation window."
		return 2
	}
	before=$(_file_size_bytes "$ARCHIVE_DB")
	_archive_compact_capacity_ok "$before" || return 2
	print_info "Archive VACUUM: ${freelist}/${pages} free pages, $(format_bytes "$before"); pre-checkpoint..."
	_archive_archive_checkpoint || {
		print_warning "Archive VACUUM deferred — pre-VACUUM checkpoint was busy or unavailable."
		return 2
	}
	holders=$(_archive_file_holder_count "$ARCHIVE_DB")
	if [[ "$holders" == "$OPENCODE_DB_STATE_UNKNOWN" || "$holders" -gt 0 ]]; then
		print_warning "Archive VACUUM skipped — holder state changed after checkpoint."
		return 2
	fi
	if ! sqlite3 -cmd ".timeout 5000" "$ARCHIVE_DB" "VACUUM;" >/dev/null 2>&1; then
		print_warning "Archive VACUUM deferred — exclusive access was lost; will retry next cycle."
		return 2
	fi
	_archive_archive_checkpoint || {
		print_warning "Post-VACUUM archive checkpoint was busy or unavailable."
		return 2
	}
	check=$(sqlite3 "$ARCHIVE_DB" "$SQL_QUICK_CHECK" 2>/dev/null || true)
	if [[ "$check" != "ok" ]]; then
		print_error "Archive quick_check failed after VACUUM: ${ARCHIVE_DB}"
		return 1
	fi
	after=$(_file_size_bytes "$ARCHIVE_DB")
	print_info "Archive VACUUM complete: $(format_bytes "$before") -> $(format_bytes "$after"); quick_check ok."
	return 0
}
