#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _count_impl_commits() and _task_id_in_recent_commits() (t2379).
#
# These helpers form the commit-subject main-commit dedup gate used by
# pulse-dispatch-core.sh to avoid dispatching workers on tasks that have
# already landed on main. They MUST NOT false-positive on planning PR
# merge commits — otherwise a task gets permanently stuck after its
# plan-filing PR merges (root cause of the t2366 r914 task block).
#
# Two fixes are covered here:
#   1. .task-counter is in the planning-only path allowlist. claim-task-id.sh
#      bumps this file on every ID allocation, so every planning PR touches
#      it alongside TODO.md and the brief. Without the allowlist entry,
#      those PRs were misclassified as implementation.
#   2. `chore: mark tNNN complete` is in the subject-prefix exclusion regex.
#      task-complete-helper.sh writes these bookkeeping commits after ANY
#      PR merge via issue-sync.yml. They touch TODO.md only in the canonical
#      case, but the subject filter is belt+braces defense-in-depth.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""

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

# Extract the two functions under test from the core source and eval
# them in the test context. Same pattern as test-pulse-dispatch-core-
# force-dispatch.sh — exercise real code, not a duplicate.
define_helpers_under_test() {
	local count_src task_id_src
	count_src=$(awk '/^_count_impl_commits\(\) \{/,/^}$/ { print }' "$CORE_SCRIPT")
	task_id_src=$(awk '/^_task_id_in_recent_commits\(\) \{/,/^}$/ { print }' "$CORE_SCRIPT")
	if [[ -z "$count_src" || -z "$task_id_src" ]]; then
		printf 'ERROR: could not extract helper functions from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helpers
	eval "$count_src"
	# shellcheck disable=SC1090
	eval "$task_id_src"
	return 0
}

setup_test_repo() {
	TEST_ROOT=$(mktemp -d)
	local repo_path="${TEST_ROOT}/test-repo"
	mkdir -p "$repo_path"
	git -C "$repo_path" init --quiet
	git -C "$repo_path" config user.email "test@test.local"
	git -C "$repo_path" config user.name "Test User"
	git -C "$repo_path" checkout -b main --quiet 2>/dev/null || true

	printf 'initial\n' >"${repo_path}/README.md"
	git -C "$repo_path" add README.md
	git -C "$repo_path" commit -m "initial commit" --quiet

	local remote_path="${TEST_ROOT}/remote.git"
	git init --bare "$remote_path" --quiet
	git -C "$repo_path" remote add origin "$remote_path"
	git -C "$repo_path" push origin main --quiet 2>/dev/null

	export TEST_REPO_PATH="$repo_path"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	return 0
}

teardown_test_repo() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Commit a set of files with a given subject and push to origin.
# Args: $1=repo_path, $2=subject, $3..$N=relative file paths
commit_files_to_main() {
	local repo_path="$1"
	local subject="$2"
	shift 2
	local f
	for f in "$@"; do
		local dir
		dir=$(dirname "${repo_path}/${f}")
		mkdir -p "$dir"
		# Content differs per call so the commit is non-empty even when
		# the same path appears across multiple test fixtures.
		printf 'content-%s\n' "$(date +%s%N)" >"${repo_path}/${f}"
		git -C "$repo_path" add "$f"
	done
	git -C "$repo_path" commit -m "$subject" --quiet
	git -C "$repo_path" push origin main --quiet 2>/dev/null
	return 0
}

# ── _count_impl_commits path-allowlist tests ──────────────────────────

test_task_counter_alone_is_planning() {
	setup_test_repo
	commit_files_to_main "$TEST_REPO_PATH" "chore: claim task IDs" ".task-counter"

	local commit_hash
	commit_hash=$(git -C "$TEST_REPO_PATH" rev-parse HEAD)

	local count
	count=$(printf '%s\n' "$commit_hash" | _count_impl_commits "$TEST_REPO_PATH")
	if [[ "$count" == "0" ]]; then
		print_result ".task-counter-only commit classified as planning (t2379)" 0
	else
		print_result ".task-counter-only commit classified as planning (t2379)" 1 \
			"Expected count 0, got ${count}"
	fi
	teardown_test_repo
	return 0
}

test_task_counter_with_todo_and_brief_is_planning() {
	setup_test_repo
	commit_files_to_main "$TEST_REPO_PATH" "t2366: plan r914 routine" \
		".task-counter" "TODO.md" "todo/tasks/t2366-brief.md"

	local commit_hash
	commit_hash=$(git -C "$TEST_REPO_PATH" rev-parse HEAD)

	local count
	count=$(printf '%s\n' "$commit_hash" | _count_impl_commits "$TEST_REPO_PATH")
	if [[ "$count" == "0" ]]; then
		print_result "planning PR (TODO+brief+.task-counter) classified as planning (t2379 root cause)" 0
	else
		print_result "planning PR (TODO+brief+.task-counter) classified as planning (t2379 root cause)" 1 \
			"Expected count 0, got ${count} — this is the t2366 regression"
	fi
	teardown_test_repo
	return 0
}

test_task_counter_with_code_is_impl() {
	# Regression guard: adding .task-counter to the allowlist must NOT
	# cause commits touching .task-counter + real code to slip through.
	setup_test_repo
	commit_files_to_main "$TEST_REPO_PATH" "t153: implement feature" \
		".task-counter" "TODO.md" ".agents/scripts/new-helper.sh"

	local commit_hash
	commit_hash=$(git -C "$TEST_REPO_PATH" rev-parse HEAD)

	local count
	count=$(printf '%s\n' "$commit_hash" | _count_impl_commits "$TEST_REPO_PATH")
	if [[ "$count" == "1" ]]; then
		print_result "commit with real code + .task-counter still classified as impl" 0
	else
		print_result "commit with real code + .task-counter still classified as impl" 1 \
			"Expected count 1, got ${count} — .task-counter allowlist entry is leaking"
	fi
	teardown_test_repo
	return 0
}

test_todo_only_is_planning() {
	# Pre-existing behaviour — must still hold after the .task-counter addition.
	setup_test_repo
	commit_files_to_main "$TEST_REPO_PATH" "chore: mark t153 complete" "TODO.md"

	local commit_hash
	commit_hash=$(git -C "$TEST_REPO_PATH" rev-parse HEAD)

	local count
	count=$(printf '%s\n' "$commit_hash" | _count_impl_commits "$TEST_REPO_PATH")
	if [[ "$count" == "0" ]]; then
		print_result "TODO.md-only commit classified as planning (pre-existing behaviour preserved)" 0
	else
		print_result "TODO.md-only commit classified as planning (pre-existing behaviour preserved)" 1 \
			"Expected count 0, got ${count}"
	fi
	teardown_test_repo
	return 0
}

# ── _task_id_in_recent_commits subject-filter tests ────────────────────

test_chore_mark_complete_excluded_by_subject_filter() {
	# Defense in depth: task-complete-helper.sh bookkeeping commits should
	# never count as implementation regardless of what files they touch.
	# Simulate a pathological case where the bookkeeping commit somehow
	# gained a code-file touch — subject filter must still exclude it.
	setup_test_repo
	# Give the commit a subject the filter should reject AND code paths
	# that would otherwise make _count_impl_commits classify it as impl.
	commit_files_to_main "$TEST_REPO_PATH" \
		"chore: mark t2366 complete (pr:#19819 completed:2026-04-19) [skip ci]" \
		".agents/scripts/rogue-file.sh"

	# created_at far in the past so all test commits are in range.
	local result=1
	if _task_id_in_recent_commits "t2366: r914 routine" "$TEST_REPO_PATH" "2020-01-01T00:00:00Z"; then
		result=1
	else
		result=0
	fi
	print_result "chore: mark tNNN complete excluded by subject filter (defense-in-depth)" "$result" \
		"Expected return 1 (not committed) — subject filter must exclude bookkeeping commits"
	teardown_test_repo
	return 0
}

test_chore_claim_excluded_by_subject_filter() {
	# Pre-existing behaviour — must still hold.
	setup_test_repo
	commit_files_to_main "$TEST_REPO_PATH" \
		"chore: claim t2379 via CAS" ".task-counter"

	local result=1
	if _task_id_in_recent_commits "t2379: fix planning filter" "$TEST_REPO_PATH" "2020-01-01T00:00:00Z"; then
		result=1
	else
		result=0
	fi
	print_result "chore: claim excluded by subject filter (pre-existing)" "$result"
	teardown_test_repo
	return 0
}

test_planning_pr_squash_commit_does_not_false_positive() {
	# Full integration test: a planning PR squash-merge touching
	# TODO.md + brief + .task-counter with a `tNNN: plan ...` subject
	# must NOT trigger _task_id_in_recent_commits. This is the exact
	# shape that blocked t2366 dispatch (commit 10321cb36).
	setup_test_repo
	commit_files_to_main "$TEST_REPO_PATH" \
		"t2366: plan r914 daily repo-aidevops-health-keeper routine (#19819)" \
		".task-counter" "TODO.md" "todo/tasks/t2366-brief.md"

	local result=1
	if _task_id_in_recent_commits "t2366: r914 repo-aidevops-health" "$TEST_REPO_PATH" "2020-01-01T00:00:00Z"; then
		result=1
	else
		result=0
	fi
	print_result "planning PR squash commit does not false-positive (t2366 root cause reproduction)" "$result" \
		"Expected return 1 — this commit shape permanently blocked t2366 dispatch"
	teardown_test_repo
	return 0
}

test_real_impl_pr_squash_commit_detected() {
	# Positive case: an actual implementation PR MUST still be detected.
	# The fix must not make the dedup too permissive.
	setup_test_repo
	commit_files_to_main "$TEST_REPO_PATH" \
		"t2366: implement r914 daily routine (#19900)" \
		"TODO.md" ".agents/scripts/repo-aidevops-health-helper.sh"

	local result=1
	if _task_id_in_recent_commits "t2366: r914 repo-aidevops-health" "$TEST_REPO_PATH" "2020-01-01T00:00:00Z"; then
		result=0
	else
		result=1
	fi
	print_result "real implementation PR still detected (regression guard)" "$result" \
		"Expected return 0 — dedup must still block redundant impl dispatches"
	teardown_test_repo
	return 0
}

# ── Run all tests ──────────────────────────────────────────────────────

main() {
	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_task_counter_alone_is_planning
	test_task_counter_with_todo_and_brief_is_planning
	test_task_counter_with_code_is_impl
	test_todo_only_is_planning
	test_chore_mark_complete_excluded_by_subject_filter
	test_chore_claim_excluded_by_subject_filter
	test_planning_pr_squash_commit_does_not_false_positive
	test_real_impl_pr_squash_commit_detected

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
