#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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

# Parse --api-key and --timeout flags from remaining arguments after ip.
# Prints newline-separated key=value pairs: api_key=<val> and timeout=<val>.
_parse_check_args() {
	local _api_key="${VIRUSTOTAL_API_KEY:-}"
	local _timeout="$DEFAULT_TIMEOUT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--api-key)
			[[ $# -lt 2 ]] && {
				echo "Error: --api-key requires a value" >&2
				return 1
			}
			_api_key="$2"
			shift 2
			;;
		--timeout)
			[[ $# -lt 2 ]] && {
				echo "Error: --timeout requires a value" >&2
				return 1
			}
			_timeout="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	printf 'api_key=%s\ntimeout=%s\n' "$_api_key" "$_timeout"
	return 0
}

# Resolve API key: env var already in _api_key, or fall back to gopass.
# Prints the resolved key (may be empty if unavailable).
_resolve_api_key() {
	local api_key="$1"
	if [[ -z "$api_key" ]] && command -v gopass &>/dev/null; then
		api_key=$(gopass show -o "aidevops/VIRUSTOTAL_API_KEY" 2>/dev/null || true)
	fi
	printf '%s' "$api_key"
	return 0
}

# Fetch VirusTotal API response for an IP.
# On curl failure or API error, prints error JSON and returns 0.
# On success, prints the raw API JSON response.
_fetch_vt_response() {
	local ip="$1"
	local api_key="$2"
	local timeout="$3"

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
	if ! printf '%s' "$response" | jq empty 2>/dev/null; then
		error_json "$ip" "invalid JSON response"
		return 0
	fi

	# Check for API errors
	local api_error
	api_error=$(printf '%s' "$response" | jq -r '.error.code // empty' 2>/dev/null || true)
	if [[ -n "$api_error" ]]; then
		local api_msg
		api_msg=$(printf '%s' "$response" | jq -r '.error.message // "Unknown error"' 2>/dev/null || true)
		error_json "$ip" "${api_error}: ${api_msg}"
		return 0
	fi

	printf '%s' "$response"
	return 0
}

# Calculate threat score (0-100) and detection flags from analysis stats.
# Prints newline-separated key=value pairs for score, is_listed, and engine counts.
_calculate_score() {
	local attrs="$1"

	local malicious suspicious harmless undetected
	malicious=$(printf '%s' "$attrs" | jq -r '.last_analysis_stats.malicious // 0')
	suspicious=$(printf '%s' "$attrs" | jq -r '.last_analysis_stats.suspicious // 0')
	harmless=$(printf '%s' "$attrs" | jq -r '.last_analysis_stats.harmless // 0')
	undetected=$(printf '%s' "$attrs" | jq -r '.last_analysis_stats.undetected // 0')

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

	printf 'score=%s\nis_listed=%s\nmalicious=%s\nsuspicious=%s\nharmless=%s\nundetected=%s\n' \
		"$score" "$is_listed" "$malicious" "$suspicious" "$harmless" "$undetected"
	return 0
}

# Build and output the final result JSON from extracted fields.
_build_result_json() {
	local ip="$1"
	local attrs="$2"
	local score="$3"
	local risk_level="$4"
	local is_listed="$5"
	local malicious="$6"
	local suspicious="$7"
	local harmless="$8"
	local undetected="$9"

	local reputation as_owner country network
	reputation=$(printf '%s' "$attrs" | jq -r '.reputation // 0')
	as_owner=$(printf '%s' "$attrs" | jq -r '.as_owner // "unknown"')
	country=$(printf '%s' "$attrs" | jq -r '.country // "unknown"')
	network=$(printf '%s' "$attrs" | jq -r '.network // "unknown"')

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

# Main check function — orchestrates argument parsing, key resolution,
# HTTP fetch, score calculation, and result assembly.
cmd_check() {
	local ip="$1"
	shift

	# Parse flags
	local parsed api_key timeout
	parsed=$(_parse_check_args "$@") || return 1
	api_key=$(printf '%s' "$parsed" | grep '^api_key=' | cut -d= -f2-)
	timeout=$(printf '%s' "$parsed" | grep '^timeout=' | cut -d= -f2-)

	# Resolve API key (env var → gopass fallback)
	api_key=$(_resolve_api_key "$api_key")
	if [[ -z "$api_key" ]]; then
		error_json "$ip" "VIRUSTOTAL_API_KEY not set — free tier requires API key (virustotal.com)"
		return 0
	fi

	# Fetch and validate response; error JSON already printed on failure
	local response
	response=$(_fetch_vt_response "$ip" "$api_key" "$timeout")
	if printf '%s' "$response" | jq -e '.error' &>/dev/null; then
		printf '%s\n' "$response"
		return 0
	fi

	local attrs
	attrs=$(printf '%s' "$response" | jq '.data.attributes // {}')

	# Calculate score and detection flags
	local calc score is_listed malicious suspicious harmless undetected
	calc=$(_calculate_score "$attrs")
	score=$(printf '%s' "$calc" | grep '^score=' | cut -d= -f2-)
	is_listed=$(printf '%s' "$calc" | grep '^is_listed=' | cut -d= -f2-)
	malicious=$(printf '%s' "$calc" | grep '^malicious=' | cut -d= -f2-)
	suspicious=$(printf '%s' "$calc" | grep '^suspicious=' | cut -d= -f2-)
	harmless=$(printf '%s' "$calc" | grep '^harmless=' | cut -d= -f2-)
	undetected=$(printf '%s' "$calc" | grep '^undetected=' | cut -d= -f2-)

	local risk_level
	risk_level=$(score_to_risk "$score")

	_build_result_json "$ip" "$attrs" "$score" "$risk_level" "$is_listed" \
		"$malicious" "$suspicious" "$harmless" "$undetected"
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
