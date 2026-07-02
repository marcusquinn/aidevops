#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Failure Classification Library
# =============================================================================
# Fetch/capture failure classification helpers and command handler.
#
# Usage: source "${SCRIPT_DIR}/reach-failure-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_FAILURE_LIB_LOADED:-}" ]] && return 0
_REACH_FAILURE_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091  # shared constants resolved at runtime via $SCRIPT_DIR
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# --- Functions ---

normalize_bool_option() {
	local value="$1"
	local option_name="$2"
	case "$value" in
		true | false)
			printf '%s' "$value"
			return 0
			;;
		*)
			log_error "$option_name must be true or false"
			return 1
			;;
	esac
}

classify_failure() {
	local http_status="$1"
	local has_login_wall="$2"
	local has_captcha="$3"
	local timeout="$4"
	local selector_drift="$5"
	local content_empty="$6"
	local bot_block="$7"

	failure_class="unknown"
	temporary="false"
	retry_after_seconds="0"
	next_action="stop and inspect sanitized evidence before retrying"
	safe_to_failover="false"
	requires_authorization="false"
	notes='"no credentials, cookies, IP addresses, session IDs, or private paths are included"'

	if [[ "$timeout" == "true" ]]; then
		failure_class="network_timeout"
		temporary="true"
		retry_after_seconds="60"
		next_action="retry once with backoff, then use an authorized alternate route"
		safe_to_failover="true"
	elif [[ "$has_login_wall" == "true" || "$http_status" == "401" ]]; then
		failure_class="auth_required"
		next_action="stop and obtain explicit authorization or an approved reusable session"
		requires_authorization="true"
	elif [[ "$has_captcha" == "true" ]]; then
		failure_class="captcha_required"
		temporary="true"
		next_action="pause for authorized CAPTCHA handling; do not bypass policy"
		safe_to_failover="true"
	elif [[ "$bot_block" == "true" || "$http_status" == "418" ]]; then
		failure_class="bot_block"
		temporary="true"
		retry_after_seconds="300"
		next_action="stop current identity and use only an authorized fresh profile or proxy"
		safe_to_failover="true"
	elif [[ "$http_status" == "403" ]]; then
		failure_class="scope_forbidden"
		next_action="stop; do not fail over without new authorization for the protected scope"
		requires_authorization="true"
	elif [[ "$http_status" == "407" || "$http_status" == "502" || "$http_status" == "503" ]]; then
		failure_class="proxy_unhealthy"
		temporary="true"
		retry_after_seconds="120"
		next_action="run network doctor and switch only to a healthy authorized proxy or VPN"
		safe_to_failover="true"
	elif [[ "$http_status" == "429" ]]; then
		failure_class="rate_limited"
		temporary="true"
		retry_after_seconds="300"
		next_action="respect rate limits, back off, then retry or fail over within authorization"
		safe_to_failover="true"
	elif [[ "$selector_drift" == "true" ]]; then
		failure_class="selector_drift"
		next_action="update selectors or extraction logic before retrying"
	elif [[ "$content_empty" == "true" ]]; then
		failure_class="content_empty"
		temporary="true"
		retry_after_seconds="30"
		next_action="retry with a lower-agency parser, then escalate to deterministic browser if authorized"
		safe_to_failover="true"
	elif [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
		failure_class="success"
		next_action="continue with extraction"
	elif [[ "$http_status" == "408" || "$http_status" == "504" ]]; then
		failure_class="network_timeout"
		temporary="true"
		retry_after_seconds="60"
		next_action="retry once with backoff, then use an authorized alternate route"
		safe_to_failover="true"
	fi
	return 0
}

handle_classify_failure() {
	local http_status="0"
	local has_login_wall="false"
	local has_captcha="false"
	local timeout="false"
	local selector_drift="false"
	local content_empty="false"
	local bot_block="false"
	local format="json"

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--http-status)
				shift
				http_status="${1:-0}"
				;;
			--has-login-wall)
				shift
				has_login_wall="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--has-captcha)
				shift
				has_captcha="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--timeout)
				shift
				timeout="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--selector-drift)
				shift
				selector_drift="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--content-empty)
				shift
				content_empty="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--bot-block)
				shift
				bot_block="$(normalize_bool_option "${1:-}" "$arg")" || return 1
				;;
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown classify-failure option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	if [[ ! "$http_status" =~ ^[0-9][0-9][0-9]$ && "$http_status" != "0" ]]; then
		log_error "--http-status must be a three-digit status code"
		return 1
	fi

	local failure_class=""
	local temporary=""
	local retry_after_seconds=""
	local next_action=""
	local safe_to_failover=""
	local requires_authorization=""
	local notes=""
	classify_failure "$http_status" "$has_login_wall" "$has_captcha" "$timeout" "$selector_drift" "$content_empty" "$bot_block"

	printf '{"schema_version":1,"failure_class":"%s","temporary":%s,"retry_after_seconds":%s,"next_action":"%s","safe_to_failover":%s,"requires_authorization":%s,"notes":[%s]}\n' \
		"$(json_escape "$failure_class")" \
		"$(json_bool "$temporary")" \
		"$retry_after_seconds" \
		"$(json_escape "$next_action")" \
		"$(json_bool "$safe_to_failover")" \
		"$(json_bool "$requires_authorization")" \
		"$notes"
	return 0
}
