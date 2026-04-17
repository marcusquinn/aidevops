#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-compute-counter-seed-octal.sh — Regression tests for the octal-leading-
# zero parse bug in claim-task-id.sh::_compute_counter_seed.
#
# Bug: get_highest_task_id returns the literal task-number string (e.g. "068"),
# and _compute_counter_seed used `[[ "$highest" -gt 0 ]]` and
# `seed=$((highest + 1))` — both of which trigger bash's octal parser when
# $highest has a leading zero AND a non-octal digit (8 or 9). Repos with any
# TODO entry in the t008-t009 or t08x-t09x ranges fail counter bootstrap with:
#   bash: [[: 068: value too great for base (error token is "068")
# The fix forces base-10 with `10#$highest` on both the test and the arithmetic.
#
# Cases covered:
#   1. Empty TODO.md → seed=1
#   2. Non-padded IDs (t005, t042, t100) → seed=highest+1
#   3. Zero-padded ID t068 (octal-trap trigger) → seed=69 (NOT crash)
#   4. Zero-padded ID t009 (octal-trap edge) → seed=10
#   5. Zero-padded ID t007 (valid octal — should still return 8 in base-10) → seed=8
#   6. Mixed padded + non-padded entries → seed=max+1

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

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

# Source claim-task-id.sh to gain access to internal helper functions.
# BASH_SOURCE guard prevents main() from running on source.
_source_claim_script() {
	# shellcheck disable=SC1090
	if ! source "$CLAIM_SCRIPT" 2>/dev/null; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
		exit 1
	fi
	return 0
}

# Create a minimal TODO.md in $1 with the given entries.
_make_todo() {
	local dir="$1"
	shift
	local todo_file="${dir}/TODO.md"
	{
		printf '# Tasks\n\n'
		for entry in "$@"; do
			printf '%s\n' "$entry"
		done
	} >"$todo_file"
	return 0
}

_source_claim_script

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_empty_todo() {
	local name="1: _compute_counter_seed — empty TODO.md returns seed=1"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_todo "$tmpdir"

	local seed
	seed=$(_compute_counter_seed "$tmpdir" 2>&1)
	if [[ "$seed" == "1" ]]; then
		pass "$name"
	else
		fail "$name" "expected seed=1, got '$seed'"
	fi
	return 0
}

test_unpadded_ids() {
	local name="2: _compute_counter_seed — unpadded IDs (t005, t042, t100) returns 101"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_todo "$tmpdir" \
		"- [x] t005 first task" \
		"- [ ] t042 middle task" \
		"- [x] t100 highest task"

	local seed
	seed=$(_compute_counter_seed "$tmpdir" 2>&1)
	if [[ "$seed" == "101" ]]; then
		pass "$name"
	else
		fail "$name" "expected seed=101, got '$seed'"
	fi
	return 0
}

test_octal_trap_t068() {
	local name="3: _compute_counter_seed — t068 (octal trap) returns 69 not crash"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_todo "$tmpdir" \
		"- [x] t042 padded prior" \
		"- [x] t068 octal-trap trigger"

	local seed
	seed=$(_compute_counter_seed "$tmpdir" 2>&1)
	if [[ "$seed" == "69" ]]; then
		pass "$name"
	else
		fail "$name" "expected seed=69, got '$seed' (likely octal parse error)"
	fi
	return 0
}

test_octal_edge_t009() {
	local name="4: _compute_counter_seed — t009 (octal edge) returns 10"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_todo "$tmpdir" \
		"- [x] t009 octal-edge trigger"

	local seed
	seed=$(_compute_counter_seed "$tmpdir" 2>&1)
	if [[ "$seed" == "10" ]]; then
		pass "$name"
	else
		fail "$name" "expected seed=10, got '$seed' (likely octal parse error)"
	fi
	return 0
}

test_valid_octal_t007() {
	local name="5: _compute_counter_seed — t007 (valid octal, base-10 forced) returns 8"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_todo "$tmpdir" \
		"- [x] t007 valid-octal trigger"

	local seed
	seed=$(_compute_counter_seed "$tmpdir" 2>&1)
	if [[ "$seed" == "8" ]]; then
		pass "$name"
	else
		fail "$name" "expected seed=8 (10#007+1), got '$seed'"
	fi
	return 0
}

test_mixed_padded_unpadded() {
	local name="6: _compute_counter_seed — mixed padded/unpadded picks max correctly"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Real-world MLW pattern: t042 (padded), t068 (padded, octal-trap),
	# t101 (unpadded). Expected seed: 102.
	_make_todo "$tmpdir" \
		"- [ ] t042 first padded" \
		"- [x] t068 padded octal-trap" \
		"- [x] t101 unpadded highest"

	local seed
	seed=$(_compute_counter_seed "$tmpdir" 2>&1)
	if [[ "$seed" == "102" ]]; then
		pass "$name"
	else
		fail "$name" "expected seed=102, got '$seed'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	printf 'Running _compute_counter_seed octal-trap regression tests...\n\n'

	test_empty_todo
	test_unpadded_ids
	test_octal_trap_t068
	test_octal_edge_t009
	test_valid_octal_t007
	test_mixed_padded_unpadded

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
