#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rt_display_name() {
	local runtime_id="$1"
	case "$runtime_id" in
	opencode) printf '%s\n' "OpenCode" ;;
	*) printf '%s\n' "$runtime_id" ;;
	esac
	return 0
}

print_success() {
	local message="$1"
	: "$message"
	return 0
}

# shellcheck source=../generate-runtime-config-agents.sh
source "$SCRIPT_DIR/generate-runtime-config-agents.sh"

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

_generate_greeting_agents_md "opencode" "$test_root"
generated="$test_root/AGENTS.md"

# Markdown backticks are intentionally literal.
# shellcheck disable=SC2016
grep -Fq 'plugin normally injects an authoritative `## Session-start greeting order`' "$generated"
grep -Fq 'If that instruction is present in the system context, follow it' "$generated"
grep -Fq 'Use the fallback only when the plugin instruction is absent.' "$generated"
grep -Fq '**Fallback on interactive conversation start**' "$generated"
# shellcheck disable=SC2016
grep -Fq 'Read line 1 of `~/.aidevops/cache/session-greeting.txt`' "$generated"
# shellcheck disable=SC2016
grep -Fq 'If the cache file is missing, read `~/.aidevops/agents/VERSION`' "$generated"
# shellcheck disable=SC2016
grep -Fq 'skip for headless sessions like `/pulse`, `/full-loop`' "$generated"

printf '%s\n' "PASS: generated OpenCode greeting guidance defers to the plugin and retains fallback evidence paths"
