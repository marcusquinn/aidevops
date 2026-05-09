#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression checks for pulse merge-conflict GitHub label lookups.
#
# Usage: bash .agents/tests/test-pulse-merge-conflict.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TARGET="${SCRIPT_DIR}/../scripts/pulse-merge-conflict.sh"

TESTS_PASSED=0
TESTS_FAILED=0

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1"
	local reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — ${reason}}"
	return 0
}

_assert_contains_literal() {
	local name="$1"
	local needle="$2"
	if grep -Fq -- "$needle" "$TARGET"; then
		_pass "$name"
		return 0
	fi
	_fail "$name" "missing literal: ${needle}"
	return 0
}

_assert_not_contains_literal() {
	local name="$1"
	local needle="$2"
	if grep -Fq -- "$needle" "$TARGET"; then
		_fail "$name" "unexpected literal: ${needle}"
		return 0
	fi
	_pass "$name"
	return 0
}

test_label_lookup_filters_are_null_safe() {
	printf '\n=== label lookup filters ===\n'
	_assert_contains_literal "issue label lookup uses optional labels" \
		"gh api \"\$issue_api\" --jq '[.labels[]?.name] | join(\",\")'"
	_assert_contains_literal "PR label lookup uses optional labels" \
		"--json labels --jq '[.labels[]?.name] | join(\",\")'"
	return 0
}

test_protected_issue_lookup_fails_closed() {
	printf '\n=== protected issue lookup failure ===\n'
	_assert_contains_literal "issue labels fetch is guarded" \
		"if ! issue_labels=\$(gh api \"\$issue_api\" --jq '[.labels[]?.name] | join(\",\")'); then"
	_assert_contains_literal "issue labels failure skips closure" \
		"skipping issue closure to be safe"
	_assert_contains_literal "issue labels failure returns early" \
		"failed to fetch labels for issue #\${linked_issue}"
	_assert_not_contains_literal "issue labels lookup does not suppress stderr" \
		"issue_labels=\$(gh api \"\$issue_api\" --jq '[.labels[]?.name] | join(\",\")' 2>/dev/null)"
	return 0
}

main() {
	test_label_lookup_filters_are_null_safe
	test_protected_issue_lookup_fails_closed

	printf '\nSummary: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
