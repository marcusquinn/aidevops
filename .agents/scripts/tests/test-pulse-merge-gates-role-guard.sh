#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-merge-gates-role-guard.sh — external repo write guard tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="${SCRIPT_DIR}/.."

TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0
GH_CALLS=0
COMMENT_CALLS=0

setup_sandbox() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	return 0
}

teardown_sandbox() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_log_contains() {
	local description="$1"
	local pattern="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qF "$pattern" "$LOGFILE"; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s (missing pattern=%s)\n' "$description" "$pattern"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

gh() {
	GH_CALLS=$((GH_CALLS + 1))
	printf 'gh must not be called for contributor/read-only repo gate tests\n' >&2
	return 99
}

gh_pr_comment() {
	COMMENT_CALLS=$((COMMENT_CALLS + 1))
	printf 'gh_pr_comment must not be called for contributor/read-only repo gate tests\n' >&2
	return 99
}

repo_allows_pulse_write_actions() {
	local repo_slug="$1"
	[[ "$repo_slug" == "alice/owned-repo" ]]
	return $?
}

_extract_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	: "$pr_number" "$repo_slug"
	return 1
}

setup_sandbox
trap teardown_sandbox EXIT

# shellcheck source=../pulse-merge-gates.sh
source "${PARENT_DIR}/pulse-merge-gates.sh"

rc=0
check_external_contributor_pr "123" "bob/external-repo" "repo-owner" "--post" || rc=$?
assert_eq "external contributor gate fails closed for contributor repo" "2" "$rc"
assert_eq "external contributor gate does not call gh" "0" "$GH_CALLS"
assert_eq "external contributor gate does not comment" "0" "$COMMENT_CALLS"
assert_log_contains \
	"external contributor gate logs contributor/read-only skip" \
	"check_external_contributor_pr: skipping PR gate writes in bob/external-repo — repo role is contributor/read-only"

rc=0
check_permission_failure_pr "123" "bob/external-repo" "repo-owner" "404" || rc=$?
assert_eq "permission failure gate fails closed for contributor repo" "2" "$rc"
assert_eq "permission failure gate does not call gh" "0" "$GH_CALLS"
assert_eq "permission failure gate does not comment" "0" "$COMMENT_CALLS"
assert_log_contains \
	"permission failure gate logs contributor/read-only skip" \
	"check_permission_failure_pr: skipping PR gate writes in bob/external-repo — repo role is contributor/read-only"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
