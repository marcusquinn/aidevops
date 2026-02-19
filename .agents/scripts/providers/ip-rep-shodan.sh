#!/usr/bin/env bash
# ip-rep-shodan.sh — Shodan provider for ip-reputation-helper.sh
# Interface: check <ip> [--api-key <key>] → JSON result on stdout
# Free tier: 1 query credit/month (Shodan Freelancer plan needed for more)
# API docs: https://developer.shodan.io/api
#
# Returned JSON fields:
#   provider      string  "shodan"
#   ip            string  queried IP
#   score         int     0-100 (derived from open ports, vulns, tags)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if score >= 50
#   open_ports    array   list of open port numbers
#   vulns         array   CVE IDs of known vulnerabilities
#   tags          array   Shodan tags (e.g., "vpn", "tor", "cloud")
#   org           string  organization name
#   country       string  ISO country code
#   is_tor        bool    true if "tor" in tags
#   is_vpn        bool    true if "vpn" in tags
#   error         string  error message if failed (absent on success)
#   raw           object  full API response

set -euo pipefail

readonly PROVIDER_NAME="shodan"
readonly PROVIDER_DISPLAY="Shodan"
readonly API_BASE="https://api.shodan.io/shodan/host"
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

# Derive risk score from Shodan data
compute_score() {
	local open_ports_count="$1"
	local vuln_count="$2"
	local has_tor="$3"
	local has_vpn="$4"

	local score=0

	# Vulnerabilities are the strongest signal
	if [[ "$vuln_count" -ge 5 ]]; then
		score=$((score + 50))
	elif [[ "$vuln_count" -ge 2 ]]; then
		score=$((score + 35))
	elif [[ "$vuln_count" -ge 1 ]]; then
		score=$((score + 20))
	fi

	# Many open ports suggest scanning target or misconfigured server
	if [[ "$open_ports_count" -ge 20 ]]; then
		score=$((score + 20))
	elif [[ "$open_ports_count" -ge 10 ]]; then
		score=$((score + 10))
	fi

	# Tor/VPN flags
	[[ "$has_tor" == "true" ]] && score=$((score + 20))
	[[ "$has_vpn" == "true" ]] && score=$((score + 10))

	# Cap at 100
	[[ "$score" -gt 100 ]] && score=100

	echo "$score"
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

# Main check function
cmd_check() {
	local ip="$1"
	local api_key="${SHODAN_API_KEY:-}"
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
		error_json "$ip" "SHODAN_API_KEY not set — free API key available at shodan.io (limited credits)"
		return 0
	fi

	local response
	response=$(curl -sf \
		--max-time "$timeout" \
		-H "Accept: application/json" \
		"${API_BASE}/${ip}?key=${api_key}&minify=false" \
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
		# 404 = IP not in Shodan (clean, not an error)
		if [[ "$api_error" == *"No information available"* ]]; then
			jq -n \
				--arg provider "$PROVIDER_NAME" \
				--arg ip "$ip" \
				'{provider: $provider, ip: $ip, score: 0, risk_level: "clean", is_listed: false,
                  open_ports: [], vulns: [], tags: [], org: "unknown", country: "unknown",
                  is_tor: false, is_vpn: false, note: "IP not indexed by Shodan"}'
			return 0
		fi
		error_json "$ip" "$api_error"
		return 0
	fi

	local open_ports vulns tags org country
	open_ports=$(echo "$response" | jq -r '[.ports // [] | .[]]')
	vulns=$(echo "$response" | jq -r '[.vulns // {} | keys | .[]]')
	tags=$(echo "$response" | jq -r '[.tags // [] | .[]]')
	org=$(echo "$response" | jq -r '.org // "unknown"')
	country=$(echo "$response" | jq -r '.country_code // "unknown"')

	local open_ports_count vuln_count
	open_ports_count=$(echo "$open_ports" | jq 'length')
	vuln_count=$(echo "$vulns" | jq 'length')

	local is_tor is_vpn
	is_tor=$(echo "$tags" | jq -r 'if index("tor") != null then true else false end')
	is_vpn=$(echo "$tags" | jq -r 'if index("vpn") != null then true else false end')

	local score
	score=$(compute_score "$open_ports_count" "$vuln_count" "$is_tor" "$is_vpn")
	local risk_level
	risk_level=$(score_to_risk "$score")

	local is_listed
	if [[ "$score" -ge 50 ]]; then
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
		--argjson open_ports "$open_ports" \
		--argjson vulns "$vulns" \
		--argjson tags "$tags" \
		--arg org "$org" \
		--arg country "$country" \
		--argjson is_tor "$is_tor" \
		--argjson is_vpn "$is_vpn" \
		--argjson raw "$response" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            open_ports: $open_ports,
            vulns: $vulns,
            tags: $tags,
            org: $org,
            country: $country,
            is_tor: $is_tor,
            is_vpn: $is_vpn,
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
            key_env: "SHODAN_API_KEY",
            free_tier: "Free API key (limited credits) at shodan.io",
            url: "https://www.shodan.io/",
            api_docs: "https://developer.shodan.io/api"
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
