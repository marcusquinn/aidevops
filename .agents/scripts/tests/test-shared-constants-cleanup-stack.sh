#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Test: shared-constants.sh cleanup stack reversal
# Verifies cleanup commands execute in LIFO order without reversal stderr noise.
# =============================================================================
set -euo pipefail

PASS=0
FAIL=0
TESTS=0

_test() {
	local desc="$1"
	local expected="$2"
	local actual="$3"
	TESTS=$((TESTS + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '  PASS: %s\n' "$desc"
		PASS=$((PASS + 1))
	else
		printf '  FAIL: %s\n' "$desc"
		printf '    expected: %s\n' "$expected"
		printf '    actual:   %s\n' "$actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

SCRIPT_DIR="${BASH_SOURCE[0]%/*}/.."
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

source "$SCRIPT_DIR/shared-constants.sh"

printf '=== cleanup stack reversal tests ===\n'

order_file="$TMPDIR_TEST/order.txt"
stderr_file="$TMPDIR_TEST/stderr.txt"

_CLEANUP_CMDS=""
push_cleanup "printf '%s\\n' first >> '$order_file'"
push_cleanup "printf '%s\\n' second >> '$order_file'"
push_cleanup "printf '%s\\n' third >> '$order_file'"

_run_cleanups 2>"$stderr_file"

actual_order="$(tr '\n' ' ' <"$order_file")"
actual_stderr="$(<"$stderr_file")"

_test "Cleanup stack executes in LIFO order" "third second first " "$actual_order"
_test "Cleanup stack reversal emits no stderr" "" "$actual_stderr"
_test "Cleanup stack is empty after execution" "" "$_CLEANUP_CMDS"

printf '\nResults: %s passed, %s failed, %s total\n' "$PASS" "$FAIL" "$TESTS"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
