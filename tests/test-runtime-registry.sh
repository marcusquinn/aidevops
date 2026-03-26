#!/usr/bin/env bash

# =============================================================================
# Tests for runtime-registry.sh
# =============================================================================
# Validates: array alignment, lookup functions, enumeration, detection,
# reverse lookups, and path expansion.
#
# Usage: bash tests/test-runtime-registry.sh [--verbose]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$REPO_DIR/.agents/scripts/runtime-registry.sh"
VERBOSE="${1:-}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	local message="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  PASS %s\n" "$message"
	fi
	return 0
}

fail() {
	local message="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  FAIL %s\n" "$message"
	if [[ -n "$detail" ]]; then
		printf "       %s\n" "$detail"
	fi
	return 0
}

section() {
	local title="$1"
	echo ""
	printf "=== %s ===\n" "$title"
	return 0
}

# Source the registry
# shellcheck source=../.agents/scripts/runtime-registry.sh
source "$REGISTRY"

# =============================================================================
section "Registry Validation"
# =============================================================================

if rt_validate_registry; then
	pass "All parallel arrays are aligned"
else
	fail "Parallel array alignment check failed"
fi

# Verify count is reasonable (at least 10 runtimes defined)
count=$(rt_count)
if [[ "$count" -ge 10 ]]; then
	pass "Registry has $count runtimes (>= 10)"
else
	fail "Registry has only $count runtimes (expected >= 10)"
fi

# =============================================================================
section "Property Lookups — Known Runtimes"
# =============================================================================

# --- opencode ---
result=$(rt_binary "opencode")
if [[ "$result" == "opencode" ]]; then
	pass "rt_binary opencode = opencode"
else
	fail "rt_binary opencode" "expected 'opencode', got '$result'"
fi

result=$(rt_display_name "opencode")
if [[ "$result" == "OpenCode" ]]; then
	pass "rt_display_name opencode = OpenCode"
else
	fail "rt_display_name opencode" "expected 'OpenCode', got '$result'"
fi

result=$(rt_config_format "opencode")
if [[ "$result" == "json" ]]; then
	pass "rt_config_format opencode = json"
else
	fail "rt_config_format opencode" "expected 'json', got '$result'"
fi

result=$(rt_mcp_root_key "opencode")
if [[ "$result" == "mcp" ]]; then
	pass "rt_mcp_root_key opencode = mcp"
else
	fail "rt_mcp_root_key opencode" "expected 'mcp', got '$result'"
fi

result=$(rt_prompt_mechanism "opencode")
if [[ "$result" == "AGENTS.md" ]]; then
	pass "rt_prompt_mechanism opencode = AGENTS.md"
else
	fail "rt_prompt_mechanism opencode" "expected 'AGENTS.md', got '$result'"
fi

result=$(rt_session_db_format "opencode")
if [[ "$result" == "sqlite" ]]; then
	pass "rt_session_db_format opencode = sqlite"
else
	fail "rt_session_db_format opencode" "expected 'sqlite', got '$result'"
fi

result=$(rt_headless_support "opencode")
if [[ "$result" == "yes" ]]; then
	pass "rt_headless_support opencode = yes"
else
	fail "rt_headless_support opencode" "expected 'yes', got '$result'"
fi

# --- claude-code ---
result=$(rt_binary "claude-code")
if [[ "$result" == "claude" ]]; then
	pass "rt_binary claude-code = claude"
else
	fail "rt_binary claude-code" "expected 'claude', got '$result'"
fi

result=$(rt_display_name "claude-code")
if [[ "$result" == "Claude Code" ]]; then
	pass "rt_display_name claude-code = Claude Code"
else
	fail "rt_display_name claude-code" "expected 'Claude Code', got '$result'"
fi

result=$(rt_config_format "claude-code")
if [[ "$result" == "json" ]]; then
	pass "rt_config_format claude-code = json"
else
	fail "rt_config_format claude-code" "expected 'json', got '$result'"
fi

result=$(rt_session_db_format "claude-code")
if [[ "$result" == "jsonl-dir" ]]; then
	pass "rt_session_db_format claude-code = jsonl-dir"
else
	fail "rt_session_db_format claude-code" "expected 'jsonl-dir', got '$result'"
fi

# --- cursor ---
result=$(rt_headless_support "cursor")
if [[ "$result" == "no" ]]; then
	pass "rt_headless_support cursor = no (editor-only)"
else
	fail "rt_headless_support cursor" "expected 'no', got '$result'"
fi

# --- aider ---
result=$(rt_config_path "aider")
if [[ "$result" == "" ]]; then
	pass "rt_config_path aider = '' (no MCP config)"
else
	fail "rt_config_path aider" "expected empty, got '$result'"
fi

result=$(rt_mcp_root_key "aider")
if [[ "$result" == "" ]]; then
	pass "rt_mcp_root_key aider = '' (no MCP)"
else
	fail "rt_mcp_root_key aider" "expected empty, got '$result'"
fi

# =============================================================================
section "Path Expansion"
# =============================================================================

result=$(rt_config_path "opencode")
expected="$HOME/.config/opencode/opencode.json"
if [[ "$result" == "$expected" ]]; then
	pass "rt_config_path opencode expands \$HOME correctly"
else
	fail "rt_config_path opencode expansion" "expected '$expected', got '$result'"
fi

result=$(rt_session_db "opencode")
expected="$HOME/.local/share/opencode/opencode.db"
if [[ "$result" == "$expected" ]]; then
	pass "rt_session_db opencode expands \$HOME correctly"
else
	fail "rt_session_db opencode expansion" "expected '$expected', got '$result'"
fi

result=$(rt_command_dir "claude-code")
expected="$HOME/.claude/commands"
if [[ "$result" == "$expected" ]]; then
	pass "rt_command_dir claude-code expands \$HOME correctly"
else
	fail "rt_command_dir claude-code expansion" "expected '$expected', got '$result'"
fi

# =============================================================================
section "Unknown Runtime Handling"
# =============================================================================

if ! rt_binary "nonexistent-runtime" 2>/dev/null; then
	pass "rt_binary returns 1 for unknown runtime"
else
	fail "rt_binary should return 1 for unknown runtime"
fi

if ! rt_config_path "nonexistent-runtime" 2>/dev/null; then
	pass "rt_config_path returns 1 for unknown runtime"
else
	fail "rt_config_path should return 1 for unknown runtime"
fi

# =============================================================================
section "Enumeration Functions"
# =============================================================================

# rt_list_ids should include known runtimes
ids=$(rt_list_ids)
if echo "$ids" | grep -q "opencode"; then
	pass "rt_list_ids includes opencode"
else
	fail "rt_list_ids missing opencode"
fi

if echo "$ids" | grep -q "claude-code"; then
	pass "rt_list_ids includes claude-code"
else
	fail "rt_list_ids missing claude-code"
fi

if echo "$ids" | grep -q "aider"; then
	pass "rt_list_ids includes aider"
else
	fail "rt_list_ids missing aider"
fi

# rt_list_headless should include opencode and claude-code but not cursor
headless=$(rt_list_headless)
if echo "$headless" | grep -q "opencode"; then
	pass "rt_list_headless includes opencode"
else
	fail "rt_list_headless missing opencode"
fi

if echo "$headless" | grep -q "claude-code"; then
	pass "rt_list_headless includes claude-code"
else
	fail "rt_list_headless missing claude-code"
fi

if ! echo "$headless" | grep -q "cursor"; then
	pass "rt_list_headless excludes cursor (editor-only)"
else
	fail "rt_list_headless should exclude cursor"
fi

# rt_list_with_commands should include opencode and claude-code
with_cmds=$(rt_list_with_commands)
if echo "$with_cmds" | grep -q "opencode"; then
	pass "rt_list_with_commands includes opencode"
else
	fail "rt_list_with_commands missing opencode"
fi

if echo "$with_cmds" | grep -q "claude-code"; then
	pass "rt_list_with_commands includes claude-code"
else
	fail "rt_list_with_commands missing claude-code"
fi

# =============================================================================
section "Reverse Lookup"
# =============================================================================

result=$(rt_id_from_binary "claude")
if [[ "$result" == "claude-code" ]]; then
	pass "rt_id_from_binary claude = claude-code"
else
	fail "rt_id_from_binary claude" "expected 'claude-code', got '$result'"
fi

result=$(rt_id_from_binary "opencode")
if [[ "$result" == "opencode" ]]; then
	pass "rt_id_from_binary opencode = opencode"
else
	fail "rt_id_from_binary opencode" "expected 'opencode', got '$result'"
fi

result=$(rt_id_from_binary "aider")
if [[ "$result" == "aider" ]]; then
	pass "rt_id_from_binary aider = aider"
else
	fail "rt_id_from_binary aider" "expected 'aider', got '$result'"
fi

if ! rt_id_from_binary "nonexistent-binary" 2>/dev/null; then
	pass "rt_id_from_binary returns 1 for unknown binary"
else
	fail "rt_id_from_binary should return 1 for unknown binary"
fi

# =============================================================================
section "All Properties for Each Runtime"
# =============================================================================
# Verify every runtime has non-empty binary and display name (minimum requirement)

all_ids=$(rt_list_ids)
while IFS= read -r rid; do
	bin=$(rt_binary "$rid")
	if [[ -n "$bin" ]]; then
		pass "rt_binary $rid is non-empty ($bin)"
	else
		fail "rt_binary $rid is empty (every runtime needs a binary name)"
	fi

	name=$(rt_display_name "$rid")
	if [[ -n "$name" ]]; then
		pass "rt_display_name $rid is non-empty ($name)"
	else
		fail "rt_display_name $rid is empty (every runtime needs a display name)"
	fi
done <<<"$all_ids"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Results ==="
printf "Total: %d  Passed: %d  Failed: %d\n" "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
	exit 1
fi
exit 0
