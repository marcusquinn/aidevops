#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# opencode-db-archive-async-helper.sh — Async background OpenCode DB archive runner (GH#21105).
#
# Designed to be invoked via nohup from _preflight_cleanup_and_ledger in
# pulse-dispatch-engine.sh so the up-to-30s archive budget never blocks the
# pulse's main dispatch cycle.
#
# Background (GH#21105):
#   The synchronous call `opencode-db-archive.sh archive --max-duration-seconds 30`
#   was consuming its full 30s time budget every preflight cycle, contributing
#   ~30s to the parent stage's 60-133s total. Archiving is catch-up work — it
#   does not need to complete within a single pulse cycle. Mirroring the
#   cleanup-worktrees-async-helper.sh pattern (GH#20554) moves the workload
#   off the critical path while preserving correctness.
#
# Lifecycle:
#   1. Acquire a mkdir-based single-runner lock (~/.aidevops/logs/opencode-db-archive.lock).
#   2. Check cadence gate: skip if last successful run < N minutes ago.
#   3. Invoke opencode-db-archive.sh archive with the configured budget.
#   4. Update ~/.aidevops/logs/opencode-db-archive.last-run on success.
#   5. Release lock on EXIT/INT/TERM (trap).
#
# Usage (from pulse-dispatch-engine.sh):
#   nohup "${SCRIPT_DIR}/opencode-db-archive-async-helper.sh" \
#     >>"${HOME}/.aidevops/logs/opencode-db-archive.log" 2>&1 &
#   disown $! 2>/dev/null || true
#
# Environment:
#   OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN — min minutes between runs (default 10)
#   OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC  — seconds per run (default 60; was 30 inline)
#
# Observability (for pulse-diagnose-helper.sh):
#   ~/.aidevops/logs/opencode-db-archive.log      — progress log
#   ~/.aidevops/logs/opencode-db-archive.last-run — epoch of last successful run
#   ~/.aidevops/logs/opencode-db-archive.lock/    — lock dir (present = running)
#   ~/.aidevops/logs/opencode-db-archive.lock/pid — PID of holder

set -euo pipefail

# ============================================================
# PATHS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${HOME}/.aidevops/logs"
readonly LOGFILE="${LOG_DIR}/opencode-db-archive.log"
readonly LOCK_DIR="${LOG_DIR}/opencode-db-archive.lock"
readonly PID_FILE="${LOCK_DIR}/pid"
readonly LAST_RUN_FILE="${LOG_DIR}/opencode-db-archive.last-run"
readonly ARCHIVE_HELPER="${SCRIPT_DIR}/opencode-db-archive.sh"

# Minimum minutes between successful runs. The async wrapper can be invoked
# every pulse cycle (~3 min) but only actually runs every CADENCE minutes.
OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN="${OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN:-10}"
OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN="${OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN//[!0-9]/}"
[[ -n "$OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN" ]] || OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN=10

# Per-run time budget. Larger than the inline 30s default — async runs are not
# on the critical path, so we let each invocation make more progress.
OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC="${OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC:-60}"
OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC="${OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC//[!0-9]/}"
[[ -n "$OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC" ]] || OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC=60

mkdir -p "$LOG_DIR"

# ============================================================
# LOCK MANAGEMENT (mkdir-based — POSIX atomic, macOS-safe)
# ============================================================

_lock_release() {
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	return 0
}

# Check whether the PID that holds the lock is still alive.
# Uses kill -0 (existence) + ps comm= (command-aware, guards against PID reuse).
# Returns 0 if alive, 1 if dead or indeterminate.
_is_pid_alive() {
	local pid="$1"
	[[ -z "$pid" ]] && return 1
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1

	if ! kill -0 "$pid" 2>/dev/null; then
		return 1
	fi

	local comm
	comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
	if [[ -z "$comm" ]]; then
		return 1
	fi

	return 0
}

# Attempt to acquire the lock directory. On success, writes PID file and
# registers a trap. Returns 1 (skip this run) if another live instance holds
# the lock. Reclaims the lock if the holder PID is dead (crash recovery).
_lock_acquire() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"$PID_FILE" 2>/dev/null || true
		# shellcheck disable=SC2064
		trap "_lock_release" EXIT INT TERM
		return 0
	fi

	if [[ -f "$PID_FILE" ]]; then
		local lock_pid
		lock_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
		if [[ -n "$lock_pid" ]] && ! _is_pid_alive "$lock_pid"; then
			echo "[opencode-db-archive-async] Reclaiming stale lock (PID ${lock_pid} no longer alive)" >>"$LOGFILE"
			rm -rf "$LOCK_DIR" 2>/dev/null || true
			if mkdir "$LOCK_DIR" 2>/dev/null; then
				printf '%s\n' "$$" >"$PID_FILE" 2>/dev/null || true
				# shellcheck disable=SC2064
				trap "_lock_release" EXIT INT TERM
				return 0
			fi
		fi
	fi

	return 1
}

# ============================================================
# CADENCE GATE
# ============================================================

# Returns 0 (proceed) if enough time has elapsed since the last successful run.
# Returns 1 (skip) if we are within the cadence window.
_cadence_ok() {
	if [[ ! -f "$LAST_RUN_FILE" ]]; then
		return 0
	fi

	local last_run now elapsed cadence_secs
	last_run=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "0")
	if ! [[ "$last_run" =~ ^[0-9]+$ ]]; then
		return 0
	fi

	now=$(date +%s)
	elapsed=$((now - last_run))
	cadence_secs=$((OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN * 60))

	if [[ "$elapsed" -lt "$cadence_secs" ]]; then
		echo "[opencode-db-archive-async] Cadence gate: last run ${elapsed}s ago (threshold ${cadence_secs}s). Skipping." >>"$LOGFILE"
		return 1
	fi

	return 0
}

_update_last_run() {
	date +%s >"$LAST_RUN_FILE" 2>/dev/null || true
	return 0
}

# ============================================================
# MAIN
# ============================================================

main() {
	echo "[opencode-db-archive-async] PID=$$ starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOGFILE"

	if [[ ! -x "$ARCHIVE_HELPER" ]]; then
		echo "[opencode-db-archive-async] ERROR: $ARCHIVE_HELPER not found or not executable — skipping" >>"$LOGFILE"
		return 0
	fi

	if ! _lock_acquire; then
		echo "[opencode-db-archive-async] Lock held by live instance — skipping this invocation" >>"$LOGFILE"
		return 0
	fi

	if ! _cadence_ok; then
		return 0
	fi

	echo "[opencode-db-archive-async] Starting archive (budget=${OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC}s, cadence=${OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN}m)" >>"$LOGFILE"

	local rc=0
	"$ARCHIVE_HELPER" archive --max-duration-seconds "$OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC" >>"$LOGFILE" 2>&1 || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		_update_last_run
		echo "[opencode-db-archive-async] Completed successfully at $(date -u '+%Y-%m-%dT%H:%M:%SZ'). last-run updated." >>"$LOGFILE"
	else
		echo "[opencode-db-archive-async] archive exited with rc=${rc} — last-run NOT updated" >>"$LOGFILE"
	fi

	return 0
}

main "$@"
