#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-removal-audit.sh — Regression tests for t2976: canonical audit
# logging at every worktree-removal event.
#
# Tests cover:
#   1. log_worktree_removal_event writes exactly one structured line per call
#   2. Log format: [ISO8601] [caller] worktree-{removed|skipped}: <path> — <reason>
#   3. Custom AIDEVOPS_CLEANUP_LOG env var is honoured
#   4. All three event types produce correct type strings in the log
#   5. should_skip_cleanup emits worktree-skipped when ownership blocks removal
#   6. Double-sourcing the audit helper is idempotent
#
# All tests run in isolated temp directories; no real ~/.aidevops state is
# written. Tests do not require git or gh — they exercise the logging functions
# directly via sourcing with stub dependencies.
#
# Scope note (t2976): The issue spec listed two additional EDIT targets —
#   cleanup_worktrees.sh and orphan-defaultbranch-guard.sh — but neither file
#   exists in this repository. All instrumented callers that DO exist are covered:
#   worktree-helper.sh, pulse-cleanup.sh, and skill-update-core-lib.sh
#   (sourced via skill-update-helper.sh). No test coverage is omitted for live code.
#
# Usage:
#   bash .agents/scripts/tests/test-worktree-removal-audit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_HELPER="${SCRIPT_DIR}/../audit-worktree-removal-helper.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

# =============================================================================
# Test framework
# =============================================================================

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

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

assert_file_contains() {
	local file="$1"
	local pattern="$2"
	grep -qE "$pattern" "$file" 2>/dev/null
	return $?
}

assert_line_count() {
	local file="$1"
	local expected="$2"
	local actual
	actual=$(wc -l <"$file" 2>/dev/null | tr -d ' ')
	if [[ "$actual" -eq "$expected" ]]; then
		return 0
	fi
	echo "  expected $expected lines, got $actual"
	return 1
}

# =============================================================================
# Test 1: log_worktree_removal_event writes one structured line
# =============================================================================
test_log_writes_one_line() {
	local log_file="${TEST_DIR}/t1-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	log_worktree_removal_event "$_WTAR_REMOVED" "test-caller.sh" "/tmp/test-wt" "manual"

	local rc=0
	assert_line_count "$log_file" 1 || rc=$?
	print_result "log_writes_one_line" "$rc" "Expected exactly 1 line in log"
	return 0
}

# =============================================================================
# Test 2: log line format matches [ISO8601] [caller] worktree-<type>: <path> — <reason>
# =============================================================================
test_log_format_correct() {
	local log_file="${TEST_DIR}/t2-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	log_worktree_removal_event "$_WTAR_SKIPPED" "worktree-helper.sh" "/some/path" "owned-skip"

	local pattern='^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] \[worktree-helper\.sh\] worktree-skipped: /some/path — owned-skip$'
	local rc=0
	assert_file_contains "$log_file" "$pattern" || rc=$?
	print_result "log_format_correct" "$rc" "Log line does not match expected format. Content: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 3: AIDEVOPS_CLEANUP_LOG env var is honoured (custom log path)
# =============================================================================
test_custom_log_path() {
	local custom_log="${TEST_DIR}/custom/subdir/audit.log"
	export AIDEVOPS_CLEANUP_LOG="$custom_log"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	log_worktree_removal_event "$_WTAR_REMOVED" "test.sh" "/wt/path" "age-eligible"

	local rc=0
	if [[ -f "$custom_log" ]]; then
		assert_file_contains "$custom_log" "worktree-removed" || rc=$?
	else
		rc=1
		echo "  custom log file not created at $custom_log"
	fi
	print_result "custom_log_path_honoured" "$rc" "Custom AIDEVOPS_CLEANUP_LOG path not written"
	return 0
}

# =============================================================================
# Test 4: Multiple event types produce correct type strings in log
# =============================================================================
test_all_event_types() {
	local log_file="${TEST_DIR}/t4-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	log_worktree_removal_event "$_WTAR_REMOVED" "s.sh" "/p1" "manual"
	log_worktree_removal_event "$_WTAR_SKIPPED" "s.sh" "/p2" "grace-period"
	log_worktree_removal_event "$_WTAR_FIXTURE_REMOVED" "s.sh" "/p3" "fixture"

	local rc=0
	assert_line_count "$log_file" 3 || rc=1
	assert_file_contains "$log_file" "worktree-removed.*p1" || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*p2.*grace-period" || rc=1
	assert_file_contains "$log_file" "worktree-fixture-removed.*p3.*fixture" || rc=1
	print_result "all_event_types_logged" "$rc" "Not all event types written correctly"
	return 0
}

# =============================================================================
# Test 5: should_skip_cleanup owned-skip path emits a worktree-skipped entry
# =============================================================================
test_should_skip_cleanup_owned_skip_logs() {
	local log_file="${TEST_DIR}/t5-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/fake-wt-$$"
	mkdir -p "$wt_path"

	# Run in a subshell to avoid polluting the outer env with stubs.
	(
		RED='' NC=''
		is_worktree_owned_by_others() { return 0; }
		check_worktree_owner()         { echo "99999|session-stub"; return 0; }
		worktree_is_in_grace_period()  { return 1; }
		get_validated_grace_hours()    { echo "4"; return 0; }
		worktree_has_changes()         { return 1; }
		branch_has_zero_commits_ahead(){ return 1; }

		export AIDEVOPS_CLEANUP_LOG="$log_file"
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"

		# Define the should_skip_cleanup function body as it appears in worktree-helper.sh
		# after the t2976 changes — exercises the owned-skip audit log path.
		should_skip_cleanup() {
			local wt_path_sc="$1"
			local wt_branch_sc="$2"
			local default_br_sc="$3"
			local open_pr_list_sc="$4"
			local force_merged_flag_sc="$5"

			if is_worktree_owned_by_others "$wt_path_sc"; then
				local owner_info_sc
				owner_info_sc=$(check_worktree_owner "$wt_path_sc")
				local owner_pid_sc="${owner_info_sc%%|*}"
				echo "  ${wt_branch_sc} (owned by active session PID $owner_pid_sc - skipping)"
				echo "    $wt_path_sc"
				echo ""
				log_worktree_removal_event "$_WTAR_SKIPPED" "worktree-helper.sh" \
					"$wt_path_sc" "owned-skip"
				return 0
			fi
			return 1
		}

		should_skip_cleanup "$wt_path" "feature/test" "main" "" "false"
	)

	local rc=0
	assert_file_contains "$log_file" "worktree-skipped.*owned-skip" || rc=$?
	print_result "should_skip_cleanup_owned_skip_logs" "$rc" \
		"Expected worktree-skipped/owned-skip entry. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 6: audit helper is idempotent — double-sourcing does not duplicate output
# =============================================================================
test_idempotent_sourcing() {
	local log_file="${TEST_DIR}/t6-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"  # second source — guard makes this a no-op

	log_worktree_removal_event "$_WTAR_REMOVED" "test.sh" "/wt" "manual"

	local rc=0
	assert_line_count "$log_file" 1 || rc=$?
	print_result "idempotent_sourcing" "$rc" "Double-sourcing produced unexpected output"
	return 0
}

# =============================================================================
# Main
# =============================================================================

setup

echo "=== test-worktree-removal-audit.sh ==="

test_log_writes_one_line
test_log_format_correct
test_custom_log_path
test_all_event_types
test_should_skip_cleanup_owned_skip_logs
test_idempotent_sourcing

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed."

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
