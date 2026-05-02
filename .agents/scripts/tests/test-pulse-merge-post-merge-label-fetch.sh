#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-post-merge-label-fetch.sh — GH#22219 regression guard.
#
# Verifies that _handle_post_merge_actions treats a provided empty 5th
# argument as authoritative "no labels" data instead of refetching PR labels.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
MERGE_FILE="${SCRIPTS_DIR}/pulse-merge.sh"

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '     %s\n' "$detail"
	fi
	return 0
}

if grep -q 'if \[\[ \$# -lt 5 \]\]; then' "$MERGE_FILE"; then
	pass "provided empty pr_labels skip refetch path"
else
	fail "provided empty pr_labels skip refetch path" \
		"_handle_post_merge_actions should check argument count, not label string emptiness"
fi

if grep -q '_gh_with_timeout read gh pr view "[$]pr_number"' "$MERGE_FILE"; then
	pass "fallback PR label fetch uses timeout wrapper"
else
	fail "fallback PR label fetch uses timeout wrapper" \
		"fallback gh pr view call should go through _gh_with_timeout read"
fi

printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
