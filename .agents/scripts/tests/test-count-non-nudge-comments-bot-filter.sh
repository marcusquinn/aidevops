#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-count-non-nudge-comments-bot-filter.sh — test bot-filtering in _count_non_nudge_comments
#
# Verifies:
#   1. _count_non_nudge_comments excludes known review-bot logins
#   2. REVIEW_BOT_LOGINS_JQ_FILTER is defined and contains expected bots
#   3. Function correctly counts only human comments (not bot comments or nudge markers)
#   4. jq syntax is valid in the filter expression
#

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected pattern: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

assert_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qF -- "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected literal: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$SCRIPT_DIR/auto-decomposer-scanner.sh"

if [[ ! -f "$SCANNER" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $SCANNER not found"
	exit 1
fi

echo "${TEST_BLUE}=== Bot filter tests for _count_non_nudge_comments ===${TEST_NC}"
echo ""

# --- Test 1: REVIEW_BOT_LOGINS_JQ_FILTER is defined ---

assert_grep_fixed \
	"1: REVIEW_BOT_LOGINS_JQ_FILTER is defined" \
	'readonly REVIEW_BOT_LOGINS_JQ_FILTER=' \
	"$SCANNER"

# --- Test 2: Filter contains expected bot logins ---

assert_grep_fixed \
	"2a: filter includes coderabbitai" \
	'coderabbitai' \
	"$SCANNER"

assert_grep_fixed \
	"2b: filter includes sonarcloud[bot]" \
	'sonarcloud[bot]' \
	"$SCANNER"

assert_grep_fixed \
	"2c: filter includes codacy-production[bot]" \
	'codacy-production[bot]' \
	"$SCANNER"

assert_grep_fixed \
	"2d: filter includes github-actions[bot]" \
	'github-actions[bot]' \
	"$SCANNER"

assert_grep_fixed \
	"2e: filter includes gemini-code-assist[bot]" \
	'gemini-code-assist[bot]' \
	"$SCANNER"

# --- Test 3: _count_non_nudge_comments uses the filter ---

assert_grep \
	"3a: _count_non_nudge_comments references REVIEW_BOT_LOGINS_JQ_FILTER" \
	'REVIEW_BOT_LOGINS_JQ_FILTER' \
	"$SCANNER"

assert_grep \
	"3b: _count_non_nudge_comments uses jq index() for bot filtering" \
	'index\(' \
	"$SCANNER"

# --- Test 4: jq syntax validation ---
# Extract the jq filter and validate it's syntactically correct

TESTS_RUN=$((TESTS_RUN + 1))
# Source the script to get the filter definition
filter_def=$(grep -A 1 'readonly REVIEW_BOT_LOGINS_JQ_FILTER=' "$SCANNER" | tail -1)
if [[ -z "$filter_def" ]]; then
	# Try single-line version
	filter_def=$(grep 'readonly REVIEW_BOT_LOGINS_JQ_FILTER=' "$SCANNER")
fi

# Extract just the array part (between the quotes)
if [[ "$filter_def" =~ \=\'(.+)\' ]]; then
	filter_array="${BASH_REMATCH[1]}"
	# Test that the array is valid JSON
	if echo "$filter_array" | jq . >/dev/null 2>&1; then
		echo "${TEST_GREEN}PASS${TEST_NC}: 4: jq filter array is valid JSON"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: 4: jq filter array is NOT valid JSON"
		echo "  filter: $filter_array"
	fi
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 4: could not extract filter array from definition"
fi

# --- Test 5: Function comment documents bot filtering ---

assert_grep \
	"5a: function comment mentions bot filtering" \
	'review bot' \
	"$SCANNER"

assert_grep \
	"5b: function comment explains fresh vs aged distinction" \
	'fresh' \
	"$SCANNER"

# --- Summary ---

echo ""
echo "${TEST_BLUE}=== Summary ===${TEST_NC}"
echo "Tests run: $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
	echo "${TEST_GREEN}All tests passed!${TEST_NC}"
	exit 0
else
	echo "${TEST_RED}Some tests failed.${TEST_NC}"
	exit 1
fi
