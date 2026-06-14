#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression checks for pulse merge required-check ruleset parsing.
#
# Usage: bash .agents/tests/test-pulse-merge-required-checks.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
TARGET="${SCRIPT_DIR}/../scripts/pulse-merge-required-checks.sh"

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

test_ruleset_jq_diagnostics_have_safe_log_fallback() {
	printf '\n=== ruleset jq diagnostics ===\n'
	_assert_contains_literal "ruleset parser defines safe log target" \
		"local log_target=\"\${LOGFILE:-/dev/stderr}\""
	_assert_contains_literal "active rulesets jq stderr uses fallback" \
		"jq -r '.[]? | select(.enforcement == \"active\") | .id // empty' 2>>\"\$log_target\""
	_assert_contains_literal "approval count jq stderr uses fallback" \
		"jq -r '[.rules[]? | select(.type == \"pull_request\") | (.parameters?.required_approving_review_count? // 0)] | max // 0' 2>>\"\$log_target\""
	_assert_not_contains_literal "ruleset jq does not redirect to possibly unset LOGFILE" \
		"jq -r '[.rules[]? | select(.type == \"pull_request\") | (.parameters?.required_approving_review_count? // 0)] | max // 0' 2>>\"\$LOGFILE\""
	return 0
}

test_ruleset_ref_patterns_fail_closed_on_malformed_schema() {
	printf '\n=== ruleset ref pattern fail-closed parsing ===\n'
	_assert_contains_literal "include patterns use strict array iteration" \
		"jq -r '.conditions?.ref_name?.include? // [] | .[]' 2>>\"\$log_target\""
	_assert_contains_literal "exclude patterns use strict array iteration" \
		"jq -r '.conditions?.ref_name?.exclude? // [] | .[]' 2>>\"\$log_target\""
	_assert_not_contains_literal "include patterns do not suppress malformed non-arrays" \
		"jq -r '.conditions?.ref_name?.include? // [] | .[]?'"
	_assert_not_contains_literal "exclude patterns do not suppress malformed non-arrays" \
		"jq -r '.conditions?.ref_name?.exclude? // [] | .[]?'"
	return 0
}

main() {
	test_ruleset_jq_diagnostics_have_safe_log_fallback
	test_ruleset_ref_patterns_fail_closed_on_malformed_schema

	printf '\nSummary: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
