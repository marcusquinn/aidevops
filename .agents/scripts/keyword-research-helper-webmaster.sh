#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2086,SC2155,SC2162
# =============================================================================
# Keyword Research Helper -- Webmaster Tools Sub-Library
# =============================================================================
# Google Search Console, Bing Webmaster Tools, and combined webmaster research.
#
# Usage: source "${SCRIPT_DIR}/keyword-research-helper-webmaster.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning, etc.)
#   - keyword-research-helper-providers.sh (dataforseo_keyword_suggestions)
#   - get_location_code, get_language_code (from orchestrator)
#   - Credentials in ~/.config/aidevops/credentials.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_KEYWORD_RESEARCH_WEBMASTER_LIB_LOADED:-}" ]] && return 0
_KEYWORD_RESEARCH_WEBMASTER_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Google Search Console API Functions
# =============================================================================

gsc_request() {
	local endpoint="$1"
	local data="$2"

	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	# Check for service account credentials
	if [[ -z "${GSC_ACCESS_TOKEN:-}" ]]; then
		# Try to get access token from service account
		if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && [[ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
			# Use gcloud or manual JWT flow
			local token
			token=$(gcloud auth application-default print-access-token 2>/dev/null || echo "")
			if [[ -z "$token" ]]; then
				print_error "Failed to get GSC access token. Run: gcloud auth application-default login"
				return 1
			fi
			GSC_ACCESS_TOKEN="$token"
		else
			print_error "GSC credentials not configured. Set GOOGLE_APPLICATION_CREDENTIALS or GSC_ACCESS_TOKEN"
			return 1
		fi
	fi

	curl -s -X POST \
		"https://searchconsole.googleapis.com/webmasters/v3/$endpoint" \
		-H "Authorization: Bearer $GSC_ACCESS_TOKEN" \
		-H "Content-Type: application/json" \
		-d "$data"
	return 0
}

# Get search analytics (queries, pages, clicks, impressions, CTR, position)
gsc_search_analytics() {
	local site_url="$1"
	local start_date="$2"
	local end_date="$3"
	local limit="${4:-1000}"
	local dimensions="${5:-query}" # query, page, country, device, searchAppearance

	# URL encode the site URL
	local encoded_url
	encoded_url=$(echo -n "$site_url" | jq -sRr @uri)

	local data
	data=$(
		cat <<EOF
{
    "startDate": "$start_date",
    "endDate": "$end_date",
    "dimensions": ["$dimensions"],
    "rowLimit": $limit,
    "startRow": 0
}
EOF
	)

	gsc_request "sites/$encoded_url/searchAnalytics/query" "$data"
	return 0
}

# Get top queries for a site
gsc_top_queries() {
	local site_url="$1"
	local days="${2:-30}"
	local limit="${3:-100}"

	local end_date
	local start_date
	end_date=$(date +%Y-%m-%d)
	start_date=$(date -v-${days}d +%Y-%m-%d 2>/dev/null || date -d "$days days ago" +%Y-%m-%d)

	gsc_search_analytics "$site_url" "$start_date" "$end_date" "$limit" "query"
	return 0
}

# Get queries for a specific page
gsc_page_queries() {
	local site_url="$1"
	local page_url="$2"
	local days="${3:-30}"
	local limit="${4:-100}"

	local end_date
	local start_date
	end_date=$(date +%Y-%m-%d)
	start_date=$(date -v-${days}d +%Y-%m-%d 2>/dev/null || date -d "$days days ago" +%Y-%m-%d)

	local encoded_site
	encoded_site=$(echo -n "$site_url" | jq -sRr @uri)

	local data
	data=$(
		cat <<EOF
{
    "startDate": "$start_date",
    "endDate": "$end_date",
    "dimensions": ["query"],
    "dimensionFilterGroups": [{
        "filters": [{
            "dimension": "page",
            "operator": "equals",
            "expression": "$page_url"
        }]
    }],
    "rowLimit": $limit
}
EOF
	)

	gsc_request "sites/$encoded_site/searchAnalytics/query" "$data"
	return 0
}

# List verified sites
gsc_list_sites() {
	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	if [[ -z "${GSC_ACCESS_TOKEN:-}" ]]; then
		if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && [[ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
			local token
			token=$(gcloud auth application-default print-access-token 2>/dev/null || echo "")
			if [[ -z "$token" ]]; then
				print_error "Failed to get GSC access token"
				return 1
			fi
			GSC_ACCESS_TOKEN="$token"
		else
			print_error "GSC credentials not configured"
			return 1
		fi
	fi

	curl -s -X GET \
		"https://searchconsole.googleapis.com/webmasters/v3/sites" \
		-H "Authorization: Bearer $GSC_ACCESS_TOKEN"
	return 0
}

# =============================================================================
# Bing Webmaster Tools API Functions
# =============================================================================

bing_request() {
	local endpoint="$1"
	local site_url="$2"

	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
		print_error "BING_WEBMASTER_API_KEY not configured in ~/.config/aidevops/credentials.sh"
		return 1
	fi

	# URL encode the site URL
	local encoded_url
	encoded_url=$(echo -n "$site_url" | jq -sRr @uri)

	curl -s -X GET \
		"https://ssl.bing.com/webmaster/api.svc/json/$endpoint?siteUrl=$encoded_url&apikey=$BING_WEBMASTER_API_KEY"
	return 0
}

# Get query statistics (top queries with impressions/clicks)
bing_query_stats() {
	local site_url="$1"

	bing_request "GetQueryStats" "$site_url"
	return 0
}

# Get keyword details for a specific query
bing_keyword() {
	local site_url="$1"
	local query="$2"
	local start_date="$3"
	local end_date="$4"

	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
		print_error "BING_WEBMASTER_API_KEY not configured"
		return 1
	fi

	local encoded_url
	encoded_url=$(echo -n "$site_url" | jq -sRr @uri)
	local encoded_query
	encoded_query=$(echo -n "$query" | jq -sRr @uri)

	curl -s -X GET \
		"https://ssl.bing.com/webmaster/api.svc/json/GetKeyword?siteUrl=$encoded_url&query=$encoded_query&startDate=$start_date&endDate=$end_date&apikey=$BING_WEBMASTER_API_KEY"
	return 0
}

# Get related keywords
bing_related_keywords() {
	local site_url="$1"
	local query="$2"
	local start_date="$3"
	local end_date="$4"

	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
		print_error "BING_WEBMASTER_API_KEY not configured"
		return 1
	fi

	local encoded_url
	encoded_url=$(echo -n "$site_url" | jq -sRr @uri)
	local encoded_query
	encoded_query=$(echo -n "$query" | jq -sRr @uri)

	curl -s -X GET \
		"https://ssl.bing.com/webmaster/api.svc/json/GetRelatedKeywords?siteUrl=$encoded_url&query=$encoded_query&startDate=$start_date&endDate=$end_date&apikey=$BING_WEBMASTER_API_KEY"
	return 0
}

# Get page query stats (queries for a specific page)
bing_page_query_stats() {
	local site_url="$1"
	local page_url="$2"

	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
		print_error "BING_WEBMASTER_API_KEY not configured"
		return 1
	fi

	local encoded_site
	encoded_site=$(echo -n "$site_url" | jq -sRr @uri)
	local encoded_page
	encoded_page=$(echo -n "$page_url" | jq -sRr @uri)

	curl -s -X GET \
		"https://ssl.bing.com/webmaster/api.svc/json/GetPageQueryStats?siteUrl=$encoded_site&page=$encoded_page&apikey=$BING_WEBMASTER_API_KEY"
	return 0
}

# Get rank and traffic stats
bing_rank_traffic() {
	local site_url="$1"

	bing_request "GetRankAndTrafficStats" "$site_url"
	return 0
}

# List user sites
bing_list_sites() {
	source "$HOME/.config/aidevops/credentials.sh" 2>/dev/null || true

	if [[ -z "${BING_WEBMASTER_API_KEY:-}" ]]; then
		print_error "BING_WEBMASTER_API_KEY not configured"
		return 1
	fi

	curl -s -X GET \
		"https://ssl.bing.com/webmaster/api.svc/json/GetUserSites?apikey=$BING_WEBMASTER_API_KEY"
	return 0
}

# =============================================================================
# Webmaster Tools Research (GSC + Bing combined)
# =============================================================================

# Fetch keyword data from GSC and Bing, returning results via nameref-style globals
# Sets: _WM_GSC_DATA, _WM_BING_DATA
_fetch_webmaster_data() {
	local site_url="$1"
	local days="$2"
	local limit="$3"

	_WM_GSC_DATA=""
	_WM_BING_DATA=""

	# Fetch from Google Search Console
	print_info "Fetching from Google Search Console..."
	_WM_GSC_DATA=$(gsc_top_queries "$site_url" "$days" "$limit" 2>/dev/null || echo "")

	if [[ -n "$_WM_GSC_DATA" ]] && echo "$_WM_GSC_DATA" | jq -e '.rows' >/dev/null 2>&1; then
		local gsc_count
		gsc_count=$(echo "$_WM_GSC_DATA" | jq '.rows | length')
		print_success "GSC: Found $gsc_count queries"
	else
		print_warning "GSC: No data or not configured"
		_WM_GSC_DATA=""
	fi

	# Fetch from Bing Webmaster Tools
	print_info "Fetching from Bing Webmaster Tools..."
	_WM_BING_DATA=$(bing_query_stats "$site_url" 2>/dev/null || echo "")

	if [[ -n "$_WM_BING_DATA" ]] && echo "$_WM_BING_DATA" | jq -e '.d' >/dev/null 2>&1; then
		local bing_count
		bing_count=$(echo "$_WM_BING_DATA" | jq '.d | length')
		print_success "Bing: Found $bing_count queries"
	else
		print_warning "Bing: No data or not configured"
		_WM_BING_DATA=""
	fi

	return 0
}

# Combine and deduplicate GSC + Bing keyword data into aggregated TSV
# Reads: _WM_GSC_DATA, _WM_BING_DATA
# Outputs aggregated TSV to stdout
_aggregate_webmaster_keywords() {
	local limit="$1"

	local combined_keywords
	combined_keywords=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${combined_keywords}'"

	# Process GSC data
	if [[ -n "$_WM_GSC_DATA" ]]; then
		echo "$_WM_GSC_DATA" | jq -r '.rows[]? | [.keys[0], .clicks, .impressions, .ctr, .position, "gsc"] | @tsv' >>"$combined_keywords"
	fi

	# Process Bing data
	if [[ -n "$_WM_BING_DATA" ]]; then
		echo "$_WM_BING_DATA" | jq -r '.d[]? | [.Query, .Clicks, .Impressions, (.Clicks / (.Impressions + 0.001)), .AvgPosition, "bing"] | @tsv' >>"$combined_keywords"
	fi

	# Aggregate by keyword (combine GSC + Bing data)
	sort -t$'\t' -k1,1 "$combined_keywords" | awk -F'\t' '
    {
        kw = $1
        clicks[kw] += $2
        impressions[kw] += $3
        ctr_sum[kw] += $4
        pos_sum[kw] += $5
        count[kw]++
        if ($6 == "gsc") gsc[kw] = 1
        if ($6 == "bing") bing[kw] = 1
    }
    END {
        for (kw in clicks) {
            sources = ""
            if (gsc[kw]) sources = "GSC"
            if (bing[kw]) sources = sources (sources ? "+" : "") "Bing"
            printf "%s\t%d\t%d\t%.4f\t%.1f\t%s\n", kw, clicks[kw], impressions[kw], ctr_sum[kw]/count[kw], pos_sum[kw]/count[kw], sources
        }
    }' | sort -t$'\t' -k3 -rn | head -n "$limit"

	rm -f "$combined_keywords"
	return 0
}

# Enrich aggregated keywords with DataForSEO volume/difficulty data
# Sets: _WM_VOLUME_LOOKUP
_enrich_webmaster_keywords() {
	local aggregated="$1"

	_WM_VOLUME_LOOKUP=""

	print_info "Enriching with search volume and difficulty data..."

	# Get unique keywords for enrichment (top 50 to avoid API limits)
	local keywords_to_enrich
	keywords_to_enrich=$(echo "$aggregated" | head -50 | cut -f1 | tr '\n' ',' | sed 's/,$//')

	if [[ -n "$keywords_to_enrich" ]]; then
		local location_code
		local language_code
		location_code=$(get_location_code "$DEFAULT_LOCALE")
		language_code=$(get_language_code "$DEFAULT_LOCALE")

		# Fetch volume data from DataForSEO
		local volume_data
		volume_data=$(dataforseo_keyword_suggestions "${keywords_to_enrich%%,*}" "$location_code" "$language_code" 50 2>/dev/null || echo "")

		# Build lookup table for volume/difficulty
		_WM_VOLUME_LOOKUP=$(echo "$volume_data" | jq -r '
            [.tasks[]?.result[]?.items[]? | {
                keyword: .keyword,
                volume: (.keyword_info.search_volume // 0),
                difficulty: (.keyword_properties.keyword_difficulty // 0),
                cpc: (.keyword_info.cpc // 0),
                intent: (.search_intent_info.main_intent // "unknown")
            }] | INDEX(.keyword)
        ' 2>/dev/null || echo "{}")
	fi

	return 0
}

# Format and display webmaster keyword results table, optionally export CSV
_format_webmaster_output() {
	local aggregated="$1"
	local volume_lookup="$2"
	local csv_export="$3"

	echo ""
	printf "| %-40s | %10s | %12s | %6s | %8s | %8s | %6s | %8s | %-10s |\n" \
		"Keyword" "Clicks" "Impressions" "CTR" "Position" "Volume" "KD" "CPC" "Sources"
	printf "|%-42s|%12s|%14s|%8s|%10s|%10s|%8s|%10s|%-12s|\n" \
		"$(printf '%0.s-' {1..42})" "$(printf '%0.s-' {1..12})" "$(printf '%0.s-' {1..14})" \
		"$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..10})" \
		"$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..12})"

	local count=0
	while IFS=$'\t' read -r keyword clicks impressions ctr position sources; do
		# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
		local _saved_ifs="$IFS"
		IFS=$' \t\n'

		# Get enrichment data if available
		local volume="-"
		local kd="-"
		local cpc="-"

		if [[ -n "${volume_lookup:-}" ]]; then
			local enriched
			enriched=$(echo "$volume_lookup" | jq -r --arg kw "$keyword" '.[$kw] // empty')
			if [[ -n "$enriched" ]]; then
				volume=$(echo "$enriched" | jq -r '.volume // "-"')
				kd=$(echo "$enriched" | jq -r '.difficulty // "-"')
				cpc=$(echo "$enriched" | jq -r '.cpc // "-"')
			fi
		fi

		# Format CTR as percentage — use awk instead of bc to avoid IFS issues
		local ctr_pct
		ctr_pct=$(awk -v c="$ctr" 'BEGIN {printf "%.2f", c * 100}')

		IFS="$_saved_ifs"
		printf "| %-40s | %10s | %12s | %5s%% | %8.1f | %8s | %6s | %8s | %-10s |\n" \
			"${keyword:0:40}" "$clicks" "$impressions" "$ctr_pct" "$position" "$volume" "$kd" "$cpc" "$sources"

		count=$((count + 1))
	done <<<"$aggregated"

	echo ""
	print_success "Found $count keywords from webmaster tools"

	# CSV export
	if [[ "$csv_export" == "true" ]]; then
		local csv_file="$DOWNLOADS_DIR/webmaster-keywords-$(date +%Y%m%d-%H%M%S).csv"
		echo "Keyword,Clicks,Impressions,CTR,Position,Volume,KD,CPC,Sources" >"$csv_file"
		echo "$aggregated" | while IFS=$'\t' read -r keyword clicks impressions ctr position sources; do
			echo "\"$keyword\",$clicks,$impressions,$ctr,$position,,,\"$sources\"" >>"$csv_file"
		done
		print_success "Exported to: $csv_file"
	fi

	return 0
}

do_webmaster_research() {
	local site_url="$1"
	local days="${2:-30}"
	local limit="${3:-100}"
	local csv_export="${4:-false}"
	local enrich="${5:-true}"

	print_header "Webmaster Tools Keyword Research"
	print_info "Site: $site_url"
	print_info "Period: Last $days days"
	print_info "Enrichment: $enrich"

	# Fetch data from GSC and Bing
	_fetch_webmaster_data "$site_url" "$days" "$limit"

	# Aggregate keywords
	local aggregated
	aggregated=$(_aggregate_webmaster_keywords "$limit")

	if [[ -z "$aggregated" ]]; then
		print_warning "No keyword data found from webmaster tools"
		return 0
	fi

	# Enrich with DataForSEO if requested
	local volume_lookup=""
	if [[ "$enrich" == "true" ]]; then
		_enrich_webmaster_keywords "$aggregated"
		volume_lookup="$_WM_VOLUME_LOOKUP"
	fi

	# Format and display results
	_format_webmaster_output "$aggregated" "$volume_lookup" "$csv_export"

	return 0
}

# List all verified sites from both GSC and Bing
do_list_sites() {
	print_header "Verified Webmaster Sites"

	echo ""
	echo "Google Search Console:"
	echo "----------------------"
	local gsc_sites
	gsc_sites=$(gsc_list_sites 2>/dev/null || echo "")
	if [[ -n "$gsc_sites" ]] && echo "$gsc_sites" | jq -e '.siteEntry' >/dev/null 2>&1; then
		echo "$gsc_sites" | jq -r '.siteEntry[]? | "  \(.siteUrl) [\(.permissionLevel)]"'
	else
		echo "  (Not configured or no sites)"
	fi

	echo ""
	echo "Bing Webmaster Tools:"
	echo "---------------------"
	local bing_sites
	bing_sites=$(bing_list_sites 2>/dev/null || echo "")
	if [[ -n "$bing_sites" ]] && echo "$bing_sites" | jq -e '.d' >/dev/null 2>&1; then
		echo "$bing_sites" | jq -r '.d[]? | "  \(.Url)"'
	else
		echo "  (Not configured or no sites)"
	fi

	echo ""
	return 0
}
