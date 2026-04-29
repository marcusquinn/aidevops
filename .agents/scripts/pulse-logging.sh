#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-logging.sh — Pulse logging plumbing — log rotation, cycle index, and health file writer.
#
# Extracted from pulse-wrapper.sh in Phase 3 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants and mutable
# _PULSE_HEALTH_* counters in the bootstrap section.
#
# Functions in this module (in source order):
#   - rotate_pulse_log
#   - append_cycle_index
#   - write_pulse_health_file
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_LOGGING_LOADED:-}" ]] && return 0
_PULSE_LOGGING_LOADED=1

#######################################
# rotate_pulse_log — hot/cold log sharding (t1886)
#
# Called once per cycle, before any log writes. If pulse.log exceeds
# PULSE_LOG_HOT_MAX_BYTES, it is gzip-compressed and moved to the cold
# archive directory. The cold archive is then pruned to stay within
# PULSE_LOG_COLD_MAX_BYTES by removing the oldest archives first.
#
# Design constraints:
#   - Atomic: uses a tmp file + mv to avoid partial archives.
#   - Non-fatal: any failure is logged to WRAPPER_LOGFILE and silently
#     ignored so the pulse cycle is never blocked by log housekeeping.
#   - macOS compatible: uses stat -f %z (BSD stat) with fallback to wc -c.
#   - No external deps beyond gzip (standard on macOS and Linux).
#######################################
rotate_pulse_log() {
	# Ensure archive directory exists
	mkdir -p "$PULSE_LOG_ARCHIVE_DIR" 2>/dev/null || {
		echo "[pulse-wrapper] rotate_pulse_log: cannot create archive dir ${PULSE_LOG_ARCHIVE_DIR}" >>"$WRAPPER_LOGFILE"
		return 0
	}

	# Check hot log size — skip if under cap or log doesn't exist
	local hot_size=0
	if [[ -f "$LOGFILE" ]]; then
		hot_size=$(_file_size_bytes "$LOGFILE")
	fi

	if [[ "$hot_size" -lt "$PULSE_LOG_HOT_MAX_BYTES" ]]; then
		return 0
	fi

	# Rotate: compress hot log to archive
	local ts
	ts=$(date -u +%Y%m%d-%H%M%S)
	local archive_name="pulse-${ts}.log.gz"
	local archive_path="${PULSE_LOG_ARCHIVE_DIR}/${archive_name}"
	local tmp_archive
	# t2997: drop .gz — XXXXXX must be at end for BSD mktemp.
	tmp_archive=$(mktemp "${PULSE_LOG_ARCHIVE_DIR}/.pulse-archive-XXXXXX") || {
		echo "[pulse-wrapper] rotate_pulse_log: mktemp failed for archive" >>"$WRAPPER_LOGFILE"
		return 0
	}

	if gzip -c "$LOGFILE" >"$tmp_archive" 2>/dev/null; then
		mv "$tmp_archive" "$archive_path" 2>/dev/null || {
			rm -f "$tmp_archive"
			echo "[pulse-wrapper] rotate_pulse_log: mv failed for ${archive_name}" >>"$WRAPPER_LOGFILE"
			return 0
		}
		# Truncate hot log (not delete — preserves file descriptor for any
		# concurrent writers that still have it open)
		: >"$LOGFILE" 2>/dev/null || true
		echo "[pulse-wrapper] rotate_pulse_log: rotated ${hot_size}B → ${archive_name}" >>"$WRAPPER_LOGFILE"
	else
		rm -f "$tmp_archive"
		echo "[pulse-wrapper] rotate_pulse_log: gzip failed for ${LOGFILE}" >>"$WRAPPER_LOGFILE"
		return 0
	fi

	# Prune cold archive to stay within PULSE_LOG_COLD_MAX_BYTES
	# Sum archive sizes; remove oldest (lexicographic = chronological) until under cap.
	local total_cold=0
	local archive_file archive_size
	# Build sorted list (oldest first via lexicographic sort on timestamp-named files)
	local -a archive_files=()
	while IFS= read -r archive_file; do
		archive_files+=("$archive_file")
	done < <(ls -1 "${PULSE_LOG_ARCHIVE_DIR}"/pulse-*.log.gz 2>/dev/null | sort)

	for archive_file in "${archive_files[@]}"; do
		archive_size=$(_file_size_bytes "$archive_file")
		total_cold=$((total_cold + archive_size))
	done

	if [[ "$total_cold" -gt "$PULSE_LOG_COLD_MAX_BYTES" ]]; then
		for archive_file in "${archive_files[@]}"; do
			[[ "$total_cold" -le "$PULSE_LOG_COLD_MAX_BYTES" ]] && break
			archive_size=$(_file_size_bytes "$archive_file")
			rm -f "$archive_file" && {
				total_cold=$((total_cold - archive_size))
				echo "[pulse-wrapper] rotate_pulse_log: pruned cold archive $(basename "$archive_file") (${archive_size}B)" >>"$WRAPPER_LOGFILE"
			}
		done
	fi

	# GH#20025: Rotate stage timings log alongside the main log.
	# Simpler rotation: just truncate when over 1MB (one TSV line ≈ 80 bytes,
	# so 1MB ≈ 12,500 entries ≈ weeks of data). Archive the old content first.
	if [[ -n "${PULSE_STAGE_TIMINGS_LOG:-}" ]] && [[ -f "$PULSE_STAGE_TIMINGS_LOG" ]]; then
		local timings_size=0
		timings_size=$(_file_size_bytes "$PULSE_STAGE_TIMINGS_LOG")
		if [[ "$timings_size" -gt 1048576 ]]; then
			local timings_archive="${PULSE_LOG_ARCHIVE_DIR}/pulse-stage-timings-${ts}.log.gz"
			if gzip -c "$PULSE_STAGE_TIMINGS_LOG" >"$timings_archive" 2>/dev/null; then
				: >"$PULSE_STAGE_TIMINGS_LOG" 2>/dev/null || true
				echo "[pulse-wrapper] rotate_pulse_log: rotated stage-timings ${timings_size}B → $(basename "$timings_archive")" >>"$WRAPPER_LOGFILE"
			fi
		fi
	fi

	return 0
}

#######################################
# append_cycle_index — write one JSONL record to the cycle index (t1886)
#
# Called once per cycle after write_pulse_health_file(). Captures the
# per-cycle counters already computed by the health file writer plus
# timing and utilisation data. The index is append-only and capped at
# PULSE_CYCLE_INDEX_MAX_LINES lines; oldest lines are pruned in-place
# using a tmp-file swap when the cap is exceeded.
#
# Fields written per cycle:
#   ts          — ISO-8601 UTC timestamp
#   duration_s  — cycle wall-clock duration in seconds (0 if unknown)
#   workers     — "active/max" string
#   dispatched  — issues dispatched this cycle
#   merged      — PRs merged this cycle
#   closed      — conflicting PRs closed this cycle
#   killed      — stalled workers killed this cycle
#   prefetch_errors — prefetch failures this cycle
#######################################
append_cycle_index() {
	local duration_s="${1:-0}"

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local workers_active workers_max
	workers_active=$(count_active_workers 2>/dev/null || echo "0")
	[[ "$workers_active" =~ ^[0-9]+$ ]] || workers_active=0
	workers_max=$(get_max_workers_target 2>/dev/null || echo "1")
	[[ "$workers_max" =~ ^[0-9]+$ ]] || workers_max=1

	local issues_dispatched=0
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$_ledger_helper" ]]; then
		local _ledger_count
		_ledger_count=$("$_ledger_helper" count 2>/dev/null || echo "0")
		[[ "$_ledger_count" =~ ^[0-9]+$ ]] && issues_dispatched="$_ledger_count"
	fi

	# Append record — use printf for portability (no echo -e needed)
	printf '{"ts":"%s","duration_s":%s,"workers":"%s/%s","dispatched":%s,"merged":%s,"closed":%s,"killed":%s,"prefetch_errors":%s}\n' \
		"$ts" \
		"$duration_s" \
		"$workers_active" \
		"$workers_max" \
		"$issues_dispatched" \
		"$_PULSE_HEALTH_PRS_MERGED" \
		"$_PULSE_HEALTH_PRS_CLOSED_CONFLICTING" \
		"$_PULSE_HEALTH_STALLED_KILLED" \
		"$_PULSE_HEALTH_PREFETCH_ERRORS" \
		>>"$PULSE_CYCLE_INDEX_FILE" 2>/dev/null || {
		echo "[pulse-wrapper] append_cycle_index: write failed to ${PULSE_CYCLE_INDEX_FILE}" >>"$WRAPPER_LOGFILE"
		return 0
	}

	# Prune index to PULSE_CYCLE_INDEX_MAX_LINES lines when exceeded
	local line_count
	line_count=$(wc -l <"$PULSE_CYCLE_INDEX_FILE" 2>/dev/null || echo "0")
	line_count="${line_count//[[:space:]]/}"
	[[ "$line_count" =~ ^[0-9]+$ ]] || line_count=0

	if [[ "$line_count" -gt "$PULSE_CYCLE_INDEX_MAX_LINES" ]]; then
		local excess=$((line_count - PULSE_CYCLE_INDEX_MAX_LINES))
		local tmp_index
		# t2997: drop .jsonl — XXXXXX must be at end for BSD mktemp.
		tmp_index=$(mktemp "${HOME}/.aidevops/logs/.pulse-cycle-index-XXXXXX") || {
			echo "[pulse-wrapper] append_cycle_index: mktemp failed for index prune" >>"$WRAPPER_LOGFILE"
			return 0
		}
		# Keep only the last PULSE_CYCLE_INDEX_MAX_LINES lines
		tail -n "$PULSE_CYCLE_INDEX_MAX_LINES" "$PULSE_CYCLE_INDEX_FILE" >"$tmp_index" 2>/dev/null &&
			mv "$tmp_index" "$PULSE_CYCLE_INDEX_FILE" 2>/dev/null || {
			rm -f "$tmp_index"
			echo "[pulse-wrapper] append_cycle_index: prune failed (excess=${excess})" >>"$WRAPPER_LOGFILE"
		}
	fi

	return 0
}

#######################################
# Write pulse-health.json — structured status snapshot for instant diagnosis.
#
# Fields (GH#15107):
#   workers_active          — current live worker count
#   workers_max             — configured max worker slots
#   prs_merged_this_cycle   — PRs squash-merged by deterministic merge pass
#   prs_closed_conflicting  — conflicting PRs closed this cycle
#   issues_dispatched       — workers launched this cycle (from dispatch ledger)
#   prefetch_errors         — prefetch_state failures this cycle
#   stalled_workers_killed  — stalled workers killed by cleanup_stalled_workers
#   models_backed_off       — active backoff entries in provider_backoff DB
#
# Historical note (GH#18668): the deadlock_* fields were removed along with
# the flock layer they reported on. The lock is now mkdir-only and cannot
# deadlock in the way flock FD inheritance did. See reference/bash-fd-locking.md.
#
# Atomic write: write to tmp file then mv to avoid partial reads.
# Non-fatal: any failure is logged and silently ignored.
#######################################
write_pulse_health_file() {
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	# t3032: declare ledger helper once — used for both workers reconciliation
	# and issues_dispatched. The ledger is written synchronously at dispatch
	# time so it reliably reflects workers just launched, while the process
	# list (list_active_worker_processes via count_active_workers) has a brief
	# race window after nohup launch before the process appears in ps.
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	local workers_active workers_max
	workers_active=$(count_active_workers 2>/dev/null || echo "0")
	[[ "$workers_active" =~ ^[0-9]+$ ]] || workers_active=0
	workers_max=$(get_max_workers_target 2>/dev/null || echo "1")
	[[ "$workers_max" =~ ^[0-9]+$ ]] || workers_max=1

	# issues_dispatched: in-flight worker count from dispatch ledger
	local issues_dispatched=0
	if [[ -x "$_ledger_helper" ]]; then
		local _ledger_count
		_ledger_count=$("$_ledger_helper" count 2>/dev/null || echo "0")
		[[ "$_ledger_count" =~ ^[0-9]+$ ]] && issues_dispatched="$_ledger_count"
		# Reconcile workers_active with ledger count (t3032): the
		# _adaptive_launch_settle_wait is skipped when the dispatched
		# counter is 0 (C2 stdout-pollution bug), so workers just
		# dispatched via nohup may not yet appear in ps when the health
		# file is written. Use the higher of the two counts — process
		# list is more accurate for long-running workers; ledger is more
		# accurate immediately post-dispatch.
		if [[ "$_ledger_count" =~ ^[0-9]+$ ]] && [[ "$_ledger_count" -gt "$workers_active" ]]; then
			workers_active="$_ledger_count"
		fi
	fi

	# models_backed_off: count active backoff entries in provider_backoff DB
	local models_backed_off=0
	if [[ -x "$HEADLESS_RUNTIME_HELPER" ]]; then
		local _backoff_rows
		_backoff_rows=$("$HEADLESS_RUNTIME_HELPER" backoff status 2>/dev/null | grep -c '|' || echo "0")
		[[ "$_backoff_rows" =~ ^[0-9]+$ ]] && models_backed_off="$_backoff_rows"
	fi

	local tmp_health
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	tmp_health=$(mktemp "${HOME}/.aidevops/logs/.pulse-health-XXXXXX") || {
		echo "[pulse-wrapper] write_pulse_health_file: mktemp failed — skipping health write" >>"$LOGFILE"
		return 0
	}

	cat >"$tmp_health" <<EOF
{
  "timestamp": "${ts}",
  "workers_active": ${workers_active},
  "workers_max": ${workers_max},
  "prs_merged_this_cycle": ${_PULSE_HEALTH_PRS_MERGED},
  "prs_closed_conflicting": ${_PULSE_HEALTH_PRS_CLOSED_CONFLICTING},
  "issues_dispatched": ${issues_dispatched},
  "prefetch_errors": ${_PULSE_HEALTH_PREFETCH_ERRORS},
  "stalled_workers_killed": ${_PULSE_HEALTH_STALLED_KILLED},
  "models_backed_off": ${models_backed_off},
  "idle_repo_skips": ${_PULSE_HEALTH_IDLE_REPO_SKIPS:-0},
  "batch_search_calls": ${_PULSE_HEALTH_BATCH_SEARCH_CALLS:-0},
  "batch_cache_hits": ${_PULSE_HEALTH_BATCH_CACHE_HITS:-0},
  "events_tickle_fresh": ${_PULSE_HEALTH_EVENTS_TICKLE_FRESH:-0},
  "events_tickle_stale": ${_PULSE_HEALTH_EVENTS_TICKLE_STALE:-0},
  "prefetch_throttled": ${_PULSE_HEALTH_PREFETCH_THROTTLED:-0},
  "idle_cycle_skipped": ${_PULSE_HEALTH_IDLE_CYCLE_SKIPPED:-0}
}
EOF

	mv "$tmp_health" "$PULSE_HEALTH_FILE" || {
		rm -f "$tmp_health"
		echo "[pulse-wrapper] write_pulse_health_file: mv failed — skipping health write" >>"$LOGFILE"
		return 0
	}

	echo "[pulse-wrapper] pulse-health.json written: workers=${workers_active}/${workers_max} merged=${_PULSE_HEALTH_PRS_MERGED} closed_conflicting=${_PULSE_HEALTH_PRS_CLOSED_CONFLICTING} dispatched=${issues_dispatched} stalled_killed=${_PULSE_HEALTH_STALLED_KILLED} backed_off=${models_backed_off} idle_skips=${_PULSE_HEALTH_IDLE_REPO_SKIPS:-0} batch_search=${_PULSE_HEALTH_BATCH_SEARCH_CALLS:-0} batch_hits=${_PULSE_HEALTH_BATCH_CACHE_HITS:-0} tickle_fresh=${_PULSE_HEALTH_EVENTS_TICKLE_FRESH:-0} tickle_stale=${_PULSE_HEALTH_EVENTS_TICKLE_STALE:-0} prefetch_throttled=${_PULSE_HEALTH_PREFETCH_THROTTLED:-0} idle_skipped=${_PULSE_HEALTH_IDLE_CYCLE_SKIPPED:-0}" >>"$LOGFILE"
	return 0
}
