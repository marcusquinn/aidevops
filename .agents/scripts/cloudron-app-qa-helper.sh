#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# cloudron-app-qa-helper.sh - qualify a Cloudron package on a live, disposable
# test install: health, mail, upload limits, WebSockets, MCP/OAuth, restart,
# backup -> clone, update and memory. Prints PASS:/FAIL: lines and exits
# non-zero on failure. Secrets, setup links, tokens and mail bodies are never
# printed. Every command takes an explicit --server so a different Cloudron's
# production apps can never be touched through the CLI's default server.
#
# Usage: cloudron-app-qa-helper.sh help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

readonly QA_MJS_DIR="${SCRIPT_DIR}/cloudron-app-qa"
readonly QA_CLOUDRON_CONFIG="${CLOUDRON_CONFIG_FILE:-$HOME/.cloudron.json}"
readonly QA_HEALTH_ATTEMPTS=30
readonly QA_HEALTH_DELAY=5

QA_FAILURES=0
QA_SERVER=""
QA_SCRATCH=""
QA_CLEANUP_ARMED=0
QA_POSITIONAL=()
QA_OPT_VERSIONS_URL=""
QA_OPT_IMAGE=""
QA_OPT_BUILD=0
QA_OPT_FORCE_LOCATION=0
QA_OPT_PATH=""
QA_OPT_URL=""
QA_OPT_FIELD="file"
QA_OPT_SIZES="20M,30M"
QA_OPT_LIMIT=""
QA_OPT_ALLOW_502=0
QA_OPT_BEARER_ENV=""
QA_OPT_RESOURCE_PATH="/mcp"
QA_OPT_ADAPTER=""
QA_OPT_RESOLVE=""
QA_OPT_IDLE="330"
QA_OPT_SSH_HOST=""
readonly QA_BOX_USER="yellowtent"
# Cloudron's default box data directory on the server (remote path, not local).
QA_OPT_BOXDATA="$(printf '/%s/%s/%s' home "$QA_BOX_USER" boxdata)"

# --- output helpers ---------------------------------------------------------

qa_pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

qa_fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message"
	QA_FAILURES=$((QA_FAILURES + 1))
	return 0
}

qa_info() {
	local message="$1"
	printf 'INFO: %s\n' "$message"
	return 0
}

qa_die() {
	local message="$1"
	printf 'ERROR: %s\n' "$message" >&2
	return 1
}

# Strip query strings and one-time token paths from text read from mail or logs.
qa_redact() {
	sed -E \
		-e 's/\?[^[:space:]"<>]*//g' \
		-e 's#(/(setup|recovery|invite|join|reset))[^[:space:]"<>]*#\1/[redacted]#g' \
		-e 's/[A-Za-z0-9_.~+=-]{40,}/[redacted]/g'
	return 0
}

# --- argument parsing -------------------------------------------------------

qa_require_value() {
	local flag="$1"
	local count="$2"
	if [[ "$count" -lt 2 ]]; then
		qa_die "Option ${flag} requires a value"
		return 1
	fi
	return 0
}

qa_parse_args() {
	QA_POSITIONAL=()
	local argv=("$@")
	local total="${#argv[@]}"
	local idx=0
	while [[ "$idx" -lt "$total" ]]; do
		local flag="${argv[$idx]}"
		case "$flag" in
		--build) QA_OPT_BUILD=1 ;;
		--force-location) QA_OPT_FORCE_LOCATION=1 ;;
		--allow-502) QA_OPT_ALLOW_502=1 ;;
		--server | --versions-url | --image | --path | --url | --field | --sizes | --limit | \
			--bearer-env | --resource-path | --adapter | --resolve | --idle | --ssh-host | --boxdata)
			qa_require_value "$flag" $((total - idx)) || return 1
			idx=$((idx + 1))
			qa_assign_option "$flag" "${argv[$idx]}"
			;;
		-*)
			qa_die "Unknown option: ${flag}"
			return 1
			;;
		*) QA_POSITIONAL+=("$flag") ;;
		esac
		idx=$((idx + 1))
	done
	return 0
}

qa_assign_option() {
	local flag="$1"
	local value="$2"
	case "$flag" in
	--server) QA_SERVER="$value" ;;
	--versions-url) QA_OPT_VERSIONS_URL="$value" ;;
	--image) QA_OPT_IMAGE="$value" ;;
	--path) QA_OPT_PATH="$value" ;;
	--url) QA_OPT_URL="$value" ;;
	--field) QA_OPT_FIELD="$value" ;;
	--sizes) QA_OPT_SIZES="$value" ;;
	--limit) QA_OPT_LIMIT="$value" ;;
	--bearer-env) QA_OPT_BEARER_ENV="$value" ;;
	--resource-path) QA_OPT_RESOURCE_PATH="$value" ;;
	--adapter) QA_OPT_ADAPTER="$value" ;;
	--resolve) QA_OPT_RESOLVE="$value" ;;
	--idle) QA_OPT_IDLE="$value" ;;
	--ssh-host) QA_OPT_SSH_HOST="$value" ;;
	--boxdata) QA_OPT_BOXDATA="$value" ;;
	esac
	return 0
}

# --- validation -------------------------------------------------------------

qa_valid_host() {
	local host="$1"
	[[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
	return $?
}

qa_valid_location() {
	local location="$1"
	[[ "$location" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
	return $?
}

qa_valid_address() {
	local address="$1"
	[[ "$address" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
	return $?
}

qa_looks_disposable() {
	local location="$1"
	[[ "$location" =~ (-test|-qa|-clone|-tmp)$ ]] || [[ "$location" =~ ^(test|qa)- ]]
	return $?
}

qa_require_server() {
	if [[ -z "$QA_SERVER" ]]; then
		qa_die "--server <cloudron-host> is required (the CLI default server is never used)"
		return 1
	fi
	if ! qa_valid_host "$QA_SERVER"; then
		qa_die "Invalid --server value"
		return 1
	fi
	return 0
}

qa_require_tools() {
	local tool
	for tool in "$@"; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			qa_die "Required tool not found: ${tool}"
			return 1
		fi
	done
	return 0
}

qa_check_location() {
	local location="$1"
	if ! qa_valid_location "$location"; then
		qa_die "Invalid location: ${location}"
		return 1
	fi
	if ! qa_looks_disposable "$location" && [[ "$QA_OPT_FORCE_LOCATION" -ne 1 ]]; then
		qa_die "Location '${location}' does not look disposable (use *-test, *-qa, *-clone) - pass --force-location to override"
		return 1
	fi
	return 0
}

# --- scratch + state --------------------------------------------------------

qa_init_scratch() {
	local base="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
	local safe="${QA_SERVER//[^A-Za-z0-9]/_}"
	QA_SCRATCH="${base}/cloudron-app-qa-${safe}"
	mkdir -p "$QA_SCRATCH"
	chmod 700 "$QA_SCRATCH"
	touch "${QA_SCRATCH}/state"
	return 0
}

qa_state_add() {
	local kind="$1"
	local value="$2"
	if ! grep -qxF "${kind} ${value}" "${QA_SCRATCH}/state" 2>/dev/null; then
		printf '%s %s\n' "$kind" "$value" >>"${QA_SCRATCH}/state"
	fi
	return 0
}

qa_state_remove() {
	local kind="$1"
	local value="$2"
	local tmp="${QA_SCRATCH}/state.tmp"
	grep -vxF "${kind} ${value}" "${QA_SCRATCH}/state" >"$tmp" || true
	mv "$tmp" "${QA_SCRATCH}/state"
	return 0
}

# --- Cloudron CLI + API -----------------------------------------------------

cl() {
	cloudron --server "$QA_SERVER" "$@"
	return $?
}

# Read the CLI token for this server. The value is only ever piped, never printed.
qa_token() {
	jq -r --arg s "$QA_SERVER" \
		'(.cloudrons[$s].token // .[$s].token // empty)' "$QA_CLOUDRON_CONFIG" 2>/dev/null
	return 0
}

# api METHOD PATH [JSON_BODY] - token travels via curl config on stdin, not argv.
api() {
	local method="$1"
	local path="$2"
	local body="${3:-}"
	local token
	token="$(qa_token)"
	if [[ -z "$token" ]]; then
		qa_die "No CLI token for ${QA_SERVER} in ${QA_CLOUDRON_CONFIG} - run: cloudron login ${QA_SERVER}"
		return 1
	fi
	local args=(-sS --max-time 60 -X "$method" -K - -H 'Content-Type: application/json')
	if [[ "${QA_API_STATUS:-0}" -eq 1 ]]; then
		args+=(-w $'\n%{http_code}')
	fi
	if [[ -n "$body" ]]; then
		args+=(--data "$body")
	fi
	printf 'header = "Authorization: Bearer %s"\n' "$token" |
		curl "${args[@]}" "https://${QA_SERVER}${path}"
	return $?
}

# api_code METHOD PATH [BODY] - print only the HTTP status; non-zero when curl failed.
qa_api_code() {
	local out rc=0
	out="$(QA_API_STATUS=1 api "$@" 2>/dev/null)" || rc=$?
	out="${out##*$'\n'}"
	if ! [[ "$out" =~ ^[0-9]{3}$ ]]; then
		out="000"
		[[ "$rc" -ne 0 ]] || rc=1
	fi
	printf '%s\n' "$out"
	return "$rc"
}

# Resolve one app by its subdomain (API field "location" on older Cloudron, "subdomain"
# on newer). Apps sharing a subdomain across domains are ambiguous: emit nothing then.
qa_app_json() {
	local location="$1"
	api GET /api/v1/apps | jq -c --arg l "$location" \
		'[.apps[]? | select((.location // .subdomain) == $l)] | if length == 1 then .[0] else empty end' 2>/dev/null
	return 0
}

# Exit 0 = exists, 1 = absent, 2 = lookup failed.
qa_app_exists() {
	local location="$1"
	local listing
	listing="$(api GET /api/v1/apps 2>/dev/null)" || return 2
	if ! printf '%s' "$listing" | jq -e '.apps | type == "array"' >/dev/null 2>&1; then
		return 2
	fi
	if printf '%s' "$listing" | jq -e --arg l "$location" \
		'any(.apps[]; (.location // .subdomain) == $l)' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

qa_cloudron_ready() {
	qa_require_server || return 1
	qa_require_tools cloudron jq curl || return 1
	qa_init_scratch
	return 0
}

# --- cleanup ----------------------------------------------------------------

qa_uninstall_app() {
	local location="$1"
	if cl uninstall --app "$location" >/dev/null 2>&1; then
		qa_info "uninstalled ${location}"
		return 0
	fi
	local exists=0
	qa_app_exists "$location" || exists=$?
	if [[ "$exists" -eq 1 ]]; then
		qa_info "no app at ${location} (already removed)"
		return 0
	fi
	qa_fail "uninstall ${location} failed (state retained for retry)"
	return 1
}

# Returns 1 when any entry could not be cleaned; failed entries stay in the state file.
qa_cleanup_state() {
	local kind value rc=0
	[[ -f "${QA_SCRATCH}/state" ]] || return 0
	while read -r kind value; do
		case "$kind" in
		app)
			if qa_uninstall_app "$value"; then
				qa_state_remove app "$value"
			else
				rc=1
			fi
			;;
		mailbox) qa_mailbox_delete "$value" || rc=1 ;;
		esac
	done <"${QA_SCRATCH}/state"
	return "$rc"
}

qa_cleanup() {
	if [[ "$QA_CLEANUP_ARMED" -eq 0 ]]; then
		return 0
	fi
	QA_CLEANUP_ARMED=0
	if ! qa_cleanup_state; then
		qa_info "cleanup incomplete - state kept in ${QA_SCRATCH}; re-run: cleanup --server ${QA_SERVER}"
		return 1
	fi
	if [[ -n "$QA_SCRATCH" && -d "$QA_SCRATCH" ]]; then
		rm -rf "$QA_SCRATCH"
	fi
	qa_info "cleanup complete (apps, clone, mailbox, profiles, scratch)"
	return 0
}

cmd_cleanup() {
	qa_parse_args "$@" || return 1
	qa_cloudron_ready || return 1
	local location
	for location in ${QA_POSITIONAL[@]+"${QA_POSITIONAL[@]}"}; do
		qa_check_location "$location" || return 1
		qa_state_add app "$location"
		qa_state_add app "${location}-clone"
	done
	QA_CLEANUP_ARMED=1
	if qa_cleanup; then
		qa_pass "cleanup finished"
	else
		qa_fail "cleanup incomplete"
	fi
	return 0
}

# --- install + health -------------------------------------------------------

cmd_install() {
	qa_parse_args "$@" || return 1
	qa_cloudron_ready || return 1
	local location="${QA_POSITIONAL[0]:-}"
	[[ -n "$location" ]] || { qa_die "install requires <location>"; return 1; }
	qa_check_location "$location" || return 1
	local sources=0
	[[ -n "$QA_OPT_VERSIONS_URL" ]] && sources=$((sources + 1))
	[[ -n "$QA_OPT_IMAGE" ]] && sources=$((sources + 1))
	[[ "$QA_OPT_BUILD" -eq 1 ]] && sources=$((sources + 1))
	if [[ "$sources" -ne 1 ]]; then
		qa_die "install needs exactly one of --versions-url URL | --image REF | --build"
		return 1
	fi
	# Never adopt (and later uninstall) an app this invocation did not create.
	local exists=0
	qa_app_exists "$location" || exists=$?
	if [[ "$exists" -eq 0 ]]; then
		qa_die "App ${location} already exists on ${QA_SERVER} - refusing to install over it"
		return 1
	elif [[ "$exists" -ne 1 ]]; then
		qa_die "Could not list apps on ${QA_SERVER} to check ${location}"
		return 1
	fi
	local rc=0
	if [[ "$QA_OPT_BUILD" -eq 1 ]]; then
		cl build >/dev/null || rc=$?
	fi
	if [[ "$rc" -eq 0 ]]; then
		# Track before install so a partial install is still cleaned up.
		qa_state_add app "$location"
		if [[ -n "$QA_OPT_VERSIONS_URL" ]]; then
			cl install --location "$location" --versions-url "$QA_OPT_VERSIONS_URL" >/dev/null || rc=$?
		elif [[ -n "$QA_OPT_IMAGE" ]]; then
			cl install --location "$location" --image "$QA_OPT_IMAGE" >/dev/null || rc=$?
		else
			cl install --location "$location" >/dev/null || rc=$?
		fi
	fi
	if [[ "$rc" -eq 0 ]]; then
		qa_pass "install ${location}"
	else
		qa_fail "install ${location} (cloudron exit ${rc})"
	fi
	return "$rc"
}

# Resolve the health path: explicit --path, else manifest healthCheckPath, else /health.
qa_health_path() {
	local location="$1"
	if [[ -n "$QA_OPT_PATH" ]]; then
		printf '%s\n' "$QA_OPT_PATH"
		return 0
	fi
	local path
	path="$(qa_app_json "$location" | jq -r '.manifest.healthCheckPath // empty' 2>/dev/null || true)"
	printf '%s\n' "${path:-/health}"
	return 0
}

qa_health_url() {
	local location="$1"
	local fqdn
	fqdn="$(qa_app_json "$location" | jq -r '.fqdn // empty' 2>/dev/null || true)"
	if [[ -z "$fqdn" ]]; then
		qa_die "App ${location} not found on ${QA_SERVER}"
		return 1
	fi
	printf 'https://%s\n' "$fqdn"
	return 0
}

qa_health_check() {
	local location="$1"
	local label="${2:-health}"
	local url path code="" http_version="" attempt
	url="$(qa_health_url "$location")" || { qa_fail "${label}: app lookup"; return 1; }
	path="$(qa_health_path "$location")"
	for ((attempt = 1; attempt <= QA_HEALTH_ATTEMPTS; attempt++)); do
		# No -k: a TLS failure must fail the check. 502 while starting is normal.
		local out
		out="$(curl -sS -o /dev/null --http2 --max-time 15 -w '%{http_code} %{http_version}' "${url}${path}" 2>/dev/null || true)"
		code="${out%% *}"
		http_version="${out#* }"
		if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
			break
		fi
		sleep "$QA_HEALTH_DELAY"
	done
	if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
		qa_pass "${label}: ${path} returned ${code} over valid TLS (HTTP ${http_version})"
		if [[ "$http_version" != "2" ]]; then
			qa_fail "${label}: HTTP/2 not negotiated (got ${http_version})"
		fi
		return 0
	fi
	qa_fail "${label}: ${path} not healthy after $((QA_HEALTH_ATTEMPTS * QA_HEALTH_DELAY))s (last status ${code:-none})"
	return 1
}

cmd_health() {
	qa_parse_args "$@" || return 1
	qa_cloudron_ready || return 1
	local location="${QA_POSITIONAL[0]:-}"
	[[ -n "$location" ]] || { qa_die "health requires <location>"; return 1; }
	qa_check_location "$location" || return 1
	qa_health_check "$location" health || true
	return 0
}

# --- mailbox ----------------------------------------------------------------

qa_mailbox_create() {
	local address="$1"
	local name="${address%@*}"
	local domain="${address#*@}"
	local owner
	owner="$(api GET /api/v1/profile | jq -r '.id // empty')"
	if [[ -z "$owner" ]]; then
		qa_fail "mailbox create ${address}: could not resolve owner id"
		return 1
	fi
	local body
	body="$(jq -cn --arg n "$name" --arg o "$owner" \
		'{name:$n, ownerId:$o, ownerType:"user", active:true, storageQuota:0, messagesQuota:0, enablePop3:false}')"
	local code rc=0
	code="$(qa_api_code POST "/api/v1/mail/${domain}/mailboxes" "$body")" || rc=$?
	if [[ "$rc" -eq 0 && "$code" =~ ^2[0-9][0-9]$ ]]; then
		qa_state_add mailbox "$address"
		qa_pass "mailbox create ${address}"
		return 0
	fi
	qa_fail "mailbox create ${address}: HTTP ${code} (curl exit ${rc})"
	return 1
}

qa_mailbox_delete() {
	local address="$1"
	local name="${address%@*}"
	local domain="${address#*@}"
	local code rc=0
	code="$(qa_api_code DELETE "/api/v1/mail/${domain}/mailboxes/${name}" '{"deleteMails":true}')" || rc=$?
	# 404 means it is already gone; anything else non-2xx keeps the state entry for retry.
	if [[ "$rc" -eq 0 && ( "$code" =~ ^2[0-9][0-9]$ || "$code" == "404" ) ]]; then
		qa_state_remove mailbox "$address"
		qa_pass "mailbox delete ${address}"
		return 0
	fi
	qa_fail "mailbox delete ${address}: HTTP ${code} (curl exit ${rc}); state retained"
	return 1
}

# Print only Date/To/Subject and link host+path (query strings stripped).
qa_mailbox_list() {
	local address="$1"
	local host="${QA_OPT_SSH_HOST:-$QA_SERVER}"
	qa_require_tools ssh || return 1
	qa_valid_host "$host" || { qa_die "Invalid --ssh-host"; return 1; }
	local dir="${QA_OPT_BOXDATA}/mail/vmail/${address}/mail"
	if [[ ! "$dir" =~ ^/[A-Za-z0-9._@/+-]+$ ]]; then
		qa_die "Invalid --boxdata value"
		return 1
	fi
	# Remote side emits only whitelisted header lines and URLs; bodies are never read here.
	local out
	if ! out="$(ssh -o BatchMode=yes "root@${host}" \
		"for f in ${dir}/new/* ${dir}/cur/*; do [ -f \"\$f\" ] || continue; echo '--'; grep -m3 -iE '^(Date|To|Subject):' \"\$f\"; grep -oE 'https?://[^ \"<>]+' \"\$f\" | sed -n '1,5p' | sed 's/^/LINK: /'; done" 2>/dev/null)"; then
		qa_fail "mailbox list ${address}: ssh to ${host} failed"
		return 1
	fi
	if [[ -z "$out" ]]; then
		qa_info "mailbox list ${address}: no messages"
	else
		printf '%s\n' "$out" | qa_redact
		qa_pass "mailbox list ${address}"
	fi
	return 0
}

cmd_mailbox() {
	qa_parse_args "$@" || return 1
	qa_cloudron_ready || return 1
	local action="${QA_POSITIONAL[0]:-}"
	local address="${QA_POSITIONAL[1]:-}"
	if [[ -z "$action" ]] || ! qa_valid_address "$address"; then
		qa_die "usage: mailbox create|delete|list <local-part@domain> --server S"
		return 1
	fi
	case "$action" in
	create) qa_mailbox_create "$address" || true ;;
	delete) qa_mailbox_delete "$address" || true ;;
	list) qa_mailbox_list "$address" || true ;;
	*)
		qa_die "Unknown mailbox action: ${action}"
		return 1
		;;
	esac
	return 0
}

# --- upload probe -----------------------------------------------------------

# Convert 20M / 512K / 1G / bytes into bytes.
qa_size_bytes() {
	local size="$1"
	local number="${size%[KkMmGg]}"
	local unit="${size#"$number"}"
	if ! [[ "$number" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	case "$unit" in
	K | k) printf '%s\n' $((number * 1024)) ;;
	M | m) printf '%s\n' $((number * 1024 * 1024)) ;;
	G | g) printf '%s\n' $((number * 1024 * 1024 * 1024)) ;;
	"") printf '%s\n' "$number" ;;
	*) return 1 ;;
	esac
	return 0
}

qa_upload_one() {
	local size="$1"
	local limit_bytes="$2"
	local bytes file code
	bytes="$(qa_size_bytes "$size")" || { qa_fail "upload ${size}: invalid size"; return 0; }
	file="${QA_SCRATCH}/upload-${size}.bin"
	head -c "$bytes" /dev/zero >"$file"
	local cargs=(-sS -o /dev/null --max-time 300 -w '%{http_code}' -F "${QA_OPT_FIELD}=@${file}")
	if [[ -n "$QA_OPT_BEARER_ENV" ]]; then
		code="$(printf 'header = "Authorization: Bearer %s"\n' "${!QA_OPT_BEARER_ENV:-}" |
			curl "${cargs[@]}" -K - "$QA_OPT_URL" 2>/dev/null || true)"
	else
		code="$(curl "${cargs[@]}" "$QA_OPT_URL" 2>/dev/null || true)"
	fi
	rm -f "$file"
	if [[ -n "$limit_bytes" && "$bytes" -gt "$limit_bytes" ]]; then
		if [[ "$code" == "413" ]]; then
			qa_pass "upload ${size} over limit rejected with 413"
		elif [[ "$code" == "502" && "$QA_OPT_ALLOW_502" -eq 1 ]]; then
			qa_pass "upload ${size} over limit gave 502 (expected with streamed uploads: nginx early-reply, see cloudron-app-packaging.md)"
		else
			qa_fail "upload ${size} over limit expected 413 (got ${code:-none})"
		fi
	elif [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
		qa_pass "upload ${size} not rejected by proxy or app limit (HTTP ${code})"
	else
		qa_fail "upload ${size} failed (HTTP ${code:-none})"
	fi
	return 0
}

cmd_upload_probe() {
	qa_parse_args "$@" || return 1
	qa_require_tools curl || return 1
	[[ "$QA_OPT_URL" =~ ^https:// ]] || { qa_die "upload-probe requires --url https://..."; return 1; }
	[[ "$QA_OPT_FIELD" =~ ^[A-Za-z0-9_-]+$ ]] || { qa_die "Invalid --field"; return 1; }
	if [[ -z "$QA_SERVER" ]]; then QA_SERVER="upload-probe"; fi
	qa_init_scratch
	local limit_bytes=""
	if [[ -n "$QA_OPT_LIMIT" ]]; then
		limit_bytes="$(qa_size_bytes "$QA_OPT_LIMIT")" || { qa_die "Invalid --limit"; return 1; }
	fi
	local size old_ifs="$IFS"
	IFS=','
	local sizes=()
	read -r -a sizes <<<"$QA_OPT_SIZES"
	IFS="$old_ifs"
	for size in "${sizes[@]}"; do
		qa_upload_one "$size" "$limit_bytes"
	done
	return 0
}

# --- lifecycle: restart, backup/clone, update, memory -----------------------

cmd_restart_persist() {
	qa_parse_args "$@" || return 1
	qa_cloudron_ready || return 1
	local location="${QA_POSITIONAL[0]:-}"
	[[ -n "$location" ]] || { qa_die "restart-persist requires <location>"; return 1; }
	qa_check_location "$location" || return 1
	local marker
	marker="qa-$(date +%s)"
	if ! cl exec --app "$location" -- sh -c "printf %s '${marker}' > /app/data/.qa-marker" >/dev/null 2>&1; then
		qa_fail "restart-persist: could not write marker to /app/data"
		return 0
	fi
	cl restart --app "$location" >/dev/null 2>&1 || { qa_fail "restart ${location}"; return 0; }
	qa_health_check "$location" "after restart" || true
	local seen
	seen="$(cl exec --app "$location" -- cat /app/data/.qa-marker 2>/dev/null || true)"
	if [[ "$seen" == "$marker" ]]; then
		qa_pass "data persisted across restart"
	else
		qa_fail "data marker missing after restart"
	fi
	return 0
}

cmd_backup_clone() {
	qa_parse_args "$@" || return 1
	qa_cloudron_ready || return 1
	local location="${QA_POSITIONAL[0]:-}"
	[[ -n "$location" ]] || { qa_die "backup-clone requires <location>"; return 1; }
	qa_check_location "$location" || return 1
	local clone="${location}-clone"
	if ! cl backup create --app "$location" >/dev/null 2>&1; then
		qa_fail "backup create ${location}"
		return 0
	fi
	qa_pass "backup create ${location}"
	local backup_id
	backup_id="$(cl backup list --app "$location" --raw 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || true)"
	if [[ -z "$backup_id" ]]; then
		qa_fail "backup list: no backup id found"
		return 0
	fi
	# Only track a clone this invocation creates; never adopt a pre-existing app.
	local exists=0
	qa_app_exists "$clone" || exists=$?
	if [[ "$exists" -ne 1 ]]; then
		qa_fail "clone ${clone}: target already exists or app lookup failed - not cloning"
		return 0
	fi
	if cl clone --app "$location" --backup "$backup_id" --location "$clone" >/dev/null 2>&1; then
		qa_state_add app "$clone"
		qa_pass "clone ${location} -> ${clone}"
		qa_health_check "$clone" "clone health" || true
	else
		qa_fail "clone ${location} -> ${clone}"
		# A failed clone can leave a partial app behind; track it for cleanup.
		exists=0
		qa_app_exists "$clone" || exists=$?
		if [[ "$exists" -eq 0 ]]; then
			qa_state_add app "$clone"
		fi
	fi
	return 0
}

cmd_update() {
	qa_parse_args "$@" || return 1
	qa_cloudron_ready || return 1
	local location="${QA_POSITIONAL[0]:-}"
	[[ -n "$location" ]] || { qa_die "update requires <location>"; return 1; }
	qa_check_location "$location" || return 1
	local rc=0
	if [[ -n "$QA_OPT_IMAGE" ]]; then
		cl update --app "$location" --image "$QA_OPT_IMAGE" >/dev/null 2>&1 || rc=$?
	elif [[ -n "$QA_OPT_VERSIONS_URL" ]]; then
		cl update --app "$location" --versions-url "$QA_OPT_VERSIONS_URL" >/dev/null 2>&1 || rc=$?
	else
		cl update --app "$location" >/dev/null 2>&1 || rc=$?
	fi
	if [[ "$rc" -eq 0 ]]; then
		qa_pass "update ${location}"
		qa_health_check "$location" "after update" || true
	else
		qa_fail "update ${location} (cloudron exit ${rc})"
	fi
	return 0
}

cmd_memory() {
	qa_parse_args "$@" || return 1
	qa_cloudron_ready || return 1
	local location="${QA_POSITIONAL[0]:-}"
	[[ -n "$location" ]] || { qa_die "memory requires <location>"; return 1; }
	qa_check_location "$location" || return 1
	local limit used
	limit="$(qa_app_json "$location" | jq -r '(.memoryLimit // .manifest.memoryLimit // empty)' 2>/dev/null || true)"
	used="$(cl exec --app "$location" -- sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null' 2>/dev/null | tr -d '[:space:]' || true)"
	if ! [[ "$used" =~ ^[0-9]+$ ]] || ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -eq 0 ]]; then
		qa_fail "memory: could not read usage (${used:-none}) or limit (${limit:-none})"
		return 0
	fi
	local pct=$((used * 100 / limit))
	if [[ "$pct" -lt 90 ]]; then
		qa_pass "memory ${used} of ${limit} bytes (${pct}%)"
	else
		qa_fail "memory ${used} of ${limit} bytes (${pct}%) is within 10% of the manifest limit"
	fi
	return 0
}

# --- node-backed probes -----------------------------------------------------

qa_run_node() {
	local module="$1"
	shift
	qa_require_tools node || return 1
	local rc=0
	node "${QA_MJS_DIR}/${module}" "$@" || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		QA_FAILURES=$((QA_FAILURES + 1))
	fi
	return 0
}

# Remove browser profiles (session cookies/tokens) after standalone probes.
qa_remove_scratch() {
	if [[ -n "$QA_SCRATCH" && -d "$QA_SCRATCH" ]]; then
		rm -rf "$QA_SCRATCH"
	fi
	return 0
}

cmd_oauth_probe() {
	qa_parse_args "$@" || return 1
	[[ "$QA_OPT_URL" =~ ^https:// ]] || { qa_die "oauth-probe requires --url https://<app>"; return 1; }
	if [[ -z "$QA_SERVER" ]]; then QA_SERVER="oauth-probe"; fi
	qa_init_scratch
	local nargs=(--base-url "$QA_OPT_URL" --resource-path "$QA_OPT_RESOURCE_PATH" --scratch "$QA_SCRATCH")
	[[ -n "$QA_OPT_ADAPTER" ]] && nargs+=(--adapter "$QA_OPT_ADAPTER")
	[[ -n "$QA_OPT_RESOLVE" ]] && nargs+=(--resolve "$QA_OPT_RESOLVE")
	qa_run_node oauth-probe.mjs "${nargs[@]}"
	qa_remove_scratch
	return 0
}

cmd_realtime() {
	qa_parse_args "$@" || return 1
	[[ "$QA_OPT_URL" =~ ^https:// ]] || { qa_die "realtime requires --url https://<app>"; return 1; }
	[[ -n "$QA_OPT_ADAPTER" ]] || { qa_die "realtime requires --adapter (see help)"; return 1; }
	if [[ -z "$QA_SERVER" ]]; then QA_SERVER="realtime"; fi
	qa_init_scratch
	local nargs=(--base-url "$QA_OPT_URL" --adapter "$QA_OPT_ADAPTER" --scratch "$QA_SCRATCH" --idle "$QA_OPT_IDLE")
	[[ -n "$QA_OPT_RESOLVE" ]] && nargs+=(--resolve "$QA_OPT_RESOLVE")
	qa_run_node realtime-probe.mjs "${nargs[@]}"
	qa_remove_scratch
	return 0
}

# --- composite run ----------------------------------------------------------

cmd_run() {
	qa_parse_args "$@" || return 1
	qa_cloudron_ready || return 1
	local location="${QA_POSITIONAL[0]:-}"
	[[ -n "$location" ]] || { qa_die "run requires <location> and an install source"; return 1; }
	QA_CLEANUP_ARMED=1
	trap qa_cleanup EXIT
	local install_args=("$location")
	[[ -n "$QA_OPT_VERSIONS_URL" ]] && install_args+=(--versions-url "$QA_OPT_VERSIONS_URL")
	[[ -n "$QA_OPT_IMAGE" ]] && install_args+=(--image "$QA_OPT_IMAGE")
	[[ "$QA_OPT_BUILD" -eq 1 ]] && install_args+=(--build)
	[[ "$QA_OPT_FORCE_LOCATION" -eq 1 ]] && install_args+=(--force-location)
	local common=(--server "$QA_SERVER")
	if cmd_install "${install_args[@]}" "${common[@]}"; then
		cmd_health "$location" "${common[@]}" || true
		cmd_restart_persist "$location" "${common[@]}" || true
		cmd_backup_clone "$location" "${common[@]}" || true
		cmd_memory "$location" "${common[@]}" || true
	fi
	# Explicit cleanup so failures count toward the exit status; the trap covers signals/aborts.
	qa_cleanup || true
	return 0
}

show_help() {
	cat <<'EOF'
cloudron-app-qa-helper.sh - qualify a Cloudron package on a live test install

Every command needs --server <cloudron-host>; the CLI default server is never
used. Locations must look disposable (*-test, *-qa, *-clone) unless
--force-location. Output is PASS:/FAIL: lines; exit is non-zero on any FAIL.

Commands:
  install <location> (--versions-url URL | --image REF | --build) --server S
  health <location> [--path /health] --server S
  mailbox create|delete|list <local-part@domain> --server S [--ssh-host H] [--boxdata DIR]
  upload-probe --url U --field F --sizes 20M,30M [--limit 25M] [--allow-502]
               [--bearer-env VAR]
  oauth-probe --url https://app [--resource-path /mcp] [--adapter A.mjs] [--resolve host=ip]
  realtime --url https://app --adapter A.mjs [--idle 330] [--resolve host=ip]
  restart-persist <location> --server S
  backup-clone <location> --server S        (clone is <location>-clone)
  update <location> [--image REF | --versions-url URL] --server S
  memory <location> --server S
  run <location> (install source) --server S   install, health, restart, backup-clone,
                                               memory, then cleanup via EXIT trap
  cleanup [<location>...] --server S        uninstall test apps and clones, delete QA
                                            mailboxes, profiles and scratch directory
  help

Adapter (--adapter path/to/adapter.mjs, ES module) for app-specific steps:
  export async function login(page, role)        // role: 'a' | 'b' | 'admin'
  export async function realtime(pageA, pageB)   // A sends, resolve when B sees it
  export async function coedit(pageA, pageB)     // optional
  export async function consent(page)            // optional OAuth consent click

Safety: tokens, setup links, mail bodies and query strings are never printed.
Scratch and browser profiles (mode 0700) live under
${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}. Needs cloudron, jq,
curl; node + the aidevops Playwright runtime for oauth-probe and realtime; ssh
for mailbox list. Docs: tools/deployment/cloudron-app-packaging.md
("Qualifying a package on a live install").
EOF
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	install) cmd_install "$@" ;;
	health) cmd_health "$@" ;;
	mailbox) cmd_mailbox "$@" ;;
	upload-probe) cmd_upload_probe "$@" ;;
	oauth-probe) cmd_oauth_probe "$@" ;;
	realtime) cmd_realtime "$@" ;;
	restart-persist) cmd_restart_persist "$@" ;;
	backup-clone) cmd_backup_clone "$@" ;;
	update) cmd_update "$@" ;;
	memory) cmd_memory "$@" ;;
	run) cmd_run "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	help | --help | -h)
		show_help
		return 0
		;;
	*)
		qa_die "Unknown command: ${command}"
		show_help
		return 1
		;;
	esac
	local rc=$?
	if [[ "$rc" -ne 0 ]]; then
		return "$rc"
	fi
	if [[ "$QA_FAILURES" -gt 0 ]]; then
		printf 'FAIL: %s check(s) failed\n' "$QA_FAILURES"
		return 1
	fi
	return 0
}

main "$@"
