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
# origin:worker + assignee normalize) that the pulse always applies. This
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

reset_test_state() {
	: >"$SET_ISSUE_STATUS_LOG"
	return 0
}

# -----------------------------------------------------------------------------
# Test cases
# -----------------------------------------------------------------------------

test_ceremony_applies_default() {
	reset_test_state
	_install_mock_set_issue_status success

	# Issue meta with one prior assignee that ceremony should remove.
	local issue_meta='{"assignees":[{"login":"prior-author"}]}'
	local rc=0
	_dsi_apply_dispatch_ceremony 12345 owner/repo runner-self "$issue_meta" >/dev/null 2>&1 || rc=$?

	local logged
	logged=$(cat "$SET_ISSUE_STATUS_LOG")

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
	[[ "$logged" == *"set_issue_status 12345 owner/repo queued"* ]] && status_check=0
	print_result "ceremony passes status:queued (not in-progress)" "$status_check" \
		"expected 'set_issue_status 12345 owner/repo queued' in: $logged"

	# Assert origin label flip flags
	local origin_add=1 origin_rm_int=1 origin_rm_take=1
	[[ "$logged" == *"--add-label origin:worker"* ]] && origin_add=0
	[[ "$logged" == *"--remove-label origin:interactive"* ]] && origin_rm_int=0
	[[ "$logged" == *"--remove-label origin:worker-takeover"* ]] && origin_rm_take=0
	print_result "ceremony adds origin:worker" "$origin_add"
	print_result "ceremony removes origin:interactive" "$origin_rm_int"
	print_result "ceremony removes origin:worker-takeover" "$origin_rm_take"

	# Assert assignee normalization
	local add_assignee=1 rm_prior=1
	[[ "$logged" == *"--add-assignee runner-self"* ]] && add_assignee=0
	[[ "$logged" == *"--remove-assignee prior-author"* ]] && rm_prior=0
	print_result "ceremony adds runner-self as assignee" "$add_assignee"
	print_result "ceremony removes prior assignee" "$rm_prior"

	return 0
}

test_ceremony_skip_when_self_assigned() {
	reset_test_state
	_install_mock_set_issue_status success

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
	trap 'rm -f "$SET_ISSUE_STATUS_LOG"' EXIT

	test_ceremony_applies_default
	test_ceremony_skip_when_self_assigned
	test_ceremony_handles_empty_assignees
	test_ceremony_handles_empty_self_login
	test_ceremony_handles_set_issue_status_failure
	test_no_ceremony_flag_parses_correctly

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
