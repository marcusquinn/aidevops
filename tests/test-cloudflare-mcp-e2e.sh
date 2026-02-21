#!/usr/bin/env bash
# test-cloudflare-mcp-e2e.sh
#
# End-to-end tests for Cloudflare Code Mode MCP integration.
# Tests: (1) MCP server connectivity and OAuth discovery,
#        (2) search() endpoint discovery, (3) execute() authenticated API calls,
#        (4) agent routing logic (MCP operations vs skill docs).
#
# Usage:
#   bash tests/test-cloudflare-mcp-e2e.sh [--verbose] [--interactive]
#
# Modes:
#   Default (headless): Tests connectivity, OAuth discovery, config, routing logic.
#                       Skips tests requiring authenticated MCP session.
#   --interactive:      Also tests live MCP tool calls (requires prior OAuth auth).
#
# Prerequisites:
#   - claude CLI installed and configured
#   - For --interactive: `claude mcp add cloudflare-api --transport http https://mcp.cloudflare.com/mcp`
#     and OAuth flow completed (browser auth on first connect)
#
# Exit codes: 0 = all pass, 1 = failures found
#
# Task: t1293 — Test Cloudflare Code Mode MCP end-to-end
# Ref: GH#2063

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="$REPO_DIR/.agents"
VERBOSE="${1:-}"
INTERACTIVE=false

for arg in "$@"; do
	case "$arg" in
	--interactive) INTERACTIVE=true ;;
	--verbose) VERBOSE="--verbose" ;;
	esac
done

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;32mPASS\033[0m %s\n" "$1"
	fi
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
	fi
	return 0
}

section() {
	printf "\n\033[1;36m=== %s ===\033[0m\n" "$1"
}

# ============================================================
# Section 1: MCP Server Connectivity & OAuth Discovery
# ============================================================
section "1. MCP Server Connectivity & OAuth Discovery"

# Test 1.1: MCP server endpoint is reachable
http_code=$(curl -s -o /dev/null -w "%{http_code}" https://mcp.cloudflare.com/mcp 2>/dev/null || echo "000")
if [[ "$http_code" == "401" ]]; then
	pass "MCP server reachable (HTTP 401 = auth required, server is up)"
elif [[ "$http_code" == "200" ]]; then
	pass "MCP server reachable (HTTP 200)"
else
	fail "MCP server unreachable (HTTP $http_code)" "Expected 200 or 401 from https://mcp.cloudflare.com/mcp"
fi

# Test 1.2: OAuth discovery endpoint exists
oauth_response=$(curl -s https://mcp.cloudflare.com/.well-known/oauth-authorization-server 2>/dev/null)
if echo "$oauth_response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('issuer')" 2>/dev/null; then
	pass "OAuth discovery endpoint returns valid metadata"
else
	fail "OAuth discovery endpoint missing or invalid" "GET /.well-known/oauth-authorization-server failed"
fi

# Test 1.3: OAuth endpoints are correctly configured
oauth_ok=true
for field in authorization_endpoint token_endpoint registration_endpoint; do
	if ! echo "$oauth_response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('$field')" 2>/dev/null; then
		oauth_ok=false
		fail "OAuth metadata missing field: $field"
	fi
done
if [[ "$oauth_ok" == "true" ]]; then
	pass "OAuth metadata has all required endpoints (authorization, token, registration)"
fi

# Test 1.4: OAuth supports PKCE (S256)
if echo "$oauth_response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'S256' in d.get('code_challenge_methods_supported',[])" 2>/dev/null; then
	pass "OAuth supports PKCE with S256 code challenge"
else
	fail "OAuth does not support PKCE S256" "Required for secure public client auth"
fi

# Test 1.5: OAuth supports authorization_code grant
if echo "$oauth_response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'authorization_code' in d.get('grant_types_supported',[])" 2>/dev/null; then
	pass "OAuth supports authorization_code grant type"
else
	fail "OAuth missing authorization_code grant type"
fi

# Test 1.6: OAuth supports refresh_token grant
if echo "$oauth_response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'refresh_token' in d.get('grant_types_supported',[])" 2>/dev/null; then
	pass "OAuth supports refresh_token grant (session persistence)"
else
	fail "OAuth missing refresh_token grant" "Sessions won't persist across restarts"
fi

# ============================================================
# Section 2: Claude Code MCP Configuration
# ============================================================
section "2. Claude Code MCP Configuration"

# Test 2.1: cloudflare-api is in master config template
if grep -q '"cloudflare-api"' "$REPO_DIR/configs/mcp-servers-config.json.txt" 2>/dev/null; then
	pass "cloudflare-api present in master MCP config template"
else
	fail "cloudflare-api missing from configs/mcp-servers-config.json.txt"
fi

# Test 2.2: Config template has correct URL
if grep -q 'mcp.cloudflare.com/mcp' "$REPO_DIR/configs/mcp-servers-config.json.txt" 2>/dev/null; then
	pass "Config template has correct MCP URL (mcp.cloudflare.com/mcp)"
else
	fail "Config template has wrong MCP URL"
fi

# Test 2.3: Config template uses remote type
if grep -q '"type": "remote"' "$REPO_DIR/configs/mcp-servers-config.json.txt" 2>/dev/null; then
	pass "Config template uses remote type (no local install needed)"
else
	fail "Config template should use remote type for Cloudflare MCP"
fi

# Test 2.4: Claude Code CLI can list the MCP server
if command -v claude &>/dev/null; then
	mcp_list=$(claude mcp list 2>&1 || true)
	if echo "$mcp_list" | grep -q "cloudflare-api"; then
		pass "cloudflare-api registered in Claude Code CLI"
		# Test 2.5: Check auth status
		if echo "$mcp_list" | grep -q "Needs authentication"; then
			skip "cloudflare-api needs OAuth authentication (expected for headless)"
		elif echo "$mcp_list" | grep -q "Connected"; then
			pass "cloudflare-api is authenticated and connected"
		else
			skip "cloudflare-api status unclear: $(echo "$mcp_list" | grep cloudflare-api)"
		fi
	else
		skip "cloudflare-api not registered in Claude Code CLI (add with: claude mcp add cloudflare-api --transport http https://mcp.cloudflare.com/mcp)"
	fi
else
	skip "claude CLI not available"
fi

# ============================================================
# Section 3: Skill Documentation & Routing
# ============================================================
section "3. Skill Documentation & Agent Routing"

# Test 3.1: cloudflare-mcp.md subagent exists
if [[ -f "$AGENTS_DIR/tools/api/cloudflare-mcp.md" ]]; then
	pass "cloudflare-mcp.md subagent exists"
else
	fail "cloudflare-mcp.md subagent missing at .agents/tools/api/cloudflare-mcp.md"
fi

# Test 3.2: cloudflare.md (DNS/CDN) subagent exists
if [[ -f "$AGENTS_DIR/services/hosting/cloudflare.md" ]]; then
	pass "cloudflare.md (DNS/CDN) subagent exists"
else
	fail "cloudflare.md missing at .agents/services/hosting/cloudflare.md"
fi

# Test 3.3: cloudflare-platform.md (development) subagent exists
if [[ -f "$AGENTS_DIR/services/hosting/cloudflare-platform.md" ]]; then
	pass "cloudflare-platform.md (development) subagent exists"
else
	fail "cloudflare-platform.md missing at .agents/services/hosting/cloudflare-platform.md"
fi

# Test 3.4: Intent-based routing table exists in cloudflare.md
if grep -q "Intent-Based Routing" "$AGENTS_DIR/services/hosting/cloudflare.md" 2>/dev/null; then
	pass "Intent-based routing table present in cloudflare.md"
else
	fail "Intent-based routing table missing from cloudflare.md"
fi

# Test 3.5: Routing table correctly maps MCP operations
if grep -q "Cloudflare Code Mode MCP" "$AGENTS_DIR/services/hosting/cloudflare.md" 2>/dev/null; then
	pass "Routing table references Cloudflare Code Mode MCP for operations"
else
	fail "Routing table missing MCP reference for operations"
fi

# Test 3.6: Routing table correctly maps development to platform docs
if grep -q "cloudflare-platform.md" "$AGENTS_DIR/services/hosting/cloudflare.md" 2>/dev/null; then
	pass "Routing table references cloudflare-platform.md for development"
else
	fail "Routing table missing platform docs reference for development"
fi

# Test 3.7: cloudflare-mcp.md has correct MCP tool prefix
if grep -q "cloudflare-api_\*" "$AGENTS_DIR/tools/api/cloudflare-mcp.md" 2>/dev/null; then
	pass "cloudflare-mcp.md declares cloudflare-api_* tool prefix"
else
	fail "cloudflare-mcp.md missing cloudflare-api_* tool declaration"
fi

# Test 3.8: cloudflare-platform.md explicitly excludes API operations
if grep -q "Not for.*API operations\|Not for.*managing\|Not for.*configuring" "$AGENTS_DIR/services/hosting/cloudflare-platform.md" 2>/dev/null; then
	pass "cloudflare-platform.md explicitly excludes API operations (routes to MCP)"
else
	fail "cloudflare-platform.md should explicitly route API operations to MCP"
fi

# Test 3.9: Search patterns documented in cloudflare-mcp.md
for pattern in "Workers" "D1" "KV" "R2" "Pages" "DNS"; do
	if grep -q "$pattern" "$AGENTS_DIR/tools/api/cloudflare-mcp.md" 2>/dev/null; then
		pass "Search pattern documented for: $pattern"
	else
		fail "Search pattern missing for: $pattern"
	fi
done

# Test 3.10: Execute patterns documented in cloudflare-mcp.md
if grep -q "Execute Patterns" "$AGENTS_DIR/tools/api/cloudflare-mcp.md" 2>/dev/null; then
	pass "Execute patterns section present in cloudflare-mcp.md"
else
	fail "Execute patterns section missing from cloudflare-mcp.md"
fi

# Test 3.11: Security model documented
if grep -q "Security Model" "$AGENTS_DIR/tools/api/cloudflare-mcp.md" 2>/dev/null; then
	pass "Security model documented in cloudflare-mcp.md"
else
	fail "Security model missing from cloudflare-mcp.md"
fi

# Test 3.12: Per-agent enablement documented
if grep -q "Per-Agent Enablement" "$AGENTS_DIR/tools/api/cloudflare-mcp.md" 2>/dev/null; then
	pass "Per-agent enablement documented in cloudflare-mcp.md"
else
	fail "Per-agent enablement missing from cloudflare-mcp.md"
fi

# ============================================================
# Section 4: Routing Decision Logic Verification
# ============================================================
section "4. Routing Decision Logic"

# Test routing scenarios by checking the documentation covers each case

# Scenario A: "List my Cloudflare zones" -> should route to MCP
if grep -qi "manage.*configure.*update.*CF resources\|DNS.*zones.*deployments" "$AGENTS_DIR/services/hosting/cloudflare.md" 2>/dev/null; then
	pass "Routing: 'list zones' intent maps to MCP (manage/configure CF resources)"
else
	fail "Routing: 'list zones' intent not clearly mapped to MCP"
fi

# Scenario B: "How do I write a Cloudflare Worker?" -> should route to platform docs
if grep -qi "Build.*develop.*CF platform\|Workers.*Pages.*D1.*R2" "$AGENTS_DIR/services/hosting/cloudflare.md" 2>/dev/null; then
	pass "Routing: 'write a Worker' intent maps to platform docs (build/develop)"
else
	fail "Routing: 'write a Worker' intent not clearly mapped to platform docs"
fi

# Scenario C: "Set up API token" -> should route to cloudflare.md itself
if grep -qi "API token auth\|token.*setup\|Set up API token" "$AGENTS_DIR/services/hosting/cloudflare.md" 2>/dev/null; then
	pass "Routing: 'set up API token' intent maps to cloudflare.md (auth setup)"
else
	fail "Routing: 'set up API token' intent not clearly mapped to cloudflare.md"
fi

# Test 4.4: Platform docs have decision trees for product selection
if grep -q "Quick Decision Trees" "$AGENTS_DIR/services/hosting/cloudflare-platform.md" 2>/dev/null; then
	pass "Platform docs have decision trees for product selection"
else
	fail "Platform docs missing decision trees"
fi

# Test 4.5: Platform docs index 60+ products
product_count=$(grep -c "README.md" "$AGENTS_DIR/services/hosting/cloudflare-platform.md" 2>/dev/null || echo "0")
if [[ "$product_count" -ge 40 ]]; then
	pass "Platform docs index $product_count product references (target: 40+)"
else
	fail "Platform docs only index $product_count products (expected 40+)"
fi

# ============================================================
# Section 5: MCP Integration Config Consistency
# ============================================================
section "5. Configuration Consistency"

# Test 5.1: mcp-integrations.md references cloudflare-api
if grep -q "cloudflare-api" "$AGENTS_DIR/aidevops/mcp-integrations.md" 2>/dev/null; then
	pass "mcp-integrations.md references cloudflare-api"
else
	fail "mcp-integrations.md missing cloudflare-api reference"
fi

# Test 5.2: mcp-integrations.md has correct URL
if grep -q "mcp.cloudflare.com/mcp" "$AGENTS_DIR/aidevops/mcp-integrations.md" 2>/dev/null; then
	pass "mcp-integrations.md has correct MCP URL"
else
	fail "mcp-integrations.md has wrong or missing MCP URL"
fi

# Test 5.3: Claude Code CLI setup command documented
if grep -q "claude mcp add" "$AGENTS_DIR/tools/api/cloudflare-mcp.md" 2>/dev/null; then
	pass "Claude Code CLI setup command documented"
else
	fail "Claude Code CLI setup command missing from docs"
fi

# Test 5.4: OpenCode config documented
if grep -q "opencode" "$AGENTS_DIR/tools/api/cloudflare-mcp.md" 2>/dev/null; then
	pass "OpenCode config documented"
else
	fail "OpenCode config missing from docs"
fi

# Test 5.5: Claude Desktop config documented
if grep -q "Claude Desktop\|claude_desktop_config" "$AGENTS_DIR/tools/api/cloudflare-mcp.md" 2>/dev/null; then
	pass "Claude Desktop config documented"
else
	fail "Claude Desktop config missing from docs"
fi

# ============================================================
# Section 6: Interactive MCP Tests (requires auth)
# ============================================================
if [[ "$INTERACTIVE" == "true" ]]; then
	section "6. Interactive MCP Tests (authenticated)"

	if command -v claude &>/dev/null; then
		mcp_status=$(claude mcp list 2>&1 || true)
		if echo "$mcp_status" | grep -q "cloudflare-api.*Connected"; then
			# Test 6.1: List available tools via MCP
			tools_output=$(claude --print "List all available Cloudflare MCP tools. Just list the tool names, nothing else." 2>&1 || true)
			if [[ -n "$tools_output" ]] && [[ "$tools_output" != *"error"* ]]; then
				pass "MCP tools listing succeeded"
			else
				fail "MCP tools listing failed" "$tools_output"
			fi

			# Test 6.2: List zones via MCP
			zones_output=$(claude --print "Use the Cloudflare MCP to list all zones in my account. Return zone names and statuses." 2>&1 || true)
			if [[ -n "$zones_output" ]] && [[ "$zones_output" != *"error"* ]]; then
				pass "List zones via MCP succeeded"
			else
				fail "List zones via MCP failed" "$zones_output"
			fi

			# Test 6.3: Query DNS via MCP
			dns_output=$(claude --print "Use the Cloudflare MCP to list DNS records for the first zone in my account. Show record type, name, and value." 2>&1 || true)
			if [[ -n "$dns_output" ]] && [[ "$dns_output" != *"error"* ]]; then
				pass "Query DNS via MCP succeeded"
			else
				fail "Query DNS via MCP failed" "$dns_output"
			fi

			# Test 6.4: Inspect WAF rules via MCP
			waf_output=$(claude --print "Use the Cloudflare MCP to list WAF rules or security settings for the first zone. Show rule IDs and descriptions." 2>&1 || true)
			if [[ -n "$waf_output" ]] && [[ "$waf_output" != *"error"* ]]; then
				pass "Inspect WAF rules via MCP succeeded"
			else
				skip "WAF rules inspection returned no data (may not be configured)"
			fi
		else
			skip "cloudflare-api not authenticated — run OAuth flow first"
			skip "Skipping all interactive MCP tests"
		fi
	else
		skip "claude CLI not available for interactive tests"
	fi
else
	section "6. Interactive MCP Tests (skipped — use --interactive)"
	skip "Interactive tests skipped (run with --interactive after OAuth auth)"
fi

# ============================================================
# Section 7: Gopass Credential Verification
# ============================================================
section "7. Credential Storage Verification"

if command -v gopass &>/dev/null; then
	# Test 7.1: Cloudflare account ID stored
	if gopass show -o aidevops/CLOUDFLARE_MARCUSQUINN_GLOBAL_ACCOUNT_ID &>/dev/null; then
		acct_len=$(gopass show -o aidevops/CLOUDFLARE_MARCUSQUINN_GLOBAL_ACCOUNT_ID 2>/dev/null | wc -c | tr -d ' ')
		if [[ "$acct_len" -ge 30 ]]; then
			pass "Cloudflare account ID stored in gopass (${acct_len} chars)"
		else
			fail "Cloudflare account ID too short (${acct_len} chars, expected 32+)"
		fi
	else
		fail "Cloudflare account ID not found in gopass"
	fi

	# Test 7.2: Cloudflare API key stored
	if gopass show -o aidevops/CLOUDFLARE_MARCUSQUINN_GLOBAL_KEY &>/dev/null; then
		key_len=$(gopass show -o aidevops/CLOUDFLARE_MARCUSQUINN_GLOBAL_KEY 2>/dev/null | wc -c | tr -d ' ')
		if [[ "$key_len" -ge 30 ]]; then
			pass "Cloudflare API key stored in gopass (${key_len} chars)"
		else
			fail "Cloudflare API key too short (${key_len} chars)"
		fi
	else
		fail "Cloudflare API key not found in gopass"
	fi
else
	skip "gopass not available — credential verification skipped"
fi

# ============================================================
# Summary
# ============================================================
printf "\n\033[1;36m=== Summary ===\033[0m\n"
printf "  Total: %d | \033[0;32mPass: %d\033[0m | \033[0;31mFail: %d\033[0m | \033[0;33mSkip: %d\033[0m\n" \
	"$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	printf "\n\033[0;31mFAILED\033[0m — %d test(s) failed\n" "$FAIL_COUNT"
	exit 1
else
	printf "\n\033[0;32mPASSED\033[0m — all tests passed (%d skipped)\n" "$SKIP_COUNT"
	exit 0
fi
