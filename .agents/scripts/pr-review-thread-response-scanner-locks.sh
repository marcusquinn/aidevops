#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Review-thread scanner state paths, cursors, dispatch locks and global capacity.
# Source from pr-review-thread-response-scanner.sh after its shared configuration.
# Functions depend on the orchestrator's _prrts_* utilities and shared constants.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PRRTS_LOCKS_LOADED:-}" ]] && return 0
_PRRTS_LOCKS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_prrts_locks_path="${BASH_SOURCE[0]%/*}"
	[[ "$_prrts_locks_path" == "${BASH_SOURCE[0]}" ]] && _prrts_locks_path="."
	SCRIPT_DIR="$(cd "$_prrts_locks_path" && pwd)"
	unset _prrts_locks_path
fi

_prrts_state_file() {
	local repo_slug="$1"
	local pr_number="$2"
	local safe_slug=""
	safe_slug="$(_prrts_safe_slug "$repo_slug")"
	printf '%s/%s-%s.state\n' "$STATE_DIR" "$safe_slug" "$pr_number"
	return 0
}

_prrts_outcome_file() {
	local repo_slug="$1"
	local pr_number="$2"
	local safe_slug=""
	safe_slug="$(_prrts_safe_slug "$repo_slug")"
	printf '%s/%s-%s.outcome\n' "$STATE_DIR" "$safe_slug" "$pr_number"
	return 0
}

_prrts_attempt_state_file() {
	local repo_slug="$1"
	local pr_number="$2"
	local outcome_id="$3"
	local safe_slug=""
	local safe_outcome_id=""
	safe_slug="$(_prrts_safe_slug "$repo_slug")"
	safe_outcome_id=$(printf '%s' "$outcome_id" | tr -c '[:alnum:]_.-' '-')
	[[ -n "$safe_outcome_id" ]] || return 1
	printf '%s/%s-%s-%s.attempt.json\n' "$STATE_DIR" "$safe_slug" "$pr_number" "$safe_outcome_id"
	return 0
}

_prrts_lock_dir() {
	local repo_slug="$1"
	local pr_number="$2"
	local safe_slug=""
	safe_slug="$(_prrts_safe_slug "$repo_slug")"
	printf '%s/%s-%s.lock\n' "$STATE_DIR" "$safe_slug" "$pr_number"
	return 0
}

_prrts_cursor_file() {
	local repo_slug="$1"
	local safe_slug=""
	safe_slug="$(_prrts_safe_slug "$repo_slug")"
	printf '%s/%s-cursor.state\n' "$STATE_DIR" "$safe_slug"
	return 0
}

_prrts_read_cursor() {
	local repo_slug="$1"
	local cursor_var="$2"
	local cursor_file="" cursor_key="" cursor_line_value="" cursor_value=""
	cursor_file="$(_prrts_cursor_file "$repo_slug")"
	if [[ -f "$cursor_file" ]]; then
		while IFS='=' read -r cursor_key cursor_line_value; do
			case "$cursor_key" in
			pr_number) cursor_value="$cursor_line_value" ;;
			esac
		done <"$cursor_file"
	fi
	[[ "$cursor_value" =~ ^[0-9]+$ ]] || cursor_value=""
	printf -v "$cursor_var" '%s' "$cursor_value"
	return 0
}

_prrts_write_cursor() {
	local repo_slug="$1"
	local pr_number="$2"
	local cursor_file="" cursor_tmp=""
	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	_prrts_ensure_dirs
	cursor_file="$(_prrts_cursor_file "$repo_slug")"
	cursor_tmp="${cursor_file}.$$"
	{
		printf 'pr_number=%s\n' "$pr_number"
		printf 'updated_at=%s\n' "$(date +%s)"
	} >"$cursor_tmp"
	mv "$cursor_tmp" "$cursor_file"
	return 0
}

_prrts_rotate_candidates_after_cursor() {
	local candidates="$1"
	local cursor="$2"
	if [[ -z "$cursor" || ! "$cursor" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$candidates"
		return 0
	fi
	printf '%s\n' "$candidates" | awk -F '\t' -v cursor="$cursor" '
		{
			rows[++count] = $0
			if ($(1) == cursor) {
				cursor_index = count
			}
		}
		END {
			if (cursor_index > 0 && cursor_index < count) {
				for (i = cursor_index + 1; i <= count; i++) print rows[i]
				for (i = 1; i <= cursor_index; i++) print rows[i]
			} else {
				for (i = 1; i <= count; i++) print rows[i]
			}
		}
	'
	return 0
}

_prrts_write_lock_metadata() {
	local lock_dir="$1"
	local now_epoch="$2"
	local metadata_tmp="${lock_dir}/metadata.$$"
	local owner_argv_hash="" owner_process_start=""
	owner_argv_hash=$(_compute_argv_hash "$$" 2>/dev/null || true)
	owner_process_start=$(_process_start_token "$$" 2>/dev/null || true)
	{
		printf 'pid=%s\n' "$$"
		printf 'created_at=%s\n' "$now_epoch"
		[[ -n "$owner_argv_hash" ]] && printf 'owner_argv_hash=%s\n' "$owner_argv_hash"
		[[ -n "$owner_process_start" ]] && printf 'owner_process_start=%s\n' "$owner_process_start"
	} >"$metadata_tmp"
	mv "$metadata_tmp" "${lock_dir}/metadata"
	return 0
}

_prrts_lock_is_stale() {
	local lock_dir="$1"
	local now_epoch="$2"
	local stale_after="" metadata_file="" created_at="0" key="" value="" age_seconds="0"
	local owner_pid="" owner_argv_hash="" owner_process_start=""
	local current_argv_hash="" current_process_start=""
	stale_after="$(_prrts_normalise_int "$PR_REVIEW_THREAD_RESPONSE_LOCK_STALE" "600" "60")"
	metadata_file="${lock_dir}/metadata"
	[[ -f "$metadata_file" ]] || return 1
	while IFS='=' read -r key value; do
		case "$key" in
		pid) owner_pid="$value" ;;
		created_at) created_at="$value" ;;
		owner_argv_hash) owner_argv_hash="$value" ;;
		owner_process_start) owner_process_start="$value" ;;
		esac
	done <"$metadata_file"
	if [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]]; then
		if ! kill -0 "$owner_pid" 2>/dev/null; then
			return 0
		fi
		if [[ -n "$owner_process_start" ]]; then
			current_process_start=$(_process_start_token "$owner_pid" 2>/dev/null || true)
			if [[ -n "$current_process_start" ]]; then
				[[ "$current_process_start" == "$owner_process_start" ]] || return 0
				if [[ -n "$owner_argv_hash" ]]; then
					current_argv_hash=$(_compute_argv_hash "$owner_pid" 2>/dev/null || true)
					if [[ -n "$current_argv_hash" ]]; then
						[[ "$current_argv_hash" == "$owner_argv_hash" ]] || return 0
					fi
				fi
				return 1
			fi
		fi
		if [[ -n "$owner_argv_hash" ]]; then
			current_argv_hash=$(_compute_argv_hash "$owner_pid" 2>/dev/null || true)
			if [[ -n "$current_argv_hash" ]]; then
				[[ "$current_argv_hash" == "$owner_argv_hash" ]] && return 1
				return 0
			fi
		fi
	fi
	[[ "$created_at" =~ ^[0-9]+$ ]] || return 1
	age_seconds=$((now_epoch - created_at))
	[[ "$age_seconds" -ge "$stale_after" ]]
	return $?
}

_prrts_remove_lock_dir() {
	local lock_dir="$1"
	[[ -n "$lock_dir" && "$lock_dir" == "${STATE_DIR}/"* && -d "$lock_dir" ]] || return 0
	rm -rf "$lock_dir"
	return 0
}

_prrts_global_capacity_lock_dir() {
	printf '%s/global-capacity.lock\n' "$STATE_DIR"
	return 0
}

_prrts_global_capacity_lease_dir() {
	printf '%s/global-capacity-leases\n' "$STATE_DIR"
	return 0
}

_prrts_global_capacity_lease_path() {
	local repo_slug="$1"
	local pr_number="$2"
	local safe_slug=""
	safe_slug="$(_prrts_safe_slug "$repo_slug")"
	printf '%s/%s-%s.lease\n' "$(_prrts_global_capacity_lease_dir)" "$safe_slug" "$pr_number"
	return 0
}

_prrts_capacity_file_value() {
	local file="$1"
	local expected_key="$2"
	[[ -f "$file" ]] || return 0
	local key=""
	local value=""
	while IFS='=' read -r key value; do
		if [[ "$key" == "$expected_key" ]]; then
			printf '%s' "$value"
			return 0
		fi
	done <"$file"
	return 0
}

_prrts_acquire_global_capacity_mutex() {
	local lock_var="$1"
	local lock_dir=""
	lock_dir="$(_prrts_global_capacity_lock_dir)"
	local attempt=1
	while [[ $attempt -le 40 ]]; do
		if mkdir "$lock_dir" 2>/dev/null; then
			printf 'pid=%s\n' "$$" >"${lock_dir}/owner"
			printf -v "$lock_var" '%s' "$lock_dir"
			return 0
		fi
		local lock_pid=""
		lock_pid="$(_prrts_capacity_file_value "${lock_dir}/owner" pid)"
		if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
			local stale_lock="${lock_dir}.stale.$$"
			if mv "$lock_dir" "$stale_lock" 2>/dev/null; then
				rm -rf "$stale_lock"
				continue
			fi
		fi
		sleep 0.05
		attempt=$((attempt + 1))
	done
	return 1
}

_prrts_release_global_capacity_mutex() {
	local lock_dir="$1"
	[[ -n "$lock_dir" && "$lock_dir" == "${STATE_DIR}/global-capacity.lock" && -d "$lock_dir" ]] || return 0
	local lock_pid=""
	lock_pid="$(_prrts_capacity_file_value "${lock_dir}/owner" pid)"
	[[ "$lock_pid" == "$$" ]] || return 1
	rm -rf "$lock_dir"
	return 0
}

_prrts_global_capacity_lease_is_active() {
	local lease="$1"
	local now_epoch="$2"
	local ttl="$3"
	local lease_pid="" created_at="0" age=0
	lease_pid="$(_prrts_capacity_file_value "$lease" pid)"
	created_at="$(_prrts_capacity_file_value "$lease" created_at)"
	[[ "$lease_pid" =~ ^[0-9]+$ && "$created_at" =~ ^[0-9]+$ ]] || return 1
	age=$((now_epoch - created_at))
	[[ "$age" -ge 0 ]] || return 1
	kill -0 "$lease_pid" 2>/dev/null || return 1
	[[ "$age" -lt "$ttl" ]] && return 0
	local session_key="" process_command=""
	session_key="$(_prrts_capacity_file_value "$lease" session_key)"
	[[ -n "$session_key" ]] || return 1
	process_command=$(ps -p "$lease_pid" -o command= 2>/dev/null || true)
	case "$process_command" in
	*"$session_key"*) return 0 ;;
	esac
	return 1
}

# Reserve one authoritative global thread-response worker slot.
# Args: repo_slug pr_number session_key output_var
# Returns: 0 reserved, PRRTS_RC_DISPATCH_DEFERRED when full/unavailable.
_prrts_reserve_global_capacity() {
	local repo_slug="$1"
	local pr_number="$2"
	local session_key="$3"
	local output_var="$4"
	_prrts_ensure_dirs
	local lease_dir=""
	lease_dir="$(_prrts_global_capacity_lease_dir)"
	mkdir -p "$lease_dir" 2>/dev/null || return "$PRRTS_RC_DISPATCH_DEFERRED"
	chmod 700 "$lease_dir" 2>/dev/null || true
	local capacity_lock=""
	if ! _prrts_acquire_global_capacity_mutex capacity_lock; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} deferred — global worker reservation lock unavailable"
		return "$PRRTS_RC_DISPATCH_DEFERRED"
	fi

	local now_epoch=""
	now_epoch="$(date +%s)"
	local ttl=""
	ttl="$(_prrts_normalise_int "$PR_REVIEW_THREAD_RESPONSE_GLOBAL_LEASE_TTL" "14400" "60")"
	local active=0
	local lease=""
	for lease in "${lease_dir}"/*.lease; do
		[[ -f "$lease" ]] || continue
		if ! _prrts_global_capacity_lease_is_active "$lease" "$now_epoch" "$ttl"; then
			rm -f "$lease"
			continue
		fi
		active=$((active + 1))
	done

	local max_global=""
	max_global="$(_prrts_normalise_int "$PR_REVIEW_THREAD_RESPONSE_MAX_GLOBAL" "6" "1")"
	local lease_path=""
	lease_path="$(_prrts_global_capacity_lease_path "$repo_slug" "$pr_number")"
	if [[ -f "$lease_path" ]]; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} deferred — global worker reservation already active"
		_prrts_release_global_capacity_mutex "$capacity_lock" || true
		return "$PRRTS_RC_DISPATCH_DEFERRED"
	fi
	if [[ "$active" -ge "$max_global" ]]; then
		_prrts_log "dispatch: global worker limit reached (${active}/${max_global} active); deferring ${repo_slug}#${pr_number}"
		_prrts_release_global_capacity_mutex "$capacity_lock" || true
		return "$PRRTS_RC_DISPATCH_DEFERRED"
	fi

	local reservation_tmp="${lease_path}.tmp.$$"
	{
		printf 'pid=%s\n' "$$"
		printf 'created_at=%s\n' "$now_epoch"
		printf 'session_key=%s\n' "$session_key"
	} >"$reservation_tmp"
	if ! mv "$reservation_tmp" "$lease_path"; then
		rm -f "$reservation_tmp"
		_prrts_release_global_capacity_mutex "$capacity_lock" || true
		return "$PRRTS_RC_DISPATCH_DEFERRED"
	fi
	_prrts_release_global_capacity_mutex "$capacity_lock" || true
	printf -v "$output_var" '%s' "$lease_path"
	return 0
}

_prrts_activate_global_capacity() {
	local reservation_file="$1"
	local worker_pid="$2"
	local session_key="$3"
	[[ -f "$reservation_file" && "$worker_pid" =~ ^[0-9]+$ ]] || return 1
	local created_at=""
	created_at="$(_prrts_capacity_file_value "$reservation_file" created_at)"
	[[ "$created_at" =~ ^[0-9]+$ ]] || return 1
	local reservation_tmp="${reservation_file}.tmp.$$"
	{
		printf 'pid=%s\n' "$worker_pid"
		printf 'created_at=%s\n' "$created_at"
		printf 'session_key=%s\n' "$session_key"
	} >"$reservation_tmp"
	mv "$reservation_tmp" "$reservation_file" || {
		rm -f "$reservation_tmp"
		return 1
	}
	return 0
}

_prrts_release_global_capacity() {
	local reservation_file="$1"
	local expected_pid="$2"
	[[ -f "$reservation_file" && "$reservation_file" == "${STATE_DIR}/global-capacity-leases/"*.lease ]] || return 0
	local lease_pid=""
	lease_pid="$(_prrts_capacity_file_value "$reservation_file" pid)"
	[[ "$lease_pid" == "$expected_pid" ]] || return 1
	rm -f "$reservation_file"
	return 0
}

_prrts_acquire_dispatch_lock() {
	local repo_slug="$1"
	local pr_number="$2"
	local lock_var="$3"
	local lock_path="" now_epoch="" stale_rename=""
	_prrts_ensure_dirs
	lock_path="$(_prrts_lock_dir "$repo_slug" "$pr_number")"
	now_epoch="$(date +%s)"
	if mkdir "$lock_path" 2>/dev/null; then
		_prrts_write_lock_metadata "$lock_path" "$now_epoch"
		printf -v "$lock_var" '%s' "$lock_path"
		return 0
	fi
	if _prrts_lock_is_stale "$lock_path" "$now_epoch"; then
		_prrts_log "dispatch: ${repo_slug}#${pr_number} removing stale dispatch lock"
		stale_rename="${lock_path}.stale.$$"
		if mv "$lock_path" "$stale_rename"; then
			_prrts_remove_lock_dir "$stale_rename"
			if mkdir "$lock_path" 2>/dev/null; then
				_prrts_write_lock_metadata "$lock_path" "$now_epoch"
				printf -v "$lock_var" '%s' "$lock_path"
				return 0
			fi
		fi
	fi
	_prrts_log "dispatch: ${repo_slug}#${pr_number} skipped — dispatch lock already held"
	return "$PRRTS_RC_DISPATCH_DEFERRED"
}

_prrts_session_key() {
	local repo_slug="$1"
	local pr_number="$2"
	local safe_slug=""
	safe_slug="$(_prrts_safe_slug "$repo_slug")"
	printf 'pr-review-thread-response-%s-%s\n' "$safe_slug" "$pr_number"
	return 0
}

_prrts_worker_active() {
	local repo_slug="$1"
	local pr_number="$2"
	local session_key="" process_command=""
	session_key="$(_prrts_session_key "$repo_slug" "$pr_number")"
	while IFS= read -r process_command; do
		case "$process_command" in
		*"$session_key"*) return 0 ;;
		esac
	done < <(ps axwwo command 2>/dev/null || true)
	return 1
}
