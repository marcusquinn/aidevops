#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-registry-unset-home.sh — GH#25457 regression guard.
#
# Verifies that the worktree registry does not fall back to a shared /tmp path
# when HOME is unset.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REGISTRY_LIB="${SCRIPT_DIR}/../shared-worktree-registry.sh"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

fallback_uid="$(id -u 2>/dev/null || printf 'shared')"
expected_dir="/tmp/aidevops-${fallback_uid}/.aidevops/.agent-workspace"
actual_dir="$(env -u HOME -u USER -u LOGNAME REGISTRY_LIB="$REGISTRY_LIB" bash -c "source \"\$REGISTRY_LIB\"; printf '%s' \"\$WORKTREE_REGISTRY_DIR\"")"

if [[ "$actual_dir" == "$expected_dir" ]]; then
	print_result "unset HOME uses user-scoped /tmp fallback" 0
else
	print_result "unset HOME uses user-scoped /tmp fallback" 1 "expected=${expected_dir} actual=${actual_dir}"
fi

if [[ "$actual_dir" != "/tmp/.aidevops/.agent-workspace" ]]; then
	print_result "unset HOME avoids shared /tmp registry path" 0
else
	print_result "unset HOME avoids shared /tmp registry path" 1 "actual=${actual_dir}"
fi

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi

printf '%d/%d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
