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
#   - dispatch lock (t19324): pulse_dispatch_lock_split_enabled,
#     pulse_dispatch_lock_publish_mode, acquire_dispatch_lock,
#     release_dispatch_lock, pulse_release_dispatch_lock_on_exit,
#     pulse_dispatch_lock_heartbeat, pulse_dispatch_stage_enter/leave,
#     pulse_run_with_dispatch_lock
#   - _pulse_exit_cleanup      (process-lifetime EXIT handler for main())
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

# Atomic refresh prevents contenders observing a truncated heartbeat and
# falling back to the long-running owner's process age during dispatch.
_pulse_instance_lock_heartbeat() {
	local owner="" temporary=""
	[[ -n "${LOCKDIR:-}" ]] || return 1
	read -r owner 2>/dev/null <"${LOCKDIR}/pid" || return 1
	[[ "$owner" == "$$" ]] && kill -0 "$owner" 2>/dev/null || return 1
	temporary=$(mktemp "${LOCKDIR}/heartbeat.XXXXXX") || return 1
	if date +%s >"$temporary" && read -r owner 2>/dev/null <"${LOCKDIR}/pid" && [[ "$owner" == "$$" ]] &&
		mv -f "$temporary" "${LOCKDIR}/supervisor_heartbeat_epoch"; then
		return 0
	fi
	rm -f "$temporary"
	return 1
}

# Publication and dispatch lease age, bound to the current instance owner.
# Invalid markers fall back to process age; expired leases stay old.
_instance_lock_publication_age() {
	local lock_pid="$1" lock_age="$2"
	local publication_epoch="" owner_pid="" now_epoch=""
	if read -r publication_epoch 2>/dev/null <"${LOCKDIR}/supervisor_heartbeat_epoch" \
		&& [[ "$publication_epoch" =~ ^[1-9][0-9]*$ ]] \
		&& read -r owner_pid 2>/dev/null <"${LOCKDIR}/pid" \
		&& [[ "$owner_pid" == "$lock_pid" ]]; then
		now_epoch=$(date +%s)
		if [[ "$publication_epoch" -le "$now_epoch" ]]; then
			lock_age=$((now_epoch - publication_epoch))
		fi
	fi
	printf '%s\n' "$lock_age"
	return 0
}

#######################################
# Age of an LLM lock hold, from its pid file mtime (written at acquisition).
#
# Returns 1 (caller falls back) when the mtime is unreadable, future-dated,
# or later than the owner's process start + 2s (PID reuse / rewritten file).
#
# Arguments:
#   $1 — pid file path
#   $2 — owner process age in seconds
# Output: hold age in seconds on stdout (only on success)
#######################################
_llm_lock_hold_age() {
	local pid_file="$1"
	local proc_age="$2"
	local mtime="" now_epoch=""
	declare -F _file_mtime_epoch >/dev/null 2>&1 || return 1
	[[ "$proc_age" =~ ^[0-9]+$ ]] || return 1
	mtime=$(_file_mtime_epoch "$pid_file" 2>/dev/null) || return 1
	[[ "$mtime" =~ ^[1-9][0-9]*$ ]] || return 1
	now_epoch=$(date +%s)
	[[ "$mtime" -le "$now_epoch" ]] || return 1
	# Process must have started no later than the pid write (+2s slack).
	[[ $((now_epoch - proc_age)) -le $((mtime + 2)) ]] || return 1
	printf '%s\n' "$((now_epoch - mtime))"
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

	# GH#21433 (t3002): Race-window grace period.
	# acquire_instance_lock writes the PID file AFTER the mkdir succeeds.
	# If we observe LOCKDIR existing but its PID file is empty/missing, the
	# owner may simply be in the brief window between mkdir success and the
	# `echo $$ >LOCKDIR/pid` write. Without this grace period, an empty PID
	# file falls through to the "stale → clear and re-acquire" path below,
	# which destroys a freshly-acquired-but-not-yet-stamped owner's LOCKDIR
	# and lets a second instance acquire its own — yielding two pulses that
	# both believe they hold the singleton lock.
	#
	# Wait briefly (~2s) for the PID to appear before declaring stale.
	# A genuine SIGKILL/OOM-orphaned LOCKDIR will still have an empty PID
	# file after the grace expires; live owners stamp the PID well within
	# this window in practice.
	if [[ -z "$lock_pid" ]]; then
		local _grace=0
		while ((_grace < 20)); do
			# Fractional sleep on BSD/coreutils sleep; fall back to 1s on
			# stripped-down shells without decimal sleep support.
			sleep 0.1 2>/dev/null || sleep 1
			lock_pid=$(_read_lock_pid)
			[[ -n "$lock_pid" ]] && break
			_grace=$((_grace + 1))
		done
		if [[ -n "$lock_pid" ]]; then
			echo "[pulse-wrapper] _handle_existing_lock: PID file appeared after ${_grace} grace iterations (PID ${lock_pid}) — GH#21433 race window observed" >>"$WRAPPER_LOGFILE"
		fi
	fi

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

		# GH#37874: elapsed cycle age is not a hang. Dispatch can fill many
		# waves; reclaim only after its owner heartbeat stops for the ceiling.
		# Legacy/malformed leases fall back to process age (GH#33007).
		lock_age=$(_instance_lock_publication_age "$lock_pid" "$lock_age")
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

	# Tier 1: No valid PID → corrupt/stale, clear immediately
	if [[ -z "$lock_pid" ]] || [[ ! "$lock_pid" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Stale LLM lockdir detected (no valid PID) — clearing (GH#20613)" >>"$WRAPPER_LOGFILE"
		rm -rf "$lockdir" 2>/dev/null || true
		if mkdir "$lockdir" 2>/dev/null; then return 0; fi
		echo "[pulse-wrapper] Lost LLM lock race after stale-lock clear — skipping" >>"$WRAPPER_LOGFILE"
		return 1
	fi

	# Tier 2: Owner PID dead → stale from SIGKILL/OOM, clear
	if ! ps -p "$lock_pid" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Stale LLM lockdir detected (owner PID ${lock_pid} is dead) — clearing (GH#20613)" >>"$WRAPPER_LOGFILE"
		rm -rf "$lockdir" 2>/dev/null || true
		if mkdir "$lockdir" 2>/dev/null; then return 0; fi
		echo "[pulse-wrapper] Lost LLM lock race after stale-lock clear — skipping" >>"$WRAPPER_LOGFILE"
		return 1
	fi

	# Tier 3: Owner alive — check PID reuse + age-based ceiling
	# Use _get_process_age (portable ps-etime) for lock holder age
	local lock_age
	lock_age=$(_get_process_age "$lock_pid")
	local owner_cmd=""
	owner_cmd=$(ps -p "$lock_pid" -o command= 2>/dev/null || echo "")

	# PID reuse guard: if the process is NOT a pulse-wrapper, the original
	# owner died and the PID was recycled by an unrelated process (GH#20025).
	# Reclaim immediately without killing the unrelated process.
	if [[ "$owner_cmd" != *"pulse-wrapper"* ]]; then
		echo "[pulse-wrapper] FORCE-RECLAIMED stale LLM lockdir from PID ${lock_pid} (age ${lock_age}s, owner_cmd='${owner_cmd%%' '*}') — PID reused by non-pulse process (GH#20626)" >>"$WRAPPER_LOGFILE"
		rm -rf "$lockdir" 2>/dev/null || true
		if mkdir "$lockdir" 2>/dev/null; then return 0; fi
		echo "[pulse-wrapper] Lost LLM lock race after PID-reuse reclaim — skipping" >>"$WRAPPER_LOGFILE"
		return 1
	fi

	# The supervisor releases the instance lock before its LLM phase (t2774),
	# so wrapper process age includes the long deterministic phase. Judge the
	# owner by how long it has held the LLM lock (pid file mtime) instead;
	# fall back to the instance lease / process age when that is unusable.
	local llm_lock_age=""
	if llm_lock_age=$(_llm_lock_hold_age "${lockdir}/pid" "$lock_age"); then
		lock_age="$llm_lock_age"
	else
		lock_age=$(_instance_lock_publication_age "$lock_pid" "$lock_age")
	fi
	local max_age="${PULSE_LOCK_MAX_AGE_S:-1800}"
	if [[ "$lock_age" -gt "$max_age" ]]; then
		echo "[pulse-wrapper] FORCE-RECLAIMED stale LLM lockdir (owner PID ${lock_pid}, age ${lock_age}s > ceiling ${max_age}s, owner_cmd='${owner_cmd%%' '*}') — killing hung owner (GH#20613)" >>"$WRAPPER_LOGFILE"
		_kill_tree "$lock_pid" || true
		sleep 2
		if kill -0 "$lock_pid" 2>/dev/null; then
			_force_kill_tree "$lock_pid" || true
		fi
		rm -rf "$lockdir" 2>/dev/null || true
		if mkdir "$lockdir" 2>/dev/null; then return 0; fi
		echo "[pulse-wrapper] Lost LLM lock race after force-reclaim — skipping" >>"$WRAPPER_LOGFILE"
		return 1
	fi

	echo "[pulse-wrapper] LLM session already running (lock held by PID ${lock_pid}, age ${lock_age}s) — skipping" >>"$WRAPPER_LOGFILE"
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
	date +%s >"${LOCKDIR}/supervisor_heartbeat_epoch"
	echo "$$" >"${LOCKDIR}/pid"

	# GH#21433 (t3002): Post-acquisition ownership verification.
	# Defence-in-depth against the mkdir-vs-PID-write race even when the
	# grace period in _handle_existing_lock fails (e.g., grace too short
	# under heavy load, or a non-pulse process touched LOCKDIR/pid). If
	# another instance executed _handle_existing_lock during our PID-write
	# window — saw the empty PID file, exhausted its grace period, removed
	# our LOCKDIR, mkdir-recreated it, and stamped its own PID — then the
	# file we just wrote was either re-overwritten by them or sits inside
	# their LOCKDIR. Re-read after a brief settle and verify the file still
	# contains $$. If not, the other instance won; abandon this attempt
	# and exit without removing LOCKDIR (we don't own it any more).
	sleep 0.2 2>/dev/null || sleep 1
	local _verify_pid
	_verify_pid=$(cat "${LOCKDIR}/pid" 2>/dev/null || echo "")
	if [[ "$_verify_pid" != "$$" ]]; then
		echo "[pulse-wrapper] Lock verification failed — LOCKDIR/pid contains '${_verify_pid:-empty}' instead of $$ — another instance won the race, exiting (GH#21433)" >>"$WRAPPER_LOGFILE"
		# Do NOT remove LOCKDIR — the other instance owns it now.
		# Leave _LOCK_OWNED=false so release_instance_lock is a no-op.
		return 1
	fi

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
# Dispatch lock (t19324, GH#40112; parent GH#40108)
#
# PULSE_DISPATCH_LOCK_SPLIT=1 gives dispatch rounds their own runner-local
# mkdir lock beside LOCKDIR. Every dispatch round (cycle stages, cycle-final
# drain, active-pulse and early-exit recycle fills, worker-exit refill) takes it, so one
# round runs per runner at a time, while the worker-exit refill no longer
# waits for the instance lock held through the cycle's maintenance stages.
# Default 0: callers run exactly as before and this lock is never created.
#
# Same primitives as the instance lock: mkdir atomicity, PID file plus
# post-acquire verification (GH#21433), stale-owner reclaim (dead owner, PID
# reuse, heartbeat older than PULSE_LOCK_MAX_AGE_S) and owner-checked release
# (GH#20260). No flock (GH#18668). The holder is never killed: a hung cycle
# is reclaimed by the instance lock; a hung refill exits with its stage clamp.
# Nested acquisition in one shell is counted, so only the outermost release
# removes the lock. The PID file names the acquiring shell itself, not $$,
# so a lock left by a killed subshell names a dead PID and is reclaimed.
#######################################
_DISPATCH_LOCK_OWNED="${_DISPATCH_LOCK_OWNED:-false}"
_DISPATCH_LOCK_DEPTH="${_DISPATCH_LOCK_DEPTH:-0}"
_DISPATCH_LOCK_OWNER_PID="${_DISPATCH_LOCK_OWNER_PID:-}"
_DISPATCH_LOCK_HOLDER_PID=""
_DISPATCH_LOCK_SELF_PID=""

# Set _DISPATCH_LOCK_SELF_PID to the calling shell's own PID: $$ names the
# top-level process even inside subshells, and Bash 3.2 has no BASHPID.
# Call directly, never inside $(...), which would report that subshell.
_pulse_dispatch_lock_resolve_self_pid() {
	local self_pid="${BASHPID:-}"
	if [[ ! "$self_pid" =~ ^[0-9]+$ ]]; then
		# shellcheck disable=SC2016 # $PPID must expand in the child sh.
		self_pid=$(exec sh -c 'echo "$PPID"' 2>/dev/null) || self_pid=""
	fi
	[[ "$self_pid" =~ ^[0-9]+$ ]] || self_pid="$$"
	_DISPATCH_LOCK_SELF_PID="$self_pid"
	return 0
}

pulse_dispatch_lockdir() {
	printf '%s\n' "${PULSE_DISPATCH_LOCKDIR:-${LOCKDIR}.dispatch}"
	return 0
}

# Mode published by the latest cycle (see pulse_dispatch_lock_publish_mode).
_pulse_dispatch_lock_mode_file() {
	printf '%s\n' "${PULSE_DISPATCH_LOCK_MODE_FILE:-${LOCKDIR}.dispatch-mode}"
	return 0
}

#######################################
# Return 0 when the dispatch lock split is enabled for this process.
# A cycle reads PULSE_DISPATCH_LOCK_SPLIT. A refill-only run uses it when set,
# otherwise the mode its latest cycle published: worker-exit observers run as
# systemd user services on Linux and do not inherit the Pulse environment, and
# a refill must never skip the instance lock while cycles do not take the
# dispatch lock. Resolved once per process so a stage entered under one mode
# is always left under the same mode.
#######################################
_PULSE_DISPATCH_LOCK_SPLIT_RESOLVED=""

pulse_dispatch_lock_split_enabled() {
	local mode="${PULSE_DISPATCH_LOCK_SPLIT:-}"
	if [[ -z "$_PULSE_DISPATCH_LOCK_SPLIT_RESOLVED" ]]; then
		if [[ -z "$mode" && "${PULSE_REFILL_ONLY:-0}" == "1" ]]; then
			read -r mode 2>/dev/null <"$(_pulse_dispatch_lock_mode_file)" || mode=""
		fi
		_PULSE_DISPATCH_LOCK_SPLIT_RESOLVED=0
		[[ "$mode" == "1" ]] && _PULSE_DISPATCH_LOCK_SPLIT_RESOLVED=1
	fi
	[[ "$_PULSE_DISPATCH_LOCK_SPLIT_RESOLVED" == "1" ]]
	return $?
}

# Publish this cycle's mode for refill-only runs. Call only while holding the
# instance lock, before the first dispatch stage. Atomic replace.
pulse_dispatch_lock_publish_mode() {
	local mode=0 mode_file temporary
	[[ -n "${LOCKDIR:-}" ]] || return 0
	[[ "${PULSE_DISPATCH_LOCK_SPLIT:-0}" == "1" ]] && mode=1
	mode_file=$(_pulse_dispatch_lock_mode_file)
	temporary="${mode_file}.tmp.$$"
	if printf '%s\n' "$mode" >"$temporary" 2>/dev/null && mv -f "$temporary" "$mode_file" 2>/dev/null; then
		return 0
	fi
	rm -f "$temporary" 2>/dev/null || true
	return 0
}

_pulse_dispatch_lock_log() {
	local message="$1"
	printf '[pulse-wrapper] %s\n' "$message" >>"${LOGFILE:-${WRAPPER_LOGFILE:-/dev/null}}" 2>/dev/null || true
	return 0
}

# Recreate the lock directory after a stale owner. Returns 1 on a lost race.
_pulse_dispatch_lock_reclaim() {
	local lockdir="$1"
	local reason="$2"
	_pulse_dispatch_lock_log "Dispatch lock reclaimed: ${reason} (t19324)"
	rm -rf "$lockdir" 2>/dev/null || true
	mkdir "$lockdir" 2>/dev/null && return 0
	_pulse_dispatch_lock_log "Dispatch lock: lost mkdir race after reclaim (t19324)"
	return 1
}

#######################################
# mkdir failed: decide between a live holder (return 1, holder PID in
# _DISPATCH_LOCK_HOLDER_PID) and a stale lock (reclaim, return 0 when won).
#######################################
_handle_existing_dispatch_lock() {
	local lockdir="$1"
	local grace=0 lock_pid owner_cmd heartbeat now_epoch
	local max_age="${PULSE_LOCK_MAX_AGE_S:-1800}"
	read -r lock_pid 2>/dev/null <"${lockdir}/pid" || lock_pid=""
	# GH#21433: the owner may be between mkdir and its PID write.
	while [[ -z "$lock_pid" && "$grace" -lt 20 ]]; do
		sleep 0.1 2>/dev/null || sleep 1
		read -r lock_pid 2>/dev/null <"${lockdir}/pid" || lock_pid=""
		grace=$((grace + 1))
	done
	_DISPATCH_LOCK_HOLDER_PID="$lock_pid"
	if [[ ! "$lock_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$lock_pid" 2>/dev/null; then
		_pulse_dispatch_lock_reclaim "$lockdir" "owner PID ${lock_pid:-unknown} is dead"
		return $?
	fi
	if [[ "$lock_pid" == "$_DISPATCH_LOCK_SELF_PID" ]]; then
		# Not owned by this shell: a pre-exec image of this PID left it.
		_pulse_dispatch_lock_reclaim "$lockdir" "left by an earlier holder with this PID (${lock_pid})"
		return $?
	fi
	owner_cmd=$(ps -p "$lock_pid" -o command= 2>/dev/null || echo "")
	if [[ "$owner_cmd" != *pulse-wrapper* ]]; then
		_pulse_dispatch_lock_reclaim "$lockdir" "PID ${lock_pid} reused by non-pulse process '${owner_cmd%%' '*}'"
		return $?
	fi
	read -r heartbeat 2>/dev/null <"${lockdir}/heartbeat_epoch" || heartbeat=""
	now_epoch=$(date +%s)
	[[ "$max_age" =~ ^[1-9][0-9]*$ ]] || max_age=1800
	if [[ "$heartbeat" =~ ^[1-9][0-9]*$ && "$heartbeat" -le "$now_epoch" ]] &&
		((now_epoch - heartbeat > max_age)); then
		_pulse_dispatch_lock_reclaim "$lockdir" "holder PID ${lock_pid} heartbeat $((now_epoch - heartbeat))s > ceiling ${max_age}s"
		return $?
	fi
	return 1
}

#######################################
# Acquire the dispatch lock without waiting. Re-entrant within one shell.
# Logs the owner PID on every acquire.
# Arguments: $1 - stage label for the log line
# Returns: 0 acquired, 1 held by a live dispatch round (_DISPATCH_LOCK_HOLDER_PID)
#######################################
acquire_dispatch_lock() {
	local stage="${1:-dispatch}"
	local lockdir="" verify_pid=""
	if [[ "$_DISPATCH_LOCK_OWNED" == true ]]; then
		_DISPATCH_LOCK_DEPTH=$((_DISPATCH_LOCK_DEPTH + 1))
		return 0
	fi
	lockdir=$(pulse_dispatch_lockdir)
	_DISPATCH_LOCK_HOLDER_PID=""
	_pulse_dispatch_lock_resolve_self_pid
	if ! mkdir "$lockdir" 2>/dev/null; then
		_handle_existing_dispatch_lock "$lockdir" || return 1
	fi
	date +%s >"${lockdir}/heartbeat_epoch" 2>/dev/null || true
	printf '%s\n' "$stage" >"${lockdir}/stage" 2>/dev/null || true
	echo "$_DISPATCH_LOCK_SELF_PID" >"${lockdir}/pid"
	# GH#21433: verify that no contender replaced the directory meanwhile.
	sleep 0.2 2>/dev/null || sleep 1
	read -r verify_pid 2>/dev/null <"${lockdir}/pid" || verify_pid=""
	if [[ "$verify_pid" != "$_DISPATCH_LOCK_SELF_PID" ]]; then
		_DISPATCH_LOCK_HOLDER_PID="$verify_pid"
		_pulse_dispatch_lock_log "Dispatch lock verification failed: pid file names '${verify_pid:-empty}', not ${_DISPATCH_LOCK_SELF_PID} (t19324)"
		return 1
	fi
	_DISPATCH_LOCK_OWNED=true
	_DISPATCH_LOCK_DEPTH=1
	_DISPATCH_LOCK_OWNER_PID="$_DISPATCH_LOCK_SELF_PID"
	_pulse_dispatch_lock_log "Dispatch lock acquired: owner_pid=${_DISPATCH_LOCK_OWNER_PID} stage=${stage} (t19324)"
	return 0
}

#######################################
# Release one level of the dispatch lock; the outermost release removes it
# when LOCKDIR.dispatch/pid still names this process (GH#20260). Idempotent.
#######################################
release_dispatch_lock() {
	local lockdir="" lock_pid=""
	[[ "$_DISPATCH_LOCK_OWNED" == true ]] || return 0
	if [[ "$_DISPATCH_LOCK_DEPTH" =~ ^[0-9]+$ && "$_DISPATCH_LOCK_DEPTH" -gt 1 ]]; then
		_DISPATCH_LOCK_DEPTH=$((_DISPATCH_LOCK_DEPTH - 1))
		return 0
	fi
	local owner_pid="$_DISPATCH_LOCK_OWNER_PID"
	_DISPATCH_LOCK_OWNED=false
	_DISPATCH_LOCK_DEPTH=0
	_DISPATCH_LOCK_OWNER_PID=""
	lockdir=$(pulse_dispatch_lockdir)
	read -r lock_pid 2>/dev/null <"${lockdir}/pid" || lock_pid=""
	if [[ -n "$lock_pid" && "$lock_pid" != "$owner_pid" ]]; then
		_pulse_dispatch_lock_log "release_dispatch_lock: lock now held by PID ${lock_pid}, skipping removal (t19324)"
		return 0
	fi
	rm -rf "$lockdir" 2>/dev/null || true
	return 0
}

#######################################
# Process-exit release: drop every nesting level and remove the lock when it
# names this process. A lock left by a killed subshell names a dead PID and
# is reclaimed by the next contender. Safe when nothing was acquired.
#######################################
pulse_release_dispatch_lock_on_exit() {
	local lockdir="" lock_pid=""
	[[ -n "${LOCKDIR:-}" || -n "${PULSE_DISPATCH_LOCKDIR:-}" ]] || return 0
	_DISPATCH_LOCK_OWNED=false
	_DISPATCH_LOCK_DEPTH=0
	_DISPATCH_LOCK_OWNER_PID=""
	lockdir=$(pulse_dispatch_lockdir)
	[[ -d "$lockdir" ]] || return 0
	read -r lock_pid 2>/dev/null <"${lockdir}/pid" || lock_pid=""
	_pulse_dispatch_lock_resolve_self_pid
	[[ "$lock_pid" == "$_DISPATCH_LOCK_SELF_PID" ]] || return 0
	rm -rf "$lockdir" 2>/dev/null || true
	return 0
}

# Refresh the holder heartbeat during long rounds (atomic replace). Children
# of the holder (command substitutions) inherit ownership and may refresh.
pulse_dispatch_lock_heartbeat() {
	local lockdir owner temporary
	[[ "$_DISPATCH_LOCK_OWNED" == true && -n "$_DISPATCH_LOCK_OWNER_PID" ]] || return 1
	lockdir=$(pulse_dispatch_lockdir)
	read -r owner 2>/dev/null <"${lockdir}/pid" || return 1
	[[ "$owner" == "$_DISPATCH_LOCK_OWNER_PID" ]] || return 1
	temporary=$(mktemp "${lockdir}/heartbeat.XXXXXX" 2>/dev/null) || return 1
	if date +%s >"$temporary" && mv -f "$temporary" "${lockdir}/heartbeat_epoch"; then
		return 0
	fi
	rm -f "$temporary" 2>/dev/null || true
	return 1
}

#######################################
# Enter a dispatch stage. Flag off: always 0, nothing taken. Flag on: take
# the dispatch lock or log the skip and return 1 (another round is already
# dispatching on this runner). Pair every 0 with pulse_dispatch_stage_leave.
# Arguments: $1 - stage label
#######################################
pulse_dispatch_stage_enter() {
	local stage="${1:-dispatch}"
	pulse_dispatch_lock_split_enabled || return 0
	acquire_dispatch_lock "$stage" && return 0
	_pulse_dispatch_lock_log "Dispatch stage ${stage} skipped: dispatch lock held by PID ${_DISPATCH_LOCK_HOLDER_PID:-unknown}, which is already dispatching (t19324)"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "pulse_dispatch_lock_stage_skipped" 2>/dev/null || true
	fi
	return 1
}

pulse_dispatch_stage_leave() {
	pulse_dispatch_lock_split_enabled || return 0
	release_dispatch_lock
	return 0
}

#######################################
# Run one dispatch stage under the dispatch lock (flag on) or directly (flag
# off). A busy lock skips the stage and returns 0.
# Arguments: $1 - stage label; $2... - command and arguments
# Returns: the command's status, or 0 when skipped
#######################################
pulse_run_with_dispatch_lock() {
	local stage="$1"
	shift
	local rc=0
	pulse_dispatch_stage_enter "$stage" || return 0
	"$@" || rc=$?
	pulse_dispatch_stage_leave
	return "$rc"
}

#######################################
# Process-lifetime EXIT handler for pulse-wrapper.sh main() (t18678, GH#34469)
#
# main() installs `trap '_pulse_exit_cleanup' EXIT` before acquiring the
# instance lock. This handler must never move onto the shared function-scoped
# cleanup stack (shared-constants.sh push_cleanup/_run_cleanups): a RETURN
# trap set by a nested helper (e.g. _gh_wrapper_enter_cleanup_scope in the
# gh_* write wrappers) stays installed after that helper returns and fires
# again in its callers, and each fire runs and pops whichever scope is
# current. While this list lived on that stack, a stage calling a gh write
# wrapper ran it mid-cycle: the runtime bundle lease, per-cycle PR list caches
# and benign-block ledger disappeared while the cycle was still running.
#
# Order matches the original direct EXIT trap, with this process's per-cycle
# PR list caches first and the runtime bundle lease last. Every step is
# idempotent and failure-tolerant, so one failing step cannot skip the lock or
# lease release. Subshells reset EXIT traps, so it runs only in the main shell.
#######################################
_PULSE_EXIT_PR_LIST_CACHE_DIR=""
_PULSE_EXIT_PR_LIST_PROVIDER_CACHE_DIR=""

_pulse_exit_cleanup() {
	local cache_dir=""
	for cache_dir in "${_PULSE_EXIT_PR_LIST_CACHE_DIR:-}" "${_PULSE_EXIT_PR_LIST_PROVIDER_CACHE_DIR:-}"; do
		[[ -n "$cache_dir" ]] || continue
		rm -rf -- "$cache_dir" 2>/dev/null || true
	done
	_PULSE_EXIT_PR_LIST_CACHE_DIR=""
	_PULSE_EXIT_PR_LIST_PROVIDER_CACHE_DIR=""
	# GH#37914: the cycle-owned routines ticker ends with its cycle.
	if declare -F _pulse_stop_routines_ticker >/dev/null 2>&1; then
		_pulse_stop_routines_ticker || true
	fi
	_dispatch_cleanup_benign_blocks_cycle || true
	_dispatch_cleanup_cycle_cache || true
	_pulse_release_llm_lock || true
	_pulse_cycle_state_finish_interrupted || true
	_pulse_cycle_index_record_once || true
	_pulse_efficiency_cycle_finish || true
	pulse_release_dispatch_lock_on_exit || true
	release_instance_lock || true
	if declare -F _pulse_finish_post_dispatch_housekeeping >/dev/null 2>&1; then
		_pulse_finish_post_dispatch_housekeeping || true
	fi
	aidevops_runtime_bundle_lease_release || true
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
