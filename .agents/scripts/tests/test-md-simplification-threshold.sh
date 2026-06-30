#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-md-simplification-threshold.sh — regression guard for GH#25926 / t18040.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
ISSUES_SCRIPT="${SCRIPTS_DIR}/pulse-simplification-issues.sh"
SCAN_HELPER="${SCRIPTS_DIR}/complexity-scan-helper.sh"
STATE_SCRIPT="${SCRIPTS_DIR}/pulse-simplification-state.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
COMPLEXITY_MD_MIN_LINES="${COMPLEXITY_MD_MIN_LINES:-500}"

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

write_lines() {
	local path="$1"
	local count="$2"
	local i

	: >"$path"
	for i in $(seq 1 "$count"); do
		printf 'line %s\n' "$i" >>"$path"
	done
	return 0
}

setup_test_repo() {
	TEST_ROOT=$(mktemp -d)
	local repo_path="${TEST_ROOT}/repo"
	mkdir -p "${repo_path}/.agents/reference" "${repo_path}/.agents/configs"
	git -C "$repo_path" init -q 2>/dev/null
	git -C "$repo_path" config user.email "test@test.com" 2>/dev/null
	git -C "$repo_path" config user.name "Test" 2>/dev/null
	write_lines "${repo_path}/.agents/reference/under.md" 499
	write_lines "${repo_path}/.agents/reference/at-threshold.md" 500
	git -C "$repo_path" add . 2>/dev/null
	git -C "$repo_path" commit -q -m "init" 2>/dev/null
	printf '%s\n' "$repo_path"
	return 0
}

teardown_test_repo() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

test_threshold_499_skipped_500_included() {
	local repo_path="$1"
	local output

	output=$(COMPLEXITY_MD_MIN_LINES=500 "$SCAN_HELPER" scan "$repo_path" --type md --state-file "${repo_path}/.agents/configs/missing-state.json")
	if [[ "$output" != *".agents/reference/under.md"* && "$output" == *".agents/reference/at-threshold.md"* ]]; then
		print_result "md scan skips 499-line docs and includes 500-line docs" 0
	else
		print_result "md scan skips 499-line docs and includes 500-line docs" 1 "output=${output}"
	fi
	return 0
}

test_unchanged_500_line_doc_is_reported() {
	local repo_path="$1"
	local state_file="${repo_path}/.agents/configs/simplification-state.json"
	local file_path=".agents/reference/at-threshold.md"
	local file_hash
	file_hash=$(git -C "$repo_path" hash-object "${repo_path}/${file_path}")

	cat >"$state_file" <<JSON
{"files":{"${file_path}":{"hash":"${file_hash}","at":"2026-06-30T00:00:00Z","pr":123,"passes":1}}}
JSON

	local output
	output=$(COMPLEXITY_MD_MIN_LINES=500 "$SCAN_HELPER" scan "$repo_path" --type md --state-file "$state_file")
	if [[ "$output" == *"unchanged|${file_path}|500"* ]]; then
		print_result "md scan reports unchanged 500-line docs for next-pass handling" 0
	else
		print_result "md scan reports unchanged 500-line docs for next-pass handling" 1 "output=${output}"
	fi
	return 0
}

test_unchanged_status_becomes_repeat_until_converged() {
	local repo_path="$1"
	local state_file="${repo_path}/.agents/configs/simplification-state.json"
	local file_path=".agents/reference/at-threshold.md"

	# shellcheck source=/dev/null
	source "$STATE_SCRIPT"
	# shellcheck source=/dev/null
	source "$ISSUES_SCRIPT"

	_complexity_scan_has_existing_issue() {
		return 1
	}

	local status
	status=$(_complexity_scan_md_file_status "owner/repo" "$file_path" "$state_file" "$repo_path" "500")
	if [[ "$status" == "repeat" ]]; then
		print_result "unchanged 500-line doc with remaining passes becomes repeat" 0
	else
		print_result "unchanged 500-line doc with remaining passes becomes repeat" 1 "status=${status}"
	fi
	return 0
}

main() {
	printf 'Running Markdown simplification threshold tests (GH#25926 / t18040)...\n\n'

	local repo_path
	repo_path=$(setup_test_repo)

	test_threshold_499_skipped_500_included "$repo_path"
	test_unchanged_500_line_doc_is_reported "$repo_path"
	test_unchanged_status_becomes_repeat_until_converged "$repo_path"

	teardown_test_repo

	printf '\n%d test(s) run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
