#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

# Accept the same major version at or above the .nvmrc patch level.
node_version_ok() {
	local required_node="$1"
	local current_node="$2"
	local required_major="${required_node%%.*}"
	local current_major="${current_node%%.*}"
	local req_minor="" req_patch="" cur_minor="" cur_patch="" older=0
	IFS=. read -r _ req_minor req_patch <<<"$required_node"
	IFS=. read -r _ cur_minor cur_patch <<<"$current_node"
	req_minor="${req_minor:-0}"
	req_patch="${req_patch:-0}"
	cur_minor="${cur_minor:-0}"
	cur_patch="${cur_patch:-0}"
	if ((10#$cur_minor < 10#$req_minor || (10#$cur_minor == 10#$req_minor && 10#$cur_patch < 10#$req_patch))); then
		older=1
	fi
	if [[ "$current_major" != "$required_major" || "$older" -eq 1 ]]; then
		printf 'QuickFile MCP requires Node.js %s (major %s, same major or newer patch) from .nvmrc; got %s. Set NODE_BIN to a matching executable.\n' "$required_node" "$required_major" "$current_node" >&2
		return 1
	fi
	return 0
}

main() {
	local aidevops_bin="${AIDEVOPS_BIN:-aidevops}"
	local node_bin="${NODE_BIN:-node}"
	local canonical_entrypoint="${HOME}/Git/mcp/quickfile-mcp/dist/index.js"
	local legacy_entrypoint="${HOME}/Git/quickfile-mcp/dist/index.js"
	local entrypoint=""
	local project_dir=""
	local required_node=""
	local current_node=""
	local nvm_node_bin=""
	local inventory=""
	local secret_name=""
	local secret_names=()

	command -v "$aidevops_bin" >/dev/null 2>&1 || {
		printf 'QuickFile MCP launcher requires aidevops secret management\n' >&2
		return 1
	}
	command -v jq >/dev/null 2>&1 || {
		printf 'QuickFile MCP launcher requires jq\n' >&2
		return 1
	}
	if [[ -f "$canonical_entrypoint" ]]; then
		entrypoint="$canonical_entrypoint"
	elif [[ -f "$legacy_entrypoint" ]]; then
		entrypoint="$legacy_entrypoint"
	else
		entrypoint="$canonical_entrypoint"
	fi
	[[ -f "$entrypoint" ]] || {
		printf 'QuickFile MCP entrypoint not found: %s\n' "$entrypoint" >&2
		return 1
	}
	project_dir="$(dirname "$(dirname "$entrypoint")")"
	if [[ -f "$project_dir/.nvmrc" ]]; then
		required_node="$(<"$project_dir/.nvmrc")"
		required_node="${required_node#v}"
		nvm_node_bin="${NVM_DIR:-${HOME}/.nvm}/versions/node/v${required_node}/bin/node"
		if [[ -z "${NODE_BIN:-}" ]]; then
			local required_major="${required_node%%.*}"
			local candidate=""
			for candidate in "$nvm_node_bin" \
				"/opt/homebrew/opt/node@${required_major}/bin/node" \
				"/usr/local/opt/node@${required_major}/bin/node"; do
				if [[ -x "$candidate" ]]; then
					node_bin="$candidate"
					break
				fi
			done
		fi
	fi
	command -v "$node_bin" >/dev/null 2>&1 || {
		printf 'QuickFile MCP launcher requires the Node.js version declared by quickfile-mcp\n' >&2
		return 1
	}
	if [[ -n "$required_node" ]]; then
		current_node="$("$node_bin" --version)" || {
			printf 'Unable to determine the QuickFile MCP Node.js version\n' >&2
			return 1
		}
		current_node="${current_node#v}"
		node_version_ok "$required_node" "$current_node" || return 1
	fi

	inventory=$("$aidevops_bin" secret inventory) || {
		printf 'Unable to read the names-only aidevops secret inventory\n' >&2
		return 1
	}
	while IFS= read -r secret_name; do
		[[ -n "$secret_name" ]] && secret_names+=("$secret_name")
	done < <(
		printf '%s' "$inventory" | jq -r '
			[.secrets[]
			 | select(.status == "configured")
			 | .name
			 | select(test("^QUICKFILE_([A-Z0-9_]+_)?(API_KEY|API_TOKEN|BEARER_TOKEN)$"))]
			| unique[]'
	)

	if [[ ${#secret_names[@]} -eq 0 ]]; then
		printf 'No QuickFile bearer tokens configured; expected QUICKFILE_<ACCOUNT>_API_KEY\n' >&2
		return 1
	fi

	if [[ "${QUICKFILE_MCP_LAUNCHER_DRY_RUN:-0}" == "1" ]]; then
		printf 'QuickFile MCP launcher validated %s account token(s)\n' "${#secret_names[@]}"
		return 0
	fi

	exec "$aidevops_bin" secret "${secret_names[@]}" -- "$node_bin" "$entrypoint"
	return 1
}

main
