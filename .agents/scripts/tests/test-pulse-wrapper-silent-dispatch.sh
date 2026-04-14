#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-wrapper-silent-dispatch.sh - Regression tests for GH#18804
#
# The deterministic fill floor pass (_dff_should_skip_candidate +
# _dff_process_candidate) previously had multiple early-return paths that
# silently rejected dispatch candidates without writing any log line, making
# silent-failure rounds (`candidates=N` followed immediately by
# `Adaptive settle wait: 0 dispatches` with nothing between) impossible to
# diagnose from pulse.log.
#
# These tests assert that EVERY skip path writes an identifiable log line so a
# future regression can be caught before it ships.
#
# Bug-class context: this is the same family as GH#18770, GH#18784, GH#18786 —
# silent set-e propagation / unchecked return swallowing. See
# `.agents/reference/bash-compat.md` pre-merge checklist item 4.

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
	# Source the wrapper to get function definitions. Config-load failures are
	# expected in test environments — disable set -e for the source itself.
	set +e
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT" 2>/dev/null
	set -e
	# Force LOGFILE into the test sandbox so log assertions are isolated.
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	export LOGFILE
	: >"$LOGFILE"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

reset_logfile() {
	: >"$LOGFILE"
	return 0
}

#######################################
# Test 1: a terminal-blocker skip MUST write a per-candidate log line.
#
# Mocks check_terminal_blockers to always return 0 (blocker detected).
# Asserts the caller logs a skip line naming the check that fired — even
# though check_terminal_blockers' own log line also goes to LOGFILE, the
# caller's redundant line is the safety net that survives any future
# refactor of the helper.
#######################################
test_terminal_blocker_skip_logs() {
	reset_logfile
	# Mock dependencies: terminal blocker positive, fast-fail negative.
	check_terminal_blockers() { return 0; }
	fast_fail_is_skipped() { return 1; }
	gh() { :; } # not reached because terminal_rc=0 short-circuits

	local rc=0
	_dff_should_skip_candidate "12345" "owner/repo" || rc=$?
	unset -f check_terminal_blockers fast_fail_is_skipped gh

	local skip_logged=1
	if grep -q "skipping #12345 (owner/repo) — terminal blocker detected" "$LOGFILE"; then
		skip_logged=0
	fi
	print_result "terminal blocker skip writes per-candidate log line" "$skip_logged" \
		"LOGFILE contents: $(cat "$LOGFILE" || true)"
	# Expected return: 0 (skip)
	print_result "terminal blocker skip returns 0 (skip)" $((rc == 0 ? 0 : 1)) "got rc=$rc"
	return 0
}

#######################################
# Test 2: fast-fail skip writes per-candidate log line (regression guard).
#######################################
test_fast_fail_skip_logs() {
	reset_logfile
	check_terminal_blockers() { return 1; } # no terminal blocker
	fast_fail_is_skipped() { return 0; }    # fast-fail tripped

	local rc=0
	_dff_should_skip_candidate "23456" "owner/repo" || rc=$?
	unset -f check_terminal_blockers fast_fail_is_skipped

	local skip_logged=1
	if grep -q "skipping #23456 (owner/repo) — fast-fail threshold reached" "$LOGFILE"; then
		skip_logged=0
	fi
	print_result "fast-fail skip writes per-candidate log line" "$skip_logged" \
		"LOGFILE contents: $(cat "$LOGFILE" || true)"
	print_result "fast-fail skip returns 0 (skip)" $((rc == 0 ? 0 : 1)) "got rc=$rc"
	return 0
}

#######################################
# Test 3: empty body skip writes per-candidate log line.
#######################################
test_empty_body_skip_logs() {
	reset_logfile
	check_terminal_blockers() { return 1; }
	fast_fail_is_skipped() { return 1; }
	# Mock gh issue view to return empty body.
	gh() {
		case "$1" in
		issue)
			[[ "$2" == "view" ]] && {
				printf '\n'
				return 0
			}
			;;
		esac
		return 0
	}

	local rc=0
	_dff_should_skip_candidate "34567" "owner/repo" || rc=$?
	unset -f check_terminal_blockers fast_fail_is_skipped gh

	local skip_logged=1
	if grep -q "skipping #34567 (owner/repo) — placeholder/empty issue body" "$LOGFILE"; then
		skip_logged=0
	fi
	print_result "empty body skip writes per-candidate log line" "$skip_logged" \
		"LOGFILE contents: $(cat "$LOGFILE" || true)"
	print_result "empty body skip returns 0 (skip)" $((rc == 0 ? 0 : 1)) "got rc=$rc"
	return 0
}

#######################################
# Test 4: stub body skip writes per-candidate log line.
#######################################
test_stub_body_skip_logs() {
	reset_logfile
	check_terminal_blockers() { return 1; }
	fast_fail_is_skipped() { return 1; }
	gh() {
		case "$1" in
		issue)
			[[ "$2" == "view" ]] && {
				printf 'placeholder body — no description provided — enrich before dispatch\n'
				return 0
			}
			;;
		esac
		return 0
	}

	local rc=0
	_dff_should_skip_candidate "45678" "owner/repo" || rc=$?
	unset -f check_terminal_blockers fast_fail_is_skipped gh

	local skip_logged=1
	if grep -q "skipping #45678 (owner/repo) — claim-task-id.sh stub body" "$LOGFILE"; then
		skip_logged=0
	fi
	print_result "stub body skip writes per-candidate log line" "$skip_logged" \
		"LOGFILE contents: $(cat "$LOGFILE" || true)"
	print_result "stub body skip returns 0 (skip)" $((rc == 0 ? 0 : 1)) "got rc=$rc"
	return 0
}

#######################################
# Test 5: malformed candidate JSON in _dff_process_candidate logs the skip
# instead of returning silently. Pre-GH#18804 this was a silent return 1.
#######################################
test_malformed_candidate_logs_skip() {
	reset_logfile
	# Bad JSON: number is missing.
	local bad_json='{"repo_slug":"owner/repo","repo_path":"/tmp/repo"}'

	local rc=0
	_dff_process_candidate "$bad_json" "test-user" "10" || rc=$?

	local skip_logged=1
	if grep -q "skipping malformed candidate — issue_number=" "$LOGFILE"; then
		skip_logged=0
	fi
	print_result "malformed candidate JSON logs skip line" "$skip_logged" \
		"LOGFILE contents: $(cat "$LOGFILE" || true)"
	print_result "malformed candidate returns 1 (skipped)" $((rc == 1 ? 0 : 1)) "got rc=$rc"
	return 0
}

#######################################
# Test 6: missing repo_path in _dff_process_candidate logs the skip.
#######################################
test_missing_repo_path_logs_skip() {
	reset_logfile
	# Valid issue_number but repo_path empty.
	local bad_json='{"number":56789,"repo_slug":"owner/repo","repo_path":""}'

	local rc=0
	_dff_process_candidate "$bad_json" "test-user" "10" || rc=$?

	local skip_logged=1
	if grep -q "skipping #56789 — missing repo_slug=" "$LOGFILE"; then
		skip_logged=0
	fi
	print_result "missing repo_path logs skip line" "$skip_logged" \
		"LOGFILE contents: $(cat "$LOGFILE" || true)"
	print_result "missing repo_path returns 1 (skipped)" $((rc == 1 ? 0 : 1)) "got rc=$rc"
	return 0
}

#######################################
# Test 7: PULSE_DEBUG=1 produces DFF DEBUG: lines for every candidate.
#######################################
test_pulse_debug_emits_per_candidate_logs() {
	reset_logfile
	export PULSE_DEBUG=1
	check_terminal_blockers() { return 1; }
	fast_fail_is_skipped() { return 1; }
	gh() {
		case "$1" in
		issue)
			[[ "$2" == "view" ]] && {
				printf 'a real implementation context\n'
				return 0
			}
			;;
		esac
		return 0
	}

	_dff_should_skip_candidate "67890" "owner/repo" || true
	unset -f check_terminal_blockers fast_fail_is_skipped gh
	unset PULSE_DEBUG

	local debug_logged=1
	if grep -q "DFF DEBUG: evaluating skip checks for #67890 (owner/repo)" "$LOGFILE"; then
		debug_logged=0
	fi
	print_result "PULSE_DEBUG=1 logs per-candidate evaluation line" "$debug_logged" \
		"LOGFILE contents: $(cat "$LOGFILE" || true)"

	local rc_logged=1
	if grep -q "DFF DEBUG: #67890: check_terminal_blockers rc=" "$LOGFILE"; then
		rc_logged=0
	fi
	print_result "PULSE_DEBUG=1 logs check_terminal_blockers rc" "$rc_logged" ""
	return 0
}

#######################################
# Test 8: PULSE_DEBUG unset = no DFF DEBUG: lines (default behaviour).
#######################################
test_pulse_debug_unset_quiet_default() {
	reset_logfile
	unset PULSE_DEBUG
	check_terminal_blockers() { return 1; }
	fast_fail_is_skipped() { return 1; }
	gh() {
		case "$1" in
		issue)
			[[ "$2" == "view" ]] && {
				printf 'a real implementation context\n'
				return 0
			}
			;;
		esac
		return 0
	}

	_dff_should_skip_candidate "78901" "owner/repo" || true
	unset -f check_terminal_blockers fast_fail_is_skipped gh

	local quiet_default=0
	if grep -q "DFF DEBUG:" "$LOGFILE"; then
		quiet_default=1
	fi
	print_result "PULSE_DEBUG unset emits no DFF DEBUG: lines" "$quiet_default" \
		"LOGFILE contents: $(cat "$LOGFILE" || true)"
	return 0
}

#######################################
# Main
#######################################
main() {
	printf 'Running pulse silent-dispatch regression tests (GH#18804)...\n\n'

	setup_test_env

	test_terminal_blocker_skip_logs
	test_fast_fail_skip_logs
	test_empty_body_skip_logs
	test_stub_body_skip_logs
	test_malformed_candidate_logs_skip
	test_missing_repo_path_logs_skip
	test_pulse_debug_emits_per_candidate_logs
	test_pulse_debug_unset_quiet_default

	teardown_test_env

	printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
