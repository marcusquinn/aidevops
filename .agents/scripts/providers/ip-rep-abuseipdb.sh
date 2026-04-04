#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# ip-rep-abuseipdb.sh — AbuseIPDB provider for ip-reputation-helper.sh
# Interface: check <ip> [--api-key <key>] → JSON result on stdout
# Free tier: 1000 checks/day with API key (key optional for basic check)
# API docs: https://docs.abuseipdb.com/
#
# Returned JSON fields:
#   provider      string  "abuseipdb"
#   ip            string  queried IP
#   score         int     0-100 (abuse confidence %)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if any abuse reports
#   reports       int     number of abuse reports
#   categories    array   abuse category IDs
#   country       string  ISO country code
#   isp           string  ISP name
#   domain        string  associated domain
#   is_tor        bool    Tor exit node flag
#   is_proxy      bool    proxy/VPN flag
#   error         string  error message if failed (absent on success)
#   raw           object  full API response

set -euo pipefail

readonly PROVIDER_NAME="abuseipdb"
readonly PROVIDER_DISPLAY="AbuseIPDB"
readonly API_BASE="https://api.abuseipdb.com/api/v2"
readonly DEFAULT_TIMEOUT=15

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

# Risk level mapping based on abuse confidence score
score_to_risk() {
	local score="$1"
	if [[ "$score" -ge 75 ]]; then
		echo "critical"
	elif [[ "$score" -ge 50 ]]; then
		echo "high"
	elif [[ "$score" -ge 25 ]]; then
		echo "medium"
	elif [[ "$score" -ge 5 ]]; then
		echo "low"
	else
		echo "clean"
	fi
	return 0
}

# Output error JSON
error_json() {
	local ip="$1"
	local msg="$2"
	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--arg error "$msg" \
		'{provider: $provider, ip: $ip, error: $error, is_listed: false, score: 0, risk_level: "unknown"}'
	return 0
}

# Parse --api-key and --timeout flags from remaining args.
# Outputs: "api_key=<value>" and "timeout=<value>" lines for eval.
_parse_check_args() {
	local api_key="${ABUSEIPDB_API_KEY:-}"
	local timeout="$DEFAULT_TIMEOUT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--api-key)
			[[ $# -lt 2 ]] && {
				echo "Error: --api-key requires a value" >&2
				return 1
			}
			api_key="$2"
			shift 2
			;;
		--timeout)
			[[ $# -lt 2 ]] && {
				echo "Error: --timeout requires a value" >&2
				return 1
			}
			timeout="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	printf 'api_key=%s\ntimeout=%s\n' "$api_key" "$timeout"
	return 0
}

# Perform the HTTP request to AbuseIPDB.
# Args: <ip> <api_key> <timeout>
# Outputs: "<http_code> <response_body>" to stdout (space-separated on first line,
# then the body follows — written to a temp file path printed on stdout).
# Returns 0 on curl success, 1 on curl failure.
_fetch_abuseipdb() {
	local ip="$1"
	local api_key="$2"
	local timeout="$3"

	local tmp_body
	tmp_body=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '${tmp_body}'" RETURN

	local http_code
	http_code=$(curl -s -o "$tmp_body" -w '%{http_code}' \
		--max-time "$timeout" \
		-H "Key: ${api_key}" \
		-H "Accept: application/json" \
		-G \
		--data-urlencode "ipAddress=${ip}" \
		--data-urlencode "maxAgeInDays=90" \
		--data-urlencode "verbose" \
		"${API_BASE}/check" 2>/dev/null) || {
		rm -f "$tmp_body"
		return 1
	}

	local response
	response=$(cat "$tmp_body")
	rm -f "$tmp_body"

	# Handle HTTP 429 rate limiting
	if [[ "$http_code" == "429" ]]; then
		local retry_after
		retry_after=$(printf '%s' "$response" | jq -r '.errors[0].detail // empty' 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "60")
		[[ -z "$retry_after" ]] && retry_after=60
		jq -n \
			--arg provider "$PROVIDER_NAME" \
			--arg ip "$ip" \
			--argjson retry_after "$retry_after" \
			'{provider: $provider, ip: $ip, error: "rate_limited", retry_after: $retry_after, is_listed: false, score: 0, risk_level: "unknown"}'
		return 0
	fi

	# Handle other HTTP errors
	if [[ "$http_code" -ge 400 ]]; then
		error_json "$ip" "HTTP ${http_code}"
		return 0
	fi

	# Signal success with response body on stdout for caller to consume
	printf '%s' "$response"
	return 0
}

# Parse a successful AbuseIPDB JSON response and emit the normalised result JSON.
# Args: <ip> <response_body>
_parse_check_response() {
	local ip="$1"
	local response="$2"

	# Validate JSON
	if ! printf '%s' "$response" | jq empty 2>/dev/null; then
		error_json "$ip" "invalid JSON response"
		return 0
	fi

	# Check for API errors
	local api_error
	api_error=$(printf '%s' "$response" | jq -r '.errors[0].detail // empty' 2>/dev/null || true)
	if [[ -n "$api_error" ]]; then
		# Check if error message indicates rate limiting
		if [[ "$api_error" == *"rate limit"* || "$api_error" == *"quota"* || "$api_error" == *"exceeded"* ]]; then
			jq -n \
				--arg provider "$PROVIDER_NAME" \
				--arg ip "$ip" \
				'{provider: $provider, ip: $ip, error: "rate_limited", retry_after: 60, is_listed: false, score: 0, risk_level: "unknown"}'
			return 0
		fi
		error_json "$ip" "$api_error"
		return 0
	fi

	local data
	data=$(printf '%s' "$response" | jq '.data // {}')

	local score is_listed reports country isp domain is_tor is_proxy
	score=$(printf '%s' "$data" | jq -r '.abuseConfidenceScore // 0')
	is_listed=$(printf '%s' "$data" | jq -r 'if .totalReports > 0 then true else false end')
	reports=$(printf '%s' "$data" | jq -r '.totalReports // 0')
	country=$(printf '%s' "$data" | jq -r '.countryCode // "unknown"')
	isp=$(printf '%s' "$data" | jq -r '.isp // "unknown"')
	domain=$(printf '%s' "$data" | jq -r '.domain // "unknown"')
	is_tor=$(printf '%s' "$data" | jq -r '.isTor // false')
	is_proxy=$(printf '%s' "$data" | jq -r 'if .usageType == "VPN Service" or .usageType == "Proxy" then true else false end')

	local risk_level
	risk_level=$(score_to_risk "${score%.*}")

	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--argjson score "$score" \
		--arg risk_level "$risk_level" \
		--argjson is_listed "$is_listed" \
		--argjson reports "$reports" \
		--arg country "$country" \
		--arg isp "$isp" \
		--arg domain "$domain" \
		--argjson is_tor "$is_tor" \
		--argjson is_proxy "$is_proxy" \
		--argjson raw "$data" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            reports: $reports,
            country: $country,
            isp: $isp,
            domain: $domain,
            is_tor: $is_tor,
            is_proxy: $is_proxy,
            raw: $raw
        }'
	return 0
}

# Main check function
cmd_check() {
	local ip="$1"
	shift

	# Parse flags into local variables
	local parsed_args api_key timeout
	parsed_args=$(_parse_check_args "$@") || return 1
	api_key=$(printf '%s' "$parsed_args" | grep '^api_key=' | cut -d= -f2-)
	timeout=$(printf '%s' "$parsed_args" | grep '^timeout=' | cut -d= -f2-)

	if [[ -z "$api_key" ]]; then
		error_json "$ip" "ABUSEIPDB_API_KEY not set — free tier requires API key (1000/day free at abuseipdb.com)"
		return 0
	fi

	local response
	response=$(_fetch_abuseipdb "$ip" "$api_key" "$timeout") || {
		error_json "$ip" "curl request failed"
		return 0
	}

	# _fetch_abuseipdb emits final JSON directly for rate-limit/HTTP-error cases;
	# if response is already a JSON object with an "error" or "provider" key, pass through.
	if printf '%s' "$response" | jq -e 'has("provider")' >/dev/null 2>&1; then
		printf '%s\n' "$response"
		return 0
	fi

	_parse_check_response "$ip" "$response"
	return 0
}

# Provider info
cmd_info() {
	jq -n \
		--arg name "$PROVIDER_NAME" \
		--arg display "$PROVIDER_DISPLAY" \
		'{
            name: $name,
            display: $display,
            requires_key: true,
            key_env: "ABUSEIPDB_API_KEY",
            free_tier: "1000 checks/day",
            url: "https://www.abuseipdb.com/",
            api_docs: "https://docs.abuseipdb.com/"
        }'
	return 0
}

# Dispatch
case "${1:-}" in
check)
	shift
	cmd_check "$@"
	;;
info)
	cmd_info
	;;
*)
	echo "Usage: $(basename "$0") check <ip> [--api-key <key>] [--timeout <s>]" >&2
	echo "       $(basename "$0") info" >&2
	exit 1
	;;
esac
