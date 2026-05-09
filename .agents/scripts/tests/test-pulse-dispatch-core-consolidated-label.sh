#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _has_consolidated_label() (GH#23187).
#
# Consolidated issues are archival records, not implementation tasks. A stale
# lifecycle label such as status:queued must not make them dispatchable again.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
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

define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_has_consolidated_label\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _has_consolidated_label from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

test_detects_consolidated_label() {
	local meta='{"number":23187,"labels":[{"name":"status:queued"},{"name":"origin:worker"},{"name":"consolidated"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "detects consolidated label among dispatch labels" 0
		return 0
	fi
	print_result "detects consolidated label among dispatch labels" 1 \
		"Expected exit 0 when consolidated is present"
	return 0
}

test_absent_label_returns_nonzero() {
	local meta='{"number":23188,"labels":[{"name":"status:queued"},{"name":"origin:worker"},{"name":"tier:standard"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "absent consolidated label returns exit 1" 1 \
			"Expected exit 1 when consolidated is absent"
		return 0
	fi
	print_result "absent consolidated label returns exit 1" 0
	return 0
}

test_review_feedback_consolidated_is_dispatchable() {
	local meta='{"number":4648,"labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"quality-debt"},{"name":"source:review-feedback"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "review-feedback consolidated issues are dispatchable" 1 \
			"Expected exit 1 for consolidated review-feedback implementation specs"
		return 0
	fi
	print_result "review-feedback consolidated issues are dispatchable" 0
	return 0
}

test_partial_label_name_does_not_match() {
	local meta='{"number":23189,"labels":[{"name":"needs-consolidation"},{"name":"consolidation-task"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "partial consolidation labels do not match" 1 \
			"Expected exit 1 for needs-consolidation/consolidation-task"
		return 0
	fi
	print_result "partial consolidation labels do not match" 0
	return 0
}

test_empty_or_invalid_meta_returns_nonzero() {
	if _has_consolidated_label "" || _has_consolidated_label "not json"; then
		print_result "empty or invalid meta_json returns exit 1" 1 \
			"Expected exit 1 for empty/invalid metadata"
		return 0
	fi
	print_result "empty or invalid meta_json returns exit 1" 0
	return 0
}

main() {
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_detects_consolidated_label
	test_absent_label_returns_nonzero
	test_review_feedback_consolidated_is_dispatchable
	test_partial_label_name_does_not_match
	test_empty_or_invalid_meta_returns_nonzero

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
