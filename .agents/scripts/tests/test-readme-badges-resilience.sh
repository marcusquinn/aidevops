#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-readme-badges-resilience.sh — regression tests for resilient README badges.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
HELPER="$REPO_ROOT/.agents/scripts/readme-badges-helper.sh"
TEMPLATE="$REPO_ROOT/.agents/templates/readme/badges.md.tmpl"
README="$REPO_ROOT/README.md"

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
	local _name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$_name"
	return 0
}

_fail() {
	local _name="$1"
	local _message="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n       %s\n' "$_name" "$_message"
	return 0
}

_assert_contains_text() {
	local _name="$1"
	local _needle="$2"
	local _haystack="$3"
	if [[ "$_haystack" == *"$_needle"* ]]; then
		_pass "$_name"
		return 0
	fi
	_fail "$_name" "missing literal: $_needle"
	return 0
}

_assert_not_contains_text() {
	local _name="$1"
	local _needle="$2"
	local _haystack="$3"
	if [[ "$_haystack" == *"$_needle"* ]]; then
		_fail "$_name" "unexpected literal present: $_needle"
		return 0
	fi
	_pass "$_name"
	return 0
}

_assert_file_not_contains() {
	local _name="$1"
	local _needle="$2"
	local _file="$3"
	if grep -Fq -- "$_needle" "$_file"; then
		_fail "$_name" "unexpected literal present in $_file: $_needle"
		return 0
	fi
	_pass "$_name"
	return 0
}

_write_repos_json() {
	local _json_path="$1"
	local _repo_path="$2"
	local _slug="$3"
	printf '{"initialized_repos":[{"slug":"%s","path":"%s","foss":true}]}\n' \
		"$_slug" "$_repo_path" >"$_json_path"
	return 0
}

_render_for_fixture() {
	local _repo_path="$1"
	local _slug="$2"
	local _repos_json="$3"
	_write_repos_json "$_repos_json" "$_repo_path" "$_slug"
	REPOS_JSON="$_repos_json" bash "$HELPER" render "$_slug" --branch main --template "$TEMPLATE"
	return 0
}

_test_native_actions_badge_uses_workflow_file() {
	local _tmp
	_tmp=$(mktemp -d)
	local _repo="$_tmp/repo"
	local _slug="example/repo"
	mkdir -p "$_repo/.github/workflows"
	printf '# Example\n' >"$_repo/README.md"
	printf 'name: Code Quality Analysis\non: [push]\n' >"$_repo/.github/workflows/code-quality.yml"

	local _out
	_out=$(_render_for_fixture "$_repo" "$_slug" "$_tmp/repos.json")
	_assert_contains_text \
		"Actions badge uses file-scoped native endpoint" \
		"https://github.com/example/repo/actions/workflows/code-quality.yml/badge.svg?branch=main" \
		"$_out"
	_assert_not_contains_text \
		"Actions badge does not use workflow-name endpoint" \
		"/workflows/CI/badge.svg" \
		"$_out"
	_assert_not_contains_text \
		"Rendered canonical block avoids Shields GitHub API endpoints" \
		"img.shields.io/github/" \
		"$_out"
	rm -rf "$_tmp"
	return 0
}

_test_actions_badge_skips_unknown_workflow() {
	local _tmp
	_tmp=$(mktemp -d)
	local _repo="$_tmp/repo"
	local _slug="example/no-workflow"
	mkdir -p "$_repo"
	printf '# Example\n' >"$_repo/README.md"

	local _out
	_out=$(_render_for_fixture "$_repo" "$_slug" "$_tmp/repos.json")
	_assert_not_contains_text \
		"Unknown workflow omits Actions badge instead of rendering a broken image" \
		"[![GitHub Actions]" \
		"$_out"
	rm -rf "$_tmp"
	return 0
}

_test_source_badge_blocks_avoid_github_shields() {
	_assert_file_not_contains \
		"Canonical badge template avoids Shields GitHub API endpoints" \
		"img.shields.io/github/" \
		"$TEMPLATE"
	_assert_file_not_contains \
		"Top-level README avoids Shields GitHub API endpoints" \
		"img.shields.io/github/" \
		"$README"
	return 0
}

main() {
	if [[ ! -f "$HELPER" || ! -f "$TEMPLATE" || ! -f "$README" ]]; then
		_fail "required files exist" "missing helper/template/README"
		printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
		return 1
	fi

	_test_native_actions_badge_uses_workflow_file
	_test_actions_badge_skips_unknown_workflow
	_test_source_badge_blocks_avoid_github_shields

	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
