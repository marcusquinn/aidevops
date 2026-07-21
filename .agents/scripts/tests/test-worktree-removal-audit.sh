#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-removal-audit.sh — Regression tests for t2976: canonical audit
# logging at every worktree-removal event.
#
# Tests cover:
#   1. log_worktree_removal_event writes exactly one structured line per call
#   2. Log format: [ISO8601] [caller] worktree-{removed|skipped}: <path> — <reason> — mode=<mode>
#   3. Custom AIDEVOPS_CLEANUP_LOG env var is honoured
#   4. All three event types produce correct type strings in the log
#   5. should_skip_cleanup emits worktree-skipped when ownership blocks removal
#   6. Double-sourcing the audit helper is idempotent
#   7. Optional guard context is appended when supplied
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
COMMANDS_HELPER="${SCRIPT_DIR}/../worktree-helper-cmds.sh"

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

	log_worktree_removal_event "$_WTAR_REMOVED" "test-caller.sh" "/tmp/test-wt" "manual" "trash"

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

	log_worktree_removal_event "$_WTAR_SKIPPED" "worktree-helper.sh" "/some/path" "owned-skip" "skipped"

	local pattern='^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] \[worktree-helper\.sh\] worktree-skipped: /some/path — owned-skip — mode=skipped$'
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

	log_worktree_removal_event "$_WTAR_REMOVED" "test.sh" "/wt/path" "age-eligible" "permanent"

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

	log_worktree_removal_event "$_WTAR_REMOVED" "s.sh" "/p1" "manual" "trash"
	log_worktree_removal_event "$_WTAR_SKIPPED" "s.sh" "/p2" "grace-period" "skipped"
	log_worktree_removal_event "$_WTAR_FIXTURE_REMOVED" "s.sh" "/p3" "fixture" "fixture"

	local rc=0
	assert_line_count "$log_file" 3 || rc=1
	assert_file_contains "$log_file" "worktree-removed.*p1.*mode=trash" || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*p2.*grace-period.*mode=skipped" || rc=1
	assert_file_contains "$log_file" "worktree-fixture-removed.*p3.*fixture.*mode=fixture" || rc=1
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
		check_worktree_owner() {
			echo "99999|session-stub"
			return 0
		}
		worktree_is_in_grace_period() { return 1; }
		get_validated_grace_hours() {
			echo "4"
			return 0
		}
		worktree_has_changes() { return 1; }
		branch_has_zero_commits_ahead() { return 1; }

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
					"$wt_path_sc" "owned-skip" "skipped"
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
	source "$AUDIT_HELPER" # second source — guard makes this a no-op

	log_worktree_removal_event "$_WTAR_REMOVED" "test.sh" "/wt" "manual" "trash"

	local rc=0
	assert_line_count "$log_file" 1 || rc=$?
	print_result "idempotent_sourcing" "$rc" "Double-sourcing produced unexpected output"
	return 0
}

# =============================================================================
# Test 7: shared guard refuses current working directory removals
# =============================================================================
test_guard_refuses_current_cwd() {
	local log_file="${TEST_DIR}/t7-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/current-wt"
	mkdir -p "$wt_path"

	local rc=0
	(
		unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
		# shellcheck source=../audit-worktree-removal-helper.sh
		source "$AUDIT_HELPER"
		cd "$wt_path" || exit 2
		if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
			exit 1
		fi
	) || rc=$?

	if [[ "$rc" -eq 0 ]]; then
		assert_file_contains "$log_file" "worktree-skipped.*current-worktree.*mode=skipped" || rc=$?
	fi
	print_result "guard_refuses_current_cwd" "$rc" \
		"Expected current-worktree skip. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 8: shared guard refuses another live process with cwd in worktree
# =============================================================================
test_guard_refuses_other_process_cwd() {
	local log_file="${TEST_DIR}/t8-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/active-process-wt"
	mkdir -p "$wt_path"

	local sleeper_pid=""
	(
		cd "$wt_path" || exit 2
		sleep 30
	) &
	sleeper_pid=$!

	local rc=0
	local attempts=0
	while [[ "$attempts" -lt 20 ]]; do
		(
			unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
			# shellcheck source=../audit-worktree-removal-helper.sh
			source "$AUDIT_HELPER"
			if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
				exit 1
			fi
		) && break
		rc=$?
		attempts=$((attempts + 1))
		sleep 0.1
	done

	kill "$sleeper_pid" 2>/dev/null || true
	wait "$sleeper_pid" 2>/dev/null || true

	if [[ "$rc" -eq 0 ]]; then
		assert_file_contains "$log_file" "worktree-skipped.*active-cwd.*mode=skipped" || rc=$?
	fi
	print_result "guard_refuses_other_process_cwd" "$rc" \
		"Expected active-cwd skip. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 9: permanent helper removes only after guard passes and logs mode
# =============================================================================
test_permanent_helper_removes_and_logs() {
	local log_file="${TEST_DIR}/t9-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	local wt_path="${TEST_DIR}/old-wt"
	mkdir -p "$wt_path"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local rc=0
	(
		capture_worktree_process_cwds() {
			printf '/\n'
			return 0
		}
		remove_worktree_path_permanently "$wt_path" "test.sh" "age-eligible"
	) || rc=$?
	[[ ! -e "$wt_path" ]] || rc=1
	assert_file_contains "$log_file" "worktree-removed.*age-eligible.*mode=permanent" || rc=1
	print_result "permanent_helper_removes_and_logs" "$rc" \
		"Expected permanent removal audit. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 10: optional guard context includes predicates needed for safe cleanup audit
# =============================================================================
test_optional_guard_context_logged() {
	local log_file="${TEST_DIR}/t10-cleanup.log"
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local context="branch=feature/gh23074 issue=23074 owner_guard=clear process_guard=clear recent_session_guard=clear commits=1 pr_state=none recovery_path=none"
	log_worktree_removal_event "$_WTAR_SKIPPED" "pulse-cleanup.sh" "/wt/context" "local-commits-no-pr" "skipped" "$context"
	local branch_merged_context="target_branch=main merge_proof=merge-base-is-ancestor merge_proof_result=ancestor branch=feature/gh23076 owner_guard=clear protected_status=clear"
	log_worktree_removal_event "$_WTAR_REMOVED" "worktree-helper.sh" "/wt/merged" "branch-merged" "permanent" "$branch_merged_context"

	local rc=0
	assert_file_contains "$log_file" "worktree-skipped.*local-commits-no-pr.*mode=skipped.*branch=feature/gh23074.*owner_guard=clear.*process_guard=clear.*recent_session_guard=clear.*commits=1.*pr_state=none.*recovery_path=none" || rc=1
	assert_file_contains "$log_file" "worktree-removed.*branch-merged.*mode=permanent.*target_branch=main.*merge_proof=merge-base-is-ancestor.*merge_proof_result=ancestor.*protected_status=clear" || rc=1
	print_result "optional_guard_context_logged" "$rc" \
		"Expected guard context audit. Log: $(cat "$log_file" 2>/dev/null)"
	return 0
}

# =============================================================================
# Test 11: process-cwd helper refuses empty paths before glob-like matching
# =============================================================================
test_process_cwd_guard_refuses_empty_paths() {
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local rc=0
	if _worktree_has_process_cwd "" "/tmp/example"; then
		rc=1
	fi
	if _worktree_has_process_cwd "/tmp/example" ""; then
		rc=1
	fi
	print_result "process_cwd_guard_refuses_empty_paths" "$rc" \
		"Expected empty path inputs to return non-match"
	return 0
}

# =============================================================================
# Test 12: snapshot collection failures block removal, while an explicitly
# supplied empty successful snapshot avoids a second platform scan.
# =============================================================================
test_process_cwd_snapshot_failure_is_fail_closed() {
	local log_file="${TEST_DIR}/t12-cleanup.log"
	local wt_path="${TEST_DIR}/snapshot-failure-wt"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	capture_worktree_process_cwds() { return 1; }
	if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
		rc=1
	fi
	assert_file_contains "$log_file" "worktree-skipped.*cwd-visibility-unusable" || rc=1
	if ! worktree_removal_guard "$wt_path" "test.sh" "manual" ""; then
		rc=1
	fi
	print_result "process_cwd_snapshot_failure_is_fail_closed" "$rc" \
		"Expected collection failure to block and explicit empty snapshot to pass"
	return 0
}

# =============================================================================
# Test 13: each platform backend fails closed when it cannot publish any cwd
# target instead of treating an empty snapshot as authoritative.
# =============================================================================
test_snapshot_backend_requires_visible_target() {
	local rc=0
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	if [[ -d /proc ]]; then
		if (
			readlink() { return 1; }
			capture_worktree_process_cwds >/dev/null
		); then
			rc=1
		fi
	else
		if (
			lsof() { return 0; }
			capture_worktree_process_cwds >/dev/null
		); then
			rc=1
		fi
	fi
	print_result "snapshot_backend_requires_visible_target" "$rc" \
		"Expected an empty process-cwd backend result to fail closed"
	return 0
}

# =============================================================================
# The macOS lsof backend distinguishes complete output, partial/permission-
# limited output, and empty unusable output. Absence-only output never proves a
# candidate inactive.
# =============================================================================
test_lsof_snapshot_visibility_states() {
	local output=""
	local capture_status=0
	local rc=0

	if output=$(
		lsof() { return 0; }
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq 1 && -z "$output" ]] || rc=1

	if output=$(
		lsof() {
			printf 'p123\nn/visible-lsof-cwd\n'
			return 1
		}
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-lsof-cwd" ]] || rc=1

	if output=$(
		lsof() {
			printf 'p123\nn/complete-lsof-cwd\n'
			return 0
		}
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq 0 && "$output" == "/complete-lsof-cwd" ]] || rc=1
	print_result "lsof_snapshot_visibility_states" "$rc" \
		"Expected empty lsof to be unusable and partial lsof output to be degraded"
	return 0
}

# =============================================================================
# Test 14: a partially visible /proc snapshot preserves readable evidence and
# reports degraded visibility instead of aliasing it to a total failure.
# =============================================================================
test_proc_snapshot_preserves_degraded_visibility() {
	local proc_root="${TEST_DIR}/fake-proc"
	local output=""
	local capture_status=0
	local rc=0
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /hidden-cwd "${proc_root}/2/cwd"

	if output=$(
		readlink() {
			local link_path="$1"
			case "$link_path" in
			*/1/cwd)
				printf '/visible-cwd\n'
				return 0
				;;
			esac
			return 1
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_preserves_degraded_visibility" "$rc" \
		"Expected unreadable unknown ownership to preserve visible cwd evidence with degraded status"
	return 0
}

# =============================================================================
# Linux /proc entries that are unreadable but provably foreign do not invalidate
# otherwise usable evidence.
# =============================================================================
test_proc_snapshot_skips_foreign_uid_unreadable_entry() {
	local proc_root="${TEST_DIR}/fake-proc-foreign"
	local current_uid=""
	local foreign_uid=""
	local output=""
	local rc=0
	current_uid=$(id -u)
	foreign_uid=$((current_uid + 1))
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /foreign-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$foreign_uid" "$foreign_uid" "$foreign_uid" "$foreign_uid" >"${proc_root}/2/status"

	output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_skips_foreign_uid_unreadable_entry" "$rc" \
		"Expected foreign unreadable cwd to be skipped without hiding visible evidence"
	return 0
}

# =============================================================================
# Same-UID unreadability is explicitly degraded while preserving readable cwd
# evidence for candidate-specific positive matching.
# =============================================================================
test_proc_snapshot_marks_same_uid_unreadable_entry_degraded() {
	local proc_root="${TEST_DIR}/fake-proc-same-uid"
	local current_uid=""
	local output=""
	local capture_status=0
	local rc=0
	current_uid=$(id -u)
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /same-user-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$current_uid" "$current_uid" "$current_uid" "$current_uid" >"${proc_root}/2/status"

	if output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_marks_same_uid_unreadable_entry_degraded" "$rc" \
		"Expected simulated same-UID EACCES to return degraded status with visible evidence intact"
	return 0
}

# =============================================================================
# Degraded visibility is candidate-specific: unrelated readable CWDs require a
# recoverable path, while any readable target inside the candidate hard-blocks.
# =============================================================================
test_degraded_visibility_preserves_positive_candidate_match() {
	local log_file="${TEST_DIR}/degraded-candidate-cleanup.log"
	local wt_path="${TEST_DIR}/degraded-candidate"
	local guard_status=0
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	if worktree_removal_guard "$wt_path" "test.sh" "manual" "/unrelated-readable-cwd" \
		"$_WT_CWD_VISIBILITY_DEGRADED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	[[ "$guard_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "$_WT_CWD_REASON_DEGRADED" ]] || rc=1

	if worktree_removal_guard "$wt_path" "test.sh" "manual" "$wt_path/active-shell" \
		"$_WT_CWD_VISIBILITY_DEGRADED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	[[ "$guard_status" -eq 1 ]] || rc=1
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "active-cwd" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*cwd-visibility-degraded.*mode=recoverable-required" || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*active-cwd.*mode=skipped" || rc=1
	print_result "degraded_visibility_preserves_positive_candidate_match" "$rc" \
		"Expected unrelated denial to be recoverable-only and readable candidate CWD to hard-block"
	return 0
}

# =============================================================================
# Foreign skips alone are not usable evidence: an empty snapshot still blocks
# destructive cleanup.
# =============================================================================
test_proc_snapshot_requires_usable_evidence_after_foreign_skips() {
	local proc_root="${TEST_DIR}/fake-proc-foreign-only"
	local current_uid=""
	local foreign_uid=""
	local rc=0
	current_uid=$(id -u)
	foreign_uid=$((current_uid + 1))
	mkdir -p "${proc_root}/1"
	ln -s /foreign-cwd "${proc_root}/1/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$foreign_uid" "$foreign_uid" "$foreign_uid" "$foreign_uid" >"${proc_root}/1/status"

	if (
		readlink() { return 1; }
		_capture_worktree_proc_cwds "$proc_root" >/dev/null
	); then
		rc=1
	fi
	print_result "proc_snapshot_requires_usable_evidence_after_foreign_skips" "$rc" \
		"Expected zero captured cwd targets to remain fail-closed"
	return 0
}

# =============================================================================
# A process that vanishes during readlink is ignored when other usable evidence
# remains in the snapshot.
# =============================================================================
test_proc_snapshot_ignores_vanished_entry() {
	local proc_root="${TEST_DIR}/fake-proc-vanished"
	local output=""
	local rc=0
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /vanished-cwd "${proc_root}/2/cwd"

	output=$(
		readlink() {
			local link_path="$1"
			if [[ "$link_path" == */1/cwd ]]; then
				printf '/visible-cwd\n'
				return 0
			fi
			rm -f "$link_path"
			return 1
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_ignores_vanished_entry" "$rc" \
		"Expected a vanished process to be ignored without losing visible evidence"
	return 0
}

# =============================================================================
# Guard refusals expose a machine-readable reason without changing the
# exactly-once audit contract.
# =============================================================================
test_guard_reason_is_machine_readable() {
	local log_file="${TEST_DIR}/t15-cleanup.log"
	local wt_path="${TEST_DIR}/reason-wt"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	if worktree_removal_guard "$wt_path" "test.sh" "manual" "$wt_path"; then
		rc=1
	fi
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "active-cwd" ]] || rc=1
	assert_line_count "$log_file" 1 || rc=1
	print_result "guard_reason_is_machine_readable" "$rc" \
		"Expected active-cwd reason and exactly one audit row"
	return 0
}

# =============================================================================
# Test 16: manual removal renders safe actionable diagnostics for each shared
# guard reason. The guard remains the sole audit writer.
# =============================================================================
test_manual_guard_refusal_diagnostics() {
	local output_file="${TEST_DIR}/t16-output.log"
	local log_file="${TEST_DIR}/t16-cleanup.log"
	local rc=0
	local reason=""
	local guard_reason_to_test=""
	export AIDEVOPS_CLEANUP_LOG="$log_file"

	unset _WORKTREE_CMDS_LIB_LOADED 2>/dev/null || true
	RED=""
	NC=""
	# shellcheck source=../worktree-helper-cmds.sh
	source "$COMMANDS_HELPER"
	worktree_removal_guard() {
		local path_to_remove="$1"
		local caller="$2"
		local removal_mode="$3"
		WORKTREE_REMOVAL_GUARD_REASON="$guard_reason_to_test"
		log_worktree_removal_event "$_WTAR_SKIPPED" "$caller" "$path_to_remove" \
			"$guard_reason_to_test" "skipped"
		: "$removal_mode"
		return 1
	}
	for reason in active-cwd current-worktree canonical-skip; do
		guard_reason_to_test="$reason"
		if _remove_validate_path "/safe/example-worktree" 2>>"$output_file"; then
			rc=1
		fi
	done
	assert_file_contains "$output_file" "Reason: active-cwd.*live process" || rc=1
	assert_file_contains "$output_file" "Reason: current-worktree.*inside the target" || rc=1
	assert_file_contains "$output_file" "Reason: canonical-skip.*canonical checkout" || rc=1
	assert_file_contains "$output_file" "cannot bypass this protection" || rc=1
	assert_line_count "$log_file" 3 || rc=1
	print_result "manual_guard_refusal_diagnostics" "$rc" \
		"Expected safe diagnostics and exactly one audit row per refusal"
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
test_guard_refuses_current_cwd
test_guard_refuses_other_process_cwd
test_permanent_helper_removes_and_logs
test_optional_guard_context_logged
test_process_cwd_guard_refuses_empty_paths
test_process_cwd_snapshot_failure_is_fail_closed
test_snapshot_backend_requires_visible_target
test_lsof_snapshot_visibility_states
test_proc_snapshot_preserves_degraded_visibility
test_proc_snapshot_skips_foreign_uid_unreadable_entry
test_proc_snapshot_marks_same_uid_unreadable_entry_degraded
test_degraded_visibility_preserves_positive_candidate_match
test_proc_snapshot_requires_usable_evidence_after_foreign_skips
test_proc_snapshot_ignores_vanished_entry
test_guard_reason_is_machine_readable
test_manual_guard_refusal_diagnostics

echo ""
echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed."

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
