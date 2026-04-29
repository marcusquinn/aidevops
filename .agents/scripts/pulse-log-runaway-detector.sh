#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-log-runaway-detector.sh — Detect and heal runaway pulse-wrapper.log growth.
#
# Catches the failure mode demonstrated by GH#21729: pulse-wrapper.log growing
# 6GB+ because a tight error loop bleeds the same line millions of times.
# Existing rotation (pulse-logging.sh) only covers pulse.log, not wrapper log.
# Existing watchdog (pulse-watchdog.sh) interprets fast log growth as "healthy".
#
# Three checks:
#   1. Absolute size cap — wrapper log exceeds PULSE_WRAPPER_LOG_RUNAWAY_BYTES
#   2. Growth rate — growth exceeds PULSE_WRAPPER_LOG_GROWTH_BYTES_PER_MIN
#   3. Repetition pattern — >95% of recent lines are identical
#
# Integration: called from pulse-wrapper.sh::main() with sentinel-gated cadence
# (every 5 min), modelled on the pulse-cache-prime pattern (t2994).
#
# Usage:
#   pulse-log-runaway-detector.sh check-and-heal
#   WRAPPER_LOGFILE=/path/to/log pulse-log-runaway-detector.sh check-and-heal
#
# Fail-open: any internal error returns 0. Never blocks the pulse cycle.

set -euo pipefail

# Resolve SCRIPT_DIR for sourcing siblings
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Source portable-stat.sh for _file_size_bytes (fail-open)
# shellcheck source=portable-stat.sh
if [[ -f "${SCRIPT_DIR}/portable-stat.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/portable-stat.sh"
fi

# Defaults — all overridable via env
WRAPPER_LOGFILE="${WRAPPER_LOGFILE:-${HOME}/.aidevops/logs/pulse-wrapper.log}"
PULSE_WRAPPER_LOG_RUNAWAY_BYTES="${PULSE_WRAPPER_LOG_RUNAWAY_BYTES:-524288000}"       # 500 MB
PULSE_WRAPPER_LOG_GROWTH_BYTES_PER_MIN="${PULSE_WRAPPER_LOG_GROWTH_BYTES_PER_MIN:-104857600}" # 100 MB/min
PULSE_WRAPPER_LOG_LAST_SIZE_FILE="${PULSE_WRAPPER_LOG_LAST_SIZE_FILE:-${HOME}/.aidevops/cache/pulse-wrapper-log-last-size}"
PULSE_LOG_ARCHIVE_DIR="${PULSE_LOG_ARCHIVE_DIR:-${HOME}/.aidevops/logs/pulse-archive}"
PULSE_WRAPPER_LOG_REPETITION_THRESHOLD="${PULSE_WRAPPER_LOG_REPETITION_THRESHOLD:-5}" # unique lines < this % = runaway

#######################################
# _log — emit a timestamped log line to stderr.
# Arguments:
#   $1 — message
# Returns: 0
#######################################
_log() {
	local msg="$1"
	printf '[pulse-log-runaway-detector] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")" "$msg" >&2
	return 0
}

#######################################
# _write_advisory — write a runaway advisory stamp for session greeting.
# Arguments:
#   $1 — advisory message
# Returns: 0
#######################################
_write_advisory() {
	local msg="$1"
	local advisory_dir="${HOME}/.aidevops/cache"
	local advisory_file="${advisory_dir}/pulse-wrapper-log-runaway-advisory.txt"
	mkdir -p "$advisory_dir" 2>/dev/null || return 0
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")" "$msg" >"$advisory_file" 2>/dev/null || true
	return 0
}

#######################################
# _rotate_wrapper_log — compress and truncate the wrapper log.
# Mirrors the gzip-and-truncate flow from rotate_pulse_log in pulse-logging.sh.
# Arguments: none (uses WRAPPER_LOGFILE, PULSE_LOG_ARCHIVE_DIR globals)
# Returns: 0
#######################################
_rotate_wrapper_log() {
	mkdir -p "$PULSE_LOG_ARCHIVE_DIR" 2>/dev/null || {
		_log "cannot create archive dir ${PULSE_LOG_ARCHIVE_DIR}"
		return 0
	}

	local ts=""
	ts=$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo "unknown")
	local archive_name="pulse-wrapper-${ts}.log.gz"
	local archive_path="${PULSE_LOG_ARCHIVE_DIR}/${archive_name}"
	local tmp_archive=""
	tmp_archive=$(mktemp "${PULSE_LOG_ARCHIVE_DIR}/.pulse-wrapper-archive-XXXXXX") || {
		_log "mktemp failed for archive"
		return 0
	}

	if gzip -c "$WRAPPER_LOGFILE" >"$tmp_archive" 2>/dev/null; then
		mv "$tmp_archive" "$archive_path" 2>/dev/null || {
			rm -f "$tmp_archive"
			_log "mv failed for ${archive_name}"
			return 0
		}
		# Truncate (not delete) — preserves file descriptor for launchd redirect
		: >"$WRAPPER_LOGFILE" 2>/dev/null || true
		_log "rotated wrapper log → ${archive_name}"
	else
		rm -f "$tmp_archive"
		_log "gzip failed for ${WRAPPER_LOGFILE}"
	fi

	return 0
}

#######################################
# _check_absolute_cap — rotate if wrapper log exceeds absolute size cap.
# Arguments: none (uses globals)
# Returns: 0 (always; sets _RUNAWAY_DETECTED=1 on finding)
#######################################
_check_absolute_cap() {
	local current_size=0
	if [[ -f "$WRAPPER_LOGFILE" ]]; then
		if command -v _file_size_bytes >/dev/null 2>&1; then
			current_size=$(_file_size_bytes "$WRAPPER_LOGFILE")
		else
			current_size=$(wc -c <"$WRAPPER_LOGFILE" 2>/dev/null || echo "0")
			current_size="${current_size//[[:space:]]/}"
		fi
	fi
	[[ "$current_size" =~ ^[0-9]+$ ]] || current_size=0

	if [[ "$current_size" -gt "$PULSE_WRAPPER_LOG_RUNAWAY_BYTES" ]]; then
		local size_mb=$(( current_size / 1048576 ))
		_log "RUNAWAY DETECTED: wrapper log is ${size_mb}MB (cap: $(( PULSE_WRAPPER_LOG_RUNAWAY_BYTES / 1048576 ))MB)"
		_write_advisory "Runaway wrapper log detected: ${size_mb}MB. Rotated automatically."
		_rotate_wrapper_log
		_RUNAWAY_DETECTED=1
	fi

	return 0
}

#######################################
# _check_growth_rate — rotate if wrapper log is growing too fast.
# Compares current size against last recorded size from sentinel file.
# Arguments: none (uses globals)
# Returns: 0 (always; sets _RUNAWAY_DETECTED=1 on finding)
#######################################
_check_growth_rate() {
	local current_size=0
	if [[ -f "$WRAPPER_LOGFILE" ]]; then
		if command -v _file_size_bytes >/dev/null 2>&1; then
			current_size=$(_file_size_bytes "$WRAPPER_LOGFILE")
		else
			current_size=$(wc -c <"$WRAPPER_LOGFILE" 2>/dev/null || echo "0")
			current_size="${current_size//[[:space:]]/}"
		fi
	fi
	[[ "$current_size" =~ ^[0-9]+$ ]] || current_size=0

	# Read last recorded size
	local last_size=0
	if [[ -f "$PULSE_WRAPPER_LOG_LAST_SIZE_FILE" ]]; then
		last_size=$(cat "$PULSE_WRAPPER_LOG_LAST_SIZE_FILE" 2>/dev/null || echo "0")
		last_size="${last_size//[[:space:]]/}"
	fi
	[[ "$last_size" =~ ^[0-9]+$ ]] || last_size=0

	# Calculate growth and time delta
	local growth=$(( current_size - last_size ))
	if [[ "$growth" -lt 0 ]]; then
		growth=0  # Log was truncated between checks
	fi

	# Get sentinel file age to compute rate
	local age_s=300  # default 5 min (the check cadence)
	if [[ -f "$PULSE_WRAPPER_LOG_LAST_SIZE_FILE" ]]; then
		local now_epoch="" stamp_epoch=""
		now_epoch=$(date +%s 2>/dev/null || echo "0")
		if command -v _file_mtime_epoch >/dev/null 2>&1; then
			stamp_epoch=$(_file_mtime_epoch "$PULSE_WRAPPER_LOG_LAST_SIZE_FILE")
		else
			# Fallback: use date on the file via find -printf (GNU) or perl
			stamp_epoch=$(perl -e 'print((stat($ARGV[0]))[9])' "$PULSE_WRAPPER_LOG_LAST_SIZE_FILE" 2>/dev/null || echo "0")
		fi
		[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
		[[ "$stamp_epoch" =~ ^[0-9]+$ ]] || stamp_epoch=0
		if [[ "$now_epoch" -gt "$stamp_epoch" ]] && [[ "$stamp_epoch" -gt 0 ]]; then
			age_s=$(( now_epoch - stamp_epoch ))
		fi
	fi
	# Avoid division by zero
	[[ "$age_s" -lt 1 ]] && age_s=1

	local growth_per_min=$(( growth * 60 / age_s ))

	if [[ "$growth_per_min" -gt "$PULSE_WRAPPER_LOG_GROWTH_BYTES_PER_MIN" ]] && [[ "$growth" -gt 0 ]]; then
		local rate_mb=$(( growth_per_min / 1048576 ))
		_log "RUNAWAY DETECTED: wrapper log growing at ${rate_mb}MB/min (cap: $(( PULSE_WRAPPER_LOG_GROWTH_BYTES_PER_MIN / 1048576 ))MB/min)"
		_write_advisory "Runaway wrapper log growth: ${rate_mb}MB/min. Rotated automatically."
		_rotate_wrapper_log
		_RUNAWAY_DETECTED=1
	fi

	# Update sentinel with current size
	mkdir -p "$(dirname "$PULSE_WRAPPER_LOG_LAST_SIZE_FILE")" 2>/dev/null || true
	printf '%s' "$current_size" >"$PULSE_WRAPPER_LOG_LAST_SIZE_FILE" 2>/dev/null || true

	return 0
}

#######################################
# _check_repetition_pattern — detect if >95% of recent lines are identical.
# Arguments: none (uses globals)
# Returns: 0 (always; sets _RUNAWAY_DETECTED=1 on finding)
#######################################
_check_repetition_pattern() {
	[[ -f "$WRAPPER_LOGFILE" ]] || return 0

	# Only check files > 100KB (small files can't be meaningfully analysed)
	local current_size=0
	if command -v _file_size_bytes >/dev/null 2>&1; then
		current_size=$(_file_size_bytes "$WRAPPER_LOGFILE")
	else
		current_size=$(wc -c <"$WRAPPER_LOGFILE" 2>/dev/null || echo "0")
		current_size="${current_size//[[:space:]]/}"
	fi
	[[ "$current_size" =~ ^[0-9]+$ ]] || current_size=0
	[[ "$current_size" -lt 102400 ]] && return 0

	local total_lines=0 unique_lines=0
	total_lines=1000  # We sample 1000 lines
	unique_lines=$(tail -n 1000 "$WRAPPER_LOGFILE" 2>/dev/null | sort -u | wc -l 2>/dev/null || echo "0")
	unique_lines="${unique_lines//[[:space:]]/}"
	[[ "$unique_lines" =~ ^[0-9]+$ ]] || unique_lines=0

	# Calculate unique percentage: (unique / total) * 100
	if [[ "$unique_lines" -gt 0 ]]; then
		local unique_pct=$(( unique_lines * 100 / total_lines ))
		if [[ "$unique_pct" -lt "$PULSE_WRAPPER_LOG_REPETITION_THRESHOLD" ]]; then
			# Extract the dominant repeated line for triage
			local dominant_line=""
			dominant_line=$(tail -n 1000 "$WRAPPER_LOGFILE" 2>/dev/null | sort | uniq -c | sort -rn | head -1 | sed 's/^[[:space:]]*[0-9]* //' 2>/dev/null || echo "unknown")
			_log "RUNAWAY DETECTED: ${unique_pct}% unique lines in last 1000 (threshold: ${PULSE_WRAPPER_LOG_REPETITION_THRESHOLD}%). Dominant line: ${dominant_line:0:200}"
			_write_advisory "Runaway repetition detected: ${unique_pct}% unique lines. Dominant: ${dominant_line:0:200}"
			_RUNAWAY_DETECTED=1
		fi
	fi

	return 0
}

#######################################
# check_and_heal — run all three checks. Fail-open.
# Arguments: none
# Returns: 0
#######################################
check_and_heal() {
	_RUNAWAY_DETECTED=0

	_check_absolute_cap || true
	# Skip further checks if we already rotated
	if [[ "$_RUNAWAY_DETECTED" == "0" ]]; then
		_check_growth_rate || true
	fi
	if [[ "$_RUNAWAY_DETECTED" == "0" ]]; then
		_check_repetition_pattern || true
	fi

	if [[ "$_RUNAWAY_DETECTED" == "1" ]]; then
		_log "Self-healing complete. Advisory written."
	fi

	return 0
}

# CLI entry point
case "${1:-}" in
	check-and-heal)
		check_and_heal
		;;
	"")
		check_and_heal
		;;
	*)
		printf 'Usage: %s check-and-heal\n' "$(basename "$0")" >&2
		exit 1
		;;
esac
