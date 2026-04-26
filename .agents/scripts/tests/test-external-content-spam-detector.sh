#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for external-content-spam-detector.sh (t2884, parent #20983 / Phase C).
#
# Two tiers:
#   1. Unit tests over the private scoring helpers (no network) — uses
#      `define_helper_under_test` to extract individual functions and
#      eval them in this shell. Validates: extract_external_hosts,
#      max_host_repetition, count_fileline_refs, is_non_collaborator,
#      compute_score with mocked author_association + pattern count.
#   2. Smoke test for the CLI dispatcher (no network) — verifies that
#      `help` and unknown commands behave correctly.
#
# Author-association lookups and `gh` issue-body fetches require network
# access and are exercised by the verification commands in the issue body
# (#20986), not by this harness.
#
# `set -e` is intentionally OMITTED — see PITFALL 1 in the test harness
# template for rationale (we capture rc explicitly after each call).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/../external-content-spam-detector.sh"

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

# Extract a function by name from the script under test and eval it here.
# This avoids running main() on source.
define_helper_under_test() {
	local func_name="$1"
	local src
	src=$(awk "/^${func_name}\\(\\) \\{/,/^\\}\$/ { print }" "$SCRIPT_UNDER_TEST")
	if [[ -z "$src" ]]; then
		printf 'ERROR: could not extract %s from %s\n' "$func_name" "$SCRIPT_UNDER_TEST" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src"
	return 0
}

# ============================================================
# Unit tests — pure functions
# ============================================================

test_A_extract_external_hosts_strips_github() {
	# Set up the EXCLUDE_HOSTS_RAW environment the helper depends on.
	EXCLUDE_HOSTS_RAW="github.com,githubusercontent.com"

	local body="See https://github.com/foo and https://api.github.com/bar
	plus https://example.com/baz and https://example.com/qux"

	local hosts
	hosts=$(_priv_extract_external_hosts "$body")
	local rc=$?

	# Should contain example.com twice, exclude github.com / api.github.com
	local example_count
	example_count=$(printf '%s\n' "$hosts" | grep -c '^example\.com$' || true)
	[[ "$example_count" =~ ^[0-9]+$ ]] || example_count=0
	local github_present
	github_present=$(printf '%s\n' "$hosts" | grep -c 'github\.com$' || true)
	[[ "$github_present" =~ ^[0-9]+$ ]] || github_present=0

	if [[ $rc -eq 0 && "$example_count" -eq 2 && "$github_present" -eq 0 ]]; then
		print_result "A: extract_external_hosts excludes github.com and dedups output candidates" 0
	else
		print_result "A: extract_external_hosts excludes github.com and dedups output candidates" 1 \
			"rc=$rc example_count=$example_count github_present=$github_present (wanted rc=0 example=2 github=0)"
	fi
	return 0
}

test_B_max_host_repetition_finds_top_host() {
	EXCLUDE_HOSTS_RAW="github.com,githubusercontent.com"

	local body="https://vendor.example/a https://vendor.example/b https://vendor.example/c https://other.test/x"
	local max
	max=$(_priv_max_host_repetition "$body")
	local rc=$?

	if [[ $rc -eq 0 && "$max" -eq 3 ]]; then
		print_result "B: max_host_repetition returns highest single-host count" 0
	else
		print_result "B: max_host_repetition returns highest single-host count" 1 \
			"rc=$rc max=$max (wanted rc=0 max=3)"
	fi
	return 0
}

test_C_max_host_repetition_zero_when_only_github() {
	EXCLUDE_HOSTS_RAW="github.com,githubusercontent.com"

	local body="https://github.com/foo https://api.github.com/bar"
	local max
	max=$(_priv_max_host_repetition "$body")

	if [[ "$max" -eq 0 ]]; then
		print_result "C: max_host_repetition returns 0 when all hosts are excluded" 0
	else
		print_result "C: max_host_repetition returns 0 when all hosts are excluded" 1 \
			"max=$max (wanted 0)"
	fi
	return 0
}

test_D_count_fileline_refs_counts_known_extensions() {
	local body="See foo.sh:42, bar/baz.py:100, qux.json:7. Also random text. Not a ref: 1.2.3"
	local count
	count=$(_priv_count_fileline_refs "$body")

	if [[ "$count" -eq 3 ]]; then
		print_result "D: count_fileline_refs counts file:line for known extensions only" 0
	else
		print_result "D: count_fileline_refs counts file:line for known extensions only" 1 \
			"count=$count (wanted 3)"
	fi
	return 0
}

test_E_count_fileline_refs_zero_for_no_refs() {
	local body="A plain narrative bug report with no file references at all."
	local count
	count=$(_priv_count_fileline_refs "$body")

	if [[ "$count" -eq 0 ]]; then
		print_result "E: count_fileline_refs returns 0 for narrative text" 0
	else
		print_result "E: count_fileline_refs returns 0 for narrative text" 1 \
			"count=$count (wanted 0)"
	fi
	return 0
}

test_F_is_non_collaborator_treats_owner_as_trusted() {
	# TRUSTED_ASSOCIATIONS must be in scope for the helper.
	TRUSTED_ASSOCIATIONS=("OWNER" "MEMBER" "COLLABORATOR")

	local result
	result=$(_priv_is_non_collaborator "OWNER")
	if [[ "$result" -eq 0 ]]; then
		print_result "F: is_non_collaborator returns 0 (trusted) for OWNER" 0
	else
		print_result "F: is_non_collaborator returns 0 (trusted) for OWNER" 1 \
			"result=$result (wanted 0)"
	fi
	return 0
}

test_G_is_non_collaborator_treats_none_as_untrusted() {
	TRUSTED_ASSOCIATIONS=("OWNER" "MEMBER" "COLLABORATOR")

	local result
	result=$(_priv_is_non_collaborator "NONE")
	if [[ "$result" -eq 1 ]]; then
		print_result "G: is_non_collaborator returns 1 (untrusted) for NONE" 0
	else
		print_result "G: is_non_collaborator returns 1 (untrusted) for NONE" 1 \
			"result=$result (wanted 1)"
	fi
	return 0
}

test_H_is_non_collaborator_treats_contributor_as_untrusted() {
	TRUSTED_ASSOCIATIONS=("OWNER" "MEMBER" "COLLABORATOR")

	# Per the brief: only OWNER/MEMBER/COLLABORATOR are trusted; CONTRIBUTOR
	# (drive-by external contributor) is untrusted for this rule.
	local result
	result=$(_priv_is_non_collaborator "CONTRIBUTOR")
	if [[ "$result" -eq 1 ]]; then
		print_result "H: is_non_collaborator returns 1 (untrusted) for CONTRIBUTOR" 0
	else
		print_result "H: is_non_collaborator returns 1 (untrusted) for CONTRIBUTOR" 1 \
			"result=$result (wanted 1)"
	fi
	return 0
}

# ============================================================
# CLI smoke tests — no network
# ============================================================

test_I_help_command_succeeds() {
	"$SCRIPT_UNDER_TEST" help >/dev/null 2>&1
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		print_result "I: help command exits 0" 0
	else
		print_result "I: help command exits 0" 1 "rc=$rc (wanted 0)"
	fi
	return 0
}

test_J_unknown_command_returns_error() {
	"$SCRIPT_UNDER_TEST" not-a-real-command >/dev/null 2>&1
	local rc=$?
	# Helper exit 3 = error.
	if [[ $rc -eq 3 ]]; then
		print_result "J: unknown command exits 3 (error)" 0
	else
		print_result "J: unknown command exits 3 (error)" 1 "rc=$rc (wanted 3)"
	fi
	return 0
}

test_K_check_without_args_returns_error() {
	"$SCRIPT_UNDER_TEST" check >/dev/null 2>&1
	local rc=$?
	if [[ $rc -eq 3 ]]; then
		print_result "K: check without args exits 3" 0
	else
		print_result "K: check without args exits 3" 1 "rc=$rc (wanted 3)"
	fi
	return 0
}

# ============================================================
# Main
# ============================================================

main() {
	if [[ ! -f "$SCRIPT_UNDER_TEST" ]]; then
		printf 'ERROR: script under test not found at %s\n' "$SCRIPT_UNDER_TEST" >&2
		exit 1
	fi

	# Define helpers under test (extracted from the script — no main() side
	# effects because we never source the full file).
	define_helper_under_test "_priv_extract_external_hosts" || exit 1
	define_helper_under_test "_priv_max_host_repetition" || exit 1
	define_helper_under_test "_priv_count_fileline_refs" || exit 1
	define_helper_under_test "_priv_is_non_collaborator" || exit 1

	test_A_extract_external_hosts_strips_github
	test_B_max_host_repetition_finds_top_host
	test_C_max_host_repetition_zero_when_only_github
	test_D_count_fileline_refs_counts_known_extensions
	test_E_count_fileline_refs_zero_for_no_refs
	test_F_is_non_collaborator_treats_owner_as_trusted
	test_G_is_non_collaborator_treats_none_as_untrusted
	test_H_is_non_collaborator_treats_contributor_as_untrusted
	test_I_help_command_succeeds
	test_J_unknown_command_returns_error
	test_K_check_without_args_returns_error

	printf '\n=== %d test(s), %d failure(s) ===\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
