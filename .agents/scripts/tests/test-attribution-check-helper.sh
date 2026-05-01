#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-attribution-check-helper.sh — regression tests for attribution checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HELPER="${REPO_ROOT}/.agents/scripts/attribution-check-helper.sh"

pass_count=0
fail_count=0

_pass() {
	local msg="$1"
	printf '  [PASS] %s\n' "$msg"
	pass_count=$((pass_count + 1))
	return 0
}

_fail() {
	local msg="$1"
	printf '  [FAIL] %s\n' "$msg" >&2
	fail_count=$((fail_count + 1))
	return 0
}

_assert_contains() {
	local label="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		_pass "$label"
	else
		_fail "$label — missing ${needle}"
	fi
	return 0
}

printf '=== attribution-check-helper tests ===\n\n'

output=$(cd "$REPO_ROOT" && "$HELPER" --file .agents/scripts/attribution-check-helper.sh --symbol main --claim t000 2>&1)

_assert_contains "claim line can begin with hyphen" "$output" "- Claim: t000"
_assert_contains "symbol-found line can begin with hyphen" "$output" "- Symbol check: found main in source"
_assert_contains "success result is reported" "$output" "RESULT: evidence-collected"

if missing_output=$(cd "$REPO_ROOT" && "$HELPER" --file .agents/scripts/attribution-check-helper.sh --symbol definitely_missing_symbol_for_test 2>&1); then
	_fail "missing symbol exits non-zero"
else
	_assert_contains "symbol-missing line can begin with hyphen" "$missing_output" "- Symbol check: missing definitely_missing_symbol_for_test in source"
	_assert_contains "hypothesis-only result is reported" "$missing_output" "RESULT: hypothesis-only"
fi

printf '\n=== Results ===\n'
printf '  Passed: %d\n' "$pass_count"
printf '  Failed: %d\n' "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
	exit 1
fi

printf 'All tests passed.\n'
exit 0
