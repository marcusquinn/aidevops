#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Dispatch-claim, permission-finish and _cmd_run_finish tests.
#
# Sourced by test-headless-runtime-completion-tests.sh (itself sourced by
# test-headless-runtime-harness.sh) after the shared test harness is initialized.

[[ -n "${_TEST_HEADLESS_RUNTIME_COMPLETION_TESTS_FINISH_LOADED:-}" ]] && return 0
_TEST_HEADLESS_RUNTIME_COMPLETION_TESTS_FINISH_LOADED=1

test_release_dispatch_claim_ignores_non_issue_session_key_digits() {
	local result status gh_called active_called unlock_called output
	result=$(
		unset WORKER_ISSUE_NUMBER 2>/dev/null || true
		DISPATCH_REPO_SLUG="owner/repo"
		WORKER_GITHUB_LOGIN="test-runner"
		gh_called=0
		active_called=0
		unlock_called=0
		gh() { gh_called=$((gh_called + 1)); return 0; }
		clear_active_status_on_release() { active_called=1; return 0; }
		_unlock_issue_after_dispatch_release() { unlock_called=1; return 0; }

		local release_output="" release_status=0
		release_output=$(_release_dispatch_claim "validation-gh3343-positive-review-20260705" "worker_complete" 0 1 2>&1) || release_status=$?
		printf '%s|%s|%s|%s|%s' "$release_status" "$gh_called" "$active_called" "$unlock_called" "$release_output"
	)
	IFS='|' read -r status gh_called active_called unlock_called output <<<"$result"

	if [[ "$status" -eq 0 && "$gh_called" -eq 0 && "$active_called" -eq 0 && "$unlock_called" -eq 0 && -z "$output" ]]; then
		print_result "release claim ignores non-issue session keys ending in digits" 0
		return 0
	fi

	print_result "release claim ignores non-issue session keys ending in digits" 1 \
		"status=$status gh=$gh_called active=$active_called unlock=$unlock_called output=${output:-<empty>}"
	return 0
}

test_session_terminal_reconciliation_preserves_null_issue_scope() {
	local result=""
	local args_file="${TEST_ROOT}/session-terminal-reconcile-args"
	(
		local fake_script_dir="${TEST_ROOT}/session-terminal-reconcile"
		mkdir -p "$fake_script_dir"
		: >"${fake_script_dir}/worker-blocker-log.mjs"
		SCRIPT_DIR="$fake_script_dir"
		DISPATCH_REPO_SLUG="owner/repo"
		unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG 2>/dev/null || true
		node() {
			local args=("$@")
			local arg=""
			for arg in "${args[@]}"; do printf '<%s>' "$arg"; done >"$args_file"
			return 0
		}
		_hrw_reconcile_session_permission_blockers "routine-r004" "success"
	)
	result=$(<"$args_file")
	if [[ "$result" == *"<resolve-session>"* && "$result" == *"<--repo-slug><owner/repo>"* && \
		"$result" == *"<--issue-number><>"* && "$result" == *"<--session-key><routine-r004>"* && \
		"$result" == *"<--reason><success>"* ]]; then
		print_result "session terminal reconciliation preserves null issue scope" 0
		return 0
	fi
	print_result "session terminal reconciliation preserves null issue scope" 1 "args=${result:-<empty>}"
	return 0
}

test_rate_limit_fast_reconciles_session_blockers() {
	local helper_file="${HELPER_SCRIPT%/*}/headless-runtime-attempt.sh"
	local callback_count=""
	local callback_pattern=''
	# shellcheck disable=SC2016 # Match the literal runtime variable reference.
	callback_pattern='_hrw_reconcile_session_permission_blockers "$session_key"'
	callback_count=$(grep -cF "$callback_pattern" "$helper_file" || true)
	if [[ "$callback_count" == "2" ]]; then
		print_result "rate-limit fast exit reconciles session blockers" 0
		return 0
	fi
	print_result "rate-limit fast exit reconciles session blockers" 1 "callback_count=${callback_count:-0}"
	return 0
}

test_cmd_run_finish_emits_noop_for_zero_output() {
	local work_dir="${TEST_ROOT}/repo-finish-noop"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	# Stub lifecycle functions to capture what was called
	local released_reason="" fast_fail_reason="" fast_fail_crash="" recorded_outcome=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_reason="$2"; fast_fail_crash="$3"; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	if [[ "$released_reason" == "worker_noop" ]]; then
		print_result "_cmd_run_finish emits worker_noop for zero-output exit" 0
	else
		print_result "_cmd_run_finish emits worker_noop for zero-output exit" 1 \
			"Expected released_reason=worker_noop, got '${released_reason}'"
	fi

	if [[ "$fast_fail_reason" == "worker_noop_zero_output" && "$fast_fail_crash" == "no_work" ]]; then
		print_result "_cmd_run_finish increments fast-fail on noop" 0
	else
		print_result "_cmd_run_finish increments fast-fail on noop" 1 \
			"Expected fast_fail reason=worker_noop_zero_output/crash=no_work, got '${fast_fail_reason}'/'${fast_fail_crash}'"
	fi
	if [[ "$recorded_outcome" == "failed" ]]; then
		print_result "_cmd_run_finish records failed telemetry for zero-output exit" 0
	else
		print_result "_cmd_run_finish records failed telemetry for zero-output exit" 1 \
			"Expected failed telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_preserves_terminal_blocked_outcome() {
	local work_dir="${TEST_ROOT}/repo-finish-blocked"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local released_reason="" fast_fail_called=0 recorded_outcome="" recorded_reason=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; recorded_reason="$3"; return 0; }

	local _run_result_label="blocked"
	local _run_failure_reason="blocked"
	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	if [[ "$released_reason" == "blocked" && "$fast_fail_called" -eq 0 &&
		"$recorded_outcome" == "deferred" && "$recorded_reason" == "blocked" ]]; then
		print_result "_cmd_run_finish preserves terminal BLOCKED without no_work accounting" 0
	else
		print_result "_cmd_run_finish preserves terminal BLOCKED without no_work accounting" 1 \
			"release=${released_reason:-<empty>} fast_fail=${fast_fail_called} outcome=${recorded_outcome:-<empty>} reason=${recorded_reason:-<empty>}"
	fi
	return 0
}

test_blocked_signal_accepts_labelled_outcome_lines() {
	local file="${TEST_ROOT}/blocked-labelled.jsonl" result=0 text
	# shellcheck disable=SC2016 # literal backticks are the fixture
	for text in 'Outcome: **BLOCKED**. dependency missing' 'Outcome: BLOCKED.' '**Status:** BLOCKED: x' 'Result: `BLOCKED`'; do
		jq -nc --arg t "$text" '{type:"text",part:{text:$t}}' >"$file"
		output_has_blocked_signal "$file" || result=1
	done
	for text in 'The upstream API was blocked earlier but I fixed it.' 'Outcome: unblocked now' 'Outcome: blocked earlier'; do
		jq -nc --arg t "$text" '{type:"text",part:{text:$t}}' >"$file"
		output_has_blocked_signal "$file" && result=1
	done
	if [[ "$result" -eq 0 ]]; then
		print_result "blocked signal accepts labelled Outcome/Status/Result lines only" 0
	else
		print_result "blocked signal accepts labelled Outcome/Status/Result lines only" 1 "labelled match mismatch"
	fi
	return 0
}

test_cmd_run_finish_emits_complete_for_real_output() {
	local work_dir="${TEST_ROOT}/repo-finish-complete"
	_setup_test_git_repo "$work_dir" 1
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local released_reason="" fast_fail_called=0 recorded_outcome=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_hrw_record_terminal_outcome() { recorded_outcome="$2"; return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete for real output" 0
	else
		print_result "_cmd_run_finish emits worker_complete for real output" 1 \
			"Expected released_reason=worker_complete, got '${released_reason}'"
	fi

	if [[ "$fast_fail_called" -eq 0 ]]; then
		print_result "_cmd_run_finish does NOT increment fast-fail for real output" 0
	else
		print_result "_cmd_run_finish does NOT increment fast-fail for real output" 1 \
			"fast-fail should not be called when worker produced real output"
	fi
	if [[ "$recorded_outcome" == "success" ]]; then
		print_result "_cmd_run_finish records success telemetry for real output" 0
	else
		print_result "_cmd_run_finish records success telemetry for real output" 1 \
			"Expected success telemetry, got '${recorded_outcome}'"
	fi
	return 0
}

test_cmd_run_finish_appends_reconciled_attempt_outcome() {
	local work_dir="${TEST_ROOT}/repo-finish-reconciled"
	local capture_file="${TEST_ROOT}/reconciled-outcome.capture"
	_setup_test_git_repo "$work_dir" 1

	(
		_run_result_label="premature_exit"
		_run_failure_reason="model_stopped_before_completion"
		_release_dispatch_claim() { return 0; }
		_report_failure_to_fast_fail() { return 0; }
		_update_dispatch_ledger() { return 0; }
		_release_session_lock() { return 0; }
		_hrw_record_terminal_outcome() { return 0; }
		_emit_worker_runtime_event() { return 0; }
		_hrw_record_reconciled_outcome() {
			local session_key="$1"
			local raw_result="$2"
			local outcome="$3"
			local status="$4"
			local classification="$5"
			printf '%s|%s|%s|%s|%s\n' "$session_key" "$raw_result" "$outcome" "$status" "$classification" >"$capture_file"
			return 0
		}
		_cmd_run_finish "issue-99999" "complete" "$work_dir"
	)

	local captured=""
	[[ -s "$capture_file" ]] && captured=$(<"$capture_file")
	if [[ "$captured" == "issue-99999|premature_exit|success|premature_exit|model_stopped_before_completion" ]]; then
		print_result "_cmd_run_finish appends the reconciled attempt outcome after final classification" 0
	else
		print_result "_cmd_run_finish appends the reconciled attempt outcome after final classification" 1 \
			"captured=${captured:-<empty>}"
	fi
	return 0
}

test_cmd_run_finish_rejects_unverified_post_pr_handoff() {
	local work_dir="${TEST_ROOT}/repo-finish-unverified-handoff"
	local capture_file="${TEST_ROOT}/unverified-handoff.capture"
	local release_file="${TEST_ROOT}/unverified-handoff.release"
	local ledger_file="${TEST_ROOT}/unverified-handoff.ledger"
	local result_file="${TEST_ROOT}/unverified-handoff.result"
	_setup_test_git_repo "$work_dir" 1

	(
		_run_result_label="post_pr_handoff"
		_run_failure_reason=""
		_release_dispatch_claim() { printf '%s' "$2" >"$release_file"; return 0; }
		_report_failure_to_fast_fail() { return 0; }
		_update_dispatch_ledger() { printf '%s' "$2" >"$ledger_file"; return 0; }
		_release_session_lock() { return 0; }
		_hrw_record_terminal_outcome() { return 0; }
		_emit_worker_runtime_event() { return 0; }
		_worker_post_pr_handoff_confirmed() { return 1; }
		# Fail-open classification is not durable PR evidence (GH#33115).
		_worker_produced_output() { printf 'pr_exists'; return 0; }
		_hrw_record_reconciled_outcome() {
			local session_key="$1"
			local raw_result="$2"
			local outcome="$3"
			local status="$4"
			local classification="$5"
			printf '%s|%s|%s|%s|%s\n' "$session_key" "$raw_result" "$outcome" "$status" "$classification" >"$capture_file"
			return 0
		}
		set +e
		_cmd_run_finish "issue-99999" "complete" "$work_dir"
		printf '%s' "$?" >"$result_file"
		set -e
	)

	local captured="" release_reason="" ledger_status="" finish_result=""
	[[ -s "$capture_file" ]] && captured=$(<"$capture_file")
	[[ -s "$release_file" ]] && release_reason=$(<"$release_file")
	[[ -s "$ledger_file" ]] && ledger_status=$(<"$ledger_file")
	[[ -s "$result_file" ]] && finish_result=$(<"$result_file")
	if [[ "$captured" == "issue-99999|post_pr_handoff|failed|failed|worker_post_pr_handoff_unverified" ]] &&
		[[ "$release_reason" == "worker_post_pr_handoff_unverified" && "$ledger_status" == "fail" && "$finish_result" == "1" ]]; then
		print_result "unverified POST_PR_HANDOFF cannot suppress failure routing" 0
	else
		print_result "unverified POST_PR_HANDOFF cannot suppress failure routing" 1 \
			"captured=${captured:-<empty>} release=${release_reason:-<empty>} ledger=${ledger_status:-<empty>} result=${finish_result:-<empty>}"
	fi
	return 0
}

test_cmd_run_finish_accepts_verified_post_pr_handoff() {
	local session_key="manual-cli-99999-1700000000"
	local work_dir="${TEST_ROOT}/repo-finish-verified-handoff"
	local capture_file="${TEST_ROOT}/verified-handoff.capture"
	local release_file="${TEST_ROOT}/verified-handoff.release"
	local ledger_file="${TEST_ROOT}/verified-handoff.ledger"
	local result_file="${TEST_ROOT}/verified-handoff.result"
	local fast_fail_file="${TEST_ROOT}/verified-handoff.fast-fail"
	_setup_test_git_repo "$work_dir" 1

	(
		local WORKER_ISSUE_NUMBER=99999 WORKER_REPO_SLUG="test-owner/test-repo"
		local DISPATCH_REPO_SLUG="test-owner/test-repo"
		local expected_head=""
		expected_head=$(git -C "$work_dir" rev-parse HEAD)
		_run_result_label="post_pr_handoff"
		_run_failure_reason=""
		_release_dispatch_claim() { printf '%s' "$2" >"$release_file"; return 0; }
		_report_failure_to_fast_fail() { : >"$fast_fail_file"; return 0; }
		_update_dispatch_ledger() { printf '%s' "$2" >"$ledger_file"; return 0; }
		_release_session_lock() { return 0; }
		_hrw_record_terminal_outcome() { return 0; }
		_emit_worker_runtime_event() { return 0; }
		# Exercise the production verifier and canonical classifier, not a success stub.
		gh_pr_list() {
			printf '[{"number":123,"state":"OPEN","isDraft":false,"headRefOid":"%s","labels":[{"name":"origin:worker"}]}]' "$expected_head"
			return 0
		}
		gh() {
			local fixture_request="$*"
			case "$fixture_request" in
			(*"api --paginate"*"/issues/123/comments"*) printf '%s' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]' ;;
			(*"api repos/"*"/pulls/123"*) printf '%s' 'Resolves #99999' ;;
			(*) return 1 ;;
			esac
			return 0
		}
		_worker_produced_output() { printf 'pr_exists'; return 0; }
		_hrw_record_reconciled_outcome() {
			local session_key="$1"
			local raw_result="$2"
			local outcome="$3"
			local status="$4"
			local classification="$5"
			printf '%s|%s|%s|%s|%s\n' "$session_key" "$raw_result" "$outcome" "$status" "$classification" >"$capture_file"
			return 0
		}
		set +e
		_cmd_run_finish "$session_key" "complete" "$work_dir"
		printf '%s' "$?" >"$result_file"
		set -e
	)

	local captured="" release_reason="" ledger_status="" finish_result=""
	[[ -s "$capture_file" ]] && captured=$(<"$capture_file")
	[[ -s "$release_file" ]] && release_reason=$(<"$release_file")
	[[ -s "$ledger_file" ]] && ledger_status=$(<"$ledger_file")
	[[ -s "$result_file" ]] && finish_result=$(<"$result_file")
	if [[ "$captured" == "${session_key}|post_pr_handoff|success|post_pr_handoff|" ]] &&
		[[ "$release_reason" == "worker_complete" && "$ledger_status" == "complete" && "$finish_result" == "0" ]] &&
		[[ ! -e "$fast_fail_file" ]]; then
		print_result "verified POST_PR_HANDOFF records success without failure escalation" 0
	else
		print_result "verified POST_PR_HANDOFF records success without failure escalation" 1 \
			"captured=${captured:-<empty>} release=${release_reason:-<empty>} ledger=${ledger_status:-<empty>} result=${finish_result:-<empty>}"
	fi
	return 0
}

test_permission_finish_failure_recovers_draft_and_runs_cleanup() {
	local result=""
	result=$(
		(
			_run_result_label="permission_required"
			_run_failure_reason=""
			local recovery_called=0 cleanup_called=0
			_hrw_finish_permission_required_run() {
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
				return 1
			}
			_worker_external_terminal_complete() { return 1; }
			_recover_worker_output_on_failure() {
				recovery_called=1
				_HRW_RECOVERY_CLASSIFICATION="$_HRW_REASON_DRAFT_CHECKPOINT"
				return 0
			}
			_report_failure_to_fast_fail() { return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() {
				local session_key="$1"
				local ledger_status="$2"
				cleanup_called=1
				printf "cleanup_ledger=%s\n" "$ledger_status"
				return 0
			}

			local status=0
			_cmd_run_finish "issue-99999" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf "status=%s|recovery=%s|cleanup=%s|terminal=%s|classification=%s|failure=%s\n" \
				"$status" "$recovery_called" "$cleanup_called" "$_HRW_FINAL_RUNTIME_STATUS" \
				"$_HRW_FINAL_RUNTIME_CLASSIFICATION" "$_run_failure_reason"
		)
	)
	if [[ "$result" == *"cleanup_ledger=fail"* && \
		"$result" == *"status=1|recovery=1|cleanup=1|terminal=escalated|classification=worker_draft_checkpoint|failure=permission_request_persistence_failed"* ]]; then
		print_result "permission persistence failure recovers draft and runs common cleanup" 0
	else
		print_result "permission persistence failure recovers draft and runs common cleanup" 1 "$result"
	fi
	return 0
}

test_permission_finish_failure_without_output_releases_and_cleans_up() {
	local result=""
	result=$(
		(
			_run_result_label="permission_required"
			_run_failure_reason=""
			local recovery_called=0 cleanup_called=0 released_reason="" fast_fail_reason=""
			_hrw_finish_permission_required_run() {
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
				return 1
			}
			_worker_external_terminal_complete() { return 1; }
			_recover_worker_output_on_failure() { recovery_called=1; return 1; }
			_release_dispatch_claim() {
				local session_key="$1"
				local reason="$2"
				released_reason="$reason"
				return 0
			}
			_report_failure_to_fast_fail() {
				local session_key="$1"
				local reason="$2"
				fast_fail_reason="$reason"
				return 0
			}
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() { cleanup_called=1; return 0; }

			local status=0
			_cmd_run_finish "issue-99999" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf "status=%s|recovery=%s|cleanup=%s|released=%s|fast_fail=%s|classification=%s\n" \
				"$status" "$recovery_called" "$cleanup_called" "$released_reason" "$fast_fail_reason" \
				"$_HRW_FINAL_RUNTIME_CLASSIFICATION"
		)
	)
	if [[ "$result" == "status=1|recovery=1|cleanup=1|released=worker_failed|fast_fail=permission_request_persistence_failed|classification=permission_request_persistence_failed" ]]; then
		print_result "permission persistence failure without output releases and cleans up" 0
	else
		print_result "permission persistence failure without output releases and cleans up" 1 "$result"
	fi
	return 0
}

test_null_issue_permission_failure_reconciles_terminal_blockers() {
	local result=""
	result=$(
		(
			unset WORKER_ISSUE_NUMBER 2>/dev/null || true
			_run_result_label="permission_required"
			_run_failure_reason=""
			local reconciled=0 reconcile_reason=""
			_hrw_finish_permission_required_run() {
				_hrw_mark_failed_terminal_state "$_HRW_STATUS_FAILED" "$_HRW_PERMISSION_PERSISTENCE_FAILED"
				return 1
			}
			_hrw_reconcile_session_permission_blockers() {
				local session_key="$1"
				local terminal_reason="$2"
				reconciled=$((reconciled + 1))
				reconcile_reason="${session_key}|${terminal_reason}"
				return 0
			}
			_worker_external_terminal_complete() { return 1; }
			_recover_worker_output_on_failure() { return 1; }
			_release_dispatch_claim() { return 0; }
			_report_failure_to_fast_fail() { return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() { return 0; }

			local status=0
			_cmd_run_finish "routine-r004" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf 'status=%s|reconciled=%s|reason=%s\n' "$status" "$reconciled" "$reconcile_reason"
		)
	)
	if [[ "$result" == "status=1|reconciled=1|reason=routine-r004|permission_request_persistence_failed" ]]; then
		print_result "null-issue permission failure reconciles terminal blockers" 0
	else
		print_result "null-issue permission failure reconciles terminal blockers" 1 "$result"
	fi
	return 0
}

test_issue_permission_handoff_skips_post_persistence_reconciliation() {
	local outcome_file="${TEST_ROOT}/permission-handoff.outcome"
	local result=""
	result=$(
		(
			WORKER_ISSUE_NUMBER="99999"
			export WORKER_ISSUE_NUMBER
			_run_result_label="permission_required"
			_WORKER_EXTERNAL_OUTCOME_FILE="$outcome_file"
			_WORKER_EXTERNAL_OUTCOME_ID="permission-handoff-outcome"
			_WORKER_EXTERNAL_OUTCOME_WRITTEN=0
			local reconciled=0
			_hrw_finish_permission_required_run() { return 0; }
			_hrw_reconcile_session_permission_blockers() { reconciled=$((reconciled + 1)); return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() { return 0; }

			local status=0
			_cmd_run_finish "issue-99999" "$_HRW_STATUS_PERMISSION_REQUIRED" "${TEST_ROOT}" || status=$?
			printf 'status=%s|reconciled=%s|reason=%s|retry=%s\n' "$status" "$reconciled" \
				"$(awk -F= '$1 == "reason" { print $2 }' "$outcome_file")" \
				"$(awk -F= '$1 == "retry_class" { print $2 }' "$outcome_file")"
		)
	)
	if [[ "$result" == "status=0|reconciled=0|reason=permission_required|retry=maintainer_gate" ]]; then
		print_result "issue permission handoff stays active after persistence" 0
	else
		print_result "issue permission handoff stays active after persistence" 1 "$result"
	fi
	return 0
}

test_post_merge_permission_uses_cleanup_receipt_without_blocking_issue() {
	local work_dir="${TEST_ROOT}/repo-post-merge-permission"
	local cleanup_dir="${TEST_ROOT}/post-merge-cleanup-receipts"
	local output_file="${TEST_ROOT}/post-merge-permission.output"
	local permission_file="${TEST_ROOT}/post-merge-permission.request"
	local handle_output_file="${TEST_ROOT}/post-merge-permission.handle-output"
	_setup_test_git_repo "$work_dir" 1
	local expected_head=""
	local resolved_work_dir=""
	expected_head=$(git -C "$work_dir" rev-parse HEAD)
	resolved_work_dir=$(cd "$work_dir" && pwd -P)
	printf '%s\n' '{"type":"text","sessionID":"ses_post_merge","text":"post-merge synchronization"}' >"$output_file"
	printf '%s\n' '{"type":"external_directory","request_id":"perm-post-merge"}' >"$permission_file"

	local result=""
	result=$(
		(
			export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="$cleanup_dir"
			export DISPATCH_REPO_SLUG="owner/repo"
			export WORKER_ISSUE_NUMBER="99999"
			_run_permission_request_file="$permission_file"
			full_loop_write_cleanup_deferred "owner/repo" 123 "$resolved_work_dir" \
				"feature/auto-test-issue-99999" "$$" "ses_post_merge" "pending" "FINALIZATION_PENDING" >/dev/null
			gh_pr_list() {
				printf '[{"number":123,"state":"MERGED","isDraft":false,"mergedAt":"2026-07-30T20:00:00Z","headRefOid":"%s","labels":[{"name":"origin:worker"}],"statusCheckRollup":[]}]\n' "$expected_head"
				return 0
			}
			gh() {
				if [[ "${*}" == *"issue view 99999"* ]]; then
					printf 'CLOSED\n'
				elif [[ "${*}" == *"api repos/owner/repo/pulls/123"* ]]; then
					printf '%s\n' 'Resolves #99999'
				elif [[ "${*}" == *"api --paginate"* && "${*}" == *"/issues/123/comments"* ]]; then
					printf '%s\n' '[[{"body":"<!-- MERGE_SUMMARY -->"}]]'
				elif [[ "${*}" == *"pr view 123"* ]]; then
					printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-30T20:00:00Z","mergeCommit":{"oid":"merge-123"}}'
				else
					return 1
				fi
				return 0
			}
			_store_headless_session_if_allowed() { return 0; }
			local permission_finish_called=0
			local success_finish_called=0
			local reconciled=0
			_hrw_finish_permission_required_run() { permission_finish_called=1; return 0; }
			_hrw_finish_success_run() {
				success_finish_called=1
				_HRW_TERMINAL_OUTCOME="$_HRW_TELEMETRY_SUCCESS"
				return 0
			}
			_hrw_reconcile_session_permission_blockers() { reconciled=$((reconciled + 1)); return 0; }
			_hrw_record_terminal_outcome() { return 0; }
			_emit_worker_runtime_event() { return 0; }
			_hrw_record_reconciled_outcome() { return 0; }
			_hrw_finish_cleanup() { return 0; }

			local handle_status=0
			local handle_output=""
			_handle_run_result 1 "$output_file" "worker" "openai" \
				"issue-99999" "openai/test" "$work_dir" >"$handle_output_file" 2>&1 || handle_status=$?
			handle_output=$(<"$handle_output_file")
			if [[ "$handle_status" -ne 84 ]]; then
				_hrw_reconcile_session_permission_blockers "issue-99999" "$_run_result_label"
				rm -f "$permission_file"
			fi
			_cmd_run_finish "issue-99999" "complete" "$work_dir"
			local receipt_state=""
			receipt_state=$(jq -r '.resource_cleanup_state' "${cleanup_dir}/owner_repo-123.json")
			printf 'handle=%s|result=%s|permission=%s|success=%s|reconciled=%s|request=%s|receipt=%s|diagnostic=%s\n' \
				"$handle_status" "$_run_result_label" "$permission_finish_called" "$success_finish_called" \
				"$reconciled" "$([[ -e "$permission_file" ]] && printf present || printf cleared)" \
				"$receipt_state" "$([[ "$handle_output" == *"cleanup_authority=guarded-supervisor"* ]] && printf present || printf missing)"
		)
	)
	if [[ "$result" == "handle=0|result=post_merge_cleanup_deferred|permission=0|success=1|reconciled=1|request=cleared|receipt=CLEANUP_DEFERRED|diagnostic=present" ]]; then
		print_result "post-merge permission retains cleanup ownership without blocking implementation" 0
	else
		print_result "post-merge permission retains cleanup ownership without blocking implementation" 1 "$result"
	fi
	return 0
}

test_pre_merge_permission_remains_blocking() {
	local work_dir="${TEST_ROOT}/repo-pre-merge-permission"
	local output_file="${TEST_ROOT}/pre-merge-permission.output"
	local permission_file="${TEST_ROOT}/pre-merge-permission.request"
	_setup_test_git_repo "$work_dir" 1
	printf '%s\n' '{"type":"text","sessionID":"ses_pre_merge","text":"implementation in progress"}' >"$output_file"
	printf '%s\n' '{"type":"external_directory","request_id":"perm-pre-merge"}' >"$permission_file"

	local result=""
	result=$(
		(
			export DISPATCH_REPO_SLUG="owner/repo"
			export WORKER_ISSUE_NUMBER="99999"
			_run_permission_request_file="$permission_file"
			gh() {
				if [[ "${*}" == *"issue view 99999"* ]]; then
					printf 'OPEN\n'
					return 0
				fi
				return 1
			}
			_store_headless_session_if_allowed() { return 0; }
			local status=0
			_handle_run_result 1 "$output_file" "worker" "openai" \
				"issue-99999" "openai/test" "$work_dir" >/dev/null 2>&1 || status=$?
			printf 'status=%s|result=%s|request=%s\n' "$status" "$_run_result_label" \
				"$([[ -e "$permission_file" ]] && printf present || printf missing)"
		)
	)
	if [[ "$result" == "status=84|result=permission_required|request=present" ]]; then
		print_result "pre-merge permission remains blocking" 0
	else
		print_result "pre-merge permission remains blocking" 1 "$result"
	fi
	return 0
}
