#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Smartlead Campaigns & Sequences -- Campaign lifecycle and email sequences
# =============================================================================
# Manages Smartlead campaigns (list, create, status, settings, schedule, delete)
# and email sequences (get, save with A/B variants).
#
# Usage: source "${SCRIPT_DIR}/smartlead-helper-campaigns.sh"
#
# Dependencies:
#   - smartlead-helper.sh (orchestrator: api_get, api_post, api_delete, log_*)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SMARTLEAD_CAMPAIGNS_LIB_LOADED:-}" ]] && return 0
_SMARTLEAD_CAMPAIGNS_LIB_LOADED=1

# --- Campaigns ---

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

# --- Sequences ---

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
