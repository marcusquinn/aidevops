#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-version-manager-task-id-extraction.sh — GH#22119 regression guard.
#
# Asserts that release task auto-mark extraction handles task IDs wider than the
# historical three-digit shape, while preserving dotted-subtask extraction.

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

assert_lines_equal() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "expected [$expected], got [$actual]"
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO_DIR="${TEST_ROOT}/repo"
mkdir -p "$REPO_DIR"
cd "$REPO_DIR" || exit 1

git init -q -b main
git config user.email 'test@example.com'
git config user.name 'Test Runner'
git config commit.gpgsign false
git config tag.gpgSign false

printf 'initial\n' >README.md
git add README.md
git commit -q -m 'initial commit'
git tag -m 'Release v0.0.1' v0.0.1

printf 'work\n' >work.txt
git add work.txt
git commit -q -m 'chore: mark t3375 complete (pr:#22116 completed:2026-05-01) [skip ci]'

printf 'scope\n' >>work.txt
git add work.txt
git commit -q -m 'fix(t3376): cover scoped four digit task IDs'

printf 'subtask\n' >>work.txt
git add work.txt
git commit -q -m 'docs(t3377.2): preserve dotted subtask IDs'

printf 'legacy\n' >>work.txt
git add work.txt
git commit -q -m 'complete t123'

printf 'prefix-boundary\n' >>work.txt
git add work.txt
git commit -q -m 'chore: at9876 complete should stay ignored'

printf 'multi-after-keyword\n' >>work.txt
git add work.txt
git commit -q -m 'chore: complete t124 and closes t125'

printf 'multi-before-keyword\n' >>work.txt
git add work.txt
git commit -q -m 'chore: t126 complete and t127 done'

SCRIPT_DIR="$TEST_SCRIPTS_DIR"
REPO_ROOT="$REPO_DIR"
VERSION_FILE="${REPO_DIR}/VERSION"
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/version-manager-git.sh"

actual=$(extract_task_ids_from_commits)
expected=$'t123\nt124\nt125\nt126\nt127\nt3375\nt3376\nt3377.2'
assert_lines_equal 'extract_task_ids_from_commits: supports four digit and dotted task IDs' "$expected" "$actual"

if [[ "$actual" != *$'t337\n'* && "$actual" != "t337" ]]; then
	print_result 'extract_task_ids_from_commits: does not truncate t3375 to t337' 0
else
	print_result 'extract_task_ids_from_commits: does not truncate t3375 to t337' 1 "got [$actual]"
fi

if [[ "$actual" != *"t9876"* ]]; then
	print_result 'extract_task_ids_from_commits: requires leading boundary before Pattern 4 task ID' 0
else
	print_result 'extract_task_ids_from_commits: requires leading boundary before Pattern 4 task ID' 1 "got [$actual]"
fi

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
