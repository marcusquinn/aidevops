#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-routines-tick.sh — cycle-owned routines ticker (GH#37914).
#
# Routines are evaluated at full-cycle start and by the GH#35349 busy pass,
# which runs only when another Pulse invocation loses the instance lock. On
# launchd (and systemd timers) the running cycle IS the scheduled job, so no
# second invocation starts while it runs and long cycles skipped calendar
# slots. The cycle now owns a small child loop that runs the same
# routines-only pass (_pulse_run_routines_while_busy) every tick until the
# cycle process exits, so routine timing no longer depends on cycle length.
#
# Duplicate-start safety is unchanged: evaluate_routines_locked serializes
# every evaluator through routines.lockdir, and runner locks plus last_run
# slot state stop a second start for one slot.
#
# Sourced by pulse-wrapper.sh; never executed directly.
#
# Config:
#   AIDEVOPS_PULSE_ROUTINES_TICK=0          disable the ticker
#   AIDEVOPS_PULSE_ROUTINES_TICK_SECONDS=N  tick interval (default 60)
#   AIDEVOPS_PULSE_BUSY_ROUTINES=0          disables the pass itself

[[ -n "${_PULSE_ROUTINES_TICK_LOADED:-}" ]] && return 0
_PULSE_ROUTINES_TICK_LOADED=1
_PULSE_ROUTINES_TICKER_PID=""
_PULSE_ROUTINES_TICKER_OWNER=""
_PULSE_ROUTINES_TICK_STOP=0

#######################################
# Print the validated tick interval in seconds (default 60).
#######################################
_pulse_routines_tick_interval() {
	local interval="${AIDEVOPS_PULSE_ROUTINES_TICK_SECONDS:-60}"
	[[ "$interval" =~ ^[1-9][0-9]{0,4}$ ]] || interval=60
	printf '%s\n' "$interval"
	return 0
}

#######################################
# Set _PULSE_ROUTINES_SELF_PID to the real PID of the calling shell (Bash 3.2
# has no BASHPID, so $$ would be the cycle PID inside subshells). Sets a global
# rather than printing, since command substitution would change BASHPID.
#######################################
_pulse_routines_self_pid() {
	local pid="${BASHPID:-}"
	if [[ -z "$pid" ]]; then
		pid="$(exec sh -c 'printf "%s" "$PPID"')" || return 1
	fi
	[[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
	_PULSE_ROUTINES_SELF_PID="$pid"
	return 0
}

#######################################
# Ticker body: sleep one interval, then run the routines-only pass while the
# owning cycle process is alive and no stop flag exists. TERM/INT/HUP end the
# loop after the in-flight pass, so a routine start is never cut in half.
# Args: $1=owner (cycle) PID, $2=interval seconds
#######################################
_pulse_routines_ticker_loop() {
	local owner_pid="$1"
	local interval="$2"
	local sleep_pid=""
	_PULSE_ROUTINES_TICK_STOP=0
	trap '_PULSE_ROUTINES_TICK_STOP=1' TERM INT HUP
	while [[ "$_PULSE_ROUTINES_TICK_STOP" == "0" ]]; do
		sleep "$interval" &
		sleep_pid=$!
		wait "$sleep_pid" 2>/dev/null || true
		kill "$sleep_pid" 2>/dev/null || true
		[[ "$_PULSE_ROUTINES_TICK_STOP" == "0" ]] || break
		kill -0 "$owner_pid" 2>/dev/null || break
		[[ -z "${STOP_FLAG:-}" || ! -f "$STOP_FLAG" ]] || break
		_pulse_run_routines_while_busy "cycle-tick" || true
	done
	return 0
}

#######################################
# Start the ticker as a child of the cycle process (idempotent). It stays in
# the cycle's process group, so a launchd/systemd job teardown also ends it.
# The child never owns the instance lock, cycle heartbeat or EXIT cleanup and
# is not clamped by the cycle budget: it must keep ticking in long cycles.
#######################################
_pulse_start_routines_ticker() {
	[[ "${AIDEVOPS_PULSE_ROUTINES_TICK:-1}" == "1" ]] || return 0
	[[ "${PULSE_DRY_RUN:-0}${PULSE_CANARY_MODE:-0}" == "00" ]] || return 0
	declare -F _pulse_run_routines_while_busy >/dev/null 2>&1 || return 0
	if [[ "${_PULSE_ROUTINES_TICKER_PID:-}" =~ ^[1-9][0-9]*$ ]] &&
		kill -0 "$_PULSE_ROUTINES_TICKER_PID" 2>/dev/null; then
		return 0
	fi
	local owner_pid=""
	_pulse_routines_self_pid || return 0
	owner_pid="$_PULSE_ROUTINES_SELF_PID"
	local interval=""
	interval=$(_pulse_routines_tick_interval)
	# Separate log: stage lines written to the supervisor LOGFILE would count
	# as watchdog progress and mask a stalled supervisor.
	local tick_log="${PULSE_ROUTINES_TICK_LOG:-${HOME}/.aidevops/logs/pulse-routines-tick.log}"
	mkdir -p "${tick_log%/*}" 2>/dev/null || true
	(
		trap - EXIT
		LOGFILE="$tick_log"
		# shellcheck disable=SC2034 # read by sourced stage/lock helpers
		AIDEVOPS_PULSE_STAGE_CYCLE_CLAMP=0
		# shellcheck disable=SC2034 # read by sourced stage/lock helpers
		_LOCK_OWNED=false
		_pulse_routines_ticker_loop "$owner_pid" "$interval"
	) </dev/null >>"$tick_log" 2>&1 &
	_PULSE_ROUTINES_TICKER_PID=$!
	_PULSE_ROUTINES_TICKER_OWNER="$owner_pid"
	echo "[pulse-wrapper] Routines ticker: started pid=${_PULSE_ROUTINES_TICKER_PID} interval=${interval}s (GH#37914)" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# Ask the ticker to stop. Does not wait: an in-flight pass finishes on its
# own under routines.lockdir. Safe to call when no ticker runs; only the
# owning cycle process stops it, never an inherited subshell copy.
#######################################
_pulse_stop_routines_ticker() {
	local ticker_pid="${_PULSE_ROUTINES_TICKER_PID:-}"
	[[ "$ticker_pid" =~ ^[1-9][0-9]*$ ]] || return 0
	_pulse_routines_self_pid || return 0
	[[ "${_PULSE_ROUTINES_TICKER_OWNER:-}" == "$_PULSE_ROUTINES_SELF_PID" ]] || return 0
	_PULSE_ROUTINES_TICKER_PID=""
	kill -TERM "$ticker_pid" 2>/dev/null || true
	return 0
}
