#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tech Stack BigQuery Library — BigQuery, BuiltWith, and file-based formatting
# =============================================================================
# BigQuery and BuiltWith provider functions extracted from tech-stack-helper.sh
# for size reduction. Also includes file-based output formatting helpers used
# exclusively by these providers.
#
# Covers:
#   1. BigQuery helpers    — check_bq_available, get_latest_crawl_date, etc.
#   2. BigQuery providers  — bq_reverse_lookup, bq_tech_detections, bq_trending, etc.
#   3. BuiltWith provider  — builtwith_reverse_lookup
#   4. File output helpers — format_output, format_as_table, format_as_csv
#
# Usage: source "${SCRIPT_DIR}/tech-stack-bq-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (log_*, print_*)
#   - tech-stack-cache-lib.sh (ensure_cache_dir, get_cache_path, is_cache_valid)
#   - Variables from tech-stack-helper.sh: BQ_PROJECT_HTTPARCHIVE, BQ_DATASET_CRAWL,
#     BQ_TABLE_PAGES, BQ_DATASET_WAPPALYZER, BQ_TABLE_TECH_DETECTIONS,
#     BQ_TABLE_TECHNOLOGIES, BQ_TABLE_CATEGORIES, BUILTWITH_API_BASE,
#     DEFAULT_LIMIT, DEFAULT_CLIENT, CACHE_TTL_DAYS
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TECH_STACK_BQ_LIB_LOADED:-}" ]] && return 0
_TECH_STACK_BQ_LIB_LOADED=1

# SCRIPT_DIR fallback — pure-bash dirname, avoids external binary dependency
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# BigQuery Helpers
# =============================================================================

check_bq_available() {
	if ! command -v bq &>/dev/null; then
		print_error "BigQuery CLI (bq) not found. Install: brew install google-cloud-sdk"
		return 1
	fi
	return 0
}

check_gcloud_auth() {
	local project
	project=$(gcloud config get-value project 2>/dev/null || true)
	if [[ -z "$project" ]]; then
		print_error "No GCP project configured. Run: gcloud config set project YOUR_PROJECT"
		print_info "You need a GCP project with BigQuery API enabled (free tier: 1TB/month)"
		return 1
	fi
	return 0
}

get_latest_crawl_date() {
	local cache_file
	cache_file=$(get_cache_path "latest_crawl_date")

	if is_cache_valid "$cache_file" 7; then
		cat "$cache_file"
		return 0
	fi

	local result
	result=$(bq query \
		--nouse_legacy_sql \
		--format=csv \
		--max_rows=1 \
		--quiet \
		"SELECT MAX(date) as latest_date FROM \`${BQ_PROJECT_HTTPARCHIVE}.${BQ_DATASET_CRAWL}.${BQ_TABLE_PAGES}\` WHERE date >= DATE_SUB(CURRENT_DATE(), INTERVAL 6 MONTH)" 2>/dev/null) || {
		print_warning "Could not determine latest crawl date, using fallback"
		date -v-1m +%Y-%m-01 2>/dev/null || date -d "1 month ago" +%Y-%m-01
		return 0
	}

	local latest_date
	latest_date=$(echo "$result" | tail -1 | tr -d '[:space:]')

	if [[ -n "$latest_date" && "$latest_date" != "latest_date" ]]; then
		ensure_cache_dir
		echo "$latest_date" >"$cache_file"
		echo "$latest_date"
	else
		date -v-1m +%Y-%m-01 2>/dev/null || date -d "1 month ago" +%Y-%m-01
	fi

	return 0
}

# Sanitize a string for safe use in BigQuery SQL (strip injection characters)
sanitize_sql_value() {
	local value="$1"
	value="${value//\'/}"
	value="${value//\\/}"
	value="${value//;/}"
	echo "$value"
}

load_builtwith_api_key() {
	if [[ -n "${BUILTWITH_API_KEY:-}" ]]; then
		echo "$BUILTWITH_API_KEY"
		return 0
	fi

	local config_file="$HOME/.config/aidevops/credentials.sh"
	if [[ -f "$config_file" ]]; then
		local key
		key=$(grep -E "^export BUILTWITH_API_KEY=" "$config_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
		if [[ -n "$key" ]]; then
			echo "$key"
			return 0
		fi
	fi

	echo ""
	return 1
}

# =============================================================================
# BigQuery Provider — HTTP Archive crawl.pages
# =============================================================================

# Validate and normalise bq_reverse_lookup parameters (limit, client, crawl_date).
# Outputs three lines: validated_limit, validated_client, resolved_crawl_date.
_bq_reverse_validate_params() {
	local limit="$1"
	local client="$2"
	local crawl_date="$3"

	if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -le 0 ]]; then
		print_warning "Invalid limit '$limit', using default"
		limit="$DEFAULT_LIMIT"
	fi

	case "$client" in
	desktop | mobile) ;;
	*)
		print_warning "Unknown client '$client', using default"
		client="$DEFAULT_CLIENT"
		;;
	esac

	if ! [[ "$crawl_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
		if [[ -n "$crawl_date" ]]; then
			print_warning "Invalid crawl_date format '$crawl_date', fetching latest"
		fi
		crawl_date=$(get_latest_crawl_date)
	fi

	printf '%s\n%s\n%s\n' "$limit" "$client" "$crawl_date"
	return 0
}

# Build SQL WHERE clauses for rank and keyword filters.
# Outputs two lines: rank_clause, keyword_clause (may be empty).
_bq_reverse_build_clauses() {
	local rank_filter="$1"
	local keywords="$2"

	local rank_clause=""
	if [[ -n "$rank_filter" ]]; then
		case "$rank_filter" in
		top1k | 1k) rank_clause="AND rank <= 1000" ;;
		top10k | 10k) rank_clause="AND rank <= 10000" ;;
		top100k | 100k) rank_clause="AND rank <= 100000" ;;
		top1m | 1m) rank_clause="AND rank <= 1000000" ;;
		*)
			if [[ "$rank_filter" =~ ^[0-9]+$ ]]; then
				rank_clause="AND rank <= ${rank_filter}"
			else
				print_warning "Unknown traffic tier: $rank_filter (ignoring)"
			fi
			;;
		esac
	fi

	local keyword_clause=""
	if [[ -n "$keywords" ]]; then
		local kw_conditions=""
		local IFS=','
		for kw in $keywords; do
			kw="${kw#"${kw%%[![:space:]]*}"}"
			kw="${kw%"${kw##*[![:space:]]}"}"
			kw=$(sanitize_sql_value "$kw")
			kw="${kw//%/\\%}"
			kw="${kw//_/\\_}"
			if [[ -z "$kw" ]]; then
				continue
			fi
			if [[ -n "$kw_conditions" ]]; then
				kw_conditions="${kw_conditions} OR "
			fi
			kw_conditions="${kw_conditions}LOWER(page) LIKE '%${kw}%' ESCAPE '\\\\'"
		done
		if [[ -n "$kw_conditions" ]]; then
			keyword_clause="AND (${kw_conditions})"
		fi
	fi

	printf '%s\n%s\n' "$rank_clause" "$keyword_clause"
	return 0
}

bq_reverse_lookup() {
	local raw_tech="$1"
	local technology
	technology=$(sanitize_sql_value "$raw_tech")
	local limit="${2:-$DEFAULT_LIMIT}"
	local client="${3:-$DEFAULT_CLIENT}"
	local rank_filter="${4:-}"
	local keywords="${5:-}"
	local crawl_date="${6:-}"
	local format="${7:-json}"

	# Validate and normalise parameters
	local validated
	validated=$(_bq_reverse_validate_params "$limit" "$client" "$crawl_date")
	limit=$(printf '%s\n' "$validated" | sed -n '1p')
	client=$(printf '%s\n' "$validated" | sed -n '2p')
	crawl_date=$(printf '%s\n' "$validated" | sed -n '3p')

	local cache_key="reverse_bq_${technology}_${client}_${rank_filter}_${keywords}_${crawl_date}_${limit}"
	local cache_file
	cache_file=$(get_cache_path "$cache_key")

	if is_cache_valid "$cache_file"; then
		print_info "Using cached results (age < ${CACHE_TTL_DAYS}d)"
		format_output "$cache_file" "$format"
		return 0
	fi

	print_info "Querying HTTP Archive via BigQuery..."
	print_info "Technology: $technology | Date: $crawl_date | Client: $client | Limit: $limit"

	# Build SQL clauses
	local clauses
	clauses=$(_bq_reverse_build_clauses "$rank_filter" "$keywords")
	local rank_clause
	rank_clause=$(printf '%s\n' "$clauses" | sed -n '1p')
	local keyword_clause
	keyword_clause=$(printf '%s\n' "$clauses" | sed -n '2p')

	local query
	query=$(
		cat <<EOSQL
SELECT
  page AS url,
  rank,
  t.technology AS tech_name,
  ARRAY_TO_STRING(t.categories, ', ') AS categories,
  ARRAY_TO_STRING(t.info, ', ') AS version_info
FROM \`${BQ_PROJECT_HTTPARCHIVE}.${BQ_DATASET_CRAWL}.${BQ_TABLE_PAGES}\`,
  UNNEST(technologies) AS t
WHERE date = '${crawl_date}'
  AND client = '${client}'
  AND is_root_page = TRUE
  AND LOWER(t.technology) = LOWER('${technology}')
  ${rank_clause}
  ${keyword_clause}
ORDER BY rank ASC NULLS LAST
LIMIT ${limit}
EOSQL
	)

	local result
	result=$(bq query \
		--nouse_legacy_sql \
		--format=prettyjson \
		--max_rows="$limit" \
		--quiet \
		"$query" 2>&1) || {
		print_error "BigQuery query failed: $result"
		return 1
	}

	if [[ -z "$result" || "$result" == "[]" ]]; then
		print_warning "No results found for technology: $technology"
		echo "[]"
		return 0
	fi

	ensure_cache_dir
	echo "$result" >"$cache_file"
	format_output "$cache_file" "$format"
	return 0
}

# =============================================================================
# BigQuery Provider — Wappalyzer tech_detections (aggregated adoption data)
# =============================================================================

bq_tech_detections() {
	local raw_tech="$1"
	local technology
	technology=$(sanitize_sql_value "$raw_tech")
	local limit="${2:-10}"
	local format="${3:-json}"

	# Validate limit is a positive integer
	if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -le 0 ]]; then
		limit=10
	fi

	local cache_key="detections_${technology}_${limit}"
	local cache_file
	cache_file=$(get_cache_path "$cache_key")

	if is_cache_valid "$cache_file"; then
		print_info "Using cached tech detection data"
		format_output "$cache_file" "$format"
		return 0
	fi

	print_info "Querying Wappalyzer tech_detections for: $technology"

	local query
	query=$(
		cat <<EOSQL
SELECT
  date,
  technology,
  total_origins_persisted AS active_sites,
  total_origins_adopted_new AS new_adoptions,
  total_origins_adopted_existing AS existing_adoptions,
  total_origins_deprecated_existing AS deprecations,
  total_origins_deprecated_gone AS sites_gone,
  sample_origins_adopted_existing AS sample_adopters
FROM \`${BQ_PROJECT_HTTPARCHIVE}.${BQ_DATASET_WAPPALYZER}.${BQ_TABLE_TECH_DETECTIONS}\`
WHERE LOWER(technology) = LOWER('${technology}')
ORDER BY date DESC
LIMIT ${limit}
EOSQL
	)

	local result
	result=$(bq query \
		--nouse_legacy_sql \
		--format=prettyjson \
		--max_rows="$limit" \
		--quiet \
		"$query" 2>&1) || {
		print_error "BigQuery query failed: $result"
		return 1
	}

	if [[ -z "$result" || "$result" == "[]" ]]; then
		print_warning "No detection data found for: $technology"
		echo "[]"
		return 0
	fi

	ensure_cache_dir
	echo "$result" >"$cache_file"
	format_output "$cache_file" "$format"
	return 0
}

# =============================================================================
# BigQuery Provider — Categories listing
# =============================================================================

bq_list_categories() {
	local format="${1:-json}"

	local cache_key="categories_list"
	local cache_file
	cache_file=$(get_cache_path "$cache_key")

	if is_cache_valid "$cache_file"; then
		print_info "Using cached categories"
		format_output "$cache_file" "$format"
		return 0
	fi

	print_info "Querying Wappalyzer categories..."

	local query
	query=$(
		cat <<EOSQL
SELECT name, description
FROM \`${BQ_PROJECT_HTTPARCHIVE}.${BQ_DATASET_WAPPALYZER}.${BQ_TABLE_CATEGORIES}\`
ORDER BY name
EOSQL
	)

	local result
	result=$(bq query \
		--nouse_legacy_sql \
		--format=prettyjson \
		--max_rows=500 \
		--quiet \
		"$query" 2>&1) || {
		print_error "BigQuery query failed: $result"
		return 1
	}

	ensure_cache_dir
	echo "$result" >"$cache_file"
	format_output "$cache_file" "$format"
	return 0
}

# =============================================================================
# BigQuery Provider — Technology metadata
# =============================================================================

bq_tech_info() {
	local raw_tech="$1"
	local technology
	technology=$(sanitize_sql_value "$raw_tech")
	local format="${2:-json}"

	local cache_key="tech_info_${technology}"
	local cache_file
	cache_file=$(get_cache_path "$cache_key")

	if is_cache_valid "$cache_file"; then
		format_output "$cache_file" "$format"
		return 0
	fi

	local query
	query=$(
		cat <<EOSQL
SELECT
  name,
  categories,
  website,
  description,
  saas,
  oss
FROM \`${BQ_PROJECT_HTTPARCHIVE}.${BQ_DATASET_WAPPALYZER}.${BQ_TABLE_TECHNOLOGIES}\`
WHERE LOWER(name) = LOWER('${technology}')
EOSQL
	)

	local result
	result=$(bq query \
		--nouse_legacy_sql \
		--format=prettyjson \
		--max_rows=1 \
		--quiet \
		"$query" 2>&1) || {
		print_error "BigQuery query failed: $result"
		return 1
	}

	ensure_cache_dir
	echo "$result" >"$cache_file"
	format_output "$cache_file" "$format"
	return 0
}

# =============================================================================
# BigQuery Provider — Trending technologies
# =============================================================================

bq_trending() {
	local direction="${1:-adopted}"
	local limit="${2:-20}"
	local format="${3:-json}"

	# Validate limit is a positive integer
	if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -le 0 ]]; then
		limit=20
	fi

	# Validate direction (allowlist) — includes aliases growing/declining
	case "$direction" in
	adopted | growing) direction="adopted" ;;
	deprecated | declining) direction="deprecated" ;;
	*)
		print_warning "Unknown direction '$direction', using 'adopted'"
		direction="adopted"
		;;
	esac

	local cache_key="trending_${direction}_${limit}"
	local cache_file
	cache_file=$(get_cache_path "$cache_key")

	if is_cache_valid "$cache_file" 7; then
		print_info "Using cached trending data"
		format_output "$cache_file" "$format"
		return 0
	fi

	print_info "Querying trending ${direction} technologies..."

	local order_col
	case "$direction" in
	adopted) order_col="total_origins_adopted_new" ;;
	deprecated) order_col="total_origins_deprecated_existing" ;;
	esac
	local query
	query=$(
		cat <<EOSQL
SELECT
  technology,
  total_origins_persisted AS active_sites,
  total_origins_adopted_new AS new_adoptions,
  total_origins_deprecated_existing AS deprecations,
  SAFE_DIVIDE(total_origins_adopted_new, GREATEST(total_origins_deprecated_existing, 1)) AS growth_ratio
FROM \`${BQ_PROJECT_HTTPARCHIVE}.${BQ_DATASET_WAPPALYZER}.${BQ_TABLE_TECH_DETECTIONS}\`
WHERE date = (
  SELECT MAX(date)
  FROM \`${BQ_PROJECT_HTTPARCHIVE}.${BQ_DATASET_WAPPALYZER}.${BQ_TABLE_TECH_DETECTIONS}\`
)
  AND total_origins_persisted > 100
ORDER BY ${order_col} DESC
LIMIT ${limit}
EOSQL
	)

	local result
	result=$(bq query \
		--nouse_legacy_sql \
		--format=prettyjson \
		--max_rows="$limit" \
		--quiet \
		"$query" 2>&1) || {
		print_error "BigQuery query failed: $result"
		return 1
	}

	ensure_cache_dir
	echo "$result" >"$cache_file"
	format_output "$cache_file" "$format"
	return 0
}

# =============================================================================
# BuiltWith Fallback Provider
# =============================================================================

builtwith_reverse_lookup() {
	local technology="$1"
	local limit="${2:-$DEFAULT_LIMIT}"
	local format="${3:-json}"

	local api_key
	api_key=$(load_builtwith_api_key)

	if [[ -z "$api_key" ]]; then
		print_warning "No BuiltWith API key configured"
		print_info "Set via: aidevops secret set BUILTWITH_API_KEY"
		print_info "Or add to ~/.config/aidevops/credentials.sh:"
		print_info "  export BUILTWITH_API_KEY=\"your-key\""
		return 1
	fi

	local cache_key="builtwith_reverse_${technology}_${limit}"
	local cache_file
	cache_file=$(get_cache_path "$cache_key")

	if is_cache_valid "$cache_file"; then
		print_info "Using cached BuiltWith results"
		format_output "$cache_file" "$format"
		return 0
	fi

	print_info "Querying BuiltWith API for: $technology"

	local encoded_tech
	encoded_tech=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$technology'))" 2>/dev/null || echo "$technology")

	local result curl_stderr
	curl_stderr=$(mktemp)
	result=$(curl -s -f \
		"${BUILTWITH_API_BASE}/v21/api.json?KEY=${api_key}&TECH=${encoded_tech}&AMOUNT=${limit}" \
		2>"$curl_stderr") || {
		local err_msg
		err_msg=$(cat "$curl_stderr")
		rm -f "$curl_stderr"
		print_error "BuiltWith API request failed${err_msg:+: $err_msg}"
		return 1
	}
	rm -f "$curl_stderr"

	if echo "$result" | jq -e '.Errors' &>/dev/null; then
		local error_msg
		error_msg=$(echo "$result" | jq -r '.Errors[0].Message // "Unknown error"')
		print_error "BuiltWith API error: $error_msg"
		return 1
	fi

	ensure_cache_dir
	echo "$result" >"$cache_file"
	format_output "$cache_file" "$format"
	return 0
}

# =============================================================================
# Output Formatting (file-based, for BigQuery results)
# =============================================================================

format_output() {
	local file="$1"
	local format="${2:-json}"

	case "$format" in
	json)
		if command -v jq &>/dev/null; then
			jq '.' "$file"
		else
			cat "$file"
		fi
		;;
	table)
		if command -v jq &>/dev/null; then
			format_as_table "$file"
		else
			cat "$file"
		fi
		;;
	csv)
		if command -v jq &>/dev/null; then
			format_as_csv "$file"
		else
			cat "$file"
		fi
		;;
	*)
		cat "$file"
		;;
	esac
	return 0
}

format_as_table() {
	local file="$1"

	local keys
	keys=$(jq -r '.[0] // {} | keys[]' "$file" 2>/dev/null)

	if [[ -z "$keys" ]]; then
		print_warning "No data to display or invalid JSON structure"
		return 0
	fi

	# Print header
	local header=""
	while IFS= read -r key; do
		if [[ -n "$header" ]]; then
			header="${header}\t"
		fi
		header="${header}${key}"
	done <<<"$keys"
	echo -e "${CYAN}${header}${NC}"

	# Print separator
	echo -e "${CYAN}$(echo "$header" | sed 's/[^\t]/-/g; s/\t/\t/g')${NC}"

	# Print rows
	jq -r '.[] | [.[]] | @tsv' "$file" 2>/dev/null || cat "$file"
	return 0
}

format_as_csv() {
	local file="$1"

	# Header
	local header_output
	header_output=$(jq -r '.[0] // {} | keys | @csv' "$file" 2>/dev/null)
	if [[ -n "$header_output" ]]; then
		echo "$header_output"
	fi
	# Rows
	local rows_output
	rows_output=$(jq -r '.[] | [.[]] | @csv' "$file" 2>/dev/null)
	if [[ -n "$rows_output" ]]; then
		echo "$rows_output"
	else
		print_warning "Could not format data as CSV or no data available"
	fi
	return 0
}
