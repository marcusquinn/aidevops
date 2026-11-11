#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for opencode-session-restart-helper.sh (GH#37663).
#
# Fake holders are bash loops whose argv0 is `opencode`, paired with
# session-bus presence records. Fake tmux and session-bus helpers log their
# arguments. Asserts: an idle tmux holder is stopped and relaunched in the same
# pane with the same session ID; a busy holder is never signalled; a bare-TTY
# holder gets a manifest entry and a notice instead of a relaunch; without
# stop authority the helper only notifies.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../opencode-session-restart-helper.sh"

if ! command -v jq >/dev/null 2>&1; then
	echo "SKIP: jq not available"
	exit 0
fi

PASS=0
FAIL=0
_pass() {
	PASS=$((PASS + 1))
	printf '  PASS %s\n' "$1"
	return 0
}
_fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1"
	return 0
}
_check() {
	local name="$1"
	shift
	if "$@"; then _pass "$name"; else _fail "$name"; fi
	return 0
}

SANDBOX=$(mktemp -d)
HOLDER_PIDS=()
_cleanup() {
	local pid
	for pid in ${HOLDER_PIDS[@]+"${HOLDER_PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	rm -rf "$SANDBOX"
	return 0
}
trap _cleanup EXIT

BIN="$SANDBOX/bin"
PRESENCE="$SANDBOX/bus/presence"
STATE="$SANDBOX/state"
mkdir -p "$BIN" "$PRESENCE" "$STATE" "$SANDBOX/home" "$SANDBOX/work dir"

cat >"$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG_DIR/tmux.log"
[[ "${1:-}" != "-S" ]] || shift 2
if [[ "${1:-}" == list-panes && -f "$FAKE_LOG_DIR/panes" ]]; then cat "$FAKE_LOG_DIR/panes"; fi
if [[ "${1:-}" == display-message && "$*" == *pane_current_command* ]]; then echo bash; fi
exit 0
EOF
cat >"$BIN/bus" <<'EOF'
#!/usr/bin/env bash
printf '%s | %s\n' "$*" "$(cat)" >>"$FAKE_LOG_DIR/bus.log"
exit 0
EOF
chmod +x "$BIN/tmux" "$BIN/bus"
: >"$SANDBOX/tmux.log"
: >"$SANDBOX/bus.log"

export FAKE_LOG_DIR="$SANDBOX"
export HOME="$SANDBOX/home"
export AIDEVOPS_SESSION_BUS_DIR="$SANDBOX/bus"
export OPENCODE_DB_PATH="$SANDBOX/absent/opencode.db"
export OPENCODE_DB_ACTIVITY_DIR="$SANDBOX/activity"
export OPENCODE_RESTART_STATE_DIR="$STATE"
export OPENCODE_RESTART_TMUX_BIN="$BIN/tmux"
export OPENCODE_RESTART_SESSION_BUS_HELPER="$BIN/bus"
export OPENCODE_RESTART_HOST_CONF="$SANDBOX/host.conf"
export OPENCODE_RESTART_WAIT_TIMEOUT=1
export OPENCODE_RESTART_POLL=1
export OPENCODE_RESTART_EXIT_TIMEOUT=5
unset OPENCODE_RESTART_ALLOW_UNATTENDED

# _spawn <var> [env…] — start a fake `opencode` TUI; sets the named variable to its PID.
_spawn() {
	local var="$1"
	shift
	# bash, not sleep: multicall coreutils (NixOS, BusyBox) dispatch on argv0.
	env -u TMUX -u TMUX_PANE -u STY -u WINDOW "$@" \
		bash -c 'exec -a opencode bash -c "trap \"exit 0\" TERM; while :; do sleep 1; done"' &
	local pid=$!
	HOLDER_PIDS+=("$pid")
	printf -v "$var" '%s' "$pid"
	return 0
}

# _presence <session> <pid> <status> <directory>
_presence() {
	local sid="$1"
	local pid="$2"
	local status="$3"
	local dir="$4"
	local token
	token="ps:$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
	jq -nc --arg sid "$sid" --argjson pid "$pid" --arg st "$status" --arg dir "$dir" --arg tok "$token" \
		--argjson last "$(($(date +%s) - 1000))" \
		'{v: 1, session_id: $sid, pid: $pid, start_token: $tok, kind: "tui", messageable: true, directory: $dir,
		  status: $st, last_activity_epoch: $last, updated_epoch: $last}' >"$PRESENCE/${sid}.json"
	return 0
}

_alive() {
	local pid="$1"
	local stat
	kill -0 "$pid" 2>/dev/null || return 1
	stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
	[[ "$stat" != Z* ]] || return 1
	return 0
}
_dead() {
	local pid="$1"
	if _alive "$pid"; then return 1; fi
	return 0
}
_log_has() {
	local file="$1"
	local text="$2"
	grep -Fq -- "$text" "$file" || return 1
	return 0
}
_manifest_field() {
	local sid="$1"
	local field="$2"
	jq -r --arg s "$sid" --arg f "$field" '.entries[] | select(.session_id == $s) | .[$f] // ""' "$STATE/manifest.json" 2>/dev/null
	return 0
}
_manifest_is() {
	local sid="$1"
	local field="$2"
	local want="$3"
	[[ "$(_manifest_field "$sid" "$field")" == "$want" ]] || return 1
	return 0
}

_spawn IDLE_PID TMUX_PANE=%7 TMUX="$SANDBOX/tmux-sock,1,0"
_spawn BUSY_PID
_spawn BARE_PID
# Ancestry fallback for hosts without /proc/<pid>/environ (macOS).
printf '%s %%7\n' "$IDLE_PID" >"$SANDBOX/panes"
sleep 0.3
_presence ses_idle "$IDLE_PID" idle "$SANDBOX/work dir"
_presence ses_busy "$BUSY_PID" busy "$SANDBOX/work dir"
_presence ses_bare "$BARE_PID" idle "$SANDBOX/work dir"

echo "Test: inventory"
inv=$("$HELPER" inventory --json </dev/null)
_check "inventory lists three TUI holders" test "$(jq 'length' <<<"$inv")" -eq 3
_check "idle holder is located in tmux pane %7" test "$(jq -r '.[] | select(.session_id == "ses_idle") | "\(.pane_kind):\(.pane)"' <<<"$inv")" == "tmux:%7"
_check "bare holder is a bare TTY" test "$(jq -r '.[] | select(.session_id == "ses_bare") | .pane_kind' <<<"$inv")" == "tty"
_check "busy holder reports busy" test "$(jq -r '.[] | select(.session_id == "ses_busy") | .status' <<<"$inv")" == "busy"

echo "Test: no stop authority without terminal or host opt-in"
rc=0
"$HELPER" stop --yes --all </dev/null >"$SANDBOX/out" 2>&1 || rc=$?
_check "exit 3 (notify-only)" test "$rc" -eq 3
_check "idle holder not signalled" _alive "$IDLE_PID"
_check "owners notified over the session bus" _log_has "$SANDBOX/bus.log" "send ses_idle --sender opencode-maintenance"
: >"$SANDBOX/bus.log"

echo "Test: stop with host opt-in"
printf 'allow_unattended=true\n' >"$OPENCODE_RESTART_HOST_CONF"
rc=0
"$HELPER" stop --yes --all </dev/null >"$SANDBOX/out" 2>&1 || rc=$?
_check "exit 2 (busy holder skipped)" test "$rc" -eq 2
_check "idle tmux holder stopped" _dead "$IDLE_PID"
_check "bare holder stopped" _dead "$BARE_PID"
_check "busy holder never signalled" _alive "$BUSY_PID"
_check "busy holder asked to checkpoint" _log_has "$SANDBOX/bus.log" "send ses_busy --sender opencode-maintenance"
_check "idle holder not messaged before stop" bash -c "! grep -q 'send ses_idle' '$SANDBOX/bus.log'"
_check "manifest records idle pane" _manifest_is ses_idle pane "%7"
_check "manifest records idle stopped" _manifest_is ses_idle status stopped
_check "manifest records bare tty" _manifest_is ses_bare pane_kind tty
_check "busy holder absent from manifest" test -z "$(_manifest_field ses_busy status)"

echo "Test: resume"
"$HELPER" resume </dev/null >"$SANDBOX/out" 2>&1
expected_cmd="cd -- $(printf '%q' "$SANDBOX/work dir") && opencode -s ses_idle"
_check "relaunch targets the same pane" _log_has "$SANDBOX/tmux.log" "send-keys -t %7 -l ${expected_cmd}"
_check "relaunch presses Enter in the pane" _log_has "$SANDBOX/tmux.log" "send-keys -t %7 Enter"
_check "bare holder not relaunched" bash -c "! grep -q 'ses_bare' '$SANDBOX/tmux.log'"
_check "manifest marks idle resumed" _manifest_is ses_idle status resumed
_check "manifest marks bare pending_manual" _manifest_is ses_bare status pending_manual
_check "resumed session gets a restart note" _log_has "$SANDBOX/bus.log" "send ses_idle --sender opencode-maintenance - | This session was stopped"
_check "resume prints bare resume command" _log_has "$SANDBOX/out" "opencode -s ses_bare"

echo "Test: notice"
notice=$("$HELPER" notice </dev/null)
_check "notice names bare resume command" grep -Fq "opencode -s ses_bare" <<<"$notice"
_check "notice is one line" test "$(printf '%s\n' "$notice" | wc -l | tr -d ' ')" -eq 1

echo "Test: maintenance helper wiring"
MAINT="${SCRIPT_DIR}/../opencode-db-maintenance-helper.sh"
maint_help=$("$MAINT" help)
_check "maintenance-window help documents --restart-interactive" grep -qF -- --restart-interactive <<<"$maint_help"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
