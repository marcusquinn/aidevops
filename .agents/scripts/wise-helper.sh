#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Wise Business Helper for AI DevOps Framework
# Read-only export of Wise Business profiles, balances and statements via the
# Wise Platform API, for bookkeeping reconciliation.
#
# Usage: wise-helper.sh [command] [options]
#
# Commands:
#   accounts                          List configured aliases (no API call)
#   accounts <alias>                  List the alias's profiles and balances
#   transactions <alias> --since YYYY-MM-DD [--until YYYY-MM-DD] [--currency CUR]
#                        [--profile ID] --csv <file>
#                                     Export balance statements (90-day windows)
#   balance <alias> [--as-of YYYY-MM-DD] [--currency CUR] [--profile ID]
#                                     Show balances (as-of = statement closing balance)
#   help                              Show this help
#
# Secrets (never printed), stored with `aidevops secret set NAME`; ALIAS is
# upper-cased and '-' becomes '_':
#   WISE_<ALIAS>_TOKEN        Read-only personal API token
#   WISE_<ALIAS>_PRIVATE_KEY  Optional RSA private key PEM for SCA statement signing
# Environment: WISE_ENV=live (default) | sandbox.
# Docs: .agents/services/banking/wise.md
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly WS_WINDOW_DAYS=90
readonly WS_CSV_HEADER="date,id,description,gross,fee,net,balance,currency"

ws_api_base() {
	if [[ "${WISE_ENV:-live}" == "sandbox" ]]; then
		printf '%s' "https://api.sandbox.transferwise.tech"
	else
		printf '%s' "https://api.wise.com"
	fi
	return 0
}

ws_setup_guidance() {
	local alias_upper="$1"
	print_error "Wise credentials for '${alias_upper}' not found."
	print_info "Wise Business > Settings > Integrations and tools > API tokens: create a READ-ONLY token, then store it (hidden prompt):"
	print_info "  aidevops secret set WISE_${alias_upper}_TOKEN"
	print_info "If statements return an SCA error (EU/UK), upload a public key in the same settings page and store the private key:"
	print_info "  aidevops secret set WISE_${alias_upper}_PRIVATE_KEY --from-file <private-key.pem>"
	print_info "See .agents/services/banking/wise.md"
	return 0
}

ws_validate_alias() {
	local account="$1"
	if [[ -z "$account" || ! "$account" =~ ^[A-Za-z0-9_-]+$ ]]; then
		print_error "Account alias is required and must contain only letters, numbers, underscores, or hyphens"
		return 1
	fi
	return 0
}

ws_validate_date() {
	local value="$1"
	local label="$2"
	if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! python3 -c 'import sys,datetime; datetime.date.fromisoformat(sys.argv[1])' "$value" 2>/dev/null; then
		print_error "${label} must be a valid date in YYYY-MM-DD format"
		return 1
	fi
	return 0
}

ws_alias_upper() {
	local account="$1"
	local upper
	upper="$(printf '%s' "$account" | tr '[:lower:]-' '[:upper:]_')"
	printf '%s' "$upper"
	return 0
}

ws_report_http_error() {
	local status="$1"
	local body="$2"
	local detail
	detail="$(printf '%s' "$body" | jq -r '[.error // .code // empty, .error_description // .message // (.errors[0].message // empty)] | map(select(. != "")) | join(": ")' 2>/dev/null || true)"
	print_error "Wise API returned HTTP ${status}${detail:+ (${detail})}"
	if [[ "$status" == "401" ]]; then
		print_info "Check the token is valid and has not been revoked."
	elif [[ "$status" == "403" ]]; then
		print_info "Statements may require SCA signing: store WISE_<ALIAS>_PRIVATE_KEY (see .agents/services/banking/wise.md)."
	fi
	return 0
}

# Sign a one-time SCA token (RSA-SHA256, base64). Args: pem ott
ws_sign() {
	local pem="$1"
	local ott="$2"
	local sig
	sig="$(printf '%s' "$ott" | openssl dgst -sha256 -sign <(printf '%s\n' "$pem") 2>/dev/null | openssl base64 -A)" || true
	if [[ -z "$sig" ]]; then
		print_error "Could not sign the SCA token (check WISE_<ALIAS>_PRIVATE_KEY is an RSA PEM key)"
		return 1
	fi
	printf '%s' "$sig"
	return 0
}

# One GET. Headers (token, SCA) go through a curl config on stdin so nothing
# sensitive reaches the process list. Args: url cfg hdr-file. Prints body then
# HTTP status.
ws_curl() {
	local url="$1"
	local cfg="$2"
	local hdr_file="$3"
	local out
	out="$(printf '%s\n' "$cfg" | curl -sS --max-time 60 -K - -D "$hdr_file" -w '\n%{http_code}' "$url")" || return 1
	printf '%s\n' "$out"
	return 0
}

# GET with bearer token, transparently completing SCA when a key is configured.
# Args: alias path-with-query. Prints body.
ws_get() {
	local account="$1"
	local path="$2"
	local upper token pem
	upper="$(ws_alias_upper "$account")"
	token="$(aidevops_resolve_secret "WISE_${upper}_TOKEN" 2>/dev/null || true)"
	if [[ -z "$token" ]]; then
		ws_setup_guidance "$upper"
		return 1
	fi
	if [[ ! "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
		print_error "WISE_${upper}_TOKEN has unexpected characters"
		return 1
	fi
	local url cfg hdr resp status body
	url="$(ws_api_base)${path}"
	cfg="$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/json"' "$token")"
	hdr="$(mktemp)"
	trap 'rm -f "${hdr:-}"' RETURN
	resp="$(ws_curl "$url" "$cfg" "$hdr")" || {
		print_error "Network error contacting Wise"
		return 1
	}
	status="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	if [[ "$status" == "403" ]] && grep -qi '^x-2fa-approval-result: *REJECTED' "$hdr"; then
		local ott
		ott="$(sed -n '/^x-2fa-approval:/I{s/^[^:]*: *//;s/[[:space:]]*$//;p;q;}' "$hdr")"
		pem="$(aidevops_resolve_secret "WISE_${upper}_PRIVATE_KEY" 2>/dev/null || true)"
		if [[ -z "$ott" || -z "$pem" ]]; then
			ws_report_http_error "$status" "$body"
			return 1
		fi
		local sig
		sig="$(ws_sign "$pem" "$ott")" || return 1
		cfg="$(printf '%s\nheader = "x-2fa-approval: %s"\nheader = "X-Signature: %s"' "$cfg" "$ott" "$sig")"
		resp="$(ws_curl "$url" "$cfg" "$hdr")" || {
			print_error "Network error contacting Wise"
			return 1
		}
		status="${resp##*$'\n'}"
		body="${resp%$'\n'*}"
	fi
	if [[ "$status" != "200" ]]; then
		ws_report_http_error "$status" "$body"
		return 1
	fi
	printf '%s' "$body"
	return 0
}

# Pick the profile id: explicit, else the business profile, else the only one.
ws_profile_id() {
	local account="$1"
	local explicit="$2"
	if [[ -n "$explicit" ]]; then
		if [[ ! "$explicit" =~ ^[0-9]+$ ]]; then
			print_error "--profile must be a numeric Wise profile id"
			return 1
		fi
		printf '%s' "$explicit"
		return 0
	fi
	local body id
	body="$(ws_get "$account" "/v1/profiles")" || return 1
	id="$(printf '%s' "$body" | jq -r '([.[] | select((.type // "" | ascii_downcase) == "business")] + .)[0].id // empty')"
	if [[ -z "$id" ]]; then
		print_error "No Wise profile found for this token"
		return 1
	fi
	printf '%s' "$id"
	return 0
}

# Emit "start end" ISO-8601 window lines covering [since, until] inclusive.
ws_windows() {
	local since="$1"
	local until_date="$2"
	python3 - "$since" "$until_date" "$WS_WINDOW_DAYS" <<'PY'
import sys, datetime as dt
s = dt.datetime.fromisoformat(sys.argv[1] + "T00:00:00")
e = dt.datetime.fromisoformat(sys.argv[2] + "T23:59:59")
step = dt.timedelta(days=int(sys.argv[3]))
cur = s
while cur <= e:
    end = min(cur + step - dt.timedelta(seconds=1), e)
    print(cur.strftime("%Y-%m-%dT%H:%M:%S.000Z"), end.strftime("%Y-%m-%dT%H:%M:%S.999Z"))
    cur = end + dt.timedelta(seconds=1)
PY
	return 0
}

# Normalise one statement (stdin) to JSON lines {k,date,id,description,gross,fee,balance,currency}.
ws_rows_jq() {
	jq -c '
	(.transactions // [])[] |
	{
	  k: (.referenceNumber // ""),
	  date: (.date // ""),
	  id: (.referenceNumber // ""),
	  description: (.details.description // .details.paymentReference // ""),
	  gross: (.amount.value // 0),
	  fee: (-((.totalFees.value // 0) | fabs)),
	  balance: (.runningBalance.value // ""),
	  currency: (.amount.currency // "")
	}'
	return $?
}

ws_csv_rows_jq() {
	jq -r '
	def r2: (. * 100 | round) / 100 | tostring;
	def q: tostring | gsub("[\r\n]+"; " ") | if test("^[=+@-]") and (test("^-?[0-9.]+$") | not) then "\u0027" + . else . end | "\"" + gsub("\""; "\"\"") + "\"";
	[ .date, .id, .description,
	  (.gross | r2), (.fee | r2), ((.gross + .fee) | r2),
	  (if .balance == "" then "" else (.balance | r2) end), .currency ] | map(q) | join(",")'
	return $?
}

# Balance list for the profile: lines "id currency".
ws_balances() {
	local account="$1"
	local profile="$2"
	local currency="$3"
	local body
	body="$(ws_get "$account" "/v4/profiles/${profile}/balances?types=STANDARD")" || return 1
	printf '%s' "$body" | jq -r --arg c "$currency" '.[] | select($c == "" or .currency == $c) | "\(.id) \(.currency)"'
	return 0
}

ws_list_account_names() {
	{
		env | sed -n 's/^\(WISE_[A-Za-z0-9_]*_TOKEN\)=.*/\1/p'
		if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
			sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\(WISE_[A-Za-z0-9_]*_TOKEN\)=.*/\2/p' "${HOME}/.config/aidevops/credentials.sh"
		fi
		if command -v gopass >/dev/null 2>&1; then
			gopass ls --flat aidevops/ 2>/dev/null | sed -n 's#^aidevops/\(WISE_[A-Za-z0-9_]*_TOKEN\)$#\1#p'
		fi
	} | sort -u || true
	return 0
}

cmd_accounts() {
	local account="${1:-}"
	if [[ -n "$account" ]]; then
		ws_validate_alias "$account" || return 1
		local body profile
		body="$(ws_get "$account" "/v1/profiles")" || return 1
		printf '%s' "$body" | jq -r '.[] | "profile \(.id)  type=\(.type // "")  \(.fullName // .businessName // "")"'
		profile="$(ws_profile_id "$account" "")" || return 1
		body="$(ws_get "$account" "/v4/profiles/${profile}/balances?types=STANDARD")" || return 1
		printf '%s' "$body" | jq -r --arg p "$profile" '.[] | "profile \($p)  balance \(.id)  \(.currency): \(.amount.value // "")"'
		return 0
	fi
	local names
	names="$(ws_list_account_names)"
	if [[ -z "$names" ]]; then
		print_warning "No Wise aliases configured."
		ws_setup_guidance "<ALIAS>"
		return 0
	fi
	local name alias_name
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		alias_name="${name#WISE_}"
		alias_name="${alias_name%_TOKEN}"
		printf '%s\n' "$alias_name"
	done <<<"$names"
	return 0
}

cmd_transactions() {
	local account="${1:-}"
	shift || true
	local since="" until_date="" csv="" currency="" profile_arg=""
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
		--currency)
			currency="${2:-}"
			shift 2 || true
			;;
		--profile)
			profile_arg="${2:-}"
			shift 2 || true
			;;
		*)
			print_error "Unknown option: ${1:-}"
			return 1
			;;
		esac
	done
	ws_validate_alias "$account" || return 1
	ws_validate_date "$since" "--since" || return 1
	[[ -n "$until_date" ]] || until_date="$(date -u +%Y-%m-%d)"
	ws_validate_date "$until_date" "--until" || return 1
	if [[ -z "$csv" ]]; then
		print_error "--csv <file> is required"
		return 1
	fi
	if [[ "$since" > "$until_date" ]]; then
		print_error "--since must not be after --until"
		return 1
	fi
	if [[ -n "$currency" && ! "$currency" =~ ^[A-Za-z]{3}$ ]]; then
		print_error "--currency must be a 3-letter code"
		return 1
	fi
	currency="$(printf '%s' "$currency" | tr '[:lower:]' '[:upper:]')"

	local profile balances
	profile="$(ws_profile_id "$account" "$profile_arg")" || return 1
	balances="$(ws_balances "$account" "$profile" "$currency")" || return 1
	if [[ -z "$balances" ]]; then
		print_error "No matching Wise balances found"
		return 1
	fi

	local tmp
	tmp="$(mktemp)"
	trap 'rm -f "${tmp:-}"' RETURN
	local bal_id bal_cur start end body
	while read -r bal_id bal_cur; do
		[[ -n "$bal_id" ]] || continue
		while read -r start end; do
			body="$(ws_get "$account" "/v1/profiles/${profile}/balance-statements/${bal_id}/statement.json?currency=${bal_cur}&intervalStart=${start}&intervalEnd=${end}&type=COMPACT")" || return 1
			printf '%s' "$body" | ws_rows_jq >>"$tmp"
		done < <(ws_windows "$since" "$until_date")
	done <<<"$balances"

	local sorted
	sorted="$(jq -sc 'unique_by([.k, .currency]) | sort_by(.date) | .[]' "$tmp")"
	{
		printf '%s\n' "$WS_CSV_HEADER"
		if [[ -n "$sorted" ]]; then
			printf '%s\n' "$sorted" | ws_csv_rows_jq
		fi
	} >"$csv"
	local count net
	count="$(awk 'END{print (NR>0?NR-1:0)}' "$csv")"
	net="$(printf '%s\n' "$sorted" | jq -s 'group_by(.currency) | map("\(.[0].currency)=\(([.[] | (.gross + .fee)] | add // 0 | (. * 100 | round) / 100))") | join(" ")')"
	print_success "Wrote ${count} transactions to ${csv} (net by currency: ${net})"
	return 0
}

cmd_balance() {
	local account="${1:-}"
	shift || true
	local as_of="" currency="" profile_arg=""
	while [[ $# -gt 0 ]]; do
		case "${1:-}" in
		--as-of)
			as_of="${2:-}"
			shift 2 || true
			;;
		--currency)
			currency="${2:-}"
			shift 2 || true
			;;
		--profile)
			profile_arg="${2:-}"
			shift 2 || true
			;;
		*)
			print_error "Unknown option: ${1:-}"
			return 1
			;;
		esac
	done
	ws_validate_alias "$account" || return 1
	if [[ -n "$currency" && ! "$currency" =~ ^[A-Za-z]{3}$ ]]; then
		print_error "--currency must be a 3-letter code"
		return 1
	fi
	currency="$(printf '%s' "$currency" | tr '[:lower:]' '[:upper:]')"
	local profile
	profile="$(ws_profile_id "$account" "$profile_arg")" || return 1
	if [[ -z "$as_of" ]]; then
		local body
		body="$(ws_get "$account" "/v4/profiles/${profile}/balances?types=STANDARD")" || return 1
		printf '%s' "$body" | jq -r --arg c "$currency" '.[] | select($c == "" or .currency == $c) | "\(.currency): \(.amount.value // "")"'
		return 0
	fi
	ws_validate_date "$as_of" "--as-of" || return 1
	local balances bal_id bal_cur body start end
	balances="$(ws_balances "$account" "$profile" "$currency")" || return 1
	start="${as_of}T00:00:00.000Z"
	end="${as_of}T23:59:59.999Z"
	print_info "as_of: ${as_of} (statement closing balance at end of day, UTC)"
	while read -r bal_id bal_cur; do
		[[ -n "$bal_id" ]] || continue
		body="$(ws_get "$account" "/v1/profiles/${profile}/balance-statements/${bal_id}/statement.json?currency=${bal_cur}&intervalStart=${start}&intervalEnd=${end}&type=COMPACT")" || return 1
		printf '%s' "$body" | jq -r --arg c "$bal_cur" '"\($c): \(.endOfStatementBalance.value // "")"'
	done <<<"$balances"
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
