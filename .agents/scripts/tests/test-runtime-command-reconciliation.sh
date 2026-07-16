#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d -t aidevops-runtime-command-reconciliation.XXXXXX)"
TEST_HOME="$TEST_ROOT/home"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p \
	"$TEST_HOME/.aidevops/agents/commands" \
	"$TEST_HOME/.aidevops/agents/scripts/commands" \
	"$TEST_HOME/.config/opencode/command"
printf '%s\n' '# build command' >"$TEST_HOME/.aidevops/agents/commands/aidevops-build-plus.md"
printf '%s\n' '# session command' >"$TEST_HOME/.aidevops/agents/scripts/commands/session-analysis.md"

HOME="$TEST_HOME"
# shellcheck source=../generate-runtime-config.sh
source "$REPO_ROOT/.agents/scripts/generate-runtime-config.sh"

if _opencode_command_output_matches_source; then
	printf '%s\n' 'FAIL: missing generated commands passed parity verification' >&2
	exit 1
fi

printf '%s\n' '# generated build command' >"$TEST_HOME/.config/opencode/command/aidevops-build-plus.md"
printf '%s\n' '# generated session command' >"$TEST_HOME/.config/opencode/command/aidevops-session-analysis.md"
if ! _opencode_command_output_matches_source; then
	printf '%s\n' 'FAIL: complete generated command set failed parity verification' >&2
	exit 1
fi

rm -f "$TEST_HOME/.config/opencode/command/aidevops-session-analysis.md"
if _opencode_command_output_matches_source; then
	printf '%s\n' 'FAIL: deleted generated command was not detected' >&2
	exit 1
fi

printf '%s\n' 'PASS: OpenCode command parity detects and clears runtime drift'
exit 0
