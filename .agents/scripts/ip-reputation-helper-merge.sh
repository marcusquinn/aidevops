#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# IP Reputation Merge & Formatting -- result aggregation and output rendering
# =============================================================================
# Merges per-provider JSON results into a unified risk assessment, computes
# weighted scores with listing-flag boosts, and renders output in table,
# markdown, compact, or raw JSON formats.
#
# Usage: source "${SCRIPT_DIR}/ip-reputation-helper-merge.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error)
#   - ip-reputation-helper-providers.sh (provider_display_name)
#   - Color accessors (c_red, c_green, c_yellow, c_cyan, c_nc, c_bold) from orchestrator
#   - VERSION (from orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_IP_REP_MERGE_LIB_LOADED:-}" ]] && return 0
_IP_REP_MERGE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

# =============================================================================
# Risk Scoring
# =============================================================================

# Aggregate a single provider result file into running merge counters.
# Outputs updated counters as tab-separated: provider_results total_score provider_count
# listed_count is_tor is_proxy is_vpn errors cache_hits cache_misses
# (All passed by reference via nameref-style positional args — caller reassigns.)
# Returns 0 always; caller checks updated values.
_merge_aggregate_file() {
	local file="$1"
	# Passed-by-reference accumulators (caller must reassign from stdout)
	local _prov_results="$2"
	local _total_score="$3"
	local _provider_count="$4"
	local _listed_count="$5"
	local _is_tor="$6"
	local _is_proxy="$7"
	local _is_vpn="$8"
	local _errors="$9"
	local _cache_hits="${10}"
	local _cache_misses="${11}"

	[[ -f "$file" ]] || {
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_prov_results" "$_total_score" "$_provider_count" "$_listed_count" \
			"$_is_tor" "$_is_proxy" "$_is_vpn" "$_errors" "$_cache_hits" "$_cache_misses"
		return 0
	}

	local content
	content=$(cat "$file")
	[[ -z "$content" ]] && {
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_prov_results" "$_total_score" "$_provider_count" "$_listed_count" \
			"$_is_tor" "$_is_proxy" "$_is_vpn" "$_errors" "$_cache_hits" "$_cache_misses"
		return 0
	}

	echo "$content" | jq empty 2>/dev/null || {
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_prov_results" "$_total_score" "$_provider_count" "$_listed_count" \
			"$_is_tor" "$_is_proxy" "$_is_vpn" "$_errors" "$_cache_hits" "$_cache_misses"
		return 0
	}

	_prov_results=$(echo "$_prov_results" | jq --argjson r "$content" '. + [$r]')

	if echo "$content" | jq -e '.error' &>/dev/null; then
		_errors=$((_errors + 1))
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_prov_results" "$_total_score" "$_provider_count" "$_listed_count" \
			"$_is_tor" "$_is_proxy" "$_is_vpn" "$_errors" "$_cache_hits" "$_cache_misses"
		return 0
	fi

	_provider_count=$((_provider_count + 1))

	local was_cached
	was_cached=$(echo "$content" | jq -r '.cached // false')
	if [[ "$was_cached" == "true" ]]; then
		_cache_hits=$((_cache_hits + 1))
	else
		_cache_misses=$((_cache_misses + 1))
	fi

	local score is_listed
	score=$(echo "$content" | jq -r '.score // 0')
	is_listed=$(echo "$content" | jq -r '.is_listed // false')
	_total_score=$((_total_score + ${score%.*}))
	[[ "$is_listed" == "true" ]] && _listed_count=$((_listed_count + 1))

	[[ "$(echo "$content" | jq -r '.is_tor // false')" == "true" ]] && _is_tor=true
	[[ "$(echo "$content" | jq -r '.is_proxy // false')" == "true" ]] && _is_proxy=true
	[[ "$(echo "$content" | jq -r '.is_vpn // false')" == "true" ]] && _is_vpn=true

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$_prov_results" "$_total_score" "$_provider_count" "$_listed_count" \
		"$_is_tor" "$_is_proxy" "$_is_vpn" "$_errors" "$_cache_hits" "$_cache_misses"
	return 0
}

# Compute unified score + risk level + recommendation from aggregated counters.
# Outputs: unified_score<TAB>risk_level<TAB>recommendation
_merge_compute_risk() {
	local provider_count="$1"
	local total_score="$2"
	local listed_count="$3"

	local unified_score=0
	if [[ "$provider_count" -gt 0 ]]; then
		unified_score=$((total_score / provider_count))
	fi

	# Boost score if multiple providers agree on listing
	if [[ "$listed_count" -ge 3 ]]; then
		unified_score=$((unified_score > 85 ? 100 : unified_score + 15))
	elif [[ "$listed_count" -ge 2 ]]; then
		unified_score=$((unified_score > 90 ? 100 : unified_score + 10))
	fi

	local risk_level
	if [[ "$unified_score" -ge 75 ]]; then
		risk_level="critical"
	elif [[ "$unified_score" -ge 50 ]]; then
		risk_level="high"
	elif [[ "$unified_score" -ge 25 ]]; then
		risk_level="medium"
	elif [[ "$unified_score" -ge 5 ]]; then
		risk_level="low"
	else
		risk_level="clean"
	fi

	local recommendation
	case "$risk_level" in
	critical) recommendation="AVOID — IP is heavily flagged across multiple sources" ;;
	high) recommendation="AVOID — IP has significant abuse/attack history" ;;
	medium) recommendation="CAUTION — IP has some flags, investigate before use" ;;
	low) recommendation="PROCEED WITH CAUTION — minor flags detected" ;;
	clean) recommendation="SAFE — no significant flags detected" ;;
	*) recommendation="UNKNOWN — insufficient data" ;;
	esac

	printf '%s\t%s\t%s\n' "$unified_score" "$risk_level" "$recommendation"
	return 0
}

# Emit the final merged JSON object.
_merge_build_json() {
	local ip="$1"
	local unified_score="$2"
	local risk_level="$3"
	local recommendation="$4"
	local listed_count="$5"
	local provider_count="$6"
	local errors="$7"
	local is_tor="$8"
	local is_proxy="$9"
	local is_vpn="${10}"
	local cache_hits="${11}"
	local cache_misses="${12}"
	local provider_results="${13}"

	local scan_time
	scan_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	jq -n \
		--arg ip "$ip" \
		--argjson unified_score "$unified_score" \
		--arg risk_level "$risk_level" \
		--arg recommendation "$recommendation" \
		--argjson listed_count "$listed_count" \
		--argjson provider_count "$provider_count" \
		--argjson errors "$errors" \
		--argjson is_tor "$is_tor" \
		--argjson is_proxy "$is_proxy" \
		--argjson is_vpn "$is_vpn" \
		--argjson cache_hits "$cache_hits" \
		--argjson cache_misses "$cache_misses" \
		--argjson providers "$provider_results" \
		--arg scan_time "$scan_time" \
		'{
            ip: $ip,
            scan_time: $scan_time,
            unified_score: $unified_score,
            risk_level: $risk_level,
            recommendation: $recommendation,
            summary: {
                providers_queried: ($provider_count + $errors),
                providers_responded: $provider_count,
                providers_errored: $errors,
                listed_by: $listed_count,
                is_tor: $is_tor,
                is_proxy: $is_proxy,
                is_vpn: $is_vpn,
                cache_hits: $cache_hits,
                cache_misses: $cache_misses
            },
            providers: $providers
        }'
	return 0
}

# Merge per-provider results into unified risk assessment
# Strategy: weighted average of scores, with listing flags as hard signals
merge_results() {
	local ip="$1"
	shift
	local result_files=("$@")

	local provider_results="[]"
	local total_score=0
	local provider_count=0
	local listed_count=0
	local is_tor=false
	local is_proxy=false
	local is_vpn=false
	local errors=0
	local cache_hits=0
	local cache_misses=0

	local file
	for file in "${result_files[@]}"; do
		local row
		row=$(_merge_aggregate_file "$file" \
			"$provider_results" "$total_score" "$provider_count" "$listed_count" \
			"$is_tor" "$is_proxy" "$is_vpn" "$errors" "$cache_hits" "$cache_misses")
		IFS=$'\t' read -r provider_results total_score provider_count listed_count \
			is_tor is_proxy is_vpn errors cache_hits cache_misses <<<"$row"
	done

	local risk_row
	risk_row=$(_merge_compute_risk "$provider_count" "$total_score" "$listed_count")
	local unified_score risk_level recommendation
	IFS=$'\t' read -r unified_score risk_level recommendation <<<"$risk_row"

	_merge_build_json "$ip" "$unified_score" "$risk_level" "$recommendation" \
		"$listed_count" "$provider_count" "$errors" \
		"$is_tor" "$is_proxy" "$is_vpn" \
		"$cache_hits" "$cache_misses" "$provider_results"
	return 0
}

# =============================================================================
# Output Formatting
# =============================================================================

# Risk level color (respects --no-color)
risk_color() {
	local level="$1"
	case "$level" in
	critical) c_red ;;
	high) c_red ;;
	medium) c_yellow ;;
	low) c_yellow ;;
	clean) c_green ;;
	*) c_nc ;;
	esac
	return 0
}

# Risk level symbol
risk_symbol() {
	local level="$1"
	case "$level" in
	critical) echo "CRITICAL" ;;
	high) echo "HIGH" ;;
	medium) echo "MEDIUM" ;;
	low) echo "LOW" ;;
	clean) echo "CLEAN" ;;
	*) echo "UNKNOWN" ;;
	esac
	return 0
}

# Format results as terminal table
format_table() {
	local json="$1"

	local ip risk_level unified_score recommendation scan_time
	ip=$(echo "$json" | jq -r '.ip')
	risk_level=$(echo "$json" | jq -r '.risk_level')
	unified_score=$(echo "$json" | jq -r '.unified_score')
	recommendation=$(echo "$json" | jq -r '.recommendation')
	scan_time=$(echo "$json" | jq -r '.scan_time')

	local color
	color=$(risk_color "$risk_level")
	local symbol
	symbol=$(risk_symbol "$risk_level")

	echo ""
	echo -e "$(c_bold)$(c_cyan)=== IP Reputation Report ===$(c_nc)"
	echo -e "IP:          $(c_bold)${ip}$(c_nc)"
	echo -e "Scanned:     ${scan_time}"
	echo -e "Risk Level:  ${color}$(c_bold)${symbol}$(c_nc) (score: ${unified_score}/100)"
	echo -e "Verdict:     ${color}${recommendation}$(c_nc)"
	echo ""

	# Summary flags
	local is_tor is_proxy is_vpn listed_by providers_queried providers_responded
	is_tor=$(echo "$json" | jq -r '.summary.is_tor')
	is_proxy=$(echo "$json" | jq -r '.summary.is_proxy')
	is_vpn=$(echo "$json" | jq -r '.summary.is_vpn')
	listed_by=$(echo "$json" | jq -r '.summary.listed_by')
	providers_queried=$(echo "$json" | jq -r '.summary.providers_queried')
	providers_responded=$(echo "$json" | jq -r '.summary.providers_responded')

	local cache_hits cache_misses
	cache_hits=$(echo "$json" | jq -r '.summary.cache_hits // 0')
	cache_misses=$(echo "$json" | jq -r '.summary.cache_misses // 0')

	echo -e "$(c_bold)Summary:$(c_nc)"
	echo -e "  Providers:  ${providers_responded}/${providers_queried} responded"
	echo -e "  Listed by:  ${listed_by} provider(s)"
	if [[ "$cache_hits" -gt 0 || "$cache_misses" -gt 0 ]]; then
		echo -e "  Cache:      ${cache_hits} hit(s), ${cache_misses} miss(es)"
	fi
	local tor_flag proxy_flag vpn_flag
	tor_flag=$([[ "$is_tor" == "true" ]] && echo "$(c_red)YES$(c_nc)" || echo "$(c_green)NO$(c_nc)")
	proxy_flag=$([[ "$is_proxy" == "true" ]] && echo "$(c_red)YES$(c_nc)" || echo "$(c_green)NO$(c_nc)")
	vpn_flag=$([[ "$is_vpn" == "true" ]] && echo "$(c_yellow)YES$(c_nc)" || echo "$(c_green)NO$(c_nc)")
	echo -e "  Tor:        $(echo -e "$tor_flag")"
	echo -e "  Proxy:      $(echo -e "$proxy_flag")"
	echo -e "  VPN:        $(echo -e "$vpn_flag")"
	echo ""

	# Per-provider results
	echo -e "$(c_bold)Provider Results:$(c_nc)"
	printf "  %-18s %-10s %-8s %-8s %s\n" "Provider" "Risk" "Score" "Source" "Details"
	printf "  %-18s %-10s %-8s %-8s %s\n" "--------" "----" "-----" "------" "-------"

	local _nc
	_nc=$(c_nc)
	echo "$json" | jq -r '.providers[] | [.provider, (.risk_level // "error"), (.score // 0 | tostring), (if .cached then "cached" else "live" end), (.error // (.is_listed | if . then "listed" else "clean" end))] | @tsv' 2>/dev/null |
		while IFS=$'\t' read -r prov risk score source detail; do
			# Reset IFS to default before $() calls — prevents zsh IFS leak corrupting PATH lookup
			local prov_color display_name _saved_ifs="$IFS"
			IFS=$' \t\n'
			prov_color=$(risk_color "$risk")
			display_name=$(provider_display_name "$prov")
			IFS="$_saved_ifs"
			printf "  %-18s ${prov_color}%-10s${_nc} %-8s %-8s %s\n" "$display_name" "$risk" "$score" "$source" "$detail"
		done

	echo ""
	return 0
}

# Format results as markdown report
format_markdown() {
	local json="$1"

	local ip risk_level unified_score recommendation scan_time
	ip=$(echo "$json" | jq -r '.ip')
	risk_level=$(echo "$json" | jq -r '.risk_level')
	unified_score=$(echo "$json" | jq -r '.unified_score')
	recommendation=$(echo "$json" | jq -r '.recommendation')
	scan_time=$(echo "$json" | jq -r '.scan_time')

	local listed_by providers_queried providers_responded is_tor is_proxy is_vpn
	listed_by=$(echo "$json" | jq -r '.summary.listed_by')
	providers_queried=$(echo "$json" | jq -r '.summary.providers_queried')
	providers_responded=$(echo "$json" | jq -r '.summary.providers_responded')
	is_tor=$(echo "$json" | jq -r '.summary.is_tor')
	is_proxy=$(echo "$json" | jq -r '.summary.is_proxy')
	is_vpn=$(echo "$json" | jq -r '.summary.is_vpn')

	local cache_hits cache_misses
	cache_hits=$(echo "$json" | jq -r '.summary.cache_hits // 0')
	cache_misses=$(echo "$json" | jq -r '.summary.cache_misses // 0')

	# Uppercase risk level (portable — no bash 4 ^^ operator)
	local risk_upper
	risk_upper=$(echo "$risk_level" | tr '[:lower:]' '[:upper:]')

	cat <<EOF
# IP Reputation Report: ${ip}

- **Scanned**: ${scan_time}
- **Risk Level**: ${risk_upper} (${unified_score}/100)
- **Verdict**: ${recommendation}

## Summary

| Metric | Value |
|--------|-------|
| Providers queried | ${providers_queried} |
| Providers responded | ${providers_responded} |
| Listed by | ${listed_by} provider(s) |
| Cache hits | ${cache_hits} |
| Cache misses | ${cache_misses} |
| Tor exit node | ${is_tor} |
| Proxy detected | ${is_proxy} |
| VPN detected | ${is_vpn} |

## Provider Results

| Provider | Risk Level | Score | Source | Listed | Details |
|----------|-----------|-------|--------|--------|---------|
EOF

	echo "$json" | jq -r '.providers[] | "| \(.provider) | \(.risk_level // "error") | \(.score // 0) | \(if .cached then "cached" else "live" end) | \(.is_listed // false) | \(.error // "ok") |"' 2>/dev/null

	echo ""
	echo "---"
	echo "*Generated by ip-reputation-helper.sh v${VERSION}*"
	return 0
}

# Format results as compact one-line summary (for scripting/batch)
format_compact() {
	local json="$1"

	local ip risk_level unified_score listed_by is_tor is_proxy is_vpn
	ip=$(echo "$json" | jq -r '.ip')
	risk_level=$(echo "$json" | jq -r '.risk_level')
	unified_score=$(echo "$json" | jq -r '.unified_score')
	listed_by=$(echo "$json" | jq -r '.summary.listed_by')
	is_tor=$(echo "$json" | jq -r '.summary.is_tor')
	is_proxy=$(echo "$json" | jq -r '.summary.is_proxy')
	is_vpn=$(echo "$json" | jq -r '.summary.is_vpn')

	local risk_upper
	risk_upper=$(echo "$risk_level" | tr '[:lower:]' '[:upper:]')

	local color
	color=$(risk_color "$risk_level")

	local flags=""
	[[ "$is_tor" == "true" ]] && flags="${flags}Tor "
	[[ "$is_proxy" == "true" ]] && flags="${flags}Proxy "
	[[ "$is_vpn" == "true" ]] && flags="${flags}VPN "
	[[ -z "$flags" ]] && flags="none"

	echo -e "${ip}  ${color}${risk_upper}$(c_nc) (${unified_score}/100)  listed:${listed_by}  flags:${flags}"
	return 0
}

# Output results in requested format
output_results() {
	local json="$1"
	local format="$2"

	case "$format" in
	json) echo "$json" ;;
	markdown) format_markdown "$json" ;;
	compact) format_compact "$json" ;;
	table | *) format_table "$json" ;;
	esac
	return 0
}
