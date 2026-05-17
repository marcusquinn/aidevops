#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-pr-list-cache.sh — Semantics-preserving per-cycle PR list provider cache.

[[ -n "${_PULSE_PR_LIST_CACHE_LOADED:-}" ]] && return 0
_PULSE_PR_LIST_CACHE_LOADED=1

#######################################
# Return 0 when the pulse PR-list provider cache is enabled.
#######################################
_pulse_pr_list_cache_enabled() {
	[[ "${PULSE_PR_LIST_PROVIDER_CACHE_DISABLE:-0}" == "1" ]] && return 1
	local ttl="${PULSE_PR_LIST_PROVIDER_CACHE_TTL:-3600}"
	[[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]] || return 1
	return 0
}

#######################################
# Record provider cache routing decisions when gh wrapper telemetry is loaded.
# Arguments:
#   $1 - route decision
#######################################
_pulse_pr_list_cache_record() {
	local decision="$1"
	if command -v gh_record_call >/dev/null 2>&1; then
		gh_record_call other pulse_pr_list_provider_cache unknown other "$decision" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Build a stable exact-argv key. This provider is intentionally exact-output:
# it never projects or reinterprets gh_pr_list data, so GraphQL-only fields keep
# the same semantics as the underlying wrapper call.
#######################################
_pulse_pr_list_cache_key() {
	local joined=""
	local arg=""
	for arg in "$@"; do
		joined="${joined}${arg}"$'\034'
	done
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 <<<"$joined" | cut -d ' ' -f 1
		return 0
	fi
	if command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 <<<"$joined" | while read -r _prefix digest; do printf '%s\n' "$digest"; done
		return 0
	fi
	local sum=""
	read -r sum _rest <<<"$(cksum <<<"$joined")"
	printf '%s\n' "$sum"
	return 0
}

#######################################
# Resolve the cache path for an exact gh_pr_list argv shape.
#######################################
_pulse_pr_list_cache_path() {
	local dir="${PULSE_PR_LIST_PROVIDER_CACHE_DIR:-${TMPDIR:-/tmp}/aidevops-pulse-pr-list-provider-${$}}"
	local key=""
	mkdir -p "$dir" 2>/dev/null || return 1
	key="$(_pulse_pr_list_cache_key "$@")" || return 1
	printf '%s/pr-list-%s.out' "$dir" "$key"
	return 0
}

#######################################
# Read a fresh exact-output PR list response from the provider cache.
#######################################
_pulse_pr_list_cache_get() {
	_pulse_pr_list_cache_enabled || return 1
	local ttl="${PULSE_PR_LIST_PROVIDER_CACHE_TTL:-3600}"
	local path=""
	path="$(_pulse_pr_list_cache_path "$@")" || { _pulse_pr_list_cache_record bypass; return 1; }
	[[ -f "$path" ]] || { _pulse_pr_list_cache_record miss; return 1; }
	local now="" mtime="" age=""
	now=$(date +%s 2>/dev/null || printf '0')
	mtime=$(perl -e 'print((stat($ARGV[0]))[9] || 0)' "$path" 2>/dev/null || printf '0')
	[[ "$now" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ ]] || return 1
	age=$((now - mtime))
	[[ "$age" -ge 0 && "$age" -le "$ttl" ]] || { _pulse_pr_list_cache_record stale; return 1; }
	_pulse_pr_list_cache_record hit
	printf '%s' "$(<"$path")"
	return 0
}

#######################################
# Store a successful exact-output PR list response.
# Arguments:
#   $1 - command output
#   $@ - original gh_pr_list argv after shifting output
#######################################
_pulse_pr_list_cache_put() {
	local body="$1"
	shift
	_pulse_pr_list_cache_enabled || return 0
	local path="" dir="" tmp=""
	path="$(_pulse_pr_list_cache_path "$@")" || return 0
	dir="${path%/*}"
	tmp=$(mktemp "${dir}/.pr-list-provider.XXXXXX" 2>/dev/null) || return 0
	printf '%s' "$body" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
	mv "$tmp" "$path" 2>/dev/null || rm -f "$tmp"
	_pulse_pr_list_cache_record store
	return 0
}

#######################################
# Semantics-preserving PR list provider. It delegates misses to gh_pr_list and
# caches the exact output. Use this inside one pulse cycle for hot paths that
# repeatedly request the same PR list shape, including GraphQL-only fields such
# as reviewDecision.
#######################################
pulse_pr_list_get() {
	local cached_output=""
	if cached_output="$(_pulse_pr_list_cache_get "$@" 2>/dev/null)"; then
		printf '%s' "$cached_output"
		return 0
	fi
	local output=""
	output="$(gh_pr_list "$@")"
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		_pulse_pr_list_cache_put "$output" "$@"
		printf '%s' "$output"
	fi
	return "$rc"
}

return 0
