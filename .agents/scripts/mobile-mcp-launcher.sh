#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Local-only Mobile MCP launcher. Never downloads packages or starts HTTP/cloud services.

set -euo pipefail

if ! command -v node >/dev/null 2>&1 || ! command -v mcp-server-mobile >/dev/null 2>&1; then
	printf '%s\n' 'Mobile MCP is not installed. Run the optional mobile setup step first.' >&2
	exit 1
fi

node_version="$(node -p 'process.versions.node' 2>/dev/null)"
major="${node_version%%.*}"
minor="${node_version#*.}"
minor="${minor%%.*}"
if ((major < 22 || (major == 22 && minor < 12))); then
	printf '%s\n' 'Mobile MCP dependencies require Node.js 22.12 or newer.' >&2
	exit 1
fi

export MOBILEMCP_DISABLE_TELEMETRY=1
exec mcp-server-mobile --stdio
