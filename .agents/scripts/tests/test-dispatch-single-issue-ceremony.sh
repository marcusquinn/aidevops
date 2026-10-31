#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Dispatch ceremony and CLI argument tests. Sourced by the main test runner;
# relies on its helper imports, mocks, reset_test_state and print_result.
# shellcheck disable=SC2016

[[ -n "${_TEST_DSI_CEREMONY_LOADED:-}" ]] && return 0
_TEST_DSI_CEREMONY_LOADED=1

test_ceremony_applies_default() {
	reset_test_state
	_install_mock_set_issue_status success
	_install_mock_set_origin_label success

	# Issue meta with one prior assignee that ceremony should remove.
	local issue_meta='{"assignees":[{"login":"prior-author"}]}'
	local rc=0
	_dsi_apply_dispatch_ceremony 12345 owner/repo runner-self "$issue_meta" >/dev/null 2>&1 || rc=$?

	local status_logged
	status_logged=$(cat "$SET_ISSUE_STATUS_LOG")

	# Assert ceremony returned success
	if [[ "$rc" -ne 0 ]]; then
		print_result "ceremony returns 0 on success" 1 "got rc=$rc"
		return 0
	fi
	print_result "ceremony returns 0 on success" 0

	# Assert exactly one set_issue_status call recorded.
	# t2763: the unsafe grep-c-then-fallback idiom stacks two zeros on the
	# zero-match path. Use the inline guard pattern instead (see counter-stack-check).
	local call_count
	call_count=$(grep -c '^set_issue_status' "$SET_ISSUE_STATUS_LOG" 2>/dev/null || true)
	[[ "$call_count" =~ ^[0-9]+$ ]] || call_count=0
	if [[ "$call_count" -ne 1 ]]; then
		print_result "ceremony emits exactly one set_issue_status call" 1 "got $call_count calls"
		return 0
	fi
	print_result "ceremony emits exactly one set_issue_status call" 0

	# Assert status:queued positional
	local status_check=1
	[[ "$status_logged" == *"set_issue_status 12345 owner/repo queued"* ]] && status_check=0
	print_result "ceremony passes status:queued (not in-progress)" "$status_check" \
		"expected 'set_issue_status 12345 owner/repo queued' in: $status_logged"

	# Origin labels are creation provenance and must not be rewritten by worker
	# claim ceremony.
	local origin_call_count
	origin_call_count=$(grep -c '^set_origin_label' "$SET_ORIGIN_LABEL_LOG" 2>/dev/null || true)
	[[ "$origin_call_count" =~ ^[0-9]+$ ]] || origin_call_count=0
	if [[ "$origin_call_count" -ne 0 ]]; then
		print_result "ceremony preserves origin provenance" 1 "got $origin_call_count set_origin_label calls"
		return 0
	fi
	print_result "ceremony preserves origin provenance" 0

	# Assert origin:worker NOT embedded in set_issue_status flags (t3007 regression guard)
	local no_bare_add=0 no_bare_rm_int=0 no_bare_rm_take=0
	[[ "$status_logged" == *"--add-label origin:worker"* ]] && no_bare_add=1
	[[ "$status_logged" == *"--remove-label origin:interactive"* ]] && no_bare_rm_int=1
	[[ "$status_logged" == *"--remove-label origin:worker-takeover"* ]] && no_bare_rm_take=1
	print_result "origin:worker not embedded in set_issue_status" "$no_bare_add" \
		"bare --add-label origin:worker found in set_issue_status call"
	print_result "origin:interactive removal not in set_issue_status (t3007)" "$no_bare_rm_int" \
		"bare --remove-label origin:interactive found"
	print_result "origin:worker-takeover removal not in set_issue_status (t3007)" "$no_bare_rm_take" \
		"bare --remove-label origin:worker-takeover found"

	# Assert assignee normalization still in set_issue_status
	local add_assignee=1 rm_prior=1
	[[ "$status_logged" == *"--add-assignee runner-self"* ]] && add_assignee=0
	[[ "$status_logged" == *"--remove-assignee prior-author"* ]] && rm_prior=0
	print_result "ceremony adds runner-self as assignee" "$add_assignee"
	print_result "ceremony removes prior assignee" "$rm_prior"

	return 0
}

test_ceremony_skip_when_self_assigned() {
	reset_test_state
	_install_mock_set_issue_status success
	_install_mock_set_origin_label success

	# When the only existing assignee IS runner-self, no --remove-assignee
	# should be emitted (don't unassign yourself).
	local issue_meta='{"assignees":[{"login":"runner-self"}]}'
	_dsi_apply_dispatch_ceremony 99 owner/repo runner-self "$issue_meta" >/dev/null 2>&1

	local logged
	logged=$(cat "$SET_ISSUE_STATUS_LOG")

	local no_self_remove=0
	if [[ "$logged" == *"--remove-assignee runner-self"* ]]; then
		no_self_remove=1
	fi
	print_result "ceremony does not remove runner-self from assignees" "$no_self_remove"

	# But still adds runner-self via --add-assignee (idempotent in gh).
	local still_adds=1
	[[ "$logged" == *"--add-assignee runner-self"* ]] && still_adds=0
	print_result "ceremony still adds runner-self (idempotent re-assert)" "$still_adds"

	return 0
}

test_ceremony_handles_empty_assignees() {
	reset_test_state
	_install_mock_set_issue_status success
	_install_mock_set_origin_label success

	# Empty assignees array — no --remove-assignee flags should appear.
	local issue_meta='{"assignees":[]}'
	local rc=0
	_dsi_apply_dispatch_ceremony 7 owner/repo runner-self "$issue_meta" >/dev/null 2>&1 || rc=$?

	local logged
	logged=$(cat "$SET_ISSUE_STATUS_LOG")

	local rc_check=1
	[[ "$rc" -eq 0 ]] && rc_check=0
	print_result "ceremony returns 0 with empty assignees" "$rc_check"

	local no_extra_remove=0
	if [[ "$logged" == *"--remove-assignee"* ]]; then
		no_extra_remove=1
	fi
	print_result "ceremony emits no --remove-assignee for empty assignees" "$no_extra_remove"

	return 0
}

test_ceremony_handles_empty_self_login() {
	reset_test_state
	_install_mock_set_issue_status success
	_install_mock_set_origin_label success

	local issue_meta='{"assignees":[]}'
	local rc=0
	# Empty self_login → ceremony refuses + emits warning, returns 1.
	# Capture stderr to /dev/null since the warning is operator-facing.
	_dsi_apply_dispatch_ceremony 1 owner/repo "" "$issue_meta" >/dev/null 2>&1 || rc=$?

	local rc_check=1
	[[ "$rc" -eq 1 ]] && rc_check=0
	print_result "ceremony returns 1 when self_login is empty" "$rc_check" \
		"expected rc=1, got $rc"

	# Assert NO set_issue_status call was made (refuse before the gh edit).
	local call_count
	call_count=$(grep -c '^set_issue_status' "$SET_ISSUE_STATUS_LOG" 2>/dev/null || true)
	[[ "$call_count" =~ ^[0-9]+$ ]] || call_count=0
	if [[ "$call_count" -ne 0 ]]; then
		print_result "ceremony skips gh edit when self_login empty" 1 "got $call_count calls"
		return 0
	fi
	print_result "ceremony skips gh edit when self_login empty" 0

	return 0
}

test_ceremony_handles_set_issue_status_failure() {
	reset_test_state
	_install_mock_set_issue_status failure
	_install_mock_set_origin_label success

	local issue_meta='{"assignees":[]}'
	local rc=0
	_dsi_apply_dispatch_ceremony 1 owner/repo runner-self "$issue_meta" >/dev/null 2>&1 || rc=$?

	# When set_issue_status fails (e.g. gh API error), ceremony returns 1 so
	# the caller can stop before creating a worktree or launching a worker.
	local rc_check=1
	[[ "$rc" -eq 1 ]] && rc_check=0
	print_result "ceremony returns 1 when set_issue_status fails" "$rc_check"

	return 0
}

test_ceremony_failure_blocks_launch_and_releases_claim() {
	reset_test_state
	_install_mock_set_issue_status success
	local test_dir=""
	test_dir=$(mktemp -d)
	local release_log="${test_dir}/release.log"
	local worktree_log="${test_dir}/worktree.log"
	local launch_log="${test_dir}/launch.log"
	local rc=0

	(
		_DSI_ARG_NO_CEREMONY=0
		_DSI_ISSUE_META_JSON='{"assignees":[]}'
		_dsi_apply_dispatch_ceremony() { return 1; }
		_dsi_release_consensus_claim() {
			printf 'released\n' >"$release_log"
			return 0
		}
		_dsi_create_worktree() {
			printf 'created\n' >"$worktree_log"
			return 0
		}
		_dsi_launch_and_report() {
			printf 'launched\n' >"$launch_log"
			return 0
		}
		_dsi_dispatch_after_dedup_clear 1 owner/repo runner-self session-key >/dev/null 2>&1
	) || rc=$?

	local blocked=1
	[[ "$rc" -eq 1 && -f "$release_log" && ! -e "$worktree_log" && ! -e "$launch_log" ]] && blocked=0
	print_result "ceremony failure releases claim before worktree creation or worker launch" "$blocked" \
		"rc=$rc release=$([[ -f "$release_log" ]] && printf yes || printf no) worktree=$([[ -e "$worktree_log" ]] && printf yes || printf no) launch=$([[ -e "$launch_log" ]] && printf yes || printf no)"

	local reset_logged=""
	reset_logged=$(<"$SET_ISSUE_STATUS_LOG")
	local reset_ok=1
	[[ "$reset_logged" == *"set_issue_status 1 owner/repo available --remove-assignee runner-self"* ]] && reset_ok=0
	print_result "ceremony failure restores available status and removes dispatcher assignee" "$reset_ok" "$reset_logged"

	rm -rf "$test_dir"
	return 0
}

test_conversation_lock_failure_blocks_manual_launch() {
	reset_test_state
	local test_dir=""
	test_dir=$(mktemp -d)
	local launch_log="${test_dir}/launch.log"
	local rc=0

	(
		_DSI_ARG_NO_CEREMONY=0
		_DSI_WORKTREE_PATH="$test_dir"
		_dsi_apply_prelaunch_ceremony_if_enabled() { return 0; }
		_dsi_create_worktree() { return 0; }
		_dsi_guard_no_existing_dispatch() { return 0; }
		lock_issue_for_worker() { return 1; }
		_dsi_reset_after_prelaunch_failure() { return 0; }
		_dsi_launch_and_report() {
			printf 'launched\n' >"$launch_log"
			return 0
		}
		_dsi_dispatch_after_dedup_clear 1 owner/repo runner-self session-key >/dev/null 2>&1
	) || rc=$?

	local blocked=1
	[[ "$rc" -eq 1 && ! -e "$launch_log" ]] && blocked=0
	print_result "manual dispatch lock failure blocks worker launch" "$blocked" "rc=$rc"
	rm -rf "$test_dir"
	return 0
}

test_no_ceremony_flag_parses_correctly() {
	reset_test_state

	# Test that the parser correctly sets _DSI_ARG_NO_CEREMONY=1 when
	# --no-ceremony is in the args, and 0 otherwise.
	local rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --no-ceremony >/dev/null 2>&1 || rc=$?
	local no_cer_flag="$_DSI_ARG_NO_CEREMONY"

	local check1=1
	[[ "$rc" -eq 0 && "$no_cer_flag" == "1" ]] && check1=0
	print_result "--no-ceremony sets _DSI_ARG_NO_CEREMONY=1" "$check1" \
		"rc=$rc no_cer=$no_cer_flag"

	# Reset and verify default is 0
	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo >/dev/null 2>&1 || rc=$?
	no_cer_flag="$_DSI_ARG_NO_CEREMONY"

	local check2=1
	[[ "$rc" -eq 0 && "$no_cer_flag" == "0" ]] && check2=0
	print_result "default _DSI_ARG_NO_CEREMONY=0 (ceremony ON)" "$check2" \
		"rc=$rc no_cer=$no_cer_flag"

	# Composes with --dry-run
	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --dry-run --no-ceremony >/dev/null 2>&1 || rc=$?
	local dry="$_DSI_ARG_DRYRUN" no_cer="$_DSI_ARG_NO_CEREMONY"

	local check3=1
	[[ "$rc" -eq 0 && "$dry" == "1" && "$no_cer" == "1" ]] && check3=0
	print_result "--dry-run and --no-ceremony compose" "$check3" \
		"rc=$rc dry=$dry no_cer=$no_cer"

	return 0
}

test_model_override_guidance_is_provider_neutral() {
	reset_test_state

	local rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --model compatibility/model-id >/dev/null 2>&1 || rc=$?
	local override_check=1
	[[ "$rc" -eq 0 && "$_DSI_ARG_MODEL" == "compatibility/model-id" ]] && override_check=0
	print_result "advanced --model compatibility override still parses" "$override_check" \
		"rc=$rc model=$_DSI_ARG_MODEL"

	local help_out
	help_out=$(_dispatch_usage)
	local help_check=1
	if [[ "$help_out" == *"Advanced compatibility override"* &&
		"$help_out" == *"tier:simple"* &&
		"$help_out" == *"tier:standard"* &&
		"$help_out" == *"tier:thinking"* &&
		"$help_out" != *"anthropic/"* &&
		"$help_out" != *"openai/"* &&
		"$help_out" != *"google/"* ]]; then
		help_check=0
	fi
	print_result "dispatch help recommends tiers without a provider pin" "$help_check" "$help_out"

	rc=0
	local error_out
	error_out=$(_dsi_parse_dispatch_args 12345 owner/repo --model --dry-run 2>&1) || rc=$?
	local error_check=1
	if [[ "$rc" -eq 2 &&
		"$error_out" == *"tier:simple"* &&
		"$error_out" == *"tier:standard"* &&
		"$error_out" == *"tier:thinking"* &&
		"$error_out" != *"anthropic/"* &&
		"$error_out" != *"openai/"* &&
		"$error_out" != *"google/"* ]]; then
		error_check=0
	fi
	print_result "missing --model error recommends tiers without a provider pin" "$error_check" \
		"rc=$rc output=$error_out"

	return 0
}
