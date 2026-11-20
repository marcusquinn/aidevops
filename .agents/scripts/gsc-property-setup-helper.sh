#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GSC new-property setup: Site Verification DNS_TXT, sites.add, sitemap submit.
# No browser needed. Two phases, because the DNS record is added elsewhere:
#
#   gsc-property-setup-helper.sh txt <domain> [--dry-run]
#   gsc-property-setup-helper.sh complete <domain> [--sitemap URL] [--owner EMAIL] [--dry-run]
#
# Credentials: same ADC resolution as seo-export-gsc.sh (gsc-auth-lib.sh), but
# with the siteverification + webmasters (read/write) scopes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	source "$SCRIPT_DIR/shared-constants.sh"
fi
# shellcheck source=./gsc-auth-lib.sh
source "$SCRIPT_DIR/gsc-auth-lib.sh"

readonly SV_API="https://www.googleapis.com/siteVerification/v1"
readonly SC_API="https://searchconsole.googleapis.com/webmasters/v3"

DRY_RUN=false

_gsc_setup_err() {
	local msg="$1"
	printf 'ERROR: %s\n' "$msg" >&2
	return 0
}

# URL-encode a string via jq.
_gsc_setup_urlencode() {
	local value="$1"
	printf '%s' "$value" | jq -sRr @uri
	return 0
}

# Validate a bare domain (no scheme, path or whitespace).
_gsc_setup_valid_domain() {
	local domain="$1"
	[[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || return 1
	return 0
}

_gsc_setup_token() {
	local cred_file
	cred_file=$(gsc_adc_credential_file)
	if [[ -z "$cred_file" ]]; then
		_gsc_setup_err "No GSC credentials (GOOGLE_APPLICATION_CREDENTIALS, ~/.config/aidevops/gsc-credentials.json or gcloud ADC)"
		return 1
	fi
	gsc_adc_access_token "$cred_file" "${GSC_SITE_VERIFICATION_SCOPE},${GSC_WEBMASTERS_SCOPE}" || {
		_gsc_setup_err "Token request failed for scopes siteverification + webmasters"
		return 1
	}
	return 0
}

# _gsc_setup_call <method> <url> [json-body]
# Prints the response body; with --dry-run prints the planned call instead.
_gsc_setup_call() {
	local method="$1"
	local url="$2"
	local body="${3:-}"
	if [[ "$DRY_RUN" == true ]]; then
		printf 'DRY-RUN: %s %s%s\n' "$method" "$url" "${body:+ $body}" >&2
		printf '{}\n'
		return 0
	fi
	local token
	token=$(_gsc_setup_token) || return 1
	local -a args=(-sS -X "$method" "$url" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -w '\n%{http_code}')
	[[ -n "$body" ]] && args+=(-d "$body")
	local out code
	out=$(curl "${args[@]}") || return 1
	code="${out##*$'\n'}"
	out="${out%$'\n'*}"
	if [[ "$code" != 2* ]]; then
		_gsc_setup_err "$method $url returned HTTP $code: $out"
		return 1
	fi
	printf '%s\n' "$out"
	return 0
}

# Step 1: request the DNS TXT verification token.
cmd_txt() {
	local domain="$1"
	local body resp
	body=$(jq -nc --arg d "$domain" '{site:{type:"INET_DOMAIN",identifier:$d},verificationMethod:"DNS_TXT"}')
	resp=$(_gsc_setup_call POST "$SV_API/token" "$body") || return 1
	if [[ "$DRY_RUN" == true ]]; then
		return 0
	fi
	printf 'Add this TXT record at the root of %s, then run: complete %s\n' "$domain" "$domain"
	printf '%s\n' "$resp" | jq -r '.token'
	return 0
}

# Steps 3-5: verify, add the property, submit the sitemap.
cmd_complete() {
	local domain="$1"
	local sitemap="$2"
	local owner="$3"
	local site="sc-domain:$domain"
	local enc_site body
	enc_site=$(_gsc_setup_urlencode "$site")

	body=$(jq -nc --arg d "$domain" --arg o "$owner" \
		'{site:{type:"INET_DOMAIN",identifier:$d}} + (if $o == "" then {} else {owners:[$o]} end)')
	_gsc_setup_call POST "$SV_API/webResource?verificationMethod=DNS_TXT" "$body" >/dev/null || return 1
	printf 'Verified %s\n' "$domain"

	_gsc_setup_call PUT "$SC_API/sites/$enc_site" >/dev/null || return 1
	printf 'Added property %s\n' "$site"

	if [[ -n "$sitemap" ]]; then
		_gsc_setup_call PUT "$SC_API/sites/$enc_site/sitemaps/$(_gsc_setup_urlencode "$sitemap")" >/dev/null || return 1
		printf 'Submitted sitemap %s\n' "$sitemap"
	fi
	return 0
}

show_help() {
	cat <<'EOF'
Usage: gsc-property-setup-helper.sh <command> <domain> [options]

Commands:
  txt <domain>        Request the DNS TXT value to add at the DNS host
  complete <domain>   Verify, add sc-domain:<domain>, submit the sitemap

Options:
  --sitemap URL       Sitemap to submit (complete)
  --owner EMAIL       Extra human owner added at verification (complete)
  --dry-run           Print planned calls without sending them
EOF
	return 0
}

main() {
	local cmd="${1:-help}"
	local domain="${2:-}"
	local sitemap="" owner=""
	[[ $# -ge 2 ]] && shift 2 || shift $#
	while [[ $# -gt 0 ]]; do
		local _opt="$1"
		case "$_opt" in
		--dry-run) DRY_RUN=true ;;
		--sitemap)
			sitemap="${2:-}"
			shift
			;;
		--owner)
			owner="${2:-}"
			shift
			;;
		*)
			_gsc_setup_err "Unknown option: $_opt"
			return 1
			;;
		esac
		shift
	done

	case "$cmd" in
	txt | complete)
		_gsc_setup_valid_domain "$domain" || {
			_gsc_setup_err "Invalid domain: '$domain'"
			return 1
		}
		if [[ "$cmd" == "txt" ]]; then
			cmd_txt "$domain"
		else
			cmd_complete "$domain" "$sitemap" "$owner"
		fi
		return $?
		;;
	help | -h | --help)
		show_help
		return 0
		;;
	*)
		show_help
		return 1
		;;
	esac
}

main "$@"
