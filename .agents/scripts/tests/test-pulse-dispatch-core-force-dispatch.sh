#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _has_force_dispatch_label() (GH#18644).
#
# The force-dispatch label is a maintainer-only override that bypasses the
# commit-subject false-positive dedup in _is_task_committed_to_main. These
# tests exercise the label-detection helper in isolation — the full dispatch
# gate integration is covered by the characterization tests.

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

# Source only the helper we need. pulse-dispatch-core.sh sources many siblings
# via a guarded `if [[ -z $SCRIPT_DIR ]]` block; those are not relevant for
# unit-testing a pure jq/label helper. We define the function inline from the
# source file to avoid pulling in the entire core module.
define_helper_under_test() {
	# Extract the _has_force_dispatch_label function from the core source
	# and eval it so the test runs against the real code, not a duplicate.
	local helper_src
	helper_src=$(awk '
		/^_has_force_dispatch_label\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _has_force_dispatch_label from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

test_detects_force_dispatch_label() {
	local meta='{"number":18599,"labels":[{"name":"bug"},{"name":"force-dispatch"},{"name":"auto-dispatch"}]}'
	if _has_force_dispatch_label "$meta"; then
		print_result "detects force-dispatch label among other labels" 0
		return 0
	fi
	print_result "detects force-dispatch label among other labels" 1 \
		"Expected exit 0 when force-dispatch is present"
	return 0
}

test_label_absent_returns_nonzero() {
	local meta='{"number":18599,"labels":[{"name":"bug"},{"name":"auto-dispatch"},{"name":"tier:standard"}]}'
	if _has_force_dispatch_label "$meta"; then
		print_result "absent label returns exit 1" 1 \
			"Expected exit 1 when force-dispatch is absent"
		return 0
	fi
	print_result "absent label returns exit 1" 0
	return 0
}

test_empty_labels_array_returns_nonzero() {
	local meta='{"number":18599,"labels":[]}'
	if _has_force_dispatch_label "$meta"; then
		print_result "empty labels array returns exit 1" 1 \
			"Expected exit 1 for empty labels"
		return 0
	fi
	print_result "empty labels array returns exit 1" 0
	return 0
}

test_empty_meta_json_returns_nonzero() {
	if _has_force_dispatch_label ""; then
		print_result "empty meta_json returns exit 1" 1 \
			"Expected exit 1 when meta is empty"
		return 0
	fi
	print_result "empty meta_json returns exit 1" 0
	return 0
}

test_invalid_meta_json_returns_nonzero() {
	# Malformed JSON — jq will fail; helper must not crash or return 0.
	local meta='not valid json'
	if _has_force_dispatch_label "$meta"; then
		print_result "invalid meta_json returns exit 1" 1 \
			"Expected exit 1 on invalid JSON"
		return 0
	fi
	print_result "invalid meta_json returns exit 1" 0
	return 0
}

test_partial_label_name_does_not_match() {
	# Substring match would be a bug — `force-dispatch-queued` is not the
	# override label. jq's index() uses exact equality, so this should be
	# correctly rejected.
	local meta='{"number":18599,"labels":[{"name":"force-dispatch-queued"}]}'
	if _has_force_dispatch_label "$meta"; then
		print_result "partial label name does not match" 1 \
			"Expected exit 1: 'force-dispatch-queued' must not trigger the override"
		return 0
	fi
	print_result "partial label name does not match" 0
	return 0
}

main() {
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_detects_force_dispatch_label
	test_label_absent_returns_nonzero
	test_empty_labels_array_returns_nonzero
	test_empty_meta_json_returns_nonzero
	test_invalid_meta_json_returns_nonzero
	test_partial_label_name_does_not_match

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
