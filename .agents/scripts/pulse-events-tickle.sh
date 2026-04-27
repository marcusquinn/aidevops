#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-events-tickle.sh — L1 events ETag tickle layer (t2830, GH#20868)
# =============================================================================
# Provides events_tickle <owner> — a cheap conditional GET against
# /users/{owner}/events or /orgs/{owner}/events using the REST core rate-limit
# pool (5000/h, independent of GraphQL). Sends a stored ETag via
# If-None-Match; a 304 Not Modified response costs 0 rate-limit points.
#
# Position in the cache hierarchy:
#   L1: Events ETag tickle (THIS)     — 0 points on 304 (ETag match)
#   L2: State fingerprint (t2041)     — 0 API calls, local hash comparison
#   L3: Idle skip (t2098)             — 0 API calls, reads L4 cache
#   L4: Batch prefetch (GH#19963)     — 2 calls per owner via Search API
#   L5: Delta prefetch (GH#15286)     — 2 calls per repo for changes
#   L6: Per-PR enrichment             — 1 call per repo with open PRs (GraphQL)
#
# Exit codes (when sourced and called as events_tickle):
#   0 — fresh (304): ETag unchanged, batch search calls can be skipped
#   1 — stale (200): events changed, caller must run batch search calls
#   2 — unknown (error / disabled): fail-open, treat as stale
#
# Module-level counters (caller-visible globals after sourcing):
#   _PULSE_EVENTS_TICKLE_FRESH — owners skipped this cycle (304 hits)
#   _PULSE_EVENTS_TICKLE_STALE — owners with changed events this cycle
#
# Feature flag: PULSE_EVENTS_TICKLE_ENABLED (default: 1; set in
#   .agents/configs/pulse-rate-limit.conf or as an env var override)
#
# ETag cache: ~/.aidevops/cache/pulse-events-etag/{owner}.json
#   Schema: {"etag":"…","owner_type":"users|orgs","last_check":"ISO-8601"}
#
# Standalone CLI usage (executed directly, not sourced):
#   pulse-events-tickle.sh <owner>
#   Prints "fresh", "stale", or "unknown"; exits 0/1/2 accordingly.
#   Useful for manual verification:
#     ~/.aidevops/agents/scripts/pulse-events-tickle.sh marcusquinn
#
# Part of aidevops framework: https://aidevops.sh
# =============================================================================

# Include guard — safe to source multiple times from the same process.
[[ -n "${_PULSE_EVENTS_TICKLE_LOADED:-}" ]] && return 0
_PULSE_EVENTS_TICKLE_LOADED=1

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Feature flag — overridable via env or pulse-rate-limit.conf (sourced by
# pulse-wrapper.sh before this script is sourced).
PULSE_EVENTS_TICKLE_ENABLED="${PULSE_EVENTS_TICKLE_ENABLED:-1}"

# ETag cache directory — created on first run if absent.
_EVENTS_TICKLE_CACHE_DIR="${HOME}/.aidevops/cache/pulse-events-etag"

# Module-level counters — reset to 0 on first load; pulse-batch-prefetch-helper.sh
# reads these after its per-owner loop to populate the refresh summary output.
_PULSE_EVENTS_TICKLE_FRESH="${_PULSE_EVENTS_TICKLE_FRESH:-0}"
_PULSE_EVENTS_TICKLE_STALE="${_PULSE_EVENTS_TICKLE_STALE:-0}"

# Logfile — inherit from caller if set, otherwise default.
_EVENTS_TICKLE_LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse-wrapper.log}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _events_tickle_log <msg>
# Write a timestamped log line to the shared pulse log.
_events_tickle_log() {
	local msg="$1"
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	printf '[%s] [pulse-events-tickle] %s\n' "$ts" "$msg" >>"$_EVENTS_TICKLE_LOGFILE" 2>/dev/null || true
	return 0
}

# _events_tickle_detect_owner_type <owner>
# Determine whether <owner> is a user or an organization via the GitHub REST
# API. Output: "users" or "orgs". Fail-open: returns "users" on any error
# so a follow-up call to /users/{owner}/events is the safe default.
# Cost: one REST call per first-time owner (result is cached in the ETag file).
_events_tickle_detect_owner_type() {
	local owner="$1"
	local api_type
	api_type=$(gh api "/users/${owner}" --jq '.type' 2>/dev/null) || api_type=""
	if [[ "$api_type" == "Organization" ]]; then
		printf 'orgs'
	else
		printf 'users'
	fi
	return 0
}

# _events_tickle_write_cache <cache_file> <etag> <owner_type>
# Atomically write the ETag cache file.
_events_tickle_write_cache() {
	local cache_file="$1"
	local etag="$2"
	local owner_type="$3"
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	# Use printf with %s for each substitution to avoid escaping issues with
	# special characters in ETags (e.g. W/"abc" weak ETags contain quotes).
	printf '{"etag":"%s","owner_type":"%s","last_check":"%s"}\n' \
		"$etag" "$owner_type" "$ts" >"$cache_file" 2>/dev/null || true
	return 0
}

# _events_tickle_parse_status <response_headers_and_body>
# Extract the HTTP status code from gh api -i output.
# Output: HTTP status integer string (e.g. "200", "304").
# Note: HTTP headers use CRLF line endings; tr -d '\r' strips the carriage
# return so the status code matches case branches cleanly.
_events_tickle_parse_status() {
	local raw="$1"
	printf '%s' "$raw" | grep -m1 "^HTTP/" | awk '{print $2}' | tr -d '\r' 2>/dev/null || printf ''
	return 0
}

# _events_tickle_parse_etag <response_headers_and_body>
# Extract the ETag header value from gh api -i output.
# Strips surrounding quotes and carriage returns (GitHub sends W/"value").
# Output: raw ETag string without quotes (empty if not found).
_events_tickle_parse_etag() {
	local raw="$1"
	printf '%s' "$raw" | grep -i "^[Ee][Tt][Aa][Gg]:" | \
		awk '{print $2}' | tr -d '\r"' | head -1 2>/dev/null || printf ''
	return 0
}

# ---------------------------------------------------------------------------
# Public function: events_tickle
# ---------------------------------------------------------------------------

# events_tickle <owner>
# Check whether the owner's GitHub events have changed since the last poll.
#
# Algorithm:
#   1. Load ETag and owner_type from cache.
#   2. Send conditional GET to /{owner_type}/{owner}/events?per_page=1
#      with If-None-Match: "<stored_etag>".
#   3. 304 → return 0 (fresh): batch search can be skipped.
#   4. 200 → update cache with new ETag, return 1 (stale): search must run.
#   5. 404 → retry with the other endpoint type (user ↔ org), update cache.
#   6. Error / rate-limit → return 2 (unknown): fail-open, treat as stale.
#
# Returns:
#   0 — fresh (304 Not Modified)
#   1 — stale (200 OK, events present or ETag changed)
#   2 — unknown (error, rate-limit, network failure, or feature disabled)
events_tickle() {
	local owner="$1"

	# Feature flag gate — disabled means we cannot skip batch search.
	if [[ "${PULSE_EVENTS_TICKLE_ENABLED:-1}" != "1" ]]; then
		return 2
	fi

	# Ensure the ETag cache directory exists.
	mkdir -p "$_EVENTS_TICKLE_CACHE_DIR" 2>/dev/null || true

	local cache_file="${_EVENTS_TICKLE_CACHE_DIR}/${owner}.json"
	local stored_etag="" owner_type=""

	# Load previously cached ETag and owner type.
	if [[ -f "$cache_file" ]]; then
		stored_etag=$(jq -r '.etag // ""' "$cache_file" 2>/dev/null) || stored_etag=""
		owner_type=$(jq -r '.owner_type // ""' "$cache_file" 2>/dev/null) || owner_type=""
	fi

	# Detect owner type on first run (one extra REST call, then cached).
	if [[ -z "$owner_type" ]]; then
		owner_type=$(_events_tickle_detect_owner_type "$owner")
	fi

	local api_path="/${owner_type}/${owner}/events?per_page=1"

	# Send conditional GET. gh api -i includes response headers so we can
	# detect the 304 status code and extract the ETag from the headers.
	# gh exits non-zero for non-2xx responses including 304.
	local response="" exit_code=0
	if [[ -n "$stored_etag" ]]; then
		response=$(gh api -i "$api_path" -H "If-None-Match: \"${stored_etag}\"" 2>&1) || exit_code=$?
	else
		response=$(gh api -i "$api_path" 2>&1) || exit_code=$?
	fi

	local http_status
	http_status=$(_events_tickle_parse_status "$response")

	case "$http_status" in

	304)
		# ETag unchanged — nothing new for this owner.
		_events_tickle_log "fresh for owner=${owner} (304 ETag match)"
		_PULSE_EVENTS_TICKLE_FRESH=$((_PULSE_EVENTS_TICKLE_FRESH + 1))
		return 0
		;;

	200)
		# Events changed (or first call). Extract the new ETag and cache it.
		local new_etag
		new_etag=$(_events_tickle_parse_etag "$response")
		if [[ -n "$new_etag" ]]; then
			_events_tickle_write_cache "$cache_file" "$new_etag" "$owner_type"
		fi
		_events_tickle_log "stale for owner=${owner} (200 events changed)"
		_PULSE_EVENTS_TICKLE_STALE=$((_PULSE_EVENTS_TICKLE_STALE + 1))
		return 1
		;;

	404)
		# Endpoint mismatch — owner type (user vs org) may be wrong.
		# Retry with the other type; update cache if the retry succeeds.
		if [[ "$owner_type" == "users" ]]; then
			local org_response="" org_exit=0
			org_response=$(gh api -i "/orgs/${owner}/events?per_page=1" 2>&1) || org_exit=$?
			local org_status
			org_status=$(_events_tickle_parse_status "$org_response")

			if [[ "$org_status" == "200" ]]; then
				owner_type="orgs"
				local new_etag
				new_etag=$(_events_tickle_parse_etag "$org_response")
				if [[ -n "$new_etag" ]]; then
					_events_tickle_write_cache "$cache_file" "$new_etag" "$owner_type"
				fi
				_events_tickle_log "stale for owner=${owner} (org endpoint, 200 on retry)"
				_PULSE_EVENTS_TICKLE_STALE=$((_PULSE_EVENTS_TICKLE_STALE + 1))
				return 1
			fi
		fi
		# 404 on both endpoints — fail-open.
		_events_tickle_log "unknown for owner=${owner} (404 on both user/org endpoints)"
		_PULSE_EVENTS_TICKLE_STALE=$((_PULSE_EVENTS_TICKLE_STALE + 1))
		return 2
		;;

	*)
		# Rate-limit (403/429), network error, or unrecognised status.
		# Fail-open: treat as stale so batch search still runs.
		_events_tickle_log "unknown for owner=${owner} (status=${http_status:-none} exit=${exit_code})"
		_PULSE_EVENTS_TICKLE_STALE=$((_PULSE_EVENTS_TICKLE_STALE + 1))
		return 2
		;;

	esac
}

# ---------------------------------------------------------------------------
# Standalone CLI entry point
# Runs only when the script is executed directly (not sourced).
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	# Apply strict mode and re-exec under modern bash for CLI invocations.
	set -euo pipefail

	# shellcheck disable=SC2292
	if [ "${AIDEVOPS_BASH_REEXECED:-}" != "1" ]; then
		_cli_modern_bash=""
		if [ -x "/opt/homebrew/bin/bash" ]; then
			_cli_modern_bash="/opt/homebrew/bin/bash"
		elif [ -x "/usr/local/bin/bash" ]; then
			_cli_modern_bash="/usr/local/bin/bash"
		fi
		if [ -n "$_cli_modern_bash" ] && [ "${BASH_VERSINFO[0]:-3}" -lt 4 ]; then
			export AIDEVOPS_BASH_REEXECED=1
			exec "$_cli_modern_bash" "$0" "$@"
		fi
		unset _cli_modern_bash
	fi

	_cli_owner="${1:-}"
	if [[ -z "$_cli_owner" ]]; then
		printf 'Usage: pulse-events-tickle.sh <owner>\n' >&2
		printf '\nPrints "fresh", "stale", or "unknown"; exits 0/1/2.\n' >&2
		exit 1
	fi

	_cli_rc=0
	events_tickle "$_cli_owner" || _cli_rc=$?
	case "$_cli_rc" in
	0) printf 'fresh\n' ;;
	1) printf 'stale\n' ;;
	2) printf 'unknown\n' ;;
	esac
	exit "$_cli_rc"
fi
