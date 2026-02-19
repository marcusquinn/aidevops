#!/usr/bin/env bash
# ip-rep-virustotal.sh — VirusTotal provider for ip-reputation-helper.sh
# Interface: check <ip> [--api-key <key>] → JSON result on stdout
# Free tier: 4 requests/minute, 500/day, 15.5K/month with API key
# API docs: https://developers.virustotal.com/reference/ip-object
#
# Returned JSON fields:
#   provider      string  "virustotal"
#   ip            string  queried IP
#   score         int     0-100 (derived from malicious detection ratio)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if any engine flagged malicious
#   malicious     int     number of engines detecting as malicious
#   suspicious    int     number of engines detecting as suspicious
#   harmless      int     number of engines detecting as harmless
#   undetected    int     number of engines with no detection
#   reputation    int     VT community reputation score
#   as_owner      string  autonomous system owner
#   country       string  ISO country code
#   network       string  network CIDR
#   error         string  error message if failed (absent on success)
#   raw           object  full API response attributes

set -euo pipefail

readonly PROVIDER_NAME="virustotal"
readonly PROVIDER_DISPLAY="VirusTotal"
readonly API_BASE="https://www.virustotal.com/api/v3"
readonly DEFAULT_TIMEOUT=15

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

# Risk level mapping based on malicious detection ratio
# Uses the ratio of malicious detections to total engines
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
	local api_key="${VIRUSTOTAL_API_KEY:-}"
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

	# Try gopass fallback if env var not set
	if [[ -z "$api_key" ]] && command -v gopass &>/dev/null; then
		api_key=$(gopass show -o "aidevops/VIRUSTOTAL_API_KEY" 2>/dev/null || true)
	fi

	if [[ -z "$api_key" ]]; then
		error_json "$ip" "VIRUSTOTAL_API_KEY not set — free tier requires API key (virustotal.com)"
		return 0
	fi

	local response
	response=$(curl -sf \
		--max-time "$timeout" \
		-H "x-apikey: ${api_key}" \
		-H "Accept: application/json" \
		"${API_BASE}/ip_addresses/${ip}" 2>/dev/null) || {
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
	api_error=$(echo "$response" | jq -r '.error.code // empty' 2>/dev/null || true)
	if [[ -n "$api_error" ]]; then
		local api_msg
		api_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"' 2>/dev/null || true)
		error_json "$ip" "${api_error}: ${api_msg}"
		return 0
	fi

	local attrs
	attrs=$(echo "$response" | jq '.data.attributes // {}')

	# Extract analysis stats
	local malicious suspicious harmless undetected
	malicious=$(echo "$attrs" | jq -r '.last_analysis_stats.malicious // 0')
	suspicious=$(echo "$attrs" | jq -r '.last_analysis_stats.suspicious // 0')
	harmless=$(echo "$attrs" | jq -r '.last_analysis_stats.harmless // 0')
	undetected=$(echo "$attrs" | jq -r '.last_analysis_stats.undetected // 0')

	local total=$((malicious + suspicious + harmless + undetected))

	# Calculate score: weighted ratio of malicious+suspicious to total engines
	# malicious counts fully, suspicious counts at half weight
	local score=0
	if [[ "$total" -gt 0 ]]; then
		local weighted=$((malicious * 100 + suspicious * 50))
		score=$((weighted / total))
		# Cap at 100
		if [[ "$score" -gt 100 ]]; then
			score=100
		fi
	fi

	local is_listed=false
	if [[ "$malicious" -gt 0 ]]; then
		is_listed=true
	fi

	local risk_level
	risk_level=$(score_to_risk "$score")

	# Extract metadata
	local reputation as_owner country network
	reputation=$(echo "$attrs" | jq -r '.reputation // 0')
	as_owner=$(echo "$attrs" | jq -r '.as_owner // "unknown"')
	country=$(echo "$attrs" | jq -r '.country // "unknown"')
	network=$(echo "$attrs" | jq -r '.network // "unknown"')

	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--argjson score "$score" \
		--arg risk_level "$risk_level" \
		--argjson is_listed "$is_listed" \
		--argjson malicious "$malicious" \
		--argjson suspicious "$suspicious" \
		--argjson harmless "$harmless" \
		--argjson undetected "$undetected" \
		--argjson reputation "$reputation" \
		--arg as_owner "$as_owner" \
		--arg country "$country" \
		--arg network "$network" \
		--argjson raw "$attrs" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            malicious: $malicious,
            suspicious: $suspicious,
            harmless: $harmless,
            undetected: $undetected,
            reputation: $reputation,
            as_owner: $as_owner,
            country: $country,
            network: $network,
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
            key_env: "VIRUSTOTAL_API_KEY",
            free_tier: "4 req/min, 500/day, 15.5K/month",
            url: "https://www.virustotal.com/",
            api_docs: "https://developers.virustotal.com/reference/ip-object"
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
