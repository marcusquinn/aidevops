#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for _dispatch_issue_body_missing_worker_context().

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
LIB_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-lib.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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
	local helper_src
	helper_src=$(awk '
		/^_dispatch_issue_body_missing_worker_context\(\) \{/,/^}$/ { print }
	' "$LIB_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _dispatch_issue_body_missing_worker_context from %s\n' "$LIB_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

test_empty_body_is_missing_context() {
	if _dispatch_issue_body_missing_worker_context ""; then
		print_result "empty body is missing context" 0
		return 0
	fi
	print_result "empty body is missing context" 1
	return 0
}

test_explicit_enrichment_marker_is_missing_context() {
	local body="Placeholder task — needs enrichment before dispatch."
	if _dispatch_issue_body_missing_worker_context "$body"; then
		print_result "explicit enrichment marker is missing context" 0
		return 0
	fi
	print_result "explicit enrichment marker is missing context" 1
	return 0
}

test_review_followup_instruction_is_dispatchable() {
	local body
	printf -v body '%s\n' \
		'### Worker Guidance' \
		'' \
		'**Files to modify:**' \
		'' \
		'- .agents/workflows/full-loop.md:35' \
		'' \
		'Exit BLOCKED for "missing implementation context" only when the issue is too vague to identify expected behavior.'
	if _dispatch_issue_body_missing_worker_context "$body"; then
		print_result "review followup instruction is dispatchable" 1 \
			"Instructional mention of missing implementation context must not block dispatch"
		return 0
	fi
	print_result "review followup instruction is dispatchable" 0
	return 0
}

main() {
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_empty_body_is_missing_context
	test_explicit_enrichment_marker_is_missing_context
	test_review_followup_instruction_is_dispatchable

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
