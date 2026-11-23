#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Immutable GitHub commit response cache for pulse merge readers.

[[ -n "${_SHARED_GH_COMMIT_CACHE_LOADED:-}" ]] && return 0
_SHARED_GH_COMMIT_CACHE_LOADED=1

_gh_commit_fetch() {
	local endpoint="$1"
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read gh api "$endpoint"
	else
		gh api "$endpoint"
	fi
	return $?
}

gh_commit_by_sha_cached() {
	local repo="$1" sha="$2"
	local root="${HOME}/.aidevops/cache/gh-commit" dir="" file="" tmp="" response=""
	# jq expands its own $sha argument.
	# shellcheck disable=SC2016
	local validation='type == "object" and .sha == $sha and (.commit | type == "object")'
	# Unqualified refs and malformed slugs must never select a cache entry.
	if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
		[[ ! "$sha" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
		_gh_commit_fetch "repos/${repo}/commits/${sha}"
		return $?
	fi
	dir="${root}/${repo/\//--}"
	file="${dir}/${sha}.json"
	if [[ -f "$file" ]] && jq -e --arg sha "$sha" "$validation" "$file" >/dev/null 2>&1; then
		command cat -- "$file"
		return $?
	fi
	if ! response=$(_gh_commit_fetch "repos/${repo}/commits/${sha}") ||
		! printf '%s\n' "$response" | jq -e --arg sha "$sha" "$validation" >/dev/null 2>&1; then
		return 1
	fi
	# Persistence is optional: a validated GitHub response remains usable even
	# when directory creation, temporary writes or atomic publication fail.
	if (umask 077; mkdir -p -- "$dir") 2>/dev/null &&
		tmp=$(umask 077; mktemp "${dir}/.commit.XXXXXXXX" 2>/dev/null); then
		if printf '%s\n' "$response" >"$tmp" && mv -f -- "$tmp" "$file"; then
			: # Published atomically with the private mktemp mode.
		fi
		rm -f -- "$tmp"
	fi
	printf '%s\n' "$response"
	return $?
}

# Per-process memo of the authenticated login (`gh api user`). Call without a
# command substitution (it would discard the memo): the result is written to
# the variable named by $1. Failed or empty lookups are never memoized.
_AIDEVOPS_GH_AUTH_LOGIN_MEMO=""
gh_authenticated_login_cached() {
	local out_var="$1"
	# Distinct local name: bash dynamic scope would shadow a caller variable
	# named like a local when printf -v writes back.
	local _ghalc_value="${_AIDEVOPS_GH_AUTH_LOGIN_MEMO:-}"
	if [[ -z "$_ghalc_value" ]]; then
		_ghalc_value=$(gh api user --jq '.login // ""' 2>/dev/null) || _ghalc_value=""
		[[ -n "$_ghalc_value" ]] || return 1
		_AIDEVOPS_GH_AUTH_LOGIN_MEMO="$_ghalc_value"
	fi
	printf -v "$out_var" '%s' "$_ghalc_value"
	return 0
}
