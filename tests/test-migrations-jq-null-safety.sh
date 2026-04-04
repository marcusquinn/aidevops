#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-migrations-jq-null-safety.sh
#
# Regression test for GH#14220: _migrate_mcp_npx_to_binary must not fail
# when opencode.json has no .mcp key (minimal config like {}).
#
# Usage: bash tests/test-migrations-jq-null-safety.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE="${1:-}"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
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

summary() {
	echo ""
	echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed out of $TOTAL_COUNT tests"
	if [[ $FAIL_COUNT -gt 0 ]]; then
		exit 1
	fi
	return 0
}

# --- Prerequisites ---
if ! command -v jq &>/dev/null; then
	echo "SKIP: jq not installed"
	exit 0
fi

echo "=== Migration jq null-safety tests (GH#14220) ==="

# --- Test 1: jq expression with (.mcp // {}) handles missing .mcp ---
# This is the exact jq expression from _migrate_mcp_npx_to_binary line 601
test_jq_missing_mcp_key() {
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "$tmp_config"' RETURN

	# Minimal config with no .mcp key
	echo '{}' >"$tmp_config"

	local result
	# The fixed expression uses (.mcp // {}) — should produce empty output, exit 0
	if result=$(jq -r --arg pkg "chrome-devtools-mcp" \
		'(.mcp // {}) | to_entries[] | select(.value.command != null) | select(.value.command | join(" ") | test("npx.*" + $pkg + "|bunx.*" + $pkg + "|pipx.*run.*" + $pkg)) | .key' \
		"$tmp_config" 2>/dev/null | head -1); then
		if [[ -z "$result" ]]; then
			pass "missing .mcp key: jq returns empty, no error"
		else
			fail "missing .mcp key: unexpected result '$result'"
		fi
	else
		fail "missing .mcp key: jq exited with error $?"
	fi
	return 0
}

# --- Test 2: jq expression still works with populated .mcp ---
test_jq_populated_mcp_key() {
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "$tmp_config"' RETURN

	# Config with an npx-based MCP entry
	cat >"$tmp_config" <<'JSON'
{
  "mcp": {
    "chrome-devtools": {
      "command": ["npx", "-y", "chrome-devtools-mcp"],
      "type": "local"
    }
  }
}
JSON

	local result
	if result=$(jq -r --arg pkg "chrome-devtools-mcp" \
		'(.mcp // {}) | to_entries[] | select(.value.command != null) | select(.value.command | join(" ") | test("npx.*" + $pkg + "|bunx.*" + $pkg + "|pipx.*run.*" + $pkg)) | .key' \
		"$tmp_config" 2>/dev/null | head -1); then
		if [[ "$result" == "chrome-devtools" ]]; then
			pass "populated .mcp key: jq finds npx entry correctly"
		else
			fail "populated .mcp key: expected 'chrome-devtools', got '$result'"
		fi
	else
		fail "populated .mcp key: jq exited with error $?"
	fi
	return 0
}

# --- Test 3: jq -e '.mcp' early-return guard works for missing key ---
test_early_return_guard_missing() {
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "$tmp_config"' RETURN

	echo '{}' >"$tmp_config"

	# The early-return guard: jq -e '.mcp' should fail (exit 1) for missing key
	if jq -e '.mcp' "$tmp_config" >/dev/null 2>&1; then
		fail "early-return guard: jq -e '.mcp' should fail for {}"
	else
		pass "early-return guard: jq -e '.mcp' correctly fails for {}"
	fi
	return 0
}

# --- Test 4: jq -e '.mcp' early-return guard passes for present key ---
test_early_return_guard_present() {
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "$tmp_config"' RETURN

	echo '{"mcp": {"foo": {}}}' >"$tmp_config"

	if jq -e '.mcp' "$tmp_config" >/dev/null 2>&1; then
		pass "early-return guard: jq -e '.mcp' passes for populated config"
	else
		fail "early-return guard: jq -e '.mcp' should pass for populated config"
	fi
	return 0
}

# --- Test 5: jq -e '.mcp' early-return guard for .mcp = null ---
test_early_return_guard_null() {
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "$tmp_config"' RETURN

	echo '{"mcp": null}' >"$tmp_config"

	# .mcp exists but is null — jq -e should fail (null is falsy)
	if jq -e '.mcp' "$tmp_config" >/dev/null 2>&1; then
		fail "early-return guard: jq -e '.mcp' should fail for null .mcp"
	else
		pass "early-return guard: jq -e '.mcp' correctly fails for null .mcp"
	fi
	return 0
}

# --- Test 6: Original (unfixed) jq expression fails on missing .mcp ---
# This proves the bug existed — .mcp | to_entries[] errors on null
test_original_expression_fails() {
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "$tmp_config"' RETURN

	echo '{}' >"$tmp_config"

	# The ORIGINAL expression without (.mcp // {}) — should fail with exit 5
	local exit_code=0
	jq -r --arg pkg "chrome-devtools-mcp" \
		'.mcp | to_entries[] | select(.value.command != null) | select(.value.command | join(" ") | test("npx.*" + $pkg + "|bunx.*" + $pkg + "|pipx.*run.*" + $pkg)) | .key' \
		"$tmp_config" >/dev/null 2>&1 || exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		pass "original expression: correctly fails with exit $exit_code on missing .mcp (proves bug)"
	else
		fail "original expression: unexpectedly succeeded — test premise invalid"
	fi
	return 0
}

# --- Test 7: .mcp as empty object {} ---
test_jq_empty_mcp_object() {
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "$tmp_config"' RETURN

	echo '{"mcp": {}}' >"$tmp_config"

	local result
	if result=$(jq -r --arg pkg "chrome-devtools-mcp" \
		'(.mcp // {}) | to_entries[] | select(.value.command != null) | select(.value.command | join(" ") | test("npx.*" + $pkg + "|bunx.*" + $pkg + "|pipx.*run.*" + $pkg)) | .key' \
		"$tmp_config" 2>/dev/null | head -1); then
		if [[ -z "$result" ]]; then
			pass "empty .mcp object: jq returns empty, no error"
		else
			fail "empty .mcp object: unexpected result '$result'"
		fi
	else
		fail "empty .mcp object: jq exited with error $?"
	fi
	return 0
}

# --- Run all tests ---
test_jq_missing_mcp_key
test_jq_populated_mcp_key
test_early_return_guard_missing
test_early_return_guard_present
test_early_return_guard_null
test_original_expression_fails
test_jq_empty_mcp_object

summary
