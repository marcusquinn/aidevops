#!/usr/bin/env bash
# ip-rep-spamhaus.sh — Spamhaus DNSBL provider for ip-reputation-helper.sh
# Interface: check <ip> → JSON result on stdout
# Free tier: DNS-based lookups, no key required (non-commercial use)
# Zones checked: zen.spamhaus.org (SBL+XBL+PBL combined)
#   SBL: Spamhaus Block List (spam sources)
#   XBL: Exploits Block List (hijacked/infected)
#   PBL: Policy Block List (end-user IPs not for direct mail)
#   DBL: Domain Block List (not checked here — domain-based)
#
# Returned JSON fields:
#   provider      string  "spamhaus"
#   ip            string  queried IP
#   score         int     0-100 (derived from listing severity)
#   risk_level    string  clean/low/medium/high/critical
#   is_listed     bool    true if listed in any zone
#   zones         array   list of zones where IP is listed
#   zone_details  object  per-zone listing details
#   error         string  error message if failed (absent on success)
#   raw           object  raw DNS lookup results

set -euo pipefail

readonly PROVIDER_NAME="spamhaus"
readonly PROVIDER_DISPLAY="Spamhaus DNSBL"
readonly DEFAULT_TIMEOUT=10

# DNSBL zones to check
readonly ZEN_ZONE="zen.spamhaus.org"

# Return codes from zen.spamhaus.org
# 127.0.0.2 = SBL (spam source)
# 127.0.0.3 = SBL CSS (snowshoe spam)
# 127.0.0.4-7 = XBL (exploits/malware)
# 127.0.0.10-11 = PBL (policy block)

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

# Reverse an IPv4 address for DNSBL lookup
reverse_ip() {
	local ip="$1"
	local a b c d
	IFS='.' read -r a b c d <<<"$ip"
	echo "${d}.${c}.${b}.${a}"
	return 0
}

# Classify a DNSBL return code
classify_return_code() {
	local code="$1"
	case "$code" in
	"127.0.0.2") echo "SBL:spam_source" ;;
	"127.0.0.3") echo "SBL_CSS:snowshoe_spam" ;;
	"127.0.0.4") echo "XBL:exploits" ;;
	"127.0.0.5") echo "XBL:exploits" ;;
	"127.0.0.6") echo "XBL:exploits" ;;
	"127.0.0.7") echo "XBL:exploits" ;;
	"127.0.0.10") echo "PBL:policy_block_isp" ;;
	"127.0.0.11") echo "PBL:policy_block_user" ;;
	*) echo "LISTED:unknown_code_${code}" ;;
	esac
	return 0
}

# Score based on listing type
listing_score() {
	local zone_type="$1"
	case "$zone_type" in
	SBL*) echo 85 ;;
	XBL*) echo 75 ;;
	PBL*) echo 40 ;;
	*) echo 60 ;;
	esac
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

	# Validate IPv4 (basic check)
	if ! echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
		error_json "$ip" "invalid IPv4 address format"
		return 0
	fi

	# Check dig is available
	if ! command -v dig &>/dev/null; then
		error_json "$ip" "dig not found — install bind-utils or dnsutils"
		return 0
	fi

	local reversed
	reversed=$(reverse_ip "$ip")

	# Query zen.spamhaus.org (combined SBL+XBL+PBL)
	local lookup_host="${reversed}.${ZEN_ZONE}"
	local dig_result
	dig_result=$(dig +short +time="${timeout}" +tries=1 "$lookup_host" A 2>/dev/null || true)

	local is_listed=false
	local zones=()
	local max_score=0
	local zone_details="{}"

	if [[ -n "$dig_result" ]]; then
		is_listed=true
		local zone_json="{}"

		while IFS= read -r code; do
			[[ -z "$code" ]] && continue
			local classification
			classification=$(classify_return_code "$code")
			local zone_type="${classification%%:*}"
			local zone_reason="${classification#*:}"
			local zone_score
			zone_score=$(listing_score "$zone_type")

			zones+=("$zone_type")

			if [[ "$zone_score" -gt "$max_score" ]]; then
				max_score="$zone_score"
			fi

			zone_json=$(echo "$zone_json" | jq \
				--arg zone "$zone_type" \
				--arg reason "$zone_reason" \
				--arg code "$code" \
				'. + {($zone): {reason: $reason, return_code: $code}}')
		done <<<"$dig_result"

		zone_details="$zone_json"
	fi

	local risk_level
	risk_level=$(score_to_risk "$max_score")

	# Build zones JSON array
	local zones_json="[]"
	local z
	for z in "${zones[@]+"${zones[@]}"}"; do
		zones_json=$(echo "$zones_json" | jq --arg z "$z" '. + [$z]')
	done

	jq -n \
		--arg provider "$PROVIDER_NAME" \
		--arg ip "$ip" \
		--argjson score "$max_score" \
		--arg risk_level "$risk_level" \
		--argjson is_listed "$is_listed" \
		--argjson zones "$zones_json" \
		--argjson zone_details "$zone_details" \
		--arg lookup_host "$lookup_host" \
		--arg dig_result "$dig_result" \
		'{
            provider: $provider,
            ip: $ip,
            score: $score,
            risk_level: $risk_level,
            is_listed: $is_listed,
            zones: $zones,
            zone_details: $zone_details,
            raw: {
                lookup_host: $lookup_host,
                dns_response: $dig_result
            }
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
            free_tier: "DNS-based, no key required (non-commercial)",
            url: "https://www.spamhaus.org/",
            api_docs: "https://www.spamhaus.org/zen/"
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
