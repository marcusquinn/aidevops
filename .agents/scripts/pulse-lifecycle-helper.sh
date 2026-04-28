#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Lifecycle Helper (t2579) — canonical start/stop/restart management
# =============================================================================
# The pulse is a long-running bash process that sources framework scripts at
# startup. Deploying updated scripts to ~/.aidevops/agents/scripts/ does NOT
# affect a running pulse — it keeps using the old code in memory. This helper
# is the single source of truth for pulse lifecycle operations.
#
# Subcommands:
#   is-running              Exit 0 if any pulse PID alive, 1 otherwise.
#   status                  Print pulse PIDs + uptime (informational).
#   start                   Start pulse in background (no-op if already running).
#   stop                    Stop all pulse instances (SIGTERM, then SIGKILL).
#   restart                 Force stop + start.
#   restart-if-running      No-op if pulse not running, otherwise stop + start.
#                           Used by setup.sh and aidevops update.
#
# Env:
#   AIDEVOPS_SKIP_PULSE_RESTART=1     Skip restart operations (for debug).
#   AIDEVOPS_PULSE_RESTART_WAIT=3     Seconds between stop and start (default 3).
#   AIDEVOPS_PULSE_SIGTERM_WAIT=2     Seconds before escalating to SIGKILL.
#
# Exit codes:
#   0  Success (includes no-op cases)
#   1  Pulse not running (is-running only)
#   2  Invalid subcommand or missing pulse-wrapper.sh
#   3  status: multiple pulse PIDs detected (singleton violation, GH#21433)
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# Paths
_PULSE_AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-${HOME}/.aidevops/agents}"
_PULSE_SCRIPT="${_PULSE_AGENTS_DIR}/scripts/pulse-wrapper.sh"
_PULSE_LOG="${HOME}/.aidevops/logs/pulse-wrapper.log"

# Process-match pattern for pgrep. The production default matches any
# pulse-wrapper.sh script regardless of path. Tests may override this to
# isolate mock pulses from the live user pulse (the mock's path is embedded
# in the pattern). See tests/test-pulse-lifecycle-helper.sh.
_PULSE_PATTERN="${AIDEVOPS_PULSE_PROCESS_PATTERN:-(^|/)pulse-wrapper\\.sh( |\$)}"

# Timing
_PULSE_RESTART_WAIT="${AIDEVOPS_PULSE_RESTART_WAIT:-3}"
_PULSE_SIGTERM_WAIT="${AIDEVOPS_PULSE_SIGTERM_WAIT:-2}"

# ANSI colors (guarded — don't collide with shared-constants)
[[ -z "${_PL_GREEN+x}" ]] && _PL_GREEN='\033[0;32m'
[[ -z "${_PL_BLUE+x}" ]] && _PL_BLUE='\033[0;34m'
[[ -z "${_PL_YELLOW+x}" ]] && _PL_YELLOW='\033[1;33m'
[[ -z "${_PL_RED+x}" ]] && _PL_RED='\033[0;31m'
[[ -z "${_PL_NC+x}" ]] && _PL_NC='\033[0m'

_pl_info() {
	local _msg="$1"
	printf '%b[INFO]%b %s\n' "$_PL_BLUE" "$_PL_NC" "$_msg"
	return 0
}

_pl_ok() {
	local _msg="$1"
	printf '%b[OK]%b %s\n' "$_PL_GREEN" "$_PL_NC" "$_msg"
	return 0
}

_pl_warn() {
	local _msg="$1"
	printf '%b[WARN]%b %s\n' "$_PL_YELLOW" "$_PL_NC" "$_msg" >&2
	return 0
}

_pl_err() {
	local _msg="$1"
	printf '%b[ERROR]%b %s\n' "$_PL_RED" "$_PL_NC" "$_msg" >&2
	return 0
}

# _pulse_pids: print all pulse PIDs (one per line). Empty output = none running.
_pulse_pids() {
	pgrep -f "$_PULSE_PATTERN" 2>/dev/null || true
	return 0
}

# _is_running: exit 0 if any pulse PID alive, 1 otherwise.
_is_running() {
	local _pids
	_pids=$(_pulse_pids)
	[[ -n "$_pids" ]]
}

# _stop_all: terminate every pulse PID. SIGTERM first, escalate to SIGKILL
# if any survive after _PULSE_SIGTERM_WAIT seconds. Idempotent.
_stop_all() {
	local _pids
	_pids=$(_pulse_pids)
	if [[ -z "$_pids" ]]; then
		return 0
	fi

	_pl_info "Stopping pulse instance(s): $(echo "$_pids" | tr '\n' ' ')"
	# SIGTERM: allow graceful shutdown (release locks, write state).
	# pkill returns 0 if any matched, 1 if none — ignore both.
	pkill -TERM -f "$_PULSE_PATTERN" 2>/dev/null || true
	sleep "$_PULSE_SIGTERM_WAIT"

	# Escalate if any survived.
	local _survivors
	_survivors=$(_pulse_pids)
	if [[ -n "$_survivors" ]]; then
		_pl_warn "SIGTERM timeout, escalating to SIGKILL: $(echo "$_survivors" | tr '\n' ' ')"
		pkill -KILL -f "$_PULSE_PATTERN" 2>/dev/null || true
		sleep 1
	fi

	# Final check.
	if _is_running; then
		_pl_err "Failed to stop pulse after SIGKILL — residual PIDs: $(_pulse_pids | tr '\n' ' ')"
		return 1
	fi
	return 0
}

# _start: launch pulse in background via nohup. No-op if already running.
_start() {
	if _is_running; then
		_pl_info "Pulse already running (PIDs: $(_pulse_pids | tr '\n' ' '))"
		return 0
	fi

	if [[ ! -x "$_PULSE_SCRIPT" ]]; then
		_pl_err "pulse-wrapper.sh not found or not executable: $_PULSE_SCRIPT"
		return 2
	fi

	mkdir -p "${_PULSE_LOG%/*}"

	# t2994: cache priming moved into pulse-wrapper.sh::main() with a
	# staleness gate. The original t2992 hook here never fired under
	# launchd-managed pulse on macOS because launchd's KeepAlive
	# auto-respawns inside this helper's stop→sleep→start window, so
	# _start's _is_running early-return skipped priming entirely. The
	# in-pulse hook fires regardless of how pulse boots (manual restart,
	# launchd respawn, aidevops update, setup.sh ensure-running).

	# GH#20580: set AIDEVOPS_PULSE_SOURCE so pulse-wrapper.sh records this
	# invocation as "lifecycle-helper" in its invocation_sources counter.
	AIDEVOPS_PULSE_SOURCE=lifecycle-helper nohup "$_PULSE_SCRIPT" >>"$_PULSE_LOG" 2>&1 &
	disown 2>/dev/null || true

	# Give nohup a moment to fork and let pulse-wrapper emit its startup banner.
	sleep 1

	if _is_running; then
		_pl_ok "Pulse started (PID: $(_pulse_pids | head -1))"
		return 0
	fi
	_pl_err "Pulse failed to start — check $_PULSE_LOG"
	return 1
}

# _restart: force stop + start. Honours AIDEVOPS_SKIP_PULSE_RESTART env opt-out.
_restart() {
	if [[ "${AIDEVOPS_SKIP_PULSE_RESTART:-0}" == "1" ]]; then
		_pl_info "AIDEVOPS_SKIP_PULSE_RESTART=1 — skipping pulse restart"
		return 0
	fi

	_stop_all || return $?
	sleep "$_PULSE_RESTART_WAIT"
	_start
}

# _restart_if_running: canonical entry point for update/deploy flows.
# No-op if pulse isn't running (user hasn't enabled it yet, or has it stopped).
# Otherwise full stop + start to pick up fresh code.
_restart_if_running() {
	if [[ "${AIDEVOPS_SKIP_PULSE_RESTART:-0}" == "1" ]]; then
		_pl_info "AIDEVOPS_SKIP_PULSE_RESTART=1 — skipping pulse restart-if-running"
		return 0
	fi

	if ! _is_running; then
		# Not running — nothing to restart. Silent success.
		return 0
	fi

	_pl_info "Restarting pulse to load updated scripts..."
	_stop_all || return $?
	sleep "$_PULSE_RESTART_WAIT"
	_start
}

# _status: human-readable PID + age. Reports lock-holder PID and warns when
# multiple pulse PIDs are alive simultaneously — the singleton invariant
# (GH#4513, GH#21433) requires exactly one. Multiple PIDs indicate a race
# escaped the lock (e.g., trap-cleanup vs launchd respawn vs lifecycle-helper
# concurrent start) and operator intervention is needed.
_status() {
	local _pids
	_pids=$(_pulse_pids)
	if [[ -z "$_pids" ]]; then
		printf 'Pulse: not running\n'
		return 0
	fi

	# Count PIDs (newline-separated). Use wc -l + tr to be portable.
	local _pid_count
	_pid_count=$(printf '%s\n' "$_pids" | wc -l | tr -d ' ')
	[[ "$_pid_count" =~ ^[0-9]+$ ]] || _pid_count=0

	printf 'Pulse: running (%s instance%s)\n' "$_pid_count" "$([[ $_pid_count -eq 1 ]] || printf 's')"

	# Read lock-holder PID for cross-reference (GH#21433 acceptance criterion).
	local _lockdir="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
	local _lock_pid=""
	if [[ -f "${_lockdir}/pid" ]]; then
		_lock_pid=$(cat "${_lockdir}/pid" 2>/dev/null || echo "")
	fi
	if [[ -n "$_lock_pid" ]]; then
		printf '  Lock holder PID: %s\n' "$_lock_pid"
	else
		printf '  Lock holder PID: (LOCKDIR/pid missing or empty)\n'
	fi

	local _pid
	while IFS= read -r _pid; do
		local _etime
		_etime=$(ps -p "$_pid" -o etime= 2>/dev/null | tr -d ' ')
		local _marker=""
		[[ "$_pid" == "$_lock_pid" ]] && _marker=" (lock holder)"
		printf '  PID %s%s (uptime %s)\n' "$_pid" "$_marker" "${_etime:-unknown}"
	done <<<"$_pids"

	if [[ "$_pid_count" -gt 1 ]]; then
		_pl_warn "MULTIPLE pulse instances detected (GH#21433) — singleton invariant violated"
		_pl_warn "Recommendation: $(basename "$0") restart    # full stop+start to recover"
		# Exit non-zero so callers (scripts, monitoring) can detect the anomaly.
		return 3
	fi
	return 0
}

_usage() {
	cat <<'EOF'
Usage: pulse-lifecycle-helper.sh <command>

Commands:
  is-running            Exit 0 if pulse running, 1 if not.
  status                Print running PIDs and uptime.
  start                 Start pulse (no-op if already running).
  stop                  Stop all pulse instances.
  restart               Force stop + start.
  restart-if-running    Restart only if running; no-op otherwise.

Env:
  AIDEVOPS_SKIP_PULSE_RESTART=1     Skip restart operations.
  AIDEVOPS_PULSE_RESTART_WAIT=3     Seconds between stop and start.
  AIDEVOPS_PULSE_SIGTERM_WAIT=2     Seconds before escalating to SIGKILL.
  AIDEVOPS_AGENTS_DIR=<path>        Override ~/.aidevops/agents.

Exit codes:
  0  Success
  1  Pulse not running (is-running only) / pulse failed to start
  2  Invalid subcommand or missing pulse-wrapper.sh
  3  status: multiple pulse PIDs detected (singleton violation, GH#21433)
EOF
	return 0
}

main() {
	local _cmd="${1:-}"
	case "$_cmd" in
	is-running)
		_is_running && exit 0 || exit 1
		;;
	status)
		_status
		;;
	start)
		_start
		;;
	stop)
		_stop_all
		;;
	restart)
		_restart
		;;
	restart-if-running)
		_restart_if_running
		;;
	-h | --help | help | "")
		_usage
		exit 0
		;;
	*)
		_pl_err "Unknown command: $_cmd"
		_usage
		exit 2
		;;
	esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
