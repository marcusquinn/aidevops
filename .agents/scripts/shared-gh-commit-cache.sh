#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Immutable GitHub commit response cache for pulse merge readers.

[[ -n "${_SHARED_GH_COMMIT_CACHE_LOADED:-}" ]] && return 0
_SHARED_GH_COMMIT_CACHE_LOADED=1

gh_commit_by_sha_cached() {
	local repo="$1" sha="$2"
	local root="${HOME}/.aidevops/cache/gh-commit" dir="" file="" tmp=""
	# jq expands its own $sha argument.
	# shellcheck disable=SC2016
	local validation='type == "object" and .sha == $sha and (.commit | type == "object")'
	# Unqualified refs and malformed slugs must never select a cache entry.
	if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
		[[ ! "$sha" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
		gh api "repos/${repo}/commits/${sha}"
		return $?
	fi
	dir="${root}/${repo/\//--}"
	file="${dir}/${sha}.json"
	if [[ -f "$file" ]] && jq -e --arg sha "$sha" "$validation" "$file" >/dev/null 2>&1; then
		command cat -- "$file"
		return $?
	fi
	(umask 077; mkdir -p -- "$dir") || return 1
	tmp=$(umask 077; mktemp "${dir}/.commit.XXXXXXXX") || return 1
	if ! gh api "repos/${repo}/commits/${sha}" >"$tmp" ||
		! jq -e --arg sha "$sha" "$validation" "$tmp" >/dev/null 2>&1; then
		rm -f -- "$tmp"
		return 1
	fi
	if ! mv -f -- "$tmp" "$file"; then
		rm -f -- "$tmp"
		return 1
	fi
	command cat -- "$file"
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
