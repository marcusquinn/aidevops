#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SH="${SCRIPT_DIR}/../report-render-helper.sh"
FIXTURE_DIR="${SCRIPT_DIR}/fixtures"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local _test_name="$1"
	local _passed="$2"
	local _message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$_passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$_test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$_test_name"
	if [[ -n "$_message" ]]; then
		printf '       %s\n' "$_message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

assert_contains() {
	local _file="$1"
	local _needle="$2"
	local _label="$3"
	if grep -qF "$_needle" "$_file"; then
		print_result "$_label" 0
		return 0
	fi
	print_result "$_label" 1 "Missing '${_needle}' in ${_file}"
	return 0
}

test_render_markdown_fixture() {
	local _out="${TEST_ROOT}/sample-md.html"
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.md" --output "$_out"
	assert_contains "$_out" "sticky-toc" "Markdown render includes sticky TOC"
	assert_contains "$_out" "@media print" "Markdown render includes print CSS"
	assert_contains "$_out" "Evidence: Verified" "Markdown render includes verified badge"
	assert_contains "$_out" "Evidence: Partial" "Markdown render includes partial badge"
	assert_contains "$_out" "Evidence: Inferred" "Markdown render includes inferred badge"
	assert_contains "$_out" "Evidence: Missing" "Markdown render includes missing badge"
	assert_contains "$_out" "source-card" "Markdown render includes source cards"
	return 0
}

test_render_json_fixture() {
	local _out="${TEST_ROOT}/sample-json.html"
	"$HELPER_SH" render "${FIXTURE_DIR}/llm-visibility-report-sample.json" --output "$_out"
	assert_contains "$_out" "sticky-toc" "JSON render includes sticky TOC"
	assert_contains "$_out" "@media print" "JSON render includes print CSS"
	assert_contains "$_out" "Evidence: Verified" "JSON render includes verified badge"
	assert_contains "$_out" "Evidence: Partial" "JSON render includes partial badge"
	assert_contains "$_out" "Evidence: Inferred" "JSON render includes inferred badge"
	assert_contains "$_out" "Evidence: Missing" "JSON render includes missing badge"
	assert_contains "$_out" "source-card" "JSON render includes source cards"
	return 0
}

test_validate_rejects_unknown_badge() {
	local _bad="${TEST_ROOT}/bad.md"
	printf '# Bad\n\n{{evidence:unknown}}\n' >"$_bad"
	local _result=0
	"$HELPER_SH" validate "$_bad" >/dev/null 2>&1 || _result=$?
	if [[ "$_result" -ne 1 ]]; then
		print_result "Validate rejects unknown badge" 1 "Expected exit 1, got ${_result}"
		return 0
	fi
	print_result "Validate rejects unknown badge" 0
	return 0
}

test_sample_and_css_commands() {
	local _sample="${TEST_ROOT}/sample.md"
	local _css="${TEST_ROOT}/print.css"
	"$HELPER_SH" sample markdown >"$_sample"
	"$HELPER_SH" print-css >"$_css"
	assert_contains "$_sample" "{{evidence:verified}}" "Sample command emits Markdown report"
	assert_contains "$_css" "@media print" "print-css emits print stylesheet"
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_render_markdown_fixture
	test_render_json_fixture
	test_validate_rejects_unknown_badge
	test_sample_and_css_commands
	printf '\nReport render helper tests: %s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
