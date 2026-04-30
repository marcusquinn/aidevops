#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# idle-state-stuck.sh — Detect stale SETUP marker in pulse.pid (t3072).
#
# Reads $PID_FILE (default ~/.aidevops/logs/pulse.pid). If it shows
# `SETUP:<pid>` and that PID is no longer alive, the lifecycle helper
# crashed during pulse setup and never released the marker. This blocks
# all subsequent pulse cycles — the lifecycle treats SETUP as "in flight"
# and refuses to start.
#
# Inputs (env):
#   PID_FILE       default ~/.aidevops/logs/pulse.pid
#   PID_ALIVE_FN   override for tests; if set, called as: $PID_ALIVE_FN <pid>
#                  must exit 0 if alive, non-zero if dead

# shellcheck shell=bash

runtime_audit_id() { printf 'idle-state-stuck\n'; return 0; }

runtime_audit_check() {
	local pid_file="${PID_FILE:-${HOME}/.aidevops/logs/pulse.pid}"
	local alive_fn="${PID_ALIVE_FN:-}"

	if [[ ! -f "$pid_file" ]]; then
		return 0
	fi

	local content
	content=$(cat "$pid_file" 2>/dev/null) || return 0
	# Pattern: "SETUP:<pid>" possibly with trailing whitespace/newline
	if [[ ! "$content" =~ ^SETUP:[0-9]+ ]]; then
		return 0
	fi

	local stuck_pid
	stuck_pid=$(printf '%s\n' "$content" | head -1 | sed -nE 's/^SETUP:([0-9]+).*/\1/p')
	[[ -z "$stuck_pid" ]] && return 0

	# Liveness check
	local alive=0
	if [[ -n "$alive_fn" ]]; then
		"$alive_fn" "$stuck_pid" && alive=1 || alive=0
	else
		kill -0 "$stuck_pid" 2>/dev/null && alive=1 || alive=0
	fi

	if [[ "$alive" == "1" ]]; then
		return 0
	fi

	# Stale: SETUP marker references a dead PID
	local mtime
	mtime=$(_file_mtime_epoch "$pid_file" 2>/dev/null) || mtime=0
	local age=$(( ${NOW_EPOCH:-$(date +%s)} - mtime ))

	local title="runtime-audit: pulse.pid stuck on SETUP:${stuck_pid} (PID dead)"
	local body
	body=$(cat <<MARKDOWN
## Task

\`${pid_file/#$HOME/\~}\` shows \`SETUP:${stuck_pid}\` but PID ${stuck_pid} is no longer alive. The pulse lifecycle helper treats SETUP as "in flight" — until this marker is cleared, no new pulse cycle can start.

## Evidence

\`\`\`
$ cat ${pid_file}
${content}

$ kill -0 ${stuck_pid}
$? = $([[ "$alive" == "1" ]] && echo "0 (alive)" || echo "non-zero (dead)")

PID file age: ${age}s ($(printf '%dh%dm' $((age/3600)) $(((age%3600)/60))))
\`\`\`

## Why

This is the t-equivalent of an idle-state-stuck condition. The supervisor LLM cycle never reads \`pulse.pid\`, so a crash inside the SETUP phase produces a permanently wedged pulse with NO issue, NO log warning, NO surface signal. Operators only notice when they observe that no new dispatches have happened for >${age}s.

## How

1. Confirm the PID is dead: \`kill -0 ${stuck_pid}\` — should return non-zero exit.
2. Inspect what was in flight when SETUP started: \`grep -A 20 "SETUP" ~/.aidevops/logs/pulse-wrapper.log | tail -30\`.
3. Clear the marker: \`echo > ~/.aidevops/logs/pulse.pid\` (or remove the file).
4. Restart pulse: \`pulse-lifecycle-helper.sh start\` (idempotent — no-op if already running, starts cleanly if not).
5. Investigate the SETUP-phase crash. Look at \`pulse-lifecycle-helper.sh\` and \`pulse-wrapper.sh\` for the SETUP path. Likely candidates: a synchronous helper call that hangs, a missing mkdir, a permission error on a write target.

## Acceptance Criteria

1. Pulse back to running with a clean PID line in pulse.pid (no SETUP prefix).
2. Root cause identified for the SETUP crash. Either fixed or filed as a separate task.

## Verification

\`\`\`
cat ~/.aidevops/logs/pulse.pid
# Should show a single integer (the running pulse PID), no "SETUP:" prefix.
~/.aidevops/agents/scripts/pulse-lifecycle-helper.sh status
# Should report "running"
\`\`\`

<!-- aidevops:generator=runtime-audit detector=idle-state-stuck -->
MARKDOWN
)

	jq -n --arg id "idle-state-stuck" --arg title "$title" --arg body "$body" \
		'{id: $id, title: $title, body: $body}'
	return 1
}
