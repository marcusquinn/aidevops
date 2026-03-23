#!/usr/bin/env bash
# oauth-pool-helper.sh — Shell-based OAuth pool account management
#
# Provides add/check/list/remove/rotate/status/assign-pending for OAuth pool
# accounts when the OpenCode TUI auth hooks are unavailable.
#
# Usage:
#   oauth-pool-helper.sh add [anthropic|openai|cursor]           # Add account via OAuth
#   oauth-pool-helper.sh check [anthropic|openai|cursor|all]     # Health check all accounts
#   oauth-pool-helper.sh list [anthropic|openai|cursor|all]      # List accounts
#   oauth-pool-helper.sh remove <provider> <email>               # Remove an account
#   oauth-pool-helper.sh rotate [anthropic|openai|cursor]        # Switch active account
#   oauth-pool-helper.sh status [anthropic|openai|cursor|all]    # Pool rotation statistics
#   oauth-pool-helper.sh assign-pending <provider> [email]       # Assign pending token
#   oauth-pool-helper.sh help                                    # Show usage
#
# Security: Tokens are written to ~/.aidevops/oauth-pool.json (600 perms).
#           Secrets are passed via stdin/env, never as command arguments.
#           No token values are printed to stdout/stderr.

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

POOL_FILE="${HOME}/.aidevops/oauth-pool.json"
OPENCODE_AUTH_FILE="${HOME}/.local/share/opencode/auth.json"

# Anthropic OAuth
ANTHROPIC_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
ANTHROPIC_TOKEN_ENDPOINT="https://platform.claude.com/v1/oauth/token"
ANTHROPIC_AUTHORIZE_URL="https://claude.ai/oauth/authorize"
ANTHROPIC_REDIRECT_URI="https://console.anthropic.com/oauth/code/callback"
ANTHROPIC_SCOPES="org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

# OpenAI OAuth
OPENAI_CLIENT_ID="app_EMoamEEZ73f0CkXaXp7hrann"
OPENAI_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token"
OPENAI_AUTHORIZE_URL="https://auth.openai.com/oauth/authorize"
OPENAI_REDIRECT_URI="http://localhost:1455/auth/callback"
OPENAI_SCOPES="openid profile email offline_access"

# User-Agent (detect Claude CLI version)
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

# Load pool JSON (create if missing)
load_pool() {
	if [[ -f "$POOL_FILE" ]]; then
		cat "$POOL_FILE"
	else
		echo '{}'
	fi
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

# ---------------------------------------------------------------------------
# Add account
# ---------------------------------------------------------------------------

cmd_add() {
	local provider="${1:-anthropic}"
	local prefill_email="${2:-}"

	if [[ "$provider" != "anthropic" && "$provider" != "openai" && "$provider" != "cursor" ]]; then
		print_error "Unsupported provider: $provider (supported: anthropic, openai, cursor)"
		return 1
	fi

	# Cursor uses a different flow — read from local IDE installation
	if [[ "$provider" == "cursor" ]]; then
		cmd_add_cursor
		return $?
	fi

	# Prompt for email (pre-filled if provided, e.g. from import)
	local email
	if [[ -n "$prefill_email" ]]; then
		email="$prefill_email"
		print_info "Using email: ${email}"
	else
		printf 'Account email: ' >&2
		read -r email
	fi
	if [[ -z "$email" || "$email" != *@* ]]; then
		print_error "Invalid email address"
		return 1
	fi

	# Generate PKCE + separate state nonce (verifier must not double as state)
	local verifier challenge state_nonce
	verifier=$(generate_verifier)
	challenge=$(generate_challenge "$verifier")
	state_nonce=$(openssl rand -hex 24)

	# Build authorize URL
	local authorize_url client_id redirect_uri scopes
	if [[ "$provider" == "anthropic" ]]; then
		client_id="$ANTHROPIC_CLIENT_ID"
		authorize_url="$ANTHROPIC_AUTHORIZE_URL"
		redirect_uri="$ANTHROPIC_REDIRECT_URI"
		scopes="$ANTHROPIC_SCOPES"
	else
		client_id="$OPENAI_CLIENT_ID"
		authorize_url="$OPENAI_AUTHORIZE_URL"
		redirect_uri="$OPENAI_REDIRECT_URI"
		scopes="$OPENAI_SCOPES"
	fi

	local encoded_scopes encoded_redirect
	encoded_scopes=$(urlencode "$scopes")
	encoded_redirect=$(urlencode "$redirect_uri")

	local full_url="${authorize_url}?client_id=${client_id}&response_type=code&redirect_uri=${encoded_redirect}&scope=${encoded_scopes}&code_challenge=${challenge}&code_challenge_method=S256&state=${state_nonce}"

	if [[ "$provider" == "anthropic" ]]; then
		full_url="${full_url}&code=true"
	fi

	print_info "Opening browser for ${provider} OAuth..."
	open_browser "$full_url"

	# Wait for authorization code
	printf 'Paste the authorization code here: ' >&2
	local auth_code
	read -r auth_code
	if [[ -z "$auth_code" ]]; then
		print_error "No authorization code provided"
		return 1
	fi

	# Strip fragment if present (code#state format) and validate state
	local code returned_state
	if [[ "$auth_code" == *"#"* ]]; then
		code="${auth_code%%#*}"
		returned_state="${auth_code#*#}"
		if [[ "$returned_state" != "$state_nonce" ]]; then
			print_error "State mismatch — possible CSRF. Expected ${state_nonce}, got ${returned_state}"
			return 1
		fi
	else
		code="$auth_code"
	fi

	# Exchange code for tokens
	print_info "Exchanging authorization code for tokens..."

	local token_endpoint token_body content_type ua_header
	if [[ "$provider" == "anthropic" ]]; then
		token_endpoint="$ANTHROPIC_TOKEN_ENDPOINT"
		content_type="application/json"
		ua_header="$USER_AGENT"
		# Build JSON via Python to safely encode the auth code (may contain
		# characters that break printf-based JSON construction).
		# The 'state' field is required by Anthropic's token endpoint as of
		# Claude CLI v2.1.x — omitting it causes HTTP 400 "Invalid request format".
		token_body=$(CODE="$code" CLIENT_ID="$client_id" REDIR="$redirect_uri" \
			VERIFIER="$verifier" STATE="$state_nonce" python3 -c "
import json, os
print(json.dumps({
    'code': os.environ['CODE'],
    'grant_type': 'authorization_code',
    'client_id': os.environ['CLIENT_ID'],
    'redirect_uri': os.environ['REDIR'],
    'code_verifier': os.environ['VERIFIER'],
    'state': os.environ['STATE'],
}))")
	else
		token_endpoint="$OPENAI_TOKEN_ENDPOINT"
		content_type="application/x-www-form-urlencoded"
		ua_header="opencode/1.2.27"
		local encoded_code
		encoded_code=$(urlencode "$code")
		token_body="code=${encoded_code}&grant_type=authorization_code&client_id=${client_id}&redirect_uri=$(urlencode "$redirect_uri")&code_verifier=${verifier}"
	fi

	# Use curl with stdin for body (keeps secrets off argv)
	local response http_status
	response=$(printf '%s' "$token_body" | curl -sS \
		-w '\n%{http_code}' \
		-X POST \
		-H "Content-Type: ${content_type}" \
		-H "User-Agent: ${ua_header}" \
		--data-binary @- \
		--max-time 15 \
		"$token_endpoint" 2>/dev/null) || {
		print_error "curl failed"
		return 1
	}

	# Parse response — last line is HTTP status
	http_status=$(printf '%s' "$response" | tail -1)
	local body
	body=$(printf '%s' "$response" | sed '$d')

	if [[ "$http_status" != "200" ]]; then
		print_error "Token exchange failed: HTTP ${http_status}"
		# Show error details but NOT any token values
		# Anthropic returns {type, message}, OpenAI returns {error, error_description}
		local error_msg
		error_msg=$(printf '%s' "$body" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    parts = []
    for k in ('type', 'error', 'message', 'error_description'):
        if k in d and d[k]:
            parts.append(str(d[k]))
    print(': '.join(parts) if parts else 'unknown')
except: print('unknown')
" 2>/dev/null || echo "unknown")
		print_error "Error: ${error_msg}"
		return 1
	fi

	# Extract tokens using python3 (jq alternative that's always available on macOS)
	local access_token refresh_token expires_in
	access_token=$(printf '%s' "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
	refresh_token=$(printf '%s' "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('refresh_token',''))" 2>/dev/null)
	expires_in=$(printf '%s' "$body" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires_in',3600))" 2>/dev/null)

	if [[ -z "$access_token" ]]; then
		print_error "No access token in response"
		return 1
	fi

	# Calculate expiry timestamp (milliseconds)
	local now_ms expires_ms
	now_ms=$(get_now_ms)
	expires_ms=$((now_ms + expires_in * 1000))

	# Upsert into pool file
	local pool
	pool=$(load_pool)

	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Use python3 for JSON manipulation (handles escaping correctly)
	pool=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" \
		ACCESS="$access_token" REFRESH="$refresh_token" \
		EXPIRES="$expires_ms" NOW_ISO="$now_iso" \
		python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
provider = os.environ['PROVIDER']
email = os.environ['EMAIL']
access = os.environ['ACCESS']
refresh = os.environ['REFRESH']
expires = int(os.environ['EXPIRES'])
now_iso = os.environ['NOW_ISO']

if provider not in pool:
    pool[provider] = []

# Find existing account by email
found = False
for account in pool[provider]:
    if account.get('email') == email:
        account['access'] = access
        account['refresh'] = refresh
        account['expires'] = expires
        account['lastUsed'] = now_iso
        account['status'] = 'active'
        account['cooldownUntil'] = None
        found = True
        break

if not found:
    pool[provider].append({
        'email': email,
        'access': access,
        'refresh': refresh,
        'expires': expires,
        'added': now_iso,
        'lastUsed': now_iso,
        'status': 'active',
        'cooldownUntil': None,
    })

json.dump(pool, sys.stdout, indent=2)
")

	save_pool "$pool"

	local count
	count=$(printf '%s' "$pool" | count_provider_accounts "$provider")

	print_success "Added ${email} to ${provider} pool (${count} account(s) total)"
	print_info "Restart OpenCode to use the new token."
	print_info "Then switch to the '${provider^}' provider and select a model to start chatting."
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

	local cursor_auth_json=""
	local cursor_state_db=""

	# Determine paths based on platform
	case "$(uname -s)" in
	Darwin)
		cursor_auth_json="${HOME}/.cursor/auth.json"
		cursor_state_db="${HOME}/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
		;;
	Linux)
		local config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}"
		cursor_auth_json="${config_dir}/cursor/auth.json"
		cursor_state_db="${HOME}/.config/Cursor/User/globalStorage/state.vscdb"
		;;
	MINGW* | MSYS* | CYGWIN*)
		local app_data="${APPDATA:-${HOME}/AppData/Roaming}"
		cursor_auth_json="${app_data}/Cursor/auth.json"
		cursor_state_db="${app_data}/Cursor/User/globalStorage/state.vscdb"
		;;
	*)
		print_error "Unsupported platform for Cursor: $(uname -s)"
		return 1
		;;
	esac

	local access_token=""
	local refresh_token=""
	local email=""

	# Source 1: cursor-agent auth.json
	if [[ -f "$cursor_auth_json" ]]; then
		print_info "Reading from Cursor auth.json..."
		local _at _rt _line _count
		_count=0
		while IFS= read -r _line; do
			_count=$((_count + 1))
			if [[ $_count -eq 1 ]]; then
				_at="$_line"
			elif [[ $_count -eq 2 ]]; then
				_rt="$_line"
			fi
		done < <(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('accessToken', ''))
    print(d.get('refreshToken', ''))
except Exception:
    print('')
    print('')
" "$cursor_auth_json" 2>/dev/null)
		access_token="${_at:-}"
		refresh_token="${_rt:-}"
	fi

	# Source 2: Cursor IDE state database (fallback or supplement)
	if [[ -z "$access_token" && -f "$cursor_state_db" ]]; then
		print_info "Reading from Cursor IDE state database..."
		if ! command -v sqlite3 &>/dev/null; then
			print_error "sqlite3 is required to read Cursor credentials but is not installed"
			return 1
		fi
		access_token=$(sqlite3 "$cursor_state_db" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'" 2>/dev/null || true)
		if [[ -z "$refresh_token" ]]; then
			refresh_token=$(sqlite3 "$cursor_state_db" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/refreshToken'" 2>/dev/null || true)
		fi
		if [[ -z "$email" ]]; then
			email=$(sqlite3 "$cursor_state_db" "SELECT value FROM ItemTable WHERE key = 'cursorAuth/cachedEmail'" 2>/dev/null || true)
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
	local jwt_email jwt_exp
	local _je _jx _jline _jcount
	_jcount=0
	while IFS= read -r _jline; do
		_jcount=$((_jcount + 1))
		if [[ $_jcount -eq 1 ]]; then
			_je="$_jline"
		elif [[ $_jcount -eq 2 ]]; then
			_jx="$_jline"
		fi
	done < <(ACCESS="$access_token" python3 -c "
import os, json, base64
token = os.environ['ACCESS']
parts = token.split('.')
if len(parts) >= 2:
    payload = parts[1] + '=' * (4 - len(parts[1]) % 4)
    try:
        data = json.loads(base64.urlsafe_b64decode(payload))
        print(data.get('email', ''))
        print(data.get('exp', 0))
    except Exception:
        print('')
        print(0)
else:
    print('')
    print(0)
" 2>/dev/null)
	jwt_email="${_je:-}"
	jwt_exp="${_jx:-0}"

	# Use JWT email if we didn't get one from the state DB
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
		# Default: 1 hour from now
		local now_ms
		now_ms=$(get_now_ms)
		expires_ms=$((now_ms + 3600000))
	fi

	# Upsert into pool file
	local pool now_iso
	pool=$(load_pool)
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	pool=$(printf '%s' "$pool" | PROVIDER="cursor" EMAIL="$email" \
		ACCESS="$access_token" REFRESH="${refresh_token:-}" \
		EXPIRES="$expires_ms" NOW_ISO="$now_iso" \
		python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
provider = os.environ['PROVIDER']
email = os.environ['EMAIL']
access = os.environ['ACCESS']
refresh = os.environ['REFRESH']
expires = int(os.environ['EXPIRES'])
now_iso = os.environ['NOW_ISO']

if provider not in pool:
    pool[provider] = []

found = False
for account in pool[provider]:
    if account.get('email') == email:
        account['access'] = access
        account['refresh'] = refresh
        account['expires'] = expires
        account['lastUsed'] = now_iso
        account['status'] = 'active'
        account['cooldownUntil'] = None
        found = True
        break

if not found:
    pool[provider].append({
        'email': email,
        'access': access,
        'refresh': refresh,
        'expires': expires,
        'added': now_iso,
        'lastUsed': now_iso,
        'status': 'active',
        'cooldownUntil': None,
    })

json.dump(pool, sys.stdout, indent=2)
")

	save_pool "$pool"

	local count
	count=$(printf '%s' "$pool" | count_provider_accounts "cursor")

	print_success "Added Cursor account ${email} to pool (${count} account(s) total)"
	print_info "Restart OpenCode to use the Cursor provider."
	return 0
}

# ---------------------------------------------------------------------------
# Check accounts
# ---------------------------------------------------------------------------

cmd_check() {
	local provider="${1:-all}"

	# Validate provider to prevent injection into python3 inline code
	case "$provider" in
	all | anthropic | openai | cursor) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, all)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	local -a providers_to_check
	if [[ "$provider" == "all" ]]; then
		providers_to_check=(anthropic openai cursor)
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

		# Single python3 pass: format details + test validity per account.
		# Validity probe uses urllib.request so the token stays in-process
		# and never appears on argv (unlike curl subprocess).
		printf '%s' "$pool" | NOW_MS="$now_ms" PROV="$prov" UA="$USER_AGENT" python3 -c "
import sys, json, os
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

pool = json.load(sys.stdin)
now = int(os.environ['NOW_MS'])
prov = os.environ['PROV']
ua = os.environ['UA']

for a in pool.get(prov, []):
    print(f\"  {a['email']}:\")
    expires_in = a.get('expires', 0) - now
    if expires_in <= 0:
        print(f\"    Token: EXPIRED\")
    else:
        mins = expires_in // 60000
        hours = mins // 60
        if hours > 0:
            print(f\"    Token: expires in {hours}h {mins % 60}m\")
        else:
            print(f\"    Token: expires in {mins}m\")
    print(f\"    Status: {a.get('status', 'unknown')}\")
    cd = a.get('cooldownUntil')
    if cd and cd > now:
        cd_mins = (cd - now + 59999) // 60000
        print(f\"    Cooldown: {cd_mins}m remaining\")
    lu = a.get('lastUsed')
    if lu:
        try:
            lu_ts = datetime.fromisoformat(lu.replace('Z','+00:00')).timestamp() * 1000
            ago = now - lu_ts
            ago_mins = int(ago // 60000)
            ago_hours = ago_mins // 60
            if ago_hours > 0:
                print(f\"    Last used: {ago_hours}h {ago_mins % 60}m ago\")
            else:
                print(f\"    Last used: {ago_mins}m ago\")
        except Exception:
            print(f\"    Last used: {lu}\")
    print(f\"    Refresh token: {'present' if a.get('refresh') else 'MISSING'}\")

    # Test token validity inline (anthropic only, in-process via urllib)
    if prov == 'anthropic':
        token = a.get('access', '')
        if not token:
            print(f\"    Validity: no access token\")
        elif expires_in <= 0:
            print(f\"    Validity: EXPIRED - will auto-refresh on next use\")
        else:
            try:
                req = Request('https://api.anthropic.com/v1/models', method='GET')
                req.add_header('Authorization', f'Bearer {token}')
                req.add_header('User-Agent', ua)
                req.add_header('anthropic-version', '2023-06-01')
                req.add_header('anthropic-beta', 'oauth-2025-04-20')
                urlopen(req, timeout=10)
                print(f\"    Validity: OK\")
            except HTTPError as e:
                if e.code == 401:
                    print(f\"    Validity: INVALID (401 - needs refresh)\")
                else:
                    print(f\"    Validity: HTTP {e.code}\")
            except (URLError, OSError):
                print(f\"    Validity: ERROR (network)\")
            except Exception:
                print(f\"    Validity: ERROR\")
" 2>/dev/null

		printf '  Token endpoint: OK\n'
	done

	if [[ "$found_any" == "false" ]]; then
		print_info "No accounts in any pool."
		echo ""
		echo "To add an account:"
		echo "  oauth-pool-helper.sh add anthropic    # Claude Pro/Max"
		echo "  oauth-pool-helper.sh add openai       # ChatGPT Plus/Pro"
		echo "  oauth-pool-helper.sh add cursor       # Cursor Pro (reads from IDE)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# List accounts
# ---------------------------------------------------------------------------

cmd_list() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, all)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	local -a providers_to_list
	if [[ "$provider" == "all" ]]; then
		providers_to_list=(anthropic openai cursor)
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
		printf '%s' "$pool" | PROVIDER="$prov" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
prov = os.environ['PROVIDER']
for i, a in enumerate(pool.get(prov, []), 1):
    status = a.get('status', 'unknown')
    email = a.get('email', 'unknown')
    print(f'  {i}. {email} [{status}]')
"
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
	new_pool=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
provider = os.environ['PROVIDER']
email = os.environ['EMAIL']

if provider not in pool:
    print(json.dumps(pool, indent=2))
    sys.exit(1)

original_count = len(pool[provider])
pool[provider] = [a for a in pool[provider] if a.get('email') != email]
new_count = len(pool[provider])

if original_count == new_count:
    print(json.dumps(pool, indent=2))
    sys.exit(1)

json.dump(pool, sys.stdout, indent=2)
") || {
		print_error "Account ${email} not found in ${provider} pool"
		return 1
	}

	save_pool "$new_pool"
	print_success "Removed ${email} from ${provider} pool"
	return 0
}

# ---------------------------------------------------------------------------
# Rotate active account
# ---------------------------------------------------------------------------

cmd_rotate() {
	local provider="${1:-anthropic}"

	case "$provider" in
	anthropic | openai | cursor) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	# Count accounts for this provider
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

	# Identify the current active account and rotate to the next one.
	# Uses python3 to:
	#   1. Read the current token from auth.json (access field under provider key)
	#   2. Find which pool account matches (by access token prefix comparison)
	#   3. Pick the next account that is NOT the current one
	#   4. Write the new account's tokens into auth.json
	#   5. Update lastUsed in the pool file
	# All token handling stays in-process — no secrets on argv or stdout.
	local result py_stderr_file
	py_stderr_file=$(mktemp "${TMPDIR:-/tmp}/oauth-rotate-err.XXXXXX")
	result=$(POOL_FILE_PATH="$POOL_FILE" AUTH_FILE_PATH="$OPENCODE_AUTH_FILE" \
		PROVIDER="$provider" python3 -c "
import sys, json, os, fcntl, tempfile
from datetime import datetime, timezone

pool_path = os.environ['POOL_FILE_PATH']
auth_path = os.environ['AUTH_FILE_PATH']
provider = os.environ['PROVIDER']

# Advisory lock on pool file to serialize concurrent rotations.
# Covers the full read-modify-write cycle for both pool and auth files.
lock_path = pool_path + '.lock'
lock_fd = open(lock_path, 'w')
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    # Load pool
    with open(pool_path) as f:
        pool = json.load(f)

    accounts = pool.get(provider, [])
    if len(accounts) < 2:
        print('ERROR:need_accounts')
        sys.exit(0)

    # Load auth.json
    with open(auth_path) as f:
        auth = json.load(f)

    # Get current access token from auth.json for this provider
    current_auth = auth.get(provider, {})
    current_access = current_auth.get('access', '')

    # Find which pool account is currently active by matching access token
    current_email = None
    for a in accounts:
        if a.get('access', '') == current_access and current_access:
            current_email = a.get('email', 'unknown')
            break

    # If no match by access token, fall back to most-recently-used
    if current_email is None:
        sorted_by_used = sorted(accounts, key=lambda a: a.get('lastUsed', ''), reverse=True)
        current_email = sorted_by_used[0].get('email', 'unknown')

    # Pick the next account: first available account that is NOT the current one
    # Prefer active/idle accounts, skip rate-limited or auth-error
    import time
    now_ms = int(time.time() * 1000)
    candidates = [
        a for a in accounts
        if a.get('email') != current_email
        and a.get('status', 'active') in ('active', 'idle')
        and (not a.get('cooldownUntil') or a['cooldownUntil'] <= now_ms)
    ]

    # If no active candidates, try any non-current account
    if not candidates:
        candidates = [a for a in accounts if a.get('email') != current_email]

    if not candidates:
        print('ERROR:no_alternate')
        sys.exit(0)

    # Sort by least-recently-used
    candidates.sort(key=lambda a: a.get('lastUsed', ''))
    next_account = candidates[0]
    next_email = next_account.get('email', 'unknown')

    # Auto-refresh expired tokens before writing to auth.json
    # If the selected account's access token is expired and it has a refresh
    # token, exchange it for a new access token via the token endpoint.
    next_expires = next_account.get('expires', 0)
    next_refresh = next_account.get('refresh', '')
    if next_expires and next_expires <= now_ms and next_refresh:
        import urllib.request, urllib.error
        token_urls = {
            'anthropic': 'https://platform.claude.com/v1/oauth/token',
            'openai': 'https://auth.openai.com/oauth/token',
        }
        client_ids = {
            'anthropic': '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
            'openai': 'app_EMoamEEZ73f0CkXaXp7hrann',
        }
        token_url = token_urls.get(provider, '')
        client_id = client_ids.get(provider, '')
        if token_url and client_id:
            refresh_body = json.dumps({
                'grant_type': 'refresh_token',
                'refresh_token': next_refresh,
                'client_id': client_id,
            }).encode('utf-8')
            req = urllib.request.Request(
                token_url,
                data=refresh_body,
                headers={
                    'Content-Type': 'application/json',
                    'User-Agent': os.environ.get('UA_HEADER', 'aidevops/1.0'),
                },
                method='POST',
            )
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    rdata = json.loads(resp.read().decode('utf-8'))
                new_access = rdata.get('access_token', '')
                new_refresh = rdata.get('refresh_token', next_refresh)
                new_expires_in = int(rdata.get('expires_in', 3600))
                new_expires_ms = now_ms + new_expires_in * 1000
                if new_access:
                    next_account['access'] = new_access
                    next_account['refresh'] = new_refresh
                    next_account['expires'] = new_expires_ms
                    next_account['status'] = 'active'
                    print('REFRESHED', file=sys.stderr)
            except (urllib.error.URLError, urllib.error.HTTPError) as e:
                # Refresh failed — write the expired token anyway; user will
                # see the error and can re-auth manually
                print(f'REFRESH_FAILED:{e}', file=sys.stderr)

    # Write the new account's tokens into auth.json (atomic: temp + os.replace)
    auth[provider] = {
        'type': current_auth.get('type', 'oauth'),
        'refresh': next_account.get('refresh', ''),
        'access': next_account.get('access', ''),
        'expires': next_account.get('expires', 0),
    }

    # Atomic write to auth.json (temp-file + rename)
    auth_dir = os.path.dirname(auth_path)
    fd_auth, tmp_auth = tempfile.mkstemp(dir=auth_dir, prefix='.auth-', suffix='.tmp')
    try:
        with os.fdopen(fd_auth, 'w') as f:
            json.dump(auth, f, indent=2)
        os.chmod(tmp_auth, 0o600)
        os.replace(tmp_auth, auth_path)
    except BaseException:
        try:
            os.unlink(tmp_auth)
        except OSError:
            pass
        raise

    # Update lastUsed in pool file for the new account (atomic: temp + os.replace)
    now_iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    for a in pool[provider]:
        if a.get('email') == next_email:
            a['lastUsed'] = now_iso
            break

    # Atomic write to pool file (temp-file + os.replace)
    pool_dir = os.path.dirname(pool_path)
    fd_pool, tmp_pool = tempfile.mkstemp(dir=pool_dir, prefix='.pool-', suffix='.tmp')
    try:
        with os.fdopen(fd_pool, 'w') as f:
            json.dump(pool, f, indent=2)
        os.chmod(tmp_pool, 0o600)
        os.replace(tmp_pool, pool_path)
    except BaseException:
        try:
            os.unlink(tmp_pool)
        except OSError:
            pass
        raise

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()

print('OK')
print(current_email)
print(next_email)
" 2>"$py_stderr_file") || {
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

	# Parse result — one field per line to avoid delimiter issues in emails
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
# Refresh — exchange refresh tokens for new access tokens
# ---------------------------------------------------------------------------

cmd_refresh() {
	local provider="${1:-anthropic}"
	local target_email="${2:-all}"

	case "$provider" in
	anthropic | openai) ;;
	cursor)
		print_info "Cursor tokens are long-lived and don't use refresh flow"
		return 0
		;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	# Refresh expired accounts that have refresh tokens
	local result
	result=$(POOL_FILE_PATH="$POOL_FILE" AUTH_FILE_PATH="$OPENCODE_AUTH_FILE" \
		PROVIDER="$provider" TARGET_EMAIL="$target_email" \
		UA_HEADER="$USER_AGENT" python3 -c "
import sys, json, os, fcntl, tempfile, urllib.request, urllib.error, time

pool_path = os.environ['POOL_FILE_PATH']
auth_path = os.environ['AUTH_FILE_PATH']
provider = os.environ['PROVIDER']
target_email = os.environ['TARGET_EMAIL']
ua_header = os.environ.get('UA_HEADER', 'aidevops/1.0')

token_urls = {
    'anthropic': 'https://platform.claude.com/v1/oauth/token',
    'openai': 'https://auth.openai.com/oauth/token',
}
client_ids = {
    'anthropic': '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
    'openai': 'app_EMoamEEZ73f0CkXaXp7hrann',
}

token_url = token_urls.get(provider, '')
client_id = client_ids.get(provider, '')
if not token_url or not client_id:
    print('ERROR:no_endpoint')
    sys.exit(0)

lock_path = pool_path + '.lock'
lock_fd = open(lock_path, 'w')
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    with open(pool_path) as f:
        pool = json.load(f)

    accounts = pool.get(provider, [])
    now_ms = int(time.time() * 1000)
    refreshed = []
    failed = []

    for acct in accounts:
        email = acct.get('email', 'unknown')
        if target_email != 'all' and email != target_email:
            continue

        refresh_tok = acct.get('refresh', '')
        expires = acct.get('expires', 0)

        if not refresh_tok:
            continue

        # Only refresh if expired or expiring within 1 hour (3600000ms)
        if expires and expires > now_ms + 3600000:
            continue

        body = json.dumps({
            'grant_type': 'refresh_token',
            'refresh_token': refresh_tok,
            'client_id': client_id,
        }).encode('utf-8')

        req = urllib.request.Request(
            token_url,
            data=body,
            headers={
                'Content-Type': 'application/json',
                'User-Agent': ua_header,
            },
            method='POST',
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                rdata = json.loads(resp.read().decode('utf-8'))
            new_access = rdata.get('access_token', '')
            new_refresh = rdata.get('refresh_token', refresh_tok)
            new_expires_in = int(rdata.get('expires_in', 3600))
            if new_access:
                acct['access'] = new_access
                acct['refresh'] = new_refresh
                acct['expires'] = now_ms + new_expires_in * 1000
                acct['status'] = 'active'
                refreshed.append(email)
            else:
                failed.append(email)
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            failed.append(f'{email}({e})')

    # Write updated pool
    if refreshed:
        pool_dir = os.path.dirname(pool_path)
        fd, tmp = tempfile.mkstemp(dir=pool_dir, prefix='.pool-', suffix='.tmp')
        try:
            with os.fdopen(fd, 'w') as f:
                json.dump(pool, f, indent=2)
            os.chmod(tmp, 0o600)
            os.replace(tmp, pool_path)
        except BaseException:
            try: os.unlink(tmp)
            except OSError: pass
            raise

        # Also update auth.json if the currently-active account was refreshed
        if os.path.exists(auth_path):
            with open(auth_path) as f:
                auth = json.load(f)
            current_access = auth.get(provider, {}).get('access', '')
            for acct in accounts:
                if acct.get('email') in refreshed:
                    # Check if this was the active account by old token match
                    # (the old token is gone now, so match by email in refreshed list
                    # and check if auth still has the expired token)
                    auth_expires = auth.get(provider, {}).get('expires', 0)
                    if auth_expires and auth_expires <= now_ms:
                        auth[provider] = {
                            'type': 'oauth',
                            'refresh': acct.get('refresh', ''),
                            'access': acct.get('access', ''),
                            'expires': acct.get('expires', 0),
                        }
                        auth_dir = os.path.dirname(auth_path)
                        fd2, tmp2 = tempfile.mkstemp(dir=auth_dir, prefix='.auth-', suffix='.tmp')
                        try:
                            with os.fdopen(fd2, 'w') as f:
                                json.dump(auth, f, indent=2)
                            os.chmod(tmp2, 0o600)
                            os.replace(tmp2, auth_path)
                        except BaseException:
                            try: os.unlink(tmp2)
                            except OSError: pass
                        break

finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()

for e in refreshed:
    print(f'REFRESHED:{e}')
for e in failed:
    print(f'FAILED:{e}')
if not refreshed and not failed:
    print('NONE')
" 2>/dev/null) || {
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
# Status (rotation statistics)
# ---------------------------------------------------------------------------

cmd_status() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, all)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	local -a providers_to_check
	if [[ "$provider" == "all" ]]; then
		providers_to_check=(anthropic openai cursor)
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

		printf '%s' "$pool" | NOW_MS="$now_ms" PROV="$prov" python3 -c "
import sys, json, os

pool = json.load(sys.stdin)
now = int(os.environ['NOW_MS'])
prov = os.environ['PROV']
accounts = pool.get(prov, [])

active = sum(1 for a in accounts if a.get('status') in ('active', 'idle'))
rate_limited = sum(1 for a in accounts if a.get('status') == 'rate-limited' and a.get('cooldownUntil', 0) > now)
auth_error = sum(1 for a in accounts if a.get('status') == 'auth-error')
available = sum(1 for a in accounts if a.get('status', 'active') in ('active', 'idle') and (not a.get('cooldownUntil') or a['cooldownUntil'] <= now))

print(f'{prov} pool status:')
print(f'  Total accounts: {len(accounts)}')
print(f'  Available now:  {available}')
print(f'  Active/idle:    {active}')
print(f'  Rate limited:   {rate_limited}')
print(f'  Auth errors:    {auth_error}')
" 2>/dev/null
	done

	if [[ "$found_any" == "false" ]]; then
		print_info "No accounts in any pool."
		echo ""
		echo "To add an account:"
		echo "  oauth-pool-helper.sh add anthropic    # Claude Pro/Max"
		echo "  oauth-pool-helper.sh add openai       # ChatGPT Plus/Pro"
		echo "  oauth-pool-helper.sh add cursor       # Cursor Pro (reads from IDE)"
	fi

	printf 'Pool file: %s\n' "$POOL_FILE"
	return 0
}

# ---------------------------------------------------------------------------
# Assign pending token to an account
# ---------------------------------------------------------------------------

cmd_assign_pending() {
	local provider="${1:-anthropic}"
	local email="${2:-}"

	case "$provider" in
	anthropic | openai | cursor) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	# Check if a pending token exists for this provider
	local pending_info
	pending_info=$(printf '%s' "$pool" | PROVIDER="$provider" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
provider = os.environ['PROVIDER']
pending_key = '_pending_' + provider
pending = pool.get(pending_key)
if pending:
    print('FOUND:' + pending.get('added', 'unknown'))
else:
    print('NONE')
" 2>/dev/null)

	if [[ "$pending_info" == "NONE" ]]; then
		print_info "No pending token for ${provider}."
		print_info "Pending tokens are created when you re-auth via the Pool provider but the email could not be identified."
		return 0
	fi

	local pending_added
	pending_added=$(printf '%s' "$pending_info" | cut -d: -f2-)

	if [[ -z "$email" ]]; then
		# Show available accounts and pending token info
		print_info "Pending ${provider} token found (added: ${pending_added})"
		print_info "Available accounts to assign to:"
		printf '%s' "$pool" | PROVIDER="$provider" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
provider = os.environ['PROVIDER']
for i, a in enumerate(pool.get(provider, []), 1):
    print(f'  {i}. {a[\"email\"]}')
" 2>/dev/null
		echo ""
		echo "Usage: oauth-pool-helper.sh assign-pending ${provider} <email>"
		return 0
	fi

	# Assign the pending token to the specified account
	local assign_result
	assign_result=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
provider = os.environ['PROVIDER']
email = os.environ['EMAIL']
pending_key = '_pending_' + provider
pending = pool.get(pending_key)

if not pending:
    print('ERROR:no_pending')
    sys.exit(0)

accounts = pool.get(provider, [])
idx = next((i for i, a in enumerate(accounts) if a.get('email') == email), -1)
if idx < 0:
    print('ERROR:not_found')
    sys.exit(0)

# Apply pending token fields to the account
accounts[idx]['refresh'] = pending.get('refresh', accounts[idx].get('refresh', ''))
accounts[idx]['access'] = pending.get('access', accounts[idx].get('access', ''))
accounts[idx]['expires'] = pending.get('expires', accounts[idx].get('expires', 0))
accounts[idx]['status'] = 'active'
accounts[idx]['cooldownUntil'] = None

# Remove pending entry
del pool[pending_key]
json.dump(pool, sys.stdout, indent=2)
" 2>/dev/null)

	if printf '%s' "$assign_result" | grep -q '^ERROR:no_pending$'; then
		print_error "No pending token for ${provider}"
		return 1
	fi
	if printf '%s' "$assign_result" | grep -q '^ERROR:not_found$'; then
		print_error "Account ${email} not found in ${provider} pool"
		return 1
	fi

	save_pool "$assign_result"
	print_success "Assigned pending token to ${email} in ${provider} pool. Token is now active."
	return 0
}

# ---------------------------------------------------------------------------
# Reset cooldowns — clear rate-limit cooldowns so all accounts are retried
# ---------------------------------------------------------------------------

cmd_reset_cooldowns() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, all)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	local result
	result=$(printf '%s' "$pool" | PROVIDER="$provider" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
target = os.environ['PROVIDER']
providers = list(pool.keys()) if target == 'all' else [target]
cleared = 0
for prov in providers:
    for a in pool.get(prov, []):
        if a.get('cooldownUntil') or a.get('status') in ('rate-limited', 'auth-error'):
            a['cooldownUntil'] = None
            a['status'] = 'idle'
            cleared += 1
json.dump({'cleared': cleared, 'pool': pool}, sys.stdout, indent=2)
")

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
# Status — pool aggregate stats per provider (distinct from list)
# ---------------------------------------------------------------------------

cmd_status() {
	local provider="${1:-all}"

	case "$provider" in
	all | anthropic | openai | cursor) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor, all)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	local now_ms
	now_ms=$(python3 -c "import time; print(int(time.time() * 1000))")

	local -a providers_to_check
	if [[ "$provider" == "all" ]]; then
		providers_to_check=(anthropic openai cursor)
	else
		providers_to_check=("$provider")
	fi

	local found_any="false"

	for prov in "${providers_to_check[@]}"; do
		local count
		count=$(printf '%s' "$pool" | count_provider_accounts "$prov")
		[[ "$count" == "0" ]] && continue
		found_any="true"

		printf '%s' "$pool" | NOW_MS="$now_ms" PROV="$prov" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
now = int(os.environ['NOW_MS'])
prov = os.environ['PROV']
accounts = pool.get(prov, [])

total      = len(accounts)
available  = sum(1 for a in accounts if not a.get('cooldownUntil') or a['cooldownUntil'] <= now)
active     = sum(1 for a in accounts if a.get('status') in ('active', 'idle'))
rate_lim   = sum(1 for a in accounts if a.get('status') == 'rate-limited' and a.get('cooldownUntil', 0) > now)
auth_err   = sum(1 for a in accounts if a.get('status') == 'auth-error')

print(f'{prov} pool:')
print(f'  Total accounts : {total}')
print(f'  Available now  : {available}')
print(f'  Active/idle    : {active}')
print(f'  Rate limited   : {rate_lim}')
print(f'  Auth errors    : {auth_err}')
if available == 0 and total > 0:
    print(f'  WARNING: no accounts available — run reset-cooldowns or add an account')
" 2>/dev/null
	done

	if [[ "$found_any" == "false" ]]; then
		print_info "No accounts in any pool."
		echo ""
		echo "Add an account:"
		echo "  aidevops model-accounts-pool add anthropic    # Claude Pro/Max"
		echo "  aidevops model-accounts-pool add openai       # ChatGPT Plus/Pro"
		echo "  aidevops model-accounts-pool add cursor       # Cursor Pro"
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
	anthropic | openai | cursor) ;;
	*)
		print_error "Invalid provider: $provider (valid: anthropic, openai, cursor)"
		return 1
		;;
	esac

	local pool
	pool=$(load_pool)

	# Check whether a pending token exists for this provider
	local pending_info
	pending_info=$(printf '%s' "$pool" | PROVIDER="$provider" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
provider = os.environ['PROVIDER']
pending = pool.get('_pending_' + provider)
if pending:
    print('FOUND:' + pending.get('added', 'unknown'))
else:
    print('NONE')
" 2>/dev/null)

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
		printf '%s' "$pool" | PROVIDER="$provider" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
provider = os.environ['PROVIDER']
for i, a in enumerate(pool.get(provider, []), 1):
    print(f'  {i}. {a[\"email\"]}')
" 2>/dev/null
		echo ""
		echo "Usage: aidevops model-accounts-pool assign-pending ${provider} <email>"
		return 0
	fi

	local new_pool
	new_pool=$(printf '%s' "$pool" | PROVIDER="$provider" EMAIL="$email" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
provider = os.environ['PROVIDER']
email = os.environ['EMAIL']
pending_key = '_pending_' + provider
pending = pool.get(pending_key)

if not pending:
    print('ERROR:no_pending')
    sys.exit(0)

accounts = pool.get(provider, [])
idx = next((i for i, a in enumerate(accounts) if a.get('email') == email), -1)
if idx < 0:
    print('ERROR:not_found')
    sys.exit(0)

accounts[idx]['refresh']      = pending.get('refresh', accounts[idx].get('refresh', ''))
accounts[idx]['access']       = pending.get('access',  accounts[idx].get('access', ''))
accounts[idx]['expires']      = pending.get('expires',  accounts[idx].get('expires', 0))
accounts[idx]['status']       = 'active'
accounts[idx]['cooldownUntil'] = None
del pool[pending_key]
json.dump(pool, sys.stdout, indent=2)
" 2>/dev/null)

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
	already_exists=$(printf '%s' "$pool" | EMAIL="$email" python3 -c "
import sys, json, os
pool = json.load(sys.stdin)
email = os.environ['EMAIL']
for acc in pool.get('anthropic', []):
    if acc.get('email') == email:
        print('yes')
        sys.exit(0)
print('no')
" 2>/dev/null)

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
  add [anthropic|openai|cursor]            Add an account (browser OAuth flow)
  check [anthropic|openai|cursor|all]      Health check: token expiry + live validity
  list [anthropic|openai|cursor|all]       List accounts with per-account status
  status [anthropic|openai|cursor|all]     Pool aggregate stats (counts, availability)
  refresh [anthropic|openai] [email|all]    Refresh expired tokens without re-auth (uses refresh_token)
  rotate [anthropic|openai|cursor]         Switch to next available account NOW (auto-refreshes expired tokens)
  reset-cooldowns [provider|all]           Clear rate-limit cooldowns so all accounts retry
  assign-pending <provider> [email]        Assign a stranded pending token to an account
  remove <provider> <email>               Remove an account from the pool
  import [claude-cli]                      Import account from Claude CLI auth

Quickstart (if you see "Key Missing" or auth errors):
  aidevops model-accounts-pool status            # 1. See pool health at a glance
  aidevops model-accounts-pool check             # 2. Test token validity live
  aidevops model-accounts-pool rotate anthropic  # 3. Switch to next account if rate-limited
  aidevops model-accounts-pool reset-cooldowns   # 4. Clear cooldowns if all accounts stuck
  aidevops model-accounts-pool add anthropic     # 5. Re-add account if pool empty

Examples:
  oauth-pool-helper.sh add anthropic                      # Claude Pro/Max (browser OAuth)
  oauth-pool-helper.sh add openai                         # ChatGPT Plus/Pro (browser OAuth)
  oauth-pool-helper.sh add cursor                         # Cursor Pro (reads from IDE)
  oauth-pool-helper.sh import claude-cli                  # Import from Claude CLI auth
  oauth-pool-helper.sh check                              # Check all accounts
  oauth-pool-helper.sh list                               # List all accounts
  oauth-pool-helper.sh rotate anthropic                   # Switch to next Anthropic account
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
  - 'assign-pending' assigns tokens saved when email could not be identified during OAuth
  - 'import claude-cli' detects your Claude CLI account and pre-fills the email
HELP
	return 0
}

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
	import) cmd_import "$@" ;;
	list) cmd_list "$@" ;;
	refresh) cmd_refresh "$@" ;;
	rotate) cmd_rotate "$@" ;;
	reset-cooldowns | reset_cooldowns | reset) cmd_reset_cooldowns "$@" ;;
	remove) cmd_remove "$@" ;;
	status) cmd_status "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
