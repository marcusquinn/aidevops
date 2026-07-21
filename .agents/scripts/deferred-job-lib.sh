#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared storage, clock, locking, and JSON helpers for deferred jobs.

if [[ -n "${_AIDEVOPS_DEFERRED_JOB_LIB_LOADED:-}" ]]; then
	return 0
fi
_AIDEVOPS_DEFERRED_JOB_LIB_LOADED=1

_DJ_SCHEMA_VERSION=1
_DJ_WORKSPACE_ROOT="${AIDEVOPS_WORKSPACE_DIR:-${HOME:?HOME is required}/.aidevops/.agent-workspace}"
DEFERRED_JOB_ROOT="${AIDEVOPS_DEFERRED_JOB_DIR:-${_DJ_WORKSPACE_ROOT}/scheduled}"
_DJ_JOBS_DIR="${DEFERRED_JOB_ROOT}/jobs"
_DJ_PROMPTS_DIR="${DEFERRED_JOB_ROOT}/prompts"
_DJ_LOGS_DIR="${DEFERRED_JOB_ROOT}/logs"
_DJ_EVENTS_FILE="${_DJ_LOGS_DIR}/events.jsonl"
_DJ_LOCK_DIR="${DEFERRED_JOB_ROOT}/queue.lock"

_dj_now_epoch() {
	if [[ -n "${AIDEVOPS_DEFERRED_NOW_EPOCH:-}" ]]; then
		printf '%s\n' "$AIDEVOPS_DEFERRED_NOW_EPOCH"
		return 0
	fi
	date +%s
	return 0
}

_dj_epoch_to_iso() {
	local epoch="$1"
	local value=""
	value=$(date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
	if [[ -z "$value" ]]; then
		value=$(date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
	fi
	[[ -n "$value" ]] || return 1
	printf '%s\n' "$value"
	return 0
}

_dj_iso_to_epoch() {
	local value="$1"
	local epoch=""
	if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
		return 1
	fi
	epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" '+%s' 2>/dev/null || true)
	if [[ -z "$epoch" ]]; then
		epoch=$(date -u -d "$value" '+%s' 2>/dev/null || true)
	fi
	[[ "$epoch" =~ ^[0-9]+$ ]] || return 1
	if [[ "$(_dj_epoch_to_iso "$epoch")" != "$value" ]]; then
		return 1
	fi
	printf '%s\n' "$epoch"
	return 0
}

_dj_parse_duration() {
	local value="$1"
	local number=""
	local unit=""
	local multiplier=0
	if [[ ! "$value" =~ ^([1-9][0-9]*)(s|m|h|d)$ ]]; then
		return 1
	fi
	number="${BASH_REMATCH[1]}"
	unit="${BASH_REMATCH[2]}"
	case "$unit" in
	s) multiplier=1 ;;
	m) multiplier=60 ;;
	h) multiplier=3600 ;;
	d) multiplier=86400 ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$((number * multiplier))"
	return 0
}

_dj_sha256() {
	local file_path="$1"
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(shasum -a 256 "$file_path" | awk '{print $1}')
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(sha256sum "$file_path" | awk '{print $1}')
	else
		return 1
	fi
	[[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

_dj_producer_version() {
	local version_file="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/../VERSION"
	local version="unknown"
	if [[ -f "$version_file" ]]; then
		IFS= read -r version <"$version_file" || version="unknown"
	fi
	printf '%s\n' "$version"
	return 0
}

_dj_init_storage() {
	umask 077
	mkdir -p "$_DJ_JOBS_DIR" "$_DJ_PROMPTS_DIR" "$_DJ_LOGS_DIR"
	chmod 700 "$DEFERRED_JOB_ROOT" "$_DJ_JOBS_DIR" "$_DJ_PROMPTS_DIR" "$_DJ_LOGS_DIR"
	if [[ ! -f "$_DJ_EVENTS_FILE" ]]; then
		: >"$_DJ_EVENTS_FILE"
	fi
	chmod 600 "$_DJ_EVENTS_FILE"
	return 0
}

_dj_job_file() {
	local job_id="$1"
	printf '%s/%s.json\n' "$_DJ_JOBS_DIR" "$job_id"
	return 0
}

_dj_prompt_file() {
	local job_id="$1"
	printf '%s/%s.prompt\n' "$_DJ_PROMPTS_DIR" "$job_id"
	return 0
}

_dj_valid_job_id() {
	local job_id="$1"
	[[ "$job_id" =~ ^dj-[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]
	return $?
}

_dj_atomic_write_json() {
	local target_file="$1"
	local json_value="$2"
	local target_dir="${target_file%/*}"
	local tmp_file=""
	tmp_file=$(mktemp "${target_dir}/.deferred-job.XXXXXX") || return 1
	if ! printf '%s\n' "$json_value" | jq -e . >"$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	chmod 600 "$tmp_file"
	mv "$tmp_file" "$target_file"
	return 0
}

_dj_read_job() {
	local job_file="$1"
	[[ -f "$job_file" ]] || return 1
	jq -e . "$job_file" 2>/dev/null
	return $?
}

_dj_schema_supported() {
	local job_json="$1"
	local schema_version=""
	schema_version=$(printf '%s\n' "$job_json" | jq -r '.schema_version // 0' 2>/dev/null || true)
	[[ "$schema_version" == "$_DJ_SCHEMA_VERSION" ]]
	return $?
}

_dj_append_event() {
	local job_id="$1"
	local status="$2"
	local event="$3"
	local detail="${4:-}"
	local timestamp=""
	local record=""
	timestamp=$(_dj_epoch_to_iso "$(_dj_now_epoch)") || return 1
	record=$(jq -cn \
		--arg timestamp "$timestamp" \
		--arg job_id "$job_id" \
		--arg status "$status" \
		--arg event "$event" \
		--arg detail "$detail" \
		'{timestamp:$timestamp,job_id:$job_id,status:$status,event:$event,detail:(if $detail == "" then null else $detail end)}') || return 1
	printf '%s\n' "$record" >>"$_DJ_EVENTS_FILE"
	chmod 600 "$_DJ_EVENTS_FILE"
	return 0
}

_dj_acquire_lock() {
	local attempts=0
	local max_attempts="${AIDEVOPS_DEFERRED_LOCK_ATTEMPTS:-200}"
	local now=0
	local acquired=0
	local age=0
	while [[ "$attempts" -lt "$max_attempts" ]]; do
		if mkdir "$_DJ_LOCK_DIR" 2>/dev/null; then
			printf '%s\n' "$$" >"${_DJ_LOCK_DIR}/pid"
			_dj_now_epoch >"${_DJ_LOCK_DIR}/epoch"
			return 0
		fi
		now=$(_dj_now_epoch)
		if [[ -f "${_DJ_LOCK_DIR}/epoch" ]]; then
			IFS= read -r acquired <"${_DJ_LOCK_DIR}/epoch" || acquired=0
		fi
		[[ "$acquired" =~ ^[0-9]+$ ]] || acquired=0
		age=$((now - acquired))
		if [[ "$age" -gt 30 ]]; then
			rm -f "${_DJ_LOCK_DIR}/pid" "${_DJ_LOCK_DIR}/epoch" 2>/dev/null || true
			rmdir "$_DJ_LOCK_DIR" 2>/dev/null || true
		fi
		attempts=$((attempts + 1))
		sleep 0.05
	done
	printf 'ERROR: deferred-job queue lock is busy\n' >&2
	return 1
}

_dj_release_lock() {
	rm -f "${_DJ_LOCK_DIR}/pid" "${_DJ_LOCK_DIR}/epoch" 2>/dev/null || true
	rmdir "$_DJ_LOCK_DIR" 2>/dev/null || true
	return 0
}

_dj_canonical_dir() {
	local dir_path="$1"
	[[ -d "$dir_path" ]] || return 1
	(
		cd "$dir_path" || exit 1
		pwd -P
	)
	return $?
}

_dj_origin_slug() {
	local worktree_path="$1"
	local remote_url=""
	remote_url=$(git -C "$worktree_path" remote get-url origin 2>/dev/null || true)
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}
