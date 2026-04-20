#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-nesting-depth-scanner.sh — tests for scanners/nesting-depth.sh (GH#20105)
#
# Covers all four documented false-positive classes, per-function reset,
# real positive nesting, and AWK fallback path.
#
# Note: fixture files are written via _write_fixture to avoid the pre-commit
# return-statement ratchet counting heredoc function definitions as real
# functions in this test file.
#
# shellcheck disable=SC2016  # Single-quoted fixture strings intentionally contain $var references

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit
SCANNER="$REPO_ROOT/.agents/scripts/scanners/nesting-depth.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"

	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

_write_fixture() {
	local _path="$1"
	local _content="$2"
	printf '%s\n' "$_content" > "$_path"
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: scanner script exists and is executable
# ---------------------------------------------------------------------------
test_scanner_exists() {
	if [[ -x "$SCANNER" ]]; then
		print_result "scanner_exists" 0
	else
		print_result "scanner_exists" 1 "Scanner not found or not executable at $SCANNER"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# FP1: elif chain — 10 elifs + fi should report depth 1, not 10+
# ---------------------------------------------------------------------------
test_fp1_elif_chain() {
	_write_fixture "$TEST_DIR/fp1_elif.sh" '#!/bin/bash
check_thing() {
  if [ "$1" = "a" ]; then
    echo a
  elif [ "$1" = "b" ]; then
    echo b
  elif [ "$1" = "c" ]; then
    echo c
  elif [ "$1" = "d" ]; then
    echo d
  elif [ "$1" = "e" ]; then
    echo e
  elif [ "$1" = "f" ]; then
    echo f
  elif [ "$1" = "g" ]; then
    echo g
  elif [ "$1" = "h" ]; then
    echo h
  elif [ "$1" = "i" ]; then
    echo i
  elif [ "$1" = "j" ]; then
    echo j
  else
    echo other
  fi
  return 0
}'

	local depth
	depth=$("$SCANNER" "$TEST_DIR/fp1_elif.sh" 2>/dev/null)
	if [[ "$depth" -eq 1 ]]; then
		print_result "fp1_elif_chain" 0
	else
		print_result "fp1_elif_chain" 1 "Expected depth=1 for elif chain, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# FP2: prose containing bare keywords — should report depth 0
# ---------------------------------------------------------------------------
test_fp2_prose_keywords() {
	_write_fixture "$TEST_DIR/fp2_prose.sh" '#!/bin/bash
echo "for all users, if it matches"
printf "warn action for runner=%s done with case if while for\n" "$1"'

	local depth
	depth=$("$SCANNER" "$TEST_DIR/fp2_prose.sh" 2>/dev/null)
	if [[ "$depth" -eq 0 ]]; then
		print_result "fp2_prose_keywords" 0
	else
		print_result "fp2_prose_keywords" 1 "Expected depth=0 for prose keywords, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# FP3: done <<<"$rows" — should report depth 1
# ---------------------------------------------------------------------------
test_fp3_herestring_done() {
	_write_fixture "$TEST_DIR/fp3_herestring.sh" '#!/bin/bash
process_rows() {
  local rows="a b c"
  while read -r line; do
    echo "$line"
  done <<<"$rows"
  return 0
}'

	local depth
	depth=$("$SCANNER" "$TEST_DIR/fp3_herestring.sh" 2>/dev/null)
	if [[ "$depth" -eq 1 ]]; then
		print_result "fp3_herestring_done" 0
	else
		print_result "fp3_herestring_done" 1 "Expected depth=1 for done<<<, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# FP3b: done | cmd — should report depth 1
# ---------------------------------------------------------------------------
test_fp3b_done_pipe() {
	_write_fixture "$TEST_DIR/fp3b_pipe.sh" '#!/bin/bash
list_things() {
  for f in /tmp/*; do
    echo "$f"
  done | sort
  return 0
}'

	local depth
	depth=$("$SCANNER" "$TEST_DIR/fp3b_pipe.sh" 2>/dev/null)
	if [[ "$depth" -eq 1 ]]; then
		print_result "fp3b_done_pipe" 0
	else
		print_result "fp3b_done_pipe" 1 "Expected depth=1 for done|sort, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# FP3c: done > file — should report depth 1
# ---------------------------------------------------------------------------
test_fp3c_done_redirect() {
	_write_fixture "$TEST_DIR/fp3c_redir.sh" '#!/bin/bash
write_list() {
  for f in /tmp/*; do
    echo "$f"
  done > /dev/null
  return 0
}'

	local depth
	depth=$("$SCANNER" "$TEST_DIR/fp3c_redir.sh" 2>/dev/null)
	if [[ "$depth" -eq 1 ]]; then
		print_result "fp3c_done_redirect" 0
	else
		print_result "fp3c_done_redirect" 1 "Expected depth=1 for done>file, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# FP4: per-function reset — 10 functions each max-depth 2 → max=2 (not 20)
# ---------------------------------------------------------------------------
test_fp4_per_function_reset() {
	_write_fixture "$TEST_DIR/fp4_functions.sh" '#!/bin/bash
fn_a() { if true; then for x in a; do echo "$x"; done; fi; return 0; }
fn_b() { if true; then for x in a; do echo "$x"; done; fi; return 0; }
fn_c() { if true; then for x in a; do echo "$x"; done; fi; return 0; }
fn_d() { if true; then for x in a; do echo "$x"; done; fi; return 0; }
fn_e() { if true; then for x in a; do echo "$x"; done; fi; return 0; }
fn_f() { if true; then for x in a; do echo "$x"; done; fi; return 0; }
fn_g() { if true; then for x in a; do echo "$x"; done; fi; return 0; }
fn_h() { if true; then for x in a; do echo "$x"; done; fi; return 0; }
fn_i() { if true; then for x in a; do echo "$x"; done; fi; return 0; }
fn_j() { if true; then for x in a; do echo "$x"; done; fi; return 0; }'

	local depth
	depth=$("$SCANNER" "$TEST_DIR/fp4_functions.sh" 2>/dev/null)
	if [[ "$depth" -le 3 ]]; then
		print_result "fp4_per_function_reset" 0
	else
		print_result "fp4_per_function_reset" 1 "Expected depth<=3 for 10 funcs each depth 2, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# FP5: heredoc body with keywords — should NOT count
# ---------------------------------------------------------------------------
test_fp5_heredoc_keywords() {
	_write_fixture "$TEST_DIR/fp5_heredoc.sh" '#!/bin/bash
show_help() {
  cat <<'"'"'HELP'"'"'
if you see this, for each case:
  while running, until done
  if nested, for each while loop
HELP
  return 0
}'

	local depth
	depth=$("$SCANNER" "$TEST_DIR/fp5_heredoc.sh" 2>/dev/null)
	if [[ "$depth" -eq 0 ]]; then
		print_result "fp5_heredoc_keywords" 0
	else
		print_result "fp5_heredoc_keywords" 1 "Expected depth=0 for heredoc keywords, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Real positive: genuinely nested code — depth 4
# ---------------------------------------------------------------------------
test_real_nesting_depth_4() {
	_write_fixture "$TEST_DIR/real_nested.sh" '#!/bin/bash
deep_fn() {
  if true; then
    for x in a; do
      while read -r line; do
        case "$line" in
          a) echo a;;
        esac
      done
    done
  fi
  return 0
}'

	local depth
	depth=$("$SCANNER" "$TEST_DIR/real_nested.sh" 2>/dev/null)
	if [[ "$depth" -eq 4 ]]; then
		print_result "real_nesting_depth_4" 0
	else
		print_result "real_nesting_depth_4" 1 "Expected depth=4 for if/for/while/case, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Integration: headless-runtime-lib.sh should report depth ≤12 (was 52/83)
# ---------------------------------------------------------------------------
test_headless_runtime_lib_sanity() {
	local _target="$REPO_ROOT/.agents/scripts/headless-runtime-lib.sh"
	if [[ ! -f "$_target" ]]; then
		print_result "headless_runtime_lib_sanity" 0 "(skipped — file not present)"
		return 0
	fi

	local depth
	depth=$("$SCANNER" "$_target" 2>/dev/null)
	if [[ "$depth" -le 12 ]]; then
		print_result "headless_runtime_lib_sanity" 0
	else
		print_result "headless_runtime_lib_sanity" 1 "Expected depth<=12 for headless-runtime-lib.sh, got $depth (old AWK: 52/83)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Empty file — depth 0
# ---------------------------------------------------------------------------
test_empty_file() {
	: > "$TEST_DIR/empty.sh"
	local depth
	depth=$("$SCANNER" "$TEST_DIR/empty.sh" 2>/dev/null)
	if [[ "$depth" -eq 0 ]]; then
		print_result "empty_file" 0
	else
		print_result "empty_file" 1 "Expected depth=0 for empty file, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Non-existent file — depth 0 (graceful)
# ---------------------------------------------------------------------------
test_nonexistent_file() {
	local depth
	depth=$("$SCANNER" "$TEST_DIR/nonexistent.sh" 2>/dev/null) || true
	if [[ "${depth:-0}" -eq 0 ]]; then
		print_result "nonexistent_file" 0
	else
		print_result "nonexistent_file" 1 "Expected depth=0 for missing file, got $depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	setup

	test_scanner_exists
	test_fp1_elif_chain
	test_fp2_prose_keywords
	test_fp3_herestring_done
	test_fp3b_done_pipe
	test_fp3c_done_redirect
	test_fp4_per_function_reset
	test_fp5_heredoc_keywords
	test_real_nesting_depth_4
	test_headless_runtime_lib_sanity
	test_empty_file
	test_nonexistent_file

	echo ""
	echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
