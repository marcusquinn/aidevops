#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-config-helper-tmp-home.sh — GH#25518 regression guard.
#
# Ensures config-helper.sh applies the same /tmp ownership validation to HOME=/tmp
# as it already applies to children of /tmp. The previous /tmp/* glob skipped the
# directory /tmp itself, allowing an unsafe shared config root to bypass the guard.
# The runtime rejection assertion is conditional because root-owned test
# containers can legitimately own /tmp; the source-pattern assertion is the
# portable regression guard for exact-/tmp coverage.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/config-helper.sh"

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

pass() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	return 0
}

[[ -f "$HELPER" ]] || {
	printf 'FATAL: helper not found: %s\n' "$HELPER" >&2
	exit 1
}

printf '%s[test]%s GH#25518 — config-helper rejects unsafe HOME=/tmp\n' "$TEST_BLUE" "$TEST_NC"

if grep -Eq '==[[:space:]]*/tmp([[:space:]]|\|)' "$HELPER"; then
	pass "validation condition explicitly covers exact /tmp"
else
	fail "validation condition does not explicitly cover exact /tmp"
fi

if [[ -O /tmp ]]; then
	pass "HOME=/tmp runtime rejection not asserted because current user owns /tmp"
else
	output=$(env -i HOME=/tmp USER="${USER:-aidevops-test}" UID="${UID:-0}" bash -c "source \"\$1\"" _ "$HELPER" 2>&1)
	status=$?

	if [[ "$status" -ne 0 ]]; then
		pass "HOME=/tmp fails validation when /tmp is not owned by current user"
	else
		fail "HOME=/tmp unexpectedly passed validation"
	fi

	if [[ "$output" == *"Security risk: /tmp is not owned by the current user."* ]]; then
		pass "HOME=/tmp emits the ownership guard error"
	else
		fail "HOME=/tmp output did not include the ownership guard error: ${output}"
	fi
fi

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
