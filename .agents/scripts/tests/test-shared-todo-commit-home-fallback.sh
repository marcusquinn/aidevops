#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Test: shared-todo-commit.sh HOME fallback
# Verifies the TODO lock directory avoids shared /tmp/.aidevops when HOME is
# unset, preventing cross-user permission conflicts and symlink-prone shared
# state.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}/.."
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

# shellcheck disable=SC2016 # Inner shell expands $1 and $TODO_LOCK_DIR after sourcing.
actual=$(env -u HOME USER=tester bash -c 'source "$1"; printf "%s\n" "$TODO_LOCK_DIR"' _ "${SCRIPT_DIR}/shared-todo-commit.sh")
expected="/tmp/aidevops-tester/.aidevops/locks"

if [[ "$actual" != "$expected" ]]; then
	printf 'FAIL: TODO_LOCK_DIR unset HOME fallback\n'
	printf '  expected: %s\n' "$expected"
	printf '  actual:   %s\n' "$actual"
	exit 1
fi

if [[ "$actual" == /tmp/.aidevops/* ]]; then
	printf 'FAIL: TODO_LOCK_DIR used shared /tmp fallback: %s\n' "$actual"
	exit 1
fi

printf 'PASS: TODO_LOCK_DIR unset HOME fallback is user-scoped\n'
exit 0
