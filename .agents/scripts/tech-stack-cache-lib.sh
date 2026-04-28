#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tech Stack Cache Library — SQLite and file-based cache helpers
# =============================================================================
# Cache functions extracted from tech-stack-helper.sh for size reduction.
# Covers two caching layers:
#   1. File-based cache  — lightweight JSON files for BigQuery results
#   2. SQLite cache      — full tech_cache / merged_cache / reverse_cache tables
#
# Usage: source "${SCRIPT_DIR}/tech-stack-cache-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (log_*, print_*)
#   - Variables from tech-stack-helper.sh: CACHE_DB, CACHE_DIR, BQ_CACHE_DIR,
#     TS_DEFAULT_CACHE_TTL, CACHE_TTL_DAYS
#   - Functions from tech-stack-helper.sh: extract_domain, normalize_url
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TECH_STACK_CACHE_LIB_LOADED:-}" ]] && return 0
_TECH_STACK_CACHE_LIB_LOADED=1

# SCRIPT_DIR fallback — pure-bash dirname, avoids external binary dependency
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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
