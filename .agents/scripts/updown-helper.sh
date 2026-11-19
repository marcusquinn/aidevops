#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155,SC2317

# Updown.io Helper Script
# Managed by AI DevOps Framework
#
# One updown.io account monitors every site; each site gets a status page on
# its own status.<domain> subdomain. Guide: services/monitoring/updown.md
#
# Version: 1.1.0

# Set strict mode
set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION & CONSTANTS
# ------------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly REPO_ROOT="$(dirname "$SCRIPT_DIR")"
readonly CONFIG_FILE="$REPO_ROOT/configs/updown-config.json"
readonly API_BASE_URL="https://updown.io/api"
readonly STATUS_PAGE_CNAME_TARGET="page.updown.io"

# Values the updown API accepts (https://updown.io/api)
readonly VALID_PERIODS="15 30 60 120 300 600 1800 3600"
readonly VALID_APDEX="0.125 0.25 0.5 1.0 2.0 4.0 8.0"
readonly VALID_VISIBILITY="public protected private"
# Hourly by default: updown charges one credit per check request.
readonly DEFAULT_PERIOD=3600
# Resource names used in token validation messages
readonly KIND_CHECK="Check"
readonly KIND_STATUS_PAGE="Status page"

# HTTP Constants
# Error Messages
readonly ERROR_CONFIG_MISSING="Configuration file not found at $CONFIG_FILE"
readonly ERROR_CURL_FAILED="Failed to execute API request"
readonly ERROR_JQ_MISSING="jq is required but not installed"

# Parsed command options. Bash 3.2 has no namerefs, so the parsers set globals.
OPT_ALIAS=""
OPT_ALIAS_SET=0
OPT_PERIOD=""
OPT_CONTAINS=""
OPT_CONTAINS_SET=0
OPT_APDEX=""
OPT_PUBLISHED=""
OPT_RECIPIENTS=()
OPT_PAGE_NAME=""
OPT_PAGE_DESCRIPTION=""
OPT_PAGE_DESCRIPTION_SET=0
OPT_PAGE_VISIBILITY=""
OPT_PAGE_CHECKS=()
OPT_POSITIONALS=()

# ------------------------------------------------------------------------------
# UTILITY FUNCTIONS
# ------------------------------------------------------------------------------

check_dependencies() {
	if ! command -v jq >/dev/null 2>&1; then
		print_error "$ERROR_JQ_MISSING"
		return 1
	fi
	return 0
}

load_config() {
	local api_key

	# First try environment variable
	api_key="${UPDOWN_API_KEY:-}"

	# Fallback to config file if env var not set
	if [[ -z "$api_key" && -f "$CONFIG_FILE" ]]; then
		api_key=$(jq -r '.api_key // empty' "$CONFIG_FILE" 2>/dev/null)
	fi

	# Then credentials.sh, then gopass aidevops/UPDOWN_API_KEY (GH#34892)
	if [[ -z "$api_key" ]]; then
		api_key=$(aidevops_resolve_secret UPDOWN_API_KEY) || api_key=""
	fi

	if [[ -z "$api_key" ]]; then
		print_error "$ERROR_API_KEY_MISSING"
		print_error "Set it with: aidevops secret set UPDOWN_API_KEY"
		return 1
	fi

	echo "$api_key"
	return 0
}

# Succeeds when the value is one of the space-separated allowed words.
is_one_of() {
	local value="$1"
	local allowed="$2"
	local item
	for item in $allowed; do
		if [[ "$item" == "$value" ]]; then
			return 0
		fi
	done
	return 1
}

# Fails when a flag that takes a value is the last argument, or when its value
# is empty and the flag does not allow that.
require_flag_value() {
	local flag="$1"
	local remaining="$2"
	local value="$3"
	local allow_empty="${4:-}"
	if [[ "$remaining" -lt 2 ]]; then
		print_error "$flag needs a value"
		return 1
	fi
	if [[ -z "$value" && "$allow_empty" != "allow-empty" ]]; then
		print_error "$flag needs a non-empty value"
		return 1
	fi
	return 0
}

# Check and status page tokens are short alphanumeric strings. Rejecting
# anything else keeps arbitrary input out of the request path.
validate_token() {
	local token="$1"
	local kind="$2"
	if [[ -z "$token" ]]; then
		print_error "$kind token is required"
		return 1
	fi
	if [[ ! "$token" =~ ^[A-Za-z0-9]+$ ]]; then
		print_error "Invalid token: $token (expected letters and digits only)"
		return 1
	fi
	return 0
}

# Accepts "1" as "1.0" so apdex values match the API's list.
normalize_apdex() {
	local value="$1"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		value="${value}.0"
	fi
	printf '%s\n' "$value"
	return 0
}

visibility_label() {
	local published="$1"
	if [[ "$published" == "true" ]]; then
		echo "public"
	else
		echo "private"
	fi
	return 0
}

# ------------------------------------------------------------------------------
# API INTERACTION FUNCTIONS
# ------------------------------------------------------------------------------

execute_request() {
	local method="$1"
	local endpoint="$2"
	local data="${3:-}"

	local api_key
	if ! api_key=$(load_config); then
		return 1
	fi

	local response
	local http_code

	# The key reaches curl on stdin (-H @-), never in process arguments, so
	# ps cannot show it. Request bodies stay in arguments; they hold no secrets.
	local curl_cmd=(curl -s -w "\n%{http_code}" -X "$method" -H @-)

	if [[ -n "$data" ]]; then
		curl_cmd+=(-H "$CONTENT_TYPE_JSON")
		curl_cmd+=(--data-raw "$data")
	fi

	curl_cmd+=("$API_BASE_URL$endpoint")

	if ! response=$(printf 'X-API-KEY: %s\n' "$api_key" | "${curl_cmd[@]}"); then
		print_error "$ERROR_CURL_FAILED"
		return 1
	fi

	http_code=$(echo "$response" | tail -n1)
	local body
	body=$(echo "$response" | sed '$d')

	if [[ "$http_code" =~ ^[0-9]+$ && "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
		echo "$body"
		return 0
	fi
	print_error "API request failed with status $http_code: $body"
	return 1
}

# ------------------------------------------------------------------------------
# CHECK OPTIONS
# ------------------------------------------------------------------------------

reset_check_options() {
	OPT_ALIAS=""
	OPT_ALIAS_SET=0
	OPT_PERIOD=""
	OPT_CONTAINS=""
	OPT_CONTAINS_SET=0
	OPT_APDEX=""
	OPT_PUBLISHED=""
	OPT_RECIPIENTS=()
	OPT_POSITIONALS=()
	return 0
}

# Parses the flags shared by add and update; other words become positionals.
parse_check_options() {
	reset_check_options
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		local value="${2:-}"
		case "$flag" in
		--alias)
			require_flag_value "$flag" "$#" "$value" allow-empty || return 1
			OPT_ALIAS="$value"
			OPT_ALIAS_SET=1
			shift 2
			;;
		--period)
			require_flag_value "$flag" "$#" "$value" || return 1
			OPT_PERIOD="$value"
			shift 2
			;;
		--contains)
			require_flag_value "$flag" "$#" "$value" allow-empty || return 1
			OPT_CONTAINS="$value"
			OPT_CONTAINS_SET=1
			shift 2
			;;
		--apdex)
			require_flag_value "$flag" "$#" "$value" || return 1
			OPT_APDEX=$(normalize_apdex "$value")
			shift 2
			;;
		--recipient)
			require_flag_value "$flag" "$#" "$value" || return 1
			OPT_RECIPIENTS+=("$value")
			shift 2
			;;
		--public)
			OPT_PUBLISHED="true"
			shift
			;;
		--private)
			OPT_PUBLISHED="false"
			shift
			;;
		-*)
			print_error "Unknown option: $flag"
			return 1
			;;
		*)
			OPT_POSITIONALS+=("$flag")
			shift
			;;
		esac
	done
	return 0
}

validate_check_options() {
	if [[ -n "$OPT_PERIOD" ]] && ! is_one_of "$OPT_PERIOD" "$VALID_PERIODS"; then
		print_error "Invalid period: $OPT_PERIOD (use one of $VALID_PERIODS seconds)"
		return 1
	fi
	if [[ -n "$OPT_APDEX" ]] && ! is_one_of "$OPT_APDEX" "$VALID_APDEX"; then
		print_error "Invalid apdex: $OPT_APDEX (use one of $VALID_APDEX seconds)"
		return 1
	fi
	local recipient
	for recipient in ${OPT_RECIPIENTS[@]+"${OPT_RECIPIENTS[@]}"}; do
		if [[ ! "$recipient" =~ ^[a-z_]+:[A-Za-z0-9_-]+$ ]]; then
			print_error "Invalid recipient id: $recipient (run 'recipients' for ids such as email:12345)"
			return 1
		fi
	done
	return 0
}

# Builds a JSON body holding only the fields that were given, so update never
# touches fields the caller did not name.
build_check_payload() {
	local url="$1"
	jq -n -c \
		--arg url "$url" \
		--arg alias "$OPT_ALIAS" \
		--arg alias_set "$OPT_ALIAS_SET" \
		--arg period "$OPT_PERIOD" \
		--arg contains "$OPT_CONTAINS" \
		--arg contains_set "$OPT_CONTAINS_SET" \
		--arg apdex "$OPT_APDEX" \
		--arg published "$OPT_PUBLISHED" \
		'{}
        + (if $url != "" then {url: $url} else {} end)
        + (if $alias_set == "1" then {alias: $alias} else {} end)
        + (if $period != "" then {period: ($period | tonumber)} else {} end)
        + (if $contains_set == "1" then {string_match: $contains} else {} end)
        + (if $apdex != "" then {apdex_t: ($apdex | tonumber)} else {} end)
        + (if $published != "" then {published: ($published == "true")} else {} end)
        + (if ($ARGS.positional | length) > 0 then {recipients: $ARGS.positional} else {} end)' \
		--args ${OPT_RECIPIENTS[@]+"${OPT_RECIPIENTS[@]}"}
	return $?
}

# ------------------------------------------------------------------------------
# CHECK COMMANDS
# ------------------------------------------------------------------------------

list_checks() {
	local response
	response=$(execute_request "GET" "/checks") || return 1
	echo "$response" | jq -r '.[] | "\(.token)\t\(.url)\t\(.alias // "")\t\(.status)\t(Last: \(.last_status))"' | column -t -s $'\t' || return 1
	return 0
}

get_checks_json() {
	local response
	if response=$(execute_request "GET" "/checks"); then
		echo "$response"
		return 0
	fi
	return 1
}

# add <url> [alias] [period] [flags]; prints the new check's token on stdout.
add_check() {
	parse_check_options "$@" || return 1

	local count="${#OPT_POSITIONALS[@]}"
	local url="${OPT_POSITIONALS[0]:-}"
	if [[ "$count" -gt 3 ]]; then
		print_error "Too many arguments: use add <url> [alias] [period] [flags]"
		return 1
	fi
	if [[ "$count" -ge 2 && "$OPT_ALIAS_SET" -eq 0 ]]; then
		OPT_ALIAS="${OPT_POSITIONALS[1]}"
		OPT_ALIAS_SET=1
	fi
	if [[ "$count" -ge 3 && -z "$OPT_PERIOD" ]]; then
		OPT_PERIOD="${OPT_POSITIONALS[2]}"
	fi
	if [[ -z "$url" ]]; then
		print_error "URL is required"
		return 1
	fi
	if [[ -z "$OPT_PERIOD" ]]; then
		OPT_PERIOD="$DEFAULT_PERIOD"
	fi
	# Private unless --public: the site's status page provides public visibility.
	if [[ -z "$OPT_PUBLISHED" ]]; then
		OPT_PUBLISHED="false"
	fi
	validate_check_options || return 1

	local payload
	payload=$(build_check_payload "$url") || return 1

	print_info "Adding check for $url..."

	local response
	response=$(execute_request "POST" "/checks" "$payload") || return 1

	local token
	token=$(echo "$response" | jq -r '.token // empty' 2>/dev/null) || token=""
	print_success "Check added successfully for $url (token ${token:-unknown}, $(visibility_label "$OPT_PUBLISHED"), every ${OPT_PERIOD}s)"
	if [[ -n "$token" ]]; then
		echo "$token"
	fi
	return 0
}

# update <token> [flags]; sends only the given fields. The URL is never copied
# from a GET: a read-only key hides basic-auth credentials, so a PUT of that
# URL would erase them.
update_check() {
	local token="${1:-}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	validate_token "$token" "$KIND_CHECK" || return 1
	parse_check_options "$@" || return 1
	if [[ "${#OPT_POSITIONALS[@]}" -gt 0 ]]; then
		print_error "Unexpected argument: ${OPT_POSITIONALS[0]}"
		return 1
	fi
	validate_check_options || return 1

	local payload
	payload=$(build_check_payload "") || return 1
	if [[ "$payload" == "{}" ]]; then
		print_error "Nothing to update: give --alias, --period, --contains, --apdex, --recipient, --public or --private"
		return 1
	fi

	print_info "Updating check $token..."

	local response
	response=$(execute_request "PUT" "/checks/$token" "$payload") || return 1
	print_success "Check $token updated"
	# The URL is left out: with a read-write key it can include credentials.
	echo "$response" | jq '{token, alias, period, apdex_t, string_match, published, recipients}' || return 1
	return 0
}

delete_check() {
	local token="${1:-}"

	validate_token "$token" "$KIND_CHECK" || return 1

	print_info "Deleting check $token..."

	if execute_request "DELETE" "/checks/$token" >/dev/null; then
		print_success "Check deleted successfully"
		return 0
	fi
	return 1
}

get_metrics() {
	local token="${1:-}"

	validate_token "$token" "$KIND_CHECK" || return 1

	local response
	response=$(execute_request "GET" "/checks/$token/metrics") || return 1
	echo "$response" | jq '.' || return 1
	return 0
}

list_recipients() {
	local response
	response=$(execute_request "GET" "/recipients") || return 1
	echo "$response" | jq -r '.[] | "\(.id)\t\(.type)\t\(.name // "")"' | column -t -s $'\t' || return 1
	return 0
}

# ------------------------------------------------------------------------------
# STATUS PAGE COMMANDS
# ------------------------------------------------------------------------------

reset_page_options() {
	OPT_PAGE_NAME=""
	OPT_PAGE_DESCRIPTION=""
	OPT_PAGE_DESCRIPTION_SET=0
	OPT_PAGE_VISIBILITY=""
	OPT_PAGE_CHECKS=()
	OPT_POSITIONALS=()
	return 0
}

# --check takes one token or a comma-separated list; the page keeps the order.
add_page_checks() {
	local value="$1"
	local -a parts=()
	local part
	IFS=',' read -r -a parts <<<"$value"
	for part in ${parts[@]+"${parts[@]}"}; do
		if [[ -z "$part" ]]; then
			continue
		fi
		validate_token "$part" "$KIND_CHECK" || return 1
		OPT_PAGE_CHECKS+=("$part")
	done
	return 0
}

parse_page_options() {
	reset_page_options
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		local value="${2:-}"
		case "$flag" in
		--name)
			require_flag_value "$flag" "$#" "$value" || return 1
			OPT_PAGE_NAME="$value"
			shift 2
			;;
		--description)
			require_flag_value "$flag" "$#" "$value" allow-empty || return 1
			OPT_PAGE_DESCRIPTION="$value"
			OPT_PAGE_DESCRIPTION_SET=1
			shift 2
			;;
		--visibility)
			require_flag_value "$flag" "$#" "$value" || return 1
			OPT_PAGE_VISIBILITY="$value"
			shift 2
			;;
		--check)
			require_flag_value "$flag" "$#" "$value" || return 1
			add_page_checks "$value" || return 1
			shift 2
			;;
		-*)
			print_error "Unknown option: $flag"
			return 1
			;;
		*)
			OPT_POSITIONALS+=("$flag")
			shift
			;;
		esac
	done
	if [[ -n "$OPT_PAGE_VISIBILITY" ]] && ! is_one_of "$OPT_PAGE_VISIBILITY" "$VALID_VISIBILITY"; then
		print_error "Invalid visibility: $OPT_PAGE_VISIBILITY (use public, protected or private)"
		return 1
	fi
	if [[ "${#OPT_POSITIONALS[@]}" -gt 0 ]]; then
		print_error "Unexpected argument: ${OPT_POSITIONALS[0]}"
		return 1
	fi
	return 0
}

build_page_payload() {
	jq -n -c \
		--arg name "$OPT_PAGE_NAME" \
		--arg description "$OPT_PAGE_DESCRIPTION" \
		--arg description_set "$OPT_PAGE_DESCRIPTION_SET" \
		--arg visibility "$OPT_PAGE_VISIBILITY" \
		'{}
        + (if $name != "" then {name: $name} else {} end)
        + (if $description_set == "1" then {description: $description} else {} end)
        + (if $visibility != "" then {visibility: $visibility} else {} end)
        + (if ($ARGS.positional | length) > 0 then {checks: $ARGS.positional} else {} end)' \
		--args ${OPT_PAGE_CHECKS[@]+"${OPT_PAGE_CHECKS[@]}"}
	return $?
}

print_status_page() {
	local page_json="$1"
	echo "$page_json" | jq -r '
        "token       \(.token)",
        "url         \(.url)",
        "name        \(.name // "")",
        "visibility  \(.visibility // "")",
        "checks      \((.checks // []) | join(","))"' || return 1
	return 0
}

# The updown API has no custom-domain field, so the helper only explains it.
print_status_page_next_steps() {
	echo
	echo "Next steps (the updown API cannot set a custom domain, so this helper does not):"
	echo "  1. On updown.io, open this status page's settings and enter the site's status"
	echo "     hostname, for example status.example.com, as its custom domain."
	echo "  2. At the site's DNS host, add every record updown's custom-domain screen lists:"
	echo "     CNAME status -> $STATUS_PAGE_CNAME_TARGET, plus any TXT record shown there."
	echo "     This helper creates no DNS records. In Cloudflare set the CNAME to DNS only."
	echo "     Proxied setups: services/monitoring/updown.md"
	return 0
}

status_page_list() {
	local response
	response=$(execute_request "GET" "/status_pages") || return 1
	echo "$response" | jq -r '.[] | "\(.token)\t\(.url)\t\(.visibility // "")\t\(.name // "")\t\((.checks // []) | join(","))"' | column -t -s $'\t' || return 1
	return 0
}

status_page_add() {
	parse_page_options "$@" || return 1
	if [[ -z "$OPT_PAGE_NAME" ]]; then
		print_error "--name is required"
		return 1
	fi
	if [[ "${#OPT_PAGE_CHECKS[@]}" -eq 0 ]]; then
		print_error "--check is required: give one or more check tokens from 'list'"
		return 1
	fi

	local payload
	payload=$(build_page_payload) || return 1

	print_info "Adding status page $OPT_PAGE_NAME..."

	local response
	response=$(execute_request "POST" "/status_pages" "$payload") || return 1
	print_success "Status page added"
	print_status_page "$response" || return 1
	print_status_page_next_steps
	return 0
}

status_page_update() {
	local token="${1:-}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	validate_token "$token" "$KIND_STATUS_PAGE" || return 1
	parse_page_options "$@" || return 1

	local payload
	payload=$(build_page_payload) || return 1
	if [[ "$payload" == "{}" ]]; then
		print_error "Nothing to update: give --name, --check, --description or --visibility"
		return 1
	fi

	print_info "Updating status page $token..."

	local response
	response=$(execute_request "PUT" "/status_pages/$token" "$payload") || return 1
	print_success "Status page $token updated"
	print_status_page "$response" || return 1
	return 0
}

status_page_delete() {
	local token="${1:-}"

	validate_token "$token" "$KIND_STATUS_PAGE" || return 1

	print_info "Deleting status page $token..."

	if execute_request "DELETE" "/status_pages/$token" >/dev/null; then
		print_success "Status page deleted successfully"
		return 0
	fi
	return 1
}

status_page_command() {
	local action="${1:-list}"
	if [[ $# -gt 0 ]]; then
		shift
	fi

	case "$action" in
	list)
		status_page_list || return 1
		;;
	add)
		status_page_add "$@" || return 1
		;;
	update)
		status_page_update "$@" || return 1
		;;
	delete)
		status_page_delete "$@" || return 1
		;;
	*)
		print_error "Unknown status-page action: $action (use list, add, update or delete)"
		return 1
		;;
	esac
	return 0
}

show_help() {
	local name
	name=$(basename "$0")
	cat <<EOF
Usage: $name <command> [arguments...]

One updown.io account monitors every site; each site gets a status page on its
own status.<domain> subdomain. Guide: services/monitoring/updown.md

Checks:
  list                          List all checks (token, URL, alias, status)
  json                          Output raw JSON of all checks
  add <url> [alias] [period] [flags]
                                Add a check, private and hourly unless flags say
                                otherwise; prints the new check's token
  update <token> <flags>        Change only the fields given by flags
  delete <token>                Delete a check
  metrics <token>               Show a check's metrics for the last month (JSON)

Check flags (add and update):
  --alias NAME                  Human-readable name
  --period SECONDS              15, 30, 60, 120, 300, 600, 1800 or 3600 (add: 3600)
  --contains TEXT               Alert unless the page contains TEXT (string match)
  --apdex SECONDS               Apdex threshold: 0.125, 0.25, 0.5, 1.0, 2.0, 4.0 or 8.0
  --recipient ID                Alert recipient id from 'recipients'; repeat for more.
                                Replaces the check's recipient selection
  --public | --private          Publish or hide the check's own updown page
                                (add: private)

Credit cost: updown charges one credit per check request, so per 30 days:
  3600 s = 720      1800 s = 1,440    600 s = 4,320     300 s = 8,640
  120 s = 21,600    60 s = 43,200     30 s = 86,400     15 s = 172,800

Alerts:
  recipients                    List alert recipients (id, type, name)

Status pages:
  status-page list              List status pages (token, URL, visibility, name, checks)
  status-page add --name NAME --check TOKEN [--check TOKEN...]
                  [--description TEXT] [--visibility public|protected|private]
                                Add a page; --check also takes a comma-separated list
  status-page update <token> [same flags]
                                Change only the given fields; --check replaces the list
  status-page delete <token>    Delete a status page

  The updown API cannot set a status page's custom domain. After 'status-page add',
  enter status.<domain> as the page's custom domain on updown.io, then add every
  DNS record that screen lists: CNAME status -> $STATUS_PAGE_CNAME_TARGET
  (Cloudflare: DNS only), plus any TXT record shown there. This helper creates
  no DNS records.

  help                          Show this help message
EOF
	return 0
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION
# ------------------------------------------------------------------------------

main() {
	local command="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi

	check_dependencies || return 1

	local rc=0
	case "$command" in
	"list")
		list_checks || rc=$?
		;;
	"json")
		get_checks_json || rc=$?
		;;
	"add")
		add_check "$@" || rc=$?
		;;
	"update")
		update_check "$@" || rc=$?
		;;
	"delete")
		delete_check "$@" || rc=$?
		;;
	"metrics")
		get_metrics "$@" || rc=$?
		;;
	"recipients")
		list_recipients || rc=$?
		;;
	"status-page" | "status-pages")
		status_page_command "$@" || rc=$?
		;;
	"help" | "-h" | "--help")
		show_help
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		rc=1
		;;
	esac
	return "$rc"
}

main "$@"
