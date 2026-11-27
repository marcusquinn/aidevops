#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# PayPal Reporting Helper for AI DevOps Framework
# Read-only export of PayPal business account transactions and balances via the
# REST Transaction Search / Balances APIs, for bookkeeping reconciliation.
#
# Usage: paypal-helper.sh [command] [options]
#
# Commands:
#   accounts                          List configured PayPal account aliases
#   transactions <alias> --since YYYY-MM-DD [--until YYYY-MM-DD] --csv <file>
#                                     Export transactions (31-day windows, paged)
#   balances <alias> [--as-of YYYY-MM-DD]
#                                     Show balances (/v1/reporting/balances)
#   help                              Show this help
#
# Secrets (never printed): PAYPAL_<ALIAS>_CLIENT_ID and PAYPAL_<ALIAS>_SECRET,
# stored with `aidevops secret set NAME`. ALIAS is upper-cased, '-' becomes '_'.
# Environment: PAYPAL_ENV=live (default) | sandbox.
# Docs: .agents/services/payments/paypal.md
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly PP_WINDOW_DAYS=30
readonly PP_PAGE_SIZE=500
readonly PP_CSV_HEADER="date,id,description,gross,fee,net,balance,currency"

pp_api_base() {
	if [[ "${PAYPAL_ENV:-live}" == "sandbox" ]]; then
		printf '%s' "https://api-m.sandbox.paypal.com"
	else
		printf '%s' "https://api-m.paypal.com"
	fi
	return 0
}

pp_setup_guidance() {
	local alias_upper="$1"
	print_error "PayPal credentials for '${alias_upper}' not found."
	print_info "Create a Live REST app (developer.paypal.com > Apps & Credentials), enable 'Transaction Search'"
	print_info "(can take up to 9 hours to take effect), then store the credentials:"
	print_info "  aidevops secret set PAYPAL_${alias_upper}_CLIENT_ID"
	print_info "  aidevops secret set PAYPAL_${alias_upper}_SECRET"
	return 0
}

pp_validate_alias() {
	local account="$1"
	if [[ -z "$account" || ! "$account" =~ ^[A-Za-z0-9_-]+$ ]]; then
		print_error "Account alias is required and must contain only letters, numbers, underscores, or hyphens"
		return 1
	fi
	return 0
}

pp_validate_date() {
	local value="$1"
	local label="$2"
	if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! python3 -c 'import sys,datetime; datetime.date.fromisoformat(sys.argv[1])' "$value" 2>/dev/null; then
		print_error "${label} must be a valid date in YYYY-MM-DD format"
		return 1
	fi
	return 0
}

pp_alias_upper() {
	local account="$1"
	local upper
	upper="$(printf '%s' "$account" | tr '[:lower:]-' '[:upper:]_')"
	printf '%s' "$upper"
	return 0
}

# Perform a curl call with secrets/headers passed through a config on stdin,
# so nothing sensitive appears in the process list. Args: method url [data]
# Reads CURL_CFG (extra config lines) from the caller. Prints body, then the
# HTTP status on the final line.
pp_curl() {
	local url="$1"
	local cfg="$2"
	local data="${3:-}"
	local out
	if [[ -n "$data" ]]; then
		out="$(printf '%s\n' "$cfg" | curl -sS --max-time 60 -K - -w '\n%{http_code}' --data "$data" "$url")" || return 1
	else
		out="$(printf '%s\n' "$cfg" | curl -sS --max-time 60 -K - -w '\n%{http_code}' "$url")" || return 1
	fi
	printf '%s\n' "$out"
	return 0
}

# Print a sanitised API error (name/message only; never the response in full).
pp_report_http_error() {
	local status="$1"
	local body="$2"
	local detail
	detail="$(printf '%s' "$body" | jq -r '[.name // .error // empty, .message // .error_description // empty] | join(": ")' 2>/dev/null || true)"
	print_error "PayPal API returned HTTP ${status}${detail:+ (${detail})}"
	if [[ "$status" == "403" ]]; then
		print_info "Check that 'Transaction Search' is enabled on the app (may take up to 9 hours)."
	fi
	return 0
}

# Obtain an OAuth token for the alias. Prints the token on stdout.
pp_get_token() {
	local account="$1"
	local upper client_id secret
	upper="$(pp_alias_upper "$account")"
	client_id="$(aidevops_resolve_secret "PAYPAL_${upper}_CLIENT_ID" 2>/dev/null || true)"
	secret="$(aidevops_resolve_secret "PAYPAL_${upper}_SECRET" 2>/dev/null || true)"
	if [[ -z "$client_id" || -z "$secret" ]]; then
		pp_setup_guidance "$upper"
		return 1
	fi
	local cfg resp status body
	cfg="$(printf 'user = "%s:%s"\nheader = "Accept: application/json"' "$client_id" "$secret")"
	resp="$(pp_curl "$(pp_api_base)/v1/oauth2/token" "$cfg" "grant_type=client_credentials")" || {
		print_error "Network error contacting PayPal"
		return 1
	}
	status="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	if [[ "$status" != "200" ]]; then
		pp_report_http_error "$status" "$body"
		return 1
	fi
	local token
	token="$(printf '%s' "$body" | jq -r '.access_token // empty')"
	if [[ -z "$token" ]]; then
		print_error "PayPal token response had no access_token"
		return 1
	fi
	printf '%s' "$token"
	return 0
}

# GET with bearer token. Prints body on stdout; returns 1 on non-200.
pp_get() {
	local token="$1"
	local url="$2"
	local cfg resp status body
	cfg="$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"' "$token")"
	resp="$(pp_curl "$url" "$cfg")" || {
		print_error "Network error contacting PayPal"
		return 1
	}
	status="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	if [[ "$status" != "200" ]]; then
		pp_report_http_error "$status" "$body"
		return 1
	fi
	printf '%s' "$body"
	return 0
}

# Emit "start end" ISO-8601 window lines covering [since, until] inclusive.
pp_windows() {
	local since="$1"
	local until_date="$2"
	python3 - "$since" "$until_date" "$PP_WINDOW_DAYS" <<'PY'
import sys, datetime as dt
s = dt.datetime.fromisoformat(sys.argv[1] + "T00:00:00")
e = dt.datetime.fromisoformat(sys.argv[2] + "T23:59:59")
step = dt.timedelta(days=int(sys.argv[3]))
cur = s
while cur <= e:
    end = min(cur + step - dt.timedelta(seconds=1), e)
    print(cur.strftime("%Y-%m-%dT%H:%M:%S-0000"), end.strftime("%Y-%m-%dT%H:%M:%S-0000"))
    cur = end + dt.timedelta(seconds=1)
PY
	return 0
}

# Convert one page of transaction_details JSON (stdin) to CSV rows (no header).
pp_rows_jq() {
	jq -r '
	def amt(x): (x.value // "0");
	(.transaction_details // [])[] |
	.transaction_info as $t |
	[
	  ($t.transaction_initiation_date // ""),
	  ($t.transaction_id // ""),
	  ($t.transaction_subject // $t.transaction_note // $t.transaction_event_code // ""),
	  amt($t.transaction_amount),
	  amt($t.fee_amount),
	  ((amt($t.transaction_amount) | tonumber) + (amt($t.fee_amount) | tonumber) | . * 100 | round / 100 | tostring),
	  amt($t.ending_balance),
	  ($t.transaction_amount.currency_code // "")
	] | map(tostring | gsub("[\r\n]+"; " ") | if test("^[=+@-]") and (test("^-?[0-9.]+$") | not) then "\u0027" + . else . end | "\"" + gsub("\""; "\"\"") + "\"") | join(",")'
	return $?
}

cmd_accounts() {
	local names
	names="$( {
		env | sed -n 's/^\(PAYPAL_[A-Za-z0-9_]*_CLIENT_ID\)=.*/\1/p'
		if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
			sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\(PAYPAL_[A-Za-z0-9_]*_CLIENT_ID\)=.*/\2/p' "${HOME}/.config/aidevops/credentials.sh"
		fi
		if command -v gopass >/dev/null 2>&1; then
			gopass ls --flat aidevops/ 2>/dev/null | sed -n 's#^aidevops/\(PAYPAL_[A-Za-z0-9_]*_CLIENT_ID\)$#\1#p'
		fi
	} | sort -u || true)"
	if [[ -z "$names" ]]; then
		print_warning "No PayPal accounts configured."
		pp_setup_guidance "<ALIAS>"
		return 0
	fi
	local name alias_name
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		alias_name="${name#PAYPAL_}"
		alias_name="${alias_name%_CLIENT_ID}"
		if aidevops_secret_available "PAYPAL_${alias_name}_SECRET"; then
			printf '%s\n' "$alias_name"
		else
			printf '%s (missing PAYPAL_%s_SECRET)\n' "$alias_name" "$alias_name"
		fi
	done <<<"$names"
	return 0
}

cmd_transactions() {
	local account="${1:-}"
	shift || true
	local since="" until_date="" csv=""
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--since)
			since="${2:-}"
			shift 2 || true
			;;
		--until)
			until_date="${2:-}"
			shift 2 || true
			;;
		--csv)
			csv="${2:-}"
			shift 2 || true
			;;
		*)
			print_error "Unknown option: ${1:-}"
			return 1
			;;
		esac
	done
	pp_validate_alias "$account" || return 1
	pp_validate_date "$since" "--since" || return 1
	[[ -n "$until_date" ]] || until_date="$(date -u +%Y-%m-%d)"
	pp_validate_date "$until_date" "--until" || return 1
	if [[ -z "$csv" ]]; then
		print_error "--csv <file> is required"
		return 1
	fi
	if [[ "$since" > "$until_date" ]]; then
		print_error "--since must not be after --until"
		return 1
	fi

	local token
	token="$(pp_get_token "$account")" || return 1

	local tmp
	tmp="$(mktemp)"
	trap 'rm -f "${tmp:-}"' RETURN
	local start end page total_pages body base
	base="$(pp_api_base)"
	while read -r start end; do
		page=1
		total_pages=1
		while [[ "$page" -le "$total_pages" ]]; do
			body="$(pp_get "$token" "${base}/v1/reporting/transactions?start_date=${start}&end_date=${end}&fields=transaction_info&balance_affecting_records_only=Y&page_size=${PP_PAGE_SIZE}&page=${page}")" || return 1
			total_pages="$(printf '%s' "$body" | jq -r '.total_pages // 1')"
			printf '%s' "$body" | pp_rows_jq >>"$tmp"
			page=$((page + 1))
		done
	done < <(pp_windows "$since" "$until_date")

	# Window boundaries are inclusive: de-duplicate by transaction id (column 2).
	{
		printf '%s\n' "$PP_CSV_HEADER"
		awk -F'","' '!seen[$2]++' "$tmp" | sort -t, -k1,1
	} >"$csv"
	local count
	count="$(awk 'END{print NR-1}' "$csv")"
	print_success "Wrote ${count} transactions to ${csv}"
	return 0
}

cmd_balances() {
	local account="${1:-}"
	shift || true
	local as_of=""
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--as-of)
			as_of="${2:-}"
			shift 2 || true
			;;
		*)
			print_error "Unknown option: ${1:-}"
			return 1
			;;
		esac
	done
	pp_validate_alias "$account" || return 1
	local url
	url="$(pp_api_base)/v1/reporting/balances?currency_code=ALL"
	if [[ -n "$as_of" ]]; then
		pp_validate_date "$as_of" "--as-of" || return 1
		url="${url}&as_of_time=${as_of}T23:59:59-0000"
	fi
	local token body
	token="$(pp_get_token "$account")" || return 1
	body="$(pp_get "$token" "$url")" || return 1
	printf '%s' "$body" | jq -r '"as_of: \(.as_of_time // "")", (.balances // [])[] | "\(.currency // .total_balance.currency_code // ""): total=\(.total_balance.value // "") available=\(.available_balance.value // "")"'
	return 0
}

show_help() {
	sed -n '/^# Usage:/,/^# Version:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	accounts) cmd_accounts ;;
	transactions) cmd_transactions "$@" ;;
	balances) cmd_balances "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: ${command}"
		show_help
		return 1
		;;
	esac
	return $?
}

main "$@"
