#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-complexity-regression-bash32-line-shift.sh — Regression test for t2248
#
# Verifies that the bash32-compat metric uses count-per-(file, pattern) keying
# instead of line-keyed (file, pattern:line). The old keying caused spurious
# regressions when line insertions above existing violations shifted their line
# numbers without adding any new violations.
#
# Tests:
#   1.  line-shift-no-regression: 3 namerefs at base, same 3 shifted by 1 line
#       at head → new: 0 (was new: 3 under old keying).
#   2.  genuine-new-violation:   3 namerefs at base, 4 namerefs at head (1 added)
#       → new: 1.
#   3.  removed-violation:       3 namerefs at base, 2 at head (1 removed)
#       → new: 0 (count decreased, not increased).
#   4.  multi-pattern-shift:     mixed patterns (nameref + assoc-array) at base,
#       all shifted at head → new: 0.
#   5.  scan-format-check:       verify scan output format is <file>\t<pattern>\t<count>
#       (no line numbers in key).

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
# ---------------------------------------------------------------------------
_DIFF_EXIT=0
_DIFF_OUTPUT=""
run_diff() {
	local _base="$1"
	local _head="$2"
	local _metric="${3:-bash32-compat}"
	_DIFF_EXIT=0
	_DIFF_OUTPUT=$("$HELPER" diff --base-file "$_base" --head-file "$_head" \
		--base-sha "abc1234" --head-sha "def5678" \
		--metric "$_metric" 2>&1) ||
		_DIFF_EXIT=$?
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: Line shift — no regression.
# Base: 3 namerefs at lines 5, 10, 15.
# Head: 1 comment inserted at line 3 → namerefs now at lines 6, 11, 16.
# Expected: new: 0 (count unchanged: 3 → 3).
# ---------------------------------------------------------------------------
test_line_shift_no_regression() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	# Base file: 3 namerefs at specific lines
	{
		printf '#!/usr/bin/env bash\n'
		printf 'echo line2\n'
		printf 'echo line3\n'
		printf 'echo line4\n'
		printf 'declare -n ref1=var1\n'    # line 5
		printf 'echo line6\n'
		printf 'echo line7\n'
		printf 'echo line8\n'
		printf 'echo line9\n'
		printf 'declare -n ref2=var2\n'    # line 10
		printf 'echo line11\n'
		printf 'echo line12\n'
		printf 'echo line13\n'
		printf 'echo line14\n'
		printf 'declare -n ref3=var3\n'    # line 15
	} >"$_base_dir/example.sh"

	# Head file: same content but with 1 comment inserted at line 3
	# Namerefs shift to lines 6, 11, 16
	{
		printf '#!/usr/bin/env bash\n'
		printf 'echo line2\n'
		printf '# shellcheck disable=SC1091\n'  # inserted comment
		printf 'echo line3\n'
		printf 'echo line4\n'
		printf 'declare -n ref1=var1\n'    # line 6 (was 5)
		printf 'echo line6\n'
		printf 'echo line7\n'
		printf 'echo line8\n'
		printf 'echo line9\n'
		printf 'declare -n ref2=var2\n'    # line 11 (was 10)
		printf 'echo line11\n'
		printf 'echo line12\n'
		printf 'echo line13\n'
		printf 'echo line14\n'
		printf 'declare -n ref3=var3\n'    # line 16 (was 15)
	} >"$_head_dir/example.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric bash32-compat
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric bash32-compat

	run_diff "$_base_scan" "$_head_scan" bash32-compat

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "bash32 line-shift: 3 namerefs shifted by 1 line → exit 0 (no regression)" 0
	else
		print_result "bash32 line-shift: 3 namerefs shifted by 1 line → exit 0 (no regression)" 1 \
			"got exit $_DIFF_EXIT (output: $_DIFF_OUTPUT)"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: Genuine new violation.
# Base: 3 namerefs. Head: 4 namerefs (1 genuinely new). Expected: new: 1.
# ---------------------------------------------------------------------------
test_genuine_new_violation() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	{
		printf '#!/usr/bin/env bash\n'
		printf 'declare -n ref1=var1\n'
		printf 'declare -n ref2=var2\n'
		printf 'declare -n ref3=var3\n'
	} >"$_base_dir/example.sh"

	{
		printf '#!/usr/bin/env bash\n'
		printf 'declare -n ref1=var1\n'
		printf 'declare -n ref2=var2\n'
		printf 'declare -n ref3=var3\n'
		printf 'declare -n ref4=var4\n'    # genuinely new
	} >"$_head_dir/example.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric bash32-compat
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric bash32-compat

	run_diff "$_base_scan" "$_head_scan" bash32-compat

	if [ "$_DIFF_EXIT" -eq 1 ]; then
		print_result "bash32 genuine-new: 3→4 namerefs → exit 1 (regression)" 0
	else
		print_result "bash32 genuine-new: 3→4 namerefs → exit 1 (regression)" 1 \
			"got exit $_DIFF_EXIT (output: $_DIFF_OUTPUT)"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: Removed violation — count decreased.
# Base: 3 namerefs. Head: 2 namerefs (1 removed). Expected: new: 0.
# ---------------------------------------------------------------------------
test_removed_violation() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	{
		printf '#!/usr/bin/env bash\n'
		printf 'declare -n ref1=var1\n'
		printf 'declare -n ref2=var2\n'
		printf 'declare -n ref3=var3\n'
	} >"$_base_dir/example.sh"

	{
		printf '#!/usr/bin/env bash\n'
		printf 'declare -n ref1=var1\n'
		printf 'declare -n ref2=var2\n'
	} >"$_head_dir/example.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric bash32-compat
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric bash32-compat

	run_diff "$_base_scan" "$_head_scan" bash32-compat

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "bash32 removed: 3→2 namerefs → exit 0 (no regression)" 0
	else
		print_result "bash32 removed: 3→2 namerefs → exit 0 (no regression)" 1 \
			"got exit $_DIFF_EXIT (output: $_DIFF_OUTPUT)"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: Multi-pattern shift — mixed patterns all shifted.
# Base: 2 namerefs + 1 assoc-array. Head: same but shifted.
# Expected: new: 0.
# ---------------------------------------------------------------------------
test_multi_pattern_shift() {
	setup
	local _base_dir="$TEST_ROOT/base"
	local _head_dir="$TEST_ROOT/head"
	mkdir -p "$_base_dir" "$_head_dir"

	{
		printf '#!/usr/bin/env bash\n'
		printf 'declare -n ref1=var1\n'
		printf 'declare -A config\n'
		printf 'declare -n ref2=var2\n'
	} >"$_base_dir/mixed.sh"

	# Same content with 2 lines inserted at top
	{
		printf '#!/usr/bin/env bash\n'
		printf '# extra comment 1\n'
		printf '# extra comment 2\n'
		printf 'declare -n ref1=var1\n'
		printf 'declare -A config\n'
		printf 'declare -n ref2=var2\n'
	} >"$_head_dir/mixed.sh"

	local _base_scan="$TEST_ROOT/base.tsv"
	local _head_scan="$TEST_ROOT/head.tsv"
	"$HELPER" scan "$_base_dir" --output "$_base_scan" --metric bash32-compat
	"$HELPER" scan "$_head_dir" --output "$_head_scan" --metric bash32-compat

	run_diff "$_base_scan" "$_head_scan" bash32-compat

	if [ "$_DIFF_EXIT" -eq 0 ]; then
		print_result "bash32 multi-pattern-shift: mixed patterns shifted → exit 0 (no regression)" 0
	else
		print_result "bash32 multi-pattern-shift: mixed patterns shifted → exit 0 (no regression)" 1 \
			"got exit $_DIFF_EXIT (output: $_DIFF_OUTPUT)"
	fi
	teardown
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Scan format check — verify output is <file>\t<pattern>\t<count>
# (no line numbers embedded in the key).
# ---------------------------------------------------------------------------
test_scan_format() {
	setup
	local _scan_dir="$TEST_ROOT/scan"
	mkdir -p "$_scan_dir"

	{
		printf '#!/usr/bin/env bash\n'
		printf 'declare -n ref1=var1\n'
		printf 'declare -n ref2=var2\n'
		printf 'declare -n ref3=var3\n'
		printf 'declare -A map\n'
	} >"$_scan_dir/check.sh"

	local _scan_out="$TEST_ROOT/scan.tsv"
	"$HELPER" scan "$_scan_dir" --output "$_scan_out" --metric bash32-compat

	# Should have exactly 2 lines: one for nameref (count 3), one for assoc-array (count 1)
	local _line_count
	_line_count=$(wc -l <"$_scan_out" | tr -d ' ')

	local _fail=0
	local _msg=""

	if [ "$_line_count" -ne 2 ]; then
		_fail=1
		_msg="expected 2 lines, got $_line_count. Content: $(cat "$_scan_out")"
	fi

	# Verify no line numbers in the key (col2 should be just the pattern name)
	if [ "$_fail" -eq 0 ]; then
		local _has_line_numbers
		_has_line_numbers=$(awk -F '\t' '$2 ~ /:[0-9]+$/' "$_scan_out" | wc -l | tr -d ' ')
		if [ "$_has_line_numbers" -gt 0 ]; then
			_fail=1
			_msg="found line numbers in key column. Content: $(cat "$_scan_out")"
		fi
	fi

	# Verify nameref count is 3
	if [ "$_fail" -eq 0 ]; then
		local _nameref_count
		_nameref_count=$(awk -F '\t' '$2=="nameref" {print $3}' "$_scan_out")
		if [ "$_nameref_count" != "3" ]; then
			_fail=1
			_msg="expected nameref count 3, got '$_nameref_count'. Content: $(cat "$_scan_out")"
		fi
	fi

	# Verify assoc-array count is 1
	if [ "$_fail" -eq 0 ]; then
		local _assoc_count
		_assoc_count=$(awk -F '\t' '$2=="assoc-array" {print $3}' "$_scan_out")
		if [ "$_assoc_count" != "1" ]; then
			_fail=1
			_msg="expected assoc-array count 1, got '$_assoc_count'. Content: $(cat "$_scan_out")"
		fi
	fi

	print_result "bash32 scan-format: output is <file>\\t<pattern>\\t<count> (no line nums in key)" "$_fail" "$_msg"
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

test_line_shift_no_regression
test_genuine_new_violation
test_removed_violation
test_multi_pattern_shift
test_scan_format

printf '\n'
if [ "$TESTS_FAILED" -eq 0 ]; then
	printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%b%d/%d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
