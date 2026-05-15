#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub secondary-rate-limit cooldown guard (GH#23605)
# =============================================================================
# Sourced by shared-gh-wrappers.sh. Provides a small shared state file that all
# gh wrapper call sites can consult before starting noncritical GitHub work.

[[ -n "${_SHARED_GH_SECONDARY_COOLDOWN_LOADED:-}" ]] && return 0
_SHARED_GH_SECONDARY_COOLDOWN_LOADED=1

: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS:=300}"
: "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE:=${HOME:-/tmp}/.aidevops/cache/gh-secondary-cooldown.json}"

_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE=0

_gh_secondary_cooldown_now() {
	date +%s
	return 0
}

_gh_secondary_cooldown_file() {
	printf '%s' "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}"
	return 0
}

_gh_secondary_cooldown_detect() {
	local text="$1"
	printf '%s' "$text" | grep -Eqi 'secondary rate limit|abuse detection mechanism|You have exceeded a secondary rate limit' || return 1
	return 0
}

_gh_secondary_cooldown_request_id() {
	local text="$1"
	local request_id=""
	request_id=$(printf '%s\n' "$text" | sed -nE 's/.*([Xx]-[Gg]it[Hh]ub-[Rr]equest-[Ii]d|request[_ -]?id)[=: ]+([A-Za-z0-9:-]+).*/\2/p' | sed -n '1p')
	printf '%s' "$request_id"
	return 0
}

_gh_secondary_cooldown_write() {
	local reason="$1"
	local response_text="${2:-}"
	local now=""
	local expires=""
	local file=""
	local dir=""
	local request_id=""

	now="$(_gh_secondary_cooldown_now)"
	expires=$((now + AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS))
	file="$(_gh_secondary_cooldown_file)"
	dir="${file%/*}"
	request_id="$(_gh_secondary_cooldown_request_id "$response_text")"
	mkdir -p "$dir" 2>/dev/null || return 1

	if command -v jq >/dev/null 2>&1; then
		jq -n \
			--arg reason "$reason" \
			--arg first_seen "$now" \
			--arg expires_at "$expires" \
			--arg request_id "$request_id" \
			'{reason:$reason, first_seen:($first_seen|tonumber), expires_at:($expires_at|tonumber), last_request_id:$request_id}' >"${file}.tmp" || return 1
	else
		printf '{"reason":"%s","first_seen":%s,"expires_at":%s,"last_request_id":"%s"}\n' \
			"$reason" "$now" "$expires" "$request_id" >"${file}.tmp" || return 1
	fi
	mv "${file}.tmp" "$file" || return 1
	printf '[gh-cooldown] secondary-rate-limit active=true expires_at=%s reason=%s\n' "$expires" "$reason" >&2
	return 0
}

_gh_secondary_cooldown_expires_at() {
	local file=""
	file="$(_gh_secondary_cooldown_file)"
	[[ -f "$file" ]] || return 1
	if command -v jq >/dev/null 2>&1; then
		jq -r '.expires_at // 0' "$file" 2>/dev/null
		return 0
	fi
	sed -nE 's/.*"expires_at"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$file" | sed -n '1p'
	return 0
}

_gh_secondary_cooldown_active() {
	local expires=""
	local now=""
	expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
	[[ "$expires" =~ ^[0-9]+$ ]] || return 1
	now="$(_gh_secondary_cooldown_now)"
	[[ "$expires" -gt "$now" ]] || return 1
	return 0
}

_gh_secondary_cooldown_log_active_once() {
	local op_class="$1"
	local expires=""
	if [[ "$_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE" -eq 1 ]]; then
		return 0
	fi
	expires="$(_gh_secondary_cooldown_expires_at 2>/dev/null || printf 'unknown')"
	printf '[gh-cooldown] secondary-rate-limit active=true skip=%s expires_at=%s\n' "$op_class" "$expires" >&2
	_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE=1
	return 0
}

_gh_secondary_cooldown_preflight() {
	local op_class="${1:-read}"
	if ! _gh_secondary_cooldown_active; then
		return 0
	fi
	if [[ "${AIDEVOPS_GH_SECONDARY_COOLDOWN_OVERRIDE:-0}" == "1" ]]; then
		printf '[gh-cooldown] secondary-rate-limit override=true op=%s actor=%s\n' \
			"$op_class" "${GITHUB_ACTOR:-${USER:-unknown}}" >&2
		return 0
	fi
	_gh_secondary_cooldown_log_active_once "$op_class"
	return 75
}

_gh_secondary_cooldown_record_if_needed() {
	local rc="$1"
	local response_text="${2:-}"
	[[ "$rc" -ne 0 ]] || return 0
	_gh_secondary_cooldown_detect "$response_text" || return 0
	_gh_secondary_cooldown_write "github-secondary-rate-limit" "$response_text" || true
	return 0
}
