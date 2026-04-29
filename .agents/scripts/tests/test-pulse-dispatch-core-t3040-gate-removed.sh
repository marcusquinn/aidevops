#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t3040 regression test: verify that `_check_commit_subject_dedup_gate` is
# NOT called from the dispatch hot path inside `dispatch_with_dedup`.
#
# Background: the gate cost 100-156s per dispatch candidate (production
# data, Apr 2026), making it the dominant cost of the pulse fill-floor
# stage. t3040 removed the call site per the "Intelligence Over
# Determinism" framework principle — workers do their own t2046 duplicate
# discovery, which is more reliable than commit-message regex.
#
# This test exists so that any future change which re-introduces the call
# fails CI with a mentoring error, instead of silently regressing the
# dispatch latency back to the t2955-era baseline.
#
# The helper functions themselves (`_check_commit_subject_dedup_gate`,
# `_is_task_committed_to_main`, etc.) remain in the source — they are
# tested in isolation by test-pulse-wrapper-main-commit-check.sh and may
# be useful for audit/diagnostic tooling. This test only checks that they
# are not invoked from `dispatch_with_dedup` at runtime.

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

# Extract the body of `dispatch_with_dedup` (or its inner gate function
# `_dispatch_dedup_check_layers`) from the source file. Both functions
# live in pulse-dispatch-core.sh; the call site this test guards against
# was originally inside `_dispatch_dedup_check_layers`.
extract_dispatch_function_bodies() {
	awk '
		/^dispatch_with_dedup\(\) \{/,/^}$/ { print }
		/^_dispatch_dedup_check_layers\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT"
}

test_gate_call_absent_from_dispatch_hot_path() {
	local body
	body=$(extract_dispatch_function_bodies)

	if [[ -z "$body" ]]; then
		print_result "extract dispatch function bodies" 1 \
			"Could not extract dispatch_with_dedup or _dispatch_dedup_check_layers from $CORE_SCRIPT"
		return 0
	fi

	# The call site we removed was:
	#   if _check_commit_subject_dedup_gate "$issue_number" ...
	# Match any non-comment line that invokes the function.
	local matches
	matches=$(printf '%s\n' "$body" |
		grep -nE '^[[:space:]]*[^#]*_check_commit_subject_dedup_gate' || true)

	if [[ -z "$matches" ]]; then
		print_result "_check_commit_subject_dedup_gate not called from dispatch hot path" 0
		return 0
	fi

	print_result "_check_commit_subject_dedup_gate not called from dispatch hot path" 1 \
		"t3040 regression: gate call re-introduced. Matches:
${matches}
The gate cost 100-156s per dispatch candidate. If you have a new reason to re-add it, document the perf measurement in the PR body and update this test accordingly."
	return 0
}

test_helper_functions_still_defined() {
	# t3040 keeps the helpers in source — only the call site was removed.
	# This test ensures we did not over-aggressively delete the helpers.
	local missing=0
	local helper
	for helper in \
		_check_commit_subject_dedup_gate \
		_is_task_committed_to_main \
		_has_committed_to_main_cache_label \
		_apply_committed_to_main_cache_label \
		_has_force_dispatch_label; do
		if ! grep -qE "^${helper}\(\) \{" "$CORE_SCRIPT"; then
			printf 'helper missing: %s\n' "$helper"
			missing=$((missing + 1))
		fi
	done

	if [[ "$missing" -eq 0 ]]; then
		print_result "all dedup helper functions still defined in source" 0
		return 0
	fi

	print_result "all dedup helper functions still defined in source" 1 \
		"$missing helper(s) missing. t3040 only removes the call site, not the helpers."
	return 0
}

main() {
	test_gate_call_absent_from_dispatch_hot_path
	test_helper_functions_still_defined

	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
