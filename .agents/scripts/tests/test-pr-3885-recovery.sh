#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

QUALITY_FILE="${REPO_ROOT}/.agents/scripts/quality-cli-manager.sh"
STUCK_FILE="${REPO_ROOT}/.agents/scripts/stuck-detection-helper.sh"
WORKTREE_FILE="${REPO_ROOT}/.agents/scripts/worktree-helper.sh"
GITIGNORE_FILE="${REPO_ROOT}/.gitignore"

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	echo "PASS ${message}"
	return 0
}

fail() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "FAIL ${message}"
	return 0
}

assert_contains() {
	local file_path="$1"
	local pattern="$2"
	local message="$3"

	if rg -Fq -- "$pattern" "$file_path"; then
		pass "$message"
		return 0
	fi

	fail "$message"
	return 1
}

assert_line_exists() {
	local file_path="$1"
	local line_value="$2"
	local message="$3"

	if rg -Fxq -- "$line_value" "$file_path"; then
		pass "$message"
		return 0
	fi

	fail "$message"
	return 0
}

run_checks() {
	set +e
	assert_contains "$QUALITY_FILE" '"qlty")' "quality-cli-manager has qlty dispatcher case"
	assert_contains "$QUALITY_FILE" 'script=".agents/scripts/qlty-cli.sh"' "quality-cli-manager routes qlty through wrapper"
	assert_contains "$QUALITY_FILE" "execute_cli_command \"qlty\" \"check\" \"\$args\"" "quality-cli-manager runs qlty check without positional org arg"
	assert_contains "$STUCK_FILE" 'unique_by([.issue, .repo])' "stuck-detection helper uses collision-safe jq dedup key"
	assert_contains "$WORKTREE_FILE" "refs/remotes/*/\$branch" "worktree helper checks remote branch presence across all remotes"
	assert_line_exists "$GITIGNORE_FILE" 'hostinger' "gitignore includes hostinger base pattern"
	assert_line_exists "$GITIGNORE_FILE" 'hostinger.*' "gitignore includes hostinger wildcard extension pattern"
	assert_line_exists "$GITIGNORE_FILE" 'hostinger_*' "gitignore retains hostinger underscore pattern"
	set -e
	return 0
}

main() {
	run_checks
	echo ""
	echo "Tests run: ${TESTS_RUN}"
	echo "Tests failed: ${TESTS_FAILED}"

	if [[ $TESTS_FAILED -gt 0 ]]; then
		return 1
	fi

	return 0
}

main "$@"
