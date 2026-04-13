#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the ANSI-strip guard in pulse-dispatch-core.sh pre-creation
# logic (GH#18671 / Fix 6a).
#
# The bug: grep -oE '/[^ ]*Git/[^ ]*' extracts the worktree path but
# captures trailing ANSI reset sequences because they contain no
# whitespace. The subsequent [[ -d $path ]] check then fails.
#
# This test verifies that the ANSI-strip `sed $'s/\x1b\\[[0-9;]*m//g'`
# recovers a clean path from sample worktree-helper.sh output.

set -euo pipefail

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

# Simulated worktree-helper output — matches the real format including
# ANSI escapes on the Path: line. This is a byte-faithful copy of the
# actual output captured from a live dispatch.
build_simulated_wt_output() {
	local branch="$1"
	local path="$2"
	# Use printf %b to interpret \x1b escape sequences.
	printf '%b' '\n\x1b[0;34mCreating worktree with new branch '"'"''"$branch"''"'"'...\x1b[0m\nPreparing worktree (new branch '"'"''"$branch"''"'"')\nHEAD is now at abcdef01 some commit\n\n\x1b[0;32mWorktree created successfully!\x1b[0m\n\nPath: \x1b[1m'"$path"'\x1b[0m\nBranch: \x1b[1m'"$branch"'\x1b[0m\n\nTo start working:\n  cd '"$path"'\n'
}

# This is the fixed extraction logic — mirrors pulse-dispatch-core.sh:
#   _wt_output=$(printf '%s' "$_wt_output" | sed $'s/\x1b\\[[0-9;]*m//g')
#   worker_worktree_path=$(printf '%s' "$_wt_output" | grep -oE '/[^ ]*Git/[^ ]*' | head -1)
extract_path_fixed() {
	local wt_output="$1"
	local stripped
	stripped=$(printf '%s' "$wt_output" | sed $'s/\x1b\\[[0-9;]*m//g')
	printf '%s' "$stripped" | grep -oE '/[^ ]*Git/[^ ]*' | head -1
}

# This is the OLD broken extraction logic — same grep, no sed.
extract_path_broken() {
	local wt_output="$1"
	printf '%s' "$wt_output" | grep -oE '/[^ ]*Git/[^ ]*' | head -1
}

test_fixed_extractor_returns_clean_path() {
	local wt_out
	wt_out=$(build_simulated_wt_output "feature/auto-test" "/tmp/aidevops-test-wt/Git/aidevops-feature-auto-test")
	local extracted
	extracted=$(extract_path_fixed "$wt_out")
	if [[ "$extracted" == "/tmp/aidevops-test-wt/Git/aidevops-feature-auto-test" ]]; then
		print_result "fixed extractor returns clean path without ANSI suffix" 0
		return 0
	fi
	# shellcheck disable=SC2028  # literal \x1b rendering is diagnostic, not a runtime escape
	print_result "fixed extractor returns clean path without ANSI suffix" 1 \
		"Expected clean path, got: '${extracted}' (hex-dump: $(printf '%s' "$extracted" | od -c | head -2 | tr '\n' ' '))"
	return 0
}

test_broken_extractor_regression() {
	# Assert that the BROKEN extractor would indeed have produced a
	# tainted path — this is the regression guard against reintroducing
	# the bug. If this test starts failing, it means the grep pattern
	# has been tightened and the sed strip may no longer be needed;
	# revisit pulse-dispatch-core.sh accordingly.
	local wt_out
	wt_out=$(build_simulated_wt_output "feature/auto-test" "/tmp/aidevops-test-wt/Git/aidevops-feature-auto-test")
	local broken
	broken=$(extract_path_broken "$wt_out")
	# The broken extractor captures the first `/…/Git/…` match, which is
	# the `\x1b[0;34m`-opened "Creating worktree" line — on that line
	# there IS no Git/ path, so the first actual match is the Path: line
	# whose value is followed by \x1b[0m (no space). Verify the capture
	# contains a non-path suffix.
	if [[ "$broken" == *$'\x1b[0m'* ]]; then
		print_result "broken extractor regression guard: old path has ANSI suffix" 0
		return 0
	fi
	# If the test simulation produces a clean path even without the sed
	# strip, the simulation is wrong — the whole test suite is moot.
	# Fail loudly so the mismatch is visible.
	print_result "broken extractor regression guard: old path has ANSI suffix" 1 \
		"Broken extractor did NOT produce an ANSI-suffixed path, got: '${broken}' — simulation may not match real output"
	return 0
}

test_fixed_extractor_passes_dir_check_with_tmpdir() {
	# Stronger assertion: create a real temp directory, simulate the
	# extractor producing its path (with ANSI wrapper), and verify the
	# fixed extractor yields a string that passes the subsequent -d check.
	local tmp_base tmp_path
	tmp_base=$(mktemp -d) || {
		print_result "fixed extractor passes real -d dir check" 1 "mktemp failed"
		return 0
	}
	mkdir -p "${tmp_base}/Git"
	tmp_path="${tmp_base}/Git/aidevops-feature-auto-realcheck"
	mkdir -p "$tmp_path"

	local wt_out extracted
	wt_out=$(build_simulated_wt_output "feature/auto-realcheck" "$tmp_path")
	extracted=$(extract_path_fixed "$wt_out")

	if [[ -n "$extracted" && -d "$extracted" ]]; then
		rm -rf "$tmp_base"
		print_result "fixed extractor passes real -d dir check" 0
		return 0
	fi
	rm -rf "$tmp_base"
	print_result "fixed extractor passes real -d dir check" 1 \
		"Extracted '${extracted}' failed -d check against real dir '${tmp_path}'"
	return 0
}

test_extractor_handles_path_with_multiple_ansi_runs() {
	# Real worktree-helper output has several ANSI runs. Make sure the
	# sed strip removes ALL of them, not just the first or last.
	local path='/tmp/Git/aidevops-multi-ansi'
	local wt_out
	# shellcheck disable=SC2028  # these are literal ANSI bytes injected into the simulation fixture
	wt_out=$(printf '%b' '\x1b[0;34mINFO\x1b[0m start\nPath: \x1b[1m'"$path"'\x1b[0m\n\x1b[0;32mSUCCESS\x1b[0m done\n')
	local extracted
	extracted=$(extract_path_fixed "$wt_out")
	if [[ "$extracted" == "$path" ]]; then
		print_result "extractor handles multiple ANSI runs on different lines" 0
		return 0
	fi
	print_result "extractor handles multiple ANSI runs on different lines" 1 \
		"Expected '$path', got '$extracted'"
	return 0
}

main() {
	test_fixed_extractor_returns_clean_path
	test_broken_extractor_regression
	test_fixed_extractor_passes_dir_check_with_tmpdir
	test_extractor_handles_path_with_multiple_ansi_runs

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
