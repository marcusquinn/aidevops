#!/usr/bin/env bash
# =============================================================================
# Tech Stack Helper - Technology discovery orchestrator
# =============================================================================
# Multi-provider orchestrator for detecting website tech stacks and finding
# sites using specific technologies. Calls provider helpers in parallel,
# merges/deduplicates results, and caches everything in SQLite.
#
# Usage:
#   tech-stack-helper.sh lookup <url> [options]     # Detect tech stack of a URL
#   tech-stack-helper.sh reverse <tech> [options]    # Find sites using a technology
#   tech-stack-helper.sh report <url> [options]      # Generate detailed report
#   tech-stack-helper.sh cache <subcommand>          # Manage result cache
#   tech-stack-helper.sh help                        # Show usage
#
# Providers (called in parallel):
#   - unbuilt-helper.sh   (t1064) - Frontend/JS specialist
#   - crft-helper.sh      (t1065) - 2500+ fingerprints + Lighthouse
#   - openexplorer-helper.sh (t1066) - Open-source discovery
#   - wappalyzer-helper.sh   (t1067) - Self-hosted fallback
#
# Cache: SQLite at ~/.aidevops/.agent-workspace/tech-stacks/cache.db
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly CACHE_DIR="${HOME}/.aidevops/.agent-workspace/tech-stacks"
readonly CACHE_DB="${CACHE_DIR}/cache.db"
readonly DEFAULT_TTL=604800  # 7 days in seconds
readonly REVERSE_TTL=2592000 # 30 days for reverse lookups
readonly PROVIDER_TIMEOUT=30 # seconds per provider
readonly MAX_PARALLEL_PROVIDERS=4

# Provider helper scripts (created by t1064-t1067)
readonly PROVIDER_UNBUILT="${SCRIPT_DIR}/unbuilt-helper.sh"
readonly PROVIDER_CRFT="${SCRIPT_DIR}/crft-helper.sh"
readonly PROVIDER_OPENEXPLORER="${SCRIPT_DIR}/openexplorer-helper.sh"
readonly PROVIDER_WAPPALYZER="${SCRIPT_DIR}/wappalyzer-helper.sh"

# All providers in dispatch order
readonly -a ALL_PROVIDERS=(unbuilt crft openexplorer wappalyzer)

# =============================================================================
# Logging
# =============================================================================

log_info() {
	echo -e "${BLUE}[INFO]${NC} $*"
	return 0
}
log_ok() {
	echo -e "${GREEN}[OK]${NC} $*"
	return 0
}
log_warn() {
	echo -e "${YELLOW}[WARN]${NC} $*"
	return 0
}
log_error() {
	echo -e "${RED}[ERROR]${NC} $*" >&2
	return 0
}
log_debug() {
	[[ "${DEBUG:-}" == "1" ]] && echo -e "${PURPLE}[DEBUG]${NC} $*" >&2
	return 0
}

# =============================================================================
# SQLite Cache Management
# =============================================================================

#######################################
# Initialize the cache database
#######################################
init_cache_db() {
	mkdir -p "$CACHE_DIR" 2>/dev/null || true

	if [[ ! -f "$CACHE_DB" ]]; then
		log_info "Creating tech stack cache at ${CACHE_DB}"
	fi

	log_stderr "init_cache_db" sqlite3 "$CACHE_DB" <<'SQL'
-- Forward lookup cache (URL -> technologies)
CREATE TABLE IF NOT EXISTS tech_stacks (
    url TEXT PRIMARY KEY,
    technologies TEXT NOT NULL,
    providers TEXT NOT NULL,
    lighthouse TEXT DEFAULT '{}',
    timestamp INTEGER NOT NULL,
    ttl INTEGER DEFAULT 604800
);

-- Reverse lookup cache (technology -> sites)
CREATE TABLE IF NOT EXISTS reverse_lookups (
    technology TEXT NOT NULL,
    filters TEXT NOT NULL DEFAULT '{}',
    results TEXT NOT NULL,
    source TEXT DEFAULT 'httparchive',
    timestamp INTEGER NOT NULL,
    ttl INTEGER DEFAULT 2592000,
    PRIMARY KEY (technology, filters)
);

-- Provider health tracking
CREATE TABLE IF NOT EXISTS provider_health (
    provider TEXT PRIMARY KEY,
    last_success INTEGER,
    last_failure INTEGER,
    consecutive_failures INTEGER DEFAULT 0,
    avg_response_ms INTEGER DEFAULT 0,
    total_calls INTEGER DEFAULT 0
);

-- Index for TTL-based expiry queries
CREATE INDEX IF NOT EXISTS idx_tech_stacks_ts ON tech_stacks(timestamp);
CREATE INDEX IF NOT EXISTS idx_reverse_ts ON reverse_lookups(timestamp);
SQL

	return 0
}

#######################################
# Check cache for a URL (forward lookup)
# Arguments:
#   $1 - URL to check
#   $2 - TTL override (optional, default: DEFAULT_TTL)
# Output: JSON result on stdout if cache hit
# Returns: 0 if cache hit, 1 if miss/expired
#######################################
cache_get() {
	local url="$1"
	local ttl="${2:-$DEFAULT_TTL}"
	local now
	now=$(date +%s)

	[[ ! -f "$CACHE_DB" ]] && return 1

	local result
	result=$(sqlite3 "$CACHE_DB" "
        SELECT json_object(
            'url', url,
            'technologies', json(technologies),
            'providers', json(providers),
            'lighthouse', json(lighthouse),
            'timestamp', timestamp,
            'cache_hit', json('true'),
            'cache_age', ($now - timestamp)
        )
        FROM tech_stacks
        WHERE url = '$(sql_escape "$url")'
          AND ($now - timestamp) < $ttl;
    " 2>/dev/null) || true

	if [[ -n "$result" ]]; then
		echo "$result"
		return 0
	fi

	return 1
}

#######################################
# Store result in cache (forward lookup)
# Arguments:
#   $1 - URL
#   $2 - technologies JSON array
#   $3 - providers JSON array
#   $4 - lighthouse JSON object (optional)
#   $5 - TTL override (optional)
#######################################
cache_set() {
	local url="$1"
	local technologies="$2"
	local providers="$3"
	local lighthouse="${4:-\{\}}"
	local ttl="${5:-$DEFAULT_TTL}"
	local now
	now=$(date +%s)

	init_cache_db

	log_stderr "cache_set" sqlite3 "$CACHE_DB" "
        INSERT OR REPLACE INTO tech_stacks (url, technologies, providers, lighthouse, timestamp, ttl)
        VALUES (
            '$(sql_escape "$url")',
            '$(sql_escape "$technologies")',
            '$(sql_escape "$providers")',
            '$(sql_escape "$lighthouse")',
            $now,
            $ttl
        );
    "

	return 0
}

#######################################
# Check cache for reverse lookup
# Arguments:
#   $1 - technology name
#   $2 - filters JSON (optional)
# Output: JSON result on stdout if cache hit
# Returns: 0 if cache hit, 1 if miss/expired
#######################################
cache_get_reverse() {
	local technology="$1"
	local filters="${2:-\{\}}"
	local now
	now=$(date +%s)

	[[ ! -f "$CACHE_DB" ]] && return 1

	local result
	result=$(sqlite3 "$CACHE_DB" "
        SELECT results
        FROM reverse_lookups
        WHERE technology = '$(sql_escape "$technology")'
          AND filters = '$(sql_escape "$filters")'
          AND ($now - timestamp) < ttl;
    " 2>/dev/null) || true

	if [[ -n "$result" ]]; then
		echo "$result"
		return 0
	fi

	return 1
}

#######################################
# Store reverse lookup result in cache
# Arguments:
#   $1 - technology name
#   $2 - results JSON
#   $3 - filters JSON (optional)
#   $4 - source (optional)
#######################################
cache_set_reverse() {
	local technology="$1"
	local results="$2"
	local filters="${3:-\{\}}"
	local source="${4:-httparchive}"
	local now
	now=$(date +%s)

	init_cache_db

	log_stderr "cache_set_reverse" sqlite3 "$CACHE_DB" "
        INSERT OR REPLACE INTO reverse_lookups (technology, filters, results, source, timestamp, ttl)
        VALUES (
            '$(sql_escape "$technology")',
            '$(sql_escape "$filters")',
            '$(sql_escape "$results")',
            '$(sql_escape "$source")',
            $now,
            $REVERSE_TTL
        );
    "

	return 0
}

#######################################
# SQL-escape a string (double single quotes)
# Arguments:
#   $1 - string to escape
#######################################
sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

# =============================================================================
# Provider Dispatch
# =============================================================================

#######################################
# Get the helper script path for a provider
# Arguments:
#   $1 - provider name (unbuilt, crft, openexplorer, wappalyzer)
# Output: path to helper script
# Returns: 0 if exists and executable, 1 otherwise
#######################################
get_provider_script() {
	local provider="$1"
	local script_path

	case "$provider" in
	unbuilt) script_path="$PROVIDER_UNBUILT" ;;
	crft) script_path="$PROVIDER_CRFT" ;;
	openexplorer) script_path="$PROVIDER_OPENEXPLORER" ;;
	wappalyzer) script_path="$PROVIDER_WAPPALYZER" ;;
	*)
		log_error "Unknown provider: $provider"
		return 1
		;;
	esac

	if [[ -x "$script_path" ]]; then
		echo "$script_path"
		return 0
	fi

	log_debug "Provider not available: $provider (${script_path} not found or not executable)"
	return 1
}

#######################################
# List available providers
# Output: space-separated list of available provider names
#######################################
list_available_providers() {
	local -a available=()
	local provider

	for provider in "${ALL_PROVIDERS[@]}"; do
		if get_provider_script "$provider" >/dev/null 2>&1; then
			available+=("$provider")
		fi
	done

	echo "${available[*]}"
	return 0
}

#######################################
# Dispatch a single provider for URL lookup
# Arguments:
#   $1 - provider name
#   $2 - URL to look up
#   $3 - output file for results
# Returns: 0 on success, 1 on failure/timeout
#######################################
dispatch_provider() {
	local provider="$1"
	local url="$2"
	local output_file="$3"

	local script_path
	script_path=$(get_provider_script "$provider") || return 1

	local start_ms
	start_ms=$(date +%s%3N 2>/dev/null || date +%s)

	# Run provider with timeout, capture JSON output
	if timeout "$PROVIDER_TIMEOUT" "$script_path" lookup "$url" --format json >"$output_file" 2>/dev/null; then
		local end_ms
		end_ms=$(date +%s%3N 2>/dev/null || date +%s)
		local duration_ms=$((end_ms - start_ms))

		# Update provider health
		update_provider_health "$provider" "success" "$duration_ms"
		log_debug "Provider $provider completed in ${duration_ms}ms"
		return 0
	else
		local end_ms
		end_ms=$(date +%s%3N 2>/dev/null || date +%s)
		local duration_ms=$((end_ms - start_ms))

		update_provider_health "$provider" "failure" "$duration_ms"
		log_debug "Provider $provider failed or timed out after ${duration_ms}ms"
		return 1
	fi
}

#######################################
# Update provider health tracking
# Arguments:
#   $1 - provider name
#   $2 - status (success|failure)
#   $3 - response time in ms
#######################################
update_provider_health() {
	local provider="$1"
	local status="$2"
	local response_ms="$3"
	local now
	now=$(date +%s)

	[[ ! -f "$CACHE_DB" ]] && return 0

	if [[ "$status" == "success" ]]; then
		log_stderr "provider_health" sqlite3 "$CACHE_DB" "
            INSERT INTO provider_health (provider, last_success, consecutive_failures, avg_response_ms, total_calls)
            VALUES ('$(sql_escape "$provider")', $now, 0, $response_ms, 1)
            ON CONFLICT(provider) DO UPDATE SET
                last_success = $now,
                consecutive_failures = 0,
                avg_response_ms = (avg_response_ms * total_calls + $response_ms) / (total_calls + 1),
                total_calls = total_calls + 1;
        " 2>/dev/null || true
	else
		log_stderr "provider_health" sqlite3 "$CACHE_DB" "
            INSERT INTO provider_health (provider, last_failure, consecutive_failures, avg_response_ms, total_calls)
            VALUES ('$(sql_escape "$provider")', $now, 1, $response_ms, 1)
            ON CONFLICT(provider) DO UPDATE SET
                last_failure = $now,
                consecutive_failures = consecutive_failures + 1,
                total_calls = total_calls + 1;
        " 2>/dev/null || true
	fi

	return 0
}

# =============================================================================
# Result Merging
# =============================================================================

#######################################
# Merge results from multiple providers into a unified tech stack
# Arguments:
#   $@ - paths to provider result JSON files
# Output: merged JSON on stdout
#######################################
merge_results() {
	local -a result_files=("$@")

	# Use jq if available for reliable JSON merging
	if ! command -v jq &>/dev/null; then
		log_error "jq is required for result merging. Install with: brew install jq"
		return 1
	fi

	# Build a combined JSON array from all provider results
	local combined="[]"
	local providers_seen="[]"
	local file

	for file in "${result_files[@]}"; do
		[[ ! -s "$file" ]] && continue

		# Validate JSON
		if ! jq empty "$file" 2>/dev/null; then
			log_debug "Skipping invalid JSON from: $file"
			continue
		fi

		# Extract provider name and technologies from each result
		local provider_name
		provider_name=$(jq -r '.provider // "unknown"' "$file" 2>/dev/null) || continue

		providers_seen=$(echo "$providers_seen" | jq --arg p "$provider_name" '. + [$p]')

		# Extract technologies array and tag each with source provider
		local techs
		techs=$(jq --arg p "$provider_name" '
            (.technologies // []) | map(. + {detected_by: [$p]})
        ' "$file" 2>/dev/null) || continue

		combined=$(echo "$combined" | jq --argjson new "$techs" '. + $new')
	done

	# Deduplicate and merge: group by normalized technology name
	local merged
	merged=$(echo "$combined" | jq '
        # Group by lowercase technology name
        group_by(.name | ascii_downcase)
        | map(
            # For each group, merge into a single entry
            {
                name: (map(.name) | sort_by(length) | last),
                category: (map(.category // empty) | first // "unknown"),
                version: (
                    map(.version // empty)
                    | map(select(. != "" and . != null))
                    | sort_by(length)
                    | last // null
                ),
                confidence: (
                    if length >= 3 then "high"
                    elif length >= 2 then "high"
                    elif (map(.confidence // empty) | first // "medium") == "high" then "high"
                    else "medium"
                    end
                ),
                detected_by: (map(.detected_by[]?) | unique),
                provider_count: (map(.detected_by[]?) | unique | length)
            }
        )
        | sort_by(.provider_count)
        | reverse
    ' 2>/dev/null) || merged="[]"

	# Build final result object
	jq -n \
		--argjson techs "$merged" \
		--argjson providers "$providers_seen" \
		--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
            technologies: $techs,
            providers: ($providers | unique),
            provider_count: ($providers | unique | length),
            technology_count: ($techs | length),
            timestamp: $timestamp,
            cache_hit: false
        }'

	return 0
}

# =============================================================================
# Commands
# =============================================================================

#######################################
# Lookup: detect tech stack of a URL
# Arguments:
#   $1 - URL
#   Flags: --format (table|json|markdown), --provider, --skip, --refresh, --ttl, --timeout
#######################################
cmd_lookup() {
	local url=""
	local format="table"
	local -a include_providers=()
	local -a skip_providers=()
	local refresh=false
	local ttl="$DEFAULT_TTL"
	local timeout_override="$PROVIDER_TIMEOUT"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format)
			format="${2:-table}"
			shift 2
			;;
		--provider)
			IFS=',' read -ra include_providers <<<"${2:-}"
			shift 2
			;;
		--skip)
			IFS=',' read -ra skip_providers <<<"${2:-}"
			shift 2
			;;
		--refresh)
			refresh=true
			shift
			;;
		--ttl)
			ttl="${2:-$DEFAULT_TTL}"
			shift 2
			;;
		--timeout)
			timeout_override="${2:-$PROVIDER_TIMEOUT}"
			shift 2
			;;
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$url" ]]; then
				url="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$url" ]]; then
		log_error "URL is required"
		echo "Usage: tech-stack-helper.sh lookup <url> [--format table|json|markdown] [--provider unbuilt,crft] [--refresh]"
		return 1
	fi

	# Normalize URL (ensure scheme)
	if [[ "$url" != http://* && "$url" != https://* ]]; then
		url="https://${url}"
	fi

	init_cache_db

	# Check cache first (unless --refresh)
	if [[ "$refresh" != true ]]; then
		local cached
		if cached=$(cache_get "$url" "$ttl"); then
			log_debug "Cache hit for $url"
			format_output "$cached" "$format" "$url"
			return 0
		fi
	fi

	# Determine which providers to use
	local -a providers_to_use=()
	if [[ ${#include_providers[@]} -gt 0 ]]; then
		providers_to_use=("${include_providers[@]}")
	else
		for p in "${ALL_PROVIDERS[@]}"; do
			providers_to_use+=("$p")
		done
	fi

	# Remove skipped providers
	if [[ ${#skip_providers[@]} -gt 0 ]]; then
		local -a filtered=()
		local p skip
		for p in "${providers_to_use[@]}"; do
			local should_skip=false
			for skip in "${skip_providers[@]}"; do
				if [[ "$p" == "$skip" ]]; then
					should_skip=true
					break
				fi
			done
			if [[ "$should_skip" != true ]]; then
				filtered+=("$p")
			fi
		done
		providers_to_use=("${filtered[@]}")
	fi

	# Check which providers are actually available
	local -a available_providers=()
	local -a unavailable_providers=()
	local p
	for p in "${providers_to_use[@]}"; do
		if get_provider_script "$p" >/dev/null 2>&1; then
			available_providers+=("$p")
		else
			unavailable_providers+=("$p")
		fi
	done

	if [[ ${#available_providers[@]} -eq 0 ]]; then
		log_warn "No providers available. Provider helpers are created by tasks t1064-t1067."
		log_warn "Unavailable: ${unavailable_providers[*]}"
		echo ""
		echo "To install providers, complete these tasks:"
		echo "  t1064 - unbuilt-helper.sh (Frontend/JS specialist)"
		echo "  t1065 - crft-helper.sh (2500+ fingerprints + Lighthouse)"
		echo "  t1066 - openexplorer-helper.sh (Open-source discovery)"
		echo "  t1067 - wappalyzer-helper.sh (Self-hosted fallback)"
		return 1
	fi

	if [[ ${#unavailable_providers[@]} -gt 0 ]]; then
		log_warn "Some providers unavailable: ${unavailable_providers[*]}"
	fi

	log_info "Looking up tech stack for: $url"
	log_info "Using providers: ${available_providers[*]}"

	# Create temp directory for provider results
	local tmp_dir
	tmp_dir=$(mktemp -d)
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	# Dispatch providers in parallel
	local -a pids=()
	local -a result_files=()
	for p in "${available_providers[@]}"; do
		local result_file="${tmp_dir}/${p}.json"
		result_files+=("$result_file")
		dispatch_provider "$p" "$url" "$result_file" &
		pids+=($!)
	done

	# Wait for all providers to complete
	local -a succeeded=()
	local -a failed=()
	local i
	for i in "${!pids[@]}"; do
		if wait "${pids[$i]}" 2>/dev/null; then
			succeeded+=("${available_providers[$i]}")
		else
			failed+=("${available_providers[$i]}")
		fi
	done

	log_info "Providers completed: ${#succeeded[@]} succeeded, ${#failed[@]} failed"

	if [[ ${#succeeded[@]} -eq 0 ]]; then
		log_error "All providers failed for: $url"
		return 1
	fi

	# Merge results from successful providers
	local -a valid_files=()
	for file in "${result_files[@]}"; do
		if [[ -s "$file" ]]; then
			valid_files+=("$file")
		fi
	done

	local merged
	merged=$(merge_results "${valid_files[@]}") || {
		log_error "Failed to merge provider results"
		return 1
	}

	# Add URL to merged result
	merged=$(echo "$merged" | jq --arg url "$url" '. + {url: $url}')

	# Cache the result
	local technologies providers lighthouse
	technologies=$(echo "$merged" | jq -c '.technologies')
	providers=$(echo "$merged" | jq -c '.providers')
	lighthouse=$(echo "$merged" | jq -c '.lighthouse // {}')
	cache_set "$url" "$technologies" "$providers" "$lighthouse" "$ttl"

	# Format and output
	format_output "$merged" "$format" "$url"

	return 0
}

#######################################
# Reverse lookup: find sites using a technology
# Arguments:
#   $1 - technology name
#   Flags: --region, --industry, --traffic, --limit, --operator, --format
#######################################
cmd_reverse() {
	local technology=""
	local region=""
	local industry=""
	local traffic=""
	local limit=50
	local operator="or"
	local format="table"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--region)
			region="${2:-}"
			shift 2
			;;
		--industry)
			industry="${2:-}"
			shift 2
			;;
		--traffic)
			traffic="${2:-}"
			shift 2
			;;
		--limit)
			limit="${2:-50}"
			shift 2
			;;
		--operator)
			operator="${2:-or}"
			shift 2
			;;
		--format)
			format="${2:-table}"
			shift 2
			;;
		-*)
			log_error "Unknown option: $1"
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
		log_error "Technology name is required"
		echo "Usage: tech-stack-helper.sh reverse <technology> [--region US] [--industry ecommerce] [--limit 50]"
		return 1
	fi

	init_cache_db

	# Build filters JSON for cache key
	local filters
	filters=$(jq -n \
		--arg region "$region" \
		--arg industry "$industry" \
		--arg traffic "$traffic" \
		--arg operator "$operator" \
		--argjson limit "$limit" \
		'{region: $region, industry: $industry, traffic: $traffic, operator: $operator, limit: $limit}' \
		2>/dev/null) || filters="{}"

	# Check cache
	local cached
	if cached=$(cache_get_reverse "$technology" "$filters"); then
		log_debug "Cache hit for reverse lookup: $technology"
		format_reverse_output "$cached" "$format" "$technology"
		return 0
	fi

	log_info "Reverse lookup: finding sites using '$technology'"

	# Dispatch to providers that support reverse lookup
	local -a results=()
	local tmp_dir
	tmp_dir=$(mktemp -d)
	trap 'rm -rf "${tmp_dir:-}"' RETURN

	local -a pids=()
	local -a provider_names=()
	local p
	for p in "${ALL_PROVIDERS[@]}"; do
		local script_path
		script_path=$(get_provider_script "$p") || continue

		local result_file="${tmp_dir}/${p}-reverse.json"
		(
			timeout "$PROVIDER_TIMEOUT" "$script_path" reverse "$technology" \
				--region "$region" \
				--industry "$industry" \
				--traffic "$traffic" \
				--limit "$limit" \
				--format json >"$result_file" 2>/dev/null
		) &
		pids+=($!)
		provider_names+=("$p")
	done

	# Wait for providers
	for i in "${!pids[@]}"; do
		wait "${pids[$i]}" 2>/dev/null || true
	done

	# Merge reverse lookup results
	local merged_sites="[]"
	local file
	for file in "${tmp_dir}"/*-reverse.json; do
		[[ ! -s "$file" ]] && continue
		if jq empty "$file" 2>/dev/null; then
			local sites
			sites=$(jq '.sites // .results // []' "$file" 2>/dev/null) || continue
			merged_sites=$(echo "$merged_sites" | jq --argjson new "$sites" '. + $new')
		fi
	done

	# Deduplicate by URL
	merged_sites=$(echo "$merged_sites" | jq '
        group_by(.url // .domain | ascii_downcase)
        | map(first)
        | sort_by(.traffic_rank // .traffic // 999999)
        | .[:'"$limit"']
    ' 2>/dev/null) || merged_sites="[]"

	local result
	result=$(jq -n \
		--arg tech "$technology" \
		--argjson sites "$merged_sites" \
		--argjson filters "$filters" \
		--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
            technology: $tech,
            filters: $filters,
            sites: $sites,
            total_found: ($sites | length),
            timestamp: $timestamp
        }')

	# Cache the result
	cache_set_reverse "$technology" "$result" "$filters"

	# Format and output
	format_reverse_output "$result" "$format" "$technology"

	return 0
}

#######################################
# Report: generate a detailed tech stack report for a URL
# Arguments:
#   $1 - URL
#   Flags: --format (markdown|json|table)
#######################################
cmd_report() {
	local url=""
	local format="markdown"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format)
			format="${2:-markdown}"
			shift 2
			;;
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$url" ]]; then
				url="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$url" ]]; then
		log_error "URL is required"
		echo "Usage: tech-stack-helper.sh report <url> [--format markdown|json|table]"
		return 1
	fi

	# Normalize URL
	if [[ "$url" != http://* && "$url" != https://* ]]; then
		url="https://${url}"
	fi

	# Run lookup first (reuses cache)
	local result
	result=$(cmd_lookup "$url" --format json 2>/dev/null) || {
		log_error "Failed to get tech stack for: $url"
		return 1
	}

	# Format as report
	case "$format" in
	json)
		echo "$result" | jq '.'
		;;
	markdown)
		format_markdown_report "$result" "$url"
		;;
	table | *)
		format_table_output "$result" "$url"
		;;
	esac

	return 0
}

#######################################
# Cache management subcommands
# Arguments:
#   $1 - subcommand (status|clear|clear-reverse|stats)
#   $2 - optional URL for targeted clear
#######################################
cmd_cache() {
	local subcmd="${1:-status}"
	shift || true

	init_cache_db

	case "$subcmd" in
	status)
		cache_status
		;;
	clear)
		cache_clear "$@"
		;;
	clear-reverse)
		cache_clear_reverse "$@"
		;;
	stats)
		cache_stats
		;;
	reverse-status)
		cache_reverse_status
		;;
	*)
		log_error "Unknown cache subcommand: $subcmd"
		echo "Usage: tech-stack-helper.sh cache [status|clear|clear-reverse|stats|reverse-status]"
		return 1
		;;
	esac

	return 0
}

# =============================================================================
# Cache Subcommands
# =============================================================================

cache_status() {
	local now
	now=$(date +%s)

	local total_entries fresh_entries expired_entries
	total_entries=$(sqlite3 "$CACHE_DB" "SELECT count(*) FROM tech_stacks;" 2>/dev/null || echo "0")
	fresh_entries=$(sqlite3 "$CACHE_DB" "SELECT count(*) FROM tech_stacks WHERE ($now - timestamp) < ttl;" 2>/dev/null || echo "0")
	expired_entries=$((total_entries - fresh_entries))

	local db_size
	if [[ -f "$CACHE_DB" ]]; then
		db_size=$(du -h "$CACHE_DB" 2>/dev/null | cut -f1)
	else
		db_size="0B"
	fi

	echo ""
	echo -e "${WHITE}Tech Stack Cache Status${NC}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo -e "  Database:        ${CACHE_DB}"
	echo -e "  Size:            ${db_size}"
	echo -e "  Total entries:   ${total_entries}"
	echo -e "  Fresh:           ${GREEN}${fresh_entries}${NC}"
	echo -e "  Expired:         ${YELLOW}${expired_entries}${NC}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	return 0
}

cache_clear() {
	local url="${1:-}"

	if [[ -n "$url" && "$url" != "--all" ]]; then
		sqlite3 "$CACHE_DB" "DELETE FROM tech_stacks WHERE url = '$(sql_escape "$url")';" 2>/dev/null
		log_ok "Cleared cache for: $url"
	elif [[ "$url" == "--all" ]]; then
		sqlite3 "$CACHE_DB" "DELETE FROM tech_stacks;" 2>/dev/null
		log_ok "Cleared all forward lookup cache"
	else
		echo "Usage: tech-stack-helper.sh cache clear <url>  OR  cache clear --all"
		return 1
	fi

	return 0
}

cache_clear_reverse() {
	local tech="${1:-}"

	if [[ -n "$tech" && "$tech" != "--all" ]]; then
		sqlite3 "$CACHE_DB" "DELETE FROM reverse_lookups WHERE technology = '$(sql_escape "$tech")';" 2>/dev/null
		log_ok "Cleared reverse cache for: $tech"
	elif [[ "$tech" == "--all" ]]; then
		sqlite3 "$CACHE_DB" "DELETE FROM reverse_lookups;" 2>/dev/null
		log_ok "Cleared all reverse lookup cache"
	else
		sqlite3 "$CACHE_DB" "DELETE FROM reverse_lookups;" 2>/dev/null
		log_ok "Cleared all reverse lookup cache"
	fi

	return 0
}

cache_stats() {
	local now
	now=$(date +%s)

	echo ""
	echo -e "${WHITE}Tech Stack Cache Statistics${NC}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	echo ""
	echo "Forward Lookups:"
	sqlite3 -header -column "$CACHE_DB" "
        SELECT
            url,
            json_array_length(technologies) AS techs,
            json_array_length(providers) AS providers,
            datetime(timestamp, 'unixepoch') AS cached_at,
            CASE WHEN ($now - timestamp) < ttl THEN 'fresh' ELSE 'expired' END AS status
        FROM tech_stacks
        ORDER BY timestamp DESC
        LIMIT 20;
    " 2>/dev/null || echo "  (no entries)"

	echo ""
	echo "Reverse Lookups:"
	sqlite3 -header -column "$CACHE_DB" "
        SELECT
            technology,
            json_array_length(json_extract(results, '$.sites')) AS sites,
            source,
            datetime(timestamp, 'unixepoch') AS cached_at,
            CASE WHEN ($now - timestamp) < ttl THEN 'fresh' ELSE 'expired' END AS status
        FROM reverse_lookups
        ORDER BY timestamp DESC
        LIMIT 20;
    " 2>/dev/null || echo "  (no entries)"

	echo ""
	echo "Provider Health:"
	sqlite3 -header -column "$CACHE_DB" "
        SELECT
            provider,
            total_calls,
            consecutive_failures AS consec_fail,
            avg_response_ms AS avg_ms,
            datetime(last_success, 'unixepoch') AS last_ok,
            datetime(last_failure, 'unixepoch') AS last_fail
        FROM provider_health
        ORDER BY provider;
    " 2>/dev/null || echo "  (no entries)"

	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	return 0
}

cache_reverse_status() {
	local now
	now=$(date +%s)

	local total fresh
	total=$(sqlite3 "$CACHE_DB" "SELECT count(*) FROM reverse_lookups;" 2>/dev/null || echo "0")
	fresh=$(sqlite3 "$CACHE_DB" "SELECT count(*) FROM reverse_lookups WHERE ($now - timestamp) < ttl;" 2>/dev/null || echo "0")

	echo ""
	echo -e "${WHITE}Reverse Lookup Cache${NC}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo -e "  Total entries:   ${total}"
	echo -e "  Fresh:           ${GREEN}${fresh}${NC}"
	echo -e "  Expired:         ${YELLOW}$((total - fresh))${NC}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	return 0
}

# =============================================================================
# Output Formatting
# =============================================================================

#######################################
# Route output to the appropriate formatter
# Arguments:
#   $1 - JSON result
#   $2 - format (table|json|markdown)
#   $3 - URL
#######################################
format_output() {
	local result="$1"
	local format="$2"
	local url="$3"

	case "$format" in
	json)
		echo "$result" | jq '.'
		;;
	markdown)
		format_markdown_report "$result" "$url"
		;;
	table | *)
		format_table_output "$result" "$url"
		;;
	esac

	return 0
}

#######################################
# Format result as terminal table
# Arguments:
#   $1 - JSON result
#   $2 - URL
#######################################
format_table_output() {
	local result="$1"
	local url="$2"

	if ! command -v jq &>/dev/null; then
		echo "$result"
		return 0
	fi

	local cache_hit
	cache_hit=$(echo "$result" | jq -r '.cache_hit // false')
	local cache_age
	cache_age=$(echo "$result" | jq -r '.cache_age // 0')
	local providers
	providers=$(echo "$result" | jq -r '(.providers // []) | join(", ")')
	local provider_count
	provider_count=$(echo "$result" | jq -r '.provider_count // (.providers | length) // 0')

	echo ""
	echo -e "${WHITE}Tech Stack for ${url}${NC}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	printf "%-22s %-22s %-10s %-12s %-10s\n" "Category" "Technology" "Version" "Confidence" "Providers"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	# Extract and format each technology
	echo "$result" | jq -r '
        (.technologies // [])[]
        | [
            (.category // "unknown"),
            (.name // "unknown"),
            (.version // "-"),
            (.confidence // "medium"),
            (.provider_count // (.detected_by | length) // 1 | tostring)
        ]
        | @tsv
    ' 2>/dev/null | while IFS=$'\t' read -r category name version confidence pcount; do
		printf "%-22s %-22s %-10s %-12s %-10s\n" \
			"$category" "$name" "$version" "$confidence" "$pcount"
	done

	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo -e "Detected by: ${providers} (${provider_count}/4 providers)"

	if [[ "$cache_hit" == "true" ]]; then
		local age_human
		age_human=$(format_duration "$cache_age")
		echo -e "Cache: ${GREEN}Fresh${NC} (retrieved ${age_human} ago)"
	else
		echo -e "Cache: ${BLUE}New lookup${NC}"
	fi

	return 0
}

#######################################
# Format result as markdown report
# Arguments:
#   $1 - JSON result
#   $2 - URL
#######################################
format_markdown_report() {
	local result="$1"
	local url="$2"

	if ! command -v jq &>/dev/null; then
		echo "$result"
		return 0
	fi

	local domain
	domain=$(echo "$url" | sed 's|https\?://||;s|/.*||')
	local timestamp
	timestamp=$(echo "$result" | jq -r '.timestamp // "unknown"')
	local providers
	providers=$(echo "$result" | jq -r '(.providers // []) | join(", ")')
	local provider_count
	provider_count=$(echo "$result" | jq -r '.provider_count // (.providers | length) // 0')

	echo "# Tech Stack Report: ${domain}"
	echo ""
	echo "**Generated**: ${timestamp}"
	echo "**Providers**: ${providers} (${provider_count}/4)"
	echo ""

	# Group technologies by category
	echo "$result" | jq -r '
        (.technologies // [])
        | group_by(.category)
        | map({
            category: (.[0].category // "Other"),
            techs: .
        })
        | sort_by(.category)
        | .[]
        | "## \(.category | gsub("-"; " ") | ascii_upcase[:1] + .[1:])\n" +
          (.techs | map(
            "- **\(.name)**" +
            (if .version then " \(.version)" else "" end) +
            " (\(.confidence // "medium") confidence, \(.provider_count // (.detected_by | length) // 1) provider" +
            (if (.provider_count // (.detected_by | length) // 1) > 1 then "s" else "" end) +
            ")"
          ) | join("\n"))
    ' 2>/dev/null || echo "(no technologies detected)"

	return 0
}

#######################################
# Format reverse lookup output
# Arguments:
#   $1 - JSON result
#   $2 - format (table|json|markdown)
#   $3 - technology name
#######################################
format_reverse_output() {
	local result="$1"
	local format="$2"
	local technology="$3"

	case "$format" in
	json)
		echo "$result" | jq '.'
		;;
	markdown)
		format_reverse_markdown "$result" "$technology"
		;;
	table | *)
		format_reverse_table "$result" "$technology"
		;;
	esac

	return 0
}

format_reverse_table() {
	local result="$1"
	local technology="$2"

	if ! command -v jq &>/dev/null; then
		echo "$result"
		return 0
	fi

	local total
	total=$(echo "$result" | jq -r '.total_found // 0')

	echo ""
	echo -e "${WHITE}Sites Using ${technology}${NC}"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	printf "%-35s %-10s %-15s %-10s %-10s\n" "URL" "Region" "Industry" "Traffic" "Version"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	echo "$result" | jq -r '
        (.sites // [])[]
        | [
            (.url // .domain // "unknown"),
            (.region // "-"),
            (.industry // "-"),
            (.traffic // .traffic_tier // "-"),
            (.version // "-")
        ]
        | @tsv
    ' 2>/dev/null | while IFS=$'\t' read -r site_url region industry traffic version; do
		printf "%-35s %-10s %-15s %-10s %-10s\n" \
			"$site_url" "$region" "$industry" "$traffic" "$version"
	done

	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo "Found ${total} sites using ${technology}"

	return 0
}

format_reverse_markdown() {
	local result="$1"
	local technology="$2"

	local total
	total=$(echo "$result" | jq -r '.total_found // 0')
	local timestamp
	timestamp=$(echo "$result" | jq -r '.timestamp // "unknown"')

	echo "# Sites Using ${technology}"
	echo ""
	echo "**Generated**: ${timestamp}"
	echo "**Total Found**: ${total}"
	echo ""
	echo "| URL | Region | Industry | Traffic | Version |"
	echo "|-----|--------|----------|---------|---------|"

	echo "$result" | jq -r '
        (.sites // [])[]
        | "| \(.url // .domain // "unknown") | \(.region // "-") | \(.industry // "-") | \(.traffic // .traffic_tier // "-") | \(.version // "-") |"
    ' 2>/dev/null

	return 0
}

# =============================================================================
# Utility Functions
# =============================================================================

#######################################
# Format seconds into human-readable duration
# Arguments:
#   $1 - seconds
#######################################
format_duration() {
	local seconds="$1"

	if [[ "$seconds" -lt 60 ]]; then
		echo "${seconds} seconds"
	elif [[ "$seconds" -lt 3600 ]]; then
		echo "$((seconds / 60)) minutes"
	elif [[ "$seconds" -lt 86400 ]]; then
		echo "$((seconds / 3600)) hours"
	else
		echo "$((seconds / 86400)) days"
	fi

	return 0
}

# =============================================================================
# Help / Usage
# =============================================================================

show_usage() {
	cat <<'EOF'
Tech Stack Helper - Technology discovery orchestrator

Usage:
    tech-stack-helper.sh <command> [arguments] [options]

Commands:
    lookup <url>              Detect the full tech stack of a URL
    reverse <technology>      Find websites using a specific technology
    report <url>              Generate a detailed tech stack report
    cache <subcommand>        Manage the result cache
    help                      Show this help message

Lookup Options:
    --format <fmt>            Output format: table (default), json, markdown
    --provider <list>         Comma-separated providers to use (e.g., unbuilt,crft)
    --skip <list>             Comma-separated providers to skip
    --refresh                 Bypass cache and fetch fresh results
    --ttl <seconds>           Cache TTL override (default: 604800 = 7 days)
    --timeout <seconds>       Per-provider timeout (default: 30)

Reverse Options:
    --region <region>         Geographic filter (US, EU, APAC, etc.)
    --industry <industry>     Industry vertical (ecommerce, saas, media, etc.)
    --traffic <tier>          Traffic tier (low, medium, high, very-high)
    --limit <n>               Max results (default: 50)
    --operator <op>           For multiple techs: and|or (default: or)
    --format <fmt>            Output format: table (default), json, markdown

Cache Subcommands:
    status                    Show cache status summary
    clear <url>               Clear cache for a specific URL
    clear --all               Clear all forward lookup cache
    clear-reverse [tech]      Clear reverse lookup cache
    reverse-status            Show reverse lookup cache status
    stats                     Show detailed cache statistics

Examples:
    tech-stack-helper.sh lookup https://example.com
    tech-stack-helper.sh lookup https://example.com --format json --provider unbuilt
    tech-stack-helper.sh reverse React --region US --limit 100
    tech-stack-helper.sh reverse "Next.js,Tailwind CSS" --operator and
    tech-stack-helper.sh report https://example.com --format markdown
    tech-stack-helper.sh cache status
    tech-stack-helper.sh cache clear https://example.com

Providers:
    unbuilt       Frontend/JS specialist (bundlers, frameworks, UI libs)
    crft          2500+ fingerprints + Lighthouse scores
    openexplorer  Open-source tech discovery
    wappalyzer    Self-hosted fallback (offline capable)

EOF
	return 0
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	lookup)
		cmd_lookup "$@"
		;;
	reverse)
		cmd_reverse "$@"
		;;
	report)
		cmd_report "$@"
		;;
	cache)
		cmd_cache "$@"
		;;
	help | --help | -h)
		show_usage
		;;
	*)
		log_error "Unknown command: $command"
		show_usage
		return 1
		;;
	esac
}

main "$@"
