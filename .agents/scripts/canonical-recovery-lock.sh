#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck source=mkdir-exclusive.sh
source "${BASH_SOURCE[0]%/*}/mkdir-exclusive.sh"

#
# canonical-recovery-lock.sh - owner-aware mkdir lock for the shared
# <common_dir>/aidevops-canonical-recovery.lock directory (GH#38643).
#
# A bare mkdir lock removed only by an EXIT trap is left behind when the holder
# is killed (SIGKILL, or systemd TimeoutStartSec). This library records the
# owner (pid, process start time, epoch, operation) inside the lock and lets the
# next acquirer take over a lock whose owner is dead or whose PID was reused.
# A lock held by a live owner is never taken over.
#
# Sourced library: callers own `set -euo pipefail`. Public functions:
#   crl_acquire LOCK_DIR OPERATION   0 = acquired, 1 = held / takeover refused
#   crl_release LOCK_DIR             removes the lock only when this shell owns it

CRL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
# shellcheck source=./portable-stat.sh
# shellcheck disable=SC1091  # sibling library resolved at runtime
source "${CRL_LIB_DIR}/portable-stat.sh"
CRL_OWNER_FILE="owner"
# Must exceed the longest supported holder timeout (auto-update TimeoutStartSec=600).
CRL_OWNERLESS_MIN_AGE="${AIDEVOPS_CANONICAL_LOCK_OWNERLESS_MIN_AGE:-900}"
CRL_HOLDER_PATTERN='canonical-recovery-helper\.sh|deploy-agents-on-merge\.sh'

# Process start time, used to detect PID reuse. Empty when the PID is gone.
_crl_proc_start() {
	local pid="$1"
	local started=""

	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	started=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | tr -s '[:space:]' ' ') || started=""
	started="${started# }"
	started="${started% }"
	[[ -n "$started" ]] || return 1
	printf '%s\n' "$started"
	return 0
}

_crl_owner_field() {
	local lock_dir="$1"
	local key="$2"
	local line=""

	[[ -r "${lock_dir}/${CRL_OWNER_FILE}" ]] || return 1
	while IFS= read -r line; do
		if [[ "$line" == "${key}="* ]]; then
			printf '%s\n' "${line#"${key}="}"
			return 0
		fi
	done <"${lock_dir}/${CRL_OWNER_FILE}"
	return 1
}

_crl_write_owner() {
	local lock_dir="$1"
	local operation="$2"
	local started=""
	local tmp="${lock_dir}/${CRL_OWNER_FILE}.$$"

	started=$(_crl_proc_start "$$") || started="unknown"
	printf 'pid=%s\nstart=%s\nepoch=%s\noperation=%s\n' \
		"$$" "$started" "$(date +%s)" "$operation" >"$tmp" || return 1
	mv -f "$tmp" "${lock_dir}/${CRL_OWNER_FILE}" || return 1
	return 0
}

# Tamper-evident record of a takeover; fail closed when it cannot be written.
_crl_audit_takeover() {
	local lock_dir="$1"
	local reason="$2"
	local dead_pid="$3"
	local dead_start="$4"
	local dead_epoch="$5"
	local dead_op="$6"
	local audit="${CRL_LIB_DIR}/audit-log-helper.sh"
	local audit_file="${AIDEVOPS_CANONICAL_RECOVERY_AUDIT_FILE:-${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl}"

	[[ -x "$audit" ]] || return 1
	AUDIT_LOG_FILE="$audit_file" AUDIT_QUIET=true "$audit" log operation.verify \
		"Canonical recovery lock takeover" \
		--detail "reason=${reason}" --detail "lock=${lock_dir}" \
		--detail "dead_owner_pid=${dead_pid:-none}" --detail "dead_owner_start=${dead_start:-none}" \
		--detail "dead_owner_epoch=${dead_epoch:-none}" --detail "dead_owner_operation=${dead_op:-none}" \
		--detail "new_owner_pid=$$" >/dev/null || return 1
	return 0
}

# Any other holder-script process running? Excludes this shell and its parent.
_crl_other_holder_running() {
	local pid=""

	command -v pgrep >/dev/null 2>&1 || return 0
	while IFS= read -r pid; do
		[[ -n "$pid" && "$pid" != "$$" && "$pid" != "$PPID" ]] && return 0
	done < <(pgrep -f "$CRL_HOLDER_PATTERN" 2>/dev/null || true)
	return 1
}

# Decide whether the existing lock is stale. Prints the reason on stdout.
# Return 0 when it may be taken over, 1 when it must be respected.
_crl_lock_is_stale() {
	local lock_dir="$1"
	local pid=""
	local recorded_start=""
	local current_start=""
	local mtime=""
	local age=0

	pid=$(_crl_owner_field "$lock_dir" pid) || pid=""
	if [[ -n "$pid" ]]; then
		if ! current_start=$(_crl_proc_start "$pid"); then
			printf 'owner-dead\n'
			return 0
		fi
		recorded_start=$(_crl_owner_field "$lock_dir" start) || recorded_start=""
		if [[ -n "$recorded_start" && "$recorded_start" != "unknown" && "$recorded_start" != "$current_start" ]]; then
			printf 'owner-pid-reused\n'
			return 0
		fi
		return 1
	fi

	# No owner record: old-format lock, or a holder between mkdir and its owner write.
	[[ -d "$lock_dir" ]] || return 1
	mtime=$(_file_mtime_epoch "$lock_dir") || return 1
	[[ "$mtime" =~ ^[1-9][0-9]*$ ]] || return 1
	age=$(($(date +%s) - mtime))
	[[ "$age" -gt "$CRL_OWNERLESS_MIN_AGE" ]] || return 1
	_crl_other_holder_running && return 1
	printf 'ownerless-expired\n'
	return 0
}

_crl_takeover() {
	local lock_dir="$1"
	local reason="$2"
	local quarantine=""
	local dead_pid="" dead_start="" dead_epoch="" dead_op=""

	quarantine="${lock_dir}.stale.$$.$(date +%s)"

	dead_pid=$(_crl_owner_field "$lock_dir" pid) || dead_pid=""
	dead_start=$(_crl_owner_field "$lock_dir" start) || dead_start=""
	dead_epoch=$(_crl_owner_field "$lock_dir" epoch) || dead_epoch=""
	dead_op=$(_crl_owner_field "$lock_dir" operation) || dead_op=""

	_crl_audit_takeover "$lock_dir" "$reason" "$dead_pid" "$dead_start" "$dead_epoch" "$dead_op" || {
		printf 'BLOCKED: lock takeover audit record could not be written\n' >&2
		return 1
	}
	# Atomic rename: only one contender wins; the loser sees a missing source.
	mv "$lock_dir" "$quarantine" 2>/dev/null || return 1
	rm -rf "$quarantine"
	printf 'RECOVERED: stale canonical recovery lock (%s, owner pid %s)\n' "$reason" "${dead_pid:-none}" >&2
	return 0
}

crl_acquire() {
	local lock_dir="$1"
	local operation="${2:-unknown}"
	local reason=""

	if mkdir "$lock_dir" 2>/dev/null; then
		_crl_write_owner "$lock_dir" "$operation" || {
			rm -rf "$lock_dir"
			return 1
		}
		return 0
	fi
	reason=$(_crl_lock_is_stale "$lock_dir") || return 1
	_crl_takeover "$lock_dir" "$reason" || return 1
	if mkdir "$lock_dir" 2>/dev/null; then
		_crl_write_owner "$lock_dir" "$operation" || {
			rm -rf "$lock_dir"
			return 1
		}
		return 0
	fi
	return 1
}

crl_release() {
	local lock_dir="$1"
	local pid=""

	[[ -d "$lock_dir" ]] || return 0
	pid=$(_crl_owner_field "$lock_dir" pid) || pid=""
	# Only the owner removes the lock; a takeover may have replaced it.
	if [[ -n "$pid" && "$pid" != "$$" ]]; then
		return 0
	fi
	rm -f "${lock_dir}/${CRL_OWNER_FILE}" "${lock_dir}/${CRL_OWNER_FILE}.$$" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}
