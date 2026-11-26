#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# opencode-db-archive.sh — Archive old OpenCode sessions to reduce active DB
# size and write contention for concurrent headless workers.
#
# The active opencode.db grows large over time (millions of part rows). With
# WAL mode and busy_timeout=0, concurrent writers hit SQLITE_BUSY. Archiving
# old sessions to a separate file reduces the active DB size.
#
# Usage:
#   opencode-db-archive.sh archive [--worker-retention-days N] [--interactive-retention-days N]
#                                  [--retention-days N] [--keep-sessions N] [--dry-run] [--max-duration-seconds N]
#                                  [--worker-event-expiry-minutes N] [--worker-events-only]
#   opencode-db-archive.sh restore --session ID [--dry-run]
#   opencode-db-archive.sh prune --older-than-days N [--dry-run|--apply] [--max-duration-seconds N]
#   opencode-db-archive.sh prune-all --older-than-days N [--dry-run|--apply]
#   opencode-db-archive.sh retention-days
#   opencode-db-archive.sh stats
#   opencode-db-archive.sh help
#
# Environment:
#   OPENCODE_DB_PATH     — active DB path override used by aidevops/OpenCode helpers
#   OPENCODE_DB          — active DB path override (fallback)
#   XDG_DATA_HOME        — default data root (default: ~/.local/share)
#   OPENCODE_ARCHIVE_DB  — archive DB path (default: next to active opencode.db)
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# Source shared-constants.sh for portable stat functions
_oda_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=shared-constants.sh
[[ -f "${_oda_dir}/shared-constants.sh" ]] && source "${_oda_dir}/shared-constants.sh"
# shellcheck source=opencode-db-safety-lib.sh
if [[ -f "${_oda_dir}/opencode-db-safety-lib.sh" ]]; then
	source "${_oda_dir}/opencode-db-safety-lib.sh"
else
	printf 'opencode-db-archive: missing safety library\n' >&2
	exit 1
fi

# --- Configuration -----------------------------------------------------------

# shellcheck source=opencode-db-inventory-lib.sh
source "${_oda_dir}/opencode-db-inventory-lib.sh"
# shellcheck source=opencode-db-idle-gate-lib.sh
source "${_oda_dir}/opencode-db-idle-gate-lib.sh"

readonly SCRIPT_NAME="opencode-db-archive"
if [[ -n "${XDG_DATA_HOME:-}" ]]; then
	readonly DEFAULT_DATA_DIR="${XDG_DATA_HOME}/opencode"
elif [[ -n "${HOME:-}" ]]; then
	readonly DEFAULT_DATA_DIR="${HOME}/.local/share/opencode"
else
	readonly DEFAULT_DATA_DIR="opencode"
fi
readonly DEFAULT_DB="${DEFAULT_DATA_DIR}/opencode.db"
# Split retention (GH#35492): headless worker sessions are bulky and rarely
# reopened, so they leave the active DB after 7 days; interactive sessions stay
# visible in the OpenCode session list for 30 days (GH#38431; was 90). Archived
# history remains queryable and is restored automatically when a worker resumes
# its session or an interactive session is resumed through
# opencode-session-restart-helper.sh (resume / open).
readonly DEFAULT_WORKER_RETENTION_DAYS=7
readonly DEFAULT_INTERACTIVE_RETENTION_DAYS=30
readonly DEFAULT_BATCH_SIZE=500
# Held mode (GH#35517): small batches keep each write lock brief while idle
# OpenCode processes hold the DB open.
readonly DEFAULT_HELD_BATCH_SIZE=10
readonly DEFAULT_MAX_DURATION=60
readonly EVENT_TABLE_NAME="event"
readonly SESSION_TABLE_NAME="session"
readonly ARCHIVE_TEXT_COLUMN_DEFINITION="text"
readonly ARCHIVE_INTEGER_COLUMN_DEFINITION="integer DEFAULT 0 NOT NULL"
readonly SQL_CHECKPOINT_TRUNCATE="PRAGMA wal_checkpoint(TRUNCATE);"
readonly SQL_QUICK_CHECK="PRAGMA quick_check;"

ARCHIVE_BATCH_SIZE="${OPENCODE_DB_ARCHIVE_BATCH_SIZE:-$DEFAULT_BATCH_SIZE}"
ARCHIVE_BATCH_DELAY_SECONDS="${OPENCODE_DB_ARCHIVE_BATCH_DELAY_SECONDS:-0}"
ARCHIVE_HELD_BATCH_SIZE="${OPENCODE_DB_ARCHIVE_HELD_BATCH_SIZE:-$DEFAULT_HELD_BATCH_SIZE}"
# Set by _archive_enter_held_mode when idle OpenCode processes hold the DB.
_ARCHIVE_HELD_MODE=0
_ARCHIVE_HELD_SESSIONS=""
DB_HOLDER_COMMAND="${OPENCODE_DB_HOLDER_COMMAND:-lsof}"
WAL_STABILITY_DELAY_SECONDS="${OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS:-1}"

ACTIVE_DB="${OPENCODE_DB_PATH:-${OPENCODE_DB:-$DEFAULT_DB}}"
_archive_default_dir="${ACTIVE_DB%/*}"
if [[ "$_archive_default_dir" == "$ACTIVE_DB" ]]; then
	_archive_default_dir="."
fi
ARCHIVE_DB="${OPENCODE_ARCHIVE_DB:-${_archive_default_dir}/opencode-archive.db}"
unset _archive_default_dir

# Headless runtime ledger: worker_sessions records every merged worker session
# (including subagent children); provider_sessions holds resumable worker IDs.
_archive_ledger_default=""
if [[ -n "${AIDEVOPS_HEADLESS_RUNTIME_DIR:-}" ]]; then
	_archive_ledger_default="${AIDEVOPS_HEADLESS_RUNTIME_DIR}/state.db"
elif [[ -n "${HOME:-}" ]]; then
	_archive_ledger_default="${HOME}/.aidevops/.agent-workspace/headless-runtime/state.db"
fi
HEADLESS_LEDGER_DB="${OPENCODE_DB_HEADLESS_LEDGER:-$_archive_ledger_default}"
unset _archive_ledger_default
# Set by _archive_prepare_headless_ledger: 1 when queries must ATTACH the ledger.
_ARCHIVE_LEDGER_ATTACH=0

# --- Output helpers -----------------------------------------------------------

print_info() {
	local msg="$1"
	echo -e "\033[0;34m[INFO]\033[0m $msg"
	return 0
}

print_success() {
	local msg="$1"
	echo -e "\033[0;32m[OK]\033[0m $msg"
	return 0
}

print_warning() {
	local msg="$1"
	echo -e "\033[1;33m[WARN]\033[0m $msg"
	return 0
}

print_error() {
	local msg="$1"
	echo -e "\033[0;31m[ERROR]\033[0m $msg" >&2
	return 0
}

# --- Utility ------------------------------------------------------------------

check_sqlite3() {
	if ! command -v sqlite3 &>/dev/null; then
		print_error "sqlite3 not found. Install it first."
		return 1
	fi
	return 0
}

check_active_db() {
	if [[ ! -f "$ACTIVE_DB" ]]; then
		print_error "Active DB not found: $ACTIVE_DB"
		return 1
	fi
	return 0
}

# Get the current epoch in milliseconds
now_ms() {
	local ms
	# Try GNU date first (Linux/coreutils); macOS date does not support %3N
	ms=$(date +%s%3N 2>/dev/null)
	if [[ "$ms" =~ ^[0-9]{13,}$ ]]; then
		echo "$ms"
		return 0
	fi
	# Fall back to python3 or perl for sub-second precision on macOS
	python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null ||
		perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null ||
		echo "$(($(date +%s) * 1000))"
	return 0
}

# Get session IDs that have an active worker (pulse log <1h old): sorted
# unique UUIDs from per-user pulse worker logs modified within the last hour.
# t19400 / GH#40443: one find plus batched grep. A per-file mtime subshell
# forked ~1,450 times over the 48 h log retention (720+ logs) on every call,
# and under the launchd job's background QoS that scan alone outlasted the
# 60 s per-DB archive deadline, so no DB made progress.
get_active_worker_sessions() {
	local pulse_tmp_root=""
	pulse_tmp_root=$(aidevops_pulse_tmp_root 2>/dev/null || true)
	[[ -n "$pulse_tmp_root" && -d "$pulse_tmp_root" ]] || return 0
	# BSD find rounds the age up to whole minutes, so -61 keeps every log the
	# old `mtime > now - 3600` check kept (GNU: at most one minute more, the
	# protective direction). grep exits 1 when a batch has no UUID; not an error.
	# -H follows a symlinked root (AIDEVOPS_PULSE_TMP_DIR) as the old glob did;
	# without it find never enters the root and protects no session.
	find -H "$pulse_tmp_root" -maxdepth 1 -type f -name 'pulse-*.log' -mmin -61 \
		-exec grep -ohE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' {} + 2>/dev/null |
		sort -u || true
	return 0
}

# Format bytes to human-readable
format_bytes() {
	local bytes="$1"
	if ((bytes >= 1073741824)); then
		printf "%.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc)"
	elif ((bytes >= 1048576)); then
		printf "%.1f MB" "$(echo "scale=1; $bytes / 1048576" | bc)"
	elif ((bytes >= 1024)); then
		printf "%.1f KB" "$(echo "scale=1; $bytes / 1024" | bc)"
	else
		printf "%d B" "$bytes"
	fi
	return 0
}

# Get file size in bytes (cross-platform)
file_size_bytes() {
	local filepath="$1"
	if [[ ! -f "$filepath" ]]; then
		echo "0"
		return 0
	fi
	_file_size_bytes "$filepath"
	return 0
}

_wal_is_stable() {
	local db="$1"
	local wal_state=""
	wal_state=$(opencode_db_wal_state "$db" "$WAL_STABILITY_DELAY_SECONDS")
	[[ "$wal_state" == "stable" ]]
	return $?
}

_db_holder_count() {
	local db="$1"
	opencode_db_holder_count "$db" "$DB_HOLDER_COMMAND"
	return 0
}

_archive_validate_active_schema() {
	local diagnostic=""

	if ! opencode_archive_schema_supported "$ACTIVE_DB" optional; then
		diagnostic=$(opencode_archive_schema_diagnostic)
		print_error "Unsupported or unavailable OpenCode session schema: ${diagnostic}; active data was left untouched."
		return 1
	fi
	return 0
}

_archive_mutation_preflight() {
	local holder_count=""

	holder_count=$(_db_holder_count "$ACTIVE_DB")
	if [[ "$holder_count" == "$OPENCODE_DB_STATE_UNKNOWN" ]]; then
		print_warning "Archive deferred — active DB holder state is unavailable."
		return 2
	fi
	if [[ "$holder_count" -gt 0 ]] && ! _archive_enter_held_mode "$holder_count"; then
		return 2
	fi
	if ! _wal_is_stable "$ACTIVE_DB"; then
		print_warning "Archive deferred — active WAL changed during the safety observation window."
		return 2
	fi
	if ! _archive_validate_active_schema; then
		return 3
	fi
	return 0
}

# GH#35517: a DB held only by idle OpenCode processes may be archived in small
# batches. Any busy, recently active, unknown or heartbeat-less holder defers.
_archive_enter_held_mode() {
	local holder_count="$1"
	local deferred="Archive deferred — ${holder_count} process(es) hold the active DB open"

	if [[ "${OPENCODE_DB_ARCHIVE_IDLE_GATE:-1}" != 1 ]]; then
		print_warning "${deferred}."
		return 1
	fi
	if [[ ! "$ARCHIVE_HELD_BATCH_SIZE" =~ ^[0-9]+$ ]] || ((ARCHIVE_HELD_BATCH_SIZE == 0)); then
		print_warning "${deferred} (OPENCODE_DB_ARCHIVE_HELD_BATCH_SIZE must be a positive integer)."
		return 1
	fi
	if ! opencode_db_idle_gate "$ACTIVE_DB" "$DB_HOLDER_COMMAND"; then
		print_warning "${deferred} (${OPENCODE_DB_IDLE_GATE_REASON})."
		return 1
	fi
	_ARCHIVE_HELD_MODE=1
	_ARCHIVE_HELD_SESSIONS="$OPENCODE_DB_IDLE_GATE_SESSIONS"
	if ((ARCHIVE_BATCH_SIZE > ARCHIVE_HELD_BATCH_SIZE)); then
		ARCHIVE_BATCH_SIZE="$ARCHIVE_HELD_BATCH_SIZE"
	fi
	print_info "Idle gate passed — ${holder_count} idle OpenCode holder(s); archiving in batches of ${ARCHIVE_BATCH_SIZE}, no VACUUM while held."
	return 0
}

# Re-check between held-mode batches; stop as soon as a holder wakes up.
_archive_held_gate_recheck() {
	((_ARCHIVE_HELD_MODE)) || return 0
	if opencode_db_idle_gate "$ACTIVE_DB" "$DB_HOLDER_COMMAND"; then
		# A holder may have claimed a session since the exclusions were built;
		# the candidate filter is stale, so pause rather than risk archiving it.
		local sid=""
		while IFS= read -r sid; do
			[[ -n "$sid" ]] || continue
			if ! grep -qxF -- "$sid" <<<"$_ARCHIVE_HELD_SESSIONS"; then
				OPENCODE_DB_IDLE_GATE_REASON="holder claimed new session ${sid}"
				print_warning "Archive paused — ${OPENCODE_DB_IDLE_GATE_REASON}. Committed batches preserved; the rest resumes next cycle."
				return 1
			fi
		done <<<"$OPENCODE_DB_IDLE_GATE_SESSIONS"
		return 0
	fi
	print_warning "Archive paused — ${OPENCODE_DB_IDLE_GATE_REASON}. Committed batches preserved; the rest resumes next cycle."
	return 1
}

# Never archive sessions (or their subagent children) that a holder has open.
_archive_held_exclude_clause() {
	local list=""
	local sid=""
	((_ARCHIVE_HELD_MODE)) || return 0
	while IFS= read -r sid; do
		[[ "$sid" =~ ^[A-Za-z0-9_-]{1,128}$ ]] || continue
		list="${list}${list:+,}'${sid}'"
	done <<<"$_ARCHIVE_HELD_SESSIONS"
	[[ -n "$list" ]] || return 0
	printf " AND id NOT IN (%s) AND COALESCE(parent_id, '') NOT IN (%s)" "$list" "$list"
	return 0
}

# VACUUM needs exclusive access; while idle OpenCode holds the DB, skip it.
# Freed pages are reused by new writes, so the file stops growing.
_archive_compact_unless_held() {
	if ((_ARCHIVE_HELD_MODE)); then
		print_info "VACUUM skipped — idle OpenCode process(es) hold the active DB; freed pages are reused by new writes."
		return 0
	fi
	_archive_compact_active_db
	return $?
}

# Checkpoint the archive WAL — called on normal exit and via trap on early return.
# Uses a global flag to prevent double-run when the fast-path calls it explicitly.
_ARCHIVE_CHECKPOINT_DONE=0
_ARCHIVE_CLEANUP_ENABLED=0
_checkpoint_archive_db() {
	local archive_db="$1"
	if ((_ARCHIVE_CHECKPOINT_DONE)); then return 0; fi
	_ARCHIVE_CHECKPOINT_DONE=1
	# Discard the busy|log|checkpointed result row; it is not user output.
	sqlite3 "$archive_db" "$SQL_CHECKPOINT_TRUNCATE" >/dev/null 2>&1 || true
	return 0
}

_archive_cleanup() {
	if ((_ARCHIVE_CLEANUP_ENABLED)) && [[ -f "$ARCHIVE_DB" ]]; then
		_checkpoint_archive_db "$ARCHIVE_DB"
	fi
	return 0
}

_archive_interrupt() {
	local exit_code="$1"
	print_warning "Archive interrupted; committed batches remain queryable and the active transaction will roll back."
	exit "$exit_code"
	return 1
}

# --- Persisted batch adaptation (GH#38590) (extracted module) ---
# shellcheck source=./opencode-db-archive-adapt.sh
# shellcheck disable=SC1091 # sibling module resolved via the entry point directory
source "${_oda_dir}/opencode-db-archive-adapt.sh"

# --- Schema creation in archive DB (extracted module) -------------------------
# shellcheck source=./opencode-db-archive-schema.sh
# shellcheck disable=SC1091 # sibling module resolved via the entry point directory
source "${_oda_dir}/opencode-db-archive-schema.sh"


_validate_nonnegative_integer() {
	local value="$1"
	local option_name="$2"

	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		print_error "${option_name} must be a non-negative integer: ${value}"
		return 1
	fi
	return 0
}

_format_cutoff_time() {
	local cutoff_ms="$1"
	local cutoff_s=$((cutoff_ms / 1000))

	date -r "$cutoff_s" '+%Y-%m-%d %H:%M' 2>/dev/null ||
		date -d "@$cutoff_s" '+%Y-%m-%d %H:%M' 2>/dev/null ||
		echo 'N/A'
	return 0
}

# _check_wal_post_archive <db>
# After a successful archive pass, checks whether the WAL is still large
# because active readers are blocking the checkpoint.  Emits a warning with
# the number of blocking processes and a deterministic next step.
# Silent no-op when WAL is within the threshold or does not exist.
_check_wal_post_archive() {
	local db="$1"
	local wal_path="${db}-wal"
	[[ -f "$wal_path" ]] || return 0
	local wal_bytes wal_mb
	wal_bytes=$(file_size_bytes "$wal_path")
	wal_mb=$((wal_bytes / 1048576))
	local threshold="${WAL_LARGE_THRESHOLD_MB:-500}"
	[[ "$wal_mb" -ge "$threshold" ]] || return 0
	print_warning "WAL still large after archive: $(format_bytes "$wal_bytes") (${wal_path})"
	# Probe checkpoint state: PASSIVE does not block writers — safe with live sessions.
	local ckpt_out blocked log_pages ckpt_pages
	ckpt_out=$(sqlite3 "$db" "PRAGMA wal_checkpoint(PASSIVE);" 2>/dev/null || echo "0|0|0")
	IFS='|' read -r blocked log_pages ckpt_pages <<<"$ckpt_out"
	if [[ "${blocked:-0}" == "1" ]] && [[ "${log_pages:-0}" -gt "${ckpt_pages:-0}" ]]; then
		local unckpt=$((${log_pages:-0} - ${ckpt_pages:-0}))
		print_warning "WAL checkpoint busy: ${unckpt} frame(s) still held by active readers"
		local n_holders=0
		if command -v lsof >/dev/null 2>&1 && [[ -f "$db" ]]; then
			n_holders=$(lsof "$db" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u | wc -l | tr -d ' ')
		fi
		n_holders="${n_holders:-0}"
		if [[ "$n_holders" -gt 0 ]]; then
			print_warning "${n_holders} process(es) holding DB open — WAL cannot be truncated until they close"
		fi
		print_info "Next step: close all OpenCode sessions, then run:"
		print_info "  opencode-db-maintenance-helper.sh maintain"
	else
		print_info "WAL will be truncated on next maintenance run (no active readers blocking)"
	fi
	return 0
}

_checkpoint_active_db_truncate() {
	local checkpoint_output=""
	local blocked=""
	local log_pages=""
	local checkpointed_pages=""

	checkpoint_output=$(sqlite3 "$ACTIVE_DB" "$SQL_CHECKPOINT_TRUNCATE" 2>/dev/null) || return 1
	IFS='|' read -r blocked log_pages checkpointed_pages <<<"$checkpoint_output"
	if [[ "${blocked:-1}" != "0" ]]; then
		return 1
	fi
	return 0
}

# Compact only with positive idle-holder, stable-WAL, and checkpoint evidence.
# This reclaims SQLite free pages; it never selects logical sessions by size.
_archive_compact_active_db() {
	local freelist_count=""
	local holder_count=""
	local quick_check=""

	freelist_count=$(sqlite3 "$ACTIVE_DB" "PRAGMA freelist_count;" 2>/dev/null || true)
	if [[ ! "$freelist_count" =~ ^[0-9]+$ ]]; then
		print_warning "VACUUM deferred — freelist state is unavailable."
		return 2
	fi
	if [[ "$freelist_count" -eq 0 ]]; then
		print_info "VACUUM not needed — active DB has no free pages."
		return 0
	fi

	holder_count=$(_db_holder_count "$ACTIVE_DB")
	if [[ "$holder_count" == "$OPENCODE_DB_STATE_UNKNOWN" ]]; then
		print_warning "VACUUM deferred — active DB holder state is unavailable."
		return 2
	fi
	if [[ "$holder_count" -gt 0 ]]; then
		print_warning "VACUUM deferred — ${holder_count} process(es) hold the active DB open."
		return 2
	fi
	if ! _wal_is_stable "$ACTIVE_DB"; then
		print_warning "VACUUM deferred — active WAL changed during the safety observation window."
		return 2
	fi

	print_info "Running pre-VACUUM wal_checkpoint(TRUNCATE)..."
	if ! _checkpoint_active_db_truncate; then
		print_warning "VACUUM deferred — pre-VACUUM checkpoint was busy or unavailable."
		return 2
	fi
	holder_count=$(_db_holder_count "$ACTIVE_DB")
	if [[ "$holder_count" == "$OPENCODE_DB_STATE_UNKNOWN" || "$holder_count" -gt 0 ]]; then
		print_warning "VACUUM deferred — active DB holder state changed after checkpoint."
		return 2
	fi

	print_info "Running VACUUM on active DB..."
	if ! sqlite3 "$ACTIVE_DB" "VACUUM;" 2>/dev/null; then
		print_warning "VACUUM deferred — exclusive access was lost. Will retry next cycle."
		return 2
	fi
	print_info "Running post-VACUUM wal_checkpoint(TRUNCATE)..."
	if ! _checkpoint_active_db_truncate; then
		print_warning "Post-VACUUM checkpoint was busy or unavailable; maintenance remains incomplete."
		return 2
	fi
	quick_check=$(sqlite3 "$ACTIVE_DB" "$SQL_QUICK_CHECK" 2>/dev/null || true)
	if [[ "$quick_check" != "ok" ]]; then
		print_error "Active DB quick_check failed after VACUUM."
		return 1
	fi
	return 0
}

# --- Session origin classification (GH#35492) ----------------------------------

_archive_sql_quote() {
	local value="$1"
	printf "'%s'" "${value//\'/\'\'}"
	return 0
}

# Print the readable headless ledger tables (worker_sessions, provider_sessions).
# A missing ledger is normal on machines that never ran headless workers.
# Callers set _ARCHIVE_LEDGER_ATTACH=1 in their own shell when output is non-empty.
_archive_ledger_tables() {
	local tables=""
	[[ -n "$HEADLESS_LEDGER_DB" && -f "$HEADLESS_LEDGER_DB" ]] || return 0
	[[ ! "$HEADLESS_LEDGER_DB" -ef "$ACTIVE_DB" ]] || return 0
	tables=$(sqlite3 -readonly -cmd '.timeout 5000' "$HEADLESS_LEDGER_DB" \
		"SELECT name FROM sqlite_master WHERE type='table' AND name IN ('worker_sessions','provider_sessions') ORDER BY name;" 2>/dev/null) || tables=""
	[[ -z "$tables" ]] || printf '%s\n' "$tables"
	return 0
}

# Run one read query against the active DB, attaching the headless ledger when
# the candidate filter references it. Each sqlite3 process is one connection,
# so the ATTACH must travel with every query that evaluates the filter.
_archive_active_query() {
	local sql="$1"
	if ((_ARCHIVE_LEDGER_ATTACH)); then
		sqlite3 -cmd '.timeout 5000' -cmd "ATTACH DATABASE $(_archive_sql_quote "$HEADLESS_LEDGER_DB") AS ledger;" "$ACTIVE_DB" "$sql"
		return $?
	fi
	sqlite3 "$ACTIVE_DB" "$sql"
	return $?
}

# _archive_headless_predicate <ledger_tables>
# SQL predicate over a session row that is true for headless sessions:
# worker sessions recorded in the ledger, their subagent children, one-shot
# headless runs in temp directories, and supervisor pulse sessions. Everything
# else is treated as interactive (the longer, safer retention).
_archive_headless_predicate() {
	local ledger_tables="$1"
	local ledger_ids="" table_name self_pred
	self_pred="directory LIKE '/tmp/opencode%' OR directory LIKE '/private/tmp/opencode%'"
	self_pred="${self_pred} OR directory GLOB '/var/folders/*/T/opencode*'"
	self_pred="${self_pred} OR directory LIKE '%/.aidevops/.agent-workspace/supervisor%'"
	while IFS= read -r table_name; do
		case "$table_name" in
		worker_sessions | provider_sessions)
			ledger_ids="${ledger_ids}${ledger_ids:+ UNION }SELECT session_id FROM ledger.${table_name}"
			;;
		esac
	done <<<"$ledger_tables"
	# COALESCE keeps NULL parent_id comparisons from making a row neither
	# headless nor interactive (NOT NULL is NULL, which would skip it entirely).
	if [[ -n "$ledger_ids" ]]; then
		self_pred="${self_pred} OR id IN (${ledger_ids})"
		printf 'COALESCE((%s OR parent_id IN (%s) OR parent_id IN (SELECT id FROM session WHERE %s)), 0)\n' \
			"$self_pred" "$ledger_ids" "$self_pred"
		return 0
	fi
	printf 'COALESCE((%s OR parent_id IN (SELECT id FROM session WHERE %s)), 0)\n' "$self_pred" "$self_pred"
	return 0
}

# _archive_candidate_filter <retention_enabled> <cutoff_ms> <keep_enabled>
#   <keep_sessions> <exclude_clause> [worker_cutoff_ms] [headless_predicate]
# With a headless predicate, headless sessions use worker_cutoff_ms and all
# other sessions use cutoff_ms (the interactive cutoff).
_archive_candidate_filter() {
	local retention_enabled="$1"
	local cutoff_ms="$2"
	local keep_enabled="$3"
	local keep_sessions="$4"
	local exclude_clause="$5"
	local worker_cutoff_ms="${6:-}"
	local headless_predicate="${7:-}"
	local filter="1=1" keep_clause=""

	if ((keep_enabled)); then
		keep_clause="id NOT IN (SELECT id FROM session ORDER BY time_updated DESC, time_created DESC, id DESC LIMIT ${keep_sessions})"
	fi
	if ((retention_enabled)) && [[ -n "$headless_predicate" && -n "$worker_cutoff_ms" ]]; then
		# The keep-newest budget protects interactive history only; a busy
		# worker fleet must not hold headless sessions past their cutoff.
		filter="${filter} AND ((${headless_predicate} AND time_updated < ${worker_cutoff_ms}) OR (NOT ${headless_predicate} AND time_updated < ${cutoff_ms}${keep_clause:+ AND ${keep_clause}}))"
		keep_enabled=0
	elif ((retention_enabled)); then
		filter="${filter} AND time_updated < ${cutoff_ms}"
	fi
	if ((keep_enabled)); then
		filter="${filter} AND id NOT IN (SELECT id FROM session ORDER BY time_updated DESC, time_created DESC, id DESC LIMIT ${keep_sessions})"
	fi
	if [[ -n "$exclude_clause" ]]; then
		filter="${filter} ${exclude_clause}"
	fi

	printf '%s\n' "$filter"
	return 0
}

# --- Archive command ----------------------------------------------------------

cmd_archive_all() {
	local db rc=0 result=0 archive_pid=""
	# Wait asynchronously so Bash handles signals immediately, and forward them
	# to the per-DB supervisor before releasing the async runner's lock.
	trap 'kill -TERM "$archive_pid" 2>/dev/null || true; wait "$archive_pid" 2>/dev/null || true; exit 143' TERM
	trap 'kill -INT "$archive_pid" 2>/dev/null || true; wait "$archive_pid" 2>/dev/null || true; exit 130' INT
	while IFS= read -r -d '' db; do
		print_info "Archive inventory: $db"
		rc=0
		OPENCODE_DB_PATH="$db" OPENCODE_ARCHIVE_DB="${db%/*}/opencode-archive.db" \
			bash "${BASH_SOURCE[0]}" archive "$@" &
		archive_pid=$!
		wait "$archive_pid" || rc=$?
		archive_pid=""
		print_info "Archive inventory outcome: db=$db rc=$rc (0=complete, 2=protected/deferred, 3=unsupported)"
		# Continue the fleet, but never record a partial fleet as fully successful.
		if [[ "$rc" -ne 0 && ("$result" -eq 0 || "$result" -eq 2) ]]; then result="$rc"; fi
	done < <(opencode_db_inventory "$ACTIVE_DB")
	trap - INT TERM
	return "$result"
}

# Bound the entire per-DB invocation, including candidate scans, integrity
# checks and compaction. A shell-loop deadline alone cannot interrupt SQLite.
# Use a private process group so cancellation also reaches SQLite grandchildren;
# SQLite rolls back an interrupted transaction and retains committed batches.
_archive_with_deadline() {
	local duration="$1"
	shift
	command -v python3 >/dev/null 2>&1 || {
		print_error "python3 is required to enforce the archive per-DB deadline"
		return 1
	}
	exec python3 - "$duration" "${BASH_SOURCE[0]}" "$@" <<'PY'
import os
import signal
import subprocess
import sys

duration = int(sys.argv[1])
env = dict(os.environ, OPENCODE_ARCHIVE_BUDGET_CHILD="1")
child = subprocess.Popen(["bash", sys.argv[2], "archive", *sys.argv[3:]],
                         env=env, start_new_session=True)

def stop(signum, _frame=None):
    # Ignore repeated signals while draining the owned process group.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    # Darwin killpg() returns EPERM, not ESRCH, when every member of the
    # group has exited but is not yet reaped. Both mean nothing is left to
    # signal; raising turned deadline deferrals (rc=2) into rc=1 failures.
    try:
        os.killpg(child.pid, signal.SIGTERM)
        child.wait(timeout=2)
    except (ProcessLookupError, PermissionError):
        pass
    except subprocess.TimeoutExpired:
        pass
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        child.wait()
    if signum:
        print(f"Archive interrupted: rc={128 + signum}", flush=True)
        sys.exit(128 + signum)
    print(f"Archive deferred/partial: per-DB time budget exhausted ({duration}s); "
          "committed batches preserved; unfinished work resumes next cycle. rc=2", flush=True)
    sys.exit(2)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    rc = child.wait(timeout=duration)
except subprocess.TimeoutExpired:
    stop(0)
sys.exit(rc if rc >= 0 else 128 - rc)
PY
}

# --- Archive compaction (GH#40302) (extracted module) ---
# shellcheck source=./opencode-db-archive-compact.sh
# shellcheck disable=SC1091 # sibling module resolved via the entry point directory
source "${_oda_dir}/opencode-db-archive-compact.sh"

# Compact every inventoried archive (one child per project DB).
cmd_compact_archives() {
	local db rc=0 result=0
	while IFS= read -r -d '' db; do
		rc=0
		OPENCODE_DB_PATH="$db" OPENCODE_ARCHIVE_DB="${db%/*}/opencode-archive.db" \
			bash "${BASH_SOURCE[0]}" compact-archive || rc=$?
		if [[ "$rc" -ne 0 && ("$result" -eq 0 || "$result" -eq 2) ]]; then result="$rc"; fi
	done < <(opencode_db_inventory "$ACTIVE_DB")
	return "$result"
}

# Expire only archived event payloads, never the saved transcript graph. Pages
# freed here are reclaimed by _archive_compact_archive_db (events-only path).
_archive_expire_events() {
	local days="$1" dry_run="$2" max_duration="$3"
	[[ "$days" -gt 0 && -f "$ARCHIVE_DB" ]] || return 0
	if [[ "$ARCHIVE_DB" -ef "$ACTIVE_DB" ]]; then
		print_error "Archive event expiry refused — active and archive DB are the same file"
		return 1
	fi
	local holders cutoff count start now total=0 bytes=0 remaining rc
	local expiry_batch_size="${OPENCODE_ARCHIVE_EVENT_EXPIRY_BATCH_SIZE:-$DEFAULT_BATCH_SIZE}"
	_validate_nonnegative_integer "$expiry_batch_size" "OPENCODE_ARCHIVE_EVENT_EXPIRY_BATCH_SIZE" || return 1
	if ((expiry_batch_size == 0)); then return 1; fi
	holders=$(_db_holder_count "$ARCHIVE_DB")
	if [[ "$holders" == "$OPENCODE_DB_STATE_UNKNOWN" || "$holders" -gt 0 ]]; then
		print_warning "Archive event expiry deferred — archive holder state is active or unknown"
		return 2
	fi
	_wal_is_stable "$ARCHIVE_DB" || return 2
	_sqlite_has_table "$ARCHIVE_DB" event || return 0
	opencode_archive_schema_supported "$ARCHIVE_DB" required || return 3
	cutoff=$(($(date +%s) * 1000 - days * 86400000))
	if ((dry_run)); then
		count=$(sqlite3 -readonly "$ARCHIVE_DB" "SELECT COUNT(*) FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE time_updated < $cutoff);") || return 1
		bytes=$(sqlite3 -readonly "$ARCHIVE_DB" "SELECT COALESCE(SUM(LENGTH(data)), 0) FROM event WHERE aggregate_id IN (SELECT id FROM session WHERE time_updated < $cutoff);") || return 1
		print_info "DRY RUN — would expire $count archived events (inactive ${days}+ days), $(format_bytes "$bytes") payload"
		print_info "Freed pages are reused; file size falls only after VACUUM."
		return 0
	fi
	start=$(date +%s)
	while true; do
		now=$(date +%s)
		remaining=$((max_duration - (now - start)))
		((remaining > 0)) || break
		rc=0
		count=$(python3 -c 'import subprocess, sys
try:
    result = subprocess.run(["sqlite3", "-cmd", ".timeout 5000", sys.argv[2], sys.argv[3]], timeout=int(sys.argv[1]), check=False)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)' "$remaining" "$ARCHIVE_DB" "DELETE FROM event WHERE rowid IN (SELECT e.rowid FROM event e JOIN session s ON s.id=e.aggregate_id WHERE s.time_updated < $cutoff LIMIT $expiry_batch_size); SELECT changes();") || rc=$?
		if ((rc == 124)); then break; fi
		((rc == 0)) || return 1
		total=$((total + count))
		[[ "$count" -gt 0 ]] || break
		now=$(date +%s)
		if ((max_duration > 0 && now - start >= max_duration)); then break; fi
	done
	print_info "Archived event expiry pass complete: expired $total events (inactive ${days}+ days); transcripts preserved; freed pages are reused until VACUUM"
	return 0
}

cmd_archive() {
	local original_args=("$@")
	# retention_days is the interactive cutoff; worker_retention_days applies to
	# headless sessions. --retention-days sets both (uniform legacy behaviour).
	local retention_days="${OPENCODE_DB_ARCHIVE_INTERACTIVE_RETENTION_DAYS:-$DEFAULT_INTERACTIVE_RETENTION_DAYS}"
	local worker_retention_days="${OPENCODE_DB_ARCHIVE_WORKER_RETENTION_DAYS:-$DEFAULT_WORKER_RETENTION_DAYS}"
	local retention_enabled=1
	local retention_explicit=0
	local keep_sessions=0
	local keep_enabled=0
	local dry_run=0
	local max_duration="$DEFAULT_MAX_DURATION"
	local event_retention_days="${OPENCODE_ARCHIVE_EVENT_RETENTION_DAYS:-$DEFAULT_WORKER_RETENTION_DAYS}"
	local events_only=0
	local worker_event_minutes="${OPENCODE_DB_ARCHIVE_EVENT_IDLE_MINUTES:-${OPENCODE_DB_ARCHIVE_WORKER_EVENT_MINUTES:-$DEFAULT_WORKER_EVENT_EXPIRY_MINUTES}}"
	local worker_events_only=0

	# Phase helpers share only these command-local settings/results via Bash's
	# dynamic scope. Batch SQL and counters have their own narrower owner below.
	local candidate_filter total_eligible
	local has_session_message_table=0 has_session_input_table=0
	local has_session_context_epoch_table=0 has_event_sequence_table=0 has_event_table=0
	local inbox_session_tables=""
	_archive_parse_options "$@" || return 1
	_archive_validate_options || return 1
	if [[ "${OPENCODE_ARCHIVE_BUDGET_CHILD:-0}" != 1 ]]; then
		_archive_with_deadline "$max_duration" "${original_args[@]}"
		return $?
	fi
	if ((worker_events_only)); then
		_archive_worker_event_phase "$max_duration"
		return $?
	fi
	local expiry_budget="$max_duration"
	((events_only)) || expiry_budget=$((max_duration / 4))
	local expiry_rc=0
	if ((expiry_budget > 0)); then
		local event_t0
		event_t0=$(date +%s)
		_archive_expire_events "$event_retention_days" "$dry_run" "$expiry_budget" || expiry_rc=$?
		_ARCHIVE_T_EVENT=$(($(date +%s) - event_t0))
		# Only a deferral (2) must not block the session move; errors stop here.
		if [[ "$expiry_rc" -ne 0 && "$expiry_rc" -ne 2 ]]; then
			return "$expiry_rc"
		fi
	fi
	if ((events_only)); then
		local compact_rc=0
		if ((!dry_run)); then
			_archive_compact_archive_db || compact_rc=$?
		fi
		if [[ "$expiry_rc" -eq 0 && "$compact_rc" -ne 0 ]]; then expiry_rc="$compact_rc"; fi
		return "$expiry_rc"
	fi
	local move_rc=0
	_archive_move_phase || move_rc=$?
	print_info "Phase seconds: event_expiry=${_ARCHIVE_T_EVENT} worker_event_expiry=${_ARCHIVE_T_WORKER} candidate_prep=${_ARCHIVE_T_PREP} sizing=${_ARCHIVE_T_SIZING} batch_write=${_ARCHIVE_T_WRITE} (rc=${move_rc})"
	# Keep rc 2 after a successful move so the scheduler retries the expiry.
	if [[ "$move_rc" -eq 0 && "$expiry_rc" -eq 2 ]]; then
		return 2
	fi
	return "$move_rc"
}

# Session-move phase of cmd_archive; shares its dynamic-scope settings.
_archive_move_phase() {
	local preflight_rc=0
	# GH#38630: idle-session event expiry no longer runs inside the move; the
	# async runner and --worker-events-only run it independently of holders, so a
	# deferred move cannot starve it. Sessions moved here carry their events.
	local now
	_archive_mutation_preflight || preflight_rc=$?
	if [[ "$preflight_rc" -ne 0 ]]; then
		return "$preflight_rc"
	fi
	now=$(date +%s)
	_archive_prepare_candidates || return $?
	_ARCHIVE_T_PREP=$(($(date +%s) - now))
	if ((total_eligible == 0)); then
		print_success "No sessions match the archive retention target."
		((dry_run)) && return 0
		_archive_compact_unless_held
		return $?
	fi
	print_info "Found $total_eligible sessions eligible for archiving"
	_archive_detect_tables
	if ((dry_run)); then
		_archive_report_dry_run
		return $?
	fi
	_archive_move_candidates
	return $?
}

# Light hourly pass (--worker-events-only): expire events of idle sessions
# without moving sessions; shares cmd_archive's dynamic-scope settings. It never
# waits for idle holders: each delete is a short write transaction (GH#38630).
_archive_worker_event_phase() {
	local budget="$1"
	_archive_expire_worker_events "$worker_event_minutes" "$dry_run" "$budget"
	return $?
}

# Updates settings owned by cmd_archive, not process-global configuration.
_archive_parse_options() {
	# Parse arguments
	while [[ $# -gt 0 ]]; do
		local option="$1"
		local option_value="${2:-}"
		case "$option" in
		--retention-days | --interactive-retention-days | --worker-retention-days | --keep-sessions | --archive-event-retention-days | --worker-event-expiry-minutes | --max-duration-seconds)
			if [[ $# -lt 2 ]]; then
				print_error "Option requires a value: $option"
				return 1
			fi
			;;
		esac
		case "$option" in
		--retention-days)
			retention_days="$option_value"
			worker_retention_days="$option_value"
			retention_enabled=1
			retention_explicit=1
			shift 2 || return 1
			;;
		--interactive-retention-days | --worker-retention-days)
			if [[ "$option" == "--worker-retention-days" ]]; then
				worker_retention_days="$option_value"
			else
				retention_days="$option_value"
			fi
			retention_enabled=1
			retention_explicit=1
			shift 2 || return 1
			;;
		--keep-sessions)
			keep_sessions="$option_value"
			keep_enabled=1
			if ((retention_explicit == 0)); then
				retention_enabled=0
			fi
			shift 2 || return 1
			;;
		--dry-run)
			dry_run=1
			shift
			;;
		--apply)
			dry_run=0
			shift
			;;
		--events-only)
			events_only=1
			shift
			;;
		--worker-events-only)
			worker_events_only=1
			shift
			;;
		--worker-event-expiry-minutes)
			worker_event_minutes="$option_value"
			shift 2 || return 1
			;;
		--archive-event-retention-days)
			event_retention_days="$option_value"
			[[ $# -ge 2 ]] || return 1
			shift 2
			;;
		--max-duration-seconds)
			max_duration="$option_value"
			shift 2 || return 1
			;;
		*)
			print_error "Unknown option: $option"
			cmd_help
			return 1
			;;
		esac
	done
	return 0
}

_archive_validate_options() {
	check_sqlite3 || return 1
	check_active_db || return 1
	_validate_nonnegative_integer "$retention_days" "--retention-days/--interactive-retention-days" || return 1
	_validate_nonnegative_integer "$worker_retention_days" "--worker-retention-days" || return 1
	_validate_nonnegative_integer "$keep_sessions" "--keep-sessions" || return 1
	_validate_nonnegative_integer "$max_duration" "--max-duration-seconds" || return 1
	_validate_nonnegative_integer "$event_retention_days" "--archive-event-retention-days" || return 1
	_validate_nonnegative_integer "$worker_event_minutes" "--worker-event-expiry-minutes" || return 1
	_validate_nonnegative_integer "$ARCHIVE_BATCH_SIZE" "OPENCODE_DB_ARCHIVE_BATCH_SIZE" || return 1
	if [[ "$ARCHIVE_BATCH_SIZE" -eq 0 ]]; then
		print_error "OPENCODE_DB_ARCHIVE_BATCH_SIZE must be greater than zero."
		return 1
	fi
	if [[ ! "$ARCHIVE_BATCH_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		print_error "OPENCODE_DB_ARCHIVE_BATCH_DELAY_SECONDS must be a non-negative number."
		return 1
	fi
	if [[ ! "$WAL_STABILITY_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		print_error "OPENCODE_DB_WAL_STABILITY_DELAY_SECONDS must be a non-negative number."
		return 1
	fi
	return 0
}

_archive_prepare_candidates() {
	local cutoff_ms worker_cutoff_ms headless_predicate="" ledger_tables=""
	cutoff_ms=$(($(date +%s) * 1000 - retention_days * 86400 * 1000))
	worker_cutoff_ms=$(($(date +%s) * 1000 - worker_retention_days * 86400 * 1000))
	_ARCHIVE_LEDGER_ATTACH=0

	if ((retention_enabled)) && [[ "$retention_days" != "$worker_retention_days" ]]; then
		ledger_tables=$(_archive_ledger_tables)
		[[ -z "$ledger_tables" ]] || _ARCHIVE_LEDGER_ATTACH=1
		headless_predicate=$(_archive_headless_predicate "$ledger_tables")
		print_info "Retention: headless/worker sessions ${worker_retention_days} days (cutoff: $(_format_cutoff_time "$worker_cutoff_ms")); interactive sessions ${retention_days} days (cutoff: $(_format_cutoff_time "$cutoff_ms"))"
		[[ -n "$ledger_tables" ]] || print_info "Headless ledger unavailable — classifying headless sessions by temp/supervisor directory only"
	elif ((retention_enabled)); then
		print_info "Retention: ${retention_days} days since last update (cutoff: $(_format_cutoff_time "$cutoff_ms"))"
	fi
	if ((keep_enabled)); then
		print_info "Retention: keep newest ${keep_sessions} active sessions by last update"
	fi
	if ((retention_enabled && keep_enabled)); then
		print_info "Combined retention: archiving only sessions inactive beyond both targets"
	fi
	print_info "Active DB: $ACTIVE_DB"
	print_info "Archive DB: $ARCHIVE_DB"
	# Get active worker sessions to exclude
	local active_sessions
	active_sessions=$(get_active_worker_sessions)
	local exclude_count=0
	if [[ -n "$active_sessions" ]]; then
		exclude_count=$(echo "$active_sessions" | wc -l | tr -d ' ')
		print_warning "Excluding $exclude_count session(s) with active workers"
	fi

	# Build exclusion clause for SQL
	local exclude_clause=""
	if [[ -n "$active_sessions" ]]; then
		# Build a comma-separated quoted list
		local exclude_list=""
		while IFS= read -r sid; do
			exclude_list="${exclude_list}${exclude_list:+,}'${sid}'"
		done <<<"$active_sessions"
		exclude_clause="AND id NOT IN ($exclude_list)"
	fi
	exclude_clause="${exclude_clause}$(_archive_held_exclude_clause)"

	# GH#38590: a leftover in-flight marker means the previous batch never
	# committed. Halve the persisted limits; a still-failing 1-session batch is
	# deferred as oversized so it cannot block the queue head forever.
	_ARCHIVE_ADAPT_LIMIT=0
	_ARCHIVE_ADAPT_BYTES=0
	if ! ((dry_run)); then
		_archive_adapt_recover sessions 1
		if [[ -n "$_ARCHIVE_ADAPT_IDS" && "$_ARCHIVE_ADAPT_IDS" != *,* ]]; then
			_archive_oversized_record "$_ARCHIVE_ADAPT_IDS"
		fi
	fi
	exclude_clause="${exclude_clause}$(_archive_oversized_exclude_clause)"

	candidate_filter=$(_archive_candidate_filter "$retention_enabled" "$cutoff_ms" "$keep_enabled" "$keep_sessions" "$exclude_clause" "$worker_cutoff_ms" "$headless_predicate")

	# Count eligible sessions
	total_eligible=$(_archive_active_query "SELECT COUNT(*) FROM session WHERE $candidate_filter;")
	return 0
}

_archive_detect_tables() {
	if _sqlite_has_table "$ACTIVE_DB" session_message; then
		has_session_message_table=1
	fi
	if _sqlite_has_table "$ACTIVE_DB" session_input; then
		has_session_input_table=1
	fi
	if _sqlite_has_table "$ACTIVE_DB" session_context_epoch; then
		has_session_context_epoch_table=1
	fi
	if _sqlite_has_table "$ACTIVE_DB" event_sequence; then
		has_event_sequence_table=1
	fi
	if _sqlite_has_table "$ACTIVE_DB" "$EVENT_TABLE_NAME"; then
		has_event_table=1
	fi
	# Session-inbox generation tables present in the active DB (space separated).
	local inbox_table=""
	inbox_session_tables=""
	for inbox_table in $OPENCODE_ARCHIVE_INBOX_SESSION_TABLES; do
		if _sqlite_has_table "$ACTIVE_DB" "$inbox_table"; then
			inbox_session_tables="${inbox_session_tables}${inbox_session_tables:+ }${inbox_table}"
		fi
	done
	return 0
}

# Payload-size SQL expression for one session-inbox generation table.
_archive_inbox_table_bytes_expr() {
	local table_name="$1"
	case "$table_name" in
	session_inbox) _archive_len_expr payload ;;
	session_pending) _archive_len_expr data ;;
	instruction_entry) _archive_len_expr value ;;
	instruction_state) printf '%s + %s\n' "$(_archive_len_expr initial_values)" "$(_archive_len_expr current_values)" ;;
	*) printf '0\n' ;;
	esac
	return 0
}

_archive_report_dry_run() {
	# Show what would be archived
	local msg_count part_count todo_count share_count event_count event_bytes
	local session_message_count=0 session_input_count=0 context_epoch_count=0 event_sequence_count=0
	local inbox_table="" inbox_count=0 inbox_report=""
	msg_count=$(_archive_active_query "SELECT COUNT(*) FROM message WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
	part_count=$(_archive_active_query "SELECT COUNT(*) FROM part WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
	todo_count=$(_archive_active_query "SELECT COUNT(*) FROM todo WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
	share_count=$(_archive_active_query "SELECT COUNT(*) FROM session_share WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
	if ((has_session_message_table)); then
		session_message_count=$(_archive_active_query "SELECT COUNT(*) FROM session_message WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
	fi
	if ((has_session_input_table)); then
		session_input_count=$(_archive_active_query "SELECT COUNT(*) FROM session_input WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
	fi
	if ((has_session_context_epoch_table)); then
		context_epoch_count=$(_archive_active_query "SELECT COUNT(*) FROM session_context_epoch WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
	fi
	if ((has_event_sequence_table)); then
		event_sequence_count=$(_archive_active_query "SELECT COUNT(*) FROM event_sequence WHERE aggregate_id IN (SELECT id FROM session WHERE $candidate_filter);")
	fi
	for inbox_table in $inbox_session_tables; do
		inbox_count=$(_archive_active_query "SELECT COUNT(*) FROM ${inbox_table} WHERE session_id IN (SELECT id FROM session WHERE $candidate_filter);")
		inbox_report="${inbox_report}  ${inbox_table}: ${inbox_count}"$'\n'
	done
	event_count=$(_archive_active_query "$(_archive_event_count_sql "$candidate_filter" "$has_event_table")")
	event_bytes=$(_archive_active_query "$(_archive_event_bytes_sql "$candidate_filter" "$has_event_table")")

	echo ""
	echo "=== DRY RUN — would archive: ==="
	echo "  Sessions:       $total_eligible"
	echo "  Messages:       $msg_count"
	echo "  Parts:          $part_count"
	echo "  Todos:          $todo_count"
	echo "  Session shares: $share_count"
	echo "  Session msgs:   $session_message_count"
	echo "  Session inputs: $session_input_count"
	echo "  Context epochs: $context_epoch_count"
	[[ -z "$inbox_report" ]] || printf '%s' "$inbox_report"
	echo "  Event sequences: $event_sequence_count"
	echo "  Events:         $event_count ($(format_bytes "$event_bytes"))"
	echo ""
	print_info "Run without --dry-run to proceed."
	return 0
}

_archive_move_candidates() {
	# Create archive DB and schema
	local archive_created=0
	[[ -f "$ARCHIVE_DB" ]] || archive_created=1
	create_archive_schema "$ARCHIVE_DB"
	if ! opencode_archive_schema_supported "$ARCHIVE_DB" required; then
		local archive_schema_diagnostic=""
		archive_schema_diagnostic=$(opencode_archive_schema_diagnostic)
		print_error "Archive schema is unavailable or unsupported: ${archive_schema_diagnostic}; active data was left untouched."
		return 3
	fi

	local project_insert_columns project_select_columns
	local session_insert_columns session_select_columns
	project_insert_columns=$(_archive_project_insert_columns)
	project_select_columns=$(_archive_project_select_columns)
	session_insert_columns=$(_archive_session_insert_columns)
	session_select_columns=$(_archive_session_select_columns)

	local size_before
	size_before=$(file_size_bytes "$ACTIVE_DB")
	local archived_total=0

	# Cleanup scope: checkpoint the archive WAL on every process exit. SQLite rolls
	# back an interrupted in-flight batch; already committed batches stay queryable.
	_ARCHIVE_CHECKPOINT_DONE=0
	_ARCHIVE_CLEANUP_ENABLED=1
	trap '_archive_cleanup' EXIT
	trap '_archive_interrupt 130' INT
	trap '_archive_interrupt 143' TERM
	# main captures command status with ||, so do not rely on errexit here.
	_archive_run_batches || return $?
	_archive_finish
	return $?
}

_archive_select_batch() {
	local batch_limit="$1" byte_limit="$2" deadline="$3"
	local selected size_sql data_len extra_bytes_sql=""
	data_len=$(_archive_len_expr data)
	if ((has_session_message_table)); then
		extra_bytes_sql=" + COALESCE((SELECT SUM(${data_len}) FROM session_message WHERE session_id=c.id),0)"
	fi
	if ((has_event_table)); then
		extra_bytes_sql="$extra_bytes_sql + COALESCE((SELECT SUM(${data_len}) FROM event WHERE aggregate_id=c.id),0)"
	fi
	if ((has_session_input_table)); then
		extra_bytes_sql="$extra_bytes_sql + COALESCE((SELECT SUM($(_archive_len_expr prompt)) FROM session_input WHERE session_id=c.id),0)"
	fi
	if ((has_session_context_epoch_table)); then
		extra_bytes_sql="$extra_bytes_sql + COALESCE((SELECT SUM($(_archive_len_expr baseline) + $(_archive_len_expr snapshot)) FROM session_context_epoch WHERE session_id=c.id),0)"
	fi
	local inbox_table=""
	for inbox_table in $inbox_session_tables; do
		extra_bytes_sql="$extra_bytes_sql + COALESCE((SELECT SUM($(_archive_inbox_table_bytes_expr "$inbox_table")) FROM ${inbox_table} WHERE session_id=c.id),0)"
	done
	# Never begin sizing or a write after the remaining budget is used.
	if (($(date +%s) >= deadline)); then return 2; fi
	# Without octet_length() every sized row reads its overflow pages, so keep
	# the sized window small; later batches take the rest.
	if ! _archive_octet_supported && ((batch_limit > 25)); then batch_limit=25; fi
	# One query sizes the whole candidate window with a cumulative window sum
	# and returns the prefix that fits the byte bound. The first session is
	# always kept so an oversized single session can still move on its own.
	size_sql="WITH cand AS (SELECT c.id AS id, ROW_NUMBER() OVER (ORDER BY c.time_updated, c.time_created, c.id) AS rn, COALESCE((SELECT SUM(${data_len}) FROM part WHERE session_id=c.id),0) + COALESCE((SELECT SUM(${data_len}) FROM message WHERE session_id=c.id),0)${extra_bytes_sql} AS b FROM (SELECT id, time_updated, time_created FROM session WHERE $candidate_filter ORDER BY time_updated, time_created, id LIMIT $batch_limit) c), cum AS (SELECT id, rn, SUM(b) OVER (ORDER BY rn) AS total FROM cand) SELECT id FROM cum WHERE rn = 1 OR total <= $byte_limit ORDER BY rn;"
	selected=$(_archive_active_query "$size_sql") || return 1
	if (($(date +%s) >= deadline)); then return 2; fi
	[[ -z "$selected" ]] || printf '%s\n' "$selected"
	return 0
}

_archive_run_batches() {
	local start_time
	start_time=$(date +%s)
	local batch_num=0
	local first_batch=1
	local next_limit="$ARCHIVE_BATCH_SIZE" last_seconds=0
	local byte_limit="${OPENCODE_DB_ARCHIVE_BATCH_BYTES:-67108864}"
	_validate_nonnegative_integer "$byte_limit" "OPENCODE_DB_ARCHIVE_BATCH_BYTES" || return 1
	if ((byte_limit == 0)); then return 1; fi
	local default_limit="$next_limit" default_bytes="$byte_limit" t0
	# GH#38590: start from the persisted (halved or regrown) limits.
	if ((_ARCHIVE_ADAPT_LIMIT > 0 && _ARCHIVE_ADAPT_LIMIT < next_limit)); then
		next_limit="$_ARCHIVE_ADAPT_LIMIT"
	fi
	if ((_ARCHIVE_ADAPT_BYTES > 0 && _ARCHIVE_ADAPT_BYTES < byte_limit)); then
		byte_limit="$_ARCHIVE_ADAPT_BYTES"
	fi

	while ((archived_total < total_eligible)); do
		# Check time budget
		local elapsed
		elapsed=$(($(date +%s) - start_time))
		if ((elapsed >= max_duration)); then
			print_warning "Time budget exhausted (${elapsed}s >= ${max_duration}s). Archived $archived_total/$total_eligible sessions. Will resume next cycle."
			return 2
		fi
		if ((batch_num > 0 && last_seconds >= max_duration - elapsed)); then
			print_warning "Remaining budget is shorter than the previous batch; resuming next cycle."
			return 2
		fi
		if ((batch_num > 0)) && ! _archive_held_gate_recheck; then
			return 2
		fi

		batch_num=$((batch_num + 1))
		local batch_limit="$next_limit"
		local remaining=$((total_eligible - archived_total))
		if ((remaining < batch_limit)); then
			batch_limit=$remaining
		fi

		# Collect batch session IDs
		local session_ids batch_start
		# Start the timer before sizing so selection cost counts toward adaptation.
		batch_start=$(date +%s)
		session_ids=$(_archive_select_batch "$batch_limit" "$byte_limit" "$((start_time + max_duration))") || return $?
		_ARCHIVE_T_SIZING=$((_ARCHIVE_T_SIZING + $(date +%s) - batch_start))

		if [[ -z "$session_ids" ]]; then
			break
		fi

		local batch_count
		batch_count=$(echo "$session_ids" | wc -l | tr -d ' ')

		# Build the IN clause for this batch.
		# macOS BSD paste -s does not accept pipe input — only file args.
		# Use tr + sed instead, which works portably on both macOS and Linux.
		# The previous `paste -sd,` silently failed on macOS, preventing
		# archival and bloating the DB to multi-GB (3232+ sessions).
		local in_clause=""
		in_clause=$(printf '%s\n' "$session_ids" | sed "s/.*/'&'/" | tr '\n' ',' | sed 's/,$//')
		# The marker survives a deadline/SIGTERM/SIGKILL kill, so the next run
		# knows this write never committed. An ordinary failure is not a kill.
		_archive_adapt_mark sessions "$next_limit" "$byte_limit" "$(printf '%s' "$session_ids" | tr '\n' ',')"
		t0=$(date +%s)
		_archive_write_batch "$in_clause" || {
			_archive_adapt_clear sessions
			return 1
		}
		_ARCHIVE_T_WRITE=$((_ARCHIVE_T_WRITE + $(date +%s) - t0))
		last_seconds=$(($(date +%s) - batch_start))
		elapsed=$(($(date +%s) - start_time))
		if ((last_seconds * 3 > max_duration - elapsed && next_limit > 1)); then
			next_limit=$(((batch_count + 1) / 2))
			# Persist the reduced limits as-is; growth is only for fast batches.
			_archive_adapt_clear sessions
			_archive_adapt_write sessions limits "$next_limit $byte_limit"
		else
			_archive_adapt_commit sessions "$next_limit" "$byte_limit" "$default_limit" "$default_bytes"
		fi
		archived_total=$((archived_total + batch_count))
		_archive_report_batch || return 1
	done
	return 0
}

_archive_write_batch() {
	local in_clause="$1"
	local session_message_copy_sql="" session_message_delete_sql=""
	local session_input_copy_sql="" session_input_delete_sql=""
	local context_epoch_copy_sql="" context_epoch_delete_sql=""
	local event_sequence_copy_sql="" event_sequence_delete_sql=""
	local event_copy_sql="" event_delete_sql=""
	local inbox_copy_sql="" inbox_delete_sql="" inbox_table=""
	local session_row_filter="session_id IN ($in_clause)"
	local aggregate_row_filter="aggregate_id IN ($in_clause)"
	for inbox_table in $inbox_session_tables; do
		inbox_copy_sql="${inbox_copy_sql}$(_archive_copy_sql "$inbox_table" "$session_row_filter")"$'\n' || return 1
		inbox_delete_sql="${inbox_delete_sql}DELETE FROM ${inbox_table} WHERE session_id IN ($in_clause);"$'\n'
	done
	if ((has_session_message_table)); then
		session_message_copy_sql=$(_archive_copy_sql session_message "$session_row_filter") || return 1
		session_message_delete_sql="DELETE FROM session_message WHERE session_id IN ($in_clause);"
	fi
	if ((has_session_input_table)); then
		session_input_copy_sql=$(_archive_copy_sql session_input "$session_row_filter") || return 1
		session_input_delete_sql="DELETE FROM session_input WHERE session_id IN ($in_clause);"
	fi
	if ((has_session_context_epoch_table)); then
		context_epoch_copy_sql=$(_archive_copy_sql session_context_epoch "$session_row_filter") || return 1
		context_epoch_delete_sql="DELETE FROM session_context_epoch WHERE session_id IN ($in_clause);"
	fi
	if ((has_event_sequence_table)); then
		event_sequence_copy_sql=$(_archive_copy_sql event_sequence "$aggregate_row_filter") || return 1
		event_sequence_delete_sql="DELETE FROM event_sequence WHERE aggregate_id IN ($in_clause);"
	fi
	if ((has_event_table)); then
		event_copy_sql=$(_archive_copy_sql event "$aggregate_row_filter") || return 1
		event_delete_sql="DELETE FROM event WHERE aggregate_id IN ($in_clause);"
	fi

	local message_copy_sql part_copy_sql todo_copy_sql share_copy_sql
	message_copy_sql=$(_archive_copy_sql message "$session_row_filter") || return 1
	part_copy_sql=$(_archive_copy_sql part "$session_row_filter") || return 1
	todo_copy_sql=$(_archive_copy_sql todo "$session_row_filter") || return 1
	share_copy_sql=$(_archive_copy_sql session_share "$session_row_filter") || return 1

	# A deadline may interrupt COMMIT. WAL commits are NOT atomic across
	# attached DBs: first commit the archive alone, then verify the durable
	# copy under a fresh write lock before deleting anything from active.
	# An interruption between commits leaves safe, retryable duplicates.
	local verify_sql table_name row_filter comparisons column
	local session_columns_array=()
	IFS=',' read -r -a session_columns_array <<<"$session_insert_columns"
	comparisons=""
	for column in "${session_columns_array[@]}"; do
		column="${column// /}"
		comparisons="${comparisons}${comparisons:+ AND }a.\"${column}\" IS s.\"${column}\""
	done
	verify_sql="INSERT INTO archive_copy_guard SELECT NOT EXISTS (SELECT 1 FROM (SELECT ${session_select_columns} FROM session WHERE id IN ($in_clause)) s WHERE NOT EXISTS (SELECT 1 FROM archive.session a WHERE a.id IS s.id AND $comparisons));"
	for table_name in message part todo session_share session_message session_input session_context_epoch $inbox_session_tables event_sequence event; do
		_sqlite_has_table "$ACTIVE_DB" "$table_name" || continue
		row_filter="$session_row_filter"
		case "$table_name" in event_sequence | event) row_filter="$aggregate_row_filter" ;; esac
		comparisons=$(sqlite3 "$ACTIVE_DB" "SELECT group_concat('a.' || quote(name) || ' IS s.' || quote(name), ' AND ') FROM pragma_table_info('$table_name');") || return 1
		verify_sql="${verify_sql}INSERT INTO archive_copy_guard SELECT NOT EXISTS (SELECT 1 FROM ${table_name} s WHERE ${row_filter} AND NOT EXISTS (SELECT 1 FROM archive.${table_name} a WHERE $comparisons));"
	done
	_archive_execute_batch
	return $?
}

_archive_execute_batch() {
	# ATTACH and DETACH are within the same sqlite3 invocation — the attachment
	# is released automatically when the process exits. The trap above ensures
	# the archive WAL is checkpointed on any exit path between batches.
	# Foreign-key mode is connection-local. Enable it explicitly and still use
	# dependency-safe manual deletes so behavior never depends on OpenCode's
	# separate connection configuration.
	if ! sqlite3 "$ACTIVE_DB" <<BATCH_SQL; then
.bail on
.timeout 5000
PRAGMA foreign_keys = ON;
ATTACH DATABASE '$ARCHIVE_DB' AS archive;

BEGIN IMMEDIATE;

-- Copy referenced project rows (INSERT OR IGNORE — projects may already exist)
INSERT OR IGNORE INTO archive.project (${project_insert_columns})
SELECT ${project_select_columns} FROM project p
WHERE p.id IN (SELECT DISTINCT project_id FROM session WHERE id IN ($in_clause));

-- Copy sessions
INSERT OR IGNORE INTO archive.session (${session_insert_columns})
SELECT ${session_select_columns} FROM session WHERE id IN ($in_clause);

-- Copy messages
${message_copy_sql}

-- Copy parts
${part_copy_sql}

-- Copy todos
${todo_copy_sql}

-- Copy session_shares
${share_copy_sql}

-- Copy OpenCode 1.18.3 session-owned rows when present.
${session_message_copy_sql}
${session_input_copy_sql}
${context_epoch_copy_sql}

-- Copy session-inbox generation rows (session_inbox, session_pending,
-- instruction_entry, instruction_state) when present.
${inbox_copy_sql}

-- Copy event sequence parents before their event rows.
${event_sequence_copy_sql}

-- Copy event stream rows when the active DB has OpenCode's event table.
-- OpenCode stores session-scoped event history with aggregate_id=session.id.
-- This table is often the largest object in opencode.db, so leaving it behind
-- defeats archiving.
${event_copy_sql}

COMMIT;
BEGIN IMMEDIATE;
CREATE TEMP TABLE archive_copy_guard (ok INTEGER CHECK (ok = 1));
${verify_sql}

-- Delete from active (child tables first since FK CASCADE is not enforced)
DELETE FROM part WHERE session_id IN ($in_clause);
DELETE FROM todo WHERE session_id IN ($in_clause);
DELETE FROM session_share WHERE session_id IN ($in_clause);
${session_message_delete_sql}
${session_input_delete_sql}
${context_epoch_delete_sql}
${inbox_delete_sql}
DELETE FROM message WHERE session_id IN ($in_clause);
${event_delete_sql}
${event_sequence_delete_sql}
DELETE FROM session WHERE id IN ($in_clause);

COMMIT;

DETACH DATABASE archive;
BATCH_SQL
		print_error "Archive batch failed or durable copy differs; active rows were not deleted. Retry requires matching archived values."
		return 1
	fi
	return 0
}

_archive_report_batch() {
	# Verify archive integrity after first batch
	if ((first_batch && archive_created)); then
		local integrity
		integrity=$(sqlite3 "$ARCHIVE_DB" "PRAGMA integrity_check;" 2>&1)
		[[ "$integrity" == "ok" ]] || {
			print_error "Archive integrity check FAILED after first batch: $integrity"
			print_error "Aborting. Data was already copied — manual review needed."
			return 1
		}
		first_batch=0
	fi

	local size_current
	size_current=$(file_size_bytes "$ACTIVE_DB")
	local freed=$((size_before - size_current))
	# freed can be negative before vacuum; show 0 in that case
	if ((freed < 0)); then freed=0; fi

	print_info "Archived $archived_total/$total_eligible sessions [batch $batch_num] ($(format_bytes "$freed") freed)"
	if [[ "$ARCHIVE_BATCH_DELAY_SECONDS" != "0" ]]; then
		sleep "$ARCHIVE_BATCH_DELAY_SECONDS"
	fi
	return 0
}

_archive_finish() {
	# Fast-path explicit cleanup: checkpoint archive WAL before vacuum.
	# Marks done so the RETURN trap does not double-run.
	_checkpoint_archive_db "$ARCHIVE_DB"

	local compact_rc=0
	_archive_compact_unless_held || compact_rc=$?
	local archive_quick_check=""
	archive_quick_check=$(sqlite3 "$ARCHIVE_DB" "$SQL_QUICK_CHECK" 2>/dev/null || true)
	if [[ "$archive_quick_check" != "ok" ]]; then
		print_error "Archive DB quick_check failed after archive pass."
		return 1
	fi

	local size_after
	size_after=$(file_size_bytes "$ACTIVE_DB")
	local total_freed=$((size_before - size_after))
	if ((total_freed < 0)); then total_freed=0; fi

	echo ""
	print_success "Archive complete: $archived_total sessions moved"
	print_success "Active DB: $(format_bytes "$size_before") → $(format_bytes "$size_after") ($(format_bytes "$total_freed") freed)"
	print_success "Archive DB: $(format_bytes "$(file_size_bytes "$ARCHIVE_DB")")"
	# Surface large WAL that remains after archiving (active readers may be blocking truncation).
	_check_wal_post_archive "$ACTIVE_DB"
	_ARCHIVE_CLEANUP_ENABLED=0
	trap - EXIT INT TERM
	if [[ "$compact_rc" -ne 0 ]]; then
		return "$compact_rc"
	fi
	return 0
}

# --- Retention and pruning ----------------------------------------------------
# shellcheck source=./opencode-db-archive-retention.sh
# shellcheck disable=SC1091 # sibling module resolved via the entry point directory
source "${_oda_dir}/opencode-db-archive-retention.sh"
# shellcheck source=./opencode-db-archive-worker-events.sh
# shellcheck disable=SC1091 # sibling module resolved via the entry point directory
source "${_oda_dir}/opencode-db-archive-worker-events.sh"

cmd_prune_all() {
	local db rc=0 result=0
	while IFS= read -r -d '' db; do
		print_info "Prune inventory: $db"
		rc=0
		OPENCODE_DB_PATH="$db" OPENCODE_ARCHIVE_DB="${db%/*}/opencode-archive.db" \
			bash "${BASH_SOURCE[0]}" prune "$@" || rc=$?
		# A protected skip is not a failure and must not prevent other DBs running.
		if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then result="$rc"; fi
	done < <(opencode_db_inventory "$ACTIVE_DB")
	return "$result"
}

# --- Stats command ------------------------------------------------------------

cmd_stats() {
	check_sqlite3 || return 1
	check_active_db || return 1

	local now_s
	now_s=$(date +%s)
	local seven_days_ms=$(((now_s - 7 * 86400) * 1000))
	local thirty_days_ms=$(((now_s - 30 * 86400) * 1000))

	echo ""
	echo "=== Active DB: $ACTIVE_DB ==="
	echo "  Size: $(format_bytes "$(file_size_bytes "$ACTIVE_DB")")"

	local session_count msg_count part_count todo_count share_count event_count event_bytes
	session_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session;")
	msg_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM message;")
	part_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM part;")
	todo_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM todo;")
	share_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session_share;")
	event_count=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM event;" 2>/dev/null || echo "0")
	event_bytes=$(sqlite3 "$ACTIVE_DB" "SELECT COALESCE(SUM(LENGTH(data)), 0) FROM event;" 2>/dev/null || echo "0")

	echo "  Sessions:       $session_count"
	echo "  Messages:       $msg_count"
	echo "  Parts:          $part_count"
	echo "  Todos:          $todo_count"
	echo "  Session shares: $share_count"
	echo "  Events:         $event_count ($(format_bytes "$event_bytes"))"

	# Last-update distribution
	local last_7d last_30d older
	last_7d=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $seven_days_ms;")
	last_30d=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $thirty_days_ms AND time_updated < $seven_days_ms;")
	older=$(sqlite3 "$ACTIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated < $thirty_days_ms;")

	echo ""
	echo "  Last-update distribution:"
	echo "    Last 7 days:   $last_7d"
	echo "    7–30 days:     $last_30d"
	echo "    Older than 30: $older"

	if [[ -f "$ARCHIVE_DB" ]]; then
		echo ""
		echo "=== Archive DB: $ARCHIVE_DB ==="
		echo "  Size: $(format_bytes "$(file_size_bytes "$ARCHIVE_DB")")"

		local arch_session arch_msg arch_part arch_todo arch_share arch_event arch_event_bytes
		arch_session=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session;" 2>/dev/null || echo "0")
		arch_msg=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM message;" 2>/dev/null || echo "0")
		arch_part=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM part;" 2>/dev/null || echo "0")
		arch_todo=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM todo;" 2>/dev/null || echo "0")
		arch_share=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session_share;" 2>/dev/null || echo "0")
		arch_event=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM event;" 2>/dev/null || echo "0")
		arch_event_bytes=$(sqlite3 "$ARCHIVE_DB" "SELECT COALESCE(SUM(LENGTH(data)), 0) FROM event;" 2>/dev/null || echo "0")

		echo "  Sessions:       $arch_session"
		echo "  Messages:       $arch_msg"
		echo "  Parts:          $arch_part"
		echo "  Todos:          $arch_todo"
		echo "  Session shares: $arch_share"
		echo "  Events:         $arch_event ($(format_bytes "$arch_event_bytes"))"

		# Last-update distribution in archive
		local arch_7d arch_30d arch_older
		arch_7d=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $seven_days_ms;" 2>/dev/null || echo "0")
		arch_30d=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated >= $thirty_days_ms AND time_updated < $seven_days_ms;" 2>/dev/null || echo "0")
		arch_older=$(sqlite3 "$ARCHIVE_DB" "SELECT COUNT(*) FROM session WHERE time_updated < $thirty_days_ms;" 2>/dev/null || echo "0")

		echo ""
		echo "  Last-update distribution:"
		echo "    Last 7 days:   $arch_7d"
		echo "    7–30 days:     $arch_30d"
		echo "    Older than 30: $arch_older"
	else
		echo ""
		echo "=== Archive DB: (not yet created) ==="
	fi

	echo ""
	return 0
}

# --- Restore command (GH#35492) -------------------------------------------------
# shellcheck source=./opencode-db-archive-restore.sh
# shellcheck disable=SC1091 # sibling module resolved via the entry point directory
source "${_oda_dir}/opencode-db-archive-restore.sh"

# --- Help command -------------------------------------------------------------

cmd_help() {
	cat <<'HELP'
opencode-db-archive.sh — Archive old OpenCode sessions

COMMANDS:
  archive   Move old sessions from active DB to archive DB
  archive-all  Archive selected/default DB and fixed-depth isolated project DBs
  prune     PERMANENTLY delete sessions older than N days from archive then active DB
  prune-all Prune selected/default DB and fixed-depth isolated project DBs
  restore   Move one archived session (and subagent children) back to the active DB
  retention-days  Print storage.opencode_session_retention_days (0 = keep all)
  stats     Show row counts and sizes (active + archive databases)
  help      Show this help message

ARCHIVE OPTIONS (split retention by session origin):
  --worker-retention-days N       Headless sessions inactive N days are archived (default: 7)
                                  Headless = headless-runtime ledger worker sessions and their
                                  subagents, temp-dir one-shot runs, supervisor pulse sessions.
  --interactive-retention-days N  All other sessions inactive N days are archived (default: 30)
  --retention-days N        One cutoff for every session (sets both values above)
  --keep-sessions N         Keep newest N active sessions by last update; archive older sessions beyond the budget
  --dry-run                 Show what would be archived without doing it
  --apply                   Explicitly apply changes (also the legacy default)
  --archive-event-retention-days N  Expire archived event rows for sessions inactive N days
                            (default 7; 0 disables). Keeps session/message/part/todo.
                            Runs before moving sessions; freed pages are reused.
  --events-only             Expire archive events without moving active sessions
  --worker-event-expiry-minutes N  Expire active-DB event rows of ANY session (interactive,
                             worker, subagent) idle N minutes (default 60; 0 disables).
                             Keeps session/message/part/todo, so transcripts stay
                             resumable. Runs even while TUIs hold the DB.
  --worker-events-only      Run only the active-DB event expiry (hourly pass)
  --max-duration-seconds N  Stop after N seconds even when not done (default: 60)

RESTORE OPTIONS:
  --session ID              Session to restore (headless workers do this automatically
                            when resuming a persisted session that was archived)
  --dry-run                 Report what would be restored
  Exit codes: 0 restored/already active, 4 not in archive, 3 incompatible schema

PRUNE OPTIONS (opt-in; default retention is keep everything):
  --older-than-days N       Delete sessions last updated more than N days ago (N >= 1)
  --dry-run                 Preview sessions/bytes (default)
  --apply                   Delete permanently, then VACUUM what the idle checks allow
  --max-duration-seconds N  Per-DB delete budget (default: 60)
  Env AIDEVOPS_OPENCODE_SESSION_RETENTION_DAYS overrides
  storage.opencode_session_retention_days; invalid values mean keep all.

ENVIRONMENT:
  XDG_DATA_HOME             Data root for default DB path (default: ~/.local/share)
  OPENCODE_DB_PATH          Active DB path override used by aidevops/OpenCode helpers
  OPENCODE_DB               Active DB path override (fallback)
  OPENCODE_ARCHIVE_DB       Archive DB path (default: next to active opencode.db)
  OPENCODE_INTERACTIVE_ROOT  Isolated DB root (default: aidevops work/opencode-interactive)
  OPENCODE_DB_ARCHIVE_WORKER_RETENTION_DAYS       Default for --worker-retention-days (7)
  OPENCODE_DB_ARCHIVE_INTERACTIVE_RETENTION_DAYS  Default for --interactive-retention-days (30)
  OPENCODE_DB_HEADLESS_LEDGER  Headless ledger DB (default: headless-runtime/state.db)
  OPENCODE_ARCHIVE_EVENT_RETENTION_DAYS  Archived event expiry, default 7; 0 disables
  OPENCODE_DB_ARCHIVE_EVENT_IDLE_MINUTES  Default for --worker-event-expiry-minutes (60);
                             legacy OPENCODE_DB_ARCHIVE_WORKER_EVENT_MINUTES still honoured
  OPENCODE_DB_EVENT_MAX_BYTES  Event payload ceiling for report/notice/expiry (2 GiB)
  OPENCODE_DB_ARCHIVE_WORKER_EVENT_BATCH_SIZE   Max events per worker-expiry transaction (500)
  OPENCODE_DB_ARCHIVE_WORKER_EVENT_BATCH_BYTES  Max event payload bytes per transaction (64 MiB)
                            archive-all always uses an archive beside each active DB;
                            max-duration-seconds applies per DB, not to the inventory.

EXAMPLES:
  # Show current stats
  opencode-db-archive.sh stats

  # Preview what would be archived (30-day retention)
  opencode-db-archive.sh archive --retention-days 30 --dry-run

  # Keep the 500 most recently updated active sessions, archive older sessions
  opencode-db-archive.sh archive --keep-sessions 500

  # Archive with defaults (workers 7 days, interactive 30 days, 60s budget)
  opencode-db-archive.sh archive

  # Bring an archived session back so OpenCode can resume it
  opencode-db-archive.sh restore --session ses_abc123

  # Archive as pulse pre-flight (short time budget)
  opencode-db-archive.sh archive --max-duration-seconds 30
HELP
	return 0
}

# --- Main dispatch ------------------------------------------------------------

main() {
	local command="${1:-help}"
	local rc=0
	shift || true

	case "$command" in
	archive-all)
		cmd_archive_all "$@" || rc=$?
		;;
	archive)
		cmd_archive "$@" || rc=$?
		;;
	compact-archive)
		_archive_compact_archive_db || rc=$?
		;;
	compact-archives)
		cmd_compact_archives || rc=$?
		;;
	prune)
		cmd_prune "$@" || rc=$?
		;;
	prune-all)
		cmd_prune_all "$@" || rc=$?
		;;
	restore)
		cmd_restore "$@" || rc=$?
		;;
	retention-days)
		cmd_retention_days || rc=$?
		;;
	stats)
		cmd_stats "$@" || rc=$?
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return "$rc"
}

main "$@"
