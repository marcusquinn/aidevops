#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# Launch the SEO Utils desktop app's local stdio MCP server (`mcp-stdio`).
# No token, Node.js or network listener is involved: the app reads its own
# auth state, and the MCP server must be enabled in SEO Utils settings.
#
# Builds without `mcp-stdio` (2.5.0 and earlier) ignore the argument and start
# the full app backend with its schedulers, so this launcher refuses them.
#
# Environment:
#   SEO_UTILS_BIN                      Explicit app executable (required off macOS)
#   SEO_UTILS_MCP_LAUNCHER_DRY_RUN=1   Validate and print the executable; do not launch
set -euo pipefail

MAC_APP_EXECUTABLE="SEO Utils.app/Contents/MacOS/SEO Utils"

resolve_seo_utils_bin() {
	local explicit="${SEO_UTILS_BIN:-}"
	local candidate=""

	if [[ -n "$explicit" ]]; then
		# Fail closed on an invalid explicit path instead of guessing another app.
		if [[ -f "$explicit" && -x "$explicit" ]]; then
			printf '%s\n' "$explicit"
			return 0
		fi
		printf 'SEO_UTILS_BIN is not an executable file: %s\n' "$explicit" >&2
		return 1
	fi

	if [[ "$(uname -s)" == "Darwin" ]]; then
		for candidate in "/Applications/$MAC_APP_EXECUTABLE" "$HOME/Applications/$MAC_APP_EXECUTABLE"; do
			if [[ -f "$candidate" && -x "$candidate" ]]; then
				printf '%s\n' "$candidate"
				return 0
			fi
		done
		printf '%s\n' 'SEO Utils is not installed in /Applications or ~/Applications; set SEO_UTILS_BIN to the app executable.' >&2
		return 1
	fi

	printf '%s\n' 'Set SEO_UTILS_BIN to the SEO Utils executable shown in Settings -> MCP Server -> Connect an AI app -> Other MCP apps.' >&2
	return 1
}

supports_mcp_stdio() {
	local bin="$1"
	LC_ALL=C grep -a -q -F -- 'mcp-stdio' "$bin" && return 0
	return 1
}

main() {
	local bin=""

	bin="$(resolve_seo_utils_bin)" || return 1
	if ! supports_mcp_stdio "$bin"; then
		printf 'SEO Utils at %s has no mcp-stdio server (2.5.0 or earlier). Update SEO Utils, then retry.\n' "$bin" >&2
		return 1
	fi

	if [[ "${SEO_UTILS_MCP_LAUNCHER_DRY_RUN:-0}" == "1" ]]; then
		printf 'SEO Utils MCP launcher validated %s\n' "$bin"
		return 0
	fi

	exec "$bin" mcp-stdio
}

main
