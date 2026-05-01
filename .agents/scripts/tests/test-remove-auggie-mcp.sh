#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_file_lacks() {
	local file_path="$1"
	local pattern="$2"
	local test_name="$3"

	if grep -q -- "$pattern" "$file_path"; then
		print_result "$test_name" 1 "unexpected pattern in ${file_path#"$REPO_ROOT"/}"
		return 0
	fi

	print_result "$test_name" 0
	return 0
}

test_runtime_generator_does_not_register_removed_mcp() {
	local aug="aug"
	local gie="gie"
	local removed_mcp="${aug}${gie}-mcp"
	local removed_context="${aug}ment-context-engine"
	local generator="$REPO_ROOT/.agents/scripts/generate-runtime-config-mcp.sh"
	local claude_generator="$REPO_ROOT/.agents/scripts/generate-claude-agents.sh"

	assert_file_lacks "$generator" "$removed_mcp" "runtime generator omits removed Auggie MCP"
	assert_file_lacks "$generator" "$removed_context" "runtime generator omits removed Augment MCP"
	assert_file_lacks "$claude_generator" "$removed_mcp" "Claude generator omits removed Auggie MCP"
	return 0
}

test_removed_mcp_templates_are_deleted() {
	local aug="aug"
	local removed_context="${aug}ment-context-engine"
	local removed_files=(
		"$REPO_ROOT/.agents/tools/context/${removed_context}.md"
		"$REPO_ROOT/configs/${removed_context}-config.json.txt"
		"$REPO_ROOT/configs/mcp-templates/${removed_context}.json"
	)

	local removed_file
	for removed_file in "${removed_files[@]}"; do
		if [[ -e "$removed_file" ]]; then
			print_result "removed Augment MCP templates are deleted" 1 "still exists: ${removed_file#"$REPO_ROOT"/}"
			return 0
		fi
	done

	print_result "removed Augment MCP templates are deleted" 0
	return 0
}

test_opencode_registry_does_not_start_removed_binary() {
	local aug="aug"
	local gie="gie"
	local registry="$REPO_ROOT/.agents/plugins/opencode-aidevops/mcp-registry.mjs"
	local binary_name="${aug}${gie}"
	local command_pattern="command: \[\"${binary_name}\", \"--mcp\"\]"

	assert_file_lacks "$registry" "$command_pattern" "OpenCode registry does not start removed MCP binary"
	return 0
}

test_migration_removes_stale_entries() {
	local tmp_config
	tmp_config="$(mktemp)"

	local aug="aug"
	local gie="gie"
	local removed_mcp="${aug}${gie}-mcp"
	local removed_context="${aug}ment-context-engine"

	printf '{"mcp":{"%s":{},"%s":{},"context7":{}},"tools":{"%s_*":true,"%s_*":true,"context7_*":true},"agent":{"Build":{"tools":{"%s_*":true,"%s_*":true,"context7_*":true}}}}\n' \
		"$removed_mcp" "$removed_context" "$removed_mcp" "$removed_context" "$removed_mcp" "$removed_context" >"$tmp_config"

	# shellcheck source=/dev/null
	source "$REPO_ROOT/setup-modules/migrations.sh"
	_remove_deprecated_mcp_entries "$tmp_config"

	if jq -e --arg removed_mcp "$removed_mcp" --arg removed_context "$removed_context" \
		'(.mcp[$removed_mcp] // .mcp[$removed_context] // .tools[$removed_mcp + "_*"] // .tools[$removed_context + "_*"] // .agent.Build.tools[$removed_mcp + "_*"] // .agent.Build.tools[$removed_context + "_*"])' \
		"$tmp_config" >/dev/null; then
		print_result "migration removes stale Auggie/Augment config entries" 1 "stale entry remained"
		rm -f "$tmp_config"
		return 0
	fi

	if jq -e '.mcp.context7 and .tools["context7_*"] and .agent.Build.tools["context7_*"]' "$tmp_config" >/dev/null; then
		print_result "migration removes stale Auggie/Augment config entries" 0
		rm -f "$tmp_config"
		return 0
	fi

	print_result "migration removes stale Auggie/Augment config entries" 1 "unrelated MCP entry was removed"
	rm -f "$tmp_config"
	return 0
}

main() {
	test_runtime_generator_does_not_register_removed_mcp
	test_removed_mcp_templates_are_deleted
	test_opencode_registry_does_not_start_removed_binary
	test_migration_removes_stale_entries

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
