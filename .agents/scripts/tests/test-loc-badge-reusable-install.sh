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

# GH#34276: an existing non-comment caller must suppress loc-badge.yml install.
_test_existing_caller_detection() {
	local _tmp
	_tmp=$(mktemp -d) || return 0
	local _helper="$SCRIPT_DIR/../badges-sync-helper.sh"
	local _fn
	_fn=$(sed -n '/^_find_metrics_caller() {/,/^}/p' "$_helper")
	eval "$_fn"

	mkdir -p "$_tmp/real/.github/workflows" "$_tmp/commented/.github/workflows"
	printf 'jobs:\n  m:\n    uses: marcusquinn/aidevops/.github/workflows/loc-badge-reusable.yml@abc\n' \
		>"$_tmp/real/.github/workflows/repo-metrics.yml"
	printf '# example:\n#   uses: marcusquinn/aidevops/.github/workflows/loc-badge-reusable.yml@abc\n' \
		>"$_tmp/commented/.github/workflows/other.yml"

	local _found=""
	if _found=$(_find_metrics_caller "$_tmp/real") && [[ "$_found" == "repo-metrics.yml" ]]; then
		_pass "detects existing metrics caller"
	else
		_fail "detects existing metrics caller" "got: $_found"
	fi
	if _find_metrics_caller "$_tmp/commented" >/dev/null; then
		_fail "ignores commented example" "commented uses: line was detected"
	else
		_pass "ignores commented example"
	fi
	rm -rf "$_tmp"
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
	_assert_contains "declares helper repository input" "aidevops_repository:"
	_assert_contains "declares private mirror read token" "AIDEVOPS_READ_TOKEN:"
	_assert_contains "checks out configured helper repository" "repository: \${{ inputs.aidevops_repository || 'marcusquinn/aidevops' }}"
	_assert_contains "keeps runtime bounded" "timeout-minutes: 5"
	_assert_contains "detects untracked generated metrics" "git status --porcelain"
	_assert_not_regex "does not apt-install tokei" 'apt(-get)? install.*tokei'
	_assert_not_regex "does not install jq" 'apt(-get)? install.*jq'
	_assert_not_regex "does not cargo-install tokei" 'cargo install.*tokei'
	_assert_not_regex "does not invoke tokei" 'tokei --version|\btokei\b'
	_assert_not_regex "does not pipe remote Rust installer" "$_installer_pipe_pattern"

	_test_existing_caller_detection

	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
