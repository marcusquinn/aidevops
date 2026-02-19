#!/usr/bin/env bash
# ip-rep-iphub.sh — IP Hub provider for ip-reputation-helper.sh
# Interface: check <ip> [--api-key <key>] → JSON result on stdout
# Free tier: 1000 checks/day with API key
# API docs: https://iphub.info/api
#
# Returned JSON fields:
#   provider      string  "iphub"
#   ip            string  queried IP
#   score         int     0-100 (derived from block value)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if block=1 (recommended to block)
#   is_proxy      bool    true if block=1 (non-residential/hosting; block=2 is caution only)
#   block         int     0=residential, 1=non-residential/hosting, 2=non-residential+residential
#   country       string  ISO country code
#   asn           int     ASN number
#   isp           string  ISP name
#   error         string  error message if failed (absent on success)
#   raw           object  full API response

set -euo pipefail

readonly PROVIDER_NAME="iphub"
readonly PROVIDER_DISPLAY="IP Hub"
readonly API_BASE="https://v2.api.iphub.info/ip"
readonly DEFAULT_TIMEOUT=15

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

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

# Map block value to score
# block=0: residential (clean)
# block=1: non-residential/hosting/VPN (recommended to block)
# block=2: non-residential + residential (mixed, caution)
block_to_score() {
	local block="$1"
	case "$block" in
	0) echo "0" ;;
	1) echo "75" ;;
	2) echo "40" ;;
	*) echo "0" ;;
	esac
	return 0
}

# Risk level from score
score_to_risk() {
	local score="$1"
	if [[ "$score" -ge 75 ]]; then
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

# Main check function
cmd_check() {
	local ip="$1"
	local api_key="${IPHUB_API_KEY:-}"
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

	if [[ -z "$api_key" ]]; then
		error_json "$ip" "IPHUB_API_KEY not set — 1000 checks/day free at iphub.info"
		return 0
	fi

	local response
	response=$(curl -sf \
		--max-time "$timeout" \
		-H "X-Key: ${api_key}" \
		-H "Accept: application/json" \
		"${API_BASE}/${ip}" \
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

	local block country asn isp
	block=$(echo "$response" | jq -r '.block // 0')
	country=$(echo "$response" | jq -r '.countryCode // "unknown"')
	asn=$(echo "$response" | jq -r '.asn // 0')
	isp=$(echo "$response" | jq -r '.isp // "unknown"')

	local score
	score=$(block_to_score "$block")
	local risk_level
	risk_level=$(score_to_risk "$score")

	local is_listed is_proxy
	if [[ "$block" -eq 1 ]]; then
		is_listed="true"
		is_proxy="true"
	else
		is_listed="false"
		is_proxy="false"
	fi

	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--argjson score "$score" \
		--arg risk_level "$risk_level" \
		--argjson is_listed "$is_listed" \
		--argjson is_proxy "$is_proxy" \
		--argjson block "$block" \
		--arg country "$country" \
		--argjson asn "$asn" \
		--arg isp "$isp" \
		--argjson raw "$response" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            is_proxy: $is_proxy,
            block: $block,
            country: $country,
            asn: $asn,
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
            requires_key: true,
            key_env: "IPHUB_API_KEY",
            free_tier: "1000 checks/day",
            url: "https://iphub.info/",
            api_docs: "https://iphub.info/api"
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
