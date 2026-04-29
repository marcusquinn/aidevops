#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
#   ip-reputation-helper.sh cache-stats
#   ip-reputation-helper.sh cache-clear [--provider <p>] [--ip <ip>]
#   ip-reputation-helper.sh rate-limit-status
#   ip-reputation-helper.sh help
#
# Options:
#   --provider <p>    Use only specified provider
#   --timeout <s>     Per-provider timeout in seconds (default: 15)
#   --format <fmt>    Output format: table (default), json, markdown, compact
#   --parallel        Run providers in parallel (default)
#   --sequential      Run providers sequentially
#   --no-color        Disable color output (also respects NO_COLOR env)
#   --no-cache        Bypass cache for this query
#   --rate-limit <n>  Requests per second per provider in batch mode (default: 2)
#   --dnsbl-overlap   Cross-reference results with email-health-check-helper.sh DNSBL
#
# Providers (free/no-key):
#   spamhaus      Spamhaus DNSBL (SBL/XBL/PBL via dig)
#   proxycheck    ProxyCheck.io (proxy/VPN/Tor detection)
#   stopforumspam StopForumSpam (forum spammer database)
#   blocklistde   Blocklist.de (attack/botnet IPs)
#   greynoise     GreyNoise Community API (internet noise scanner)
#
# Providers (free tier with API key):
#   abuseipdb       AbuseIPDB (community abuse reports, 1000/day free)
#   virustotal      VirusTotal (70+ AV engines, 500/day free)
#   ipqualityscore  IPQualityScore (fraud/proxy/VPN detection, 5000/month free)
#   scamalytics     Scamalytics (fraud scoring, 5000/month free)
#   shodan          Shodan (open ports, vulns, tags — free key, limited credits)
#   iphub           IP Hub (proxy/VPN/hosting detection, 1000/day free)
#
# Risk levels: clean → low → medium → high → critical
#
# Environment variables:
#   ABUSEIPDB_API_KEY         AbuseIPDB API key (free at abuseipdb.com)
#   VIRUSTOTAL_API_KEY        VirusTotal API key (free at virustotal.com)
#   PROXYCHECK_API_KEY        ProxyCheck.io API key (optional, increases limit)
#   IPQUALITYSCORE_API_KEY    IPQualityScore API key (free at ipqualityscore.com)
#   SCAMALYTICS_API_KEY       Scamalytics API key (free at scamalytics.com)
#   GREYNOISE_API_KEY         GreyNoise API key (optional, enables full API)
#   SHODAN_API_KEY            Shodan API key (free at shodan.io, limited credits)
#   IPHUB_API_KEY             IP Hub API key (free at iphub.info)
#   IP_REP_TIMEOUT            Default per-provider timeout (default: 15)
#   IP_REP_FORMAT             Default output format (default: table)
#   IP_REP_CACHE_DIR          SQLite cache directory (default: ~/.cache/ip-reputation)
#   IP_REP_CACHE_TTL          Default cache TTL in seconds (default: 86400 = 24h)
#   IP_REP_RATE_LIMIT         Requests per second per provider in batch (default: 2)
#
# Cache TTL per provider (seconds):
#   spamhaus/blocklistde/stopforumspam: 3600  (1h — DNSBL data changes frequently)
#   proxycheck/iphub:                   21600 (6h)
#   abuseipdb/ipqualityscore/virustotal: 86400 (24h)
#   scamalytics/greynoise:              86400 (24h)
#   shodan:                             604800 (7d — scan data changes slowly)
#
# Examples:
#   ip-reputation-helper.sh check 1.2.3.4
#   ip-reputation-helper.sh check 1.2.3.4 --format json
#   ip-reputation-helper.sh check 1.2.3.4 --provider spamhaus
#   ip-reputation-helper.sh check 1.2.3.4 --no-cache
#   ip-reputation-helper.sh batch ips.txt
#   ip-reputation-helper.sh batch ips.txt --rate-limit 1 --dnsbl-overlap
#   ip-reputation-helper.sh report 1.2.3.4
#   ip-reputation-helper.sh providers
#   ip-reputation-helper.sh cache-stats
#   ip-reputation-helper.sh cache-clear --provider abuseipdb

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly VERSION="2.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR
readonly PROVIDERS_DIR="${SCRIPT_DIR}/providers"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

# All available providers (order matters for display)
# greynoise has a free community API (no key required) but also supports keyed full API
readonly ALL_PROVIDERS="spamhaus proxycheck stopforumspam blocklistde greynoise abuseipdb virustotal ipqualityscore scamalytics shodan iphub"

# Global color toggle (set by --no-color flag or NO_COLOR env before any output)
# shellcheck disable=SC2034
IP_REP_NO_COLOR="${NO_COLOR:-false}"

# =============================================================================
# SQLite Cache Constants
# =============================================================================

readonly IP_REP_CACHE_DIR="${IP_REP_CACHE_DIR:-${HOME}/.cache/ip-reputation}"
readonly IP_REP_CACHE_DB="${IP_REP_CACHE_DIR}/cache.db"
readonly IP_REP_DEFAULT_CACHE_TTL="${IP_REP_CACHE_TTL:-86400}"

# Portable timeout: timeout_sec() is provided by shared-constants.sh (sourced above).
# It handles Linux timeout, macOS gtimeout, and bare macOS fallback transparently.

# Default settings (prefixed to avoid conflict with shared-constants.sh DEFAULT_TIMEOUT)
readonly IP_REP_DEFAULT_TIMEOUT="${IP_REP_TIMEOUT:-15}"
readonly IP_REP_DEFAULT_FORMAT="${IP_REP_FORMAT:-table}"

# =============================================================================
# Colors (RED, GREEN, YELLOW, CYAN, NC sourced from shared-constants.sh)
# =============================================================================

# BOLD is not in shared-constants.sh — define it here
# shellcheck disable=SC2034
BOLD='\033[1m'

# Color accessor functions — return empty strings when --no-color is active.
# This avoids reassigning readonly variables from shared-constants.sh.
c_red() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$RED"; return 0; }
c_green() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$GREEN"; return 0; }
c_yellow() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$YELLOW"; return 0; }
c_cyan() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$CYAN"; return 0; }
c_nc() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$NC"; return 0; }
c_bold() { [[ "$IP_REP_NO_COLOR" == "true" ]] && echo "" || echo "$BOLD"; return 0; }

# Disable colors when --no-color is active or NO_COLOR env is set
# Called after argument parsing sets IP_REP_NO_COLOR
disable_colors() {
	IP_REP_NO_COLOR="true"
	return 0
}

# =============================================================================
# Sub-Libraries
# =============================================================================

# shellcheck source=./ip-reputation-helper-cache.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/ip-reputation-helper-cache.sh"

# shellcheck source=./ip-reputation-helper-providers.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/ip-reputation-helper-providers.sh"

# shellcheck source=./ip-reputation-helper-merge.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/ip-reputation-helper-merge.sh"

# shellcheck source=./ip-reputation-helper-commands.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/ip-reputation-helper-commands.sh"

# =============================================================================
# Per-Subcommand Help
# =============================================================================

print_usage_check() {
	cat <<EOF
Usage: $(basename "$0") check <ip> [options]

Check the reputation of a single IP address across multiple providers.

Arguments:
  <ip>              IPv4 address to check (required)

Options:
  --provider, -p <p>    Use only specified provider (default: all available)
  --timeout, -t <s>     Per-provider timeout in seconds (default: ${IP_REP_DEFAULT_TIMEOUT})
  --format, -f <fmt>    Output format: table (default), json, markdown, compact
  --parallel            Run providers in parallel (default)
  --sequential          Run providers sequentially
  --no-cache            Bypass cache for this query
  --no-color            Disable color output (also respects NO_COLOR env)

Examples:
  $(basename "$0") check 1.2.3.4
  $(basename "$0") check 1.2.3.4 -f json
  $(basename "$0") check 1.2.3.4 --format markdown
  $(basename "$0") check 1.2.3.4 --format compact
  $(basename "$0") check 1.2.3.4 --provider abuseipdb
  $(basename "$0") check 1.2.3.4 --no-cache
  $(basename "$0") check 1.2.3.4 --no-color
  $(basename "$0") check 1.2.3.4 --sequential --timeout 30
EOF
	return 0
}

print_usage_batch() {
	cat <<EOF
Usage: $(basename "$0") batch <file> [options]

Check multiple IP addresses from a file (one IP per line).
Lines starting with # and blank lines are skipped.

Arguments:
  <file>            Path to file containing IPs (required)

Options:
  --provider, -p <p>    Use only specified provider (default: all available)
  --timeout, -t <s>     Per-provider timeout in seconds (default: ${IP_REP_DEFAULT_TIMEOUT})
  --format, -f <fmt>    Output format: table (default), json
  --no-cache            Bypass cache for this query
  --rate-limit <n>      Requests per second per provider (default: 2)
  --dnsbl-overlap       Cross-reference results with email DNSBL zones

Examples:
  $(basename "$0") batch ips.txt
  $(basename "$0") batch ips.txt --rate-limit 1
  $(basename "$0") batch ips.txt --dnsbl-overlap
  $(basename "$0") batch ips.txt -f json
  $(basename "$0") batch ips.txt --provider spamhaus --rate-limit 5
EOF
	return 0
}

print_usage_report() {
	cat <<EOF
Usage: $(basename "$0") report <ip> [options]

Generate a detailed markdown report for an IP address.
Queries all available providers and outputs a formatted markdown document
suitable for documentation, audit trails, or sharing.

Arguments:
  <ip>              IPv4 address to report on (required)

Options:
  --provider, -p <p>    Use only specified provider (default: all available)
  --timeout, -t <s>     Per-provider timeout in seconds (default: ${IP_REP_DEFAULT_TIMEOUT})

Examples:
  $(basename "$0") report 1.2.3.4
  $(basename "$0") report 1.2.3.4 > report.md
  $(basename "$0") report 1.2.3.4 --provider abuseipdb
  $(basename "$0") report 1.2.3.4 --timeout 30

Note: Equivalent to: $(basename "$0") check 1.2.3.4 --format markdown
EOF
	return 0
}

print_usage_cache_clear() {
	cat <<EOF
Usage: $(basename "$0") cache-clear [options]

Clear cached IP reputation results from the SQLite cache.
Without filters, clears all cached entries.

Options:
  --provider, -p <p>    Clear cache only for specified provider
  --ip <ip>             Clear cache only for specified IP address

Examples:
  $(basename "$0") cache-clear
  $(basename "$0") cache-clear --provider abuseipdb
  $(basename "$0") cache-clear --ip 1.2.3.4
  $(basename "$0") cache-clear --provider spamhaus --ip 1.2.3.4
EOF
	return 0
}

# =============================================================================
# Usage
# =============================================================================

print_usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  check <ip>          Check reputation of a single IP address
  batch <file>        Check multiple IPs from file (one per line)
  report <ip>         Generate detailed markdown report for an IP
  providers           List available providers and their status
  cache-stats         Show SQLite cache statistics
  cache-clear         Clear cache entries (--provider, --ip filters)
  rate-limit-status   Show per-provider rate limit status and history
  help                Show this help message

Options:
  --provider <p>    Use only specified provider
  --timeout <s>     Per-provider timeout in seconds (default: ${IP_REP_DEFAULT_TIMEOUT})
  --format <fmt>    Output format: table (default), json, markdown, compact
  --parallel        Run providers in parallel (default)
  --sequential      Run providers sequentially
  --no-cache        Bypass cache for this query
  --no-color        Disable color output (also respects NO_COLOR env)
  --rate-limit <n>  Requests/second per provider in batch mode (default: 2)
  --dnsbl-overlap   Cross-reference with DNSBL in batch mode

Providers (no key required):
  spamhaus          Spamhaus DNSBL (SBL/XBL/PBL)
  proxycheck        ProxyCheck.io (optional key for higher limits)
  stopforumspam     StopForumSpam
  blocklistde       Blocklist.de
  greynoise         GreyNoise Community API (optional key for full API)

Providers (free API key required):
  abuseipdb         AbuseIPDB — 1000/day free (abuseipdb.com)
  virustotal        VirusTotal — 500/day free (virustotal.com)
  ipqualityscore    IPQualityScore — 5000/month free (ipqualityscore.com)
  scamalytics       Scamalytics — 5000/month free (scamalytics.com)
  shodan            Shodan — free key, limited credits (shodan.io)
  iphub             IP Hub — 1000/day free (iphub.info)

Environment:
  ABUSEIPDB_API_KEY         AbuseIPDB API key
  VIRUSTOTAL_API_KEY        VirusTotal API key
  PROXYCHECK_API_KEY        ProxyCheck.io API key (optional)
  IPQUALITYSCORE_API_KEY    IPQualityScore API key
  SCAMALYTICS_API_KEY       Scamalytics API key
  GREYNOISE_API_KEY         GreyNoise API key (optional, enables full API)
  SHODAN_API_KEY            Shodan API key
  IPHUB_API_KEY             IP Hub API key
  IP_REP_TIMEOUT            Default timeout (default: 15)
  IP_REP_FORMAT             Default format (default: table)
  IP_REP_CACHE_DIR          SQLite cache directory (default: ~/.cache/ip-reputation)
  IP_REP_CACHE_TTL          Default cache TTL in seconds (default: 86400)
  IP_REP_RATE_LIMIT         Batch rate limit req/s (default: 2)

Examples:
  $(basename "$0") check 1.2.3.4
  $(basename "$0") check 1.2.3.4 --format json
  $(basename "$0") check 1.2.3.4 --format compact
  $(basename "$0") check 1.2.3.4 --provider spamhaus
  $(basename "$0") check 1.2.3.4 --no-cache
  $(basename "$0") check 1.2.3.4 --no-color
  $(basename "$0") batch ips.txt
  $(basename "$0") batch ips.txt --rate-limit 1 --dnsbl-overlap
  $(basename "$0") batch ips.txt --format json
  $(basename "$0") report 1.2.3.4
  $(basename "$0") providers
  $(basename "$0") cache-stats
  $(basename "$0") cache-clear --provider abuseipdb
  $(basename "$0") cache-clear --ip 1.2.3.4
  $(basename "$0") rate-limit-status
EOF
	return 0
}

# =============================================================================
# Main Dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	# Handle global --no-color before dispatch (for commands that don't parse it)
	if [[ "${NO_COLOR:-}" == "true" || "${NO_COLOR:-}" == "1" ]]; then
		# shellcheck disable=SC2034
		IP_REP_NO_COLOR="true"
		disable_colors
	fi

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
	cache-stats | cache_stats)
		cmd_cache_stats
		;;
	cache-clear | cache_clear)
		cmd_cache_clear "$@"
		;;
	rate-limit-status | rate_limit_status)
		cache_init
		cmd_rate_limit_status
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
