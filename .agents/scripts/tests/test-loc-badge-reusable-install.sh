#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-loc-badge-reusable-install.sh — regression test for GH#24541

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

	_assert_contains "pins tokei version" "TOKEI_VERSION: '14.0.0'"
	_assert_contains "uses locked cargo install" "cargo install tokei --version \"\$TOKEI_VERSION\" --locked"
	_assert_contains "bounds cargo install time" "timeout 600 cargo install"
	_assert_contains "prints tokei version" "tokei --version"
	_assert_contains "prints jq version" "jq --version"
	_assert_not_regex "does not apt-install tokei" 'apt(-get)? install.*tokei'
	_assert_not_regex "does not pipe remote Rust installer" "$_installer_pipe_pattern"

	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
