#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Smartlead Accounts & Warmup -- Email account and warmup management
# =============================================================================
# Manages email accounts (list, create, update, delete, campaign assignment)
# and warmup configuration/stats.
#
# Usage: source "${SCRIPT_DIR}/smartlead-helper-accounts.sh"
#
# Dependencies:
#   - smartlead-helper.sh (orchestrator: api_get, api_post, api_put, api_delete, log_*)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SMARTLEAD_ACCOUNTS_LIB_LOADED:-}" ]] && return 0
_SMARTLEAD_ACCOUNTS_LIB_LOADED=1

# --- Accounts ---

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

# --- Warmup ---

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
