#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-wrapper-rest-fallback.sh — t2574 / GH#20243 regression guard.
#
# Asserts that `gh issue *` wrappers in shared-gh-wrappers.sh fall back to
# REST API (`gh api -X POST|PATCH /repos/...`) when:
#   1. the primary `gh issue *` call fails, AND
#   2. `gh api rate_limit --jq .resources.graphql.remaining` returns <= 10.
#
# Production failure (2026-04-21 ~01:00 UTC on marcusquinn/aidevops):
#   GraphQL quota saturated to 0/5000; `gh issue create|edit|comment` all
#   returned HTTP 403 "rate limit exceeded"; `gh api /repos/...` REST
#   endpoints continued to work because the core REST budget (5000/hour)
#   is separate from GraphQL. Workers had no escape hatch — interactive
#   operators pivoted manually; dispatched workers crashed at step 1.
#
# Fix (t2574): add _gh_should_fallback_to_rest + _gh_issue_*_rest helpers
# in shared-gh-wrappers-rest-fallback.sh; wrap the 4 entry points
# (gh_create_issue, gh_issue_comment, gh_issue_edit_safe, set_issue_status)
# to retry via REST when primary fails and GraphQL is exhausted.
#
# Tests:
#   1. _gh_should_fallback_to_rest returns 0 when remaining <= 10
#   2. _gh_should_fallback_to_rest returns 1 when remaining > 10
#   3. _gh_should_fallback_to_rest returns 1 when rate_limit call fails (fail-safe)
#   4. _gh_issue_create_rest translates --title/--body/--label → POST /repos/.../issues
#   5. _gh_issue_create_rest uses -F body=@file for newline/unicode safety
#   6. _gh_issue_comment_rest translates --body → POST /repos/.../issues/N/comments
#   7. _gh_issue_comment_rest extracts repo and num from a URL argument
#   8. _gh_issue_edit_rest translates --add-label/--remove-label into full labels array
#   9. gh_issue_comment falls back to REST when gh fails AND graphql exhausted
#  10. gh_issue_comment does NOT fall back when gh succeeds
#  11. gh_issue_comment does NOT fall back when gh fails but graphql healthy
#
# Stub strategy: define `gh` as a shell function. Shell functions take
# precedence over PATH binaries, so the stub captures all `gh` invocations
# without PATH mutation. Sub-stubs (primary-fail, rate-limit-return) are
# controlled via env vars set per-test.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2574.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
GH_INFO_OUTPUT="${TMP}/info_output.log"

# Configurable stub behaviour per test via env vars:
#   STUB_RATE_LIMIT_REMAINING  — what gh api rate_limit returns (default: 5000)
#   STUB_PRIMARY_FAIL          — 1 to make gh issue create/comment/edit fail
#   STUB_REST_FAIL             — 1 to make gh api -X POST|PATCH fail
# =============================================================================
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
export -f print_info print_warning print_error print_success log_verbose

export AIDEVOPS_SESSION_ORIGIN=interactive
export AIDEVOPS_SESSION_USER=testuser

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

# Re-override print_* AFTER sourcing — shared-constants.sh defines its own
# that would otherwise shadow our capturing stubs.
# shellcheck disable=SC2317
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
export -f print_info

# Post-source stubs. Shell functions beat PATH binaries.
gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"

	# gh api rate_limit - always succeeds, returns configurable value
	if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
		local remaining="${STUB_RATE_LIMIT_REMAINING:-5000}"
		printf '%s\n' "$remaining"
		return 0
	fi

	# gh api user - always returns testuser (for _gh_wrapper_auto_assignee)
	if [[ "$1" == "api" && "$2" == "user" ]]; then
		printf '"testuser"\n'
		return 0
	fi

	# gh api /repos/.../issues/N (state fetch for label/assignee deltas)
	if [[ "$1" == "api" && "$2" =~ ^/repos/.+/issues/[0-9]+$ ]]; then
		# Return pre-canned labels/assignees from env for label delta tests
		printf '%s\n' "${STUB_CURRENT_LABELS:-bug}"
		return 0
	fi

	# gh api -X POST|PATCH - REST calls. Succeed unless STUB_REST_FAIL=1
	if [[ "$1" == "api" && ("$2" == "-X" || "$2" =~ ^-X ) ]]; then
		if [[ "${STUB_REST_FAIL:-0}" == "1" ]]; then
			printf 'REST stub forced failure\n' >&2
			return 1
		fi
		printf 'https://github.com/owner/repo/issues/9999\n'
		return 0
	fi

	# gh issue create|comment|edit - the primary path
	if [[ "$1" == "issue" && ( "$2" == "create" || "$2" == "comment" || "$2" == "edit" ) ]]; then
		if [[ "${STUB_PRIMARY_FAIL:-0}" == "1" ]]; then
			printf 'primary stub forced failure (rate limit)\n' >&2
			return 1
		fi
		if [[ "$2" == "create" ]]; then
			printf 'https://github.com/owner/repo/issues/9000\n'
		fi
		return 0
	fi

	# gh label create - silent success
	return 0
}
export -f gh

printf '%sRunning gh-wrapper REST fallback tests (t2574 / GH#20243)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1: _gh_should_fallback_to_rest returns 0 (true) when remaining <= 10
# =============================================================================
STUB_RATE_LIMIT_REMAINING=0
if _gh_should_fallback_to_rest; then
	pass "should_fallback returns true when remaining=0"
else
	fail "should_fallback returns true when remaining=0" \
		"expected 0 (true) but got non-zero"
fi

STUB_RATE_LIMIT_REMAINING=10
if _gh_should_fallback_to_rest; then
	pass "should_fallback returns true when remaining=10 (boundary)"
else
	fail "should_fallback returns true when remaining=10 (boundary)" \
		"expected 0 (true) at boundary"
fi

# =============================================================================
# Test 2: _gh_should_fallback_to_rest returns 1 (false) when remaining > 10
# =============================================================================
STUB_RATE_LIMIT_REMAINING=100
if ! _gh_should_fallback_to_rest; then
	pass "should_fallback returns false when remaining=100"
else
	fail "should_fallback returns false when remaining=100" \
		"expected non-zero (false) but got 0 (true)"
fi

# =============================================================================
# Test 3: _gh_should_fallback_to_rest fail-safe when rate_limit unparseable
# Stub returns non-numeric — fallback should NOT activate (fail-safe: let
# caller see original error rather than running REST call that may also fail).
# =============================================================================
STUB_RATE_LIMIT_REMAINING="unknown"
if ! _gh_should_fallback_to_rest; then
	pass "should_fallback returns false when rate_limit unparseable (fail-safe)"
else
	fail "should_fallback returns false when rate_limit unparseable (fail-safe)" \
		"expected false but got true — would trigger unnecessary REST fallback"
fi

# Reset for remaining tests
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 4: _gh_issue_create_rest → POST /repos/.../issues with correct args
# =============================================================================
: >"$GH_CALLS"
_gh_issue_create_rest \
	--repo "owner/repo" \
	--title "t9991: test create" \
	--body "test body" \
	--label "bug,auto-dispatch" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'title=t9991: test create' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=bug' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=auto-dispatch' "$GH_CALLS" 2>/dev/null; then
	pass "_gh_issue_create_rest translates to POST /repos/.../issues with labels"
else
	fail "_gh_issue_create_rest translates to POST /repos/.../issues with labels" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 5: _gh_issue_create_rest uses -F body=@file (for newline/unicode safety)
# =============================================================================
: >"$GH_CALLS"
_gh_issue_create_rest \
	--repo "owner/repo" \
	--title "t9992: newline test" \
	--body "line1
line2
line3" >/dev/null 2>&1 || true

if grep -qE 'body=@/.*aidevops-gh-rest-body' "$GH_CALLS" 2>/dev/null; then
	pass "_gh_issue_create_rest uses -F body=@tmpfile for body"
else
	fail "_gh_issue_create_rest uses -F body=@tmpfile for body" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 6: _gh_issue_comment_rest translates --body → POST .../comments
# =============================================================================
: >"$GH_CALLS"
_gh_issue_comment_rest 12345 \
	--repo "owner/repo" \
	--body "test comment" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues/12345/comments' "$GH_CALLS" 2>/dev/null; then
	pass "_gh_issue_comment_rest translates to POST /issues/N/comments"
else
	fail "_gh_issue_comment_rest translates to POST /issues/N/comments" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 7: _gh_issue_comment_rest extracts repo + num from a URL argument
# =============================================================================
: >"$GH_CALLS"
_gh_issue_comment_rest "https://github.com/owner/repo/issues/777" \
	--body "url-form comment" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues/777/comments' "$GH_CALLS" 2>/dev/null; then
	pass "_gh_issue_comment_rest extracts repo+num from URL"
else
	fail "_gh_issue_comment_rest extracts repo+num from URL" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 8: _gh_issue_edit_rest computes full labels array from add/remove deltas
# Current labels stub returns "bug" (single label). We add "auto-dispatch",
# remove "bug" — target set should be ["auto-dispatch"] only.
# =============================================================================
: >"$GH_CALLS"
export STUB_CURRENT_LABELS="bug"
_gh_issue_edit_rest 42 \
	--repo "owner/repo" \
	--add-label "auto-dispatch" \
	--remove-label "bug" >/dev/null 2>&1 || true

if grep -qE 'labels\[\]=auto-dispatch' "$GH_CALLS" 2>/dev/null &&
	! grep -qE 'labels\[\]=bug' "$GH_CALLS" 2>/dev/null; then
	pass "_gh_issue_edit_rest computes target label set (add auto-dispatch, remove bug)"
else
	fail "_gh_issue_edit_rest computes target label set (add auto-dispatch, remove bug)" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_CURRENT_LABELS

# =============================================================================
# Test 9: gh_issue_comment → falls back to REST when primary fails AND exhausted
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

gh_issue_comment 5555 --repo "owner/repo" --body "fallback test" >/dev/null 2>&1 || true

# Verify: primary was called AND rate_limit was checked AND REST was called
if grep -qE '^issue comment 5555' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api.*-X POST.*/repos/owner/repo/issues/5555/comments' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_comment falls back to REST when primary fails AND exhausted"
else
	fail "gh_issue_comment falls back to REST when primary fails AND exhausted" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

if grep -qE 'GraphQL exhausted.*falling back to REST' "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "gh_issue_comment emits fallback log line"
else
	fail "gh_issue_comment emits fallback log line" \
		"INFO log: $(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 10: gh_issue_comment → does NOT fall back when primary succeeds
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
gh_issue_comment 6666 --repo "owner/repo" --body "success path" >/dev/null 2>&1 || true

if grep -qE '^issue comment 6666' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/issues/6666' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_comment does NOT fall back when primary succeeds"
else
	fail "gh_issue_comment does NOT fall back when primary succeeds" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 11: gh_issue_comment → does NOT fall back when primary fails but healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=5000

gh_issue_comment 7777 --repo "owner/repo" --body "healthy fail" >/dev/null 2>&1 || true

# Primary should fail; rate_limit checked (returns healthy); NO REST call.
if grep -qE '^issue comment 7777' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/issues/7777' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_comment does NOT fall back when primary fails but healthy"
else
	fail "gh_issue_comment does NOT fall back when primary fails but healthy" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s%d/%d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
