#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tech Stack Lookup Library -- Lookup, reverse lookup, and report commands
# =============================================================================
# Implements cmd_lookup (multi-provider site scanning), cmd_reverse (find sites
# using a technology), cmd_report, region-to-TLD mapping, and the associated
# usage/help text for these commands.
#
# Usage: source "${SCRIPT_DIR}/tech-stack-lookup-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (log_*, print_*, CYAN, NC)
#   - tech-stack-providers-lib.sh (normalize_url, run_provider, is_provider_available,
#                                   get_available_providers, provider_script)
#   - tech-stack-cache-lib.sh (cache_get_merged, cache_get_provider, cache_store,
#                               cache_store_merged, sqlite3_param)
#   - tech-stack-merge-lib.sh (merge_results)
#   - tech-stack-format-lib.sh (output_results)
#   - tech-stack-bq-lib.sh (check_bq_available, check_gcloud_auth, bq_reverse_lookup,
#                            builtwith_reverse_lookup)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TECH_STACK_LOOKUP_LIB_LOADED:-}" ]] && return 0
_TECH_STACK_LOOKUP_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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
# Lookup: detect tech stack of a URL
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

# =============================================================================
# Report command
# =============================================================================

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

# =============================================================================
# Reverse Lookup
# =============================================================================

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

# =============================================================================
# Help: Reverse lookup
# =============================================================================

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
