#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# network-tier-helper.sh — Network domain tiering for worker sandboxing (t1412.3)
# Commands: classify | log-access | check | report | init | help
#
# Implements a 4-tier graduated trust model for headless worker network access:
#   Tier 1: Always allowed, no logging (core infrastructure: github.com)
#   Tier 2: Allowed + logged (package registries: npmjs.org, pypi.org)
#   Tier 3: Allowed + logged (known tools/docs: sonarcloud.io, docs.anthropic.com)
#   Tier 4: Allowed + flagged (unknown domains — logged with alert for review)
#   Tier 5: Denied (exfiltration indicators: requestbin, ngrok, raw IPs)
#
# Interactive sessions are unrestricted — tiering only applies to sandboxed workers.
#
# Integration:
#   - sandbox-exec-helper.sh calls `check` before network operations
#   - Workers call `log-access` after each network request
#   - Supervisors call `report` to review flagged domains
#
# Config:
#   - Default tiers: .agents/configs/network-tiers.conf
#   - User overrides: ~/.config/aidevops/network-tiers-custom.conf
#
# Compatibility: bash 3.2+ (macOS default). Uses file-based lookup, not
# associative arrays, for portability.
#
# Usage:
#   network-tier-helper.sh classify example.com     # → 1|2|3|4|5
#   network-tier-helper.sh check example.com        # exit 0=allow, 1=deny
#   network-tier-helper.sh check-session example.com [--session-id ID]
#                                                   # Session-aware check (t1428.3)
#   network-tier-helper.sh log-access example.com worker-123 200
#   network-tier-helper.sh report [--last N] [--flagged-only]
#   network-tier-helper.sh init                     # Create log dirs and validate config
#   network-tier-helper.sh help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

LOG_PREFIX="NET-TIER"

# =============================================================================
# Constants
# =============================================================================

readonly NET_TIER_DIR="${HOME}/.aidevops/.agent-workspace/network"
readonly NET_TIER_LOG="${NET_TIER_DIR}/access.jsonl"
readonly NET_TIER_FLAGGED_LOG="${NET_TIER_DIR}/flagged.jsonl"
readonly NET_TIER_DENIED_LOG="${NET_TIER_DIR}/denied.jsonl"

# Config file locations (default + user override)
readonly NET_TIER_DEFAULT_CONF="${SCRIPT_DIR}/../configs/network-tiers.conf"
readonly NET_TIER_USER_CONF="${HOME}/.config/aidevops/network-tiers-custom.conf"

# File-based tier lookup cache (bash 3.2 compatible — no associative arrays)
# Format: "exact:domain tier" or "wild:suffix tier", one per line
_TIER_LOOKUP_FILE=""
_TIER_DATA_LOADED=""

# =============================================================================
# Config Parsing
# =============================================================================

# Parse a network-tiers.conf file and append entries to the lookup file.
# Reads [tierN] sections. User config entries override defaults (last match wins
# in grep, so user config is appended after defaults).
# Arguments:
#   $1 - config file path
#   $2 - lookup file to append to
_parse_tier_config() {
	local config_file="$1"
	local lookup_file="$2"
	local current_tier=""

	if [[ ! -r "$config_file" ]]; then
		return 0
	fi

	local line
	while IFS= read -r line || [[ -n "$line" ]]; do
		# Skip empty lines and comments
		[[ -z "$line" || "$line" == \#* ]] && continue

		# Trim whitespace
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -z "$line" || "$line" == \#* ]] && continue

		# Section headers: [tier1], [tier2], etc.
		if [[ "$line" =~ ^\[tier([1-5])\]$ ]]; then
			current_tier="${BASH_REMATCH[1]}"
			continue
		fi

		# Skip lines outside a section
		[[ -z "$current_tier" ]] && continue

		# Normalize: lowercase, strip trailing dot
		local domain="$line"
		domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
		domain="${domain%.}"

		if [[ "$domain" == \*.* ]]; then
			# Wildcard: *.example.com → store the suffix
			local suffix="${domain#\*.}"
			printf 'wild:%s %s\n' "$suffix" "$current_tier" >>"$lookup_file"
		else
			printf 'exact:%s %s\n' "$domain" "$current_tier" >>"$lookup_file"
		fi
	done <"$config_file"

	return 0
}

# Load tier configuration from default + user override files.
# Creates a temp file with all tier mappings for grep-based lookup.
# Called once per script invocation; results cached in _TIER_LOOKUP_FILE.
_load_tier_data() {
	if [[ -n "$_TIER_DATA_LOADED" ]]; then
		return 0
	fi

	_TIER_LOOKUP_FILE="$(mktemp)"

	# Load default config first
	_parse_tier_config "$NET_TIER_DEFAULT_CONF" "$_TIER_LOOKUP_FILE"

	# Load user overrides (appended after defaults — last match wins)
	_parse_tier_config "$NET_TIER_USER_CONF" "$_TIER_LOOKUP_FILE"

	_TIER_DATA_LOADED="1"
	return 0
}

# Clean up the temp lookup file on exit.
_cleanup_tier_data() {
	if [[ -n "${_TIER_LOOKUP_FILE:-}" && -f "${_TIER_LOOKUP_FILE:-}" ]]; then
		rm -f "$_TIER_LOOKUP_FILE"
	fi
	return 0
}
trap '_cleanup_tier_data' EXIT

# Look up a domain in the tier lookup file.
# Returns the tier number for the last matching entry (user overrides win).
# Arguments:
#   $1 - lookup key (e.g., "exact:github.com" or "wild:github.com")
# Output: tier number on stdout, or empty if no match
_tier_lookup() {
	local key="$1"

	if [[ -z "${_TIER_LOOKUP_FILE:-}" || ! -f "${_TIER_LOOKUP_FILE:-}" ]]; then
		return 0
	fi

	# Exact string match via awk (avoids regex injection from domain names)
	# Last match wins (user override), so we don't exit early
	local result
	result="$(awk -v k="${key} " 'index($0, k) == 1 { val = $NF } END { if (val) print val }' "$_TIER_LOOKUP_FILE")" || true
	if [[ -n "$result" ]]; then
		printf '%s' "$result"
	fi

	return 0
}

# Count entries in the lookup file by type.
# Arguments:
#   $1 - type prefix ("exact" or "wild")
# Output: count on stdout
_tier_count() {
	local type_prefix="$1"

	if [[ -z "${_TIER_LOOKUP_FILE:-}" || ! -f "${_TIER_LOOKUP_FILE:-}" ]]; then
		echo "0"
		return 0
	fi

	grep -c "^${type_prefix}:" "$_TIER_LOOKUP_FILE" || echo "0"
	return 0
}

# =============================================================================
# Domain Classification
# =============================================================================

# Check if a string looks like a raw IP address (IPv4 or IPv6).
# Raw IPs are Tier 5 (denied) — legitimate services use hostnames.
# Arguments:
#   $1 - string to check
# Returns: 0 if IP address, 1 if hostname
_is_raw_ip() {
	local host="$1"

	# IPv4: digits and dots only, 4 octets
	if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		return 0
	fi

	# IPv6: contains colons (simplified check)
	if [[ "$host" == *:* ]]; then
		return 0
	fi

	return 1
}

# Check if a domain has a suspicious TLD (Tier 5).
# Arguments:
#   $1 - domain
# Returns: 0 if suspicious, 1 if normal
_is_suspicious_tld() {
	local domain="$1"

	case "$domain" in
	*.onion | *.bit | *.i2p)
		return 0
		;;
	esac

	return 1
}

# Classify a domain into its network tier.
# Arguments:
#   $1 - domain or hostname (e.g., "api.github.com", "evil.ngrok.io")
# Output: tier number (1-5) on stdout
# Returns: 0 always
classify_domain() {
	local domain="$1"

	# Normalize: lowercase, strip port, strip protocol, strip trailing dot
	domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
	domain="${domain#*://}"
	domain="${domain%%:*}"
	domain="${domain%%/*}"
	domain="${domain%.}"

	if [[ -z "$domain" ]]; then
		echo "4"
		return 0
	fi

	# Rule 1: Raw IP addresses → Tier 5 (deny)
	if _is_raw_ip "$domain"; then
		echo "5"
		return 0
	fi

	# Rule 2: Suspicious TLDs → Tier 5 (deny)
	if _is_suspicious_tld "$domain"; then
		echo "5"
		return 0
	fi

	# Load tier data if not already loaded
	_load_tier_data

	# Rule 3: Exact match
	local tier
	tier="$(_tier_lookup "exact:${domain}")"
	if [[ -n "$tier" ]]; then
		echo "$tier"
		return 0
	fi

	# Rule 4: Wildcard match — walk up the domain hierarchy
	# For "api.sub.example.com", check: sub.example.com, example.com
	local check_domain="$domain"
	while [[ "$check_domain" == *.* ]]; do
		# Strip the leftmost label
		check_domain="${check_domain#*.}"
		tier="$(_tier_lookup "wild:${check_domain}")"
		if [[ -n "$tier" ]]; then
			echo "$tier"
			return 0
		fi
	done

	# Rule 5: No match → Tier 4 (unknown, allowed but flagged)
	echo "4"
	return 0
}

# Human-readable tier label.
# Arguments:
#   $1 - tier number (1-5)
tier_label() {
	local tier="$1"
	case "$tier" in
	1) echo "ALLOW" ;;
	2) echo "ALLOW+LOG" ;;
	3) echo "ALLOW+LOG" ;;
	4) echo "ALLOW+FLAG" ;;
	5) echo "DENY" ;;
	*) echo "UNKNOWN" ;;
	esac
	return 0
}

# =============================================================================
# Quarantine Integration (t1428.4)
# =============================================================================
# Sends Tier 4 (unknown/flagged) domains to the quarantine queue for human
# review. The quarantine-helper.sh learn command feeds decisions back into
# network-tiers-custom.conf (allow → Tier 3, deny → Tier 5).

readonly _NT_QUARANTINE_HELPER="${SCRIPT_DIR}/quarantine-helper.sh"

# Send a Tier 4 domain to the quarantine queue.
_nt_quarantine_domain() {
	local domain="$1"
	local worker_id="$2"

	if [[ ! -x "$_NT_QUARANTINE_HELPER" ]]; then
		return 0
	fi

	"$_NT_QUARANTINE_HELPER" add \
		--source network-tier \
		--severity MEDIUM \
		--category unknown_domain \
		--content "$domain" \
		--worker-id "$worker_id" \
		>/dev/null 2>&1 || true

	return 0
}

# =============================================================================
# Access Logging
# =============================================================================

# Log a network access event to the appropriate JSONL log file.
# Arguments:
#   $1 - domain
#   $2 - worker ID (e.g., "worker-abc123")
#   $3 - HTTP status code or "blocked" (optional, default "")
#   $4 - URL path (optional, default "")
log_access() {
	local domain="$1"
	local worker_id="${2:-unknown}"
	local status_code="${3:-}"
	local url_path="${4:-}"

	local tier
	tier=$(classify_domain "$domain")
	local label
	label=$(tier_label "$tier")
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# Ensure log directory exists
	mkdir -p "$NET_TIER_DIR" 2>/dev/null || true

	# Helper to escape JSON quotes and strip newlines (prevents log injection)
	_escape_json() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

	# Build JSON record (portable — no jq dependency for writing)
	local record
	record=$(printf '{"ts":"%s","domain":"%s","tier":%s,"label":"%s","worker":"%s","status":"%s","path":"%s"}' \
		"$timestamp" \
		"$(_escape_json "$domain")" \
		"$tier" \
		"$label" \
		"$(_escape_json "$worker_id")" \
		"$(_escape_json "$status_code")" \
		"$(_escape_json "${url_path:0:500}")")

	# Route to appropriate log based on tier
	case "$tier" in
	1)
		# Tier 1: no logging (core infrastructure, high volume)
		return 0
		;;
	2 | 3)
		# Tier 2-3: log to main access log
		echo "$record" >>"$NET_TIER_LOG"
		;;
	4)
		# Tier 4: log to both access and flagged logs
		echo "$record" >>"$NET_TIER_LOG"
		echo "$record" >>"$NET_TIER_FLAGGED_LOG"
		log_warn "Tier 4 (unknown domain): ${domain} by ${worker_id}"
		# Quarantine for human review (t1428.4)
		_nt_quarantine_domain "$domain" "$worker_id"
		;;
	5)
		# Tier 5: log to denied log (access was blocked)
		echo "$record" >>"$NET_TIER_DENIED_LOG"
		log_error "Tier 5 (DENIED): ${domain} by ${worker_id}"
		;;
	esac

	return 0
}

# =============================================================================
# Access Check (for sandbox integration)
# =============================================================================

# Check if a domain should be allowed or denied.
# Arguments:
#   $1 - domain
# Returns: 0 if allowed (Tiers 1-4), 1 if denied (Tier 5)
# Output: tier classification info on stderr
check_domain() {
	local domain="$1"

	local tier
	tier=$(classify_domain "$domain")

	if [[ "$tier" -eq 5 ]]; then
		log_error "BLOCKED: ${domain} (Tier 5: DENY)"
		return 1
	fi

	if [[ "$tier" -eq 4 ]]; then
		log_warn "FLAGGED: ${domain} (Tier 4: unknown domain)"
	fi

	return 0
}

# Session-aware domain check (t1428.3).
# Checks the session security context for taint signals. If the session is
# tainted (sensitive data was accessed), the effective tier is elevated —
# domains that would normally be allowed may be denied.
# Arguments:
#   $1 - domain
#   Remaining args scanned for --session-id
# Returns: 0 if allowed, 1 if denied (base or elevated)
# Output: tier info on stderr
check_domain_session() {
	local domain="$1"
	shift || true

	# Parse --session-id from remaining args
	local session_id=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-id)
			session_id="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# If no session ID, fall back to standard check
	if [[ -z "$session_id" ]]; then
		check_domain "$domain"
		return $?
	fi

	# Get session-elevated tier from session-security-helper.sh
	local session_helper="${SCRIPT_DIR}/session-security-helper.sh"
	local effective_tier

	if [[ -x "$session_helper" ]]; then
		effective_tier=$("$session_helper" elevate-tier "$domain" --session-id "$session_id" 2>/dev/null) || effective_tier=""
	fi

	# Fall back to base classification if session helper unavailable
	if [[ -z "$effective_tier" ]]; then
		effective_tier=$(classify_domain "$domain")
	fi

	local base_tier
	base_tier=$(classify_domain "$domain")

	if [[ "$effective_tier" -eq 5 ]]; then
		if [[ "$base_tier" -ne 5 ]]; then
			log_error "BLOCKED (session-elevated): ${domain} T${base_tier}→T5 (session tainted)"
		else
			log_error "BLOCKED: ${domain} (Tier 5: DENY)"
		fi
		# Record the network flag in session context
		if [[ -x "$session_helper" ]]; then
			"$session_helper" record-signal "network-flag" "HIGH" \
				"Blocked domain ${domain} (base=T${base_tier}, effective=T${effective_tier})" \
				--session-id "$session_id" 2>/dev/null || true
		fi
		return 1
	fi

	if [[ "$effective_tier" -eq 4 ]]; then
		log_warn "FLAGGED: ${domain} (Tier 4: unknown domain)"
		# Record tier 4 access in session context as LOW signal
		if [[ -x "$session_helper" ]]; then
			"$session_helper" record-signal "network-flag" "LOW" \
				"Unknown domain ${domain} (T4)" \
				--session-id "$session_id" 2>/dev/null || true
		fi
	fi

	return 0
}

# =============================================================================
# Reporting
# =============================================================================

# Generate a report of network access events.
# Arguments:
#   --last N          Show last N entries (default: 50)
#   --flagged-only    Show only Tier 4 (flagged) entries
#   --denied-only     Show only Tier 5 (denied) entries
#   --summary         Show domain frequency summary
report() {
	local last_n=50
	local mode="all"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--last)
			last_n="$2"
			shift 2
			;;
		--flagged-only)
			mode="flagged"
			shift
			;;
		--denied-only)
			mode="denied"
			shift
			;;
		--summary)
			mode="summary"
			shift
			;;
		*) shift ;;
		esac
	done

	local log_file
	case "$mode" in
	flagged) log_file="$NET_TIER_FLAGGED_LOG" ;;
	denied) log_file="$NET_TIER_DENIED_LOG" ;;
	*) log_file="$NET_TIER_LOG" ;;
	esac

	if [[ "$mode" == "summary" ]]; then
		_report_summary "$last_n"
		return 0
	fi

	if [[ ! -f "$log_file" ]]; then
		echo "No network access logs found."
		echo "Log location: ${log_file}"
		return 0
	fi

	echo "Network access report (${mode}, last ${last_n}):"
	echo "---"

	tail -n "$last_n" "$log_file" | while IFS= read -r line; do
		local ts domain tier label worker
		ts="$(printf '%s' "$line" | jq -r '.ts // "?"' || true)"
		domain="$(printf '%s' "$line" | jq -r '.domain // "?"' || true)"
		tier="$(printf '%s' "$line" | jq -r '.tier // "?"' || true)"
		label="$(printf '%s' "$line" | jq -r '.label // "?"' || true)"
		worker="$(printf '%s' "$line" | jq -r '.worker // "?"' || true)"
		printf '%s  T%s %-12s %-40s %s\n' "$ts" "$tier" "$label" "$domain" "$worker"
	done

	return 0
}

# Summary report: unique domains by tier with frequency counts.
_report_summary() {
	local last_n="$1"

	echo "Network tier summary (from all logs):"
	echo "---"

	local log_file
	for log_file in "$NET_TIER_LOG" "$NET_TIER_FLAGGED_LOG" "$NET_TIER_DENIED_LOG"; do
		[[ ! -f "$log_file" ]] && continue
		local label
		label="$(basename "$log_file" .jsonl)"
		echo ""
		echo "=== ${label} ==="
		{ tail -n "$last_n" "$log_file" |
			jq -r '[.domain, (.tier | tostring)] | join(" T")' || true; } |
			sort | uniq -c | sort -rn | head -20
	done

	# Show flagged domain count
	if [[ -f "$NET_TIER_FLAGGED_LOG" ]]; then
		local flagged_count
		flagged_count="$(wc -l <"$NET_TIER_FLAGGED_LOG" | tr -d ' ')"
		echo ""
		echo "Total flagged (Tier 4) domains: ${flagged_count}"
	fi

	if [[ -f "$NET_TIER_DENIED_LOG" ]]; then
		local denied_count
		denied_count="$(wc -l <"$NET_TIER_DENIED_LOG" | tr -d ' ')"
		echo "Total denied (Tier 5) attempts: ${denied_count}"
	fi

	return 0
}

# =============================================================================
# Init
# =============================================================================

# Initialize log directories and validate configuration.
init() {
	mkdir -p "$NET_TIER_DIR" 2>/dev/null || true

	# Validate default config exists
	if [[ ! -r "$NET_TIER_DEFAULT_CONF" ]]; then
		log_error "Default config not found: ${NET_TIER_DEFAULT_CONF}"
		echo "Run 'aidevops update' to restore default configuration."
		return 1
	fi

	# Load and validate tier data
	_load_tier_data

	local exact_count
	exact_count="$(_tier_count "exact")"
	local wildcard_count
	wildcard_count="$(_tier_count "wild")"

	log_success "Network tier configuration loaded"
	echo "  Default config: ${NET_TIER_DEFAULT_CONF}"
	echo "  User overrides: ${NET_TIER_USER_CONF} ($([ -f "$NET_TIER_USER_CONF" ] && echo "present" || echo "not set"))"
	echo "  Exact domains:  ${exact_count}"
	echo "  Wildcard rules: ${wildcard_count}"
	echo "  Log directory:  ${NET_TIER_DIR}"

	# Quick self-test
	local test_results=0
	_self_test || test_results=$?
	if [[ $test_results -ne 0 ]]; then
		log_error "Self-test failed"
		return 1
	fi

	log_success "Self-test passed"
	return 0
}

# Quick self-test to verify classification works correctly.
_self_test() {
	local failures=0

	# Tier 1: github.com
	local result
	result=$(classify_domain "github.com")
	if [[ "$result" != "1" ]]; then
		log_error "Self-test: github.com expected tier 1, got tier ${result}"
		((++failures))
	fi

	# Tier 1: api.github.com (wildcard *.github.com)
	result=$(classify_domain "api.github.com")
	if [[ "$result" != "1" ]]; then
		log_error "Self-test: api.github.com expected tier 1, got tier ${result}"
		((++failures))
	fi

	# Tier 2: registry.npmjs.org
	result=$(classify_domain "registry.npmjs.org")
	if [[ "$result" != "2" ]]; then
		log_error "Self-test: registry.npmjs.org expected tier 2, got tier ${result}"
		((++failures))
	fi

	# Tier 3: sonarcloud.io
	result=$(classify_domain "sonarcloud.io")
	if [[ "$result" != "3" ]]; then
		log_error "Self-test: sonarcloud.io expected tier 3, got tier ${result}"
		((++failures))
	fi

	# Tier 4: unknown domain
	result=$(classify_domain "totally-unknown-domain.example.net")
	if [[ "$result" != "4" ]]; then
		log_error "Self-test: unknown domain expected tier 4, got tier ${result}"
		((++failures))
	fi

	# Tier 5: ngrok.io (deny list)
	result=$(classify_domain "evil.ngrok.io")
	if [[ "$result" != "5" ]]; then
		log_error "Self-test: evil.ngrok.io expected tier 5, got tier ${result}"
		((++failures))
	fi

	# Tier 5: raw IP
	result=$(classify_domain "192.168.1.1")
	if [[ "$result" != "5" ]]; then
		log_error "Self-test: raw IP expected tier 5, got tier ${result}"
		((++failures))
	fi

	# Tier 5: .onion TLD
	result=$(classify_domain "hidden.onion")
	if [[ "$result" != "5" ]]; then
		log_error "Self-test: .onion expected tier 5, got tier ${result}"
		((++failures))
	fi

	# URL normalization: strip protocol and port
	result=$(classify_domain "https://github.com:443/foo/bar")
	if [[ "$result" != "1" ]]; then
		log_error "Self-test: URL normalization expected tier 1, got tier ${result}"
		((++failures))
	fi

	if [[ $failures -gt 0 ]]; then
		return 1
	fi

	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'HELP'
network-tier-helper.sh — Network domain tiering for worker sandboxing (t1412.3)

Commands:
  classify <domain>          Classify domain into tier (1-5)
  check <domain>             Check if domain is allowed (exit 0) or denied (exit 1)
  check-session <domain> [--session-id ID]
                             Session-aware check — elevates tier if session
                             is tainted (t1428.3). Falls back to check if
                             no session ID or session helper unavailable.
  log-access <domain> [worker-id] [status] [path]
                             Log a network access event
  report [options]           Show network access report
  init                       Initialize and validate configuration
  help                       Show this help

Report options:
  --last N                   Show last N entries (default: 50)
  --flagged-only             Show only Tier 4 (unknown/flagged) entries
  --denied-only              Show only Tier 5 (denied) entries
  --summary                  Show domain frequency summary

Tier model:
  Tier 1  ALLOW       Core infrastructure (github.com) — no logging
  Tier 2  ALLOW+LOG   Package registries (npmjs, pypi) — logged
  Tier 3  ALLOW+LOG   Known tools/docs (sonarcloud, anthropic) — logged
  Tier 4  ALLOW+FLAG  Unknown domains — allowed but flagged for review
  Tier 5  DENY        Exfiltration indicators — blocked

Config files:
  Default: .agents/configs/network-tiers.conf
  Custom:  ~/.config/aidevops/network-tiers-custom.conf

Log files:
  Access:  ~/.aidevops/.agent-workspace/network/access.jsonl
  Flagged: ~/.aidevops/.agent-workspace/network/flagged.jsonl
  Denied:  ~/.aidevops/.agent-workspace/network/denied.jsonl

Examples:
  network-tier-helper.sh classify api.github.com
  # Output: 1

  network-tier-helper.sh check requestbin.com
  # Exit 1 (denied)

  network-tier-helper.sh log-access pypi.org worker-abc 200 /simple/requests/
  network-tier-helper.sh report --flagged-only --last 20
  network-tier-helper.sh report --summary

Integration with sandbox-exec-helper.sh:
  Before network access, call:
    if network-tier-helper.sh check "$domain"; then
      # proceed with request
      network-tier-helper.sh log-access "$domain" "$WORKER_ID" "$status"
    fi

Session-aware integration (t1428.3):
  # Check with session taint elevation
  if network-tier-helper.sh check-session "$domain" --session-id "$SESSION_ID"; then
    # proceed — tier may have been elevated if session is tainted
    network-tier-helper.sh log-access "$domain" "$WORKER_ID" "$status"
  fi
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	classify)
		if [[ -z "${1:-}" ]]; then
			log_error "Domain required. Usage: network-tier-helper.sh classify <domain>"
			return 1
		fi
		classify_domain "$1"
		;;
	check)
		if [[ -z "${1:-}" ]]; then
			log_error "Domain required. Usage: network-tier-helper.sh check <domain>"
			return 1
		fi
		check_domain "$1"
		;;
	check-session)
		if [[ -z "${1:-}" ]]; then
			log_error "Domain required. Usage: network-tier-helper.sh check-session <domain> [--session-id ID]"
			return 1
		fi
		check_domain_session "$@"
		;;
	log-access | log)
		if [[ -z "${1:-}" ]]; then
			log_error "Domain required. Usage: network-tier-helper.sh log-access <domain> [worker-id] [status] [path]"
			return 1
		fi
		log_access "${1:-}" "${2:-unknown}" "${3:-}" "${4:-}"
		;;
	report)
		report "$@"
		;;
	init)
		init
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: ${cmd}"
		show_help
		return 1
		;;
	esac
}

main "$@"
