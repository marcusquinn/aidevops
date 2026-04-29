#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# =============================================================================
# OpenCode Database Maintenance Helper
# =============================================================================
# Periodic SQLite maintenance for opencode's session database to reduce
# lock contention under concurrent session load.
#
# Problem: opencode stores session state in ~/.local/share/opencode/opencode.db
# (SQLite + WAL). Each opencode process opens 2+ connections (one per
# read-pool + writer). A single TUI with 10+ FDs is already multi-writer
# from SQLite's perspective. As the DB grows (1 GB+ is common for active
# users), write transactions exceed the compiled busy_timeout (5s) and
# fail as "database is locked" — halting the session mid-turn.
#
# Related upstream issues (anomalyco/opencode):
#   #21215 — SQLITE_BUSY on concurrent sessions (busy_timeout=0 in some paths)
#   #21000 — Bash tool hangs on massive output, locks DB
#   #20935 — Per-session-tree sharding (architectural fix, pending)
#   #21579 — Harden per-session SQLite sharding (PR, pending)
#
# This helper cannot fix the architectural problem (sharding must land
# upstream), but it can minimise lock-hold time by:
#   1. Truncating the WAL file (wal_checkpoint TRUNCATE)
#   2. Reclaiming free pages (VACUUM)
#   3. Refreshing query planner stats (PRAGMA optimize)
#   4. Right-sizing the WAL journal limit
#
# A 30-50% size reduction after VACUUM is typical for DBs that have seen
# heavy delete/prune activity. Smaller DB = faster writes = shorter locks.
#
# Subcommands:
#   check                — report readiness; does opencode.db exist, is it locked?
#   report               — human-readable DB stats (size, row counts, fragmentation)
#   maintain [--force]   — run maintenance; aborts if opencode processes active
#   auto                 — run maintenance only if safe (no active processes);
#                          used by the r913 weekly routine. Silent no-op if
#                          opencode is not installed.
#   install              — macOS only: install/refresh LaunchAgent for weekly
#                          auto-run on Sun 04:00 local (t2183). Linux install
#                          is handled by setup-modules/schedulers.sh directly.
#   uninstall            — macOS only: remove LaunchAgent. Idempotent.
#   status               — report scheduler install state (launchd on macOS,
#                          systemd/cron on Linux).
#   help                 — show this help
#
# Usage:
#   opencode-db-maintenance-helper.sh <subcommand> [options]
#
# Exit codes:
#   0   — success (or no-op on auto mode when opencode not installed)
#   1   — DB path unreadable, integrity check failed, sqlite3 missing
#   2   — opencode processes active (maintain aborted without --force)
#   10  — maintenance partially completed (some step failed, see logs)
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
	echo "ERROR: cannot resolve script dir" >&2
	exit 1
}

# Source shared constants if present; tolerate standalone execution.
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Color fallbacks (GH#18702 pattern): guard each assignment so we don't
# clobber readonlies from shared-constants.sh when sourced.
[[ -z "${RED+x}" ]] && RED=$'\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN=$'\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW=$'\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE=$'\033[0;34m'
[[ -z "${NC+x}" ]] && NC=$'\033[0m'

# -----------------------------------------------------------------------------
# Paths and defaults
# -----------------------------------------------------------------------------

readonly OPENCODE_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode"
readonly OPENCODE_DB="${OPENCODE_DATA_DIR}/opencode.db"
readonly OPENCODE_WAL="${OPENCODE_DB}-wal"
readonly OPENCODE_SHM="${OPENCODE_DB}-shm"

readonly STATE_DIR="${HOME}/.aidevops/.agent-workspace/work/opencode-maintenance"
readonly STATE_FILE="${STATE_DIR}/last-run.json"
readonly LOG_FILE="${STATE_DIR}/maintenance.log"

# Thresholds — overrideable via env for advanced users.
# VACUUM_FREELIST_THRESHOLD: only VACUUM if free pages > this fraction (default 10%)
: "${VACUUM_FREELIST_THRESHOLD:=0.10}"
# FORCE_VACUUM_SIZE_MB: always VACUUM if DB larger than this (default 500 MB)
: "${FORCE_VACUUM_SIZE_MB:=500}"
# AUTO_MIN_SECONDS_BETWEEN: skip auto run if last run was within N seconds (default 6 days)
: "${AUTO_MIN_SECONDS_BETWEEN:=518400}"

# Scheduler (macOS launchd) — used by cmd_install / cmd_uninstall / cmd_status.
# Linux systemd/cron install is handled by setup-modules/schedulers.sh
# (setup_opencode_db_maintenance → _install_scheduler_linux).
readonly LAUNCHD_LABEL="sh.aidevops.opencode-db-maintenance"
readonly LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
readonly LAUNCHD_PLIST="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist"
readonly SCHEDULER_LOG_DIR="${HOME}/.aidevops/.agent-workspace/logs"
readonly SCHEDULER_LOG_FILE="${SCHEDULER_LOG_DIR}/opencode-db-maintenance.log"

# -----------------------------------------------------------------------------
# Output helpers (fallback if shared-constants didn't provide them)
# -----------------------------------------------------------------------------

if ! declare -f print_info >/dev/null 2>&1; then
	print_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
fi
if ! declare -f print_success >/dev/null 2>&1; then
	print_success() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
fi
if ! declare -f print_warning >/dev/null 2>&1; then
	print_warning() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*"; }
fi
if ! declare -f print_error >/dev/null 2>&1; then
	print_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }
fi

# -----------------------------------------------------------------------------
# Logging to state dir (separate from terminal output)
# -----------------------------------------------------------------------------

_log() {
	local level="$1"
	shift
	local msg="$*"
	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	mkdir -p "$STATE_DIR"
	printf '%s [%s] %s\n' "$ts" "$level" "$msg" >>"$LOG_FILE"
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------

# _opencode_installed — 0 if opencode CLI and DB both present
_opencode_installed() {
	[[ -f "$OPENCODE_DB" ]] || return 1
	return 0
}

# _sqlite_available — 0 if sqlite3 is on PATH
_sqlite_available() {
	command -v sqlite3 >/dev/null 2>&1
}

# _opencode_process_count — number of running opencode processes
# Combines two signals to cover Homebrew, manual, and npm-installed builds:
#   1. pgrep against a broad regex that matches "opencode", ".opencode",
#      and path-prefixed variants like opencode-ai/bin/.opencode.
#   2. lsof against the DB file to catch any process holding it open,
#      even if argv doesn't contain the word "opencode" (e.g. via a
#      renamed binary).
# Deduplicates by PID so a process matched by both methods is counted once.
_opencode_process_count() {
	local pids=""
	# shellcheck disable=SC2009
	pids=$(pgrep -f '(^|/)\.?opencode($|[[:space:]])' 2>/dev/null || true)
	if [[ -f "$OPENCODE_DB" ]] && command -v lsof >/dev/null 2>&1; then
		local lsof_pids
		lsof_pids=$(lsof "$OPENCODE_DB" 2>/dev/null | awk 'NR>1 {print $2}' || true)
		pids=$(printf '%s\n%s\n' "$pids" "$lsof_pids")
	fi
	printf '%s\n' "$pids" | awk 'NF' | sort -u | wc -l | tr -d ' '
}

# _db_size_bytes <path> — portable file-size getter
_db_size_bytes() {
	local path="$1"
	[[ -f "$path" ]] || {
		echo 0
		return 0
	}
	_file_size_bytes "$path"
}

# _db_size_human <bytes> — portable human-readable byte formatter.
# Uses integer math with a fixed-point split so it works without bc.
_db_size_human() {
	local bytes="$1"
	if [[ "$bytes" -lt 1024 ]]; then
		echo "${bytes} B"
	elif [[ "$bytes" -lt 1048576 ]]; then
		# KB, 1 decimal: bytes*10/1024 → tenths of KB
		local tenths=$((bytes * 10 / 1024))
		printf '%d.%d KB\n' "$((tenths / 10))" "$((tenths % 10))"
	elif [[ "$bytes" -lt 1073741824 ]]; then
		# MB, 1 decimal
		local tenths=$((bytes * 10 / 1048576))
		printf '%d.%d MB\n' "$((tenths / 10))" "$((tenths % 10))"
	else
		# GB, 2 decimals
		local hundredths=$((bytes * 100 / 1073741824))
		printf '%d.%02d GB\n' "$((hundredths / 100))" "$((hundredths % 100))"
	fi
}

# _pragma <db> <name>
_pragma() {
	local db="$1"
	local name="$2"
	sqlite3 "$db" "PRAGMA ${name};" 2>/dev/null
}

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

	return "$exit_code"
}

# -----------------------------------------------------------------------------
# Subcommand: report
# -----------------------------------------------------------------------------

cmd_report() {
	if ! _opencode_installed; then
		print_info "opencode not installed — nothing to report"
		return 0
	fi
	if ! _sqlite_available; then
		print_error "sqlite3 CLI not available"
		return 1
	fi

	local db_bytes wal_bytes
	db_bytes=$(_db_size_bytes "$OPENCODE_DB")
	wal_bytes=$(_db_size_bytes "$OPENCODE_WAL")

	local page_count page_size freelist_count
	page_count=$(_pragma "$OPENCODE_DB" "page_count")
	page_size=$(_pragma "$OPENCODE_DB" "page_size")
	freelist_count=$(_pragma "$OPENCODE_DB" "freelist_count")

	local freelist_pct=0
	if [[ "$page_count" -gt 0 ]]; then
		freelist_pct=$(echo "scale=2; $freelist_count * 100 / $page_count" | bc -l 2>/dev/null || echo 0)
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
	printf '  Pages:         %s (page_size=%sB)\n' "$page_count" "$page_size"
	printf '  Free pages:    %s (%s%% of total)\n' "$freelist_count" "$freelist_pct"
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

	echo
	return 0
}

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
# Echoes "true"/"false" based on size and freelist thresholds.
_maintain_should_vacuum() {
	local before_bytes="$1"
	local freelist_count page_count size_mb
	freelist_count=$(_pragma "$OPENCODE_DB" "freelist_count")
	page_count=$(_pragma "$OPENCODE_DB" "page_count")
	size_mb=$((before_bytes / 1048576))

	if [[ "$page_count" -gt 0 ]]; then
		local pct_num pct_threshold
		# Integer math to avoid bc dependency in comparison
		pct_num=$((freelist_count * 100))
		pct_threshold=$(echo "${VACUUM_FREELIST_THRESHOLD} * 100" | awk '{printf "%d", $1}')
		if [[ $((pct_num / page_count)) -ge "$pct_threshold" ]]; then
			printf '%s %s %s %s' true "$freelist_count" "$page_count" "$size_mb"
			return 0
		fi
	fi
	if [[ "$size_mb" -ge "$FORCE_VACUUM_SIZE_MB" ]]; then
		printf '%s %s %s %s' true "$freelist_count" "$page_count" "$size_mb"
		return 0
	fi
	printf '%s %s %s %s' false "$freelist_count" "$page_count" "$size_mb"
	return 0
}

# _maintain_run_steps <before_bytes>
# Runs the three SQLite maintenance steps. Echoes "step_failures vacuum_ran".
_maintain_run_steps() {
	local before_bytes="$1"
	local step_failures=0

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
		print_info "Step 3/3: VACUUM (DB ${size_mb} MB, ${freelist_count}/${page_count} free pages)..."
		local vacuum_err
		if ! vacuum_err=$(sqlite3 "$OPENCODE_DB" "VACUUM;" 2>&1); then
			print_error "VACUUM failed: ${vacuum_err}"
			_log ERROR "VACUUM failed: ${vacuum_err}"
			step_failures=$((step_failures + 1))
		fi
	else
		print_info "Step 3/3: VACUUM skipped (low fragmentation: ${freelist_count}/${page_count} free pages, ${size_mb} MB < ${FORCE_VACUUM_SIZE_MB} MB)"
	fi

	printf '%s %s' "$step_failures" "$do_vacuum"
}

# _maintain_write_state <before_bytes> <after_bytes> <before_wal> <after_wal> <duration> <do_vacuum> <step_failures>
# Writes last-run.json and prints the summary.
_maintain_write_state() {
	local before_bytes="$1"
	local after_bytes="$2"
	local before_wal="$3"
	local after_wal="$4"
	local duration="$5"
	local do_vacuum="$6"
	local step_failures="$7"
	local reclaimed=$((before_bytes - after_bytes))
	local outcome="success"
	[[ "$step_failures" -gt 0 ]] && outcome="partial"

	mkdir -p "$STATE_DIR"
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
  "vacuum_ran": $do_vacuum,
  "step_failures": $step_failures
}
EOF

	print_success "Maintenance complete in ${duration}s"
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
	local step_failures do_vacuum
	read -r step_failures do_vacuum <<<"$steps_result"

	local end_epoch after_bytes after_wal duration
	end_epoch=$(date +%s)
	after_bytes=$(_db_size_bytes "$OPENCODE_DB")
	after_wal=$(_db_size_bytes "$OPENCODE_WAL")
	duration=$((end_epoch - start_epoch))

	_maintain_write_state "$before_bytes" "$after_bytes" "$before_wal" "$after_wal" \
		"$duration" "$do_vacuum" "$step_failures"

	if [[ "$step_failures" -gt 0 ]]; then
		return 10
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: auto
# -----------------------------------------------------------------------------
# Safe wrapper for the weekly r913 routine. Exits 0 silently when opencode
# isn't installed (other users benefit from the routine being registered
# without seeing errors).

cmd_auto() {
	# Silent no-op if opencode not installed
	if ! _opencode_installed; then
		_log INFO "auto: opencode not installed — no-op"
		return 0
	fi

	# Throttle: skip if last run was recent
	if [[ -f "$STATE_FILE" ]]; then
		local last_ts_str last_epoch now_epoch delta
		if command -v jq >/dev/null 2>&1; then
			last_ts_str=$(jq -r '.timestamp // empty' "$STATE_FILE" 2>/dev/null || true)
		else
			last_ts_str=$(grep -Eo '"timestamp":[[:space:]]*"[^"]+"' "$STATE_FILE" 2>/dev/null |
				sed 's/.*"\([^"]*\)"$/\1/' || true)
		fi
		if [[ -n "$last_ts_str" ]]; then
			# Try GNU date first, then BSD date
			last_epoch=$(date -u -d "$last_ts_str" +%s 2>/dev/null ||
				date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts_str" +%s 2>/dev/null ||
				echo 0)
			now_epoch=$(date +%s)
			delta=$((now_epoch - last_epoch))
			if [[ "$delta" -lt "$AUTO_MIN_SECONDS_BETWEEN" ]]; then
				_log INFO "auto: throttled (last run ${delta}s ago, min ${AUTO_MIN_SECONDS_BETWEEN}s)"
				print_info "Skipping: last maintenance was ${delta}s ago (threshold: ${AUTO_MIN_SECONDS_BETWEEN}s)"
				return 0
			fi
		fi
	fi

	# Delegate to maintain without --force (respects active processes).
	# Exit 2 = "opencode is running, skipping" — this is expected state for
	# a scheduled routine, not a failure. Translate to exit 0 so the
	# scheduler doesn't flag it as a failed run.
	local rc=0
	cmd_maintain --auto || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		_log INFO "auto: skipped — opencode active"
		return 0
	fi
	return "$rc"
}

# -----------------------------------------------------------------------------
# Subcommand: install / uninstall / status (macOS launchd scheduler, t2183)
# -----------------------------------------------------------------------------
# Helper owns its plist generation (Approach B, mirrors repo-sync-helper.sh).
# Linux systemd/cron install is handled by setup-modules/schedulers.sh calling
# _install_scheduler_linux — these subcommands are macOS-only; on Linux they
# print an info message and exit 0 (success, nothing to do here).

# _is_macos — 0 on Darwin
_is_macos() {
	[[ "$(uname -s)" == "Darwin" ]]
}

# _launchd_is_loaded — 0 if our LaunchAgent is listed
# SIGPIPE-safe under set -o pipefail (t1265): capture to variable first
_launchd_is_loaded() {
	local output
	output=$(launchctl list 2>/dev/null) || true
	echo "$output" | grep -qF "$LAUNCHD_LABEL"
}

# _resolve_self_path — emit the path that launchd should exec.
# Prefer the deployed copy at ~/.aidevops/agents/scripts/ so the LaunchAgent
# survives repo moves. Fall back to the running script's dir when the deployed
# copy is missing (first-install from a checkout).
_resolve_self_path() {
	local deployed="${HOME}/.aidevops/agents/scripts/opencode-db-maintenance-helper.sh"
	if [[ -f "$deployed" ]]; then
		printf '%s' "$deployed"
	else
		printf '%s' "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
	fi
}

# _generate_plist_content <self_path>
# Emit the LaunchAgent plist XML for the r913 weekly schedule.
# Uses StartCalendarInterval (not StartInterval) with Weekday=0 (Sunday),
# Hour=4, Minute=0 — matches the routine's declared "weekly(sun@04:00)".
_generate_plist_content() {
	local self_path="$1"
	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${self_path}</string>
		<string>auto</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Weekday</key>
		<integer>0</integer>
		<key>Hour</key>
		<integer>4</integer>
		<key>Minute</key>
		<integer>0</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>${SCHEDULER_LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${SCHEDULER_LOG_FILE}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${HOME}</string>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
EOF
}

cmd_install() {
	if ! _is_macos; then
		print_info "install: Linux scheduling is handled by setup-modules/schedulers.sh (systemd/cron)"
		print_info "This helper's install subcommand is macOS-only — exiting cleanly"
		return 0
	fi

	mkdir -p "$LAUNCHD_DIR" "$SCHEDULER_LOG_DIR"

	local self_path new_content
	self_path=$(_resolve_self_path)
	new_content=$(_generate_plist_content "$self_path")

	# Content-diff: skip reload if identical and already loaded (same semantics
	# as _launchd_install_if_changed in setup.sh).
	if [[ -f "$LAUNCHD_PLIST" ]] && _launchd_is_loaded; then
		local existing
		existing=$(cat "$LAUNCHD_PLIST" 2>/dev/null || echo "")
		if [[ "$existing" == "$new_content" ]]; then
			print_info "Already installed with identical config ($LAUNCHD_LABEL)"
			return 0
		fi
	fi

	# Unload before replacing plist (avoid stale config)
	if _launchd_is_loaded; then
		launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
	fi

	printf '%s\n' "$new_content" >"$LAUNCHD_PLIST"
	if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
		print_success "opencode DB maintenance scheduled (weekly, Sun 04:00 local)"
		print_info "  Label:  $LAUNCHD_LABEL"
		print_info "  Plist:  $LAUNCHD_PLIST"
		print_info "  Script: $self_path"
		print_info "  Logs:   $SCHEDULER_LOG_FILE"
		_log INFO "install: LaunchAgent loaded ($LAUNCHD_LABEL → $self_path)"
	else
		print_error "Failed to load LaunchAgent: $LAUNCHD_LABEL"
		_log ERROR "install: launchctl load failed"
		return 1
	fi
	return 0
}

cmd_uninstall() {
	if ! _is_macos; then
		print_info "uninstall: Linux scheduling is handled by setup-modules/schedulers.sh"
		return 0
	fi

	local changed=false
	if _launchd_is_loaded; then
		launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
		changed=true
	fi
	if [[ -f "$LAUNCHD_PLIST" ]]; then
		rm -f "$LAUNCHD_PLIST"
		changed=true
	fi

	if [[ "$changed" == true ]]; then
		print_success "LaunchAgent removed ($LAUNCHD_LABEL)"
		_log INFO "uninstall: LaunchAgent removed"
	else
		print_info "Not installed (nothing to remove)"
	fi
	return 0
}

cmd_status() {
	local installed=false
	if _is_macos; then
		if _launchd_is_loaded; then
			print_success "macOS LaunchAgent loaded: $LAUNCHD_LABEL"
			installed=true
		fi
		if [[ -f "$LAUNCHD_PLIST" ]]; then
			print_info "  Plist: $LAUNCHD_PLIST"
		fi
	fi

	if command -v systemctl >/dev/null 2>&1 &&
		systemctl --user is-enabled aidevops-opencode-db-maintenance.timer >/dev/null 2>&1; then
		print_success "Linux systemd timer enabled: aidevops-opencode-db-maintenance.timer"
		installed=true
	fi

	if command -v crontab >/dev/null 2>&1 &&
		crontab -l 2>/dev/null | grep -qF "aidevops: opencode-db-maintenance"; then
		print_success "Cron entry installed"
		installed=true
	fi

	if [[ "$installed" == false ]]; then
		print_info "Scheduler not installed (run: opencode-db-maintenance-helper.sh install)"
	fi

	if [[ -f "$SCHEDULER_LOG_FILE" ]]; then
		print_info "  Log:   $SCHEDULER_LOG_FILE"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

cmd_help() {
	cat <<'EOF'
opencode-db-maintenance-helper.sh — periodic SQLite maintenance for opencode

Usage:
  opencode-db-maintenance-helper.sh <subcommand> [options]

Subcommands:
  check                  Preflight: DB exists, sqlite3 available, no locks
  report                 Human-readable DB stats (size, pages, free list, PRAGMAs)
  maintain [--force]     Run maintenance. Aborts if opencode processes active
                         unless --force is passed (may cause session errors).
  auto                   Safe mode for scheduled use (r913). Silent no-op when
                         opencode not installed; throttles rapid re-runs.
  install                macOS: install/refresh LaunchAgent (weekly Sun 04:00).
                         Linux: no-op (handled by setup-modules/schedulers.sh).
  uninstall              macOS: remove LaunchAgent. Idempotent.
  status                 Report scheduler state (launchd/systemd/cron).
  help                   This help

What maintenance does:
  1. wal_checkpoint(TRUNCATE) — folds pending writes back into main DB
  2. PRAGMA optimize         — refreshes query planner stats
  3. VACUUM (conditional)    — reclaims free pages; runs when DB >500MB
                               OR free-page fraction >10%

Why it helps:
  opencode SQLite locks ("database is locked") surface when a writer holds
  the WAL beyond the compiled busy_timeout (5s). Smaller DB and shorter WAL
  = shorter lock windows = fewer session-halting errors.
  Full upstream context: anomalyco/opencode #21215, #21000, #20935.

Environment variables (advanced):
  VACUUM_FREELIST_THRESHOLD    Fraction of free pages triggering VACUUM (default 0.10)
  FORCE_VACUUM_SIZE_MB         Always VACUUM above this size (default 500)
  AUTO_MIN_SECONDS_BETWEEN     Throttle for auto mode (default 518400 = 6 days)

State:
  ~/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json
  ~/.aidevops/.agent-workspace/work/opencode-maintenance/maintenance.log

Exit codes:
  0   success (including auto no-op)
  1   DB unreadable, integrity check failed, sqlite3 missing
  2   opencode processes active (maintain without --force)
  10  partial success (some step failed)
EOF
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

main() {
	local sub="${1:-help}"
	shift || true
	case "$sub" in
	check) cmd_check "$@" ;;
	report) cmd_report "$@" ;;
	maintain | run) cmd_maintain "$@" ;;
	auto) cmd_auto "$@" ;;
	install) cmd_install "$@" ;;
	uninstall) cmd_uninstall "$@" ;;
	status) cmd_status "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown subcommand: $sub"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
