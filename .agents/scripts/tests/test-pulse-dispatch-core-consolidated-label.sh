#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _has_consolidated_label() (GH#23187).
#
# Consolidated source issues are archival records, while marked successor specs
# with an explicit auto-dispatch handoff are implementation tasks.

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

test_ci_feedback_consolidated_is_dispatchable() {
	local meta='{"number":4649,"labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"source:ci-feedback"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "CI-feedback consolidated issues are dispatchable" 1 \
			"Expected exit 1 for consolidated CI-feedback implementation specs"
		return 0
	fi
	print_result "CI-feedback consolidated issues are dispatchable" 0
	return 0
}

test_marked_auto_dispatch_successor_is_dispatchable() {
	local meta='{"number":27903,"body":"_Supersedes #27896 — this issue is the consolidated spec._\n\n## What\nImplement the fix.","labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"auto-dispatch"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "marked auto-dispatch successor is dispatchable" 1 \
			"Expected exit 1 for a canonical consolidated successor spec"
		return 0
	fi
	print_result "marked auto-dispatch successor is dispatchable" 0
	return 0
}

test_auto_dispatch_parent_without_marker_remains_blocked() {
	local meta='{"number":27896,"body":"Original issue body.","labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"auto-dispatch"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "auto-dispatch parent without marker remains blocked" 0
		return 0
	fi
	print_result "auto-dispatch parent without marker remains blocked" 1 \
		"Expected exit 0 when auto-dispatch lacks the successor marker"
	return 0
}

test_marker_without_auto_dispatch_remains_blocked() {
	local meta='{"number":27903,"body":"_Supersedes #27896 — this issue is the consolidated spec._","labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "marker without auto-dispatch remains blocked" 0
		return 0
	fi
	print_result "marker without auto-dispatch remains blocked" 1 \
		"Expected exit 0 when the successor lacks an explicit handoff"
	return 0
}

test_instructional_marker_text_does_not_bypass() {
	# shellcheck disable=SC2016 # Literal backticks are part of the body fixture.
	local meta='{"number":27848,"body":"Start the body with: `_Supersedes #27799 — this issue is the consolidated spec._`","labels":[{"name":"status:available"},{"name":"origin:worker"},{"name":"consolidated"},{"name":"auto-dispatch"}]}'
	if _has_consolidated_label "$meta"; then
		print_result "instructional marker text does not bypass" 0
		return 0
	fi
	print_result "instructional marker text does not bypass" 1 \
		"Expected exit 0 for a marker embedded in instructional prose"
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
	test_ci_feedback_consolidated_is_dispatchable
	test_marked_auto_dispatch_successor_is_dispatchable
	test_auto_dispatch_parent_without_marker_remains_blocked
	test_marker_without_auto_dispatch_remains_blocked
	test_instructional_marker_text_does_not_bypass
	test_partial_label_name_does_not_match
	test_empty_or_invalid_meta_returns_nonzero

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
