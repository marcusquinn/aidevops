#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tech Stack Merge Library -- Multi-provider result merging
# =============================================================================
# Covers collecting, validating, and merging tech-stack results from
# multiple providers into a unified report with confidence scoring.
#
# Usage: source "${SCRIPT_DIR}/tech-stack-merge-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error)
#   - tech-stack-providers-lib.sh (extract_domain)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TECH_STACK_MERGE_LIB_LOADED:-}" ]] && return 0
_TECH_STACK_MERGE_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Result Merging
# =============================================================================

# Collect valid provider result files into a JSON array string.
# Sets $combined (JSON array) and $providers_list (comma-separated names).
# Returns 1 if no valid results were found.
_merge_collect_results() {
	local combined_var="$1"
	local providers_var="$2"
	shift 2
	local -a result_files=("$@")

	local combined="["
	local first=true
	local providers_list=""
	local file

	for file in "${result_files[@]}"; do
		if [[ -f "$file" ]]; then
			local content
			content=$(cat "$file")
			if echo "$content" | jq -e '.error' &>/dev/null; then
				continue
			fi
			if [[ "$first" == "true" ]]; then
				first=false
			else
				combined+=","
			fi
			combined+="$content"
			local pname
			pname=$(echo "$content" | jq -r '.provider // "unknown"' 2>/dev/null || echo "unknown")
			if [[ -n "$providers_list" ]]; then
				providers_list+=",${pname}"
			else
				providers_list="$pname"
			fi
		fi
	done
	combined+="]"

	# Export via nameref-safe approach: write to temp files read by caller
	printf '%s' "$combined" >"${combined_var}"
	printf '%s' "$providers_list" >"${providers_var}"

	if [[ "$first" == "true" ]]; then
		return 1
	fi
	return 0
}

# Emit an empty/error merged result object for a URL.
_merge_empty_result() {
	local url="$1"
	local domain="$2"
	jq -n \
		--arg url "$url" \
		--arg domain "$domain" \
		'{
            url: $url,
            domain: $domain,
            scan_time: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            provider_count: 0,
            providers: [],
            technology_count: 0,
            technologies: [],
            categories: [],
            error: "no_providers_returned_results"
        }'
	return 0
}

# Merge results from multiple providers into a unified report.
# Strategy: union of all detected technologies, with confidence scores
# based on how many providers detected each technology.
merge_results() {
	local url="$1"
	shift
	local -a result_files=("$@")

	local domain
	domain=$(extract_domain "$url")

	local combined_file providers_file
	combined_file=$(mktemp)
	providers_file=$(mktemp)
	trap 'rm -f "${combined_file:-}" "${providers_file:-}"' RETURN

	if ! _merge_collect_results "$combined_file" "$providers_file" "${result_files[@]}"; then
		_merge_empty_result "$url" "$domain"
		return 1
	fi

	local combined providers_list
	combined=$(cat "$combined_file")
	providers_list=$(cat "$providers_file")

	echo "$combined" | jq \
		--arg url "$url" \
		--arg domain "$domain" \
		--arg providers "$providers_list" \
		'
        ($providers | split(",")) as $prov_list |
        [.[] | (.provider // "unknown") as $prov |
            (.technologies // [])[] |
            . + {detected_by: $prov}
        ] |
        group_by(.name | ascii_downcase) |
        map({
            name: .[0].name,
            category: .[0].category // "unknown",
            version: ([.[] | .version // empty] | if length > 0 then sort | last else null end),
            confidence: ((length / ($prov_list | length)) * 100 | round / 100),
            detected_by: [.[] | .detected_by] | unique,
            provider_count: ([.[] | .detected_by] | unique | length)
        }) |
        sort_by(-.confidence, .name) |
        {
            url: $url,
            domain: $domain,
            scan_time: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            provider_count: ($prov_list | length),
            providers: $prov_list,
            technology_count: length,
            technologies: .,
            categories: (group_by(.category) | map({
                category: .[0].category,
                count: length,
                technologies: [.[] | .name]
            }) | sort_by(.category))
        }
        ' 2>/dev/null || {
		log_error "Failed to merge provider results"
		echo '{"error":"merge_failed"}'
		return 1
	}

	return 0
}
