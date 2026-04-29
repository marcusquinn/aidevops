#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-ta-heading-variants.sh — tests for heading variant support (GH#21543)
#
# Verifies that task-complete-helper.sh accepts multiple completion section headings:
# - ## Done (canonical)
# - ## Completed
# - ## Complete
# - ## Finished
#
# Tests (4 cases):
#   1. Task completes with ## Done heading (canonical)
#   2. Task completes with ## Completed heading (non-canonical)
#   3. Task completes with ## Complete heading (non-canonical)
#   4. Task completes with ## Finished heading (non-canonical)

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/task-complete-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf 'test harness cannot find helper at %s\n' "$HELPER" >&2
	exit 1
fi

TMP=$(mktemp -d -t gh21543-heading-variants.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# Helper: set up a minimal git repo with fixture TODO.md content
setup_repo() {
	local fixture_content="$1"
	local repo_name="${2:-repo}"
	local repo_dir="$TMP/$repo_name"
	mkdir -p "$repo_dir"
	printf '%s\n' "$fixture_content" >"$repo_dir/TODO.md"
	git -C "$repo_dir" init -q
	git -C "$repo_dir" config user.email "test@test.com"
	git -C "$repo_dir" config user.name "Test"
	git -C "$repo_dir" add TODO.md
	git -C "$repo_dir" commit -q -m "initial"
	REPO_PATH="$repo_dir"
	return 0
}

# Helper: check if a task is in a completion section (any variant)
task_in_completion_section() {
	local task_id="$1"
	local todo_file="$2"
	awk -v tid="$task_id" '
		/^## (Done|Completed|Complete|Finished)$/ { in_done=1; next }
		/^## /      { in_done=0; next }
		in_done && $0 ~ ("^[[:space:]]*- \\[x\\] " tid "([[:space:]]|$)") { found=1 }
		END { exit (found ? 0 : 1) }
	' "$todo_file"
	return $?
}

FIXTURE_HEADER='## Format

- [ ] tXXX Description #tag

## Routines

## Ready

'

printf '%sRunning task-complete-helper heading variant tests (GH#21543)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1: Canonical ## Done heading
# =============================================================================
printf '\nTest 1: canonical ## Done heading\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t1001 task with done heading #tag ~1h ref:GH#1001 logged:2026-01-01

## Backlog

## Done

## Declined
"

setup_repo "$FIXTURE" "repo_done"

"$HELPER" t1001 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1

if task_in_completion_section "t1001" "$REPO_PATH/TODO.md"; then
	pass "t1001 moved to ## Done section"
else
	fail "t1001 moved to ## Done section" "task not found in completion section"
fi

if grep -qE "verified:2026-01-15" "$REPO_PATH/TODO.md"; then
	pass "proof-log added with ## Done"
else
	fail "proof-log added with ## Done" "verified: not found"
fi

# =============================================================================
# Test 2: ## Completed heading (non-canonical)
# =============================================================================
printf '\nTest 2: ## Completed heading (non-canonical)\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t1002 task with completed heading #tag ~1h ref:GH#1002 logged:2026-01-01

## Backlog

## Completed

## Declined
"

setup_repo "$FIXTURE" "repo_completed"

output=$("$HELPER" t1002 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" 2>&1 || true)

if task_in_completion_section "t1002" "$REPO_PATH/TODO.md"; then
	pass "t1002 moved to ## Completed section"
else
	fail "t1002 moved to ## Completed section" "task not found in completion section"
fi

if echo "$output" | grep -qi "completed"; then
	pass "warning emitted for non-canonical ## Completed"
else
	fail "warning emitted for non-canonical ## Completed" "no warning found in output"
fi

# =============================================================================
# Test 3: ## Complete heading (non-canonical)
# =============================================================================
printf '\nTest 3: ## Complete heading (non-canonical)\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t1003 task with complete heading #tag ~1h ref:GH#1003 logged:2026-01-01

## Backlog

## Complete

## Declined
"

setup_repo "$FIXTURE" "repo_complete"

output=$("$HELPER" t1003 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" 2>&1 || true)

if task_in_completion_section "t1003" "$REPO_PATH/TODO.md"; then
	pass "t1003 moved to ## Complete section"
else
	fail "t1003 moved to ## Complete section" "task not found in completion section"
fi

if echo "$output" | grep -qi "complete"; then
	pass "warning emitted for non-canonical ## Complete"
else
	fail "warning emitted for non-canonical ## Complete" "no warning found in output"
fi

# =============================================================================
# Test 4: ## Finished heading (non-canonical)
# =============================================================================
printf '\nTest 4: ## Finished heading (non-canonical)\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t1004 task with finished heading #tag ~1h ref:GH#1004 logged:2026-01-01

## Backlog

## Finished

## Declined
"

setup_repo "$FIXTURE" "repo_finished"

output=$("$HELPER" t1004 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" 2>&1 || true)

if task_in_completion_section "t1004" "$REPO_PATH/TODO.md"; then
	pass "t1004 moved to ## Finished section"
else
	fail "t1004 moved to ## Finished section" "task not found in completion section"
fi

if echo "$output" | grep -qi "finished"; then
	pass "warning emitted for non-canonical ## Finished"
else
	fail "warning emitted for non-canonical ## Finished" "no warning found in output"
fi

# =============================================================================
# Test 5: No completion section — error handling
# =============================================================================
printf '\nTest 5: no completion section — error handling\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t1005 task without completion section #tag ~1h ref:GH#1005 logged:2026-01-01

## Backlog

## Declined
"

setup_repo "$FIXTURE" "repo_no_section"

if ! "$HELPER" t1005 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "helper exits non-zero when no completion section exists"
else
	fail "helper exits non-zero when no completion section exists" "should have failed"
fi

# TODO.md must be unchanged
if grep -qE "^- \[ \] t1005" "$REPO_PATH/TODO.md"; then
	pass "TODO.md unchanged when completion section missing (rollback works)"
else
	fail "TODO.md unchanged when completion section missing (rollback works)" \
		"TODO.md was modified despite the error"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%s----%s\n' "$TEST_BLUE" "$TEST_NC"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests FAILED%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
