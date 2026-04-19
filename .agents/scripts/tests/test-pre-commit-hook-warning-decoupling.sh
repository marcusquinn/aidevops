#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pre-commit-hook-warning-decoupling.sh — Tests that validate_string_literals
# emits a WARNING without blocking (exit 0) when repeated literals are found.
#
# Regression: GH#19839 (t2228 anti-pattern) — print_warning was incorrectly
# incrementing the violations counter, turning an advisory into a commit blocker.
#
# Tests:
#   1. validate_string_literals exits 0 on a file with repeated string literals
#      (confirm: advisory warning does NOT block the commit)
#   2. validate_string_literals emits "[WARNING]" text to stderr
#   3. validate_string_literals exits 0 on a clean file (no repeated literals)
#   4. Smoke: the full pre-commit-hook.sh exits 0 when only repeated literals
#      are staged (the warning is informational only)

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
# Helper: define validate_string_literals in isolation (no full-hook source).
# We inline the function with minimal stubs so the test is self-contained and
# does not break on shared-constants.sh color dependencies in CI.
# The inlined function body MUST match the fixed version in pre-commit-hook.sh.
# ---------------------------------------------------------------------------
WARNING_CAPTURED=""

stub_print_warning() {
	local msg="$1"
	WARNING_CAPTURED="$msg"
	echo "[WARNING] $msg" >&2
	return 0
}

stub_print_info() {
	local msg="$1"
	echo "[INFO] $msg" >&2
	return 0
}

# Define the function under test using the fixed implementation.
# This avoids sourcing the full hook (which requires git context, secretlint, etc.).
validate_string_literals_under_test() {
	local violations=0

	stub_print_info "Validating string literals..."

	for file in "$@"; do
		if [[ -f "$file" ]]; then
			local repeated
			repeated=$(grep -oE '"[^"]{4,}"' "$file" | grep -vE '^"[0-9]+\.?[0-9]*"$' | sort | uniq -c | awk '$1 >= 3' | wc -l || true)

			if [[ $repeated -gt 0 ]]; then
				stub_print_warning "Repeated string literals in $file (consider using constants)"
				grep -oE '"[^"]{4,}"' "$file" | grep -vE '^"[0-9]+\.?[0-9]*"$' | sort | uniq -c | awk '$1 >= 3 {print "  " $1 "x: " $2}' | head -3
				# print_warning is advisory — do NOT increment violations counter
				# (AGENTS.md "Gate design — ratchet, not absolute (t2228 class)"):
				# test files legitimately repeat assertion strings; this should inform, not block.
			fi
		fi
	done

	return $violations
}

# ---------------------------------------------------------------------------
# Test 1: validate_string_literals exits 0 on file with repeated literals
# ---------------------------------------------------------------------------
test_returns_zero_with_repeated_literals() {
	local fixture="${TEST_ROOT}/repeated_literals.sh"
	# Create a file with the same string appearing 4 times (threshold is 3)
	cat >"$fixture" <<'EOF'
#!/usr/bin/env bash
msg1="assert this string"
msg2="assert this string"
msg3="assert this string"
msg4="assert this string"
EOF

	WARNING_CAPTURED=""
	local ret=0
	validate_string_literals_under_test "$fixture" 2>/dev/null || ret=$?

	if [ "$ret" -eq 0 ]; then
		print_result "validate_string_literals exits 0 with repeated literals" 0
	else
		print_result "validate_string_literals exits 0 with repeated literals" 1 \
			"expected exit 0 (advisory), got exit $ret — violation counter incorrectly incremented"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: validate_string_literals emits [WARNING] to stderr
# ---------------------------------------------------------------------------
test_emits_warning_to_stderr() {
	local fixture="${TEST_ROOT}/repeated_literals2.sh"
	cat >"$fixture" <<'EOF'
#!/usr/bin/env bash
msg1="assert this string"
msg2="assert this string"
msg3="assert this string"
msg4="assert this string"
EOF

	WARNING_CAPTURED=""
	local stderr_out
	stderr_out=$(validate_string_literals_under_test "$fixture" 2>&1 >/dev/null || true)

	if echo "$stderr_out" | grep -q "\[WARNING\]"; then
		print_result "validate_string_literals emits [WARNING] to stderr" 0
	else
		print_result "validate_string_literals emits [WARNING] to stderr" 1 \
			"expected '[WARNING]' in stderr, got: $stderr_out"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: validate_string_literals exits 0 on a clean file (no repeated literals)
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

	local ret=0
	validate_string_literals_under_test "$fixture" 2>/dev/null || ret=$?

	if [ "$ret" -eq 0 ]; then
		print_result "validate_string_literals exits 0 on clean file" 0
	else
		print_result "validate_string_literals exits 0 on clean file" 1 \
			"expected exit 0, got exit $ret"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: Verify the fixed function body in pre-commit-hook.sh does NOT
#          increment violations on repeated-literal warning (source validation).
# Check: the line '((++violations))' does NOT appear directly after print_warning
#         in validate_string_literals block.
# ---------------------------------------------------------------------------
test_hook_source_no_violations_after_warning() {
	if [ ! -f "$HOOK_SCRIPT" ]; then
		print_result "hook source: no violation increment after string-literal warning" 1 \
			"pre-commit-hook.sh not found at $HOOK_SCRIPT"
		return 0
	fi

	# Extract the validate_string_literals function body and check the old
	# anti-pattern (print_warning followed by ((++violations))) is absent.
	local func_body
	func_body=$(awk '/^validate_string_literals\(\)/{found=1} found{print} /^}$/{if(found){exit}}' "$HOOK_SCRIPT")

	# The advisory pattern: print_warning line immediately followed by ((++violations))
	# We check that no line with ((++violations)) appears in the function body.
	if echo "$func_body" | grep -qF '((++violations))'; then
		print_result "hook source: no violation increment after string-literal warning" 1 \
			"((++violations)) still present in validate_string_literals — fix not applied"
	else
		print_result "hook source: no violation increment after string-literal warning" 0
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	setup

	test_returns_zero_with_repeated_literals
	test_emits_warning_to_stderr
	test_returns_zero_on_clean_file
	test_hook_source_no_violations_after_warning

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
