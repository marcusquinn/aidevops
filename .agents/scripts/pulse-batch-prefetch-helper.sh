#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-batch-prefetch-helper.sh — Batch prefetch via org-level gh search
# =============================================================================
# Groups pulse-enabled repos by owner and runs one `gh search issues` +
# one `gh search prs` per owner, splitting results into per-slug cache
# files. This is L3 in the layered cache hierarchy:
#
#   L1: State fingerprint (t2041) — 0 API calls, local hash comparison
#   L2: Idle skip (t2098)         — 0 API calls, reads L4 cache
#   L3: Batch prefetch (THIS)     — 2 calls per owner via Search API
#   L4: Delta prefetch (GH#15286) — 2 calls per repo for changes since last fetch
#   L5: Per-PR enrichment         — 1 call per repo with open PRs (GraphQL)
#
# Usage:
#   pulse-batch-prefetch-helper.sh refresh              # Fetch and cache
#   pulse-batch-prefetch-helper.sh cache-path --kind issues --slug owner/repo
#   pulse-batch-prefetch-helper.sh clear                # Wipe cache
#   pulse-batch-prefetch-helper.sh status               # Show cache ages
#
# Feature flag: PULSE_BATCH_PREFETCH_ENABLED (default: 1)
# When 0, all subcommands exit 0 immediately (no-op).
#
# GH#19963: Reduces GraphQL consumption by using the separate Search API
# rate-limit bucket (30/min = 1800/hr, currently near 0 usage).
#
# Part of aidevops framework: https://aidevops.sh
# =============================================================================

set -euo pipefail

# --- Bash 3.2 re-exec guard (macOS compatibility) ---
# shellcheck disable=SC2292
if [ "${AIDEVOPS_BASH_REEXECED:-}" != "1" ]; then
	_modern_bash=""
	if [ -x "/opt/homebrew/bin/bash" ]; then
		_modern_bash="/opt/homebrew/bin/bash"
	elif [ -x "/usr/local/bin/bash" ]; then
		_modern_bash="/usr/local/bin/bash"
	fi
	if [ -n "$_modern_bash" ]; then
		_major="${BASH_VERSINFO[0]:-3}"
		if [ "$_major" -lt 4 ]; then
			export AIDEVOPS_BASH_REEXECED=1
			exec "$_modern_bash" "$0" "$@"
		fi
	fi
	unset _modern_bash
fi

# --- Constants ---
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

# Source shared constants for colors and helpers
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# --- Configuration ---
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
BATCH_CACHE_DIR="${PULSE_BATCH_PREFETCH_CACHE_DIR:-${HOME}/.aidevops/logs/batch-prefetch}"
PULSE_BATCH_PREFETCH_ENABLED="${PULSE_BATCH_PREFETCH_ENABLED:-1}"
PULSE_PREFETCH_FULL_SWEEP_INTERVAL="${PULSE_PREFETCH_FULL_SWEEP_INTERVAL:-14400}"
BATCH_SEARCH_LIMIT="${PULSE_BATCH_SEARCH_LIMIT:-200}"
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse-wrapper.log}"

# String constants to avoid repeated-literal ratchet violations
_KIND_ISSUES="issues"
_KIND_PRS="prs"
_JSON_NULL="null"
_JSON_EMPTY_OBJ="{}"
_JSON_EMPTY_ARR="[]"

# --- Feature flag gate ---
_check_enabled() {
	if [[ "$PULSE_BATCH_PREFETCH_ENABLED" != "1" ]]; then
		return 1
	fi
	return 0
}

# --- Logging ---
_log() {
	local msg="$1"
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	echo "[${ts}] [pulse-batch-prefetch] ${msg}" >>"$LOGFILE"
	return 0
}

# --- Search API rate-limit detection ---
# The Search API uses a separate rate-limit bucket from GraphQL.
# Detection patterns differ from GraphQL patterns in _pulse_gh_err_is_rate_limit.
_is_search_rate_limited() {
	local err_file="$1"
	[[ -n "$err_file" && -s "$err_file" ]] || return 1
	grep -qiE 'Search rate limit exceeded|search API rate limit|HTTP 422.*abuse detection|secondary rate limit|was submitted too quickly' "$err_file"
}

# --- Owner grouping ---
# Read repos.json and group pulse-enabled, non-local-only repos by owner.
# Output: one line per owner with pipe-separated slugs.
# Format: owner|slug1,slug2,slug3
_group_repos_by_owner() {
	local repos_json="$1"
	[[ -f "$repos_json" ]] || return 1

	jq -r '
		[.initialized_repos[] |
			select(.pulse == true and (.local_only // false) == false and .slug != "") |
			.slug
		] |
		group_by(split("/")[0]) |
		map(
			(.[0] | split("/")[0]) + "|" + (map(.) | join(","))
		) |
		.[]
	' "$repos_json" 2>/dev/null
	return 0
}

# --- Normalization ---
# Map gh search output to the same schema as _prefetch_cache_set expects.
# gh search returns .repository.nameWithOwner but not .createdAt or .author
# for issues. We add null placeholders so downstream consumers don't break.
#
# Arguments:
#   $1 - kind: "issues" or "prs"
# Input: JSON array on stdin (from gh search)
# Output: JSON object keyed by slug, each value an array of normalized items
_normalize_search_to_prefetch_schema() {
	local kind="$1"

	if [[ "$kind" == "$_KIND_ISSUES" ]]; then
		jq '
			group_by(.repository.nameWithOwner) |
			map({
				key: (.[0].repository.nameWithOwner),
				value: [.[] | {
					number: .number,
					title: .title,
					labels: .labels,
					updatedAt: .updatedAt,
					assignees: .assignees
				}]
			}) |
			from_entries
		' 2>/dev/null
	else
		# PRs: preserve headRefName if available
		jq '
			group_by(.repository.nameWithOwner) |
			map({
				key: (.[0].repository.nameWithOwner),
				value: [.[] | {
					number: .number,
					title: .title,
					labels: (.labels // []),
					updatedAt: .updatedAt,
					assignees: (.assignees // []),
					headRefName: (.headRefName // null),
					createdAt: (.createdAt // null),
					author: (.author // null)
				}]
			}) |
			from_entries
		' 2>/dev/null
	fi
	return 0
}

# --- Cache file path ---
# Generate deterministic cache file path for a slug+kind combo.
# Slug slashes are replaced with double dashes for filesystem safety.
_cache_file_path() {
	local kind="$1"
	local slug="$2"
	local safe_slug="${slug//\//__}"
	echo "${BATCH_CACHE_DIR}/${kind}-${safe_slug}.json"
	return 0
}

# --- Write per-slug cache files ---
# Takes normalized JSON (keyed by slug) and writes individual cache files.
_write_per_slug_caches() {
	local kind="$1"
	local normalized_json="$2"

	local slugs
	slugs=$(echo "$normalized_json" | jq -r 'keys[]' 2>/dev/null) || return 1

	local slug
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local cache_file
		cache_file=$(_cache_file_path "$kind" "$slug")
		local ts
		ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		echo "$normalized_json" | jq --arg slug "$slug" --arg ts "$ts" '{
			timestamp: $ts,
			items: .[$slug]
		}' >"$cache_file" 2>/dev/null || {
			_log "WARNING: failed to write cache for ${kind}/${slug}"
		}
	done <<<"$slugs"
	return 0
}

# =============================================================================
# Subcommand: refresh — per-owner fetch helpers
# =============================================================================

# Fetch and cache issues for a single owner.
# Sets _OWNER_SEARCH_CALLS, _OWNER_CACHE_WRITES, _OWNER_ERRORS (Bash 3.2 namerefs workaround)
# Arguments: $1=owner
_refresh_owner_issues() {
	local owner="$1"
	local issue_err
	issue_err=$(mktemp)
	local issue_json=""
	issue_json=$(gh search issues --owner "$owner" --state open \
		--limit "$BATCH_SEARCH_LIMIT" \
		--json number,title,labels,updatedAt,assignees,repository 2>"$issue_err") || issue_json=""
	_OWNER_SEARCH_CALLS=$((_OWNER_SEARCH_CALLS + 1))

	if [[ -z "$issue_json" || "$issue_json" == "$_JSON_NULL" ]]; then
		local issue_err_msg
		issue_err_msg=$(cat "$issue_err" 2>/dev/null || echo "unknown error")
		if _is_search_rate_limited "$issue_err"; then
			_log "Search API rate-limited during issues fetch for owner=${owner} — falling through to per-repo GraphQL"
		else
			_log "gh search issues failed for owner=${owner}: ${issue_err_msg}"
		fi
		_OWNER_ERRORS=$((_OWNER_ERRORS + 1))
		rm -f "$issue_err"
		return 1
	fi
	rm -f "$issue_err"

	local normalized_issues
	normalized_issues=$(echo "$issue_json" | _normalize_search_to_prefetch_schema "$_KIND_ISSUES")
	if [[ -n "$normalized_issues" && "$normalized_issues" != "$_JSON_NULL" && "$normalized_issues" != "$_JSON_EMPTY_OBJ" ]]; then
		_write_per_slug_caches "$_KIND_ISSUES" "$normalized_issues"
		local issue_slug_count
		issue_slug_count=$(echo "$normalized_issues" | jq 'keys | length' 2>/dev/null) || issue_slug_count=0
		_OWNER_CACHE_WRITES=$((_OWNER_CACHE_WRITES + issue_slug_count))
		_log "issues refresh for owner=${owner}: ${issue_slug_count} slug caches written"
	fi
	return 0
}

# Fetch and cache PRs for a single owner.
# Sets _OWNER_SEARCH_CALLS, _OWNER_CACHE_WRITES, _OWNER_ERRORS
# Arguments: $1=owner
_refresh_owner_prs() {
	local owner="$1"
	local pr_err
	pr_err=$(mktemp)
	local pr_json=""
	pr_json=$(gh search prs --owner "$owner" --state open \
		--limit "$BATCH_SEARCH_LIMIT" \
		--json number,title,labels,updatedAt,assignees,repository,headRefName,createdAt,author 2>"$pr_err") || pr_json=""
	_OWNER_SEARCH_CALLS=$((_OWNER_SEARCH_CALLS + 1))

	if [[ -z "$pr_json" || "$pr_json" == "$_JSON_NULL" ]]; then
		local pr_err_msg
		pr_err_msg=$(cat "$pr_err" 2>/dev/null || echo "unknown error")
		if _is_search_rate_limited "$pr_err"; then
			_log "Search API rate-limited during PR fetch for owner=${owner} — falling through to per-repo GraphQL"
		else
			_log "gh search prs failed for owner=${owner}: ${pr_err_msg}"
		fi
		_OWNER_ERRORS=$((_OWNER_ERRORS + 1))
		rm -f "$pr_err"
		return 1
	fi
	rm -f "$pr_err"

	local normalized_prs
	normalized_prs=$(echo "$pr_json" | _normalize_search_to_prefetch_schema "$_KIND_PRS")
	if [[ -n "$normalized_prs" && "$normalized_prs" != "$_JSON_NULL" && "$normalized_prs" != "$_JSON_EMPTY_OBJ" ]]; then
		_write_per_slug_caches "$_KIND_PRS" "$normalized_prs"
		local pr_slug_count
		pr_slug_count=$(echo "$normalized_prs" | jq 'keys | length' 2>/dev/null) || pr_slug_count=0
		_OWNER_CACHE_WRITES=$((_OWNER_CACHE_WRITES + pr_slug_count))
		_log "prs refresh for owner=${owner}: ${pr_slug_count} slug caches written"
	fi
	return 0
}

# =============================================================================
# Subcommand: refresh
# =============================================================================
_cmd_refresh() {
	_check_enabled || {
		_log "batch prefetch disabled (PULSE_BATCH_PREFETCH_ENABLED=0)"
		return 0
	}

	[[ -f "$REPOS_JSON" ]] || {
		_log "repos.json not found at ${REPOS_JSON} — skipping batch prefetch"
		return 1
	}

	mkdir -p "$BATCH_CACHE_DIR" 2>/dev/null || true

	local owner_groups
	owner_groups=$(_group_repos_by_owner "$REPOS_JSON") || {
		_log "failed to group repos by owner"
		return 1
	}

	if [[ -z "$owner_groups" ]]; then
		_log "no pulse-enabled repos found — nothing to prefetch"
		return 0
	fi

	# Shared counters updated by _refresh_owner_issues/_refresh_owner_prs
	_OWNER_SEARCH_CALLS=0
	_OWNER_CACHE_WRITES=0
	_OWNER_ERRORS=0

	local owner slugs
	while IFS='|' read -r owner slugs; do
		[[ -n "$owner" ]] || continue
		_refresh_owner_issues "$owner" || true
		_refresh_owner_prs "$owner" || true
	done <<<"$owner_groups"

	_log "refresh complete: search_calls=${_OWNER_SEARCH_CALLS} cache_writes=${_OWNER_CACHE_WRITES} errors=${_OWNER_ERRORS}"

	# Export counters for health instrumentation
	echo "search_calls=${_OWNER_SEARCH_CALLS}"
	echo "cache_writes=${_OWNER_CACHE_WRITES}"
	echo "errors=${_OWNER_ERRORS}"
	return 0
}

# =============================================================================
# Subcommand: cache-path
# =============================================================================
_cmd_cache_path() {
	local kind="" slug=""
	local _args=("$@")
	local _i=0
	while [[ $_i -lt ${#_args[@]} ]]; do
		case "${_args[$_i]}" in
		--kind)
			kind="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		--slug)
			slug="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		*)
			_i=$((_i + 1))
			;;
		esac
	done

	if [[ -z "$kind" || -z "$slug" ]]; then
		echo "Usage: pulse-batch-prefetch-helper.sh cache-path --kind issues|prs --slug owner/repo" >&2
		return 1
	fi

	_check_enabled || return 1

	local cache_file
	cache_file=$(_cache_file_path "$kind" "$slug")

	if [[ ! -f "$cache_file" ]]; then
		return 1
	fi

	# Check freshness — stale cache (past TTL) returns exit 1
	local cache_ts
	cache_ts=$(jq -r '.timestamp // ""' "$cache_file" 2>/dev/null) || cache_ts=""
	if [[ -z "$cache_ts" || "$cache_ts" == "$_JSON_NULL" ]]; then
		return 1
	fi

	local cache_epoch now_epoch
	if [[ "$(uname)" == "Darwin" ]]; then
		cache_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$cache_ts" "+%s" 2>/dev/null) || cache_epoch=0
	else
		cache_epoch=$(date -u -d "$cache_ts" +%s 2>/dev/null) || cache_epoch=0
	fi
	now_epoch=$(date -u +%s)
	local age=$((now_epoch - cache_epoch))

	if [[ "$age" -ge "$PULSE_PREFETCH_FULL_SWEEP_INTERVAL" ]]; then
		return 1  # Cache too old
	fi

	echo "$cache_file"
	return 0
}

# =============================================================================
# Subcommand: read-cache
# Read normalized items from a batch cache file for a given slug+kind.
# Used by pulse-prefetch integration to read batch data without making API calls.
# Arguments: --kind issues|prs --slug owner/repo
# Output: JSON array of items on stdout, exit 1 on miss/stale
# =============================================================================
_cmd_read_cache() {
	local kind="" slug=""
	local _args=("$@")
	local _i=0
	while [[ $_i -lt ${#_args[@]} ]]; do
		case "${_args[$_i]}" in
		--kind)
			kind="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		--slug)
			slug="${_args[$_i+1]:-}"
			_i=$((_i + 2))
			;;
		*)
			_i=$((_i + 1))
			;;
		esac
	done

	if [[ -z "$kind" || -z "$slug" ]]; then
		echo "Usage: pulse-batch-prefetch-helper.sh read-cache --kind issues|prs --slug owner/repo" >&2
		return 1
	fi

	local cache_file
	cache_file=$(_cmd_cache_path --kind "$kind" --slug "$slug") || return 1

	jq -c '.items // []' "$cache_file" 2>/dev/null || {
		return 1
	}
	return 0
}

# =============================================================================
# Subcommand: clear
# =============================================================================
_cmd_clear() {
	if [[ -d "$BATCH_CACHE_DIR" ]]; then
		rm -rf "${BATCH_CACHE_DIR:?}"/*
		_log "batch cache cleared"
		echo "Batch cache cleared: ${BATCH_CACHE_DIR}"
	else
		echo "No batch cache directory found at ${BATCH_CACHE_DIR}"
	fi
	return 0
}

# =============================================================================
# Subcommand: status
# =============================================================================
_cmd_status() {
	if [[ ! -d "$BATCH_CACHE_DIR" ]]; then
		echo "No batch cache directory at ${BATCH_CACHE_DIR}"
		return 0
	fi

	local cache_files
	cache_files=$(find "$BATCH_CACHE_DIR" -name "*.json" -type f 2>/dev/null | sort)

	if [[ -z "$cache_files" ]]; then
		echo "No cache files found in ${BATCH_CACHE_DIR}"
		return 0
	fi

	local now_epoch
	now_epoch=$(date -u +%s)
	local ttl="$PULSE_PREFETCH_FULL_SWEEP_INTERVAL"

	echo "Batch prefetch cache status (TTL=${ttl}s, enabled=${PULSE_BATCH_PREFETCH_ENABLED})"
	echo "---"

	local file
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local basename
		basename=$(basename "$file" .json)
		local ts item_count age_s freshness
		ts=$(jq -r '.timestamp // "unknown"' "$file" 2>/dev/null) || ts="unknown"
		item_count=$(jq '.items | length' "$file" 2>/dev/null) || item_count="?"

		if [[ "$ts" != "unknown" ]]; then
			local cache_epoch
			if [[ "$(uname)" == "Darwin" ]]; then
				cache_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null) || cache_epoch=0
			else
				cache_epoch=$(date -u -d "$ts" +%s 2>/dev/null) || cache_epoch=0
			fi
			age_s=$((now_epoch - cache_epoch))
			if [[ "$age_s" -lt "$ttl" ]]; then
				freshness="FRESH (${age_s}s old)"
			else
				freshness="STALE (${age_s}s old, TTL=${ttl}s)"
			fi
		else
			freshness="UNKNOWN"
		fi

		echo "  ${basename}: ${item_count} items, ${freshness}, ts=${ts}"
	done <<<"$cache_files"

	return 0
}

# =============================================================================
# Main dispatcher
# =============================================================================
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	refresh)
		_cmd_refresh
		;;
	cache-path)
		_cmd_cache_path "$@"
		;;
	read-cache)
		_cmd_read_cache "$@"
		;;
	clear)
		_cmd_clear
		;;
	status)
		_cmd_status
		;;
	help | --help | -h)
		echo "Usage: pulse-batch-prefetch-helper.sh <command> [options]"
		echo ""
		echo "Commands:"
		echo "  refresh                          Fetch all repos via org-level search and cache"
		echo "  cache-path --kind K --slug S     Return cache path if fresh, exit 1 if stale"
		echo "  read-cache --kind K --slug S     Read cached items as JSON array"
		echo "  clear                            Wipe batch cache directory"
		echo "  status                           Show cache file ages and counts"
		echo ""
		echo "Environment:"
		echo "  PULSE_BATCH_PREFETCH_ENABLED     Enable/disable (default: 1)"
		echo "  PULSE_BATCH_PREFETCH_CACHE_DIR   Cache directory"
		echo "  PULSE_BATCH_SEARCH_LIMIT         Max results per search call (default: 200)"
		return 0
		;;
	*)
		echo "Unknown command: ${cmd}. Run with --help for usage." >&2
		return 1
		;;
	esac
}

main "$@"
