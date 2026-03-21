#!/usr/bin/env bash
# oauth-pool-helper.sh — Shell-based OAuth pool account management
#
# Provides add/check/list/remove for OAuth pool accounts when the OpenCode
# TUI auth hooks are unavailable (e.g., OpenCode v1.2.27 regression).
#
# Usage:
#   oauth-pool-helper.sh add [anthropic|openai]    # Add account via OAuth
#   oauth-pool-helper.sh check [anthropic|openai]   # Health check all accounts
#   oauth-pool-helper.sh list [anthropic|openai]     # List accounts
#   oauth-pool-helper.sh remove <provider> <email>   # Remove an account
#   oauth-pool-helper.sh help                        # Show usage
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
	local opened="false"
	if command -v open &>/dev/null; then
		open "$url" 2>/dev/null && opened="true"
	fi
	if [[ "$opened" == "false" ]] && command -v xdg-open &>/dev/null; then
		xdg-open "$url" 2>/dev/null && opened="true"
	fi
	if [[ "$opened" == "false" ]] && command -v wslview &>/dev/null; then
		wslview "$url" 2>/dev/null && opened="true"
	fi
	if [[ "$opened" == "false" ]]; then
		print_warning "Cannot open browser automatically."
	fi
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

	if [[ "$provider" != "anthropic" && "$provider" != "openai" ]]; then
		print_error "Unsupported provider: $provider (supported: anthropic, openai)"
		return 1
	fi

	# Prompt for email
	printf 'Account email: ' >&2
	local email
	read -r email
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
		# characters that break printf-based JSON construction)
		token_body=$(CODE="$code" CLIENT_ID="$client_id" REDIR="$redirect_uri" \
			VERIFIER="$verifier" python3 -c "
import json, os
print(json.dumps({
    'code': os.environ['CODE'],
    'grant_type': 'authorization_code',
    'client_id': os.environ['CLIENT_ID'],
    'redirect_uri': os.environ['REDIR'],
    'code_verifier': os.environ['VERIFIER'],
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
		# Show error message but NOT any token values
		local error_msg
		error_msg=$(printf '%s' "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error','unknown'))" 2>/dev/null || echo "unknown")
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
	now_ms=$(python3 -c "import time; print(int(time.time() * 1000))")
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
	count=$(printf '%s' "$pool" | PROVIDER="$provider" python3 -c "import sys,json,os; print(len(json.load(sys.stdin).get(os.environ['PROVIDER'],[])))")

	print_success "Added ${email} to ${provider} pool (${count} account(s) total)"
	print_info "Restart OpenCode to use the new token."
	print_info "Then switch to the '${provider^}' provider and select a model to start chatting."
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
	now_ms=$(python3 -c "import time; print(int(time.time() * 1000))")

	for prov in "${providers_to_check[@]}"; do
		local count
		count=$(printf '%s' "$pool" | PROVIDER="$prov" python3 -c "import sys,json,os; print(len(json.load(sys.stdin).get(os.environ['PROVIDER'],[])))" 2>/dev/null || echo "0")
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
		count=$(printf '%s' "$pool" | PROVIDER="$prov" python3 -c "import sys,json,os; print(len(json.load(sys.stdin).get(os.environ['PROVIDER'],[])))" 2>/dev/null || echo "0")
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
# Help
# ---------------------------------------------------------------------------

cmd_help() {
	cat >&2 <<'HELP'
oauth-pool-helper.sh — Manage OAuth pool accounts from the shell

Commands:
  add [anthropic|openai]       Add an account via OAuth browser flow
  check [anthropic|openai|all] Health check accounts (token expiry, validity)
  list [anthropic|openai|all]  List accounts and their status
  remove <provider> <email>    Remove an account from the pool

Examples:
  oauth-pool-helper.sh add anthropic       # Add a Claude Pro/Max account
  oauth-pool-helper.sh add openai          # Add a ChatGPT Plus/Pro account
  oauth-pool-helper.sh check               # Check all accounts
  oauth-pool-helper.sh list anthropic      # List Anthropic accounts
  oauth-pool-helper.sh remove anthropic user@example.com

Notes:
  - Pool file: ~/.aidevops/oauth-pool.json (600 permissions)
  - After adding an account, restart OpenCode to use the new token
  - Tokens refresh automatically; use 'add' with the same email to re-auth
  - The pool auto-rotates between accounts when one hits rate limits
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
	check) cmd_check "$@" ;;
	list) cmd_list "$@" ;;
	remove) cmd_remove "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
