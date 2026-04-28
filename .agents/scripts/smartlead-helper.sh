#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# smartlead-helper.sh — Smartlead cold outreach API integration
# Manages campaigns, leads, sequences, email accounts, warmup, analytics,
# webhooks, and block lists via the Smartlead REST API.
#
# Usage:
#   smartlead-helper.sh campaigns list [--client-id <id>]
#   smartlead-helper.sh campaigns get <campaign_id>
#   smartlead-helper.sh campaigns create <name> [--client-id <id>]
#   smartlead-helper.sh campaigns status <campaign_id> <START|PAUSED|STOPPED|ARCHIVED>
#   smartlead-helper.sh campaigns settings <campaign_id> [--json <settings_json>]
#   smartlead-helper.sh campaigns schedule <campaign_id> --json <schedule_json>
#   smartlead-helper.sh campaigns delete <campaign_id>
#
#   smartlead-helper.sh sequences get <campaign_id>
#   smartlead-helper.sh sequences save <campaign_id> --json <sequences_json>
#
#   smartlead-helper.sh leads add <campaign_id> --file <json_file> [--settings <json>]
#   smartlead-helper.sh leads list <campaign_id>
#   smartlead-helper.sh leads get <campaign_id> <lead_id>
#   smartlead-helper.sh leads search <email>
#   smartlead-helper.sh leads update <campaign_id> <lead_id> --json <lead_json>
#   smartlead-helper.sh leads pause <campaign_id> <lead_id>
#   smartlead-helper.sh leads resume <campaign_id> <lead_id> [--delay-days <n>]
#   smartlead-helper.sh leads delete <campaign_id> <lead_id>
#   smartlead-helper.sh leads unsubscribe <campaign_id> <lead_id>
#   smartlead-helper.sh leads unsubscribe-global <lead_id>
#   smartlead-helper.sh leads export <campaign_id> [--output <file>]
#   smartlead-helper.sh leads history <campaign_id> <lead_id>
#
#   smartlead-helper.sh accounts list [--offset <n>] [--limit <n>]
#   smartlead-helper.sh accounts get <account_id>
#   smartlead-helper.sh accounts create --json <account_json>
#   smartlead-helper.sh accounts update <account_id> --json <update_json>
#   smartlead-helper.sh accounts delete <account_id>
#   smartlead-helper.sh accounts add-to-campaign <campaign_id> --ids <id1,id2,...>
#   smartlead-helper.sh accounts campaign-list <campaign_id>
#   smartlead-helper.sh accounts remove-from-campaign <campaign_id> --ids <id1,id2,...>
#
#   smartlead-helper.sh warmup configure <account_id> --json <warmup_json>
#   smartlead-helper.sh warmup stats <account_id>
#
#   smartlead-helper.sh analytics campaign <campaign_id>
#   smartlead-helper.sh analytics campaign-stats <campaign_id>
#   smartlead-helper.sh analytics date-range <campaign_id> --start <YYYY-MM-DD> --end <YYYY-MM-DD>
#   smartlead-helper.sh analytics overview [--start <date>] [--end <date>]
#
#   smartlead-helper.sh webhooks create <campaign_id> --json <webhook_json>
#   smartlead-helper.sh webhooks list <campaign_id>
#   smartlead-helper.sh webhooks delete <campaign_id> <webhook_id>
#   smartlead-helper.sh webhooks global-create --json <webhook_json>
#   smartlead-helper.sh webhooks global-get <webhook_id>
#   smartlead-helper.sh webhooks global-update <webhook_id> --json <webhook_json>
#   smartlead-helper.sh webhooks global-delete <webhook_id>
#
#   smartlead-helper.sh blocklist add-domains --json <domains_json>
#   smartlead-helper.sh blocklist list-domains
#   smartlead-helper.sh blocklist list-emails
#
#   smartlead-helper.sh help
#
# Environment variables:
#   SMARTLEAD_API_KEY          API key (or via gopass: smartlead-api-key)
#   SMARTLEAD_BASE_URL         Base URL (default: https://server.smartlead.ai/api/v1)
#   SMARTLEAD_TIMEOUT          Request timeout in seconds (default: 30)
#   SMARTLEAD_RATE_LIMIT_DELAY Delay between requests in seconds (default: 0.2)
#
# Rate limit: Smartlead allows 10 requests per 2 seconds. The built-in delay
# of 0.2s between requests keeps usage within this limit for sequential calls.
#
# Examples:
#   smartlead-helper.sh campaigns list
#   smartlead-helper.sh campaigns create "Q1 Outreach 2026"
#   smartlead-helper.sh campaigns status 123 START
#   smartlead-helper.sh leads add 123 --file leads.json
#   smartlead-helper.sh warmup stats 456
#   smartlead-helper.sh analytics overview --start 2026-01-01 --end 2026-03-31

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
readonly SCRIPT_DIR

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

readonly SL_DEFAULT_BASE_URL="https://server.smartlead.ai/api/v1"
readonly SL_DEFAULT_TIMEOUT=30
readonly SL_DEFAULT_RATE_LIMIT_DELAY="0.2"
readonly SL_MAX_LEADS_PER_BATCH=400

# =============================================================================
# Configuration
# =============================================================================

get_api_key() {
	# Priority: env var > gopass > credentials.sh (already sourced)
	if [[ -n "${SMARTLEAD_API_KEY:-}" ]]; then
		printf '%s' "$SMARTLEAD_API_KEY"
		return 0
	fi

	# Try gopass
	if command -v gopass &>/dev/null; then
		local key
		key=$(gopass show -o "aidevops/smartlead-api-key" 2>/dev/null) || true
		if [[ -n "$key" ]]; then
			printf '%s' "$key"
			return 0
		fi
	fi

	log_error "Smartlead API key not found. Set SMARTLEAD_API_KEY or run: aidevops secret set smartlead-api-key"
	return 1
}

get_base_url() {
	printf '%s' "${SMARTLEAD_BASE_URL:-$SL_DEFAULT_BASE_URL}"
}

get_timeout() {
	printf '%s' "${SMARTLEAD_TIMEOUT:-$SL_DEFAULT_TIMEOUT}"
}

get_rate_limit_delay() {
	printf '%s' "${SMARTLEAD_RATE_LIMIT_DELAY:-$SL_DEFAULT_RATE_LIMIT_DELAY}"
}

# =============================================================================
# Logging
# =============================================================================

log_info() {
	printf '[INFO] %s\n' "$1" >&2
}

log_error() {
	printf '[ERROR] %s\n' "$1" >&2
}

log_warn() {
	printf '[WARN] %s\n' "$1" >&2
}

# =============================================================================
# HTTP / API
# =============================================================================

# Rate limit: pause between requests to stay within 10 req/2s
rate_limit_pause() {
	sleep "$(get_rate_limit_delay)"
}

# Make an API request
# Usage: api_request <method> <path> [body_json]
# Outputs response body to stdout. Returns non-zero on HTTP error.
api_request() {
	local method="$1"
	local path="$2"
	local body="${3:-}"

	local api_key
	api_key=$(get_api_key) || return 1

	local base_url
	base_url=$(get_base_url)

	local timeout
	timeout=$(get_timeout)

	# Build URL with api_key query parameter
	local url="${base_url}${path}"
	if [[ "$url" == *"?"* ]]; then
		url="${url}&api_key=${api_key}"
	else
		url="${url}?api_key=${api_key}"
	fi

	local curl_args=(
		--silent
		--show-error
		--max-time "$timeout"
		--header "Content-Type: application/json"
		--header "Accept: application/json"
		-w '\n%{http_code}'
		-X "$method"
	)

	if [[ -n "$body" ]]; then
		curl_args+=(--data "$body")
	fi

	curl_args+=("$url")

	rate_limit_pause

	local response
	response=$(curl "${curl_args[@]}" 2>&1) || {
		log_error "curl failed for ${method} ${path}"
		return 1
	}

	# Extract HTTP status code (last line) and body (everything else)
	local http_code
	http_code=$(printf '%s' "$response" | tail -n1)
	local response_body
	response_body=$(printf '%s' "$response" | sed '$d')

	# Check for HTTP errors
	case "$http_code" in
	2[0-9][0-9])
		printf '%s' "$response_body"
		return 0
		;;
	401)
		log_error "Authentication failed (401). Check your API key."
		return 1
		;;
	404)
		log_error "Resource not found (404): ${path}"
		return 1
		;;
	422)
		log_error "Validation error (422): $(printf '%s' "$response_body" | jq -r '.message // .error // "Unknown"' 2>/dev/null || printf '%s' "$response_body")"
		return 1
		;;
	429)
		log_error "Rate limit exceeded (429). Increase SMARTLEAD_RATE_LIMIT_DELAY or wait."
		return 1
		;;
	*)
		log_error "HTTP ${http_code} for ${method} ${path}: $(printf '%s' "$response_body" | jq -r '.message // .error // "Unknown"' 2>/dev/null || printf '%s' "$response_body")"
		return 1
		;;
	esac
}

# Convenience wrappers
api_get() {
	api_request GET "$@"
}

api_post() {
	api_request POST "$@"
}

api_put() {
	api_request PUT "$@"
}

api_delete() {
	api_request DELETE "$@"
}

# =============================================================================
# Sub-libraries
# =============================================================================

# shellcheck source=./smartlead-helper-campaigns.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/smartlead-helper-campaigns.sh"

# shellcheck source=./smartlead-helper-leads.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/smartlead-helper-leads.sh"

# shellcheck source=./smartlead-helper-accounts.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/smartlead-helper-accounts.sh"

# shellcheck source=./smartlead-helper-outreach.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/smartlead-helper-outreach.sh"

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'HELP'
smartlead-helper.sh — Smartlead cold outreach API integration

COMMANDS:
  campaigns     Manage campaigns (list, create, status, settings, schedule, delete)
  sequences     Manage email sequences (get, save with A/B variants)
  leads         Manage leads (add batch, list, update, pause, resume, delete, unsubscribe, export)
  accounts      Manage email accounts (list, create, update, delete, campaign assignment)
  warmup        Configure warmup and view stats
  analytics     Campaign analytics, date range, global overview
  webhooks      Campaign and global webhooks (create, list, update, delete)
  blocklist     Global block list (add domains, list domains/emails)
  help          Show this help

AUTHENTICATION:
  Set SMARTLEAD_API_KEY environment variable, or store via:
    aidevops secret set smartlead-api-key

RATE LIMITS:
  Smartlead allows 10 requests per 2 seconds. Built-in delay: 0.2s between requests.
  Adjust with SMARTLEAD_RATE_LIMIT_DELAY (seconds).

EXAMPLES:
  smartlead-helper.sh campaigns list
  smartlead-helper.sh campaigns create "Q1 Outreach 2026"
  smartlead-helper.sh campaigns status 123 START
  smartlead-helper.sh sequences get 123
  smartlead-helper.sh leads add 123 --file leads.json
  smartlead-helper.sh leads export 123 --output leads.csv
  smartlead-helper.sh accounts list --limit 50
  smartlead-helper.sh accounts add-to-campaign 123 --ids 456,457,458
  smartlead-helper.sh warmup configure 456 --json '{"warmup_enabled":true,"total_warmup_per_day":15}'
  smartlead-helper.sh warmup stats 456
  smartlead-helper.sh analytics overview --start 2026-01-01 --end 2026-03-31
  smartlead-helper.sh webhooks create 123 --json '{"name":"Reply Hook","webhook_url":"https://example.com/hook","event_types":["LEAD_REPLIED"]}'
  smartlead-helper.sh blocklist add-domains --json '{"domains":["spam.com"],"source":"manual"}'

VERSION: 1.0.0
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	# Check dependencies
	if ! command -v curl &>/dev/null; then
		log_error "curl is required but not installed"
		return 1
	fi
	if ! command -v jq &>/dev/null; then
		log_error "jq is required but not installed"
		return 1
	fi

	local command="${1:-help}"
	shift || true

	case "$command" in
	campaigns) cmd_campaigns "$@" ;;
	sequences) cmd_sequences "$@" ;;
	leads) cmd_leads "$@" ;;
	accounts) cmd_accounts "$@" ;;
	warmup) cmd_warmup "$@" ;;
	analytics) cmd_analytics "$@" ;;
	webhooks) cmd_webhooks "$@" ;;
	blocklist) cmd_blocklist "$@" ;;
	help | --help | -h) show_help ;;
	version | --version | -v) printf 'smartlead-helper.sh v%s\n' "$VERSION" ;;
	*)
		log_error "Unknown command: ${command}"
		show_help
		return 1
		;;
	esac
}

main "$@"
