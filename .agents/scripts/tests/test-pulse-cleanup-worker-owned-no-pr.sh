#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23074: pulse orphan cleanup must not permanently remove
# worker-style worktrees that have local commits and no PR while worker ownership
# signals are active/recent.

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULSE_CLEANUP="${SCRIPT_DIR}/../pulse-cleanup.sh"

print_result() {
	local name="$1"
	local rc="$2"
	local extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s %s\n' "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

teardown() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

setup_repo_with_worker_worktree() {
	local repo_dir="$1"
	local wt_path="$2"
	local branch_name="$3"
	local age_spec="${4:-30 hours ago}"

	mkdir -p "$repo_dir"
	(
		cd "$repo_dir" || exit 1
		git init -q -b main
		git config user.email "test@example.invalid"
		git config user.name "Test Worker"
		printf 'base\n' >README.md
		git add README.md
		git commit -q -m "init"
		git worktree add -q -b "$branch_name" "$wt_path" main
	)
	(
		cd "$wt_path" || exit 1
		printf 'worker change\n' >worker.txt
		git add worker.txt
		git commit -q -m "worker commit"
	)
	local old_ts
	old_ts=$(date -u -v-30H +%Y%m%d%H%M 2>/dev/null \
		|| date -u -d "$age_spec" +%Y%m%d%H%M 2>/dev/null \
		|| printf '202601010000\n')
	if [[ "$age_spec" == "8 days ago" ]]; then
		old_ts=$(date -u -v-8d +%Y%m%d%H%M 2>/dev/null \
			|| date -u -d "$age_spec" +%Y%m%d%H%M 2>/dev/null \
			|| printf '202601010000\n')
	fi
	touch -t "$old_ts" "$wt_path/.git"
	return 0
}

source_pulse_cleanup_with_stubs() {
	LOGFILE="${TEST_ROOT}/pulse.log"
	export LOGFILE
	AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup.log"
	export AIDEVOPS_CLEANUP_LOG
	ORPHAN_WORKTREE_GRACE_SECS=1800
	export ORPHAN_WORKTREE_GRACE_SECS

	is_worktree_owned_by_others() { return 1; }
	unregister_worktree() { local wt_path="$1"; : "$wt_path"; return 0; }
	gh() { return 1; }
	gh_pr_list() { return 0; }
	recover_failed_launch_state() { return 0; }
	gh_issue_comment() { return 0; }

	unset _PULSE_CLEANUP_LOADED 2>/dev/null || true
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../portable-stat.sh
	source "${SCRIPT_DIR}/../portable-stat.sh"
	# shellcheck source=../pulse-cleanup.sh
	source "$PULSE_CLEANUP"
	return 0
}

test_closed_issue_local_commit_no_pr_removes_before_age_threshold() {
	local repo_dir="${TEST_ROOT}/repo-closed-issue"
	local wt_path="${TEST_ROOT}/worker-wt-closed-issue"
	local branch_name="feature/auto-20260507-190804-gh23077"
	setup_repo_with_worker_worktree "$repo_dir" "$wt_path" "$branch_name" || return 1
	source_pulse_cleanup_with_stubs || return 1
	gh() {
		if [[ "${1:-}" == "issue" && "${2:-}" == "view" && "${3:-}" == "23077" ]]; then
			printf '%s\n' "CLOSED"
			return 0
		fi
		return 1
	}

	local now_epoch
	now_epoch=$(date +%s)
	AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/missing-closed-issue-metrics.jsonl"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local branch_exists=1
	git -C "$repo_dir" rev-parse --verify "refs/heads/${branch_name}" >/dev/null 2>&1 && branch_exists=0

	local rc=0
	[[ "$cleanup_rc" -eq 0 ]] || rc=1
	[[ ! -d "$wt_path" ]] || rc=1
	[[ "$branch_exists" -eq 0 ]] || rc=1
	grep -q 'worktree-removed.*local-commits-branch-preserved.*mode=branch-preserved' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'recovery_path=branch-preserved-closed-issue' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "closed issue local commits/no PR archives before age threshold" "$rc" \
		"cleanup_rc=$cleanup_rc branch_exists=$branch_exists log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_closed_pr_reference_local_commit_no_pr_removes_before_age_threshold() {
	local repo_dir="${TEST_ROOT}/repo-closed-pr-ref"
	local wt_path="${TEST_ROOT}/worker-wt-closed-pr-ref"
	local branch_name="repair/pr-23078-followup"
	setup_repo_with_worker_worktree "$repo_dir" "$wt_path" "$branch_name" || return 1
	source_pulse_cleanup_with_stubs || return 1
	gh() {
		if [[ "${1:-}" == "pr" && "${2:-}" == "view" && "${3:-}" == "23078" ]]; then
			printf '%s\n' "CLOSED"
			return 0
		fi
		return 1
	}

	local now_epoch
	now_epoch=$(date +%s)
	AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/missing-closed-pr-metrics.jsonl"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local branch_exists=1
	git -C "$repo_dir" rev-parse --verify "refs/heads/${branch_name}" >/dev/null 2>&1 && branch_exists=0

	local rc=0
	[[ "$cleanup_rc" -eq 0 ]] || rc=1
	[[ ! -d "$wt_path" ]] || rc=1
	[[ "$branch_exists" -eq 0 ]] || rc=1
	grep -q 'worktree-removed.*local-commits-branch-preserved.*mode=branch-preserved' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'pr_state=pr-CLOSED' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'recovery_path=branch-preserved-closed-pr-23078' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "closed PR reference local commits/no PR archives before age threshold" "$rc" \
		"cleanup_rc=$cleanup_rc branch_exists=$branch_exists log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_recent_metric_blocks_local_commit_no_pr_removal() {
	local repo_dir="${TEST_ROOT}/repo"
	local wt_path="${TEST_ROOT}/worker-wt"
	local branch_name="feature/auto-20260507-190801-gh23074"
	setup_repo_with_worker_worktree "$repo_dir" "$wt_path" "$branch_name" || return 1
	source_pulse_cleanup_with_stubs || return 1

	local now_epoch
	now_epoch=$(date +%s)
	local metrics_file="${TEST_ROOT}/headless-runtime-metrics.jsonl"
	printf '{"ts":%s,"issue_number":23074,"session_key":"issue-23074","result":"watchdog_stall_continue"}\n' "$now_epoch" >"$metrics_file"
	AIDEVOPS_HEADLESS_METRICS_FILE="$metrics_file"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 1 ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	grep -q 'worktree-skipped.*active-worker-metric.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'recent_session_guard=active' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'commits=1' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "recent metric blocks local commits/no PR permanent cleanup" "$rc" \
		"cleanup_rc=$cleanup_rc log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_local_commit_no_pr_skips_without_recent_metric() {
	local repo_dir="${TEST_ROOT}/repo-no-metric"
	local wt_path="${TEST_ROOT}/worker-wt-no-metric"
	local branch_name="feature/auto-20260507-190802-gh23075"
	setup_repo_with_worker_worktree "$repo_dir" "$wt_path" "$branch_name" || return 1
	source_pulse_cleanup_with_stubs || return 1

	local now_epoch
	now_epoch=$(date +%s)
	AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/missing-metrics.jsonl"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 1 ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	grep -q 'worktree-skipped.*local-commits-no-pr.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'owner_guard=clear' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'process_guard=clear' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'pr_state=none' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'recovery_path=branch-preserved-after-' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "local commits/no PR skip without safety proof" "$rc" \
		"cleanup_rc=$cleanup_rc log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_young_local_commit_logs_not_age_eligible() {
	local repo_dir="${TEST_ROOT}/repo-young-local-commit"
	local wt_path="${TEST_ROOT}/worker-wt-young-local-commit"
	local branch_name="feature/auto-20260507-190805-gh23079"
	setup_repo_with_worker_worktree "$repo_dir" "$wt_path" "$branch_name" || return 1
	source_pulse_cleanup_with_stubs || return 1
	touch "$wt_path/.git"

	local now_epoch
	now_epoch=$(date +%s)
	AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/missing-young-metrics.jsonl"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 1 ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	grep -q 'worktree-skipped.*not-age-eligible.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'pr_state=not-eligible' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'commits=1' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "young local commit logs not-age-eligible skip" "$rc" \
		"cleanup_rc=$cleanup_rc log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_local_only_repo_worktree_logs_explicit_skip() {
	local repo_dir="${TEST_ROOT}/repo-local-only"
	local wt_path="${TEST_ROOT}/worker-wt-local-only"
	local branch_name="chore/aidevops-init"
	setup_repo_with_worker_worktree "$repo_dir" "$wt_path" "$branch_name" || return 1
	source_pulse_cleanup_with_stubs || return 1
	printf 'local init artifact\n' >"$wt_path/.aidevops.json"
	mkdir -p "${HOME}/.config/aidevops"
	cat >"${HOME}/.config/aidevops/repos.json" <<JSON
{"initialized_repos":[{"slug":"testowner/local-only","path":"${repo_dir}","local_only":true}]}
JSON

	cleanup_worktrees >/dev/null 2>&1
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 0 ]] || rc=1
	[[ -d "$wt_path" ]] || rc=1
	grep -q 'worktree-skipped.*local-only-repo.*mode=skipped' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "local-only repo worktree logs explicit skip" "$rc" \
		"cleanup_rc=$cleanup_rc log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_stale_local_commit_no_pr_removes_worktree_preserves_branch() {
	local repo_dir="${TEST_ROOT}/repo-stale-local-commit"
	local wt_path="${TEST_ROOT}/worker-wt-stale-local-commit"
	local branch_name="feature/auto-20260507-190803-gh23076"
	setup_repo_with_worker_worktree "$repo_dir" "$wt_path" "$branch_name" "8 days ago" || return 1
	source_pulse_cleanup_with_stubs || return 1

	local now_epoch
	now_epoch=$(date +%s)
	AIDEVOPS_HEADLESS_METRICS_FILE="${TEST_ROOT}/missing-stale-metrics.jsonl"
	export AIDEVOPS_HEADLESS_METRICS_FILE

	_cleanup_single_worktree "$repo_dir" "$wt_path" "$branch_name" "$now_epoch" "testowner/testrepo" "main" >/dev/null 2>&1
	local cleanup_rc=$?

	local branch_exists=1
	git -C "$repo_dir" rev-parse --verify "refs/heads/${branch_name}" >/dev/null 2>&1 && branch_exists=0

	local rc=0
	[[ "$cleanup_rc" -eq 0 ]] || rc=1
	[[ ! -d "$wt_path" ]] || rc=1
	[[ "$branch_exists" -eq 0 ]] || rc=1
	grep -q 'worktree-removed.*local-commits-branch-preserved.*mode=branch-preserved' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	grep -q 'recovery_path=branch-preserved' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "stale local commits/no PR removes folder while preserving branch" "$rc" \
		"cleanup_rc=$cleanup_rc branch_exists=$branch_exists log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

test_no_newline_pr_output_blocks_local_commit_cleanup() {
	source_pulse_cleanup_with_stubs || return 1
	gh_pr_list() { printf '42'; return 0; }

	local reason=""
	reason=$(_evaluate_worktree_removal 1 0 $((25 * 3600)) "feature/has-pr" "testowner/testrepo" 2>/dev/null)
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 1 ]] || rc=1
	[[ -z "$reason" ]] || rc=1
	print_result "no-newline PR output blocks local-commit no-PR cleanup" "$rc" \
		"cleanup_rc=$cleanup_rc reason=$reason"
	return 0
}

test_no_newline_open_pr_output_blocks_clean_fastpath() {
	source_pulse_cleanup_with_stubs || return 1
	gh_pr_list() { printf '42'; return 0; }

	local reason=""
	reason=$(_evaluate_worktree_removal 0 0 3600 "feature/open-pr" "testowner/testrepo" 2>/dev/null)
	local cleanup_rc=$?

	local rc=0
	[[ "$cleanup_rc" -eq 1 ]] || rc=1
	[[ -z "$reason" ]] || rc=1
	print_result "no-newline open PR output blocks clean fast-path cleanup" "$rc" \
		"cleanup_rc=$cleanup_rc reason=$reason"
	return 0
}

test_branch_pr_lookup_uses_null_safe_jq_filter() {
	source_pulse_cleanup_with_stubs || return 1
	local captured_args_file="${TEST_ROOT}/gh-pr-list-args.txt"
	gh_pr_list() {
		local args="$*"
		printf '%s' "$args" >"$captured_args_file"
		return 0
	}

	_pc_branch_has_pr "testowner/testrepo" "feature/missing-number" "open" >/dev/null
	local lookup_rc=$?
	local captured_args=""
	captured_args=$(<"$captured_args_file") || captured_args=""

	local rc=0
	[[ "$lookup_rc" -eq 1 ]] || rc=1
	[[ "$captured_args" == *".[].number // empty"* ]] || rc=1
	print_result "branch PR lookup uses null-safe jq fallback" "$rc" \
		"lookup_rc=$lookup_rc args=$captured_args"
	return 0
}

test_branch_pr_lookup_treats_null_pr_number_as_no_pr() {
	source_pulse_cleanup_with_stubs || return 1
	gh_pr_list() {
		local args="$*"
		if [[ "$args" == *".[].number // empty"* ]]; then
			return 0
		fi
		printf 'null'
		return 0
	}

	_pc_branch_has_pr "testowner/testrepo" "feature/null-number" "open" >/dev/null
	local lookup_rc=$?

	local rc=0
	[[ "$lookup_rc" -eq 1 ]] || rc=1
	print_result "branch PR lookup treats null PR number as no PR" "$rc" \
		"lookup_rc=$lookup_rc"
	return 0
}

TEST_ROOT=$(mktemp -d)
trap teardown EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

echo "=== test-pulse-cleanup-worker-owned-no-pr.sh ==="
test_recent_metric_blocks_local_commit_no_pr_removal
test_local_commit_no_pr_skips_without_recent_metric
test_young_local_commit_logs_not_age_eligible
test_local_only_repo_worktree_logs_explicit_skip
test_closed_issue_local_commit_no_pr_removes_before_age_threshold
test_closed_pr_reference_local_commit_no_pr_removes_before_age_threshold
test_stale_local_commit_no_pr_removes_worktree_preserves_branch
test_no_newline_pr_output_blocks_local_commit_cleanup
test_no_newline_open_pr_output_blocks_clean_fastpath
test_branch_pr_lookup_uses_null_safe_jq_filter
test_branch_pr_lookup_treats_null_pr_number_as_no_pr

echo ""
echo "Results: $((TESTS_RUN - TESTS_FAILED))/${TESTS_RUN} passed, ${TESTS_FAILED} failed."

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
