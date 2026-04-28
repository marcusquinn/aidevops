#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Smartlead Leads -- Lead management and batch operations
# =============================================================================
# Manages leads: add (with batch support), list, get, search, update, pause,
# resume, delete, unsubscribe, export, and message history.
#
# Usage: source "${SCRIPT_DIR}/smartlead-helper-leads.sh"
#
# Dependencies:
#   - smartlead-helper.sh (orchestrator: api_get, api_post, api_delete, log_*,
#     SL_MAX_LEADS_PER_BATCH)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SMARTLEAD_LEADS_LIB_LOADED:-}" ]] && return 0
_SMARTLEAD_LEADS_LIB_LOADED=1

# --- Lead Command Dispatcher ---

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

# --- Internal Helpers ---

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

# --- Lead Functions ---

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
