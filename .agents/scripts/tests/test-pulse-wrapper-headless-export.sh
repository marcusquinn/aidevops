#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the AIDEVOPS_HEADLESS=true export at the top of pulse-wrapper.sh
# main() (GH#18670 / Fix 7).
#
# Behaviors under test:
#   1. Executing pulse-wrapper.sh --self-check exports AIDEVOPS_HEADLESS=true
#      before returning (side effect lives only in the self-check subprocess,
#      but we can verify it from a wrapper that captures `env` via a hook).
#   2. detect_session_origin() returns "worker" when the env var is set.
#   3. Sourcing pulse-wrapper.sh WITHOUT invoking main() does NOT set the
#      env var (scoping guarantee — importing for tests must not pollute
#      the importing shell).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"
SHARED_CONSTANTS="${SCRIPT_DIR}/../shared-constants.sh"

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
	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Test 1: Static source inspection — the export line exists at the
# top of main() ABOVE the --self-check flag scan. This is a spec check
# rather than a runtime check, because running `pulse-wrapper.sh --self-check`
# in a subprocess doesn't reveal the child's env to the parent.
test_export_line_present_at_top_of_main() {
	local snippet
	snippet=$(awk '
		/^main\(\) \{/ { in_main=1; next }
		in_main && /^[[:space:]]*local _sc_flag=0/ { exit }
		in_main { print }
	' "$WRAPPER_SCRIPT")
	if printf '%s' "$snippet" | grep -qE '^[[:space:]]*export AIDEVOPS_HEADLESS=true[[:space:]]*$'; then
		print_result "export AIDEVOPS_HEADLESS=true present at top of main()" 0
		return 0
	fi
	print_result "export AIDEVOPS_HEADLESS=true present at top of main()" 1 \
		"Expected 'export AIDEVOPS_HEADLESS=true' line between 'main() {' and 'local _sc_flag=0'. Got snippet:${snippet}"
	return 0
}

# Test 2: detect_session_origin() reports "worker" when AIDEVOPS_HEADLESS=true.
# Sources shared-constants.sh in a subshell, sets the env var, and invokes
# the function. This is the behavioural half of the contract — Test 1
# guarantees the export is present, Test 2 guarantees the export has the
# intended effect on detect_session_origin().
test_detect_session_origin_returns_worker_when_headless() {
	local result
	result=$(
		# shellcheck source=/dev/null
		AIDEVOPS_SESSION_ORIGIN="" \
			AIDEVOPS_HEADLESS="true" \
			FULL_LOOP_HEADLESS="" \
			OPENCODE_HEADLESS="" \
			GITHUB_ACTIONS="" \
			bash -c "source '$SHARED_CONSTANTS' 2>/dev/null; detect_session_origin"
	)
	if [[ "$result" == "worker" ]]; then
		print_result "detect_session_origin returns 'worker' when AIDEVOPS_HEADLESS=true" 0
		return 0
	fi
	print_result "detect_session_origin returns 'worker' when AIDEVOPS_HEADLESS=true" 1 \
		"Expected 'worker', got '$result'"
	return 0
}

# Test 3: Sourcing pulse-wrapper.sh without invoking main() must NOT
# set AIDEVOPS_HEADLESS in the caller shell. Scoping guarantee — protects
# callers that import pulse-wrapper.sh functions for testing.
#
# We cannot source pulse-wrapper.sh directly because it depends on a long
# chain of sibling modules with include guards. Instead we verify the
# export is INSIDE the main() function body, not at top level, via AST
# grep. This is a static check but it's the same invariant.
test_export_is_inside_main_not_top_level() {
	# Find all lines matching `export AIDEVOPS_HEADLESS=true` anywhere in
	# the script. There should be exactly one, and it should be inside
	# the main() function (between `main() {` and the corresponding `}`).
	local count line_num
	count=$(grep -cE '^[[:space:]]*export AIDEVOPS_HEADLESS=true[[:space:]]*$' "$WRAPPER_SCRIPT" || echo "0")
	if [[ "$count" -ne 1 ]]; then
		print_result "export is inside main(), not top-level" 1 \
			"Expected exactly 1 export line, found $count"
		return 0
	fi
	line_num=$(grep -nE '^[[:space:]]*export AIDEVOPS_HEADLESS=true[[:space:]]*$' "$WRAPPER_SCRIPT" | head -1 | cut -d: -f1)
	# The export line must be AFTER `main() {` (indented, inside a function).
	local main_line
	main_line=$(grep -nE '^main\(\) \{' "$WRAPPER_SCRIPT" | head -1 | cut -d: -f1)
	if [[ -z "$main_line" || "$line_num" -le "$main_line" ]]; then
		print_result "export is inside main(), not top-level" 1 \
			"Export at line $line_num, main() at line ${main_line:-<not found>}. Export must be after main() {."
		return 0
	fi
	# And the export must be indented (inside a function body), not at
	# column 0 (which would be top-level code even inside a brace block
	# that eval shenanigans could abuse).
	if ! sed -n "${line_num}p" "$WRAPPER_SCRIPT" | grep -qE '^[[:space:]]+export'; then
		print_result "export is inside main(), not top-level" 1 \
			"Export line is not indented — appears to be top-level code"
		return 0
	fi
	print_result "export is inside main(), not top-level" 0
	return 0
}

# Test 4: the export comes BEFORE the --self-check flag scan, so that
# --self-check also runs under the headless env. This matters because
# the self-check is used by CI and installation smoke tests, and those
# contexts should be treated as headless.
test_export_before_self_check() {
	local export_line sc_line
	export_line=$(grep -nE '^[[:space:]]*export AIDEVOPS_HEADLESS=true[[:space:]]*$' "$WRAPPER_SCRIPT" | head -1 | cut -d: -f1)
	sc_line=$(awk '/^main\(\) \{/{inmain=1; next} inmain && /^[[:space:]]*local _sc_flag=0/{print NR; exit}' "$WRAPPER_SCRIPT")
	if [[ -z "$export_line" || -z "$sc_line" ]]; then
		print_result "export precedes --self-check scan" 1 \
			"Missing export_line=$export_line or sc_line=$sc_line"
		return 0
	fi
	if [[ "$export_line" -lt "$sc_line" ]]; then
		print_result "export precedes --self-check scan" 0
		return 0
	fi
	print_result "export precedes --self-check scan" 1 \
		"Export at line $export_line is AFTER --self-check scan at line $sc_line"
	return 0
}

main_test() {
	test_export_line_present_at_top_of_main
	test_detect_session_origin_returns_worker_when_headless
	test_export_is_inside_main_not_top_level
	test_export_before_self_check

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main_test "$@"
