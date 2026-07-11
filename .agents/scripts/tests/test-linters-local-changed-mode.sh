#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-linters-local-changed-mode.sh — changed-file gate orchestration tests

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${TEST_SCRIPT_DIR}/../../.." && pwd)" || exit 1
SCRIPT_DIR="${REPO_ROOT}/.agents/scripts"

# shellcheck source=../linters-local.sh
source "${REPO_ROOT}/.agents/scripts/linters-local.sh"

TESTS_RUN=0
TESTS_FAILED=0
CALLS=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

record_call() {
	local name="$1"
	CALLS="${CALLS}${name}"$'\n'
	return 0
}

linters_local_changed_files_matching() {
	local pattern="$1"
	case "$pattern" in
	*'\.md$'*) printf '%s\n' "docs/changed.md" ;;
	*) printf '%s\n' ".agents/scripts/linters-local.sh" "docs/changed.md" ;;
	esac
	return 0
}

check_git_diff_whitespace() {
	record_call "git-diff-check"
	return 0
}
check_string_literals() {
	record_call "string-literals"
	return 0
}
check_forbidden_exec_fd() {
	record_call "forbidden-exec-fd"
	return 0
}
run_shfmt() {
	record_call "shfmt"
	return 0
}
run_shellcheck() {
	record_call "shellcheck"
	return 0
}
check_secrets() {
	record_call "secretlint"
	return 0
}
check_markdown_lint() {
	record_call "markdownlint"
	return 0
}
check_file_size() {
	record_call "file-size"
	return 0
}
check_secret_policy() {
	record_call "secret-policy"
	return 0
}
check_bash32_compat() {
	record_call "bash32-compat"
	return 0
}
check_shell_portability() {
	record_call "shell-portability"
	return 0
}
check_function_complexity() {
	record_call "function-complexity"
	return 0
}
check_nesting_depth() {
	record_call "nesting-depth"
	return 0
}
check_targeted_tests() {
	record_call "targeted-tests"
	return 0
}

assert_called() {
	local name="$1"
	if printf '%s\n' "$CALLS" | grep -qxF "$name"; then
		print_result "changed mode runs ${name}" 0
		return 0
	fi
	print_result "changed mode runs ${name}" 1 "calls: ${CALLS//$'\n'/, }"
	return 0
}

assert_summary_contains() {
	local expected="$1"
	local haystack="$2"
	if printf '%s\n' "$haystack" | grep -qF "$expected"; then
		print_result "summary records ${expected}" 0
		return 0
	fi
	print_result "summary records ${expected}" 1 "$haystack"
	return 0
}

test_changed_mode_gate_set() {
	LINTERS_LOCAL_MODE="changed"
	ALL_SH_FILES=(".agents/scripts/linters-local.sh")
	CALLS=""
	LINTERS_LOCAL_GATES_RAN=""
	LINTERS_LOCAL_GATES_SKIPPED=""
	LINTERS_LOCAL_GATES_DELEGATED=""

	_run_gate_checks >/dev/null

	assert_called "git-diff-check"
	assert_called "secretlint"
	assert_called "shellcheck"
	assert_called "bash32-compat"
	assert_called "shell-portability"
	assert_called "targeted-tests"
	assert_summary_contains "sonarcloud" "$LINTERS_LOCAL_GATES_DELEGATED"
	assert_summary_contains "repo-layout" "$LINTERS_LOCAL_GATES_SKIPPED"
	return 0
}

test_mode_defaults_and_full_override() {
	_linters_local_parse_args
	if [[ "$LINTERS_LOCAL_MODE" == "changed" && "$LINTERS_LOCAL_CHANGED" == "true" ]]; then
		print_result "no-argument mode defaults to changed-file scope" 0
	else
		print_result "no-argument mode defaults to changed-file scope" 1 \
			"mode=$LINTERS_LOCAL_MODE changed=$LINTERS_LOCAL_CHANGED"
	fi

	_linters_local_parse_args --full
	if [[ "$LINTERS_LOCAL_MODE" == "full" && "$LINTERS_LOCAL_CHANGED" == "false" && "$LINTERS_LOCAL_CACHE_ENABLED" == "false" ]]; then
		print_result "--full explicitly enables uncached release scope" 0
	else
		print_result "--full explicitly enables uncached release scope" 1 \
			"mode=$LINTERS_LOCAL_MODE changed=$LINTERS_LOCAL_CHANGED cache=$LINTERS_LOCAL_CACHE_ENABLED"
	fi
	return 0
}

main() {
	test_changed_mode_gate_set
	test_mode_defaults_and_full_override
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
