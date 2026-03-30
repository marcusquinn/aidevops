#!/usr/bin/env bash
# Tests for _migrate_mcp_npx_to_binary() regression hardening (GH#14220)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_SCRIPT="$REPO_DIR/setup-modules/migrations.sh"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
	local name="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;32mPASS\033[0m %s\n" "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "\033[0;31mFAIL\033[0m %s\n" "$name"
	if [[ -n "$detail" ]]; then
		printf "     %s\n" "$detail"
	fi
	return 0
}

section() {
	echo ""
	echo "=== $1 ==="
	return 0
}

TEST_HOME=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TEST_HOME'" EXIT
export HOME="$TEST_HOME"

# Minimal stubs required for sourcing migrations.sh in isolation.
# shellcheck disable=SC2329
print_info() { return 0; }
# shellcheck disable=SC2329
print_success() { return 0; }
# shellcheck disable=SC2329
print_warning() { return 0; }
# shellcheck disable=SC2329
_launchd_has_agent() { return 1; }
# shellcheck disable=SC2329
find_opencode_config() { return 1; }
# shellcheck disable=SC2329
create_backup_with_rotation() { return 0; }
# shellcheck disable=SC2329
update_mcp_paths_in_opencode() { return 0; }
# shellcheck disable=SC2329
sanitize_plugin_namespace() {
	echo "$1"
	return 0
}
# shellcheck disable=SC2329
resolve_mcp_binary_path() {
	local bin_name="$1"
	if [[ "$bin_name" == "chrome-devtools-mcp" ]]; then
		echo "/usr/local/bin/chrome-devtools-mcp"
		return 0
	fi
	return 1
}

export -f print_info print_success print_warning _launchd_has_agent
export -f find_opencode_config create_backup_with_rotation update_mcp_paths_in_opencode
export -f sanitize_plugin_namespace resolve_mcp_binary_path

# shellcheck disable=SC1090
source "$MIGRATIONS_SCRIPT"

section "Test: minimal config without .mcp does not fail"

config_without_mcp="$TEST_HOME/opencode-empty.json"
printf '{}\n' >"$config_without_mcp"

output=$(_migrate_mcp_npx_to_binary "$config_without_mcp" 2>&1)
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
	pass "Function succeeds when .mcp is missing"
else
	fail "Function should succeed when .mcp is missing" "exit code: $exit_code"
fi

if [[ "$output" == *"exit 5"* ]]; then
	fail "No jq exit-5 style failure when .mcp is missing" "$output"
else
	pass "No jq exit-5 style failure when .mcp is missing"
fi

if jq -e '. == {}' "$config_without_mcp" >/dev/null 2>&1; then
	pass "Config remains unchanged when .mcp is missing"
else
	fail "Config should remain unchanged when .mcp is missing"
fi

section "Test: npx MCP command migrates to resolved binary path"

config_with_mcp="$TEST_HOME/opencode-mcp.json"
printf '{"mcp":{"chrome":{"command":["npx","-y","chrome-devtools-mcp"]}}}\n' >"$config_with_mcp"

_migrate_mcp_npx_to_binary "$config_with_mcp"
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
	pass "Function succeeds when MCP entries are present"
else
	fail "Function should succeed when MCP entries are present" "exit code: $exit_code"
fi

if [[ ${_cleanup_count:-0} -eq 1 ]]; then
	pass "Cleanup counter increments for migrated MCP entry"
else
	fail "Cleanup counter should increment for migrated MCP entry" "_cleanup_count=${_cleanup_count:-unset}"
fi

migrated_command=$(jq -r '.mcp.chrome.command[0]' "$config_with_mcp" 2>/dev/null || echo "")
if [[ "$migrated_command" == "/usr/local/bin/chrome-devtools-mcp" ]]; then
	pass "MCP command migrated to resolved binary path"
else
	fail "MCP command should migrate to resolved binary path" "got: $migrated_command"
fi

echo ""
echo "================================"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $TOTAL_COUNT total"
echo "================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
	exit 1
fi
exit 0
