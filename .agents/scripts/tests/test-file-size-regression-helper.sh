#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-file-size-regression-helper.sh — Unit tests for file-size-regression-helper.sh (t2938)
#
# Tests:
#   1. zero-violation baseline  — no files over limit at base or head → exit 0
#   2. baseline-equals-head     — same set of violations at base and head → exit 0
#   3. head-greater-than-base   — head adds a new oversized file → exit 1
#   4. new-file-over-limit      — new file >1500 lines even though net count is
#                                 unchanged (one removed, one added) → exit 1
#   5. docs-only                — --docs-only flag skips gate → exit 0
#
# Usage: bash .agents/scripts/tests/test-file-size-regression-helper.sh
# Requires: the helper at .agents/scripts/file-size-regression-helper.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../file-size-regression-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

# ---------------------------------------------------------------------------
# print_result <name> <failed> [<message>]
# ---------------------------------------------------------------------------
print_result() {
	local _name="$1"
	local _failed="$2"
	local _msg="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [ "$_failed" -eq 0 ]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$_name"
	if [ -n "$_msg" ]; then
		printf '       %s\n' "$_msg"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------
setup() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown() {
	if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	return 0
}

# ---------------------------------------------------------------------------
# make_sh_file <path> <lines>
# Create a shell script file with exactly <lines> trivial no-op lines.
# ---------------------------------------------------------------------------
make_sh_file() {
	local _path="$1"
	local _lines="$2"
	mkdir -p "$(dirname "$_path")"
	printf '#!/usr/bin/env bash\n' > "$_path"
	local _i=1
	while [ "$_i" -lt "$_lines" ]; do
		printf ': # pad %d\n' "$_i" >> "$_path"
		_i=$((_i + 1))
	done
	return 0
}

# ---------------------------------------------------------------------------
# run_diff <base_tsv> <head_tsv> [extra_args...]
# Runs the diff subcommand; stores exit code in _DIFF_EXIT.
# ---------------------------------------------------------------------------
_DIFF_EXIT=0
run_diff() {
	local _base="$1"
	local _head="$2"
	shift 2
	_DIFF_EXIT=0
	"$HELPER" diff --base-file "$_base" --head-file "$_head" "$@" \
		>/dev/null 2>&1 || _DIFF_EXIT=$?
	return 0
}

# ---------------------------------------------------------------------------
# run_scan <dir> <output_tsv>
# Runs the scan subcommand against <dir>, writing TSV to <output_tsv>.
# ---------------------------------------------------------------------------
run_scan() {
	local _dir="$1"
	local _out="$2"
	"$HELPER" scan "$_dir" --output "$_out" 2>/dev/null
	return 0
}

# ===========================================================================
# Test 1: zero-violation baseline — no files over limit at base or head → 0
# ===========================================================================
test_zero_violation_baseline() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# Both base and head have a small file (well under 1500 lines)
	make_sh_file "$_base_dir/small.sh" 100
	make_sh_file "$_head_dir/small.sh" 100

	local _base_tsv="$TEST_ROOT/base.tsv"
	local _head_tsv="$TEST_ROOT/head.tsv"
	run_scan "$_base_dir" "$_base_tsv"
	run_scan "$_head_dir" "$_head_tsv"

	run_diff "$_base_tsv" "$_head_tsv"

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "zero-violation-baseline: no violations at base or head → exit 0" 0
	else
		print_result "zero-violation-baseline: no violations at base or head → exit 0" 1 \
			"got exit $_DIFF_EXIT, expected 0"
	fi
	teardown
	return 0
}

# ===========================================================================
# Test 2: baseline-equals-head — same violations in both → exit 0 (no regression)
# ===========================================================================
test_baseline_equals_head() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# Both base and head have the same large file
	make_sh_file "$_base_dir/big.sh" 1600
	make_sh_file "$_head_dir/big.sh" 1600

	local _base_tsv="$TEST_ROOT/base.tsv"
	local _head_tsv="$TEST_ROOT/head.tsv"
	run_scan "$_base_dir" "$_base_tsv"
	run_scan "$_head_dir" "$_head_tsv"

	run_diff "$_base_tsv" "$_head_tsv"

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "baseline-equals-head: same violations → exit 0 (no regression)" 0
	else
		print_result "baseline-equals-head: same violations → exit 0 (no regression)" 1 \
			"got exit $_DIFF_EXIT, expected 0"
	fi
	teardown
	return 0
}

# ===========================================================================
# Test 3: head-greater-than-base — head adds a new oversized file → exit 1
# ===========================================================================
test_head_greater_than_base() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# Base: one large file
	make_sh_file "$_base_dir/existing.sh" 1600

	# Head: same file plus a new oversized file
	make_sh_file "$_head_dir/existing.sh" 1600
	make_sh_file "$_head_dir/new_giant.sh" 2000

	local _base_tsv="$TEST_ROOT/base.tsv"
	local _head_tsv="$TEST_ROOT/head.tsv"
	run_scan "$_base_dir" "$_base_tsv"
	run_scan "$_head_dir" "$_head_tsv"

	run_diff "$_base_tsv" "$_head_tsv"

	if [ "$_DIFF_EXIT" -eq 1 ]; then
		print_result "head-greater-than-base: new oversized file → exit 1 (block)" 0
	else
		print_result "head-greater-than-base: new oversized file → exit 1 (block)" 1 \
			"got exit $_DIFF_EXIT, expected 1"
	fi
	teardown
	return 0
}

# ===========================================================================
# Test 4: new-file-over-limit — net count unchanged but new file added → exit 1
#
# Scenario: base has file A (>1500 lines). Head removes A but adds file B
# (>1500 lines). Net count: same (1). Still a regression because B is a new
# oversized file that wasn't in base. The ratchet must catch this to prevent
# gaming the gate by cycling oversized files.
# ===========================================================================
test_new_file_over_limit_net_unchanged() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# Base: one large file (file_a.sh)
	make_sh_file "$_base_dir/file_a.sh" 1600

	# Head: file_a.sh removed, file_b.sh added (different path, both >1500 lines)
	make_sh_file "$_head_dir/file_b.sh" 1600

	local _base_tsv="$TEST_ROOT/base.tsv"
	local _head_tsv="$TEST_ROOT/head.tsv"
	run_scan "$_base_dir" "$_base_tsv"
	run_scan "$_head_dir" "$_head_tsv"

	# Verify both have exactly 1 violation (net unchanged)
	local _base_count _head_count
	_base_count=$(grep -c '.' "$_base_tsv" 2>/dev/null || true)
	_head_count=$(grep -c '.' "$_head_tsv" 2>/dev/null || true)

	run_diff "$_base_tsv" "$_head_tsv"

	if [ "$_DIFF_EXIT" -eq 1 ]; then
		print_result "new-file-over-limit (net unchanged): new path → exit 1 (block regardless)" 0
	else
		print_result "new-file-over-limit (net unchanged): new path → exit 1 (block regardless)" 1 \
			"got exit $_DIFF_EXIT (base=$_base_count head=$_head_count violations), expected 1"
	fi
	teardown
	return 0
}

# ===========================================================================
# Test 5: docs-only — --docs-only flag skips gate → exit 0
# ===========================================================================
test_docs_only_skip() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# Head has more violations than base — would normally fail
	make_sh_file "$_base_dir/existing.sh" 1600
	make_sh_file "$_head_dir/existing.sh" 1600
	make_sh_file "$_head_dir/also_big.sh" 1700

	local _base_tsv="$TEST_ROOT/base.tsv"
	local _head_tsv="$TEST_ROOT/head.tsv"
	run_scan "$_base_dir" "$_base_tsv"
	run_scan "$_head_dir" "$_head_tsv"

	# Pass --docs-only: gate must be skipped regardless of violation delta
	run_diff "$_base_tsv" "$_head_tsv" "--docs-only"

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "docs-only: --docs-only flag skips gate → exit 0" 0
	else
		print_result "docs-only: --docs-only flag skips gate → exit 0" 1 \
			"got exit $_DIFF_EXIT, expected 0"
	fi
	teardown
	return 0
}

# ===========================================================================
# Main
# ===========================================================================
main() {
	if [ ! -x "$HELPER" ]; then
		printf '%bERROR%b helper not found or not executable: %s\n' \
			"$TEST_RED" "$TEST_RESET" "$HELPER" >&2
		exit 2
	fi

	printf '\n=== file-size-regression-helper tests (t2938) ===\n\n'

	test_zero_violation_baseline
	test_baseline_equals_head
	test_head_greater_than_base
	test_new_file_over_limit_net_unchanged
	test_docs_only_skip

	printf '\n%d/%d tests passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

	if [ "$TESTS_FAILED" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
