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
#
# Sub-libraries (sourced below):
#   oauth-pool-add.sh      — add account flows (anthropic, openai, cursor, google)
#   oauth-pool-manage.sh   — check/list/remove/rotate/refresh/status/etc.
#   oauth-pool-diagnose.sh — help text and full pipeline diagnostics

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

POOL_FILE="${HOME}/.aidevops/oauth-pool.json"
# t2249: XDG-aware auth path. Resolves to the isolated per-worker auth.json
# when called from a headless worker context (XDG_DATA_HOME set by
# headless-runtime-helper.sh invoke_opencode), and to the shared interactive
# file otherwise. This is what makes rotate safe for concurrent interactive +
# headless usage: rotation from a worker targets the worker's isolated file,
# never the shared interactive auth.json.
OPENCODE_AUTH_FILE="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/auth.json"

# Script directory — used to source sub-libraries and locate pool_ops.py
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Companion Python library for complex operations (extracted to reduce nesting depth)
POOL_OPS="${SCRIPT_DIR}/oauth-pool-lib/pool_ops.py"

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

# Open URL in browser (best-effort, never fatal — cascades on failure)
open_browser() {
	local url="$1"
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
# Sub-libraries
# ---------------------------------------------------------------------------

# shellcheck source=./oauth-pool-add.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/oauth-pool-add.sh"

# shellcheck source=./oauth-pool-manage.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/oauth-pool-manage.sh"

# shellcheck source=./oauth-pool-diagnose.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/oauth-pool-diagnose.sh"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	add) cmd_add "$@" ;;
	assign-pending | assign_pending) cmd_assign_pending "$@" ;;
	check | test) cmd_check "$@" ;;
	diagnose) cmd_diagnose "$@" ;;
	import) cmd_import "$@" ;;
	list) cmd_list "$@" ;;
	mark-failure | mark_failure) cmd_mark_failure "$@" ;;
	refresh) cmd_refresh "$@" ;;
	rotate) cmd_rotate "$@" ;;
	reset-cooldowns | reset_cooldowns | reset) cmd_reset_cooldowns "$@" ;;
	remove) cmd_remove "$@" ;;
	set-priority | set_priority) cmd_set_priority "$@" ;;
	status) cmd_status "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
