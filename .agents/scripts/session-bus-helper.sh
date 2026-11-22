#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# session-bus-helper.sh — `aidevops sessions`: list and message live OpenCode
# sessions (t18886/GH#37149). Thin wrapper over the Node CLI that shares the
# session-bus store with the OpenCode plugin. Docs: reference/session-bus.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

_session_bus_cli() {
	local candidate
	for candidate in \
		"${SCRIPT_DIR}/../plugins/opencode-aidevops/session-bus-cli.mjs" \
		"${HOME}/.aidevops/agents/plugins/opencode-aidevops/session-bus-cli.mjs"; do
		if [[ -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

main() {
	local cli=""
	if ! command -v node >/dev/null 2>&1; then
		printf 'aidevops sessions: node is required\n' >&2
		return 1
	fi
	if ! cli="$(_session_bus_cli)"; then
		printf 'aidevops sessions: session-bus-cli.mjs not found. Run: aidevops update\n' >&2
		return 1
	fi
	node "$cli" "$@"
	return $?
}

main "$@"
