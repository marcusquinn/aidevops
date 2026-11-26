#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OpenCode DB maintenance -- Subcommands: check and report
# =============================================================================
# Split from opencode-db-maintenance-helper.sh (cmd_check and cmd_report).
# Sourced by the helper; relies on its constants and shared helpers.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_OPENCODE_DB_MAINTENANCE_REPORT_LOADED:-}" ]] && return 0
_OPENCODE_DB_MAINTENANCE_REPORT_LOADED=1

# -----------------------------------------------------------------------------
# Subcommand: check
# -----------------------------------------------------------------------------

cmd_check() {
	local exit_code=0

	# Installation check
	if ! _opencode_installed; then
		print_info "opencode not installed (no DB at $OPENCODE_DB) — nothing to maintain"
		return 0
	fi

	# sqlite3 check
	if ! _sqlite_available; then
		print_error "sqlite3 CLI not available on PATH — cannot run maintenance"
		return 1
	fi

	# Integrity check (quick)
	local integrity
	integrity=$(sqlite3 "$OPENCODE_DB" "PRAGMA quick_check;" 2>&1 || echo "error")
	if [[ "$integrity" != "ok" ]]; then
		print_error "quick_check failed: $integrity"
		exit_code=1
	else
		print_success "DB integrity quick_check: ok"
	fi

	# Active processes
	local n
	n=$(_opencode_process_count)
	if [[ "$n" -gt 0 ]]; then
		print_warning "$n opencode process(es) currently active — maintain will refuse without --force"
	else
		print_success "no opencode processes active — maintain is safe"
	fi

	# Size reporting
	local db_bytes wal_bytes
	db_bytes=$(_db_size_bytes "$OPENCODE_DB")
	wal_bytes=$(_db_size_bytes "$OPENCODE_WAL")
	print_info "DB:  $(_db_size_human "$db_bytes") ($OPENCODE_DB)"
	print_info "WAL: $(_db_size_human "$wal_bytes") ($OPENCODE_WAL)"

	# WAL-specific warning: if WAL is large, probe checkpoint state and name blockers
	local wal_mb=$(( wal_bytes / 1048576 ))
	if [[ "$wal_mb" -ge "${WAL_LARGE_THRESHOLD_MB}" ]] && [[ -f "$OPENCODE_WAL" ]]; then
		local probe_result probe_blocked probe_log probe_ckpt
		probe_result=$(_wal_checkpoint_probe "$OPENCODE_DB")
		read -r probe_blocked probe_log probe_ckpt <<<"$probe_result"
		if [[ "$probe_blocked" == "1" ]]; then
			local unckpt=$(( probe_log - probe_ckpt ))
			print_warning "WAL large and checkpoint BUSY — ${unckpt} frame(s) still held by active readers"
			local holders
			holders=$(_wal_list_db_holders "$OPENCODE_DB")
			if [[ -n "$holders" ]]; then
				print_info "Active DB holders blocking WAL truncation (PID process):"
				while IFS=' ' read -r pid name; do
					print_info "  PID ${pid}  ${name}"
				done <<<"$holders"
			fi
			print_info "Next step: close all OpenCode sessions, then run:"
			print_info "  opencode-db-maintenance-helper.sh maintain"
		else
			print_info "WAL large but checkpoint is not blocked — run maintain to truncate"
		fi
	fi

	return "$exit_code"
}

# -----------------------------------------------------------------------------
# Subcommand: report
# -----------------------------------------------------------------------------

_report_print_compact_large_note() {
	local top_tables="$1"
	local top_table_name="" top_table_bytes="" top_table_line=""
	if [[ -n "$top_tables" ]]; then
		top_table_line=${top_tables%%$'\n'*}
		top_table_name=${top_table_line%%|*}
		top_table_bytes=${top_table_line#*|}
	fi
	printf '\n  Maintenance note: DB is compact but large; WAL and free pages are below maintenance thresholds.\n'
	if [[ -n "$top_table_name" && "$top_table_line" == *'|'* ]]; then
		printf '                    Largest object is %s (%s), which may be retained live data.\n' \
			"$top_table_name" "$(_db_size_human "$top_table_bytes")"
	fi
	printf '                    Re-running maintenance-window is unlikely to reclaim space.\n'
	return 0
}

_report_print_wal_status() {
	local wal_bytes="$1"
	local wal_mb_report=$((wal_bytes / 1048576))
	[[ "$wal_mb_report" -ge "${WAL_LARGE_THRESHOLD_MB}" ]] || return 0
	[[ -f "$OPENCODE_WAL" ]] || return 0
	local rp_result rp_blocked rp_log rp_ckpt
	rp_result=$(_wal_checkpoint_probe "$OPENCODE_DB")
	read -r rp_blocked rp_log rp_ckpt <<<"$rp_result"
	if [[ "$rp_blocked" == "1" ]]; then
		local rp_unckpt=$((rp_log - rp_ckpt))
		printf '  WAL status:    BUSY — checkpoint blocked by active readers\n'
		printf '                 (%s frames total, %s checkpointed, %s held)\n' \
			"$rp_log" "$rp_ckpt" "$rp_unckpt"
		local rp_holders
		rp_holders=$(_wal_list_db_holders "$OPENCODE_DB")
		if [[ -n "$rp_holders" ]]; then
			printf '  WAL blockers:  (PID process)\n'
			while IFS=' ' read -r pid name; do
				printf '                 PID %-8s %s\n' "$pid" "$name"
			done <<<"$rp_holders"
		fi
		printf '  Next step:     close all OpenCode sessions, then:\n'
		printf '                 opencode-db-maintenance-helper.sh maintain\n'
	else
		printf '  WAL status:    ok (checkpoint not blocked)\n'
	fi
	return 0
}

# _report_print_page_stats <pages> <page_size> <free> <free_pct> <db_bytes>
_report_print_page_stats() {
	local pages="$1" page_size="$2" free="$3" free_pct="$4" db_bytes="$5"
	printf '  Pages:         %s (page_size=%sB)\n' "$pages" "$page_size"
	printf '  Free pages:    %s (%s%% of total)\n' "$free" "$free_pct"
	_report_print_event_stats "$db_bytes"
	return 0
}

# _report_archive_bytes <legacy-archive-path>: bytes of legacy archive plus monthly segments (GH#40419).
_report_archive_bytes() {
	local legacy="$1"
	local segment="" total=0 bytes=""
	while IFS= read -r segment; do
		[[ -n "$segment" ]] || continue
		bytes=$(_db_size_bytes "$segment")
		[[ "$bytes" =~ ^[0-9]+$ ]] && total=$((total + bytes))
	done < <(opencode_archive_segments "$legacy")
	printf '%s\n' "$total"
	return 0
}

cmd_report() {
	local inventory_db
	printf '\nOpenCode DB inventory (active / WAL / archive bytes):\n'
	while IFS= read -r -d '' inventory_db; do
		printf '  %s: %s / %s / %s\n' "$inventory_db" \
			"$(_db_size_bytes "$inventory_db")" "$(_db_size_bytes "${inventory_db}-wal")" \
			"$(_report_archive_bytes "${inventory_db%/*}/opencode-archive.db")"
	done < <(opencode_db_inventory "$OPENCODE_DB")
	# Inventory is still useful when the selected/default DB does not exist.
	[[ -f "$OPENCODE_DB" ]] || return 0
	if ! _opencode_installed; then
		print_info "opencode not installed — nothing to report"
		return 0
	fi
	if ! _sqlite_available; then
		print_error "${SQLITE3_BIN} CLI not available"
		return 1
	fi

	local db_bytes wal_bytes
	db_bytes=$(_db_size_bytes "$OPENCODE_DB")
	wal_bytes=$(_db_size_bytes "$OPENCODE_WAL")

	local page_count page_size freelist_count
	page_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_COUNT")
	page_size=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_SIZE")
	freelist_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_FREELIST_COUNT")
	if [[ ! "$page_count" =~ ^[0-9]+$ || ! "$freelist_count" =~ ^[0-9]+$ || ! "$page_size" =~ ^[0-9]+$ ]]; then
		print_error "Unable to read SQLite page counts or page size from $OPENCODE_DB"; return 1
	fi

	local freelist_pct=0
	if [[ $((10#$page_count)) -ne 0 ]]; then
		freelist_pct=$(awk -v free="$freelist_count" -v pages="$page_count" 'BEGIN { if (pages <= 0) { print "0"; exit } printf "%.2f", (free * 100) / pages }' </dev/null)
	fi

	local journal_mode sync_mode busy_timeout mmap_size
	journal_mode=$(_pragma "$OPENCODE_DB" "journal_mode")
	sync_mode=$(_pragma "$OPENCODE_DB" "synchronous")
	busy_timeout=$(_pragma "$OPENCODE_DB" "busy_timeout")
	mmap_size=$(_pragma "$OPENCODE_DB" "mmap_size")

	printf '\n%b== OpenCode DB Report ==%b\n\n' "$BLUE" "$NC"
	printf '  Path:          %s\n' "$OPENCODE_DB"
	printf '  DB size:       %s\n' "$(_db_size_human "$db_bytes")"
	printf '  WAL size:      %s\n' "$(_db_size_human "$wal_bytes")"
	# WAL status: distinguish active-DB table size from WAL size; show checkpoint state
	# when WAL is large so users understand why it hasn't shrunk after archiving.
	_report_print_wal_status "$wal_bytes"
	_report_print_page_stats "$page_count" "$page_size" "$freelist_count" "$freelist_pct" "$db_bytes"
	local compact_large=false
	if [[ $((db_bytes / 1048576)) -ge "$FORCE_VACUUM_SIZE_MB" ]] && \
		[[ $((wal_bytes / 1048576)) -lt "$WAL_LARGE_THRESHOLD_MB" ]] && \
		! _freelist_exceeds_threshold "$freelist_count" "$page_count"; then
		compact_large=true
	fi
	printf '\n  PRAGMAs (fresh CLI connection — not what opencode uses):\n'
	printf '    journal_mode = %s\n' "$journal_mode"
	printf '    synchronous  = %s\n' "$sync_mode"
	printf '    busy_timeout = %s\n' "$busy_timeout"
	printf '    mmap_size    = %s\n' "$mmap_size"

	# Top tables by size if dbstat is available
	local top_tables
	top_tables=$(sqlite3 "$OPENCODE_DB" \
		"SELECT name, SUM(pgsize) FROM dbstat WHERE aggregate=TRUE GROUP BY name ORDER BY 2 DESC LIMIT 5;" 2>/dev/null || true)
	if [[ -z "$top_tables" ]]; then
		# Fallback without aggregate
		top_tables=$(sqlite3 "$OPENCODE_DB" \
			"SELECT name, SUM(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC LIMIT 5;" 2>/dev/null || true)
	fi
	if [[ -n "$top_tables" ]]; then
		printf '\n  Top 5 tables/indexes by size:\n'
		printf '%s\n' "$top_tables" | while IFS='|' read -r name bytes; do
			printf '    %-40s %s\n' "$name" "$(_db_size_human "$bytes")"
		done
	fi
	if [[ "$compact_large" == true ]]; then
		_report_print_compact_large_note "$top_tables"
	fi

	# Last run info
	if [[ -f "$STATE_FILE" ]]; then
		printf '\n  Last maintenance run:\n'
		if command -v jq >/dev/null 2>&1; then
			jq -r '. | "    timestamp:       \(.timestamp)\n    outcome:         \(.outcome)\n    duration_sec:    \(.duration_sec)\n    bytes_reclaimed: \(.bytes_reclaimed)"' "$STATE_FILE" 2>/dev/null || cat "$STATE_FILE"
		else
			cat "$STATE_FILE"
		fi
	else
		printf '\n  No previous maintenance runs recorded.\n'
	fi
	local holder_line
	if holder_line=$(_interactive_holder_advisory); then
		printf '\n  %s\n' "$holder_line"
	fi

	echo
	return 0
}
