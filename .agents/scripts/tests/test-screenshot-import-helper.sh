#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Unit tests for screenshot-import-helper.sh
#
# Three cases:
#   1. Clean filename   — passthrough, no copy
#   2. U+202F filename  — sanitized, file copied to temp dir, clean path returned
#   3. Missing source   — non-existent path with U+202F, exit non-zero with error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../screenshot-import-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

# U+202F (narrow no-break space) as raw UTF-8 bytes.
readonly U202F=$'\xe2\x80\xaf'

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS ${test_name}"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL ${test_name}"
		if [[ -n "$message" ]]; then
			echo "  ${message}"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_TMPDIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	if [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR}" ]]; then
		rm -rf "${TEST_TMPDIR}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 1: clean filename — no U+202F → path returned unchanged, no copy made
# ---------------------------------------------------------------------------
test_clean_filename_passthrough() {
	local clean_src="${TEST_TMPDIR}/Screenshot_2026-04-28_at_8.16.59_AM.png"
	# Create a real file with a clean name.
	printf 'pixel' >"${clean_src}"

	local result
	result=$(HOME="${TEST_TMPDIR}" bash "${HELPER}" sanitize "${clean_src}" 2>/dev/null)

	if [[ "${result}" == "${clean_src}" ]]; then
		print_result "clean filename: returned unchanged" 0
	else
		print_result "clean filename: returned unchanged" 1 \
			"expected '${clean_src}', got '${result}'"
	fi

	# Verify no copy was created (only the original file exists).
	local copy_count
	copy_count=$(find "${TEST_TMPDIR}" -type f | wc -l | tr -d ' ')
	if [[ "${copy_count}" -eq 1 ]]; then
		print_result "clean filename: no copy created" 0
	else
		print_result "clean filename: no copy created" 1 \
			"expected 1 file in tmpdir, found ${copy_count}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 2: U+202F filename — sanitized, file copied, clean path returned
# ---------------------------------------------------------------------------
test_u202f_filename_sanitized() {
	# Build a filename with U+202F before AM (same pattern macOS produces).
	local dirty_name="Screenshot 2026-04-28 at 8.16.59${U202F}AM.png"
	# Use a dedicated subdirectory so this file does not bleed into case 3.
	local case_dir="${TEST_TMPDIR}/case2"
	mkdir -p "${case_dir}"
	local dirty_src="${case_dir}/${dirty_name}"
	printf 'pixel' >"${dirty_src}"

	local result
	result=$(HOME="${case_dir}" bash "${HELPER}" sanitize "${dirty_src}" 2>/dev/null)

	# Result must not contain U+202F.
	if ! printf '%s' "${result}" | LC_ALL=C grep -q "${U202F}"; then
		print_result "u202f filename: result path has no U+202F" 0
	else
		print_result "u202f filename: result path has no U+202F" 1 \
			"result still contains U+202F bytes: ${result}"
	fi

	# Result must point to an existing file.
	if [[ -f "${result}" ]]; then
		print_result "u202f filename: copied file exists at clean path" 0
	else
		print_result "u202f filename: copied file exists at clean path" 1 \
			"file not found at returned path: ${result}"
	fi

	# Clean basename must equal dirty basename with U+202F removed.
	local expected_basename="Screenshot 2026-04-28 at 8.16.59AM.png"
	local actual_basename
	actual_basename=$(basename "${result}")
	if [[ "${actual_basename}" == "${expected_basename}" ]]; then
		print_result "u202f filename: clean basename is correct" 0
	else
		print_result "u202f filename: clean basename is correct" 1 \
			"expected '${expected_basename}', got '${actual_basename}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 3: missing source file with U+202F — exit non-zero with clear error
# ---------------------------------------------------------------------------
test_missing_file_exits_nonzero() {
	# Use a fresh subdirectory so the file definitely does not exist.
	local case_dir="${TEST_TMPDIR}/case3"
	mkdir -p "${case_dir}"
	local missing_src="${case_dir}/Screenshot 2026-04-28 at 8.16.59${U202F}AM.png"
	# Explicitly ensure the file does not exist.

	local rc=0
	local stderr_output
	stderr_output=$(HOME="${case_dir}" bash "${HELPER}" sanitize "${missing_src}" 2>&1 >/dev/null) || rc=$?

	if [[ "${rc}" -ne 0 ]]; then
		print_result "missing file: exits non-zero" 0
	else
		print_result "missing file: exits non-zero" 1 \
			"expected non-zero exit, got 0"
	fi

	# Error output must mention "not found" or "File not found".
	if echo "${stderr_output}" | grep -qi "not found"; then
		print_result "missing file: error mentions 'not found'" 0
	else
		print_result "missing file: error mentions 'not found'" 1 \
			"expected 'not found' in stderr, got: ${stderr_output}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Case 4: help / no args — exits 0 and prints usage
# ---------------------------------------------------------------------------
test_help_exits_zero() {
	local rc=0
	local output
	output=$(bash "${HELPER}" help 2>&1) || rc=$?

	if [[ "${rc}" -eq 0 ]]; then
		print_result "help: exits 0" 0
	else
		print_result "help: exits 0" 1 "got exit code ${rc}"
	fi

	if echo "${output}" | grep -q "sanitize"; then
		print_result "help: output mentions 'sanitize'" 0
	else
		print_result "help: output mentions 'sanitize'" 1 \
			"'sanitize' not found in help output"
	fi
	return 0
}

main() {
	setup

	test_clean_filename_passthrough
	test_u202f_filename_sanitized
	test_missing_file_exits_nonzero
	test_help_exits_zero

	echo ""
	echo "Tests run: ${TESTS_RUN}, passed: ${TESTS_PASSED}, failed: ${TESTS_FAILED}"

	if [[ "${TESTS_FAILED}" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
