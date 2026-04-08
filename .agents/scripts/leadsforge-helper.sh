#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# leadsforge-helper.sh — LeadsForge B2B lead search and enrichment CLI
# Wraps the LeadsForge REST API (api.leadsforge.ai/public/) for lead search,
# enrichment, and export from the command line.
#
# Usage:
#   leadsforge-helper.sh search --icp "Marketing managers in SaaS companies in the US"
#   leadsforge-helper.sh enrich --email "john@example.com"
#   leadsforge-helper.sh enrich --linkedin "https://linkedin.com/in/johndoe"
#   leadsforge-helper.sh lookalikes --domain "salesforce.com"
#   leadsforge-helper.sh followers --domain "salesforce.com"
#   leadsforge-helper.sh credits
#   leadsforge-helper.sh export --list-id "abc123" --format csv
#
# Environment / Secrets:
#   LEADSFORGE_API_KEY — set directly, or resolved from gopass/credentials.sh
#   gopass path: aidevops/leadsforge-api-key
#
# Exit codes: 0=success, 1=error, 2=missing API key

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

LOG_PREFIX="LEADSFORGE"

# =============================================================================
# Configuration
# =============================================================================

readonly LEADSFORGE_API_BASE="${LEADSFORGE_API_BASE:-https://api.leadsforge.ai/public}"
readonly LEADSFORGE_REPORTS_DIR="${HOME}/.aidevops/reports/leadsforge"
readonly LEADSFORGE_DEFAULT_LIMIT="${LEADSFORGE_DEFAULT_LIMIT:-25}"

mkdir -p "$LEADSFORGE_REPORTS_DIR"

# =============================================================================
# Credential Resolution
# =============================================================================

#######################################
# Resolve LeadsForge API key from available sources
# Priority: env var > gopass > credentials.sh
# Output: API key on stdout
# Returns: 0 if found, 1 if not
#######################################
resolve_api_key() {
	# 1. Environment variable
	if [[ -n "${LEADSFORGE_API_KEY:-}" ]]; then
		echo "$LEADSFORGE_API_KEY"
		return 0
	fi

	# 2. gopass
	if command -v gopass &>/dev/null; then
		local key
		key=$(gopass show -o "aidevops/leadsforge-api-key" 2>/dev/null) || true
		if [[ -n "$key" ]]; then
			echo "$key"
			return 0
		fi
	fi

	# 3. credentials.sh
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]]; then
		local key
		key=$(grep -E '^LEADSFORGE_API_KEY=' "$creds_file" 2>/dev/null | cut -d= -f2- | tr -d '"'"'" || true)
		if [[ -n "$key" ]]; then
			echo "$key"
			return 0
		fi
	fi

	return 1
}

# =============================================================================
# Dependency Checks
# =============================================================================

check_deps() {
	local missing=0

	if ! command -v curl &>/dev/null; then
		print_error "curl is required"
		missing=1
	fi

	if ! command -v jq &>/dev/null; then
		print_error "jq is required for JSON parsing"
		print_info "Install: brew install jq"
		missing=1
	fi

	if [[ $missing -ne 0 ]]; then
		return 1
	fi
	return 0
}

# =============================================================================
# Core API Call
# =============================================================================

#######################################
# Make an authenticated LeadsForge API request
# Arguments:
#   $1 — HTTP method (GET, POST)
#   $2 — endpoint path (e.g. /search)
#   $3 — JSON body (optional, for POST)
# Output: raw JSON response on stdout
# Returns: 0 on success, 1 on HTTP/network error, 2 on auth error
#######################################
api_call() {
	local method="$1"
	local endpoint="$2"
	local body="${3:-}"

	local api_key
	api_key=$(resolve_api_key) || {
		print_error "No LeadsForge API key found."
		print_info "Set via: aidevops secret set LEADSFORGE_API_KEY"
		print_info "Or export LEADSFORGE_API_KEY=<key> in your shell"
		return 2
	}

	local url="${LEADSFORGE_API_BASE}${endpoint}"
	local curl_args=(
		-sS
		--max-time 60
		-H "Authorization: Bearer ${api_key}"
		-H "${CONTENT_TYPE_JSON}"
		-H "${USER_AGENT}"
		-X "$method"
	)

	if [[ -n "$body" ]]; then
		curl_args+=(-d "$body")
	fi

	local response
	local http_code
	http_code=$(curl "${curl_args[@]}" -o /tmp/leadsforge_response.json -w "%{http_code}" "$url" 2>/dev/null) || {
		print_error "Network error calling LeadsForge API"
		return 1
	}

	local response_body
	response_body=$(cat /tmp/leadsforge_response.json 2>/dev/null || echo "{}")
	rm -f /tmp/leadsforge_response.json

	case "$http_code" in
	200 | 201 | 202)
		echo "$response_body"
		return 0
		;;
	401 | 403)
		print_error "Authentication failed (HTTP $http_code). Check your API key."
		return 2
		;;
	429)
		print_error "Rate limit exceeded (HTTP 429). Wait before retrying."
		return 1
		;;
	404)
		print_error "Endpoint not found (HTTP 404): ${endpoint}"
		return 1
		;;
	*)
		local err_msg
		err_msg=$(echo "$response_body" | jq -r '.message // .error // empty' 2>/dev/null || echo "")
		if [[ -n "$err_msg" ]]; then
			print_error "API error (HTTP $http_code): $err_msg"
		else
			print_error "API error (HTTP $http_code)"
		fi
		return 1
		;;
	esac
}

# =============================================================================
# Commands
# =============================================================================

#######################################
# Search for leads by ICP description
# Arguments:
#   --icp TEXT     — natural language ICP description (required)
#   --limit N      — max results (default: 25)
#   --enrich       — also enrich with email/LinkedIn (flag)
#   --output FILE  — save JSON to file
#######################################
cmd_search() {
	local icp=""
	local limit="$LEADSFORGE_DEFAULT_LIMIT"
	local enrich=false
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--icp)
			icp="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--enrich)
			enrich=true
			shift
			;;
		--output)
			output_file="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$icp" ]]; then
		print_error "--icp is required"
		print_info "Example: leadsforge-helper.sh search --icp \"CTOs at Series A SaaS companies in the US\""
		return 1
	fi

	print_info "Searching for leads: $icp"

	local body
	body=$(jq -n \
		--arg icp "$icp" \
		--argjson limit "$limit" \
		--argjson enrich "$enrich" \
		'{
			query: $icp,
			limit: $limit,
			enrich: $enrich
		}')

	local response
	response=$(api_call POST "/search" "$body") || return $?

	local count
	count=$(echo "$response" | jq -r '.total // (.leads | length) // 0' 2>/dev/null || echo "0")
	print_success "Found ${count} leads"

	if [[ -n "$output_file" ]]; then
		echo "$response" >"$output_file"
		print_info "Saved to: $output_file"
	else
		echo "$response" | jq '.'
	fi

	return 0
}

#######################################
# Enrich a contact by email or LinkedIn URL
# Arguments:
#   --email EMAIL        — email address to enrich
#   --linkedin URL       — LinkedIn profile URL to enrich
#   --output FILE        — save JSON to file
#######################################
cmd_enrich() {
	local email=""
	local linkedin=""
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--email)
			email="$2"
			shift 2
			;;
		--linkedin)
			linkedin="$2"
			shift 2
			;;
		--output)
			output_file="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$email" && -z "$linkedin" ]]; then
		print_error "Either --email or --linkedin is required"
		return 1
	fi

	local body
	local response
	if [[ -n "$email" ]]; then
		print_info "Enriching contact by email: $email"
		body=$(jq -n --arg email "$email" '{email: $email}')
		response=$(api_call POST "/enrich/email" "$body") || return $?
	else
		print_info "Enriching contact by LinkedIn: $linkedin"
		body=$(jq -n --arg url "$linkedin" '{linkedin_url: $url}')
		response=$(api_call POST "/enrich/linkedin" "$body") || return $?
	fi

	if [[ -n "$output_file" ]]; then
		echo "$response" >"$output_file"
		print_success "Saved to: $output_file"
	else
		echo "$response" | jq '.'
	fi

	return 0
}

#######################################
# Find company lookalikes by domain
# Arguments:
#   --domain DOMAIN    — company domain (required)
#   --limit N          — max results (default: 25)
#   --output FILE      — save JSON to file
#######################################
cmd_lookalikes() {
	local domain=""
	local limit="$LEADSFORGE_DEFAULT_LIMIT"
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--domain)
			domain="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--output)
			output_file="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$domain" ]]; then
		print_error "--domain is required"
		print_info "Example: leadsforge-helper.sh lookalikes --domain salesforce.com"
		return 1
	fi

	print_info "Finding company lookalikes for: $domain"

	local body
	body=$(jq -n \
		--arg domain "$domain" \
		--argjson limit "$limit" \
		'{domain: $domain, limit: $limit}')

	local response
	response=$(api_call POST "/lookalikes" "$body") || return $?

	local count
	count=$(echo "$response" | jq -r '.total // (.companies | length) // 0' 2>/dev/null || echo "0")
	print_success "Found ${count} lookalike companies"

	if [[ -n "$output_file" ]]; then
		echo "$response" >"$output_file"
		print_info "Saved to: $output_file"
	else
		echo "$response" | jq '.'
	fi

	return 0
}

#######################################
# Find LinkedIn company page followers
# Arguments:
#   --domain DOMAIN    — company domain (required)
#   --limit N          — max results (default: 25)
#   --output FILE      — save JSON to file
#######################################
cmd_followers() {
	local domain=""
	local limit="$LEADSFORGE_DEFAULT_LIMIT"
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--domain)
			domain="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--output)
			output_file="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$domain" ]]; then
		print_error "--domain is required"
		print_info "Example: leadsforge-helper.sh followers --domain salesforce.com"
		return 1
	fi

	print_info "Finding LinkedIn followers for: $domain"

	local body
	body=$(jq -n \
		--arg domain "$domain" \
		--argjson limit "$limit" \
		'{domain: $domain, limit: $limit}')

	local response
	response=$(api_call POST "/followers" "$body") || return $?

	local count
	count=$(echo "$response" | jq -r '.total // (.followers | length) // 0' 2>/dev/null || echo "0")
	print_success "Found ${count} followers"

	if [[ -n "$output_file" ]]; then
		echo "$response" >"$output_file"
		print_info "Saved to: $output_file"
	else
		echo "$response" | jq '.'
	fi

	return 0
}

#######################################
# Check remaining credits
#######################################
cmd_credits() {
	print_info "Checking LeadsForge credit balance..."

	local response
	response=$(api_call GET "/credits") || return $?

	local credits
	credits=$(echo "$response" | jq -r '.credits // .balance // .remaining // empty' 2>/dev/null || echo "")

	if [[ -n "$credits" ]]; then
		print_success "Remaining credits: $credits"
	else
		echo "$response" | jq '.'
	fi

	return 0
}

#######################################
# Export a saved lead list
# Arguments:
#   --list-id ID       — list ID to export (required)
#   --format FORMAT    — csv or json (default: json)
#   --output FILE      — save to file (default: stdout)
#######################################
cmd_export() {
	local list_id=""
	local format="json"
	local output_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--list-id)
			list_id="$2"
			shift 2
			;;
		--format)
			format="$2"
			shift 2
			;;
		--output)
			output_file="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$list_id" ]]; then
		print_error "--list-id is required"
		return 1
	fi

	print_info "Exporting list: $list_id (format: $format)"

	local response
	response=$(api_call GET "/lists/${list_id}/export?format=${format}") || return $?

	if [[ -n "$output_file" ]]; then
		echo "$response" >"$output_file"
		print_success "Exported to: $output_file"
	else
		echo "$response"
	fi

	return 0
}

#######################################
# Store API key securely
#######################################
cmd_setup() {
	print_info "LeadsForge API key setup"
	print_info "Get your API key from: https://app.leadsforge.ai/settings/api"
	echo ""
	print_info "To store securely via gopass:"
	echo "  gopass insert aidevops/leadsforge-api-key"
	echo ""
	print_info "Or export in your shell profile:"
	echo "  export LEADSFORGE_API_KEY=<your-key>"
	echo ""
	print_info "WARNING: Never paste API key values into AI chat. Run the above commands in your terminal."
	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'EOF'
leadsforge-helper.sh — LeadsForge B2B lead search and enrichment CLI

Usage: leadsforge-helper.sh <command> [options]

Commands:
  search      Search for leads by ICP description
  enrich      Enrich a contact by email or LinkedIn URL
  lookalikes  Find companies similar to a given domain
  followers   Find LinkedIn company page followers
  credits     Check remaining credit balance
  export      Export a saved lead list
  setup       Show API key setup instructions
  help        Show this help

Options for search:
  --icp TEXT      Natural language ICP description (required)
  --limit N       Max results (default: 25)
  --enrich        Also enrich with email/LinkedIn
  --output FILE   Save JSON output to file

Options for enrich:
  --email EMAIL   Email address to enrich
  --linkedin URL  LinkedIn profile URL to enrich
  --output FILE   Save JSON output to file

Options for lookalikes:
  --domain DOMAIN Company domain (required)
  --limit N       Max results (default: 25)
  --output FILE   Save JSON output to file

Followers options:
  --domain DOMAIN Company domain (required)
  --limit N       Max results (default: 25)
  --output FILE   Save JSON output to file

Export options:
  --list-id ID    List ID to export (required)
  --format FORMAT csv or json (default: json)
  --output FILE   Save to file

Environment:
  LEADSFORGE_API_KEY   API key (or use gopass: aidevops/leadsforge-api-key)
  LEADSFORGE_API_BASE  Override API base URL (default: https://api.leadsforge.ai/public)
  LEADSFORGE_DEFAULT_LIMIT  Default result limit (default: 25)

Examples:
  leadsforge-helper.sh search --icp "CTOs at Series A SaaS companies in the US" --limit 50
  leadsforge-helper.sh enrich --email "john@example.com"
  leadsforge-helper.sh enrich --linkedin "https://linkedin.com/in/johndoe"
  leadsforge-helper.sh lookalikes --domain "salesforce.com" --limit 10
  leadsforge-helper.sh followers --domain "hubspot.com"
  leadsforge-helper.sh credits
  leadsforge-helper.sh export --list-id "abc123" --format csv --output leads.csv
EOF
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	search)
		check_deps || return 1
		cmd_search "$@"
		;;
	enrich)
		check_deps || return 1
		cmd_enrich "$@"
		;;
	lookalikes)
		check_deps || return 1
		cmd_lookalikes "$@"
		;;
	followers)
		check_deps || return 1
		cmd_followers "$@"
		;;
	credits)
		check_deps || return 1
		cmd_credits "$@"
		;;
	export)
		check_deps || return 1
		cmd_export "$@"
		;;
	setup)
		cmd_setup
		;;
	help | --help | -h)
		show_help
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
	return $?
}

main "$@"
