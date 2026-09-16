#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared lifecycle for headless runtime session-key PID locks.

[[ -n "${_HEADLESS_SESSION_LOCKS_LOADED:-}" ]] && return 0
_HEADLESS_SESSION_LOCKS_LOADED=1

_session_lock_default_dir() {
	printf '%s/locks\n' "${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
	return 0
}

_session_lock_runtime_dir() {
	if [[ -n "${LOCK_DIR:-}" ]]; then
		printf '%s\n' "$LOCK_DIR"
	else
		_session_lock_default_dir
	fi
	return 0
}

_session_lock_process_pattern() {
	printf '%s\n' "${WORKER_PROCESS_PATTERN:-opencode|claude|Claude}|headless-runtime-helper"
	return 0
}

#######################################
# Classify one lock snapshot by owner liveness.
# Args: $1=raw PID or PID|argv_hash snapshot
# Returns: 0=live owner, 1=stale owner, 2=indeterminate live owner,
#          3=malformed owner record
#######################################
_session_lock_owner_state() {
	local raw="$1"
	local pid=""
	local stored_hash=""
	local current_command=""
	local process_pattern=""

	pid="${raw%%|*}"
	if [[ "$raw" == *"|"* ]]; then
		stored_hash="${raw#*|}"
	fi
	[[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 3

	# A dead PID is conclusive even when the remaining record is malformed.
	kill -0 "$pid" 2>/dev/null || return 1
	if [[ -n "$stored_hash" && ! "$stored_hash" =~ ^[a-f0-9]{12}$ ]]; then
		return 2
	fi

	# Fail closed when process identity cannot be read. When it can be read,
	# the shared matcher distinguishes the owner from a recycled PID.
	current_command=$(ps -p "$pid" -o command= 2>/dev/null) || return 2
	[[ -n "$current_command" ]] || return 2
	process_pattern=$(_session_lock_process_pattern)
	_is_process_alive_and_matches "$pid" "$process_pattern" "$stored_hash" && return 0
	return 1
}

#######################################
# Remove a lock only when its complete snapshot is unchanged.
# Args: $1=path, $2=expected raw snapshot
# Returns: 0=removed/already absent, 1=I/O failure, 2=snapshot changed
#######################################
_session_lock_remove_snapshot() {
	local lock_file="$1"
	local expected_raw="$2"
	local current_raw=""

	[[ -e "$lock_file" ]] || return 0
	current_raw=$(<"$lock_file") || return 1
	[[ "$current_raw" == "$expected_raw" ]] || return 2
	rm -f "$lock_file" || return 1
	[[ ! -e "$lock_file" ]] || return 1
	return 0
}

#######################################
# Prevent duplicate workers for the same session key.
# Args: $1=session key
# Returns: 0=acquired, 1=live/indeterminate owner or concurrent acquisition
#######################################
_acquire_session_lock() {
	local lock_session_key="$1"
	local lock_dir=""
	local safe_key=""
	local lock_file=""
	local existing_raw=""
	local owner_state=0
	local argv_hash=""
	local attempt=0

	lock_dir=$(_session_lock_runtime_dir)
	mkdir -p "$lock_dir" 2>/dev/null || return 1
	safe_key=$(printf '%s' "$lock_session_key" | tr '/ ' '__')
	lock_file="${lock_dir}/${safe_key}.pid"
	argv_hash=$(_compute_argv_hash "$$" 2>/dev/null || printf '')

	while [[ "$attempt" -lt 3 ]]; do
		attempt=$((attempt + 1))
		if [[ -f "$lock_file" ]]; then
			existing_raw=$(<"$lock_file") || existing_raw=""
			owner_state=0
			_session_lock_owner_state "$existing_raw" || owner_state=$?
			if [[ "$owner_state" -eq 0 || "$owner_state" -eq 2 || "$owner_state" -eq 3 ]]; then
				print_warning "Duplicate dispatch blocked: session-key '${lock_session_key}' has an active or indeterminate owner (GH#6538/GH#31988)"
				return 1
			fi
			owner_state=0
			_session_lock_remove_snapshot "$lock_file" "$existing_raw" || owner_state=$?
			[[ "$owner_state" -eq 0 ]] || continue
		fi

		# noclobber makes creation atomic when two launchers race on an absent key.
		if (
			set -o noclobber
			printf '%s|%s' "$$" "$argv_hash" >"$lock_file"
		) 2>/dev/null; then
			return 0
		fi
	done

	print_warning "Duplicate dispatch blocked: session-key '${lock_session_key}' changed during acquisition (GH#31988)"
	return 1
}

#######################################
# Remove this process's session lock without disturbing a replacement owner.
# Args: $1=session key
#######################################
_release_session_lock() {
	local lock_session_key="$1"
	local lock_dir=""
	local safe_key=""
	local lock_file=""
	local stored_raw=""
	local stored_pid=""

	lock_dir=$(_session_lock_runtime_dir)
	safe_key=$(printf '%s' "$lock_session_key" | tr '/ ' '__')
	lock_file="${lock_dir}/${safe_key}.pid"
	if [[ -f "$lock_file" ]]; then
		stored_raw=$(<"$lock_file") || stored_raw=""
		stored_pid="${stored_raw%%|*}"
		if [[ "$stored_pid" == "$$" ]]; then
			_session_lock_remove_snapshot "$lock_file" "$stored_raw" || return 1
		fi
	fi
	return 0
}

#######################################
# Reconcile stale locks independently of process exit or same-key reuse.
# Args: $1=optional lock directory
# Env: AIDEVOPS_SESSION_LOCK_SWEEP_MAX (default 500)
#      AIDEVOPS_SESSION_LOCK_MALFORMED_GRACE_SECONDS (default 300)
#######################################
cleanup_stale_session_locks() {
	local lock_dir="${1:-}"
	local max_entries="${AIDEVOPS_SESSION_LOCK_SWEEP_MAX:-500}"
	local malformed_grace="${AIDEVOPS_SESSION_LOCK_MALFORMED_GRACE_SECONDS:-300}"
	local now_epoch=""
	local cursor_file=""
	local cursor_temp=""
	local cursor=0
	local file_count=0
	local visit_limit=0
	local visited=0
	local index=0
	local lock_file=""
	local raw=""
	local owner_state=0
	local file_mtime=0
	local file_age=0
	local remove_state=0
	local scanned=0
	local removed=0
	local preserved=0
	local errors=0
	local -a lock_files=()

	[[ -n "$lock_dir" ]] || lock_dir=$(_session_lock_default_dir)
	[[ "$max_entries" =~ ^[1-9][0-9]*$ ]] || max_entries=500
	[[ "$malformed_grace" =~ ^[0-9]+$ ]] || malformed_grace=300
	[[ -d "$lock_dir" ]] || return 0
	now_epoch=$(date +%s)
	lock_files=("$lock_dir"/*.pid)
	[[ -f "${lock_files[0]}" ]] || return 0
	file_count=${#lock_files[@]}
	visit_limit="$max_entries"
	[[ "$visit_limit" -le "$file_count" ]] || visit_limit="$file_count"
	cursor_file="${lock_dir}/.session-lock-sweep-cursor"
	if [[ -f "$cursor_file" ]]; then
		cursor=$(<"$cursor_file") || cursor=0
	fi
	[[ "$cursor" =~ ^[0-9]+$ && "$cursor" -lt "$file_count" ]] || cursor=0

	while [[ "$visited" -lt "$visit_limit" ]]; do
		index=$(((cursor + visited) % file_count))
		lock_file="${lock_files[$index]}"
		visited=$((visited + 1))
		[[ -f "$lock_file" ]] || continue
		scanned=$((scanned + 1))
		raw=$(<"$lock_file") || {
			errors=$((errors + 1))
			continue
		}
		owner_state=0
		_session_lock_owner_state "$raw" || owner_state=$?
		if [[ "$owner_state" -eq 0 ]]; then
			preserved=$((preserved + 1))
			continue
		fi
		if [[ "$owner_state" -eq 2 ]]; then
			preserved=$((preserved + 1))
			continue
		fi
		if [[ "$owner_state" -eq 3 ]]; then
			file_mtime=$(_file_mtime_epoch "$lock_file" 2>/dev/null || printf '0')
			[[ "$file_mtime" =~ ^[0-9]+$ ]] || file_mtime=0
			file_age=$((now_epoch - file_mtime))
			if [[ "$file_mtime" -eq 0 || "$file_age" -lt "$malformed_grace" ]]; then
				preserved=$((preserved + 1))
				continue
			fi
		fi

		remove_state=0
		_session_lock_remove_snapshot "$lock_file" "$raw" || remove_state=$?
		case "$remove_state" in
		0) removed=$((removed + 1)) ;;
		2) preserved=$((preserved + 1)) ;;
		*) errors=$((errors + 1)) ;;
		esac
	done

	cursor_temp="${cursor_file}.$$"
	if ! printf '%s\n' "$(((cursor + visited) % file_count))" >"$cursor_temp" ||
		! mv "$cursor_temp" "$cursor_file"; then
		rm -f "$cursor_temp" 2>/dev/null || true
		errors=$((errors + 1))
	fi

	if [[ -n "${LOGFILE:-}" ]]; then
		printf '[pulse-wrapper] session-lock-cleanup scanned=%s removed=%s preserved=%s errors=%s\n' \
			"$scanned" "$removed" "$preserved" "$errors" >>"$LOGFILE"
	fi
	[[ "$errors" -eq 0 ]]
}
