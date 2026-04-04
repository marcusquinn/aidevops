#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-wrapper-terminal-blockers.sh - Tests for check_terminal_blockers() (GH#5141)
#
# Tests the terminal blocker detection function that prevents dispatching
# workers against issues with known user-action-required blockers.
#
# These tests mock the gh CLI to simulate various comment patterns.

set -euo pipefail

# Disable startup jitter — pulse-wrapper.sh sleeps up to 30s on source
export PULSE_JITTER_MAX=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

# Mock state for gh CLI
GH_API_EXIT=0
GH_API_OUTPUT='[]'
GH_ISSUE_VIEW_EXIT=0
GH_ISSUE_VIEW_OUTPUT=''
GH_ISSUE_EDIT_CALLED=false
GH_ISSUE_COMMENT_CALLED=false
GH_ISSUE_COMMENT_BODY=""

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	# Source the wrapper to get the function definitions.
	# Temporarily disable set -e because the config system emits
	# non-zero exits when the config file is absent (expected in tests).
	set +e
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT" 2>/dev/null
	set -e
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

reset_mock_state() {
	GH_API_EXIT=0
	GH_API_OUTPUT='[]'
	GH_ISSUE_VIEW_EXIT=0
	GH_ISSUE_VIEW_OUTPUT=''
	GH_ISSUE_EDIT_CALLED=false
	GH_ISSUE_COMMENT_CALLED=false
	GH_ISSUE_COMMENT_BODY=""
	return 0
}

# Mock gh CLI
gh() {
	case "$1" in
	api)
		if [[ $GH_API_EXIT -ne 0 ]]; then
			return "$GH_API_EXIT"
		fi
		printf '%s\n' "$GH_API_OUTPUT"
		return 0
		;;
	issue)
		case "$2" in
		view)
			if [[ $GH_ISSUE_VIEW_EXIT -ne 0 ]]; then
				return "$GH_ISSUE_VIEW_EXIT"
			fi
			printf '%s\n' "$GH_ISSUE_VIEW_OUTPUT"
			return 0
			;;
		edit)
			GH_ISSUE_EDIT_CALLED=true
			return 0
			;;
		comment)
			GH_ISSUE_COMMENT_CALLED=true
			# Capture the body argument
			local prev_arg_val=""
			local arg
			for arg in "$@"; do
				if [[ "$prev_arg_val" == "--body" ]]; then
					GH_ISSUE_COMMENT_BODY="$arg"
					break
				fi
				prev_arg_val="$arg"
			done
			return 0
			;;
		esac
		;;
	esac
	return 0
}

#######################################
# Test: missing arguments returns exit 2
#######################################
test_missing_args() {
	reset_mock_state
	local exit_code=0
	check_terminal_blockers "" "" 2>/dev/null || exit_code=$?
	print_result "missing args returns exit 2" $((exit_code == 2 ? 0 : 1)) "got exit $exit_code"
	return 0
}

#######################################
# Test: non-numeric issue number returns exit 2
#######################################
test_non_numeric_issue() {
	reset_mock_state
	local exit_code=0
	check_terminal_blockers "abc" "owner/repo" 2>/dev/null || exit_code=$?
	print_result "non-numeric issue returns exit 2" $((exit_code == 2 ? 0 : 1)) "got exit $exit_code"
	return 0
}

#######################################
# Test: API error fails open (exit 2)
#######################################
test_api_error_fails_open() {
	reset_mock_state
	GH_API_EXIT=1
	local exit_code=0
	check_terminal_blockers "42" "owner/repo" 2>/dev/null || exit_code=$?
	print_result "API error fails open (exit 2)" $((exit_code == 2 ? 0 : 1)) "got exit $exit_code"
	return 0
}

#######################################
# Test: no comments returns exit 1 (no blocker)
#######################################
test_no_comments() {
	reset_mock_state
	GH_API_OUTPUT='[]'
	GH_ISSUE_VIEW_OUTPUT='none'
	local exit_code=0
	check_terminal_blockers "42" "owner/repo" 2>/dev/null || exit_code=$?
	print_result "no comments returns exit 1 (no blocker)" $((exit_code == 1 ? 0 : 1)) "got exit $exit_code"
	return 0
}

#######################################
# Test: comments without blocker patterns return exit 1
#######################################
test_clean_comments() {
	reset_mock_state
	GH_API_OUTPUT='[{"body":"This looks good, working on it now.","created_at":"2026-03-16T00:00:00Z"},{"body":"Made progress on the implementation.","created_at":"2026-03-16T01:00:00Z"}]'
	GH_ISSUE_VIEW_OUTPUT='none'
	local exit_code=0
	check_terminal_blockers "42" "owner/repo" 2>/dev/null || exit_code=$?
	print_result "clean comments return exit 1 (no blocker)" $((exit_code == 1 ? 0 : 1)) "got exit $exit_code"
	return 0
}

#######################################
# Test: workflow scope blocker detected (exit 0)
#######################################
test_workflow_scope_blocker() {
	reset_mock_state
	GH_API_OUTPUT='[{"body":"Error: refusing to allow an OAuth App to create or update workflow .github/workflows/ci.yml without workflow scope","created_at":"2026-03-16T00:03:00Z"}]'
	GH_ISSUE_VIEW_OUTPUT='none'
	local exit_code=0
	check_terminal_blockers "57" "owner/repo" 2>/dev/null || exit_code=$?
	print_result "workflow scope blocker detected (exit 0)" $((exit_code == 0 ? 0 : 1)) "got exit $exit_code"
	return 0
}

#######################################
# Test: token lacks scope blocker detected (exit 0)
#######################################
test_token_lacks_scope() {
	reset_mock_state
	GH_API_OUTPUT='[{"body":"The token lacks workflow scope. Run gh auth refresh -s workflow to fix.","created_at":"2026-03-16T00:03:00Z"}]'
	GH_ISSUE_VIEW_OUTPUT='none'
	local exit_code=0
	check_terminal_blockers "57" "owner/repo" 2>/dev/null || exit_code=$?
	print_result "token lacks scope blocker detected (exit 0)" $((exit_code == 0 ? 0 : 1)) "got exit $exit_code"
	return 0
}

#######################################
# Test: ACTION REQUIRED blocker detected (exit 0)
#######################################
test_action_required() {
	reset_mock_state
	GH_API_OUTPUT='[{"body":"ACTION REQUIRED: You need to add the workflow scope to your GitHub token.","created_at":"2026-03-16T00:03:00Z"}]'
	GH_ISSUE_VIEW_OUTPUT='none'
	local exit_code=0
	check_terminal_blockers "57" "owner/repo" 2>/dev/null || exit_code=$?
	print_result "ACTION REQUIRED blocker detected (exit 0)" $((exit_code == 0 ? 0 : 1)) "got exit $exit_code"
	return 0
}

#######################################
# Test: idempotent — does not double-post comment
#######################################
test_idempotent_no_double_post() {
	reset_mock_state
	GH_API_OUTPUT='[{"body":"Terminal blocker detected (GH#5141) — skipping dispatch.\n\nReason: workflow scope","created_at":"2026-03-16T00:03:00Z"},{"body":"Error: refusing to allow an OAuth App to create or update workflow","created_at":"2026-03-16T00:02:00Z"}]'
	GH_ISSUE_VIEW_OUTPUT='status:blocked'
	local exit_code=0
	check_terminal_blockers "57" "owner/repo" 2>/dev/null || exit_code=$?
	# Should still return 0 (blocker detected) but not post a new comment
	print_result "idempotent — still detects blocker (exit 0)" $((exit_code == 0 ? 0 : 1)) "got exit $exit_code"
	# The comment mock was not called because the existing comment contains "Terminal blocker detected"
	local double_post_check=1
	if [[ "$GH_ISSUE_COMMENT_CALLED" == "false" ]]; then
		double_post_check=0
	fi
	print_result "idempotent — does not double-post" "$double_post_check" "comment called: $GH_ISSUE_COMMENT_CALLED"
	return 0
}

#######################################
# Test: missing scope with different wording
#######################################
test_missing_scope_variant() {
	reset_mock_state
	GH_API_OUTPUT='[{"body":"Push failed: token lacks the required scope for workflow files.","created_at":"2026-03-16T00:03:00Z"}]'
	GH_ISSUE_VIEW_OUTPUT='none'
	local exit_code=0
	check_terminal_blockers "57" "owner/repo" 2>/dev/null || exit_code=$?
	print_result "missing scope variant detected (exit 0)" $((exit_code == 0 ? 0 : 1)) "got exit $exit_code"
	return 0
}

#######################################
# Main
#######################################
main() {
	printf 'Running terminal blocker detection tests (GH#5141)...\n\n'

	setup_test_env

	test_missing_args
	test_non_numeric_issue
	test_api_error_fails_open
	test_no_comments
	test_clean_comments
	test_workflow_scope_blocker
	test_token_lacks_scope
	test_action_required
	test_idempotent_no_double_post
	test_missing_scope_variant

	teardown_test_env

	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
