#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pre-commit-hook-duplicate-ids.sh — t2209 regression guard.
#
# Asserts the pre-commit hook's validate_duplicate_task_ids function
# correctly distinguishes real task-list collisions from documentation
# examples, prose mentions, and historical state that cannot be undone.
#
# Failure history motivating this test: PR #19683 (t2191) installed the
# `.git/hooks/pre-commit` dispatcher, which activated a dormant
# context-blind grep in pre-commit-hook.sh. The grep flagged
# `## Format` section doc examples and inline prose mentions of task IDs
# as duplicates, blocking every subsequent TODO.md commit. Worse, TODO.md
# on main has historical duplicate task IDs (t131 and t1056 were each
# claimed twice under old workflows) that cannot be retroactively
# renamed without breaking PR/issue back-references.

# NOTE: not using `set -e` intentionally — assertions run the function
# in subshells via `bash -c`/`run_case` and capture non-zero exits. A
# fail-fast shell would abort on the first expected non-zero.
# See `test-parent-task-guard.sh` for the canonical precedent.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_PATH="${TEST_SCRIPTS_DIR}/pre-commit-hook.sh"

if [[ ! -f "$HOOK_PATH" ]]; then
	printf 'FAIL: hook not found at %s\n' "$HOOK_PATH" >&2
	exit 1
fi

# NOT readonly — shared-constants.sh (transitively sourced by the hook)
# declares readonly RED/GREEN/RESET and the collision would fire `|| exit`
# under set -e and silently kill the test shell. Use plain vars.
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

# Sandbox HOME so sourcing the hook is side-effect-free. The hook sources
# shared-constants.sh which touches ~/.aidevops/logs; we isolate to avoid
# polluting the real deployment.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace"

# =============================================================================
# Test harness
# =============================================================================

# Create a throwaway git repo, seed it with a HEAD TODO.md, stage a new
# TODO.md, and run validate_duplicate_task_ids. Returns the function's
# exit code via stdout in the form "rc=N\n<stderr>".
#
# Usage: run_case <head-todo-content> <staged-todo-content>
# Pass the empty string as $1 to simulate "TODO.md not yet in HEAD".
run_case() {
	local head_content="$1" staged_content="$2"
	local repo="${TEST_ROOT}/repo-${TESTS_RUN}"

	rm -rf "$repo"
	mkdir -p "$repo"
	(
		cd "$repo" || exit 1
		git init -q
		git config user.email 'test@aidevops.local'
		git config user.name 'Test Runner'
		git config commit.gpgsign false

		# Seed repo so HEAD exists; use README rather than TODO.md so the
		# TODO.md-not-in-HEAD case can be modelled by passing an empty
		# head_content.
		printf 'initial\n' > README.md
		git add README.md
		git commit -q -m 'initial'

		if [[ -n "$head_content" ]]; then
			printf '%s' "$head_content" > TODO.md
			git add TODO.md
			git commit -q -m 'seed todo'
		fi

		printf '%s' "$staged_content" > TODO.md
		git add TODO.md

		# shared-constants.sh defines print_error et al. Source it first
		# with the real path; the hook's own attempt to source it via
		# `${SCRIPT_DIR}/shared-constants.sh` resolves SCRIPT_DIR against
		# the process-substitution fd when we source the hook below, so
		# that call silently fails. Pre-sourcing here makes print_error
		# available to validate_duplicate_task_ids regardless.
		# shellcheck source=/dev/null
		source "${TEST_SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1

		# Source the hook with the trailing `main "$@"` invocation
		# stripped so only function definitions run. This avoids
		# executing the full hook (shellcheck, secret scan, etc.) and
		# lets us call validate_duplicate_task_ids in isolation.
		# shellcheck source=/dev/null
		source <(sed '/^main "\$@"$/d' "$HOOK_PATH") >/dev/null 2>&1

		# The hook enables `set -e` at top level; sourcing inherits it.
		# Disable before invoking validate so a non-zero return doesn't
		# kill this subshell before we can capture `$?`.
		set +e
		validate_duplicate_task_ids 2>&1
		local rc=$?
		set -e
		echo "rc=${rc}"
	)
	return 0
}

assert_pass() {
	local name="$1" head_content="$2" staged_content="$3"
	local output rc
	output=$(run_case "$head_content" "$staged_content")
	rc=$(printf '%s' "$output" | grep -oE 'rc=[0-9]+$' | tail -1 | cut -d= -f2)
	if [[ "${rc:-1}" -eq 0 ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "expected pass, got rc=$rc; output: $output"
	fi
	return 0
}

assert_fail() {
	local name="$1" head_content="$2" staged_content="$3" expect_id="$4"
	local output rc
	output=$(run_case "$head_content" "$staged_content")
	rc=$(printf '%s' "$output" | grep -oE 'rc=[0-9]+$' | tail -1 | cut -d= -f2)
	if [[ "${rc:-0}" -ne 1 ]]; then
		print_result "$name" 1 "expected fail (rc=1), got rc=$rc; output: $output"
		return
	fi
	if ! printf '%s' "$output" | grep -qF "$expect_id"; then
		print_result "$name" 1 "expected mention of '$expect_id' in output; got: $output"
		return
	fi
	print_result "$name" 0
	return 0
}

# =============================================================================
# Test cases
# =============================================================================

# Case 1: doc examples only (no task-list entries). Should pass — no
# real task IDs to collide.
# shellcheck disable=SC2016  # backticks are literal fixture content, not subshells
FIXTURE_DOC_ONLY='## Format

- `t001` - Top-level task
- `t001.1` - Subtask of t001
- `t001.1.1` - Sub-subtask

## Ready
'
assert_pass \
	"doc-examples-only TODO.md passes (no task-list entries)" \
	"" \
	"$FIXTURE_DOC_ONLY"

# Case 2: doc examples co-existing with a real task entry that shares
# the ID. The doc example must be filtered out so the real entry isn't
# flagged as a duplicate of itself.
# shellcheck disable=SC2016
FIXTURE_DOC_PLUS_REAL='## Format

- `t001` - Top-level task example

## Ready
- [ ] t001 Real live task using ID 001 @owner
'
assert_pass \
	"doc example ignored when real task uses same ID" \
	"" \
	"$FIXTURE_DOC_PLUS_REAL"

# Case 3: prose mention embedded in a different section — not a
# task-list entry. Regex anchored at line start with [ ]/[x] checkbox
# should not match this.
# shellcheck disable=SC2016
FIXTURE_PROSE_MENTION='## Ready
- [ ] t500 Add guard
- This creates phantom issues from format examples in TODO.md (e.g. `- [ ] t500 Task description @owner`)
'
assert_pass \
	"prose mention of '- [ ] tNNN' inside backticks is ignored" \
	"" \
	"$FIXTURE_PROSE_MENTION"

# Case 4: two new task-list entries in one commit share the same ID.
# Classic collision — must fail.
FIXTURE_TWO_NEW_DUPES='## Ready
- [ ] t900 First task
- [ ] t900 Different task claiming the same ID
'
assert_fail \
	"two new task-list entries with same ID fail" \
	"" \
	"$FIXTURE_TWO_NEW_DUPES" \
	"t900"

# Case 5: new task-list entry collides with an ID already in HEAD.
# The ID is present in HEAD once, this commit adds a second occurrence —
# new duplicate introduced, must fail.
FIXTURE_HEAD_HAS_ONE='## Ready
- [ ] t800 First task
'
FIXTURE_STAGED_ADDS_DUPE='## Ready
- [ ] t800 First task
- [ ] t800 Collision with existing ID
'
assert_fail \
	"new entry colliding with existing HEAD ID fails" \
	"$FIXTURE_HEAD_HAS_ONE" \
	"$FIXTURE_STAGED_ADDS_DUPE" \
	"t800"

# Case 6: HEAD already has a historical duplicate. Staged content
# preserves it unchanged. No NEW duplicate introduced — must pass.
# This is the critical case that unblocks TODO.md commits against the
# current state of main, where t131 and t1056 have pre-existing dupes.
FIXTURE_HEAD_HISTORICAL_DUPE='## Ready
- [x] t131 Original historical task
- [x] t131 Different task that reused the ID in 2026-02-09
- [ ] t500 An unrelated pending task
'
FIXTURE_STAGED_PRESERVES='## Ready
- [x] t131 Original historical task
- [x] t131 Different task that reused the ID in 2026-02-09
- [ ] t500 An unrelated pending task
- [ ] t501 A newly-added pending task
'
assert_pass \
	"historical duplicate in HEAD preserved in staged = pass (diff-aware)" \
	"$FIXTURE_HEAD_HISTORICAL_DUPE" \
	"$FIXTURE_STAGED_PRESERVES"

# Case 7: first commit introducing TODO.md with duplicates. HEAD has no
# TODO.md, staged has collisions — all dupes are "new" and must fail.
FIXTURE_FIRST_COMMIT_WITH_DUPES='## Ready
- [ ] t100 First
- [ ] t100 Second (duplicate)
'
assert_fail \
	"first commit introducing TODO.md with dupes fails" \
	"" \
	"$FIXTURE_FIRST_COMMIT_WITH_DUPES" \
	"t100"

# Case 8: subtask IDs (t123.1, t123.1.2) are distinct from parents.
# Having t123 and t123.1 in the same file is NOT a duplicate.
FIXTURE_SUBTASKS='## Ready
- [ ] t700 Parent task
  - [ ] t700.1 Subtask one
  - [ ] t700.2 Subtask two
    - [ ] t700.2.1 Sub-subtask
'
assert_pass \
	"subtask IDs (t700, t700.1, t700.2, t700.2.1) are distinct" \
	"" \
	"$FIXTURE_SUBTASKS"

# Case 9: same subtask ID duplicated — must fail.
FIXTURE_SUBTASK_DUPE='## Ready
- [ ] t600 Parent
  - [ ] t600.1 Subtask
  - [ ] t600.1 Another subtask claiming the same ID
'
assert_fail \
	"duplicated subtask ID fails" \
	"" \
	"$FIXTURE_SUBTASK_DUPE" \
	"t600.1"

# Case 10 (t2222): declined task colliding with active task — must fail.
# `- [-]` is the declined checkbox per TODO.md ## Format. A declined task
# re-using an active task's ID is a real collision.
FIXTURE_DECLINED_DUPE='## Ready
- [-] t500 Declined version of this task
- [ ] t500 Active version reusing same ID
'
assert_fail \
	"declined task (- [-]) colliding with active task fails" \
	"" \
	"$FIXTURE_DECLINED_DUPE" \
	"t500"

# Case 11 (t2222): routine IDs (r-prefix) duplicated — must fail.
# Routine entries under ## Routines use `r001`, `r002`, etc. Two
# routines with the same r-ID is a collision.
FIXTURE_ROUTINE_DUPE='## Routines
- [ ] r099 First routine
- [x] r099 Second routine reusing same ID
'
assert_fail \
	"duplicate routine ID (r099) fails" \
	"" \
	"$FIXTURE_ROUTINE_DUPE" \
	"r099"

# =============================================================================
# Summary
# =============================================================================

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
