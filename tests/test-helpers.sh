#!/usr/bin/env bash
# test-helpers.sh
#
# Shared test framework helpers for all test scripts.
# Provides pass(), fail(), skip(), section(), and summary functions
# with consistent counter tracking and colored output.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
#
# Counter variables (available after sourcing):
#   PASS_COUNT, FAIL_COUNT, SKIP_COUNT, TOTAL_COUNT
#
# Optional: set VERBOSE="--verbose" before sourcing to enable verbose output
# for pass() and skip() (they are silent by default for cleaner CI output).

# --- Test Framework Counters ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

# Record a passing test and print status.
# Arguments: description string
pass() {
	local msg="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;32mPASS\033[0m %s\n" "$msg"
	return 0
}

# Record a failing test and print status with optional detail.
# Arguments: description string, optional detail string
fail() {
	local msg="$1"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$msg"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

# Record a skipped test and print status.
# Arguments: description string
skip() {
	local msg="$1"
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;33mSKIP\033[0m %s\n" "$msg"
	return 0
}

# Print a section header for test grouping.
# Arguments: section name string
section() {
	local name="$1"
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$name"
	return 0
}

# Print a summary of test results and exit with appropriate code.
# Call this at the end of your test script.
# Exit codes: 0 = all pass, 1 = failures found
print_summary() {
	echo ""
	echo "========================================"
	printf "  \033[1mResults: %d total, \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m, \033[0;33m%d skipped\033[0m\n" \
		"$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
	echo "========================================"

	if [[ "$FAIL_COUNT" -gt 0 ]]; then
		echo ""
		printf "\033[0;31mFAILURES DETECTED - review output above\033[0m\n"
		return 1
	else
		echo ""
		printf "\033[0;32mAll tests passed.\033[0m\n"
		return 0
	fi
}
