#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# github-app-auth-helper.sh -- User-owned GitHub App auth + API routing
# =============================================================================
# Provides a sourceable library and CLI for GitHub App installation tokens,
# per-principal rate-limit cache, and semantic route decisions. Secret values are
# never printed by status/route commands; installation tokens are only written to
# stdout by the sourceable github_app_token* functions or when the explicit
# AIDEVOPS_GITHUB_APP_ALLOW_TOKEN_STDOUT=1 escape hatch is set for automation.
# =============================================================================

if [[ -n "${_GITHUB_APP_AUTH_HELPER_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_GITHUB_APP_AUTH_HELPER_LOADED=1

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

if ! command -v print_info >/dev/null 2>&1; then
	print_info() { printf '[INFO] %s\n' "$*" >&2; return 0; }
fi
if ! command -v print_warning >/dev/null 2>&1; then
	print_warning() { printf '[WARN] %s\n' "$*" >&2; return 0; }
fi
if ! command -v print_error >/dev/null 2>&1; then
	print_error() { printf '[ERROR] %s\n' "$*" >&2; return 0; }
fi

: "${AIDEVOPS_GITHUB_APP_CONFIG:=${HOME:-/tmp}/.config/aidevops/github-app-auth.json}"
: "${AIDEVOPS_GITHUB_APP_CACHE_DIR:=${HOME:-/tmp}/.aidevops/cache/github-app}"
: "${AIDEVOPS_GITHUB_APP_RATE_LIMIT_CACHE_TTL:=20}"
: "${AIDEVOPS_GITHUB_APP_REST_FIRST:=1}"

_github_app_bool_true() {
	local value="${1:-}"
	value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
	case "$value" in
	1 | true | yes | on | enabled) return 0 ;;
	*) return 1 ;;
	esac
}

_github_app_bool_false() {
	local value="${1:-}"
	value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
	case "$value" in
	0 | false | no | off | disabled) return 0 ;;
	*) return 1 ;;
	esac
}

_github_app_config_value() {
	local key="$1"
	local env_primary="${2:-}"
	local env_secondary="${3:-}"
	local value=""
	if [[ -n "$env_primary" && -n "${!env_primary:-}" ]]; then
		printf '%s\n' "${!env_primary}"
		return 0
	fi
	if [[ -n "$env_secondary" && -n "${!env_secondary:-}" ]]; then
		printf '%s\n' "${!env_secondary}"
		return 0
	fi
	if [[ -f "$AIDEVOPS_GITHUB_APP_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
		value=$(jq -r --arg key "$key" '.[$key] // empty' "$AIDEVOPS_GITHUB_APP_CONFIG" 2>/dev/null || true)
		[[ -n "$value" && "$value" != "null" ]] && printf '%s\n' "$value"
	fi
	return 0
}

github_app_app_id() {
	_github_app_config_value "app_id" "AIDEVOPS_GITHUB_APP_ID" "GITHUB_APP_ID"
	return 0
}

github_app_installation_id() {
	_github_app_config_value "installation_id" "AIDEVOPS_GITHUB_APP_INSTALLATION_ID" "GITHUB_APP_INSTALLATION_ID"
	return 0
}

github_app_private_key_path() {
	local value=""
	value=$(_github_app_config_value "private_key_path" "AIDEVOPS_GITHUB_APP_PRIVATE_KEY_PATH" "GITHUB_APP_PRIVATE_KEY_PATH")
	if [[ -z "$value" ]]; then
		local secret_name=""
		secret_name=$(_github_app_config_value "private_key_path_secret" "AIDEVOPS_GITHUB_APP_PRIVATE_KEY_PATH_SECRET" "GITHUB_APP_PRIVATE_KEY_PATH_SECRET")
		if [[ -n "$secret_name" ]] && command -v gopass >/dev/null 2>&1; then
			value=$(gopass show -o "aidevops/${secret_name}" 2>/dev/null || true)
		fi
	fi
	[[ -n "$value" ]] && printf '%s\n' "$value"
	return 0
}

github_app_enabled() {
	local enabled=""
	enabled=$(_github_app_config_value "enabled" "AIDEVOPS_GITHUB_APP_ENABLED" "GITHUB_APP_ENABLED")
	if [[ -n "$enabled" ]]; then
		_github_app_bool_false "$enabled" && return 1
		_github_app_bool_true "$enabled" && return 0
	fi
	[[ -n "$(github_app_app_id)" ]] && return 0
	return 1
}

_github_app_cache_dir() {
	mkdir -p "$AIDEVOPS_GITHUB_APP_CACHE_DIR" 2>/dev/null || true
	chmod 700 "$AIDEVOPS_GITHUB_APP_CACHE_DIR" 2>/dev/null || true
	printf '%s\n' "$AIDEVOPS_GITHUB_APP_CACHE_DIR"
	return 0
}

_github_app_cache_slug() {
	local raw="${1:-default}"
	printf '%s\n' "$raw" | tr -c 'A-Za-z0-9_.-' '_'
	return 0
}

_github_app_token_cache_path() {
	local installation_id="${1:-}"
	local cache_dir slug
	cache_dir=$(_github_app_cache_dir)
	slug=$(_github_app_cache_slug "${installation_id:-default}")
	printf '%s/token-%s.json\n' "$cache_dir" "$slug"
	return 0
}

_github_app_rate_cache_path() {
	local auth_mode="${1:-gh-pat}"
	local principal="${2:-default}"
	local cache_dir mode_slug principal_slug
	cache_dir=$(_github_app_cache_dir)
	mode_slug=$(_github_app_cache_slug "$auth_mode")
	principal_slug=$(_github_app_cache_slug "$principal")
	printf '%s/rate-limit-%s-%s.json\n' "$cache_dir" "$mode_slug" "$principal_slug"
	return 0
}

_github_app_cached_token() {
	local installation_id="$1"
	local cache_file token expiry now
	cache_file=$(_github_app_token_cache_path "$installation_id")
	[[ -f "$cache_file" ]] || return 1
	token=$(jq -r '.token // empty' "$cache_file" 2>/dev/null || true)
	expiry=$(jq -r '.expires_at_epoch // 0' "$cache_file" 2>/dev/null || printf '0')
	now=$(date +%s)
	[[ -n "$token" && "$expiry" =~ ^[0-9]+$ && $((now + 60)) -lt "$expiry" ]] || return 1
	printf '%s\n' "$token"
	return 0
}

_github_app_iso_to_epoch() {
	local iso="${1:-}"
	[[ -z "$iso" ]] && return 1
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$iso" <<'PY' 2>/dev/null || return 1
import datetime
import sys

value = sys.argv[1].replace('Z', '+00:00')
print(int(datetime.datetime.fromisoformat(value).timestamp()))
PY
		return 0
	fi
	return 1
}

_github_app_cache_token() {
	local installation_id="$1"
	local token="$2"
	local expires_at="${3:-}"
	local cache_file now expiry tmp
	cache_file=$(_github_app_token_cache_path "$installation_id")
	now=$(date +%s)
	expiry=$(_github_app_iso_to_epoch "$expires_at" 2>/dev/null || true)
	[[ "$expiry" =~ ^[0-9]+$ ]] || expiry=$((now + 3300))
	tmp="${cache_file}.$$"
	jq -n --arg token "$token" --arg expires_at "$expires_at" --argjson expires_at_epoch "$expiry" \
		'{token:$token, expires_at:$expires_at, expires_at_epoch:$expires_at_epoch}' >"$tmp" || return 1
	chmod 600 "$tmp" 2>/dev/null || true
	mv "$tmp" "$cache_file"
	return 0
}

_github_app_base64url() {
	base64 | tr '+/' '-_' | tr -d '=\n'
	return 0
}

github_app_create_jwt() {
	local app_id key_path now iat exp header payload signing_input signature
	app_id=$(github_app_app_id)
	key_path=$(github_app_private_key_path)
	if [[ -z "$app_id" || -z "$key_path" || ! -r "$key_path" ]]; then
		return 1
	fi
	if ! command -v openssl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
		return 1
	fi
	now=$(date +%s)
	iat=$((now - 60))
	exp=$((now + 540))
	header=$(printf '{"alg":"RS256","typ":"JWT"}' | _github_app_base64url)
	payload=$(jq -nc --argjson iat "$iat" --argjson exp "$exp" --arg iss "$app_id" '{iat:$iat,exp:$exp,iss:$iss}' | _github_app_base64url)
	signing_input="${header}.${payload}"
	signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$key_path" -binary 2>/dev/null | _github_app_base64url) || return 1
	[[ -n "$signature" ]] || return 1
	printf '%s.%s\n' "$signing_input" "$signature"
	return 0
}

github_app_has_private_key_source() {
	local key_path=""
	key_path=$(github_app_private_key_path)
	[[ -n "$key_path" && -r "$key_path" ]] && return 0
	return 1
}

github_app_is_configured() {
	github_app_enabled || return 1
	[[ -n "$(github_app_app_id)" ]] || return 1
	if github_app_has_private_key_source; then
		return 0
	fi
	local installation_id=""
	installation_id=$(github_app_installation_id)
	[[ -n "$installation_id" ]] && _github_app_cached_token "$installation_id" >/dev/null 2>&1 && return 0
	return 1
}

github_app_installation_id_for_repo() {
	local repo="${1:-}"
	local installation_id jwt
	installation_id=$(github_app_installation_id)
	if [[ -n "$installation_id" ]]; then
		printf '%s\n' "$installation_id"
		return 0
	fi
	[[ -n "$repo" ]] || return 1
	jwt=$(github_app_create_jwt) || return 1
	installation_id=$(gh api "/repos/${repo}/installation" \
		-H "Authorization: Bearer ${jwt}" \
		-H "Accept: application/vnd.github+json" \
		--jq '.id // empty' 2>/dev/null || true)
	[[ -n "$installation_id" ]] || return 1
	printf '%s\n' "$installation_id"
	return 0
}

github_app_exchange_token() {
	local repo="${1:-}"
	local installation_id jwt response token expires_at
	installation_id=$(github_app_installation_id_for_repo "$repo") || return 1
	jwt=$(github_app_create_jwt) || return 1
	response=$(gh api -X POST "/app/installations/${installation_id}/access_tokens" \
		-H "Authorization: Bearer ${jwt}" \
		-H "Accept: application/vnd.github+json" 2>/dev/null) || return 1
	token=$(printf '%s\n' "$response" | jq -r '.token // empty' 2>/dev/null || true)
	expires_at=$(printf '%s\n' "$response" | jq -r '.expires_at // empty' 2>/dev/null || true)
	[[ -n "$token" ]] || return 1
	_github_app_cache_token "$installation_id" "$token" "$expires_at" || true
	printf '%s\n' "$token"
	return 0
}

github_app_token_for_repo() {
	local repo="${1:-}"
	local installation_id token
	github_app_enabled || return 1
	installation_id=$(github_app_installation_id_for_repo "$repo" 2>/dev/null || true)
	if [[ -n "$installation_id" ]]; then
		token=$(_github_app_cached_token "$installation_id" 2>/dev/null || true)
		if [[ -n "$token" ]]; then
			printf '%s\n' "$token"
			return 0
		fi
	fi
	github_app_exchange_token "$repo"
	return $?
}

github_app_token() {
	github_app_token_for_repo "${1:-}"
	return $?
}

_github_app_extract_repo_from_api_args() {
	local arg owner repo
	for arg in "$@"; do
		if [[ "$arg" =~ ^/repos/([^/]+/[^/?#]+)($|[/?#]) ]]; then
			printf '%s\n' "${BASH_REMATCH[1]}"
			return 0
		fi
	done
	return 1
}

_github_app_api_invoke() {
	local timeout_class="$1"
	shift
	if command -v _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout "$timeout_class" "$@"
		return $?
	fi
	"$@"
	return $?
}

github_app_api_call() {
	local timeout_class="$1"
	local api_pool="$2"
	shift 2
	local repo token installation_id context_wrapper context_operation context_stage
	local old_token token_was_set old_auth auth_was_set old_principal principal_was_set
	local old_pool pool_was_set old_route route_was_set old_context_operation context_operation_was_set
	local old_context_wrapper context_wrapper_was_set old_context_stage context_stage_was_set rc
	repo=$(_github_app_extract_repo_from_api_args "$@" 2>/dev/null || true)
	token=$(github_app_token_for_repo "$repo" 2>/dev/null || true)
	context_wrapper="${FUNCNAME[1]:-github_app_api_call}"
	context_operation="${FUNCNAME[2]:-$context_wrapper}"
	context_stage="${AIDEVOPS_GH_COOLDOWN_STAGE:-github-app-auth}"
	[[ "$context_wrapper" == "_rest_api_call" ]] && context_stage="${AIDEVOPS_GH_COOLDOWN_STAGE:-rest-fallback}"
	old_token="${GH_TOKEN:-}"; token_was_set="${GH_TOKEN+x}"
	old_auth="${AIDEVOPS_GH_AUTH_MODE:-}"; auth_was_set="${AIDEVOPS_GH_AUTH_MODE+x}"
	old_principal="${AIDEVOPS_GH_AUTH_PRINCIPAL:-}"; principal_was_set="${AIDEVOPS_GH_AUTH_PRINCIPAL+x}"
	old_pool="${AIDEVOPS_GH_API_POOL:-}"; pool_was_set="${AIDEVOPS_GH_API_POOL+x}"
	old_route="${AIDEVOPS_GH_ROUTE_DECISION:-}"; route_was_set="${AIDEVOPS_GH_ROUTE_DECISION+x}"
	old_context_operation="${AIDEVOPS_GH_COOLDOWN_OPERATION:-}"; context_operation_was_set="${AIDEVOPS_GH_COOLDOWN_OPERATION+x}"
	old_context_wrapper="${AIDEVOPS_GH_COOLDOWN_WRAPPER:-}"; context_wrapper_was_set="${AIDEVOPS_GH_COOLDOWN_WRAPPER+x}"
	old_context_stage="${AIDEVOPS_GH_COOLDOWN_STAGE:-}"; context_stage_was_set="${AIDEVOPS_GH_COOLDOWN_STAGE+x}"
	AIDEVOPS_GH_COOLDOWN_OPERATION="$context_operation"
	AIDEVOPS_GH_COOLDOWN_WRAPPER="$context_wrapper"
	AIDEVOPS_GH_COOLDOWN_STAGE="$context_stage"
	AIDEVOPS_GH_API_POOL="$api_pool"
	if [[ -n "$token" ]]; then
		installation_id=$(github_app_installation_id 2>/dev/null || true)
		GH_TOKEN="$token"
		AIDEVOPS_GH_AUTH_MODE="github-app"
		AIDEVOPS_GH_AUTH_PRINCIPAL="app-installation:${installation_id:-unknown}"
		AIDEVOPS_GH_ROUTE_DECISION="${api_pool}-github-app"
	else
		AIDEVOPS_GH_AUTH_MODE="gh-pat"
		AIDEVOPS_GH_AUTH_PRINCIPAL="${AIDEVOPS_GH_AUTH_PRINCIPAL:-unknown}"
		AIDEVOPS_GH_ROUTE_DECISION="${api_pool}-gh-pat"
	fi
	export GH_TOKEN AIDEVOPS_GH_AUTH_MODE AIDEVOPS_GH_AUTH_PRINCIPAL AIDEVOPS_GH_API_POOL AIDEVOPS_GH_ROUTE_DECISION AIDEVOPS_GH_COOLDOWN_OPERATION AIDEVOPS_GH_COOLDOWN_WRAPPER AIDEVOPS_GH_COOLDOWN_STAGE
	_github_app_api_invoke "$timeout_class" "$@"
	rc=$?
	if [[ -n "$token_was_set" ]]; then
		GH_TOKEN="$old_token"
	else
		unset GH_TOKEN
	fi
	if [[ -n "$auth_was_set" ]]; then
		AIDEVOPS_GH_AUTH_MODE="$old_auth"
	else
		unset AIDEVOPS_GH_AUTH_MODE
	fi
	if [[ -n "$principal_was_set" ]]; then
		AIDEVOPS_GH_AUTH_PRINCIPAL="$old_principal"
	else
		unset AIDEVOPS_GH_AUTH_PRINCIPAL
	fi
	if [[ -n "$pool_was_set" ]]; then
		AIDEVOPS_GH_API_POOL="$old_pool"
	else
		unset AIDEVOPS_GH_API_POOL
	fi
	if [[ -n "$route_was_set" ]]; then
		AIDEVOPS_GH_ROUTE_DECISION="$old_route"
	else
		unset AIDEVOPS_GH_ROUTE_DECISION
	fi
	if [[ -n "$context_operation_was_set" ]]; then
		AIDEVOPS_GH_COOLDOWN_OPERATION="$old_context_operation"
	else
		unset AIDEVOPS_GH_COOLDOWN_OPERATION
	fi
	if [[ -n "$context_wrapper_was_set" ]]; then
		AIDEVOPS_GH_COOLDOWN_WRAPPER="$old_context_wrapper"
	else
		unset AIDEVOPS_GH_COOLDOWN_WRAPPER
	fi
	if [[ -n "$context_stage_was_set" ]]; then
		AIDEVOPS_GH_COOLDOWN_STAGE="$old_context_stage"
	else
		unset AIDEVOPS_GH_COOLDOWN_STAGE
	fi
	return "$rc"
}

github_app_rate_limit_json() {
	local repo="${1:-}"
	local requested_mode="${2:-auto}"
	local auth_mode="gh-pat"
	local principal="default"
	local token=""
	local cache_file now cached_ts response tmp
	if [[ "$requested_mode" == "github-app" || "$requested_mode" == "auto" ]]; then
		token=$(github_app_token_for_repo "$repo" 2>/dev/null || true)
		if [[ -n "$token" ]]; then
			auth_mode="github-app"
			principal=$(github_app_installation_id_for_repo "$repo" 2>/dev/null || printf 'default')
		fi
	fi
	cache_file=$(_github_app_rate_cache_path "$auth_mode" "$principal")
	now=$(date +%s)
	if [[ -f "$cache_file" ]]; then
		cached_ts=$(jq -r '._aidevops_cached_at // 0' "$cache_file" 2>/dev/null || printf '0')
		if [[ "$cached_ts" =~ ^[0-9]+$ && $((now - cached_ts)) -le "$AIDEVOPS_GITHUB_APP_RATE_LIMIT_CACHE_TTL" ]]; then
			cat "$cache_file"
			return 0
		fi
	fi
	if [[ "$auth_mode" == "github-app" ]]; then
		response=$(GH_TOKEN="$token" gh api rate_limit 2>/dev/null) || return 1
	else
		response=$(gh api rate_limit 2>/dev/null) || return 1
	fi
	if [[ "$response" =~ ^[0-9]+$ ]]; then
		response=$(jq -n --argjson remaining "$response" \
			'{resources:{graphql:{remaining:$remaining},core:{remaining:5000},search:{remaining:30}}}')
	fi
	tmp="${cache_file}.$$"
	printf '%s\n' "$response" | jq --arg auth_mode "$auth_mode" --arg principal "$principal" --argjson cached_at "$now" \
		'. + {_aidevops_auth_mode:$auth_mode, _aidevops_principal:$principal, _aidevops_cached_at:$cached_at}' >"$tmp" || return 1
	chmod 600 "$tmp" 2>/dev/null || true
	mv "$tmp" "$cache_file"
	cat "$cache_file"
	return 0
}

github_app_rate_limit_remaining() {
	local pool="${1:-graphql}"
	local repo="${2:-}"
	local mode="${3:-auto}"
	local json jq_path value
	json=$(github_app_rate_limit_json "$repo" "$mode") || return 1
	case "$pool" in
	graphql) jq_path='.resources.graphql.remaining // empty' ;;
	rest-core | core | rest) jq_path='.resources.core.remaining // empty' ;;
	rest-search | search) jq_path='.resources.search.remaining // empty' ;;
	*) jq_path='.resources.graphql.remaining // empty' ;;
	esac
	value=$(printf '%s\n' "$json" | jq -r "$jq_path" 2>/dev/null || true)
	[[ "$value" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$value"
	return 0
}

github_app_classify_operation() {
	local operation="${1:-}"
	case "$operation" in
	graphql | graphql-only | mutation | node-id | subissue | project-v2) printf 'graphql\n' ;;
	issue-search | search | search-issues | issue-list-search) printf 'rest-search\n' ;;
	issue-view | issue-list | pr-view | pr-list | checks | statuses | labels | comments | read) printf 'rest-core\n' ;;
	issue-create | issue-edit | issue-comment | pr-create | pr-merge | gh-cli | native-gh | write) printf 'gh-pat-fallback\n' ;;
	*) printf 'gh-pat-fallback\n' ;;
	esac
	return 0
}

github_app_should_route_rest() {
	local api_pool="${1:-rest-core}"
	local operation="${2:-read}"
	local remaining=""
	[[ "${AIDEVOPS_GITHUB_APP_DISABLE_ROUTING:-0}" == "1" ]] && return 1
	case "$api_pool" in
	rest-core | rest-search) ;;
	*) return 1 ;;
	esac
	if github_app_is_configured; then
		if _github_app_bool_true "${AIDEVOPS_GITHUB_APP_REST_FIRST:-1}"; then
			return 0
		fi
		remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null || true)
		if [[ "$remaining" =~ ^[0-9]+$ && "$remaining" -le "${AIDEVOPS_GH_REST_FALLBACK_THRESHOLD:-3000}" ]]; then
			return 0
		fi
	fi
	[[ -n "$operation" ]] || return 1
	return 1
}

github_app_route_json() {
	local operation="${1:-read}"
	local repo="${2:-}"
	local semantic selected_pool auth_mode decision graphql_remaining core_remaining search_remaining configured
	semantic=$(github_app_classify_operation "$operation")
	selected_pool="$semantic"
	auth_mode="gh-pat"
	decision="${semantic}-selected"
	configured=false
	if github_app_is_configured; then
		configured=true
	fi
	if [[ "$semantic" == "rest-core" || "$semantic" == "rest-search" ]]; then
		if [[ "$configured" == "true" ]]; then
			auth_mode="github-app"
			decision="${semantic}-github-app-rest-first"
		else
			auth_mode="gh-pat"
			decision="${semantic}-gh-rest-fallback"
		fi
	elif [[ "$semantic" == "graphql" ]]; then
		decision="graphql-required"
	else
		selected_pool="gh-pat-fallback"
		decision="native-gh-fallback"
	fi
	graphql_remaining=$(github_app_rate_limit_remaining graphql "$repo" "$auth_mode" 2>/dev/null || true)
	core_remaining=$(github_app_rate_limit_remaining rest-core "$repo" "$auth_mode" 2>/dev/null || true)
	search_remaining=$(github_app_rate_limit_remaining rest-search "$repo" "$auth_mode" 2>/dev/null || true)
	jq -n \
		--arg operation "$operation" \
		--arg semantic "$semantic" \
		--arg selected_pool "$selected_pool" \
		--arg auth_mode "$auth_mode" \
		--arg decision "$decision" \
		--arg graphql_remaining "$graphql_remaining" \
		--arg core_remaining "$core_remaining" \
		--arg search_remaining "$search_remaining" \
		--argjson configured "$configured" \
		'{operation:$operation, semantic:$semantic, selected_pool:$selected_pool, auth_mode:$auth_mode, route_decision:$decision, configured:$configured, budgets:{graphql_remaining:$graphql_remaining, rest_core_remaining:$core_remaining, rest_search_remaining:$search_remaining}}'
	return 0
}

github_app_status_json() {
	local repo="${1:-}"
	local app_id installation_id key_path configured rate_json graphql_remaining core_remaining search_remaining auth_mode
	app_id=$(github_app_app_id)
	installation_id=$(github_app_installation_id)
	key_path=$(github_app_private_key_path)
	configured=false
	github_app_is_configured && configured=true
	rate_json=$(github_app_rate_limit_json "$repo" auto 2>/dev/null || true)
	auth_mode=$(printf '%s\n' "$rate_json" | jq -r '._aidevops_auth_mode // "gh-pat"' 2>/dev/null || printf 'gh-pat')
	graphql_remaining=$(printf '%s\n' "$rate_json" | jq -r '.resources.graphql.remaining // empty' 2>/dev/null || true)
	core_remaining=$(printf '%s\n' "$rate_json" | jq -r '.resources.core.remaining // empty' 2>/dev/null || true)
	search_remaining=$(printf '%s\n' "$rate_json" | jq -r '.resources.search.remaining // empty' 2>/dev/null || true)
	jq -n \
		--arg configured "$configured" \
		--arg app_id "$app_id" \
		--arg installation_id "$installation_id" \
		--arg private_key_source "$([[ -n "$key_path" ]] && printf 'file' || printf 'missing')" \
		--arg auth_mode "$auth_mode" \
		--arg graphql_remaining "$graphql_remaining" \
		--arg core_remaining "$core_remaining" \
		--arg search_remaining "$search_remaining" \
		'{configured:($configured == "true"), app_id:$app_id, installation_id:$installation_id, private_key_source:$private_key_source, active_auth_mode:$auth_mode, budgets:{graphql_remaining:$graphql_remaining, rest_core_remaining:$core_remaining, rest_search_remaining:$search_remaining}}'
	return 0
}

_github_app_print_status() {
	local repo="${1:-}"
	local json
	json=$(github_app_status_json "$repo") || return 1
	printf 'GitHub App auth: %s\n' "$(printf '%s\n' "$json" | jq -r 'if .configured then "configured" else "not configured" end')"
	printf 'Active auth mode: %s\n' "$(printf '%s\n' "$json" | jq -r '.active_auth_mode')"
	printf 'App ID: %s\n' "$(printf '%s\n' "$json" | jq -r '.app_id // empty')"
	printf 'Installation ID: %s\n' "$(printf '%s\n' "$json" | jq -r '.installation_id // empty')"
	printf 'Private key source: %s\n' "$(printf '%s\n' "$json" | jq -r '.private_key_source')"
	printf 'Budgets: graphql=%s rest-core=%s rest-search=%s\n' \
		"$(printf '%s\n' "$json" | jq -r '.budgets.graphql_remaining // "unknown"')" \
		"$(printf '%s\n' "$json" | jq -r '.budgets.rest_core_remaining // "unknown"')" \
		"$(printf '%s\n' "$json" | jq -r '.budgets.rest_search_remaining // "unknown"')"
	return 0
}

_github_app_usage() {
	cat <<'EOF'
github-app-auth-helper.sh — GitHub App auth and API routing

Subcommands:
  status [--json] [--repo owner/repo]     Show configured auth mode and budgets
  route <operation> [--json] [--repo r]   Show route decision for an operation
  rate-limit [--json] [--repo owner/repo] Show cached per-pool rate-limit state
  clear-cache                             Remove cached app tokens/rate limits
  token [--repo owner/repo]               Print token only when AIDEVOPS_GITHUB_APP_ALLOW_TOKEN_STDOUT=1
  help                                    Show this help

Operations: issue-view, issue-list, issue-search, pr-view, pr-list,
graphql-only, issue-create, issue-edit, issue-comment, pr-create.

Configuration: copy .agents/configs/github-app-auth.json.txt to
~/.config/aidevops/github-app-auth.json or set AIDEVOPS_GITHUB_APP_* env vars.
EOF
	return 0
}

_github_app_cli() {
	local cmd="${1:-help}"
	shift || true
	local repo=""
	local json=0
	local operation=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo) repo="${2:-}"; shift 2 ;;
		--repo=*) repo="${arg#--repo=}"; shift ;;
		--json) json=1; shift ;;
		*) if [[ -z "$operation" ]]; then operation="$arg"; fi; shift ;;
		esac
	done
	case "$cmd" in
	status)
		if [[ "$json" -eq 1 ]]; then github_app_status_json "$repo"; else _github_app_print_status "$repo"; fi
		return $?
		;;
	route)
		operation="${operation:-read}"
		if [[ "$json" -eq 1 ]]; then
			github_app_route_json "$operation" "$repo"
		else
			github_app_route_json "$operation" "$repo" | jq -r '"\(.operation): \(.auth_mode) → \(.selected_pool) (\(.route_decision))"'
		fi
		return $?
		;;
	rate-limit)
		if [[ "$json" -eq 1 ]]; then
			github_app_rate_limit_json "$repo" auto
		else
			github_app_status_json "$repo" | jq -r '"graphql=\(.budgets.graphql_remaining // "unknown") rest-core=\(.budgets.rest_core_remaining // "unknown") rest-search=\(.budgets.rest_search_remaining // "unknown")"'
		fi
		return $?
		;;
	clear-cache)
		rm -f "${AIDEVOPS_GITHUB_APP_CACHE_DIR}"/token-*.json "${AIDEVOPS_GITHUB_APP_CACHE_DIR}"/rate-limit-*.json 2>/dev/null || true
		printf 'GitHub App auth cache cleared\n'
		return 0
		;;
	token)
		if [[ "${AIDEVOPS_GITHUB_APP_ALLOW_TOKEN_STDOUT:-0}" != "1" ]]; then
			print_error "Refusing to print installation token without AIDEVOPS_GITHUB_APP_ALLOW_TOKEN_STDOUT=1"
			return 2
		fi
		github_app_token_for_repo "$repo"
		return $?
		;;
	help | --help | -h)
		_github_app_usage
		return 0
		;;
	*)
		print_error "Unknown subcommand: $cmd"
		_github_app_usage
		return 2
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_github_app_cli "$@"
fi
