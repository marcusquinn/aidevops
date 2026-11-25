#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OpenCode DB maintenance -- Subcommand: maintain
# =============================================================================
# Split from opencode-db-maintenance-helper.sh (cmd_maintain (checkpoint, optimize, VACUUM)).
# Sourced by the helper; relies on its constants and shared helpers.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_OPENCODE_DB_MAINTENANCE_MAINTAIN_LOADED:-}" ]] && return 0
_OPENCODE_DB_MAINTENANCE_MAINTAIN_LOADED=1

# -----------------------------------------------------------------------------
# Subcommand: maintain
# -----------------------------------------------------------------------------
# Runs wal_checkpoint(TRUNCATE) → PRAGMA optimize → optional VACUUM.
# Aborts with exit 2 if opencode processes are active, unless --force.

# _maintain_preflight <force:bool> <is_auto:bool>
# Validates environment before maintenance. Returns 0 to proceed, other
# codes to exit cmd_maintain with (handled by caller).
_maintain_preflight() {
	local force="$1"
	local is_auto="$2"

	if ! _opencode_installed; then
		if [[ "$is_auto" == true ]]; then
			_log INFO "auto: opencode not installed — no-op"
			return 100
		fi
		print_info "opencode not installed — nothing to maintain"
		return 100
	fi

	if ! _sqlite_available; then
		print_error "sqlite3 CLI not available"
		return 1
	fi

	local n
	n=$(_opencode_process_count)
	if [[ "$n" -gt 0 ]]; then
		if [[ "$force" == true ]]; then
			print_warning "$n opencode process(es) active — running anyway (--force)"
			_log WARN "--force: proceeding with $n active processes"
			return 0
		fi
		print_warning "$n opencode process(es) currently active"
		print_info "Close all opencode TUIs first, or re-run with --force (may cause session errors)"
		_log INFO "refused: $n active processes (no --force)"
		return 2
	fi
	return 0
}

# _maintain_should_vacuum <before_bytes>
# Echoes "true"/"false" based only on reclaimable freelist fragmentation.
_maintain_should_vacuum() {
	local before_bytes="$1"
	local freelist_count page_count size_mb
	freelist_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_FREELIST_COUNT")
	page_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_COUNT")
	size_mb=$((before_bytes / 1048576))

	if _freelist_exceeds_threshold "$freelist_count" "$page_count"; then
		printf '%s %s %s %s' true "$freelist_count" "$page_count" "$size_mb"
		return 0
	fi
	printf '%s %s %s %s' false "$freelist_count" "$page_count" "$size_mb"
	return 0
}

# _maintain_vacuum_capacity <before_bytes>
# Emits "available_kb required_kb reason". VACUUM may need one database-sized
# temporary copy plus one database-sized WAL. Requiring 3x the DB size as free
# space reserves an additional database-sized safety margin.
_maintain_vacuum_capacity() {
	local before_bytes="$1"
	local db_kb=$(((before_bytes + 1023) / 1024))
	local required_kb=$((db_kb * VACUUM_FREE_SPACE_MULTIPLIER))
	local available_kb=0
	local reason="capacity-unknown"

	if ! declare -f aidevops_disk_capacity_snapshot >/dev/null 2>&1; then
		printf '%s %s %s' "$available_kb" "$required_kb" "$reason"
		return 2
	fi
	if ! aidevops_disk_capacity_snapshot "$OPENCODE_DB"; then
		printf '%s %s %s' "$available_kb" "$required_kb" "$reason"
		return 2
	fi
	available_kb="$AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB"
	if [[ "$available_kb" -lt "$required_kb" ]]; then
		reason="insufficient-capacity"
		printf '%s %s %s' "$available_kb" "$required_kb" "$reason"
		return 1
	fi
	printf '%s %s %s' "$available_kb" "$required_kb" "available"
	return 0
}

# _maintain_run_steps <before_bytes>
# Runs the SQLite maintenance steps. Echoes
# "step_failures vacuum_ran vacuum_deferred".
_maintain_run_steps() {
	local before_bytes="$1"
	local step_failures=0
	local vacuum_ran=false
	local vacuum_deferred=false

	# Step 1: Truncate WAL — fold pending writes back into main DB and shrink the WAL file.
	print_info "Step 1/3: wal_checkpoint(TRUNCATE)..."
	if ! sqlite3 "$OPENCODE_DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
		print_warning "wal_checkpoint failed (non-fatal)"
		_log WARN "wal_checkpoint failed"
		step_failures=$((step_failures + 1))
	fi

	# Step 2: Refresh query planner stats.
	print_info "Step 2/3: PRAGMA optimize..."
	if ! sqlite3 "$OPENCODE_DB" "PRAGMA optimize;" >/dev/null 2>&1; then
		print_warning "PRAGMA optimize failed (non-fatal)"
		_log WARN "optimize failed"
		step_failures=$((step_failures + 1))
	fi

	# Step 3: VACUUM only if needed — it rewrites the entire DB.
	local vacuum_decision
	vacuum_decision=$(_maintain_should_vacuum "$before_bytes")
	local do_vacuum freelist_count page_count size_mb
	read -r do_vacuum freelist_count page_count size_mb <<<"$vacuum_decision"

	if [[ "$do_vacuum" == true ]]; then
		local capacity_result capacity_rc=0 available_kb=0 required_kb=0 capacity_reason=""
		capacity_result=$(_maintain_vacuum_capacity "$before_bytes") || capacity_rc=$?
		read -r available_kb required_kb capacity_reason <<<"$capacity_result"
		if [[ "$capacity_rc" -ne 0 ]]; then
			vacuum_deferred=true
			print_warning "Step 3/3: VACUUM deferred (${capacity_reason}; available ${available_kb} KiB, required ${required_kb} KiB)"
			_log WARN "VACUUM deferred: reason=${capacity_reason} available_kb=${available_kb} required_kb=${required_kb}"
		else
			print_info "Step 3/3: VACUUM (DB ${size_mb} MB, ${freelist_count}/${page_count} free pages; ${available_kb} KiB available)..."
			local vacuum_err
			vacuum_ran=true
			if ! vacuum_err=$(sqlite3 "$OPENCODE_DB" "VACUUM;" 2>&1); then
				print_error "VACUUM failed: ${vacuum_err}"
				_log ERROR "VACUUM failed: ${vacuum_err}"
				step_failures=$((step_failures + 1))
			fi
		fi
	else
		print_info "Step 3/3: VACUUM skipped (low fragmentation: ${freelist_count}/${page_count} free pages, ${size_mb} MB)"
	fi

	# VACUUM itself can write a large WAL. The manual 2026-05-01 run saw
	# maintenance report success while opencode.db-wal grew to DB-size. Always
	# checkpoint again after VACUUM so success means "DB compact and WAL folded".
	if [[ "$vacuum_ran" == true ]]; then
		print_info "Final step: post-VACUUM wal_checkpoint(TRUNCATE)..."
		local final_ckpt
		if ! final_ckpt=$("$SQLITE3_BIN" "$OPENCODE_DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>&1); then
			print_warning "post-VACUUM wal_checkpoint failed (non-fatal): ${final_ckpt}"
			_log WARN "post-VACUUM wal_checkpoint failed: ${final_ckpt}"
			step_failures=$((step_failures + 1))
		elif [[ "$final_ckpt" == 1\|* ]]; then
			print_warning "post-VACUUM wal_checkpoint busy: ${final_ckpt}"
			_log WARN "post-VACUUM wal_checkpoint busy: ${final_ckpt}"
			step_failures=$((step_failures + 1))
		fi
	fi

	printf '%s %s %s' "$step_failures" "$vacuum_ran" "$vacuum_deferred"
	return 0
}

# _maintain_write_state <before_bytes> <after_bytes> <before_wal> <after_wal> <duration> <vacuum_ran> <vacuum_deferred> <step_failures>
# Writes last-run.json and prints the summary.
_maintain_write_state() {
	local before_bytes="$1"
	local after_bytes="$2"
	local before_wal="$3"
	local after_wal="$4"
	local duration="$5"
	local vacuum_ran="$6"
	local vacuum_deferred="$7"
	local step_failures="$8"
	local reclaimed=$((before_bytes - after_bytes))
	local outcome="success"
	if [[ "$step_failures" -gt 0 ]]; then
		outcome="partial"
	elif [[ "$vacuum_deferred" == true ]]; then
		outcome="deferred"
	fi

	mkdir -p "$STATE_DIR"
	# A completed maintain ends any run of holder-blocked auto skips.
	if [[ "$step_failures" -eq 0 && "$vacuum_deferred" != true ]]; then
		rm -f "$AUTO_SKIPS_FILE" 2>/dev/null || true
	fi
	cat >"$STATE_FILE" <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "outcome": "$outcome",
  "duration_sec": $duration,
  "bytes_before": $before_bytes,
  "bytes_after": $after_bytes,
  "bytes_reclaimed": $reclaimed,
  "wal_before": $before_wal,
  "wal_after": $after_wal,
  "vacuum_ran": $vacuum_ran,
  "vacuum_deferred": $vacuum_deferred,
  "step_failures": $step_failures
}
EOF

	if [[ "$outcome" == "partial" ]]; then
		print_warning "Maintenance partially completed in ${duration}s"
	elif [[ "$outcome" == "deferred" ]]; then
		print_warning "Maintenance deferred after safe preliminary steps in ${duration}s"
	else
		print_success "Maintenance complete in ${duration}s"
	fi
	print_info "DB:  $(_db_size_human "$before_bytes") → $(_db_size_human "$after_bytes") (reclaimed $(_db_size_human "$reclaimed"))"
	print_info "WAL: $(_db_size_human "$before_wal") → $(_db_size_human "$after_wal")"
	_log INFO "done: outcome=$outcome duration=${duration}s reclaimed=${reclaimed} step_failures=${step_failures}"
	return 0
}

cmd_maintain() {
	local force=false
	local is_auto=false
	local arg
	for arg in "$@"; do
		case "$arg" in
		--force) force=true ;;
		--auto) is_auto=true ;;
		esac
	done

	_maintain_preflight "$force" "$is_auto"
	local rc=$?
	# 100 = clean no-op (opencode not installed)
	[[ "$rc" -eq 100 ]] && return 0
	# Any other non-zero = error, propagate
	[[ "$rc" -ne 0 ]] && return "$rc"

	local start_epoch before_bytes before_wal
	start_epoch=$(date +%s)
	before_bytes=$(_db_size_bytes "$OPENCODE_DB")
	before_wal=$(_db_size_bytes "$OPENCODE_WAL")

	print_info "Starting maintenance (DB: $(_db_size_human "$before_bytes"), WAL: $(_db_size_human "$before_wal"))"
	_log INFO "start: db=${before_bytes} wal=${before_wal}"

	local steps_result
	steps_result=$(_maintain_run_steps "$before_bytes")
	local step_failures vacuum_ran vacuum_deferred
	read -r step_failures vacuum_ran vacuum_deferred <<<"$steps_result"

	local end_epoch after_bytes after_wal duration
	end_epoch=$(date +%s)
	after_bytes=$(_db_size_bytes "$OPENCODE_DB")
	after_wal=$(_db_size_bytes "$OPENCODE_WAL")
	duration=$((end_epoch - start_epoch))

	_maintain_write_state "$before_bytes" "$after_bytes" "$before_wal" "$after_wal" \
		"$duration" "$vacuum_ran" "$vacuum_deferred" "$step_failures"

	if [[ "$step_failures" -gt 0 ]]; then
		return 10
	fi
	return 0
}
