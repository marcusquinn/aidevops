#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Watchdog Tick (t2939) — independent revival of dead pulse
# =============================================================================
# Runs every 60s via the sh.aidevops.pulse-watchdog launchd job. Independent
# of the pulse plist itself — survives `aidevops update` plist regeneration.
#
# Layered defense:
#   Layer 1 (pulse plist KeepAlive=<dict><SuccessfulExit=false>): launchd
#     auto-restarts pulse on crash within seconds, but on clean exit the
#     StartInterval (default 600s) governs the next launch.
#   Layer 2 (this script): if pulse has been dead longer than
#     (StartInterval + grace), revive it. Catches the "clean exit + lost
#     launchd schedule" failure mode (system sleep/wake races, plist drift,
#     race during plist reload, OOM-kill misclassified as success, etc.).
#
# Idempotence: cheap. If pulse is alive, this script exits 0 with no work.
# If pulse is dead but within the grace window, also exit 0 (let launchd's
# own StartInterval fire it). Only invokes pulse-lifecycle-helper.sh start
# when the gap exceeds the grace period — preserves user's pulse-interval
# tuning for GraphQL rate-limit conservation.
#
# Env:
#   AIDEVOPS_PULSE_WATCHDOG_GRACE     Seconds beyond StartInterval to wait
#                                     before reviving (default: 120)
#   AIDEVOPS_PULSE_WATCHDOG_DISABLE=1 Disable the watchdog (no-op exit 0)
#   AIDEVOPS_AGENTS_DIR=<path>        Override ~/.aidevops/agents
#
# Exit codes:
#   0  Always (even on revival failure — log and continue, not fail).
#
# Part of aidevops framework: https://aidevops.sh

set -uo pipefail

# Honour explicit disable flag (debugging / maintenance windows).
if [[ "${AIDEVOPS_PULSE_WATCHDOG_DISABLE:-0}" == "1" ]]; then
	exit 0
fi

_AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-${HOME}/.aidevops/agents}"
_LIFECYCLE_HELPER="${_AGENTS_DIR}/scripts/pulse-lifecycle-helper.sh"
_LOG_DIR="${HOME}/.aidevops/logs"
_WATCHDOG_LOG="${_LOG_DIR}/pulse-watchdog.log"
_LAST_RUN_FILE="${_LOG_DIR}/pulse-wrapper-last-run.ts"
_SETTINGS_FILE="${HOME}/.config/aidevops/settings.json"

mkdir -p "$_LOG_DIR" 2>/dev/null || true

_wd_log() {
	local _msg="$1"
	printf '[%s] [pulse-watchdog] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_msg" >>"$_WATCHDOG_LOG" 2>/dev/null || true
	return 0
}

# Resolve the configured pulse interval from settings.json (default 180s).
# Mirrors _read_pulse_interval_seconds in setup-modules/schedulers.sh.
# Reads orchestration.pulse_interval_seconds canonically; falls back to
# supervisor.pulse_interval_seconds for legacy settings.json files (t2946).
_read_pulse_interval() {
	local _interval=180
	if command -v jq >/dev/null 2>&1 && [[ -f "$_SETTINGS_FILE" ]]; then
		local _raw
		_raw=$(jq -r '.orchestration.pulse_interval_seconds // .supervisor.pulse_interval_seconds // empty' "$_SETTINGS_FILE" 2>/dev/null) || _raw=""
		if [[ -n "$_raw" && "$_raw" =~ ^[0-9]+$ ]]; then
			_interval="$_raw"
		fi
	fi
	# Clamp to validated range (mirrors settings-helper.sh: 30-3600)
	if [[ "$_interval" -lt 30 ]]; then
		_interval=30
	elif [[ "$_interval" -gt 3600 ]]; then
		_interval=3600
	fi
	printf '%d' "$_interval"
	return 0
}

# Bail early if the lifecycle helper is missing — nothing to revive with.
if [[ ! -x "$_LIFECYCLE_HELPER" ]]; then
	_wd_log "lifecycle-helper missing or non-executable: $_LIFECYCLE_HELPER"
	exit 0
fi

# Fast path: pulse alive → no work.
if "$_LIFECYCLE_HELPER" is-running >/dev/null 2>&1; then
	exit 0
fi

# Pulse is dead. Decide whether to revive based on age vs grace window.
_INTERVAL=$(_read_pulse_interval)
_GRACE="${AIDEVOPS_PULSE_WATCHDOG_GRACE:-120}"
# Validate grace is numeric; fall back to 120 on bad input.
if ! [[ "$_GRACE" =~ ^[0-9]+$ ]]; then
	_GRACE=120
fi
_THRESHOLD=$((_INTERVAL + _GRACE))

_LAST_RUN=0
if [[ -f "$_LAST_RUN_FILE" ]]; then
	_raw_ts=$(tr -d '[:space:]' <"$_LAST_RUN_FILE" 2>/dev/null) || _raw_ts=""
	if [[ "$_raw_ts" =~ ^[0-9]+$ ]]; then
		_LAST_RUN="$_raw_ts"
	fi
fi

_NOW=$(date +%s)
_AGE=$((_NOW - _LAST_RUN))

# If we have no last-run record, treat as "very old" — revive immediately.
# This catches first-boot and post-clean-install scenarios where the watchdog
# fires before the pulse has ever recorded a timestamp.
if [[ "$_LAST_RUN" -eq 0 ]]; then
	_wd_log "no last-run timestamp — reviving pulse"
	"$_LIFECYCLE_HELPER" start >>"$_WATCHDOG_LOG" 2>&1 || _wd_log "revival exit=$?"
	exit 0
fi

# Within grace window — let launchd's own StartInterval fire on its schedule.
if [[ "$_AGE" -lt "$_THRESHOLD" ]]; then
	exit 0
fi

# Past grace window — revive.
_wd_log "pulse dead for ${_AGE}s (threshold ${_THRESHOLD}s = interval ${_INTERVAL} + grace ${_GRACE}) — reviving"
"$_LIFECYCLE_HELPER" start >>"$_WATCHDOG_LOG" 2>&1 || _wd_log "revival exit=$?"
exit 0
