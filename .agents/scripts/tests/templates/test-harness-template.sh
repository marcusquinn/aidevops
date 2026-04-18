#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# TEMPLATE: Shell test harness for aidevops framework helpers
#
# Copy this file to tests/test-<feature>.sh and:
#   1. Replace SCRIPT_UNDER_TEST with the actual target helper path.
#   2. Replace mock stub reference if your tests need a different fixture.
#   3. Add your test_* functions following the rc-capture pattern below.
#   4. List each test in main() in execution order.
#   5. Run shellcheck before committing.
#
# =============================================================================
# PITFALL 1 — set -e IS INTENTIONALLY OMITTED
# =============================================================================
# Do NOT add -e to the flags below.
#
# Test harnesses deliberately call helpers that return non-zero (testing error
# paths, gate functions that return 1 when a condition is not met, etc.).
# Under `set -e`, the first non-zero return from any helper kills the whole
# script before `$?` can be captured, so assertions never run and you get a
# misleading "all tests passed by not running" outcome.
#
# The correct pattern is to call the helper, immediately capture `$?` into a
# local variable, then assert on that variable. See test_* functions below.
#
# Bad:
#   set -euo pipefail
#   my_helper arg            # kills script on failure before assert
#   [[ "$?" -eq 1 ]]         # never reached
#
# Good (used here):
#   set -uo pipefail
#   my_helper "arg"
#   local rc=$?              # captured immediately after the call
#   [[ $rc -eq 1 ]]          # safe to assert now
#
set -uo pipefail

# =============================================================================
# PITFALL 2 — `local` IS ONLY VALID INSIDE FUNCTIONS
# =============================================================================
# Do NOT use the `local` keyword for variables declared at the script's
# top-level scope.
#
# Under bash 5.x, `local var=value` outside a function silently succeeds but
# drops the assignment — the variable ends up empty. This is a no-op that
# produces no error and no warning, making it very hard to debug via bash -x.
#
# Counters and path variables used across functions must be plain assignments
# here at the top level:
#
#   TESTS_RUN=0        (correct — plain assignment)
#   local TESTS_RUN=0  (wrong  — silently ignored at top level)
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/../../<replace-with-target-helper>.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

# Top-level counters — plain assignments, NOT `local` (see PITFALL 2 above).
TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# =============================================================================
# MOCK CLI STUB
# =============================================================================
# When the helper under test shells out to `gh`, `git`, or another CLI, replace
# that binary with a mock stub for the duration of the test. The canonical
# pattern is:
#
#   1. Keep the stub in tests/fixtures/mock-<feature>.sh (separate file so
#      setup_test_env stays under the 100-line function-complexity threshold).
#   2. In setup_test_env(), prepend a tmp bin/ dir to PATH and copy the stub
#      there as the target binary name (e.g. "gh").
#   3. Drive scenarios via plain text state files in $TEST_ROOT — the stub
#      reads these instead of hitting the real API. Tests mutate the state
#      files between assertions to exercise different branches.
#
# Example setup (see tests/fixtures/mock-gh-interactive-handover.sh for a
# complete working example):
#
#   setup_test_env() {
#       TEST_ROOT=$(mktemp -d)
#       mkdir -p "${TEST_ROOT}/bin"
#       export PATH="${TEST_ROOT}/bin:${PATH}"
#       local mock_src="${SCRIPT_DIR}/fixtures/mock-<feature>.sh"
#       cp "${mock_src}" "${TEST_ROOT}/bin/<cli-name>"  # name stub after CLI it replaces
#       return 0
#   }
#
# If the helper under test does NOT call any external CLI, skip the mock setup.

# =============================================================================
# Test infrastructure
# =============================================================================

# print_result <test-name> <failed-flag> [message]
#   failed-flag: 0 = PASS, non-zero = FAIL
print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	# Uncomment and adapt if a mock CLI stub is needed:
	# mkdir -p "${TEST_ROOT}/bin"
	# export PATH="${TEST_ROOT}/bin:${PATH}"
	# local mock_src="${SCRIPT_DIR}/fixtures/mock-<feature>.sh"
	# cp "${mock_src}" "${TEST_ROOT}/bin/gh"   # see MOCK CLI STUB section above
	# chmod +x "${TEST_ROOT}/bin/gh"
	export TEST_ROOT
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "${TEST_ROOT}"
	fi
	return 0
}

# Extract a function by name from the script under test and eval it in this
# shell. This avoids sourcing the entire script (which may have side effects at
# load time) and keeps the test harness focused on the specific helpers.
#
# Usage: define_helper_under_test "my_function_name"
define_helper_under_test() {
	local func_name="$1"
	local src
	src=$(awk "/^${func_name}\\(\\) \\{/,/^\\}\$/ { print }" "$SCRIPT_UNDER_TEST")
	if [[ -z "$src" ]]; then
		printf 'ERROR: could not extract %s from %s\n' "$func_name" "$SCRIPT_UNDER_TEST" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src"
	return 0
}

# =============================================================================
# Tests — replace these with your actual test functions
# =============================================================================
#
# RC-CAPTURE PATTERN (mandatory — see PITFALL 1 at the top):
#
#   Every test that invokes a helper which may return non-zero MUST capture the
#   return code immediately after the call, in its own statement. Combining the
#   call with a conditional (`if my_helper; then`) suppresses non-zero exits
#   under pipefail and hides the actual code. Use the explicit capture form:
#
#       my_helper "arg1" arg2
#       local rc=$?
#       if [[ $rc -eq 0 ]]; then ...
#
#   Do NOT write:
#       if my_helper "arg1" arg2; then ...   # hides $? under pipefail
#       [[ $(my_helper arg1) == "x" ]] ...   # swallows non-zero in subshell

test_A_example_success_case() {
	# Setup: arrange preconditions
	local expected=0

	# Act: call the helper under test
	# my_helper "arg"
	# local rc=$?    # <- capture immediately, before any other command
	local rc=0       # placeholder — replace with actual call above

	# Assert
	if [[ "$rc" -eq "$expected" ]]; then
		print_result "A: example success case" 0
	else
		print_result "A: example success case" 1 "Expected rc=$expected, got $rc"
	fi
	return 0
}

test_B_example_failure_case() {
	# Setup: arrange conditions that cause the helper to return non-zero
	local expected=1

	# Act
	# my_helper "bad-arg"
	# local rc=$?
	local rc=1       # placeholder — replace with actual call above

	if [[ "$rc" -eq "$expected" ]]; then
		print_result "B: example failure case returns non-zero" 0
	else
		print_result "B: example failure case returns non-zero" 1 "Expected rc=$expected, got $rc"
	fi
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	if [[ ! -f "${SCRIPT_UNDER_TEST}" ]]; then
		printf 'ERROR: script under test not found at %s\n' "${SCRIPT_UNDER_TEST}" >&2
		exit 1
	fi

	setup_test_env
	trap teardown_test_env EXIT

	# Extract the specific helpers you need (remove if sourcing the full script):
	# define_helper_under_test "my_function_name" || {
	#     printf 'ERROR: could not define helpers under test\n' >&2
	#     exit 1
	# }

	test_A_example_success_case
	test_B_example_failure_case

	printf '\n=== %d test(s), %d failure(s) ===\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
