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

_linters_local_required_diff_gate() {
	local metric="$1"
	record_call "$metric"
	return 0
}

_linters_local_run_cached_gate() {
	local gate_name="$1"
	local gate_function="$2"
	: "$gate_name"
	"$gate_function"
	return $?
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

assert_inventory_contains() {
	local inventory="$1"
	local expected="$2"
	local name="$3"
	if printf '%s\n' "$inventory" | grep -qxF "$expected"; then
		print_result "$name" 0
	else
		print_result "$name" 1 "inventory: ${inventory//$'\n'/, }"
	fi
	return 0
}

assert_inventory_excludes() {
	local inventory="$1"
	local unexpected="$2"
	local name="$3"
	if ! printf '%s\n' "$inventory" | grep -qxF "$unexpected"; then
		print_result "$name" 0
	else
		print_result "$name" 1 "inventory: ${inventory//$'\n'/, }"
	fi
	return 0
}

create_changed_mode_fixture() {
	local repo="$1"
	git -C "$repo" init -q
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name "Fixture User"
	printf 'common\n' >"${repo}/common.txt"
	git -C "$repo" add common.txt
	git -C "$repo" commit -qm "common"
	local common_sha=""
	common_sha=$(git -C "$repo" rev-parse HEAD)

	git -C "$repo" branch -M main
	printf 'main only\n' >"${repo}/main-only.txt"
	git -C "$repo" add main-only.txt
	git -C "$repo" commit -qm "main only"
	git -C "$repo" update-ref refs/remotes/origin/main HEAD

	git -C "$repo" checkout -qb develop "$common_sha"
	printf 'develop baseline\n' >"${repo}/develop-baseline.txt"
	git -C "$repo" add develop-baseline.txt
	git -C "$repo" commit -qm "develop baseline"
	git -C "$repo" update-ref refs/remotes/origin/develop HEAD
	git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop

	git -C "$repo" checkout -qb feature
	printf 'feature commit\n' >"${repo}/feature.txt"
	git -C "$repo" add feature.txt
	git -C "$repo" commit -qm "feature"
	printf 'staged\n' >"${repo}/staged.txt"
	git -C "$repo" add staged.txt
	printf 'unstaged\n' >>"${repo}/feature.txt"
	printf 'untracked\n' >"${repo}/untracked.txt"
	return 0
}

changed_inventory_for_repo() {
	local repo="$1"
	local explicit_ref="${2:-}"
	(
		cd "$repo" || exit 1
		LINT_CHANGED_FILES_READY=false
		LINT_CHANGED_FILES=""
		LINTERS_LOCAL_MODE=changed
		LINTERS_LOCAL_BASE_REF="$explicit_ref"
		if ! _linters_local_prepare_changed_inventory; then
			return 1
		fi
		printf '%s\n' "$LINT_CHANGED_FILES"
	)
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

test_changed_inventory_uses_remote_default() {
	local repo=""
	repo=$(mktemp -d)
	create_changed_mode_fixture "$repo"
	local inventory=""
	inventory=$(changed_inventory_for_repo "$repo")
	assert_inventory_contains "$inventory" "feature.txt" "develop base includes committed feature change"
	assert_inventory_contains "$inventory" "staged.txt" "develop base retains staged changes"
	assert_inventory_contains "$inventory" "untracked.txt" "develop base retains untracked changes"
	assert_inventory_excludes "$inventory" "develop-baseline.txt" "develop base excludes integration history"
	assert_inventory_excludes "$inventory" "main-only.txt" "develop base excludes divergent main history"
	rm -rf "$repo"
	return 0
}

test_explicit_base_override() {
	local repo=""
	repo=$(mktemp -d)
	create_changed_mode_fixture "$repo"
	git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	local inventory=""
	inventory=$(changed_inventory_for_repo "$repo" origin/develop)
	assert_inventory_excludes "$inventory" "develop-baseline.txt" "explicit base overrides remote default"
	_linters_local_parse_args --base-ref origin/develop
	if [[ "${LINTERS_LOCAL_BASE_REF:-}" == "origin/develop" ]]; then
		print_result "--base-ref parses its argument" 0
	else
		print_result "--base-ref parses its argument" 1 "base=${LINTERS_LOCAL_BASE_REF:-unset}"
	fi
	rm -rf "$repo"
	return 0
}

test_main_base_and_missing_ref() {
	local repo=""
	repo=$(mktemp -d)
	create_changed_mode_fixture "$repo"
	git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
	git -C "$repo" reset --hard -q
	git -C "$repo" clean -fdq
	git -C "$repo" checkout -q main
	git -C "$repo" checkout -qb main-feature
	printf 'main feature\n' >"${repo}/main-feature.txt"
	git -C "$repo" add main-feature.txt
	git -C "$repo" commit -qm "main feature"
	local inventory=""
	inventory=$(changed_inventory_for_repo "$repo")
	assert_inventory_contains "$inventory" "main-feature.txt" "main default includes feature change"
	assert_inventory_excludes "$inventory" "main-only.txt" "main default excludes base history"
	git -C "$repo" symbolic-ref --delete refs/remotes/origin/HEAD
	local error_output=""
	local rc=0
	error_output=$(changed_inventory_for_repo "$repo" 2>&1) || rc=$?
	if [[ "$rc" -ne 0 && "$error_output" == *"use --base-ref REF"* ]]; then
		print_result "missing default ref fails with override guidance" 0
	else
		print_result "missing default ref fails with override guidance" 1 "rc=$rc output=$error_output"
	fi
	rm -rf "$repo"
	return 0
}

test_help_and_invalid_arguments() {
	local outside_repo=""
	outside_repo=$(mktemp -d)
	local output=""
	local rc=0
	output=$(cd "$outside_repo" && PATH="/usr/bin:/bin" bash "${REPO_ROOT}/.agents/scripts/linters-local.sh" --help 2>&1) || rc=$?
	if [[ "$rc" -eq 0 && "$output" == *"Usage: linters-local.sh"* && "$output" != *"Local Linters - Fast"* ]]; then
		print_result "--help exits before inventory and gates outside Git" 0
	else
		print_result "--help exits before inventory and gates outside Git" 1 "rc=$rc output=$output"
	fi
	rc=0
	output=$(cd "$outside_repo" && PATH="/usr/bin:/bin" bash "${REPO_ROOT}/.agents/scripts/linters-local.sh" --unknown-option 2>&1) || rc=$?
	if [[ "$rc" -eq 2 && "$output" == *"unknown option"* && "$output" != *"Local Linters - Fast"* ]]; then
		print_result "unknown option exits 2 before gates" 0
	else
		print_result "unknown option exits 2 before gates" 1 "rc=$rc output=$output"
	fi
	rc=0
	output=$(cd "$outside_repo" && PATH="/usr/bin:/bin" bash "${REPO_ROOT}/.agents/scripts/linters-local.sh" --base-ref 2>&1) || rc=$?
	if [[ "$rc" -eq 2 && "$output" == *"requires a Git ref"* ]]; then
		print_result "missing --base-ref argument exits 2" 0
	else
		print_result "missing --base-ref argument exits 2" 1 "rc=$rc output=$output"
	fi
	rm -rf "$outside_repo"
	return 0
}

main() {
	test_changed_mode_gate_set
	test_mode_defaults_and_full_override
	test_changed_inventory_uses_remote_default
	test_explicit_base_override
	test_main_base_and_missing_ref
	test_help_and_invalid_arguments
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
