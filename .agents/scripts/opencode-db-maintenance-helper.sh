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
#   maintenance-window    — stop pulse, drain in-flight headless workers, then
#                          archive + maintain every inventory DB (default plus
#                          isolated per-project DBs) that no process holds open,
#                          then restart pulse (explicitly disruptive)
#   auto                 — run maintenance only if safe (no active processes);
#                          used by the r913 weekly routine. Silent no-op if
#                          opencode is not installed.
#   install              — macOS only: install/refresh LaunchAgent for weekly
#                          auto-run on Sun 04:00 local (t2183). Linux install
#                          is handled by .agents/scripts/setup/modules/schedulers.sh directly.
#   uninstall            — macOS only: remove LaunchAgent. Idempotent.
#   status               — report scheduler install state (launchd on macOS,
#                          systemd/cron on Linux).
#   notice               — emit one toast-safe warning line when due/scheduled.
#   sessions             — read-only lookup for hidden/child/archived sessions.
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
# Path of this helper; sourced modules re-invoke it (BASH_SOURCE there is the module).
OPENCODE_DB_MAINTENANCE_SELF="${BASH_SOURCE[0]}"

# Source shared constants if present; tolerate standalone execution.
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Reuse the portable filesystem-capacity probe when available. Standalone
# copies without the library fail closed only when a VACUUM would run.
# shellcheck source=disk-capacity-lib.sh
if [[ -f "${SCRIPT_DIR}/disk-capacity-lib.sh" ]]; then
	source "${SCRIPT_DIR}/disk-capacity-lib.sh"
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

# shellcheck source=opencode-db-inventory-lib.sh
source "${SCRIPT_DIR}/opencode-db-inventory-lib.sh"
# shellcheck source=opencode-db-archive-segments-lib.sh
source "${SCRIPT_DIR}/opencode-db-archive-segments-lib.sh"

readonly OPENCODE_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode"
readonly OPENCODE_DB="${OPENCODE_DB_PATH:-${OPENCODE_DB:-${OPENCODE_DATA_DIR}/opencode.db}}"
readonly OPENCODE_ARCHIVE_DB="${OPENCODE_ARCHIVE_DB:-${OPENCODE_DB%/*}/opencode-archive.db}"
readonly OPENCODE_WAL="${OPENCODE_DB}-wal"
readonly OPENCODE_SHM="${OPENCODE_DB}-shm"
readonly MAINTENANCE_WINDOW_MODE="maintenance-window"
readonly SQLITE_QUICK_CHECK="PRAGMA quick_check;"
readonly PRAGMA_PAGE_COUNT="page_count"
readonly PRAGMA_FREELIST_COUNT="freelist_count"
readonly PRAGMA_PAGE_SIZE="page_size"
readonly SESSION_PARENT_ID_COLUMN="parent_id"
readonly SESSION_PROJECT_ID_COLUMN="project_id"

readonly STATE_DIR="${OPENCODE_MAINTENANCE_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/work/opencode-maintenance}"
readonly STATE_FILE="${STATE_DIR}/last-run.json"
readonly AUTO_SKIPS_FILE="${STATE_DIR}/auto-skips.json"
readonly LOG_FILE="${STATE_DIR}/maintenance.log"

# Thresholds — overrideable via env for advanced users.
# VACUUM_FREELIST_THRESHOLD: only VACUUM if free pages > this fraction (default 10%)
: "${VACUUM_FREELIST_THRESHOLD:=0.10}"
# Legacy variable name: this now controls compact-large reporting only. Size
# alone is not evidence that VACUUM can reclaim space.
: "${FORCE_VACUUM_SIZE_MB:=500}"
: "${AUTO_MIN_SECONDS_BETWEEN:=518400}"
: "${WAL_LARGE_THRESHOLD_MB:=500}"
# AUTO_SKIP_ESCALATION_COUNT: consecutive holder-blocked `auto` skips before
# notice/cleanup advise maintenance-window (default 3).
: "${AUTO_SKIP_ESCALATION_COUNT:=3}"
[[ "$AUTO_SKIP_ESCALATION_COUNT" =~ ^[0-9]+$ ]] && AUTO_SKIP_ESCALATION_COUNT=$((10#$AUTO_SKIP_ESCALATION_COUNT)) || AUTO_SKIP_ESCALATION_COUNT=3
[[ "$FORCE_VACUUM_SIZE_MB" =~ ^[0-9]+$ ]] && FORCE_VACUUM_SIZE_MB=$((10#$FORCE_VACUUM_SIZE_MB)) || FORCE_VACUUM_SIZE_MB=500
[[ "$AUTO_MIN_SECONDS_BETWEEN" =~ ^[0-9]+$ ]] && AUTO_MIN_SECONDS_BETWEEN=$((10#$AUTO_MIN_SECONDS_BETWEEN)) || AUTO_MIN_SECONDS_BETWEEN=518400
[[ "$WAL_LARGE_THRESHOLD_MB" =~ ^[0-9]+$ ]] && WAL_LARGE_THRESHOLD_MB=$((10#$WAL_LARGE_THRESHOLD_MB)) || WAL_LARGE_THRESHOLD_MB=500
: "${MAINTENANCE_WINDOW_KEEP_SESSIONS:=500}"  # maintenance-window count target
# Split age targets (GH#35492). A legacy MAINTENANCE_WINDOW_RETENTION_DAYS, when
# set, still applies one cutoff to every session.
: "${MAINTENANCE_WINDOW_WORKER_RETENTION_DAYS:=${MAINTENANCE_WINDOW_RETENTION_DAYS:-7}}"
: "${MAINTENANCE_WINDOW_INTERACTIVE_RETENTION_DAYS:=${MAINTENANCE_WINDOW_RETENTION_DAYS:-90}}"
: "${MAINTENANCE_WINDOW_DRAIN_TIMEOUT:=600}"  # max seconds to wait for headless workers
: "${MAINTENANCE_WINDOW_DRAIN_POLL:=10}"      # seconds between drain polls
# Headless workers run `opencode run ...`; interactive TUIs/servers do not.
readonly HEADLESS_WORKER_PATTERN='(^|/)\.?opencode run( |$)'
# Scheduler knobs: safe default is weekly Sun 04:00 running non-disruptive auto.
: "${OPENCODE_DB_MAINTENANCE_HOUR:=4}"
: "${OPENCODE_DB_MAINTENANCE_MINUTE:=0}"
: "${OPENCODE_DB_MAINTENANCE_MODE:=auto}"
readonly VACUUM_FREE_SPACE_MULTIPLIER=3

# Scheduler (macOS launchd) — used by cmd_install / cmd_uninstall / cmd_status.
# Linux systemd/cron install is handled by .agents/scripts/setup/modules/schedulers.sh
# (setup_opencode_db_maintenance → _install_scheduler_linux).
readonly LAUNCHD_LABEL="sh.aidevops.opencode-db-maintenance"
readonly LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
readonly LAUNCHD_PLIST="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist"
readonly SCHEDULER_LOG_DIR="${HOME}/.aidevops/.agent-workspace/logs"
readonly SCHEDULER_LOG_FILE="${SCHEDULER_LOG_DIR}/opencode-db-maintenance.log"

# Helper paths are overrideable for tests. Empty values mean "auto-detect".
if [[ -z "${PULSE_LIFECYCLE_HELPER:-}" ]]; then
	if [[ -x "${SCRIPT_DIR}/pulse-lifecycle-helper.sh" ]]; then
		PULSE_LIFECYCLE_HELPER="${SCRIPT_DIR}/pulse-lifecycle-helper.sh"
	else
		PULSE_LIFECYCLE_HELPER="pulse-lifecycle-helper.sh"
	fi
fi
: "${OPENCODE_DB_ARCHIVE_HELPER:=${SCRIPT_DIR}/opencode-db-archive.sh}"
# GH#37663: interrupt → maintain → resume for interactive TUI holders.
: "${OPENCODE_SESSION_RESTART_HELPER:=${SCRIPT_DIR}/opencode-session-restart-helper.sh}"
: "${OPENCODE_ARCHIVE_LAST_RUN_FILE:=${HOME}/.aidevops/logs/opencode-db-archive.last-run}"
# Name interactive TUI holders once archive/maintenance has not succeeded for this long (72h).
: "${INTERACTIVE_HOLDER_NOTICE_SECONDS:=259200}"
[[ "$INTERACTIVE_HOLDER_NOTICE_SECONDS" =~ ^[0-9]+$ ]] || INTERACTIVE_HOLDER_NOTICE_SECONDS=259200
: "${SQLITE3_BIN:=sqlite3}"

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
	# Inventory children target independent stores. A TUI using another project
	# must not veto every idle DB; unavailable inspection still vetoes this DB.
	if [[ "${OPENCODE_MAINTENANCE_SINGLE_DB:-0}" == 1 ]]; then
		if ! command -v lsof >/dev/null 2>&1; then
			printf '1\n'
			return 0
		fi
		local holder_rc=0
		local files=("$OPENCODE_DB")
		[[ ! -e "${OPENCODE_DB}-wal" ]] || files+=("${OPENCODE_DB}-wal")
		[[ ! -e "${OPENCODE_DB}-shm" ]] || files+=("${OPENCODE_DB}-shm")
		# Exit 1 also means no matches. Preserve diagnostics instead of treating
		# permission/inspection errors as idle; omit absent sidecars to avoid
		# generating our own missing-file errors during an ordinary idle check.
		pids=$(lsof -t "${files[@]}" 2>&1) || holder_rc=$?
		if [[ "$holder_rc" -gt 1 || ! "$pids" =~ ^[0-9[:space:]]*$ ]]; then
			printf '1\n'
			return 0
		fi
		printf '%s\n' "$pids" | awk 'NF' | sort -u | wc -l | tr -d ' '
		return 0
	fi
	# shellcheck disable=SC2009
	pids=$(pgrep -f '(^|/)\.?opencode($|[[:space:]])' 2>/dev/null || true)
	if [[ -f "$OPENCODE_DB" ]] && command -v lsof >/dev/null 2>&1; then
		local lsof_pids
		lsof_pids=$(lsof "$OPENCODE_DB" 2>/dev/null | awk 'NR>1 {print $2}' || true)
		pids=$(printf '%s\n%s\n' "$pids" "$lsof_pids")
	fi
	printf '%s\n' "$pids" | awk 'NF' | sort -u | wc -l | tr -d ' '
	return 0
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

# _state_mtime_epoch <path> — portable file mtime getter for last-run state.
_state_mtime_epoch() {
	local path="$1"
	[[ -f "$path" ]] || {
		echo 0
		return 0
	}
	if declare -f _file_mtime_epoch >/dev/null 2>&1; then
		_file_mtime_epoch "$path"
		return 0
	fi
	echo 0
	return 0
}

# _pragma <db> <name>
_pragma() {
	local db="$1"
	local name="$2"
	sqlite3 "$db" "PRAGMA ${name};" 2>/dev/null
	return 0
}

# GH#38630: the `event` table re-serialises payloads on every update and once
# grew to ~64 GB of a 72 GB DB. Ceiling for the payload shown/warned on.
readonly EVENT_MAX_BYTES_DEFAULT=2147483648
readonly DB_GROWTH_WARN_BYTES=5368709120
readonly DB_SIZE_LAST_FILE="${STATE_DIR}/last-report-db-bytes"

# _event_stats <db> — print "<rows> <payload_bytes>", or nothing when the DB has
# no event table. octet_length() (SQLite 3.43+) avoids reading overflow pages.
_event_stats() {
	local db="$1" expr="LENGTH(CAST(data AS BLOB))" out
	[[ -f "$db" ]] || return 0
	if [[ "$(sqlite3 :memory: "SELECT octet_length('ab');" 2>/dev/null)" == "2" ]]; then
		expr="octet_length(data)"
	fi
	out=$(sqlite3 -readonly -cmd '.timeout 5000' "$db" \
		"SELECT COUNT(*) || ' ' || COALESCE(SUM(${expr}), 0) FROM event;" 2>/dev/null) || return 0
	[[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] && printf '%s\n' "$out"
	return 0
}

# _event_max_bytes — validated ceiling (OPENCODE_DB_EVENT_MAX_BYTES, default 2 GiB).
_event_max_bytes() {
	local max="${OPENCODE_DB_EVENT_MAX_BYTES:-$EVENT_MAX_BYTES_DEFAULT}"
	[[ "$max" =~ ^[0-9]+$ ]] || max="$EVENT_MAX_BYTES_DEFAULT"
	printf '%s\n' "$max"
	return 0
}

# _db_growth_since_last_report <db_bytes> — print growth in bytes (0 if none or
# unknown) and record the current size when <record> is 1.
_db_growth_since_last_report() {
	local db_bytes="$1" record="${2:-0}" previous=0
	if [[ -f "$DB_SIZE_LAST_FILE" ]]; then
		previous=$(<"$DB_SIZE_LAST_FILE")
		[[ "$previous" =~ ^[0-9]+$ ]] || previous=0
	fi
	if [[ "$record" == 1 ]] && mkdir -p "$STATE_DIR" 2>/dev/null; then
		printf '%s\n' "$db_bytes" >"$DB_SIZE_LAST_FILE" 2>/dev/null || true
	fi
	if ((previous > 0 && db_bytes > previous)); then
		printf '%s\n' "$((db_bytes - previous))"
	else
		printf '0\n'
	fi
	return 0
}

# _report_print_event_stats <db_bytes> — event rows/bytes and growth lines.
_report_print_event_stats() {
	local db_bytes="$1" stats rows bytes max growth
	stats=$(_event_stats "$OPENCODE_DB")
	[[ -n "$stats" ]] || return 0
	read -r rows bytes <<<"$stats"
	max=$(_event_max_bytes)
	printf '  Event table:   %s rows, %s payload (cap %s)\n' "$rows" "$(_db_size_human "$bytes")" "$(_db_size_human "$max")"
	if ((max > 0 && bytes > max)); then
		printf '                 WARNING: above cap; run aidevops opencode-db archive (expires events of idle sessions)\n'
	fi
	growth=$(_db_growth_since_last_report "$db_bytes" 1)
	if ((growth > DB_GROWTH_WARN_BYTES)); then
		printf '  DB growth:     +%s since the previous report\n' "$(_db_size_human "$growth")"
	fi
	return 0
}

_state_json_field() {
	local field="$1"
	[[ -f "$STATE_FILE" ]] || {
		printf '%s' ""
		return 0
	}
	if command -v jq >/dev/null 2>&1; then
		jq -r --arg field "$field" '.[$field] // empty' "$STATE_FILE" 2>/dev/null || true
		return 0
	fi
	local value
	value=$(sed -n "s/^[[:space:]]*\"${field}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$STATE_FILE" 2>/dev/null | awk 'NR == 1 {print; exit}' || true)
	printf '%s' "$value"
	return 0
}

_freelist_exceeds_threshold() {
	local freelist_count="$1"
	local page_count="$2"
	[[ "$freelist_count" =~ ^[0-9]+$ && "$page_count" =~ ^[0-9]+$ && "$VACUUM_FREELIST_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
	[[ $((10#$page_count)) -eq 0 ]] && return 1
	local threshold_met
	threshold_met=$(awk -v free="$freelist_count" -v pages="$page_count" -v threshold="$VACUUM_FREELIST_THRESHOLD" 'BEGIN { if (pages <= 0) { print 0; exit } print ((free / pages) >= threshold) ? 1 : 0 }' </dev/null)
	if [[ "$threshold_met" == "1" ]]; then
		return 0
	fi
	return 1
}

# _auto_skip_count — consecutive holder-blocked auto skips (missing file = 0)
_auto_skip_count() {
	local value=""
	if [[ -f "$AUTO_SKIPS_FILE" ]]; then
		if command -v jq >/dev/null 2>&1; then
			value=$(jq -r '.consecutive // empty' "$AUTO_SKIPS_FILE" 2>/dev/null || true)
		else
			value=$(sed -n 's/^[[:space:]]*"consecutive"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$AUTO_SKIPS_FILE" 2>/dev/null | awk 'NR == 1 {print; exit}' || true)
		fi
	fi
	[[ "$value" =~ ^[0-9]+$ ]] || value=0
	printf '%s\n' "$((10#$value))"
	return 0
}

# _auto_skip_record <holders> — append one holder-blocked skip (best-effort).
# Atomic temp+mv; an unwritable STATE_DIR logs and never fails the scheduled run.
_auto_skip_record() {
	local holders="$1"
	local count page_count="" freelist_count="" page_size="" tmp
	[[ "$holders" =~ ^[0-9]+$ ]] || holders=0
	count=$(($(_auto_skip_count) + 1))
	if _sqlite_available && [[ -f "$OPENCODE_DB" ]]; then
		page_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_COUNT")
		freelist_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_FREELIST_COUNT")
		page_size=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_SIZE")
	fi
	[[ "$page_count" =~ ^[0-9]+$ ]] || page_count=0
	[[ "$freelist_count" =~ ^[0-9]+$ ]] || freelist_count=0
	[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=0
	if ! mkdir -p "$STATE_DIR" 2>/dev/null || ! tmp=$(mktemp "${STATE_DIR}/auto-skips.XXXXXX" 2>/dev/null); then
		_log WARN "auto: cannot record skip (state dir unwritable)"
		return 0
	fi
	{
		cat >"$tmp" <<EOF
{
  "consecutive": $count,
  "recorded_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "holders": $holders,
  "page_count": $page_count,
  "freelist_count": $freelist_count,
  "page_size": $page_size
}
EOF
	} 2>/dev/null &&
		mv -f "$tmp" "$AUTO_SKIPS_FILE" 2>/dev/null || {
		rm -f "$tmp" 2>/dev/null || true
		_log WARN "auto: cannot record skip (write failed)"
	}
	return 0
}

# _auto_skip_advisory — print one advisory line and return 0 when consecutive
# holder-blocked skips reached AUTO_SKIP_ESCALATION_COUNT and free pages exceed
# VACUUM_FREELIST_THRESHOLD; return 1 (silent) otherwise, including no state.
_auto_skip_advisory() {
	local skips page_count freelist_count page_size reclaim_bytes
	skips=$(_auto_skip_count)
	[[ "$skips" -ge "$AUTO_SKIP_ESCALATION_COUNT" && "$skips" -gt 0 ]] || return 1
	_sqlite_available && [[ -f "$OPENCODE_DB" ]] || return 1
	page_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_COUNT")
	freelist_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_FREELIST_COUNT")
	page_size=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_SIZE")
	[[ "$page_size" =~ ^[0-9]+$ ]] || return 1
	_freelist_exceeds_threshold "$freelist_count" "$page_count" || return 1
	reclaim_bytes=$((10#$freelist_count * 10#$page_size))
	printf '[OPENCODE MAINTENANCE] %s consecutive scheduled runs skipped (opencode running); ~%s MB reclaimable free pages in %s. Run aidevops opencode-db maintenance-window --force-opencode to reclaim.\n' \
		"$skips" "$((reclaim_bytes / 1048576))" "$OPENCODE_DB"
	return 0
}

# _last_success_epoch — newest successful maintenance or archive run (0 = none).
_last_success_epoch() {
	local maintained archived
	maintained=$(_state_mtime_epoch "$STATE_FILE")
	archived=$(tr -cd '0-9' <"$OPENCODE_ARCHIVE_LAST_RUN_FILE" 2>/dev/null || true)
	[[ "$maintained" =~ ^[0-9]+$ ]] || maintained=0
	[[ "$archived" =~ ^[0-9]+$ ]] || archived=0
	if [[ "$archived" -gt "$maintained" ]]; then printf '%s\n' "$archived"; else printf '%s\n' "$maintained"; fi
	return 0
}

# _interactive_holder_advisory — GH#37663: when archive/maintenance has not
# succeeded for INTERACTIVE_HOLDER_NOTICE_SECONDS and interactive TUIs hold the
# DB, print one line naming the oldest holder's PID, session and age.
_interactive_holder_advisory() {
	local last now holders line
	[[ -x "$OPENCODE_SESSION_RESTART_HELPER" ]] && command -v jq >/dev/null 2>&1 || return 1
	last=$(_last_success_epoch)
	now=$(date +%s)
	[[ "$last" -gt 0 && $((now - last)) -ge "$INTERACTIVE_HOLDER_NOTICE_SECONDS" ]] || return 1
	holders=$(OPENCODE_DB_PATH="$OPENCODE_DB" "$OPENCODE_SESSION_RESTART_HELPER" inventory --json 2>/dev/null || true)
	line=$(jq -r 'if (type == "array" and length > 0) then (sort_by(-.age_seconds) | .[0]) as $h
		| "\(length)\t\($h.pid)\t\($h.session_id)\t\(($h.age_seconds / 86400) | floor)" else empty end' <<<"$holders" 2>/dev/null || true)
	[[ -n "$line" ]] || return 1
	local count pid sid days
	IFS=$'\t' read -r count pid sid days <<<"$line"
	printf '[OPENCODE MAINTENANCE] Archive/maintenance deferred %sh by %s interactive TUI holder(s), oldest PID %s session %s up %sd. Run aidevops opencode-db maintenance-window --restart-interactive to checkpoint, stop and resume idle sessions.\n' \
		"$(((now - last) / 3600))" "$count" "$pid" "$sid" "$days"
	return 0
}

# _interactive_holder_notify <reason> — scheduled path: notify holders over the
# session bus (throttled by the restart helper); never stops a session.
_interactive_holder_notify() {
	local reason="$1"
	[[ -x "$OPENCODE_SESSION_RESTART_HELPER" ]] || return 0
	OPENCODE_DB_PATH="$OPENCODE_DB" "$OPENCODE_SESSION_RESTART_HELPER" notify --reason "$reason" >/dev/null 2>&1 ||
		_log WARN "interactive holder notify failed"
	return 0
}

# Subcommand: reclaimable — per-DB free-page estimate (consumed by aidevops cleanup).
cmd_reclaimable() {
	if [[ "${OPENCODE_MAINTENANCE_SINGLE_DB:-0}" != 1 ]]; then
		local db state_dir
		while IFS= read -r -d '' db; do
			state_dir="$STATE_DIR"
			if [[ ! "$db" -ef "$OPENCODE_DB" ]]; then state_dir="${db%/*}/aidevops-maintenance"; fi
			OPENCODE_DB_PATH="$db" OPENCODE_MAINTENANCE_SINGLE_DB=1 \
				OPENCODE_MAINTENANCE_STATE_DIR="$state_dir" \
				bash "${BASH_SOURCE[0]}" reclaimable || true
		done < <(opencode_db_inventory "$OPENCODE_DB")
		return 0
	fi
	_opencode_installed && _sqlite_available && [[ -f "$OPENCODE_DB" ]] || return 0
	local page_count freelist_count page_size
	page_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_COUNT")
	freelist_count=$(_pragma "$OPENCODE_DB" "$PRAGMA_FREELIST_COUNT")
	page_size=$(_pragma "$OPENCODE_DB" "$PRAGMA_PAGE_SIZE")
	[[ "$page_count" =~ ^[0-9]+$ && "$freelist_count" =~ ^[0-9]+$ && "$page_size" =~ ^[0-9]+$ ]] || return 0
	printf 'Reclaimable free pages: %s MB of %s MB in %s\n' \
		"$((10#$freelist_count * 10#$page_size / 1048576))" "$((10#$page_count * 10#$page_size / 1048576))" "$OPENCODE_DB"
	_auto_skip_advisory || true
	return 0
}

# _wal_checkpoint_probe <db>
# Runs PRAGMA wal_checkpoint(PASSIVE) and emits "blocked log checkpointed"
# as space-separated integers. PASSIVE is non-blocking — safe with live sessions.
# blocked=1 means at least one reader still holds frames in the WAL.
# On sqlite3 error or empty output, emits "0 0 0".
_wal_checkpoint_probe() {
	local db="$1"
	[[ -f "$db" ]] || { printf '%s' "0 0 0"; return 0; }
	local result
	result=$(sqlite3 "$db" "PRAGMA wal_checkpoint(PASSIVE);" 2>/dev/null || true)
	if [[ -z "$result" ]]; then
		printf '%s' "0 0 0"
		return 0
	fi
	local blocked log_pages ckpt_pages
	IFS='|' read -r blocked log_pages ckpt_pages <<<"$result"
	printf '%s %s %s' "${blocked:-0}" "${log_pages:-0}" "${ckpt_pages:-0}"
	return 0
}

# _wal_list_db_holders <db>
# Emits "PID CMDNAME" lines for processes holding <db> open (via lsof).
# Returns empty when lsof is unavailable or no holders found.
_wal_list_db_holders() {
	local db="$1"
	[[ -f "$db" ]] || return 0
	command -v lsof >/dev/null 2>&1 || return 0
	lsof "$db" 2>/dev/null | awk 'NR>1 {print $2, $1}' | sort -u || true
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand modules (split from this file; GH#40304)
# -----------------------------------------------------------------------------

# shellcheck source=./opencode-db-maintenance-sessions.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/opencode-db-maintenance-sessions.sh"
# shellcheck source=./opencode-db-maintenance-report.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/opencode-db-maintenance-report.sh"
# shellcheck source=./opencode-db-maintenance-maintain.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/opencode-db-maintenance-maintain.sh"
# shellcheck source=./opencode-db-maintenance-window.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/opencode-db-maintenance-window.sh"
# shellcheck source=./opencode-db-maintenance-scheduler.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/opencode-db-maintenance-scheduler.sh"

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
                         Includes active/WAL/archive sizes for isolated project DBs.
  maintain [--force]     Run maintenance. Aborts if opencode processes active
                         unless --force is passed (may cause session errors).
  maintenance-window     Disruptive off-hours mode: stop pulse (no new workers), wait
                         for in-flight headless workers to finish (never killed),
                         then archive + maintain + quick_check every inventory DB
                         (default and isolated project DBs), restart pulse.
                         Each DB is skipped while a process holds it open (exit 2);
                         close those OpenCode sessions or pass --force-opencode.
                         Options: --drain-timeout N (default 600, 0 = no wait),
                         --worker-retention-days N (default 7),
                         --interactive-retention-days N (default 90),
                         --retention-days N (one cutoff for both), --keep-sessions N
                         (protects interactive sessions only), --skip-archive,
                         --restart-interactive [--yes]: ask busy TUIs to checkpoint,
                         stop idle TUIs (never busy ones), maintain, then relaunch
                         `opencode -s <id>` in the original tmux/screen pane. Needs
                         terminal confirmation (or --yes); non-terminal runs only
                         notify owners unless the host allows unattended restarts
                         (opencode-session-restart-helper.sh help).
  auto                   Safe mode for scheduled use (r913). Silent no-op when
                         opencode not installed; throttles rapid re-runs.
                         Visits isolated project DBs too, skipping each live DB.
  install                macOS: install/refresh LaunchAgent (weekly Sun 04:00).
                         Linux: no-op (handled by .agents/scripts/setup/modules/schedulers.sh).
  uninstall              macOS: remove LaunchAgent. Idempotent.
  status                 Report scheduler state (launchd/systemd/cron).
  notice                 Emit one toast-safe warning when maintenance is due or disruptive mode is scheduled.
  sessions               Read-only lookup for active child, archived, and project-id-hidden sessions.
  help                   This help

What maintenance does:
  1. wal_checkpoint(TRUNCATE) — folds pending writes back into main DB
  2. PRAGMA optimize         — refreshes query planner stats
  3. VACUUM (conditional)    — reclaims free pages only when the free-page
                               fraction exceeds 10% and 3x DB size is free

Why it helps:
  opencode SQLite locks ("database is locked") surface when a writer holds
  the WAL beyond the compiled busy_timeout (5s). Smaller DB and shorter WAL
  = shorter lock windows = fewer session-halting errors.
  Full upstream context: anomalyco/opencode #21215, #21000, #20935.

Environment variables (advanced):
  VACUUM_FREELIST_THRESHOLD    Fraction of free pages triggering VACUUM (default 0.10)
  FORCE_VACUUM_SIZE_MB         Compact-large reporting threshold (default 500)
  AUTO_MIN_SECONDS_BETWEEN     Throttle for auto mode (default 518400 = 6 days)
  WAL_LARGE_THRESHOLD_MB       Warn/report large WAL above this size (default 500)
  MAINTENANCE_WINDOW_KEEP_SESSIONS  Archive keep target for maintenance-window (default 500)
  MAINTENANCE_WINDOW_WORKER_RETENTION_DAYS      Headless session age target (default 7)
  MAINTENANCE_WINDOW_INTERACTIVE_RETENTION_DAYS Interactive session age target (default 90)
  MAINTENANCE_WINDOW_RETENTION_DAYS Legacy: one age target for both when set
  MAINTENANCE_WINDOW_DRAIN_TIMEOUT  Max seconds maintenance-window waits for headless workers (default 600)
  MAINTENANCE_WINDOW_DRAIN_POLL     Seconds between worker drain polls (default 10)
  OPENCODE_DB_MAINTENANCE_HOUR Scheduled local hour for install (default 4)
  OPENCODE_DB_MAINTENANCE_MINUTE Scheduled local minute for install (default 0)
  OPENCODE_DB_MAINTENANCE_MODE  Scheduler mode: auto or maintenance-window
  OPENCODE_DB_PATH              Active DB override for sessions/maintenance
  OPENCODE_ARCHIVE_DB           Archive DB override for sessions lookup
  OPENCODE_INTERACTIVE_ROOT     Fixed-depth isolated DB inventory root (default:
                               ~/.aidevops/.agent-workspace/work/opencode-interactive)
  OPENCODE_MAINTENANCE_STATE_DIR  Override maintenance state/log directory

Session lookup examples:
  opencode-db-maintenance-helper.sh sessions --query "24396" --include-archive
  opencode-db-maintenance-helper.sh sessions --id "ses_..." --json
  opencode-db-maintenance-helper.sh sessions --directory "/path/to/repo" --limit 20

State:
  ~/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json
  ~/.aidevops/.agent-workspace/work/opencode-maintenance/maintenance.log
  Isolated inventory children keep independent state under the DB directory:
  aidevops-maintenance/{last-run.json,maintenance.log}

Exit codes:
  0   success (including auto no-op)
  1   DB unreadable, integrity check failed, sqlite3 missing
  2   opencode processes active (maintain without --force); maintenance-window:
      at least one DB skipped because it was held open
  10  partial success (some step failed)
EOF
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

# Compact archive DBs by exact-file holder evidence, independent of the global
# opencode process count (GH#40302). Never fails the caller's primary command.
_compact_archives_best_effort() {
	local rc=0
	[[ -f "$OPENCODE_DB_ARCHIVE_HELPER" ]] || return 0
	bash "$OPENCODE_DB_ARCHIVE_HELPER" compact-archives || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		_log WARN "archive compaction returned rc=${rc}"
	fi
	return 0
}

main() {
	local sub="${1:-help}"
	shift || true
	case "$sub" in
	check) cmd_check "$@" ;;
	report) cmd_report "$@" ;;
	maintain | run) cmd_maintain "$@" ;;
	"$MAINTENANCE_WINDOW_MODE" | window) cmd_maintenance_window "$@" ;;
	auto)
		local auto_rc=0
		cmd_auto "$@" || auto_rc=$?
		_compact_archives_best_effort
		return "$auto_rc"
		;;
	compact-archives) bash "$OPENCODE_DB_ARCHIVE_HELPER" compact-archives ;;
	install) cmd_install "$@" ;;
	uninstall) cmd_uninstall "$@" ;;
	status) cmd_status "$@" ;;
	notice) cmd_notice "$@" ;;
	reclaimable) cmd_reclaimable "$@" ;;
	sessions | find-session | find-sessions) cmd_sessions "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown subcommand: $sub"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
