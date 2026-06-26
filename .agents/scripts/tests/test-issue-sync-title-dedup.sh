#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/issue-sync-reusable.yml"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

test_title_window_configured() {
	if grep -q 'ISSUE_SYNC_TITLE_DEDUP_WINDOW_SECONDS' "$WORKFLOW_FILE"; then
		print_result "title dedup window configured" 0
	else
		print_result "title dedup window configured" 1
	fi
	return 0
}

test_title_match_sets_duplicate_reason() {
	if grep -q 'same title within' "$WORKFLOW_FILE" && grep -q 'title matches' "$WORKFLOW_FILE"; then
		print_result "same-title duplicate path present" 0
	else
		print_result "same-title duplicate path present" 1
	fi
	return 0
}

test_title_window_not_shadowed_by_fingerprint_window() {
	if grep -q "time_diff\" -gt \"\$TITLE_WINDOW" "$WORKFLOW_FILE" && grep -q "time_diff\" -le \"\$WINDOW" "$WORKFLOW_FILE"; then
		print_result "title window is checked independently from fingerprint window" 0
	else
		print_result "title window is checked independently from fingerprint window" 1
	fi
	return 0
}

test_api_fallback_does_not_append_partial_stdout() {
	if grep -q '_dedup_gh_api_json' "$WORKFLOW_FILE" \
		&& grep -q "gh api \"\$@\" >\"\$tmp_file\"" "$WORKFLOW_FILE" \
		&& ! grep -q "issues_json=\$(gh api" "$WORKFLOW_FILE"; then
		print_result "dedup API fallback discards partial stdout before fallback" 0
	else
		print_result "dedup API fallback discards partial stdout before fallback" 1
	fi
	return 0
}

test_issue_candidate_fetch_uses_get_method() {
	if grep -q -- '--method GET -f state=open' "$WORKFLOW_FILE"; then
		print_result "candidate issue fetch stays a GET request" 0
	else
		print_result "candidate issue fetch stays a GET request" 1
	fi
	return 0
}

main() {
	if [[ ! -f "$WORKFLOW_FILE" ]]; then
		printf 'FATAL: workflow not found: %s\n' "$WORKFLOW_FILE" >&2
		return 1
	fi
	test_title_window_configured
	test_title_match_sets_duplicate_reason
	test_title_window_not_shadowed_by_fingerprint_window
	test_api_fallback_does_not_append_partial_stdout
	test_issue_candidate_fetch_uses_get_method
	printf 'Tests run: %s\n' "$TESTS_RUN"
	printf 'Tests failed: %s\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
