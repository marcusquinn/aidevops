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

# Technology categories for structured output (referenced by provider helpers)
# shellcheck disable=SC2034 # exported for provider helper scripts
readonly TECH_CATEGORIES="frameworks,cms,analytics,cdn,hosting,bundlers,ui-libs,state-management,styling,languages,databases,monitoring,security,seo,performance"

# =============================================================================
# Logging — thin wrappers over shared print_* (all output to stderr for logging)
# =============================================================================

log_info() {
	print_info "$1" >&2
	return 0
}
log_success() {
	print_success "$1" >&2
	return 0
}
log_warning() {
	print_warning "$1" >&2
	return 0
}
log_error() {
	print_error "$1"
	return 0
} # print_error already writes to stderr

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
# Output Formatting
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
cmd_reverse() {
	local technology="$1"
	local output_format="$2"
	local use_cache="$3"
	local cache_ttl="$4"
	shift 4
	local -a filters=("$@")

	log_info "Reverse lookup for technology: ${technology}"

	# Build filters hash for cache key
	local filters_hash
	filters_hash=$(echo "${technology}|${filters[*]:-}" | shasum -a 256 | cut -d' ' -f1)

	# Check cache
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

	# Check which providers support reverse lookup
	local -a reverse_providers=()
	local provider
	for provider in $PROVIDERS; do
		local script
		script=$(provider_script "$provider")
		local script_path="${SCRIPT_DIR}/${script}"
		if [[ -x "$script_path" ]]; then
			# Check if provider supports reverse command
			if "$script_path" help 2>/dev/null | grep -q "reverse"; then
				reverse_providers+=("$provider")
			fi
		fi
	done

	if [[ ${#reverse_providers[@]} -eq 0 ]]; then
		log_warning "No providers support reverse lookup yet."
		log_info "Reverse lookup will be fully implemented by t1068."

		# Return a placeholder result
		local placeholder
		placeholder=$(jq -n \
			--arg tech "$technology" \
			'{
                technology: $tech,
                scan_time: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
                sites: [],
                total_count: 0,
                note: "Reverse lookup requires provider support (t1068). No providers currently implement this."
            }')

		output_results "$placeholder" "$output_format"
		return 0
	fi

	# Run reverse lookup on available providers
	local tmp_dir
	tmp_dir=$(mktemp -d)
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	local -a result_files=()
	for provider in "${reverse_providers[@]}"; do
		local script
		script=$(provider_script "$provider")
		local script_path="${SCRIPT_DIR}/${script}"
		local result_file="${tmp_dir}/${provider}.json"
		result_files+=("$result_file")

		local result
		result=$(timeout "$TS_DEFAULT_TIMEOUT" "$script_path" reverse "$technology" --json ${filters[@]+"${filters[@]}"} 2>/dev/null) || true
		echo "${result:-{}}" >"$result_file"
	done

	# Merge reverse results
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

	# Cache result
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
    tech-stack-helper.sh report example.com > report.md
    tech-stack-helper.sh cache stats
    tech-stack-helper.sh cache clear expired
    tech-stack-helper.sh cache get example.com
    tech-stack-helper.sh providers

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
		cmd_reverse "$technology" "$output_format" "$use_cache" "$cache_ttl" ${filters[@]+"${filters[@]}"}
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

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
