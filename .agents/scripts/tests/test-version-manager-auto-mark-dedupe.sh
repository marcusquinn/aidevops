#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-version-manager-auto-mark-dedupe.sh — GH#22655 regression guard.
#
# Asserts that release task auto-marking collapses duplicate completed TODO.md
# entries for the same task ID instead of preserving release-sync duplicates.

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

assert_count() {
	local name="$1" expected="$2" pattern="$3" file="$4"
	local actual
	actual=$(grep -Ec "$pattern" "$file" || true)
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

printf 'initial\n' >README.md
git add README.md
git commit -q -m 'initial commit'

SCRIPT_DIR="$TEST_SCRIPTS_DIR"
REPO_ROOT="$REPO_DIR"
VERSION_FILE="${REPO_DIR}/VERSION"
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/version-manager-git.sh"
set +e

TODO_FILE="${REPO_DIR}/TODO.md"
today_short="2026-05-03"

cat >"$TODO_FILE" <<'TODO'
# Tasks

- [ ] t9999 Release auto-mark duplicate prevention #bug
- [x] t9999 Release auto-mark duplicate prevention #bug pr:#123 completed:2026-05-02
- [x] t8888 Already completed duplicate #bug pr:#124 completed:2026-05-02
- [x] t8888 Already completed duplicate #bug pr:#124 completed:2026-05-02
TODO

rc=0
_mark_single_task_complete 't9999' "$TODO_FILE" "$today_short" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result '_mark_single_task_complete: marks unchecked duplicate task' 0
else
	print_result '_mark_single_task_complete: marks unchecked duplicate task' 1 "expected rc=0, got rc=$rc"
fi
assert_count '_mark_single_task_complete: keeps one t9999 TODO line' 1 '^[[:space:]]*- \[[ x]\] t9999[[:space:]]' "$TODO_FILE"
assert_count '_mark_single_task_complete: leaves t9999 completed' 1 '^[[:space:]]*- \[x\] t9999[[:space:]]' "$TODO_FILE"

rc=0
_mark_single_task_complete 't8888' "$TODO_FILE" "$today_short" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
	print_result '_mark_single_task_complete: cleans already-completed duplicates' 0
else
	print_result '_mark_single_task_complete: cleans already-completed duplicates' 1 "expected rc=0, got rc=$rc"
fi
assert_count '_mark_single_task_complete: keeps one t8888 TODO line' 1 '^[[:space:]]*- \[[ x]\] t8888[[:space:]]' "$TODO_FILE"

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
