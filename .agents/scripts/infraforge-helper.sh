#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Infraforge helper
# Domain/mailbox provisioning, DNS automation, IP management.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

readonly INFRAFORGE_BASE_URL="${INFRAFORGE_BASE_URL:-https://api.infraforge.ai/public}"
readonly INFRAFORGE_API_KEY="${INFRAFORGE_API_KEY:-}"
readonly INFRAFORGE_TIMEOUT_SECONDS="${INFRAFORGE_TIMEOUT_SECONDS:-30}"

check_dependencies() {
	if ! command -v curl >/dev/null 2>&1; then
		print_error "curl is required"
		return 1
	fi

	if ! command -v jq >/dev/null 2>&1; then
		print_error "jq is required"
		return 1
	fi

	return 0
}

require_api_key() {
	if [[ -z "$INFRAFORGE_API_KEY" ]]; then
		print_error "INFRAFORGE_API_KEY is not set"
		print_info "Store it with: aidevops secret set INFRAFORGE_API_KEY"
		print_info "Then export it in your terminal before running this helper"
		return 1
	fi

	return 0
}

api_request() {
	local method="$1"
	local endpoint="$2"
	local data="${3:-}"

	local url="${INFRAFORGE_BASE_URL%/}/${endpoint#'/'}"
	local curl_args
	curl_args=(
		-sS
		-X "$method"
		-H "Authorization: Bearer $INFRAFORGE_API_KEY"
		-H "$CONTENT_TYPE_JSON"
		--connect-timeout "$INFRAFORGE_TIMEOUT_SECONDS"
		--max-time "$INFRAFORGE_TIMEOUT_SECONDS"
		"$url"
	)

	if [[ -n "$data" ]]; then
		curl_args=(-sS -X "$method" -H "Authorization: Bearer $INFRAFORGE_API_KEY" -H "$CONTENT_TYPE_JSON" --connect-timeout "$INFRAFORGE_TIMEOUT_SECONDS" --max-time "$INFRAFORGE_TIMEOUT_SECONDS" -d "$data" "$url")
	fi

	local response
	if ! response="$(curl "${curl_args[@]}")"; then
		print_error "Request failed: $method $endpoint"
		return 1
	fi

	if ! echo "$response" | jq empty >/dev/null 2>&1; then
		print_error "Infraforge API did not return JSON"
		echo "$response"
		return 1
	fi

	echo "$response" | jq '.'
	return 0
}

domains_list() {
	print_info "Listing domains"
	api_request "GET" "domains"
	return $?
}

domains_provision() {
	local domain="$1"
	local tld_plan="${2:-standard}"

	if [[ -z "$domain" ]]; then
		print_error "Domain is required"
		return 1
	fi

	local payload
	payload="$(jq -n --arg domain "$domain" --arg plan "$tld_plan" '{domain: $domain, plan: $plan}')"

	print_info "Provisioning domain: $domain"
	api_request "POST" "domains/provision" "$payload"
	return $?
}

mailboxes_create() {
	local domain="$1"
	local mailbox_local_part="$2"
	local mailbox_password="${INFRAFORGE_MAILBOX_PASSWORD:-}"

	if [[ -z "$domain" || -z "$mailbox_local_part" ]]; then
		print_error "Usage: mailboxes-create <domain> <local-part>"
		return 1
	fi

	if [[ -z "$mailbox_password" ]]; then
		print_error "Set INFRAFORGE_MAILBOX_PASSWORD in your terminal before mailbox creation"
		return 1
	fi

	local payload
	payload="$(jq -n \
		--arg domain "$domain" \
		--arg local_part "$mailbox_local_part" \
		--arg password "$mailbox_password" \
		'{domain: $domain, local_part: $local_part, password: $password}')"

	print_info "Creating mailbox ${mailbox_local_part}@${domain}"
	api_request "POST" "mailboxes/create" "$payload"
	return $?
}

dns_list() {
	local domain="$1"

	if [[ -z "$domain" ]]; then
		print_error "Domain is required"
		return 1
	fi

	print_info "Listing DNS for: $domain"
	api_request "GET" "dns/${domain}"
	return $?
}

dns_upsert() {
	local domain="$1"
	local record_type="$2"
	local record_name="$3"
	local record_value="$4"
	local record_ttl="${5:-3600}"

	if [[ -z "$domain" || -z "$record_type" || -z "$record_name" || -z "$record_value" ]]; then
		print_error "Usage: dns-upsert <domain> <type> <name> <value> [ttl]"
		return 1
	fi

	local payload
	payload="$(jq -n \
		--arg domain "$domain" \
		--arg type "$record_type" \
		--arg name "$record_name" \
		--arg value "$record_value" \
		--arg ttl "$record_ttl" \
		'{domain: $domain, type: $type, name: $name, value: $value, ttl: ($ttl|tonumber)}')"

	print_info "Upserting DNS record $record_name ($record_type)"
	api_request "POST" "dns/upsert" "$payload"
	return $?
}

ips_list() {
	print_info "Listing dedicated IP pool"
	api_request "GET" "ips"
	return $?
}

ips_assign() {
	local ip_id="$1"
	local domain="$2"

	if [[ -z "$ip_id" || -z "$domain" ]]; then
		print_error "Usage: ips-assign <ip-id> <domain>"
		return 1
	fi

	local payload
	payload="$(jq -n --arg ip_id "$ip_id" --arg domain "$domain" '{ip_id: $ip_id, domain: $domain}')"

	print_info "Assigning IP $ip_id to $domain"
	api_request "POST" "ips/assign" "$payload"
	return $?
}

ssl_enable() {
	local domain="$1"

	if [[ -z "$domain" ]]; then
		print_error "Usage: ssl-enable <domain>"
		return 1
	fi

	local payload
	payload="$(jq -n --arg domain "$domain" '{domain: $domain}')"

	print_info "Enabling SSL for $domain"
	api_request "POST" "ssl/enable" "$payload"
	return $?
}

masking_enable() {
	local domain="$1"

	if [[ -z "$domain" ]]; then
		print_error "Usage: masking-enable <domain>"
		return 1
	fi

	local payload
	payload="$(jq -n --arg domain "$domain" '{domain: $domain}')"

	print_info "Enabling domain masking for $domain"
	api_request "POST" "domain-masking/enable" "$payload"
	return $?
}

show_help() {
	cat <<'EOF'
Infraforge helper

Usage:
  infraforge-helper.sh <command> [args]

Commands:
  domains-list
  domains-provision <domain> [plan]
  mailboxes-create <domain> <local-part>
  dns-list <domain>
  dns-upsert <domain> <type> <name> <value> [ttl]
  ips-list
  ips-assign <ip-id> <domain>
  ssl-enable <domain>
  masking-enable <domain>
  help

Environment:
  INFRAFORGE_API_KEY            Required
  INFRAFORGE_BASE_URL           Optional (default: https://api.infraforge.ai/public)
  INFRAFORGE_TIMEOUT_SECONDS    Optional (default: 30)
  INFRAFORGE_MAILBOX_PASSWORD   Required only for mailboxes-create

Examples:
  INFRAFORGE_API_KEY=... infraforge-helper.sh domains-list
  INFRAFORGE_API_KEY=... infraforge-helper.sh domains-provision sender-example.com
  INFRAFORGE_API_KEY=... INFRAFORGE_MAILBOX_PASSWORD=... infraforge-helper.sh mailboxes-create sender-example.com inbox1
EOF
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	check_dependencies || return 1

	case "$command" in
	help | -h | --help)
		show_help
		return 0
		;;
	domains-list | domains-provision | mailboxes-create | dns-list | dns-upsert | ips-list | ips-assign | ssl-enable | masking-enable)
		require_api_key || return 1
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac

	case "$command" in
	domains-list) domains_list ;;
	domains-provision) domains_provision "${1:-}" "${2:-}" ;;
	mailboxes-create) mailboxes_create "${1:-}" "${2:-}" ;;
	dns-list) dns_list "${1:-}" ;;
	dns-upsert) dns_upsert "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
	ips-list) ips_list ;;
	ips-assign) ips_assign "${1:-}" "${2:-}" ;;
	ssl-enable) ssl_enable "${1:-}" ;;
	masking-enable) masking_enable "${1:-}" ;;
	help | -h | --help) show_help ;;
	esac

	return $?
}

main "$@"
