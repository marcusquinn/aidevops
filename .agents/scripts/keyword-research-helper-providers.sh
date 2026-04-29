#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2086,SC2155
# =============================================================================
# Keyword Research Helper -- API Providers Sub-Library
# =============================================================================
# DataForSEO, Serper, and Ahrefs API functions for keyword research.
#
# Usage: source "${SCRIPT_DIR}/keyword-research-helper-providers.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - Credentials in ~/.config/aidevops/credentials.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_KEYWORD_RESEARCH_PROVIDERS_LIB_LOADED:-}" ]] && return 0
_KEYWORD_RESEARCH_PROVIDERS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# DataForSEO API Functions
# =============================================================================

dataforseo_request() {
	local endpoint="$1"
	local data="$2"

	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	local auth
	auth=$(echo -n "${DATAFORSEO_USERNAME}:${DATAFORSEO_PASSWORD}" | base64)

	curl -s -X POST \
		"https://api.dataforseo.com/v3/$endpoint" \
		-H "Authorization: Basic $auth" \
		-H "Content-Type: application/json" \
		-d "$data"
	return 0
}

# Keyword suggestions (seed keyword expansion)
dataforseo_keyword_suggestions() {
	local keyword="$1"
	local location_code="$2"
	local language_code="$3"
	local limit="$4"

	local data
	data=$(
		cat <<EOF
[{
    "keyword": "$keyword",
    "location_code": $location_code,
    "language_code": "$language_code",
    "limit": $limit,
    "include_seed_keyword": true,
    "include_serp_info": true
}]
EOF
	)

	dataforseo_request "dataforseo_labs/google/keyword_suggestions/live" "$data"
	return 0
}

# Google autocomplete (uses keyword_suggestions for richer data)
dataforseo_autocomplete() {
	local keyword="$1"
	local location_code="$2"
	local language_code="$3"

	local data
	data=$(
		cat <<EOF
[{
    "keyword": "$keyword",
    "location_code": $location_code,
    "language_code": "$language_code",
    "limit": 50,
    "include_seed_keyword": true
}]
EOF
	)

	dataforseo_request "dataforseo_labs/google/keyword_suggestions/live" "$data"
	return 0
}

# Ranked keywords (competitor research)
dataforseo_ranked_keywords() {
	local domain="$1"
	local location_code="$2"
	local language_code="$3"
	local limit="$4"

	local data
	data=$(
		cat <<EOF
[{
    "target": "$domain",
    "location_code": $location_code,
    "language_code": "$language_code",
    "limit": $limit,
    "order_by": ["keyword_data.keyword_info.search_volume,desc"]
}]
EOF
	)

	dataforseo_request "dataforseo_labs/google/ranked_keywords/live" "$data"
	return 0
}

# Domain intersection (keyword gap)
dataforseo_keyword_gap() {
	local your_domain="$1"
	local competitor_domain="$2"
	local location_code="$3"
	local language_code="$4"
	local limit="$5"

	local data
	data=$(
		cat <<EOF
[{
    "target1": "$competitor_domain",
    "target2": "$your_domain",
    "location_code": $location_code,
    "language_code": "$language_code",
    "limit": $limit,
    "intersections": false,
    "order_by": ["first_domain_serp_element.etv,desc"]
}]
EOF
	)

	dataforseo_request "dataforseo_labs/google/domain_intersection/live" "$data"
	return 0
}

# Backlinks summary (domain/page scores)
dataforseo_backlinks_summary() {
	local target="$1"

	local data
	data=$(
		cat <<EOF
[{
    "target": "$target",
    "include_subdomains": true
}]
EOF
	)

	dataforseo_request "backlinks/summary/live" "$data"
	return 0
}

# SERP organic results
dataforseo_serp_organic() {
	local keyword="$1"
	local location_code="$2"
	local language_code="$3"

	local data
	data=$(
		cat <<EOF
[{
    "keyword": "$keyword",
    "location_code": $location_code,
    "language_code": "$language_code",
    "device": "desktop",
    "os": "windows",
    "depth": 10
}]
EOF
	)

	dataforseo_request "serp/google/organic/live/regular" "$data"
	return 0
}

# On-page instant (page speed, technical analysis)
dataforseo_onpage_instant() {
	local url="$1"

	local data
	data=$(
		cat <<EOF
[{
    "url": "$url",
    "enable_javascript": true,
    "load_resources": true
}]
EOF
	)

	dataforseo_request "on_page/instant_pages" "$data"
	return 0
}

# =============================================================================
# Serper API Functions
# =============================================================================

serper_request() {
	local endpoint="$1"
	local data="$2"

	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	curl -s -X POST \
		"https://google.serper.dev/$endpoint" \
		-H "X-API-KEY: ${SERPER_API_KEY}" \
		-H "Content-Type: application/json" \
		-d "$data"
	return 0
}

serper_search() {
	local query="$1"
	local location="$2"
	local num="$3"

	local data
	data=$(
		cat <<EOF
{
    "q": "$query",
    "gl": "$location",
    "num": $num
}
EOF
	)

	serper_request "search" "$data"
	return 0
}

serper_autocomplete() {
	local query="$1"
	local location="$2"

	local data
	data=$(
		cat <<EOF
{
    "q": "$query",
    "gl": "$location"
}
EOF
	)

	serper_request "autocomplete" "$data"
	return 0
}

# =============================================================================
# Ahrefs API Functions
# =============================================================================

ahrefs_request() {
	local endpoint="$1"
	local params="$2"

	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	curl -s -X GET \
		"https://api.ahrefs.com/v3/$endpoint?$params" \
		-H "Authorization: Bearer ${AHREFS_API_KEY}"
	return 0
}

ahrefs_domain_rating() {
	local domain="$1"
	local today
	today=$(date +%Y-%m-%d)

	ahrefs_request "site-explorer/domain-rating" "target=$domain&date=$today"
	return 0
}

ahrefs_url_rating() {
	local url="$1"
	local today
	today=$(date +%Y-%m-%d)

	ahrefs_request "site-explorer/url-rating" "target=$url&date=$today"
	return 0
}
