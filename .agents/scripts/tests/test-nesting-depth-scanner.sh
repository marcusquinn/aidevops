#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-nesting-depth-scanner.sh — tests for scanners/nesting-depth.sh (GH#20105)
#
# Covers all four documented false-positive classes, per-function reset,
# real deep nesting, heredoc bodies, case statements, and AWK fallback.
#
# Usage: test-nesting-depth-scanner.sh [--verbose]
#
# Exit codes: 0 = all passed, 1 = failures

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="${SCRIPT_DIR}/../scanners/nesting-depth.sh"
TMP_DIR=""
PASS=0
FAIL=0
VERBOSE="${1:-}"

cleanup() {
	if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
		rm -rf "$TMP_DIR"
	fi
	return 0
}
trap cleanup EXIT

_setup() {
	TMP_DIR=$(mktemp -d)
	return 0
}

_assert_depth() {
	local _name="$1"
	local _file="$2"
	local _expected="$3"
	local _env="${4:-}"

	local _actual
	if [ -n "$_env" ]; then
		_actual=$(env "$_env" "$SCANNER" "$_file" 2>/dev/null)
	else
		_actual=$("$SCANNER" "$_file" 2>/dev/null)
	fi

	if [ "${_actual:-}" = "$_expected" ]; then
		PASS=$((PASS + 1))
		if [ "$VERBOSE" = "--verbose" ]; then
			printf '  PASS: %s (expected=%s, got=%s)\n' "$_name" "$_expected" "$_actual"
		fi
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s (expected=%s, got=%s)\n' "$_name" "$_expected" "${_actual:-<empty>}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------

test_simple_nesting() {
	printf 'Test: simple if/for/while nesting (depth=3)\n'
	cat <<'EOF' >"$TMP_DIR/simple.sh"
#!/bin/bash
foo() {
  if true; then
    for x in 1 2 3; do
      while true; do
        echo "deep"
        break
      done
    done
  fi
  return 0
}
EOF
	_assert_depth "shfmt" "$TMP_DIR/simple.sh" "3"
	return 0
}

test_elif_chain_no_inflation() {
	printf 'Test: elif chain of 10 elifs — depth=1 (not +9)\n'
	cat <<'EOF' >"$TMP_DIR/elif.sh"
#!/bin/bash
check() {
  if [ "$1" = "a" ]; then
    echo "a"
  elif [ "$1" = "b" ]; then
    echo "b"
  elif [ "$1" = "c" ]; then
    echo "c"
  elif [ "$1" = "d" ]; then
    echo "d"
  elif [ "$1" = "e" ]; then
    echo "e"
  elif [ "$1" = "f" ]; then
    echo "f"
  elif [ "$1" = "g" ]; then
    echo "g"
  elif [ "$1" = "h" ]; then
    echo "h"
  elif [ "$1" = "i" ]; then
    echo "i"
  elif [ "$1" = "j" ]; then
    echo "j"
  else
    echo "other"
  fi
  return 0
}
EOF
	_assert_depth "shfmt" "$TMP_DIR/elif.sh" "1"
	return 0
}

test_prose_keywords_no_count() {
	printf 'Test: prose containing bare keywords — depth=0\n'
	cat <<'EOF' >"$TMP_DIR/prose.sh"
#!/bin/bash
msg() {
  echo "for all users, if it matches"
  printf "warn action for runner=%s\n" "$1"
  echo "while processing, until done"
  return 0
}
EOF
	_assert_depth "shfmt" "$TMP_DIR/prose.sh" "0"
	return 0
}

test_done_herestring() {
	printf 'Test: done <<<"\044rows" — depth=1 (not stuck at +1)\n'
	cat <<'EOF' >"$TMP_DIR/herestring.sh"
#!/bin/bash
process() {
  local rows="a b c"
  while IFS= read -r line; do
    echo "$line"
  done <<<"$rows"
  return 0
}
EOF
	_assert_depth "shfmt" "$TMP_DIR/herestring.sh" "1"
	return 0
}

test_done_pipe() {
	printf 'Test: done | cmd — depth=1\n'
	cat <<'EOF' >"$TMP_DIR/done_pipe.sh"
#!/bin/bash
process() {
  for f in *.sh; do
    echo "$f"
  done | sort
  return 0
}
EOF
	_assert_depth "shfmt" "$TMP_DIR/done_pipe.sh" "1"
	return 0
}

test_done_redirect() {
	printf 'Test: done > file — depth=1\n'
	cat <<'EOF' >"$TMP_DIR/done_redirect.sh"
#!/bin/bash
process() {
  for f in *.sh; do
    echo "$f"
  done > /tmp/output.txt
  return 0
}
EOF
	_assert_depth "shfmt" "$TMP_DIR/done_redirect.sh" "1"
	return 0
}

test_heredoc_keywords() {
	printf 'Test: heredoc body with keywords — depth=0\n'
	cat <<'OUTER' >"$TMP_DIR/heredoc.sh"
#!/bin/bash
show_help() {
  cat <<'EOF'
if you want to use this tool:
  for each file, while processing:
    case by case until done
  done
EOF
  return 0
}
OUTER
	_assert_depth "shfmt" "$TMP_DIR/heredoc.sh" "0"
	return 0
}

test_per_function_reset() {
	printf 'Test: 10 functions each depth=3 — max=3 (not 30)\n'
	{
		echo '#!/bin/bash'
		for i in $(seq 1 10); do
			printf 'f%d() { if true; then for x in 1; do while true; do echo; break; done; done; fi; }\n' "$i"
		done
	} >"$TMP_DIR/multi_func.sh"
	_assert_depth "shfmt" "$TMP_DIR/multi_func.sh" "3"
	return 0
}

test_case_statement() {
	printf 'Test: case with nested if — depth=2\n'
	cat <<'EOF' >"$TMP_DIR/case.sh"
#!/bin/bash
dispatch() {
  case "$1" in
    start)
      if [ -n "$2" ]; then
        echo "starting $2"
      fi
      ;;
    stop)
      echo "stopping"
      ;;
  esac
  return 0
}
EOF
	_assert_depth "shfmt" "$TMP_DIR/case.sh" "2"
	return 0
}

test_real_deep_nesting() {
	printf 'Test: real deep nesting (depth=5)\n'
	cat <<'EOF' >"$TMP_DIR/deep.sh"
#!/bin/bash
deep() {
  if true; then
    for x in 1; do
      while true; do
        case "$x" in
          1)
            if [ -n "$x" ]; then
              echo "depth 5"
            fi
            ;;
        esac
        break
      done
    done
  fi
  return 0
}
EOF
	_assert_depth "shfmt" "$TMP_DIR/deep.sh" "5"
	return 0
}

test_empty_file() {
	printf 'Test: empty file — depth=0\n'
	printf '#!/bin/bash\n' >"$TMP_DIR/empty.sh"
	_assert_depth "shfmt" "$TMP_DIR/empty.sh" "0"
	return 0
}

test_top_level_code() {
	printf 'Test: top-level code (no functions) — depth counted correctly\n'
	cat <<'EOF' >"$TMP_DIR/toplevel.sh"
#!/bin/bash
if [ -n "$1" ]; then
  for f in *.sh; do
    echo "$f"
  done
fi
EOF
	_assert_depth "shfmt" "$TMP_DIR/toplevel.sh" "2"
	return 0
}

test_awk_fallback() {
	printf 'Test: AWK fallback when shfmt forced off\n'
	cat <<'EOF' >"$TMP_DIR/awk_test.sh"
#!/bin/bash
foo() {
  if true; then
    for x in 1; do
      echo "nested"
    done
  fi
  return 0
}
EOF
	_assert_depth "AWK fallback" "$TMP_DIR/awk_test.sh" "2" "NESTING_DEPTH_FORCE_AWK=1"
	return 0
}

test_headless_runtime_lib() {
	printf 'Test: headless-runtime-lib.sh — depth <=12 (sanity)\n'
	local _hrlib
	_hrlib="$(cd "$SCRIPT_DIR/../.." && git ls-files '*.sh' 2>/dev/null | grep headless-runtime-lib | head -1)"
	if [ -z "$_hrlib" ]; then
		printf '  SKIP: headless-runtime-lib.sh not found\n'
		return 0
	fi
	local _hrlib_path
	_hrlib_path="$(cd "$SCRIPT_DIR/../.." && pwd)/$_hrlib"
	local _depth
	_depth=$("$SCANNER" "$_hrlib_path" 2>/dev/null)
	if [ "${_depth:-0}" -le 12 ]; then
		PASS=$((PASS + 1))
		if [ "$VERBOSE" = "--verbose" ]; then
			printf '  PASS: headless-runtime-lib.sh depth=%s (<=12)\n' "$_depth"
		fi
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: headless-runtime-lib.sh depth=%s (expected <=12)\n' "$_depth"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

main() {
	if [ ! -x "$SCANNER" ]; then
		printf 'ERROR: scanner not found or not executable: %s\n' "$SCANNER" >&2
		exit 2
	fi

	_setup

	printf 'Running nesting-depth scanner tests...\n\n'

	test_simple_nesting
	test_elif_chain_no_inflation
	test_prose_keywords_no_count
	test_done_herestring
	test_done_pipe
	test_done_redirect
	test_heredoc_keywords
	test_per_function_reset
	test_case_statement
	test_real_deep_nesting
	test_empty_file
	test_top_level_code
	test_awk_fallback
	test_headless_runtime_lib

	printf '\n--- Results: %d passed, %d failed ---\n' "$PASS" "$FAIL"

	if [ "$FAIL" -gt 0 ]; then
		return 1
	fi
	return 0
}

main "$@"
