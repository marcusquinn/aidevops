#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# opencode-db-idle-gate-lib.sh — GH#35517 idle gate for archiving a DB that
# OpenCode holds open. `lsof` proves only that a process holds the DB; the
# opencode-aidevops plugin heartbeat (db-activity-heartbeat.mjs) proves whether
# that process has a busy session and when it last did work.
#
# The gate passes only when every holder is an `opencode` process whose
# heartbeat files all report zero busy sessions for the configured quiet
# period, and (where measurable) the user has not touched keyboard/mouse
# recently. Missing, unreadable or foreign evidence always defers.
#
# Environment:
#   OPENCODE_DB_ACTIVITY_DIR                 heartbeat directory
#   OPENCODE_DB_ARCHIVE_IDLE_SECONDS         holder quiet period (default 900)
#   OPENCODE_DB_ARCHIVE_USER_IDLE_SECONDS    user input quiet period (default 1800; 0 disables)
#   OPENCODE_DB_USER_IDLE_COMMAND            override user-idle probe (prints seconds)
#   OPENCODE_DB_PS_COMMAND                   override `ps` (fixtures)

[[ -n "${_OPENCODE_DB_IDLE_GATE_LOADED:-}" ]] && return 0
_OPENCODE_DB_IDLE_GATE_LOADED=1

OPENCODE_DB_IDLE_GATE_REASON=""
OPENCODE_DB_IDLE_GATE_SESSIONS=""
OPENCODE_DB_IDLE_GATE_HOLDERS=0

opencode_db_activity_dir() {
	printf '%s' "${OPENCODE_DB_ACTIVITY_DIR:-${HOME:-}/.aidevops/.agent-workspace/state/opencode-activity}"
	return 0
}

# Print seconds since last user input, or nothing when unmeasurable
# (headless hosts, SSH-only Linux). Callers treat "nothing" as not required.
opencode_db_user_idle_seconds() {
	local idle_ns=""
	local idle_ms=""

	if [[ -n "${OPENCODE_DB_USER_IDLE_COMMAND:-}" ]]; then
		"$OPENCODE_DB_USER_IDLE_COMMAND" 2>/dev/null || true
		return 0
	fi
	if [[ "$(uname -s)" == "Darwin" ]] && command -v ioreg >/dev/null 2>&1; then
		idle_ns=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {gsub(/[^0-9]/, "", $NF); print $NF; exit}')
		if [[ "$idle_ns" =~ ^[0-9]+$ ]]; then
			printf '%s' "$((idle_ns / 1000000000))"
		fi
		return 0
	fi
	if [[ -n "${DISPLAY:-}" ]] && command -v xprintidle >/dev/null 2>&1; then
		idle_ms=$(xprintidle 2>/dev/null || true)
		if [[ "$idle_ms" =~ ^[0-9]+$ ]]; then
			printf '%s' "$((idle_ms / 1000))"
		fi
	fi
	return 0
}

_opencode_db_idle_gate_defer() {
	local reason="$1"
	OPENCODE_DB_IDLE_GATE_REASON="$reason"
	return 2
}

_opencode_db_holder_is_opencode() {
	local pid="$1"
	local comm=""
	comm=$("${OPENCODE_DB_PS_COMMAND:-ps}" -o comm= -p "$pid" 2>/dev/null || true)
	comm="${comm##*/}"
	comm="${comm//[[:space:]]/}"
	[[ "$comm" == "opencode" || "$comm" == ".opencode" ]]
	return $?
}

# Print the epoch a PID started, from portable `ps -o etime=`
# ([[dd-]hh:]mm:ss on macOS and Linux); nothing when unknown.
_opencode_db_holder_start_epoch() {
	local pid="$1"
	local now="$2"
	local etime=""
	local days=0
	local rest=""
	local h=0
	local m=0
	local s=0

	etime=$("${OPENCODE_DB_PS_COMMAND:-ps}" -o etime= -p "$pid" 2>/dev/null || true)
	etime="${etime//[[:space:]]/}"
	[[ "$etime" =~ ^([0-9]+-)?([0-9]+:){1,2}[0-9]+$ ]] || return 0
	if [[ "$etime" == *-* ]]; then
		days="${etime%%-*}"
		rest="${etime#*-}"
	else
		rest="$etime"
	fi
	IFS=: read -r h m s <<<"$rest"
	if [[ -z "$s" ]]; then
		s="$m"
		m="$h"
		h=0
	fi
	printf '%s' "$((now - (10#$days * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s)))"
	return 0
}

# Check every heartbeat file for one holder PID; append its session IDs.
# Files written before the process started belong to an earlier process that
# reused the PID and are ignored, so a plugin-less OpenCode never inherits them.
_opencode_db_holder_heartbeats_idle() {
	local pid="$1"
	local dir="$2"
	local now="$3"
	local quiet_seconds="$4"
	local file=""
	local found=0
	local fields=""
	local hb_pid=""
	local busy=""
	local last=""
	local updated=""
	local sessions=""
	local started=""

	started=$(_opencode_db_holder_start_epoch "$pid" "$now")
	if [[ ! "$started" =~ ^[0-9]+$ ]]; then
		_opencode_db_idle_gate_defer "holder PID ${pid} start time is unknown"
		return 2
	fi
	for file in "$dir/${pid}"-*.json; do
		[[ -f "$file" ]] || continue
		fields=$(jq -r '[(.pid // "" | tostring), (.busy_sessions // "" | tostring), (.last_activity_epoch // "" | tostring), (.updated_epoch // "" | tostring)] | join(" ")' "$file" 2>/dev/null || true)
		read -r hb_pid busy last updated <<<"$fields"
		if [[ "$hb_pid" != "$pid" || ! "$busy" =~ ^[0-9]+$ || ! "$last" =~ ^[0-9]+$ || ! "$updated" =~ ^[0-9]+$ ]]; then
			_opencode_db_idle_gate_defer "holder PID ${pid} heartbeat is unreadable"
			return 2
		fi
		# 2s tolerance: etime and epoch seconds round independently.
		((updated + 2 >= started)) || continue
		found=1
		if ((busy > 0)); then
			_opencode_db_idle_gate_defer "holder PID ${pid} has ${busy} busy session(s)"
			return 2
		fi
		if ((now - last < quiet_seconds)); then
			_opencode_db_idle_gate_defer "holder PID ${pid} was active $((now - last))s ago (need ${quiet_seconds}s)"
			return 2
		fi
		sessions=$(jq -r '.sessions[]? | strings | select(test("^[A-Za-z0-9_-]{1,128}$"))' "$file" 2>/dev/null || true)
		if [[ -n "$sessions" ]]; then
			OPENCODE_DB_IDLE_GATE_SESSIONS="${OPENCODE_DB_IDLE_GATE_SESSIONS}${OPENCODE_DB_IDLE_GATE_SESSIONS:+$'\n'}${sessions}"
		fi
	done
	if ((found == 0)); then
		_opencode_db_idle_gate_defer "holder PID ${pid} has no activity heartbeat"
		return 2
	fi
	return 0
}

# opencode_db_idle_gate <db> [holder_command]
# Return 0 when the DB has no holders or every holder is an idle OpenCode
# process; 2 otherwise. Sets OPENCODE_DB_IDLE_GATE_REASON, _SESSIONS (IDs the
# holders have open; never archive these) and _HOLDERS.
opencode_db_idle_gate() {
	local db="$1"
	local holder_command="${2:-lsof}"
	local quiet_seconds="${OPENCODE_DB_ARCHIVE_IDLE_SECONDS:-900}"
	local user_quiet_seconds="${OPENCODE_DB_ARCHIVE_USER_IDLE_SECONDS:-1800}"
	local pids=""
	local pid=""
	local now=""
	local dir=""
	local user_idle=""

	OPENCODE_DB_IDLE_GATE_REASON=""
	OPENCODE_DB_IDLE_GATE_SESSIONS=""
	OPENCODE_DB_IDLE_GATE_HOLDERS=0
	if [[ ! "$quiet_seconds" =~ ^[0-9]+$ || ! "$user_quiet_seconds" =~ ^[0-9]+$ ]]; then
		_opencode_db_idle_gate_defer "idle gate thresholds are not non-negative integers"
		return 2
	fi
	if ! command -v "$holder_command" >/dev/null 2>&1; then
		_opencode_db_idle_gate_defer "holder state is unavailable"
		return 2
	fi
	pids=$("$holder_command" -t "$db" 2>/dev/null | awk 'NF' | sort -u || true)
	[[ -n "$pids" ]] || return 0
	OPENCODE_DB_IDLE_GATE_HOLDERS=$(printf '%s\n' "$pids" | wc -l | tr -d ' ')
	if ! command -v jq >/dev/null 2>&1; then
		_opencode_db_idle_gate_defer "jq is required to read activity heartbeats"
		return 2
	fi
	if ((user_quiet_seconds > 0)); then
		user_idle=$(opencode_db_user_idle_seconds)
		if [[ "$user_idle" =~ ^[0-9]+$ ]] && ((user_idle < user_quiet_seconds)); then
			_opencode_db_idle_gate_defer "user input ${user_idle}s ago (need ${user_quiet_seconds}s)"
			return 2
		fi
	fi
	dir=$(opencode_db_activity_dir)
	now=$(date +%s)
	while IFS= read -r pid; do
		if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
			_opencode_db_idle_gate_defer "holder state is unreadable"
			return 2
		fi
		if ! _opencode_db_holder_is_opencode "$pid"; then
			_opencode_db_idle_gate_defer "holder PID ${pid} is not an OpenCode process"
			return 2
		fi
		_opencode_db_holder_heartbeats_idle "$pid" "$dir" "$now" "$quiet_seconds" || return 2
	done <<<"$pids"
	return 0
}
