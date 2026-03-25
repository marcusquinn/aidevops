#!/usr/bin/env bash
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
readonly SL_SL_MAX_LEADS_PER_BATCH=400

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
# Campaigns
# =============================================================================

cmd_campaigns() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
	list) campaigns_list "$@" ;;
	get) campaigns_get "$@" ;;
	create) campaigns_create "$@" ;;
	status) campaigns_status "$@" ;;
	settings) campaigns_settings "$@" ;;
	schedule) campaigns_schedule "$@" ;;
	delete) campaigns_delete "$@" ;;
	*)
		log_error "Unknown campaigns command: ${subcmd}"
		printf 'Usage: smartlead-helper.sh campaigns <list|get|create|status|settings|schedule|delete>\n'
		return 1
		;;
	esac
}

campaigns_list() {
	local client_id=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--client-id)
			client_id="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local path="/campaigns/"
	if [[ -n "$client_id" ]]; then
		path="/campaigns/?client_id=${client_id}"
	fi

	local result
	result=$(api_get "$path") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

campaigns_get() {
	local campaign_id="${1:-}"
	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	local result
	result=$(api_get "/campaigns/${campaign_id}") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

campaigns_create() {
	local name="${1:-}"
	local client_id=""
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--client-id)
			client_id="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local body
	if [[ -n "$client_id" ]]; then
		body=$(jq -n --arg name "$name" --argjson cid "$client_id" \
			'{name: $name, client_id: $cid}')
	elif [[ -n "$name" ]]; then
		body=$(jq -n --arg name "$name" '{name: $name}')
	else
		body='{}'
	fi

	local result
	result=$(api_post "/campaigns/create" "$body") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

campaigns_status() {
	local campaign_id="${1:-}"
	local status="${2:-}"

	if [[ -z "$campaign_id" ]] || [[ -z "$status" ]]; then
		log_error "Usage: campaigns status <campaign_id> <START|PAUSED|STOPPED|ARCHIVED>"
		return 1
	fi

	# Validate status
	case "$status" in
	START | PAUSED | STOPPED | ARCHIVED) ;;
	*)
		log_error "Invalid status: ${status}. Must be START, PAUSED, STOPPED, or ARCHIVED"
		return 1
		;;
	esac

	if [[ "$status" == "STOPPED" ]]; then
		log_warn "STOPPED is permanent and irreversible. Use PAUSED for temporary holds."
	fi

	local body
	body=$(jq -n --arg status "$status" '{status: $status}')

	local result
	result=$(api_post "/campaigns/${campaign_id}/status" "$body") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

campaigns_settings() {
	local campaign_id="${1:-}"
	local settings_json=""
	shift || true

	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			settings_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$settings_json" ]]; then
		log_error "Settings JSON required (--json)"
		return 1
	fi

	# Validate JSON
	if ! printf '%s' "$settings_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/campaigns/${campaign_id}/settings" "$settings_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

campaigns_schedule() {
	local campaign_id="${1:-}"
	local schedule_json=""
	shift || true

	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			schedule_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$schedule_json" ]]; then
		log_error "Schedule JSON required (--json)"
		return 1
	fi

	if ! printf '%s' "$schedule_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/campaigns/${campaign_id}/schedule" "$schedule_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

campaigns_delete() {
	local campaign_id="${1:-}"
	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	log_warn "This permanently deletes campaign ${campaign_id} and all associated data."

	local result
	result=$(api_delete "/campaigns/${campaign_id}") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

# =============================================================================
# Sequences
# =============================================================================

cmd_sequences() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
	get) sequences_get "$@" ;;
	save) sequences_save "$@" ;;
	*)
		log_error "Unknown sequences command: ${subcmd}"
		printf 'Usage: smartlead-helper.sh sequences <get|save>\n'
		return 1
		;;
	esac
}

sequences_get() {
	local campaign_id="${1:-}"
	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	local result
	result=$(api_get "/campaigns/${campaign_id}/sequences") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

sequences_save() {
	local campaign_id="${1:-}"
	local sequences_json=""
	shift || true

	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			sequences_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$sequences_json" ]]; then
		log_error "Sequences JSON required (--json). Provide a JSON object with a 'sequences' array."
		return 1
	fi

	if ! printf '%s' "$sequences_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/campaigns/${campaign_id}/sequences" "$sequences_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

# =============================================================================
# Leads
# =============================================================================

cmd_leads() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
	add) leads_add "$@" ;;
	list) leads_list "$@" ;;
	get) leads_get "$@" ;;
	search) leads_search "$@" ;;
	update) leads_update "$@" ;;
	pause) leads_pause "$@" ;;
	resume) leads_resume "$@" ;;
	delete) leads_delete "$@" ;;
	unsubscribe) leads_unsubscribe "$@" ;;
	unsubscribe-global) leads_unsubscribe_global "$@" ;;
	export) leads_export "$@" ;;
	history) leads_history "$@" ;;
	*)
		log_error "Unknown leads command: ${subcmd}"
		printf 'Usage: smartlead-helper.sh leads <add|list|get|search|update|pause|resume|delete|unsubscribe|unsubscribe-global|export|history>\n'
		return 1
		;;
	esac
}

# Read, validate, and return lead file content on stdout.
# Usage: _leads_add_read_file <file> [settings_json]
# Outputs validated (and settings-merged) JSON to stdout.
_leads_add_read_file() {
	local file="$1"
	local settings_json="${2:-}"

	if [[ ! -f "$file" ]]; then
		log_error "File not found: ${file}"
		return 1
	fi

	local file_content
	file_content=$(cat "$file") || {
		log_error "Failed to read file: ${file}"
		return 1
	}

	if ! printf '%s' "$file_content" | jq empty 2>/dev/null; then
		log_error "Invalid JSON in file: ${file}"
		return 1
	fi

	local lead_count
	lead_count=$(printf '%s' "$file_content" | jq '.lead_list | length' 2>/dev/null) || lead_count=0

	if [[ "$lead_count" -eq 0 ]]; then
		log_error "No leads found in file. Expected JSON with 'lead_list' array."
		return 1
	fi

	if [[ -n "$settings_json" ]]; then
		file_content=$(printf '%s' "$file_content" | jq --argjson settings "$settings_json" '. + {settings: $settings}')
	fi

	printf '%s' "$file_content"
	return 0
}

# Send leads in multiple batches and print a summary JSON.
# Usage: _leads_add_multi_batch <campaign_id> <file_content> <lead_count>
_leads_add_multi_batch() {
	local campaign_id="$1"
	local file_content="$2"
	local lead_count="$3"

	log_info "Splitting ${lead_count} leads into batches of ${SL_MAX_LEADS_PER_BATCH}"
	local offset=0
	local batch_num=0
	local total_added=0
	local total_skipped=0

	while [[ "$offset" -lt "$lead_count" ]]; do
		batch_num=$((batch_num + 1))
		local batch_body
		batch_body=$(printf '%s' "$file_content" | jq --argjson offset "$offset" --argjson limit "$SL_MAX_LEADS_PER_BATCH" \
			'.lead_list = (.lead_list[$offset:$offset+$limit])')

		local batch_size
		batch_size=$(printf '%s' "$batch_body" | jq '.lead_list | length')
		log_info "Batch ${batch_num}: sending ${batch_size} leads (offset ${offset})"

		local result
		result=$(api_post "/campaigns/${campaign_id}/leads" "$batch_body") || {
			log_error "Batch ${batch_num} failed at offset ${offset}"
			return 1
		}

		local added
		added=$(printf '%s' "$result" | jq -r '.added_count // 0')
		local skipped
		skipped=$(printf '%s' "$result" | jq -r '.skipped_count // 0')
		total_added=$((total_added + added))
		total_skipped=$((total_skipped + skipped))

		log_info "Batch ${batch_num}: added=${added}, skipped=${skipped}"
		offset=$((offset + SL_MAX_LEADS_PER_BATCH))
	done

	printf '{"total_added": %d, "total_skipped": %d, "batches": %d}\n' \
		"$total_added" "$total_skipped" "$batch_num"
	return 0
}

leads_add() {
	local campaign_id="${1:-}"
	local file=""
	local settings_json=""
	shift || true

	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--file)
			file="$2"
			shift 2
			;;
		--settings)
			settings_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$file" ]]; then
		log_error "Lead file required (--file). JSON file with a 'lead_list' array."
		return 1
	fi

	local file_content
	file_content=$(_leads_add_read_file "$file" "$settings_json") || return 1

	local lead_count
	lead_count=$(printf '%s' "$file_content" | jq '.lead_list | length' 2>/dev/null) || lead_count=0

	if [[ "$lead_count" -le "$SL_MAX_LEADS_PER_BATCH" ]]; then
		# Single batch
		local result
		result=$(api_post "/campaigns/${campaign_id}/leads" "$file_content") || return 1
		printf '%s\n' "$result" | jq '.'
	else
		_leads_add_multi_batch "$campaign_id" "$file_content" "$lead_count" || return 1
	fi
	return 0
}

leads_list() {
	local campaign_id="${1:-}"
	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	local result
	result=$(api_get "/campaigns/${campaign_id}/leads") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

leads_get() {
	local campaign_id="${1:-}"
	local lead_id="${2:-}"

	if [[ -z "$campaign_id" ]] || [[ -z "$lead_id" ]]; then
		log_error "Usage: leads get <campaign_id> <lead_id>"
		return 1
	fi

	local result
	result=$(api_get "/campaigns/${campaign_id}/leads/${lead_id}") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

leads_search() {
	local email="${1:-}"
	if [[ -z "$email" ]]; then
		log_error "Email address required"
		return 1
	fi

	local result
	result=$(api_get "/leads/?email=${email}") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

leads_update() {
	local campaign_id="${1:-}"
	local lead_id="${2:-}"
	local lead_json=""
	shift 2 || true

	if [[ -z "$campaign_id" ]] || [[ -z "$lead_id" ]]; then
		log_error "Usage: leads update <campaign_id> <lead_id> --json <lead_json>"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			lead_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$lead_json" ]]; then
		log_error "Lead JSON required (--json)"
		return 1
	fi

	if ! printf '%s' "$lead_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/campaigns/${campaign_id}/leads/${lead_id}/" "$lead_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

leads_pause() {
	local campaign_id="${1:-}"
	local lead_id="${2:-}"

	if [[ -z "$campaign_id" ]] || [[ -z "$lead_id" ]]; then
		log_error "Usage: leads pause <campaign_id> <lead_id>"
		return 1
	fi

	local result
	result=$(api_post "/campaigns/${campaign_id}/leads/${lead_id}/pause") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

leads_resume() {
	local campaign_id="${1:-}"
	local lead_id="${2:-}"
	local delay_days=""
	shift 2 || true

	if [[ -z "$campaign_id" ]] || [[ -z "$lead_id" ]]; then
		log_error "Usage: leads resume <campaign_id> <lead_id> [--delay-days <n>]"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--delay-days)
			delay_days="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local body="{}"
	if [[ -n "$delay_days" ]]; then
		body=$(jq -n --argjson days "$delay_days" '{resume_lead_with_delay_days: $days}')
	fi

	local result
	result=$(api_post "/campaigns/${campaign_id}/leads/${lead_id}/resume" "$body") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

leads_delete() {
	local campaign_id="${1:-}"
	local lead_id="${2:-}"

	if [[ -z "$campaign_id" ]] || [[ -z "$lead_id" ]]; then
		log_error "Usage: leads delete <campaign_id> <lead_id>"
		return 1
	fi

	local result
	result=$(api_delete "/campaigns/${campaign_id}/leads/${lead_id}") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

leads_unsubscribe() {
	local campaign_id="${1:-}"
	local lead_id="${2:-}"

	if [[ -z "$campaign_id" ]] || [[ -z "$lead_id" ]]; then
		log_error "Usage: leads unsubscribe <campaign_id> <lead_id>"
		return 1
	fi

	local result
	result=$(api_post "/campaigns/${campaign_id}/leads/${lead_id}/unsubscribe") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

leads_unsubscribe_global() {
	local lead_id="${1:-}"
	if [[ -z "$lead_id" ]]; then
		log_error "Lead ID required"
		return 1
	fi

	log_warn "Global unsubscribe is permanent and cannot be undone via API."

	local result
	result=$(api_post "/leads/${lead_id}/unsubscribe") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

leads_export() {
	local campaign_id="${1:-}"
	local output_file=""
	shift || true

	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output)
			output_file="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local result
	result=$(api_get "/campaigns/${campaign_id}/leads-export") || return 1

	if [[ -n "$output_file" ]]; then
		printf '%s\n' "$result" >"$output_file"
		log_info "Exported leads to ${output_file}"
	else
		printf '%s\n' "$result"
	fi
	return 0
}

leads_history() {
	local campaign_id="${1:-}"
	local lead_id="${2:-}"

	if [[ -z "$campaign_id" ]] || [[ -z "$lead_id" ]]; then
		log_error "Usage: leads history <campaign_id> <lead_id>"
		return 1
	fi

	local result
	result=$(api_get "/campaigns/${campaign_id}/leads/${lead_id}/message-history") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

# =============================================================================
# Email Accounts
# =============================================================================

cmd_accounts() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
	list) accounts_list "$@" ;;
	get) accounts_get "$@" ;;
	create) accounts_create "$@" ;;
	update) accounts_update "$@" ;;
	delete) accounts_delete "$@" ;;
	add-to-campaign) accounts_add_to_campaign "$@" ;;
	campaign-list) accounts_campaign_list "$@" ;;
	remove-from-campaign) accounts_remove_from_campaign "$@" ;;
	*)
		log_error "Unknown accounts command: ${subcmd}"
		printf 'Usage: smartlead-helper.sh accounts <list|get|create|update|delete|add-to-campaign|campaign-list|remove-from-campaign>\n'
		return 1
		;;
	esac
}

accounts_list() {
	local offset=""
	local limit=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--offset)
			offset="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local path="/email-accounts/"
	local params=""
	if [[ -n "$offset" ]]; then
		params="${params}&offset=${offset}"
	fi
	if [[ -n "$limit" ]]; then
		params="${params}&limit=${limit}"
	fi
	if [[ -n "$params" ]]; then
		path="${path}?${params:1}"
	fi

	local result
	result=$(api_get "$path") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

accounts_get() {
	local account_id="${1:-}"
	if [[ -z "$account_id" ]]; then
		log_error "Account ID required"
		return 1
	fi

	local result
	result=$(api_get "/email-accounts/${account_id}/") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

accounts_create() {
	local account_json=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			account_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$account_json" ]]; then
		log_error "Account JSON required (--json). Must include from_name, from_email, user_name, password, smtp_host, smtp_port, imap_host, imap_port."
		return 1
	fi

	if ! printf '%s' "$account_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/email-accounts/save" "$account_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

accounts_update() {
	local account_id="${1:-}"
	local update_json=""
	shift || true

	if [[ -z "$account_id" ]]; then
		log_error "Account ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			update_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$update_json" ]]; then
		log_error "Update JSON required (--json)"
		return 1
	fi

	if ! printf '%s' "$update_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/email-accounts/${account_id}" "$update_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

accounts_delete() {
	local account_id="${1:-}"
	if [[ -z "$account_id" ]]; then
		log_error "Account ID required"
		return 1
	fi

	local result
	result=$(api_delete "/email-accounts/${account_id}") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

accounts_add_to_campaign() {
	local campaign_id="${1:-}"
	local ids_csv=""
	shift || true

	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--ids)
			ids_csv="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$ids_csv" ]]; then
		log_error "Account IDs required (--ids <id1,id2,...>)"
		return 1
	fi

	# Convert comma-separated IDs to JSON array
	local ids_json
	ids_json=$(printf '%s' "$ids_csv" | tr ',' '\n' | jq -R 'tonumber' | jq -s '.')

	local body
	body=$(jq -n --argjson ids "$ids_json" '{email_account_ids: $ids}')

	local result
	result=$(api_post "/campaigns/${campaign_id}/email-accounts" "$body") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

accounts_campaign_list() {
	local campaign_id="${1:-}"
	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	local result
	result=$(api_get "/campaigns/${campaign_id}/email-accounts") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

accounts_remove_from_campaign() {
	local campaign_id="${1:-}"
	local ids_csv=""
	shift || true

	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--ids)
			ids_csv="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$ids_csv" ]]; then
		log_error "Account IDs required (--ids <id1,id2,...>)"
		return 1
	fi

	local ids_json
	ids_json=$(printf '%s' "$ids_csv" | tr ',' '\n' | jq -R 'tonumber' | jq -s '.')

	local body
	body=$(jq -n --argjson ids "$ids_json" '{email_account_ids: $ids}')

	# DELETE with body requires --data
	local result
	result=$(api_delete "/campaigns/${campaign_id}/email-accounts" "$body") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

# =============================================================================
# Warmup
# =============================================================================

cmd_warmup() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
	configure) warmup_configure "$@" ;;
	stats) warmup_stats "$@" ;;
	*)
		log_error "Unknown warmup command: ${subcmd}"
		printf 'Usage: smartlead-helper.sh warmup <configure|stats>\n'
		return 1
		;;
	esac
}

warmup_configure() {
	local account_id="${1:-}"
	local warmup_json=""
	shift || true

	if [[ -z "$account_id" ]]; then
		log_error "Account ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			warmup_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$warmup_json" ]]; then
		log_error "Warmup JSON required (--json). Fields: warmup_enabled, total_warmup_per_day, daily_rampup, reply_rate_percentage."
		return 1
	fi

	if ! printf '%s' "$warmup_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/email-accounts/${account_id}/warmup" "$warmup_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

warmup_stats() {
	local account_id="${1:-}"
	if [[ -z "$account_id" ]]; then
		log_error "Account ID required"
		return 1
	fi

	local result
	result=$(api_get "/email-accounts/${account_id}/warmup-stats") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

# =============================================================================
# Analytics
# =============================================================================

cmd_analytics() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
	campaign) analytics_campaign "$@" ;;
	campaign-stats) analytics_campaign_stats "$@" ;;
	date-range) analytics_date_range "$@" ;;
	overview) analytics_overview "$@" ;;
	*)
		log_error "Unknown analytics command: ${subcmd}"
		printf 'Usage: smartlead-helper.sh analytics <campaign|campaign-stats|date-range|overview>\n'
		return 1
		;;
	esac
}

analytics_campaign() {
	local campaign_id="${1:-}"
	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	local result
	result=$(api_get "/campaigns/${campaign_id}/analytics") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

analytics_campaign_stats() {
	local campaign_id="${1:-}"
	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	local result
	result=$(api_get "/campaigns/${campaign_id}/statistics") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

analytics_date_range() {
	local campaign_id="${1:-}"
	local start_date=""
	local end_date=""
	shift || true

	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--start)
			start_date="$2"
			shift 2
			;;
		--end)
			end_date="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local path="/campaigns/${campaign_id}/analytics-by-date"
	local params=""
	if [[ -n "$start_date" ]]; then
		params="${params}&start_date=${start_date}"
	fi
	if [[ -n "$end_date" ]]; then
		params="${params}&end_date=${end_date}"
	fi
	if [[ -n "$params" ]]; then
		path="${path}?${params:1}"
	fi

	local result
	result=$(api_get "$path") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

analytics_overview() {
	local start_date=""
	local end_date=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--start)
			start_date="$2"
			shift 2
			;;
		--end)
			end_date="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local path="/analytics/overall-stats-v2"
	local params=""
	if [[ -n "$start_date" ]]; then
		params="${params}&start_date=${start_date}"
	fi
	if [[ -n "$end_date" ]]; then
		params="${params}&end_date=${end_date}"
	fi
	if [[ -n "$params" ]]; then
		path="${path}?${params:1}"
	fi

	local result
	result=$(api_get "$path") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

# =============================================================================
# Webhooks
# =============================================================================

cmd_webhooks() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
	create) webhooks_create "$@" ;;
	list) webhooks_list "$@" ;;
	delete) webhooks_delete "$@" ;;
	global-create) webhooks_global_create "$@" ;;
	global-get) webhooks_global_get "$@" ;;
	global-update) webhooks_global_update "$@" ;;
	global-delete) webhooks_global_delete "$@" ;;
	*)
		log_error "Unknown webhooks command: ${subcmd}"
		printf 'Usage: smartlead-helper.sh webhooks <create|list|delete|global-create|global-get|global-update|global-delete>\n'
		return 1
		;;
	esac
}

webhooks_create() {
	local campaign_id="${1:-}"
	local webhook_json=""
	shift || true

	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			webhook_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$webhook_json" ]]; then
		log_error "Webhook JSON required (--json). Fields: name, webhook_url, event_types."
		return 1
	fi

	if ! printf '%s' "$webhook_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/campaigns/${campaign_id}/webhooks" "$webhook_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

webhooks_list() {
	local campaign_id="${1:-}"
	if [[ -z "$campaign_id" ]]; then
		log_error "Campaign ID required"
		return 1
	fi

	local result
	result=$(api_get "/campaigns/${campaign_id}/webhooks") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

webhooks_delete() {
	local campaign_id="${1:-}"
	local webhook_id="${2:-}"

	if [[ -z "$campaign_id" ]] || [[ -z "$webhook_id" ]]; then
		log_error "Usage: webhooks delete <campaign_id> <webhook_id>"
		return 1
	fi

	local result
	result=$(api_delete "/campaigns/${campaign_id}/webhooks/${webhook_id}") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

webhooks_global_create() {
	local webhook_json=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			webhook_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$webhook_json" ]]; then
		log_error "Webhook JSON required (--json). Fields: webhook_url, association_type, event_type_map."
		return 1
	fi

	if ! printf '%s' "$webhook_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/webhook/create" "$webhook_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

webhooks_global_get() {
	local webhook_id="${1:-}"
	if [[ -z "$webhook_id" ]]; then
		log_error "Webhook ID required"
		return 1
	fi

	local result
	result=$(api_get "/webhook/${webhook_id}") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

webhooks_global_update() {
	local webhook_id="${1:-}"
	local webhook_json=""
	shift || true

	if [[ -z "$webhook_id" ]]; then
		log_error "Webhook ID required"
		return 1
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			webhook_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$webhook_json" ]]; then
		log_error "Webhook JSON required (--json)"
		return 1
	fi

	if ! printf '%s' "$webhook_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_put "/webhook/update/${webhook_id}" "$webhook_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

webhooks_global_delete() {
	local webhook_id="${1:-}"
	if [[ -z "$webhook_id" ]]; then
		log_error "Webhook ID required"
		return 1
	fi

	local result
	result=$(api_delete "/webhook/delete/${webhook_id}") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

# =============================================================================
# Block List
# =============================================================================

cmd_blocklist() {
	local subcmd="${1:-help}"
	shift || true

	case "$subcmd" in
	add-domains) blocklist_add_domains "$@" ;;
	list-domains) blocklist_list_domains "$@" ;;
	list-emails) blocklist_list_emails "$@" ;;
	*)
		log_error "Unknown blocklist command: ${subcmd}"
		printf 'Usage: smartlead-helper.sh blocklist <add-domains|list-domains|list-emails>\n'
		return 1
		;;
	esac
}

blocklist_add_domains() {
	local domains_json=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			domains_json="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$domains_json" ]]; then
		log_error "Domains JSON required (--json). Fields: domains (array), source (manual|bounce|complaint|invalid)."
		return 1
	fi

	if ! printf '%s' "$domains_json" | jq empty 2>/dev/null; then
		log_error "Invalid JSON provided"
		return 1
	fi

	local result
	result=$(api_post "/master-inbox/block-domains" "$domains_json") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

blocklist_list_domains() {
	local result
	result=$(api_get "/smart-delivery/domain-blacklist") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

blocklist_list_emails() {
	local result
	result=$(api_get "/smart-delivery/blacklists") || return 1
	printf '%s\n' "$result" | jq '.'
	return 0
}

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
