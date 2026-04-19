#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pre-commit-hook-counter-monotonic.sh — t2228 regression guard.
#
# Asserts the pre-commit hook's validate_task_counter_monotonic function
# correctly blocks stale .task-counter regressions while permitting
# legitimate advances and no-ops.
#
# Incident motivating this test: during PR #19730 preparation (2026-04-18)
# a long-lived planning worktree staged .task-counter at 2204 while
# origin/main was at 2224. Committing would have silently wiped 20 claimed
# task IDs. The near-miss was caught only via manual diff inspection.

# NOTE: not using `set -e` intentionally — assertions run the function
# in subshells via run_case and capture non-zero exits. A fail-fast shell
# would abort on the first expected non-zero.
set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_PATH="${TEST_SCRIPTS_DIR}/pre-commit-hook.sh"

if [[ ! -f "$HOOK_PATH" ]]; then
	printf 'FAIL: hook not found at %s\n' "$HOOK_PATH" >&2
	exit 1
fi

# NOT readonly — shared-constants.sh (transitively sourced by the hook)
# declares readonly RED/GREEN/RESET and the collision would fire under
# set -e and silently kill the test shell.
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

# Sandbox HOME so sourcing the hook is side-effect-free.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace"

# =============================================================================
# Test harness
# =============================================================================

# Create a throwaway git repo, seed it with a HEAD .task-counter at
# $head_value, stage .task-counter at $staged_value, and run
# validate_task_counter_monotonic.
#
# Usage: run_case <head_value> <staged_value>
# Pass empty string as head_value to simulate "no .task-counter in HEAD".
run_case() {
	local head_value="$1" staged_value="$2"
	local repo="${TEST_ROOT}/repo-${TESTS_RUN}"

	rm -rf "$repo"
	mkdir -p "$repo"
	(
		cd "$repo" || exit 1
		git init -q
		git config user.email 'test@aidevops.local'
		git config user.name 'Test Runner'
		git config commit.gpgsign false

		# Always create a HEAD so HEAD references work.
		printf 'initial\n' >README.md
		git add README.md
		git commit -q -m 'initial'

		if [[ -n "$head_value" ]]; then
			printf '%s\n' "$head_value" >.task-counter
			git add .task-counter
			git commit -q -m 'seed counter'
		fi

		printf '%s\n' "$staged_value" >.task-counter
		git add .task-counter

		# Pre-source shared-constants.sh so print_error etc. are available.
		# shellcheck source=/dev/null
		source "${TEST_SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1

		# Source hook with the trailing `main "$@"` invocation stripped so
		# only function definitions load. Avoids executing the full hook
		# (shellcheck, secret scan, etc.) and lets us call the validator
		# in isolation.
		# shellcheck source=/dev/null
		source <(sed '/^main "\$@"$/d' "$HOOK_PATH") >/dev/null 2>&1

		# The hook enables set -e; disable before invoking validate so a
		# non-zero return doesn't kill this subshell before we capture $?.
		set +e
		validate_task_counter_monotonic 2>&1
		local rc=$?
		set -e
		echo "rc=${rc}"
	)
	return 0
}

assert_pass() {
	local name="$1" head_value="$2" staged_value="$3"
	local output rc
	output=$(run_case "$head_value" "$staged_value")
	rc=$(printf '%s' "$output" | grep -oE 'rc=[0-9]+$' | tail -1 | cut -d= -f2)
	if [[ "${rc:-1}" -eq 0 ]]; then
		print_result "$name" 0
	else
		print_result "$name" 1 "expected pass, got rc=$rc; output: $output"
	fi
	return 0
}

assert_fail() {
	local name="$1" head_value="$2" staged_value="$3" expect_msg="$4"
	local output rc
	output=$(run_case "$head_value" "$staged_value")
	rc=$(printf '%s' "$output" | grep -oE 'rc=[0-9]+$' | tail -1 | cut -d= -f2)
	if [[ "${rc:-0}" -ne 1 ]]; then
		print_result "$name" 1 "expected fail (rc=1), got rc=$rc; output: $output"
		return
	fi
	if ! printf '%s' "$output" | grep -qF "$expect_msg"; then
		print_result "$name" 1 "expected '$expect_msg' in output; got: $output"
		return
	fi
	print_result "$name" 0
	return 0
}

# =============================================================================
# Test cases
# =============================================================================

# Case 1: staged == HEAD → pass (no-op / merge commit pattern)
assert_pass \
	"staged == HEAD passes (no-op)" \
	"2200" \
	"2200"

# Case 2: staged < HEAD → fail with regression message
assert_fail \
	"staged < HEAD fails with regression message" \
	"2224" \
	"2204" \
	".task-counter regression detected"

# Case 3: staged > HEAD → pass (normal new claim)
assert_pass \
	"staged > HEAD passes (new claim)" \
	"2200" \
	"2205"

# Case 4: .task-counter not staged → pass (no-op, different files changed)
# We achieve "not staged" by sourcing into a repo where the counter was not
# added to the index. We repurpose run_case: pass a non-counter file instead.
# Easier: directly call in a fresh repo with no .task-counter staged.
_run_no_counter_staged() {
	local repo="${TEST_ROOT}/repo-no-counter"
	rm -rf "$repo"
	mkdir -p "$repo"
	(
		cd "$repo" || exit 1
		git init -q
		git config user.email 'test@aidevops.local'
		git config user.name 'Test Runner'
		git config commit.gpgsign false

		printf 'initial\n' >README.md
		git add README.md
		git commit -q -m 'initial'

		# Stage something other than .task-counter
		printf 'hello\n' >some-file.txt
		git add some-file.txt

		# shellcheck source=/dev/null
		source "${TEST_SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1
		# shellcheck source=/dev/null
		source <(sed '/^main "\$@"$/d' "$HOOK_PATH") >/dev/null 2>&1

		set +e
		validate_task_counter_monotonic 2>&1
		local rc=$?
		set -e
		echo "rc=${rc}"
	)
	return 0
}

output=$(_run_no_counter_staged)
rc=$(printf '%s' "$output" | grep -oE 'rc=[0-9]+$' | tail -1 | cut -d= -f2)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "${rc:-1}" -eq 0 ]]; then
	printf '%sPASS%s .task-counter not staged is a no-op (skipped)\n' "$TEST_GREEN" "$TEST_RESET"
else
	printf '%sFAIL%s .task-counter not staged is a no-op (skipped) expected pass got rc=%s; output: %s\n' "$TEST_RED" "$TEST_RESET" "$rc" "$output"
	TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Case 5: non-numeric in staged → skip gracefully (pass)
assert_pass \
	"non-numeric staged value skipped gracefully" \
	"2200" \
	"not-a-number"

# Case 6: no .task-counter in HEAD (first commit introducing it) → pass
# Non-numeric head_value (empty HEAD) falls through the numeric guard.
assert_pass \
	"first commit introducing .task-counter passes (no HEAD value)" \
	"" \
	"2200"

# Case 7: HEAD has non-numeric value (legacy) → skip gracefully (pass)
assert_pass \
	"non-numeric HEAD value skipped gracefully" \
	"legacy-value" \
	"2200"

# =============================================================================
# Summary
# =============================================================================

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
