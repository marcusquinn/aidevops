#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the GH#22948 pulse dispatch guard that refuses to dispatch workers
# against pull requests in the shared Issues API number space.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
MOCK_GH_TARGET_IS_PR="0"

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

define_helper_under_test() {
	local helper_src=""
	helper_src=$(awk '
		/^_dispatch_target_is_pull_request\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _dispatch_target_is_pull_request from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

# shellcheck disable=SC2317
gh() {
	local gh_subcommand="${1:-}"
	local gh_resource="${2:-}"
	if [[ "$gh_subcommand" == "api" && "$gh_resource" == repos/*/issues/* ]]; then
		case "$MOCK_GH_TARGET_IS_PR" in
		1) printf '{"number":456,"pull_request":{"url":"https://api.example.invalid/pulls/456"}}\n' ;;
		api_fail) return 1 ;;
		*) printf '{"number":456}\n' ;;
		esac
		return 0
	fi
	printf 'unexpected gh call: %s\n' "$*" >&2
	return 1
}

test_detects_pull_request_target() {
	MOCK_GH_TARGET_IS_PR="1"
	local rc=0
	_dispatch_target_is_pull_request 456 owner/repo >/dev/null 2>&1 || rc=$?
	local check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "pulse guard detects pull_request marker" "$check" "rc=$rc"
	return 0
}

test_allows_plain_issue_target() {
	MOCK_GH_TARGET_IS_PR="0"
	local rc=0
	_dispatch_target_is_pull_request 456 owner/repo >/dev/null 2>&1 || rc=$?
	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "pulse guard allows plain issue target" "$check" "rc=$rc"
	return 0
}

test_fails_closed_when_verification_errors() {
	MOCK_GH_TARGET_IS_PR="api_fail"
	local rc=0
	_dispatch_target_is_pull_request 456 owner/repo >/dev/null 2>&1 || rc=$?
	local check=1
	[[ "$rc" -eq 2 ]] && check=0
	print_result "pulse guard reports verification error" "$check" "rc=$rc"
	return 0
}

test_dispatch_path_calls_guard_before_launch() {
	local call_line launch_line check=1
	call_line=$(grep -n '_dispatch_target_is_pull_request' "$CORE_SCRIPT" | tail -n 1 | cut -d: -f1)
	launch_line=$(grep -n '_dispatch_launch_worker' "$CORE_SCRIPT" | tail -n 1 | cut -d: -f1)
	if [[ "$call_line" =~ ^[0-9]+$ && "$launch_line" =~ ^[0-9]+$ && "$call_line" -lt "$launch_line" ]]; then
		check=0
	fi
	print_result "dispatch path checks PR guard before worker launch" "$check" \
		"call_line=${call_line:-missing} launch_line=${launch_line:-missing}"
	return 0
}

main() {
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_detects_pull_request_target
	test_allows_plain_issue_target
	test_fails_closed_when_verification_errors
	test_dispatch_path_calls_guard_before_launch

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
