#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Smartlead Outreach -- Analytics, Webhooks, and Block Lists
# =============================================================================
# Manages campaign analytics (per-campaign, date-range, overview), webhooks
# (campaign-scoped and global), and domain/email block lists.
#
# Usage: source "${SCRIPT_DIR}/smartlead-helper-outreach.sh"
#
# Dependencies:
#   - smartlead-helper.sh (orchestrator: api_get, api_post, api_put, api_delete, log_*)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SMARTLEAD_OUTREACH_LIB_LOADED:-}" ]] && return 0
_SMARTLEAD_OUTREACH_LIB_LOADED=1

# --- Analytics ---

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

# --- Webhooks ---

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

# --- Block List ---

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
