#!/usr/bin/env bash
# ip-rep-scamalytics.sh — Scamalytics provider for ip-reputation-helper.sh
# Interface: check <ip> [--api-key <key>] → JSON result on stdout
# Free tier: 5000 checks/month with API key
# API docs: https://scamalytics.com/ip/api/docs
#
# Returned JSON fields:
#   provider      string  "scamalytics"
#   ip            string  queried IP
#   score         int     0-100 (fraud score)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if score >= 75
#   is_proxy      bool    proxy detected
#   is_vpn        bool    VPN detected
#   is_tor        bool    Tor exit node
#   is_datacenter bool    datacenter/hosting IP
#   error         string  error message if failed (absent on success)
#   raw           object  full API response

set -euo pipefail

readonly PROVIDER_NAME="scamalytics"
readonly PROVIDER_DISPLAY="Scamalytics"
readonly API_BASE="https://api11.scamalytics.com"
readonly DEFAULT_TIMEOUT=15

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

# Risk level mapping based on fraud score
score_to_risk() {
	local score="$1"
	if [[ "$score" -ge 90 ]]; then
		echo "critical"
	elif [[ "$score" -ge 75 ]]; then
		echo "high"
	elif [[ "$score" -ge 50 ]]; then
		echo "medium"
	elif [[ "$score" -ge 25 ]]; then
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
	local api_key="${SCAMALYTICS_API_KEY:-}"
	local timeout="$DEFAULT_TIMEOUT"

	shift
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--api-key)
			api_key="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$api_key" ]]; then
		error_json "$ip" "SCAMALYTICS_API_KEY not set — 5000 checks/month free at scamalytics.com"
		return 0
	fi

	# Scamalytics API: GET /v1/{api_key}/?ip={ip}
	local response
	response=$(curl -sf \
		--max-time "$timeout" \
		-H "Accept: application/json" \
		"${API_BASE}/v1/${api_key}/?ip=${ip}" \
		2>/dev/null) || {
		error_json "$ip" "curl request failed"
		return 0
	}

	if ! echo "$response" | jq empty 2>/dev/null; then
		error_json "$ip" "invalid JSON response"
		return 0
	fi

	# Check for API errors
	local api_error
	api_error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null || true)
	if [[ -n "$api_error" ]]; then
		error_json "$ip" "$api_error"
		return 0
	fi

	local score is_proxy is_vpn is_tor is_datacenter
	score=$(echo "$response" | jq -r '.score // 0')
	is_proxy=$(echo "$response" | jq -r 'if .proxy == "yes" then true else false end')
	is_vpn=$(echo "$response" | jq -r 'if .vpn == "yes" then true else false end')
	is_tor=$(echo "$response" | jq -r 'if .tor == "yes" then true else false end')
	is_datacenter=$(echo "$response" | jq -r 'if .datacenter == "yes" then true else false end')

	local score_int
	score_int="${score%.*}"
	local risk_level
	risk_level=$(score_to_risk "$score_int")

	local is_listed
	if [[ "$score_int" -ge 75 ]]; then
		is_listed="true"
	else
		is_listed="false"
	fi

	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--argjson score "$score" \
		--arg risk_level "$risk_level" \
		--argjson is_listed "$is_listed" \
		--argjson is_proxy "$is_proxy" \
		--argjson is_vpn "$is_vpn" \
		--argjson is_tor "$is_tor" \
		--argjson is_datacenter "$is_datacenter" \
		--argjson raw "$response" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            is_proxy: $is_proxy,
            is_vpn: $is_vpn,
            is_tor: $is_tor,
            is_datacenter: $is_datacenter,
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
            key_env: "SCAMALYTICS_API_KEY",
            free_tier: "5000 checks/month",
            url: "https://scamalytics.com/",
            api_docs: "https://scamalytics.com/ip/api/docs"
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
