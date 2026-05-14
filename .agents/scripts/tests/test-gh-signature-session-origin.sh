#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-signature-session-origin.sh — GH#23520 regression guard.
#
# Verifies that gh-signature-helper-session.sh trusts the same canonical
# AIDEVOPS_SESSION_ORIGIN contract as the GitHub wrappers. This prevents a
# sandboxed worker from losing legacy HEADLESS/FULL_LOOP_HEADLESS markers and
# falling back to interactive footer wording.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

_is_opencode_runtime() { return 1; }

# shellcheck source=../gh-signature-helper-session.sh
source "${SCRIPTS_DIR}/gh-signature-helper-session.sh" || exit 1

unset FULL_LOOP_HEADLESS AIDEVOPS_HEADLESS OPENCODE_HEADLESS GITHUB_ACTIONS OPENCODE OPENCODE_SESSION_ID
export AIDEVOPS_SESSION_ORIGIN=worker
detected="$(_detect_explicit_session_type)"
if [[ "$detected" == "worker" ]]; then
	print_result "AIDEVOPS_SESSION_ORIGIN=worker -> worker" 0
else
	print_result "AIDEVOPS_SESSION_ORIGIN=worker -> worker" 1 "got '${detected}'"
fi

export AIDEVOPS_SESSION_ORIGIN=interactive
export AIDEVOPS_HEADLESS=true
detected="$(_detect_explicit_session_type)"
if [[ "$detected" == "interactive" ]]; then
	print_result "AIDEVOPS_SESSION_ORIGIN=interactive overrides headless marker" 0
else
	print_result "AIDEVOPS_SESSION_ORIGIN=interactive overrides headless marker" 1 "got '${detected}'"
fi

unset AIDEVOPS_SESSION_ORIGIN AIDEVOPS_HEADLESS
export GITHUB_ACTIONS=true
detected="$(_detect_explicit_session_type)"
if [[ "$detected" == "worker" ]]; then
	print_result "GITHUB_ACTIONS=true -> worker" 0
else
	print_result "GITHUB_ACTIONS=true -> worker" 1 "got '${detected}'"
fi

echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi

printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
