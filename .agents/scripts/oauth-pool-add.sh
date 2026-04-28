#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OAuth Pool Helper -- Add Account Sub-Library
# =============================================================================
# Provides all "add account" flows for the OAuth pool:
#   - Anthropic and OpenAI: PKCE browser OAuth flows
#   - OpenAI: device flow via OpenCode CLI (default)
#   - Cursor: reads credentials from local Cursor IDE installation
#   - Google: OAuth2 PKCE flow with ADC bearer token injection
#
# Usage: source "${SCRIPT_DIR}/oauth-pool-add.sh"
#
# Dependencies:
#   - oauth-pool-helper.sh must be sourced first (provides POOL_FILE, POOL_OPS,
#     USER_AGENT, provider constants, and core helper functions)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_OAUTH_POOL_ADD_LOADED:-}" ]] && return 0
_OAUTH_POOL_ADD_LOADED=1

# SCRIPT_DIR fallback — for defensive portability (sub-library may be sourced
# by test harnesses that don't pre-set SCRIPT_DIR).
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ---------------------------------------------------------------------------
# Add account — helpers
# ---------------------------------------------------------------------------

# Prompt for or validate an email address.
# Usage: _add_prompt_email "$prefill_email" "$prompt_text"
# Prints the validated email to stdout; returns 1 on invalid input.
_add_prompt_email() {
	local prefill_email="$1"
	local prompt_text="${2:-Account email: }"
	local email
	if [[ -n "$prefill_email" ]]; then
		email="$prefill_email"
		print_info "Using email: ${email}" >&2
	else
		printf '%s' "$prompt_text" >&2
		read -r email
	fi
	if [[ -z "$email" || "$email" != *@* ]]; then
		print_error "Invalid email address" >&2
		return 1
	fi
	printf '%s' "$email"
	return 0
}

# Build the OAuth authorize URL for anthropic or openai providers.
# Usage: _add_build_authorize_url "$provider" "$client_id" "$redirect_uri" \
#            "$scopes" "$challenge" "$state_nonce"
# Prints the full URL to stdout.
_add_build_authorize_url() {
	local provider="$1"
	local client_id="$2"
	local redirect_uri="$3"
	local scopes="$4"
	local challenge="$5"
	local state_nonce="$6"
	local encoded_scopes encoded_redirect
	encoded_scopes=$(urlencode "$scopes")
	encoded_redirect=$(urlencode "$redirect_uri")
	local full_url="${ANTHROPIC_AUTHORIZE_URL}"
	if [[ "$provider" == "openai" ]]; then
		full_url="$OPENAI_AUTHORIZE_URL"
	fi
	full_url="${full_url}?client_id=${client_id}&response_type=code&redirect_uri=${encoded_redirect}&scope=${encoded_scopes}&code_challenge=${challenge}&code_challenge_method=S256&state=${state_nonce}"
	if [[ "$provider" == "anthropic" ]]; then
		# Alignment: &code=true matches Claude CLI — tells the login page to show
		# the Claude Max upsell. Required for parity with the official client.
		full_url="${full_url}&code=true"
		# Claude CLI also supports these optional params (we don't send them):
		#   &orgUUID=...      — pre-select org for team/enterprise logins
		#   &login_hint=...   — pre-populate email (standard OIDC parameter)
		#   &login_method=... — request specific login method (sso, magic_link, google)
		# FALLBACK: if org-scoped auth is needed, add &orgUUID= to the URL.
	fi
	printf '%s' "$full_url"
	return 0
}

# Save a new/updated account into the pool and print a success message.
# Usage: _add_save_to_pool "$provider" "$email" "$access_token" \
#            "$refresh_token" "$expires_ms" "$now_iso"
_add_save_to_pool() {
	local provider="$1"
	local email="$2"
	local access_token="$3"
	local refresh_token="$4"
	local expires_ms="$5"
	local now_iso="$6"
	local account_id="${7:-}"
	local pool count
	pool=$(load_pool)
	pool=$(printf '%s' "$pool" | pool_upsert_account "$provider" "$email" \
		"$access_token" "$refresh_token" "$expires_ms" "$now_iso" "$account_id")
	save_pool "$pool"
	count=$(printf '%s' "$pool" | count_provider_accounts "$provider")
	print_success "Added ${email} to ${provider} pool (${count} account(s) total)"
	return 0
}

# Read OpenCode OpenAI auth fields (access, refresh, expires, accountId).
# Prints four lines in that order.
_openai_read_opencode_auth_fields() {
	local auth_path="$OPENCODE_AUTH_FILE"
	if [[ ! -f "$auth_path" ]]; then
		print_error "OpenCode auth file not found: ${auth_path}"
		return 1
	fi
	AUTH_PATH="$auth_path" python3 "$POOL_OPS" openai-read-auth 2>/dev/null
	return 0
}

# Add OpenAI account via OpenCode's headless Codex device flow.
# Falls back to callback mode in cmd_add() when this returns non-zero.
_cmd_add_openai_device() {
	local prefill_email="$1"
	local email
	email=$(_add_prompt_email "$prefill_email") || return 1

	if ! command -v opencode &>/dev/null; then
		print_error "OpenCode CLI not found. Cannot run OpenAI device login flow."
		return 1
	fi

	print_info "Starting OpenAI device login (Codex) via OpenCode..."
	print_info "Follow the browser/device prompts, then return to this terminal."
	if ! opencode providers login -p OpenAI -m "ChatGPT Pro/Plus (headless)"; then
		print_error "OpenAI device login failed"
		return 1
	fi

	local auth_fields access_token refresh_token expires_raw account_id
	auth_fields=$(_openai_read_opencode_auth_fields) || return 1
	access_token=$(printf '%s\n' "$auth_fields" | sed -n '1p')
	refresh_token=$(printf '%s\n' "$auth_fields" | sed -n '2p')
	expires_raw=$(printf '%s\n' "$auth_fields" | sed -n '3p')
	account_id=$(printf '%s\n' "$auth_fields" | sed -n '4p')

	if [[ -z "$access_token" ]]; then
		print_error "OpenCode login completed but no OpenAI access token was found"
		return 1
	fi

	local now_ms expires_ms now_iso
	now_ms=$(get_now_ms)
	if [[ "$expires_raw" =~ ^[0-9]+$ ]]; then
		if [[ "$expires_raw" -gt 1000000000000 ]]; then
			expires_ms="$expires_raw"
		else
			expires_ms=$((expires_raw * 1000))
		fi
	else
		expires_ms=$((now_ms + 3600 * 1000))
	fi
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	_add_save_to_pool "openai" "$email" "$access_token" "$refresh_token" "$expires_ms" "$now_iso" "$account_id"
	print_info "OpenAI account added via device flow. Restart OpenCode to use the pool token."
	return 0
}

# Resolve provider-specific OAuth parameters.
# Prints 5 lines: client_id, redirect_uri, scopes, token_endpoint, content_type, ua_header.
_add_get_provider_params() {
	local provider="$1"
	if [[ "$provider" == "anthropic" ]]; then
		printf '%s\n' "$ANTHROPIC_CLIENT_ID"
		printf '%s\n' "$ANTHROPIC_REDIRECT_URI"
		printf '%s\n' "$ANTHROPIC_SCOPES"
		printf '%s\n' "$ANTHROPIC_TOKEN_ENDPOINT"
		printf '%s\n' "application/json"
		printf '%s\n' "$USER_AGENT"
	else
		printf '%s\n' "$OPENAI_CLIENT_ID"
		printf '%s\n' "$OPENAI_REDIRECT_URI"
		printf '%s\n' "$OPENAI_SCOPES"
		printf '%s\n' "$OPENAI_TOKEN_ENDPOINT"
		printf '%s\n' "application/x-www-form-urlencoded"
		printf '%s\n' "opencode/1.2.27"
	fi
	return 0
}

# Read and validate the authorization code from stdin, stripping fragment and
# checking state nonce. Prints the bare code to stdout.
_add_read_auth_code() {
	local state_nonce="$1"
	local auth_code
	printf 'Paste the authorization code here: ' >&2
	read -r auth_code
	if [[ -z "$auth_code" ]]; then
		print_error "No authorization code provided" >&2
		return 1
	fi
	local code returned_state
	if [[ "$auth_code" == *"#"* ]]; then
		code="${auth_code%%#*}"
		returned_state="${auth_code#*#}"
		if [[ "$returned_state" != "$state_nonce" ]]; then
			print_error "State mismatch — possible CSRF. Expected ${state_nonce}, got ${returned_state}" >&2
			return 1
		fi
	else
		code="$auth_code"
	fi
	printf '%s' "$code"
	return 0
}

# Build the token exchange request body for anthropic or openai.
# Prints the body string to stdout.
_add_build_token_body() {
	local provider="$1"
	local code="$2"
	local client_id="$3"
	local redirect_uri="$4"
	local verifier="$5"
	local state_nonce="$6"
	if [[ "$provider" == "anthropic" ]]; then
		# Build JSON via Python to safely encode the auth code.
		# The 'state' field is required by Anthropic's token endpoint as of
		# Claude CLI v2.1.x — omitting it causes HTTP 400 "Invalid request format".
		# Alignment: body fields match Claude CLI's exchangeCodeForTokens() exactly:
		#   grant_type, code, redirect_uri, client_id, code_verifier, state
		# Claude CLI also supports an optional 'expires_in' field for custom token
		# lifetimes — we don't send it (server default is fine for pool rotation).
		CODE="$code" CLIENT_ID="$client_id" REDIR="$redirect_uri" \
			VERIFIER="$verifier" STATE="$state_nonce" python3 -c "
import json, os
print(json.dumps({
    'code': os.environ['CODE'],
    'grant_type': 'authorization_code',
    'client_id': os.environ['CLIENT_ID'],
    'redirect_uri': os.environ['REDIR'],
    'code_verifier': os.environ['VERIFIER'],
    'state': os.environ['STATE'],
}))"
	else
		local encoded_code
		encoded_code=$(urlencode "$code")
		printf 'code=%s&grant_type=authorization_code&client_id=%s&redirect_uri=%s&code_verifier=%s' \
			"$encoded_code" "$client_id" "$(urlencode "$redirect_uri")" "$verifier"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Add account — PKCE authorize phase
# ---------------------------------------------------------------------------

# Open the browser for OAuth and return the authorization code.
# Usage: _cmd_add_pkce_authorize "$provider" "$email" "$verifier" "$challenge" \
#            "$state_nonce" "$client_id" "$redirect_uri" "$scopes"
# Prints the authorization code to stdout; returns 1 on failure.
_cmd_add_pkce_authorize() {
	local provider="$1"
	local email="$2"
	local verifier="$3"
	local challenge="$4"
	local state_nonce="$5"
	local client_id="$6"
	local redirect_uri="$7"
	local scopes="$8"

	local full_url
	full_url=$(_add_build_authorize_url "$provider" "$client_id" "$redirect_uri" "$scopes" "$challenge" "$state_nonce")

	print_info "Opening browser for ${provider} OAuth..."
	open_browser "$full_url"

	local code
	code=$(_add_read_auth_code "$state_nonce") || return 1
	printf '%s' "$code"
	return 0
}

# ---------------------------------------------------------------------------
# Add account — token exchange and pool save phase
# ---------------------------------------------------------------------------

# Exchange an authorization code for tokens and save the account to the pool.
# Usage: _cmd_add_exchange_and_save "$provider" "$email" "$code" \
#            "$client_id" "$redirect_uri" "$verifier" "$state_nonce" \
#            "$token_endpoint" "$content_type" "$ua_header"
# Returns 1 on any failure.
_cmd_add_exchange_and_save() {
	local provider="$1"
	local email="$2"
	local code="$3"
	local client_id="$4"
	local redirect_uri="$5"
	local verifier="$6"
	local state_nonce="$7"
	local token_endpoint="$8"
	local content_type="$9"
	local ua_header="${10}"

	print_info "Exchanging authorization code for tokens..."

	local token_body
	token_body=$(_add_build_token_body "$provider" "$code" "$client_id" "$redirect_uri" "$verifier" "$state_nonce")

	local response http_status body
	response=$(_oauth_exchange_code "$token_endpoint" "$content_type" "$ua_header" "$token_body") || {
		print_error "curl failed"
		return 1
	}
	http_status=$(printf '%s' "$response" | tail -1)
	body=$(printf '%s' "$response" | sed '$d')

	if [[ "$http_status" != "200" ]]; then
		print_error "Token exchange failed: HTTP ${http_status}"
		local error_msg
		error_msg=$(printf '%s' "$body" | extract_token_error)
		print_error "Error: ${error_msg}"
		return 1
	fi

	# Extract tokens (three lines: access, refresh, expires_in)
	local token_fields access_token refresh_token expires_in
	token_fields=$(printf '%s' "$body" | _extract_token_fields)
	access_token=$(printf '%s\n' "$token_fields" | sed -n '1p')
	refresh_token=$(printf '%s\n' "$token_fields" | sed -n '2p')
	expires_in=$(printf '%s\n' "$token_fields" | sed -n '3p')

	if [[ -z "$access_token" ]]; then
		print_error "No access token in response"
		return 1
	fi

	# Alignment note: after token exchange, Claude CLI fetches the user profile
	# via GET https://api.anthropic.com/api/oauth/profile (Bearer token auth) to
	# determine subscription type (pro/max/team/enterprise) and rate limit tier.
	# We skip this — pool rotation doesn't need subscription info. But if
	# debugging auth issues, this endpoint is useful for verifying the token
	# grants the expected access level.
	# DIAGNOSTIC: curl -s -H "Authorization: Bearer $access_token" \
	#   -H "Content-Type: application/json" \
	#   https://api.anthropic.com/api/oauth/profile

	local now_ms expires_ms now_iso
	now_ms=$(get_now_ms)
	expires_ms=$((now_ms + expires_in * 1000))
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	_add_save_to_pool "$provider" "$email" "$access_token" "$refresh_token" "$expires_ms" "$now_iso"
	return 0
}

# ---------------------------------------------------------------------------
# Add account
# ---------------------------------------------------------------------------

cmd_add() {
	local provider="${1:-anthropic}"
	local prefill_email="${2:-}"

	if [[ "$provider" != "anthropic" && "$provider" != "openai" && "$provider" != "cursor" && "$provider" != "google" ]]; then
		print_error "Unsupported provider: $provider (supported: anthropic, openai, cursor, google)"
		return 1
	fi

	# Cursor uses a different flow — read from local IDE installation
	if [[ "$provider" == "cursor" ]]; then
		cmd_add_cursor
		return $?
	fi

	# Google uses its own OAuth flow with ADC token injection
	if [[ "$provider" == "google" ]]; then
		cmd_add_google "$prefill_email"
		return $?
	fi

	# OpenAI default path: headless device auth (Codex). Callback flow remains fallback.
	if [[ "$provider" == "openai" ]]; then
		local openai_add_mode="${AIDEVOPS_OPENAI_ADD_MODE:-device}"
		case "$openai_add_mode" in
		device)
			if _cmd_add_openai_device "$prefill_email"; then
				return 0
			fi
			print_warning "OpenAI device login failed — falling back to callback URL flow"
			;;
		callback)
			print_info "Using callback URL flow for OpenAI (AIDEVOPS_OPENAI_ADD_MODE=callback)"
			;;
		*)
			print_error "Invalid AIDEVOPS_OPENAI_ADD_MODE: ${openai_add_mode} (valid: device, callback)"
			return 1
			;;
		esac
	fi

	local email
	email=$(_add_prompt_email "$prefill_email") || return 1

	# Generate PKCE + separate state nonce (verifier must not double as state)
	local verifier challenge state_nonce
	verifier=$(generate_verifier)
	challenge=$(generate_challenge "$verifier")
	state_nonce=$(openssl rand -hex 24)

	# Select provider-specific OAuth parameters
	local params client_id redirect_uri scopes token_endpoint content_type ua_header
	params=$(_add_get_provider_params "$provider")
	client_id=$(printf '%s\n' "$params" | sed -n '1p')
	redirect_uri=$(printf '%s\n' "$params" | sed -n '2p')
	scopes=$(printf '%s\n' "$params" | sed -n '3p')
	token_endpoint=$(printf '%s\n' "$params" | sed -n '4p')
	content_type=$(printf '%s\n' "$params" | sed -n '5p')
	ua_header=$(printf '%s\n' "$params" | sed -n '6p')

	local code
	code=$(_cmd_add_pkce_authorize "$provider" "$email" "$verifier" "$challenge" \
		"$state_nonce" "$client_id" "$redirect_uri" "$scopes") || return 1

	_cmd_add_exchange_and_save "$provider" "$email" "$code" \
		"$client_id" "$redirect_uri" "$verifier" "$state_nonce" \
		"$token_endpoint" "$content_type" "$ua_header" || return 1

	print_info "Restart OpenCode to use the new token."
	# Bash 3.2 compat: ${var^} (uppercase first) requires Bash 4+. Use printf + tr.
	local provider_cap
	provider_cap="$(printf '%s' "${provider:0:1}" | tr '[:lower:]' '[:upper:]')${provider:1}"
	print_info "Then switch to the '${provider_cap}' provider and select a model to start chatting."
	return 0
}

# ---------------------------------------------------------------------------
# Add Cursor account — helpers
# ---------------------------------------------------------------------------

# Resolve Cursor credential file paths for the current platform.
# Prints two lines: cursor_auth_json path, cursor_state_db path.
# Returns 1 on unsupported platform.
_cursor_get_platform_paths() {
	case "$(uname -s)" in
	Darwin)
		printf '%s\n' "${HOME}/.cursor/auth.json"
		printf '%s\n' "${HOME}/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
		;;
	Linux)
		local config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}"
		printf '%s\n' "${config_dir}/cursor/auth.json"
		printf '%s\n' "${HOME}/.config/Cursor/User/globalStorage/state.vscdb"
		;;
	MINGW* | MSYS* | CYGWIN*)
		local app_data="${APPDATA:-${HOME}/AppData/Roaming}"
		printf '%s\n' "${app_data}/Cursor/auth.json"
		printf '%s\n' "${app_data}/Cursor/User/globalStorage/state.vscdb"
		;;
	*)
		print_error "Unsupported platform for Cursor: $(uname -s)"
		return 1
		;;
	esac
	return 0
}

# Read access and refresh tokens from Cursor auth.json.
# Prints two lines: access_token, refresh_token (may be empty).
_cursor_read_auth_json() {
	local cursor_auth_json="$1"
	AUTH_PATH="$cursor_auth_json" python3 "$POOL_OPS" cursor-read-auth 2>/dev/null
	return 0
}

# Read Cursor credentials from the IDE SQLite state database.
# Prints three lines: access_token, refresh_token, email (may be empty).
_cursor_read_state_db() {
	local cursor_state_db="$1"
	if ! command -v sqlite3 &>/dev/null; then
		print_error "sqlite3 is required to read Cursor credentials but is not installed"
		return 1
	fi
	local at rt em
	at=$(sqlite3 "$cursor_state_db" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'" 2>/dev/null || true)
	rt=$(sqlite3 "$cursor_state_db" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/refreshToken'" 2>/dev/null || true)
	em=$(sqlite3 "$cursor_state_db" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/cachedEmail'" 2>/dev/null || true)
	printf '%s\n' "${at:-}"
	printf '%s\n' "${rt:-}"
	printf '%s\n' "${em:-}"
	return 0
}

# Decode a JWT access token to extract email and expiry (no secrets printed).
# Prints two lines: email, exp (unix seconds, 0 if unavailable).
_cursor_decode_jwt_fields() {
	local access_token="$1"
	ACCESS="$access_token" python3 "$POOL_OPS" cursor-decode-jwt 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# Add Cursor account (reads from local Cursor IDE installation)
# ---------------------------------------------------------------------------

cmd_add_cursor() {
	# Cursor doesn't use a browser OAuth flow. Instead, credentials are
	# managed by the Cursor IDE and stored locally. We read them from:
	#   1. ~/.cursor/auth.json (cursor-agent CLI)
	#   2. Cursor IDE's SQLite state database (fallback)

	local cursor_auth_json cursor_state_db
	local path_lines
	path_lines=$(_cursor_get_platform_paths) || return 1
	cursor_auth_json=$(printf '%s\n' "$path_lines" | sed -n '1p')
	cursor_state_db=$(printf '%s\n' "$path_lines" | sed -n '2p')

	local access_token="" refresh_token="" email=""

	# Source 1: cursor-agent auth.json
	if [[ -f "$cursor_auth_json" ]]; then
		print_info "Reading from Cursor auth.json..."
		local auth_lines
		auth_lines=$(_cursor_read_auth_json "$cursor_auth_json")
		access_token=$(printf '%s\n' "$auth_lines" | sed -n '1p')
		refresh_token=$(printf '%s\n' "$auth_lines" | sed -n '2p')
	fi

	# Source 2: Cursor IDE state database (fallback or supplement)
	if [[ -z "$access_token" && -f "$cursor_state_db" ]]; then
		print_info "Reading from Cursor IDE state database..."
		local db_lines
		db_lines=$(_cursor_read_state_db "$cursor_state_db") || return 1
		access_token=$(printf '%s\n' "$db_lines" | sed -n '1p')
		if [[ -z "$refresh_token" ]]; then
			refresh_token=$(printf '%s\n' "$db_lines" | sed -n '2p')
		fi
		if [[ -z "$email" ]]; then
			email=$(printf '%s\n' "$db_lines" | sed -n '3p')
		fi
	fi

	if [[ -z "$access_token" ]]; then
		print_error "No Cursor credentials found."
		echo "" >&2
		echo "Make sure you:" >&2
		echo "  1. Have Cursor IDE installed" >&2
		echo "  2. Are logged into your Cursor account in the IDE" >&2
		echo "  3. Have an active Cursor Pro subscription" >&2
		echo "" >&2
		echo "After logging in, run this command again." >&2
		return 1
	fi

	# Decode JWT to get email and expiry (no secrets printed)
	local jwt_fields jwt_email jwt_exp
	jwt_fields=$(_cursor_decode_jwt_fields "$access_token")
	jwt_email=$(printf '%s\n' "$jwt_fields" | sed -n '1p')
	jwt_exp=$(printf '%s\n' "$jwt_fields" | sed -n '2p')
	jwt_exp="${jwt_exp:-0}"

	if [[ -z "$email" && -n "$jwt_email" ]]; then
		email="$jwt_email"
	fi
	if [[ -z "$email" ]]; then
		email="unknown"
	fi

	# Calculate expiry in milliseconds
	local expires_ms
	if [[ "$jwt_exp" != "0" && -n "$jwt_exp" ]]; then
		expires_ms=$((jwt_exp * 1000))
	else
		local now_ms
		now_ms=$(get_now_ms)
		expires_ms=$((now_ms + 3600000))
	fi

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	_add_save_to_pool "cursor" "$email" "$access_token" "${refresh_token:-}" "$expires_ms" "$now_iso"
	print_info "Restart OpenCode to use the Cursor provider."
	return 0
}

# ---------------------------------------------------------------------------
# Add Google account — helpers
# ---------------------------------------------------------------------------

# Build the Google OAuth2 authorize URL with PKCE.
# Usage: _google_build_authorize_url "$challenge" "$state_nonce"
# Prints the full URL to stdout.
_google_build_authorize_url() {
	local challenge="$1"
	local state_nonce="$2"
	local encoded_scopes encoded_redirect
	encoded_scopes=$(urlencode "$GOOGLE_SCOPES")
	encoded_redirect=$(urlencode "$GOOGLE_REDIRECT_URI")
	printf '%s?client_id=%s&response_type=code&redirect_uri=%s&scope=%s&code_challenge=%s&code_challenge_method=S256&state=%s&access_type=offline&prompt=consent' \
		"$GOOGLE_AUTHORIZE_URL" "$GOOGLE_CLIENT_ID" \
		"$encoded_redirect" "$encoded_scopes" \
		"$challenge" "$state_nonce"
	return 0
}

# Exchange a Google authorization code for tokens.
# Prints two lines: http_status, then body JSON.
_google_exchange_code() {
	local auth_code="$1"
	local verifier="$2"
	local token_body
	token_body=$(CODE="$auth_code" CLIENT_ID="$GOOGLE_CLIENT_ID" \
		REDIR="$GOOGLE_REDIRECT_URI" VERIFIER="$verifier" python3 -c "
import json, os
print(json.dumps({
    'code': os.environ['CODE'],
    'grant_type': 'authorization_code',
    'client_id': os.environ['CLIENT_ID'],
    'redirect_uri': os.environ['REDIR'],
    'code_verifier': os.environ['VERIFIER'],
}))")
	_oauth_exchange_code "$GOOGLE_TOKEN_ENDPOINT" "application/json" "aidevops/1.0" "$token_body"
	return 0
}

# Report the result of a Google token health check to the user.
# Usage: _google_report_health "$health_status"
# Returns 1 if the token is definitively invalid (HTTP_401).
_google_report_health() {
	local health_status="$1"
	case "$health_status" in
	OK)
		print_success "Token validated against Gemini API"
		;;
	HTTP_403)
		print_warning "Token valid but Gemini API returned 403 — account may lack AI Pro/Ultra subscription"
		print_info "Token will still be stored; check your Google AI subscription at https://one.google.com/about/google-ai-plans/"
		;;
	HTTP_401)
		print_error "Token invalid (401) — authorization may have failed"
		return 1
		;;
	*)
		print_warning "Could not validate against Gemini API (${health_status}) — storing token anyway"
		;;
	esac
	return 0
}

# Validate a Google access token against the Gemini API.
# Prints one of: OK, HTTP_NNN, NETWORK_ERROR, ERROR.
_google_validate_token() {
	local access_token="$1"
	local health_check_url="$2"
	ACCESS="$access_token" HEALTH_URL="$health_check_url" python3 "$POOL_OPS" google-validate 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# Add Google account (OAuth2 PKCE flow, ADC bearer token injection)
# ---------------------------------------------------------------------------

cmd_add_google() {
	local prefill_email="${1:-}"

	print_info "Adding Google AI account to pool..."
	print_info "Supported plans: Google AI Pro (~\$25/mo), AI Ultra (~\$65/mo), Workspace with Gemini"
	print_info "Token is injected as GOOGLE_OAUTH_ACCESS_TOKEN (ADC bearer) for Gemini CLI / Vertex AI"
	echo "" >&2

	local email
	email=$(_add_prompt_email "$prefill_email" "Google account email: ") || return 1

	# Generate PKCE + state nonce
	local verifier challenge state_nonce
	verifier=$(generate_verifier)
	challenge=$(generate_challenge "$verifier")
	state_nonce=$(openssl rand -hex 24)

	local full_url
	full_url=$(_google_build_authorize_url "$challenge" "$state_nonce")

	print_info "Opening browser for Google OAuth..."
	print_info "Sign in with your Google AI Pro/Ultra or Workspace account."
	open_browser "$full_url"

	# Google OOB flow: the authorization code is shown in the browser
	printf 'Paste the authorization code from the browser: ' >&2
	local auth_code
	read -r auth_code
	if [[ -z "$auth_code" ]]; then
		print_error "No authorization code provided"
		return 1
	fi
	auth_code="${auth_code// /}"

	print_info "Exchanging authorization code for tokens..."

	local response http_status body
	response=$(_google_exchange_code "$auth_code" "$verifier") || {
		print_error "curl failed during token exchange"
		return 1
	}
	http_status=$(printf '%s' "$response" | tail -1)
	body=$(printf '%s' "$response" | sed '$d')

	if [[ "$http_status" != "200" ]]; then
		print_error "Token exchange failed: HTTP ${http_status}"
		local error_msg
		error_msg=$(printf '%s' "$body" | extract_token_error)
		print_error "Error: ${error_msg}"
		return 1
	fi

	local token_fields access_token refresh_token expires_in
	token_fields=$(printf '%s' "$body" | _extract_token_fields)
	access_token=$(printf '%s\n' "$token_fields" | sed -n '1p')
	refresh_token=$(printf '%s\n' "$token_fields" | sed -n '2p')
	expires_in=$(printf '%s\n' "$token_fields" | sed -n '3p')

	if [[ -z "$access_token" ]]; then
		print_error "No access token in response"
		return 1
	fi

	# Validate token against Gemini API (health check)
	print_info "Validating token against Gemini API..."
	local health_status
	health_status=$(_google_validate_token "$access_token" "$GOOGLE_HEALTH_CHECK_URL")
	_google_report_health "$health_status" || return 1

	local now_ms expires_ms now_iso
	now_ms=$(get_now_ms)
	expires_ms=$((now_ms + expires_in * 1000))
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	_add_save_to_pool "google" "$email" "$access_token" "$refresh_token" "$expires_ms" "$now_iso"
	print_info "Token injected as GOOGLE_OAUTH_ACCESS_TOKEN for Gemini CLI / Vertex AI."
	print_info "Restart OpenCode to use the new token."
	return 0
}
