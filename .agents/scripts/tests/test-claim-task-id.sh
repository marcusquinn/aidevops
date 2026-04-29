#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for claim-task-id.sh issue-number extraction (GH#21760).
#
# Background
# ----------
# Two reports (GH#21736, GH#21737) showed claim-task-id.sh linking downstream
# work to GH#2157 (an unrelated merged issue) instead of the issue it just
# created. Root cause: `gh_create_issue ... 2>&1` merges stderr into
# $issue_url, and `grep -oE '[0-9]+$'` matched trailing digits on the static
# log line "[INFO] auto-dispatch label present -- skipping self-assignment per
# t2157". The fix anchors extraction to the GitHub issue URL pattern
# `https://github.com/.../issues/N` so no log line can be mistaken for the
# issue number.
#
# What this test guards
# ---------------------
# The extraction regex must return the correct issue number from the GitHub URL
# regardless of stderr/stdout interleave ordering. These tests pin the contract
# across three orderings that can occur in practice.

set -euo pipefail

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
	if [[ "$passed" == "true" ]]; then
		printf "${TEST_GREEN}PASS${TEST_RESET} %s\n" "$test_name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf "${TEST_RED}FAIL${TEST_RESET} %s" "$test_name"
		[[ -n "$message" ]] && printf " — %s" "$message"
		printf "\n"
	fi
	return 0
}

# --------------------------------------------------------------------------
# Extract the issue-number extraction logic from claim-task-id.sh.
# We replicate the exact pipeline used in the script so the test pins the
# actual production code behaviour.
# --------------------------------------------------------------------------
extract_issue_num() {
	local issue_url="$1"
	local issue_num
	issue_num=$(printf '%s\n' "$issue_url" | grep -oE 'https://github\.com/[^/]+/[^/]+/issues/[0-9]+' | grep -oE '[0-9]+$' | tail -1 || echo "")
	printf '%s' "$issue_num"
	return 0
}

# --------------------------------------------------------------------------
# Case A: URL-after-stderr interleave
# stderr log appears before the URL in the captured output.
# --------------------------------------------------------------------------
test_url_after_stderr() {
	local input
	input=$(printf '%s\n%s' \
		'[INFO] auto-dispatch label present — skipping self-assignment per t2157' \
		'https://github.com/marcusquinn/aidevops/issues/21800')
	local result
	result=$(extract_issue_num "$input")
	if [[ "$result" == "21800" ]]; then
		print_result "Case A: URL-after-stderr — extracts 21800" "true"
	else
		print_result "Case A: URL-after-stderr — extracts 21800" "false" "got '$result'"
	fi
	return 0
}

# --------------------------------------------------------------------------
# Case B: URL-before-stderr interleave
# URL appears before the log line.
# --------------------------------------------------------------------------
test_url_before_stderr() {
	local input
	input=$(printf '%s\n%s' \
		'https://github.com/marcusquinn/aidevops/issues/21800' \
		'[INFO] auto-dispatch label present — skipping self-assignment per t2157')
	local result
	result=$(extract_issue_num "$input")
	if [[ "$result" == "21800" ]]; then
		print_result "Case B: URL-before-stderr — extracts 21800" "true"
	else
		print_result "Case B: URL-before-stderr — extracts 21800" "false" "got '$result'"
	fi
	return 0
}

# --------------------------------------------------------------------------
# Case C: Stderr-only (no URL)
# Only log lines, no URL — should return empty string and not crash.
# --------------------------------------------------------------------------
test_stderr_only() {
	local input='[INFO] auto-dispatch label present — skipping self-assignment per t2157'
	local result
	result=$(extract_issue_num "$input")
	if [[ -z "$result" ]]; then
		print_result "Case C: stderr-only (no URL) — returns empty" "true"
	else
		print_result "Case C: stderr-only (no URL) — returns empty" "false" "got '$result'"
	fi
	return 0
}

# --------------------------------------------------------------------------
# Case D: Multiple stderr lines with URL in the middle
# More complex interleave with multiple log lines.
# --------------------------------------------------------------------------
test_url_between_stderr() {
	local input
	input=$(printf '%s\n%s\n%s' \
		'[INFO] auto-dispatch label present — skipping self-assignment per t2157' \
		'https://github.com/marcusquinn/aidevops/issues/21800' \
		'[INFO] some other log line ending in 9999')
	local result
	result=$(extract_issue_num "$input")
	if [[ "$result" == "21800" ]]; then
		print_result "Case D: URL between stderr lines — extracts 21800" "true"
	else
		print_result "Case D: URL between stderr lines — extracts 21800" "false" "got '$result'"
	fi
	return 0
}

# --------------------------------------------------------------------------
# Case E: Clean URL only (no stderr noise)
# The happy path — just a URL, no interleaved stderr.
# --------------------------------------------------------------------------
test_clean_url_only() {
	local input='https://github.com/marcusquinn/aidevops/issues/21800'
	local result
	result=$(extract_issue_num "$input")
	if [[ "$result" == "21800" ]]; then
		print_result "Case E: clean URL only — extracts 21800" "true"
	else
		print_result "Case E: clean URL only — extracts 21800" "false" "got '$result'"
	fi
	return 0
}

# --------------------------------------------------------------------------
# Case F: Verify the OLD regex would have failed Case A
# This documents the exact failure mode that GH#21760 reported.
# --------------------------------------------------------------------------
test_old_regex_would_fail() {
	local input
	input=$(printf '%s\n%s' \
		'[INFO] auto-dispatch label present — skipping self-assignment per t2157' \
		'https://github.com/marcusquinn/aidevops/issues/21800')
	# Old regex: grep -oE '[0-9]+$'
	# This would match both "2157" and "21800", and depending on interleave
	# the last match could be either one.
	local old_result
	old_result=$(echo "$input" | grep -oE '[0-9]+$' | tail -1 || echo "")
	# The old regex with tail -1 gets 21800 here because URL is last line,
	# but without tail -1 (the original code had no tail), it gets any match.
	# The original code: echo "$issue_url" | grep -oE '[0-9]+$'
	# grep -oE outputs ALL matches, one per line. The original code captured
	# ALL of them into issue_num. With the URL last, $issue_num would be
	# "2157\n21800" — a multi-line string that breaks awk downstream.
	local old_no_tail
	old_no_tail=$(echo "$input" | grep -oE '[0-9]+$' || echo "")
	local line_count
	line_count=$(printf '%s\n' "$old_no_tail" | wc -l | tr -d ' ')
	if [[ "$line_count" -gt 1 ]]; then
		print_result "Case F: old regex produces multi-line output (documents bug)" "true"
	else
		print_result "Case F: old regex produces multi-line output (documents bug)" "false" \
			"expected multi-line, got $line_count line(s): '$old_no_tail'"
	fi
	return 0
}

# --------------------------------------------------------------------------
# Run all tests
# --------------------------------------------------------------------------
main() {
	printf "=== claim-task-id.sh issue-number extraction tests (GH#21760) ===\n\n"

	test_url_after_stderr
	test_url_before_stderr
	test_stderr_only
	test_url_between_stderr
	test_clean_url_only
	test_old_regex_would_fail

	printf "\n=== Results: %d tests, %d failures ===\n" "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
exit $?
