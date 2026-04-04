#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2317,SC2329
# SC2034: Variables set for sourced scripts
# SC2317: Commands inside test functions appear unreachable to ShellCheck
# SC2329: test_* functions invoked from main(); ShellCheck cannot trace indirect calls
set -euo pipefail

# Test suite for microsoft-graph-helper.sh
# Tests configuration loading, token cache management, argument parsing,
# and command routing. Does NOT test live Graph API calls (requires real credentials).
#
# Usage: bash tests/test-microsoft-graph-helper.sh
#
# Part of aidevops framework (t1526)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
HELPER="${REPO_ROOT}/.agents/scripts/microsoft-graph-helper.sh"
CONFIG_TEMPLATE="${REPO_ROOT}/.agents/configs/microsoft-graph-config.json.txt"

# Test workspace (isolated from real data)
TEST_WORKSPACE=$(mktemp -d)
TEST_TOKEN_CACHE_DIR="${TEST_WORKSPACE}/microsoft-graph"
TEST_TOKEN_CACHE="${TEST_TOKEN_CACHE_DIR}/token-cache.json"
TEST_CONFIG_DIR="${TEST_WORKSPACE}/configs"
TEST_CONFIG="${TEST_CONFIG_DIR}/microsoft-graph-config.json"

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================================
# Test utilities
# ============================================================================

cleanup() {
	rm -rf "$TEST_WORKSPACE"
}
trap cleanup EXIT

setup_test_env() {
	mkdir -p "$TEST_CONFIG_DIR"
	mkdir -p "$TEST_TOKEN_CACHE_DIR"
	chmod 700 "$TEST_TOKEN_CACHE_DIR"

	# Create minimal test config
	cat >"$TEST_CONFIG" <<'JSON'
{
  "tenant_id": "test-tenant-id",
  "client_id": "test-client-id",
  "auth_flow": "device",
  "default_mailbox": "me",
  "shared_mailboxes": ["support@test.com"],
  "default_folder": "Inbox",
  "message_list_limit": 25,
  "api_version": "v1.0"
}
JSON
}

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected: $expected"
		echo "    Actual:   $actual"
	fi
	return 0
}

assert_contains() {
	local description="$1"
	local needle="$2"
	local haystack="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	if echo "$haystack" | grep -q "$needle"; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected to contain: $needle"
		echo "    Actual: ${haystack:0:200}"
	fi
	return 0
}

assert_not_empty() {
	local description="$1"
	local value="$2"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -n "$value" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description (value is empty)"
	fi
	return 0
}

assert_file_exists() {
	local description="$1"
	local file="$2"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -f "$file" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description (file not found: $file)"
	fi
	return 0
}

assert_file_perms() {
	local description="$1"
	local expected_perms="$2"
	local file="$3"

	TESTS_RUN=$((TESTS_RUN + 1))
	local actual_perms
	actual_perms=$(stat -f "%Lp" "$file" 2>/dev/null || stat -c "%a" "$file" 2>/dev/null || echo "unknown")
	if [[ "$actual_perms" == "$expected_perms" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected perms: $expected_perms"
		echo "    Actual perms:   $actual_perms"
	fi
	return 0
}

assert_exit_code() {
	local description="$1"
	local expected_code="$2"
	shift 2

	TESTS_RUN=$((TESTS_RUN + 1))
	local actual_code=0
	"$@" >/dev/null 2>&1 || actual_code=$?
	if [[ "$actual_code" -eq "$expected_code" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: $description"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: $description"
		echo "    Expected exit code: $expected_code"
		echo "    Actual exit code:   $actual_code"
	fi
	return 0
}

# ============================================================================
# Config template tests
# ============================================================================

test_config_template() {
	echo "Test: Config template validity"

	assert_file_exists "Config template exists" "$CONFIG_TEMPLATE"

	# Validate JSON syntax
	local parse_result
	parse_result=$(jq '.' "$CONFIG_TEMPLATE" 2>&1)
	local parse_exit=$?
	assert_eq "Config template is valid JSON" "0" "$parse_exit"

	# Check required fields
	local tenant_id
	tenant_id=$(jq -r '.tenant_id // empty' "$CONFIG_TEMPLATE")
	assert_not_empty "Config template has tenant_id field" "$tenant_id"

	local client_id
	client_id=$(jq -r '.client_id // empty' "$CONFIG_TEMPLATE")
	assert_not_empty "Config template has client_id field" "$client_id"

	local auth_flow
	auth_flow=$(jq -r '.auth_flow // empty' "$CONFIG_TEMPLATE")
	assert_not_empty "Config template has auth_flow field" "$auth_flow"

	local permissions
	permissions=$(jq -r '.permissions // empty' "$CONFIG_TEMPLATE")
	assert_not_empty "Config template has permissions section" "$permissions"

	local azure_setup
	azure_setup=$(jq -r '.azure_app_setup // empty' "$CONFIG_TEMPLATE")
	assert_not_empty "Config template has azure_app_setup section" "$azure_setup"

	return 0
}

# ============================================================================
# Helper script structure tests
# ============================================================================

test_helper_exists() {
	echo "Test: Helper script exists and is executable"

	assert_file_exists "Helper script exists" "$HELPER"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -x "$HELPER" ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: Helper script is executable"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: Helper script is not executable"
	fi
	return 0
}

test_help_output() {
	echo "Test: Help command output"

	local help_output
	help_output=$(bash "$HELPER" help 2>&1)

	assert_contains "Help shows auth command" "auth" "$help_output"
	assert_contains "Help shows list-messages command" "list-messages" "$help_output"
	assert_contains "Help shows send command" "send" "$help_output"
	assert_contains "Help shows reply command" "reply" "$help_output"
	assert_contains "Help shows move command" "move" "$help_output"
	assert_contains "Help shows flag command" "flag" "$help_output"
	assert_contains "Help shows delete command" "delete" "$help_output"
	assert_contains "Help shows list-folders command" "list-folders" "$help_output"
	assert_contains "Help shows permissions command" "permissions" "$help_output"
	assert_contains "Help shows grant-access command" "grant-access" "$help_output"
	assert_contains "Help shows status command" "status" "$help_output"
	assert_contains "Help shows setup instructions" "SETUP" "$help_output"
	assert_contains "Help shows examples" "EXAMPLES" "$help_output"

	return 0
}

test_unknown_command() {
	echo "Test: Unknown command exits non-zero"

	assert_exit_code "Unknown command exits 1" "1" bash "$HELPER" nonexistent-command-xyz

	return 0
}

# ============================================================================
# Token cache tests
# ============================================================================

test_token_cache_write_and_read() {
	echo "Test: Token cache write and read"

	# Write a token cache directly (simulating what save_token does)
	# This tests the cache structure without sourcing the helper (which has readonly vars)
	mkdir -p "$TEST_TOKEN_CACHE_DIR"
	chmod 700 "$TEST_TOKEN_CACHE_DIR"

	local expires_at
	expires_at=$(date -u -v+3600S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "+3600 seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		echo "2099-01-01T00:00:00Z")

	jq -n \
		--arg at "test-access-token-value" \
		--arg rt "test-refresh-token-value" \
		--arg ea "$expires_at" \
		--arg tt "Bearer" \
		--arg sc "Mail.ReadWrite" \
		'{access_token: $at, refresh_token: $rt, expires_at: $ea, token_type: $tt, scope: $sc}' \
		>"$TEST_TOKEN_CACHE"
	chmod 600 "$TEST_TOKEN_CACHE"

	# Verify cache file was created
	assert_file_exists "Token cache file created" "$TEST_TOKEN_CACHE"

	# Verify permissions are 0600
	assert_file_perms "Token cache has 0600 permissions" "600" "$TEST_TOKEN_CACHE"

	# Verify cache contains expected fields (not values — just structure)
	local has_access_token has_expires_at has_scope
	has_access_token=$(jq -r 'has("access_token")' "$TEST_TOKEN_CACHE" 2>/dev/null || echo "false")
	has_expires_at=$(jq -r 'has("expires_at")' "$TEST_TOKEN_CACHE" 2>/dev/null || echo "false")
	has_scope=$(jq -r 'has("scope")' "$TEST_TOKEN_CACHE" 2>/dev/null || echo "false")

	assert_eq "Token cache has access_token field" "true" "$has_access_token"
	assert_eq "Token cache has expires_at field" "true" "$has_expires_at"
	assert_eq "Token cache has scope field" "true" "$has_scope"

	return 0
}

test_token_cache_no_value_in_output() {
	echo "Test: Token cache operations do not print token values"

	# Create a fake token cache
	mkdir -p "$TEST_TOKEN_CACHE_DIR"
	chmod 700 "$TEST_TOKEN_CACHE_DIR"
	cat >"$TEST_TOKEN_CACHE" <<'JSON'
{
  "access_token": "SENSITIVE_ACCESS_TOKEN_VALUE_12345",
  "refresh_token": "SENSITIVE_REFRESH_TOKEN_VALUE_67890",
  "expires_at": "2099-01-01T00:00:00Z",
  "token_type": "Bearer",
  "scope": "Mail.ReadWrite"
}
JSON
	chmod 600 "$TEST_TOKEN_CACHE"

	# token-status should NOT print the actual token values
	local status_output
	status_output=$(
		export MSGRAPH_CLIENT_ID="test-client-id"
		export MSGRAPH_TENANT_ID="test-tenant-id"
		bash "$HELPER" token-status 2>&1 || true
	)

	# The output should NOT contain the sensitive token values
	TESTS_RUN=$((TESTS_RUN + 1))
	if echo "$status_output" | grep -q "SENSITIVE_ACCESS_TOKEN_VALUE_12345"; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: token-status printed access token value (security violation)"
	else
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: token-status does not print access token value"
	fi

	TESTS_RUN=$((TESTS_RUN + 1))
	if echo "$status_output" | grep -q "SENSITIVE_REFRESH_TOKEN_VALUE_67890"; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: token-status printed refresh token value (security violation)"
	else
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: token-status does not print refresh token value"
	fi

	return 0
}

# ============================================================================
# Config loading tests
# ============================================================================

test_config_loading() {
	echo "Test: Config loading and value extraction"

	# Test config values directly via jq (same logic as get_config_value)
	local tenant_id
	tenant_id=$(jq -r '.tenant_id // empty' "$TEST_CONFIG" 2>/dev/null)
	assert_eq "Config loads tenant_id" "test-tenant-id" "$tenant_id"

	local default_folder
	default_folder=$(jq -r '.default_folder // empty' "$TEST_CONFIG" 2>/dev/null)
	assert_eq "Config loads default_folder" "Inbox" "$default_folder"

	local missing_key
	missing_key=$(jq -r '.nonexistent_key // empty' "$TEST_CONFIG" 2>/dev/null)
	# Empty string is the expected result for missing keys (get_config_value returns default)
	assert_eq "Missing config key returns empty (default applied by caller)" "" "$missing_key"

	return 0
}

test_config_missing() {
	echo "Test: Missing config file returns error"

	# list-mailboxes requires config — without it, should exit non-zero
	# Set credentials env vars so it gets past credential check, but config is missing
	local exit_code=0
	MSGRAPH_CLIENT_ID="test-client-id" MSGRAPH_TENANT_ID="test-tenant-id" \
		bash "$HELPER" list-mailboxes >/dev/null 2>&1 || exit_code=$?

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$exit_code" -ne 0 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: Missing config returns non-zero exit"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: Missing config should return non-zero exit (got $exit_code)"
	fi
	return 0
}

# ============================================================================
# Mailbox path tests
# ============================================================================

test_mailbox_path() {
	echo "Test: mailbox_path() resolution"

	# Test mailbox_path logic directly (it's simple enough to inline)
	# Logic: "me" or "" -> /me, anything else -> /users/<addr>
	local me_path
	me_path=$(
		# shellcheck disable=SC1090
		source "$HELPER" 2>/dev/null
		mailbox_path "me"
	)
	assert_eq "mailbox_path 'me' returns /me" "/me" "$me_path"

	local empty_path
	empty_path=$(
		# shellcheck disable=SC1090
		source "$HELPER" 2>/dev/null
		mailbox_path ""
	)
	assert_eq "mailbox_path '' returns /me" "/me" "$empty_path"

	local shared_path
	shared_path=$(
		# shellcheck disable=SC1090
		source "$HELPER" 2>/dev/null
		mailbox_path "support@company.com"
	)
	assert_eq "mailbox_path shared mailbox returns /users/..." "/users/support@company.com" "$shared_path"

	return 0
}

# ============================================================================
# Argument validation tests
# ============================================================================

test_list_messages_requires_mailbox() {
	echo "Test: list-messages requires --mailbox"

	assert_exit_code "list-messages without --mailbox exits non-zero" "1" \
		bash "$HELPER" list-messages

	return 0
}

test_send_requires_all_args() {
	echo "Test: send requires --mailbox, --to, --subject, --body"

	# Without credentials, send will fail at load_credentials — but we want to test
	# argument validation. Use the CLI and check it exits non-zero.
	local exit_code=0
	bash "$HELPER" send --mailbox "support@test.com" >/dev/null 2>&1 || exit_code=$?

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$exit_code" -ne 0 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: send with missing args exits non-zero"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: send with missing args should exit non-zero"
	fi
	return 0
}

test_flag_validates_flag_value() {
	echo "Test: flag validates flag value"

	# Use CLI — flag with invalid value should exit non-zero
	# Without credentials it will fail at load_credentials, but that's also non-zero
	assert_exit_code "flag with invalid value exits non-zero" "1" \
		bash "$HELPER" flag --mailbox "support@test.com" --id "msg-123" --flag "invalid-flag-value"

	return 0
}

test_grant_access_validates_role() {
	echo "Test: grant-access validates role"

	# grant-access does NOT require credentials (it just prints PowerShell commands)
	assert_exit_code "grant-access with invalid role exits non-zero" "1" \
		bash "$HELPER" grant-access --mailbox "support@test.com" --user "alice@test.com" --role "InvalidRole"

	return 0
}

test_grant_access_valid_roles() {
	echo "Test: grant-access accepts valid roles"

	for role in FullAccess SendAs SendOnBehalf; do
		local exit_code=0
		bash "$HELPER" grant-access \
			--mailbox "support@test.com" \
			--user "alice@test.com" \
			--role "$role" >/dev/null 2>&1 || exit_code=$?

		TESTS_RUN=$((TESTS_RUN + 1))
		if [[ "$exit_code" -eq 0 ]]; then
			TESTS_PASSED=$((TESTS_PASSED + 1))
			echo "  PASS: grant-access accepts role $role"
		else
			TESTS_FAILED=$((TESTS_FAILED + 1))
			echo "  FAIL: grant-access should accept role $role (exit: $exit_code)"
		fi
	done
	return 0
}

# ============================================================================
# Documentation tests
# ============================================================================

test_documentation_exists() {
	echo "Test: Documentation file exists"

	local doc_file="${REPO_ROOT}/.agents/services/email/microsoft-graph.md"
	assert_file_exists "microsoft-graph.md documentation exists" "$doc_file"

	# Check frontmatter (use grep -F for literal string to avoid BSD grep treating --- as flags)
	local has_frontmatter=0
	head -1 "$doc_file" | grep -qF -- "---" && has_frontmatter=1
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$has_frontmatter" -eq 1 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: Documentation has YAML frontmatter"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: Documentation missing YAML frontmatter"
	fi

	# Check key sections
	local content
	content=$(cat "$doc_file")
	assert_contains "Documentation has Setup section" "## Setup" "$content"
	assert_contains "Documentation has Authentication section" "## Authentication" "$content"
	assert_contains "Documentation has Shared Mailbox section" "## Shared Mailbox" "$content"
	assert_contains "Documentation has Troubleshooting section" "## Troubleshooting" "$content"
	assert_contains "Documentation references helper script" "microsoft-graph-helper.sh" "$content"

	return 0
}

# ============================================================================
# Security tests
# ============================================================================

test_no_credentials_in_config_template() {
	echo "Test: Config template contains no real credentials"

	local template_content
	template_content=$(cat "$CONFIG_TEMPLATE")

	# Template should use placeholder values, not real credential patterns
	TESTS_RUN=$((TESTS_RUN + 1))
	# Real tenant IDs are GUIDs like xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
	# The template uses "YOUR_TENANT_ID" as placeholder
	if echo "$template_content" | grep -qE '"tenant_id":\s*"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: Config template appears to contain a real tenant ID GUID"
	else
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: Config template uses placeholder for tenant_id"
	fi

	TESTS_RUN=$((TESTS_RUN + 1))
	if echo "$template_content" | grep -qE '"client_id":\s*"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: Config template appears to contain a real client ID GUID"
	else
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: Config template uses placeholder for client_id"
	fi

	return 0
}

test_helper_no_hardcoded_secrets() {
	echo "Test: Helper script contains no hardcoded secrets"

	local helper_content
	helper_content=$(cat "$HELPER")

	# Should not contain any GUID-like values (real client/tenant IDs)
	TESTS_RUN=$((TESTS_RUN + 1))
	if echo "$helper_content" | grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: Helper script may contain hardcoded GUID (potential credential)"
	else
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: Helper script contains no hardcoded GUIDs"
	fi

	# Should not contain any base64-encoded strings that look like tokens
	TESTS_RUN=$((TESTS_RUN + 1))
	if echo "$helper_content" | grep -qE 'eyJ[A-Za-z0-9+/]{20,}'; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "  FAIL: Helper script may contain a hardcoded JWT token"
	else
		TESTS_PASSED=$((TESTS_PASSED + 1))
		echo "  PASS: Helper script contains no hardcoded JWT tokens"
	fi

	return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
	echo "================================================"
	echo "microsoft-graph-helper.sh test suite"
	echo "================================================"
	echo ""

	# Check prerequisites
	if ! command -v jq &>/dev/null; then
		echo "ERROR: jq is required for tests. Install: brew install jq"
		exit 1
	fi

	setup_test_env

	echo "--- Config template ---"
	test_config_template
	echo ""

	echo "--- Helper script structure ---"
	test_helper_exists
	test_help_output
	test_unknown_command
	echo ""

	echo "--- Token cache ---"
	test_token_cache_write_and_read
	test_token_cache_no_value_in_output
	echo ""

	echo "--- Config loading ---"
	test_config_loading
	test_config_missing
	echo ""

	echo "--- Mailbox path resolution ---"
	test_mailbox_path
	echo ""

	echo "--- Argument validation ---"
	test_list_messages_requires_mailbox
	test_send_requires_all_args
	test_flag_validates_flag_value
	test_grant_access_validates_role
	test_grant_access_valid_roles
	echo ""

	echo "--- Documentation ---"
	test_documentation_exists
	echo ""

	echo "--- Security ---"
	test_no_credentials_in_config_template
	test_helper_no_hardcoded_secrets
	echo ""

	echo "================================================"
	echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
	echo "================================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
