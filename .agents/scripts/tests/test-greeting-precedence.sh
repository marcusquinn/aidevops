#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#27032 greeting precedence and fallback generation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

rt_display_name() {
	local runtime_id="$1"
	case "$runtime_id" in
	opencode) printf '%s\n' "OpenCode" ;;
	claude-code) printf '%s\n' "Claude Code" ;;
	*) printf '%s\n' "$runtime_id" ;;
	esac
	return 0
}

print_success() {
	local message="$1"
	printf '%s\n' "$message" >/dev/null
	return 0
}

# shellcheck source=../generate-runtime-config-agents.sh
source "${SCRIPT_DIR}/generate-runtime-config-agents.sh"

_generate_greeting_agents_md opencode "$TMP_DIR"
GENERATED_FILE="${TMP_DIR}/AGENTS.md"
TEMPLATE_FILE="${REPO_ROOT}/templates/opencode-config-agents.md"

grep -q 'authoritative plugin-injected greeting block' "$GENERATED_FILE"
grep -q 'plugin injection is unavailable' "$GENERATED_FILE"
# shellcheck disable=SC2016
grep -q 'if the cache file is missing, read `~/.aidevops/agents/VERSION`' "$GENERATED_FILE"
grep -q 'Never emit both the injected greeting and the fallback greeting' "$GENERATED_FILE"
# shellcheck disable=SC2016
grep -q 'do NOT re-run `aidevops-update-check.sh`' "$GENERATED_FILE"
if grep -q 'Run .*aidevops-update-check.sh' "$GENERATED_FILE"; then
	exit 1
fi
[[ "$(grep -c '^       Hi!$' "$GENERATED_FILE")" -eq 1 ]]

grep -q 'authoritative plugin-injected greeting block' "$TEMPLATE_FILE"
grep -q 'plugin injection is unavailable' "$TEMPLATE_FILE"
# shellcheck disable=SC2016
grep -q 'if the cache file is missing, read `~/.aidevops/agents/VERSION`' "$TEMPLATE_FILE"
grep -q 'Never emit both the injected greeting and the fallback greeting' "$TEMPLATE_FILE"
# shellcheck disable=SC2016
grep -q 'do NOT re-run `aidevops-update-check.sh`' "$TEMPLATE_FILE"
if grep -q 'Run .*aidevops-update-check.sh' "$TEMPLATE_FILE"; then
	exit 1
fi
[[ "$(grep -c '^   Hi!$' "$TEMPLATE_FILE")" -eq 1 ]]

printf 'PASS: greeting injection precedence and fallback generation\n'
