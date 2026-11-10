#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# opencode-session-restart-helper.sh — safe interrupt → maintain → resume for
# long-lived interactive OpenCode TUI sessions (GH#37663).
#
# Interactive TUIs left open for days hold opencode.db, so archive/VACUUM and
# plugin/runtime upgrades never run. This helper:
#   1. inventories interactive holders (session-bus presence `kind: tui`, plus
#      activity heartbeats for DB holders that predate the session bus);
#   2. asks busy sessions over the session bus to checkpoint and pause;
#   3. waits for idle and never signals a busy session;
#   4. stops idle TUIs gracefully (SIGTERM) and records a restart manifest;
#   5. after maintenance, relaunches `opencode -s <id>` in the original
#      tmux/screen pane, or leaves a resume command for bare-TTY sessions.
#
# Authority: stopping is opt-in. A terminal operator confirms (or passes
# --yes). Without a terminal (scheduler, headless agent) the helper only
# notifies owners unless the host config allows unattended restarts.
#
# Usage: opencode-session-restart-helper.sh <command> [options]
#   inventory [--json] [--all]       Interactive holders: pid, session, cwd, age, busy/idle, pane
#   stop [options]                   Checkpoint request → wait idle → SIGTERM idle TUIs → manifest
#   resume                           Relaunch stopped sessions from the manifest
#   run [options] -- <command…>      stop, run the command, then always resume
#   notify [--reason <text>]         Session-bus note to holders (throttled, never stops)
#   notice                           One session-start line for sessions awaiting manual resume
#   help
#
# Exit codes: 0 ok; 1 error; 2 some sessions skipped (busy, unverifiable or
# still running after the signal); 3 notify-only (no stop authority).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh disable=SC1091
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=opencode-db-idle-gate-lib.sh
source "${SCRIPT_DIR}/opencode-db-idle-gate-lib.sh"

if ! declare -f print_info >/dev/null 2>&1; then
	print_info() { printf '[INFO] %s\n' "$*"; return 0; }
	print_success() { printf '[OK] %s\n' "$*"; return 0; }
	print_warning() { printf '[WARN] %s\n' "$*"; return 0; }
	print_error() { printf '[ERROR] %s\n' "$*" >&2; return 0; }
fi

readonly RESTART_STATE_DIR="${OPENCODE_RESTART_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/work/opencode-session-restart}"
readonly RESTART_MANIFEST="${RESTART_STATE_DIR}/manifest.json"
readonly RESTART_NOTIFIED_DIR="${RESTART_STATE_DIR}/notified"
readonly RESTART_PRESENCE_DIR="${AIDEVOPS_SESSION_BUS_DIR:-${HOME}/.aidevops/.agent-workspace/state/session-bus}/presence"
readonly RESTART_DB="${OPENCODE_DB_PATH:-${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/opencode.db}"
readonly RESTART_HOST_CONF="${OPENCODE_RESTART_HOST_CONF:-${XDG_CONFIG_HOME:-${HOME}/.config}/aidevops/opencode-session-restart.conf}"
readonly RESTART_SENDER="opencode-maintenance"
readonly RESTART_DEFAULT_REASON="maintenance"
readonly RESTART_SESSION_RE='^[A-Za-z0-9_-]{1,128}$'
readonly RESTART_MANIFEST_MAX_AGE=604800
# Row field separator: a non-whitespace IFS keeps empty fields (cwd, pane) in place.
readonly SEP=$'\x1f'

: "${OPENCODE_RESTART_WAIT_TIMEOUT:=600}"   # max seconds to wait for busy sessions to go idle
: "${OPENCODE_RESTART_POLL:=10}"            # seconds between idle polls
: "${OPENCODE_RESTART_IDLE_SECONDS:=120}"   # quiet period after last activity before a stop
: "${OPENCODE_RESTART_EXIT_TIMEOUT:=30}"    # seconds to wait for exit after the signal
: "${OPENCODE_RESTART_SIGNAL:=TERM}"
: "${OPENCODE_RESTART_OPENCODE_BIN:=opencode}"
: "${OPENCODE_RESTART_NOTIFY_INTERVAL:=86400}"
: "${OPENCODE_RESTART_TMUX_BIN:=tmux}"
: "${OPENCODE_RESTART_SCREEN_BIN:=screen}"
: "${OPENCODE_RESTART_SESSION_BUS_HELPER:=${SCRIPT_DIR}/session-bus-helper.sh}"
: "${OPENCODE_RESTART_PS:=ps}"

# -----------------------------------------------------------------------------
# Process facts
# -----------------------------------------------------------------------------

_uint_or() {
	local value="$1"
	local fallback="$2"
	if [[ "$value" =~ ^[0-9]+$ ]]; then printf '%s' "$((10#$value))"; else printf '%s' "$fallback"; fi
	return 0
}

# _pid_alive <pid> — live and not a zombie.
_pid_alive() {
	local pid="$1"
	local stat=""
	[[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
	kill -0 "$pid" 2>/dev/null || return 1
	stat=$("$OPENCODE_RESTART_PS" -o stat= -p "$pid" 2>/dev/null || true)
	stat="${stat//[[:space:]]/}"
	[[ "$stat" != Z* ]] || return 1
	return 0
}

_pid_args() {
	local pid="$1"
	"$OPENCODE_RESTART_PS" -o args= -p "$pid" 2>/dev/null || true
	return 0
}

# _pid_is_interactive_opencode <pid> — argv0 is opencode and it is not a
# headless `opencode run` worker or an `opencode serve` host.
_pid_is_interactive_opencode() {
	local pid="$1"
	local args first rest
	args=$(_pid_args "$pid")
	[[ -n "$args" ]] || return 1
	first="${args%% *}"
	first="${first##*/}"
	[[ "$first" == "opencode" || "$first" == ".opencode" ]] || return 1
	rest=" ${args#"${args%% *}"} "
	[[ "$rest" != *" run "* && "$rest" != *" serve "* ]] || return 1
	return 0
}

# _pid_start_token <pid> — same token the session-bus plugin records.
_pid_start_token() {
	local pid="$1"
	local lstart=""
	lstart=$(LC_ALL=C TZ=UTC "$OPENCODE_RESTART_PS" -o lstart= -p "$pid" 2>/dev/null || true)
	lstart=$(printf '%s' "$lstart" | tr -s '[:space:]' ' ')
	lstart="${lstart# }"
	lstart="${lstart% }"
	[[ -z "$lstart" ]] || printf 'ps:%s' "$lstart"
	return 0
}

# _pid_verified <pid> <start_token> — still the same interactive OpenCode process.
_pid_verified() {
	local pid="$1"
	local token="$2"
	_pid_alive "$pid" || return 1
	_pid_is_interactive_opencode "$pid" || return 1
	if [[ "$token" == ps:* ]]; then
		[[ "$(_pid_start_token "$pid")" == "$token" ]] || return 1
	fi
	return 0
}

_pid_env_value() {
	local pid="$1"
	local name="$2"
	local file="/proc/${pid}/environ"
	[[ -r "$file" ]] || return 0
	tr '\0' '\n' <"$file" 2>/dev/null | awk -v key="${name}=" 'index($0, key) == 1 { print substr($0, length(key) + 1); exit }' || true
	return 0
}

_pid_cwd() {
	local pid="$1"
	local cwd=""
	if [[ -e "/proc/${pid}/cwd" ]]; then
		cwd=$(readlink "/proc/${pid}/cwd" 2>/dev/null || true)
	elif command -v lsof >/dev/null 2>&1; then
		cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/ { print substr($0, 2); exit }' || true)
	fi
	printf '%s' "$cwd"
	return 0
}

_pid_age_seconds() {
	local pid="$1"
	local now started
	now=$(date +%s)
	started=$(OPENCODE_DB_PS_COMMAND="$OPENCODE_RESTART_PS" _opencode_db_holder_start_epoch "$pid" "$now")
	if [[ "$started" =~ ^[0-9]+$ ]]; then printf '%s' "$((now - started))"; else printf '0'; fi
	return 0
}

# _pane_locate <pid> — print "<kind> <target> <socket>" (SEP) where kind is tmux,
# screen or tty. tmux: TMUX_PANE from the environment (Linux), else the
# process ancestry matched against `tmux list-panes -a`.
_pane_locate() {
	local pid="$1"
	local pane tmux_env sty window
	pane=$(_pid_env_value "$pid" TMUX_PANE)
	tmux_env=$(_pid_env_value "$pid" TMUX)
	if [[ "$pane" =~ ^%[0-9]+$ ]]; then
		printf 'tmux%s%s%s%s\n' "$SEP" "$pane" "$SEP" "${tmux_env%%,*}"
		return 0
	fi
	sty=$(_pid_env_value "$pid" STY)
	window=$(_pid_env_value "$pid" WINDOW)
	if [[ -n "$sty" && "$window" =~ ^[0-9]+$ ]]; then
		printf 'screen%s%s%s%s\n' "$SEP" "$window" "$SEP" "$sty"
		return 0
	fi
	pane=$(_pane_from_tmux_ancestry "$pid")
	if [[ -n "$pane" ]]; then
		printf 'tmux%s%s%s\n' "$SEP" "$pane" "$SEP"
		return 0
	fi
	printf 'tty%s%s%s\n' "$SEP" "$("$OPENCODE_RESTART_PS" -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)" "$SEP"
	return 0
}

_pane_from_tmux_ancestry() {
	local pid="$1"
	local panes="" depth=0 cur="$pid" match=""
	command -v "$OPENCODE_RESTART_TMUX_BIN" >/dev/null 2>&1 || return 0
	panes=$("$OPENCODE_RESTART_TMUX_BIN" list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null || true)
	[[ -n "$panes" ]] || return 0
	while [[ "$cur" =~ ^[1-9][0-9]*$ && "$cur" -gt 1 && "$depth" -lt 20 ]]; do
		match=$(awk -v p="$cur" '$1 == p { print $2; exit }' <<<"$panes")
		if [[ "$match" =~ ^%[0-9]+$ ]]; then
			printf '%s' "$match"
			return 0
		fi
		cur=$("$OPENCODE_RESTART_PS" -o ppid= -p "$cur" 2>/dev/null | tr -d '[:space:]' || true)
		depth=$((depth + 1))
	done
	return 0
}

# -----------------------------------------------------------------------------
# Inventory
# -----------------------------------------------------------------------------

# _db_holder_pids — PIDs holding the active DB; "*" when the DB filter does not
# apply (no DB, no lsof) so every live TUI is a candidate.
_db_holder_pids() {
	local files=() rc=0 out=""
	[[ -f "$RESTART_DB" ]] && command -v lsof >/dev/null 2>&1 || { printf '*'; return 0; }
	files=("$RESTART_DB")
	[[ ! -e "${RESTART_DB}-wal" ]] || files+=("${RESTART_DB}-wal")
	[[ ! -e "${RESTART_DB}-shm" ]] || files+=("${RESTART_DB}-shm")
	out=$(lsof -t "${files[@]}" 2>/dev/null) || rc=$?
	if [[ "$rc" -gt 1 ]]; then printf '*'; return 0; fi
	printf '%s\n' "$out" | awk 'NF' | sort -u
	return 0
}

# _presence_rows — one SEP-delimited row per live TUI pid:
# pid, session_id, status (idle|busy), directory, last_activity_epoch, start_token, source
_presence_rows() {
	local file records=""
	command -v jq >/dev/null 2>&1 || return 0
	[[ -d "$RESTART_PRESENCE_DIR" ]] || return 0
	for file in "$RESTART_PRESENCE_DIR"/*.json; do
		[[ -f "$file" ]] || continue
		records+=$(jq -c 'select(type == "object" and .kind == "tui" and (.pid | type) == "number" and (.session_id | type) == "string")' "$file" 2>/dev/null || true)
		records+=$'\n'
	done
	[[ -n "${records//[[:space:]]/}" ]] || return 0
	printf '%s' "$records" | jq -rs '
		group_by(.pid)[] | (max_by(.updated_epoch // 0)) as $r
		| [($r.pid | tostring), $r.session_id,
		   (if all(.[]; .status == "idle") then "idle" else "busy" end),
		   ($r.directory // ""), (($r.last_activity_epoch // 0) | tostring),
		   ($r.start_token // ""), "presence"] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' 2>/dev/null || true
	return 0
}

# _row <field…> — print one SEP-delimited row.
_row() {
	local IFS="$SEP"
	printf '%s\n' "$*"
	return 0
}

# _heartbeat_row <pid> — fallback row from the activity heartbeat for a DB
# holder without session-bus presence. Requires exactly one open session.
_heartbeat_row() {
	local pid="$1"
	local dir file fields busy last sessions count
	dir=$(opencode_db_activity_dir)
	for file in "$dir/${pid}"-*.json; do
		[[ -f "$file" ]] || continue
		fields=$(jq -r '[(.busy_sessions // "" | tostring), (.last_activity_epoch // "" | tostring)] | join(" ")' "$file" 2>/dev/null || true)
		read -r busy last <<<"$fields"
		sessions=$(jq -r '.sessions[]? | strings' "$file" 2>/dev/null | awk 'NF' || true)
		count=$(printf '%s\n' "$sessions" | awk 'NF' | wc -l | tr -d ' ')
		[[ "$busy" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ && "$count" -eq 1 ]] || continue
		_row "$pid" "$sessions" "$([[ "$busy" -eq 0 ]] && printf idle || printf busy)" "$(_pid_cwd "$pid")" "$last" "" heartbeat
		return 0
	done
	return 0
}

# _inventory_rows [all] — verified interactive holders as TSV rows (see
# _presence_rows) with age, pane kind, pane target and pane socket appended.
_inventory_rows() {
	local all="${1:-false}"
	local holders pid sid status cwd last token source seen=" " kind target socket
	holders='*'
	[[ "$all" == true ]] || holders=$(_db_holder_pids)
	while IFS="$SEP" read -r pid sid status cwd last token source; do
		[[ -n "$pid" && "$sid" =~ $RESTART_SESSION_RE ]] || continue
		if [[ "$holders" != '*' ]] && ! grep -qx "$pid" <<<"$holders"; then continue; fi
		_pid_verified "$pid" "$token" || continue
		seen+="${pid} "
		[[ -n "$cwd" ]] || cwd=$(_pid_cwd "$pid")
		IFS="$SEP" read -r kind target socket < <(_pane_locate "$pid")
		_row "$pid" "$sid" "$status" "$cwd" "$last" "$token" "$source" "$(_pid_age_seconds "$pid")" "$kind" "$target" "$socket"
	done < <(_presence_rows)
	[[ "$holders" != '*' ]] || return 0
	while IFS= read -r pid; do
		[[ -n "$pid" && "$seen" != *" ${pid} "* ]] || continue
		_pid_verified "$pid" "" || continue
		IFS="$SEP" read -r pid sid status cwd last token source < <(_heartbeat_row "$pid") || continue
		[[ "$sid" =~ $RESTART_SESSION_RE ]] || continue
		IFS="$SEP" read -r kind target socket < <(_pane_locate "$pid")
		_row "$pid" "$sid" "$status" "$cwd" "$last" "$token" "$source" "$(_pid_age_seconds "$pid")" "$kind" "$target" "$socket"
	done <<<"$holders"
	return 0
}

cmd_inventory() {
	local json=false all=false arg rows pid sid status cwd age kind target
	for arg in "$@"; do
		case "$arg" in
		--json) json=true ;;
		--all) all=true ;;
		*) print_error "Unknown inventory option: $arg"; return 1 ;;
		esac
	done
	if [[ "$json" == true ]] && ! command -v jq >/dev/null 2>&1; then
		printf '[]\n'
		return 0
	fi
	rows=$(_inventory_rows "$all")
	if [[ "$json" == true ]]; then
		printf '%s\n' "$rows" | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\u001f")
			| {pid: (.[0] | tonumber), session_id: .[1], status: .[2], cwd: .[3], last_activity_epoch: (.[4] | tonumber? // 0),
			   source: .[6], age_seconds: (.[7] | tonumber? // 0), pane_kind: .[8], pane: .[9]}]'
		return 0
	fi
	if [[ -z "$rows" ]]; then
		print_info "No interactive OpenCode TUI holders found"
		return 0
	fi
	printf '%-8s %-32s %-5s %-7s %-6s %s\n' PID SESSION STATE AGE PANE CWD
	while IFS="$SEP" read -r pid sid status cwd _ _ _ age kind target _; do
		printf '%-8s %-32s %-5s %-7s %-6s %s\n' "$pid" "$sid" "$status" "$((age / 3600))h" "${kind}${target:+:$target}" "$cwd"
	done <<<"$rows"
	return 0
}

# -----------------------------------------------------------------------------
# Manifest
# -----------------------------------------------------------------------------

_manifest_read() {
	if [[ -f "$RESTART_MANIFEST" ]] && jq -e '.entries | type == "array"' "$RESTART_MANIFEST" >/dev/null 2>&1; then
		jq -c '.' "$RESTART_MANIFEST"
	else
		printf '{"v":1,"entries":[]}'
	fi
	return 0
}

# _manifest_write <json> — atomic replace; drops entries older than 7 days.
_manifest_write() {
	local json="$1"
	local tmp cutoff
	if [[ -z "${json//[[:space:]]/}" ]]; then
		print_error "Refusing to write an empty restart manifest"
		return 1
	fi
	mkdir -p "$RESTART_STATE_DIR"
	cutoff=$(($(date +%s) - RESTART_MANIFEST_MAX_AGE))
	tmp=$(mktemp "${RESTART_STATE_DIR}/manifest.XXXXXX")
	if ! jq --argjson cutoff "$cutoff" '.entries |= map(select((.stopped_epoch // 0) >= $cutoff))' <<<"$json" >"$tmp" || [[ ! -s "$tmp" ]]; then
		rm -f "$tmp"
		return 1
	fi
	chmod 600 "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$RESTART_MANIFEST"
	return 0
}

# _manifest_put <entry-json> — upsert by session_id.
_manifest_put() {
	local entry="$1"
	local json
	json=$(_manifest_read | jq -c --argjson e "$entry" '.entries = ([.entries[] | select(.session_id != $e.session_id)] + [$e])')
	_manifest_write "$json"
	return $?
}

_manifest_set_status() {
	local sid="$1"
	local status="$2"
	local json
	json=$(_manifest_read | jq -c --arg s "$sid" --arg st "$status" --argjson now "$(date +%s)" \
		'.entries |= map(if .session_id == $s then .status = $st | .updated_epoch = $now else . end)')
	_manifest_write "$json"
	return $?
}

_resume_command() {
	local cwd="$1"
	local sid="$2"
	local cmd=""
	[[ -z "$cwd" ]] || cmd="cd -- $(printf '%q' "$cwd") && "
	printf '%s%s -s %s' "$cmd" "$OPENCODE_RESTART_OPENCODE_BIN" "$(printf '%q' "$sid")"
	return 0
}

# -----------------------------------------------------------------------------
# Session-bus messages
# -----------------------------------------------------------------------------

_bus_send() {
	local sid="$1"
	local text="$2"
	[[ -x "$OPENCODE_RESTART_SESSION_BUS_HELPER" ]] || command -v "$OPENCODE_RESTART_SESSION_BUS_HELPER" >/dev/null 2>&1 || return 1
	printf '%s' "$text" | "$OPENCODE_RESTART_SESSION_BUS_HELPER" send "$sid" --sender "$RESTART_SENDER" - >/dev/null 2>&1
	return $?
}

_checkpoint_request_text() {
	local reason="$1"
	printf 'OpenCode maintenance (%s) will restart this TUI so the session DB can be archived/compacted. At your next safe pause: save a continuation checkpoint (session-checkpoint-helper.sh save, or /checkpoint) per reference/session.md "Context Compaction Resilience", then stop and stay idle. The session is relaunched with opencode -s after maintenance; a busy session is never stopped.' "$reason"
	return 0
}

_resumed_note_text() {
	local reason="$1"
	local when="$2"
	printf 'This session was stopped at %s for OpenCode maintenance (%s) and relaunched with opencode -s. Load your continuation checkpoint (session-checkpoint-helper.sh load) and revalidate git, PR and tool state before the next side effect.' "$when" "$reason"
	return 0
}

# -----------------------------------------------------------------------------
# Authority
# -----------------------------------------------------------------------------

_host_allows_unattended() {
	[[ "${OPENCODE_RESTART_ALLOW_UNATTENDED:-}" == 1 || "${OPENCODE_RESTART_ALLOW_UNATTENDED:-}" == true ]] && return 0
	[[ -f "$RESTART_HOST_CONF" ]] || return 1
	grep -Eq '^[[:space:]]*allow_unattended[[:space:]]*=[[:space:]]*(true|1)[[:space:]]*$' "$RESTART_HOST_CONF"
	return $?
}

# _authorize_stop <yes> <count> — 0 stop allowed, 3 notify-only, 1 declined.
_authorize_stop() {
	local yes="$1"
	local count="$2"
	local answer=""
	if [[ -t 0 ]]; then
		[[ "$yes" == true ]] && return 0
		read -r -p "Checkpoint, stop and later resume ${count} interactive OpenCode session(s)? [y/N] " answer || answer=""
		[[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] && return 0
		print_info "Declined; no session was stopped"
		return 1
	fi
	if [[ "$yes" == true ]] && _host_allows_unattended; then
		return 0
	fi
	print_warning "No terminal confirmation and host config does not allow unattended restarts (${RESTART_HOST_CONF}: allow_unattended=true); notifying owners only"
	return 3
}

# -----------------------------------------------------------------------------
# stop
# -----------------------------------------------------------------------------

_row_is_quiet() {
	local status="$1"
	local last="$2"
	local now
	now=$(date +%s)
	[[ "$status" == idle ]] || return 1
	last=$(_uint_or "$last" 0)
	((now - last >= OPENCODE_RESTART_IDLE_SECONDS)) || return 1
	return 0
}

# _current_row <pid> <rows> — fresh inventory row for one pid.
_current_row() {
	local pid="$1"
	local rows="$2"
	awk -F"$SEP" -v p="$pid" '$1 == p { print; exit }' <<<"$rows"
	return 0
}

# _wait_for_quiet <targets> — poll until each target is quiet or the timeout
# passes; print the final rows of targets that went quiet.
_wait_for_quiet() {
	local targets="$1"
	local all="$2"
	local waited=0 rows pid row status last pending
	local poll
	poll=$(_uint_or "$OPENCODE_RESTART_POLL" 10)
	[[ "$poll" -gt 0 ]] || poll=1
	while true; do
		rows=$(_inventory_rows "$all")
		pending=0
		while IFS="$SEP" read -r pid _rest; do
			[[ -n "$pid" ]] || continue
			row=$(_current_row "$pid" "$rows")
			IFS="$SEP" read -r _ _ status _ last _ <<<"$row"
			[[ -n "$row" ]] && ! _row_is_quiet "$status" "$last" && pending=$((pending + 1))
		done <<<"$targets"
		if [[ "$pending" -eq 0 || "$waited" -ge "$OPENCODE_RESTART_WAIT_TIMEOUT" ]]; then
			break
		fi
		print_info "  waiting for ${pending} busy session(s) to reach a safe pause (${waited}s/${OPENCODE_RESTART_WAIT_TIMEOUT}s)" >&2
		sleep "$poll"
		waited=$((waited + poll))
	done
	while IFS="$SEP" read -r pid _rest; do
		[[ -n "$pid" ]] || continue
		row=$(_current_row "$pid" "$rows")
		IFS="$SEP" read -r _ _ status _ last _ <<<"$row"
		if [[ -n "$row" ]] && _row_is_quiet "$status" "$last"; then printf '%s\n' "$row"; fi
	done <<<"$targets"
	return 0
}

_wait_for_exit() {
	local pid="$1"
	local waited=0
	while _pid_alive "$pid" && [[ "$waited" -lt "$OPENCODE_RESTART_EXIT_TIMEOUT" ]]; do
		sleep 1
		waited=$((waited + 1))
	done
	_pid_alive "$pid" && return 1
	return 0
}

# _stop_one <row> <reason> — record the manifest entry, signal, confirm exit.
_stop_one() {
	local row="$1"
	local reason="$2"
	local pid sid status cwd last token source age kind target socket entry
	IFS="$SEP" read -r pid sid status cwd last token source age kind target socket <<<"$row"
	if ! _pid_verified "$pid" "$token"; then
		print_warning "Session ${sid}: PID ${pid} changed before stop; skipped"
		return 1
	fi
	entry=$(jq -nc --arg sid "$sid" --argjson pid "$pid" --arg cwd "$cwd" --arg kind "$kind" --arg pane "$target" \
		--arg socket "$socket" --arg argv "$(_pid_args "$pid")" --arg resume "$(_resume_command "$cwd" "$sid")" \
		--arg reason "$reason" --argjson now "$(date +%s)" --argjson age "$(_uint_or "$age" 0)" \
		'{session_id: $sid, pid: $pid, cwd: $cwd, pane_kind: $kind, pane: $pane, pane_socket: $socket, argv: $argv,
		  resume_command: $resume, reason: $reason, age_seconds: $age, stopped_epoch: $now, updated_epoch: $now, status: "stopping"}')
	_manifest_put "$entry" || { print_error "Cannot write restart manifest; not stopping ${sid}"; return 1; }
	kill "-${OPENCODE_RESTART_SIGNAL}" "$pid" 2>/dev/null || true
	if _wait_for_exit "$pid"; then
		_manifest_set_status "$sid" stopped
		print_success "Stopped idle session ${sid} (PID ${pid}, ${kind}${target:+ ${target}})"
		return 0
	fi
	_manifest_set_status "$sid" stop_failed
	print_warning "Session ${sid} (PID ${pid}) still running ${OPENCODE_RESTART_EXIT_TIMEOUT}s after SIG${OPENCODE_RESTART_SIGNAL}; left running"
	return 1
}

_parse_stop_args() {
	STOP_YES=false
	STOP_ALL=false
	STOP_REASON="$RESTART_DEFAULT_REASON"
	STOP_SESSIONS=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--yes | -y) STOP_YES=true; shift ;;
		--all) STOP_ALL=true; shift ;;
		--reason | --session | --wait-timeout)
			if [[ $# -lt 2 ]]; then
				print_error "Option ${arg} requires a value"
				return 1
			fi
			local optval="${2}"
			case "$arg" in
			--reason) STOP_REASON="$optval" ;;
			--session) STOP_SESSIONS+=" ${optval}" ;;
			--wait-timeout) OPENCODE_RESTART_WAIT_TIMEOUT=$(_uint_or "$optval" "$OPENCODE_RESTART_WAIT_TIMEOUT") ;;
			esac
			shift 2
			;;
		--) shift; STOP_REST=("$@"); return 0 ;;
		*) print_error "Unknown option: $arg"; return 1 ;;
		esac
	done
	STOP_REST=()
	return 0
}

cmd_stop() {
	STOP_REST=()
	_parse_stop_args "$@" || return 1
	_stop_targets
	return $?
}

# _stop_targets — body of stop using the parsed STOP_* options.
_stop_targets() {
	local rows targets="" row pid sid status last quiet fresh skipped=0 stopped=0 auth=0
	command -v jq >/dev/null 2>&1 || { print_error "jq is required"; return 1; }
	rows=$(_inventory_rows "$STOP_ALL")
	while IFS= read -r row; do
		[[ -n "$row" ]] || continue
		IFS="$SEP" read -r pid sid _ <<<"$row"
		[[ -z "$STOP_SESSIONS" || " ${STOP_SESSIONS} " == *" ${sid} "* ]] || continue
		targets+="${row}"$'\n'
	done <<<"$rows"
	if [[ -z "$targets" ]]; then
		print_info "No interactive OpenCode TUI holders to restart"
		return 0
	fi
	_authorize_stop "$STOP_YES" "$(printf '%s' "$targets" | awk 'NF' | wc -l | tr -d ' ')" || auth=$?
	if [[ "$auth" -eq 3 ]]; then
		_notify_rows "$targets" "$STOP_REASON"
		return 3
	fi
	[[ "$auth" -eq 0 ]] || return 1
	# Only busy sessions get the checkpoint request: an idle session is already
	# at a safe pause, and a queued message would arrive only after the resume.
	while IFS="$SEP" read -r pid sid status _; do
		[[ -n "$pid" ]] || continue
		if [[ "$status" != idle ]]; then
			_bus_send "$sid" "$(_checkpoint_request_text "$STOP_REASON")" ||
				print_warning "Session ${sid}: checkpoint request not delivered (session bus unavailable)"
			print_info "Session ${sid} (PID ${pid}) is busy; asked it to checkpoint and pause"
		fi
	done <<<"$targets"
	quiet=$(_wait_for_quiet "$targets" "$STOP_ALL")
	while IFS="$SEP" read -r pid sid _; do
		[[ -n "$pid" ]] || continue
		if [[ -z "$(_current_row "$pid" "$quiet")" ]]; then
			if ! _pid_alive "$pid"; then
				print_info "Session ${sid} (PID ${pid}) exited on its own; nothing to resume"
				continue
			fi
			print_warning "Session ${sid} (PID ${pid}) stayed busy; not stopped"
			skipped=$((skipped + 1))
			continue
		fi
		# Re-check idleness right before the signal: a prompt may have arrived
		# while earlier sessions were being stopped.
		fresh=$(_current_row "$pid" "$(_inventory_rows "$STOP_ALL")")
		IFS="$SEP" read -r _ _ status _ last _ <<<"$fresh"
		if [[ -z "$fresh" ]] || ! _row_is_quiet "$status" "$last"; then
			print_warning "Session ${sid} (PID ${pid}) became busy before the stop; not stopped"
			skipped=$((skipped + 1))
			continue
		fi
		if _stop_one "$fresh" "$STOP_REASON"; then
			stopped=$((stopped + 1))
		else
			skipped=$((skipped + 1))
		fi
	done <<<"$targets"
	print_info "Interactive restart: ${stopped} stopped, ${skipped} skipped. Manifest: ${RESTART_MANIFEST}"
	[[ "$skipped" -eq 0 ]] || return 2
	return 0
}

# -----------------------------------------------------------------------------
# resume
# -----------------------------------------------------------------------------

_session_live() {
	local sid="$1"
	local file="${RESTART_PRESENCE_DIR}/${sid}.json"
	local pid token
	[[ -f "$file" ]] || return 1
	pid=$(jq -r '.pid // empty' "$file" 2>/dev/null || true)
	token=$(jq -r '.start_token // empty' "$file" 2>/dev/null || true)
	_pid_verified "$pid" "$token"
	return $?
}

_tmux() {
	local socket="$1"
	shift
	if [[ -n "$socket" ]]; then
		"$OPENCODE_RESTART_TMUX_BIN" -S "$socket" "$@"
	else
		"$OPENCODE_RESTART_TMUX_BIN" "$@"
	fi
	return $?
}

# _relaunch_entry <entry-json> — print the new status for one manifest entry.
_relaunch_entry() {
	local entry="$1"
	local sid kind pane socket cmd pane_cmd
	sid=$(jq -r '.session_id' <<<"$entry")
	kind=$(jq -r '.pane_kind // "tty"' <<<"$entry")
	pane=$(jq -r '.pane // ""' <<<"$entry")
	socket=$(jq -r '.pane_socket // ""' <<<"$entry")
	cmd=$(jq -r '.resume_command' <<<"$entry")
	if _session_live "$sid"; then
		printf 'already_running'
		return 0
	fi
	case "$kind" in
	tmux)
		# Only type into a pane that is back at a shell prompt.
		pane_cmd=$(_tmux "$socket" display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null || true)
		if [[ "$pane_cmd" =~ ^-?(bash|zsh|fish|sh|dash|ksh)$ ]] &&
			_tmux "$socket" send-keys -t "$pane" -l "$cmd" >/dev/null 2>&1 &&
			_tmux "$socket" send-keys -t "$pane" Enter >/dev/null 2>&1; then
			printf 'resumed'
			return 0
		fi
		;;
	screen)
		if "$OPENCODE_RESTART_SCREEN_BIN" -S "$socket" -p "$pane" -X stuff "${cmd}"$'\r' >/dev/null 2>&1; then
			printf 'resumed'
			return 0
		fi
		;;
	esac
	printf 'pending_manual'
	return 0
}

# _entry_still_running <entry-json> — true when a stopping/stop_failed entry's
# recorded PID is still alive (the TUI has not exited, so nothing to resume).
_entry_still_running() {
	local entry="$1"
	local st pid
	st=$(jq -r '.status' <<<"$entry")
	[[ "$st" == stop_failed || "$st" == stop* ]] || return 1
	[[ "$st" != stopped ]] || return 1
	pid=$(jq -r '.pid // empty' <<<"$entry")
	[[ -n "$pid" ]] || return 1
	_pid_alive "$pid"
	return $?
}

cmd_resume() {
	local manifest entries entry sid status reason stopped when pending=0 resumed=0
	command -v jq >/dev/null 2>&1 || { print_error "jq is required"; return 1; }
	manifest=$(_manifest_read)
	entries=$(jq -c '.entries[] | select(.status | test("^(stopped|stopping|stop_failed)$"))' <<<"$manifest")
	if [[ -z "$entries" ]]; then
		print_info "No stopped interactive sessions to resume"
		return 0
	fi
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		_entry_still_running "$entry" && continue
		sid=$(jq -r '.session_id' <<<"$entry")
		reason=$(jq -r --arg d "$RESTART_DEFAULT_REASON" '.reason // $d' <<<"$entry")
		stopped=$(jq -r '.stopped_epoch // 0' <<<"$entry")
		when=$(date -u -d "@${stopped}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$stopped" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$stopped")
		status=$(_relaunch_entry "$entry")
		_manifest_set_status "$sid" "$status"
		_bus_send "$sid" "$(_resumed_note_text "$reason" "$when")" || true
		if [[ "$status" == pending_manual ]]; then
			pending=$((pending + 1))
			print_warning "Session ${sid} cannot be relaunched in place; resume with: $(jq -r '.resume_command' <<<"$entry")"
		else
			resumed=$((resumed + 1))
			print_success "Session ${sid}: ${status}"
		fi
	done <<<"$entries"
	print_info "Interactive resume: ${resumed} resumed, ${pending} awaiting manual resume"
	return 0
}

# -----------------------------------------------------------------------------
# run / notify / notice
# -----------------------------------------------------------------------------

cmd_run() {
	local rc=0 stop_rc=0
	STOP_REST=()
	_parse_stop_args "$@" || return 1
	if [[ "${#STOP_REST[@]}" -eq 0 ]]; then
		print_error "run requires a command after --"
		return 1
	fi
	_stop_targets || stop_rc=$?
	[[ "$stop_rc" -ne 1 ]] || return 1
	trap 'cmd_resume || true' EXIT
	"${STOP_REST[@]}" || rc=$?
	trap - EXIT
	cmd_resume || true
	[[ "$rc" -ne 0 ]] || rc="$stop_rc"
	return "$rc"
}

# _notify_rows <rows> <reason> — throttled owner notice; never stops anything.
_notify_rows() {
	local rows="$1"
	local reason="$2"
	local pid sid age marker now last text
	now=$(date +%s)
	mkdir -p "$RESTART_NOTIFIED_DIR"
	while IFS="$SEP" read -r pid sid _ _ _ _ _ age _; do
		[[ -n "$pid" && "$sid" =~ $RESTART_SESSION_RE ]] || continue
		marker="${RESTART_NOTIFIED_DIR}/${sid}"
		last=$(_uint_or "$(cat "$marker" 2>/dev/null || true)" 0)
		((now - last >= OPENCODE_RESTART_NOTIFY_INTERVAL)) || continue
		text="OpenCode maintenance (${reason}) is deferred because this TUI (PID ${pid}, up $(( $(_uint_or "$age" 0) / 3600 ))h) holds opencode.db. At a safe pause, save a checkpoint and close it, or run: aidevops opencode-db maintenance-window --restart-interactive (checkpoints, stops and resumes idle sessions)."
		if _bus_send "$sid" "$text"; then
			printf '%s\n' "$now" >"$marker"
			print_info "Notified session ${sid} (PID ${pid})"
		fi
	done <<<"$rows"
	return 0
}

cmd_notify() {
	local reason="$RESTART_DEFAULT_REASON" all=false
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--reason) reason="${2:-$RESTART_DEFAULT_REASON}"; shift 2 ;;
		--all) all=true; shift ;;
		*) print_error "Unknown notify option: $arg"; return 1 ;;
		esac
	done
	_notify_rows "$(_inventory_rows "$all")" "$reason"
	return 0
}

# cmd_notice — one toast-safe line for stopped sessions awaiting a manual
# resume; entries whose session is live again are marked resumed.
cmd_notice() {
	local entries entry sid count=0 first=""
	command -v jq >/dev/null 2>&1 || return 0
	[[ -f "$RESTART_MANIFEST" ]] || return 0
	entries=$(jq -c '.entries[]? | select(.status | test("^(pending_manual|stopped|stopping|stop_failed)$"))' "$RESTART_MANIFEST" 2>/dev/null || true)
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		_entry_still_running "$entry" && continue
		sid=$(jq -r '.session_id' <<<"$entry")
		if _session_live "$sid"; then
			_manifest_set_status "$sid" resumed >/dev/null 2>&1 || true
			continue
		fi
		count=$((count + 1))
		[[ -n "$first" ]] || first=$(jq -r '.resume_command' <<<"$entry")
	done <<<"$entries"
	[[ "$count" -gt 0 ]] || return 0
	printf '[OPENCODE RESTART] %s interactive session(s) stopped for maintenance await resume, e.g.: %s (list: %s)\n' "$count" "$first" "$RESTART_MANIFEST"
	return 0
}

cmd_help() {
	sed -n '5,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	cat <<EOF

Options (stop/run): --yes  --all (every live TUI, not only active-DB holders)
  --session <id> (repeatable)  --reason <text>  --wait-timeout <s>

Environment:
  OPENCODE_RESTART_WAIT_TIMEOUT  busy-session wait (default 600)
  OPENCODE_RESTART_IDLE_SECONDS  quiet period before a stop (default 120)
  OPENCODE_RESTART_EXIT_TIMEOUT  exit wait after the signal (default 30)
  OPENCODE_RESTART_SIGNAL        stop signal (default TERM; never escalates)
  OPENCODE_RESTART_STATE_DIR     manifest directory
  OPENCODE_RESTART_ALLOW_UNATTENDED=1 or allow_unattended=true in
  ${RESTART_HOST_CONF}
                                 lets non-terminal runs with --yes stop sessions
EOF
	return 0
}

main() {
	local sub="${1:-help}"
	shift || true
	OPENCODE_RESTART_WAIT_TIMEOUT=$(_uint_or "$OPENCODE_RESTART_WAIT_TIMEOUT" 600)
	OPENCODE_RESTART_IDLE_SECONDS=$(_uint_or "$OPENCODE_RESTART_IDLE_SECONDS" 120)
	OPENCODE_RESTART_EXIT_TIMEOUT=$(_uint_or "$OPENCODE_RESTART_EXIT_TIMEOUT" 30)
	OPENCODE_RESTART_NOTIFY_INTERVAL=$(_uint_or "$OPENCODE_RESTART_NOTIFY_INTERVAL" 86400)
	[[ "$OPENCODE_RESTART_SIGNAL" =~ ^(TERM|INT|HUP)$ ]] || OPENCODE_RESTART_SIGNAL=TERM
	case "$sub" in
	inventory | list) cmd_inventory "$@" ;;
	stop) cmd_stop "$@" ;;
	resume) cmd_resume "$@" ;;
	run) cmd_run "$@" ;;
	notify) cmd_notify "$@" ;;
	notice) cmd_notice "$@" ;;
	help | -h | --help) cmd_help ;;
	*) print_error "Unknown command: $sub"; cmd_help; return 1 ;;
	esac
	return $?
}

main "$@"
