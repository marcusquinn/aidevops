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

# --- t18545: transient permission failures -------------------------------
LOOKUP_CALLS=0
LOOKUP_SEQUENCE=()
_gh_collaborator_permission_lookup() {
	local repo_slug="$1"
	local user="$2"
	local out_var="${3:-}"
	: "$repo_slug" "$user"
	local step="${LOOKUP_SEQUENCE[$LOOKUP_CALLS]:-fail}"
	LOOKUP_CALLS=$((LOOKUP_CALLS + 1))
	if [[ "$step" == "ok" ]]; then
		AIDEVOPS_GH_COLLAB_PERMISSION_HTTP="200"
		AIDEVOPS_GH_COLLAB_PERMISSION_REASON="ok"
		[[ -n "$out_var" ]] && printf -v "$out_var" '%s' "write"
		return 0
	fi
	AIDEVOPS_GH_COLLAB_PERMISSION_HTTP="unknown"
	AIDEVOPS_GH_COLLAB_PERMISSION_REASON="api-failure"
	return 2
}
_pulse_merge_pr_comment_bodies_rest() {
	printf '%s\n' ""
	return 0
}

# shellcheck source=../pulse-merge-author-checks.sh
source "${PARENT_DIR}/pulse-merge-author-checks.sh"

AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR="${TEST_ROOT}/perm-cache"
mkdir -p "$AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR"

# One transient failure then success: later PRs by the same author proceed.
LOOKUP_CALLS=0
LOOKUP_SEQUENCE=(fail ok)
rc=0
_is_collaborator_author "owner" "alice/owned-repo" || rc=$?
assert_eq "first lookup failure is fail-closed" "2" "$rc"
assert_eq "failure reason is exposed to callers" "api-failure" "$_PULSE_AUTHOR_PERMISSION_REASON"
rc=0
_is_collaborator_author "owner" "alice/owned-repo" || rc=$?
assert_eq "second lookup retries fresh and succeeds" "0" "$rc"
rc=0
_is_collaborator_author "owner" "alice/owned-repo" || rc=$?
assert_eq "confirmed verdict is cached after recovery" "0" "$rc"
assert_eq "recovery used exactly two API calls" "2" "$LOOKUP_CALLS"

# Two consecutive failures: served from cache afterwards (max 2 calls).
rm -f "${AIDEVOPS_PULSE_AUTHOR_PERMISSION_CACHE_DIR}"/*
LOOKUP_CALLS=0
LOOKUP_SEQUENCE=(fail fail ok)
for _i in 1 2 3 4; do
	rc=0
	_is_collaborator_author "owner" "alice/owned-repo" || rc=$?
	assert_eq "double failure stays fail-closed (attempt ${_i})" "2" "$rc"
done
assert_eq "double failure bounded to two API calls" "2" "$LOOKUP_CALLS"
assert_eq "cached failure keeps reason" "api-failure" "$_PULSE_AUTHOR_PERMISSION_REASON"

# Transient failure: no PR comment, log includes status and reason.
COMMENT_CALLS=0
rc=0
check_permission_failure_pr "200" "alice/owned-repo" "owner" "unknown" "api-failure" || rc=$?
assert_eq "transient failure returns 0" "0" "$rc"
assert_eq "transient failure posts no comment" "0" "$COMMENT_CALLS"
assert_log_contains "transient failure log has status and reason" "(HTTP unknown, reason api-failure)"
check_permission_failure_pr "201" "alice/owned-repo" "owner" "503" "unexpected-http" || rc=$?
assert_eq "5xx failure posts no comment" "0" "$COMMENT_CALLS"

# Non-transient failure: one comment, no manual-merge default instruction.
COMMENT_BODY=""
gh_pr_comment() {
	COMMENT_CALLS=$((COMMENT_CALLS + 1))
	COMMENT_BODY="$*"
	return 0
}
check_permission_failure_pr "202" "alice/owned-repo" "owner" "403" "unexpected-http" || true
assert_eq "non-transient failure posts one comment" "1" "$COMMENT_CALLS"
case "$COMMENT_BODY" in
*"merge this PR manually"*) rc=1 ;;
*) rc=0 ;;
esac
assert_eq "comment no longer instructs manual merge" "0" "$rc"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
