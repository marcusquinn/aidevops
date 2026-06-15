#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
SETUP_SH="${REPO_ROOT}/setup.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local result="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		echo -e "${TEST_GREEN}PASS${RESET} ${test_name}"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo -e "${TEST_RED}FAIL${RESET} ${test_name}"
		if [[ -n "$message" ]]; then
			echo "       ${message}"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	TEST_DIR=""
	return 0
}

load_setup_xml_escape() {
	local function_file="${TEST_DIR}/xml-escape-function.sh"
	awk '
		/^_xml_escape\(\) \{/ { capture = 1 }
		capture { print }
		capture && /^}/ { exit }
	' "$SETUP_SH" >"$function_file"

	# shellcheck source=/dev/null
	source "$function_file"
	if ! declare -F _xml_escape >/dev/null 2>&1; then
		return 1
	fi
	return 0
}

restore_patsub_replacement() {
	local previous_state="$1"
	case "$previous_state" in
	on) shopt -s patsub_replacement 2>/dev/null || true ;;
	off) shopt -u patsub_replacement 2>/dev/null || true ;;
	*) ;;
	esac
	return 0
}

test_xml_escape_survives_patsub_replacement() {
	local test_name="xml escape survives patsub_replacement"
	setup

	if ! load_setup_xml_escape; then
		print_result "$test_name" 1 "could not load _xml_escape from setup.sh"
		teardown
		return 0
	fi

	local previous_state="unsupported"
	if shopt -q patsub_replacement 2>/dev/null; then
		previous_state="on"
	elif shopt -u patsub_replacement 2>/dev/null; then
		previous_state="off"
	fi
	shopt -s patsub_replacement 2>/dev/null || true

	local input expected escaped
	input="cmd 'x' \"y\" >/tmp/a&b <tag>"
	expected="cmd &apos;x&apos; &quot;y&quot; &gt;/tmp/a&amp;b &lt;tag&gt;"
	escaped=$(_xml_escape "$input")
	restore_patsub_replacement "$previous_state"

	if [[ "$escaped" != "$expected" ]]; then
		print_result "$test_name" 1 "expected '${expected}', got '${escaped}'"
		teardown
		return 0
	fi

	print_result "$test_name" 0
	teardown
	return 0
}

main() {
	if [[ ! -f "$SETUP_SH" ]]; then
		echo "setup.sh not found: ${SETUP_SH}" >&2
		return 1
	fi

	test_xml_escape_survives_patsub_replacement

	echo ""
	echo "Tests run: ${TESTS_RUN}"
	echo "Passed:    ${TESTS_PASSED}"
	echo "Failed:    ${TESTS_FAILED}"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
