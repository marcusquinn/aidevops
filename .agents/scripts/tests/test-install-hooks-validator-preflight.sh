#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-install-hooks-validator-preflight.sh — t2226 regression test.
#
# Validates the pre-install validator dry-run gate in install-hooks-helper.sh:
#   1. _dry_run_validators function exists.
#   2. Happy path: validators pass → install proceeds (function returns 0).
#   3. Failure path: a broken validator → install aborts (function returns 1).
#   4. Force-install path: --force-install bypasses failure (returns 0 with warning).
#   5. install_hook accepts --force-install flag.
#   6. Validator enumeration finds validate_* functions from pre-commit-hook.sh.
#
# These tests validate the preflight logic without running actual install
# (no .git/hooks writes, no settings.json modifications).

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# --- Test 1: _dry_run_validators function exists ---
test_function_exists() {
	if grep -q '^_dry_run_validators()' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh"; then
		print_result "_dry_run_validators() function exists" 0
	else
		print_result "_dry_run_validators() function exists" 1 "not found in install-hooks-helper.sh"
	fi
	return 0
}

# --- Test 2: install_hook accepts --force-install ---
test_force_install_flag() {
	if grep -q '\-\-force-install' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh"; then
		print_result "install_hook accepts --force-install" 0
	else
		print_result "install_hook accepts --force-install" 1 "flag not found"
	fi
	return 0
}

# --- Test 3: Validator enumeration finds functions ---
test_validator_enumeration() {
	local pch="$TEST_SCRIPTS_DIR/pre-commit-hook.sh"
	if [[ ! -f "$pch" ]]; then
		print_result "validator enumeration" 1 "pre-commit-hook.sh not found"
		return 0
	fi
	local count
	count=$(grep -oE 'validate_[a-z_]+\(\)' "$pch" | sed 's/()//' | sort -u | wc -l | tr -d ' ')
	if [[ "$count" -gt 0 ]]; then
		print_result "validator enumeration finds $count validators" 0
	else
		print_result "validator enumeration finds validators" 1 "found 0"
	fi
	return 0
}

# --- Test 4: _dry_run_validators is called in install flow ---
test_dry_run_called_in_install() {
	if grep -q '_dry_run_validators.*force_install' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh"; then
		print_result "_dry_run_validators called in install flow" 0
	else
		print_result "_dry_run_validators called in install flow" 1 "call not found in install_hook"
	fi
	return 0
}

# --- Helper: run _dry_run_validators with a mock pre-commit-hook.sh ---
# Creates a temp mock, sources install-hooks-helper.sh functions, overrides
# _find_pre_commit_hook AFTER sourcing (so the override sticks), then calls
# _dry_run_validators.
_run_dry_run_test() {
	local mock_content="$1"
	local force_flag="$2"

	local test_tmpdir
	test_tmpdir=$(mktemp -d)

	cat >"$test_tmpdir/pre-commit-hook.sh" <<MOCK_EOF
$mock_content
MOCK_EOF

	# Write a test harness script that sources the helper and runs the function
	cat >"$test_tmpdir/harness.sh" <<HARNESS_EOF
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$TEST_SCRIPTS_DIR"
# shellcheck source=../shared-constants.sh disable=SC1091
[[ -f "\${SCRIPT_DIR}/shared-constants.sh" ]] && source "\${SCRIPT_DIR}/shared-constants.sh"

# Source functions from install-hooks-helper.sh, skipping set -euo and main block
eval "\$(sed '/^set -euo pipefail\$/d; /^# Main\$/,\$ d' "$TEST_SCRIPTS_DIR/install-hooks-helper.sh")"

# Override _find_pre_commit_hook AFTER sourcing (so our mock wins)
_find_pre_commit_hook() {
	echo "$test_tmpdir/pre-commit-hook.sh"
	return 0
}

_dry_run_validators "unused" "$force_flag"
HARNESS_EOF

	local rc=0
	bash "$test_tmpdir/harness.sh" >/dev/null 2>&1 || rc=$?
	rm -rf "$test_tmpdir"
	return $rc
}

# --- Test 5: Dry-run passes with valid validators (happy path) ---
test_dry_run_happy_path() {
	local mock_body
	mock_body='#!/usr/bin/env bash
validate_test_pass() {
	return 0
}'

	local rc=0
	_run_dry_run_test "$mock_body" "false" || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "dry-run happy path (passing validator)" 0
	else
		print_result "dry-run happy path (passing validator)" 1 "exit=$rc"
	fi
	return 0
}

# --- Test 6: Dry-run fails with broken validator ---
test_dry_run_failure_path() {
	local mock_body
	mock_body='#!/usr/bin/env bash
validate_test_fail() {
	return 1
}'

	local rc=0
	_run_dry_run_test "$mock_body" "false" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		print_result "dry-run failure path (broken validator aborts)" 0
	else
		print_result "dry-run failure path (broken validator aborts)" 1 "expected non-zero exit"
	fi
	return 0
}

# --- Test 7: --force-install bypasses failure ---
test_force_install_bypass() {
	local mock_body
	mock_body='#!/usr/bin/env bash
validate_test_fail() {
	return 1
}'

	local rc=0
	_run_dry_run_test "$mock_body" "true" || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		print_result "force-install bypasses broken validator" 0
	else
		print_result "force-install bypasses broken validator" 1 "exit=$rc"
	fi
	return 0
}

# --- Test 8: help text includes --force-install ---
test_help_text() {
	local output
	output=$(bash "$TEST_SCRIPTS_DIR/install-hooks-helper.sh" help 2>&1)
	if echo "$output" | grep -q '\-\-force-install'; then
		print_result "help text mentions --force-install" 0
	else
		print_result "help text mentions --force-install" 1 "not in help output"
	fi
	return 0
}

# --- Run all tests ---
main() {
	echo "=== install-hooks-helper.sh validator preflight tests (t2226) ==="
	echo ""

	test_function_exists
	test_force_install_flag
	test_validator_enumeration
	test_dry_run_called_in_install
	test_dry_run_happy_path
	test_dry_run_failure_path
	test_force_install_bypass
	test_help_text

	echo ""
	echo "=== Results: $TESTS_RUN tests, $TESTS_FAILED failures ==="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
