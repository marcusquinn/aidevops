#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture strings deliberately contain unexpanded $vars
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-nesting-depth-scanner.sh — tests for scanners/nesting-depth.sh (t2430)
#
# Covers all four false-positive classes from the old AWK scanner, plus:
#   - Per-function reset (depth does not compound across functions)
#   - Real deep nesting (positive case)
#   - elif chain correctness
#   - Heredoc body isolation
#   - done with redirect/pipe/herestring
#
# Usage: bash test-nesting-depth-scanner.sh
#   Exits 0 on all pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCANNER="${SCRIPT_DIR}/../scanners/nesting-depth.sh"
PASS=0
FAIL=0
TMPDIR_TEST=""

cleanup() {
	if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
		rm -rf "$TMPDIR_TEST"
	fi
	return 0
}
trap cleanup EXIT

TMPDIR_TEST=$(mktemp -d)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
assert_depth() {
	local _label="$1"
	local _fixture_file="$2"
	local _expected="$3"
	local _actual

	_actual=$(bash "$SCANNER" "$_fixture_file" 2>/dev/null)
	if [ "$_actual" = "$_expected" ]; then
		printf '  PASS: %s (expected=%s, got=%s)\n' "$_label" "$_expected" "$_actual"
		PASS=$((PASS + 1))
	else
		printf '  FAIL: %s (expected=%s, got=%s)\n' "$_label" "$_expected" "$_actual" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_func_depth() {
	local _label="$1"
	local _fixture_file="$2"
	local _func_name="$3"
	local _expected="$4"
	local _actual

	_actual=$(bash "$SCANNER" --per-function "$_fixture_file" 2>/dev/null |
		awk -F'\t' -v fn="$_func_name" '$1 == fn { print $2 }')
	if [ "$_actual" = "$_expected" ]; then
		printf '  PASS: %s (func=%s, expected=%s, got=%s)\n' "$_label" "$_func_name" "$_expected" "$_actual"
		PASS=$((PASS + 1))
	else
		printf '  FAIL: %s (func=%s, expected=%s, got=%s)\n' "$_label" "$_func_name" "$_expected" "$_actual" >&2
		FAIL=$((FAIL + 1))
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _write_fixture <filename> <content>
# Writes a fixture file to the test tmpdir. Using a helper avoids putting
# fixture function declarations at column 1 in the host file, which would
# trip the pre-commit return-statement ratchet.
# ---------------------------------------------------------------------------
_write_fixture() {
	local _name="$1"
	local _content="$2"
	printf '%s\n' "$_content" > "${TMPDIR_TEST}/${_name}"
	return 0
}

# ---------------------------------------------------------------------------
# Fixture 1: elif chain (FP class 1)
# 10 elifs + fi = net depth 1 (not 10+)
# ---------------------------------------------------------------------------
_write_fixture "elif-chain.sh" '#!/bin/bash
func_elif() {
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

# ---------------------------------------------------------------------------
# Fixture 2: Prose containing bare keywords (FP class 2)
# No real control flow, just strings with if/for/while/case words
# ---------------------------------------------------------------------------
_write_fixture "prose-keywords.sh" '#!/bin/bash
func_prose() {
  echo "warn action for runner=%s"
  printf "for all users, if it matches\n"
  echo "while processing, until done with case"
  echo "if you need help, for each item, while waiting"
  return 0
}'

# ---------------------------------------------------------------------------
# Fixture 3: done <<<"$rows" (FP class 3)
# while/done with herestring, pipe, redirect — all should close properly
# ---------------------------------------------------------------------------
_write_fixture "done-variants.sh" '#!/bin/bash
func_herestring() {
  while IFS= read -r row; do
    echo "$row"
  done <<<"$rows"
  return 0
}

func_pipe() {
  while IFS= read -r line; do
    echo "$line"
  done | sort
  return 0
}

func_redirect() {
  while IFS= read -r line; do
    echo "$line"
  done > /tmp/out.txt
  return 0
}'

# ---------------------------------------------------------------------------
# Fixture 4: Heredoc body containing keywords (FP class 4 overlap)
# Keywords inside heredoc should contribute 0 to nesting
# ---------------------------------------------------------------------------
_write_fixture "heredoc-keywords.sh" '#!/bin/bash
func_heredoc() {
  cat <<HEREDOC
if this is a test
for all intents
while we wait
case in point
done with this
fi
esac
until further notice
HEREDOC
  return 0
}'

# ---------------------------------------------------------------------------
# Fixture 5: Per-function reset
# 10 functions each with max depth 3 → file max should be 3, not 30
# ---------------------------------------------------------------------------
_write_fixture "per-function-reset.sh" '#!/bin/bash
f1() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }
f2() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }
f3() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }
f4() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }
f5() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }
f6() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }
f7() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }
f8() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }
f9() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }
f10() { if true; then for i in 1; do while true; do break; done; done; fi; return 0; }'

# ---------------------------------------------------------------------------
# Fixture 6: Real deep nesting (positive case — should report actual depth)
# if > for > while > case > if = depth 5
# ---------------------------------------------------------------------------
_write_fixture "deep-nesting.sh" '#!/bin/bash
func_deep() {
  if [ -n "$1" ]; then
    for i in 1 2 3; do
      while read -r line; do
        case "$line" in
          a)
            if [ "$i" -eq 1 ]; then
              echo "depth 5"
            fi
            ;;
        esac
      done
    done
  fi
  return 0
}'

# ---------------------------------------------------------------------------
# Fixture 7: Only echo/printf — depth 0
# ---------------------------------------------------------------------------
_write_fixture "no-nesting.sh" '#!/bin/bash
func_flat() {
  echo "hello"
  printf "world\n"
  local var="value"
  return 0
}'

# ---------------------------------------------------------------------------
# Fixture 8: Subshell containing control flow
# ---------------------------------------------------------------------------
_write_fixture "subshell.sh" '#!/bin/bash
func_subshell() {
  result=$(
    if [ -n "$1" ]; then
      for item in "$@"; do
        echo "$item"
      done
    fi
  )
  echo "$result"
  return 0
}'

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
printf '=== nesting-depth scanner tests (t2430) ===\n\n'

# Check scanner exists
if [ ! -f "$SCANNER" ]; then
	printf 'FATAL: scanner not found at %s\n' "$SCANNER" >&2
	exit 2
fi

# Check shfmt available
if ! command -v shfmt >/dev/null 2>&1; then
	printf 'SKIP: shfmt not available, cannot run AST-based tests\n' >&2
	exit 0
fi

printf 'Test group: FP class 1 — elif chain\n'
assert_depth "elif chain of 10: file max = 1" "$TMPDIR_TEST/elif-chain.sh" "1"
assert_func_depth "elif chain: func_elif depth = 1" "$TMPDIR_TEST/elif-chain.sh" "func_elif" "1"

printf '\nTest group: FP class 2 — prose keywords\n'
assert_depth "prose keywords: file max = 0" "$TMPDIR_TEST/prose-keywords.sh" "0"
assert_func_depth "prose keywords: func_prose depth = 0" "$TMPDIR_TEST/prose-keywords.sh" "func_prose" "0"

printf '\nTest group: FP class 3 — done variants\n'
assert_depth "done variants: file max = 1" "$TMPDIR_TEST/done-variants.sh" "1"
assert_func_depth "herestring: func_herestring depth = 1" "$TMPDIR_TEST/done-variants.sh" "func_herestring" "1"
assert_func_depth "pipe: func_pipe depth = 1" "$TMPDIR_TEST/done-variants.sh" "func_pipe" "1"
assert_func_depth "redirect: func_redirect depth = 1" "$TMPDIR_TEST/done-variants.sh" "func_redirect" "1"

printf '\nTest group: FP class 4 — heredoc keywords\n'
assert_depth "heredoc keywords: file max = 0" "$TMPDIR_TEST/heredoc-keywords.sh" "0"
assert_func_depth "heredoc: func_heredoc depth = 0" "$TMPDIR_TEST/heredoc-keywords.sh" "func_heredoc" "0"

printf '\nTest group: per-function reset\n'
assert_depth "10 funcs each depth 3: file max = 3" "$TMPDIR_TEST/per-function-reset.sh" "3"

printf '\nTest group: real deep nesting (positive case)\n'
assert_depth "deep nesting: file max = 5" "$TMPDIR_TEST/deep-nesting.sh" "5"
assert_func_depth "deep: func_deep depth = 5" "$TMPDIR_TEST/deep-nesting.sh" "func_deep" "5"

printf '\nTest group: no nesting\n'
assert_depth "flat code: file max = 0" "$TMPDIR_TEST/no-nesting.sh" "0"

printf '\nTest group: subshell nesting\n'
assert_depth "subshell: file max = 2" "$TMPDIR_TEST/subshell.sh" "2"

printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0
