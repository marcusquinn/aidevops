#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stdout-narration-hygiene.sh — GH#20212 regression tests
#
# Verifies that "data-returning" functions do not emit ANSI colour codes or
# banner narration to stdout. Root cause: worktree-helper.sh cmd_clean and
# pre-commit-hook.sh main_pre_push/main_pre_commit wrote coloured banners to
# stdout, poisoning callers that used $(…) command substitution.
#
# Two concrete failures from GH#20212:
#   1. pulse-canonical-maintenance.sh:334 — sweep_count=$((sweep_count + removed))
#      where removed=$(_stale_worktree_sweep_single_repo …) → called
#      worktree-helper.sh clean --auto → banner "[1mChecking for worktrees..."
#      leaked into $removed → arithmetic crash.
#   2. claim-task-id.sh:792 — first_id=$((first_id + i)) where first_id was
#      captured via $(allocate_online …) → allocate_online ran git push → hook
#      emitted "${BLUE}Pre-push Quality Validation" to stdout → arithmetic crash.
#
# Tests cover:
#   1. worktree-helper.sh clean --auto: stdout empty
#   2. worktree-helper.sh clean --auto: no ANSI on stdout
#   3. worktree-helper.sh clean --auto: arithmetic-safe in $(( ))
#   4. pre-commit-hook.sh main_pre_push: no ANSI on stdout
#   5. pre-commit-hook.sh main_pre_commit: no ANSI on stdout

set -u

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="${SCRIPT_DIR_TEST}/.."
WORKTREE_HELPER="${SCRIPTS_DIR}/worktree-helper.sh"
PRE_COMMIT_HOOK="${SCRIPTS_DIR}/pre-commit-hook.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="${1:-}"
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

# Returns 0 (true) if $1 contains an ANSI ESC sequence (\033[).
# Uses bash pattern matching — portable, no grep -P required.
_contains_ansi() {
	local str="$1"
	[[ "$str" == *$'\033'* ]]
	return $?
}

TMP=$(mktemp -d -t "narration-hygiene.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# Create a minimal git repo in $1 with one empty commit.
_setup_git_repo() {
	local dir="$1"
	git -C "$dir" init -q 2>/dev/null
	git -C "$dir" config user.email "test@test.invalid" 2>/dev/null
	git -C "$dir" config user.name "Test" 2>/dev/null
	git -C "$dir" commit --allow-empty -m "init" -q 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: worktree-helper.sh clean --auto produces empty stdout
# ---------------------------------------------------------------------------
test_worktree_clean_auto_stdout_empty() {
	local name="worktree-helper.sh clean --auto: stdout is empty (no narration leaked)"
	local repo="${TMP}/repo-t1"
	mkdir -p "$repo"
	_setup_git_repo "$repo"

	local captured_stdout
	captured_stdout=$(cd "$repo" && bash "$WORKTREE_HELPER" clean --auto 2>/dev/null)

	if [[ -n "$captured_stdout" ]]; then
		fail "$name" "expected empty stdout, got: $(printf '%q' "$captured_stdout")"
	else
		pass "$name"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: worktree-helper.sh clean --auto stdout contains no ANSI codes
# (Covers the case where a plain-text message might slip through even if
# the empty-stdout check above relaxes in future.)
# ---------------------------------------------------------------------------
test_worktree_clean_auto_no_ansi_stdout() {
	local name="worktree-helper.sh clean --auto: no ANSI escape codes on stdout"
	local repo="${TMP}/repo-t2"
	mkdir -p "$repo"
	_setup_git_repo "$repo"

	local captured_stdout
	captured_stdout=$(cd "$repo" && bash "$WORKTREE_HELPER" clean --auto 2>/dev/null)

	if _contains_ansi "$captured_stdout"; then
		fail "$name" "stdout contains ANSI: $(printf '%q' "$captured_stdout")"
	else
		pass "$name"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: worktree-helper.sh clean --auto stdout is arithmetic-safe
# Reproduces the exact pattern from pulse-canonical-maintenance.sh:
#   removed=$(_stale_worktree_sweep_single_repo …)
#   sweep_count=$((sweep_count + removed))
# ---------------------------------------------------------------------------
test_worktree_clean_auto_arithmetic_safe() {
	local name="worktree-helper.sh clean --auto: captured stdout is arithmetic-safe in \$(( ))"
	local repo="${TMP}/repo-t3"
	mkdir -p "$repo"
	_setup_git_repo "$repo"

	local captured_stdout
	captured_stdout=$(cd "$repo" && bash "$WORKTREE_HELPER" clean --auto 2>/dev/null)

	# Simulate: sweep_count=$((0 + captured_stdout))
	local arith_result=0
	if ! arith_result=$(( 0 + ${captured_stdout:-0} )) 2>/dev/null; then
		fail "$name" "arithmetic failed with captured stdout: $(printf '%q' "$captured_stdout")"
	else
		pass "$name"
		# arith_result is intentionally unused — we only test that arithmetic doesn't crash
		: "$arith_result"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: pre-commit-hook.sh main_pre_push stdout has no ANSI codes
# Sources the hook in a subshell and stubs out the check_* functions so the
# test is fast and doesn't require git state. Verifies the banner that was
# previously at line 895-896 goes to stderr, not stdout.
# ---------------------------------------------------------------------------
test_pre_push_banner_no_ansi_stdout() {
	local name="pre-commit-hook.sh main_pre_push: banner written to stderr, not stdout"

	# Run in a subshell to isolate the hook's set -euo pipefail
	local captured_stdout
	captured_stdout=$(
		# shellcheck disable=SC1090
		source "$PRE_COMMIT_HOOK" 2>/dev/null || exit 1
		# Stub expensive checks to no-ops for speed
		check_secrets() { return 0; }
		check_quality_standards() { return 0; }
		main_pre_push 2>/dev/null
	)

	if _contains_ansi "$captured_stdout"; then
		fail "$name" "stdout contains ANSI: $(printf '%q' "$captured_stdout")"
	else
		pass "$name"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: pre-commit-hook.sh main_pre_commit stdout has no ANSI codes
# Tests the "no shell files modified" early-exit path (most common).
# ---------------------------------------------------------------------------
test_pre_commit_banner_no_ansi_stdout() {
	local name="pre-commit-hook.sh main_pre_commit: banner written to stderr, not stdout"

	local captured_stdout
	captured_stdout=$(
		# shellcheck disable=SC1090
		source "$PRE_COMMIT_HOOK" 2>/dev/null || exit 1
		# Stub all validators so the function exits early via the
		# "no shell files modified" path.
		validate_duplicate_task_ids() { return 0; }
		validate_task_counter_monotonic() { return 0; }
		validate_todo_completions() { return 0; }
		validate_parent_subtask_blocking() { return 0; }
		validate_repo_root_files() { return 0; }
		# Return empty output → ${#modified_files[@]} == 0 → early return
		get_modified_shell_files() { printf ''; return 0; }
		main_pre_commit 2>/dev/null
	)

	if _contains_ansi "$captured_stdout"; then
		fail "$name" "stdout contains ANSI: $(printf '%q' "$captured_stdout")"
	else
		pass "$name"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf '%stest-stdout-narration-hygiene.sh — GH#20212 regression%s\n' \
		"$TEST_BLUE" "$TEST_NC"
	printf '==========================================================\n\n'

	test_worktree_clean_auto_stdout_empty
	test_worktree_clean_auto_no_ansi_stdout
	test_worktree_clean_auto_arithmetic_safe
	test_pre_push_banner_no_ansi_stdout
	test_pre_commit_banner_no_ansi_stdout

	printf '\n'
	printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%b\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
