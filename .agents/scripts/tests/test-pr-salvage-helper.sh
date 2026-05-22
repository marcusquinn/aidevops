#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TEST_SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly TEST_SCRIPT_DIR

# shellcheck source=../shared-constants.sh
source "${TEST_SCRIPT_DIR}/shared-constants.sh"

TESTS_RUN=0
TESTS_FAILED=0
GH_CLOSED_LIST_ARGS_FILE=""

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
		if [[ " ${*} " == *" view 54 "* ]]; then
			printf '%s\n' '{"number":54,"title":"Recoverable unsuppressed work","headRefName":"feature/keep-me","closedAt":"2026-05-01T13:00:00Z","mergedAt":null,"additions":70,"deletions":0,"author":{"login":"worker-b"},"labels":[],"state":"CLOSED"}'
			return 0
		fi
		if [[ " ${*} " == *" view 55 "* ]]; then
			printf '%s\n' '{"number":55,"title":"Already merged work","headRefName":"feature/merged","closedAt":"2026-05-01T14:00:00Z","mergedAt":"2026-05-01T15:00:00Z","additions":90,"deletions":0,"author":{"login":"worker-c"},"labels":[],"state":"MERGED"}'
			return 0
		fi
		if [[ " ${*} " == *" --state closed "* ]]; then
			printf ' %s ' "$*" >"$GH_CLOSED_LIST_ARGS_FILE"
			printf '%s\n' '[
				{"number":53,"title":"Add buffalo logo favicon","headRefName":"feature/buffalo-favicon","closedAt":"2026-05-01T12:00:00Z","mergedAt":null,"additions":7,"deletions":0,"author":{"login":"worker-a"},"labels":[],"state":"CLOSED"},
				{"number":54,"title":"Recoverable unsuppressed work","headRefName":"feature/keep-me","closedAt":"2026-05-01T13:00:00Z","mergedAt":null,"additions":70,"deletions":0,"author":{"login":"worker-b"},"labels":[],"state":"CLOSED"}
			]'
			return 0
		fi
		if [[ " ${*} " == *" --state open "* ]]; then
			printf '%s\n' '0'
			return 0
		fi
		;;
	issue)
		if [[ " ${*} " == *" recover OR recovery "* ]]; then
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

test_closed_pr_list_requests_state_field() {
	# shellcheck source=/dev/null
	source "${TEST_SCRIPT_DIR}/pr-salvage-helper.sh"

	local gh_closed_list_args
	: >"$GH_CLOSED_LIST_ARGS_FILE"
	scan_repo "example/repo" 30 >/dev/null
	gh_closed_list_args=$(<"$GH_CLOSED_LIST_ARGS_FILE")

	if [[ "$gh_closed_list_args" == *"--json number,title,headRefName,closedAt,mergedAt,additions,deletions,author,labels,state"* ]]; then
		print_result "closed PR list requests state for safety filter" 0
	else
		print_result "closed PR list requests state for safety filter" 1 "gh pr list args did not include state: ${gh_closed_list_args}"
	fi
	: >"$GH_CLOSED_LIST_ARGS_FILE"
	return 0
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

test_explicit_pr_numbers_fetch_exact_records() {
	# shellcheck source=/dev/null
	source "${TEST_SCRIPT_DIR}/pr-salvage-helper.sh"

	local result
	result=$(scan_repo "example/repo" 30 "54 55")

	local numbers
	numbers=$(printf '%s' "$result" | jq -r '[.[].number] | join(",")')
	if [[ "$numbers" == "54" ]]; then
		print_result "explicit PR numbers fetch exact closed-unmerged records" 0
	else
		print_result "explicit PR numbers fetch exact closed-unmerged records" 1 "expected only PR 54, got '${numbers}'"
	fi
	return 0
}

test_cmd_scan_accepts_hash_prefixed_pr_numbers() {
	# shellcheck source=/dev/null
	source "${TEST_SCRIPT_DIR}/pr-salvage-helper.sh"

	local result
	result=$(cmd_scan --repo example/repo --json 54 '#55')

	local numbers
	numbers=$(printf '%s' "$result" | jq -r '[.[].number] | join(",")')
	if [[ "$numbers" == "54" ]]; then
		print_result "scan command accepts hash-prefixed explicit PR numbers" 0
	else
		print_result "scan command accepts hash-prefixed explicit PR numbers" 1 "expected only PR 54, got '${numbers}'"
	fi
	return 0
}

run_tests() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	GH_CLOSED_LIST_ARGS_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-salvage-gh-args.XXXXXX")
	push_cleanup "rm -f \"${GH_CLOSED_LIST_ARGS_FILE}\""

	test_completed_recovery_issue_suppresses_salvage_candidate
	test_closed_pr_list_requests_state_field
	test_explicit_pr_numbers_fetch_exact_records
	test_cmd_scan_accepts_hash_prefixed_pr_numbers

	printf '\nResults: %s run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	rm -f "$GH_CLOSED_LIST_ARGS_FILE"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

run_tests
exit $?
