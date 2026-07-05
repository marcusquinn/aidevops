#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-full-loop-commit-default-branch.sh — GH#26626 regression guard.
#
# Verifies commit-and-pr resolves the remote default branch from origin/HEAD
# instead of hardcoding origin/main for ahead-count, rebase, fetch, and
# .task-counter race-prevention logic.

# Negative assertions capture non-zero exits.
set -uo pipefail

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

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message" >>"${STUB_LOG:?}"
	return 0
}

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message" >>"${STUB_LOG:?}"
	return 0
}

print_error() {
	local message="$1"
	printf 'ERROR %s\n' "$message" >>"${STUB_LOG:?}"
	return 0
}

print_success() {
	local message="$1"
	printf 'OK %s\n' "$message" >>"${STUB_LOG:?}"
	return 0
}

SCRIPT_DIR_TEST="$(cd "$(dirname "$0")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

STUB_LOG="${TEST_ROOT}/stub.log"
GIT_LOG="${TEST_ROOT}/git.log"
TASK_COUNTER_FILE="${TEST_ROOT}/.task-counter"
ORIGIN_HEAD_REF="origin/develop"
GIT_SHOW_COUNTER="7"
: >"$STUB_LOG"
: >"$GIT_LOG"
export STUB_LOG GIT_LOG TASK_COUNTER_FILE ORIGIN_HEAD_REF GIT_SHOW_COUNTER

git() {
	local subcommand="${1:-}"
	shift || true
	printf 'git %s %s\n' "$subcommand" "$*" >>"${GIT_LOG:?}"
	case "$subcommand" in
	symbolic-ref)
		if [[ "$*" == "--short refs/remotes/origin/HEAD" ]]; then
			[[ -n "${ORIGIN_HEAD_REF:-}" ]] || return 1
			printf '%s\n' "$ORIGIN_HEAD_REF"
			return 0
		fi
		;;
	add)
		return 0
		;;
	diff)
		if [[ "$*" == "--cached --quiet" ]]; then
			return 0
		fi
		return 0
		;;
	rev-list)
		if [[ "$*" == "--count origin/develop..HEAD" ]]; then
			printf '2\n'
			return 0
		fi
		printf '0\n'
		return 0
		;;
	fetch | rebase | push | commit)
		return 0
		;;
	rev-parse)
		printf 'false\n'
		return 0
		;;
	show)
		if [[ "$*" == "origin/develop:.task-counter" ]]; then
			printf '%s\n' "$GIT_SHOW_COUNTER"
			return 0
		fi
		return 1
		;;
	esac
	command git "$subcommand" "$@"
	return $?
}
export -f git

timeout() {
	local duration="${1:-}"
	: "$duration"
	shift || return 1
	"$@"
	return $?
}
export -f timeout

# shellcheck source=../full-loop-helper-commit.sh
source "${SCRIPTS_DIR}/full-loop-helper-commit.sh"

_check_and_handle_shallow_clone() {
	return 0
}

test_stage_uses_remote_default_branch_for_ahead_count() {
	: >"$GIT_LOG"
	_stage_and_commit "test commit" >/dev/null 2>&1
	local rc=$?
	if [[ "$rc" -eq 0 ]] && grep -qF 'git rev-list --count origin/develop..HEAD' "$GIT_LOG" && ! grep -qF 'origin/main..HEAD' "$GIT_LOG"; then
		print_result "stage ahead-count uses origin/develop" 0
	else
		print_result "stage ahead-count uses origin/develop" 1 "rc=${rc}; log=$(tr '\n' ';' <"$GIT_LOG")"
	fi
	return 0
}

test_rebase_uses_remote_default_branch_and_counter_ref() {
	: >"$GIT_LOG"
	printf '3\n' >"$TASK_COUNTER_FILE"
	(
		cd "$TEST_ROOT" || exit 1
		_rebase_and_push "feature/test" 0 >/dev/null 2>&1
	)
	local rc=$?
	local counter_value=""
	counter_value=$(tr -d '[:space:]' <"$TASK_COUNTER_FILE")
	if [[ "$rc" -eq 0 ]] \
		&& [[ "$counter_value" == "7" ]] \
		&& grep -qF 'git fetch origin develop --quiet' "$GIT_LOG" \
		&& grep -qF 'git rebase origin/develop' "$GIT_LOG" \
		&& grep -qF 'git show origin/develop:.task-counter' "$GIT_LOG" \
		&& ! grep -qF 'origin/main' "$GIT_LOG"; then
		print_result "rebase and counter reset use origin/develop" 0
	else
		print_result "rebase and counter reset use origin/develop" 1 "rc=${rc}; counter=${counter_value}; log=$(tr '\n' ';' <"$GIT_LOG")"
	fi
	rm -f "$TASK_COUNTER_FILE"
	return 0
}

test_missing_origin_head_fails_actionably_without_main_fallback() {
	: >"$GIT_LOG"
	ORIGIN_HEAD_REF=""
	export ORIGIN_HEAD_REF
	_rebase_and_push "feature/test" 0 >/dev/null 2>&1
	local rc=$?
	if [[ "$rc" -ne 0 ]] && ! grep -qF 'origin/main' "$GIT_LOG" && grep -qF 'remote set-head origin --auto' "$STUB_LOG"; then
		print_result "missing origin/HEAD fails without main fallback" 0
	else
		print_result "missing origin/HEAD fails without main fallback" 1 "rc=${rc}; git=$(tr '\n' ';' <"$GIT_LOG"); log=$(tr '\n' ';' <"$STUB_LOG")"
	fi
	return 0
}

test_stage_uses_remote_default_branch_for_ahead_count
test_rebase_uses_remote_default_branch_and_counter_ref
test_missing_origin_head_fails_actionably_without_main_fallback

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
