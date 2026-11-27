#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Revolut Business Helper for AI DevOps Framework
# Read-only export of Revolut Business accounts, transactions and balances via
# the Business API, for bookkeeping reconciliation.
#
# Usage: revolut-helper.sh [command] [options]
#
# Commands:
#   accounts                          List configured aliases (no API call)
#   accounts <alias>                  List the alias's Revolut accounts and balances
#   transactions <alias> --since YYYY-MM-DD [--until YYYY-MM-DD] [--account ID] --csv <file>
#                                     Export completed transaction legs (paged)
#   balance <alias> [--as-of YYYY-MM-DD] [--account ID]
#                                     Show balances (as-of derived from transaction legs)
#   auth-code <alias> <code>          One-time: exchange the consent authorisation code
#                                     for a refresh token (stored in the secret store)
#   help                              Show this help
#
# Secrets (never printed), stored with `aidevops secret set NAME`; ALIAS is
# upper-cased and '-' becomes '_':
#   REVOLUT_<ALIAS>_CLIENT_ID      Client ID from Business API settings
#   REVOLUT_<ALIAS>_ISS            Domain of the redirect URI (JWT issuer)
#   REVOLUT_<ALIAS>_PRIVATE_KEY    RSA private key PEM (public cert uploaded to Revolut)
#   REVOLUT_<ALIAS>_REFRESH_TOKEN  Refresh token (from auth-code; rotated if Revolut issues a new one)
# Environment: REVOLUT_ENV=live (default) | sandbox.
# Docs: .agents/services/banking/revolut.md
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly RV_PAGE_SIZE=1000
readonly RV_CSV_HEADER="date,id,description,gross,fee,net,balance,currency"

rv_api_base() {
	if [[ "${REVOLUT_ENV:-live}" == "sandbox" ]]; then
		printf '%s' "https://sandbox-b2b.revolut.com/api/1.0"
	else
		printf '%s' "https://b2b.revolut.com/api/1.0"
	fi
	return 0
}

rv_setup_guidance() {
	local alias_upper="$1"
	print_error "Revolut Business credentials for '${alias_upper}' not found or incomplete."
	print_info "One-time setup (Revolut Business > Settings > APIs > Business API): upload your public"
	print_info "certificate, set the redirect URI, authorise read-only access, then store (hidden prompts):"
	print_info "  aidevops secret set REVOLUT_${alias_upper}_CLIENT_ID"
	print_info "  aidevops secret set REVOLUT_${alias_upper}_ISS"
	print_info "  aidevops secret set REVOLUT_${alias_upper}_PRIVATE_KEY --from-file <private-key.pem>"
	print_info "  revolut-helper.sh auth-code ${alias_upper} <code-from-consent-redirect>"
	print_info "See .agents/services/banking/revolut.md"
	return 0
}

rv_validate_alias() {
	local account="$1"
	if [[ -z "$account" || ! "$account" =~ ^[A-Za-z0-9_-]+$ ]]; then
		print_error "Account alias is required and must contain only letters, numbers, underscores, or hyphens"
		return 1
	fi
	return 0
}

rv_validate_date() {
	local value="$1"
	local label="$2"
	if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! python3 -c 'import sys,datetime; datetime.date.fromisoformat(sys.argv[1])' "$value" 2>/dev/null; then
		print_error "${label} must be a valid date in YYYY-MM-DD format"
		return 1
	fi
	return 0
}

rv_validate_token() {
	local value="$1"
	local label="$2"
	if [[ ! "$value" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
		print_error "${label} has unexpected characters"
		return 1
	fi
	return 0
}

rv_alias_upper() {
	local account="$1"
	local upper
	upper="$(printf '%s' "$account" | tr '[:lower:]-' '[:upper:]_')"
	printf '%s' "$upper"
	return 0
}

# curl with headers/secrets supplied through a config on stdin so nothing
# sensitive appears in the process list. Prints body, then HTTP status.
rv_curl() {
	local url="$1"
	local cfg="$2"
	local out
	out="$(printf '%s\n' "$cfg" | curl -sS --max-time 60 -K - -w '\n%{http_code}' "$url")" || return 1
	printf '%s\n' "$out"
	return 0
}

rv_report_http_error() {
	local status="$1"
	local body="$2"
	local detail
	detail="$(printf '%s' "$body" | jq -r '[.error // empty, .error_description // .message // empty] | join(": ")' 2>/dev/null || true)"
	print_error "Revolut API returned HTTP ${status}${detail:+ (${detail})}"
	if [[ "$status" == "401" || "$status" == "403" ]]; then
		print_info "Check the certificate, issuer domain, read scope and consent (re-run auth-code if the refresh token was revoked)."
	fi
	return 0
}

# Build an RS256 client-assertion JWT. Args: client_id iss private_key_pem
rv_client_assertion() {
	local client_id="$1"
	local iss="$2"
	local pem="$3"
	local header payload signing_input sig exp
	exp="$(($(date +%s) + 300))"
	header="$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
	payload="$(jq -cn --arg iss "$iss" --arg sub "$client_id" --argjson exp "$exp" \
		'{iss:$iss,sub:$sub,aud:"https://revolut.com",exp:$exp}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
	signing_input="${header}.${payload}"
	sig="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign <(printf '%s\n' "$pem") 2>/dev/null | openssl base64 -A | tr '+/' '-_' | tr -d '=')" || true
	if [[ -z "$sig" ]]; then
		print_error "Could not sign the client assertion (check REVOLUT_<ALIAS>_PRIVATE_KEY is an RSA PEM key)"
		return 1
	fi
	printf '%s.%s' "$signing_input" "$sig"
	return 0
}

# Persist a rotated refresh token via the secret store (value on stdin).
rv_store_refresh_token() {
	local name="$1"
	local value="$2"
	if printf '%s' "$value" | aidevops secret set "$name" >/dev/null 2>&1; then
		return 0
	fi
	print_warning "Revolut issued a new refresh token but it could not be stored; run: aidevops secret set ${name}"
	return 1
}

# Resolve a secret by name; empty output when unset. Never prints errors.
rv_secret() {
	local name="$1"
	local value
	value="$(aidevops_resolve_secret "$name" 2>/dev/null || true)"
	printf '%s' "$value"
	return 0
}

# Build a curl config for a form POST from key=value args (values are
# pre-validated or base64url, so no quoting characters can appear).
rv_form_cfg() {
	local pair
	printf 'request = POST\nheader = "Accept: application/json"'
	for pair in "$@"; do
		printf '\ndata = "%s"' "$pair"
	done
	return 0
}

# Exchange a grant for an access token. Args: alias grant_type grant_value
# grant_type: refresh_token | authorization_code. Prints the access token.
rv_token_request() {
	local account="$1"
	local grant_type="$2"
	local grant_value="$3"
	local upper client_id iss pem assertion
	upper="$(rv_alias_upper "$account")"
	client_id="$(rv_secret "REVOLUT_${upper}_CLIENT_ID")"
	iss="$(rv_secret "REVOLUT_${upper}_ISS")"
	pem="$(rv_secret "REVOLUT_${upper}_PRIVATE_KEY")"
	if [[ -z "$client_id" || -z "$iss" || -z "$pem" || -z "$grant_value" ]]; then
		rv_setup_guidance "$upper"
		return 1
	fi
	rv_validate_token "$client_id" "Client ID" || return 1
	rv_validate_token "$grant_value" "Grant value" || return 1
	assertion="$(rv_client_assertion "$client_id" "$iss" "$pem")" || return 1

	local grant_param="refresh_token"
	[[ "$grant_type" == "authorization_code" ]] && grant_param="code"
	local cfg resp status body
	cfg="$(rv_form_cfg \
		"grant_type=${grant_type}" \
		"${grant_param}=${grant_value}" \
		"client_id=${client_id}" \
		"client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
		"client_assertion=${assertion}")"
	resp="$(rv_curl "$(rv_api_base)/auth/token" "$cfg")" || {
		print_error "Network error contacting Revolut"
		return 1
	}
	status="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	if [[ "$status" != "200" ]]; then
		rv_report_http_error "$status" "$body"
		return 1
	fi
	local access new_refresh
	access="$(printf '%s' "$body" | jq -r '.access_token // empty')"
	new_refresh="$(printf '%s' "$body" | jq -r '.refresh_token // empty')"
	if [[ -z "$access" ]]; then
		print_error "Revolut token response had no access_token"
		return 1
	fi
	if [[ -n "$new_refresh" && "$new_refresh" != "$grant_value" ]]; then
		rv_store_refresh_token "REVOLUT_${upper}_REFRESH_TOKEN" "$new_refresh" || true
	fi
	printf '%s' "$access"
	return 0
}

rv_get_access_token() {
	local account="$1"
	local upper refresh
	upper="$(rv_alias_upper "$account")"
	refresh="$(rv_secret "REVOLUT_${upper}_REFRESH_TOKEN")"
	if [[ -z "$refresh" ]]; then
		rv_setup_guidance "$upper"
		return 1
	fi
	rv_token_request "$account" "refresh_token" "$refresh"
	return $?
}

# GET with bearer token. Args: token path-with-query. Prints body.
rv_get() {
	local token="$1"
	local path="$2"
	local cfg resp status body
	cfg="$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"' "$token")"
	resp="$(rv_curl "$(rv_api_base)${path}" "$cfg")" || {
		print_error "Network error contacting Revolut"
		return 1
	}
	status="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	if [[ "$status" != "200" ]]; then
		rv_report_http_error "$status" "$body"
		return 1
	fi
	printf '%s' "$body"
	return 0
}

# Normalise one page of transactions (stdin, JSON array) to one JSON object
# per completed leg: {k,date,id,description,gross,fee,balance,currency}.
rv_legs_jq() {
	jq -c '
	.[] | select(.state == "completed") | . as $t |
	($t.legs // [])[] |
	{
	  k: (.leg_id // $t.id),
	  account_id: (.account_id // ""),
	  date: ($t.completed_at // $t.created_at // ""),
	  id: ($t.id // ""),
	  description: (.description // $t.reference // ""),
	  gross: (.amount // 0),
	  fee: (-((.fee // 0) | fabs)),
	  balance: (.balance // ""),
	  currency: (.currency // "")
	}'
	return $?
}

# Format normalised legs (stdin, JSON lines, already de-duplicated and sorted)
# as CSV rows. Same columns as the other bank/payment helpers.
rv_csv_rows_jq() {
	jq -r '
	def r2: (. * 100 | round) / 100 | tostring;
	def q: tostring | gsub("[\r\n]+"; " ") | if test("^[=+@-]") and (test("^-?[0-9.]+$") | not) then "\u0027" + . else . end | "\"" + gsub("\""; "\"\"") + "\"";
	[ .date, .id, .description,
	  (.gross | r2), (.fee | r2), ((.gross + .fee) | r2),
	  (if .balance == "" then "" else (.balance | r2) end), .currency ] | map(q) | join(",")'
	return $?
}

rv_list_account_names() {
	{
		env | sed -n 's/^\(REVOLUT_[A-Za-z0-9_]*_CLIENT_ID\)=.*/\1/p'
		if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
			sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\(REVOLUT_[A-Za-z0-9_]*_CLIENT_ID\)=.*/\2/p' "${HOME}/.config/aidevops/credentials.sh"
		fi
		if command -v gopass >/dev/null 2>&1; then
			gopass ls --flat aidevops/ 2>/dev/null | sed -n 's#^aidevops/\(REVOLUT_[A-Za-z0-9_]*_CLIENT_ID\)$#\1#p'
		fi
	} | sort -u || true
	return 0
}

cmd_accounts() {
	local account="${1:-}"
	if [[ -n "$account" ]]; then
		rv_validate_alias "$account" || return 1
		local token body
		token="$(rv_get_access_token "$account")" || return 1
		body="$(rv_get "$token" "/accounts")" || return 1
		printf '%s' "$body" | jq -r '.[] | "\(.id)  \(.name // "")  \(.currency // "")  balance=\(.balance // "")  state=\(.state // "")"'
		return 0
	fi
	local names
	names="$(rv_list_account_names)"
	if [[ -z "$names" ]]; then
		print_warning "No Revolut aliases configured."
		rv_setup_guidance "<ALIAS>"
		return 0
	fi
	local name alias_name
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		alias_name="${name#REVOLUT_}"
		alias_name="${alias_name%_CLIENT_ID}"
		if aidevops_secret_available "REVOLUT_${alias_name}_REFRESH_TOKEN"; then
			printf '%s\n' "$alias_name"
		else
			printf '%s (missing REVOLUT_%s_REFRESH_TOKEN; run auth-code)\n' "$alias_name" "$alias_name"
		fi
	done <<<"$names"
	return 0
}

cmd_auth_code() {
	local account="${1:-}"
	local code="${2:-}"
	rv_validate_alias "$account" || return 1
	if [[ -z "$code" ]]; then
		print_error "Usage: revolut-helper.sh auth-code <alias> <authorisation-code>"
		return 1
	fi
	local upper token
	upper="$(rv_alias_upper "$account")"
	# The authorisation-code response carries the refresh token; rv_token_request
	# stores it because it differs from the (code) grant value.
	token="$(rv_token_request "$account" "authorization_code" "$code")" || return 1
	[[ -n "$token" ]] || return 1
	if aidevops_secret_available "REVOLUT_${upper}_REFRESH_TOKEN"; then
		print_success "Refresh token stored as REVOLUT_${upper}_REFRESH_TOKEN"
	else
		print_error "Refresh token was not stored; run: aidevops secret set REVOLUT_${upper}_REFRESH_TOKEN"
		return 1
	fi
	return 0
}

# Fetch transaction pages newest-first, moving "to" back until exhausted.
# Args: token from(ISO or empty) to(ISO) account(optional) out-file
rv_fetch_legs() {
	local token="$1"
	local from="$2"
	local to="$3"
	local account_id="$4"
	local out="$5"
	local limit="${6:-0}"
	local query body n oldest prev_oldest="" total=0
	while :; do
		query="/transactions?to=${to}&count=${RV_PAGE_SIZE}"
		[[ -n "$from" ]] && query="${query}&from=${from}"
		[[ -n "$account_id" ]] && query="${query}&account=${account_id}"
		body="$(rv_get "$token" "$query")" || return 1
		n="$(printf '%s' "$body" | jq 'length')"
		printf '%s' "$body" | rv_legs_jq >>"$out"
		total=$((total + n))
		[[ "$n" -ge "$RV_PAGE_SIZE" ]] || break
		[[ "$limit" -gt 0 && "$total" -ge "$limit" ]] && break
		oldest="$(printf '%s' "$body" | jq -r '[.[].created_at] | min')"
		if [[ -z "$oldest" || "$oldest" == "null" || "$oldest" == "$prev_oldest" ]]; then
			print_error "Pagination stalled at ${oldest:-unknown}; narrow the date range"
			return 1
		fi
		prev_oldest="$oldest"
		to="$oldest"
	done
	return 0
}

cmd_transactions() {
	local account="${1:-}"
	shift || true
	local since="" until_date="" csv="" account_id=""
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
		--account)
			account_id="${2:-}"
			shift 2 || true
			;;
		*)
			print_error "Unknown option: ${1:-}"
			return 1
			;;
		esac
	done
	rv_validate_alias "$account" || return 1
	rv_validate_date "$since" "--since" || return 1
	[[ -n "$until_date" ]] || until_date="$(date -u +%Y-%m-%d)"
	rv_validate_date "$until_date" "--until" || return 1
	if [[ -z "$csv" ]]; then
		print_error "--csv <file> is required"
		return 1
	fi
	if [[ "$since" > "$until_date" ]]; then
		print_error "--since must not be after --until"
		return 1
	fi
	if [[ -n "$account_id" && ! "$account_id" =~ ^[A-Za-z0-9-]+$ ]]; then
		print_error "--account must be a Revolut account id"
		return 1
	fi

	local token tmp
	token="$(rv_get_access_token "$account")" || return 1
	tmp="$(mktemp)"
	trap 'rm -f "${tmp:-}"' RETURN
	rv_fetch_legs "$token" "${since}T00:00:00Z" "${until_date}T23:59:59Z" "$account_id" "$tmp" || return 1

	# De-duplicate page-boundary overlaps by leg id; oldest first.
	local sorted
	sorted="$(jq -sc 'unique_by(.k) | sort_by(.date) | .[]' "$tmp")"
	{
		printf '%s\n' "$RV_CSV_HEADER"
		if [[ -n "$sorted" ]]; then
			printf '%s\n' "$sorted" | rv_csv_rows_jq
		fi
	} >"$csv"
	local count net
	count="$(awk 'END{print (NR>0?NR-1:0)}' "$csv")"
	net="$(printf '%s\n' "$sorted" | jq -s '[.[] | (.gross + .fee)] | add // 0 | (. * 100 | round) / 100')"
	print_success "Wrote ${count} transaction legs to ${csv} (net total ${net})"
	return 0
}

cmd_balance() {
	local account="${1:-}"
	shift || true
	local as_of="" account_id=""
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--as-of)
			as_of="${2:-}"
			shift 2 || true
			;;
		--account)
			account_id="${2:-}"
			shift 2 || true
			;;
		*)
			print_error "Unknown option: ${1:-}"
			return 1
			;;
		esac
	done
	rv_validate_alias "$account" || return 1
	if [[ -n "$account_id" && ! "$account_id" =~ ^[A-Za-z0-9-]+$ ]]; then
		print_error "--account must be a Revolut account id"
		return 1
	fi
	local token
	token="$(rv_get_access_token "$account")" || return 1
	if [[ -z "$as_of" ]]; then
		local body
		body="$(rv_get "$token" "/accounts")" || return 1
		printf '%s' "$body" | jq -r --arg a "$account_id" '.[] | select($a == "" or .id == $a) | "\(.id)  \(.name // "")  \(.currency // ""): \(.balance // "")"'
		return 0
	fi
	rv_validate_date "$as_of" "--as-of" || return 1
	# Closing balance = running balance on the newest completed leg up to the date.
	local tmp
	tmp="$(mktemp)"
	trap 'rm -f "${tmp:-}"' RETURN
	rv_fetch_legs "$token" "" "${as_of}T23:59:59Z" "$account_id" "$tmp" "$RV_PAGE_SIZE" || return 1
	print_info "as_of: ${as_of} (latest completed leg per account within the newest ${RV_PAGE_SIZE} legs; use --account for quiet accounts)"
	jq -sr 'sort_by(.date) | group_by(.account_id) | .[] | last | "\(.account_id)  \(.currency): \(.balance)  (leg dated \(.date))"' "$tmp"
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
	accounts) cmd_accounts "$@" ;;
	transactions) cmd_transactions "$@" ;;
	balance | balances) cmd_balance "$@" ;;
	auth-code) cmd_auth_code "$@" ;;
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
