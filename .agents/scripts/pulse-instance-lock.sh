#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-instance-lock.sh — Instance lock (mkdir + flock), PID sentinel handling, dedup guard.
#
# Extracted from pulse-wrapper.sh in Phase 1 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - acquire_instance_lock
#   - release_instance_lock
#   - _handle_setup_sentinel
#   - _handle_running_pulse_pid
#   - check_dedup
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing. pulse-wrapper.sh sources every
# module unconditionally on start, and characterization tests re-source to
# verify idempotency.
[[ -n "${_PULSE_INSTANCE_LOCK_LOADED:-}" ]] && return 0
_PULSE_INSTANCE_LOCK_LOADED=1

#######################################
# Acquire an exclusive instance lock using mkdir atomicity (GH#4513)
#
# Primary defense against concurrent pulse instances on macOS and Linux.
# mkdir is POSIX-guaranteed atomic — the kernel ensures only one process
# succeeds even under concurrent invocations. No TOCTOU race is possible.
#
# The lock directory (LOCKDIR) contains a PID file so stale locks from
# SIGKILL or power loss can be detected and cleared on the next startup.
# A trap registered by the caller releases the lock on normal exit and
# SIGTERM. SIGKILL cannot be trapped — the stale-lock detection handles
# that case on the next invocation.
#
# On Linux with util-linux flock available, flock is used as an additional
# layer on the LOCKFILE (FD 9) for belt-and-suspenders protection. The
# mkdir guard is the primary atomic primitive; flock is supplementary.
#
# Returns: 0 if lock acquired, 1 if another instance holds the lock
#######################################
acquire_instance_lock() {
	# Step 1: mkdir-based atomic lock (primary — works on macOS and Linux)
	if ! mkdir "$LOCKDIR" 2>/dev/null; then
		# Lock directory already exists — check if the owning process is alive
		local lock_pid=""
		local lock_pid_file="${LOCKDIR}/pid"
		if [[ -f "$lock_pid_file" ]]; then
			lock_pid=$(cat "$lock_pid_file" 2>/dev/null || echo "")
		fi

		if [[ -n "$lock_pid" ]] && [[ "$lock_pid" =~ ^[0-9]+$ ]] && ps -p "$lock_pid" >/dev/null 2>&1; then
			# Lock owner is alive — genuine concurrent instance
			local lock_age
			lock_age=$(_get_process_age "$lock_pid")
			echo "[pulse-wrapper] Another pulse instance holds the mkdir lock (PID ${lock_pid}, age ${lock_age}s) — exiting immediately (GH#4513)" >>"$WRAPPER_LOGFILE"
			return 1
		fi

		# Lock owner is dead (SIGKILL, power loss, OOM) — stale lock
		# Remove and re-acquire atomically. If two instances race here,
		# only one will succeed at the mkdir below.
		echo "[pulse-wrapper] Stale mkdir lock detected (owner PID ${lock_pid:-unknown} is dead) — clearing and re-acquiring" >>"$WRAPPER_LOGFILE"
		rm -rf "$LOCKDIR" 2>/dev/null || true

		if ! mkdir "$LOCKDIR" 2>/dev/null; then
			# Another instance won the race to re-acquire
			echo "[pulse-wrapper] Lost mkdir lock race after stale-lock clear — another instance acquired it first" >>"$WRAPPER_LOGFILE"
			return 1
		fi
	fi

	# Write our PID into the lock directory for stale-lock detection
	echo "$$" >"${LOCKDIR}/pid"

	# Step 2: flock as supplementary layer on Linux (belt-and-suspenders)
	# flock is not available on macOS without util-linux — skip silently.
	if command -v flock &>/dev/null; then
		if ! flock -n 9 2>/dev/null; then
			# flock says another instance holds it — diagnose and attempt recovery
			# (GH#18141: Layer 1 diagnostic + Layer 2 inode self-recovery)
			local flock_holder_pid flock_holder_cmd flock_holder_comm
			local bounce_file bounce_count
			flock_holder_pid=$(fuser "$LOCKFILE" 2>/dev/null | tr -d ' ')
			flock_holder_cmd=$(ps -p "$flock_holder_pid" -o args= 2>/dev/null | head -c 120)
			flock_holder_comm=$(ps -p "$flock_holder_pid" -o comm= 2>/dev/null)

			# Track consecutive bounces in a file so we can detect sustained deadlocks
			bounce_file="${HOME}/.aidevops/logs/pulse-flock-bounce-count"
			bounce_count=0
			[[ -f "$bounce_file" ]] && bounce_count=$(cat "$bounce_file" 2>/dev/null || echo "0")
			[[ "$bounce_count" =~ ^[0-9]+$ ]] || bounce_count=0
			bounce_count=$((bounce_count + 1))
			echo "$bounce_count" >"$bounce_file"

			echo "[pulse-wrapper] flock secondary guard: held by PID ${flock_holder_pid:-unknown} (${flock_holder_cmd:-unknown}), bounce ${bounce_count}" >>"$WRAPPER_LOGFILE"

			# Update deadlock health state for pulse-health.json (GH#18141: Layer 3)
			_PULSE_HEALTH_DEADLOCK_DETECTED=true
			_PULSE_HEALTH_DEADLOCK_HOLDER_PID="${flock_holder_pid:-unknown}"
			_PULSE_HEALTH_DEADLOCK_HOLDER_CMD="${flock_holder_cmd:-unknown}"
			_PULSE_HEALTH_DEADLOCK_BOUNCES="$bounce_count"

			# GH#18141: Layer 2 — inode recreation self-recovery after 3+ bounces
			# when the holder is NOT a pulse-wrapper/bash process.
			# Safety: we hold the mkdir lock (primary guard), so no concurrency hole.
			# The orphaned child's flock on the old (now unlinked) inode becomes
			# a lock on nothing — POSIX guarantees unlink+open creates a new inode.
			if ((bounce_count >= 3)) &&
				[[ -n "$flock_holder_comm" ]] &&
				[[ "$flock_holder_comm" != "bash" ]] &&
				[[ "$flock_holder_comm" != "pulse-wrapper" ]] &&
				[[ "$flock_holder_comm" != "pulse-wrapper.sh" ]]; then
				echo "[pulse-wrapper] Deadlock detected: flock held by non-pulse process PID ${flock_holder_pid:-unknown} (${flock_holder_cmd:-unknown}) for ${bounce_count} consecutive bounces — attempting inode recovery" >>"$WRAPPER_LOGFILE"
				exec 9>&-          # close our FD to the old inode
				rm -f "$LOCKFILE"  # unlink old inode (orphan keeps its FD)
				exec 9>"$LOCKFILE" # create new file at same path = new inode
				if flock -n 9 2>/dev/null; then
					echo "[pulse-wrapper] Deadlock recovery successful — acquired flock on new inode after ${bounce_count} bounces" >>"$WRAPPER_LOGFILE"
					echo "0" >"$bounce_file"
					_PULSE_HEALTH_DEADLOCK_RECOVERED=true
					# Fall through to success path below
				else
					echo "[pulse-wrapper] Deadlock recovery failed — flock still contested after inode recreation, releasing mkdir lock and exiting" >>"$WRAPPER_LOGFILE"
					rm -rf "$LOCKDIR" 2>/dev/null || true
					return 1
				fi
			else
				# Holder is a pulse process or bounce threshold not yet met — normal exit
				rm -rf "$LOCKDIR" 2>/dev/null || true
				return 1
			fi
		else
			# Successful flock acquisition — reset the bounce counter
			local bounce_file
			bounce_file="${HOME}/.aidevops/logs/pulse-flock-bounce-count"
			[[ -f "$bounce_file" ]] && echo "0" >"$bounce_file"
		fi
		echo "[pulse-wrapper] Instance lock acquired via mkdir+flock (PID $$)" >>"$WRAPPER_LOGFILE"
	else
		# yeah, mkdir atomicity is sufficient on macOS without flock
		echo "[pulse-wrapper] Instance lock acquired via mkdir (PID $$, flock not available on this platform)" >>"$WRAPPER_LOGFILE"
	fi

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
#######################################
release_instance_lock() {
	# GH#18264: only release the lock when this process actually acquired it.
	# _LOCK_OWNED is set to true by acquire_instance_lock() on success.
	# This prevents the EXIT trap from removing LOCKDIR when the lock was
	# never acquired (e.g., another instance was already running).
	[[ "$_LOCK_OWNED" == "true" ]] || return 0
	# exec 9>&- closes FD 9 in the current (parent) bash process, releasing the
	# flock so the next pulse cycle can acquire it immediately.
	exec 9>&- 2>/dev/null || true
	rm -rf "$LOCKDIR" 2>/dev/null || true
	return 0
} # nice — idempotent cleanup

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
