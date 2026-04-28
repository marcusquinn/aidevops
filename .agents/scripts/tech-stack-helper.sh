#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Tech Stack Helper — orchestrates multiple tech detection providers
# to replicate BuiltWith.com capabilities for single-site lookup,
# reverse lookup, reporting, and cached results.
#
# Usage:
#   tech-stack-helper.sh lookup <url>                  Detect tech stack of a URL
#   tech-stack-helper.sh reverse <technology>           Find sites using a technology
#   tech-stack-helper.sh report <url>                   Generate full markdown report
#   tech-stack-helper.sh cache [stats|clear|get <url>]  Manage SQLite cache
#   tech-stack-helper.sh providers                      List available providers
#   tech-stack-helper.sh categories                     List technology categories (BigQuery)
#   tech-stack-helper.sh trending                       Show trending technologies (BigQuery)
#   tech-stack-helper.sh info <technology>              Get technology metadata (BigQuery)
#   tech-stack-helper.sh help                           Show this help
#
# Options:
#   --json          Output raw JSON
#   --markdown      Output markdown report
#   --no-cache      Skip cache for this request
#   --provider <p>  Use only specified provider (unbuilt|crft|openexplorer|wappalyzer)
#   --parallel      Run providers in parallel (default)
#   --sequential    Run providers sequentially
#   --timeout <s>   Per-provider timeout in seconds (default: 60)
#   --cache-ttl <h> Cache TTL in hours (default: 168 = 7 days)
#
# Providers (t1064-t1067):
#   unbuilt       — Unbuilt.app CLI (frontend/JS detection)
#   crft          — CRFT Lookup (Wappalyzer-fork, Lighthouse scores)
#   openexplorer  — Open Tech Explorer (general detection)
#   wappalyzer    — Wappalyzer OSS fork (self-hosted fallback)
#
# Environment:
#   TECH_STACK_CACHE_DIR   Override cache directory
#   TECH_STACK_CACHE_TTL   Cache TTL in hours (default: 168)
#   TECH_STACK_TIMEOUT     Per-provider timeout in seconds (default: 60)

# Source shared constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck disable=SC2034
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true
init_log_file

# =============================================================================
# Configuration
# =============================================================================

# shellcheck disable=SC2034 # VERSION used in format_markdown/format_reverse_markdown output
readonly VERSION="1.0.0"
readonly CACHE_DIR="${TECH_STACK_CACHE_DIR:-${HOME}/.aidevops/.agent-workspace/work/tech-stack}"
readonly CACHE_DB="${CACHE_DIR}/cache.db"
readonly TS_DEFAULT_CACHE_TTL="${TECH_STACK_CACHE_TTL:-168}" # hours
readonly TS_DEFAULT_TIMEOUT="${TECH_STACK_TIMEOUT:-60}"      # seconds

# Provider list (bash 3.2 compatible — no associative arrays)
readonly PROVIDERS="unbuilt crft openexplorer wappalyzer"

# File-based cache for BigQuery results
readonly BQ_CACHE_DIR="${CACHE_DIR}/bq"
CACHE_TTL_DAYS=30
readonly DEFAULT_LIMIT=25
readonly MAX_LIMIT=1000
readonly DEFAULT_CLIENT="desktop"
readonly REPORTS_DIR="${HOME}/.aidevops/.agent-workspace/work/tech-stack/reports"
readonly UNBUILT_TIMEOUT="${UNBUILT_TIMEOUT:-120}"

# BigQuery configuration
readonly BQ_PROJECT_HTTPARCHIVE="httparchive"
readonly BQ_DATASET_CRAWL="crawl"
readonly BQ_TABLE_PAGES="pages"
readonly BQ_DATASET_WAPPALYZER="wappalyzer"
readonly BQ_TABLE_TECH_DETECTIONS="tech_detections"
readonly BQ_TABLE_TECHNOLOGIES="technologies"
readonly BQ_TABLE_CATEGORIES="categories"

# BuiltWith configuration
readonly BUILTWITH_API_BASE="https://api.builtwith.com"

# Common message constants
readonly HELP_SHOW_MESSAGE="Show this help"

# Technology categories for structured output (referenced by provider helpers)
# shellcheck disable=SC2034 # exported for provider helper scripts
readonly TECH_CATEGORIES="frameworks,cms,analytics,cdn,hosting,bundlers,ui-libs,state-management,styling,languages,databases,monitoring,security,seo,performance"

# Ensure directories exist
mkdir -p "$CACHE_DIR" "$BQ_CACHE_DIR" "$REPORTS_DIR" 2>/dev/null || true

# Map provider name to helper script filename
provider_script() {
	local provider="$1"
	case "$provider" in
	unbuilt) echo "unbuilt-provider-helper.sh" ;;
	crft) echo "crft-provider-helper.sh" ;;
	openexplorer) echo "openexplorer-provider-helper.sh" ;;
	wappalyzer) echo "wappalyzer-provider-helper.sh" ;;
	*) echo "" ;;
	esac
	return 0
}

# Map provider name to display name
provider_display_name() {
	local provider="$1"
	case "$provider" in
	unbuilt) echo "Unbuilt.app" ;;
	crft) echo "CRFT Lookup" ;;
	openexplorer) echo "Open Tech Explorer" ;;
	wappalyzer) echo "Wappalyzer OSS" ;;
	*) echo "$provider" ;;
	esac
	return 0
}

# =============================================================================
# Logging: uses shared log_* from shared-constants.sh
# =============================================================================

# =============================================================================
# Dependencies
# =============================================================================

check_dependencies() {
	local missing=()

	if ! command -v jq &>/dev/null; then
		missing+=("jq")
	fi

	if ! command -v sqlite3 &>/dev/null; then
		missing+=("sqlite3")
	fi

	if ! command -v curl &>/dev/null; then
		missing+=("curl")
	fi

	if [[ ${#missing[@]} -gt 0 ]]; then
		log_error "Missing required tools: ${missing[*]}"
		log_info "Install with: brew install ${missing[*]}"
		return 1
	fi

	return 0
}

# =============================================================================
# URL Normalization
# =============================================================================

normalize_url() {
	local url="$1"

	# Add https:// if no protocol specified
	if [[ ! "$url" =~ ^https?:// ]]; then
		url="https://${url}"
	fi

	# Remove trailing slash
	url="${url%/}"

	echo "$url"
	return 0
}

# Extract domain from URL for cache key
extract_domain() {
	local url="$1"

	# Remove protocol
	local domain="${url#*://}"
	# Remove path
	domain="${domain%%/*}"
	# Remove port
	domain="${domain%%:*}"

	echo "$domain"
	return 0
}

# =============================================================================
# Sub-libraries
# =============================================================================

# shellcheck source=./tech-stack-cache-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/tech-stack-cache-lib.sh"

# shellcheck source=./tech-stack-bq-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/tech-stack-bq-lib.sh"

# =============================================================================
# Provider Management
# =============================================================================

# List available providers and their status
list_providers() {
	echo -e "${CYAN}=== Tech Stack Providers ===${NC}"
	echo ""

	local provider
	for provider in $PROVIDERS; do
		local script
		script=$(provider_script "$provider")
		local name
		name=$(provider_display_name "$provider")
		local script_path="${SCRIPT_DIR}/${script}"
		local status

		if [[ -x "$script_path" ]]; then
			status="${GREEN}available${NC}"
		elif [[ -f "$script_path" ]]; then
			status="${YELLOW}not executable${NC}"
		else
			status="${RED}not installed${NC}"
		fi

		printf "  %-15s %-25s %b\n" "$provider" "$name" "$status"
	done

	echo ""
	echo "Provider helpers are installed by tasks t1064-t1067."
	echo "Each provider implements: lookup <url> --json"

	return 0
}

# Check if a specific provider is available
is_provider_available() {
	local provider="$1"

	local script
	script=$(provider_script "$provider")
	if [[ -z "$script" ]]; then
		return 1
	fi

	local script_path="${SCRIPT_DIR}/${script}"
	if [[ -x "$script_path" ]]; then
		return 0
	fi

	return 1
}

# Get list of available providers
get_available_providers() {
	local available=()
	local provider

	for provider in $PROVIDERS; do
		if is_provider_available "$provider"; then
			available+=("$provider")
		fi
	done

	if [[ ${#available[@]} -eq 0 ]]; then
		echo ""
		return 1
	fi

	echo "${available[*]}"
	return 0
}

# Run a single provider lookup
run_provider() {
	local provider="$1"
	local url="$2"
	local timeout_secs="$3"

	local script
	script=$(provider_script "$provider")
	local script_path="${SCRIPT_DIR}/${script}"

	if [[ ! -x "$script_path" ]]; then
		log_warning "Provider '${provider}' not available: ${script_path}"
		echo '{"error":"provider_not_available","provider":"'"$provider"'"}'
		return 1
	fi

	local result
	if result=$(timeout "$timeout_secs" "$script_path" lookup "$url" --json 2>/dev/null); then
		# Validate JSON
		if echo "$result" | jq empty 2>/dev/null; then
			echo "$result"
			return 0
		else
			log_warning "Provider '${provider}' returned invalid JSON"
			echo '{"error":"invalid_json","provider":"'"$provider"'"}'
			return 1
		fi
	else
		local exit_code=$?
		if [[ $exit_code -eq 124 ]]; then
			log_warning "Provider '${provider}' timed out after ${timeout_secs}s"
			echo '{"error":"timeout","provider":"'"$provider"'"}'
		else
			log_warning "Provider '${provider}' failed with exit code ${exit_code}"
			echo '{"error":"provider_failed","provider":"'"$provider"'","exit_code":'"$exit_code"'}'
		fi
		return 1
	fi
}

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

# =============================================================================
# Output Formatting (JSON-based, for multi-provider results)
# =============================================================================

# Format merged results as a terminal table
format_table() {
	local json="$1"

	local url domain tech_count provider_count scan_time
	url=$(echo "$json" | jq -r '.url' 2>/dev/null)
	domain=$(echo "$json" | jq -r '.domain' 2>/dev/null)
	tech_count=$(echo "$json" | jq -r '.technology_count' 2>/dev/null)
	provider_count=$(echo "$json" | jq -r '.provider_count' 2>/dev/null)
	scan_time=$(echo "$json" | jq -r '.scan_time' 2>/dev/null)

	echo ""
	echo -e "${CYAN}=== Tech Stack: ${domain} ===${NC}"
	echo -e "URL: ${url}"
	echo -e "Scanned: ${scan_time} | Providers: ${provider_count} | Technologies: ${tech_count}"
	echo ""

	# Print by category
	echo "$json" | jq -r '.categories[] | "\(.category)|\(.count)"' 2>/dev/null | while IFS='|' read -r category count; do
		echo -e "${GREEN}${category}${NC} (${count}):"

		echo "$json" | jq -r --arg cat "$category" '
            .technologies[] | select(.category == $cat) |
            "  \(.name)\t\(.version // "-")\t\(.confidence * 100 | round)%\t[\(.detected_by | join(", "))]"
        ' 2>/dev/null | while IFS= read -r line; do
			echo -e "$line"
		done

		echo ""
	done

	return 0
}

# Format merged results as markdown
format_markdown() {
	local json="$1"

	local url domain tech_count provider_count scan_time
	url=$(echo "$json" | jq -r '.url' 2>/dev/null)
	domain=$(echo "$json" | jq -r '.domain' 2>/dev/null)
	tech_count=$(echo "$json" | jq -r '.technology_count' 2>/dev/null)
	provider_count=$(echo "$json" | jq -r '.provider_count' 2>/dev/null)
	scan_time=$(echo "$json" | jq -r '.scan_time' 2>/dev/null)

	echo "# Tech Stack Report: ${domain}"
	echo ""
	echo "- **URL**: ${url}"
	echo "- **Scanned**: ${scan_time}"
	echo "- **Providers**: ${provider_count}"
	echo "- **Technologies detected**: ${tech_count}"
	echo ""

	echo "## Technologies by Category"
	echo ""

	echo "$json" | jq -r '.categories[] | "### \(.category) (\(.count))\n"' 2>/dev/null | while IFS= read -r line; do
		echo "$line"
	done

	echo "| Technology | Version | Confidence | Detected By |"
	echo "|------------|---------|------------|-------------|"

	echo "$json" | jq -r '
        .technologies[] |
        "| \(.name) | \(.version // "-") | \(.confidence * 100 | round)% | \(.detected_by | join(", ")) |"
    ' 2>/dev/null

	echo ""
	echo "---"
	echo "*Generated by tech-stack-helper.sh v${VERSION}*"

	return 0
}

# =============================================================================
# Core Commands
# =============================================================================

# Run providers in parallel, writing results to tmp_dir/<provider>.json.
# Populates result_files_var (nameref-safe: writes paths to a temp file, one per line).
_lookup_run_parallel() {
	local url="$1"
	local use_cache="$2"
	local timeout_secs="$3"
	local cache_ttl="$4"
	local tmp_dir="$5"
	local result_files_out="$6"
	shift 6
	local -a providers_to_run=("$@")

	local -a pids=()
	local provider
	for provider in "${providers_to_run[@]}"; do
		local result_file="${tmp_dir}/${provider}.json"
		printf '%s\n' "$result_file" >>"$result_files_out"

		if [[ "$use_cache" == "true" ]]; then
			local provider_cached
			if provider_cached=$(cache_get_provider "$url" "$provider"); then
				echo "$provider_cached" >"$result_file"
				log_info "Provider cache hit: ${provider}"
				continue
			fi
		fi

		(
			local result
			result=$(run_provider "$provider" "$url" "$timeout_secs")
			echo "$result" >"$result_file"
			if ! echo "$result" | jq -e '.error' &>/dev/null; then
				cache_store "$url" "$provider" "$result" "$cache_ttl"
			fi
		) &
		pids+=($!)
	done

	local pid
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || true
	done
	return 0
}

# Run providers sequentially, writing results to tmp_dir/<provider>.json.
_lookup_run_sequential() {
	local url="$1"
	local use_cache="$2"
	local timeout_secs="$3"
	local cache_ttl="$4"
	local tmp_dir="$5"
	local result_files_out="$6"
	shift 6
	local -a providers_to_run=("$@")

	local provider
	for provider in "${providers_to_run[@]}"; do
		local result_file="${tmp_dir}/${provider}.json"
		printf '%s\n' "$result_file" >>"$result_files_out"

		if [[ "$use_cache" == "true" ]]; then
			local provider_cached
			if provider_cached=$(cache_get_provider "$url" "$provider"); then
				echo "$provider_cached" >"$result_file"
				log_info "Provider cache hit: ${provider}"
				continue
			fi
		fi

		local result
		result=$(run_provider "$provider" "$url" "$timeout_secs")
		echo "$result" >"$result_file"
		if ! echo "$result" | jq -e '.error' &>/dev/null; then
			cache_store "$url" "$provider" "$result" "$cache_ttl"
		fi
	done
	return 0
}

# Lookup: detect tech stack of a URL
cmd_lookup() {
	local url="$1"
	local use_cache="$2"
	local output_format="$3"
	local specific_provider="$4"
	local run_parallel="$5"
	local timeout_secs="$6"
	local cache_ttl="$7"

	url=$(normalize_url "$url")
	log_info "Looking up tech stack for: ${url}"

	if [[ "$use_cache" == "true" ]]; then
		local cached
		if cached=$(cache_get_merged "$url"); then
			log_success "Cache hit for ${url}"
			output_results "$cached" "$output_format"
			return 0
		fi
	fi

	local -a providers_to_run=()
	if [[ -n "$specific_provider" ]]; then
		if is_provider_available "$specific_provider"; then
			providers_to_run+=("$specific_provider")
		else
			log_error "Provider '${specific_provider}' is not available"
			list_providers
			return 1
		fi
	else
		local available
		available=$(get_available_providers) || {
			log_error "No providers available. Install provider helpers (t1064-t1067)."
			list_providers
			return 1
		}
		read -ra providers_to_run <<<"$available"
	fi

	log_info "Using providers: ${providers_to_run[*]}"

	local tmp_dir
	tmp_dir=$(mktemp -d)
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	local result_files_out="${tmp_dir}/_result_files.txt"

	if [[ "$run_parallel" == "true" && ${#providers_to_run[@]} -gt 1 ]]; then
		_lookup_run_parallel "$url" "$use_cache" "$timeout_secs" "$cache_ttl" \
			"$tmp_dir" "$result_files_out" "${providers_to_run[@]}"
	else
		_lookup_run_sequential "$url" "$use_cache" "$timeout_secs" "$cache_ttl" \
			"$tmp_dir" "$result_files_out" "${providers_to_run[@]}"
	fi

	local -a result_files=()
	if [[ -f "$result_files_out" ]]; then
		while IFS= read -r rf; do
			result_files+=("$rf")
		done <"$result_files_out"
	fi

	local merged
	merged=$(merge_results "$url" "${result_files[@]}") || {
		log_error "Failed to merge results"
		return 1
	}

	if [[ "$use_cache" == "true" ]]; then
		local providers_str
		providers_str=$(echo "$merged" | jq -r '.providers | join(",")' 2>/dev/null || echo "")
		cache_store_merged "$url" "$merged" "$providers_str" "$cache_ttl"
	fi

	output_results "$merged" "$output_format"
	return 0
}

# Parse cmd_reverse args; write shell variable assignments to out_file.
# Returns 1 on --help or parse error (writes HELP/ERROR sentinel to out_file).
_reverse_parse_args() {
	local out_file="$1"
	shift

	local technology="" limit="$DEFAULT_LIMIT" client="$DEFAULT_CLIENT"
	local traffic="" keywords="" region="" industry=""
	local format="json" provider="auto" crawl_date=""
	local output_format="table" use_cache="true" cache_ttl="$TS_DEFAULT_CACHE_TTL"
	local filters_str=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit | -n)
			limit="$2"
			shift 2
			;;
		--traffic | -t)
			traffic="$2"
			shift 2
			;;
		--keywords | -k)
			keywords="$2"
			shift 2
			;;
		--region | -r)
			region="$2"
			shift 2
			;;
		--industry | -i)
			industry="$2"
			shift 2
			;;
		--format | -f)
			format="$2"
			output_format="$2"
			shift 2
			;;
		--json)
			format="json"
			output_format="json"
			shift
			;;
		--markdown)
			format="json"
			output_format="markdown"
			shift
			;;
		--provider | -p)
			provider="$2"
			shift 2
			;;
		--client)
			client="$2"
			shift 2
			;;
		--date)
			crawl_date="$2"
			shift 2
			;;
		--no-cache)
			use_cache="false"
			CACHE_TTL_DAYS=0
			shift
			;;
		--cache-ttl)
			cache_ttl="${2:-$TS_DEFAULT_CACHE_TTL}"
			shift 2
			;;
		--help | -h)
			usage_reverse
			printf 'HELP\n' >"$out_file"
			return 1
			;;
		-*)
			print_error "Unknown option: $1"
			usage_reverse
			printf 'ERROR\n' >"$out_file"
			return 1
			;;
		*)
			if [[ -z "$technology" ]]; then technology="$1"; else filters_str="${filters_str} $1"; fi
			shift
			;;
		esac
	done

	# Write variables as shell assignments; quote values that may contain spaces
	{
		printf 'technology=%s\n' "$technology"
		printf 'limit=%s\nclient=%s\n' "$limit" "$client"
		printf 'traffic=%s\nkeywords=%s\n' "$traffic" "$keywords"
		printf 'region=%s\nindustry=%s\n' "$region" "$industry"
		printf 'format=%s\noutput_format=%s\n' "$format" "$output_format"
		printf 'provider=%s\ncrawl_date=%s\n' "$provider" "$crawl_date"
		printf 'use_cache=%s\ncache_ttl=%s\n' "$use_cache" "$cache_ttl"
		printf 'filters_str=%s\n' "$filters_str"
	} >"$out_file"
	return 0
}

# Execute reverse lookup via installed provider helpers (not BigQuery/BuiltWith).
# Handles cache check, provider dispatch, merge, and cache store.
_reverse_via_providers() {
	local technology="$1"
	local use_cache="$2"
	local cache_ttl="$3"
	local output_format="$4"
	shift 4
	local -a reverse_providers=("$@")

	log_info "Reverse lookup for technology: ${technology}"

	local filters_hash
	filters_hash=$(printf '%s' "$technology" | shasum -a 256 | cut -d' ' -f1)

	if [[ "$use_cache" == "true" && -f "$CACHE_DB" ]]; then
		local cached
		cached=$(sqlite3_param "$CACHE_DB" \
			"SELECT results_json FROM reverse_cache
			WHERE technology = :tech
			  AND filters_hash = :hash
			  AND expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now');" \
			":tech" "$technology" \
			":hash" "$filters_hash" \
			2>/dev/null || echo "")
		if [[ -n "$cached" ]]; then
			log_success "Cache hit for reverse lookup: ${technology}"
			output_results "$cached" "$output_format"
			return 0
		fi
	fi

	local tmp_dir
	tmp_dir=$(mktemp -d)
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	local -a result_files=()
	local p
	for p in "${reverse_providers[@]}"; do
		local script
		script=$(provider_script "$p")
		local script_path="${SCRIPT_DIR}/${script}"
		local result_file="${tmp_dir}/${p}.json"
		result_files+=("$result_file")
		local result
		result=$(timeout "$TS_DEFAULT_TIMEOUT" "$script_path" reverse "$technology" --json 2>/dev/null) || true
		echo "${result:-{}}" >"$result_file"
	done

	local merged
	merged=$(jq -s '
        {
            technology: .[0].technology,
            scan_time: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            sites: [.[].sites // [] | .[]] | unique_by(.url),
            total_count: ([.[].sites // [] | .[]] | unique_by(.url) | length)
        }
    ' "${result_files[@]}" 2>/dev/null) || {
		log_error "Failed to merge reverse lookup results"
		return 1
	}

	if [[ "$use_cache" == "true" ]]; then
		log_stderr "cache reverse" sqlite3_param "$CACHE_DB" \
			"INSERT OR REPLACE INTO reverse_cache (technology, filters_hash, results_json, expires_at)
			VALUES (:tech, :hash, :json,
				strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+' || :ttl || ' hours'));" \
			":tech" "$technology" \
			":hash" "$filters_hash" \
			":json" "$merged" \
			":ttl" "$cache_ttl" \
			2>/dev/null || true
	fi

	output_results "$merged" "$output_format"
	return 0
}

# Reverse lookup: find sites using a technology.
# Supports both multi-provider orchestration (provider helpers) and BigQuery/BuiltWith direct.
cmd_reverse() {
	local args_file
	args_file=$(mktemp)
	trap 'rm -f "${args_file:-}"' RETURN

	if ! _reverse_parse_args "$args_file" "$@"; then
		local sentinel
		sentinel=$(cat "$args_file" 2>/dev/null || echo "ERROR")
		[[ "$sentinel" == "HELP" ]] && return 0
		return 1
	fi

	# shellcheck disable=SC1090
	source "$args_file"

	if [[ -z "$technology" ]]; then
		print_error "Technology name is required"
		usage_reverse
		return 1
	fi

	if [[ "$limit" -gt "$MAX_LIMIT" ]]; then
		print_warning "Limit capped at $MAX_LIMIT (requested: $limit)"
		limit="$MAX_LIMIT"
	fi

	if [[ -n "$region" ]]; then
		local region_tld
		region_tld=$(region_to_tld "$region")
		if [[ -n "$region_tld" ]]; then
			keywords="${keywords:+${keywords},}${region_tld}"
			print_info "Filtering by region: $region (TLD: $region_tld)"
		else
			print_warning "Unknown region '$region' — region filter ignored"
		fi
	fi

	if [[ -n "$industry" ]]; then
		keywords="${keywords:+${keywords},}${industry}"
		print_info "Filtering by industry keyword: $industry"
	fi

	local -a reverse_providers=()
	local p
	for p in $PROVIDERS; do
		local script
		script=$(provider_script "$p")
		local script_path="${SCRIPT_DIR}/${script}"
		if [[ -x "$script_path" ]]; then
			if "$script_path" help 2>/dev/null | grep -q "reverse"; then
				reverse_providers+=("$p")
			fi
		fi
	done

	if [[ ${#reverse_providers[@]} -gt 0 && "$provider" == "auto" ]]; then
		_reverse_via_providers "$technology" "$use_cache" "$cache_ttl" \
			"$output_format" "${reverse_providers[@]}"
		return $?
	fi

	case "$provider" in
	auto | httparchive | bq)
		if check_bq_available && check_gcloud_auth; then
			print_info "Using provider: HTTP Archive (BigQuery)"
			bq_reverse_lookup "$technology" "$limit" "$client" "$traffic" "$keywords" "$crawl_date" "$format"
		else
			print_warning "BigQuery not available, falling back to BuiltWith API..."
			builtwith_reverse_lookup "$technology" "$limit" "$format"
		fi
		;;
	builtwith)
		builtwith_reverse_lookup "$technology" "$limit" "$format"
		;;
	*)
		print_error "Unknown provider: $provider (use: auto, httparchive, builtwith)"
		return 1
		;;
	esac

	return $?
}

# Report: generate full markdown report for a URL
cmd_report() {
	local url="$1"
	local use_cache="$2"
	local specific_provider="$3"
	local timeout_secs="$4"
	local cache_ttl="$5"

	# Run lookup with markdown output
	cmd_lookup "$url" "$use_cache" "markdown" "$specific_provider" "true" "$timeout_secs" "$cache_ttl"

	return $?
}

# Output results in the requested format
output_results() {
	local json="$1"
	local format="$2"

	# Detect result type (lookup vs reverse)
	local is_reverse="false"
	if echo "$json" | jq -e '.technology' &>/dev/null; then
		is_reverse="true"
	fi

	case "$format" in
	json)
		echo "$json" | jq '.' 2>/dev/null || echo "$json"
		;;
	markdown)
		if [[ "$is_reverse" == "true" ]]; then
			format_reverse_markdown "$json"
		else
			format_markdown "$json"
		fi
		;;
	table | *)
		if [[ "$is_reverse" == "true" ]]; then
			format_reverse_table "$json"
		else
			format_table "$json"
		fi
		;;
	esac

	return 0
}

# Format reverse lookup results as terminal table
format_reverse_table() {
	local json="$1"

	local technology total_count scan_time note
	technology=$(echo "$json" | jq -r '.technology' 2>/dev/null)
	total_count=$(echo "$json" | jq -r '.total_count' 2>/dev/null)
	scan_time=$(echo "$json" | jq -r '.scan_time' 2>/dev/null)
	note=$(echo "$json" | jq -r '.note // empty' 2>/dev/null)

	echo ""
	echo -e "${CYAN}=== Reverse Lookup: ${technology} ===${NC}"
	echo -e "Scanned: ${scan_time} | Sites found: ${total_count}"

	if [[ -n "$note" ]]; then
		echo ""
		echo -e "${YELLOW}Note:${NC} ${note}"
	fi

	if [[ "$total_count" != "0" ]]; then
		echo ""
		echo "$json" | jq -r '.sites[] | "  \(.url)\t\(.traffic_tier // "-")\t\(.region // "-")"' 2>/dev/null
	fi

	echo ""
	return 0
}

# Format reverse lookup results as markdown
format_reverse_markdown() {
	local json="$1"

	local technology total_count scan_time note
	technology=$(echo "$json" | jq -r '.technology' 2>/dev/null)
	total_count=$(echo "$json" | jq -r '.total_count' 2>/dev/null)
	scan_time=$(echo "$json" | jq -r '.scan_time' 2>/dev/null)
	note=$(echo "$json" | jq -r '.note // empty' 2>/dev/null)

	echo "# Reverse Lookup: ${technology}"
	echo ""
	echo "- **Scanned**: ${scan_time}"
	echo "- **Sites found**: ${total_count}"

	if [[ -n "$note" ]]; then
		echo ""
		echo "> ${note}"
	fi

	if [[ "$total_count" != "0" ]]; then
		echo ""
		echo "| URL | Traffic | Region |"
		echo "|-----|---------|--------|"
		echo "$json" | jq -r '.sites[] | "| \(.url) | \(.traffic_tier // "-") | \(.region // "-") |"' 2>/dev/null
	fi

	echo ""
	echo "---"
	echo "*Generated by tech-stack-helper.sh v${VERSION}*"

	return 0
}

# =============================================================================
# Command: categories
# =============================================================================

cmd_categories() {
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format | -f)
			format="$2"
			shift 2
			;;
		--help | -h)
			usage_categories
			return 0
			;;
		*) shift ;;
		esac
	done

	if ! check_bq_available || ! check_gcloud_auth; then
		print_error "BigQuery required for categories listing"
		return 1
	fi

	bq_list_categories "$format"
	return $?
}

# =============================================================================
# Command: trending
# =============================================================================

cmd_trending() {
	local direction="adopted"
	local limit=20
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--direction | -d)
			direction="$2"
			shift 2
			;;
		--limit | -n)
			limit="$2"
			shift 2
			;;
		--format | -f)
			format="$2"
			shift 2
			;;
		--help | -h)
			usage_trending
			return 0
			;;
		*) shift ;;
		esac
	done

	if ! check_bq_available || ! check_gcloud_auth; then
		print_error "BigQuery required for trending data"
		return 1
	fi

	bq_trending "$direction" "$limit" "$format"
	return $?
}

# =============================================================================
# Command: info
# =============================================================================

cmd_info() {
	local technology=""
	local format="json"
	local show_detections=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format | -f)
			format="$2"
			shift 2
			;;
		--detections)
			show_detections=true
			shift
			;;
		--help | -h)
			usage_info
			return 0
			;;
		-*)
			print_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$technology" ]]; then
				technology="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$technology" ]]; then
		print_error "Technology name is required"
		usage_info
		return 1
	fi

	if ! check_bq_available || ! check_gcloud_auth; then
		print_error "BigQuery required for technology info"
		return 1
	fi

	bq_tech_info "$technology" "$format"

	if [[ "$show_detections" == true ]]; then
		echo ""
		print_info "Adoption/deprecation history:"
		bq_tech_detections "$technology" 6 "$format"
	fi

	return 0
}

# =============================================================================
# Region to TLD Mapping
# =============================================================================

region_to_tld() {
	local region="$1"
	local tld=""

	case "$(echo "$region" | tr '[:upper:]' '[:lower:]')" in
	uk | gb | "united kingdom") tld=".co.uk" ;;
	us | usa | "united states") tld=".com" ;;
	de | germany) tld=".de" ;;
	fr | france) tld=".fr" ;;
	jp | japan) tld=".jp" ;;
	cn | china) tld=".cn" ;;
	au | australia) tld=".com.au" ;;
	ca | canada) tld=".ca" ;;
	br | brazil) tld=".com.br" ;;
	in | india) tld=".in" ;;
	it | italy) tld=".it" ;;
	es | spain) tld=".es" ;;
	nl | netherlands) tld=".nl" ;;
	se | sweden) tld=".se" ;;
	no | norway) tld=".no" ;;
	dk | denmark) tld=".dk" ;;
	fi | finland) tld=".fi" ;;
	pl | poland) tld=".pl" ;;
	ru | russia) tld=".ru" ;;
	kr | "south korea") tld=".kr" ;;
	*)
		if [[ ${#region} -le 3 ]]; then
			tld=".${region}"
		fi
		;;
	esac

	echo "$tld"
	return 0
}

# =============================================================================
# Help
# =============================================================================

print_usage() {
	cat <<'EOF'
Tech Stack Helper — Open-source BuiltWith alternative

USAGE:
    tech-stack-helper.sh <command> [options]

COMMANDS:
    lookup <url>                  Detect the full tech stack of a URL
    reverse <technology>          Find sites using a specific technology
    report <url>                  Generate a full markdown report
    cache [stats|clear|get <url>] Manage the SQLite result cache
    providers                     List available detection providers
    categories                    List technology categories (BigQuery)
    trending                      Show trending technologies (BigQuery)
    info <technology>             Get technology metadata (BigQuery)
    help                          Show this help message

OPTIONS:
    --json              Output raw JSON
    --markdown          Output markdown report
    --no-cache          Skip cache for this request
    --provider <name>   Use only the specified provider
    --parallel          Run providers in parallel (default)
    --sequential        Run providers sequentially
    --timeout <secs>    Per-provider timeout (default: 60)
    --cache-ttl <hours> Cache TTL in hours (default: 168 = 7 days)

PROVIDERS:
    unbuilt       Unbuilt.app — frontend/JS detection (t1064)
    crft          CRFT Lookup — Wappalyzer-fork + Lighthouse (t1065)
    openexplorer  Open Tech Explorer — general detection (t1066)
    wappalyzer    Wappalyzer OSS — self-hosted fallback (t1067)

EXAMPLES:
    tech-stack-helper.sh lookup example.com
    tech-stack-helper.sh lookup https://github.com --json
    tech-stack-helper.sh lookup example.com --provider unbuilt
    tech-stack-helper.sh reverse "React" --json
    tech-stack-helper.sh reverse WordPress --limit 50 --traffic top10k
    tech-stack-helper.sh reverse React --region uk --format table
    tech-stack-helper.sh report example.com > report.md
    tech-stack-helper.sh cache stats
    tech-stack-helper.sh cache clear expired
    tech-stack-helper.sh cache get example.com
    tech-stack-helper.sh providers
    tech-stack-helper.sh categories --format table
    tech-stack-helper.sh trending --direction adopted --limit 30
    tech-stack-helper.sh info WordPress --detections

PROVIDER INTERFACE:
    Each provider helper must implement:
      <provider>-provider-helper.sh lookup <url> --json
    
    Expected JSON output schema:
      {
        "provider": "<name>",
        "url": "<scanned-url>",
        "technologies": [
          {
            "name": "React",
            "category": "ui-libs",
            "version": "18.2",
            "confidence": 0.9
          }
        ],
        "meta": { ... }
      }

    Categories: frameworks, cms, analytics, cdn, hosting, bundlers,
    ui-libs, state-management, styling, languages, databases,
    monitoring, security, seo, performance

CACHE:
    Results are cached in SQLite at:
      ~/.aidevops/.agent-workspace/work/tech-stack/cache.db
    Default TTL: 7 days. Override with --cache-ttl or TECH_STACK_CACHE_TTL.

DATA SOURCES (reverse lookup):
    Primary:  HTTP Archive via BigQuery (crawl.pages + Wappalyzer detection)
    Fallback: BuiltWith API (requires API key)
    Prerequisites for BigQuery:
      - Google Cloud SDK (brew install google-cloud-sdk)
      - GCP project with BigQuery API enabled (free tier: 1TB/month)
      - gcloud auth login && gcloud config set project YOUR_PROJECT
EOF

	return 0
}

usage() {
	print_usage
	return 0
}

usage_reverse() {
	cat <<EOF
${CYAN}reverse${NC} — Find websites using a specific technology

${HELP_LABEL_USAGE}
  $0 reverse <technology> [options]

${HELP_LABEL_OPTIONS}
  --limit, -n <num>       Max results (default: $DEFAULT_LIMIT, max: $MAX_LIMIT)
  --traffic, -t <tier>    Filter by traffic rank: top1k, top10k, top100k, top1m, or number
  --keywords, -k <terms>  Filter URLs containing terms (comma-separated)
  --region, -r <region>   Filter by region (maps to TLD: uk, de, fr, jp, etc.)
  --industry, -i <term>   Filter by industry keyword in URL
  --format, -f <fmt>      Output format: json (default), table, csv
  --provider, -p <name>   Data provider: auto (default), httparchive, builtwith
  --client <type>         HTTP Archive client: desktop (default), mobile
  --date <YYYY-MM-DD>     Specific crawl date (default: latest)
  --no-cache              Skip cache, force fresh query
  --help, -h              ${HELP_SHOW_MESSAGE}

${HELP_LABEL_EXAMPLES}
  $0 reverse WordPress
  $0 reverse React --traffic top10k --format table
  $0 reverse Shopify --region uk --limit 50
  $0 reverse "Next.js" --keywords blog,news --format csv
  $0 reverse Cloudflare --traffic top1k --provider httparchive
EOF
	return 0
}

usage_categories() {
	cat <<EOF
${CYAN}categories${NC} — List available technology categories

${HELP_LABEL_USAGE}
  $0 categories [options]

${HELP_LABEL_OPTIONS}
  --format, -f <fmt>   Output format: json (default), table
  --help, -h           ${HELP_SHOW_MESSAGE}
EOF
	return 0
}

usage_trending() {
	cat <<EOF
${CYAN}trending${NC} — Show trending technology adoptions/deprecations

${HELP_LABEL_USAGE}
  $0 trending [options]

${HELP_LABEL_OPTIONS}
  --direction, -d <dir>  Direction: adopted (default), deprecated
  --limit, -n <num>      Max results (default: 20)
  --format, -f <fmt>     Output format: json (default), table
  --help, -h             ${HELP_SHOW_MESSAGE}
EOF
	return 0
}

usage_info() {
	cat <<EOF
${CYAN}info${NC} — Get technology metadata and adoption trends

${HELP_LABEL_USAGE}
  $0 info <technology> [options]

${HELP_LABEL_OPTIONS}
  --detections         Include adoption/deprecation history
  --format, -f <fmt>   Output format: json (default), table
  --help, -h           ${HELP_SHOW_MESSAGE}
EOF
	return 0
}

# =============================================================================
# Main Command Router
# =============================================================================

# Parse global options from main()'s argument list.
# Writes parsed values to out_file as shell variable assignments.
# Remaining positional args are written one-per-line to positional_file.
_main_parse_global_opts() {
	local out_file="$1"
	local positional_file="$2"
	shift 2

	local output_format="table" use_cache="true" specific_provider=""
	local run_parallel="true"
	local timeout_secs="$TS_DEFAULT_TIMEOUT"
	local cache_ttl="$TS_DEFAULT_CACHE_TTL"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			output_format="json"
			shift
			;;
		--markdown)
			output_format="markdown"
			shift
			;;
		--no-cache)
			use_cache="false"
			shift
			;;
		--provider)
			specific_provider="${2:-}"
			shift 2
			;;
		--parallel)
			run_parallel="true"
			shift
			;;
		--sequential)
			run_parallel="false"
			shift
			;;
		--timeout)
			timeout_secs="${2:-$TS_DEFAULT_TIMEOUT}"
			shift 2
			;;
		--cache-ttl)
			cache_ttl="${2:-$TS_DEFAULT_CACHE_TTL}"
			shift 2
			;;
		-h | --help)
			print_usage
			printf 'HELP\n' >"$out_file"
			return 1
			;;
		*)
			printf '%s\n' "$1" >>"$positional_file"
			shift
			;;
		esac
	done

	cat >"$out_file" <<ENDVARS
output_format=$output_format
use_cache=$use_cache
specific_provider=$specific_provider
run_parallel=$run_parallel
timeout_secs=$timeout_secs
cache_ttl=$cache_ttl
ENDVARS
	return 0
}

# Route a parsed command to the appropriate cmd_* function.
_main_route_command() {
	local command="$1"
	local use_cache="$2"
	local output_format="$3"
	local specific_provider="$4"
	local run_parallel="$5"
	local timeout_secs="$6"
	local cache_ttl="$7"
	shift 7
	local -a positional=("$@")

	case "$command" in
	lookup)
		local url="${positional[0]:-}"
		if [[ -z "$url" ]]; then
			log_error "URL is required. Usage: tech-stack-helper.sh lookup <url>"
			return 1
		fi
		cmd_lookup "$url" "$use_cache" "$output_format" "$specific_provider" "$run_parallel" "$timeout_secs" "$cache_ttl"
		;;
	reverse)
		local technology="${positional[0]:-}"
		if [[ -z "$technology" ]]; then
			log_error "Technology name is required. Usage: tech-stack-helper.sh reverse <technology>"
			return 1
		fi
		local -a filters=()
		if [[ ${#positional[@]} -gt 1 ]]; then
			filters=("${positional[@]:1}")
		fi
		cmd_reverse "$technology" ${filters[@]+"${filters[@]}"}
		;;
	report)
		local url="${positional[0]:-}"
		if [[ -z "$url" ]]; then
			log_error "URL is required. Usage: tech-stack-helper.sh report <url>"
			return 1
		fi
		cmd_report "$url" "$use_cache" "$specific_provider" "$timeout_secs" "$cache_ttl"
		;;
	cache)
		local subcmd="${positional[0]:-stats}"
		case "$subcmd" in
		stats) cache_stats ;;
		clear) cache_clear "${positional[1]:-expired}" ;;
		get)
			local url="${positional[1]:-}"
			if [[ -z "$url" ]]; then
				log_error "URL is required. Usage: tech-stack-helper.sh cache get <url>"
				return 1
			fi
			cache_get "$url"
			;;
		*)
			log_error "Unknown cache command: ${subcmd}. Use: stats, clear, get"
			return 1
			;;
		esac
		;;
	providers) list_providers ;;
	categories) cmd_categories ${positional[@]+"${positional[@]}"} ;;
	trending) cmd_trending ${positional[@]+"${positional[@]}"} ;;
	info)
		local technology="${positional[0]:-}"
		if [[ -z "$technology" ]]; then
			log_error "Technology name is required. Usage: tech-stack-helper.sh info <technology>"
			return 1
		fi
		cmd_info "$technology" "${positional[@]:1}"
		;;
	help | -h | --help) print_usage ;;
	version) echo "tech-stack-helper.sh v${VERSION}" ;;
	*)
		log_error "Unknown command: ${command}"
		print_usage
		return 1
		;;
	esac
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	local opts_file positional_file
	opts_file=$(mktemp)
	positional_file=$(mktemp)
	trap 'rm -f "${opts_file:-}" "${positional_file:-}"' RETURN

	if ! _main_parse_global_opts "$opts_file" "$positional_file" "$@"; then
		local sentinel
		sentinel=$(cat "$opts_file" 2>/dev/null || echo "ERROR")
		[[ "$sentinel" == "HELP" ]] && return 0
		return 1
	fi

	# shellcheck disable=SC1090
	source "$opts_file"

	local -a positional=()
	if [[ -s "$positional_file" ]]; then
		while IFS= read -r pos; do
			positional+=("$pos")
		done <"$positional_file"
	fi

	check_dependencies || return 1
	init_cache_db || true

	_main_route_command "$command" "$use_cache" "$output_format" \
		"$specific_provider" "$run_parallel" "$timeout_secs" "$cache_ttl" \
		"${positional[@]+"${positional[@]}"}"
	return $?
}

main "$@"
