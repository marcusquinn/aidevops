#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# gh-merge-cache-remediation-lib.sh — targeted remediation for stale gh HTTP 401 cache entries.

[[ -n "${_GH_MERGE_CACHE_REMEDIATION_LIB_LOADED:-}" ]] && return 0
_GH_MERGE_CACHE_REMEDIATION_LIB_LOADED=1

gh_merge_output_is_auth_401() {
	local merge_output="$1"

	printf '%s' "$merge_output" | grep -qiE '(^|[^0-9])(401)([^0-9]|$)|401 Unauthorized|Requires authentication'
	return $?
}

gh_merge_live_auth_probe_ok() {
	gh api user >/dev/null 2>&1
	return $?
}

gh_merge_cache_quarantine_dir() {
	local cache_root="${GH_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/gh}"
	local stamp=""

	stamp=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%dT%H%M%S')
	printf '%s/aidevops-quarantine-%s' "$cache_root" "$stamp"
	return 0
}

gh_merge_cache_file_has_stale_auth_401() {
	local cache_file="$1"

	[[ -f "$cache_file" ]] || return 1
	grep -Iq . "$cache_file" 2>/dev/null || return 1
	grep -qiE '401 Unauthorized|Requires authentication|"message"[[:space:]]*:[[:space:]]*"Requires authentication"' "$cache_file" 2>/dev/null || return 1
	grep -qiE 'api\.github\.com|graphql|GraphQL|X-Gh-Cache-Ttl|Requires authentication' "$cache_file" 2>/dev/null || return 1
	return 0
}

gh_merge_quarantine_stale_auth_cache() {
	local cache_root="${GH_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/gh}"
	local quarantine_dir=""
	local cache_file=""
	local base_name=""
	local moved=0

	[[ -d "$cache_root" ]] || return 1
	quarantine_dir=$(gh_merge_cache_quarantine_dir)

	while IFS= read -r cache_file; do
		[[ -n "$cache_file" ]] || continue
		case "$cache_file" in
		"$cache_root"/aidevops-quarantine-*) continue ;;
		esac
		if gh_merge_cache_file_has_stale_auth_401 "$cache_file"; then
			mkdir -p "$quarantine_dir" || return 1
			base_name=$(basename "$cache_file")
			if mv "$cache_file" "${quarantine_dir}/${base_name}.$$" 2>/dev/null; then
				moved=$((moved + 1))
			fi
		fi
	done < <(find "$cache_root" -type f -print 2>/dev/null)

	[[ "$moved" -gt 0 ]] || return 1
	printf '%s\n' "$moved"
	return 0
}

gh_merge_remediate_stale_auth_cache() {
	local merge_output="$1"
	local context="${2:-gh pr merge}"
	local log_file="${3:-}"
	local moved=""

	gh_merge_output_is_auth_401 "$merge_output" || return 1
	if ! gh_merge_live_auth_probe_ok; then
		[[ -n "$log_file" ]] && printf '[gh-merge-cache] %s: live gh api user probe failed; treating 401 as current auth failure\n' "$context" >>"$log_file"
		return 1
	fi

	if ! moved=$(gh_merge_quarantine_stale_auth_cache); then
		[[ -n "$log_file" ]] && printf '[gh-merge-cache] %s: live auth succeeded, but no stale gh HTTP 401 cache entries were quarantined\n' "$context" >>"$log_file"
		return 1
	fi

	if [[ -n "$log_file" ]]; then
		printf '[gh-merge-cache] %s: live auth succeeded; quarantined %s stale gh HTTP 401 cache file(s); retrying gh pr merge once\n' "$context" "$moved" >>"$log_file"
	fi
	return 0
}
