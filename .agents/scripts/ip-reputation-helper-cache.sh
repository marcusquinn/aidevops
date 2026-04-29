#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# IP Reputation Cache & Rate Limiting -- SQLite cache and rate-limit tracking
# =============================================================================
# Pure data-layer functions for the IP reputation checker.  Handles SQLite
# cache init/get/put, auto-pruning of expired entries, and per-provider 429
# rate-limit recording and checking.
#
# Usage: source "${SCRIPT_DIR}/ip-reputation-helper-cache.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - IP_REP_CACHE_DIR, IP_REP_CACHE_DB, IP_REP_DEFAULT_CACHE_TTL (from orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_IP_REP_CACHE_LIB_LOADED:-}" ]] && return 0
_IP_REP_CACHE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

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
# Defense-in-depth: escape single quotes in all interpolated values even though
# ip is validated as IPv4 and provider is validated by sanitize_provider.
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
	# Escape single quotes in all interpolated values (SQL standard: ' → '')
	local safe_ip="${ip//\'/\'\'}"
	local safe_provider="${provider//\'/\'\'}"
	local result
	result=$(sqlite3 "$IP_REP_CACHE_DB" \
		"SELECT result FROM ip_cache WHERE ip='${safe_ip}' AND provider='${safe_provider}' AND (cached_at + ttl) > ${now} LIMIT 1;" \
		2>/dev/null || true)
	echo "$result"
	return 0
}

# Store result in cache
# Defense-in-depth: escape single quotes in all interpolated values consistently.
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
	# Escape single quotes in all interpolated values (SQL standard: ' → '')
	local safe_ip="${ip//\'/\'\'}"
	local safe_provider="${provider//\'/\'\'}"
	local safe_result="${result//\'/\'\'}"
	sqlite3 "$IP_REP_CACHE_DB" \
		"INSERT OR REPLACE INTO ip_cache (ip, provider, result, cached_at, ttl) VALUES ('${safe_ip}', '${safe_provider}', '${safe_result}', ${now}, ${ttl});" \
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
