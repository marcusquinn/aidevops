#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# =============================================================================
# Purelymail helper (GH#38865): domains, DNS, mailboxes, routing, IMAP checks
# =============================================================================
# Calls the Purelymail API (POST https://purelymail.com/api/v0/<endpoint>,
# header Purelymail-Api-Token) with the token injected from aidevops secrets.
# Cloudflare DNS writes go through the `cf` CLI, also with an injected token.
# Secret values never appear in argv, stdout or stderr: secret-helper.sh
# injects them into a child run of this script (the __* internal commands),
# which hands them to curl through a config on a file descriptor.
# Sieve filters use email-sieve-helper.sh and its shared ManageSieve client, which
# reads the password from the injected environment variable.
#
# Usage: purelymail-helper.sh <command> [args]   (purelymail-helper.sh help)
# Docs:  .agents/services/email/purelymail.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

PM_SELF="${SCRIPT_DIR}/purelymail-helper.sh"
PM_API_BASE="https://purelymail.com/api/v0"
PM_IMAP_URL="imaps://imap.purelymail.com:993"
PM_TOKEN_SECRET="${PURELYMAIL_TOKEN_SECRET:-PURELYMAIL_API_TOKEN}"
PM_STATE_ROOT="${PURELYMAIL_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/work/purelymail}"
PM_SECRET_HELPER="${SCRIPT_DIR}/secret-helper.sh"
PM_RECORD_COMMENT="purelymail-helper"
PM_OWNERSHIP_PREFIX="purelymail_ownership_proof="
# Parsed DNS options (globals keep Bash 3.2 compatibility without namerefs).
PM_CF_SECRET="${PURELYMAIL_CF_SECRET:-}"
PM_ZONE=""
PM_DRY_RUN=false
PM_YES=false

# --- validation ---------------------------------------------------------------

_pm_valid_domain() {
	local domain="$1"
	[[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && return 0
	print_error "Invalid domain (lowercase, e.g. example.com): $domain"
	return 1
}

_pm_valid_address() {
	local address="$1"
	if [[ "$address" =~ ^[A-Za-z0-9._%+-]+@[a-z0-9.-]+$ ]]; then
		_pm_valid_domain "${address#*@}" || return 1
		return 0
	fi
	print_error "Invalid mail address: $address"
	return 1
}

_pm_valid_secret_name() {
	local name="$1"
	[[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] && return 0
	print_error "Invalid secret name (UPPER_SNAKE_CASE): $name"
	return 1
}

_pm_require() {
	local tool="$1"
	command -v "$tool" >/dev/null 2>&1 && return 0
	print_error "$tool is required but not installed"
	return 1
}

# --- internal commands (run only inside secret injection) ---------------------

# Read the value of the injected variable named VAR_NAME; fail if empty.
_pm_inner_value() {
	local var_name="$1"
	_pm_valid_secret_name "$var_name" >&2 || return 3
	local value="${!var_name:-}"
	if [[ -z "$value" ]]; then
		print_error "Secret $var_name is missing or empty" >&2
		return 3
	fi
	printf '%s' "$value"
	return 0
}

# __post TOKEN_VAR URL: POST the JSON body on stdin with the API token header.
_pm_inner_post() {
	local token_var="$1"
	local url="$2"
	local token
	token=$(_pm_inner_value "$token_var") || return 3
	if [[ ! "$token" =~ ^[A-Za-z0-9._~-]+$ ]]; then
		print_error "Secret $token_var has unexpected characters" >&2
		return 3
	fi
	curl -sS --max-time 60 --proto =https -X POST -H "Content-Type: application/json" \
		-K <(printf 'header = "Purelymail-Api-Token: %s"\n' "$token") \
		--data-binary @- "$url"
	return $?
}

# __create-user TOKEN_VAR PASSWORD_VAR LOCAL DOMAIN URL: createUser with the
# password from an injected secret. createUser defaults enablePasswordReset
# to true, so the request sends false explicitly.
_pm_inner_create_user() {
	local token_var="$1"
	local password_var="$2"
	local local_part="$3"
	local domain="$4"
	local url="$5"
	local password
	password=$(_pm_inner_value "$password_var") || return 3
	# The password reaches jq on stdin (printf is a builtin), never in argv.
	printf '%s' "$password" | jq -Rsc --arg u "$local_part" --arg d "$domain" \
		'{userName: $u, domainName: $d, password: ., enablePasswordReset: false, sendWelcomeEmail: false}' |
		_pm_inner_post "$token_var" "$url"
	return $?
}

# __app-password TOKEN_VAR URL STORE_SECRET: createAppPassword (body on stdin)
# and pipe the result straight into `secret-helper.sh set`.
_pm_inner_app_password() {
	local token_var="$1"
	local url="$2"
	local store_secret="$3"
	_pm_inner_post "$token_var" "$url" |
		jq -er '.result.appPassword // empty' |
		"$PM_SECRET_HELPER" set "$store_secret" >/dev/null
	return $?
}

# __cf TOKEN_VAR ARGS...: run cf with the token as CLOUDFLARE_API_TOKEN.
_pm_inner_cf() {
	local token_var="$1"
	shift
	local token
	token=$(_pm_inner_value "$token_var") || return 3
	CLOUDFLARE_API_TOKEN="$token" CF_SEND_TELEMETRY=false CF_QUIET=1 cf "$@" --quiet
	return $?
}

# __imap PASSWORD_VAR USER URL CURL_ARGS...: one IMAP request as USER.
_pm_inner_imap() {
	local password_var="$1"
	local user="$2"
	local url="$3"
	shift 3
	local password
	password=$(_pm_inner_value "$password_var") || return 3
	password="${password//\\/\\\\}"
	password="${password//\"/\\\"}"
	curl -sS --max-time 60 -K <(printf 'user = "%s:%s"\n' "$user" "$password") "$@" "$url"
	return $?
}

# --- Purelymail API -----------------------------------------------------------

# Fail with the API's own error code/message; succeed only when .result exists.
_pm_check_response() {
	local endpoint="$1"
	local response="$2"
	if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$response"; then
		print_error "Purelymail $endpoint: response was not JSON (check the token and network)"
		return 1
	fi
	if jq -e 'has("result")' >/dev/null <<<"$response"; then
		return 0
	fi
	local code message
	code=$(jq -r '.code // "unknown"' <<<"$response")
	message=$(jq -r '.message // "no message"' <<<"$response")
	print_error "Purelymail $endpoint failed: $code: $message"
	return 1
}

# Report a failed injected request with the next step.
_pm_request_failed() {
	local endpoint="$1"
	local rc="$2"
	print_error "Purelymail $endpoint: request failed (exit $rc). Store the token with: aidevops secret set $PM_TOKEN_SECRET"
	return 0
}

# POST a non-secret JSON body to an endpoint; print the response on success.
_pm_api() {
	local endpoint="$1"
	local body="$2"
	_pm_require curl || return 1
	_pm_require jq || return 1
	local response="" rc=0
	response=$(printf '%s' "$body" |
		"$PM_SECRET_HELPER" "$PM_TOKEN_SECRET" -- "$PM_SELF" __post "$PM_TOKEN_SECRET" "${PM_API_BASE}/${endpoint}") || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		_pm_request_failed "$endpoint" "$rc"
		return 1
	fi
	_pm_check_response "$endpoint" "$response" || return 1
	printf '%s\n' "$response"
	return 0
}

_pm_domain_exists() {
	local domain="$1"
	local response
	response=$(_pm_api listDomains '{}') || return 2
	jq -e --arg d "$domain" '.result.domains[] | select(.name == $d)' >/dev/null <<<"$response" && return 0
	return 1
}

_pm_user_exists() {
	local address="$1"
	local response
	response=$(_pm_api listUser '{}') || return 2
	jq -e --arg u "$address" '.result.users[] | select(ascii_downcase == ($u | ascii_downcase))' >/dev/null <<<"$response" && return 0
	return 1
}

# --- DNS records --------------------------------------------------------------

# Purelymail's published records (purelymail.com/docs/domainDocs), one per
# line: TYPE|FQDN|CONTENT|PRIORITY. The ownership TXT is account-specific.
_pm_expected_records() {
	local domain="$1"
	local ownership_code="$2"
	printf 'MX|%s|mailserver.purelymail.com|50\n' "$domain"
	printf 'TXT|%s|v=spf1 include:_spf.purelymail.com ~all|\n' "$domain"
	if [[ -n "$ownership_code" ]]; then
		printf 'TXT|%s|%s|\n' "$domain" "$ownership_code"
	fi
	local n
	for n in 1 2 3; do
		printf 'CNAME|purelymail%s._domainkey.%s|key%s.dkimroot.purelymail.com|\n' "$n" "$domain" "$n"
	done
	printf 'CNAME|_dmarc.%s|dmarcroot.purelymail.com|\n' "$domain"
	return 0
}

# The portal shows the ownership TXT as purelymail_ownership_proof=<code>; the
# API spec does not say whether .result.code includes that prefix, so accept both.
_pm_ownership_code() {
	local response code
	response=$(_pm_api getOwnershipCode '{}') || return 1
	code=$(jq -r '.result.code // empty' <<<"$response")
	[[ -n "$code" ]] || return 0
	[[ "$code" == "$PM_OWNERSHIP_PREFIX"* ]] || code="${PM_OWNERSHIP_PREFIX}${code}"
	printf '%s\n' "$code"
	return 0
}

# Parse --cf-secret/--zone/--dry-run/--yes for the DNS commands.
_pm_parse_dns_opts() {
	PM_DRY_RUN=false
	PM_YES=false
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		local value="${2:-}"
		case "$flag" in
		--cf-secret | --zone)
			if [[ -z "$value" ]]; then
				print_error "$flag needs a value"
				return 1
			fi
			[[ "$flag" == "--cf-secret" ]] && PM_CF_SECRET="$value"
			[[ "$flag" == "--zone" ]] && PM_ZONE="$value"
			shift 2
			;;
		--dry-run)
			PM_DRY_RUN=true
			shift
			;;
		--yes)
			PM_YES=true
			shift
			;;
		*)
			print_error "Unknown option: $flag"
			return 1
			;;
		esac
	done
	if [[ -z "$PM_CF_SECRET" ]]; then
		print_error "Name the Cloudflare token secret: --cf-secret NAME (see: aidevops secret describe)"
		return 1
	fi
	_pm_valid_secret_name "$PM_CF_SECRET" || return 1
	return 0
}

# Run cf with the chosen Cloudflare token injected.
_pm_cf() {
	_pm_require cf || return 1
	"$PM_SECRET_HELPER" "$PM_CF_SECRET" -- "$PM_SELF" __cf "$PM_CF_SECRET" "$@"
	return $?
}

# Replace a zone name in PM_ZONE with its 32-hex ID. cf resolves a name via
# an account lookup that zone-scoped tokens may not allow; zones list does not.
_pm_resolve_zone() {
	[[ "$PM_ZONE" =~ ^[0-9a-f]{32}$ ]] && return 0
	local out id
	out=$(_pm_cf zones list --name "$PM_ZONE" --per-page 5 2>/dev/null) || {
		print_error "Could not list zones with $PM_CF_SECRET"
		return 1
	}
	id=$(jq -r --arg z "$PM_ZONE" 'first((if type == "array" then . else .result end)[] | select(.name == $z) | .id) // empty' <<<"$out")
	if [[ ! "$id" =~ ^[0-9a-f]{32}$ ]]; then
		print_error "Zone $PM_ZONE is not visible to $PM_CF_SECRET (check: aidevops secret describe)"
		return 1
	fi
	PM_ZONE="$id"
	return 0
}

# Existing records with this exact type and name, as a JSON array.
_pm_cf_list() {
	local type="$1"
	local name="$2"
	local out
	out=$(_pm_cf dns records list --zone "$PM_ZONE" --type "$type" --name-exact "$name" --per-page 100) || return 1
	jq -c 'if type == "array" then . elif has("result") then .result else [.] end' <<<"$out"
	return $?
}

# Compare same-type records with the expected content: ok, missing, proxied or
# rival. Rivals are every other MX, any other SPF TXT, or any other CNAME;
# unrelated TXT records are allowed. Rivals win over a match.
_pm_match_state() {
	local type="$1"
	local content="$2"
	local same="$3"
	jq -r --arg t "$type" --arg c "$content" '
		def norm: ascii_downcase | rtrimstr(".") | ltrimstr("\"") | rtrimstr("\"");
		($c | ascii_downcase) as $want
		| (if $t == "TXT" then map(select($want | startswith("v=spf1")) | select(.content | norm | startswith("v=spf1"))) else . end) as $pool
		| if any($pool[]; (.content | norm) != $want) then "rival"
		  elif all(.[]; (.content | norm) != $want) then "missing"
		  elif any(.[]; (.content | norm) == $want and .proxied == true) then "proxied"
		  else "ok" end' <<<"$same"
	return $?
}

# Classify one expected record against the zone: ok, missing or conflict.
_pm_classify() {
	local type="$1"
	local name="$2"
	local content="$3"
	local same state other others
	same=$(_pm_cf_list "$type" "$name") || return 1
	state=$(_pm_match_state "$type" "$content" "$same") || return 1
	case "$state:$type" in
	rival:MX) echo "conflict: other MX records at $name" ;;
	rival:TXT) echo "conflict: another SPF record at $name (merge it by hand)" ;;
	rival:CNAME) echo "conflict: CNAME at $name points elsewhere" ;;
	proxied:*) echo "conflict: $type at $name is proxied; Purelymail needs DNS only" ;;
	missing:CNAME)
		# A CNAME cannot share its name; find blockers before any write starts.
		for other in A AAAA TXT MX; do
			others=$(_pm_cf_list "$other" "$name") || return 1
			if jq -e 'length > 0' >/dev/null <<<"$others"; then
				echo "conflict: $other record exists at $name"
				return 0
			fi
		done
		echo "missing"
		;;
	*) echo "$state" ;;
	esac
	return 0
}

_pm_state_file() {
	local domain="$1"
	local dir="${PM_STATE_ROOT}/${domain}"
	mkdir -p "$dir" || return 1
	chmod 700 "$dir"
	echo "${dir}/dns-created.jsonl"
	return 0
}

_pm_create_record() {
	local type="$1"
	local name="$2"
	local content="$3"
	local priority="$4"
	local state_file="$5"
	local body out id
	body=$(jq -cn --arg t "$type" --arg n "$name" --arg c "$content" --arg p "$priority" --arg m "$PM_RECORD_COMMENT" \
		'{type: $t, name: $n, content: $c, ttl: 1, comment: $m}
		+ (if $p != "" then {priority: ($p | tonumber)} else {} end)
		+ (if $t == "CNAME" then {proxied: false} else {} end)')
	out=$(_pm_cf dns records create --zone "$PM_ZONE" --body "$body") || return 1
	id=$(jq -r '(.result // .) | .id // empty' <<<"$out")
	if [[ -z "$id" ]]; then
		print_error "Cloudflare did not return a record ID for $type $name"
		return 1
	fi
	if ! jq -cn --arg id "$id" --arg t "$type" --arg n "$name" --arg c "$content" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{id: $id, type: $t, name: $n, content: $c, created_at: $at}' >>"$state_file"; then
		print_error "Created $type $name ($id) but could not record it in $state_file; delete it by hand"
		return 1
	fi
	chmod 600 "$state_file"
	print_success "Created $type $name ($id)"
	return 0
}

# --- commands -----------------------------------------------------------------

cmd_domains() {
	local response
	response=$(_pm_api listDomains '{}') || return 1
	jq -r '.result.domains[] | [.name, "mx=\(.dnsSummary.passesMx)", "spf=\(.dnsSummary.passesSpf)",
		"dkim=\(.dnsSummary.passesDkim)", "dmarc=\(.dnsSummary.passesDmarc)",
		"allowAccountReset=\(.allowAccountReset)"] | @tsv' <<<"$response"
	return 0
}

cmd_dns_records() {
	local domain="${1:-}"
	_pm_valid_domain "$domain" || return 1
	local code=""
	code=$(_pm_ownership_code) || print_warning "Ownership TXT omitted: the account code needs $PM_TOKEN_SECRET" >&2
	printf 'TYPE\tNAME\tCONTENT\tPRIORITY\n'
	_pm_expected_records "$domain" "$code" | tr '|' '\t'
	return 0
}

# Create missing records; refuse every write if any record conflicts.
cmd_dns_apply() {
	local domain="${1:-}"
	_pm_valid_domain "$domain" || return 1
	shift
	_pm_parse_dns_opts "$@" || return 1
	[[ -n "$PM_ZONE" ]] || PM_ZONE="$domain"
	local code=""
	code=$(_pm_ownership_code) || code=""
	if [[ -z "$code" && "$PM_DRY_RUN" != true ]]; then
		print_error "No Purelymail ownership code; a real apply needs $PM_TOKEN_SECRET"
		return 1
	fi
	[[ -n "$code" ]] || print_warning "Dry run without the ownership TXT (no Purelymail token)" >&2
	_pm_resolve_zone || return 1

	local plan="" type name content priority status conflicts=0 missing=0
	while IFS='|' read -r type name content priority; do
		status=$(_pm_classify "$type" "$name" "$content") || return 1
		printf '%-6s %-45s %s\n' "$type" "$name" "$status"
		case "$status" in
		conflict*) conflicts=$((conflicts + 1)) ;;
		missing)
			missing=$((missing + 1))
			plan+="${type}|${name}|${content}|${priority}"$'\n'
			;;
		esac
	done < <(_pm_expected_records "$domain" "$code")

	if [[ "$conflicts" -gt 0 ]]; then
		print_error "$conflicts conflicting record(s); nothing written. Fix them in the zone, then re-run."
		return 1
	fi
	if [[ "$missing" -eq 0 ]]; then
		print_success "All Purelymail records already present; no changes"
		return 0
	fi
	if [[ "$PM_DRY_RUN" == true ]]; then
		print_info "Dry run: $missing record(s) would be created"
		return 0
	fi
	local state_file
	state_file=$(_pm_state_file "$domain") || return 1
	while IFS='|' read -r type name content priority; do
		[[ -n "$type" ]] || continue
		_pm_create_record "$type" "$name" "$content" "$priority" "$state_file" || return 1
	done <<<"$plan"
	print_info "Record IDs saved for rollback: $state_file"
	print_info "Next: purelymail-helper.sh domain-add $domain  (after DNS propagates)"
	return 0
}

# Delete only the records this helper created, from the saved IDs.
cmd_dns_rollback() {
	local domain="${1:-}"
	_pm_valid_domain "$domain" || return 1
	shift
	_pm_parse_dns_opts "$@" || return 1
	[[ -n "$PM_ZONE" ]] || PM_ZONE="$domain"
	local state_file="${PM_STATE_ROOT}/${domain}/dns-created.jsonl"
	if [[ ! -s "$state_file" ]]; then
		print_info "No records created by this helper for $domain"
		return 0
	fi
	jq -r '"\(.type)\t\(.name)\t\(.content)\t\(.id)"' "$state_file"
	if [[ "$PM_DRY_RUN" == true ]]; then
		print_info "Dry run: nothing deleted"
		return 0
	fi
	if [[ "$PM_YES" != true ]]; then
		print_info "Re-run with --yes to delete these records"
		return 0
	fi
	_pm_resolve_zone || return 1
	local remaining id rc=0
	remaining=$(mktemp "${state_file}.XXXXXX") || return 1
	while IFS= read -r id; do
		if _pm_cf dns records delete "$id" --zone "$PM_ZONE" --force >/dev/null; then
			print_success "Deleted $id"
		else
			print_error "Could not delete $id; kept in the state file"
			jq -c --arg id "$id" 'select(.id == $id)' "$state_file" >>"$remaining"
			rc=1
		fi
	done < <(jq -r '.id' "$state_file")
	mv "$remaining" "$state_file"
	chmod 600 "$state_file"
	return "$rc"
}

# Compare public DNS with the expected records, then ask Purelymail to recheck.
cmd_dns_check() {
	local domain="${1:-}"
	_pm_valid_domain "$domain" || return 1
	_pm_require dig || return 1
	local code="" type name content priority answer want failures=0
	code=$(_pm_ownership_code) || print_warning "Ownership TXT not checked (needs $PM_TOKEN_SECRET)" >&2
	while IFS='|' read -r type name content priority; do
		answer=$(dig +short "$type" "$name" | tr -d '"' | sed 's/\.$//' | tr '[:upper:]' '[:lower:]')
		want=$(tr '[:upper:]' '[:lower:]' <<<"$content")
		[[ "$type" == "MX" ]] && want="${priority} ${want}"
		if grep -Fxq -- "$want" <<<"$answer"; then
			print_success "$type $name"
		else
			print_error "$type $name: expected '$want'"
			failures=$((failures + 1))
		fi
	done < <(_pm_expected_records "$domain" "$code")
	if _pm_domain_exists "$domain"; then
		_pm_api updateDomainSettings "$(jq -cn --arg d "$domain" '{name: $d, recheckDns: true}')" >/dev/null || return 1
		_pm_api listDomains '{}' | jq -r --arg d "$domain" '.result.domains[] | select(.name == $d)
			| "Purelymail sees: mx=\(.dnsSummary.passesMx) spf=\(.dnsSummary.passesSpf) dkim=\(.dnsSummary.passesDkim) dmarc=\(.dnsSummary.passesDmarc)"'
	fi
	[[ "$failures" -eq 0 ]] || return 1
	return 0
}

cmd_domain_add() {
	local domain="${1:-}"
	_pm_valid_domain "$domain" || return 1
	local exists=0
	_pm_domain_exists "$domain" || exists=$?
	[[ "$exists" -eq 2 ]] && return 1
	if [[ "$exists" -eq 0 ]]; then
		print_info "$domain is already on the account"
		return 0
	fi
	if ! _pm_api addDomain "$(jq -cn --arg d "$domain" '{domainName: $d}')" >/dev/null; then
		print_info "addDomain needs the ownership TXT live first: purelymail-helper.sh dns-check $domain"
		return 1
	fi
	print_success "Added $domain"
	return 0
}

# Password reset off for a user, then read it back.
_pm_reset_off() {
	local address="$1"
	_pm_api modifyUser "$(jq -cn --arg u "$address" '{userName: $u, enablePasswordReset: false}')" >/dev/null || return 1
	local response
	response=$(_pm_api getUser "$(jq -cn --arg u "$address" '{userName: $u}')") || return 1
	if jq -e '.result.recoveryEnabled == false' >/dev/null <<<"$response"; then
		print_success "$address: password reset is off"
		return 0
	fi
	print_error "$address: password reset still reported as enabled"
	return 1
}

cmd_users() {
	_pm_api listUser '{}' | jq -r '.result.users[]'
	return 0
}

# Create a mailbox with reset off and no welcome mail; password from a secret.
cmd_user_create() {
	local address="${1:-}"
	_pm_valid_address "$address" || return 1
	shift
	local password_secret=""
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		local value="${2:-}"
		case "$opt" in
		--password-secret)
			password_secret="$value"
			shift 2 || shift
			;;
		*)
			print_error "Unknown option: $opt"
			return 1
			;;
		esac
	done
	if [[ -z "$password_secret" ]]; then
		print_error "Usage: user-create <addr> --password-secret NAME (store it first: aidevops secret set NAME)"
		return 1
	fi
	_pm_valid_secret_name "$password_secret" || return 1

	local exists=0
	_pm_user_exists "$address" || exists=$?
	[[ "$exists" -eq 2 ]] && return 1
	if [[ "$exists" -eq 0 ]]; then
		print_info "$address already exists; enforcing reset off"
		_pm_reset_off "$address"
		return $?
	fi

	local response="" rc=0
	response=$("$PM_SECRET_HELPER" "$PM_TOKEN_SECRET" "$password_secret" -- "$PM_SELF" __create-user \
		"$PM_TOKEN_SECRET" "$password_secret" "${address%@*}" "${address#*@}" "${PM_API_BASE}/createUser") || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		_pm_request_failed createUser "$rc"
		return 1
	fi
	_pm_check_response createUser "$response" || return 1
	print_success "Created $address"
	_pm_reset_off "$address"
	return $?
}

cmd_user_reset_off() {
	local address="${1:-}"
	_pm_valid_address "$address" || return 1
	_pm_reset_off "$address"
	return $?
}

# Create an app password and store it straight into a secret; never print it.
cmd_app_password() {
	local address="${1:-}"
	_pm_valid_address "$address" || return 1
	shift
	local store_secret="" label="aidevops"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		local value="${2:-}"
		case "$opt" in
		--store-secret) store_secret="$value" ;;
		--label) label="$value" ;;
		*)
			print_error "Unknown option: $opt"
			return 1
			;;
		esac
		shift 2 || shift
	done
	if [[ -z "$store_secret" ]]; then
		print_error "Usage: app-password <addr> --store-secret NAME [--label TEXT]"
		return 1
	fi
	_pm_valid_secret_name "$store_secret" || return 1
	# check: 0 readable, 1 missing, 3 unreadable, 5 timeout. Only 1 is safe to
	# write: set overwrites, and an unreadable secret may still hold a value.
	local check_rc=0
	"$PM_SECRET_HELPER" check "$store_secret" || check_rc=$?
	case "$check_rc" in
	0)
		print_error "Secret $store_secret already exists; choose a new name"
		return 1
		;;
	1) ;;
	*)
		print_error "Could not read secret $store_secret (status $check_rc); refusing to overwrite it"
		return 1
		;;
	esac
	local body
	body=$(jq -cn --arg u "$address" --arg n "$label" '{userHandle: $u, name: $n}')
	if ! printf '%s' "$body" | "$PM_SECRET_HELPER" "$PM_TOKEN_SECRET" -- "$PM_SELF" __app-password \
		"$PM_TOKEN_SECRET" "${PM_API_BASE}/createAppPassword" "$store_secret"; then
		print_error "App password not stored (API error or empty result)"
		return 1
	fi
	if "$PM_SECRET_HELPER" check "$store_secret"; then
		print_success "App password for $address stored as $store_secret (value not shown)"
		return 0
	fi
	print_error "App password created but $store_secret is not readable; delete it in the Purelymail portal"
	return 1
}

cmd_routes() {
	local domain="${1:-}"
	[[ -z "$domain" ]] || _pm_valid_domain "$domain" || return 1
	_pm_api listRoutingRules '{}' | jq -r --arg d "$domain" '.result.rules[] | select($d == "" or .domainName == $d)
		| [(.id | tostring), "\(if .prefix then "prefix:" else "" end)\(.matchUser)@\(.domainName)",
		   (.targetAddresses | join(",")), (if .catchall then "catchall" else "" end)] | @tsv'
	return 0
}

# Route alias@domain to one or more targets; identical rules are left alone.
cmd_route_add() {
	local alias_address="${1:-}"
	_pm_valid_address "$alias_address" || return 1
	shift
	if [[ $# -eq 0 ]]; then
		print_error "Usage: route-add <alias@domain> <target> [target...]"
		return 1
	fi
	local target
	for target in "$@"; do
		_pm_valid_address "$target" || return 1
	done
	local local_part="${alias_address%@*}" domain="${alias_address#*@}"
	local targets existing match
	targets=$(jq -cn '$ARGS.positional | map(ascii_downcase) | sort' --args "$@")
	existing=$(_pm_api listRoutingRules '{}') || return 1
	match=$(jq -c --arg d "$domain" --arg u "$local_part" '[.result.rules[]
		| select(.domainName == $d and (.matchUser | ascii_downcase) == ($u | ascii_downcase) and (.prefix | not))]' <<<"$existing")
	if jq -e --argjson t "$targets" 'any(.[]; (.targetAddresses | map(ascii_downcase) | sort) == $t)' >/dev/null <<<"$match"; then
		print_info "Route $alias_address -> $* already exists"
		return 0
	fi
	if jq -e 'length > 0' >/dev/null <<<"$match"; then
		print_error "A different rule already routes $alias_address (IDs: $(jq -r 'map(.id | tostring) | join(",")' <<<"$match")); delete it first"
		return 1
	fi
	_pm_api createRoutingRule "$(jq -cn --arg d "$domain" --arg u "$local_part" --argjson t "$targets" \
		'{domainName: $d, prefix: false, matchUser: $u, targetAddresses: $t, catchall: false}')" >/dev/null || return 1
	print_success "Routed $alias_address -> $*"
	return 0
}

cmd_route_delete() {
	local rule_id="${1:-}"
	local confirm="${2:-}"
	if [[ ! "$rule_id" =~ ^[0-9]+$ ]]; then
		print_error "Usage: route-delete <rule-id> --yes  (IDs from: routes)"
		return 1
	fi
	if [[ "$confirm" != "--yes" ]]; then
		print_info "Re-run with --yes to delete routing rule $rule_id"
		return 0
	fi
	_pm_api deleteRoutingRule "$(jq -cn --argjson id "$rule_id" '{routingRuleId: $id}')" >/dev/null || return 1
	print_success "Deleted routing rule $rule_id"
	return 0
}

# One IMAP request as ADDRESS with the password from SECRET; output on stdout.
_pm_imap() {
	local address="$1"
	local secret="$2"
	local url="$3"
	shift 3
	_pm_require curl || return 1
	"$PM_SECRET_HELPER" "$secret" -- "$PM_SELF" __imap "$secret" "$address" "$url" "$@"
	return $?
}

cmd_imap_check() {
	local address="${1:-}"
	local secret="${2:-}"
	_pm_valid_address "$address" || return 1
	_pm_valid_secret_name "$secret" || return 1
	local out
	if ! out=$(_pm_imap "$address" "$secret" "${PM_IMAP_URL}/" -X "EXAMINE INBOX"); then
		print_error "IMAP login or EXAMINE failed for $address. With 2FA on, use an app password: app-password $address --store-secret NAME"
		return 1
	fi
	local exists_line=""
	[[ "$out" =~ [0-9]+\ EXISTS ]] && exists_line="${BASH_REMATCH[0]}"
	print_success "IMAP login OK for $address (${exists_line:-INBOX opened})"
	return 0
}

# Unfold header continuation lines so each header is one line.
_pm_unfold_headers() {
	tr -d '\r' | awk '/^[ \t]/ { sub(/^[ \t]+/, " "); line = line $0; next }
		{ if (line != "") print line; line = $0 } END { if (line != "") print line }'
	return 0
}

# Find the newest message whose Subject matches REGEX and show its
# Authentication-Results; succeed only when dkim, spf and dmarc all pass.
cmd_auth_results() {
	local address="${1:-}"
	local secret="${2:-}"
	local subject_regex="${3:-}"
	local last="${4:-20}"
	_pm_valid_address "$address" || return 1
	_pm_valid_secret_name "$secret" || return 1
	if [[ -z "$subject_regex" || ! "$last" =~ ^[0-9]+$ ]]; then
		print_error "Usage: auth-results <addr> <secret-name> <subject-regex> [last-N]"
		return 1
	fi
	local search uid uids headers subject_line tmp_dir header_file found="" fetch_failed=0
	if ! search=$(_pm_imap "$address" "$secret" "${PM_IMAP_URL}/INBOX" -X "UID SEARCH ALL"); then
		print_error "IMAP search failed for $address"
		return 1
	fi
	# IMAP lines end in CRLF: strip CR first, or the last (newest) UID is
	# read as "N\r" and silently dropped by the numeric filter.
	uids=$(tr -d '\r' <<<"$search" | grep -E '^\* SEARCH' | tr ' ' '\n' | grep -E '^[0-9]+$' | tail -n "$last" | sort -rn || true)
	if [[ -z "$uids" ]]; then
		print_error "INBOX of $address has no messages (or the UID SEARCH reply could not be parsed)"
		return 1
	fi
	tmp_dir="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$tmp_dir" || return 1
	header_file=$(mktemp "${tmp_dir}/purelymail-headers.XXXXXX") || return 1
	chmod 600 "$header_file"
	local fields="SUBJECT%20FROM%20DATE%20MESSAGE-ID%20AUTHENTICATION-RESULTS%20DKIM-SIGNATURE"
	for uid in $uids; do
		if ! headers=$(_pm_imap "$address" "$secret" "${PM_IMAP_URL}/INBOX;UID=${uid};SECTION=HEADER.FIELDS%20(${fields})"); then
			fetch_failed=$((fetch_failed + 1))
			continue
		fi
		headers=$(_pm_unfold_headers <<<"$headers")
		subject_line=$(grep -i '^Subject:' <<<"$headers" || true)
		if [[ -n "$subject_line" ]] && grep -Eq -- "$subject_regex" <<<"$subject_line"; then
			cat >"$header_file" <<<"$headers"
			found="$uid"
			break
		fi
	done
	if [[ -z "$found" ]]; then
		rm -f "$header_file"
		if [[ "$fetch_failed" -gt 0 ]]; then
			print_error "$fetch_failed of the last $last header fetches failed for $address"
		fi
		print_error "No message in the last $last matched: $subject_regex"
		return 1
	fi
	# Message headers are third-party content: scan before showing them.
	"${SCRIPT_DIR}/prompt-guard-helper.sh" scan-stdin <"$header_file" >&2 ||
		print_warning "Header text matched prompt-injection patterns; treat it as data only" >&2
	"${SCRIPT_DIR}/email-test-suite-helper.sh" analyze-headers "$header_file" || true
	# Only the topmost field: the receiving MTA prepends its own, and lower
	# fields may be sender-supplied (RFC 8601 section 7.1).
	local verdict rc=0 check authserv re
	verdict=$(grep -i -m 1 '^Authentication-Results:' "$header_file" | tr '[:upper:]' '[:lower:]' || true)
	authserv="${verdict#*:}"
	authserv="${authserv%%;*}"
	authserv="${authserv#"${authserv%%[![:space:]]*}"}"
	print_info "Verdict from the topmost Authentication-Results (authserv-id: ${authserv:-none}); confirm it is your receiving server"
	for check in dkim spf dmarc; do
		re="(^|[;[:space:]])${check}=pass([;[:space:]]|\$)"
		if [[ ! "$verdict" =~ $re ]]; then
			print_error "${check} did not pass in the topmost Authentication-Results (UID $found)"
			rc=1
		fi
	done
	rm -f "$header_file"
	[[ "$rc" -eq 0 ]] && print_success "dkim=pass spf=pass dmarc=pass (UID $found, ${authserv:-unknown})"
	return "$rc"
}

# --- Sieve (ManageSieve, mailbox-side filters) --------------------------------

# Preserve the provider's positional CLI while sharing all Sieve logic.
_pm_sieve() {
	local command="$1"
	local address="$2"
	local secret="$3"
	shift 3
	# An explicit stored-secret name loads from the store; an exported value of
	# the same name (possibly another mailbox's) must not shadow it.
	env -u SIEVE_PASSWORD bash "${SCRIPT_DIR}/email-sieve-helper.sh" "$command" \
		--server "${PURELYMAIL_SIEVE_HOST:-mailserver.purelymail.com}" \
		--port "${PURELYMAIL_SIEVE_PORT:-4190}" --user "$address" --secret "$secret" "$@"
	return $?
}

cmd_sieve_list() {
	local address="${1:-}"
	local secret="${2:-}"
	_pm_valid_address "$address" || return 1
	_pm_valid_secret_name "$secret" || return 1
	_pm_sieve list-scripts "$address" "$secret" || {
		print_error "ManageSieve failed for $address (needs the mailbox password or an app password with SIEVE scope)"
		return 1
	}
	return 0
}

cmd_copy_to() {
	local address="${1:-}"
	local secret="${2:-}"
	local target="${3:-}"
	local option="${4:-}"
	_pm_valid_address "$address" || return 1
	_pm_valid_secret_name "$secret" || return 1
	_pm_valid_address "$target" || return 1
	if [[ -n "$option" && "$option" != "--dry-run" ]]; then
		print_error "Usage: copy-to <addr> <secret-name> <target> [--dry-run]"
		return 1
	fi
	if [[ -n "$option" ]]; then
		_pm_sieve copy-to "$address" "$secret" --target "$target" "$option"
	else
		_pm_sieve copy-to "$address" "$secret" --target "$target"
	fi
	return $?
}

cmd_copy_to_remove() {
	local address="${1:-}"
	local secret="${2:-}"
	local confirm="${3:-}"
	_pm_valid_address "$address" || return 1
	_pm_valid_secret_name "$secret" || return 1
	if [[ "$confirm" == "--yes" ]]; then
		_pm_sieve copy-to-remove "$address" "$secret" "$confirm"
	else
		_pm_sieve copy-to-remove "$address" "$secret"
	fi
	return $?
}

cmd_help() {
	cat <<EOF
Purelymail helper (docs: services/email/purelymail.md)

Token: secret ${PM_TOKEN_SECRET} (override with PURELYMAIL_TOKEN_SECRET=NAME).
The API key is account-wide: treat it as an admin secret.

Domains and DNS
  domains                                   List domains with Purelymail's DNS summary
  dns-records <domain>                      Print the records Purelymail needs
  dns-apply <domain> --cf-secret NAME [--zone Z] [--dry-run]
                                            Create missing records via cf; refuses on any conflict
  dns-rollback <domain> --cf-secret NAME [--zone Z] [--yes]
                                            Delete only records this helper created
  dns-check <domain>                        Compare public DNS, then ask Purelymail to recheck
  domain-add <domain>                       Add the domain (ownership TXT must be live)

Mailboxes and routing
  users                                     List mailboxes
  user-create <addr> --password-secret NAME Create with password reset off, no welcome mail
  user-reset-off <addr>                     Turn password reset off and verify
  app-password <addr> --store-secret NAME [--label TEXT]
                                            Create an app password straight into a secret
  routes [domain]                           List routing rules
  route-add <alias@domain> <target>...      Route an alias (identical rule = no change)
  route-delete <rule-id> --yes              Delete a routing rule
  sieve-list <addr> <secret-name>           List the mailbox's Sieve scripts (read only)
  copy-to <addr> <secret-name> <target> [--dry-run]
                                            Keep mail and copy it to target (Sieve filter)
  copy-to-remove <addr> <secret-name> [--yes]
                                            Remove the copy-to filter

Checks
  imap-check <addr> <secret-name>           IMAP login + EXAMINE INBOX
  auth-results <addr> <secret-name> <subject-regex> [last-N]
                                            Show Authentication-Results of the newest match;
                                            exit 0 only when dkim, spf and dmarc pass
EOF
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	domains) cmd_domains ;;
	dns-records) cmd_dns_records "$@" ;;
	dns-apply) cmd_dns_apply "$@" ;;
	dns-rollback) cmd_dns_rollback "$@" ;;
	dns-check) cmd_dns_check "$@" ;;
	domain-add) cmd_domain_add "$@" ;;
	users) cmd_users ;;
	user-create) cmd_user_create "$@" ;;
	user-reset-off) cmd_user_reset_off "$@" ;;
	app-password) cmd_app_password "$@" ;;
	routes) cmd_routes "$@" ;;
	route-add) cmd_route_add "$@" ;;
	route-delete) cmd_route_delete "$@" ;;
	sieve-list) cmd_sieve_list "$@" ;;
	copy-to) cmd_copy_to "$@" ;;
	copy-to-remove) cmd_copy_to_remove "$@" ;;
	imap-check) cmd_imap_check "$@" ;;
	auth-results) cmd_auth_results "$@" ;;
	# Internal: invoked by secret-helper.sh with secrets in the environment.
	__post) _pm_inner_post "$@" ;;
	__create-user) _pm_inner_create_user "$@" ;;
	__app-password) _pm_inner_app_password "$@" ;;
	__cf) _pm_inner_cf "$@" ;;
	__imap) _pm_inner_imap "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
