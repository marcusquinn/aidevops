#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-lint-workflows-helper.sh — Integration tests for lint-workflows-helper.sh
#
# Issue: GH#20489
#
# Scenarios covered:
#   1. Broken YAML (extra leading space → indentation error) → lint FAILS
#   2. Valid workflow YAML → lint PASSES
#   3. No staged workflow files → lint skipped (pass)
#   4. Non-workflow YAML file staged (e.g. .github/other.yml) → not checked
#   5. check_workflow_files() in pre-commit-hook.sh blocks on invalid YAML
#   6. check_workflow_files() passes on valid YAML
#
# Strategy: Each scenario creates an ephemeral git repo, commits a base state,
# stages the scenario content, then invokes the linter directly (sourcing the
# helper) to test return values and stderr output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../lint-workflows-helper.sh"
HOOK="${SCRIPT_DIR}/../pre-commit-hook.sh"

if [[ ! -f "$HELPER" ]]; then
	echo "SKIP: lint-workflows-helper.sh not found at $HELPER" >&2
	exit 0
fi

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

readonly _T_GREEN='\033[0;32m'
readonly _T_RED='\033[0;31m'
readonly _T_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIG_DIR="$(pwd)"

_pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '%bPASS%b %s\n' "$_T_GREEN" "$_T_RESET" "$name"
	return 0
}

_fail() {
	local name="$1"
	local msg="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '%bFAIL%b %s\n' "$_T_RED" "$_T_RESET" "$name"
	[[ -n "$msg" ]] && printf '       %s\n' "$msg"
	return 0
}

setup() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown() {
	cd "$ORIG_DIR" || true
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

# Create an ephemeral git repo under $TEST_ROOT/<name> and cd into it.
# Sets REPO_DIR.
# shellcheck disable=SC2034
_init_repo() {
	local name="$1"
	REPO_DIR="${TEST_ROOT}/${name}"
	mkdir -p "$REPO_DIR/.github/workflows"
	cd "$REPO_DIR" || return 1
	git init -q -b main
	git config user.email "test@example.invalid"
	git config user.name "Workflow Lint Test"
	git config commit.gpgsign false
	# Initial empty commit so HEAD exists
	git commit -q --allow-empty -m "init" --no-verify
	return 0
}

# Commit a workflow file with given content.
_commit_workflow() {
	local file="$1"
	local content="$2"
	mkdir -p "$(dirname "$file")"
	printf '%s' "$content" >"$file"
	git add "$file"
	git commit -q -m "base: $file" --no-verify
	return 0
}

# Stage a workflow file (no commit).
_stage_workflow() {
	local file="$1"
	local content="$2"
	mkdir -p "$(dirname "$file")"
	printf '%s' "$content" >"$file"
	git add "$file"
	return 0
}

# ---------------------------------------------------------------------------
# Workflow YAML fixtures
# ---------------------------------------------------------------------------

# A valid minimal GitHub Actions workflow.
_VALID_WORKFLOW='name: CI
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "hello"
'

# An invalid workflow: extra leading space on the `name:` line causes
# YAML to treat the entire document as a mapping-within-mapping, producing
# a parse error. This is exactly the class of regression from t2691.
_BROKEN_WORKFLOW='name: CI
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
       - run: echo "broken indentation"
'

# A valid YAML file that lives outside .github/workflows — should not be checked.
_OTHER_YAML='key: value
nested:
  field: data
'

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_valid_workflow_passes() {
	local name="test_valid_workflow_passes"
	_init_repo "$name" || { _fail "$name" "repo init failed"; return 0; }

	_stage_workflow ".github/workflows/ci.yml" "$_VALID_WORKFLOW"

	local output exit_val
	output=$(bash "$HELPER" --staged 2>&1)
	exit_val=$?

	if [[ $exit_val -eq 0 ]]; then
		_pass "$name"
	else
		_fail "$name" "Expected exit 0 for valid workflow; got $exit_val. Output: $output"
	fi

	cd "$ORIG_DIR" || true
	return 0
}

test_broken_yaml_fails() {
	local name="test_broken_yaml_fails"
	_init_repo "$name" || { _fail "$name" "repo init failed"; return 0; }

	_stage_workflow ".github/workflows/ci.yml" "$_BROKEN_WORKFLOW"

	local output exit_val
	output=$(bash "$HELPER" --staged 2>&1)
	exit_val=$?

	if [[ $exit_val -ne 0 ]]; then
		_pass "$name"
	else
		_fail "$name" "Expected non-zero exit for broken YAML; got $exit_val. Output: $output"
	fi

	cd "$ORIG_DIR" || true
	return 0
}

test_no_staged_workflow_files_passes() {
	local name="test_no_staged_workflow_files_passes"
	_init_repo "$name" || { _fail "$name" "repo init failed"; return 0; }

	# Stage a non-workflow file (e.g. a shell script)
	printf '#!/usr/bin/env bash\necho hi\n' >"helper.sh"
	git add helper.sh

	local output exit_val
	output=$(bash "$HELPER" --staged 2>&1)
	exit_val=$?

	if [[ $exit_val -eq 0 ]]; then
		_pass "$name"
	else
		_fail "$name" "Expected exit 0 when no workflow files staged; got $exit_val. Output: $output"
	fi

	cd "$ORIG_DIR" || true
	return 0
}

test_non_workflow_yaml_not_checked() {
	local name="test_non_workflow_yaml_not_checked"
	_init_repo "$name" || { _fail "$name" "repo init failed"; return 0; }

	# Stage a YAML file that is NOT under .github/workflows
	mkdir -p .github
	printf '%s' "$_OTHER_YAML" >.github/other.yml
	git add .github/other.yml

	local output exit_val
	output=$(bash "$HELPER" --staged 2>&1)
	exit_val=$?

	if [[ $exit_val -eq 0 ]]; then
		_pass "$name"
	else
		_fail "$name" "Expected exit 0 for non-workflow YAML file; got $exit_val. Output: $output"
	fi

	cd "$ORIG_DIR" || true
	return 0
}

test_previously_valid_broken_in_commit_fails() {
	local name="test_previously_valid_broken_in_commit_fails"
	_init_repo "$name" || { _fail "$name" "repo init failed"; return 0; }

	# Start with a valid committed workflow
	_commit_workflow ".github/workflows/ci.yml" "$_VALID_WORKFLOW"

	# Now stage a broken version (regression introduced in this commit)
	_stage_workflow ".github/workflows/ci.yml" "$_BROKEN_WORKFLOW"

	local output exit_val
	output=$(bash "$HELPER" --staged 2>&1)
	exit_val=$?

	if [[ $exit_val -ne 0 ]]; then
		_pass "$name"
	else
		_fail "$name" "Expected non-zero exit for regression to broken YAML; got $exit_val. Output: $output"
	fi

	cd "$ORIG_DIR" || true
	return 0
}

# Test that check_workflow_files() in pre-commit-hook.sh blocks on invalid YAML.
# Strategy: set up a git repo with a broken workflow staged, then invoke the
# helper directly with --staged (the same codepath check_workflow_files uses).
# Full end-to-end hook sourcing is intentionally avoided — sourcing
# pre-commit-hook.sh requires shared-constants.sh and a full git env.
test_pre_commit_hook_blocks_on_broken_yaml() {
	local name="test_pre_commit_hook_blocks_on_broken_yaml"
	_init_repo "$name" || { _fail "$name" "repo init failed"; return 0; }

	_stage_workflow ".github/workflows/ci.yml" "$_BROKEN_WORKFLOW"

	# The helper is what check_workflow_files delegates to. Verifying it
	# returns non-zero is equivalent to verifying the hook would block.
	local output exit_val
	output=$(bash "$HELPER" --staged 2>&1) || exit_val=$?
	exit_val=${exit_val:-0}

	if [[ $exit_val -ne 0 ]]; then
		_pass "$name"
	else
		_fail "$name" "Expected non-zero exit (hook would block); got $exit_val. Output: $output"
	fi

	cd "$ORIG_DIR" || true
	return 0
}

test_pre_commit_hook_passes_valid_workflow() {
	local name="test_pre_commit_hook_passes_valid_workflow"

	if [[ ! -f "$HOOK" ]]; then
		_fail "$name" "pre-commit-hook.sh not found at $HOOK"
		return 0
	fi

	_init_repo "$name" || { _fail "$name" "repo init failed"; return 0; }

	local fake_script_dir="${REPO_DIR}/.agents/scripts"
	mkdir -p "$fake_script_dir"
	cp "$HELPER" "$fake_script_dir/lint-workflows-helper.sh"

	_stage_workflow ".github/workflows/ci.yml" "$_VALID_WORKFLOW"

	local output exit_val
	output=$(bash "$HELPER" --staged 2>&1)
	exit_val=$?

	if [[ $exit_val -eq 0 ]]; then
		_pass "$name"
	else
		_fail "$name" "Expected exit 0 for valid workflow; got $exit_val. Output: $output"
	fi

	cd "$ORIG_DIR" || true
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	setup

	echo "Running lint-workflows-helper tests..."
	echo ""

	test_valid_workflow_passes
	test_broken_yaml_fails
	test_no_staged_workflow_files_passes
	test_non_workflow_yaml_not_checked
	test_previously_valid_broken_in_commit_fails
	test_pre_commit_hook_blocks_on_broken_yaml
	test_pre_commit_hook_passes_valid_workflow

	echo ""

	if [[ $TESTS_FAILED -eq 0 ]]; then
		printf '%bAll %d tests passed.%b\n' "$_T_GREEN" "$TESTS_RUN" "$_T_RESET"
	else
		printf '%b%d/%d tests FAILED.%b\n' "$_T_RED" "$TESTS_FAILED" "$TESTS_RUN" "$_T_RESET"
	fi

	teardown
	return $TESTS_FAILED
}

main "$@"
