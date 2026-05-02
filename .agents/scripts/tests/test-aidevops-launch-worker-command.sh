#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for the first-class `aidevops launch-worker` command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
AIDEVOPS_SH="${REPO_ROOT}/aidevops.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_NC='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

_result() {
	local name="$1"
	local failed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$failed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_NC" "$name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_NC" "$name" >&2
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message" >&2
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

test_help_lists_launch_worker() {
	local out rc=0
	out=$(bash "$AIDEVOPS_SH" help 2>&1) || rc=$?
	local failed=1
	[[ "$rc" -eq 0 && "$out" == *"launch-worker"* ]] && failed=0
	_result "help lists launch-worker command" "$failed" "rc=$rc"
	return 0
}

test_launch_worker_help() {
	local out rc=0
	out=$(bash "$AIDEVOPS_SH" launch-worker --help 2>&1) || rc=$?
	local failed=1
	[[ "$rc" -eq 0 && "$out" == *"Usage: aidevops launch-worker"* && "$out" == *"--batch"* && "$out" == *"defaults to the current git repository"* ]] && failed=0
	_result "launch-worker help exposes batch syntax and default repo" "$failed" "rc=$rc out=$out"
	return 0
}

test_launch_worker_invalid_batch_value() {
	local out rc=0
	out=$(bash "$AIDEVOPS_SH" launch-worker --batch --dry-run marcusquinn/aidevops 2>&1) || rc=$?
	local failed=1
	[[ "$rc" -eq 2 && "$out" == *"--batch requires"* ]] && failed=0
	_result "launch-worker rejects missing --batch value" "$failed" "rc=$rc out=$out"
	return 0
}

main() {
	test_help_lists_launch_worker
	test_launch_worker_help
	test_launch_worker_invalid_batch_value

	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
