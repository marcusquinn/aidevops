#!/usr/bin/env bash
# ip-reputation-helper.sh — IP reputation checker using multiple providers
# Queries multiple IP reputation databases in parallel and merges results
# into a unified risk report. Use case: vet VPS/server/proxy IPs before
# purchase or deployment to check if they are burned (blacklisted, flagged).
#
# Usage:
#   ip-reputation-helper.sh check <ip> [options]
#   ip-reputation-helper.sh batch <file> [options]
#   ip-reputation-helper.sh report <ip> [options]
#   ip-reputation-helper.sh providers
#   ip-reputation-helper.sh help
#
# Options:
#   --provider <p>    Use only specified provider
#   --timeout <s>     Per-provider timeout in seconds (default: 15)
#   --format <fmt>    Output format: table (default), json, markdown
#   --parallel        Run providers in parallel (default)
#   --sequential      Run providers sequentially
#   --no-color        Disable color output
#
# Providers (free/no-key):
#   spamhaus      Spamhaus DNSBL (SBL/XBL/PBL via dig)
#   proxycheck    ProxyCheck.io (proxy/VPN/Tor detection)
#   stopforumspam StopForumSpam (forum spammer database)
#   blocklistde   Blocklist.de (attack/botnet IPs)
#
# Providers (free tier with API key):
#   abuseipdb     AbuseIPDB (community abuse reports, 1000/day free)
#
# Risk levels: clean → low → medium → high → critical
#
# Environment variables:
#   ABUSEIPDB_API_KEY     AbuseIPDB API key (free at abuseipdb.com)
#   PROXYCHECK_API_KEY    ProxyCheck.io API key (optional, increases limit)
#   IP_REP_TIMEOUT        Default per-provider timeout (default: 15)
#   IP_REP_FORMAT         Default output format (default: table)
#
# Examples:
#   ip-reputation-helper.sh check 1.2.3.4
#   ip-reputation-helper.sh check 1.2.3.4 --format json
#   ip-reputation-helper.sh check 1.2.3.4 --provider spamhaus
#   ip-reputation-helper.sh batch ips.txt
#   ip-reputation-helper.sh report 1.2.3.4
#   ip-reputation-helper.sh providers

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly PROVIDERS_DIR="${SCRIPT_DIR}/providers"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

# All available providers (order matters for display)
readonly ALL_PROVIDERS="spamhaus proxycheck stopforumspam blocklistde abuseipdb"

# Portable timeout command (macOS uses gtimeout from coreutils, Linux has timeout)
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then
	TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
	TIMEOUT_CMD="gtimeout"
fi
readonly TIMEOUT_CMD

# Default settings (prefixed to avoid conflict with shared-constants.sh DEFAULT_TIMEOUT)
readonly IP_REP_DEFAULT_TIMEOUT="${IP_REP_TIMEOUT:-15}"
readonly IP_REP_DEFAULT_FORMAT="${IP_REP_FORMAT:-table}"

# =============================================================================
# Colors (RED, GREEN, YELLOW, CYAN, NC sourced from shared-constants.sh)
# =============================================================================

# BOLD is not in shared-constants.sh — define it here
readonly BOLD='\033[1m'

# =============================================================================
# Logging
# =============================================================================

log_info() {
	echo -e "${CYAN}[INFO]${NC} $*" >&2
	return 0
}

log_warn() {
	echo -e "${YELLOW}[WARN]${NC} $*" >&2
	return 0
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $*" >&2
	return 0
}

log_success() {
	echo -e "${GREEN}[OK]${NC} $*" >&2
	return 0
}

# =============================================================================
# Provider Management
# =============================================================================

# Map provider name to script filename
provider_script() {
	local provider="$1"
	case "$provider" in
	abuseipdb) echo "ip-rep-abuseipdb.sh" ;;
	proxycheck) echo "ip-rep-proxycheck.sh" ;;
	spamhaus) echo "ip-rep-spamhaus.sh" ;;
	stopforumspam) echo "ip-rep-stopforumspam.sh" ;;
	blocklistde) echo "ip-rep-blocklistde.sh" ;;
	*) echo "" ;;
	esac
	return 0
}

# Map provider name to display name
provider_display_name() {
	local provider="$1"
	case "$provider" in
	abuseipdb) echo "AbuseIPDB" ;;
	proxycheck) echo "ProxyCheck.io" ;;
	spamhaus) echo "Spamhaus DNSBL" ;;
	stopforumspam) echo "StopForumSpam" ;;
	blocklistde) echo "Blocklist.de" ;;
	*) echo "$provider" ;;
	esac
	return 0
}

# Check if a provider script exists and is executable
is_provider_available() {
	local provider="$1"
	local script
	script=$(provider_script "$provider")
	[[ -n "$script" ]] && [[ -x "${PROVIDERS_DIR}/${script}" ]]
	return $?
}

# Get list of available providers (space-separated)
get_available_providers() {
	local available=()
	local provider
	for provider in $ALL_PROVIDERS; do
		if is_provider_available "$provider"; then
			available+=("$provider")
		fi
	done

	if [[ ${#available[@]} -eq 0 ]]; then
		log_error "No provider scripts found in ${PROVIDERS_DIR}/"
		return 1
	fi

	echo "${available[*]}"
	return 0
}

# =============================================================================
# Provider Execution
# =============================================================================

# Run a single provider and write JSON result to stdout
run_provider() {
	local provider="$1"
	local ip="$2"
	local timeout_secs="$3"

	local script
	script=$(provider_script "$provider")
	local script_path="${PROVIDERS_DIR}/${script}"

	if [[ ! -x "$script_path" ]]; then
		jq -n \
			--arg provider "$provider" \
			--arg ip "$ip" \
			'{provider: $provider, ip: $ip, error: "provider_not_available", is_listed: false, score: 0, risk_level: "unknown"}'
		return 0
	fi

	local result
	local run_cmd=("$script_path" check "$ip")
	if [[ -n "$TIMEOUT_CMD" ]]; then
		run_cmd=("$TIMEOUT_CMD" "$timeout_secs" "${run_cmd[@]}")
	fi

	if result=$("${run_cmd[@]}" 2>/dev/null); then
		if echo "$result" | jq empty 2>/dev/null; then
			echo "$result"
		else
			jq -n \
				--arg provider "$provider" \
				--arg ip "$ip" \
				'{provider: $provider, ip: $ip, error: "invalid_json_response", is_listed: false, score: 0, risk_level: "unknown"}'
		fi
	else
		local exit_code=$?
		local err_msg
		if [[ $exit_code -eq 124 ]]; then
			err_msg="timeout after ${timeout_secs}s"
		else
			err_msg="provider failed (exit ${exit_code})"
		fi
		jq -n \
			--arg provider "$provider" \
			--arg ip "$ip" \
			--arg error "$err_msg" \
			'{provider: $provider, ip: $ip, error: $error, is_listed: false, score: 0, risk_level: "unknown"}'
	fi
	return 0
}

# =============================================================================
# Risk Scoring
# =============================================================================

# Merge per-provider results into unified risk assessment
# Strategy: weighted average of scores, with listing flags as hard signals
merge_results() {
	local ip="$1"
	shift
	local result_files=("$@")

	local provider_results="[]"
	local total_score=0
	local provider_count=0
	local listed_count=0
	local is_tor=false
	local is_proxy=false
	local is_vpn=false
	local errors=0
	local file

	for file in "${result_files[@]}"; do
		[[ -f "$file" ]] || continue
		local content
		content=$(cat "$file")
		[[ -z "$content" ]] && continue

		# Skip if not valid JSON
		echo "$content" | jq empty 2>/dev/null || continue

		provider_results=$(echo "$provider_results" | jq --argjson r "$content" '. + [$r]')

		# Check for errors
		if echo "$content" | jq -e '.error' &>/dev/null; then
			errors=$((errors + 1))
			continue
		fi

		provider_count=$((provider_count + 1))

		local score is_listed
		score=$(echo "$content" | jq -r '.score // 0')
		is_listed=$(echo "$content" | jq -r '.is_listed // false')

		total_score=$((total_score + ${score%.*}))

		if [[ "$is_listed" == "true" ]]; then
			listed_count=$((listed_count + 1))
		fi

		# Aggregate flags
		if [[ "$(echo "$content" | jq -r '.is_tor // false')" == "true" ]]; then
			is_tor=true
		fi
		if [[ "$(echo "$content" | jq -r '.is_proxy // false')" == "true" ]]; then
			is_proxy=true
		fi
		if [[ "$(echo "$content" | jq -r '.is_vpn // false')" == "true" ]]; then
			is_vpn=true
		fi
	done

	# Calculate unified score
	local unified_score=0
	if [[ "$provider_count" -gt 0 ]]; then
		unified_score=$((total_score / provider_count))
	fi

	# Boost score if multiple providers agree on listing
	if [[ "$listed_count" -ge 3 ]]; then
		unified_score=$((unified_score > 85 ? 100 : unified_score + 15))
	elif [[ "$listed_count" -ge 2 ]]; then
		unified_score=$((unified_score > 90 ? 100 : unified_score + 10))
	fi

	# Determine unified risk level
	local risk_level
	if [[ "$unified_score" -ge 75 ]]; then
		risk_level="critical"
	elif [[ "$unified_score" -ge 50 ]]; then
		risk_level="high"
	elif [[ "$unified_score" -ge 25 ]]; then
		risk_level="medium"
	elif [[ "$unified_score" -ge 5 ]]; then
		risk_level="low"
	else
		risk_level="clean"
	fi

	# Recommendation
	local recommendation
	case "$risk_level" in
	critical) recommendation="AVOID — IP is heavily flagged across multiple sources" ;;
	high) recommendation="AVOID — IP has significant abuse/attack history" ;;
	medium) recommendation="CAUTION — IP has some flags, investigate before use" ;;
	low) recommendation="PROCEED WITH CAUTION — minor flags detected" ;;
	clean) recommendation="SAFE — no significant flags detected" ;;
	*) recommendation="UNKNOWN — insufficient data" ;;
	esac

	local scan_time
	scan_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	jq -n \
		--arg ip "$ip" \
		--argjson unified_score "$unified_score" \
		--arg risk_level "$risk_level" \
		--arg recommendation "$recommendation" \
		--argjson listed_count "$listed_count" \
		--argjson provider_count "$provider_count" \
		--argjson errors "$errors" \
		--argjson is_tor "$is_tor" \
		--argjson is_proxy "$is_proxy" \
		--argjson is_vpn "$is_vpn" \
		--argjson providers "$provider_results" \
		--arg scan_time "$scan_time" \
		'{
            ip: $ip,
            scan_time: $scan_time,
            unified_score: $unified_score,
            risk_level: $risk_level,
            recommendation: $recommendation,
            summary: {
                providers_queried: ($provider_count + $errors),
                providers_responded: $provider_count,
                providers_errored: $errors,
                listed_by: $listed_count,
                is_tor: $is_tor,
                is_proxy: $is_proxy,
                is_vpn: $is_vpn
            },
            providers: $providers
        }'
	return 0
}

# =============================================================================
# Output Formatting
# =============================================================================

# Risk level color
risk_color() {
	local level="$1"
	case "$level" in
	critical) echo "$RED" ;;
	high) echo "$RED" ;;
	medium) echo "$YELLOW" ;;
	low) echo "$YELLOW" ;;
	clean) echo "$GREEN" ;;
	*) echo "$NC" ;;
	esac
	return 0
}

# Risk level symbol
risk_symbol() {
	local level="$1"
	case "$level" in
	critical) echo "CRITICAL" ;;
	high) echo "HIGH" ;;
	medium) echo "MEDIUM" ;;
	low) echo "LOW" ;;
	clean) echo "CLEAN" ;;
	*) echo "UNKNOWN" ;;
	esac
	return 0
}

# Format results as terminal table
format_table() {
	local json="$1"

	local ip risk_level unified_score recommendation scan_time
	ip=$(echo "$json" | jq -r '.ip')
	risk_level=$(echo "$json" | jq -r '.risk_level')
	unified_score=$(echo "$json" | jq -r '.unified_score')
	recommendation=$(echo "$json" | jq -r '.recommendation')
	scan_time=$(echo "$json" | jq -r '.scan_time')

	local color
	color=$(risk_color "$risk_level")
	local symbol
	symbol=$(risk_symbol "$risk_level")

	echo ""
	echo -e "${BOLD}${CYAN}=== IP Reputation Report ===${NC}"
	echo -e "IP:          ${BOLD}${ip}${NC}"
	echo -e "Scanned:     ${scan_time}"
	echo -e "Risk Level:  ${color}${BOLD}${symbol}${NC} (score: ${unified_score}/100)"
	echo -e "Verdict:     ${color}${recommendation}${NC}"
	echo ""

	# Summary flags
	local is_tor is_proxy is_vpn listed_by providers_queried providers_responded
	is_tor=$(echo "$json" | jq -r '.summary.is_tor')
	is_proxy=$(echo "$json" | jq -r '.summary.is_proxy')
	is_vpn=$(echo "$json" | jq -r '.summary.is_vpn')
	listed_by=$(echo "$json" | jq -r '.summary.listed_by')
	providers_queried=$(echo "$json" | jq -r '.summary.providers_queried')
	providers_responded=$(echo "$json" | jq -r '.summary.providers_responded')

	echo -e "${BOLD}Summary:${NC}"
	echo -e "  Providers:  ${providers_responded}/${providers_queried} responded"
	echo -e "  Listed by:  ${listed_by} provider(s)"
	local tor_flag proxy_flag vpn_flag
	tor_flag=$([[ "$is_tor" == "true" ]] && echo "${RED}YES${NC}" || echo "${GREEN}NO${NC}")
	proxy_flag=$([[ "$is_proxy" == "true" ]] && echo "${RED}YES${NC}" || echo "${GREEN}NO${NC}")
	vpn_flag=$([[ "$is_vpn" == "true" ]] && echo "${YELLOW}YES${NC}" || echo "${GREEN}NO${NC}")
	echo -e "  Tor:        $(echo -e "$tor_flag")"
	echo -e "  Proxy:      $(echo -e "$proxy_flag")"
	echo -e "  VPN:        $(echo -e "$vpn_flag")"
	echo ""

	# Per-provider results
	echo -e "${BOLD}Provider Results:${NC}"
	printf "  %-18s %-10s %-8s %s\n" "Provider" "Risk" "Score" "Details"
	printf "  %-18s %-10s %-8s %s\n" "--------" "----" "-----" "-------"

	echo "$json" | jq -r '.providers[] | [.provider, (.risk_level // "error"), (.score // 0 | tostring), (.error // (.is_listed | if . then "listed" else "clean" end))] | @tsv' 2>/dev/null |
		while IFS=$'\t' read -r prov risk score detail; do
			local prov_color
			prov_color=$(risk_color "$risk")
			local display_name
			display_name=$(provider_display_name "$prov")
			printf "  %-18s ${prov_color}%-10s${NC} %-8s %s\n" "$display_name" "$risk" "$score" "$detail"
		done

	echo ""
	return 0
}

# Format results as markdown report
format_markdown() {
	local json="$1"

	local ip risk_level unified_score recommendation scan_time
	ip=$(echo "$json" | jq -r '.ip')
	risk_level=$(echo "$json" | jq -r '.risk_level')
	unified_score=$(echo "$json" | jq -r '.unified_score')
	recommendation=$(echo "$json" | jq -r '.recommendation')
	scan_time=$(echo "$json" | jq -r '.scan_time')

	local listed_by providers_queried providers_responded is_tor is_proxy is_vpn
	listed_by=$(echo "$json" | jq -r '.summary.listed_by')
	providers_queried=$(echo "$json" | jq -r '.summary.providers_queried')
	providers_responded=$(echo "$json" | jq -r '.summary.providers_responded')
	is_tor=$(echo "$json" | jq -r '.summary.is_tor')
	is_proxy=$(echo "$json" | jq -r '.summary.is_proxy')
	is_vpn=$(echo "$json" | jq -r '.summary.is_vpn')

	# Uppercase risk level (portable — no bash 4 ^^ operator)
	local risk_upper
	risk_upper=$(echo "$risk_level" | tr '[:lower:]' '[:upper:]')

	cat <<EOF
# IP Reputation Report: ${ip}

- **Scanned**: ${scan_time}
- **Risk Level**: ${risk_upper} (${unified_score}/100)
- **Verdict**: ${recommendation}

## Summary

| Metric | Value |
|--------|-------|
| Providers queried | ${providers_queried} |
| Providers responded | ${providers_responded} |
| Listed by | ${listed_by} provider(s) |
| Tor exit node | ${is_tor} |
| Proxy detected | ${is_proxy} |
| VPN detected | ${is_vpn} |

## Provider Results

| Provider | Risk Level | Score | Listed | Details |
|----------|-----------|-------|--------|---------|
EOF

	echo "$json" | jq -r '.providers[] | "| \(.provider) | \(.risk_level // "error") | \(.score // 0) | \(.is_listed // false) | \(.error // "ok") |"' 2>/dev/null

	echo ""
	echo "---"
	echo "*Generated by ip-reputation-helper.sh v${VERSION}*"
	return 0
}

# Output results in requested format
output_results() {
	local json="$1"
	local format="$2"

	case "$format" in
	json) echo "$json" ;;
	markdown) format_markdown "$json" ;;
	table | *) format_table "$json" ;;
	esac
	return 0
}

# =============================================================================
# Core Commands
# =============================================================================

# Check a single IP address
cmd_check() {
	local ip=""
	local specific_provider=""
	local run_parallel=true
	local timeout_secs="$IP_REP_DEFAULT_TIMEOUT"
	local output_format="$IP_REP_DEFAULT_FORMAT"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider | -p)
			specific_provider="$2"
			shift 2
			;;
		--timeout | -t)
			timeout_secs="$2"
			shift 2
			;;
		--format | -f)
			output_format="$2"
			shift 2
			;;
		--parallel)
			run_parallel=true
			shift
			;;
		--sequential)
			run_parallel=false
			shift
			;;
		--no-color)
			shift
			;;
		-*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "$ip" ]]; then
				ip="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$ip" ]]; then
		log_error "IP address required"
		echo "Usage: $(basename "$0") check <ip> [options]" >&2
		return 1
	fi

	# Validate IPv4 format
	if ! echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
		log_error "Invalid IPv4 address: ${ip}"
		return 1
	fi

	log_info "Checking IP reputation for: ${ip}"

	# Determine providers to use
	local -a providers_to_run=()
	if [[ -n "$specific_provider" ]]; then
		if is_provider_available "$specific_provider"; then
			providers_to_run+=("$specific_provider")
		else
			log_error "Provider '${specific_provider}' not available"
			cmd_providers
			return 1
		fi
	else
		local available
		available=$(get_available_providers) || return 1
		read -ra providers_to_run <<<"$available"
	fi

	log_info "Using providers: ${providers_to_run[*]}"

	# Create temp directory for results
	local tmp_dir
	tmp_dir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '${tmp_dir}'" RETURN

	local -a result_files=()
	local -a pids=()

	if [[ "$run_parallel" == "true" && ${#providers_to_run[@]} -gt 1 ]]; then
		# Parallel execution via background jobs
		local provider
		for provider in "${providers_to_run[@]}"; do
			local result_file="${tmp_dir}/${provider}.json"
			result_files+=("$result_file")

			(
				local result
				result=$(run_provider "$provider" "$ip" "$timeout_secs")
				echo "$result" >"$result_file"
			) &
			pids+=($!)
		done

		# Wait for all background jobs
		local pid
		for pid in "${pids[@]}"; do
			wait "$pid" 2>/dev/null || true
		done
	else
		# Sequential execution
		local provider
		for provider in "${providers_to_run[@]}"; do
			local result_file="${tmp_dir}/${provider}.json"
			result_files+=("$result_file")
			local result
			result=$(run_provider "$provider" "$ip" "$timeout_secs")
			echo "$result" >"$result_file"
		done
	fi

	# Merge results
	local merged
	merged=$(merge_results "$ip" "${result_files[@]}") || {
		log_error "Failed to merge provider results"
		return 1
	}

	output_results "$merged" "$output_format"
	return 0
}

# Batch check IPs from a file (one IP per line)
cmd_batch() {
	local file=""
	local output_format="$IP_REP_DEFAULT_FORMAT"
	local timeout_secs="$IP_REP_DEFAULT_TIMEOUT"
	local specific_provider=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format | -f)
			output_format="$2"
			shift 2
			;;
		--timeout | -t)
			timeout_secs="$2"
			shift 2
			;;
		--provider | -p)
			specific_provider="$2"
			shift 2
			;;
		-*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "$file" ]]; then
				file="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$file" ]]; then
		log_error "File path required"
		echo "Usage: $(basename "$0") batch <file> [options]" >&2
		return 1
	fi

	if [[ ! -f "$file" ]]; then
		log_error "File not found: ${file}"
		return 1
	fi

	local total=0
	local processed=0
	local clean=0
	local flagged=0

	# Count IPs
	total=$(grep -cE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' "$file" || echo 0)
	log_info "Processing ${total} IPs from ${file}"

	local batch_results="[]"

	while IFS= read -r line; do
		# Skip empty lines and comments
		[[ -z "$line" || "$line" =~ ^# ]] && continue

		# Validate IP format
		if ! echo "$line" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
			log_warn "Skipping invalid IP: ${line}"
			continue
		fi

		processed=$((processed + 1))
		log_info "[${processed}/${total}] Checking ${line}..."

		local check_args=("$line" "--format" "json" "--timeout" "$timeout_secs")
		[[ -n "$specific_provider" ]] && check_args+=("--provider" "$specific_provider")

		local result
		result=$(cmd_check "${check_args[@]}" 2>/dev/null) || {
			log_warn "Failed to check ${line}"
			continue
		}

		local risk_level
		risk_level=$(echo "$result" | jq -r '.risk_level // "unknown"')

		if [[ "$risk_level" == "clean" ]]; then
			clean=$((clean + 1))
		else
			flagged=$((flagged + 1))
		fi

		batch_results=$(echo "$batch_results" | jq --argjson r "$result" '. + [$r]')

	done <"$file"

	# Batch summary
	echo ""
	echo -e "${BOLD}${CYAN}=== Batch Results ===${NC}"
	echo -e "File:     ${file}"
	echo -e "Total:    ${processed} IPs processed"
	echo -e "Clean:    ${GREEN}${clean}${NC}"
	echo -e "Flagged:  ${RED}${flagged}${NC}"
	echo ""

	# Show flagged IPs
	if [[ "$flagged" -gt 0 ]]; then
		echo -e "${BOLD}Flagged IPs:${NC}"
		echo "$batch_results" | jq -r '.[] | select(.risk_level != "clean") | "\(.ip)\t\(.risk_level)\t\(.unified_score)\t\(.recommendation)"' 2>/dev/null |
			while IFS=$'\t' read -r ip risk score rec; do
				local color risk_upper
				color=$(risk_color "$risk")
				risk_upper=$(echo "$risk" | tr '[:lower:]' '[:upper:]')
				echo -e "  ${ip}  ${color}${risk_upper}${NC} (${score})  ${rec}"
			done
		echo ""
	fi

	if [[ "$output_format" == "json" ]]; then
		jq -n \
			--arg file "$file" \
			--argjson total "$processed" \
			--argjson clean "$clean" \
			--argjson flagged "$flagged" \
			--argjson results "$batch_results" \
			'{file: $file, total: $total, clean: $clean, flagged: $flagged, results: $results}'
	fi

	return 0
}

# Generate detailed markdown report for an IP
cmd_report() {
	local ip=""
	local timeout_secs="$IP_REP_DEFAULT_TIMEOUT"
	local specific_provider=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--timeout | -t)
			timeout_secs="$2"
			shift 2
			;;
		--provider | -p)
			specific_provider="$2"
			shift 2
			;;
		-*)
			log_warn "Unknown option: $1"
			shift
			;;
		*)
			if [[ -z "$ip" ]]; then
				ip="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$ip" ]]; then
		log_error "IP address required"
		echo "Usage: $(basename "$0") report <ip> [options]" >&2
		return 1
	fi

	local check_args=("$ip" "--format" "json" "--timeout" "$timeout_secs")
	[[ -n "$specific_provider" ]] && check_args+=("--provider" "$specific_provider")

	local result
	result=$(cmd_check "${check_args[@]}") || return 1

	format_markdown "$result"
	return 0
}

# List all providers and their status
cmd_providers() {
	echo ""
	echo -e "${BOLD}${CYAN}=== IP Reputation Providers ===${NC}"
	echo ""
	printf "  %-18s %-20s %-10s %-12s %s\n" "Provider" "Display Name" "Status" "Key Req." "Free Tier"
	printf "  %-18s %-20s %-10s %-12s %s\n" "--------" "------------" "------" "--------" "---------"

	local provider
	for provider in $ALL_PROVIDERS; do
		local script
		script=$(provider_script "$provider")
		local script_path="${PROVIDERS_DIR}/${script}"
		local display_name
		display_name=$(provider_display_name "$provider")

		local status key_req free_tier
		if [[ -x "$script_path" ]]; then
			# Get info from provider
			local info
			info=$("$script_path" info 2>/dev/null || echo '{}')
			key_req=$(echo "$info" | jq -r '.requires_key // false | if . then "yes" else "no" end')
			free_tier=$(echo "$info" | jq -r '.free_tier // "unknown"')
			status="${GREEN}available${NC}"
		else
			status="${RED}missing${NC}"
			key_req="-"
			free_tier="-"
		fi

		printf "  %-18s %-20s " "$provider" "$display_name"
		echo -e "${status}  ${key_req}          ${free_tier}"
	done

	echo ""
	echo -e "Provider scripts location: ${PROVIDERS_DIR}/"
	echo -e "Each provider implements: check <ip> [--api-key <key>] [--timeout <s>]"
	echo ""
	return 0
}

# =============================================================================
# Usage
# =============================================================================

print_usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  check <ip>        Check reputation of a single IP address
  batch <file>      Check multiple IPs from file (one per line)
  report <ip>       Generate detailed markdown report for an IP
  providers         List available providers and their status
  help              Show this help message

Options:
  --provider <p>    Use only specified provider
  --timeout <s>     Per-provider timeout in seconds (default: ${IP_REP_DEFAULT_TIMEOUT})
  --format <fmt>    Output format: table (default), json, markdown
  --parallel        Run providers in parallel (default)
  --sequential      Run providers sequentially
  --no-color        Disable color output

Providers:
  spamhaus          Spamhaus DNSBL (no key required)
  proxycheck        ProxyCheck.io (no key required, optional key for more)
  stopforumspam     StopForumSpam (no key required)
  blocklistde       Blocklist.de (no key required)
  abuseipdb         AbuseIPDB (free API key required: abuseipdb.com)

Environment:
  ABUSEIPDB_API_KEY     AbuseIPDB API key
  PROXYCHECK_API_KEY    ProxyCheck.io API key (optional)
  IP_REP_TIMEOUT        Default timeout (default: 15)
  IP_REP_FORMAT         Default format (default: table)

Examples:
  $(basename "$0") check 1.2.3.4
  $(basename "$0") check 1.2.3.4 --format json
  $(basename "$0") check 1.2.3.4 --provider spamhaus
  $(basename "$0") batch ips.txt
  $(basename "$0") batch ips.txt --format json
  $(basename "$0") report 1.2.3.4
  $(basename "$0") providers
EOF
	return 0
}

# =============================================================================
# Main Dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	check)
		cmd_check "$@"
		;;
	batch)
		cmd_batch "$@"
		;;
	report)
		cmd_report "$@"
		;;
	providers)
		cmd_providers
		;;
	help | --help | -h)
		print_usage
		;;
	version | --version | -v)
		echo "ip-reputation-helper.sh v${VERSION}"
		;;
	*)
		log_error "Unknown command: ${command}"
		print_usage
		exit 1
		;;
	esac
	return 0
}

main "$@"
