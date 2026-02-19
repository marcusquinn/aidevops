#!/usr/bin/env bash
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

# Main check function
cmd_check() {
	local ip="$1"
	local api_key="${ABUSEIPDB_API_KEY:-}"
	local timeout="$DEFAULT_TIMEOUT"

	# Parse optional flags
	shift
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

	if [[ -z "$api_key" ]]; then
		error_json "$ip" "ABUSEIPDB_API_KEY not set — free tier requires API key (1000/day free at abuseipdb.com)"
		return 0
	fi

	local response
	response=$(curl -sf \
		--max-time "$timeout" \
		-H "Key: ${api_key}" \
		-H "Accept: application/json" \
		-G \
		--data-urlencode "ipAddress=${ip}" \
		--data-urlencode "maxAgeInDays=90" \
		--data-urlencode "verbose" \
		"${API_BASE}/check" 2>/dev/null) || {
		error_json "$ip" "curl request failed"
		return 0
	}

	# Validate JSON
	if ! echo "$response" | jq empty 2>/dev/null; then
		error_json "$ip" "invalid JSON response"
		return 0
	fi

	# Check for API errors
	local api_error
	api_error=$(echo "$response" | jq -r '.errors[0].detail // empty' 2>/dev/null || true)
	if [[ -n "$api_error" ]]; then
		error_json "$ip" "$api_error"
		return 0
	fi

	local data
	data=$(echo "$response" | jq '.data // {}')

	local score is_listed reports country isp domain is_tor is_proxy
	score=$(echo "$data" | jq -r '.abuseConfidenceScore // 0')
	is_listed=$(echo "$data" | jq -r 'if .totalReports > 0 then true else false end')
	reports=$(echo "$data" | jq -r '.totalReports // 0')
	country=$(echo "$data" | jq -r '.countryCode // "unknown"')
	isp=$(echo "$data" | jq -r '.isp // "unknown"')
	domain=$(echo "$data" | jq -r '.domain // "unknown"')
	is_tor=$(echo "$data" | jq -r '.isTor // false')
	is_proxy=$(echo "$data" | jq -r 'if .usageType == "VPN Service" or .usageType == "Proxy" then true else false end')

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
