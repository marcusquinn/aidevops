#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2086,SC2155,SC2162
# =============================================================================
# Keyword Research Helper -- Analysis & Research Sub-Library
# =============================================================================
# SERP weakness detection, scoring, output formatting, CSV export,
# and main research orchestration functions.
#
# Usage: source "${SCRIPT_DIR}/keyword-research-helper-analysis.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning, etc.)
#   - keyword-research-helper-providers.sh (dataforseo_*, serper_*)
#   - get_location_code, get_language_code, check_credentials (from orchestrator)
#   - THRESHOLD_* constants, DOWNLOADS_DIR, MAX_LIMIT (from orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_KEYWORD_RESEARCH_ANALYSIS_LIB_LOADED:-}" ]] && return 0
_KEYWORD_RESEARCH_ANALYSIS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# SERP Weakness Detection
# =============================================================================

detect_weaknesses() {
	local serp_data="$1"
	local weaknesses=()
	local weakness_count=0

	# Parse SERP results and detect weaknesses
	# This is a simplified version - full implementation would analyze each result

	# Check for low domain scores
	local low_ds_count
	low_ds_count=$(echo "$serp_data" | jq "[.items[]? | select(.main_domain_rank <= $THRESHOLD_LOW_DS)] | length" 2>/dev/null || echo "0")
	if [[ "$low_ds_count" -gt 0 ]]; then
		weaknesses+=("Low DS ($low_ds_count)")
		weakness_count=$((weakness_count + low_ds_count))
	fi

	# Check for no backlinks
	local no_backlinks_count
	no_backlinks_count=$(echo "$serp_data" | jq '[.items[]? | select(.backlinks_count == 0)] | length' 2>/dev/null || echo "0")
	if [[ "$no_backlinks_count" -gt 0 ]]; then
		weaknesses+=("No Backlinks ($no_backlinks_count)")
		weakness_count=$((weakness_count + no_backlinks_count))
	fi

	# Check for non-HTTPS
	# SONAR: Detecting insecure URLs for security audit, not using them
	local non_https_count
	non_https_count=$(echo "$serp_data" | jq '[.items[]? | select(.url | startswith("http://"))] | length' 2>/dev/null || echo "0")
	if [[ "$non_https_count" -gt 0 ]]; then
		weaknesses+=("Non-HTTPS ($non_https_count)")
		weakness_count=$((weakness_count + non_https_count))
	fi

	# Check for UGC-heavy results
	local ugc_count
	ugc_count=$(echo "$serp_data" | jq '[.items[]? | select(.domain | test("reddit|quora|stackoverflow|forum"; "i"))] | length' 2>/dev/null || echo "0")
	if [[ "$ugc_count" -ge "$THRESHOLD_UGC_HEAVY" ]]; then
		weaknesses+=("UGC-Heavy ($ugc_count)")
		weakness_count=$((weakness_count + 1))
	fi

	# Output results
	echo "$weakness_count|${weaknesses[*]:-None}"
	return 0
}

calculate_keyword_score() {
	local weakness_count="$1"
	local volume="$2"
	local difficulty="$3"
	local serp_features="$4"

	local score=0

	# Base score from weaknesses (1 point each, max 13)
	score=$((score + weakness_count))

	# Volume bonus
	if [[ "$volume" -gt 5000 ]]; then
		score=$((score + 3))
	elif [[ "$volume" -gt 1000 ]]; then
		score=$((score + 2))
	elif [[ "$volume" -gt 100 ]]; then
		score=$((score + 1))
	fi

	# Difficulty bonus
	if [[ "$difficulty" -eq 0 ]]; then
		score=$((score + 3))
	elif [[ "$difficulty" -le 15 ]]; then
		score=$((score + 2))
	elif [[ "$difficulty" -le 30 ]]; then
		score=$((score + 1))
	fi

	# SERP features penalty (max -3)
	local feature_penalty
	feature_penalty=$(echo "$serp_features" | jq 'length' 2>/dev/null || echo "0")
	if [[ "$feature_penalty" -gt 3 ]]; then
		feature_penalty=3
	fi
	score=$((score - feature_penalty))

	# Normalize to 0-100 scale (exponential scaling)
	# Max raw score ~20, scale to 100
	local normalized
	normalized=$(echo "scale=0; ($score * 5)" | bc)
	if [[ "$normalized" -gt 100 ]]; then
		normalized=100
	fi
	if [[ "$normalized" -lt 0 ]]; then
		normalized=0
	fi

	echo "$normalized"
	return 0
}

# =============================================================================
# Output Formatting
# =============================================================================

format_volume() {
	local volume="$1"

	if [[ "$volume" -ge 1000000 ]]; then
		echo "$(echo "scale=1; $volume / 1000000" | bc)M"
	elif [[ "$volume" -ge 1000 ]]; then
		echo "$(echo "scale=1; $volume / 1000" | bc)K"
	else
		echo "$volume"
	fi
	return 0
}

format_cpc() {
	local cpc="$1"
	printf "\$%.2f" "$cpc"
	return 0
}

# Print markdown table with space-padded columns
print_research_table() {
	local json_data="$1"
	local mode="$2"

	case "$mode" in
	"basic")
		echo ""
		printf "| %-40s | %8s | %7s | %4s | %-14s |\n" "Keyword" "Volume" "CPC" "KD" "Intent"
		printf "|%-42s|%10s|%9s|%6s|%16s|\n" "$(printf '%0.s-' {1..42})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..9})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..16})"

		echo "$json_data" | jq -r '.[] | "\(.keyword)|\(.volume)|\(.cpc)|\(.difficulty)|\(.intent)"' 2>/dev/null | while IFS='|' read -r kw vol cpc kd intent; do
			local vol_fmt
			vol_fmt=$(format_volume "$vol")
			local cpc_fmt
			cpc_fmt=$(format_cpc "$cpc")
			printf "| %-40s | %8s | %7s | %4s | %-14s |\n" "${kw:0:40}" "$vol_fmt" "$cpc_fmt" "$kd" "${intent:0:14}"
		done
		;;
	"extended")
		echo ""
		printf "| %-30s | %7s | %4s | %4s | %10s | %-30s | %4s | %4s |\n" "Keyword" "Vol" "KD" "KS" "Weaknesses" "Weakness Types" "DS" "PS"
		printf "|%-32s|%9s|%6s|%6s|%12s|%32s|%6s|%6s|\n" "$(printf '%0.s-' {1..32})" "$(printf '%0.s-' {1..9})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..12})" "$(printf '%0.s-' {1..32})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..6})"

		echo "$json_data" | jq -r '.[] | "\(.keyword)|\(.volume)|\(.difficulty)|\(.keyword_score)|\(.weakness_count)|\(.weaknesses)|\(.domain_score)|\(.page_score)"' 2>/dev/null | while IFS='|' read -r kw vol kd ks wc wt ds ps; do
			local vol_fmt
			vol_fmt=$(format_volume "$vol")
			printf "| %-30s | %7s | %4s | %4s | %10s | %-30s | %4s | %4s |\n" "${kw:0:30}" "$vol_fmt" "$kd" "$ks" "$wc" "${wt:0:30}" "$ds" "$ps"
		done
		;;
	"competitor")
		echo ""
		printf "| %-30s | %7s | %4s | %8s | %11s | %-35s |\n" "Keyword" "Vol" "KD" "Position" "Est Traffic" "Ranking URL"
		printf "|%-32s|%9s|%6s|%10s|%13s|%37s|\n" "$(printf '%0.s-' {1..32})" "$(printf '%0.s-' {1..9})" "$(printf '%0.s-' {1..6})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..13})" "$(printf '%0.s-' {1..37})"

		echo "$json_data" | jq -r '.[] | "\(.keyword)|\(.volume)|\(.difficulty)|\(.position)|\(.est_traffic)|\(.ranking_url)"' 2>/dev/null | while IFS='|' read -r kw vol kd pos traffic url; do
			local vol_fmt
			vol_fmt=$(format_volume "$vol")
			printf "| %-30s | %7s | %4s | %8s | %11s | %-35s |\n" "${kw:0:30}" "$vol_fmt" "$kd" "$pos" "$traffic" "${url:0:35}"
		done
		;;
	*)
		print_error "Unknown mode: $mode"
		;;
	esac
	echo ""
	return 0
}

# =============================================================================
# CSV Export
# =============================================================================

export_csv() {
	local json_data="$1"
	local mode="$2"
	local filename="$3"

	local filepath="$DOWNLOADS_DIR/$filename"

	case "$mode" in
	"basic")
		echo "Keyword,Volume,CPC,Difficulty,Intent" >"$filepath"
		echo "$json_data" | jq -r '.[] | "\"\(.keyword)\",\(.volume),\(.cpc),\(.difficulty),\"\(.intent)\""' >>"$filepath"
		;;
	"extended")
		echo "Keyword,Volume,CPC,Difficulty,Intent,KeywordScore,DomainScore,PageScore,WeaknessCount,Weaknesses" >"$filepath"
		echo "$json_data" | jq -r '.[] | "\"\(.keyword)\",\(.volume),\(.cpc),\(.difficulty),\"\(.intent)\",\(.keyword_score),\(.domain_score),\(.page_score),\(.weakness_count),\"\(.weaknesses)\""' >>"$filepath"
		;;
	"competitor")
		echo "Keyword,Volume,CPC,Difficulty,Intent,Position,EstTraffic,RankingURL" >"$filepath"
		echo "$json_data" | jq -r '.[] | "\"\(.keyword)\",\(.volume),\(.cpc),\(.difficulty),\"\(.intent)\",\(.position),\(.est_traffic),\"\(.ranking_url)\""' >>"$filepath"
		;;
	*)
		print_error "Unknown export mode: $mode"
		return 1
		;;
	esac

	print_success "Exported to: $filepath"
	return 0
}

# =============================================================================
# Main Research Functions
# =============================================================================

do_keyword_research() {
	local keywords="$1"
	local provider="$2"
	local locale="$3"
	local limit="$4"
	local csv_export="$5"
	local filters="$6"

	print_header "Keyword Research"
	print_info "Keywords: $keywords"
	print_info "Provider: $provider"
	print_info "Locale: $locale"
	print_info "Limit: $limit"

	check_credentials "$provider" || return 1

	local location_code
	location_code=$(get_location_code "$locale")
	local language_code
	language_code=$(get_language_code "$locale")

	local results="[]"

	# Split keywords by comma and process each
	local -a keyword_array
	IFS=',' read -ra keyword_array <<<"$keywords"

	local keyword
	for keyword in "${keyword_array[@]}"; do
		keyword=$(echo "$keyword" | xargs) # Trim whitespace
		print_info "Researching: $keyword"

		if [[ "$provider" == "dataforseo" ]] || [[ "$provider" == "both" ]]; then
			local response
			response=$(dataforseo_keyword_suggestions "$keyword" "$location_code" "$language_code" "$limit")

			# Parse and add to results
			local parsed
			parsed=$(echo "$response" | jq '[.tasks[0].result[0].items[]? | {
                keyword: .keyword,
                volume: (.keyword_info.search_volume // 0),
                cpc: (.keyword_info.cpc // 0),
                difficulty: (.keyword_info.keyword_difficulty // 0),
                intent: (.search_intent_info.main_intent // "unknown")
            }]' 2>/dev/null || echo "[]")

			results=$(echo "$results $parsed" | jq -s 'add')
		fi

		if [[ "$provider" == "serper" ]] || [[ "$provider" == "both" ]]; then
			# Serper doesn't have keyword suggestions, use search instead
			print_warning "Serper doesn't support keyword suggestions. Use DataForSEO for this feature."
		fi
	done

	# Apply filters if provided
	if [[ -n "$filters" ]]; then
		results=$(apply_filters "$results" "$filters")
	fi

	# Count results
	local count
	count=$(echo "$results" | jq 'length')
	print_success "Found $count keywords"

	# Print table
	print_research_table "$results" "basic"

	# Export CSV if requested
	if [[ "$csv_export" == "true" ]]; then
		local timestamp
		timestamp=$(date +"%Y%m%d-%H%M%S")
		export_csv "$results" "basic" "keyword-research-$timestamp.csv"
	fi

	# Prompt for more results
	if [[ "$count" -ge "$limit" ]]; then
		echo ""
		read -p "Retrieved $count keywords. Need more? Enter number (max $MAX_LIMIT) or press Enter to continue: " more_count
		if [[ -n "$more_count" ]] && [[ "$more_count" =~ ^[0-9]+$ ]]; then
			if [[ "$more_count" -le "$MAX_LIMIT" ]]; then
				do_keyword_research "$keywords" "$provider" "$locale" "$more_count" "$csv_export" "$filters"
			else
				print_warning "Maximum limit is $MAX_LIMIT"
			fi
		fi
	fi

	return 0
}

do_autocomplete_research() {
	local keyword="$1"
	local provider="$2"
	local locale="$3"
	local csv_export="$4"

	print_header "Autocomplete Research"
	print_info "Keyword: $keyword"
	print_info "Provider: $provider"
	print_info "Locale: $locale"

	check_credentials "$provider" || return 1

	local location_code
	location_code=$(get_location_code "$locale")
	local language_code
	language_code=$(get_language_code "$locale")

	local results="[]"

	if [[ "$provider" == "dataforseo" ]] || [[ "$provider" == "both" ]]; then
		local response
		response=$(dataforseo_autocomplete "$keyword" "$location_code" "$language_code")

		local parsed
		# Parse keyword_suggestions response format (same as keyword research)
		parsed=$(echo "$response" | jq '[.tasks[0].result[0].items[]? | {
            keyword: .keyword,
            volume: (.keyword_info.search_volume // 0),
            cpc: (.keyword_info.cpc // 0),
            difficulty: (.keyword_properties.keyword_difficulty // 0),
            intent: (.search_intent_info.main_intent // "unknown")
        }]' 2>/dev/null || echo "[]")

		results=$(echo "$results $parsed" | jq -s 'add')
	fi

	if [[ "$provider" == "serper" ]] || [[ "$provider" == "both" ]]; then
		local gl_code="${locale%-*}"
		local response
		response=$(serper_autocomplete "$keyword" "$gl_code")

		local parsed
		# Serper returns suggestions[].value
		parsed=$(echo "$response" | jq '[.suggestions[]? | {
            keyword: .value,
            volume: 0,
            cpc: 0,
            difficulty: 0,
            intent: "unknown"
        }]' 2>/dev/null || echo "[]")

		results=$(echo "$results $parsed" | jq -s 'add | unique_by(.keyword)')
	fi

	local count
	count=$(echo "$results" | jq 'length')
	print_success "Found $count autocomplete suggestions"

	print_research_table "$results" "basic"

	if [[ "$csv_export" == "true" ]]; then
		local timestamp
		timestamp=$(date +"%Y%m%d-%H%M%S")
		export_csv "$results" "basic" "autocomplete-research-$timestamp.csv"
	fi

	return 0
}

# Fetch ranked keywords for domain/competitor/gap modes
# Outputs JSON array to stdout
_extended_research_ranked() {
	local mode="$1"
	local target="$2"
	local location_code="$3"
	local language_code="$4"
	local limit="$5"

	local response

	case "$mode" in
	"domain")
		print_info "Domain research for: $target"
		response=$(dataforseo_ranked_keywords "$target" "$location_code" "$language_code" "$limit")

		echo "$response" | jq '[.tasks[0].result[0].items[]? | {
                keyword: .keyword_data.keyword,
                volume: (.keyword_data.keyword_info.search_volume // 0),
                cpc: (.keyword_data.keyword_info.cpc // 0),
                difficulty: (.keyword_data.keyword_info.keyword_difficulty // 0),
                intent: (.keyword_data.search_intent_info.main_intent // "unknown"),
                position: .ranked_serp_element.serp_item.rank_absolute,
                est_traffic: (.ranked_serp_element.serp_item.etv // 0),
                ranking_url: .ranked_serp_element.serp_item.url
            }]' 2>/dev/null || echo "[]"
		;;
	"competitor")
		print_info "Competitor research for: $target"
		response=$(dataforseo_ranked_keywords "$target" "$location_code" "$language_code" "$limit")

		echo "$response" | jq '[.tasks[0].result[0].items[]? | {
                keyword: .keyword_data.keyword,
                volume: (.keyword_data.keyword_info.search_volume // 0),
                cpc: (.keyword_data.keyword_info.cpc // 0),
                difficulty: (.keyword_data.keyword_info.keyword_difficulty // 0),
                intent: (.keyword_data.search_intent_info.main_intent // "unknown"),
                position: .ranked_serp_element.serp_item.rank_absolute,
                est_traffic: (.ranked_serp_element.serp_item.etv // 0),
                ranking_url: .ranked_serp_element.serp_item.url
            }]' 2>/dev/null || echo "[]"
		;;
	"gap")
		local -a domains
		IFS=',' read -ra domains <<<"$target"
		local your_domain="${domains[0]}"
		local competitor_domain="${domains[1]}"
		print_info "Keyword gap: $your_domain vs $competitor_domain"

		response=$(dataforseo_keyword_gap "$your_domain" "$competitor_domain" "$location_code" "$language_code" "$limit")

		echo "$response" | jq '[.tasks[0].result[0].items[]? | {
                keyword: .keyword_data.keyword,
                volume: (.keyword_data.keyword_info.search_volume // 0),
                cpc: (.keyword_data.keyword_info.cpc // 0),
                difficulty: (.keyword_data.keyword_info.keyword_difficulty // 0),
                intent: (.keyword_data.search_intent_info.main_intent // "unknown"),
                position: .first_domain_serp_element.serp_item.rank_absolute,
                est_traffic: (.first_domain_serp_element.serp_item.etv // 0),
                ranking_url: .first_domain_serp_element.serp_item.url
            }]' 2>/dev/null || echo "[]"
		;;
	*)
		echo "[]"
		;;
	esac
	return 0
}

# Quick-mode keyword suggestions without SERP analysis
# Outputs JSON array to stdout
_extended_research_quick() {
	local keywords="$1"
	local location_code="$2"
	local language_code="$3"
	local limit="$4"

	local results="[]"
	local -a keyword_array
	IFS=',' read -ra keyword_array <<<"$keywords"

	local keyword
	for keyword in "${keyword_array[@]}"; do
		keyword=$(echo "$keyword" | xargs)
		print_info "Researching: $keyword"

		local suggestions
		suggestions=$(dataforseo_keyword_suggestions "$keyword" "$location_code" "$language_code" "$limit")

		local parsed
		parsed=$(echo "$suggestions" | jq '[.tasks[0].result[0].items[]? | {
            keyword: .keyword,
            volume: (.keyword_info.search_volume // 0),
            cpc: (.keyword_info.cpc // 0),
            difficulty: (.keyword_properties.keyword_difficulty // 0),
            intent: (.search_intent_info.main_intent // "unknown"),
            keyword_score: 0,
            domain_score: 0,
            page_score: 0,
            weakness_count: 0,
            weaknesses: "N/A (quick mode)"
        }]' 2>/dev/null || echo "[]")

		results=$(echo "$results $parsed" | jq -s 'add')
	done

	echo "$results"
	return 0
}

# Full SERP analysis mode - fetches SERP data and detects weaknesses per keyword
# Outputs JSON array to stdout
_extended_research_full_serp() {
	local keywords="$1"
	local location_code="$2"
	local language_code="$3"
	local limit="$4"

	local results="[]"
	local -a keyword_array
	IFS=',' read -ra keyword_array <<<"$keywords"

	local keyword
	for keyword in "${keyword_array[@]}"; do
		keyword=$(echo "$keyword" | xargs)
		print_info "Analyzing SERP for: $keyword"

		# Get keyword suggestions first
		local suggestions
		suggestions=$(dataforseo_keyword_suggestions "$keyword" "$location_code" "$language_code" "$limit")

		# Get list of keywords
		local kw_list
		kw_list=$(echo "$suggestions" | jq -r '.tasks[0].result[0].items[]?.keyword' 2>/dev/null | head -n "$limit")

		# Process each keyword
		while IFS= read -r kw; do
			if [[ -z "$kw" ]]; then
				continue
			fi

			local kw_data
			kw_data=$(echo "$suggestions" | jq --arg k "$kw" '.tasks[0].result[0].items[] | select(.keyword == $k)' 2>/dev/null)

			local volume
			volume=$(echo "$kw_data" | jq -r '.keyword_info.search_volume // 0')
			local cpc
			cpc=$(echo "$kw_data" | jq -r '.keyword_info.cpc // 0')
			local difficulty
			difficulty=$(echo "$kw_data" | jq -r '.keyword_properties.keyword_difficulty // 0')
			local intent
			intent=$(echo "$kw_data" | jq -r '.search_intent_info.main_intent // "unknown"')

			# Get SERP data for weakness detection
			local serp_data
			serp_data=$(dataforseo_serp_organic "$kw" "$location_code" "$language_code")

			# Detect weaknesses
			local weakness_result
			weakness_result=$(detect_weaknesses "$serp_data")
			local weakness_count
			weakness_count=$(echo "$weakness_result" | cut -d'|' -f1)
			local weakness_list
			weakness_list=$(echo "$weakness_result" | cut -d'|' -f2)

			# Get domain score from first result
			local domain_score
			domain_score=$(echo "$serp_data" | jq -r '.tasks[0].result[0].items[0].main_domain_rank // 0' 2>/dev/null || echo "0")
			local page_score
			page_score=$(echo "$serp_data" | jq -r '.tasks[0].result[0].items[0].page_rank // 0' 2>/dev/null || echo "0")

			# Normalize scores to 0-100
			domain_score=$(echo "scale=0; $domain_score / 10" | bc 2>/dev/null || echo "0")
			page_score=$(echo "scale=0; $page_score / 10" | bc 2>/dev/null || echo "0")

			# Calculate keyword score
			local serp_features
			serp_features=$(echo "$serp_data" | jq '.tasks[0].result[0].item_types // []' 2>/dev/null || echo "[]")
			local keyword_score
			keyword_score=$(calculate_keyword_score "$weakness_count" "$volume" "$difficulty" "$serp_features")

			# Build result object and add to results
			local result_obj
			result_obj="{\"keyword\":\"$kw\",\"volume\":$volume,\"cpc\":$cpc,\"difficulty\":$difficulty,\"intent\":\"$intent\",\"keyword_score\":$keyword_score,\"domain_score\":$domain_score,\"page_score\":$page_score,\"weakness_count\":$weakness_count,\"weaknesses\":\"$weakness_list\"}"
			results=$(echo "$results [$result_obj]" | jq -s 'add')
		done <<<"$kw_list"
	done

	echo "$results"
	return 0
}

do_extended_research() {
	local keywords="$1"
	local provider="$2"
	local locale="$3"
	local limit="$4"
	local csv_export="$5"
	local quick_mode="$6"
	local include_ahrefs="$7"
	local mode="$8" # domain, competitor, gap, or empty for keyword
	local target="$9"

	print_header "Extended Keyword Research"
	print_info "Mode: ${mode:-keyword}"
	print_info "Provider: $provider"
	print_info "Locale: $locale"
	print_info "Quick mode: $quick_mode"
	print_info "Include Ahrefs: $include_ahrefs"

	check_credentials "$provider" || return 1

	if [[ "$include_ahrefs" == "true" ]]; then
		check_credentials "ahrefs" || print_warning "Ahrefs credentials not found. Skipping DR/UR metrics."
	fi

	local location_code
	location_code=$(get_location_code "$locale")
	local language_code
	language_code=$(get_language_code "$locale")

	local results="[]"

	case "$mode" in
	"domain" | "competitor" | "gap")
		results=$(_extended_research_ranked "$mode" "$target" "$location_code" "$language_code" "$limit")
		;;
	*)
		if [[ "$quick_mode" == "true" ]]; then
			results=$(_extended_research_quick "$keywords" "$location_code" "$language_code" "$limit")
		else
			results=$(_extended_research_full_serp "$keywords" "$location_code" "$language_code" "$limit")
		fi
		;;
	esac

	local count
	count=$(echo "$results" | jq 'length')
	print_success "Found $count keywords"

	# Print appropriate table
	if [[ "$mode" == "competitor" ]] || [[ "$mode" == "gap" ]] || [[ "$mode" == "domain" ]]; then
		print_research_table "$results" "competitor"
	else
		print_research_table "$results" "extended"
	fi

	# Export CSV if requested
	if [[ "$csv_export" == "true" ]]; then
		local timestamp
		timestamp=$(date +"%Y%m%d-%H%M%S")
		if [[ "$mode" == "competitor" ]] || [[ "$mode" == "gap" ]] || [[ "$mode" == "domain" ]]; then
			export_csv "$results" "competitor" "keyword-research-extended-$timestamp.csv"
		else
			export_csv "$results" "extended" "keyword-research-extended-$timestamp.csv"
		fi
	fi

	return 0
}

apply_filters() {
	local json_data="$1"
	local filters="$2"

	local result="$json_data"

	# Parse filters (format: min-volume:1000,max-difficulty:40,intent:commercial,contains:term,excludes:term)
	local -a filter_array
	IFS=',' read -ra filter_array <<<"$filters"

	for filter in "${filter_array[@]}"; do
		local key="${filter%%:*}"
		local value="${filter#*:}"

		case "$key" in
		"min-volume")
			result=$(echo "$result" | jq --argjson v "$value" '[.[] | select(.volume >= $v)]')
			;;
		"max-volume")
			result=$(echo "$result" | jq --argjson v "$value" '[.[] | select(.volume <= $v)]')
			;;
		"min-difficulty")
			result=$(echo "$result" | jq --argjson v "$value" '[.[] | select(.difficulty >= $v)]')
			;;
		"max-difficulty")
			result=$(echo "$result" | jq --argjson v "$value" '[.[] | select(.difficulty <= $v)]')
			;;
		"intent")
			result=$(echo "$result" | jq --arg v "$value" '[.[] | select(.intent == $v)]')
			;;
		"contains")
			result=$(echo "$result" | jq --arg v "$value" '[.[] | select(.keyword | contains($v))]')
			;;
		"excludes")
			result=$(echo "$result" | jq --arg v "$value" '[.[] | select(.keyword | contains($v) | not)]')
			;;
		*)
			print_warning "Unknown filter: $key"
			;;
		esac
	done

	echo "$result"
	return 0
}
