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
		|| date -u -d "30 hours ago" +%Y%m%d%H%M 2>/dev/null \
		|| printf '202601010000\n')
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
	grep -q 'recovery_path=none' "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null || rc=1
	print_result "local commits/no PR skip without safety proof" "$rc" \
		"cleanup_rc=$cleanup_rc log=$(cat "$AIDEVOPS_CLEANUP_LOG" 2>/dev/null)"
	return 0
}

TEST_ROOT=$(mktemp -d)
trap teardown EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

echo "=== test-pulse-cleanup-worker-owned-no-pr.sh ==="
test_recent_metric_blocks_local_commit_no_pr_removal
test_local_commit_no_pr_skips_without_recent_metric

echo ""
echo "Results: $((TESTS_RUN - TESTS_FAILED))/${TESTS_RUN} passed, ${TESTS_FAILED} failed."

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
