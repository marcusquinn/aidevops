#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-opencode-agent-workflow-security.sh — Regression tests for OpenCode Agent deny-path hardening

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW="${REPO_ROOT}/.github/workflows/opencode-agent.yml"

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local message="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s: %s\n' "$name" "$message"
	return 0
}

assert_contains() {
	local name="$1"
	local needle="$2"

	if grep -Fq "$needle" "$WORKFLOW"; then
		pass "$name"
		return 0
	fi

	fail "$name" "missing ${needle}"
	return 0
}

test_security_check_permissions_are_explicit() {
	local name="test_security_check_permissions_are_explicit"

	assert_contains "${name}_contents_read" "      contents: read"
	assert_contains "${name}_pull_requests_write" "      pull-requests: write"
	assert_contains "${name}_issues_write" "      issues: write"
	return 0
}

test_deny_writes_use_safe_helper() {
	local name="test_deny_writes_use_safe_helper"
	local direct_writes

	direct_writes=$(grep -E 'await github\.rest\.(issues|pulls)\.(createComment|createReplyForReviewComment|addLabels)' "$WORKFLOW" || true)
	if [[ -z "$direct_writes" ]]; then
		pass "$name"
		return 0
	fi

	fail "$name" "found direct throwing deny-path writes: ${direct_writes}"
	return 0
}

test_safe_helper_catches_permission_denials() {
	local name="test_safe_helper_catches_permission_denials"

	assert_contains "${name}_helper" "const safeGitHubWrite = async (description, fn) => {"
	assert_contains "${name}_403" "error.status === 403"
	assert_contains "${name}_404" "error.status === 404"
	# shellcheck disable=SC2016 # Intentionally matching a JavaScript template literal.
	assert_contains "${name}_warning" 'core.warning(`${description} skipped: ${error.message}`)'
	return 0
}

main() {
	if [[ ! -f "$WORKFLOW" ]]; then
		fail "workflow_exists" "missing ${WORKFLOW}"
		return 1
	fi

	test_security_check_permissions_are_explicit
	test_deny_writes_use_safe_helper
	test_safe_helper_catches_permission_denials

	printf 'Tests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ $TESTS_FAILED -eq 0 ]]; then
		return 0
	fi

	return 1
}

main "$@"
