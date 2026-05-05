#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TEST_SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly TEST_SCRIPT_DIR

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

gh() {
	local area="${1:-}"
	shift || true

	case "$area" in
	pr)
		if [[ " ${*} " == *" --state closed "* ]]; then
			printf '%s\n' '[
				{"number":53,"title":"Add buffalo logo favicon","headRefName":"feature/buffalo-favicon","closedAt":"2026-05-01T12:00:00Z","mergedAt":null,"additions":7,"deletions":0,"author":{"login":"worker-a"},"labels":[]},
				{"number":54,"title":"Recoverable unsuppressed work","headRefName":"feature/keep-me","closedAt":"2026-05-01T13:00:00Z","mergedAt":null,"additions":70,"deletions":0,"author":{"login":"worker-b"},"labels":[]}
			]'
			return 0
		fi
		if [[ " ${*} " == *" --state open "* ]]; then
			printf '%s\n' '0'
			return 0
		fi
		;;
	issue)
		if [[ " ${*} " == *"PR #53"* ]]; then
			printf '%s\n' '[{"number":60,"title":"Recover buffalo logo favicon from closed PR #53","body":"Worker completion audit: completed recovery.","state":"CLOSED","labels":[{"name":"status:done"}]}]'
			return 0
		fi
		printf '%s\n' '[]'
		return 0
		;;
	api)
		printf '%s\n' '{"name":"main"}'
		return 0
		;;
	esac

	return 1
}

test_completed_recovery_issue_suppresses_salvage_candidate() {
	# shellcheck source=/dev/null
	source "${TEST_SCRIPT_DIR}/pr-salvage-helper.sh"

	local result
	result=$(scan_repo "example/repo" 30)

	local numbers
	numbers=$(printf '%s' "$result" | jq -r '[.[].number] | join(",")')
	if [[ "$numbers" == "54" ]]; then
		print_result "GH#22939: completed recovery issue suppresses matching closed PR" 0
	else
		print_result "GH#22939: completed recovery issue suppresses matching closed PR" 1 "expected only PR 54, got '${numbers}'"
	fi
	return 0
}

test_completed_recovery_issue_suppresses_salvage_candidate

printf '\nResults: %s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
