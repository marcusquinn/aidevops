#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression guard for GH#26533: `create-pr` must stay on the full-loop
# wrapper path instead of failing as an unknown command and nudging workers
# toward raw `gh pr create` fallback without provenance labels.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../full-loop-helper.sh"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

assert_contains() {
	local label="$1"
	local haystack="$2"
	local needle="$3"

	if [[ "$haystack" != *"$needle"* ]]; then
		fail "$label missing expected text: $needle"
		return 1
	fi
	return 0
}

main() {
	local help_output=""
	help_output=$("$HELPER" help 2>&1)
	assert_contains "help output" "$help_output" "commit-and-pr|create-pr"

	local alias_output=""
	local rc=0
	alias_output=$("$HELPER" create-pr 2>&1) || rc=$?
	if [[ $rc -eq 0 ]]; then
		fail "create-pr without required args should fail validation"
		return 1
	fi
	if [[ "$alias_output" == *"Unknown command: create-pr"* ]]; then
		fail "create-pr fell through to unknown-command handler"
		return 1
	fi
	assert_contains "create-pr validation" "$alias_output" "commit-and-pr|create-pr"

	printf 'PASS: full-loop create-pr alias\n'
	return 0
}

main "$@"
