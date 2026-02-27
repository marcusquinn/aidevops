#!/usr/bin/env bash
# ip-reputation-helper.sh — IP reputation checker using multiple providers
# Queries multiple IP reputation databases in parallel and merges results
# into a unified risk report. Use case: vet VPS/server/proxy IPs before
# purchase or deployment to check if they are burned (blacklisted, flagged).
#
# Usage:
#   ip-reputation-helper.sh check <ip> [options]
#   ip-reputation-helper.sh batch <file> [options]
#   ip-reputation-helper.sh report <ip> [options]
#   ip-reputation-helper.sh providers
#   ip-reputation-helper.sh cache-stats
#   ip-reputation-helper.sh cache-clear [--provider <p>] [--ip <ip>]
#   ip-reputation-helper.sh rate-limit-status
#   ip-reputation-helper.sh help
#
# Options:
#   --provider <p>    Use only specified provider
#   --timeout <s>     Per-provider timeout in seconds (default: 15)
#   --format <fmt>    Output format: table (default), json, markdown, compact
#   --parallel        Run providers in parallel (default)
#   --sequential      Run providers sequentially
#   --no-color        Disable color output (also respects NO_COLOR env)
#   --no-cache        Bypass cache for this query
#   --rate-limit <n>  Requests per second per provider in batch mode (default: 2)
#   --dnsbl-overlap   Cross-reference results with email-health-check-helper.sh DNSBL
#
# Providers (free/no-key):
#   spamhaus      Spamhaus DNSBL (SBL/XBL/PBL via dig)
#   proxycheck    ProxyCheck.io (proxy/VPN/Tor detection)
#   stopforumspam StopForumSpam (forum spammer database)
#   blocklistde   Blocklist.de (attack/botnet IPs)
#   greynoise     GreyNoise Community API (internet noise scanner)
#
# Providers (free tier with API key):
#   abuseipdb       AbuseIPDB (community abuse reports, 1000/day free)
#   virustotal      VirusTotal (70+ AV engines, 500/day free)
#   ipqualityscore  IPQualityScore (fraud/proxy/VPN detection, 5000/month free)
#   scamalytics     Scamalytics (fraud scoring, 5000/month free)
#   shodan          Shodan (open ports, vulns, tags — free key, limited credits)
#   iphub           IP Hub (proxy/VPN/hosting detection, 1000/day free)
#
# Risk levels: clean → low → medium → high → critical
#
# Environment variables:
#   ABUSEIPDB_API_KEY         AbuseIPDB API key (free at abuseipdb.com)
#   VIRUSTOTAL_API_KEY        VirusTotal API key (free at virustotal.com)
#   PROXYCHECK_API_KEY        ProxyCheck.io API key (optional, increases limit)
#   IPQUALITYSCORE_API_KEY    IPQualityScore API key (free at ipqualityscore.com)
#   SCAMALYTICS_API_KEY       Scamalytics API key (free at scamalytics.com)
#   GREYNOISE_API_KEY         GreyNoise API key (optional, enables full API)
#   SHODAN_API_KEY            Shodan API key (free at shodan.io, limited credits)
#   IPHUB_API_KEY             IP Hub API key (free at iphub.info)
#   IP_REP_TIMEOUT            Default per-provider timeout (default: 15)
#   IP_REP_FORMAT             Default output format (default: table)
#   IP_REP_CACHE_DIR          SQLite cache directory (default: ~/.cache/ip-reputation)
#   IP_REP_CACHE_TTL          Default cache TTL in seconds (default: 86400 = 24h)
#   IP_REP_RATE_LIMIT         Requests per second per provider in batch (default: 2)
#
# Cache TTL per provider (seconds):
#   spamhaus/blocklistde/stopforumspam: 3600  (1h — DNSBL data changes frequently)
#   proxycheck/iphub:                   21600 (6h)
#   abuseipdb/ipqualityscore/virustotal: 86400 (24h)
#   scamalytics/greynoise:              86400 (24h)
#   shodan:                             604800 (7d — scan data changes slowly)
#
# Examples:
#   ip-reputation-helper.sh check 1.2.3.4
#   ip-reputation-helper.sh check 1.2.3.4 --format json
#   ip-reputation-helper.sh check 1.2.3.4 --provider spamhaus
#   ip-reputation-helper.sh check 1.2.3.4 --no-cache
#   ip-reputation-helper.sh batch ips.txt
#   ip-reputation-helper.sh batch ips.txt --rate-limit 1 --dnsbl-overlap
#   ip-reputation-helper.sh report 1.2.3.4
#   ip-reputation-helper.sh providers
#   ip-reputation-helper.sh cache-stats
#   ip-reputation-helper.sh cache-clear --provider abuseipdb

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly PROVIDERS_DIR="${SCRIPT_DIR}/providers"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

# All available providers (order matters for display)
# greynoise has a free community API (no key required) but also supports keyed full API
readonly ALL_PROVIDERS="spamhaus proxycheck stopforumspam blocklistde greynoise abuseipdb virustotal ipqualityscore scamalytics shodan iphub"

# Global color toggle (set by --no-color flag or NO_COLOR env before any output)
# shellcheck disable=SC2034
IP_REP_NO_COLOR="${NO_COLOR:-false}"

# =============================================================================
# SQLite Cache
# =============================================================================

readonly IP_REP_CACHE_DIR="${IP_REP_CACHE_DIR:-${HOME}/.cache/ip-reputation}"
readonly IP_REP_CACHE_DB="${IP_REP_CACHE_DIR}/cache.db"
readonly IP_REP_DEFAULT_CACHE_TTL="${IP_REP_CACHE_TTL:-86400}"

# Per-provider TTL overrides (seconds)
provider_cache_ttl() {
	local provider="$1"
	case "$provider" in
	spamhaus | blocklistde | stopforumspam) echo "3600" ;;
	proxycheck | iphub) echo "21600" ;;
	shodan) echo "604800" ;;
	*) echo "$IP_REP_DEFAULT_CACHE_TTL" ;;
	esac
	return 0
}

# Initialise SQLite cache database (includes rate_limits table for 429 tracking)
cache_init() {
	if ! command -v sqlite3 &>/dev/null; then
		return 0
	fi
	mkdir -p "$IP_REP_CACHE_DIR"
	sqlite3 "$IP_REP_CACHE_DB" <<'SQL' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS ip_cache (
    ip       TEXT NOT NULL,
    provider TEXT NOT NULL,
    result   TEXT NOT NULL,
    cached_at INTEGER NOT NULL,
    ttl      INTEGER NOT NULL,
    PRIMARY KEY (ip, provider)
);
CREATE INDEX IF NOT EXISTS idx_ip_cache_expiry ON ip_cache (cached_at, ttl);
CREATE TABLE IF NOT EXISTS rate_limits (
    provider    TEXT PRIMARY KEY,
    hit_at      INTEGER NOT NULL,
    retry_after INTEGER NOT NULL DEFAULT 60,
    hit_count   INTEGER NOT NULL DEFAULT 1
);
SQL
	# Auto-prune expired entries (runs at most once per hour via timestamp check)
	cache_auto_prune
	return 0
}

# Auto-prune expired cache entries (gated to once per hour)
cache_auto_prune() {
	if ! command -v sqlite3 &>/dev/null; then
		return 0
	fi
	[[ -f "$IP_REP_CACHE_DB" ]] || return 0
	local prune_marker="${IP_REP_CACHE_DIR}/.last_prune"
	local now
	now=$(date +%s)
	if [[ -f "$prune_marker" ]]; then
		local last_prune
		last_prune=$(cat "$prune_marker" 2>/dev/null || echo "0")
		local elapsed=$((now - last_prune))
		if [[ "$elapsed" -lt 3600 ]]; then
			return 0
		fi
	fi
	local pruned
	pruned=$(sqlite3 "$IP_REP_CACHE_DB" \
		"DELETE FROM ip_cache WHERE (cached_at + ttl) <= ${now}; SELECT changes();" \
		2>/dev/null || echo "0")
	printf '%s' "$now" >"$prune_marker"
	if [[ "$pruned" -gt 0 ]]; then
		log_info "Auto-pruned ${pruned} expired cache entries"
	fi
	return 0
}

# Sanitize a provider name: allow only alphanumeric, hyphen, underscore
# Returns 0 if valid, 1 if invalid
sanitize_provider() {
	local provider="$1"
	[[ "$provider" =~ ^[a-zA-Z0-9_-]+$ ]]
	return $?
}

# Get cached result for ip+provider; returns empty string if miss/expired
# ip is validated as IPv4 (digits/dots only) by callers; provider is validated
# by sanitize_provider ([a-zA-Z0-9_-]+) — neither can contain SQL metacharacters.
cache_get() {
	local ip="$1"
	local provider="$2"
	if ! command -v sqlite3 &>/dev/null; then
		echo ""
		return 0
	fi
	if ! sanitize_provider "$provider"; then
		echo ""
		return 0
	fi
	local now
	now=$(date +%s)
	local result
	result=$(sqlite3 "$IP_REP_CACHE_DB" \
		"SELECT result FROM ip_cache WHERE ip='${ip}' AND provider='${provider}' AND (cached_at + ttl) > ${now} LIMIT 1;" \
		2>/dev/null || true)
	echo "$result"
	return 0
}

# Store result in cache
# ip and provider are validated before this call; result (JSON) has single quotes escaped.
cache_put() {
	local ip="$1"
	local provider="$2"
	local result="$3"
	local ttl="$4"
	if ! command -v sqlite3 &>/dev/null; then
		return 0
	fi
	if ! sanitize_provider "$provider"; then
		return 0
	fi
	local now
	now=$(date +%s)
	# Escape single quotes in result JSON by doubling them (SQL standard)
	local escaped_result
	escaped_result=$(printf '%s' "$result" | sed "s/'/''/g")
	sqlite3 "$IP_REP_CACHE_DB" \
		"INSERT OR REPLACE INTO ip_cache (ip, provider, result, cached_at, ttl) VALUES ('${ip}', '${provider}', '${escaped_result}', ${now}, ${ttl});" \
		2>/dev/null || true
	return 0
}

# =============================================================================
# Rate Limit Tracking
# =============================================================================

# Record a rate limit hit (HTTP 429) for a provider
rate_limit_record() {
	local provider="$1"
	local retry_after="${2:-60}"
	if ! command -v sqlite3 &>/dev/null; then
		return 0
	fi
	if ! sanitize_provider "$provider"; then
		return 0
	fi
	local now
	now=$(date +%s)
	sqlite3 "$IP_REP_CACHE_DB" \
		"INSERT INTO rate_limits (provider, hit_at, retry_after, hit_count)
		 VALUES ('${provider}', ${now}, ${retry_after}, 1)
		 ON CONFLICT(provider) DO UPDATE SET
		   hit_at = ${now},
		   retry_after = ${retry_after},
		   hit_count = hit_count + 1;" \
		2>/dev/null || true
	return 0
}

# Check if a provider is currently rate-limited; returns 0 if OK, 1 if limited
rate_limit_check() {
	local provider="$1"
	if ! command -v sqlite3 &>/dev/null; then
		return 0
	fi
	if ! sanitize_provider "$provider"; then
		return 0
	fi
	local now
	now=$(date +%s)
	local remaining
	remaining=$(sqlite3 "$IP_REP_CACHE_DB" \
		"SELECT (hit_at + retry_after) - ${now} FROM rate_limits
		 WHERE provider='${provider}' AND (hit_at + retry_after) > ${now}
		 LIMIT 1;" \
		2>/dev/null || true)
	if [[ -n "$remaining" && "$remaining" -gt 0 ]]; then
		log_warn "Provider '${provider}' rate-limited for ${remaining}s more"
		return 1
	fi
	return 0
}

# Show rate limit status for all providers
cmd_rate_limit_status() {
	if ! command -v sqlite3 &>/dev/null; then
		log_warn "sqlite3 not available — rate limit tracking disabled"
		return 0
	fi
	if [[ ! -f "$IP_REP_CACHE_DB" ]]; then
		log_info "No rate limit data (no queries run yet)"
		return 0
	fi
	local now
	now=$(date +%s)
	echo ""
	echo -e "$(c_bold)$(c_cyan)=== Rate Limit Status ===$(c_nc)"
	echo ""
	printf "  %-18s %-12s %-14s %-10s %s\n" "Provider" "Status" "Retry After" "Hits" "Last Hit"
	printf "  %-18s %-12s %-14s %-10s %s\n" "--------" "------" "-----------" "----" "--------"

	local has_data=false
	local provider
	for provider in $ALL_PROVIDERS; do
		local row
		row=$(sqlite3 "$IP_REP_CACHE_DB" \
			"SELECT hit_at, retry_after, hit_count FROM rate_limits
			 WHERE provider='${provider}' LIMIT 1;" \
			2>/dev/null || true)
		[[ -z "$row" ]] && continue
		has_data=true
		local hit_at retry_after hit_count
		IFS='|' read -r hit_at retry_after hit_count <<<"$row"
		local expires=$((hit_at + retry_after))
		local status status_color
		if [[ "$expires" -gt "$now" ]]; then
			local remaining=$((expires - now))
			status="LIMITED (${remaining}s)"
			status_color=$(c_red)
		else
			status="OK"
			status_color=$(c_green)
		fi
		local last_hit_fmt
		last_hit_fmt=$(date -r "$hit_at" +"%Y-%m-%d %H:%M" 2>/dev/null || date -d "@${hit_at}" +"%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown")
		local display_name
		display_name=$(provider_display_name "$provider")
		printf "  %-18s " "$display_name"
		echo -e "${status_color}${status}$(c_nc)  ${retry_after}s           ${hit_count}         ${last_hit_fmt}"
	done

	if [[ "$has_data" == "false" ]]; then
		echo "  No rate limit events recorded."
	fi
	echo ""
	return 0
}

# Show cache statistics
cmd_cache_stats() {
	if ! command -v sqlite3 &>/dev/null; then
		log_warn "sqlite3 not available — caching disabled"
		return 0
	fi
	if [[ ! -f "$IP_REP_CACHE_DB" ]]; then
		log_info "Cache database not yet initialised (no queries run yet)"
		return 0
	fi
	local now
	now=$(date +%s)
	echo ""
	echo -e "$(c_bold)$(c_cyan)=== IP Reputation Cache Statistics ===$(c_nc)"
	echo -e "Database: ${IP_REP_CACHE_DB}"
	echo ""
	sqlite3 "$IP_REP_CACHE_DB" <<SQL 2>/dev/null || true
.mode column
.headers on
SELECT
    provider,
    COUNT(*) AS total_entries,
    SUM(CASE WHEN (cached_at + ttl) > ${now} THEN 1 ELSE 0 END) AS valid,
    SUM(CASE WHEN (cached_at + ttl) <= ${now} THEN 1 ELSE 0 END) AS expired,
    MIN(datetime(cached_at, 'unixepoch')) AS oldest,
    MAX(datetime(cached_at, 'unixepoch')) AS newest
FROM ip_cache
GROUP BY provider
ORDER BY provider;
SQL
	echo ""
	return 0
}

# Clear cache entries
cmd_cache_clear() {
	local specific_provider=""
	local specific_ip=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			print_usage_cache_clear
			return 0
			;;
		--provider | -p)
			specific_provider="$2"
			shift 2
			;;
		--ip)
			specific_ip="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if ! command -v sqlite3 &>/dev/null; then
		log_warn "sqlite3 not available — caching disabled"
		return 0
	fi
	if [[ ! -f "$IP_REP_CACHE_DB" ]]; then
		log_info "Cache database not found — nothing to clear"
		return 0
	fi

	# Validate inputs before use in SQL to prevent injection
	if [[ -n "$specific_provider" ]] && ! sanitize_provider "$specific_provider"; then
		log_error "Invalid provider name: ${specific_provider}"
		return 1
	fi
	if [[ -n "$specific_ip" ]] && ! [[ "$specific_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		log_error "Invalid IP address: ${specific_ip}"
		return 1
	fi

	local deleted
	if [[ -n "$specific_provider" && -n "$specific_ip" ]]; then
		deleted=$(sqlite3 "$IP_REP_CACHE_DB" \
			"DELETE FROM ip_cache WHERE provider=? AND ip=?; SELECT changes();" \
			"$specific_provider" "$specific_ip" \
			2>/dev/null || echo "0")
	elif [[ -n "$specific_provider" ]]; then
		deleted=$(sqlite3 "$IP_REP_CACHE_DB" \
			"DELETE FROM ip_cache WHERE provider=?; SELECT changes();" \
			"$specific_provider" \
			2>/dev/null || echo "0")
	elif [[ -n "$specific_ip" ]]; then
		deleted=$(sqlite3 "$IP_REP_CACHE_DB" \
			"DELETE FROM ip_cache WHERE ip=?; SELECT changes();" \
			"$specific_ip" \
			2>/dev/null || echo "0")
	else
		deleted=$(sqlite3 "$IP_REP_CACHE_DB" \
			"DELETE FROM ip_cache; SELECT changes();" \
			2>/dev/null || echo "0")
	fi
	log_success "Cleared ${deleted} cache entries"
	return 0
}

# Portable timeout command (macOS uses gtimeout from coreutils, Linux has timeout)
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then
	TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
	TIMEOUT_CMD="gtimeout"
fi
readonly TIMEOUT_CMD

# Default settings (prefixed to avoid conflict with shared-constants.sh DEFAULT_TIMEOUT)
readonly IP_REP_DEFAULT_TIMEOUT="${IP_REP_TIMEOUT:-15}"
readonly IP_REP_DEFAULT_FORMAT="${IP_REP_FORMAT:-table}"

# =============================================================================
# Colors (RED, GREEN, YELLOW, CYAN, NC sourced from shared-constants.sh)
# =============================================================================

# BOLD is not in shared-constants.sh — define it here
# shellcheck disable=SC2034
BOLD='\033[1m'

# Color accessor functions — return empty strings when --no-color is active.
# This avoids reassigning readonly variables from shared-constants.sh.
c_red() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$RED"; }
c_green() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$GREEN"; }
c_yellow() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$YELLOW"; }
c_cyan() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$CYAN"; }
c_nc() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$NC"; }
c_bold() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$BOLD"; }

# Disable colors when --no-color is active or NO_COLOR env is set
# Called after argument parsing sets IP_REP_NO_COLOR
disable_colors() {
	IP_REP_NO_COLOR="true"
	return 0
}

# =============================================================================
# Logging
# =============================================================================

log_info() {
	echo -e "$(c_cyan)[INFO]$(c_nc) $*" >&2
	return 0
}

log_warn() {
	echo -e "$(c_yellow)[WARN]$(c_nc) $*" >&2
	return 0
}

log_error() {
	echo -e "$(c_red)[ERROR]$(c_nc) $*" >&2
	return 0
}

log_success() {
	echo -e "$(c_green)[OK]$(c_nc) $*" >&2
	return 0
}

# =============================================================================
# Provider Management
# =============================================================================

# Map provider name to script filename
provider_script() {
	local provider="$1"
	case "$provider" in
	abuseipdb) echo "ip-rep-abuseipdb.sh" ;;
	virustotal) echo "ip-rep-virustotal.sh" ;;
	proxycheck) echo "ip-rep-proxycheck.sh" ;;
	spamhaus) echo "ip-rep-spamhaus.sh" ;;
	stopforumspam) echo "ip-rep-stopforumspam.sh" ;;
	blocklistde) echo "ip-rep-blocklistde.sh" ;;
	greynoise) echo "ip-rep-greynoise.sh" ;;
	ipqualityscore) echo "ip-rep-ipqualityscore.sh" ;;
	scamalytics) echo "ip-rep-scamalytics.sh" ;;
	shodan) echo "ip-rep-shodan.sh" ;;
	iphub) echo "ip-rep-iphub.sh" ;;
	*) echo "" ;;
	esac
	return 0
}

# Map provider name to display name
provider_display_name() {
	local provider="$1"
	case "$provider" in
	abuseipdb) echo "AbuseIPDB" ;;
	virustotal) echo "VirusTotal" ;;
	proxycheck) echo "ProxyCheck.io" ;;
	spamhaus) echo "Spamhaus DNSBL" ;;
	stopforumspam) echo "StopForumSpam" ;;
	blocklistde) echo "Blocklist.de" ;;
	greynoise) echo "GreyNoise" ;;
	ipqualityscore) echo "IPQualityScore" ;;
	scamalytics) echo "Scamalytics" ;;
	shodan) echo "Shodan" ;;
	iphub) echo "IP Hub" ;;
	*) echo "$provider" ;;
	esac
	return 0
}

# Check if a provider script exists and is executable
is_provider_available() {
	local provider="$1"
	local script
	script=$(provider_script "$provider")
	[[ -n "$script" ]] && [[ -x "${PROVIDERS_DIR}/${script}" ]]
	return $?
}

# Get list of available providers (space-separated)
get_available_providers() {
	local available=()
	local provider
	for provider in $ALL_PROVIDERS; do
		if is_provider_available "$provider"; then
			available+=("$provider")
		fi
	done

	if [[ ${#available[@]} -eq 0 ]]; then
		log_error "No provider scripts found in ${PROVIDERS_DIR}/"
		return 1
	fi

	echo "${available[*]}"
	return 0
}

# =============================================================================
# Provider Execution
# =============================================================================

# Run a single provider and write JSON result to stdout
# Checks rate limits and SQLite cache first; falls back to live query on miss/expiry
# Detects HTTP 429 (rate_limited error) and retries with exponential backoff
run_provider() {
	local provider="$1"
	local ip="$2"
	local timeout_secs="$3"
	local use_cache="${4:-true}"

	local script
	script=$(provider_script "$provider")
	local script_path="${PROVIDERS_DIR}/${script}"

	if [[ ! -x "$script_path" ]]; then
		jq -n \
			--arg provider "$provider" \
			--arg ip "$ip" \
			'{provider: $provider, ip: $ip, error: "provider_not_available", is_listed: false, score: 0, risk_level: "unknown"}'
		return 0
	fi

	# Check if provider is currently rate-limited
	if ! rate_limit_check "$provider" 2>/dev/null; then
		jq -n \
			--arg provider "$provider" \
			--arg ip "$ip" \
			'{provider: $provider, ip: $ip, error: "rate_limited", is_listed: false, score: 0, risk_level: "unknown"}'
		return 0
	fi

	# Check cache first (skip if --no-cache or provider errored last time)
	if [[ "$use_cache" == "true" ]]; then
		local cached
		cached=$(cache_get "$ip" "$provider")
		if [[ -n "$cached" ]]; then
			# Annotate cached result
			echo "$cached" | jq '. + {cached: true}'
			return 0
		fi
	fi

	# Retry loop with exponential backoff for rate limit (429) responses
	local max_retries=2
	local attempt=0
	local backoff=2

	while [[ "$attempt" -le "$max_retries" ]]; do
		local result
		local run_cmd=("$script_path" check "$ip")
		if [[ -n "$TIMEOUT_CMD" ]]; then
			run_cmd=("$TIMEOUT_CMD" "$timeout_secs" "${run_cmd[@]}")
		fi

		if result=$("${run_cmd[@]}" 2>/dev/null); then
			if echo "$result" | jq empty 2>/dev/null; then
				# Check for rate_limited error from provider script
				local error_type
				error_type=$(echo "$result" | jq -r '.error // empty')
				if [[ "$error_type" == "rate_limited" || "$error_type" == *"429"* || "$error_type" == *"rate limit"* ]]; then
					local retry_after
					retry_after=$(echo "$result" | jq -r '.retry_after // 60')
					rate_limit_record "$provider" "$retry_after"
					if [[ "$attempt" -lt "$max_retries" ]]; then
						attempt=$((attempt + 1))
						local jitter=$((RANDOM % backoff))
						local backoff_with_jitter=$((backoff + jitter))
						log_warn "Provider '${provider}' returned 429 — retry ${attempt}/${max_retries} in ${backoff_with_jitter}s"
						sleep "$backoff_with_jitter" 2>/dev/null || true
						backoff=$((backoff * 2))
						continue
					fi
					echo "$result"
					return 0
				fi

				# Only cache successful (non-error) results
				if [[ -z "$error_type" && "$use_cache" == "true" ]]; then
					local ttl
					ttl=$(provider_cache_ttl "$provider")
					cache_put "$ip" "$provider" "$result" "$ttl"
				fi
				echo "$result"
			else
				jq -n \
					--arg provider "$provider" \
					--arg ip "$ip" \
					'{provider: $provider, ip: $ip, error: "invalid_json_response", is_listed: false, score: 0, risk_level: "unknown"}'
			fi
			return 0
		else
			local exit_code=$?
			local err_msg
			if [[ $exit_code -eq 124 ]]; then
				err_msg="timeout after ${timeout_secs}s"
			else
				err_msg="provider failed (exit ${exit_code})"
			fi
			jq -n \
				--arg provider "$provider" \
				--arg ip "$ip" \
				--arg error "$err_msg" \
				'{provider: $provider, ip: $ip, error: $error, is_listed: false, score: 0, risk_level: "unknown"}'
			return 0
		fi
	done
	return 0
}

# =============================================================================
# Risk Scoring
# =============================================================================

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
		[[ -f "$file" ]] || continue
		local content
		content=$(cat "$file")
		[[ -z "$content" ]] && continue

		# Skip if not valid JSON
		echo "$content" | jq empty 2>/dev/null || continue

		provider_results=$(echo "$provider_results" | jq --argjson r "$content" '. + [$r]')

		# Check for errors
		if echo "$content" | jq -e '.error' &>/dev/null; then
			errors=$((errors + 1))
			continue
		fi

		provider_count=$((provider_count + 1))

		# Track cache hit/miss
		local was_cached
		was_cached=$(echo "$content" | jq -r '.cached // false')
		if [[ "$was_cached" == "true" ]]; then
			cache_hits=$((cache_hits + 1))
		else
			cache_misses=$((cache_misses + 1))
		fi

		local score is_listed
		score=$(echo "$content" | jq -r '.score // 0')
		is_listed=$(echo "$content" | jq -r '.is_listed // false')

		total_score=$((total_score + ${score%.*}))

		if [[ "$is_listed" == "true" ]]; then
			listed_count=$((listed_count + 1))
		fi

		# Aggregate flags
		if [[ "$(echo "$content" | jq -r '.is_tor // false')" == "true" ]]; then
			is_tor=true
		fi
		if [[ "$(echo "$content" | jq -r '.is_proxy // false')" == "true" ]]; then
			is_proxy=true
		fi
		if [[ "$(echo "$content" | jq -r '.is_vpn // false')" == "true" ]]; then
			is_vpn=true
		fi
	done

	# Calculate unified score
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

	# Determine unified risk level
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

	# Recommendation
	local recommendation
	case "$risk_level" in
	critical) recommendation="AVOID — IP is heavily flagged across multiple sources" ;;
	high) recommendation="AVOID — IP has significant abuse/attack history" ;;
	medium) recommendation="CAUTION — IP has some flags, investigate before use" ;;
	low) recommendation="PROCEED WITH CAUTION — minor flags detected" ;;
	clean) recommendation="SAFE — no significant flags detected" ;;
	*) recommendation="UNKNOWN — insufficient data" ;;
	esac

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
			local prov_color
			prov_color=$(risk_color "$risk")
			local display_name
			display_name=$(provider_display_name "$prov")
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

# =============================================================================
# Core Commands
# =============================================================================

# Check a single IP address
cmd_check() {
	local ip=""
	local specific_provider=""
	local run_parallel=true
	local timeout_secs="$IP_REP_DEFAULT_TIMEOUT"
	local output_format="$IP_REP_DEFAULT_FORMAT"
	local use_cache="true"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			print_usage_check
			return 0
			;;
		--provider | -p)
			specific_provider="$2"
			shift 2
			;;
		--timeout | -t)
			timeout_secs="$2"
			shift 2
			;;
		--format | -f)
			output_format="$2"
			shift 2
			;;
		--parallel)
			run_parallel=true
			shift
			;;
		--sequential)
			run_parallel=false
			shift
			;;
		--no-cache)
			use_cache="false"
			shift
			;;
		--no-color)
			IP_REP_NO_COLOR="true"
			disable_colors
			shift
			;;
		# Batch-mode passthrough flags (ignored in single-check context)
		--rate-limit | --dnsbl-overlap)
			[[ "$1" == "--rate-limit" ]] && shift
			shift
			;;
		-*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "$ip" ]]; then
				ip="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$ip" ]]; then
		log_error "IP address required"
		echo "Usage: $(basename "$0") check <ip> [options]" >&2
		return 1
	fi

	# Validate IPv4 format
	if ! echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
		log_error "Invalid IPv4 address: ${ip}"
		return 1
	fi

	log_info "Checking IP reputation for: ${ip}"

	# Initialise cache
	cache_init

	# Determine providers to use
	local -a providers_to_run=()
	if [[ -n "$specific_provider" ]]; then
		if is_provider_available "$specific_provider"; then
			providers_to_run+=("$specific_provider")
		else
			log_error "Provider '${specific_provider}' not available"
			cmd_providers
			return 1
		fi
	else
		local available
		available=$(get_available_providers) || return 1
		read -ra providers_to_run <<<"$available"
	fi

	log_info "Using providers: ${providers_to_run[*]}"

	# Create temp directory for results
	local tmp_dir
	tmp_dir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '${tmp_dir}'" RETURN

	local -a result_files=()
	local -a pids=()

	if [[ "$run_parallel" == "true" && ${#providers_to_run[@]} -gt 1 ]]; then
		# Parallel execution via background jobs
		local provider
		for provider in "${providers_to_run[@]}"; do
			local result_file="${tmp_dir}/${provider}.json"
			result_files+=("$result_file")

			(
				local result
				result=$(run_provider "$provider" "$ip" "$timeout_secs" "$use_cache")
				echo "$result" >"$result_file"
			) &
			pids+=($!)
		done

		# Wait for all background jobs
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
			local result
			result=$(run_provider "$provider" "$ip" "$timeout_secs" "$use_cache")
			echo "$result" >"$result_file"
		done
	fi

	# Merge results
	local merged
	merged=$(merge_results "$ip" "${result_files[@]}") || {
		log_error "Failed to merge provider results"
		return 1
	}

	output_results "$merged" "$output_format"
	return 0
}

# DNSBL overlap check — performs standalone DNS lookups against common blacklists.
# Returns JSON array of blacklists the IP appears on.
# Uses the same DNSBL zones as email-health-check-helper.sh for cross-tool consistency.
dnsbl_overlap_check() {
	local ip="$1"

	if ! command -v dig &>/dev/null; then
		echo "[]"
		return 0
	fi

	# Reverse IP for DNSBL lookup
	local reversed_ip
	reversed_ip=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')

	# Common DNSBL zones (same set used by email-health-check-helper.sh)
	local blacklists="zen.spamhaus.org bl.spamcop.net b.barracudacentral.org"
	local listed_on="[]"

	local bl
	for bl in $blacklists; do
		local result
		result=$(dig A "${reversed_ip}.${bl}" +short 2>/dev/null || true)
		if [[ -n "$result" && "$result" != *"NXDOMAIN"* ]]; then
			listed_on=$(echo "$listed_on" | jq --arg bl "$bl" '. + [$bl]')
		fi
	done

	echo "$listed_on"
	return 0
}

# Batch check IPs from a file (one IP per line)
# Supports rate limiting across providers and optional DNSBL overlap
cmd_batch() {
	local file=""
	local output_format="$IP_REP_DEFAULT_FORMAT"
	local timeout_secs="$IP_REP_DEFAULT_TIMEOUT"
	local specific_provider=""
	local use_cache="true"
	local rate_limit="${IP_REP_RATE_LIMIT:-2}"
	local dnsbl_overlap=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			print_usage_batch
			return 0
			;;
		--format | -f)
			output_format="$2"
			shift 2
			;;
		--timeout | -t)
			timeout_secs="$2"
			shift 2
			;;
		--provider | -p)
			specific_provider="$2"
			shift 2
			;;
		--no-cache)
			use_cache="false"
			shift
			;;
		--no-color)
			IP_REP_NO_COLOR="true"
			disable_colors
			shift
			;;
		--rate-limit)
			rate_limit="$2"
			shift 2
			;;
		--dnsbl-overlap)
			dnsbl_overlap=true
			shift
			;;
		-*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "$file" ]]; then
				file="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$file" ]]; then
		log_error "File path required"
		echo "Usage: $(basename "$0") batch <file> [options]" >&2
		return 1
	fi

	if [[ ! -f "$file" ]]; then
		log_error "File not found: ${file}"
		return 1
	fi

	# Initialise cache
	cache_init

	local total=0
	local processed=0
	local clean=0
	local flagged=0

	# Count IPs
	total=$(grep -cE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' "$file" || echo 0)
	log_info "Processing ${total} IPs from ${file} (rate limit: ${rate_limit} req/s per provider)"

	local batch_results="[]"

	# Validate rate_limit is a positive integer
	if ! [[ "$rate_limit" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid --rate-limit value '${rate_limit}' — must be a positive integer; defaulting to 2"
		rate_limit=2
	fi

	# Rate limiting: sleep a fixed interval between IPs
	# rate_limit=2 means 2 IPs/second → sleep 0.5s between IPs
	# Uses awk for portable float division (bash doesn't do floats)
	local sleep_between
	if [[ "$rate_limit" -gt 0 ]]; then
		sleep_between=$(awk "BEGIN {printf \"%.3f\", 1/$rate_limit}")
	else
		sleep_between="0"
	fi

	local first_ip=true

	while IFS= read -r line; do
		# Skip empty lines and comments
		[[ -z "$line" || "$line" =~ ^# ]] && continue

		# Validate IP format
		if ! echo "$line" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
			log_warn "Skipping invalid IP: ${line}"
			continue
		fi

		# Rate limiting: sleep between IPs (skip before first IP)
		if [[ "$sleep_between" != "0" && "$first_ip" == "false" ]]; then
			sleep "$sleep_between" 2>/dev/null || true
		fi
		first_ip=false

		processed=$((processed + 1))
		log_info "[${processed}/${total}] Checking ${line}..."

		local check_args=("$line" "--format" "json" "--timeout" "$timeout_secs")
		[[ -n "$specific_provider" ]] && check_args+=("--provider" "$specific_provider")
		[[ "$use_cache" == "false" ]] && check_args+=("--no-cache")

		local result
		result=$(cmd_check "${check_args[@]}" 2>/dev/null) || {
			log_warn "Failed to check ${line}"
			continue
		}

		# DNSBL overlap integration
		if [[ "$dnsbl_overlap" == "true" ]]; then
			local dnsbl_hits
			dnsbl_hits=$(dnsbl_overlap_check "$line")
			local dnsbl_count
			dnsbl_count=$(echo "$dnsbl_hits" | jq 'length')
			result=$(echo "$result" | jq \
				--argjson dnsbl_hits "$dnsbl_hits" \
				--argjson dnsbl_count "$dnsbl_count" \
				'. + {dnsbl_overlap: {listed_on: $dnsbl_hits, count: $dnsbl_count}}')
		fi

		local risk_level
		risk_level=$(echo "$result" | jq -r '.risk_level // "unknown"')

		if [[ "$risk_level" == "clean" ]]; then
			clean=$((clean + 1))
		else
			flagged=$((flagged + 1))
		fi

		batch_results=$(echo "$batch_results" | jq --argjson r "$result" '. + [$r]')

	done <"$file"

	# Batch summary
	echo ""
	echo -e "$(c_bold)$(c_cyan)=== Batch Results ===$(c_nc)"
	echo -e "File:     ${file}"
	echo -e "Total:    ${processed} IPs processed"
	echo -e "Clean:    $(c_green)${clean}$(c_nc)"
	echo -e "Flagged:  $(c_red)${flagged}$(c_nc)"
	[[ "$dnsbl_overlap" == "true" ]] && echo -e "DNSBL:    overlap check enabled"
	echo ""

	# Show flagged IPs
	if [[ "$flagged" -gt 0 ]]; then
		echo -e "$(c_bold)Flagged IPs:$(c_nc)"
		local _nc_batch
		_nc_batch=$(c_nc)
		echo "$batch_results" | jq -r '.[] | select(.risk_level != "clean") | "\(.ip)\t\(.risk_level)\t\(.unified_score)\t\(.recommendation)"' 2>/dev/null |
			while IFS=$'\t' read -r batch_ip risk score rec; do
				local color risk_upper
				color=$(risk_color "$risk")
				risk_upper=$(echo "$risk" | tr '[:lower:]' '[:upper:]')
				echo -e "  ${batch_ip}  ${color}${risk_upper}${_nc_batch} (${score})  ${rec}"
			done
		echo ""
	fi

	if [[ "$output_format" == "json" ]]; then
		jq -n \
			--arg file "$file" \
			--argjson total "$processed" \
			--argjson clean "$clean" \
			--argjson flagged "$flagged" \
			--argjson results "$batch_results" \
			'{file: $file, total: $total, clean: $clean, flagged: $flagged, results: $results}'
	fi

	return 0
}

# Generate detailed markdown report for an IP
cmd_report() {
	local ip=""
	local timeout_secs="$IP_REP_DEFAULT_TIMEOUT"
	local specific_provider=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			print_usage_report
			return 0
			;;
		--timeout | -t)
			timeout_secs="$2"
			shift 2
			;;
		--provider | -p)
			specific_provider="$2"
			shift 2
			;;
		-*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "$ip" ]]; then
				ip="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$ip" ]]; then
		log_error "IP address required"
		echo "Usage: $(basename "$0") report <ip> [options]" >&2
		return 1
	fi

	local check_args=("$ip" "--format" "json" "--timeout" "$timeout_secs")
	[[ -n "$specific_provider" ]] && check_args+=("--provider" "$specific_provider")

	local result
	result=$(cmd_check "${check_args[@]}") || return 1

	format_markdown "$result"
	return 0
}

# List all providers and their status
cmd_providers() {
	echo ""
	echo -e "$(c_bold)$(c_cyan)=== IP Reputation Providers ===$(c_nc)"
	echo ""
	printf "  %-18s %-20s %-10s %-12s %s\n" "Provider" "Display Name" "Status" "Key Req." "Free Tier"
	printf "  %-18s %-20s %-10s %-12s %s\n" "--------" "------------" "------" "--------" "---------"

	local provider
	for provider in $ALL_PROVIDERS; do
		local script
		script=$(provider_script "$provider")
		local script_path="${PROVIDERS_DIR}/${script}"
		local display_name
		display_name=$(provider_display_name "$provider")

		local status key_req free_tier
		if [[ -x "$script_path" ]]; then
			# Get info from provider
			local info
			info=$("$script_path" info 2>/dev/null || echo '{}')
			key_req=$(echo "$info" | jq -r '.requires_key // false | if . then "yes" else "no" end')
			free_tier=$(echo "$info" | jq -r '.free_tier // "unknown"')
			status="$(c_green)available$(c_nc)"
		else
			status="$(c_red)missing$(c_nc)"
			key_req="-"
			free_tier="-"
		fi

		printf "  %-18s %-20s " "$provider" "$display_name"
		echo -e "${status}  ${key_req}          ${free_tier}"
	done

	echo ""
	echo -e "Provider scripts location: ${PROVIDERS_DIR}/"
	echo -e "Each provider implements: check <ip> [--api-key <key>] [--timeout <s>]"
	echo ""
	return 0
}

# =============================================================================
# Per-Subcommand Help
# =============================================================================

print_usage_check() {
	cat <<EOF
Usage: $(basename "$0") check <ip> [options]

Check the reputation of a single IP address across multiple providers.

Arguments:
  <ip>              IPv4 address to check (required)

Options:
  --provider, -p <p>    Use only specified provider (default: all available)
  --timeout, -t <s>     Per-provider timeout in seconds (default: ${IP_REP_DEFAULT_TIMEOUT})
  --format, -f <fmt>    Output format: table (default), json, markdown, compact
  --parallel            Run providers in parallel (default)
  --sequential          Run providers sequentially
  --no-cache            Bypass cache for this query
  --no-color            Disable color output (also respects NO_COLOR env)

Examples:
  $(basename "$0") check 1.2.3.4
  $(basename "$0") check 1.2.3.4 -f json
  $(basename "$0") check 1.2.3.4 --format markdown
  $(basename "$0") check 1.2.3.4 --format compact
  $(basename "$0") check 1.2.3.4 --provider abuseipdb
  $(basename "$0") check 1.2.3.4 --no-cache
  $(basename "$0") check 1.2.3.4 --no-color
  $(basename "$0") check 1.2.3.4 --sequential --timeout 30
EOF
	return 0
}

print_usage_batch() {
	cat <<EOF
Usage: $(basename "$0") batch <file> [options]

Check multiple IP addresses from a file (one IP per line).
Lines starting with # and blank lines are skipped.

Arguments:
  <file>            Path to file containing IPs (required)

Options:
  --provider, -p <p>    Use only specified provider (default: all available)
  --timeout, -t <s>     Per-provider timeout in seconds (default: ${IP_REP_DEFAULT_TIMEOUT})
  --format, -f <fmt>    Output format: table (default), json
  --no-cache            Bypass cache for this query
  --rate-limit <n>      Requests per second per provider (default: 2)
  --dnsbl-overlap       Cross-reference results with email DNSBL zones

Examples:
  $(basename "$0") batch ips.txt
  $(basename "$0") batch ips.txt --rate-limit 1
  $(basename "$0") batch ips.txt --dnsbl-overlap
  $(basename "$0") batch ips.txt -f json
  $(basename "$0") batch ips.txt --provider spamhaus --rate-limit 5
EOF
	return 0
}

print_usage_report() {
	cat <<EOF
Usage: $(basename "$0") report <ip> [options]

Generate a detailed markdown report for an IP address.
Queries all available providers and outputs a formatted markdown document
suitable for documentation, audit trails, or sharing.

Arguments:
  <ip>              IPv4 address to report on (required)

Options:
  --provider, -p <p>    Use only specified provider (default: all available)
  --timeout, -t <s>     Per-provider timeout in seconds (default: ${IP_REP_DEFAULT_TIMEOUT})

Examples:
  $(basename "$0") report 1.2.3.4
  $(basename "$0") report 1.2.3.4 > report.md
  $(basename "$0") report 1.2.3.4 --provider abuseipdb
  $(basename "$0") report 1.2.3.4 --timeout 30

Note: Equivalent to: $(basename "$0") check 1.2.3.4 --format markdown
EOF
	return 0
}

print_usage_cache_clear() {
	cat <<EOF
Usage: $(basename "$0") cache-clear [options]

Clear cached IP reputation results from the SQLite cache.
Without filters, clears all cached entries.

Options:
  --provider, -p <p>    Clear cache only for specified provider
  --ip <ip>             Clear cache only for specified IP address

Examples:
  $(basename "$0") cache-clear
  $(basename "$0") cache-clear --provider abuseipdb
  $(basename "$0") cache-clear --ip 1.2.3.4
  $(basename "$0") cache-clear --provider spamhaus --ip 1.2.3.4
EOF
	return 0
}

# =============================================================================
# Usage
# =============================================================================

print_usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  check <ip>          Check reputation of a single IP address
  batch <file>        Check multiple IPs from file (one per line)
  report <ip>         Generate detailed markdown report for an IP
  providers           List available providers and their status
  cache-stats         Show SQLite cache statistics
  cache-clear         Clear cache entries (--provider, --ip filters)
  rate-limit-status   Show per-provider rate limit status and history
  help                Show this help message

Options:
  --provider <p>    Use only specified provider
  --timeout <s>     Per-provider timeout in seconds (default: ${IP_REP_DEFAULT_TIMEOUT})
  --format <fmt>    Output format: table (default), json, markdown, compact
  --parallel        Run providers in parallel (default)
  --sequential      Run providers sequentially
  --no-cache        Bypass cache for this query
  --no-color        Disable color output (also respects NO_COLOR env)
  --rate-limit <n>  Requests/second per provider in batch mode (default: 2)
  --dnsbl-overlap   Cross-reference with DNSBL in batch mode

Providers (no key required):
  spamhaus          Spamhaus DNSBL (SBL/XBL/PBL)
  proxycheck        ProxyCheck.io (optional key for higher limits)
  stopforumspam     StopForumSpam
  blocklistde       Blocklist.de
  greynoise         GreyNoise Community API (optional key for full API)

Providers (free API key required):
  abuseipdb         AbuseIPDB — 1000/day free (abuseipdb.com)
  virustotal        VirusTotal — 500/day free (virustotal.com)
  ipqualityscore    IPQualityScore — 5000/month free (ipqualityscore.com)
  scamalytics       Scamalytics — 5000/month free (scamalytics.com)
  shodan            Shodan — free key, limited credits (shodan.io)
  iphub             IP Hub — 1000/day free (iphub.info)

Environment:
  ABUSEIPDB_API_KEY         AbuseIPDB API key
  VIRUSTOTAL_API_KEY        VirusTotal API key
  PROXYCHECK_API_KEY        ProxyCheck.io API key (optional)
  IPQUALITYSCORE_API_KEY    IPQualityScore API key
  SCAMALYTICS_API_KEY       Scamalytics API key
  GREYNOISE_API_KEY         GreyNoise API key (optional, enables full API)
  SHODAN_API_KEY            Shodan API key
  IPHUB_API_KEY             IP Hub API key
  IP_REP_TIMEOUT            Default timeout (default: 15)
  IP_REP_FORMAT             Default format (default: table)
  IP_REP_CACHE_DIR          SQLite cache directory (default: ~/.cache/ip-reputation)
  IP_REP_CACHE_TTL          Default cache TTL in seconds (default: 86400)
  IP_REP_RATE_LIMIT         Batch rate limit req/s (default: 2)

Examples:
  $(basename "$0") check 1.2.3.4
  $(basename "$0") check 1.2.3.4 --format json
  $(basename "$0") check 1.2.3.4 --format compact
  $(basename "$0") check 1.2.3.4 --provider spamhaus
  $(basename "$0") check 1.2.3.4 --no-cache
  $(basename "$0") check 1.2.3.4 --no-color
  $(basename "$0") batch ips.txt
  $(basename "$0") batch ips.txt --rate-limit 1 --dnsbl-overlap
  $(basename "$0") batch ips.txt --format json
  $(basename "$0") report 1.2.3.4
  $(basename "$0") providers
  $(basename "$0") cache-stats
  $(basename "$0") cache-clear --provider abuseipdb
  $(basename "$0") cache-clear --ip 1.2.3.4
  $(basename "$0") rate-limit-status
EOF
	return 0
}

# =============================================================================
# Main Dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	# Handle global --no-color before dispatch (for commands that don't parse it)
	if [[ "${NO_COLOR:-}" == "true" || "${NO_COLOR:-}" == "1" ]]; then
		# shellcheck disable=SC2034
		IP_REP_NO_COLOR="true"
		disable_colors
	fi

	case "$command" in
	check)
		cmd_check "$@"
		;;
	batch)
		cmd_batch "$@"
		;;
	report)
		cmd_report "$@"
		;;
	providers)
		cmd_providers
		;;
	cache-stats | cache_stats)
		cmd_cache_stats
		;;
	cache-clear | cache_clear)
		cmd_cache_clear "$@"
		;;
	rate-limit-status | rate_limit_status)
		cache_init
		cmd_rate_limit_status
		;;
	help | --help | -h)
		print_usage
		;;
	version | --version | -v)
		echo "ip-reputation-helper.sh v${VERSION}"
		;;
	*)
		log_error "Unknown command: ${command}"
		print_usage
		exit 1
		;;
	esac
	return 0
}

main "$@"
