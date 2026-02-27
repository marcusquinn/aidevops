#!/usr/bin/env bash
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
# File-based cache helpers (for BigQuery results)
# =============================================================================

ensure_cache_dir() {
	mkdir -p "$BQ_CACHE_DIR"
	return 0
}

get_cache_path() {
	local key="$1"
	local safe_key
	safe_key=$(echo "$key" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g')
	echo "${BQ_CACHE_DIR}/${safe_key}.json"
	return 0
}

is_cache_valid() {
	local cache_file="$1"
	local ttl_days="${2:-$CACHE_TTL_DAYS}"

	if [[ ! -f "$cache_file" ]]; then
		return 1
	fi

	local file_age_days
	if [[ "$(uname)" == "Darwin" ]]; then
		local file_mod
		file_mod=$(stat -f %m "$cache_file")
		local now
		now=$(date +%s)
		file_age_days=$(((now - file_mod) / 86400))
	else
		file_age_days=$((($(date +%s) - $(stat -c %Y "$cache_file")) / 86400))
	fi

	if [[ "$file_age_days" -lt "$ttl_days" ]]; then
		return 0
	fi

	return 1
}

# Cache key from provider + command + args
cache_key() {
	local provider="$1"
	local command="$2"
	local args="$3"
	echo "${provider}_${command}_$(echo "$args" | tr -c '[:alnum:]' '_')"
	return 0
}

# =============================================================================
# SQLite Cache
# =============================================================================

# Safe parameterized sqlite3 query helper.
# Usage: sqlite3_param "$db" "SQL with :params" ":param1" "value1" ":param2" "value2" ...
# Uses .param set for safe binding — prevents SQL injection.
sqlite3_param() {
	local db="$1"
	local sql="$2"
	shift 2

	local param_cmds=""
	while [[ $# -ge 2 ]]; do
		local pname="$1"
		local pval="$2"
		shift 2
		# Double-quote values for .param set — sqlite3 handles escaping internally
		param_cmds+=".param set ${pname} \"${pval//\"/\\\"}\""$'\n'
	done

	sqlite3 "$db" <<EOSQL
${param_cmds}
${sql}
EOSQL
	return $?
}

init_cache_db() {
	mkdir -p "$CACHE_DIR" 2>/dev/null || true

	log_stderr "cache init" sqlite3 "$CACHE_DB" "
        PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=5000;

        CREATE TABLE IF NOT EXISTS tech_cache (
            url           TEXT NOT NULL,
            domain        TEXT NOT NULL,
            provider      TEXT NOT NULL,
            results_json  TEXT NOT NULL,
            detected_at   TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            expires_at    TEXT NOT NULL,
            PRIMARY KEY (url, provider)
        );

        CREATE TABLE IF NOT EXISTS merged_cache (
            url           TEXT PRIMARY KEY,
            domain        TEXT NOT NULL,
            merged_json   TEXT NOT NULL,
            providers     TEXT NOT NULL,
            detected_at   TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            expires_at    TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS reverse_cache (
            technology    TEXT NOT NULL,
            filters_hash  TEXT NOT NULL,
            results_json  TEXT NOT NULL,
            detected_at   TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            expires_at    TEXT NOT NULL,
            PRIMARY KEY (technology, filters_hash)
        );

        CREATE INDEX IF NOT EXISTS idx_tech_cache_domain ON tech_cache(domain);
        CREATE INDEX IF NOT EXISTS idx_tech_cache_expires ON tech_cache(expires_at);
        CREATE INDEX IF NOT EXISTS idx_merged_cache_domain ON merged_cache(domain);
        CREATE INDEX IF NOT EXISTS idx_reverse_cache_tech ON reverse_cache(technology);
    " 2>/dev/null || {
		log_warning "Failed to initialize cache database"
		return 1
	}

	return 0
}

# Store provider results in cache
cache_store() {
	local url="$1"
	local provider="$2"
	local results_json="$3"
	local ttl_hours="${4:-$TS_DEFAULT_CACHE_TTL}"

	local domain
	domain=$(extract_domain "$url")

	log_stderr "cache store" sqlite3_param "$CACHE_DB" \
		"INSERT OR REPLACE INTO tech_cache (url, domain, provider, results_json, expires_at)
		VALUES (:url, :domain, :provider, :json,
			strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+' || :ttl || ' hours'));" \
		":url" "$url" \
		":domain" "$domain" \
		":provider" "$provider" \
		":json" "$results_json" \
		":ttl" "$ttl_hours" \
		2>/dev/null || true

	return 0
}

# Store merged results in cache
cache_store_merged() {
	local url="$1"
	local merged_json="$2"
	local providers="$3"
	local ttl_hours="${4:-$TS_DEFAULT_CACHE_TTL}"

	local domain
	domain=$(extract_domain "$url")

	log_stderr "cache store merged" sqlite3_param "$CACHE_DB" \
		"INSERT OR REPLACE INTO merged_cache (url, domain, merged_json, providers, expires_at)
		VALUES (:url, :domain, :json, :providers,
			strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+' || :ttl || ' hours'));" \
		":url" "$url" \
		":domain" "$domain" \
		":json" "$merged_json" \
		":providers" "$providers" \
		":ttl" "$ttl_hours" \
		2>/dev/null || true

	return 0
}

# Retrieve cached merged results (returns empty if expired)
cache_get_merged() {
	local url="$1"

	[[ ! -f "$CACHE_DB" ]] && return 1

	local result
	result=$(sqlite3_param "$CACHE_DB" \
		"SELECT merged_json FROM merged_cache
		WHERE url = :url
		  AND expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now');" \
		":url" "$url" \
		2>/dev/null || echo "")

	if [[ -n "$result" ]]; then
		echo "$result"
		return 0
	fi

	return 1
}

# Retrieve cached provider results
cache_get_provider() {
	local url="$1"
	local provider="$2"

	[[ ! -f "$CACHE_DB" ]] && return 1

	local result
	result=$(sqlite3_param "$CACHE_DB" \
		"SELECT results_json FROM tech_cache
		WHERE url = :url
		  AND provider = :provider
		  AND expires_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now');" \
		":url" "$url" \
		":provider" "$provider" \
		2>/dev/null || echo "")

	if [[ -n "$result" ]]; then
		echo "$result"
		return 0
	fi

	return 1
}

# Cache statistics
cache_stats() {
	if [[ ! -f "$CACHE_DB" ]]; then
		log_info "No cache database found"
		return 0
	fi

	echo -e "${CYAN}=== Tech Stack Cache Statistics ===${NC}"
	echo ""

	# Single query to gather all statistics efficiently
	local stats_output
	stats_output=$(sqlite3 -separator '|' "$CACHE_DB" "
		SELECT
			(SELECT count(*) FROM tech_cache),
			(SELECT count(*) FROM tech_cache WHERE expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			(SELECT count(*) FROM merged_cache),
			(SELECT count(*) FROM merged_cache WHERE expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
			(SELECT count(*) FROM reverse_cache),
			(SELECT count(*) FROM reverse_cache WHERE expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
	" 2>/dev/null || echo "0|0|0|0|0|0")

	local total_lookups expired_lookups active_lookups
	local total_merged expired_merged active_merged
	local total_reverse expired_reverse active_reverse
	IFS='|' read -r total_lookups expired_lookups total_merged expired_merged total_reverse expired_reverse <<<"$stats_output"
	active_lookups=$((total_lookups - expired_lookups))
	active_merged=$((total_merged - expired_merged))
	active_reverse=$((total_reverse - expired_reverse))

	echo "Provider lookups:  ${active_lookups} active / ${expired_lookups} expired / ${total_lookups} total"
	echo "Merged results:    ${active_merged} active / ${expired_merged} expired / ${total_merged} total"
	echo "Reverse lookups:   ${active_reverse} active / ${expired_reverse} expired / ${total_reverse} total"
	echo ""

	# Show recent lookups
	local recent
	recent=$(sqlite3 -separator ' | ' "$CACHE_DB" "
        SELECT domain, providers, detected_at
        FROM merged_cache
        ORDER BY detected_at DESC
        LIMIT 5;
    " 2>/dev/null || echo "")

	if [[ -n "$recent" ]]; then
		echo "Recent lookups:"
		echo "$recent" | while IFS= read -r line; do
			echo "  $line"
		done
	fi

	# DB file size
	local db_size
	db_size=$(du -h "$CACHE_DB" 2>/dev/null | cut -f1 || echo "unknown")
	echo ""
	echo "Cache DB size: ${db_size}"
	echo "Cache location: ${CACHE_DB}"

	return 0
}

# Clear cache (all or expired only)
cache_clear() {
	local mode="${1:-expired}"

	if [[ ! -f "$CACHE_DB" ]]; then
		log_info "No cache database to clear"
		return 0
	fi

	case "$mode" in
	all)
		sqlite3 "$CACHE_DB" "
                DELETE FROM tech_cache;
                DELETE FROM merged_cache;
                DELETE FROM reverse_cache;
            " 2>/dev/null || true
		log_success "Cache cleared (all entries)"
		;;
	expired)
		local now_clause="strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
		sqlite3 "$CACHE_DB" "
                DELETE FROM tech_cache WHERE expires_at <= ${now_clause};
                DELETE FROM merged_cache WHERE expires_at <= ${now_clause};
                DELETE FROM reverse_cache WHERE expires_at <= ${now_clause};
            " 2>/dev/null || true
		log_success "Cache cleared (expired entries only)"
		;;
	*)
		log_error "Unknown cache clear mode: ${mode}. Use 'all' or 'expired'"
		return 1
		;;
	esac

	# Vacuum to reclaim space
	sqlite3 "$CACHE_DB" "VACUUM;" 2>/dev/null || true

	return 0
}

# Get cached result for a specific URL
cache_get() {
	local url="$1"

	url=$(normalize_url "$url")

	if [[ ! -f "$CACHE_DB" ]]; then
		log_error "No cache database found"
		return 1
	fi

	local result
	result=$(cache_get_merged "$url") || {
		log_info "No cached results for: ${url}"
		return 1
	}

	echo "$result"
	return 0
}

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

bq_reverse_lookup() {
	local technology
	technology=$(sanitize_sql_value "$1")
	local limit="${2:-$DEFAULT_LIMIT}"
	local client="${3:-$DEFAULT_CLIENT}"
	local rank_filter="${4:-}"
	local keywords="${5:-}"
	local crawl_date="${6:-}"
	local format="${7:-json}"

	if [[ -z "$crawl_date" ]]; then
		crawl_date=$(get_latest_crawl_date)
	fi

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
			kw=$(echo "$kw" | xargs)
			# Sanitize: strip single quotes and backslashes to prevent SQL injection
			kw="${kw//\'/}"
			kw="${kw//\\/}"
			if [[ -z "$kw" ]]; then
				continue
			fi
			if [[ -n "$kw_conditions" ]]; then
				kw_conditions="${kw_conditions} OR "
			fi
			kw_conditions="${kw_conditions}LOWER(page) LIKE '%${kw}%'"
		done
		keyword_clause="AND (${kw_conditions})"
	fi

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
	local technology
	technology=$(sanitize_sql_value "$1")
	local limit="${2:-10}"
	local format="${3:-json}"

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
	local technology
	technology=$(sanitize_sql_value "$1")
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
	adopted | growing) order_col="total_origins_adopted_new" ;;
	deprecated | declining) order_col="total_origins_deprecated_existing" ;;
	*) order_col="total_origins_adopted_new" ;;
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

# Merge results from multiple providers into a unified report
# Strategy: union of all detected technologies, with confidence scores
# based on how many providers detected each technology
merge_results() {
	local url="$1"
	shift
	# Remaining args are provider:json pairs passed via temp files
	local -a result_files=("$@")

	local domain
	domain=$(extract_domain "$url")

	# Collect all provider results into a JSON array
	local combined="["
	local first=true
	local providers_list=""
	local file

	for file in "${result_files[@]}"; do
		if [[ -f "$file" ]]; then
			local content
			content=$(cat "$file")

			# Skip error results
			if echo "$content" | jq -e '.error' &>/dev/null; then
				continue
			fi

			if [[ "$first" == "true" ]]; then
				first=false
			else
				combined+=","
			fi
			combined+="$content"

			# Track provider names
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

	# If no valid results, return empty
	if [[ "$first" == "true" ]]; then
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
		return 1
	fi

	# Use jq to merge — simpler approach that handles the actual provider output format
	echo "$combined" | jq \
		--arg url "$url" \
		--arg domain "$domain" \
		--arg providers "$providers_list" \
		'
        ($providers | split(",")) as $prov_list |

        # Flatten all technologies from all providers
        [.[] | (.provider // "unknown") as $prov |
            (.technologies // [])[] |
            . + {detected_by: $prov}
        ] |

        # Group by lowercase name
        group_by(.name | ascii_downcase) |

        # Merge each group
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

	# Check cache first
	if [[ "$use_cache" == "true" ]]; then
		local cached
		if cached=$(cache_get_merged "$url"); then
			log_success "Cache hit for ${url}"
			output_results "$cached" "$output_format"
			return 0
		fi
	fi

	# Determine which providers to use
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

	# Create temp directory for provider results
	local tmp_dir
	tmp_dir=$(mktemp -d)
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	# Run providers
	local -a result_files=()
	local -a pids=()

	if [[ "$run_parallel" == "true" && ${#providers_to_run[@]} -gt 1 ]]; then
		# Parallel execution
		local provider
		for provider in "${providers_to_run[@]}"; do
			local result_file="${tmp_dir}/${provider}.json"
			result_files+=("$result_file")

			# Check provider cache first
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

				# Cache individual provider result
				if echo "$result" | jq -e '.error' &>/dev/null; then
					: # Don't cache errors
				else
					cache_store "$url" "$provider" "$result" "$cache_ttl"
				fi
			) &
			pids+=($!)
		done

		# Wait for all providers
		local pid
		for pid in "${pids[@]}"; do
			wait "$pid" 2>/dev/null || true
		done
	else
		# Sequential execution
		local provider
		for provider in "${providers_to_run[@]}"; do
			local result_file="${tmp_dir}/${provider}.json"
			result_files+=("$result_file")

			# Check provider cache first
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

			# Cache individual provider result
			if echo "$result" | jq -e '.error' &>/dev/null; then
				: # Don't cache errors
			else
				cache_store "$url" "$provider" "$result" "$cache_ttl"
			fi
		done
	fi

	# Merge results
	local merged
	merged=$(merge_results "$url" "${result_files[@]}") || {
		log_error "Failed to merge results"
		return 1
	}

	# Cache merged result
	if [[ "$use_cache" == "true" ]]; then
		local providers_str
		providers_str=$(echo "$merged" | jq -r '.providers | join(",")' 2>/dev/null || echo "")
		cache_store_merged "$url" "$merged" "$providers_str" "$cache_ttl"
	fi

	# Output
	output_results "$merged" "$output_format"

	return 0
}

# Reverse lookup: find sites using a technology
# Supports both multi-provider orchestration (provider helpers) and BigQuery/BuiltWith direct
cmd_reverse() {
	local technology=""
	local limit="$DEFAULT_LIMIT"
	local client="$DEFAULT_CLIENT"
	local traffic=""
	local keywords=""
	local region=""
	local industry=""
	local format="json"
	local provider="auto"
	local crawl_date=""
	local output_format="table"
	local use_cache="true"
	local cache_ttl="$TS_DEFAULT_CACHE_TTL"
	local -a filters=()

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
			return 0
			;;
		-*)
			print_error "Unknown option: $1"
			usage_reverse
			return 1
			;;
		*)
			if [[ -z "$technology" ]]; then
				technology="$1"
			else
				filters+=("$1")
			fi
			shift
			;;
		esac
	done

	if [[ -z "$technology" ]]; then
		print_error "Technology name is required"
		usage_reverse
		return 1
	fi

	if [[ "$limit" -gt "$MAX_LIMIT" ]]; then
		print_warning "Limit capped at $MAX_LIMIT (requested: $limit)"
		limit="$MAX_LIMIT"
	fi

	# Region/industry filtering via keywords (HTTP Archive doesn't have structured region data)
	if [[ -n "$region" ]]; then
		local region_tld
		region_tld=$(region_to_tld "$region")
		if [[ -n "$region_tld" ]]; then
			if [[ -n "$keywords" ]]; then
				keywords="${keywords},${region_tld}"
			else
				keywords="$region_tld"
			fi
			print_info "Filtering by region: $region (TLD: $region_tld)"
		else
			print_warning "Unknown region '$region' — region filter ignored"
		fi
	fi

	if [[ -n "$industry" ]]; then
		if [[ -n "$keywords" ]]; then
			keywords="${keywords},${industry}"
		else
			keywords="$industry"
		fi
		print_info "Filtering by industry keyword: $industry"
	fi

	# Check if provider helpers support reverse lookup
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

	# If provider helpers support reverse, use them; otherwise fall back to BigQuery/BuiltWith
	if [[ ${#reverse_providers[@]} -gt 0 && "$provider" == "auto" ]]; then
		log_info "Reverse lookup for technology: ${technology}"

		# Build filters hash for SQLite cache key
		local filters_hash
		filters_hash=$(echo "${technology}|${filters[*]:-}" | shasum -a 256 | cut -d' ' -f1)

		# Check SQLite cache
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
		for p in "${reverse_providers[@]}"; do
			local script
			script=$(provider_script "$p")
			local script_path="${SCRIPT_DIR}/${script}"
			local result_file="${tmp_dir}/${p}.json"
			result_files+=("$result_file")

			local result
			result=$(timeout "$TS_DEFAULT_TIMEOUT" "$script_path" reverse "$technology" --json ${filters[@]+"${filters[@]}"} 2>/dev/null) || true
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
	fi

	# BigQuery / BuiltWith path
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

main() {
	local command="${1:-help}"
	shift || true

	# Parse global options
	local output_format="table"
	local use_cache="true"
	local specific_provider=""
	local run_parallel="true"
	local timeout_secs="$TS_DEFAULT_TIMEOUT"
	local cache_ttl="$TS_DEFAULT_CACHE_TTL"
	local -a positional=()

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
			return 0
			;;
		*)
			positional+=("$1")
			shift
			;;
		esac
	done

	# Check dependencies
	check_dependencies || return 1

	# Initialize cache
	init_cache_db || true

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
		# Pass remaining positional args as filters
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
		stats)
			cache_stats
			;;
		clear)
			local mode="${positional[1]:-expired}"
			cache_clear "$mode"
			;;
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
	providers)
		list_providers
		;;
	categories)
		cmd_categories ${positional[@]+"${positional[@]}"}
		;;
	trending)
		cmd_trending ${positional[@]+"${positional[@]}"}
		;;
	info)
		local technology="${positional[0]:-}"
		if [[ -z "$technology" ]]; then
			log_error "Technology name is required. Usage: tech-stack-helper.sh info <technology>"
			return 1
		fi
		cmd_info "$technology" "${positional[@]:1}"
		;;
	help | -h | --help)
		print_usage
		;;
	version)
		echo "tech-stack-helper.sh v${VERSION}"
		;;
	*)
		log_error "Unknown command: ${command}"
		print_usage
		return 1
		;;
	esac

	return 0
}

main "$@"
