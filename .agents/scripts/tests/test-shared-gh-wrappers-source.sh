#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-shared-gh-wrappers-source.sh — t2709 / GH#20357 regression guard.
#
# Asserts that sourcing shared-constants.sh (which in turn sources
# shared-gh-wrappers.sh) emits no warning about shared-gh-wrappers-rest-fallback.sh
# under both bash and zsh, and that the REST fallback helpers are defined.
#
# Root cause: shared-gh-wrappers.sh:44 used ${BASH_SOURCE[0]%/*} which
# evaluates to empty string under zsh (BASH_SOURCE is not populated), causing
# the source call to attempt /shared-gh-wrappers-rest-fallback.sh — a warning
# on every invocation from a zsh session. Fix: cross-shell resolver with
# SCRIPT_DIR priority, BASH_SOURCE fallback, and zsh ${(%):-%x} fallback.
#
# Tests:
#   1. bash: source shared-constants.sh produces no warning about rest-fallback
#   2. bash: REST fallback helper _gh_issue_create_rest is defined after sourcing
#   3. zsh:  source shared-constants.sh produces no warning about rest-fallback (skip if no zsh)
#   4. zsh:  REST fallback helper _gh_issue_create_rest is defined after sourcing (skip if no zsh)

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
SHARED_CONSTANTS="${SCRIPTS_DIR}/shared-constants.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_YELLOW=$'\033[0;33m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN=''
	TEST_RED=''
	TEST_YELLOW=''
	TEST_NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() {
	local msg="$1"
	echo "${TEST_GREEN}PASS${TEST_NC}: ${msg}"
	PASS_COUNT=$((PASS_COUNT + 1))
	return 0
}

fail() {
	local msg="$1"
	echo "${TEST_RED}FAIL${TEST_NC}: ${msg}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

skip() {
	local msg="$1"
	echo "${TEST_YELLOW}SKIP${TEST_NC}: ${msg}"
	SKIP_COUNT=$((SKIP_COUNT + 1))
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: bash — no warning about rest-fallback on source
# ---------------------------------------------------------------------------
test_bash_no_warning() {
	local output
	output=$(bash -c "source '${SHARED_CONSTANTS}'" 2>&1) || true
	if echo "${output}" | grep -q 'shared-gh-wrappers-rest-fallback.sh'; then
		fail "bash source emitted warning about shared-gh-wrappers-rest-fallback.sh"
		echo "  Output: ${output}"
	else
		pass "bash sources shared-constants.sh with no rest-fallback warning"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: bash — REST fallback helper is defined after sourcing
# ---------------------------------------------------------------------------
test_bash_rest_helper_defined() {
	local type_output
	type_output=$(bash -c "source '${SHARED_CONSTANTS}' && type _gh_issue_create_rest 2>/dev/null") || true
	if echo "${type_output}" | grep -q 'function'; then
		pass "bash: _gh_issue_create_rest is defined after sourcing shared-constants.sh"
	else
		fail "bash: _gh_issue_create_rest is NOT defined after sourcing shared-constants.sh"
		echo "  type output: ${type_output}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: zsh — no warning about rest-fallback on source (skip if no zsh)
# ---------------------------------------------------------------------------
test_zsh_no_warning() {
	if ! command -v zsh >/dev/null 2>&1; then
		skip "zsh not available — skipping zsh source-clean test"
		return 0
	fi
	local output
	output=$(zsh -c "source '${SHARED_CONSTANTS}'" 2>&1) || true
	if echo "${output}" | grep -q 'shared-gh-wrappers-rest-fallback.sh'; then
		fail "zsh source emitted warning about shared-gh-wrappers-rest-fallback.sh"
		echo "  Output: ${output}"
	else
		pass "zsh sources shared-constants.sh with no rest-fallback warning"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: zsh — REST fallback helper is defined after sourcing (skip if no zsh)
# ---------------------------------------------------------------------------
test_zsh_rest_helper_defined() {
	if ! command -v zsh >/dev/null 2>&1; then
		skip "zsh not available — skipping zsh REST helper definition test"
		return 0
	fi
	local type_output
	type_output=$(zsh -c "source '${SHARED_CONSTANTS}' && type _gh_issue_create_rest 2>/dev/null") || true
	if echo "${type_output}" | grep -q 'function'; then
		pass "zsh: _gh_issue_create_rest is defined after sourcing shared-constants.sh"
	else
		fail "zsh: _gh_issue_create_rest is NOT defined after sourcing shared-constants.sh"
		echo "  type output: ${type_output}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=== test-shared-gh-wrappers-source.sh — t2709 cross-shell sourcing ==="
test_bash_no_warning
test_bash_rest_helper_defined
test_zsh_no_warning
test_zsh_rest_helper_defined

echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
	exit 1
fi
exit 0
