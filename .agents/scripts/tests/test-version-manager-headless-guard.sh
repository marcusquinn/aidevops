#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for version-manager.sh headless task-worker release guard.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

reset_guard_env() {
	unset AIDEVOPS_HEADLESS FULL_LOOP_HEADLESS OPENCODE_HEADLESS HEADLESS
	unset WORKER_TASK_NUMBER WORKER_ISSUE_NUMBER WORKER_SESSION_KEY AIDEVOPS_SESSION_KEY
	unset AIDEVOPS_RELEASE_CONTEXT_APPROVED VERSION_MANAGER_RELEASE_CONTEXT_APPROVED AIDEVOPS_TASK_SCOPE
	unset AIDEVOPS_RELEASE_INTENT_TRUSTED AIDEVOPS_TRUSTED_ISSUE_PRIORITY
	unset AIDEVOPS_SESSION_TITLE WORKER_SESSION_TITLE
	return 0
}

# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/version-manager.sh"
set +e

reset_guard_env
export AIDEVOPS_HEADLESS=false WORKER_ISSUE_NUMBER=24089
rc=0
_version_manager_is_headless_task_worker >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result 'headless guard rejects false marker strings' 0
else
	print_result 'headless guard rejects false marker strings' 1 'expected non-zero rc for AIDEVOPS_HEADLESS=false'
fi

reset_guard_env
export AIDEVOPS_HEADLESS=1 WORKER_TASK_NUMBER=123
rc=0
_version_manager_is_headless_task_worker >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result 'headless guard accepts explicit task workers' 0
else
	print_result 'headless guard accepts explicit task workers' 1 "rc=$rc"
fi

reset_guard_env
export FULL_LOOP_HEADLESS=true WORKER_SESSION_KEY='TASK-123'
rc=0
_version_manager_is_headless_task_worker >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result 'headless guard matches task session keys case-insensitively' 0
else
	print_result 'headless guard matches task session keys case-insensitively' 1 "rc=$rc"
fi

reset_guard_env
export AIDEVOPS_HEADLESS=false FULL_LOOP_HEADLESS=0 OPENCODE_HEADLESS=True WORKER_ISSUE_NUMBER=24089
rc=0
_version_manager_is_headless_task_worker >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result 'headless guard accepts mixed-case truthy markers' 0
else
	print_result 'headless guard accepts mixed-case truthy markers' 1 "rc=$rc"
fi

reset_guard_env
export OPENCODE_HEADLESS=1 WORKER_SESSION_KEY='ISSUE-24089'
rc=0
_version_manager_is_headless_task_worker >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result 'headless guard preserves issue session key compatibility' 0
else
	print_result 'headless guard preserves issue session key compatibility' 1 "rc=$rc"
fi

reset_guard_env
export AIDEVOPS_HEADLESS=1 WORKER_TASK_NUMBER=123
rc=0
_version_manager_guard_headless_release_scope help >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result 'help remains allowed for headless task workers' 0
else
	print_result 'help remains allowed for headless task workers' 1 "rc=$rc"
fi

reset_guard_env
export AIDEVOPS_HEADLESS=1 WORKER_TASK_NUMBER=123 WORKER_SESSION_KEY='task-123'
output=$(_version_manager_guard_headless_release_scope bump 2>&1)
rc=$?
if [[ "$rc" -ne 0 && "$output" == *"Task worker: 123"* && "$output" == *"repo: ${REPO_ROOT}"* && "$output" == *"session: task-123"* ]]; then
	print_result 'blocked writes include task, repo, session diagnostics' 0
else
	print_result 'blocked writes include task, repo, session diagnostics' 1 "rc=$rc output=$output"
fi

reset_guard_env
original_repo_root="$REPO_ROOT"
REPO_ROOT="${TMPDIR:-/tmp}/aidevops-version-manager-missing-repo-root-$$"
branch_name=$(_version_manager_current_branch_name)
REPO_ROOT="$original_repo_root"
if [[ "$branch_name" == "unknown" ]]; then
	print_result 'branch lookup falls back when repo root is not a git worktree' 0
else
	print_result 'branch lookup falls back when repo root is not a git worktree' 1 "branch_name=$branch_name"
fi

for priority in low medium ''; do
	reset_guard_env
	export AIDEVOPS_HEADLESS=1 WORKER_ISSUE_NUMBER=24089 AIDEVOPS_RELEASE_INTENT_TRUSTED=1
	export AIDEVOPS_TRUSTED_ISSUE_PRIORITY="$priority"
	rc=0
	_version_manager_has_approved_release_context main >/dev/null 2>&1 || rc=$?
	[[ "$rc" -ne 0 ]] && print_result "worker priority ${priority:-omitted} cannot authorize release" 0 || print_result "worker priority ${priority:-omitted} cannot authorize release" 1
done

for priority in high critical; do
	reset_guard_env
	export AIDEVOPS_HEADLESS=1 WORKER_ISSUE_NUMBER=24089 AIDEVOPS_RELEASE_INTENT_TRUSTED=1
	export AIDEVOPS_TRUSTED_ISSUE_PRIORITY="$priority"
	rc=0
	_version_manager_has_approved_release_context main >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 0 ]] && print_result "worker priority $priority with trusted scope authorizes release" 0 || print_result "worker priority $priority with trusted scope authorizes release" 1 "rc=$rc"
done

reset_guard_env
export AIDEVOPS_RELEASE_INTENT_TRUSTED=1
rc=0
_version_manager_has_approved_release_context main >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] && print_result 'interactive explicit trusted intent authorizes release' 0 || print_result 'interactive explicit trusted intent authorizes release' 1 "rc=$rc"

reset_guard_env
rc=0
_version_manager_guard_headless_release_scope release patch >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && print_result 'interactive generic invocation does not authorize release' 0 || print_result 'interactive generic invocation does not authorize release' 1

reset_guard_env
output=$(main release --dry-run 2>&1)
rc=$?
if [[ "$rc" -eq 0 && "$output" == *"Bump type: patch"* ]]; then
	print_result 'authorized release with omitted type defaults to patch' 0
else
	print_result 'authorized release with omitted type defaults to patch' 1 "rc=$rc output=$output"
fi

reset_guard_env
export AIDEVOPS_HEADLESS=1 WORKER_ISSUE_NUMBER=24089 WORKER_SESSION_KEY='issue-24089' AIDEVOPS_SESSION_TITLE='ordinary issue mentioning release cleanup'
rc=0
_version_manager_guard_headless_release_scope bump >/dev/null 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then
	print_result 'release context denies broad title substring match' 0
else
	print_result 'release context denies broad title substring match' 1 "rc=$rc"
fi

printf '\nTests run: %d, failures: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
