#!/usr/bin/env bash
# ip-rep-blocklistde.sh — Blocklist.de provider for ip-reputation-helper.sh
# Interface: check <ip> → JSON result on stdout
# Free tier: No key required, open API
# API docs: https://www.blocklist.de/en/api.html
#
# Blocklist.de tracks IPs that have attacked servers (SSH brute force,
# FTP attacks, web exploits, spam, etc.) reported by fail2ban users.
#
# Returned JSON fields:
#   provider      string  "blocklistde"
#   ip            string  queried IP
#   score         int     0-100 (derived from attack count)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if in attack database
#   attacks       int     number of attacks reported
#   reports       int     number of reports
#   attack_types  array   types of attacks (ssh, ftp, web, etc.)
#   error         string  error message if failed (absent on success)
#   raw           object  raw API response

set -euo pipefail

readonly PROVIDER_NAME="blocklistde"
readonly PROVIDER_DISPLAY="Blocklist.de"
readonly API_BASE="https://api.blocklist.de/api.php"
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

# Derive score from attack count
attacks_to_score() {
	local attacks="$1"
	if [[ "$attacks" -ge 100 ]]; then
		echo 90
	elif [[ "$attacks" -ge 50 ]]; then
		echo 75
	elif [[ "$attacks" -ge 20 ]]; then
		echo 60
	elif [[ "$attacks" -ge 5 ]]; then
		echo 40
	elif [[ "$attacks" -ge 1 ]]; then
		echo 25
	else
		echo 0
	fi
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

	# Blocklist.de API returns plain text: "attacks: N\nreports: M\n" or "listed: 0"
	local response
	response=$(curl -sf \
		--max-time "$timeout" \
		"${API_BASE}?ip=${ip}&txt=1" 2>/dev/null) || {
		error_json "$ip" "curl request failed"
		return 0
	}

	# Parse response — may be plain text or HTML with <br /> tags
	# Normalize: strip HTML tags, convert <br /> to newlines
	local normalized
	normalized=$(echo "$response" | sed 's/<br[[:space:]]*\/?>/\n/g' | sed 's/<[^>]*>//g')

	local attacks=0
	local reports=0
	local is_listed=false

	if echo "$normalized" | grep -q "listed: 0"; then
		is_listed=false
		attacks=0
		reports=0
	elif echo "$normalized" | grep -q "attacks:"; then
		# Extract numbers after "attacks:" and "reports:" labels
		attacks=$(echo "$normalized" | grep -oE 'attacks:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' || echo "0")
		reports=$(echo "$normalized" | grep -oE 'reports:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' || echo "0")
		attacks="${attacks:-0}"
		reports="${reports:-0}"
		if [[ "$attacks" -gt 0 || "$reports" -gt 0 ]]; then
			is_listed=true
		else
			is_listed=false
		fi
	else
		# Unexpected response format — treat as error
		error_json "$ip" "unexpected response format: ${response:0:100}"
		return 0
	fi

	local score
	score=$(attacks_to_score "$attacks")

	local risk_level
	risk_level=$(score_to_risk "$score")

	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--argjson score "$score" \
		--arg risk_level "$risk_level" \
		--argjson is_listed "$is_listed" \
		--argjson attacks "$attacks" \
		--argjson reports "$reports" \
		--arg raw_response "$response" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            attacks: $attacks,
            reports: $reports,
            raw: {response: $raw_response}
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
            url: "https://www.blocklist.de/",
            api_docs: "https://www.blocklist.de/en/api.html"
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
