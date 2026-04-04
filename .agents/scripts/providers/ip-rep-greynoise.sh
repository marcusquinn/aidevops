#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# ip-rep-greynoise.sh — GreyNoise provider for ip-reputation-helper.sh
# Interface: check <ip> [--api-key <key>] → JSON result on stdout
# Free tier: Community API (no key) — limited data; full API requires key
# API docs: https://docs.greynoise.io/reference/get_v3-community-ip
#
# Returned JSON fields:
#   provider      string  "greynoise"
#   ip            string  queried IP
#   score         int     0-100 (derived from noise/riot/classification)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if noise=true and classification=malicious
#   is_noise      bool    seen scanning the internet
#   is_riot       bool    known benign service (Google, Cloudflare, etc.)
#   classification string malicious/benign/unknown
#   name          string  actor/organization name
#   link          string  GreyNoise analysis URL
#   error         string  error message if failed (absent on success)
#   raw           object  full API response

set -euo pipefail

readonly PROVIDER_NAME="greynoise"
readonly PROVIDER_DISPLAY="GreyNoise"
readonly API_BASE_COMMUNITY="https://api.greynoise.io/v3/community"
readonly API_BASE_FULL="https://api.greynoise.io/v3/noise/context"
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

# Derive risk score from GreyNoise classification
classification_to_score() {
	local classification="$1"
	local is_noise="$2"
	local is_riot="$3"

	if [[ "$is_riot" == "true" ]]; then
		echo "0"
	elif [[ "$classification" == "malicious" ]]; then
		echo "85"
	elif [[ "$is_noise" == "true" && "$classification" == "unknown" ]]; then
		echo "40"
	elif [[ "$is_noise" == "true" ]]; then
		echo "20"
	else
		echo "0"
	fi
	return 0
}

# Risk level from score
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

# Parse --api-key and --timeout flags; sets _api_key and _timeout in caller scope
# Usage: _parse_check_args "$@"; sets exit status 1 on bad args
_parse_check_args() {
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
	return 0
}

# Fetch raw JSON from GreyNoise API; prints response to stdout
# Usage: _fetch_greynoise <ip> <api_key> <timeout>
# On curl failure: emits error_json and returns 1
_fetch_greynoise() {
	local ip="$1"
	local api_key="$2"
	local timeout="$3"
	local api_url
	local response

	if [[ -n "$api_key" ]]; then
		api_url="${API_BASE_FULL}/${ip}"
		response=$(curl -sf \
			--max-time "$timeout" \
			-H "Accept: application/json" \
			-H "key: ${api_key}" \
			"$api_url" \
			2>/dev/null) || {
			error_json "$ip" "curl request failed"
			return 1
		}
	else
		api_url="${API_BASE_COMMUNITY}/${ip}"
		response=$(curl -sf \
			--max-time "$timeout" \
			-H "Accept: application/json" \
			"$api_url" \
			2>/dev/null) || {
			error_json "$ip" "curl request failed"
			return 1
		}
	fi

	echo "$response"
	return 0
}

# Validate JSON response and check for API-level errors
# Usage: _validate_response <ip> <response>
# On invalid JSON or API error: emits error_json and returns 1
_validate_response() {
	local ip="$1"
	local response="$2"

	if ! echo "$response" | jq empty 2>/dev/null; then
		error_json "$ip" "invalid JSON response"
		return 1
	fi

	local api_message
	api_message=$(echo "$response" | jq -r '.message // empty' 2>/dev/null || true)
	if [[ -n "$api_message" ]] && echo "$response" | jq -e '.noise == null' &>/dev/null; then
		error_json "$ip" "$api_message"
		return 1
	fi

	return 0
}

# Extract fields from response and compute score/risk/is_listed
# Usage: _extract_fields <response>
# Outputs: tab-separated is_noise, is_riot, classification, name, link, score, risk_level, is_listed
_extract_fields() {
	local response="$1"
	local is_noise is_riot classification name link score risk_level is_listed

	is_noise=$(echo "$response" | jq -r '.noise // false')
	is_riot=$(echo "$response" | jq -r '.riot // false')
	classification=$(echo "$response" | jq -r '.classification // "unknown"')
	name=$(echo "$response" | jq -r '.name // "unknown"')
	link=$(echo "$response" | jq -r '.link // ""')

	score=$(classification_to_score "$classification" "$is_noise" "$is_riot")
	risk_level=$(score_to_risk "$score")

	if [[ "$classification" == "malicious" && "$is_noise" == "true" ]]; then
		is_listed="true"
	else
		is_listed="false"
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$is_noise" "$is_riot" "$classification" "$name" "$link" \
		"$score" "$risk_level" "$is_listed"
	return 0
}

# Assemble and emit the final result JSON
# Usage: _build_result_json <ip> <response> <is_noise> <is_riot> <classification> \
#                           <name> <link> <score> <risk_level> <is_listed>
_build_result_json() {
	local ip="$1"
	local response="$2"
	local is_noise="$3"
	local is_riot="$4"
	local classification="$5"
	local name="$6"
	local link="$7"
	local score="$8"
	local risk_level="$9"
	local is_listed="${10}"

	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--argjson score "$score" \
		--arg risk_level "$risk_level" \
		--argjson is_listed "$is_listed" \
		--argjson is_noise "$is_noise" \
		--argjson is_riot "$is_riot" \
		--arg classification "$classification" \
		--arg name "$name" \
		--arg link "$link" \
		--argjson raw "$response" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            is_noise: $is_noise,
            is_riot: $is_riot,
            classification: $classification,
            name: $name,
            link: $link,
            raw: $raw
        }'
	return 0
}

# Main check function — orchestrates sub-functions
cmd_check() {
	local ip="$1"
	local _api_key="${GREYNOISE_API_KEY:-}"
	local _timeout="$DEFAULT_TIMEOUT"

	shift
	_parse_check_args "$@" || return 1

	local response
	response=$(_fetch_greynoise "$ip" "$_api_key" "$_timeout") || return 0

	_validate_response "$ip" "$response" || return 0

	local fields
	fields=$(_extract_fields "$response")

	local is_noise is_riot classification name link score risk_level is_listed
	IFS=$'\t' read -r is_noise is_riot classification name link score risk_level is_listed <<<"$fields"

	_build_result_json "$ip" "$response" \
		"$is_noise" "$is_riot" "$classification" "$name" "$link" \
		"$score" "$risk_level" "$is_listed"
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
            key_env: "GREYNOISE_API_KEY",
            free_tier: "Community API (no key) or full API with key",
            url: "https://www.greynoise.io/",
            api_docs: "https://docs.greynoise.io/"
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
