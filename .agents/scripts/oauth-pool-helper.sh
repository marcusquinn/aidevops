#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# oauth-pool-helper.sh — Shell-based OAuth pool account management
#
# Provides add/check/list/remove/rotate/status/assign-pending for OAuth pool
# accounts when the OpenCode TUI auth hooks are unavailable.
#
# Usage:
#   oauth-pool-helper.sh add [anthropic|openai|cursor|google]           # Add account via OAuth/device flow
#   oauth-pool-helper.sh add --no-open [anthropic|openai|cursor|google]  # Print URL instead of opening browser
#   oauth-pool-helper.sh check [anthropic|openai|cursor|google|all]     # Health check all accounts
#   oauth-pool-helper.sh list [anthropic|openai|cursor|google|all]      # List accounts
#   oauth-pool-helper.sh remove <provider> <email>                      # Remove an account
#   oauth-pool-helper.sh rotate [anthropic|openai|cursor|google]        # Switch active account
#   oauth-pool-helper.sh status [anthropic|openai|cursor|google|all]    # Pool rotation statistics
#   oauth-pool-helper.sh assign-pending <provider> [email]              # Assign pending token
#   oauth-pool-helper.sh help                                           # Show usage
#
# Security: Tokens are written to ~/.aidevops/oauth-pool.json (600 perms).
#           Secrets are passed via stdin/env, never as command arguments.
#           No token values are printed to stdout/stderr.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Global flag: set by --no-open to skip browser launch and print the URL instead.
OAUTH_NO_OPEN=false

POOL_FILE="${HOME}/.aidevops/oauth-pool.json"
OPENCODE_AUTH_FILE="${HOME}/.local/share/opencode/auth.json"

# Companion Python library for complex operations (extracted to reduce nesting depth)
POOL_OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/oauth-pool-lib/pool_ops.py"

# Anthropic OAuth
# Alignment notes (vs Claude CLI codebase, for troubleshooting):
#   CLIENT_ID        — identical to Claude CLI (public, same for all clients)
#   TOKEN_ENDPOINT   — identical to Claude CLI prod config
#   AUTHORIZE_URL    — we hit claude.ai directly; Claude CLI now routes through
#                      https://claude.com/cai/oauth/authorize for attribution,
#                      which 307-redirects to claude.ai. Ours is the final dest.
#                      FALLBACK: if authorize breaks, try the claude.com route.
#   REDIRECT_URI     — we use console.anthropic.com; Claude CLI switched to
#                      platform.claude.com (the new Console domain). Both are
#                      currently registered redirect URIs. If Anthropic
#                      deregisters the old domain, switch to the new one below.
#                      FALLBACK: "https://platform.claude.com/oauth/code/callback"
#   SCOPES           — identical to Claude CLI's ALL_OAUTH_SCOPES union
ANTHROPIC_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
ANTHROPIC_TOKEN_ENDPOINT="https://platform.claude.com/v1/oauth/token"
ANTHROPIC_AUTHORIZE_URL="https://claude.ai/oauth/authorize"
# FALLBACK_AUTHORIZE_URL="https://claude.com/cai/oauth/authorize"
ANTHROPIC_REDIRECT_URI="https://console.anthropic.com/oauth/code/callback"
# FALLBACK_REDIRECT_URI="https://platform.claude.com/oauth/code/callback"
ANTHROPIC_SCOPES="org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

# OpenAI OAuth
OPENAI_CLIENT_ID="app_EMoamEEZ73f0CkXaXp7hrann"
OPENAI_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token"
OPENAI_AUTHORIZE_URL="https://auth.openai.com/oauth/authorize"
OPENAI_REDIRECT_URI="http://localhost:1455/auth/callback"
OPENAI_SCOPES="openid profile email offline_access"

# Google OAuth (AI Pro/Ultra/Workspace subscription accounts)
# Client ID is the Google Cloud OAuth2 client for Gemini CLI / AI Studio.
# Tokens are injected as ADC bearer tokens (GOOGLE_OAUTH_ACCESS_TOKEN env var)
# which Gemini CLI, Vertex AI SDK, and generativelanguage.googleapis.com pick up.
GOOGLE_CLIENT_ID="681255809395-oo8ft6t5t0rnmhfqgpnkqtev5b9a2i5j.apps.googleusercontent.com"
GOOGLE_TOKEN_ENDPOINT="https://oauth2.googleapis.com/token"
GOOGLE_AUTHORIZE_URL="https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_REDIRECT_URI="urn:ietf:wg:oauth:2.0:oob"
GOOGLE_SCOPES="https://www.googleapis.com/auth/generative-language https://www.googleapis.com/auth/cloud-platform openid email profile"
GOOGLE_HEALTH_CHECK_URL="https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"

# User-Agent (detect Claude CLI version)
# Note: Claude CLI itself uses axios defaults (no custom UA) for token exchange
# and refresh requests. We set an explicit UA to appear as a Claude CLI client.
# The "(external, cli)" suffix is our addition — not sent by the real CLI.
# FALLBACK: if UA filtering ever causes issues, try removing the suffix or
# switching to an axios-style UA like "axios/1.7.9".
CLAUDE_VERSION="2.1.80"
if command -v claude &>/dev/null; then
	local_ver=$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
	if [[ -n "${local_ver:-}" ]]; then
		CLAUDE_VERSION="$local_ver"
	fi
fi
USER_AGENT="claude-cli/${CLAUDE_VERSION} (external, cli)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

print_info() { printf '\033[0;34m[INFO]\033[0m %s\n' "$1" >&2; }
print_success() { printf '\033[0;32m[OK]\033[0m %s\n' "$1" >&2; }
print_error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$1" >&2; }
print_warning() { printf '\033[0;33m[WARN]\033[0m %s\n' "$1" >&2; }

# Generate PKCE code_verifier (43-128 chars, base64url-no-padding)
generate_verifier() {
	# 32 random bytes -> 43 base64url chars (no padding)
	openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '='
	return 0
}

# Generate PKCE code_challenge from verifier (S256)
generate_challenge() {
	local verifier="$1"
	# SHA256 hash of verifier, then base64url-no-padding
	printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
	return 0
}

# URL-encode a string
urlencode() {
	local string="$1"
	# Pass via env to avoid shell injection in python3 -c string
	INPUT="$string" python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ['INPUT'], safe=''))"
	return 0
}

# Count accounts for a provider in the pool JSON (stdin)
# Usage: printf '%s' "$pool" | count_provider_accounts "$provider"
count_provider_accounts() {
	local provider="$1"
	jq -r --arg p "$provider" '.[$p] | length // 0' 2>/dev/null || echo "0"
	return 0
}

# Current time in milliseconds (epoch)
get_now_ms() {
	python3 -c "import time; print(int(time.time() * 1000))"
	return 0
}

# Auto-clear expired cooldowns so stale rate limits do not block availability.
# Usage: printf '%s' "$pool" | normalize_expired_cooldowns [provider|all]
# Prints JSON object: {"updated": <count>, "pool": <updated_pool>}
normalize_expired_cooldowns() {
	local provider="${1:-all}"
	PROVIDER="$provider" python3 "$POOL_OPS" normalize-cooldowns 2>/dev/null
	return 0
}

# Load pool JSON (create if missing)
load_pool() {
	if [[ -f "$POOL_FILE" ]]; then
		cat "$POOL_FILE"
	else
		echo '{}'
	fi
	return 0
}

# Auto-clear expired cooldowns in the pool JSON.
# Accounts with status "rate-limited" whose cooldownUntil has passed
# are reset to "idle" with cooldownUntil cleared.
# Uses the same file-level lock as mark-failure to prevent races.
# Saves the pool file only if changes were made.
auto_clear_expired_cooldowns() {
	if [[ ! -f "$POOL_FILE" ]]; then
		return 0
	fi
	local result py_stderr_file
	py_stderr_file=$(mktemp "${TMPDIR:-/tmp}/oauth-autoclear-err.XXXXXX")
	if ! result=$(POOL_FILE_PATH="$POOL_FILE" python3 "$POOL_OPS" auto-clear 2>"$py_stderr_file"); then
		local py_err
		py_err=$(cat "$py_stderr_file" 2>/dev/null)
		rm -f "$py_stderr_file"
		if [[ -n "${py_err:-}" ]]; then
			print_warning "oauth-pool-helper: auto-clear python error: ${py_err}" >&2
		fi
		return 1
	fi
	rm -f "$py_stderr_file"
	return 0
}

# Save pool JSON (atomic write, 600 perms)
save_pool() {
	local json="$1"
	local pool_dir
	pool_dir=$(dirname "$POOL_FILE")
	mkdir -p "$pool_dir"
	chmod 700 "$pool_dir"
	local tmp_file="${POOL_FILE}.tmp.$$"
	printf '%s\n' "$json" >"$tmp_file"
	chmod 600 "$tmp_file"
	mv "$tmp_file" "$POOL_FILE"
	return 0
}

# Open URL in browser (best-effort, never fatal — cascades on failure).
# When OAUTH_NO_OPEN=true (set by --no-open), skip the browser and just print the URL.
open_browser() {
	local url="$1"

	if [[ "$OAUTH_NO_OPEN" == "true" ]]; then
		print_info "Open this URL in your browser:"
		printf '%s\n' "$url" >&2
		return 0
	fi

	local cmd
	for cmd in open xdg-open wslview; do
		if command -v "$cmd" &>/dev/null && "$cmd" "$url" 2>/dev/null; then
			return 0
		fi
	done
	print_warning "Cannot open browser automatically."
	# Always print URL so user can open manually if browser launch failed
	print_info "If the browser didn't open, visit this URL:"
	printf '%s\n' "$url" >&2
	return 0
}

# Upsert an account into the pool JSON (stdin → stdout).
# Usage: printf '%s' "$pool" | pool_upsert_account "$provider" "$email" \
#            "$access_token" "$refresh_token" "$expires_ms" "$now_iso"
# Prints the updated pool JSON to stdout.
pool_upsert_account() {
	local provider="$1"
	local email="$2"
	local access_token="$3"
	local refresh_token="$4"
	local expires_ms="$5"
	local now_iso="$6"
	local account_id="${7:-}"
	PROVIDER="$provider" EMAIL="$email" \
		ACCESS="$access_token" REFRESH="$refresh_token" \
		EXPIRES="$expires_ms" NOW_ISO="$now_iso" ACCOUNT_ID="$account_id" \
		python3 "$POOL_OPS" upsert
	return 0
}

# Parse HTTP response (body + status) from curl -w '\n%{http_code}' output.
# Sets caller's 'http_status' and 'body' variables via stdout lines.
# Usage: parse_curl_response "$response" http_status_var body_var
# Prints: first line = status code, remaining lines = body
parse_curl_response() {
	local response="$1"
	printf '%s' "$response" | tail -1
	printf '%s' "$response" | sed '$d'
	return 0
}

# Extract a JSON error message from a token endpoint response body (stdin).
# Prints a human-readable error string (never a token value).
extract_token_error() {
	python3 "$POOL_OPS" extract-token-error 2>/dev/null || echo "unknown"
	return 0
}

# Exchange an OAuth authorization code for tokens via curl (body via stdin).
# Usage: _oauth_exchange_code "$token_endpoint" "$content_type" "$ua_header" "$token_body"
# Prints two lines: http_status, then body (JSON).
_oauth_exchange_code() {
	local token_endpoint="$1"
	local content_type="$2"
	local ua_header="$3"
	local token_body="$4"
	printf '%s' "$token_body" | curl -sS \
		-w '\n%{http_code}' \
		-X POST \
		-H "Content-Type: ${content_type}" \
		-H "User-Agent: ${ua_header}" \
		--data-binary @- \
		--max-time 15 \
		"$token_endpoint" 2>/dev/null
	return 0
}

# Extract access_token, refresh_token, expires_in from a JSON token response (stdin).
# Prints three lines: access_token, refresh_token, expires_in.
# Alignment note: Claude CLI's token response also contains 'scope' (space-delimited
# string) and optionally 'account' (object with uuid, email_address) and
# 'organization' (object with uuid). We ignore these — pool doesn't need them.
# DIAGNOSTIC: if debugging, parse the full response to inspect granted scopes:
#   d.get('scope', '').split()     — should include user:inference
#   d.get('account', {})           — account uuid + email
#   d.get('organization', {})      — org uuid (for team/enterprise)
_extract_token_fields() {
	python3 "$POOL_OPS" extract-token-fields 2>/dev/null
	return 0
}

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

# ---------------------------------------------------------------------------
# Check accounts — helpers
# ---------------------------------------------------------------------------

# Print formatted details for all accounts of a provider (stdin = pool JSON).
# Tests live token validity for anthropic and google via urllib (in-process).
# Usage: printf '%s' "$pool" | _check_print_provider_accounts "$prov" "$now_ms" "$ua"
# Print token expiry line for a single account.
# Args: expires_in (ms, may be negative)
_check_print_token_expiry() {
	local expires_in="$1"
	EXPIRES_IN="$expires_in" python3 "$POOL_OPS" check-expiry
	return 0
}

# Print status, cooldown, last-used, and refresh-token presence for one account.
# Reads account JSON from stdin; NOW_MS env var required.
_check_print_account_meta() {
	local now_ms="$1"
	NOW_MS="$now_ms" python3 "$POOL_OPS" check-meta
	return 0
}

# Perform a live HTTP validity check for a single token.
# Args: provider, expires_in (ms), access_token, user_agent
_check_validate_token() {
	local prov="$1"
	local expires_in="$2"
	local token="$3"
	local ua="$4"
	PROV="$prov" EXPIRES_IN="$expires_in" TOKEN="$token" UA="$ua" \
		python3 "$POOL_OPS" check-validate 2>/dev/null
	return 0
}

# Iterate all accounts for a provider and print a health summary.
# Pool JSON is read from stdin; args: provider, now_ms, user_agent.
_check_print_provider_accounts() {
	local prov="$1"
	local now_ms="$2"
	local ua="$3"
	local tmp_records
	tmp_records=$(mktemp)
	# Emit one JSON record per account (newline-delimited) to a temp file.
	NOW_MS="$now_ms" PROV="$prov" python3 "$POOL_OPS" check-accounts 2>/dev/null >"$tmp_records"
	while IFS= read -r record; do
		local email expires_in acc_json token
		email=$(printf '%s' "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)['email'])" 2>/dev/null)
		expires_in=$(printf '%s' "$record" | python3 -c "import sys,json; print(json.load(sys.stdin)['expires_in'])" 2>/dev/null)
		acc_json=$(printf '%s' "$record" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['account']))" 2>/dev/null)
		token=$(printf '%s' "$acc_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access',''))" 2>/dev/null)
		printf '  %s:\n' "$email"
		_check_print_token_expiry "$expires_in"
		printf '%s' "$acc_json" | _check_print_account_meta "$now_ms"
		_check_validate_token "$prov" "$expires_in" "$token" "$ua"
	done <"$tmp_records"
	rm -f "$tmp_records"
	return 0
}

# ---------------------------------------------------------------------------
# Check accounts
# ---------------------------------------------------------------------------

cmd_check() {
	local provider="${1:-all}"

	# Validate provider to prevent injection into python3 inline code
	case "$provider" in
	all | anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google, all)"
		return 1
		;;
	esac

	# Auto-clear expired cooldowns before reporting
	auto_clear_expired_cooldowns

	local pool
	pool=$(load_pool)

	local normalized updated
	normalized=$(printf '%s' "$pool" | normalize_expired_cooldowns "$provider")
	updated=$(printf '%s' "$normalized" | jq -r '.updated // 0')
	pool=$(printf '%s' "$normalized" | jq -c '.pool')
	if [[ "$updated" != "0" ]]; then
		save_pool "$pool"
		print_info "Auto-cleared ${updated} expired cooldown(s)."
	fi

	local -a providers_to_check
	if [[ "$provider" == "all" ]]; then
		providers_to_check=(anthropic openai cursor google)
	else
		providers_to_check=("$provider")
	fi

	local found_any="false"
	local now_ms
	now_ms=$(get_now_ms)

	for prov in "${providers_to_check[@]}"; do
		local count
		count=$(printf '%s' "$pool" | count_provider_accounts "$prov")
		if [[ "$count" == "0" ]]; then
			continue
		fi
		found_any="true"

		printf '\n## %s (%s account%s)\n' "$prov" "$count" "$([ "$count" = "1" ] && echo "" || echo "s")"
		printf '%s' "$pool" | _check_print_provider_accounts "$prov" "$now_ms" "$USER_AGENT"
		printf '  Token endpoint: OK\n'
	done

	if [[ "$found_any" == "false" ]]; then
		print_info "No accounts in any pool."
		echo ""
		echo "To add an account:"
		echo "  oauth-pool-helper.sh add anthropic    # Claude Pro/Max"
		echo "  oauth-pool-helper.sh add openai       # ChatGPT Plus/Pro (device flow default)"
		echo "  oauth-pool-helper.sh add cursor       # Cursor Pro (reads from IDE)"
		echo "  oauth-pool-helper.sh add google       # Google AI Pro/Ultra/Workspace"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# List accounts
# ---------------------------------------------------------------------------

cmd_list() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google, all)"
		return 1
		;;
	esac

	# Auto-clear expired cooldowns before reporting
	auto_clear_expired_cooldowns

	local pool
	pool=$(load_pool)

	local normalized updated
	normalized=$(printf '%s' "$pool" | normalize_expired_cooldowns "$provider")
	updated=$(printf '%s' "$normalized" | jq -r '.updated // 0')
	pool=$(printf '%s' "$normalized" | jq -c '.pool')
	if [[ "$updated" != "0" ]]; then
		save_pool "$pool"
		print_info "Auto-cleared ${updated} expired cooldown(s)."
	fi

	local -a providers_to_list
	if [[ "$provider" == "all" ]]; then
		providers_to_list=(anthropic openai cursor google)
	else
		providers_to_list=("$provider")
	fi

	for prov in "${providers_to_list[@]}"; do
		local count
		count=$(printf '%s' "$pool" | count_provider_accounts "$prov")
		if [[ "$count" == "0" ]]; then
			continue
		fi

		printf '%s (%s account%s):\n' "$prov" "$count" "$([ "$count" = "1" ] && echo "" || echo "s")"
		printf '%s' "$pool" | PROVIDER="$prov" python3 "$POOL_OPS" list-accounts
	done
	return 0
}

# ---------------------------------------------------------------------------
# Remove account
# ---------------------------------------------------------------------------

cmd_remove() {
	local provider="${1:-}"
	local email="${2:-}"

	if [[ -z "$provider" || -z "$email" ]]; then
		print_error "Usage: oauth-pool-helper.sh remove <provider> <email>"
		return 1
	fi

	local pool
	pool=$(load_pool)

	local new_pool
	new_pool=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" \
		python3 "$POOL_OPS" remove-account) || {
		print_error "Account ${email} not found in ${provider} pool"
		return 1
	}

	save_pool "$new_pool"
	print_success "Removed ${email} from ${provider} pool"
	return 0
}

# ---------------------------------------------------------------------------
# Rotate active account — helpers
# ---------------------------------------------------------------------------

# Core rotation logic: find next account, auto-refresh if expired, write
# auth.json and pool atomically under an advisory lock.
# All token handling stays in-process — no secrets on argv or stdout.
# Prints three lines to stdout: status (OK|ERROR:*), prev_email, next_email.
# Prints REFRESHED or REFRESH_FAILED:* to stderr (informational only).
_rotate_execute() {
	local provider="$1"
	POOL_FILE_PATH="$POOL_FILE" AUTH_FILE_PATH="$OPENCODE_AUTH_FILE" \
		PROVIDER="$provider" UA_HEADER="$USER_AGENT" \
		python3 "$POOL_OPS" rotate
	return 0
}

# Parse the result lines from _rotate_execute and emit user-facing messages.
# Returns 0 on success, 1 on error.
_rotate_parse_result() {
	local result="$1"
	local provider="$2"
	local first_line
	first_line=$(printf '%s\n' "$result" | sed -n '1p')
	case "$first_line" in
	ERROR:need_accounts)
		print_error "Cannot rotate: need at least 2 accounts in ${provider} pool"
		return 1
		;;
	ERROR:no_alternate)
		print_error "No alternate account available for ${provider} (all others may be in cooldown)"
		return 1
		;;
	OK_COOLDOWN:*)
		local wait_mins prev_email next_email
		wait_mins="${first_line#OK_COOLDOWN:}"
		prev_email=$(printf '%s\n' "$result" | sed -n '2p')
		next_email=$(printf '%s\n' "$result" | sed -n '3p')
		print_warning "All ${provider} accounts are rate-limited"
		if [[ "$prev_email" == "$next_email" ]]; then
			print_info "Staying on ${next_email} (shortest cooldown: ~${wait_mins}m remaining)"
		else
			print_info "Switched to ${next_email} (shortest cooldown: ~${wait_mins}m remaining)"
		fi
		return 0
		;;
	OK)
		local prev_email next_email
		prev_email=$(printf '%s\n' "$result" | sed -n '2p')
		next_email=$(printf '%s\n' "$result" | sed -n '3p')
		print_success "Rotated ${provider}: ${prev_email} -> ${next_email}"
		print_info "Restart OpenCode sessions to pick up the new credentials."
		return 0
		;;
	*)
		print_error "Unexpected result from rotation"
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# Rotate active account
# ---------------------------------------------------------------------------

cmd_rotate() {
	local provider="${1:-anthropic}"

	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google)"
		return 1
		;;
	esac

	# Auto-clear expired cooldowns so rotate sees all available accounts
	auto_clear_expired_cooldowns

	local pool
	pool=$(load_pool)

	local account_count
	account_count=$(printf '%s' "$pool" | count_provider_accounts "$provider")

	if [[ "$account_count" -lt 2 ]]; then
		print_error "Cannot rotate: only ${account_count} account(s) in ${provider} pool. Need at least 2."
		print_info "Add more accounts: oauth-pool-helper.sh add ${provider}"
		return 1
	fi

	if [[ ! -f "$OPENCODE_AUTH_FILE" ]]; then
		print_error "OpenCode auth file not found: ${OPENCODE_AUTH_FILE}"
		print_info "Is OpenCode installed? The auth file is created on first login."
		return 1
	fi

	local result py_stderr_file
	py_stderr_file=$(mktemp "${TMPDIR:-/tmp}/oauth-rotate-err.XXXXXX")
	result=$(_rotate_execute "$provider" 2>"$py_stderr_file") || {
		local py_err
		py_err=$(cat "$py_stderr_file" 2>/dev/null)
		rm -f "$py_stderr_file"
		print_error "Rotation failed — python3 error"
		if [[ -n "${py_err:-}" ]]; then
			print_error "Detail: ${py_err}"
		fi
		return 1
	}
	rm -f "$py_stderr_file"

	_rotate_parse_result "$result" "$provider"
	return $?
}

# ---------------------------------------------------------------------------
# Refresh — exchange refresh tokens for new access tokens
# ---------------------------------------------------------------------------

cmd_refresh() {
	local provider="${1:-anthropic}"
	local target_email="${2:-all}"

	case "$provider" in
	anthropic | openai | google) ;;
	cursor)
		print_info "Cursor tokens are long-lived and don't use refresh flow"
		return 0
		;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, google)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	# Refresh expired accounts that have refresh tokens
	local result
	result=$(POOL_FILE_PATH="$POOL_FILE" AUTH_FILE_PATH="$OPENCODE_AUTH_FILE" \
		PROVIDER="$provider" TARGET_EMAIL="$target_email" \
		UA_HEADER="$USER_AGENT" python3 "$POOL_OPS" refresh 2>/dev/null) || {
		print_error "Refresh failed — python3 error"
		return 1
	}

	# Parse results
	local had_refresh=false
	local had_failure=false
	while IFS= read -r line; do
		case "$line" in
		REFRESHED:*)
			had_refresh=true
			local email="${line#REFRESHED:}"
			print_success "Refreshed ${provider} token for ${email}"
			;;
		FAILED:*)
			had_failure=true
			local detail="${line#FAILED:}"
			print_error "Failed to refresh: ${detail}"
			;;
		NONE)
			print_info "No ${provider} accounts need refreshing"
			;;
		ERROR:no_endpoint)
			print_error "No token endpoint for provider: ${provider}"
			return 1
			;;
		esac
	done <<<"$result"

	if [[ "$had_refresh" == "true" ]]; then
		print_info "Restart OpenCode sessions to pick up refreshed credentials."
	fi
	if [[ "$had_failure" == "true" ]]; then
		print_warning "Some accounts failed to refresh — may need re-auth via: oauth-pool-helper.sh add ${provider}"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Reset cooldowns — clear rate-limit cooldowns so all accounts are retried
# ---------------------------------------------------------------------------

cmd_reset_cooldowns() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google, all)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	local result
	result=$(printf '%s' "$pool" | PROVIDER="$provider" python3 "$POOL_OPS" reset-cooldowns)

	local cleared new_pool
	cleared=$(printf '%s' "$result" | jq -r '.cleared')
	new_pool=$(printf '%s' "$result" | jq -c '.pool')

	save_pool "$new_pool"

	if [[ "$cleared" == "0" ]]; then
		print_info "No cooldowns to clear — all accounts already active."
	else
		print_success "Cleared cooldowns on ${cleared} account(s). All accounts set to idle."
	fi
	print_info "Restart OpenCode to pick up the reset state."
	return 0
}

# ---------------------------------------------------------------------------
# Set priority — set the priority field on an account
# ---------------------------------------------------------------------------

cmd_set_priority() {
	local provider="${1:-}"
	local email="${2:-}"
	local priority="${3:-}"

	if [[ -z "$provider" || -z "$email" || -z "$priority" ]]; then
		print_error "Usage: oauth-pool-helper.sh set-priority <provider> <email> <N>"
		print_info "  N is an integer; higher values are preferred during rotation."
		print_info "  Example: oauth-pool-helper.sh set-priority anthropic work@example.com 10"
		return 1
	fi

	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google)"
		return 1
		;;
	esac

	if ! [[ "$priority" =~ ^-?[0-9]+$ ]]; then
		print_error "Priority must be an integer (e.g. 0, 5, 10)"
		return 1
	fi

	local pool
	pool=$(load_pool)

	local new_pool
	new_pool=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" PRIORITY="$priority" \
		python3 "$POOL_OPS" set-priority 2>/dev/null)

	case "$new_pool" in
	ERROR:not_found)
		print_error "Account ${email} not found in ${provider} pool"
		print_info "Run 'oauth-pool-helper.sh list ${provider}' to see existing accounts"
		return 1
		;;
	esac

	save_pool "$new_pool"
	if [[ "$priority" == "0" ]]; then
		print_success "Cleared priority for ${email} in ${provider} pool (defaults to 0)"
	else
		print_success "Set priority ${priority} for ${email} in ${provider} pool"
	fi
	print_info "Higher priority accounts are preferred during rotation."
	return 0
}

# ---------------------------------------------------------------------------
# Mark current account failure state (for headless auto-rotation)
# ---------------------------------------------------------------------------

cmd_mark_failure() {
	local provider="${1:-}"
	local reason="${2:-rate_limit}"
	local retry_seconds="${3:-900}"

	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google)"
		return 1
		;;
	esac

	case "$reason" in
	rate_limit | auth_error | provider_error) ;;
	*)
		print_error "Invalid reason: $reason (valid: rate_limit, auth_error, provider_error)"
		return 1
		;;
	esac

	if [[ ! "$retry_seconds" =~ ^[0-9]+$ ]]; then
		print_error "retry_seconds must be an integer"
		return 1
	fi

	if [[ ! -f "$POOL_FILE" || ! -f "$OPENCODE_AUTH_FILE" ]]; then
		print_warning "Pool/auth file missing; skipping account failure mark"
		return 0
	fi

	local mark_result
	mark_result=$(POOL_FILE_PATH="$POOL_FILE" AUTH_FILE_PATH="$OPENCODE_AUTH_FILE" \
		PROVIDER="$provider" REASON="$reason" RETRY_SECONDS="$retry_seconds" \
		python3 "$POOL_OPS" mark-failure 2>/dev/null) || {
		print_warning "Failed to mark account failure state for ${provider}"
		return 1
	}

	case "$mark_result" in
	OK:*)
		print_info "Marked current ${provider} account as ${reason}"
		return 0
		;;
	SKIP:*)
		print_warning "No ${provider} accounts available to mark"
		return 0
		;;
	*)
		print_warning "Unexpected mark-failure result: ${mark_result}"
		return 1
		;;
	esac
}

# ---------------------------------------------------------------------------
# Status — pool aggregate stats per provider (distinct from list)
# ---------------------------------------------------------------------------

cmd_status() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google, all)"
		return 1
		;;
	esac

	# Auto-clear expired cooldowns before reporting
	auto_clear_expired_cooldowns

	local pool
	pool=$(load_pool)

	local normalized updated
	normalized=$(printf '%s' "$pool" | normalize_expired_cooldowns "$provider")
	updated=$(printf '%s' "$normalized" | jq -r '.updated // 0')
	pool=$(printf '%s' "$normalized" | jq -c '.pool')
	if [[ "$updated" != "0" ]]; then
		save_pool "$pool"
		print_info "Auto-cleared ${updated} expired cooldown(s)."
	fi

	local now_ms
	now_ms=$(python3 -c "import time; print(int(time.time() * 1000))")

	local -a providers_to_check
	if [[ "$provider" == "all" ]]; then
		providers_to_check=(anthropic openai cursor google)
	else
		providers_to_check=("$provider")
	fi

	local found_any="false"

	for prov in "${providers_to_check[@]}"; do
		local count
		count=$(printf '%s' "$pool" | count_provider_accounts "$prov")
		[[ "$count" == "0" ]] && continue
		found_any="true"

		printf '%s' "$pool" | NOW_MS="$now_ms" PROV="$prov" python3 "$POOL_OPS" status-stats 2>/dev/null
	done

	if [[ "$found_any" == "false" ]]; then
		print_info "No accounts in any pool."
		echo ""
		echo "Add an account:"
		echo "  aidevops model-accounts-pool add anthropic    # Claude Pro/Max"
		echo "  aidevops model-accounts-pool add openai       # ChatGPT Plus/Pro (device flow default)"
		echo "  aidevops model-accounts-pool add cursor       # Cursor Pro"
		echo "  aidevops model-accounts-pool add google       # Google AI Pro/Ultra/Workspace"
		echo "  aidevops model-accounts-pool import claude-cli"
	fi

	printf 'Pool file: %s\n' "$POOL_FILE"
	return 0
}

# ---------------------------------------------------------------------------
# Assign pending — assign a stranded _pending_ token to a named account
# ---------------------------------------------------------------------------

cmd_assign_pending() {
	local provider="${1:-anthropic}"
	local email="${2:-}"

	case "$provider" in
	anthropic | openai | cursor | google) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, google)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	# Check whether a pending token exists for this provider
	local pending_info
	pending_info=$(printf '%s' "$pool" | PROVIDER="$provider" python3 "$POOL_OPS" check-pending 2>/dev/null)

	if [[ "$pending_info" == "NONE" ]]; then
		print_info "No pending token for ${provider}."
		print_info "Pending tokens are created when OAuth completes but the email cannot be identified."
		print_info "If you recently re-authenticated and it didn't take effect, try:"
		print_info "  aidevops model-accounts-pool add ${provider}"
		return 0
	fi

	local pending_added
	pending_added=$(printf '%s' "$pending_info" | cut -d: -f2-)

	if [[ -z "$email" ]]; then
		print_info "Pending ${provider} token found (added: ${pending_added})"
		print_info "Existing accounts to assign to:"
		printf '%s' "$pool" | PROVIDER="$provider" python3 "$POOL_OPS" list-pending 2>/dev/null
		echo ""
		echo "Usage: aidevops model-accounts-pool assign-pending ${provider} <email>"
		return 0
	fi

	local new_pool
	new_pool=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" \
		python3 "$POOL_OPS" assign-pending 2>/dev/null)

	case "$new_pool" in
	ERROR:no_pending)
		print_error "No pending token for ${provider}"
		return 1
		;;
	ERROR:not_found)
		print_error "Account ${email} not found in ${provider} pool"
		print_info "Run 'aidevops model-accounts-pool list' to see existing accounts"
		return 1
		;;
	esac

	save_pool "$new_pool"
	print_success "Assigned pending token to ${email} in ${provider} pool — account is now active."
	print_info "Restart OpenCode to pick up the new credentials."
	return 0
}

# ---------------------------------------------------------------------------
# Import from Claude CLI
# ---------------------------------------------------------------------------

cmd_import() {
	local source="${1:-claude-cli}"

	if [[ "$source" != "claude-cli" ]]; then
		print_error "Unsupported import source: $source (supported: claude-cli)"
		return 1
	fi

	# Check if claude CLI is installed
	if ! command -v claude &>/dev/null; then
		print_error "Claude CLI not found in PATH"
		print_info "Install it from https://claude.ai/code or run: npm install -g @anthropic-ai/claude-code"
		return 1
	fi

	# Get auth status from Claude CLI
	print_info "Checking Claude CLI auth status..."
	local auth_json
	auth_json=$(claude auth status --json 2>/dev/null) || {
		print_error "Failed to get Claude CLI auth status"
		print_info "Run 'claude auth login' first to authenticate the CLI"
		return 1
	}

	# Parse auth status (use env vars to avoid secrets on argv)
	local logged_in email sub_type
	logged_in=$(printf '%s' "$auth_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('loggedIn', False))" 2>/dev/null)
	email=$(printf '%s' "$auth_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('email', ''))" 2>/dev/null)
	sub_type=$(printf '%s' "$auth_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('subscriptionType', ''))" 2>/dev/null)

	if [[ "$logged_in" != "True" ]]; then
		print_error "Claude CLI is not logged in"
		print_info "Run 'claude auth login' first, then retry this import"
		return 1
	fi

	if [[ -z "$email" || "$email" == "None" ]]; then
		print_error "Could not determine email from Claude CLI auth"
		return 1
	fi

	if [[ "$sub_type" != "pro" && "$sub_type" != "max" ]]; then
		print_warning "Claude CLI subscription type is '${sub_type}' (expected 'pro' or 'max')"
		print_info "OAuth pool models require a Claude Pro or Max subscription"
		printf 'Continue anyway? [y/N] ' >&2
		local confirm
		read -r confirm
		if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
			print_info "Aborted"
			return 0
		fi
	fi

	# Check if this email already exists in the anthropic pool
	local pool
	pool=$(load_pool)
	local already_exists
	already_exists=$(printf '%s' "$pool" | EMAIL="$email" python3 "$POOL_OPS" import-check 2>/dev/null)

	if [[ "$already_exists" == "yes" ]]; then
		print_info "Account ${email} already exists in the Anthropic pool"
		print_info "Use 'oauth-pool-helper.sh check anthropic' to verify token health"
		return 0
	fi

	# Account not in pool — guide user through OAuth to add it
	print_success "Found Claude ${sub_type} account: ${email}"
	print_info "Adding to Anthropic OAuth pool..."
	print_info ""
	print_info "This will open your browser to authorize the same account."
	print_info "Since you're already logged in to claude.ai, it should be quick."
	print_info ""

	# Run the standard add flow with the email pre-filled
	cmd_add "anthropic" "$email"
	return $?
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

cmd_help() {
	cat >&2 <<'HELP'
oauth-pool-helper.sh — Manage OAuth pool accounts from the shell

Preferred CLI (same commands, no path needed):
  aidevops model-accounts-pool <command>

Commands:
  add [anthropic|openai|cursor|google]            Add an account (OAuth; OpenAI defaults to device flow)
  add --no-open [provider]                        Print OAuth URL instead of opening browser
  check [anthropic|openai|cursor|google|all]      Health check: token expiry + live validity
  diagnose [anthropic]                            Full pipeline diagnostics (pool, plugin, CCH, runtime)
  list [anthropic|openai|cursor|google|all]       List accounts with per-account status
  status [anthropic|openai|cursor|google|all]     Pool aggregate stats (counts, availability)
  refresh [anthropic|openai|google] [email|all]   Refresh expired tokens without re-auth (uses refresh_token)
  rotate [anthropic|openai|cursor|google]         Switch to next available account NOW (auto-refreshes expired tokens)
  set-priority <provider> <email> <N>             Set rotation priority (higher N = preferred; 0 = default)
  mark-failure <provider> <reason> [retry_secs]   Mark current account cooldown/status from runtime failures
  reset-cooldowns [provider|all]                  Clear rate-limit cooldowns so all accounts retry
  assign-pending <provider> [email]               Assign a stranded pending token to an account
  remove <provider> <email>                       Remove an account from the pool
  import [claude-cli]                             Import account from Claude CLI auth

Global flags:
  --no-open                                       Print OAuth URL instead of opening browser

Quickstart (if you see "Key Missing", "invalid request data", or auth errors):
  aidevops model-accounts-pool diagnose          # 0. Full pipeline check (start here)
  aidevops model-accounts-pool status            # 1. See pool health at a glance
  aidevops model-accounts-pool check             # 2. Test token validity live
  aidevops model-accounts-pool rotate anthropic  # 3. Switch to next account if rate-limited
  aidevops model-accounts-pool reset-cooldowns   # 4. Clear cooldowns if all accounts stuck
  aidevops model-accounts-pool add anthropic     # 5. Re-add account if pool empty

Examples:
  oauth-pool-helper.sh add anthropic                      # Claude Pro/Max (browser OAuth)
  oauth-pool-helper.sh add --no-open anthropic             # Print URL instead of opening browser
  oauth-pool-helper.sh add openai                         # ChatGPT Plus/Pro (device flow default)
  oauth-pool-helper.sh add cursor                         # Cursor Pro (reads from IDE)
  oauth-pool-helper.sh add google                         # Google AI Pro/Ultra/Workspace (browser OAuth)
  oauth-pool-helper.sh import claude-cli                  # Import from Claude CLI auth
  oauth-pool-helper.sh check                              # Check all accounts
  oauth-pool-helper.sh list                               # List all accounts
  oauth-pool-helper.sh rotate anthropic                   # Switch to next Anthropic account
  oauth-pool-helper.sh rotate google                      # Switch to next Google account
  oauth-pool-helper.sh set-priority anthropic work@example.com 10  # Prefer work account
  oauth-pool-helper.sh set-priority anthropic work@example.com 0   # Clear priority (default)
  oauth-pool-helper.sh reset-cooldowns                    # Clear all cooldowns
  oauth-pool-helper.sh status                             # Show pool statistics
  oauth-pool-helper.sh remove anthropic user@example.com
  oauth-pool-helper.sh assign-pending anthropic           # Show pending token info
  oauth-pool-helper.sh assign-pending anthropic user@example.com  # Assign pending token

Notes:
  - Pool file: ~/.aidevops/oauth-pool.json (600 permissions)
  - Auth file: ~/.local/share/opencode/auth.json (written by rotate)
  - After adding/rotating an account, restart OpenCode to use the new token
  - Expired tokens auto-refresh on rotate; use 'refresh' to refresh manually
  - If refresh fails, re-auth with 'add' using the same email
  - The pool auto-rotates between accounts when one hits rate limits
  - Cursor reads credentials from your local Cursor IDE — log in there first
  - Google tokens are injected as GOOGLE_OAUTH_ACCESS_TOKEN (ADC bearer) for Gemini CLI / Vertex AI
  - Google requires AI Pro (~$25/mo), AI Ultra (~$65/mo), or Workspace with Gemini subscription
  - 'assign-pending' assigns tokens saved when email could not be identified during OAuth
  - 'import claude-cli' detects your Claude CLI account and pre-fills the email
HELP
	return 0
}

# ---------------------------------------------------------------------------
# Diagnose — full auth pipeline health check (GH#17746)
# ---------------------------------------------------------------------------
# Goes beyond `check` (which only validates tokens): tests the entire
# request pipeline that provider-auth.mjs uses, including plugin load
# detection, CCH billing header, auth.json state, and a real API probe.

# Print the result of a single diagnostic check.
# Usage: _diag_print "Check name" "PASS|WARN|FAIL|SKIP" "detail message"
_diag_print() {
	local name="$1" result="$2" detail="$3"
	case "$result" in
	PASS) printf '  \033[1m%-40s\033[0m \033[0;32mPASS\033[0m  %s\n' "$name" "$detail" ;;
	WARN) printf '  \033[1m%-40s\033[0m \033[1;33mWARN\033[0m  %s\n' "$name" "$detail" ;;
	FAIL) printf '  \033[1m%-40s\033[0m \033[0;31mFAIL\033[0m  %s\n' "$name" "$detail" ;;
	SKIP) printf '  \033[1m%-40s\033[0m \033[0;36mSKIP\033[0m  %s\n' "$name" "$detail" ;;
	esac
	return 0
}

# Check 1: Pool file exists and has accounts.
_diag_check_pool() {
	if [[ ! -f "$POOL_FILE" ]]; then
		_diag_print "Pool file" "FAIL" "Missing: $POOL_FILE — run 'aidevops model-accounts-pool add anthropic'"
		return 1
	fi
	local perms
	perms=$(stat -f '%Lp' "$POOL_FILE" 2>/dev/null || stat -c '%a' "$POOL_FILE" 2>/dev/null || echo "unknown")
	if [[ "$perms" != "600" ]]; then
		_diag_print "Pool file permissions" "WARN" "$perms (expected 600)"
	else
		_diag_print "Pool file permissions" "PASS" "600"
	fi
	local count
	count=$(jq '[.anthropic // [] | length] | add' "$POOL_FILE" 2>/dev/null || echo "0")
	if [[ "$count" == "0" ]]; then
		_diag_print "Anthropic accounts" "FAIL" "No accounts in pool — run 'aidevops model-accounts-pool add anthropic'"
		return 1
	fi
	_diag_print "Anthropic accounts" "PASS" "$count account(s)"
	return 0
}

# Check 2: OpenCode auth.json exists and has OAuth type.
_diag_check_auth_json() {
	if [[ ! -f "$OPENCODE_AUTH_FILE" ]]; then
		_diag_print "OpenCode auth.json" "WARN" "Missing: $OPENCODE_AUTH_FILE — plugin may create it on first run"
		return 0
	fi
	local auth_type
	auth_type=$(jq -r '.anthropic.type // "missing"' "$OPENCODE_AUTH_FILE" 2>/dev/null || echo "error")
	if [[ "$auth_type" == "oauth" ]]; then
		_diag_print "OpenCode auth.json" "PASS" "type=oauth"
	elif [[ "$auth_type" == "missing" ]]; then
		_diag_print "OpenCode auth.json" "WARN" "No anthropic entry — plugin hasn't injected yet"
	else
		_diag_print "OpenCode auth.json" "WARN" "type=$auth_type (expected oauth)"
	fi
	return 0
}

# Check 3: Plugin directory exists and has key files.
_diag_check_plugin() {
	local plugin_dir="$HOME/.aidevops/agents/plugins/opencode-aidevops"
	if [[ ! -d "$plugin_dir" ]]; then
		_diag_print "Plugin directory" "FAIL" "Missing: $plugin_dir — run 'aidevops update'"
		return 1
	fi
	local missing=""
	local -a key_files=(index.mjs provider-auth.mjs oauth-pool.mjs)
	local f
	for f in "${key_files[@]}"; do
		if [[ ! -f "$plugin_dir/$f" ]]; then
			missing="$missing $f"
		fi
	done
	if [[ -n "$missing" ]]; then
		_diag_print "Plugin files" "FAIL" "Missing:$missing"
		return 1
	fi
	_diag_print "Plugin files" "PASS" "index.mjs, provider-auth.mjs, oauth-pool.mjs"
	return 0
}

# Check 4: OpenCode config references the plugin.
_diag_check_plugin_registered() {
	local opencode_config="$HOME/.config/opencode/config.json"
	if [[ ! -f "$opencode_config" ]]; then
		# Try alternate locations
		opencode_config="$HOME/.config/opencode/opencode.json"
	fi
	if [[ ! -f "$opencode_config" ]]; then
		_diag_print "Plugin registration" "SKIP" "No OpenCode config found — may use in-memory config"
		return 0
	fi
	if grep -q "opencode-aidevops" "$opencode_config" 2>/dev/null; then
		_diag_print "Plugin registration" "PASS" "Found in $opencode_config"
	else
		_diag_print "Plugin registration" "WARN" "Not found in $opencode_config — plugin registers via config hook at runtime"
	fi
	return 0
}

# Check 5: CCH constants cache.
_diag_check_cch() {
	local cch_file="$HOME/.aidevops/cch-constants.json"
	if [[ ! -f "$cch_file" ]]; then
		_diag_print "CCH constants cache" "WARN" "Missing — billing header will use fallback defaults"
		return 0
	fi
	local cached_ver
	cached_ver=$(jq -r '.version // "unknown"' "$cch_file" 2>/dev/null || echo "error")
	_diag_print "CCH constants cache" "PASS" "version=$cached_ver"

	# Check if claude CLI is installed and if versions match
	if command -v claude &>/dev/null; then
		local live_ver
		live_ver=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		if [[ -n "$live_ver" ]]; then
			if [[ "$cached_ver" == "$live_ver" ]]; then
				_diag_print "CCH version match" "PASS" "cache=$cached_ver, cli=$live_ver"
			else
				_diag_print "CCH version match" "WARN" "cache=$cached_ver, cli=$live_ver — run 'aidevops client-format extract'"
			fi
		fi
	else
		_diag_print "Claude CLI" "WARN" "Not installed — CCH uses fallback constants (may cause 'invalid request data')"
	fi
	return 0
}

# Check 6: OpenCode version.
_diag_check_opencode_version() {
	if ! command -v opencode &>/dev/null; then
		_diag_print "OpenCode" "FAIL" "Not installed"
		return 1
	fi
	local ver
	ver=$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
	if [[ -z "$ver" ]]; then
		_diag_print "OpenCode version" "WARN" "Could not detect version"
		return 0
	fi
	# Check against tracked version in plugin package.json
	local tracked_ver=""
	local pkg_file="$HOME/.aidevops/agents/plugins/opencode-aidevops/package.json"
	if [[ -f "$pkg_file" ]]; then
		tracked_ver=$(jq -r '.opencode.tracked_version // ""' "$pkg_file" 2>/dev/null || echo "")
	fi
	if [[ -n "$tracked_ver" ]] && [[ "$ver" != "$tracked_ver" ]]; then
		_diag_print "OpenCode version" "WARN" "running=$ver, plugin tested=$tracked_ver — check changelog"
	else
		_diag_print "OpenCode version" "PASS" "$ver"
	fi
	return 0
}

# Check 7: Live token validity (same as cmd_check but single account).
_diag_check_live_token() {
	local pool
	pool=$(load_pool)
	local accounts
	accounts=$(printf '%s' "$pool" | jq -c '.anthropic // []' 2>/dev/null)
	local count
	count=$(printf '%s' "$accounts" | jq 'length' 2>/dev/null || echo "0")
	if [[ "$count" == "0" ]]; then
		_diag_print "Live token test" "SKIP" "No accounts to test"
		return 0
	fi
	# Test the first active/idle account
	local token email expires
	token=$(printf '%s' "$accounts" | jq -r '[ .[] | select(.status == "active" or .status == "idle") ] | .[0].access // ""' 2>/dev/null)
	email=$(printf '%s' "$accounts" | jq -r '[ .[] | select(.status == "active" or .status == "idle") ] | .[0].email // "unknown"' 2>/dev/null)
	expires=$(printf '%s' "$accounts" | jq -r '[ .[] | select(.status == "active" or .status == "idle") ] | .[0].expires // 0' 2>/dev/null)
	if [[ -z "$token" || "$token" == "null" ]]; then
		_diag_print "Live token test" "WARN" "No active/idle account with access token"
		return 0
	fi
	local now_ms
	now_ms=$(get_now_ms)
	if [[ "$expires" -le "$now_ms" ]]; then
		_diag_print "Token expiry ($email)" "WARN" "Expired — will auto-refresh on next use"
		return 0
	fi
	# Probe the models endpoint (same as check-validate)
	local http_status
	http_status=$(curl -s -o /dev/null -w '%{http_code}' \
		-H "Authorization: Bearer $token" \
		-H "User-Agent: $USER_AGENT" \
		-H "anthropic-version: 2023-06-01" \
		-H "anthropic-beta: oauth-2025-04-20" \
		"https://api.anthropic.com/v1/models" 2>/dev/null || echo "000")
	case "$http_status" in
	200) _diag_print "Live token test ($email)" "PASS" "HTTP 200 from /v1/models" ;;
	401) _diag_print "Live token test ($email)" "FAIL" "HTTP 401 — token invalid or revoked" ;;
	403) _diag_print "Live token test ($email)" "FAIL" "HTTP 403 — token lacks required scopes" ;;
	429) _diag_print "Live token test ($email)" "WARN" "HTTP 429 — rate limited (token is valid)" ;;
	000) _diag_print "Live token test ($email)" "FAIL" "Network error — cannot reach api.anthropic.com" ;;
	*) _diag_print "Live token test ($email)" "WARN" "HTTP $http_status — unexpected response" ;;
	esac
	return 0
}

# Check 8: Recent auth errors in observability DB.
_diag_check_recent_errors() {
	local db_path="$HOME/.aidevops/.agent-workspace/observability/llm-requests.db"
	if [[ ! -f "$db_path" ]]; then
		_diag_print "Recent auth errors" "SKIP" "No observability DB"
		return 0
	fi
	local error_count
	error_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM llm_requests WHERE error_type IS NOT NULL AND timestamp > datetime('now', '-1 hour');" 2>/dev/null || echo "0")
	if [[ "$error_count" -gt 0 ]]; then
		local last_error
		last_error=$(sqlite3 "$db_path" "SELECT error_type || ': ' || COALESCE(error_message, '(no message)') FROM llm_requests WHERE error_type IS NOT NULL ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null || echo "unknown")
		_diag_print "Recent errors (1h)" "WARN" "$error_count error(s), latest: $last_error"
	else
		_diag_print "Recent errors (1h)" "PASS" "No errors in last hour"
	fi
	return 0
}

cmd_diagnose() {
	local provider="${1:-anthropic}"
	echo ""
	printf '\033[1m=== OAuth Auth Pipeline Diagnostics ===\033[0m\n\n'
	printf 'Tests the full auth pipeline, not just token validity.\n'
	printf 'Share this output when reporting auth issues.\n\n'

	local has_failures=false

	printf '\033[0;36m--- Pool & Tokens ---\033[0m\n'
	_diag_check_pool || has_failures=true
	_diag_check_auth_json
	_diag_check_live_token

	printf '\n\033[0;36m--- Plugin & Runtime ---\033[0m\n'
	_diag_check_opencode_version
	_diag_check_plugin || has_failures=true
	_diag_check_plugin_registered

	printf '\n\033[0;36m--- Request Pipeline ---\033[0m\n'
	_diag_check_cch
	_diag_check_recent_errors

	echo ""
	if [[ "$has_failures" == "true" ]]; then
		print_error "Diagnostics found issues above. Fix FAIL items first."
	else
		print_success "No critical issues found."
		echo ""
		echo "If requests still fail, capture stderr logs:"
		echo "  opencode 2>~/opencode-debug.log"
		echo "  # Reproduce the error, then search for:"
		echo "  grep '\\[aidevops\\]' ~/opencode-debug.log"
	fi
	echo ""
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true

	# Parse global flags before command dispatch
	local args=()
	local arg
	for arg in "$@"; do
		case "$arg" in
		--no-open)
			OAUTH_NO_OPEN=true
			;;
		*)
			args+=("$arg")
			;;
		esac
	done

	case "$cmd" in
	add) cmd_add "${args[@]}" ;;
	assign-pending | assign_pending) cmd_assign_pending "${args[@]}" ;;
	check | test) cmd_check "${args[@]}" ;;
	diagnose) cmd_diagnose "${args[@]}" ;;
	import) cmd_import "${args[@]}" ;;
	list) cmd_list "${args[@]}" ;;
	mark-failure | mark_failure) cmd_mark_failure "${args[@]}" ;;
	refresh) cmd_refresh "${args[@]}" ;;
	rotate) cmd_rotate "${args[@]}" ;;
	reset-cooldowns | reset_cooldowns | reset) cmd_reset_cooldowns "${args[@]}" ;;
	remove) cmd_remove "${args[@]}" ;;
	set-priority | set_priority) cmd_set_priority "${args[@]}" ;;
	status) cmd_status "${args[@]}" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
