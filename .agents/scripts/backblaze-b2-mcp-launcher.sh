#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Launch the reviewed B2 MCP with only a least-privilege application key.
set -euo pipefail

PACKAGE="@backblaze-labs/b2-mcp@0.2.1"

node_is_supported() {
	local version="$1"
	local major="${version%%.*}"
	local remainder="${version#*.}"
	local minor="${remainder%%.*}"
	[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
	[[ "$major" -ge 24 || ("$major" -eq 22 && "$minor" -ge 22) ]]
}

main() {
	local aidevops_bin="${AIDEVOPS_BIN:-aidevops}"
	local node_bin="${NODE_BIN:-node}"
	local npx_bin="${NPX_BIN:-npx}"
	local node_version=""

	command -v "$aidevops_bin" >/dev/null 2>&1 || {
		printf 'Backblaze B2 MCP launcher requires aidevops secret management\n' >&2
		return 1
	}
	command -v "$node_bin" >/dev/null 2>&1 || {
		printf 'Backblaze B2 MCP launcher requires Node.js 22.22.2 or newer\n' >&2
		return 1
	}
	command -v "$npx_bin" >/dev/null 2>&1 || {
		printf 'Backblaze B2 MCP launcher requires npx\n' >&2
		return 1
	}
	node_version="$("$node_bin" --version)" || return 1
	node_version="${node_version#v}"
	node_is_supported "$node_version" || {
		printf 'Backblaze B2 MCP requires Node.js ^22.22.2, ^24, or ^26; got %s\n' "$node_version" >&2
		return 1
	}

	if [[ "${BACKBLAZE_B2_MCP_LAUNCHER_DRY_RUN:-0}" == "1" ]]; then
		printf 'Backblaze B2 MCP launcher validated Node.js %s and package %s\n' "$node_version" "$PACKAGE"
		return 0
	fi

	# Deliberately exclude B2 master-key, partner, group, and account secrets.
	exec "$aidevops_bin" secret B2_APPLICATION_KEY_ID B2_APPLICATION_KEY -- \
		"$npx_bin" --yes "$PACKAGE"
}

main
