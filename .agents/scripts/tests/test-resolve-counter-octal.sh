#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-resolve-counter-octal.sh — Regression test for the octal-leading-zero
# parse bug in task-id-collision-guard.sh::_resolve_current_counter.
#
# Bug: _resolve_current_counter used `"$val" -gt "$best"` inside [[ ]] which
# triggers bash's octal parser when the .task-counter file contains a value
# with a leading zero AND a non-octal digit (8 or 9). For example, "068"
# would crash with:
#   bash: [[: 068: value too great for base (error token is "068")
# The fix forces base-10 with (( 10#$val > 10#$best )) on the comparison.
#
# GH#19667 (review-followup from GH#19620 / PR #19621).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
GUARD_SCRIPT="${SCRIPT_DIR}/../../hooks/task-id-collision-guard.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# Source the guard script to access _resolve_current_counter.
_source_guard_script() {
	# The guard script has a main() that only runs when invoked directly
	# (not sourced), but we need to prevent any side effects.
	# shellcheck disable=SC1090
	if ! source "$GUARD_SCRIPT" 2>/dev/null; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$GUARD_SCRIPT" >&2
		exit 1
	fi
	return 0
}

# Create a temp git repo with a .task-counter containing $1.
_make_repo_with_counter() {
	local counter_value="$1"
	local tmpdir
	tmpdir=$(mktemp -d)
	(
		cd "$tmpdir" || exit 1
		git init -q
		git config user.email "test@test.com"
		git config user.name "Test"
		printf '%s\n' "$counter_value" >.task-counter
		git add .task-counter
		git commit -q -m "init with counter=$counter_value"
	) >/dev/null 2>&1
	printf '%s' "$tmpdir"
	return 0
}

_source_guard_script

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# Test 1: .task-counter = "068" (octal trap) — should not crash, return "068"
test_counter_068() {
	local name="1: _resolve_current_counter — counter=068 (octal trap) does not crash"
	local tmpdir
	tmpdir=$(_make_repo_with_counter "068")
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local result
	result=$(cd "$tmpdir" && _resolve_current_counter 2>&1)
	local rc=$?

	if [[ "$rc" -ne 0 ]]; then
		fail "$name" "exit code=$rc (expected 0)"
		return 0
	fi
	if [[ "$result" == "068" ]]; then
		pass "$name"
	else
		fail "$name" "expected '068', got '$result'"
	fi
	return 0
}

# Test 2: .task-counter = "009" (octal edge) — should return "009"
test_counter_009() {
	local name="2: _resolve_current_counter — counter=009 (octal edge) does not crash"
	local tmpdir
	tmpdir=$(_make_repo_with_counter "009")
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local result
	result=$(cd "$tmpdir" && _resolve_current_counter 2>&1)
	local rc=$?

	if [[ "$rc" -ne 0 ]]; then
		fail "$name" "exit code=$rc (expected 0)"
		return 0
	fi
	if [[ "$result" == "009" ]]; then
		pass "$name"
	else
		fail "$name" "expected '009', got '$result'"
	fi
	return 0
}

# Test 3: .task-counter = "100" (no leading zero) — baseline sanity
test_counter_100() {
	local name="3: _resolve_current_counter — counter=100 (no leading zero) returns 100"
	local tmpdir
	tmpdir=$(_make_repo_with_counter "100")
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	local result
	result=$(cd "$tmpdir" && _resolve_current_counter 2>&1)

	if [[ "$result" == "100" ]]; then
		pass "$name"
	else
		fail "$name" "expected '100', got '$result'"
	fi
	return 0
}

# Test 4: Two sources with leading-zero values — picks the max correctly.
# Working-copy .task-counter = "078", HEAD commit has "042".
# 78 > 42 so result should be "078".
test_counter_max_with_leading_zeros() {
	local name="4: _resolve_current_counter — max pick works with leading-zero values (078 vs 042)"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	(
		cd "$tmpdir" || exit 1
		git init -q
		git config user.email "test@test.com"
		git config user.name "Test"
		printf '042\n' >.task-counter
		git add .task-counter
		git commit -q -m "init with counter=042"
		# Now update working copy to 078 (not committed)
		printf '078\n' >.task-counter
	) >/dev/null 2>&1

	local result
	result=$(cd "$tmpdir" && _resolve_current_counter 2>&1)

	if [[ "$result" == "078" ]]; then
		pass "$name"
	else
		fail "$name" "expected '078', got '$result'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	printf 'Running _resolve_current_counter octal-trap regression tests...\n\n'

	test_counter_068
	test_counter_009
	test_counter_100
	test_counter_max_with_leading_zeros

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
