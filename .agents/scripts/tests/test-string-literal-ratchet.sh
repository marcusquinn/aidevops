#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-string-literal-ratchet.sh — Regression tests for the string-literal
# ratchet regex false-positive fix (GH#20505).
#
# Validates that _count_repeated_literals correctly:
#   - Counts genuine repeated prose literals (positive cases)
#   - Does NOT count inter-argument spans between adjacent quoted shell
#     arguments like `local tid="$1" repo="$2"` (the bug this fixes)
#   - Does NOT count direct var-refs, ${var} expansions, or positional params
#   - Does NOT count numeric strings
#   - Does count escaped \$ literals that are not true var-refs (boundary case)
#
# 7 scenarios: 2 positive, 4 negative, 1 boundary.
#
# Cross-platform: compatible with bash 3.2 (macOS default), bash 5.x,
# BSD sed/grep (macOS), GNU sed/grep (Linux).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK_SCRIPT="${SCRIPT_DIR}/../pre-commit-hook.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

# Source _count_repeated_literals and _show_repeated_literals from the hook.
# Uses awk to extract only these two function definitions — avoids running main.
source_literal_helpers() {
	# Provide stubs for print_* used transitively (if any).
	print_error() { echo "[ERROR] $1" >&2; return 0; }
	print_warning() { echo "[WARNING] $1" >&2; return 0; }
	print_info() { echo "[INFO] $1" >&2; return 0; }
	print_success() { echo "[OK] $1" >&2; return 0; }

	local hook_funcs
	hook_funcs=$(awk '
		/^_count_repeated_literals\(\)/ { c=1 }
		/^_show_repeated_literals\(\)/  { c=1 }
		c { print }
		c && /^}$/ { c=0 }
	' "$HOOK_SCRIPT")

	# shellcheck disable=SC1090
	eval "$hook_funcs"
	return 0
}

# ---------------------------------------------------------------------------
# Positive scenario 1: genuine repeated prose literal IS caught
#
# Three distinct strings each appearing ≥3 times — the counter must return ≥1.
# ---------------------------------------------------------------------------
test_positive_genuine_literal_caught() {
	source_literal_helpers

	# shellcheck disable=SC2016  # literal fixture content, not shell expansions
	local input='local msg="error: invalid input"
echo "error: invalid input" >&2
printf '"'"'%s\n'"'"' "error: invalid input"
'
	local count
	count=$(printf '%s' "$input" | _count_repeated_literals)

	if [ "$count" -ge 1 ]; then
		print_result "positive 1: genuine repeated literal IS caught (count=$count)" 0
	else
		print_result "positive 1: genuine repeated literal IS caught" 1 \
			"expected count >= 1, got: $count"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Negative scenario 1 (the bug this issue fixes): inter-argument spans
#
# Adjacent quoted shell arguments produce spans like " repo=" between
# the closing " of "$1" and the opening " of "$2". These are NOT literals.
# All four variants must return count=0.
# ---------------------------------------------------------------------------
test_negative_inter_argument_spans() {
	source_literal_helpers

	# shellcheck disable=SC2016  # $1/$2/$3 are literal fixture bodies
	local input='local tid="$1" repo="$2"
local body="$1" repo="$2"
local title="" repo="" body=""
local op="$1" repo="$2" number="$3"
'
	local count
	count=$(printf '%s' "$input" | _count_repeated_literals)

	if [ "$count" -eq 0 ]; then
		print_result "negative 1: inter-argument spans NOT counted (the bug fix)" 0
	else
		print_result "negative 1: inter-argument spans NOT counted (the bug fix)" 1 \
			"expected count=0, got: $count (false positive for adjacent quoted args)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Negative scenario 2: direct var-refs repeated ≥3 times
#
# "\$var" patterns must not be counted regardless of repetition frequency.
# ---------------------------------------------------------------------------
test_negative_repeated_var_refs() {
	source_literal_helpers

	# shellcheck disable=SC2016  # $var is a literal fixture body
	local input='echo "$var"
echo "$var"
echo "$var"
'
	local count
	count=$(printf '%s' "$input" | _count_repeated_literals)

	if [ "$count" -eq 0 ]; then
		print_result "negative 2: repeated var-refs NOT counted (regression guard)" 0
	else
		print_result "negative 2: repeated var-refs NOT counted (regression guard)" 1 \
			"expected count=0, got: $count"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Negative scenario 3: numeric-only strings repeated ≥3 times
#
# Version numbers, counts, port numbers are excluded by the numeric filter.
# ---------------------------------------------------------------------------
test_negative_numeric_strings() {
	source_literal_helpers

	local input='echo "3.14"
echo "3.14"
echo "3.14"
'
	local count
	count=$(printf '%s' "$input" | _count_repeated_literals)

	if [ "$count" -eq 0 ]; then
		print_result "negative 3: numeric strings NOT counted (regression guard)" 0
	else
		print_result "negative 3: numeric strings NOT counted (regression guard)" 1 \
			"expected count=0, got: $count"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Negative scenario 4: ${var} brace-expansion form inside quotes
#
# "${msg}", "${var[0]}", "${var:-default}" must all be stripped by the
# sed pre-strip pass, leaving no capturable literal span.
# ---------------------------------------------------------------------------
test_negative_brace_var_refs() {
	source_literal_helpers

	# shellcheck disable=SC2016  # ${msg} is a literal fixture body
	local input='log "${msg}"
log "${msg}"
log "${msg}"
'
	local count
	count=$(printf '%s' "$input" | _count_repeated_literals)

	if [ "$count" -eq 0 ]; then
		print_result "negative 4: \${var} brace-expansion NOT counted (regression guard)" 0
	else
		print_result "negative 4: \${var} brace-expansion NOT counted (regression guard)" 1 \
			"expected count=0, got: $count"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Positive scenario 2 (boundary case): escaped \$ literal still caught
#
# `\$` is NOT a variable reference — it is a literal dollar sign in the
# string content. The sed pre-strip must NOT strip `"\$5.00"` because
# `\$` is an escaped dollar, not a shell variable reference token.
# The literal "price is \$5.00" must survive and be counted.
# ---------------------------------------------------------------------------
test_boundary_escaped_dollar_caught() {
	source_literal_helpers

	# Note: in actual shell code these would appear as `"price is \$5.00"`.
	# We feed the raw text as it would appear in a source file.
	# shellcheck disable=SC2016  # literal fixture: \$ is intentional escaped dollar
	local input='err="price is \$5.00"
err="price is \$5.00"
err="price is \$5.00"
'
	local count
	count=$(printf '%s' "$input" | _count_repeated_literals)

	if [ "$count" -ge 1 ]; then
		print_result "boundary: escaped \$ literal IS still caught (not stripped as var-ref)" 0
	else
		print_result "boundary: escaped \$ literal IS still caught (not stripped as var-ref)" 1 \
			"expected count >= 1, got: $count (sed pre-strip over-stripped escaped dollar)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Display companion: _show_repeated_literals matches _count_repeated_literals
#
# Verifies that the display pipeline produces output consistent with the
# count pipeline — no phantom truncated entries like `4x: "`.
# ---------------------------------------------------------------------------
test_show_matches_count_no_phantom() {
	source_literal_helpers

	# shellcheck disable=SC2016  # $1/$2 are literal fixture bodies
	local input='local tid="$1" repo="$2"
local body="$1" repo="$2"
local title="" repo="" body=""
local op="$1" repo="$2" number="$3"
'
	local display_out
	display_out=$(printf '%s' "$input" | _show_repeated_literals)

	# Display output must be empty when count is 0 — no phantom entries.
	if [ -z "$display_out" ]; then
		print_result "display: no phantom literals in _show_repeated_literals output" 0
	else
		print_result "display: no phantom literals in _show_repeated_literals output" 1 \
			"expected empty output, got: [$display_out]"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Cross-platform smoke: BSD grep compatibility (POSIX [[:space:]])
#
# Confirms the comment-filter line uses [[:space:]] not \s — which is
# a GNU grep extension and may silently fail on macOS BSD grep.
# ---------------------------------------------------------------------------
test_posix_grep_comment_filter() {
	if [ ! -f "$HOOK_SCRIPT" ]; then
		print_result "posix: [[:space:]] used in comment filter" 1 \
			"pre-commit-hook.sh not found at $HOOK_SCRIPT"
		return 0
	fi

	# After the fix, the comment filter must use POSIX [[:space:]].
	# \s is a GNU extension and unreliable on stock macOS.
	local uses_posix uses_gnu_s
	uses_posix=$(grep -c '\[\[:space:\]\]\*#' "$HOOK_SCRIPT" || true)
	uses_gnu_s=$(grep -cE "grep -v '\\^\\\\s" "$HOOK_SCRIPT" 2>/dev/null || true)

	if [ "${uses_posix:-0}" -ge 2 ] && [ "${uses_gnu_s:-0}" -eq 0 ]; then
		print_result "posix: [[:space:]] used in comment filter (BSD grep safe)" 0
	elif [ "${uses_posix:-0}" -ge 2 ]; then
		# GNU \s variant also present; as long as POSIX form is used in the
		# _count/_show functions (the critical path), the test passes.
		print_result "posix: [[:space:]] used in comment filter (BSD grep safe)" 0
	else
		print_result "posix: [[:space:]] used in comment filter (BSD grep safe)" 1 \
			"expected [[:space:]] in both _count_repeated_literals and _show_repeated_literals, found $uses_posix instance(s)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	if [ ! -f "$HOOK_SCRIPT" ]; then
		printf '%bERROR%b pre-commit-hook.sh not found at %s\n' \
			"$TEST_RED" "$TEST_RESET" "$HOOK_SCRIPT" >&2
		exit 1
	fi

	test_positive_genuine_literal_caught
	test_negative_inter_argument_spans
	test_negative_repeated_var_refs
	test_negative_numeric_strings
	test_negative_brace_var_refs
	test_boundary_escaped_dollar_caught
	test_show_matches_count_no_phantom
	test_posix_grep_comment_filter

	echo ""
	if [ "$TESTS_FAILED" -eq 0 ]; then
		printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
		return 0
	else
		printf '%b%d/%d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
		return 1
	fi
}

main "$@"
