#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Bridge a self-hosted NetBird MCP endpoint (<management>/api/mcp) to stdio.
#
# The token comes from aidevops secrets: NETBIRD_MCP_SECRET, else the declared
# `aidevops secret default netbird`. The server comes from NETBIRD_MCP_URL, else
# the registry account name recorded for that secret (a hostname). mcp-remote
# expands ${NAME} in --header itself, so the token never appears in argv.
set -euo pipefail

PACKAGE="mcp-remote@0.16.6"

main() {
	local aidevops_bin="${AIDEVOPS_BIN:-aidevops}"
	local npx_bin="${NPX_BIN:-npx}"
	local secret_name="${NETBIRD_MCP_SECRET:-}"
	local url="${NETBIRD_MCP_URL:-}"
	local host=""

	command -v "$aidevops_bin" >/dev/null 2>&1 || {
		printf 'NetBird MCP launcher requires aidevops secret management\n' >&2
		return 1
	}
	command -v jq >/dev/null 2>&1 || {
		printf 'NetBird MCP launcher requires jq\n' >&2
		return 1
	}
	command -v "$npx_bin" >/dev/null 2>&1 || {
		printf 'NetBird MCP launcher requires npx (Node.js 20+)\n' >&2
		return 1
	}

	if [[ -z "$secret_name" ]]; then
		secret_name="$("$aidevops_bin" secret resolve netbird 2>/dev/null)" || {
			printf 'No NetBird token: set NETBIRD_MCP_SECRET or run: aidevops secret default netbird NETBIRD_<NAME>_MCP_PAT\n' >&2
			return 1
		}
	fi
	[[ "$secret_name" =~ ^NETBIRD_[A-Z0-9_]+$ ]] || {
		printf 'NetBird MCP secret name must match NETBIRD_[A-Z0-9_]+\n' >&2
		return 1
	}
	"$aidevops_bin" secret check "$secret_name" || {
		printf 'NetBird MCP secret %s is not configured\n' "$secret_name" >&2
		return 1
	}

	if [[ -z "$url" ]]; then
		host="$("$aidevops_bin" secret describe "$secret_name" --json 2>/dev/null | jq -r '.account.name // empty')" || host=""
		[[ "$host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$host" == *.* ]] || {
			printf 'No NetBird server: set NETBIRD_MCP_URL or record the secret with --account <ref> whose name is the hostname\n' >&2
			return 1
		}
		url="https://${host}/api/mcp"
	fi
	[[ "$url" =~ ^https://[a-z0-9.-]+(:[0-9]+)?/api/mcp$ ]] || {
		printf 'NETBIRD_MCP_URL must be https://<host>/api/mcp\n' >&2
		return 1
	}

	if [[ "${NETBIRD_MCP_LAUNCHER_DRY_RUN:-0}" == "1" ]]; then
		printf 'NetBird MCP launcher validated %s for %s via %s\n' "$secret_name" "$url" "$PACKAGE"
		return 0
	fi

	# NetBird personal access tokens use the `Token` scheme. Streamable HTTP only:
	# NetBird answers the legacy SSE transport with 405.
	exec "$aidevops_bin" secret "$secret_name" -- \
		"$npx_bin" --yes "$PACKAGE" "$url" \
		--transport http-only --silent \
		--header "Authorization: Token \${${secret_name}}"
	return 1
}

main
