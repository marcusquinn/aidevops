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

test_worker_produced_output_no_commits_returns_noop() {
	local work_dir="${TEST_ROOT}/repo-no-commits"
	_setup_test_git_repo "$work_dir" 0
	# No gh available in test env, no DISPATCH_REPO_SLUG set — signal 3 skipped
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "noop" ]]; then
		print_result "_worker_produced_output returns 'noop' with zero commits" 0
	else
		print_result "_worker_produced_output returns 'noop' with zero commits" 1 \
			"Expected 'noop' but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_with_commits_returns_pr_exists_failopen() {
	# Commits present but no DISPATCH_REPO_SLUG → cannot confirm PR absence → fail-open (pr_exists)
	local work_dir="${TEST_ROOT}/repo-with-commits"
	_setup_test_git_repo "$work_dir" 1
	unset DISPATCH_REPO_SLUG 2>/dev/null || true

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' with commits (fail-open no slug)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' with commits (fail-open no slug)" 1 \
			"Expected 'pr_exists' (fail-open) but got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_non_worker_session_returns_pr_exists() {
	local work_dir="${TEST_ROOT}/repo-pulse"
	_setup_test_git_repo "$work_dir" 0

	# Non-worker session keys (pulse, triage) must always return pr_exists (fail-open)
	local classification
	classification=$(_worker_produced_output "pulse-main" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for non-worker session" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for non-worker session" 1 \
			"Non-worker session should always return 'pr_exists' (fail-open), got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_invalid_workdir_returns_pr_exists() {
	# Missing / non-git work_dir must fail-open
	local classification
	classification=$(_worker_produced_output "issue-99999" "/nonexistent/path/$$")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for invalid work_dir (fail-open)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for invalid work_dir (fail-open)" 1 \
			"Invalid work_dir should fail-open as 'pr_exists', got '${classification}'"
	fi
	return 0
}

test_worker_produced_output_pushed_branch_no_slug_returns_pr_exists() {
	# Pushed branch but DISPATCH_REPO_SLUG unset → cannot check PR → fail-open (pr_exists)
	local work_dir="${TEST_ROOT}/repo-pushed-noslug"
	_setup_test_git_repo "$work_dir" 0
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' for pushed branch (no slug, fail-open)" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' for pushed branch (no slug, fail-open)" 1 \
			"Expected 'pr_exists' (fail-open, no DISPATCH_REPO_SLUG), got '${classification}'"
	fi
	return 0
}

# AC#2: pushed branch + confirmed no PR → branch_orphan
test_worker_produced_output_branch_no_pr_returns_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-orphan"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	# Set DISPATCH_REPO_SLUG and stub gh to return 0 PRs
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() { printf '0'; return 0; }

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "branch_orphan" ]]; then
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 0
	else
		print_result "_worker_produced_output returns 'branch_orphan' (commits + branch, no PR)" 1 \
			"Expected 'branch_orphan' but got '${classification}'"
	fi
	return 0
}

# AC#2 variant: PR confirmed → pr_exists even when branch is pushed
test_worker_produced_output_branch_with_pr_returns_pr_exists() {
	local work_dir="${TEST_ROOT}/repo-pr-exists"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"
	gh() { printf '1'; return 0; }  # Stub gh: 1 PR found

	local classification
	classification=$(_worker_produced_output "issue-99999" "$work_dir")
	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$classification" == "pr_exists" ]]; then
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 0
	else
		print_result "_worker_produced_output returns 'pr_exists' when PR confirmed" 1 \
			"Expected 'pr_exists' but got '${classification}'"
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

# AC#3: orphan-recovery attempts gh pr create with correct args
test_attempt_orphan_recovery_pr_calls_gh_create() {
	local work_dir="${TEST_ROOT}/repo-orphan-recovery"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"

	local gh_head="" gh_base="" gh_repo="" gh_label=""
	local gh_called=0
	gh() {
		# Capture pr create args
		local arg
		for arg in "$@"; do
			case "$_last_flag" in
			"--head") gh_head="$arg" ;;
			"--base") gh_base="$arg" ;;
			"--repo") gh_repo="$arg" ;;
			"--label") gh_label="$arg" ;;
			esac
			_last_flag="$arg"
		done
		gh_called=1
		return 0
	}
	_last_flag=""

	_attempt_orphan_recovery_pr \
		"issue-99999" "$work_dir" "feature/auto-test-issue-99999" "test-owner/test-repo"

	unset -f gh 2>/dev/null || true

	if [[ "$gh_called" -eq 1 ]]; then
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 0
	else
		print_result "_attempt_orphan_recovery_pr calls gh pr create" 1 \
			"gh was not called"
	fi

	if [[ "$gh_head" == "feature/auto-test-issue-99999" ]]; then
		print_result "_attempt_orphan_recovery_pr passes correct --head" 0
	else
		print_result "_attempt_orphan_recovery_pr passes correct --head" 1 \
			"Expected --head=feature/auto-test-issue-99999, got '${gh_head}'"
	fi

	if [[ "$gh_label" == "origin:worker-takeover" ]]; then
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 0
	else
		print_result "_attempt_orphan_recovery_pr passes --label origin:worker-takeover" 1 \
			"Expected --label=origin:worker-takeover, got '${gh_label}'"
	fi

	return 0
}

# AC#4: on auto-PR success, _cmd_run_finish emits worker_complete with orphan note
test_cmd_run_finish_orphan_recovery_success_emits_worker_complete() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-ok"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Stub gh: pr list returns 0 (no PR); pr create succeeds; issue view = OPEN
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then printf '0'
		elif [[ "${*}" == *"issue view"* ]]; then printf 'OPEN'
		elif [[ "${*}" == *"repo view"* ]]; then printf 'main'
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_complete" ]]; then
		print_result "_cmd_run_finish emits worker_complete after successful orphan recovery" 0
	else
		print_result "_cmd_run_finish emits worker_complete after successful orphan recovery" 1 \
			"Expected worker_complete (PR auto-created), got '${released_reason}'"
	fi
	return 0
}

# AC#4: on auto-PR failure, _cmd_run_finish emits worker_branch_orphan
test_cmd_run_finish_orphan_recovery_failure_emits_branch_orphan() {
	local work_dir="${TEST_ROOT}/repo-finish-orphan-fail"
	_setup_test_git_repo "$work_dir" 1
	git -C "$work_dir" push -q origin "feature/auto-test-issue-99999"
	DISPATCH_REPO_SLUG="test-owner/test-repo"

	# Stub gh: pr list returns 0, issue view = OPEN, pr create FAILS
	gh() {
		if [[ "${*}" == *"pr list"* ]]; then
			printf '0'
			return 0
		elif [[ "${*}" == *"issue view"* ]]; then
			printf 'OPEN'
			return 0
		elif [[ "${*}" == *"repo view"* ]]; then
			printf 'main'
			return 0
		elif [[ "${*}" == *"pr create"* ]]; then
			return 1  # Simulate pr create failure
		fi
		return 0
	}

	local released_reason="" fast_fail_called=0
	_release_dispatch_claim() { released_reason="$2"; return 0; }
	_report_failure_to_fast_fail() { fast_fail_called=1; return 0; }
	_update_dispatch_ledger() { return 0; }
	_release_session_lock() { return 0; }
	_increment_orphan_count_stat() { return 0; }

	_cmd_run_finish "issue-99999" "complete" "$work_dir"

	unset DISPATCH_REPO_SLUG 2>/dev/null || true
	unset -f gh 2>/dev/null || true

	if [[ "$released_reason" == "worker_branch_orphan" ]]; then
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 0
	else
		print_result "_cmd_run_finish emits worker_branch_orphan when PR creation fails" 1 \
			"Expected worker_branch_orphan (PR create failed), got '${released_reason}'"
	fi
	return 0
}

main() {
	setup_test_env
	test_appends_escalation_contract
	test_non_full_loop_prompt_unchanged
	test_does_not_double_append
	test_extract_session_id_from_output_returns_latest_session_id
	# Classification tests (GH#20819 refactor of _worker_produced_output)
	test_worker_produced_output_no_commits_returns_noop
	test_worker_produced_output_with_commits_returns_pr_exists_failopen
	test_worker_produced_output_non_worker_session_returns_pr_exists
	test_worker_produced_output_invalid_workdir_returns_pr_exists
	test_worker_produced_output_pushed_branch_no_slug_returns_pr_exists
	test_worker_produced_output_branch_no_pr_returns_branch_orphan
	test_worker_produced_output_branch_with_pr_returns_pr_exists
	# _cmd_run_finish integration tests
	test_cmd_run_finish_emits_noop_for_zero_output
	test_cmd_run_finish_emits_complete_for_real_output
	test_cmd_run_finish_emits_complete_when_no_workdir
	# Orphan recovery tests (GH#20819)
	test_attempt_orphan_recovery_pr_calls_gh_create
	test_cmd_run_finish_orphan_recovery_success_emits_worker_complete
	test_cmd_run_finish_orphan_recovery_failure_emits_branch_orphan
	teardown_test_env

	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Failures: %d\n' "$TESTS_FAILED"

	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi

	return 1
}

main "$@"
