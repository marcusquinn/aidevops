#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# IP Reputation Provider Management -- provider discovery, mapping, and execution
# =============================================================================
# Maps provider names to scripts, checks availability, and runs providers with
# cache-aware retry logic (exponential backoff on HTTP 429).
#
# Usage: source "${SCRIPT_DIR}/ip-reputation-helper-providers.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error, log_warn, log_info, timeout_sec)
#   - ip-reputation-helper-cache.sh (cache_get, cache_put, provider_cache_ttl,
#     rate_limit_record, rate_limit_check, sanitize_provider)
#   - PROVIDERS_DIR (from orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_IP_REP_PROVIDERS_LIB_LOADED:-}" ]] && return 0
_IP_REP_PROVIDERS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

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

# Execute a single provider attempt; handle rate-limit 429 and cache writes.
# Outputs JSON result to stdout. Returns 0 always (errors encoded in JSON).
# Called by _run_provider_with_retry inside the retry loop.
_run_provider_attempt() {
	local provider="$1"
	local ip="$2"
	local script_path="$3"
	local timeout_secs="$4"
	local use_cache="$5"
	local attempt="$6"
	local max_retries="$7"
	local backoff="$8"

	local result
	local run_cmd=(timeout_sec "$timeout_secs" "$script_path" check "$ip")

	if result=$("${run_cmd[@]}" 2>/dev/null); then
		if echo "$result" | jq empty 2>/dev/null; then
			local error_type
			error_type=$(echo "$result" | jq -r '.error // empty')
			if [[ "$error_type" == "rate_limited" || "$error_type" == *"429"* || "$error_type" == *"rate limit"* ]]; then
				local retry_after
				retry_after=$(echo "$result" | jq -r '.retry_after // 60')
				rate_limit_record "$provider" "$retry_after"
				if [[ "$attempt" -lt "$max_retries" ]]; then
					local jitter=$((RANDOM % backoff))
					local backoff_with_jitter=$((backoff + jitter))
					log_warn "Provider '${provider}' returned 429 — retry $((attempt + 1))/${max_retries} in ${backoff_with_jitter}s"
					sleep "$backoff_with_jitter" 2>/dev/null || true
					# Signal caller to retry: print sentinel + new backoff
					echo "__RETRY__ $((backoff * 2))"
					return 0
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
}

# Retry loop with exponential backoff for rate limit (429) responses.
# Outputs JSON result to stdout. Returns 0 always.
_run_provider_with_retry() {
	local provider="$1"
	local ip="$2"
	local script_path="$3"
	local timeout_secs="$4"
	local use_cache="$5"

	local max_retries=2
	local attempt=0
	local backoff=2

	while [[ "$attempt" -le "$max_retries" ]]; do
		local attempt_out
		attempt_out=$(_run_provider_attempt \
			"$provider" "$ip" "$script_path" "$timeout_secs" "$use_cache" \
			"$attempt" "$max_retries" "$backoff")
		if [[ "$attempt_out" == __RETRY__* ]]; then
			backoff="${attempt_out#__RETRY__ }"
			attempt=$((attempt + 1))
			continue
		fi
		echo "$attempt_out"
		return 0
	done
	return 0
}

# Run a single provider and write JSON result to stdout.
# Checks script availability, rate limits, and SQLite cache first;
# falls back to live query on miss/expiry with exponential backoff on 429.
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
			echo "$cached" | jq '. + {cached: true}'
			return 0
		fi
	fi

	_run_provider_with_retry "$provider" "$ip" "$script_path" "$timeout_secs" "$use_cache"
	return 0
}
