#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-complexity-regression-helper.sh — Unit tests for complexity-regression-helper.sh (t2159)
#
# Tests:
#   1. clean-to-clean: no violations at base or head → exit 0
#   2. clean-to-new:   no violations at base, new 100+ line function at head → exit 1
#   3. stable:         existing violation at base unchanged at head → exit 0 (not new)
#   4. growing:        existing violation at base grows at head → exit 0 (still not new)
#   5. multi-file:     two new violations in different files → exit 1
#   6. dry-run:        --dry-run scans current tree and exits 0 regardless

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../complexity-regression-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [ "$passed" -eq 0 ]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [ -n "$message" ]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# ---------------------------------------------------------------------------
# make_sh_function <file> <name> <lines>
# Appends a shell function of exactly <lines> body lines to <file>.
# The AWK detector counts lines between `fname() {` (exclusive) and `}` (exclusive),
# so a function with `n` interior lines has body size n.
# ---------------------------------------------------------------------------
make_sh_function() {
	local _file="$1"
	local _fname="$2"
	local _lines="$3"

	printf '%s() {\n' "$_fname" >>"$_file"
	local _i=0
	while [ "$_i" -lt "$_lines" ]; do
		printf '  : # line %d\n' "$_i" >>"$_file"
		_i=$((_i + 1))
	done
	printf '}\n' >>"$_file"
	return 0
}

setup() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown() {
	if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# run_diff <base_scan> <head_scan> [<metric>]
# Runs the diff subcommand and returns its exit code via _DIFF_EXIT global.
# Uses `|| _DIFF_EXIT=$?` to prevent set -e from triggering.
# ---------------------------------------------------------------------------
_DIFF_EXIT=0
run_diff() {
	local _base="$1"
	local _head="$2"
	local _metric="${3:-function-complexity}"
	_DIFF_EXIT=0
	"$HELPER" diff --base-file "$_base" --head-file "$_head" \
		--base-sha "abc1234" --head-sha "def5678" \
		--metric "$_metric" >/dev/null 2>&1 ||
		_DIFF_EXIT=$?
	return 0
}

# ---------------------------------------------------------------------------
# make_deep_nesting <file> <depth>
# Writes a shell file with an if-chain nested <depth> levels deep. Each level
# adds +1 to the global max nesting depth tracked by the scanner.
# ---------------------------------------------------------------------------
make_deep_nesting() {
	local _file="$1"
	local _depth="$2"
	printf '#!/usr/bin/env bash\n' >"$_file"
	local _i=0
	local _indent=""
	while [ "$_i" -lt "$_depth" ]; do
		printf '%sif true ; then\n' "$_indent" >>"$_file"
		_indent="$_indent  "
		_i=$((_i + 1))
	done
	printf '%s:\n' "$_indent" >>"$_file"
	while [ "$_i" -gt 0 ]; do
		_i=$((_i - 1))
		_indent="${_indent#  }"
		printf '%sfi\n' "$_indent" >>"$_file"
	done
	return 0
}

# ---------------------------------------------------------------------------
# make_large_file <file> <lines>
# Creates a shell file with <lines> trivial no-op lines.
# ---------------------------------------------------------------------------
make_large_file() {
	local _file="$1"
	local _lines="$2"
	printf '#!/usr/bin/env bash\n' >"$_file"
	local _i=1
	while [ "$_i" -lt "$_lines" ]; do
		printf ': # pad %d\n' "$_i" >>"$_file"
		_i=$((_i + 1))
	done
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: clean-to-clean — no violations at base or head → exit 0
# ---------------------------------------------------------------------------
test_clean_to_clean() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# 50-line function body — under threshold
	printf '#!/usr/bin/env bash\n' >"$_base_dir/a.sh"
	make_sh_function "$_base_dir/a.sh" "small_func" 50
	cp "$_base_dir/a.sh" "$_head_dir/a.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan"
	"$HELPER" scan "$_head_dir" --output "$_head_scan"

	run_diff "$_base_scan" "$_head_scan"

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "clean-to-clean: no violations → exit 0" 0
	else
		print_result "clean-to-clean: no violations → exit 0" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: clean-to-new — base clean, head adds 105-line function → exit 1
# ---------------------------------------------------------------------------
test_clean_to_new() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	printf '#!/usr/bin/env bash\n' >"$_base_dir/a.sh"
	make_sh_function "$_base_dir/a.sh" "small_func" 50

	cp "$_base_dir/a.sh" "$_head_dir/a.sh"
	# Add a 105-body-line function (lines > 100)
	make_sh_function "$_head_dir/a.sh" "big_func" 105

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan"
	"$HELPER" scan "$_head_dir" --output "$_head_scan"

	run_diff "$_base_scan" "$_head_scan"

	if [ "$_DIFF_EXIT" -eq 1 ]; then
		print_result "clean-to-new: new violation → exit 1" 0
	else
		print_result "clean-to-new: new violation → exit 1" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: stable — violation in base unchanged at head → exit 0 (not new)
# ---------------------------------------------------------------------------
test_stable_existing_violation() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	printf '#!/usr/bin/env bash\n' >"$_base_dir/a.sh"
	make_sh_function "$_base_dir/a.sh" "big_func" 105

	cp "$_base_dir/a.sh" "$_head_dir/a.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan"
	"$HELPER" scan "$_head_dir" --output "$_head_scan"

	run_diff "$_base_scan" "$_head_scan"

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "stable: existing violation unchanged → exit 0" 0
	else
		print_result "stable: existing violation unchanged → exit 0" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: growing — existing violation grows at head → exit 0 (still not new)
# ---------------------------------------------------------------------------
test_growing_existing_violation() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# Base: 105-line function body (already violating)
	printf '#!/usr/bin/env bash\n' >"$_base_dir/a.sh"
	make_sh_function "$_base_dir/a.sh" "big_func" 105

	# Head: same function name, larger body (150 lines)
	printf '#!/usr/bin/env bash\n' >"$_head_dir/a.sh"
	make_sh_function "$_head_dir/a.sh" "big_func" 150

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan"
	"$HELPER" scan "$_head_dir" --output "$_head_scan"

	run_diff "$_base_scan" "$_head_scan"

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "growing: existing violation grew → exit 0 (identity match)" 0
	else
		print_result "growing: existing violation grew → exit 0 (identity match)" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: multi-file — two new violations across two files → exit 1
# ---------------------------------------------------------------------------
test_multi_file_new_violations() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# Base: two files with small functions
	printf '#!/usr/bin/env bash\n' >"$_base_dir/a.sh"
	make_sh_function "$_base_dir/a.sh" "func_a" 50
	printf '#!/usr/bin/env bash\n' >"$_base_dir/b.sh"
	make_sh_function "$_base_dir/b.sh" "func_b" 50

	# Head: each file gains a new 105-line function
	cp "$_base_dir/a.sh" "$_head_dir/a.sh"
	make_sh_function "$_head_dir/a.sh" "new_big_func_a" 105
	cp "$_base_dir/b.sh" "$_head_dir/b.sh"
	make_sh_function "$_head_dir/b.sh" "new_big_func_b" 105

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan"
	"$HELPER" scan "$_head_dir" --output "$_head_scan"

	run_diff "$_base_scan" "$_head_scan"

	if [ "$_DIFF_EXIT" -eq 1 ]; then
		# Also verify the head scan shows 2 violations
		local _head_count
		_head_count=$(wc -l <"$_head_scan" | tr -d ' ')
		if [ "$_head_count" -eq 2 ]; then
			print_result "multi-file: 2 new violations → exit 1" 0
		else
			print_result "multi-file: 2 new violations → exit 1" 1 \
				"exit=1 correct but head count=$_head_count (expected 2)"
		fi
	else
		print_result "multi-file: 2 new violations → exit 1" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: dry-run — --dry-run exits 0 regardless of violations
# ---------------------------------------------------------------------------
test_dry_run_exits_zero() {
	setup
	local _dir="$TEST_ROOT/dir"
	mkdir -p "$_dir"

	# Create a file with a 105-line function in the current directory
	# (dry-run scans "." relative to the CWD, so we need to CD there)
	printf '#!/usr/bin/env bash\n' >"$_dir/c.sh"
	make_sh_function "$_dir/c.sh" "violating_func" 105

	# dry-run runs from CWD — change to our test dir
	local _dry_exit=0
	local _dry_out
	_dry_out=$(cd "$_dir" && "$HELPER" check --dry-run 2>&1) || _dry_exit=$?

	if [ "$_dry_exit" -eq 0 ] && printf '%s' "$_dry_out" | grep -q "Total violations"; then
		print_result "dry-run: exits 0 and reports violation count" 0
	else
		print_result "dry-run: exits 0 and reports violation count" 1 \
			"exit=$_dry_exit output=$_dry_out"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: nesting-depth — clean-to-new. Base has shallow file; head adds a
# file with nesting depth 10 (>8 threshold) → exit 1.
# ---------------------------------------------------------------------------
test_nesting_clean_to_new() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	make_deep_nesting "$_base_dir/shallow.sh" 3
	cp "$_base_dir/shallow.sh" "$_head_dir/shallow.sh"
	make_deep_nesting "$_head_dir/deep.sh" 10

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric nesting-depth
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric nesting-depth

	run_diff "$_base_scan" "$_head_scan" nesting-depth

	if [ "$_DIFF_EXIT" -eq 1 ]; then
		print_result "nesting: new file with depth 10 → exit 1" 0
	else
		print_result "nesting: new file with depth 10 → exit 1" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: nesting-depth — stable. Same deep file at base and head → exit 0.
# ---------------------------------------------------------------------------
test_nesting_stable() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	make_deep_nesting "$_base_dir/deep.sh" 10
	cp "$_base_dir/deep.sh" "$_head_dir/deep.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric nesting-depth
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric nesting-depth

	run_diff "$_base_scan" "$_head_scan" nesting-depth

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "nesting: pre-existing deep file unchanged → exit 0" 0
	else
		print_result "nesting: pre-existing deep file unchanged → exit 0" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: file-size — clean-to-new. Head adds a 2000-line .sh file → exit 1.
# ---------------------------------------------------------------------------
test_file_size_clean_to_new() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	make_large_file "$_base_dir/small.sh" 100
	cp "$_base_dir/small.sh" "$_head_dir/small.sh"
	make_large_file "$_head_dir/huge.sh" 2000

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric file-size
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric file-size

	run_diff "$_base_scan" "$_head_scan" file-size

	if [ "$_DIFF_EXIT" -eq 1 ]; then
		print_result "file-size: new 2000-line .sh → exit 1" 0
	else
		print_result "file-size: new 2000-line .sh → exit 1" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 10: file-size — stable. Same 2000-line file at both → exit 0.
# ---------------------------------------------------------------------------
test_file_size_stable() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	make_large_file "$_base_dir/huge.sh" 2000
	cp "$_base_dir/huge.sh" "$_head_dir/huge.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric file-size
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric file-size

	run_diff "$_base_scan" "$_head_scan" file-size

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "file-size: pre-existing 2000-line file unchanged → exit 0" 0
	else
		print_result "file-size: pre-existing 2000-line file unchanged → exit 0" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 11: bash32-compat — clean-to-new. Head adds associative-array
# declaration (bash 4.0+ only) → exit 1.
# ---------------------------------------------------------------------------
test_bash32_clean_to_new() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	printf '#!/usr/bin/env bash\necho ok\n' >"$_base_dir/a.sh"
	cp "$_base_dir/a.sh" "$_head_dir/a.sh"
	printf '#!/usr/bin/env bash\ndeclare -A config\n' >"$_head_dir/new.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric bash32-compat
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric bash32-compat

	run_diff "$_base_scan" "$_head_scan" bash32-compat

	if [ "$_DIFF_EXIT" -eq 1 ]; then
		print_result "bash32: new associative-array declaration → exit 1" 0
	else
		print_result "bash32: new associative-array declaration → exit 1" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 12: bash32-compat — stable. Existing nameref at base and head → exit 0.
# ---------------------------------------------------------------------------
test_bash32_stable() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	printf '#!/usr/bin/env bash\ndeclare -n ref=other\n' >"$_base_dir/a.sh"
	cp "$_base_dir/a.sh" "$_head_dir/a.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric bash32-compat
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric bash32-compat

	run_diff "$_base_scan" "$_head_scan" bash32-compat

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "bash32: pre-existing nameref unchanged → exit 0" 0
	else
		print_result "bash32: pre-existing nameref unchanged → exit 0" 1 "got exit $_DIFF_EXIT"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[ -x "$HELPER" ] || {
	printf 'SKIP: %s not executable\n' "$HELPER"
	exit 0
}

test_clean_to_clean
test_clean_to_new
test_stable_existing_violation
test_growing_existing_violation
test_multi_file_new_violations
test_dry_run_exits_zero
test_nesting_clean_to_new
test_nesting_stable
test_file_size_clean_to_new
test_file_size_stable
test_bash32_clean_to_new
test_bash32_stable

printf '\n'
if [ "$TESTS_FAILED" -eq 0 ]; then
	printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%b%d/%d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
