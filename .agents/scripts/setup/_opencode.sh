#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# OpenCode configuration functions for setup.sh

# Update OpenCode config with new settings
update_opencode_config() {
	# TODO: Extract from setup.sh lines 3746-3790
	:
	return 0
}

# Update MCP paths in OpenCode config to use full binary paths
update_mcp_paths_in_opencode() {
	# TODO: Extract from setup.sh lines 4012-4097
	:
	return 0
}

# Deploy the opencode-aidevops plugin from repo to runtime location.
# Usage: add_opencode_plugin [--force]
add_opencode_plugin() {
	local force="${1:-}"
	local repo_plugin_dir="${AIDEVOPS_REPO:-${HOME}/Git/aidevops}/.agents/plugins/opencode-aidevops"
	local runtime_plugin_dir="${HOME}/.aidevops/agents/plugins/opencode-aidevops"

	if [[ ! -d "${repo_plugin_dir}" ]]; then
		echo "WARN: Plugin source not found at ${repo_plugin_dir}" >&2
		return 1
	fi

	# Skip if already deployed and not forcing
	if [[ -d "${runtime_plugin_dir}/node_modules" && "${force}" != "--force" ]]; then
		echo "OK: opencode-aidevops plugin already deployed"
		return 0
	fi

	echo "Deploying opencode-aidevops plugin..."

	# Sync plugin files (exclude tests, .git, etc.)
	mkdir -p "${runtime_plugin_dir}"
	rsync -a --delete \
		--exclude='node_modules/' \
		--exclude='tests/' \
		--exclude='.git/' \
		--exclude='*.log' \
		"${repo_plugin_dir}/" "${runtime_plugin_dir}/"

	# Install production dependencies
	if command -v npm &>/dev/null; then
		(cd "${runtime_plugin_dir}" && npm install --omit=dev --silent 2>/dev/null) || true
	elif command -v bun &>/dev/null; then
		(cd "${runtime_plugin_dir}" && bun install --production --silent 2>/dev/null) || true
	fi

	# Ensure the plugin is referenced in opencode.json
	local opencode_config="${HOME}/.config/opencode/opencode.json"
	if [[ -f "${opencode_config}" ]]; then
		local plugin_ref="file://${runtime_plugin_dir}/index.mjs"
		if ! rg -q "${plugin_ref}" "${opencode_config}" 2>/dev/null; then
			echo "NOTE: Add this to opencode.json plugin array:" >&2
			echo "  \"${plugin_ref}\"" >&2
		fi
	fi

	echo "OK: opencode-aidevops plugin deployed to ${runtime_plugin_dir}"
	return 0
}
