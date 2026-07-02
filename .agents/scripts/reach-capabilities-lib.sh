#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Capabilities Library
# =============================================================================
# Capability registry and doctor/readiness command handlers.
#
# Usage: source "${SCRIPT_DIR}/reach-capabilities-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_CAPABILITIES_LIB_LOADED:-}" ]] && return 0
_REACH_CAPABILITIES_LIB_LOADED=1

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

print_capability_object() {
	local key="$1"
	local name="$2"
	local agency="$3"
	local mode="$4"
	local available="false"

	if capability_available "$key"; then
		available="true"
	fi

	printf '{"key":"%s","name":"%s","agency":"%s","mode":"%s","available":%s}' \
		"$(json_escape "$key")" \
		"$(json_escape "$name")" \
		"$(json_escape "$agency")" \
		"$(json_escape "$mode")" \
		"$(json_bool "$available")"
	return 0
}

emit_capabilities_json() {
	printf '{"schema_version":1,"capabilities":['
	print_capability_object "fetch" "Fetch/static parse" "1" "static"
	printf ','
	print_capability_object "crawler" "Crawl4AI/WaterCrawl crawler" "2" "crawl"
	printf ','
	print_capability_object "browser" "Deterministic browser" "3" "deterministic_browser"
	printf ','
	print_capability_object "persistent_profile" "Persistent profile" "4" "profile"
	printf ','
	print_capability_object "cookie_session" "Cookie-session reuse" "4" "cookie_session"
	printf ','
	print_capability_object "anti_detect_profile" "Anti-detect profile" "6" "authorized_stealth"
	printf ','
	print_capability_object "proxy_vpn" "Proxy/VPN" "6" "authorized_proxy"
	printf ','
	print_capability_object "inbox_capture" "_inbox capture" "storage" "capture"
	printf ','
	print_capability_object "knowledge_staging" "_knowledge staging" "storage" "staging"
	printf ','
	print_capability_object "performance_logging" "_performance logging" "telemetry" "logging"
	printf ','
	print_capability_object "feedback_mining" "_feedback mining" "telemetry" "mining"
	printf ']}\n'
	return 0
}

require_json_format() {
	local format="$1"
	if [[ "$format" != "json" ]]; then
		log_error "Only --format json is supported"
		return 1
	fi
	return 0
}

handle_capabilities() {
	local format="json"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown capabilities option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	emit_capabilities_json
	return 0
}

handle_doctor() {
	local format="json"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown doctor option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	local capabilities_json=""
	local checks_json=""
	capabilities_json="$(emit_capabilities_json)"
	checks_json="${capabilities_json#*\"capabilities\":}"
	checks_json="${checks_json%\}}"
	printf '{"schema_version":1,"contacted_targets":false,"checks":'
	printf '%s' "$checks_json"
	printf '}\n'
	return 0
}

emit_network_doctor_json() {
	local proxy_available="false"
	local vpn_available="false"
	local proxy_status="missing_helper"
	local vpn_status="missing_helper"

	if capability_available "proxy_vpn"; then
		proxy_available="true"
		proxy_status="ready"
	fi
	if helper_available nostr-vpn-helper.sh || command_available wg || command_available tailscale; then
		vpn_available="true"
		vpn_status="ready"
	fi

	printf '{"schema_version":1,"contacted_targets":false,"doctor":"network","provider_class":"proxy_or_vpn","checks":[{"key":"proxy_vpn","available":%s,"status":"%s"},{"key":"vpn","available":%s,"status":"%s"}],"notes":["sanitized readiness only","no IP addresses, proxy credentials, session IDs, cookies, or private paths are printed"]}\n' \
		"$(json_bool "$proxy_available")" \
		"$(json_escape "$proxy_status")" \
		"$(json_bool "$vpn_available")" \
		"$(json_escape "$vpn_status")"
	return $?
}

emit_fingerprint_doctor_json() {
	local profile_available="false"
	local browser_available="false"
	local profile_status="missing_helper"
	local browser_status="missing_helper"

	if capability_available "anti_detect_profile"; then
		profile_available="true"
		profile_status="ready"
	fi
	if capability_available "browser"; then
		browser_available="true"
		browser_status="ready"
	fi

	printf '{"schema_version":1,"contacted_targets":false,"doctor":"fingerprint","profile_type":"persistent_clean_warm_or_disposable","checks":[{"key":"anti_detect_profile","available":%s,"status":"%s"},{"key":"deterministic_browser","available":%s,"status":"%s"}],"notes":["authorized automation only","no profile paths, session IDs, cookies, or private targets are printed"]}\n' \
		"$(json_bool "$profile_available")" \
		"$(json_escape "$profile_status")" \
		"$(json_bool "$browser_available")" \
		"$(json_escape "$browser_status")"
	return 0
}

handle_nested_doctor() {
	local doctor_name="$1"
	shift
	local subcommand="${1:-}"
	if [[ "$subcommand" != "doctor" ]]; then
		log_error "$doctor_name requires the doctor subcommand"
		return 1
	fi
	shift

	local format="json"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--format)
				shift
				format="${1:-}"
				;;
			*)
				log_error "Unknown $doctor_name doctor option: $arg"
				return 1
				;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1

	case "$doctor_name" in
		network)
			emit_network_doctor_json
			return $?
			;;
		fingerprint)
			emit_fingerprint_doctor_json
			return $?
			;;
		*)
			log_error "Unknown doctor: $doctor_name"
			return 1
			;;
	esac
}
