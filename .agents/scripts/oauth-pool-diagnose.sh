#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OAuth Pool Helper -- Help and Diagnostics Sub-Library
# =============================================================================
# Provides:
#   cmd_help     — usage text for all commands
#   cmd_diagnose — full auth pipeline health check (pool, plugin, CCH, runtime)
#
# Diagnostics go beyond cmd_check (token validity): tests the entire request
# pipeline that provider-auth.mjs uses, including plugin load detection, CCH
# billing header, auth.json state, and a real API probe.
#
# Usage: source "${SCRIPT_DIR}/oauth-pool-diagnose.sh"
#
# Dependencies:
#   - oauth-pool-helper.sh must be sourced first (provides POOL_FILE, POOL_OPS,
#     USER_AGENT, provider constants, and core helper functions)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_OAUTH_POOL_DIAGNOSE_LOADED:-}" ]] && return 0
_OAUTH_POOL_DIAGNOSE_LOADED=1

# SCRIPT_DIR fallback — for defensive portability (sub-library may be sourced
# by test harnesses that don't pre-set SCRIPT_DIR).
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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

Quickstart (if you see "Key Missing", "invalid request data", or auth errors):
  aidevops model-accounts-pool diagnose          # 0. Full pipeline check (start here)
  aidevops model-accounts-pool status            # 1. See pool health at a glance
  aidevops model-accounts-pool check             # 2. Test token validity live
  aidevops model-accounts-pool rotate anthropic  # 3. Switch to next account if rate-limited
  aidevops model-accounts-pool reset-cooldowns   # 4. Clear cooldowns if all accounts stuck
  aidevops model-accounts-pool add anthropic     # 5. Re-add account if pool empty

Examples:
  oauth-pool-helper.sh add anthropic                      # Claude Pro/Max (browser OAuth)
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
  - Auth file override: set XDG_DATA_HOME=<dir> to rotate
    $XDG_DATA_HOME/opencode/auth.json instead. Used by headless workers
    so per-worker rotation cannot corrupt the interactive session auth (t2249).
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
	perms=$(_file_perms "$POOL_FILE")
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
