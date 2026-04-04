#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

readonly WARMFORGE_API_BASE_URL="${WARMFORGE_API_BASE_URL:-https://api.warmforge.ai/v1}"

log_info_safe() {
	local message="$1"
	if command -v print_info >/dev/null 2>&1; then
		print_info "$message"
		return 0
	fi
	echo "[INFO] $message"
	return 0
}

log_success_safe() {
	local message="$1"
	if command -v print_success >/dev/null 2>&1; then
		print_success "$message"
		return 0
	fi
	echo "[SUCCESS] $message"
	return 0
}

log_error_safe() {
	local message="$1"
	if command -v print_error >/dev/null 2>&1; then
		print_error "$message"
		return 0
	fi
	echo "[ERROR] $message" >&2
	return 0
}

show_help() {
	echo "WarmForge Helper"
	echo ""
	echo "Usage: warmforge-helper.sh <command> [arguments]"
	echo ""
	echo "Commands:"
	echo "  health"
	echo "      Check WarmForge API connectivity"
	echo ""
	echo "  domains"
	echo "      List sending domains"
	echo ""
	echo "  mailboxes [status]"
	echo "      List warmup mailboxes (optional status filter)"
	echo ""
	echo "  deliverability <domain> [window]"
	echo "      Retrieve domain deliverability metrics (window default: 7d)"
	echo ""
	echo "  warmup-status <mailbox_id>"
	echo "      Retrieve active warmup orchestration status"
	echo ""
	echo "  warmup-start <mailbox_id> [profile] [start_date]"
	echo "      Start or update mailbox warmup schedule"
	echo "      profile defaults to 'standard', start_date defaults to today"
	echo ""
	echo "  warmup-pause <mailbox_id>"
	echo "      Pause warmup for a mailbox"
	echo ""
	echo "  warmup-resume <mailbox_id>"
	echo "      Resume warmup for a mailbox"
	echo ""
	echo "  raw <METHOD> <PATH> [JSON_BODY]"
	echo "      Execute a raw WarmForge API request"
	echo ""
	echo "Environment:"
	echo "  WARMFORGE_API_KEY       Required API token"
	echo "  WARMFORGE_API_BASE_URL  Optional base URL (default: $WARMFORGE_API_BASE_URL)"
	echo ""
	echo "Examples:"
	echo "  warmforge-helper.sh health"
	echo "  warmforge-helper.sh deliverability example.com 30d"
	echo "  warmforge-helper.sh warmup-start mbx_123 conservative 2026-03-20"
	echo "  warmforge-helper.sh raw GET /warmup/schedules/mbx_123"
	return 0
}

require_tooling() {
	if ! command -v curl >/dev/null 2>&1; then
		log_error_safe "curl is required"
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		log_error_safe "jq is required"
		return 1
	fi
	return 0
}

require_api_key() {
	if [[ -z "${WARMFORGE_API_KEY:-}" ]]; then
		log_error_safe "WARMFORGE_API_KEY is not set"
		log_error_safe "WARNING: Never paste secret values into AI chat. Run secret setup in your terminal only"
		return 1
	fi
	return 0
}

request_warmforge() {
	local method="$1"
	local endpoint="$2"
	local data="${3:-}"

	local url="${WARMFORGE_API_BASE_URL%/}${endpoint}"
	local curl_config
	curl_config="$(mktemp)"
	chmod 600 "$curl_config"

	{
		echo "silent"
		echo "show-error"
		echo "request = \"$method\""
		echo "url = \"$url\""
		echo "header = \"Authorization: Bearer ${WARMFORGE_API_KEY}\""
		echo "header = \"Accept: application/json\""
		if [[ -n "$data" ]]; then
			echo "header = \"Content-Type: application/json\""
			echo "data = '$data'"
		fi
	} >"$curl_config"

	local response
	local exit_code=0
	response="$(curl --config "$curl_config" -w $'\n%{http_code}')" || exit_code=$?
	rm -f "$curl_config"

	if [[ "$exit_code" -ne 0 ]]; then
		log_error_safe "WarmForge request failed"
		return 1
	fi

	local http_code
	http_code="$(printf '%s\n' "$response" | tail -n 1)"
	local body
	body="$(printf '%s\n' "$response" | sed '$d')"

	if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
		log_error_safe "WarmForge API returned HTTP $http_code"
		printf '%s\n' "$body" | jq . 2>/dev/null || printf '%s\n' "$body"
		return 1
	fi

	printf '%s\n' "$body" | jq .
	return 0
}

cmd_health() {
	log_info_safe "Checking WarmForge API health"
	request_warmforge "GET" "/health"
	return $?
}

cmd_domains() {
	request_warmforge "GET" "/domains"
	return $?
}

cmd_mailboxes() {
	local status_filter="${1:-}"
	if [[ -n "$status_filter" ]]; then
		request_warmforge "GET" "/mailboxes?status=${status_filter}"
		return $?
	fi
	request_warmforge "GET" "/mailboxes"
	return $?
}

cmd_deliverability() {
	local domain="$1"
	local window="${2:-7d}"
	request_warmforge "GET" "/deliverability/${domain}?window=${window}"
	return $?
}

cmd_warmup_status() {
	local mailbox_id="$1"
	request_warmforge "GET" "/warmup/schedules/${mailbox_id}"
	return $?
}

cmd_warmup_start() {
	local mailbox_id="$1"
	local profile="${2:-standard}"
	local start_date="${3:-$(date +%F)}"
	local payload
	payload="$(jq -n --arg mailbox_id "$mailbox_id" --arg profile "$profile" --arg start_date "$start_date" '{mailbox_id: $mailbox_id, profile: $profile, start_date: $start_date}')"
	request_warmforge "POST" "/warmup/schedules" "$payload"
	return $?
}

cmd_warmup_pause() {
	local mailbox_id="$1"
	request_warmforge "POST" "/warmup/schedules/${mailbox_id}/pause"
	return $?
}

cmd_warmup_resume() {
	local mailbox_id="$1"
	request_warmforge "POST" "/warmup/schedules/${mailbox_id}/resume"
	return $?
}

cmd_raw() {
	local method="$1"
	local path="$2"
	local data="${3:-}"
	request_warmforge "$method" "$path" "$data"
	return $?
}

main() {
	local command="${1:-help}"
	if [[ "$command" == "help" || "$command" == "-h" || "$command" == "--help" || -z "$command" ]]; then
		show_help
		return 0
	fi

	require_tooling || return 1
	require_api_key || return 1

	case "$command" in
	"health")
		cmd_health
		return $?
		;;
	"domains")
		cmd_domains
		return $?
		;;
	"mailboxes")
		cmd_mailboxes "${2:-}"
		return $?
		;;
	"deliverability")
		if [[ -z "${2:-}" ]]; then
			log_error_safe "Usage: warmforge-helper.sh deliverability <domain> [window]"
			return 1
		fi
		cmd_deliverability "$2" "${3:-7d}"
		return $?
		;;
	"warmup-status")
		if [[ -z "${2:-}" ]]; then
			log_error_safe "Usage: warmforge-helper.sh warmup-status <mailbox_id>"
			return 1
		fi
		cmd_warmup_status "$2"
		return $?
		;;
	"warmup-start")
		if [[ -z "${2:-}" ]]; then
			log_error_safe "Usage: warmforge-helper.sh warmup-start <mailbox_id> [profile] [start_date]"
			return 1
		fi
		cmd_warmup_start "$2" "${3:-standard}" "${4:-$(date +%F)}"
		return $?
		;;
	"warmup-pause")
		if [[ -z "${2:-}" ]]; then
			log_error_safe "Usage: warmforge-helper.sh warmup-pause <mailbox_id>"
			return 1
		fi
		cmd_warmup_pause "$2"
		return $?
		;;
	"warmup-resume")
		if [[ -z "${2:-}" ]]; then
			log_error_safe "Usage: warmforge-helper.sh warmup-resume <mailbox_id>"
			return 1
		fi
		cmd_warmup_resume "$2"
		return $?
		;;
	"raw")
		if [[ -z "${2:-}" || -z "${3:-}" ]]; then
			log_error_safe "Usage: warmforge-helper.sh raw <METHOD> <PATH> [JSON_BODY]"
			return 1
		fi
		cmd_raw "$2" "$3" "${4:-}"
		return $?
		;;
	*)
		log_error_safe "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
