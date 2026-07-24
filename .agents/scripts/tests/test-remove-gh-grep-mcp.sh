#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

assert_file_lacks_removed_reference() {
	local relative_path="$1"
	local file_path="${REPO_ROOT}/${relative_path}"

	if grep -Eq 'gh_grep|grep-vercel' "$file_path"; then
		printf 'FAIL removed MCP reference remains in %s\n' "$relative_path"
		return 1
	fi

	printf 'PASS removed MCP reference absent from %s\n' "$relative_path"
	return 0
}

assert_removed_template_absent() {
	local template_path="${REPO_ROOT}/configs/mcp-templates/grep-vercel.json"

	if [[ -e "$template_path" ]]; then
		printf 'FAIL removed MCP template still exists\n'
		return 1
	fi

	printf 'PASS removed MCP template is absent\n'
	return 0
}

assert_migration_removes_stale_config() {
	local tmp_config
	tmp_config="$(mktemp)"
	printf '%s\n' '{"mcp":{"gh_grep":{},"context7":{}},"tools":{"gh_grep_*":true,"context7_*":true}}' >"$tmp_config"

	# shellcheck source=/dev/null
	source "$REPO_ROOT/.agents/scripts/setup/modules/migrations.sh"
	_remove_deprecated_mcp_entries "$tmp_config"

	if ! jq -e '.mcp.context7 and .tools["context7_*"]' "$tmp_config" >/dev/null; then
		printf 'FAIL migration removed an unrelated MCP entry\n'
		rm -f "$tmp_config"
		return 1
	fi

	if jq -e '.mcp.gh_grep or .tools["gh_grep_*"]' "$tmp_config" >/dev/null; then
		printf 'FAIL migration retained the removed MCP entry\n'
		rm -f "$tmp_config"
		return 1
	fi

	rm -f "$tmp_config"
	printf 'PASS migration removes stale MCP configuration\n'
	return 0
}

main() {
	local relative_path
	local live_surfaces=(
		"README.md"
		"configs/mcp-servers-config.json.txt"
		".agents/scripts/setup-mcp-integrations.sh"
		".agents/plugins/opencode-aidevops/agent-mcp-tools.mjs"
	)

	for relative_path in "${live_surfaces[@]}"; do
		assert_file_lacks_removed_reference "$relative_path"
	done
	assert_removed_template_absent
	assert_migration_removes_stale_config
	return 0
}

main "$@"
