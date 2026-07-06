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
#   4. new-file-over-limit      — new file >500 lines even though net count is
#                                 unchanged (one removed, one added) → exit 1
#   5. docs-only                — --docs-only flag skips gate → exit 0
#   6. code-and-readme-ignored  — oversized code and README.md do not count
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
# make_doc_file <path> <lines>
# Create a Markdown/doc fixture file with exactly <lines> trivial lines.
# ---------------------------------------------------------------------------
make_doc_file() {
	local _path="$1"
	local _lines="$2"
	mkdir -p "$(dirname "$_path")"
	: >"$_path"
	local _i=0
	while [ "$_i" -lt "$_lines" ]; do
		printf 'doc line %d\n' "$_i" >>"$_path"
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

# ---------------------------------------------------------------------------
# init_git_repo <repo-dir>
# Create a minimal git repository with local identity for check-mode tests.
# ---------------------------------------------------------------------------
init_git_repo() {
	local _repo="$1"
	mkdir -p "$_repo"
	git -C "$_repo" init -q
	git -C "$_repo" config user.email "test@example.invalid"
	git -C "$_repo" config user.name "File Size Test"
	return 0
}

# ---------------------------------------------------------------------------
# commit_all <repo-dir> <message>
# ---------------------------------------------------------------------------
commit_all() {
	local _repo="$1"
	local _message="$2"
	git -C "$_repo" add -A
	git -C "$_repo" commit -q -m "$_message"
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

	# Both base and head have a small Markdown file (well under 500 lines)
	make_doc_file "$_base_dir/small.md" 100
	make_doc_file "$_head_dir/small.md" 100

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
	make_doc_file "$_base_dir/big.md" 501
	make_doc_file "$_head_dir/big.md" 501

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
	make_doc_file "$_base_dir/existing.md" 501

	# Head: same file plus a new oversized file
	make_doc_file "$_head_dir/existing.md" 501
	make_doc_file "$_head_dir/new_giant.md" 600

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
# Scenario: base has file A (>500 lines). Head removes A but adds file B
# (>500 lines). Net count: same (1). Still a regression because B is a new
# oversized file that wasn't in base. The ratchet must catch this to prevent
# gaming the gate by cycling oversized files.
# ===========================================================================
test_new_file_over_limit_net_unchanged() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# Base: one large Markdown file (file_a.md)
	make_doc_file "$_base_dir/file_a.md" 501

	# Head: file_a.md removed, file_b.md added (different path, both >500 lines)
	make_doc_file "$_head_dir/file_b.md" 501

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
	make_doc_file "$_base_dir/existing.md" 501
	make_doc_file "$_head_dir/existing.md" 501
	make_doc_file "$_head_dir/also_big.md" 600

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
# Test 6: code-and-readme-ignored — oversized code and README.md do not count
# ===========================================================================
test_code_and_readme_ignored() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	make_doc_file "$_head_dir/README.md" 1000
	make_doc_file "$_head_dir/script.sh" 1000
	make_doc_file "$_head_dir/module.py" 1000

	local _base_tsv="$TEST_ROOT/base.tsv"
	local _head_tsv="$TEST_ROOT/head.tsv"
	run_scan "$_base_dir" "$_base_tsv"
	run_scan "$_head_dir" "$_head_tsv"

	run_diff "$_base_tsv" "$_head_tsv"

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "code-and-readme-ignored: oversized code and README.md → exit 0" 0
	else
		print_result "code-and-readme-ignored: oversized code and README.md → exit 0" 1 \
			"got exit $_DIFF_EXIT, expected 0"
	fi
	teardown
	return 0
}

# ===========================================================================
# Test 7: ignored-node-modules-not-counted — ignored vendor Markdown ignored
# ===========================================================================
test_ignored_node_modules_not_counted() {
	setup
	local _repo="$TEST_ROOT/repo"
	init_git_repo "$_repo"
	printf 'node_modules/\n' >"$_repo/.gitignore"
	make_doc_file "$_repo/small.md" 10
	commit_all "$_repo" "base"

	make_doc_file "$_repo/node_modules/pkg/huge.md" 600

	local _log="$TEST_ROOT/check.log"
	local _check_exit=0
	( cd "$_repo" && "$HELPER" check --base HEAD >"$_log" 2>&1 ) || _check_exit=$?

	if [ "$_check_exit" -eq 0 ]; then
		print_result "ignored-node-modules-not-counted: ignored vendor Markdown → exit 0" 0
	else
		print_result "ignored-node-modules-not-counted: ignored vendor Markdown → exit 0" 1 \
			"got exit $_check_exit, expected 0"
	fi
	teardown
	return 0
}

# ===========================================================================
# Test 8: tracked-oversized-fails-with-diagnostics — staged tracked file blocks
# ===========================================================================
test_tracked_oversized_fails_with_diagnostics() {
	setup
	local _repo="$TEST_ROOT/repo"
	init_git_repo "$_repo"
	make_doc_file "$_repo/small.md" 10
	commit_all "$_repo" "base"

	make_doc_file "$_repo/big.md" 600
	git -C "$_repo" add "big.md"

	local _log="$TEST_ROOT/check.log"
	local _check_exit=0
	( cd "$_repo" && "$HELPER" check --base HEAD >"$_log" 2>&1 ) || _check_exit=$?

	if [ "$_check_exit" -eq 1 ] \
		&& grep -q 'big.md' "$_log" \
		&& grep -q 'compared refs:' "$_log"; then
		print_result "tracked-oversized-fails-with-diagnostics: path and refs printed" 0
	else
		print_result "tracked-oversized-fails-with-diagnostics: path and refs printed" 1 \
			"exit=$_check_exit; expected 1 with big.md and compared refs in log"
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
	test_code_and_readme_ignored
	test_ignored_node_modules_not_counted
	test_tracked_oversized_fails_with_diagnostics

	printf '\n%d/%d tests passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

	if [ "$TESTS_FAILED" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
