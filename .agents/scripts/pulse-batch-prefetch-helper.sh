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

# Source L1 events ETag tickle helper (t2830, GH#20868).
# Provides events_tickle <owner> — skips batch search on 304 ETag match.
# Fail-open: if the file is absent, events_tickle is a no-op stub below.
# shellcheck source=./pulse-events-tickle.sh
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/pulse-events-tickle.sh" ]]; then
	source "${SCRIPT_DIR}/pulse-events-tickle.sh"
elif ! declare -F events_tickle >/dev/null 2>&1; then
	# Stub: always returns "unknown" (exit 2) so the batch search runs.
	events_tickle() { return 2; }
fi

# Source pulse-stats-helper for persistent counter recording (fail-open).
# shellcheck source=./pulse-stats-helper.sh
# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/pulse-stats-helper.sh" ]]; then
	source "${SCRIPT_DIR}/pulse-stats-helper.sh" 2>/dev/null || true
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
# Detection patterns cover both Search API limits AND GraphQL exhaustion:
#   - "GraphQL: API rate limit (already) exceeded" — observed in production
#     2026-04-22 17:36–18:45 UTC: gh search prs/issues internally uses GraphQL;
#     when the GraphQL quota is exhausted the error contains this string.
#   - "API rate limit exceeded for user" — alternate GitHub phrasing.
# Both are distinct from the Search-API-specific patterns (30/min bucket).
_is_search_rate_limited() {
	local err_file="$1"
	[[ -n "$err_file" && -s "$err_file" ]] || return 1
	grep -qiE 'Search rate limit exceeded|search API rate limit|HTTP 422.*abuse detection|secondary rate limit|was submitted too quickly|GraphQL: API rate limit (already )?exceeded|API rate limit exceeded for user' "$err_file"
}

# --- REST fallback: issues fetch for a single slug ---
# Called when gh search issues is rate-limited (GraphQL or Search API exhausted).
# Fetches open issues via GET /repos/{slug}/issues (REST core bucket: 5000/hr,
# independent of GraphQL quota). Writes the normalized cache file directly.
# Field mapping: REST updated_at → prefetch-schema updatedAt.
#
# Arguments: $1=slug (owner/repo)
# Returns: 0 on success (cache written), 1 on failure (REST also failed/no data)
_prefetch_rest_issues_for_slug() {
	local slug="$1"
	gh_record_call rest 2>/dev/null || true
	local rest_json
	rest_json=$(gh api "/repos/${slug}/issues?state=open&per_page=${BATCH_SEARCH_LIMIT}" 2>/dev/null) || rest_json=""
	if [[ -z "$rest_json" || "$rest_json" == "$_JSON_NULL" || "$rest_json" == "$_JSON_EMPTY_ARR" ]]; then
		_log "REST issues fallback: empty/null response for ${slug}"
		return 1
	fi
	local cache_file
	cache_file=$(_cache_file_path "$_KIND_ISSUES" "$slug")
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	echo "$rest_json" | jq --arg ts "$ts" '{
		timestamp: $ts,
		items: [.[] | {
			number: .number,
			title: .title,
			labels: (.labels // []),
			updatedAt: .updated_at,
			assignees: (.assignees // [])
		}]
	}' >"$cache_file" 2>/dev/null || {
		_log "REST issues fallback: failed to write cache for ${slug}"
		return 1
	}
	local item_count
	item_count=$(jq '.items | length' "$cache_file" 2>/dev/null) || item_count=0
	_log "REST issues fallback: wrote ${item_count} items to cache for ${slug}"
	return 0
}

# --- REST fallback: PRs fetch for a single slug ---
# Called when gh search prs is rate-limited (GraphQL or Search API exhausted).
# Fetches open PRs via GET /repos/{slug}/pulls (REST core budget: 5000/hr,
# independent of GraphQL quota). Writes the normalized cache file directly.
# Field mapping: REST updated_at → updatedAt, created_at → createdAt, user → author.
#
# Arguments: $1=slug (owner/repo)
# Returns: 0 on success (cache written), 1 on failure (REST also failed/no data)
_prefetch_rest_prs_for_slug() {
	local slug="$1"
	gh_record_call rest 2>/dev/null || true
	local rest_json
	rest_json=$(gh api "/repos/${slug}/pulls?state=open&per_page=${BATCH_SEARCH_LIMIT}" 2>/dev/null) || rest_json=""
	if [[ -z "$rest_json" || "$rest_json" == "$_JSON_NULL" || "$rest_json" == "$_JSON_EMPTY_ARR" ]]; then
		_log "REST PRs fallback: empty/null response for ${slug}"
		return 1
	fi
	local cache_file
	cache_file=$(_cache_file_path "$_KIND_PRS" "$slug")
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	echo "$rest_json" | jq --arg ts "$ts" '{
		timestamp: $ts,
		items: [.[] | {
			number: .number,
			title: .title,
			labels: (.labels // []),
			updatedAt: .updated_at,
			assignees: (.assignees // []),
			createdAt: (.created_at // null),
			author: (if .user then {login: .user.login} else null end)
		}]
	}' >"$cache_file" 2>/dev/null || {
		_log "REST PRs fallback: failed to write cache for ${slug}"
		return 1
	}
	local item_count
	item_count=$(jq '.items | length' "$cache_file" 2>/dev/null) || item_count=0
	_log "REST PRs fallback: wrote ${item_count} items to cache for ${slug}"
	return 0
}

# --- REST per-slug iteration (t2902) ---
# Iterate a comma-separated slug list and dispatch each to the per-slug REST
# fallback helper for the requested kind. Updates _OWNER_CACHE_WRITES /
# _OWNER_ERRORS (Bash 3.2 namerefs workaround — these are pseudo-globals
# set by the caller).
#
# Used by both:
#   (a) the proactive guard in _refresh_owner_* (skip gh search when GraphQL
#       budget is below threshold), and
#   (b) the reactive fallback after a gh search rate-limit error.
#
# Arguments: $1=kind ("issues" | "prs")  $2=slugs (comma-separated)
# Returns: 0 always (per-slug failures roll into _OWNER_ERRORS counter)
_prefetch_rest_per_slug() {
	local kind="$1"
	local slugs="${2:-}"
	[[ -n "$slugs" ]] || return 0
	local slug ok
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		ok=0
		case "$kind" in
		issues) _prefetch_rest_issues_for_slug "$slug" && ok=1 ;;
		prs) _prefetch_rest_prs_for_slug "$slug" && ok=1 ;;
		*)
			_log "_prefetch_rest_per_slug: unknown kind=${kind}"
			return 1
			;;
		esac
		if [[ "$ok" -eq 1 ]]; then
			_OWNER_CACHE_WRITES=$((_OWNER_CACHE_WRITES + 1))
		else
			_OWNER_ERRORS=$((_OWNER_ERRORS + 1))
		fi
	done < <(tr ',' '\n' <<< "$slugs")
	return 0
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
		# PRs: normalize to prefetch schema.
		# Note: headRefName is NOT available from gh search prs (Search API
		# returns issue-shaped results). Consumers needing branch names must
		# fetch lazily via `gh pr view <N> --json headRefName`.
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
# Arguments: $1=owner  $2=slugs (comma-separated owner/repo list for REST fallback)
#            $3=graphql_remaining (optional pre-computed integer; pass to avoid redundant
#                                  rate-limit API calls when iterating over many owners)
_refresh_owner_issues() {
	local owner="$1"
	local slugs="${2:-}"
	local graphql_remaining="${3:-}"
	# Proactive REST fallback (t2902): if GraphQL is at/below the fallback
	# threshold, skip `gh search issues` (which uses the GraphQL Search API,
	# ~30 points/call) and go straight to per-slug REST iteration. Avoids
	# burning points on a call that will fail and then be retried via REST.
	# Pass pre-computed remaining to avoid a redundant rate-limit API call per owner.
	if _gh_should_fallback_to_rest "$graphql_remaining" 2>/dev/null; then
		_log "GraphQL <= threshold — skipping gh search issues for owner=${owner}, going straight to REST"
		gh_record_call search-rest 2>/dev/null || true
		_prefetch_rest_per_slug issues "$slugs"
		return 0
	fi
	gh_record_call search-graphql 2>/dev/null || true
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
			_log "Search/GraphQL rate-limited during issues fetch for owner=${owner} — falling back to per-repo REST"
			rm -f "$issue_err"
			# Reactive REST fallback: iterate per-slug via core REST bucket.
			_prefetch_rest_per_slug issues "$slugs"
			return 0
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
# Arguments: $1=owner  $2=slugs (comma-separated owner/repo list for REST fallback)
#            $3=graphql_remaining (optional pre-computed integer; pass to avoid redundant
#                                  rate-limit API calls when iterating over many owners)
_refresh_owner_prs() {
	local owner="$1"
	local slugs="${2:-}"
	local graphql_remaining="${3:-}"
	# Proactive REST fallback (t2902): same pattern as _refresh_owner_issues.
	# Pass pre-computed remaining to avoid a redundant rate-limit API call per owner.
	if _gh_should_fallback_to_rest "$graphql_remaining" 2>/dev/null; then
		_log "GraphQL <= threshold — skipping gh search prs for owner=${owner}, going straight to REST"
		gh_record_call search-rest 2>/dev/null || true
		_prefetch_rest_per_slug prs "$slugs"
		return 0
	fi
	gh_record_call search-graphql 2>/dev/null || true
	local pr_err
	pr_err=$(mktemp)
	local pr_json=""
	pr_json=$(gh search prs --owner "$owner" --state open \
		--limit "$BATCH_SEARCH_LIMIT" \
		--json number,title,labels,updatedAt,assignees,repository,createdAt,author 2>"$pr_err") || pr_json=""
	_OWNER_SEARCH_CALLS=$((_OWNER_SEARCH_CALLS + 1))

	if [[ -z "$pr_json" || "$pr_json" == "$_JSON_NULL" ]]; then
		local pr_err_msg
		pr_err_msg=$(cat "$pr_err" 2>/dev/null || echo "unknown error")
		if _is_search_rate_limited "$pr_err"; then
			_log "Search/GraphQL rate-limited during PR fetch for owner=${owner} — falling back to per-repo REST"
			rm -f "$pr_err"
			# Reactive REST fallback: iterate per-slug via core REST bucket.
			_prefetch_rest_per_slug prs "$slugs"
			return 0
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

	# Pre-fetch GraphQL remaining once per refresh cycle (t2902 review followup).
	# Both _refresh_owner_issues and _refresh_owner_prs call _gh_should_fallback_to_rest,
	# which issues a `gh api rate_limit` call when no pre-computed value is supplied.
	# With N owners that produces 2×N redundant API calls. Fetch here and pass the
	# integer down so each per-owner function can reuse it without hitting the API again.
	# Fail-open: if the fetch fails, an empty string is passed and the per-owner functions
	# fall back to their own rate-limit call (the existing behaviour).
	local _graphql_remaining=""
	_graphql_remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null) || _graphql_remaining=""

	# L1 tickle counters — reset per refresh cycle (module globals from
	# pulse-events-tickle.sh; may already be 0 if sourced fresh, but
	# explicit reset ensures correct totals when _cmd_refresh is called
	# multiple times within the same process).
	_PULSE_EVENTS_TICKLE_FRESH=0
	_PULSE_EVENTS_TICKLE_STALE=0

	local owner slugs
	while IFS='|' read -r owner slugs; do
		[[ -n "$owner" ]] || continue

		# L1 events ETag tickle (t2830, GH#20868): cheap conditional GET
		# via REST core bucket. On 304 (ETag unchanged), skip the 2 Search
		# API calls for this owner entirely. On error (exit 2), fail-open
		# and let the normal batch search proceed.
		local _tickle_rc=0
		events_tickle "$owner" || _tickle_rc=$?
		if [[ "$_tickle_rc" -eq 0 ]]; then
			_log "events tickle fresh for owner=${owner} — skipping search calls"
			continue
		fi

		_refresh_owner_issues "$owner" "$slugs" "$_graphql_remaining" || true
		_refresh_owner_prs "$owner" "$slugs" "$_graphql_remaining" || true
	done <<<"$owner_groups"

	_log "refresh complete: search_calls=${_OWNER_SEARCH_CALLS} cache_writes=${_OWNER_CACHE_WRITES} errors=${_OWNER_ERRORS} tickle_fresh=${_PULSE_EVENTS_TICKLE_FRESH} tickle_stale=${_PULSE_EVENTS_TICKLE_STALE}"

	# t2902: aggregate gh API call records to JSON report at the end of each
	# refresh cycle. Fail-open: if gh-api-instrument.sh isn't sourced, the
	# 2>/dev/null || true silences the unbound function and the host script
	# keeps working. trim keeps the append-only log under MAX_LINES.
	gh_aggregate_calls 2>/dev/null || true
	gh_trim_log 2>/dev/null || true

	# Record tickle counters to pulse-stats.json (one timestamp entry per
	# fresh/stale owner). Fail-open: pulse_stats_increment is sourced from
	# pulse-stats-helper.sh above; if it was not sourced, the declare -F
	# guard is a no-op and the batch search continues unaffected.
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		local _fi=0
		while [[ "$_fi" -lt "$_PULSE_EVENTS_TICKLE_FRESH" ]]; do
			pulse_stats_increment "pulse_events_tickle_fresh" 2>/dev/null || true
			_fi=$((_fi + 1))
		done
		local _si=0
		while [[ "$_si" -lt "$_PULSE_EVENTS_TICKLE_STALE" ]]; do
			pulse_stats_increment "pulse_events_tickle_stale" 2>/dev/null || true
			_si=$((_si + 1))
		done
	fi

	# Export counters for health instrumentation (parsed by _prefetch_batch_refresh
	# in pulse-prefetch.sh and added to per-cycle health totals).
	echo "search_calls=${_OWNER_SEARCH_CALLS}"
	echo "cache_writes=${_OWNER_CACHE_WRITES}"
	echo "errors=${_OWNER_ERRORS}"
	echo "events_tickle_fresh=${_PULSE_EVENTS_TICKLE_FRESH}"
	echo "events_tickle_stale=${_PULSE_EVENTS_TICKLE_STALE}"
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
