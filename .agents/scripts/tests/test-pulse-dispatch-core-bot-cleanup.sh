#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _is_bot_generated_cleanup_issue() (GH#18648 / Fix 3a).
#
# Bot-generated cleanup issues created by post-merge-review-scanner.sh
# are exempt from the ever-NMR permanence trap. These tests verify the
# label-detection helper that gates the exemption.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

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

# Extract the helper from pulse-dispatch-core.sh and eval it so the test
# runs against the real source — same pattern as the force-dispatch tests.
define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_is_bot_generated_cleanup_issue\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _is_bot_generated_cleanup_issue from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

test_detects_review_followup_label() {
	local meta='{"number":2294,"labels":[{"name":"auto-dispatch"},{"name":"review-followup"}]}'
	if _is_bot_generated_cleanup_issue "$meta"; then
		print_result "detects review-followup label" 0
		return 0
	fi
	print_result "detects review-followup label" 1 \
		"Expected exit 0 when review-followup is present"
	return 0
}

test_detects_source_review_scanner_label() {
	local meta='{"number":2294,"labels":[{"name":"bug"},{"name":"source:review-scanner"}]}'
	if _is_bot_generated_cleanup_issue "$meta"; then
		print_result "detects source:review-scanner label" 0
		return 0
	fi
	print_result "detects source:review-scanner label" 1 \
		"Expected exit 0 when source:review-scanner is present"
	return 0
}

test_detects_both_labels() {
	local meta='{"number":2294,"labels":[{"name":"review-followup"},{"name":"source:review-scanner"}]}'
	if _is_bot_generated_cleanup_issue "$meta"; then
		print_result "detects both review-followup and source:review-scanner" 0
		return 0
	fi
	print_result "detects both review-followup and source:review-scanner" 1
	return 0
}

test_ignores_non_cleanup_issue() {
	local meta='{"number":18599,"labels":[{"name":"bug"},{"name":"auto-dispatch"},{"name":"tier:standard"}]}'
	if _is_bot_generated_cleanup_issue "$meta"; then
		print_result "non-cleanup issue returns exit 1" 1 \
			"Expected exit 1 for a regular bug issue"
		return 0
	fi
	print_result "non-cleanup issue returns exit 1" 0
	return 0
}

test_empty_labels_array() {
	local meta='{"number":1,"labels":[]}'
	if _is_bot_generated_cleanup_issue "$meta"; then
		print_result "empty labels array returns exit 1" 1
		return 0
	fi
	print_result "empty labels array returns exit 1" 0
	return 0
}

test_empty_meta_json() {
	if _is_bot_generated_cleanup_issue ""; then
		print_result "empty meta_json returns exit 1" 1
		return 0
	fi
	print_result "empty meta_json returns exit 1" 0
	return 0
}

test_invalid_meta_json() {
	if _is_bot_generated_cleanup_issue "not valid json"; then
		print_result "invalid meta_json returns exit 1" 1
		return 0
	fi
	print_result "invalid meta_json returns exit 1" 0
	return 0
}

test_partial_label_name_does_not_match() {
	# Substring match would be a bug — `review-followup-queued` is not the
	# exemption label. jq's index() uses exact equality.
	local meta='{"number":1,"labels":[{"name":"review-followup-queued"}]}'
	if _is_bot_generated_cleanup_issue "$meta"; then
		print_result "partial 'review-followup-queued' does not match" 1 \
			"Expected exit 1: partial name must not trigger exemption"
		return 0
	fi
	print_result "partial 'review-followup-queued' does not match" 0
	return 0
}

# Regression case representing the exact awardsapp #2294 scenario:
# real issue labels from the stuck queue.
test_awardsapp_2294_scenario() {
	local meta='{"number":2294,"labels":[{"name":"auto-dispatch"},{"name":"origin:worker"},{"name":"origin:interactive"},{"name":"review-followup"},{"name":"source:review-scanner"}]}'
	if _is_bot_generated_cleanup_issue "$meta"; then
		print_result "awardsapp #2294 label set triggers exemption" 0
		return 0
	fi
	print_result "awardsapp #2294 label set triggers exemption" 1 \
		"Expected exit 0: this is the exact stuck-queue scenario Fix 3a addresses"
	return 0
}

main() {
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_detects_review_followup_label
	test_detects_source_review_scanner_label
	test_detects_both_labels
	test_ignores_non_cleanup_issue
	test_empty_labels_array
	test_empty_meta_json
	test_invalid_meta_json
	test_partial_label_name_does_not_match
	test_awardsapp_2294_scenario

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
