#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# cleanup-stashes-async-helper.sh — Async background stash cleanup runner (GH#21997).
#
# Designed to be invoked by _preflight_launch_async_cleanup from
# _preflight_cleanup_and_ledger. Linux systemd hosts use a transient user
# service outside the parent pulse cgroup; other hosts retain a nohup fallback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="${HOME}/.aidevops/logs"
readonly LOGFILE="${LOG_DIR}/cleanup_stashes.log"
readonly LOCK_DIR="${LOG_DIR}/cleanup_stashes.lock"
readonly PID_FILE="${LOCK_DIR}/pid"
readonly LAST_RUN_FILE="${LOG_DIR}/cleanup_stashes.last-run"

CLEANUP_STASHES_ASYNC_CADENCE_MIN="${CLEANUP_STASHES_ASYNC_CADENCE_MIN:-10}"
CLEANUP_STASHES_ASYNC_CADENCE_MIN="${CLEANUP_STASHES_ASYNC_CADENCE_MIN//[!0-9]/}"
[[ -n "$CLEANUP_STASHES_ASYNC_CADENCE_MIN" ]] || CLEANUP_STASHES_ASYNC_CADENCE_MIN=10

AIDEVOPS_CLEANUP_LOG_MAX_MB="${AIDEVOPS_CLEANUP_LOG_MAX_MB:-20}"
AIDEVOPS_CLEANUP_LOG_MAX_MB="${AIDEVOPS_CLEANUP_LOG_MAX_MB//[!0-9]/}"
[[ "$AIDEVOPS_CLEANUP_LOG_MAX_MB" =~ ^[1-9][0-9]{0,3}$ ]] || AIDEVOPS_CLEANUP_LOG_MAX_MB=20

mkdir -p "$LOG_DIR"

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	printf '[cleanup-stashes-async] ERROR: shared-constants.sh not found at %s\n' "${SCRIPT_DIR}" >>"$LOGFILE"
	exit 1
fi

if [[ -f "${SCRIPT_DIR}/pulse-cleanup.sh" ]]; then
	# shellcheck source=pulse-cleanup.sh
	source "${SCRIPT_DIR}/pulse-cleanup.sh"
else
	printf '[cleanup-stashes-async] ERROR: pulse-cleanup.sh not found at %s\n' "${SCRIPT_DIR}" >>"$LOGFILE"
	exit 1
fi

_lock_release() {
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	return 0
}

_lock_signal_exit() {
	local exit_code="$1"
	trap - EXIT INT TERM
	_lock_release
	exit "$exit_code"
	return 1
}

_lock_install_traps() {
	trap '_lock_release' EXIT
	trap '_lock_signal_exit 130' INT
	trap '_lock_signal_exit 143' TERM
	return 0
}

_is_pid_alive() {
	local pid="$1"
	[[ -z "$pid" ]] && return 1
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1

	if ! kill -0 "$pid" 2>/dev/null; then
		return 1
	fi

	local comm
	comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
	[[ -n "$comm" ]] || return 1
	return 0
}

_lock_finish_acquire() {
	if ! printf '%s\n' "$$" >"$PID_FILE"; then
		rm -f "$PID_FILE" 2>/dev/null || true
		rmdir "$LOCK_DIR" 2>/dev/null || true
		return 1
	fi
	_lock_install_traps
	return 0
}

_lock_acquire() {
	_LOCK_SKIP_REASON="Lock unavailable"
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		_lock_finish_acquire
		return $?
	fi

	local lock_pid=""
	if [[ -f "$PID_FILE" ]]; then
		lock_pid=$(<"$PID_FILE")
	fi
	if [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]]; then
		_LOCK_SKIP_REASON="Lock held by live instance (PID ${lock_pid})"
		_is_pid_alive "$lock_pid" && return 1
		printf '[cleanup-stashes-async] Reclaiming stale lock (PID %s no longer alive)\n' "$lock_pid" >>"$LOGFILE"
	else
		local grace="${AIDEVOPS_LOCK_OWNERLESS_GRACE_SECONDS:-300}"
		local mtime="" now="" age=""
		[[ "$grace" =~ ^[0-9]+$ && ${#grace} -le 9 ]] || grace=300
		_LOCK_SKIP_REASON="Ownerless lock age unavailable"
		case "$(uname -s)" in
		Darwin* | FreeBSD*) mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null) || return 1 ;;
		*) mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null) || return 1 ;;
		esac
		[[ "$mtime" =~ ^[0-9]+$ ]] || return 1
		now=$(date +%s) || return 1
		age=$((now - mtime))
		_LOCK_SKIP_REASON="Young ownerless lock (age ${age}s, grace ${grace}s)"
		((age > 10#$grace)) || return 1
		# Re-read the owner: a live acquirer may have written it during stat.
		if [[ -f "$PID_FILE" ]]; then
			lock_pid=$(<"$PID_FILE")
			[[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && return 1
		fi
		printf '[cleanup-stashes-async] Reclaiming ownerless lock (age %ss)\n' "$age" >>"$LOGFILE"
	fi
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		_lock_finish_acquire
		return $?
	fi

	return 1
}

_cadence_ok() {
	if [[ ! -f "$LAST_RUN_FILE" ]]; then
		return 0
	fi

	local last_run now elapsed cadence_secs
	IFS= read -r last_run <"$LAST_RUN_FILE" 2>/dev/null || last_run=""
	if ! [[ "$last_run" =~ ^[0-9]+$ ]]; then
		return 0
	fi

	now=$(date +%s)
	elapsed=$((now - last_run))
	cadence_secs=$((CLEANUP_STASHES_ASYNC_CADENCE_MIN * 60))

	if [[ "$elapsed" -lt "$cadence_secs" ]]; then
		printf '[cleanup-stashes-async] Cadence gate: last run %ss ago (threshold %ss). Skipping.\n' \
			"$elapsed" "$cadence_secs" >>"$LOGFILE"
		return 1
	fi

	return 0
}

_update_last_run() {
	date +%s >"$LAST_RUN_FILE" 2>/dev/null || true
	return 0
}

_rotate_log_if_oversize() {
	local log_size=0
	local max_size=$((AIDEVOPS_CLEANUP_LOG_MAX_MB * 1024 * 1024))
	local rotated_log="${LOGFILE}.1"

	[[ -f "$LOGFILE" ]] || return 0
	log_size=$(wc -c <"$LOGFILE" | tr -d '[:space:]') || return 0
	[[ "$log_size" =~ ^[0-9]+$ && "$log_size" -gt "$max_size" ]] || return 0
	rm -f "$rotated_log" 2>/dev/null || return 0
	mv "$LOGFILE" "$rotated_log" 2>/dev/null || return 0
	printf '[cleanup-stashes-async] rotated log bytes=%s cap_mb=%s\n' \
		"$log_size" "$AIDEVOPS_CLEANUP_LOG_MAX_MB" >>"$LOGFILE"
	return 0
}

main() {
	if ! _lock_acquire; then
		printf '[cleanup-stashes-async] %s — skipping this invocation\n' "${_LOCK_SKIP_REASON:-Lock unavailable}" >>"$LOGFILE"
		return 0
	fi
	_rotate_log_if_oversize
	printf '[cleanup-stashes-async] PID=%s starting at %s\n' "$$" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOGFILE"

	if ! _cadence_ok; then
		return 0
	fi

	printf '[cleanup-stashes-async] Starting cleanup_stashes (cadence OK)\n' >>"$LOGFILE"

	local rc=0
	cleanup_stashes || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		_update_last_run
		printf '[cleanup-stashes-async] outcome=success skip_reasons=none last-run=updated\n' >>"$LOGFILE"
	else
		printf '[cleanup-stashes-async] outcome=failed rc=%s skip_reasons=unavailable last-run=not-updated\n' "$rc" >>"$LOGFILE"
	fi

	return 0
}

main "$@"
