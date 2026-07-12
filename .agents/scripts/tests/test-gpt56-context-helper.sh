#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../gpt56-context-helper.sh"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"

assert_contains() {
	local haystack="$1"
	local needle="$2"
	if [[ "$haystack" != *"$needle"* ]]; then
		printf 'Expected output to contain: %s\nActual: %s\n' "$needle" "$haystack" >&2
		return 1
	fi
	return 0
}

output=$(bash "$HELPER" status)
assert_contains "$output" "enabled (300K"

bash "$HELPER" disable >/dev/null
[[ "$(jq -r '.runtime.opencode.gpt56_context_cap' "$HOME/.config/aidevops/settings.json")" == "false" ]]
output=$(bash "$HELPER" status)
assert_contains "$output" "disabled"

bash "$HELPER" enable >/dev/null
[[ "$(jq -r '.runtime.opencode.gpt56_context_cap' "$HOME/.config/aidevops/settings.json")" == "true" ]]

printf '%s\n' "PASS: gpt56 context helper"
