#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#22733: approval verification must distinguish an
# absent approval from an existing approval marker that cannot be verified on
# the current worker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
APPROVAL_HELPER="${SCRIPT_DIR}/../approval-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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

setup_case() {
	TEST_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-approval-verify)
	mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/home"
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${GH_COMMENTS_MODE:-empty}" == "marker" ]]; then
	printf '%s\n' '[{"body":"<!-- aidevops-signed-approval -->"}]'
	exit 0
fi
printf '%s\n' '[]'
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

cleanup_case() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

run_verify() {
	local comments_mode="$1"
	HOME="${TEST_ROOT}/home" \
		PATH="${TEST_ROOT}/bin:$PATH" \
		GH_COMMENTS_MODE="$comments_mode" \
		"$APPROVAL_HELPER" verify 22733 owner/repo 2>/dev/null
	return $?
}

test_no_marker_reports_no_approval_even_without_key() {
	setup_case
	local output rc=0
	output=$(run_verify empty) || rc=$?
	if [[ "$rc" -ne 0 && "$output" == "NO_APPROVAL" ]]; then
		print_result "no marker reports NO_APPROVAL before key check" 0
		cleanup_case
		return 0
	fi
	print_result "no marker reports NO_APPROVAL before key check" 1 "rc=${rc}, output=${output}"
	cleanup_case
	return 0
}

test_marker_without_key_reports_no_key() {
	setup_case
	local output rc=0
	output=$(run_verify marker) || rc=$?
	if [[ "$rc" -ne 0 && "$output" == "NO_KEY" ]]; then
		print_result "marker without key reports NO_KEY" 0
		cleanup_case
		return 0
	fi
	print_result "marker without key reports NO_KEY" 1 "rc=${rc}, output=${output}"
	cleanup_case
	return 0
}

main() {
	test_no_marker_reports_no_approval_even_without_key
	test_marker_without_key_reports_no_key

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
