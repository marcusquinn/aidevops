#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-todo-collision.sh — Regression tests for GH#19454
#
# Tests _id_exists_in_todo() and _allocate_online_with_collision_check()
# added to claim-task-id.sh to prevent counter-drift collisions with
# historical TODO entries.
#
# Branches covered:
#   1. _id_exists_in_todo: ID absent from TODO.md → returns 1
#   2. _id_exists_in_todo: completed ID in TODO.md → returns 0
#   3. _id_exists_in_todo: active (unchecked) ID in TODO.md → returns 0
#   4. _id_exists_in_todo: zero-padded ID (t02155 == t2155) → returns 0
#   5. _allocate_online_with_collision_check: no collision → allocates first_id
#   6. _allocate_online_with_collision_check: single skip → skips one, returns next
#   7. _allocate_online_with_collision_check: multi-skip → skips N, returns first clean
#   8. _allocate_online_with_collision_check: max-skip cap exceeded → returns 1

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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
# The script uses BASH_SOURCE guard so main() is NOT called on source.
# shared-constants.sh is in the same directory — sourcing resolves correctly.
_source_claim_script() {
	# Temporarily set TASK_TITLE to satisfy the "required unless batch" check
	# that parse_args enforces — but we never call parse_args in tests.
	# The sourcing guard (BASH_SOURCE != 0) prevents main() from running.
	# shellcheck disable=SC1090
	if ! source "$CLAIM_SCRIPT" 2>/dev/null; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
		exit 1
	fi
	return 0
}

# Create a minimal TODO.md in $1 with the given entries.
# Usage: _make_todo <dir> "- [x] t2155 some task" "- [ ] t2156 another"
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

# ---------------------------------------------------------------------------
# Source the script once for all tests in this session.
# ---------------------------------------------------------------------------
_source_claim_script

# ---------------------------------------------------------------------------
# Tests 1-4: _id_exists_in_todo
# ---------------------------------------------------------------------------

test_id_not_in_empty_todo() {
	local name="1: _id_exists_in_todo — ID absent from TODO.md returns 1"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_todo "$tmpdir" # empty task list

	local rc=0
	_id_exists_in_todo "2155" "$tmpdir" || rc=$?
	if [[ $rc -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected return 1 (not found), got $rc"
	fi
	return 0
}

test_id_completed_in_todo() {
	local name="2: _id_exists_in_todo — completed entry returns 0"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_todo "$tmpdir" \
		"- [x] t2155 tighten agent doc ref:GH#15042 pr:#15580 completed:2026-04-02"

	local rc=0
	_id_exists_in_todo "2155" "$tmpdir" || rc=$?
	if [[ $rc -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected return 0 (found completed), got $rc"
	fi
	return 0
}

test_id_active_in_todo() {
	local name="3: _id_exists_in_todo — active (unchecked) entry returns 0"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_todo "$tmpdir" \
		"- [ ] t2158 fix claim-task-id collision check ref:GH#19454"

	local rc=0
	_id_exists_in_todo "2158" "$tmpdir" || rc=$?
	if [[ $rc -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected return 0 (found active), got $rc"
	fi
	return 0
}

test_id_zero_padded_variant() {
	local name="4: _id_exists_in_todo — zero-padded t02155 matches query 2155"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	_make_todo "$tmpdir" \
		"- [x] t02155 padded variant entry"

	local rc=0
	_id_exists_in_todo "2155" "$tmpdir" || rc=$?
	if [[ $rc -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected return 0 (zero-padded match), got $rc"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Tests 5-8: _allocate_online_with_collision_check
#
# These tests mock allocate_online() to return a predetermined sequence of
# IDs.  The mock uses a counter file in $TMPDIR to advance through the
# sequence on each call, mirroring what the real CAS would do.
# ---------------------------------------------------------------------------

# Global state for mock
_MOCK_SEQ=()
_MOCK_SEQ_IDX=0
_MOCK_SEQ_IDX_FILE=""

# Reset mock state; call before each test that uses the mock.
_reset_mock() {
	local seq_file="$1"
	_MOCK_SEQ_IDX_FILE="$seq_file"
	echo "0" >"$seq_file"
	return 0
}

# Override allocate_online() to return sequential IDs from _MOCK_SEQ.
# Each call advances the index.
# shellcheck disable=SC2317  # referenced indirectly
allocate_online() {
	local idx=0
	[[ -f "$_MOCK_SEQ_IDX_FILE" ]] && idx=$(cat "$_MOCK_SEQ_IDX_FILE")
	if [[ $idx -ge ${#_MOCK_SEQ[@]} ]]; then
		# Ran off the end of the sequence — treat as hard error
		return 1
	fi
	local val="${_MOCK_SEQ[$idx]}"
	echo $((idx + 1)) >"$_MOCK_SEQ_IDX_FILE"
	echo "$val"
	return 0
}

test_no_collision() {
	local name="5: _allocate_online_with_collision_check — no collision, returns first_id"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# TODO.md has t2154 only; counter will allocate t2155 — no collision
	_make_todo "$tmpdir" \
		"- [x] t2154 previous task"
	_MOCK_SEQ=(2155)
	_reset_mock "${tmpdir}/idx"

	local result=""
	local rc=0
	result=$(_allocate_online_with_collision_check "$tmpdir" 1) || rc=$?

	if [[ $rc -eq 0 && "$result" == "2155" ]]; then
		pass "$name"
	else
		fail "$name" "expected first_id=2155 rc=0, got result='$result' rc=$rc"
	fi
	return 0
}

test_single_skip() {
	local name="6: _allocate_online_with_collision_check — single skip"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# t2155 exists in TODO.md; counter allocates 2155 first (collision) then 2156
	_make_todo "$tmpdir" \
		"- [x] t2155 old completed task ref:GH#15042 pr:#15580 completed:2026-04-02"
	_MOCK_SEQ=(2155 2156)
	_reset_mock "${tmpdir}/idx"

	local result=""
	local rc=0
	result=$(_allocate_online_with_collision_check "$tmpdir" 1) || rc=$?

	if [[ $rc -eq 0 && "$result" == "2156" ]]; then
		pass "$name"
	else
		fail "$name" "expected first_id=2156 rc=0, got result='$result' rc=$rc"
	fi
	return 0
}

test_multi_skip() {
	local name="7: _allocate_online_with_collision_check — multi-skip (3 collisions)"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# t2153, t2154, t2155 all exist; counter will skip all three, land on t2156
	_make_todo "$tmpdir" \
		"- [x] t2153 first old task" \
		"- [x] t2154 second old task" \
		"- [x] t2155 third old task"
	_MOCK_SEQ=(2153 2154 2155 2156)
	_reset_mock "${tmpdir}/idx"

	local result=""
	local rc=0
	result=$(_allocate_online_with_collision_check "$tmpdir" 1) || rc=$?

	if [[ $rc -eq 0 && "$result" == "2156" ]]; then
		pass "$name"
	else
		fail "$name" "expected first_id=2156 rc=0, got result='$result' rc=$rc"
	fi
	return 0
}

test_max_skip_exceeded() {
	local name="8: _allocate_online_with_collision_check — max-skip cap (100) returns error"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Build a TODO.md with 101 historical entries: t1 through t101
	local entries=()
	local k
	for ((k = 1; k <= 101; k++)); do
		entries+=("- [x] t$(printf '%03d' "$k") historical entry $k")
	done
	_make_todo "$tmpdir" "${entries[@]}"

	# Mock returns IDs 1..101 (all collide), then 102 (which would be clean
	# but the cap triggers before we reach it after 100 skips)
	local mock_seq=()
	for ((k = 1; k <= 102; k++)); do
		mock_seq+=("$k")
	done
	_MOCK_SEQ=("${mock_seq[@]}")
	_reset_mock "${tmpdir}/idx"

	# Also need REMOTE_NAME and COUNTER_BRANCH for the error message
	local saved_remote="${REMOTE_NAME:-origin}"
	local saved_branch="${COUNTER_BRANCH:-main}"
	REMOTE_NAME="origin"
	COUNTER_BRANCH="main"

	local result=""
	local rc=0
	result=$(_allocate_online_with_collision_check "$tmpdir" 1 2>/dev/null) || rc=$?

	REMOTE_NAME="$saved_remote"
	COUNTER_BRANCH="$saved_branch"

	if [[ $rc -eq 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected rc=1 (cap exceeded), got rc=$rc result='$result'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	printf 'Running claim-task-id TODO collision tests...\n\n'

	test_id_not_in_empty_todo
	test_id_completed_in_todo
	test_id_active_in_todo
	test_id_zero_padded_variant
	test_no_collision
	test_single_skip
	test_multi_skip
	test_max_skip_exceeded

	printf '\n'
	printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
