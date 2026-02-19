#!/usr/bin/env bash
# ip-rep-stopforumspam.sh — StopForumSpam provider for ip-reputation-helper.sh
# Interface: check <ip> → JSON result on stdout
# Free tier: No key required, open API
# API docs: https://www.stopforumspam.com/usage
#
# Returned JSON fields:
#   provider      string  "stopforumspam"
#   ip            string  queried IP
#   score         int     0-100 (derived from frequency/confidence)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if in spammer database
#   frequency     int     number of times seen as spammer
#   confidence    float   confidence score (0-100) from SFS
#   last_seen     string  ISO date of last spam activity
#   error         string  error message if failed (absent on success)
#   raw           object  full API response

set -euo pipefail

readonly PROVIDER_NAME="stopforumspam"
readonly PROVIDER_DISPLAY="StopForumSpam"
readonly API_BASE="https://api.stopforumspam.org/api"
readonly DEFAULT_TIMEOUT=15

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

# Risk level from confidence and frequency
derive_score() {
	local confidence="$1"
	local frequency="$2"

	# Use confidence as primary signal, boost by frequency
	local score="${confidence%.*}"

	# Frequency boost: high frequency = more certain threat
	if [[ "$frequency" -ge 100 ]]; then
		score=$((score > 90 ? 100 : score + 10))
	elif [[ "$frequency" -ge 10 ]]; then
		score=$((score > 95 ? 100 : score + 5))
	fi

	echo "$score"
	return 0
}

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

# Main check function
cmd_check() {
	local ip="$1"
	local timeout="$DEFAULT_TIMEOUT"

	shift
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--timeout)
			timeout="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	local response
	response=$(curl -sf \
		--max-time "$timeout" \
		-H "Accept: application/json" \
		"${API_BASE}?ip=${ip}&json" 2>/dev/null) || {
		error_json "$ip" "curl request failed"
		return 0
	}

	if ! echo "$response" | jq empty 2>/dev/null; then
		error_json "$ip" "invalid JSON response"
		return 0
	fi

	# Check for API-level success
	local api_success
	api_success=$(echo "$response" | jq -r '.success // 1')
	if [[ "$api_success" == "0" ]]; then
		local api_error
		api_error=$(echo "$response" | jq -r '.error // "unknown error"')
		error_json "$ip" "$api_error"
		return 0
	fi

	local ip_data
	ip_data=$(echo "$response" | jq '.ip // {}')

	local is_listed frequency confidence last_seen
	is_listed=$(echo "$ip_data" | jq -r 'if .appears == 1 then true else false end')
	frequency=$(echo "$ip_data" | jq -r '.frequency // 0')
	confidence=$(echo "$ip_data" | jq -r '.confidence // 0')
	last_seen=$(echo "$ip_data" | jq -r '.lastseen // "never"')

	local score
	score=$(derive_score "$confidence" "${frequency%.*}")

	local risk_level
	risk_level=$(score_to_risk "$score")

	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--argjson score "$score" \
		--arg risk_level "$risk_level" \
		--argjson is_listed "$is_listed" \
		--argjson frequency "$frequency" \
		--argjson confidence "$confidence" \
		--arg last_seen "$last_seen" \
		--argjson raw "$ip_data" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            frequency: $frequency,
            confidence: $confidence,
            last_seen: $last_seen,
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
            key_env: "",
            free_tier: "Unlimited, no key required",
            url: "https://www.stopforumspam.com/",
            api_docs: "https://www.stopforumspam.com/usage"
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
	echo "Usage: $(basename "$0") check <ip> [--timeout <s>]" >&2
	echo "       $(basename "$0") info" >&2
	exit 1
	;;
esac
