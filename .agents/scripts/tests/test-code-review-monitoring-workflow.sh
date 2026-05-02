#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression checks for the Code Review Monitoring auto-fix workflow.
#
# Run: bash .agents/scripts/tests/test-code-review-monitoring-workflow.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/code-review-monitoring.yml"

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

assert_contains() {
	local test_name="$1"
	local needle="$2"

	if grep -qF -- "$needle" "$WORKFLOW_FILE"; then
		print_result "$test_name" 0
		return 0
	fi

	print_result "$test_name" 1 "Missing expected text: $needle"
	return 0
}

assert_not_contains() {
	local test_name="$1"
	local needle="$2"

	if grep -qF -- "$needle" "$WORKFLOW_FILE"; then
		print_result "$test_name" 1 "Unexpected text present: $needle"
		return 0
	fi

	print_result "$test_name" 0
	return 0
}

main() {
	if [[ ! -f "$WORKFLOW_FILE" ]]; then
		printf '%bFAIL%b workflow file missing: %s\n' "$TEST_RED" "$TEST_RESET" "$WORKFLOW_FILE"
		return 1
	fi

	assert_not_contains "workflow avoids chmod-only artifacts" "chmod +x .agents/scripts/*.sh"
	assert_contains "monitor step invokes script through bash" "bash ./.agents/scripts/monitor-code-review.sh monitor"
	assert_contains "fix step invokes script through bash" "bash ./.agents/scripts/monitor-code-review.sh fix"
	assert_contains "report step invokes script through bash" "bash ./.agents/scripts/monitor-code-review.sh report > quality-report.md"
	assert_contains "validate step ignores chmod-only diffs" "git -c core.fileMode=false diff --quiet"
	assert_contains "push retry aborts conflicted rebase" "git rebase --abort || true"
	assert_contains "push retry uses explicit HEAD to main ref" "git push origin HEAD:main"

	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
