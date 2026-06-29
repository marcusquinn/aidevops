#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-loc-badge-reusable-install.sh — regression test for local repo metrics workflow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
WORKFLOW="$REPO_ROOT/.github/workflows/loc-badge-reusable.yml"

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

_assert_contains() {
	local _name="$1"
	local _pattern="$2"
	if grep -Fq -- "$_pattern" "$WORKFLOW"; then
		_pass "$_name"
		return 0
	fi
	_fail "$_name" "missing literal: $_pattern"
	return 0
}

_assert_not_regex() {
	local _name="$1"
	local _pattern="$2"
	if grep -Eq -- "$_pattern" "$WORKFLOW"; then
		_fail "$_name" "unexpected pattern present: $_pattern"
		return 0
	fi
	_pass "$_name"
	return 0
}

main() {
	local _installer_pipe_pattern="curl.*rust""up|rust""up.*curl"
	if [[ ! -f "$WORKFLOW" ]]; then
		_fail "workflow exists" "not found: $WORKFLOW"
		printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
		return 1
	fi

	_assert_contains "uses repo metrics helper" "repo-metrics-helper.sh generate"
	_assert_contains "writes JSON metrics" "docs/metrics"
	_assert_contains "uses freshness skip" "skip_if_fresh_hours"
	_assert_contains "keeps runtime bounded" "timeout-minutes: 5"
	_assert_contains "detects untracked generated metrics" "git status --porcelain"
	_assert_not_regex "does not apt-install tokei" 'apt(-get)? install.*tokei'
	_assert_not_regex "does not install jq" 'apt(-get)? install.*jq'
	_assert_not_regex "does not cargo-install tokei" 'cargo install.*tokei'
	_assert_not_regex "does not invoke tokei" 'tokei --version|\btokei\b'
	_assert_not_regex "does not pipe remote Rust installer" "$_installer_pipe_pattern"

	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
