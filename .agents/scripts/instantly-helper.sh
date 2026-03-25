#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

readonly INSTANTLY_API_BASE_DEFAULT="https://api.instantly.ai/api/v2"

print_usage() {
	echo "Instantly Helper - AI DevOps Framework"
	echo ""
	echo "${HELP_LABEL_USAGE}"
	echo "  instantly-helper.sh <command> [subcommand] [options]"
	echo ""
	echo "${HELP_LABEL_COMMANDS}"
	echo "  campaigns list [--status active|paused] [--limit N]"
	echo "  campaigns get --campaign-id <id>"
	echo "  campaigns create --json-file <file.json>"
	echo "  campaigns pause --campaign-id <id>"
	echo "  campaigns resume --campaign-id <id>"
	echo "  leads list [--campaign-id <id>] [--limit N]"
	echo "  leads create --json-file <file.json>"
	echo "  leads delete --lead-id <id>"
	echo "  sequences list [--limit N]"
	echo "  sequences get --sequence-id <id>"
	echo "  warmup list [--email-account-id <id>]"
	echo "  warmup enable --email-account-id <id>"
	echo "  warmup disable --email-account-id <id>"
	echo "  analytics campaign --campaign-id <id>"
	echo "  request --method <GET|POST|PATCH|DELETE> --endpoint </path> [--json-file file]"
	echo "  status"
	echo "  help"
	echo ""
	echo "${HELP_LABEL_OPTIONS}"
	echo "  --campaign-id <id>       Campaign ID"
	echo "  --lead-id <id>           Lead ID"
	echo "  --sequence-id <id>       Sequence ID"
	echo "  --email-account-id <id>  Email account ID"
	echo "  --status <value>         Status filter"
	echo "  --limit <number>         Max records"
	echo "  --method <verb>          HTTP method for raw request"
	echo "  --endpoint <path>        API v2 endpoint path for raw request"
	echo "  --json-file <file>       JSON request payload file"
	echo "  --api-base <url>         Override API base URL"
	echo "  --raw                    Disable pretty JSON formatting"
	echo ""
	echo "${HELP_LABEL_EXAMPLES}"
	echo "  instantly-helper.sh campaigns list --status active --limit 20"
	echo "  instantly-helper.sh leads create --json-file ./new-lead.json"
	echo "  instantly-helper.sh warmup enable --email-account-id acc_123"
	echo "  instantly-helper.sh request --method GET --endpoint /campaigns"
	echo ""
	echo "Auth:"
	echo "  Export INSTANTLY_API_KEY in your terminal (recommended via: aidevops secret run INSTANTLY_API_KEY -- instantly-helper.sh ...)."
	return 0
}

require_api_key() {
	if [[ -z "${INSTANTLY_API_KEY:-}" ]]; then
		print_error "INSTANTLY_API_KEY is not set"
		print_info "Set it in your terminal via: aidevops secret set INSTANTLY_API_KEY"
		print_info "Then run using: aidevops secret run INSTANTLY_API_KEY -- instantly-helper.sh status"
		return 1
	fi
	return 0
}

validate_json_file() {
	local json_file="$1"

	if [[ -z "$json_file" ]]; then
		print_error "--json-file is required for this command"
		return 1
	fi

	if ! validate_file_exists "$json_file" "JSON payload"; then
		return 1
	fi

	if ! python3 -m json.tool "$json_file" >/dev/null 2>&1; then
		print_error "Invalid JSON file: ${json_file}"
		return 1
	fi

	return 0
}

is_positive_integer() {
	local value="$1"

	case "$value" in
	"" | *[!0-9]*)
		return 1
		;;
	esac

	if [[ "$value" -le 0 ]]; then
		return 1
	fi

	return 0
}

append_query_param() {
	local current_url="$1"
	local key="$2"
	local value="$3"

	if [[ -z "$value" ]]; then
		echo "$current_url"
		return 0
	fi

	if [[ "$current_url" == *"?"* ]]; then
		echo "${current_url}&${key}=${value}"
	else
		echo "${current_url}?${key}=${value}"
	fi

	return 0
}

pretty_print_response() {
	local raw_mode="$1"
	local body_file="$2"

	if [[ "$raw_mode" == "true" ]]; then
		cat "$body_file"
		return 0
	fi

	if command -v jq >/dev/null 2>&1; then
		if jq . "$body_file" >/dev/null 2>&1; then
			jq . "$body_file"
			return 0
		fi
	fi

	cat "$body_file"
	return 0
}

api_request() {
	local method="$1"
	local endpoint="$2"
	local json_file="$3"
	local api_base="$4"
	local raw_mode="$5"

	local body_file
	body_file="$(mktemp)"
	local http_code

	if [[ -n "$json_file" ]]; then
		http_code="$(curl -sS -o "$body_file" -w "%{http_code}" -X "$method" "${api_base}${endpoint}" -H "${AUTH_HEADER_PREFIX} ${INSTANTLY_API_KEY}" -H "${CONTENT_TYPE_JSON}" -H "Accept: application/json" --data-binary "@${json_file}")" || {
			rm -f "$body_file"
			print_error "Request failed: ${method} ${endpoint}"
			return 1
		}
	else
		http_code="$(curl -sS -o "$body_file" -w "%{http_code}" -X "$method" "${api_base}${endpoint}" -H "${AUTH_HEADER_PREFIX} ${INSTANTLY_API_KEY}" -H "Accept: application/json")" || {
			rm -f "$body_file"
			print_error "Request failed: ${method} ${endpoint}"
			return 1
		}
	fi

	if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
		pretty_print_response "$raw_mode" "$body_file"
		rm -f "$body_file"
		return 0
	fi

	print_error "Instantly API returned HTTP ${http_code}"
	cat "$body_file" >&2
	rm -f "$body_file"
	return 1
}

cmd_status() {
	local api_base="$1"

	require_api_key || return 1
	print_info "Checking Instantly API connectivity (${api_base})"
	api_request "GET" "/campaigns?limit=1" "" "$api_base" "false" >/dev/null || return 1
	print_success "Instantly API authentication succeeded"
	return 0
}

cmd_campaigns() {
	local subcommand="$1"
	local campaign_id="$2"
	local status_filter="$3"
	local limit="$4"
	local json_file="$5"
	local api_base="$6"
	local raw_mode="$7"

	case "$subcommand" in
	list)
		local endpoint="/campaigns"
		endpoint="$(append_query_param "$endpoint" "status" "$status_filter")"
		endpoint="$(append_query_param "$endpoint" "limit" "$limit")"
		api_request "GET" "$endpoint" "" "$api_base" "$raw_mode"
		return $?
		;;
	get)
		validate_required_param "--campaign-id" "$campaign_id" || return 1
		api_request "GET" "/campaigns/${campaign_id}" "" "$api_base" "$raw_mode"
		return $?
		;;
	create)
		validate_json_file "$json_file" || return 1
		api_request "POST" "/campaigns" "$json_file" "$api_base" "$raw_mode"
		return $?
		;;
	pause)
		validate_required_param "--campaign-id" "$campaign_id" || return 1
		api_request "POST" "/campaigns/${campaign_id}/pause" "" "$api_base" "$raw_mode"
		return $?
		;;
	resume)
		validate_required_param "--campaign-id" "$campaign_id" || return 1
		api_request "POST" "/campaigns/${campaign_id}/resume" "" "$api_base" "$raw_mode"
		return $?
		;;
	*)
		print_error "Unknown campaigns subcommand: ${subcommand}"
		return 1
		;;
	esac
}

cmd_leads() {
	local subcommand="$1"
	local lead_id="$2"
	local campaign_id="$3"
	local limit="$4"
	local json_file="$5"
	local api_base="$6"
	local raw_mode="$7"

	case "$subcommand" in
	list)
		local endpoint="/leads"
		endpoint="$(append_query_param "$endpoint" "campaign_id" "$campaign_id")"
		endpoint="$(append_query_param "$endpoint" "limit" "$limit")"
		api_request "GET" "$endpoint" "" "$api_base" "$raw_mode"
		return $?
		;;
	create)
		validate_json_file "$json_file" || return 1
		api_request "POST" "/leads" "$json_file" "$api_base" "$raw_mode"
		return $?
		;;
	delete)
		validate_required_param "--lead-id" "$lead_id" || return 1
		api_request "DELETE" "/leads/${lead_id}" "" "$api_base" "$raw_mode"
		return $?
		;;
	*)
		print_error "Unknown leads subcommand: ${subcommand}"
		return 1
		;;
	esac
}

cmd_sequences() {
	local subcommand="$1"
	local sequence_id="$2"
	local limit="$3"
	local api_base="$4"
	local raw_mode="$5"

	case "$subcommand" in
	list)
		local endpoint="/sequences"
		endpoint="$(append_query_param "$endpoint" "limit" "$limit")"
		api_request "GET" "$endpoint" "" "$api_base" "$raw_mode"
		return $?
		;;
	get)
		validate_required_param "--sequence-id" "$sequence_id" || return 1
		api_request "GET" "/sequences/${sequence_id}" "" "$api_base" "$raw_mode"
		return $?
		;;
	*)
		print_error "Unknown sequences subcommand: ${subcommand}"
		return 1
		;;
	esac
}

cmd_warmup() {
	local subcommand="$1"
	local email_account_id="$2"
	local api_base="$3"
	local raw_mode="$4"

	case "$subcommand" in
	list)
		if [[ -n "$email_account_id" ]]; then
			api_request "GET" "/email-accounts/${email_account_id}/warmup" "" "$api_base" "$raw_mode"
			return $?
		fi
		api_request "GET" "/email-accounts" "" "$api_base" "$raw_mode"
		return $?
		;;
	enable)
		validate_required_param "--email-account-id" "$email_account_id" || return 1
		api_request "POST" "/email-accounts/${email_account_id}/warmup/enable" "" "$api_base" "$raw_mode"
		return $?
		;;
	disable)
		validate_required_param "--email-account-id" "$email_account_id" || return 1
		api_request "POST" "/email-accounts/${email_account_id}/warmup/disable" "" "$api_base" "$raw_mode"
		return $?
		;;
	*)
		print_error "Unknown warmup subcommand: ${subcommand}"
		return 1
		;;
	esac
}

cmd_analytics() {
	local subcommand="$1"
	local campaign_id="$2"
	local api_base="$3"
	local raw_mode="$4"

	case "$subcommand" in
	campaign)
		validate_required_param "--campaign-id" "$campaign_id" || return 1
		api_request "GET" "/analytics/campaigns/${campaign_id}" "" "$api_base" "$raw_mode"
		return $?
		;;
	*)
		print_error "Unknown analytics subcommand: ${subcommand}"
		return 1
		;;
	esac
}

cmd_request() {
	local method="$1"
	local endpoint="$2"
	local json_file="$3"
	local api_base="$4"
	local raw_mode="$5"

	validate_required_param "--method" "$method" || return 1
	validate_required_param "--endpoint" "$endpoint" || return 1

	if [[ -n "$json_file" ]]; then
		validate_json_file "$json_file" || return 1
	fi

	api_request "$method" "$endpoint" "$json_file" "$api_base" "$raw_mode"
	return $?
}

parse_main_args() {
	# Sets script-level variables: _campaign_id, _lead_id, _sequence_id,
	# _email_account_id, _status_filter, _limit, _method, _endpoint,
	# _json_file, _api_base, _raw_mode
	# Returns 1 on unknown option.
	_campaign_id=""
	_lead_id=""
	_sequence_id=""
	_email_account_id=""
	_status_filter=""
	_limit=""
	_method=""
	_endpoint=""
	_json_file=""
	_api_base="$INSTANTLY_API_BASE_DEFAULT"
	_raw_mode="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--campaign-id)
			_campaign_id="${2:-}"
			shift 2
			;;
		--lead-id)
			_lead_id="${2:-}"
			shift 2
			;;
		--sequence-id)
			_sequence_id="${2:-}"
			shift 2
			;;
		--email-account-id)
			_email_account_id="${2:-}"
			shift 2
			;;
		--status)
			_status_filter="${2:-}"
			shift 2
			;;
		--limit)
			_limit="${2:-}"
			shift 2
			;;
		--method)
			_method="${2:-}"
			shift 2
			;;
		--endpoint)
			_endpoint="${2:-}"
			shift 2
			;;
		--json-file)
			_json_file="${2:-}"
			shift 2
			;;
		--api-base)
			_api_base="${2:-}"
			shift 2
			;;
		--raw)
			_raw_mode="true"
			shift
			;;
		*)
			print_error "Unknown option: ${1}"
			return 1
			;;
		esac
	done

	return 0
}

dispatch_command() {
	local command="$1"
	local subcommand="$2"

	case "$command" in
	campaigns)
		require_api_key || return 1
		cmd_campaigns "$subcommand" "$_campaign_id" "$_status_filter" "$_limit" "$_json_file" "$_api_base" "$_raw_mode"
		return $?
		;;
	leads)
		require_api_key || return 1
		cmd_leads "$subcommand" "$_lead_id" "$_campaign_id" "$_limit" "$_json_file" "$_api_base" "$_raw_mode"
		return $?
		;;
	sequences)
		require_api_key || return 1
		cmd_sequences "$subcommand" "$_sequence_id" "$_limit" "$_api_base" "$_raw_mode"
		return $?
		;;
	warmup)
		require_api_key || return 1
		cmd_warmup "$subcommand" "$_email_account_id" "$_api_base" "$_raw_mode"
		return $?
		;;
	analytics)
		require_api_key || return 1
		cmd_analytics "$subcommand" "$_campaign_id" "$_api_base" "$_raw_mode"
		return $?
		;;
	request)
		require_api_key || return 1
		cmd_request "$_method" "$_endpoint" "$_json_file" "$_api_base" "$_raw_mode"
		return $?
		;;
	status)
		cmd_status "$_api_base"
		return $?
		;;
	help | --help | -h)
		print_usage
		return 0
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		print_usage
		return 1
		;;
	esac
}

main() {
	local command="${1:-help}"
	local subcommand="${2:-}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	if [[ $# -gt 0 ]]; then
		shift
	fi

	parse_main_args "$@" || return 1

	if [[ -n "$_limit" ]] && ! is_positive_integer "$_limit"; then
		print_error "--limit must be a positive integer"
		return 1
	fi

	dispatch_command "$command" "$subcommand"
	return $?
}

main "$@"
