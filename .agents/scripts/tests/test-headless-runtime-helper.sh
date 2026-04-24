#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-headless-runtime-helper.sh - Coverage for /full-loop headless contract injection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER_SCRIPT="${SCRIPT_DIR}/../headless-runtime-helper.sh"

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
	set +e
	# shellcheck source=/dev/null
	source "$HELPER_SCRIPT" >/dev/null 2>&1
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

test_appends_escalation_contract() {
	local prompt='/full-loop Implement issue #14964'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == *'HEADLESS_CONTINUATION_CONTRACT_V6'* ]] &&
		[[ "$output" == *'Read the issue body FIRST'* ]] &&
		[[ "$output" == *'Look for a "Worker Guidance" or "How" section'* ]] &&
		[[ "$output" == *'Never ask for user confirmation, approval, or next steps. No user will respond.'* ]] &&
		[[ "$output" == *'The only valid exit states are FULL_LOOP_COMPLETE or BLOCKED with evidence.'* ]]; then
		print_result "appends escalation-before-blocked contract to full-loop prompts" 0
		return 0
	fi

	print_result "appends escalation-before-blocked contract to full-loop prompts" 1 "Output missing required contract clauses"
	return 0
}

test_non_full_loop_prompt_unchanged() {
	local prompt='Review this file only'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "leaves non-full-loop prompt unchanged" 0
		return 0
	fi

	print_result "leaves non-full-loop prompt unchanged" 1 "Prompt was unexpectedly modified"
	return 0
}

test_does_not_double_append() {
	local prompt='/full-loop Continue issue #14964

[HEADLESS_CONTINUATION_CONTRACT_V6]
This worker run is unattended.'
	local output
	output=$(append_worker_headless_contract "$prompt")

	if [[ "$output" == "$prompt" ]]; then
		print_result "does not double-append existing contract" 0
		return 0
	fi

	print_result "does not double-append existing contract" 1 "Existing contract was modified"
	return 0
}

test_extract_session_id_from_output_returns_latest_session_id() {
	local output_file="${TEST_ROOT}/opencode-output.jsonl"
	cat >"$output_file" <<'EOF'
not-json
{"type":"message","sessionID":"ses_early"}
{"type":"tool_use","part":{"sessionID":"ses_latest"}}
EOF

	local session_id
	session_id=$(extract_session_id_from_output "$output_file")

	if [[ "$session_id" == "ses_latest" ]]; then
		print_result "extract_session_id_from_output returns latest session id" 0
		return 0
	fi

	print_result "extract_session_id_from_output returns latest session id" 1 "Expected ses_latest, got ${session_id:-<empty>}"
	return 0
}

# Helper: create a bare git repo and a feature branch with optional commits.
# Each call uses work_dir-derived remote path to avoid inter-test collisions.
# Args: $1 = work_dir path, $2 = 1 to add a commit (0 for none)
_setup_test_git_repo() {
	local work_dir="$1"
	local add_commit="${2:-0}"
	mkdir -p "$work_dir"
	git -C "$work_dir" init -q
	git -C "$work_dir" config user.email "test@test.local"
	git -C "$work_dir" config user.name "Test"
	# Create initial commit on main so origin/main reference exists
	touch "$work_dir/README.md"
	git -C "$work_dir" add README.md
	git -C "$work_dir" commit -q -m "init"
	git -C "$work_dir" branch -M main
	# Create remote stub unique to this repo (bare repo alongside work_dir)
	local remote_dir="${work_dir}.remote.git"
	git init -q --bare "$remote_dir"
	git -C "$work_dir" remote add origin "$remote_dir"
	git -C "$work_dir" push -q origin main
	# Switch to feature branch
	git -C "$work_dir" checkout -q -b "feature/auto-test-issue-99999"
	if [[ "$add_commit" -eq 1 ]]; then
		echo "change" >"$work_dir/change.txt"
		git -C "$work_dir" add change.txt
		git -C "$work_dir" commit -q -m "feat: add change"
	fi
	return 0
}

test_worker_produced_output_no_commits_returns_false() {
	local work_dir="${TEST_ROOT}/repo-no-commits"
	_setup_test_git_repo "$work_dir" 0
	# No gh available in test env, no DISPATCH_REPO_SLUG set — signal 3 skipped
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	if ! _worker_produced_output "issue-99999" "$work_dir"; then
		print_result "_worker_produced_output returns false with zero commits" 0
	else
		print_result "_worker_produced_output returns false with zero commits" 1 \
			"Expected false (no output) but got true"
	fi
	return 0
}

test_worker_produced_output_with_commits_returns_true() {
	local work_dir="${TEST_ROOT}/repo-with-commits"
	_setup_test_git_repo "$work_dir" 1

	if _worker_produced_output "issue-99999" "$work_dir"; then
		print_result "_worker_produced_output returns true with commits" 0
	else
		print_result "_worker_produced_output returns true with commits" 1 \
			"Expected true (has output) but got false"
	fi
	return 0
}

test_worker_produced_output_non_worker_session_returns_true() {
	local work_dir="${TEST_ROOT}/repo-pulse"
	_setup_test_git_repo "$work_dir" 0

	# Non-worker session keys (pulse, triage) must always return true (fail-open)
	if _worker_produced_output "pulse-main" "$work_dir"; then
		print_result "_worker_produced_output returns true for non-worker session" 0
	else
		print_result "_worker_produced_output returns true for non-worker session" 1 \
			"Non-worker session should always return true (fail-open)"
	fi
	return 0
}

test_worker_produced_output_invalid_workdir_returns_true() {
	# Missing / non-git work_dir must fail-open
	if _worker_produced_output "issue-99999" "/nonexistent/path/$$"; then
		print_result "_worker_produced_output returns true for invalid work_dir (fail-open)" 0
	else
		print_result "_worker_produced_output returns true for invalid work_dir (fail-open)" 1 \
			"Invalid work_dir should fail-open and return true"
	fi
	return 0
}

test_worker_produced_output_pushed_branch_returns_true() {
	local work_dir="${TEST_ROOT}/repo-pushed"
	_setup_test_git_repo "$work_dir" 0
	# Push the feature branch (no additional commits, but branch exists on remote)
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"

	if _worker_produced_output "issue-99999" "$work_dir"; then
		print_result "_worker_produced_output returns true for pushed branch" 0
	else
		print_result "_worker_produced_output returns true for pushed branch" 1 \
			"Pushed branch should count as tangible output"
	fi
	return 0
}

test_cmd_run_finish_emits_noop_for_zero_output() {
	local work_dir="${TEST_ROOT}/repo-finish-noop"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	# Stub lifecycle functions to capture what was called
	local released_reason="" fast_fail_reason="" fast_fail_crash=""
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_reason="$2"; fast_fail_crash="$3"; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }

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
	return 0
}

test_cmd_run_finish_emits_complete_for_real_output() {
	local work_dir="${TEST_ROOT}/repo-finish-complete"
	_setup_test_git_repo "$work_dir" 1
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }

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
	return 0
}

test_cmd_run_finish_emits_complete_when_no_workdir() {
	# When work_dir is absent (fail paths), behaviour is unchanged: worker_complete
	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }

	_cmd_run_finish "issue-99999" "complete"

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete when no work_dir provided" 0
	else
		print_result "_cmd_run_finish emits worker_complete when no work_dir provided" 1 \
			"Expected worker_complete (fail-open), got '${released_reason}'"
	fi
	return 0
}

main() {
	setup_test_env
	test_appends_escalation_contract
	test_non_full_loop_prompt_unchanged
	test_does_not_double_append
	test_extract_session_id_from_output_returns_latest_session_id
	test_worker_produced_output_no_commits_returns_false
	test_worker_produced_output_with_commits_returns_true
	test_worker_produced_output_non_worker_session_returns_true
	test_worker_produced_output_invalid_workdir_returns_true
	test_worker_produced_output_pushed_branch_returns_true
	test_cmd_run_finish_emits_noop_for_zero_output
	test_cmd_run_finish_emits_complete_for_real_output
	test_cmd_run_finish_emits_complete_when_no_workdir
	teardown_test_env

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi

	return 1
}

main "$@"
