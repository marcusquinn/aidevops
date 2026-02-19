#!/usr/bin/env bash
# ip-rep-proxycheck.sh — ProxyCheck.io provider for ip-reputation-helper.sh
# Interface: check <ip> [--api-key <key>] → JSON result on stdout
# Free tier: 1000 req/day without key, 100/day with free key (more with paid)
# API docs: https://proxycheck.io/api/
#
# Returned JSON fields:
#   provider      string  "proxycheck"
#   ip            string  queried IP
#   score         int     0-100 (risk score)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if proxy/VPN detected
#   is_proxy      bool    proxy detected
#   is_vpn        bool    VPN detected
#   is_tor        bool    Tor exit node
#   proxy_type    string  type of proxy if detected
#   country       string  ISO country code
#   isp           string  ISP name
#   error         string  error message if failed (absent on success)
#   raw           object  full API response

set -euo pipefail

readonly PROVIDER_NAME="proxycheck"
readonly PROVIDER_DISPLAY="ProxyCheck.io"
readonly API_BASE="https://proxycheck.io/v2"
readonly DEFAULT_TIMEOUT=15

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

# Risk level mapping based on risk score
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
	local api_key="${PROXYCHECK_API_KEY:-}"
	local timeout="$DEFAULT_TIMEOUT"

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

	# Build URL — key is optional for free tier
	local url="${API_BASE}/${ip}?vpn=1&risk=1&port=1&seen=1&days=7&tag=ip-reputation-helper"
	if [[ -n "$api_key" ]]; then
		url="${url}&key=${api_key}"
	fi

	local response
	response=$(curl -sf \
		--max-time "$timeout" \
		-H "Accept: application/json" \
		"$url" 2>/dev/null) || {
		error_json "$ip" "curl request failed"
		return 0
	}

	if ! echo "$response" | jq empty 2>/dev/null; then
		error_json "$ip" "invalid JSON response"
		return 0
	fi

	# Check API status
	local status
	status=$(echo "$response" | jq -r '.status // "ok"')
	if [[ "$status" == "error" ]]; then
		local api_error
		api_error=$(echo "$response" | jq -r '.message // "unknown error"')
		error_json "$ip" "$api_error"
		return 0
	fi

	# ProxyCheck returns data under the IP key
	local data
	data=$(echo "$response" | jq --arg ip "$ip" '.[$ip] // {}')

	local score is_proxy is_vpn is_tor proxy_type country isp
	score=$(echo "$data" | jq -r '.risk // 0')
	is_proxy=$(echo "$data" | jq -r 'if .proxy == "yes" then true else false end')
	is_vpn=$(echo "$data" | jq -r 'if .type == "VPN" then true else false end')
	is_tor=$(echo "$data" | jq -r 'if .type == "TOR" then true else false end')
	proxy_type=$(echo "$data" | jq -r '.type // "none"')
	country=$(echo "$data" | jq -r '.isocode // "unknown"')
	isp=$(echo "$data" | jq -r '.provider // "unknown"')

	local is_listed
	is_listed=$(echo "$data" | jq -r 'if .proxy == "yes" then true else false end')

	local risk_level
	risk_level=$(score_to_risk "${score%.*}")

	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--argjson score "$score" \
		--arg risk_level "$risk_level" \
		--argjson is_listed "$is_listed" \
		--argjson is_proxy "$is_proxy" \
		--argjson is_vpn "$is_vpn" \
		--argjson is_tor "$is_tor" \
		--arg proxy_type "$proxy_type" \
		--arg country "$country" \
		--arg isp "$isp" \
		--argjson raw "$data" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            is_proxy: $is_proxy,
            is_vpn: $is_vpn,
            is_tor: $is_tor,
            proxy_type: $proxy_type,
            country: $country,
            isp: $isp,
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
            requires_key: false,
            key_env: "PROXYCHECK_API_KEY",
            free_tier: "1000 req/day (no key), more with free key",
            url: "https://proxycheck.io/",
            api_docs: "https://proxycheck.io/api/"
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
