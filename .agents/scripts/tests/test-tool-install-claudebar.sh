#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOL_INSTALL="$REPO_ROOT/.agents/scripts/setup/modules/tool-install.sh"

SANDBOX="$(mktemp -d -t tool-install-claudebar-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

assert_rc() {
	local desc="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf '  PASS: %s\n' "$desc"
		PASS=$((PASS + 1))
		return 0
	fi
	printf '  FAIL: %s -- expected rc %s, got %s\n' "$desc" "$expected" "$actual" >&2
	FAIL=$((FAIL + 1))
	return 1
}

extract_functions() {
	awk '
		/^setup_claudebar_needs_upgrade\(\)/, /^}$/ { print; next }
	' "$TOOL_INSTALL" >"$SANDBOX/extract.sh"
	if ! grep -q '^setup_claudebar_needs_upgrade()' "$SANDBOX/extract.sh"; then
		printf 'FAIL: extraction did not capture setup_claudebar_needs_upgrade\n' >&2
		exit 1
	fi
	return 0
}

needs_upgrade_rc() {
	local installed_version="$1"
	local target_version="$2"
	local rc=0
	# shellcheck disable=SC1090
	source "$SANDBOX/extract.sh"
	setup_claudebar_needs_upgrade "$installed_version" "$target_version" || rc=$?
	printf '%s\n' "$rc"
	return 0
}

extract_functions

assert_rc "older ClaudeBar prompts for upgrade" "0" "$(needs_upgrade_rc "0.4.65" "0.4.66")"
assert_rc "matching ClaudeBar suppresses upgrade prompt" "1" "$(needs_upgrade_rc "0.4.66" "0.4.66")"
assert_rc "newer ClaudeBar suppresses upgrade prompt" "1" "$(needs_upgrade_rc "v0.4.67" "0.4.66")"
assert_rc "unknown ClaudeBar version keeps conservative prompt" "0" "$(needs_upgrade_rc "" "0.4.66")"

if [[ "$FAIL" -gt 0 ]]; then
	printf 'FAIL: %s ClaudeBar setup checks failed\n' "$FAIL" >&2
	exit 1
fi

printf 'PASS: %s ClaudeBar setup checks passed\n' "$PASS"
exit 0
