#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-instance-lock.sh — Instance lock (mkdir), PID sentinel handling, dedup guard.
#
# Extracted from pulse-wrapper.sh in Phase 1 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# Lock primitive: mkdir atomicity + PID file for stale detection.
# flock was removed in GH#18668 after four recurring deadlock incidents
# (GH#18094 → GH#18141 → GH#18264 → GH#18668) traced to the same root
# cause: bash has no built-in for fcntl(F_SETFD, FD_CLOEXEC), so any
# persistent FD held by the parent is inherited by every daemonising
# descendant. The annotation-based allowlist (`9>&-` on known call
# sites) was a structurally incomplete blocklist. See:
#   reference/bash-fd-locking.md
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _read_lock_pid           (acquire helper: read existing lock PID)
#   - _handle_existing_lock    (acquire helper: live vs stale owner check)
#   - acquire_instance_lock
#   - release_instance_lock
#   - _handle_setup_sentinel
#   - _handle_running_pulse_pid
#   - check_dedup

# Include guard — prevent double-sourcing. pulse-wrapper.sh sources every
# module unconditionally on start, and characterization tests re-source to
# verify idempotency.
[[ -n "${_PULSE_INSTANCE_LOCK_LOADED:-}" ]] && return 0
_PULSE_INSTANCE_LOCK_LOADED=1

#######################################
# Read the existing lock owner's PID from LOCKDIR/pid
#
# Prints the PID to stdout (empty string if the file is absent or
# unreadable). Called by _handle_existing_lock() before any liveness check.
#
# Arguments: none (uses LOCKDIR global)
#######################################
_read_lock_pid() {
	local lock_pid_file="${LOCKDIR}/pid"
	if [[ -f "$lock_pid_file" ]]; then
		cat "$lock_pid_file" 2>/dev/null || echo ""
	else
		echo ""
	fi
	return 0
}

#######################################
# Handle an already-existing lock directory (mkdir failed)
#
# Called by acquire_instance_lock() when the initial mkdir returns non-zero.
# Checks whether the current lock owner is alive:
#   - Alive  → log the conflict and return 1 (genuine concurrent instance).
#   - Dead   → clear the stale lock and attempt to re-acquire via mkdir.
#              Returns 0 on success, 1 if another instance won the race.
#
# Arguments: none (uses LOCKDIR, WRAPPER_LOGFILE globals)
# Returns: 0 if lock re-acquired, 1 if a live owner holds the lock
#######################################
_handle_existing_lock() {
	local lock_pid
	lock_pid=$(_read_lock_pid)

	if [[ -n "$lock_pid" ]] && [[ "$lock_pid" =~ ^[0-9]+$ ]] && ps -p "$lock_pid" >/dev/null 2>&1; then
		# Lock owner PID is alive — but is it actually a pulse-wrapper?
		# GH#20025 Phase C: PID reuse guard + age-based force-reclaim.
		local lock_age
		lock_age=$(_get_process_age "$lock_pid")
		local owner_cmd=""
		owner_cmd=$(ps -p "$lock_pid" -o command= 2>/dev/null || echo "")

		# Check 1: PID reuse — if the process is NOT a pulse-wrapper,
		# the original owner died and the PID was reused by an unrelated
		# process. Reclaim immediately.
		if [[ "$owner_cmd" != *"pulse-wrapper"* ]]; then
			echo "[pulse-wrapper] FORCE-RECLAIMED stale lock from PID ${lock_pid} (age ${lock_age}s, owner_cmd='${owner_cmd%%' '*}') — PID reused by non-pulse process (GH#20025)" >>"$WRAPPER_LOGFILE"
			rm -rf "$LOCKDIR" 2>/dev/null || true
			if ! mkdir "$LOCKDIR" 2>/dev/null; then
				echo "[pulse-wrapper] Lost mkdir lock race after PID-reuse reclaim" >>"$WRAPPER_LOGFILE"
				return 1
			fi
			return 0
		fi

		# Check 2: Age-based force-reclaim — if a genuine pulse-wrapper
		# has been holding the lock for longer than PULSE_LOCK_MAX_AGE_S
		# (default 1800s = 30min), it is hung. A healthy pulse cycle
		# completes in <5 min; 30+ min means the process is stuck.
		# Kill the stuck owner and reclaim.
		local max_age="${PULSE_LOCK_MAX_AGE_S:-1800}"
		if [[ "$lock_age" -gt "$max_age" ]]; then
			echo "[pulse-wrapper] FORCE-RECLAIMED stale lock from PID ${lock_pid} (age ${lock_age}s > ceiling ${max_age}s, owner_cmd='${owner_cmd%%' '*}') — killing hung owner (GH#20025)" >>"$WRAPPER_LOGFILE"
			_kill_tree "$lock_pid" || true
			sleep 2
			if kill -0 "$lock_pid" 2>/dev/null; then
				_force_kill_tree "$lock_pid" || true
			fi
			rm -rf "$LOCKDIR" 2>/dev/null || true
			if ! mkdir "$LOCKDIR" 2>/dev/null; then
				echo "[pulse-wrapper] Lost mkdir lock race after age-ceiling reclaim" >>"$WRAPPER_LOGFILE"
				return 1
			fi
			return 0
		fi

		# Lock owner is genuinely alive and within time limits
		echo "[pulse-wrapper] Another pulse instance holds the mkdir lock (PID ${lock_pid}, age ${lock_age}s, LOCKDIR=${LOCKDIR}) — exiting immediately (GH#4513)" >>"$WRAPPER_LOGFILE"
		return 1
	fi

	# Lock owner is dead (SIGKILL, power loss, OOM) — stale lock.
	# Remove and re-acquire atomically. If two instances race here,
	# only one will succeed at the mkdir below.
	echo "[pulse-wrapper] Stale mkdir lock detected (owner PID ${lock_pid:-unknown} is dead) — clearing and re-acquiring" >>"$WRAPPER_LOGFILE"
	rm -rf "$LOCKDIR" 2>/dev/null || true

	if ! mkdir "$LOCKDIR" 2>/dev/null; then
		# Another instance won the race to re-acquire
		echo "[pulse-wrapper] Lost mkdir lock race after stale-lock clear — another instance acquired it first" >>"$WRAPPER_LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Handle stale LLM session lockdir (GH#20613)
#
# The LLM lockdir (LOCKDIR.llm) gates LLM dispatch so only one session
# runs at a time without blocking the deterministic 2-min cycle. Unlike
# the main instance lock, it had no stale-lock detection — a process
# killed mid-LLM-session (SIGKILL, OOM, crash) left a stale lockdir
# that permanently blocked all subsequent LLM dispatch. Observed: 6-day
# outage, 876 blocked invocations, manual rm -rf required to recover.
#
# Three-tier detection mirroring _handle_existing_lock():
#   1. No valid PID → corrupt/stale, clear immediately
#   2. Owner PID dead → stale from SIGKILL/OOM, clear
#   3. Owner alive but age > PULSE_LOCK_MAX_AGE_S → hung, kill + clear
#
# Arguments:
#   $1 — path to the LLM lockdir
# Returns: 0 if lock was reclaimed and re-acquired, 1 otherwise
#######################################
_handle_stale_llm_lock() {
	local lockdir="$1"
	local lock_pid=""
	if [[ -f "${lockdir}/pid" ]]; then
		lock_pid=$(cat "${lockdir}/pid" 2>/dev/null || echo "")
	fi

	if [[ -z "$lock_pid" ]] || [[ ! "$lock_pid" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Stale LLM lockdir detected (no valid PID) — clearing (GH#20613)" >>"$LOGFILE"
		rm -rf "$lockdir" 2>/dev/null || true
		if mkdir "$lockdir" 2>/dev/null; then return 0; fi
		echo "[pulse-wrapper] Lost LLM lock race after stale-lock clear — skipping" >>"$LOGFILE"
		return 1
	fi

	if ! ps -p "$lock_pid" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Stale LLM lockdir detected (owner PID ${lock_pid} is dead) — clearing (GH#20613)" >>"$LOGFILE"
		rm -rf "$lockdir" 2>/dev/null || true
		if mkdir "$lockdir" 2>/dev/null; then return 0; fi
		echo "[pulse-wrapper] Lost LLM lock race after stale-lock clear — skipping" >>"$LOGFILE"
		return 1
	fi

	# Owner is alive — check age-based ceiling
	local lock_age=0
	local lock_mtime
	lock_mtime=$(stat -c '%Y' "$lockdir" 2>/dev/null || echo "0")
	if [[ "$lock_mtime" -gt 0 ]]; then
		lock_age=$(( $(date +%s) - lock_mtime ))
	fi
	local max_age="${PULSE_LOCK_MAX_AGE_S:-1800}"
	if [[ "$lock_age" -gt "$max_age" ]]; then
		echo "[pulse-wrapper] FORCE-RECLAIMED stale LLM lockdir (owner PID ${lock_pid}, age ${lock_age}s > ceiling ${max_age}s) — killing hung owner (GH#20613)" >>"$LOGFILE"
		kill "$lock_pid" 2>/dev/null || true
		sleep 2
		if kill -0 "$lock_pid" 2>/dev/null; then
			kill -9 "$lock_pid" 2>/dev/null || true
		fi
		rm -rf "$lockdir" 2>/dev/null || true
		if mkdir "$lockdir" 2>/dev/null; then return 0; fi
		echo "[pulse-wrapper] Lost LLM lock race after force-reclaim — skipping" >>"$LOGFILE"
		return 1
	fi

	echo "[pulse-wrapper] LLM session already running (lock held by PID ${lock_pid}, age ${lock_age}s) — skipping" >>"$LOGFILE"
	return 1
}

#######################################
# Acquire an exclusive instance lock using mkdir atomicity (GH#4513)
#
# mkdir is the ONLY lock primitive. flock was removed in GH#18668 after
# recurring deadlocks — see module header and reference/bash-fd-locking.md
# for the full rationale.
#
# mkdir is POSIX-guaranteed atomic on all local filesystems — the kernel
# ensures only one process succeeds even under concurrent invocations.
# No TOCTOU race is possible. Works identically on macOS APFS/HFS+ and
# Linux ext4/btrfs/xfs without util-linux.
#
# When mkdir fails (lock already held), delegates to _handle_existing_lock()
# which distinguishes a live owner (return 1) from a dead/stale one
# (clear + re-acquire). See that function for the detailed logic.
#
# Returns: 0 if lock acquired, 1 if another instance holds the lock
#######################################
acquire_instance_lock() {
	if ! mkdir "$LOCKDIR" 2>/dev/null; then
		_handle_existing_lock || return 1
	fi

	# Write our PID into the lock directory for stale-lock detection
	echo "$$" >"${LOCKDIR}/pid"

	echo "[pulse-wrapper] Instance lock acquired via mkdir (PID $$)" >>"$WRAPPER_LOGFILE"

	# GH#18264: mark that this process owns the lock so release_instance_lock()
	# only cleans up when we actually hold it.
	_LOCK_OWNED=true
	return 0
}

#######################################
# Release the instance lock (mkdir-based)
#
# Called by the EXIT trap to ensure the lock directory is removed
# on normal exit and SIGTERM. SIGKILL cannot be trapped — the
# stale-lock detection in acquire_instance_lock() handles that case.
#
# Safe to call multiple times (idempotent).
#
# GH#20260: two-layer safety prevents removing another instance's lock
# after a voluntary pre-LLM release:
#   1. _LOCK_OWNED=false is set BEFORE the rm so the EXIT trap is a
#      guaranteed no-op when called after the voluntary release.
#   2. PID ownership is verified against LOCKDIR/pid — if another
#      instance acquired the lock between the voluntary release and the
#      EXIT trap, its PID will differ from $$ and we skip the removal.
#######################################
release_instance_lock() {
	# GH#18264: only release the lock when this process actually acquired it.
	# _LOCK_OWNED is set to true by acquire_instance_lock() on success.
	# This prevents the EXIT trap from removing LOCKDIR when the lock was
	# never acquired (e.g., another instance was already running).
	[[ "$_LOCK_OWNED" == "true" ]] || return 0

	# GH#20260: Reset _LOCK_OWNED BEFORE the rm so the EXIT trap is a
	# guaranteed no-op after a voluntary pre-LLM release (run_cycle line
	# ~1327). Without this reset, a second call from the EXIT trap would
	# see _LOCK_OWNED=true and remove a LOCKDIR now owned by a new instance.
	_LOCK_OWNED=false

	# GH#20260: Verify PID ownership before removing — between a voluntary
	# release and process exit, another instance may have acquired LOCKDIR.
	# Only remove if LOCKDIR/pid still contains our own PID ($$).
	local _lock_pid_file="${LOCKDIR}/pid"
	if [[ -f "$_lock_pid_file" ]]; then
		local _current_lock_pid
		_current_lock_pid=$(cat "$_lock_pid_file" 2>/dev/null || echo "")
		if [[ -n "$_current_lock_pid" ]] && [[ "$_current_lock_pid" != "$$" ]]; then
			echo "[pulse-wrapper] release_instance_lock: LOCKDIR reacquired by PID ${_current_lock_pid} — skipping removal (PID $$ already released) (GH#20260)" >>"$WRAPPER_LOGFILE"
			return 0
		fi
	fi

	rm -rf "$LOCKDIR" 2>/dev/null || true
	return 0
}

#######################################
# Handle SETUP sentinel in PID file (GH#5627, extracted from check_dedup)
#
# SETUP sentinel (t1482): another wrapper is running pre-flight stages
# (cleanup, prefetch). The instance lock already prevents true concurrency,
# so if we got past acquire_instance_lock, the SETUP wrapper is dead or
# we ARE that wrapper.
#
# Arguments:
#   $1 - pid_content (the raw SETUP:NNN string from the PID file)
# Exit codes:
#   0 - safe to proceed (sentinel handled)
#   1 - should not happen (fallthrough)
#######################################
_handle_setup_sentinel() {
	local pid_content="$1"
	local setup_pid="${pid_content#SETUP:}"

	# Numeric validation — corrupt sentinel gets reset (GH#4575)
	if ! [[ "$setup_pid" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] check_dedup: invalid SETUP sentinel '${pid_content}' — resetting to IDLE" >>"$LOGFILE"
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi
	if [[ "$setup_pid" == "$$" ]]; then
		# We wrote this ourselves — proceed
		return 0
	fi

	# Check if the process is still alive via its cmdline (GH#4575)
	local setup_cmd=""
	setup_cmd=$(ps -p "$setup_pid" -o command= 2>/dev/null || echo "")

	if [[ -z "$setup_cmd" ]]; then
		echo "[pulse-wrapper] check_dedup: SETUP wrapper $setup_pid is dead — proceeding" >>"$LOGFILE"
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi

	# PID reuse guard: verify the process is actually a pulse-wrapper
	# before killing. PID reuse can assign the old PID to an unrelated
	# process between cycles. (GH#4575)
	if [[ "$setup_cmd" != *"pulse-wrapper.sh"* ]]; then
		echo "[pulse-wrapper] check_dedup: SETUP PID $setup_pid belongs to non-wrapper process ('${setup_cmd%%' '*}'); refusing kill, resetting sentinel" >>"$LOGFILE"
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi
	# SETUP wrapper is alive but we hold the instance lock — it's a zombie
	# from a previous cycle. Kill it and proceed.
	echo "[pulse-wrapper] check_dedup: killing zombie SETUP wrapper $setup_pid" >>"$LOGFILE"
	_kill_tree "$setup_pid" || true
	sleep 1
	if kill -0 "$setup_pid" 2>/dev/null; then
		_force_kill_tree "$setup_pid" || true
	fi
	echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
	return 0
}

#######################################
# Handle a live numeric PID in the PID file (GH#5627, extracted from check_dedup)
#
# Checks if the process is stale (exceeds threshold) and kills it,
# or reports genuine dedup (another pulse is legitimately running).
#
# Arguments:
#   $1 - old_pid (numeric PID from the PID file)
# Exit codes:
#   0 - safe to proceed (process was dead or stale and killed)
#   1 - genuine dedup (another pulse is running within limits)
#######################################
_handle_running_pulse_pid() {
	local old_pid="$1"

	# Check if the process is still running
	if ! ps -p "$old_pid" >/dev/null 2>&1; then
		# Process is dead — write IDLE sentinel so the file is never absent
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi

	# Process is running — check how long
	local elapsed_seconds
	elapsed_seconds=$(_get_process_age "$old_pid")

	if [[ "$elapsed_seconds" -gt "$PULSE_STALE_THRESHOLD" ]]; then
		# Process has been running too long — it's stuck.
		# Guard kill commands with || true so set -e doesn't abort cleanup
		# if the target process has already exited between checks.
		echo "[pulse-wrapper] Killing stale pulse process $old_pid (running ${elapsed_seconds}s, threshold ${PULSE_STALE_THRESHOLD}s)" >>"$LOGFILE"
		_kill_tree "$old_pid" || true
		sleep 2
		# Force kill if still alive
		if kill -0 "$old_pid" 2>/dev/null; then
			_force_kill_tree "$old_pid" || true
		fi
		# Write IDLE sentinel — never leave the file absent (GH#4324)
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 0
	fi

	# Underfill is now intelligence-managed by the pulse session itself.
	# Do not recycle running pulse processes based only on elapsed time while
	# underfilled — that creates churn loops and suppresses transcript analysis.
	local max_workers active_workers deficit_pct
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	deficit_pct=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		deficit_pct=$(((max_workers - active_workers) * 100 / max_workers))
		echo "[pulse-wrapper] Underfilled ${active_workers}/${max_workers} (${deficit_pct}%) but preserving active pulse PID $old_pid for transcript-driven decisions" >>"$LOGFILE"
	fi

	# Process is running and within time limit — genuine dedup
	echo "[pulse-wrapper] Pulse already running (PID $old_pid, ${elapsed_seconds}s elapsed). Skipping." >>"$LOGFILE"
	return 1
}

#######################################
# Check for stale PID file and clean up
# Returns: 0 if safe to proceed, 1 if another pulse is genuinely running
#
# PID file sentinel protocol (GH#4324):
#   The PID file is never deleted — only overwritten. Valid states:
#     <numeric PID>  — a pulse may be running; verify with ps
#     IDLE:<ts>      — last run completed normally; safe to proceed
#     empty / other  — treat as safe to proceed (first run or corrupt)
#######################################
check_dedup() {
	if [[ ! -f "$PIDFILE" ]]; then
		return 0
	fi

	local pid_content
	pid_content=$(cat "$PIDFILE" 2>/dev/null || echo "")

	# Empty file or IDLE sentinel — safe to proceed (GH#4324)
	if [[ -z "$pid_content" ]] || [[ "$pid_content" == IDLE:* ]]; then
		return 0
	fi

	# SETUP sentinel — delegate to helper
	if [[ "$pid_content" == SETUP:* ]]; then
		_handle_setup_sentinel "$pid_content"
		return $?
	fi

	# Non-numeric content (corrupt/unknown) — safe to proceed
	local old_pid="$pid_content"
	if ! [[ "$old_pid" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] check_dedup: unrecognised PID file content '${old_pid}' — treating as idle" >>"$LOGFILE"
		return 0
	fi

	# Self-detection (t1482): if the PID file contains our own PID, we wrote
	# it in a previous code path (e.g., early PID write at main() entry).
	# Never block on ourselves.
	if [[ "$old_pid" == "$$" ]]; then
		return 0
	fi

	# Delegate live PID handling (stale check, dedup)
	_handle_running_pulse_pid "$old_pid"
	return $?
}
