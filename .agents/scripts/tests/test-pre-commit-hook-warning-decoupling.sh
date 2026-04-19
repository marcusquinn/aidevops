#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pre-commit-hook-warning-decoupling.sh — Tests that the advisory
# (print_warning) branch of validate_string_literals does NOT increment the
# violations counter. Only the error branch (new introductions under ratchet
# semantics) may increment.
#
# Regression history:
#   - GH#19839 (t2228 anti-pattern) — print_warning was incorrectly
#     incrementing the violations counter, turning an advisory into a blocker.
#   - t2230 — validator upgraded to ratchet semantics (head-vs-staged diff).
#     The advisory invariant is preserved: pre-existing debt emits a warning
#     and never blocks; only NEW literals emit an error and block.
#
# What this test guards:
#   1. The warning branch (pre-existing literals) does NOT increment violations.
#   2. The "[WARNING]" marker still appears in stderr for pre-existing debt.
#   3. A clean file (no repeated literals) exits 0 silently.
#   4. The real hook source preserves this structure — ((++violations)) only
#      appears inside the print_error branch, never in the print_warning branch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOK_SCRIPT="${SCRIPT_DIR}/../pre-commit-hook.sh"

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
# Helper: simulate the ratchet-aware validate_string_literals in isolation.
# Pre-existing state is stubbed via _stub_head_content, so the test is
# self-contained and doesn't require a real git HEAD.
# The inlined function body MUST match the ratchet version in pre-commit-hook.sh.
# ---------------------------------------------------------------------------
WARNING_CAPTURED=""
ERROR_CAPTURED=""
STUB_HEAD_CONTENT=""

stub_print_warning() {
	local msg="$1"
	WARNING_CAPTURED="$msg"
	echo "[WARNING] $msg" >&2
	return 0
}

stub_print_error() {
	local msg="$1"
	ERROR_CAPTURED="$msg"
	echo "[ERROR] $msg" >&2
	return 0
}

stub_print_info() {
	local msg="$1"
	echo "[INFO] $msg" >&2
	return 0
}

_stub_get_head_content() {
	printf '%s' "$STUB_HEAD_CONTENT"
	return 0
}

# Ratchet-aware validator. Mirrors validate_string_literals in
# pre-commit-hook.sh but with stubbed head-content and print_* helpers.
validate_string_literals_under_test() {
	local violations=0

	stub_print_info "Validating string literals (ratchet)..."

	for file in "$@"; do
		if [[ -f "$file" ]]; then
			local staged_repeated head_repeated=0
			staged_repeated=$(grep -v '^\s*#' "$file" | grep -oE '"[^"]{4,}"' | grep -vE '^"[0-9]+\.?[0-9]*"$' | grep -vE '^"\$' | sort | uniq -c | awk '$1 >= 3' | wc -l | tr -d ' ')
			[[ -z "$staged_repeated" ]] && staged_repeated=0

			local head_content
			head_content=$(_stub_get_head_content)
			if [[ -n "$head_content" ]]; then
				head_repeated=$(printf '%s\n' "$head_content" | grep -v '^\s*#' | grep -oE '"[^"]{4,}"' | grep -vE '^"[0-9]+\.?[0-9]*"$' | grep -vE '^"\$' | sort | uniq -c | awk '$1 >= 3' | wc -l | tr -d ' ')
				[[ -z "$head_repeated" ]] && head_repeated=0
			fi

			if ((staged_repeated > head_repeated)); then
				stub_print_error "NEW repeated string literals in $file (new: $((staged_repeated - head_repeated)), pre-existing: $head_repeated)"
				((++violations))
			elif ((staged_repeated > 0)); then
				stub_print_warning "Pre-existing repeated string literals in $file: $staged_repeated distinct literal(s) (not blocking)"
			fi
		fi
	done

	return $violations
}

# ---------------------------------------------------------------------------
# Test 1: Pre-existing literals equal to staged → WARNING branch, no increment.
# ---------------------------------------------------------------------------
test_warning_branch_does_not_increment() {
	local fixture="${TEST_ROOT}/preexisting_literals.sh"
	cat >"$fixture" <<'EOF'
#!/usr/bin/env bash
msg1="assert this string"
msg2="assert this string"
msg3="assert this string"
msg4="assert this string"
EOF

	# Head content is identical — pre-existing debt, no new introduction.
	STUB_HEAD_CONTENT=$(cat "$fixture")
	WARNING_CAPTURED=""
	ERROR_CAPTURED=""

	local ret=0
	validate_string_literals_under_test "$fixture" 2>/dev/null || ret=$?

	if [ "$ret" -eq 0 ] && [ -n "$WARNING_CAPTURED" ] && [ -z "$ERROR_CAPTURED" ]; then
		print_result "warning branch does not increment violations" 0
	else
		print_result "warning branch does not increment violations" 1 \
			"expected exit 0 + warning + no error, got exit=$ret warn='$WARNING_CAPTURED' err='$ERROR_CAPTURED'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: Warning branch still emits "[WARNING]" to stderr.
# ---------------------------------------------------------------------------
test_emits_warning_to_stderr() {
	local fixture="${TEST_ROOT}/preexisting_literals2.sh"
	cat >"$fixture" <<'EOF'
#!/usr/bin/env bash
msg1="assert this string"
msg2="assert this string"
msg3="assert this string"
msg4="assert this string"
EOF

	STUB_HEAD_CONTENT=$(cat "$fixture")

	local stderr_out
	stderr_out=$(validate_string_literals_under_test "$fixture" 2>&1 >/dev/null || true)

	if echo "$stderr_out" | grep -q "\[WARNING\]"; then
		print_result "warning branch emits [WARNING] to stderr" 0
	else
		print_result "warning branch emits [WARNING] to stderr" 1 \
			"expected '[WARNING]' in stderr, got: $stderr_out"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: Clean file (no repeated literals) exits 0 silently.
# ---------------------------------------------------------------------------
test_returns_zero_on_clean_file() {
	local fixture="${TEST_ROOT}/clean_file.sh"
	cat >"$fixture" <<'EOF'
#!/usr/bin/env bash
# A clean file with no repeated string literals
foo() {
	local msg="hello world"
	local other="something different"
	return 0
}
EOF

	STUB_HEAD_CONTENT=$(cat "$fixture")
	WARNING_CAPTURED=""
	ERROR_CAPTURED=""

	local ret=0
	validate_string_literals_under_test "$fixture" 2>/dev/null || ret=$?

	if [ "$ret" -eq 0 ] && [ -z "$WARNING_CAPTURED" ] && [ -z "$ERROR_CAPTURED" ]; then
		print_result "clean file exits 0 silently" 0
	else
		print_result "clean file exits 0 silently" 1 \
			"expected exit 0 + no output, got exit=$ret warn='$WARNING_CAPTURED' err='$ERROR_CAPTURED'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: The real hook source places ((++violations)) ONLY inside the
#         print_error branch of validate_string_literals. The print_warning
#         branch must never increment.
# ---------------------------------------------------------------------------
test_hook_source_warning_branch_no_increment() {
	if [ ! -f "$HOOK_SCRIPT" ]; then
		print_result "hook source: warning branch does not increment" 1 \
			"pre-commit-hook.sh not found at $HOOK_SCRIPT"
		return 0
	fi

	# Extract the validate_string_literals function body.
	local func_body
	func_body=$(awk '/^validate_string_literals\(\)/{found=1} found{print} /^}$/{if(found){exit}}' "$HOOK_SCRIPT")

	if [ -z "$func_body" ]; then
		print_result "hook source: warning branch does not increment" 1 \
			"could not extract validate_string_literals body from $HOOK_SCRIPT"
		return 0
	fi

	# Find the print_warning line number, then check no ((++violations))
	# appears between it and the next structural boundary (elif/else/fi/done).
	local warning_line_num
	warning_line_num=$(echo "$func_body" | grep -n 'print_warning' | head -1 | cut -d: -f1)
	if [ -z "$warning_line_num" ]; then
		# Hook has no print_warning call — acceptable (no warning branch to gate).
		print_result "hook source: warning branch does not increment" 0
		return 0
	fi

	# Look at up to 10 lines following print_warning. Any ((++violations)) in
	# that window would mean the warning branch blocks — the GH#19839 bug.
	local following_block
	following_block=$(echo "$func_body" | sed -n "${warning_line_num},$((warning_line_num + 10))p")
	if echo "$following_block" | grep -qF '((++violations))'; then
		print_result "hook source: warning branch does not increment" 1 \
			"((++violations)) appears within 10 lines after print_warning — regression of GH#19839"
	else
		print_result "hook source: warning branch does not increment" 0
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	setup

	test_warning_branch_does_not_increment
	test_emits_warning_to_stderr
	test_returns_zero_on_clean_file
	test_hook_source_warning_branch_no_increment

	teardown

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
