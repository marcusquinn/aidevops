#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for dispatch-single-issue-helper.sh — focused on the t3000
# `_dsi_apply_dispatch_ceremony` function which mirrors the canonical pulse
# `_dlw_assign_and_label` ownership-claim sequence.
#
# Background: the manual single-issue dispatch CLI was previously launching
# workers without applying the pre-launch ceremony (status:queued +
# assignee normalize) that the pulse always applies. This
# created a race window where the next pulse cycle could see the issue in
# its prior state and dispatch a duplicate worker on top of the running one.
#
# The tests exercise the helper in isolation by sourcing the script (the
# `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard prevents main() from
# running) and overriding `set_issue_status` with a mock that captures
# every flag for assertion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_PATH="${SCRIPT_DIR}/../dispatch-single-issue-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
SET_ISSUE_STATUS_LOG=""
SET_ORIGIN_LABEL_LOG=""
MOCK_GH_ISSUE_STATE="OPEN"
MOCK_GH_FAIL="0"
MOCK_GH_TARGET_IS_PR="0"
MOCK_PS_LINES=""
MOCK_LEDGER_RECORD=""

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

# Source the helper so its functions become available in this shell.
# The main() guard means executing the test does NOT re-enter the dispatch
# CLI — only the function definitions land in scope.
# shellcheck source=../dispatch-single-issue-helper.sh
# shellcheck disable=SC1091
source "$HELPER_PATH"

# Override set_issue_status (defined by shared-gh-wrappers.sh which the
# helper sourced) with a mock that logs every flag to SET_ISSUE_STATUS_LOG.
# This is what the ceremony function calls; we never actually touch GitHub.
#
# Mode comes from the global $MOCK_SET_ISSUE_STATUS_MODE — NOT a local of
# the installer function. A nested function definition does not capture the
# enclosing function's locals (bash has no closures); after the installer
# returns, those locals are gone and `set -u` would tank the mock body.
MOCK_SET_ISSUE_STATUS_MODE="success"

# shellcheck disable=SC2317
set_issue_status() {
	printf 'set_issue_status %s\n' "$*" >>"$SET_ISSUE_STATUS_LOG"
	case "$MOCK_SET_ISSUE_STATUS_MODE" in
	success) return 0 ;;
	failure) return 1 ;;
	*) return 0 ;;
	esac
}

_install_mock_set_issue_status() {
	MOCK_SET_ISSUE_STATUS_MODE="${1:-success}"
	return 0
}

# Override set_origin_label (also from shared-gh-wrappers.sh) with a mock that
# logs every call to SET_ORIGIN_LABEL_LOG. Dispatch ceremony should not call it:
# origin:* labels are immutable creation provenance, not worker-claim state.
MOCK_SET_ORIGIN_LABEL_MODE="success"

# shellcheck disable=SC2317
set_origin_label() {
	printf 'set_origin_label %s\n' "$*" >>"$SET_ORIGIN_LABEL_LOG"
	case "$MOCK_SET_ORIGIN_LABEL_MODE" in
	success) return 0 ;;
	failure) return 1 ;;
	*) return 0 ;;
	esac
}

_install_mock_set_origin_label() {
	MOCK_SET_ORIGIN_LABEL_MODE="${1:-success}"
	return 0
}

# shellcheck disable=SC2317
gh() {
	local gh_subcommand="${1:-}"
	local gh_resource="${2:-}"
	if [[ "$MOCK_GH_FAIL" == "1" ]]; then
		return 1
	fi

	if [[ "$gh_subcommand" == "issue" && "$gh_resource" == "view" ]]; then
		printf '{"number":%s,"title":"Mock issue","state":"%s","labels":[],"assignees":[],"url":"https://example.invalid/issues/%s"}\n' \
			"$3" "$MOCK_GH_ISSUE_STATE" "$3"
		return 0
	fi

	if [[ "$gh_subcommand" == "api" && "$gh_resource" == "user" ]]; then
		printf '%s\n' 'runner-self'
		return 0
	fi

	if [[ "$gh_subcommand" == "api" && "$gh_resource" == repos/*/issues/* ]]; then
		case "$MOCK_GH_TARGET_IS_PR" in
		1) printf '{"number":123,"pull_request":{"url":"https://api.example.invalid/pulls/123"}}\n' ;;
		api_fail) return 1 ;;
		*) printf '{"number":123}\n' ;;
		esac
		return 0
	fi

	printf 'unexpected gh call: %s\n' "$*" >&2
	return 1
}


# shellcheck disable=SC2317
_dsi_ps_worker_lines() {
	printf '%s\n' "$MOCK_PS_LINES"
	return 0
}

# shellcheck disable=SC2317
_dsi_repo_slug_for_worktree() {
	local worktree_path="$1"
	case "$worktree_path" in
	/tmp/aidevops-existing | /tmp/aidevops-recovery) printf '%s\n' "owner/repo" ;;
	*) printf '\n' ;;
	esac
	return 0
}

# shellcheck disable=SC2317
_dsi_find_ledger_dispatch() {
	local issue_number="$1"
	local repo_slug="$2"
	if [[ -n "$MOCK_LEDGER_RECORD" && "$issue_number" == "12345" && "$repo_slug" == "owner/repo" ]]; then
		printf '%s\n' "$MOCK_LEDGER_RECORD"
		return 0
	fi
	return 1
}

reset_test_state() {
	: >"$SET_ISSUE_STATUS_LOG"
	: >"$SET_ORIGIN_LABEL_LOG"
	return 0
}

# -----------------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------------

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

	# When set_issue_status fails (e.g. gh API error), ceremony returns 1
	# but does NOT propagate set -e — caller treats it as best-effort.
	local rc_check=1
	[[ "$rc" -eq 1 ]] && rc_check=0
	print_result "ceremony returns 1 when set_issue_status fails" "$rc_check"

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

test_load_issue_meta_accepts_lowercase_open() {
	MOCK_GH_FAIL="0"
	MOCK_GH_ISSUE_STATE="open"

	local rc=0
	_dsi_load_issue_meta 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 && "$_DSI_ISSUE_TITLE" == "Mock issue" ]] && check=0
	print_result "load issue meta accepts lowercase open" "$check" \
		"expected rc=0 with title populated, got rc=$rc title=$_DSI_ISSUE_TITLE"

	return 0
}

test_agent_flag_parses_with_default() {
	reset_test_state

	local rc=0
	_dsi_parse_dispatch_args 12345 owner/repo >/dev/null 2>&1 || rc=$?
	local default_agent="$_DSI_ARG_AGENT"
	local check1=1
	[[ "$rc" -eq 0 && "$default_agent" == "Build+" ]] && check1=0
	print_result "default worker agent is Build+" "$check1" \
		"rc=$rc agent=$default_agent"

	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --agent CustomAgent >/dev/null 2>&1 || rc=$?
	local custom_agent="$_DSI_ARG_AGENT"
	local check2=1
	[[ "$rc" -eq 0 && "$custom_agent" == "CustomAgent" ]] && check2=0
	print_result "--agent overrides worker agent" "$check2" \
		"rc=$rc agent=$custom_agent"

	rc=0
	_dsi_parse_dispatch_args 12345 owner/repo --agent --dry-run >/dev/null 2>&1 || rc=$?
	local check3=1
	[[ "$rc" -eq 2 ]] && check3=0
	print_result "--agent requires a value" "$check3" "rc=$rc"

	return 0
}

test_load_issue_meta_blocks_lowercase_closed() {
	MOCK_GH_FAIL="0"
	MOCK_GH_ISSUE_STATE="closed"

	local rc=0
	_dsi_load_issue_meta 124 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "load issue meta blocks lowercase closed" "$check" \
		"expected rc=1 for closed state, got rc=$rc"

	return 0
}

test_pr_target_guard_detects_pull_request() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="1"

	local rc=0
	_dsi_target_is_pull_request 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "PR target guard detects pull_request marker" "$check" \
		"expected rc=0 for PR-shaped issue, got rc=$rc"
	return 0
}

test_pr_target_guard_allows_plain_issue() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="0"

	local rc=0
	_dsi_target_is_pull_request 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "PR target guard allows plain issue" "$check" \
		"expected rc=1 for plain issue, got rc=$rc"
	return 0
}

test_pr_target_guard_fails_closed_on_api_error() {
	MOCK_GH_FAIL="0"
	MOCK_GH_TARGET_IS_PR="api_fail"

	local rc=0
	_dsi_target_is_pull_request 123 owner/repo >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 2 ]] && check=0
	print_result "PR target guard reports verification errors" "$check" \
		"expected rc=2 for API failure, got rc=$rc"
	return 0
}

test_interactive_hold_guard_blocks_review_label() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,status:in-review,auto-dispatch" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "interactive hold guard blocks status:in-review" "$check" "rc=$rc"
	return 0
}

test_interactive_hold_guard_blocks_origin_interactive_without_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,origin:interactive" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 1 ]] && check=0
	print_result "interactive hold guard blocks origin:interactive without handoff" "$check" "rc=$rc"
	return 0
}

test_interactive_hold_guard_allows_auto_dispatch_handoff() {
	local rc=0
	_dsi_guard_no_interactive_hold "bug,origin:interactive,auto-dispatch" >/dev/null 2>&1 || rc=$?

	local check=1
	[[ "$rc" -eq 0 ]] && check=0
	print_result "interactive hold guard allows auto-dispatch handoff" "$check" "rc=$rc"
	return 0
}

test_launch_worker_forwards_agent() {
	local failed=1
	if grep -Fq "cmd+=(--agent \"\$agent_name\")" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worker launch forwards --agent to headless runtime" "$failed"
	return 0
}

test_launch_worker_forwards_repo_contract() {
	local failed=1
	if grep -Fq "WORKER_REPO_SLUG=\"\$repo_slug\"" "$HELPER_PATH" &&
		grep -Fq "GITHUB_REPOSITORY=\"\$repo_slug\"" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worker launch forwards target repo contract" "$failed"
	return 0
}

test_create_worktree_uses_target_repo_path() {
	local failed=1
	if grep -Fq "repo_path=\$(_dsi_repo_path_for_slug \"\$repo_slug\")" "$HELPER_PATH" &&
		grep -Fq "cd \"\$repo_path\" && AIDEVOPS_SKIP_AUTO_CLAIM=1" "$HELPER_PATH" &&
		grep -Fq "git -C \"\$repo_path\" worktree list --porcelain" "$HELPER_PATH"; then
		failed=0
	fi
	print_result "worktree creation uses target repo path" "$failed"
	return 0
}


test_readiness_accepts_worker_started_marker() {
	MOCK_LEDGER_RECORD=""
	local session_key="manual-cli-ready-$$"
	local runtime_log=""
	runtime_log=$(_dsi_detached_runtime_log "$session_key")
	printf '%s\n' "[lifecycle] worker_started session=${session_key}" >"$runtime_log"

	local out="" rc=0
	out=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" /tmp/manual-ready.log 2>&1) || rc=$?
	rm -f "$runtime_log"

	local passed=1
	[[ "$rc" -eq 0 && -z "$out" ]] && passed=0
	print_result "readiness gate accepts worker_started marker" "$passed" "rc=$rc output=$out"
	return 0
}

test_readiness_rejects_live_child_without_ready_signal() {
	MOCK_LEDGER_RECORD=""
	local session_key="manual-cli-not-ready-$$"
	local runtime_log=""
	runtime_log=$(_dsi_detached_runtime_log "$session_key")
	rm -f "$runtime_log"

	local out="" rc=0
	out=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" /tmp/manual-not-ready.log 2>&1) || rc=$?
	rm -f "$runtime_log"

	local passed=1
	[[ "$rc" -eq 1 && "$out" == *"did not reach readiness"* && "$out" == *"Runtime log:"* ]] && passed=0
	print_result "readiness gate rejects live child without ready signal" "$passed" "rc=$rc output=$out"
	return 0
}

test_readiness_rejects_ledger_without_worker_started() {
	MOCK_LEDGER_RECORD=$'ledger\t888\t/tmp/manual.log\t/tmp/aidevops-existing\tmanual-cli-12345-ledger'
	local session_key="manual-cli-ledger-only-$$"
	local runtime_log=""
	runtime_log=$(_dsi_detached_runtime_log "$session_key")
	rm -f "$runtime_log"

	local out="" rc=0
	out=$(AIDEVOPS_DSI_READY_TIMEOUT_SECONDS=0 _dsi_wait_for_worker_readiness 12345 owner/repo "$session_key" "$$" /tmp/manual-ledger-only.log 2>&1) || rc=$?
	rm -f "$runtime_log"
	MOCK_LEDGER_RECORD=""

	local passed=1
	[[ "$rc" -eq 1 && "$out" == *"did not reach readiness"* ]] && passed=0
	print_result "readiness gate rejects ledger without worker_started" "$passed" "rc=$rc output=$out"
	return 0
}

test_launch_report_waits_before_success_message() {
	local wait_line="" ok_line=""
	wait_line=$(grep -n '_dsi_wait_for_worker_readiness' "$HELPER_PATH" | tail -1 | cut -d: -f1)
	ok_line=$(grep -n '_dsi_ok "Worker launched"' "$HELPER_PATH" | tail -1 | cut -d: -f1)

	local passed=1
	if [[ -n "$wait_line" && -n "$ok_line" && "$wait_line" -lt "$ok_line" ]]; then
		passed=0
	fi
	print_result "launch report waits for readiness before Worker launched" "$passed" "wait_line=$wait_line ok_line=$ok_line"
	return 0
}



test_live_dispatch_detects_issue_repo() {
	MOCK_LEDGER_RECORD=""
	MOCK_PS_LINES='700 S bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key manual-cli-12345-999 --dir /tmp/aidevops-existing --title Issue #12345 --prompt-file /tmp/prompt'

	local record="" rc=0
	record=$(_dsi_find_live_dispatch 12345 owner/repo "") || rc=$?

	local found=1
	[[ "$rc" -eq 0 && "$record" == process$'\t'700$'\t'*$'\t'/tmp/aidevops-existing$'\t'manual-cli-12345-999 ]] && found=0
	print_result "live process evidence detects active issue/repo worker" "$found" "rc=$rc record=$record"
	return 0
}

test_guard_blocks_ledger_duplicate() {
	MOCK_PS_LINES=""
	MOCK_LEDGER_RECORD=$'ledger\t888\t/tmp/manual.log\t/tmp/aidevops-existing\tmanual-cli-12345-1'

	local out="" rc=0
	out=$(_dsi_guard_no_existing_dispatch 12345 owner/repo 2>&1) || rc=$?

	local blocked=1
	[[ "$rc" -eq 1 && "$out" == *"Existing PID:"* && "$out" == *"888"* && "$out" == *"Existing worktree:"* ]] && blocked=0
	print_result "duplicate guard blocks active ledger dispatch" "$blocked" "rc=$rc output=$out"
	return 0
}

test_guard_blocks_live_worktree_duplicate() {
	MOCK_LEDGER_RECORD=""
	MOCK_PS_LINES='701 S opencode run --dir /tmp/aidevops-recovery --title Issue #9999 "/full-loop Implement issue #9999"'

	local out="" rc=0
	out=$(_dsi_guard_no_existing_dispatch 12345 owner/repo /tmp/aidevops-recovery 2>&1) || rc=$?

	local blocked=1
	[[ "$rc" -eq 1 && "$out" == *"701"* && "$out" == *"/tmp/aidevops-recovery"* ]] && blocked=0
	print_result "duplicate guard blocks active worktree owner" "$blocked" "rc=$rc output=$out"
	return 0
}



test_status_reports_live_process_without_ledger() {
	MOCK_LEDGER_RECORD=""
	MOCK_PS_LINES='702 S bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key manual-cli-12345-777 --dir /tmp/aidevops-existing --title Issue #12345 --prompt-file /tmp/prompt'

	local out="" rc=0
	out=$(cmd_status 12345 owner/repo 2>&1) || rc=$?

	local active=1
	[[ "$rc" -eq 0 && "$out" == *"Active dispatch"* && "$out" == *"live process evidence"* && "$out" == *"702"* ]] && active=0
	print_result "status reports live process when ledger is missing" "$active" "rc=$rc output=$out"
	return 0
}

# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------
# IMPORTANT: the helper script we source defines `main()` for its CLI entry.
# We renamed our runner to `_run_tests` to avoid shadowing the helper's main
# (which is itself sourced but guarded behind BASH_SOURCE check). Sourcing
# re-defines main() in this shell, so a test runner named main would simply
# silently replace the helper's main and may collide with future helpers.

_run_tests() {
	SET_ISSUE_STATUS_LOG=$(mktemp)
	SET_ORIGIN_LABEL_LOG=$(mktemp)
	trap 'rm -f "$SET_ISSUE_STATUS_LOG" "$SET_ORIGIN_LABEL_LOG"' EXIT

	test_ceremony_applies_default
	test_ceremony_skip_when_self_assigned
	test_ceremony_handles_empty_assignees
	test_ceremony_handles_empty_self_login
	test_ceremony_handles_set_issue_status_failure
	test_no_ceremony_flag_parses_correctly
	test_load_issue_meta_accepts_lowercase_open
	test_load_issue_meta_blocks_lowercase_closed
	test_pr_target_guard_detects_pull_request
	test_pr_target_guard_allows_plain_issue
	test_pr_target_guard_fails_closed_on_api_error
	test_interactive_hold_guard_blocks_review_label
	test_interactive_hold_guard_blocks_origin_interactive_without_handoff
	test_interactive_hold_guard_allows_auto_dispatch_handoff
	test_agent_flag_parses_with_default
	test_launch_worker_forwards_agent
	test_launch_worker_forwards_repo_contract
	test_create_worktree_uses_target_repo_path
	test_readiness_accepts_worker_started_marker
	test_readiness_rejects_live_child_without_ready_signal
	test_readiness_rejects_ledger_without_worker_started
	test_launch_report_waits_before_success_message
	test_live_dispatch_detects_issue_repo
	test_guard_blocks_ledger_duplicate
	test_guard_blocks_live_worktree_duplicate
	test_status_reports_live_process_without_ledger

	echo
	echo "======================================"
	echo "Tests run:    $TESTS_RUN"
	echo "Tests passed: $((TESTS_RUN - TESTS_FAILED))"
	echo "Tests failed: $TESTS_FAILED"
	echo "======================================"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

_run_tests "$@"
