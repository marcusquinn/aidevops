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
