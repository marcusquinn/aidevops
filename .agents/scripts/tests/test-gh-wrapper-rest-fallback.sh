#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-wrapper-rest-fallback.sh — t2574 / GH#20243 regression guard.
#
# Asserts that `gh issue *` and `gh pr create|comment|view|list` wrappers in shared-gh-wrappers.sh
# fall back to REST API (`gh api -X POST|PATCH /repos/...`) when:
#   1. the primary `gh issue *` / `gh pr create|comment|view|list` call fails, AND
#   2. `gh api rate_limit --jq .resources.graphql.remaining` returns <= 10.
#
# Production failure (2026-04-21 ~01:00 UTC on marcusquinn/aidevops):
#   GraphQL quota saturated to 0/5000; `gh issue create|edit|comment` all
#   returned HTTP 403 "rate limit exceeded"; `gh api /repos/...` REST
#   endpoints continued to work because the core REST budget (5000/hour)
#   is separate from GraphQL. Workers had no escape hatch — interactive
#   operators pivoted manually; dispatched workers crashed at step 1.
#
# t2579 addendum: gh_create_pr also hit GraphQL exhaustion during PR creation.
# Fix (t2580): extend REST fallback to gh_create_pr via _rest_pr_create.
#
# Fix (t2574): add _rest_should_fallback + _gh_issue_*_rest helpers
# in shared-gh-wrappers-rest-fallback.sh; wrap the 4 entry points
# (gh_create_issue, gh_issue_comment, gh_issue_edit_safe, set_issue_status)
# to retry via REST when primary fails and GraphQL is exhausted.
#
# Tests:
#   1. _rest_should_fallback returns 0 when remaining <= 10
#   2. _rest_should_fallback returns 1 when remaining > 10
#   3. _rest_should_fallback returns 1 when rate_limit call fails (fail-safe)
#   4. _rest_issue_create translates --title/--body/--label → POST /repos/.../issues
#   5. _rest_issue_create uses -F body=@file for newline/unicode safety
#   6. _rest_issue_comment translates --body → POST /repos/.../issues/N/comments
#   7. _rest_issue_comment extracts repo and num from a URL argument
#   8. _rest_issue_edit translates --add-label/--remove-label into full labels array
#   9. gh_issue_comment falls back to REST when gh fails AND graphql exhausted
#  10. gh_issue_comment does NOT fall back when gh succeeds
#  11. gh_issue_comment does NOT fall back when gh fails but graphql healthy
#  12. _rest_pr_create translates --title/--head/--base → POST /repos/.../pulls
#  13. _rest_pr_create uses -F body=@file for body
#  14. _rest_pr_create applies labels via POST /repos/.../issues/{N}/labels
#  15. gh_pr_comment falls back to REST when primary fails AND exhausted
#  16. gh_pr_comment does NOT fall back when primary succeeds
#  17. gh_pr_comment does NOT fall back when primary fails but graphql healthy
#  18. gh_create_pr falls back to REST when primary fails AND exhausted
#  19. gh_create_pr does NOT fall back when primary succeeds
#  20. gh_create_pr does NOT fall back when primary fails but graphql healthy
#  21. _rest_pr_create auto-detects --head from git HEAD when omitted
#  22. _rest_pr_create auto-detects --base from repo default_branch via REST
#  23. gh_issue_view routes directly to REST when GraphQL remaining is low
#  24. gh_issue_list keeps the healthy GraphQL path
#  25. gh_issue_list routes low-budget --search calls to /search/issues
#  26. gh_pr_list routes directly to REST when GraphQL remaining is low
#  27. gh_pr_list keeps --search on the GraphQL path when budget is low
#  28. gh_pr_view routes directly to REST when GraphQL remaining is low
#  29. AIDEVOPS_GH_FORCE_REST_READS routes supported reads through REST without
#      a rate-limit probe
#  30. gh_pr_list does NOT fall back for --search because REST pulls cannot
#      preserve search semantics
#  31. AIDEVOPS_GH_REST_FIRST_READS routes REST-equivalent reads without a
#      rate-limit probe while leaving GraphQL-only PR list fields on GraphQL
#  32. AIDEVOPS_GH_PR_VIEW_CACHE coalesces duplicate REST PR view reads
#
# Stub strategy: define `gh` as a shell function. Shell functions take
# precedence over PATH binaries, so the stub captures all `gh` invocations
# without PATH mutation. Sub-stubs (primary-fail, rate-limit-return) are
# controlled via env vars set per-test.

set -uo pipefail

# Keep the harness hermetic: production pulse sessions may export REST-first
# routing globally, but this test enables it only in the dedicated scenarios.
unset AIDEVOPS_GH_REST_FIRST_READS
unset AIDEVOPS_GH_FORCE_REST_READS

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
GH_APP_TOKEN_CALLS="${TMP}/gh_app_token_calls.log"

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

# Lock REST fallback threshold to 10 for the boundary tests below.
# The default value (1000 since t2744) is intentionally high to enable
# proactive REST routing under load, but these tests verify the
# function's *logic* (fallback-when-remaining-≤-threshold) — not the
# default value itself. Setting the env var BEFORE the source bakes
# the value into _GH_REST_FALLBACK_THRESHOLD inside
# shared-gh-wrappers-rest-fallback.sh.
export AIDEVOPS_GH_REST_FALLBACK_THRESHOLD=10
export AIDEVOPS_GH_REST_FALLBACK_DISABLE_CACHE=1

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

# Re-override print_* AFTER sourcing — shared-constants.sh defines its own
# that would otherwise shadow our capturing stubs.
# shellcheck disable=SC2317
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
export -f print_info

# Keep wrapper tests inside this shell so the gh() function stub below captures
# both primary and REST paths. The production timeout helper may use an external
# timeout binary, which cannot execute shell functions.
# shellcheck disable=SC2317
_gh_with_timeout() { shift; "$@"; return $?; }
export -f _gh_with_timeout

# Post-source stubs. Shell functions beat PATH binaries.
gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"
	[[ -n "${GH_TOKEN:-}" ]] && printf '%s\n' "$GH_TOKEN" >>"${GH_APP_TOKEN_CALLS}"

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
	if [[ "$1" == "api" && "$2" =~ ^/repos/[^/]+/[^/]+/issues\? ]]; then
		local jq_filter=""
		local i=3
		while [[ $i -le $# ]]; do
			if [[ "${!i}" == "--jq" ]]; then
				local next=$((i + 1))
				jq_filter="${!next:-}"
				break
			fi
			i=$((i + 1))
		done
		local fixture='[{"number":22430,"state":"open","title":"Reduce GraphQL list-call pressure","html_url":"https://github.com/owner/repo/issues/22430","updated_at":"2026-05-02T17:52:48Z","labels":[{"name":"auto-dispatch"}],"assignees":[{"login":"worker"}],"user":{"login":"maintainer"}}]'
		if [[ -n "$jq_filter" ]]; then
			printf '%s\n' "$fixture" | jq -c "$jq_filter"
		else
			printf '%s\n' "$fixture"
		fi
		return 0
	fi

	# gh api /repos/{owner}/{repo} (GET, no -X, no /issues suffix) — default branch lookup
	# STUB_REPO_DEFAULT_BRANCH controls the returned value (default: main).
	if [[ "$1" == "api" && "$2" =~ ^/repos/[^/]+/[^/]+/pulls/[0-9]+$ ]]; then
		local jq_filter=""
		local i=3
		while [[ $i -le $# ]]; do
			if [[ "${!i}" == "--jq" ]]; then
				local next=$((i + 1))
				jq_filter="${!next:-}"
				break
			fi
			i=$((i + 1))
		done
		local fixture='{"number":123,"title":"stub PR"}'
		fixture="${STUB_PR_VIEW_FIXTURE:-$fixture}"
		if [[ -n "$jq_filter" ]]; then
			printf '%s\n' "$fixture" | jq -r "$jq_filter"
		else
			printf '%s\n' "$fixture"
		fi
		return 0
	fi
	if [[ "$1" == "api" && "$2" =~ ^/repos/[^/]+/[^/]+/pulls\? ]]; then
		local jq_filter=""
		local i=3
		while [[ $i -le $# ]]; do
			if [[ "${!i}" == "--jq" ]]; then
				local next=$((i + 1))
				jq_filter="${!next:-}"
				break
			fi
			i=$((i + 1))
		done
		local fixture='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"feature/auto-20260502-135611-gh22289"},"base":{"ref":"main"}},{"number":22343,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22343","head":{"ref":"other"},"base":{"ref":"main"}}]'
		fixture="${STUB_PR_LIST_FIXTURE:-$fixture}"
		if [[ "$2" == *"head=owner%3Afeature%2Fauto-20260502-135611-gh22289"* ]]; then
			fixture='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"feature/auto-20260502-135611-gh22289"},"base":{"ref":"main"}}]'
		fi
		if [[ -n "$jq_filter" ]]; then
			printf '%s\n' "$fixture" | jq -c "$jq_filter"
		else
			printf '%s\n' "$fixture"
		fi
		return 0
	fi
	if [[ "$1" == "api" && "$2" =~ ^/repos/[^/]+/[^/]+$ ]]; then
		printf '%s\n' "${STUB_REPO_DEFAULT_BRANCH:-main}"
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
	if [[ "$1" == "issue" && ( "$2" == "create" || "$2" == "comment" || "$2" == "edit" || "$2" == "view" || "$2" == "list" ) ]]; then
		if [[ "${STUB_PRIMARY_FAIL:-0}" == "1" ]]; then
			printf 'primary stub forced failure (rate limit)\n' >&2
			return 1
		fi
		if [[ "$2" == "create" ]]; then
			printf 'https://github.com/owner/repo/issues/9000\n'
		fi
		return 0
	fi

	# gh pr create|comment|view|list - primary PR paths
	if [[ "$1" == "pr" && ( "$2" == "create" || "$2" == "comment" || "$2" == "view" || "$2" == "list" ) ]]; then
		if [[ "${STUB_PRIMARY_FAIL:-0}" == "1" ]]; then
			printf 'primary stub forced failure (rate limit)\n' >&2
			return 1
		fi
		if [[ "$2" == "create" ]]; then
			printf 'https://github.com/owner/repo/pull/9100\n'
		elif [[ "$2" == "view" ]]; then
			printf '{"number":9101}\n'
		elif [[ "$2" == "list" ]]; then
			printf '[]\n'
		fi
		return 0
	fi

	# gh label create / gh pr ready / other - silent success
	return 0
}
export -f gh

# Stub _rest_append_sig as a no-op to prevent gh-signature-helper.sh calls
# during tests. The helper queries the OpenCode SQLite session DB which can
# be slow or blocked when the DB is locked, causing the test to hang after
# the PR fallback cases (GH#22076). The test does not assert on signature
# footer content, so a no-op stub is safe for all existing assertions.
# shellcheck disable=SC2317
_rest_append_sig() { return 0; }
export -f _rest_append_sig

printf '%sRunning gh-wrapper REST fallback tests (t2574 / GH#20243)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1: _rest_should_fallback returns 0 (true) when remaining <= 10
# =============================================================================
STUB_RATE_LIMIT_REMAINING=0
if _rest_should_fallback; then
	pass "should_fallback returns true when remaining=0"
else
	fail "should_fallback returns true when remaining=0" \
		"expected 0 (true) but got non-zero"
fi

STUB_RATE_LIMIT_REMAINING=10
if _rest_should_fallback; then
	pass "should_fallback returns true when remaining=10 (boundary)"
else
	fail "should_fallback returns true when remaining=10 (boundary)" \
		"expected 0 (true) at boundary"
fi

# =============================================================================
# Test 2: _rest_should_fallback returns 1 (false) when remaining > 10
# =============================================================================
STUB_RATE_LIMIT_REMAINING=100
if ! _rest_should_fallback; then
	pass "should_fallback returns false when remaining=100"
else
	fail "should_fallback returns false when remaining=100" \
		"expected non-zero (false) but got 0 (true)"
fi

# =============================================================================
# Test 3: _rest_should_fallback fail-safe when rate_limit unparseable
# Stub returns non-numeric — fallback should NOT activate (fail-safe: let
# caller see original error rather than running REST call that may also fail).
# =============================================================================
STUB_RATE_LIMIT_REMAINING="unknown"
if ! _rest_should_fallback; then
	pass "should_fallback returns false when rate_limit unparseable (fail-safe)"
else
	fail "should_fallback returns false when rate_limit unparseable (fail-safe)" \
		"expected false but got true — would trigger unnecessary REST fallback"
fi

# Reset for remaining tests
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 4: _rest_issue_create → POST /repos/.../issues with correct args
# =============================================================================
: >"$GH_CALLS"
_rest_issue_create \
	--repo "owner/repo" \
	--title "t9991: test create" \
	--body "test body" \
	--label "bug,auto-dispatch" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'title=t9991: test create' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=bug' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=auto-dispatch' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_create translates to POST /repos/.../issues with labels"
else
	fail "_rest_issue_create translates to POST /repos/.../issues with labels" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 5: _rest_issue_create uses -F body=@file (for newline/unicode safety)
# =============================================================================
: >"$GH_CALLS"
_rest_issue_create \
	--repo "owner/repo" \
	--title "t9992: newline test" \
	--body "line1
line2
line3" >/dev/null 2>&1 || true

if grep -qE 'body=@/.*aidevops-gh-rest-body' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_create uses -F body=@tmpfile for body"
else
	fail "_rest_issue_create uses -F body=@tmpfile for body" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 6: _rest_issue_comment translates --body → POST .../comments
# =============================================================================
: >"$GH_CALLS"
_rest_issue_comment 12345 \
	--repo "owner/repo" \
	--body "test comment" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues/12345/comments' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_comment translates to POST /issues/N/comments"
else
	fail "_rest_issue_comment translates to POST /issues/N/comments" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 7: _rest_issue_comment extracts repo + num from a URL argument
# =============================================================================
: >"$GH_CALLS"
_rest_issue_comment "https://github.com/owner/repo/issues/777" \
	--body "url-form comment" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues/777/comments' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_comment extracts repo+num from URL"
else
	fail "_rest_issue_comment extracts repo+num from URL" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 8: _rest_issue_edit computes full labels array from add/remove deltas
# Current labels stub returns "bug" (single label). We add "auto-dispatch",
# remove "bug" — target set should be ["auto-dispatch"] only.
# =============================================================================
: >"$GH_CALLS"
export STUB_CURRENT_LABELS="bug"
_rest_issue_edit 42 \
	--repo "owner/repo" \
	--add-label "auto-dispatch" \
	--remove-label "bug" >/dev/null 2>&1 || true

if grep -qE 'labels\[\]=auto-dispatch' "$GH_CALLS" 2>/dev/null &&
	! grep -qE 'labels\[\]=bug' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_issue_edit computes target label set (add auto-dispatch, remove bug)"
else
	fail "_rest_issue_edit computes target label set (add auto-dispatch, remove bug)" \
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
# Test 12: _rest_pr_create → POST /repos/.../pulls with correct args
# =============================================================================
: >"$GH_CALLS"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9993: test PR create" \
	--head "feature/t9993-test" \
	--base "main" \
	--body "PR body" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'title=t9993: test PR create' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'head=feature/t9993-test' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'base=main' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create translates to POST /repos/.../pulls with head/base/title"
else
	fail "_rest_pr_create translates to POST /repos/.../pulls with head/base/title" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 13: _rest_pr_create uses -F body=@file for body
# =============================================================================
: >"$GH_CALLS"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9994: body file test" \
	--head "feature/t9994-body" \
	--base "main" \
	--body "line1
line2
line3" >/dev/null 2>&1 || true

if grep -qE 'body=@/.*aidevops-gh-rest-body' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create uses -F body=@tmpfile for body"
else
	fail "_rest_pr_create uses -F body=@tmpfile for body" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 14: _rest_pr_create applies labels via POST /repos/.../issues/{N}/labels
# The stub returns https://github.com/owner/repo/issues/9999 for REST calls,
# so label call should target issues/9999/labels.
# =============================================================================
: >"$GH_CALLS"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9995: label test" \
	--head "feature/t9995-labels" \
	--base "main" \
	--label "origin:worker,auto-dispatch" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues/[0-9]+/labels' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=origin:worker' "$GH_CALLS" 2>/dev/null &&
	grep -qE 'labels\[\]=auto-dispatch' "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create applies labels via POST /issues/{N}/labels"
else
	fail "_rest_pr_create applies labels via POST /issues/{N}/labels" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 15: gh_pr_comment → falls back to REST when primary fails AND exhausted
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

gh_pr_comment 8888 --repo "owner/repo" --body "fallback pr comment" >/dev/null 2>&1 || true

if grep -qE '^pr comment 8888' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api.*-X POST.*/repos/owner/repo/issues/8888/comments' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_comment falls back to REST when primary fails AND exhausted"
else
	fail "gh_pr_comment falls back to REST when primary fails AND exhausted" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

if grep -qE 'GraphQL exhausted.*falling back to REST' "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "gh_pr_comment emits fallback log line"
else
	fail "gh_pr_comment emits fallback log line" \
		"INFO log: $(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 16: gh_pr_comment → does NOT fall back when primary succeeds
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
gh_pr_comment 8889 --repo "owner/repo" --body "success pr comment" >/dev/null 2>&1 || true

if grep -qE '^pr comment 8889' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/issues/8889/comments' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_comment does NOT fall back when primary succeeds"
else
	fail "gh_pr_comment does NOT fall back when primary succeeds" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 17: gh_pr_comment → does NOT fall back when primary fails but healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=5000

gh_pr_comment 8890 --repo "owner/repo" --body "healthy pr fail" >/dev/null 2>&1 || true

if grep -qE '^pr comment 8890' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/issues/8890/comments' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_comment does NOT fall back when primary fails but healthy"
else
	fail "gh_pr_comment does NOT fall back when primary fails but healthy" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 18: gh_create_pr → falls back to REST when primary fails AND exhausted
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

gh_create_pr \
	--repo "owner/repo" \
	--title "t9996: fallback test" \
	--head "feature/t9996-fallback" \
	--base "main" \
	--body "fallback body" >/dev/null 2>&1 || true

# Verify: primary was called AND rate_limit was checked AND REST was called
if grep -qE '^pr create' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api.*-X POST.*/repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null; then
	pass "gh_create_pr falls back to REST when primary fails AND exhausted"
else
	fail "gh_create_pr falls back to REST when primary fails AND exhausted" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

if grep -qE 'GraphQL exhausted.*falling back to REST' "$GH_INFO_OUTPUT" 2>/dev/null; then
	pass "gh_create_pr emits fallback log line"
else
	fail "gh_create_pr emits fallback log line" \
		"INFO log: $(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 19: gh_create_pr → does NOT fall back when primary succeeds
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"

gh_create_pr \
	--repo "owner/repo" \
	--title "t9997: success test" \
	--head "feature/t9997-success" \
	--base "main" \
	--body "success body" >/dev/null 2>&1 || true

if grep -qE '^pr create' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null; then
	pass "gh_create_pr does NOT fall back when primary succeeds"
else
	fail "gh_create_pr does NOT fall back when primary succeeds" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 20: gh_create_pr → does NOT fall back when primary fails but healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=5000

gh_create_pr \
	--repo "owner/repo" \
	--title "t9998: healthy fail test" \
	--head "feature/t9998-healthy" \
	--base "main" \
	--body "healthy fail" >/dev/null 2>&1 || true

if grep -qE '^pr create' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api.*-X POST.*/repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null; then
	pass "gh_create_pr does NOT fall back when primary fails but healthy"
else
	fail "gh_create_pr does NOT fall back when primary fails but healthy" \
		"GH_CALLS=$(cat "$GH_CALLS")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 21: _rest_pr_create auto-detects --head from git HEAD when omitted
# Verifies that omitting --head causes the current branch to be used as head.
# =============================================================================
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
: >"$GH_CALLS"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9999: auto-head test" \
	--base "main" \
	--body "auto-detect head body" >/dev/null 2>&1 || true

if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
	pass "_rest_pr_create auto-detects --head skipped in detached HEAD rebase context"
elif [[ -n "$CURRENT_BRANCH" ]] && grep -qE "head=${CURRENT_BRANCH}" "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create auto-detects --head from git HEAD when omitted"
else
	fail "_rest_pr_create auto-detects --head from git HEAD when omitted" \
		"expected head=${CURRENT_BRANCH} in calls; GH_CALLS=$(cat "$GH_CALLS")"
fi

# =============================================================================
# Test 22: _rest_pr_create auto-detects --base from repo default_branch
# Uses STUB_REPO_DEFAULT_BRANCH=develop to verify REST resolution path.
# =============================================================================
: >"$GH_CALLS"
export STUB_REPO_DEFAULT_BRANCH="develop"
_rest_pr_create \
	--repo "owner/repo" \
	--title "t9999: auto-base test" \
	--head "feature/t9999-auto-base" \
	--body "auto-detect base body" >/dev/null 2>&1 || true

if grep -qE "base=develop" "$GH_CALLS" 2>/dev/null; then
	pass "_rest_pr_create auto-detects --base from repo default_branch via REST"
else
	fail "_rest_pr_create auto-detects --base from repo default_branch via REST" \
		"expected base=develop in calls; GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_REPO_DEFAULT_BRANCH

# =============================================================================
# Test 20: gh_issue_view routes directly to REST when GraphQL remaining is low
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

gh_issue_view 4242 --repo "owner/repo" --json number --jq '.number' >/dev/null 2>&1 || true

if grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api /repos/owner/repo/issues/4242' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue view 4242' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_view proactively routes to REST when GraphQL budget is low"
else
	fail "gh_issue_view proactively routes to REST when GraphQL budget is low" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 21: gh_issue_list keeps the primary path when GraphQL is healthy
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=5000

gh_issue_list --repo "owner/repo" --state open --json number --jq length >/dev/null 2>&1 || true

if grep -qE '^issue list' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/issues\?' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list uses primary path when GraphQL budget is healthy"
else
	fail "gh_issue_list uses primary path when GraphQL budget is healthy" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 22: gh_issue_list preserves --search by routing low-budget calls to search
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

gh_issue_list --repo "owner/repo" --search "fallback" --state open --json number --jq '.[0].number' >/dev/null 2>&1 || true

if grep -qE '^api /search/issues\?' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list proactively routes --search to /search/issues"
else
	fail "gh_issue_list proactively routes --search to /search/issues" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 23: gh_pr_list routes directly to REST when GraphQL remaining is low
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

gh_pr_list --repo "owner/repo" --state open --json number --jq length >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^pr list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list proactively routes to REST when GraphQL budget is low"
else
	fail "gh_pr_list proactively routes to REST when GraphQL budget is low" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 23b: gh_pr_list REST fallback preserves --head and gh-shaped JSON output
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

pr_list_numbers=$(gh_pr_list --repo "owner/repo" --head "feature/auto-20260502-135611-gh22289" \
	--state all --json number,state,mergedAt,url --jq '.[].number' 2>/dev/null || true)

if [[ "$pr_list_numbers" == "22337" ]] &&
	grep -qE '^api /repos/owner/repo/pulls\?state=all&per_page=30&head=owner%3Afeature%2Fauto-20260502-135611-gh22289' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^pr list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list REST fallback preserves --head and compact --json/--jq shape"
else
	fail "gh_pr_list REST fallback preserves --head and compact --json/--jq shape" \
		"output=${pr_list_numbers} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 23c: gh_issue_list REST fallback preserves gh-shaped JSON output
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

issue_list_title=$(gh_issue_list --repo "owner/repo" --state open \
	--json number,title,url,assignees,labels,updatedAt --jq '.[0].title' 2>/dev/null || true)

if [[ "$issue_list_title" == '"Reduce GraphQL list-call pressure"' ]] &&
	grep -qE '^api /repos/owner/repo/issues\?state=open&per_page=30' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue list' "$GH_CALLS" 2>/dev/null; then
	pass "gh_issue_list REST fallback preserves compact --json/--jq shape"
else
	fail "gh_issue_list REST fallback preserves compact --json/--jq shape" \
		"output=${issue_list_title} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 24: gh_pr_list keeps --search on GraphQL path when budget is low
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

gh_pr_list --repo "owner/repo" --search "fallback" --state open --json number --jq length >/dev/null 2>&1 || true

if grep -qE '^pr list' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list leaves --search on primary path when REST cannot preserve semantics"
else
	fail "gh_pr_list leaves --search on primary path when REST cannot preserve semantics" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 25: gh_pr_view routes directly to REST when GraphQL remaining is low
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0

gh_pr_view 123 --repo "owner/repo" --json number,title --jq '.number' >/dev/null 2>&1 || true

if grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api /repos/owner/repo/pulls/123' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^pr view 123' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_view proactively routes to REST when GraphQL budget is low"
else
	fail "gh_pr_view proactively routes to REST when GraphQL budget is low" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

# =============================================================================
# Test 25b: REST PR view normalizes REST boolean mergeable to gh GraphQL enum
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_VIEW_FIXTURE='{"number":123,"mergeable":true}'

pr_view_mergeable=$(gh_pr_view 123 --repo "owner/repo" --json mergeable --jq '.mergeable' 2>/dev/null || true)

if [[ "$pr_view_mergeable" == "MERGEABLE" ]]; then
	pass "gh_pr_view REST fallback normalizes mergeable=true to MERGEABLE"
else
	fail "gh_pr_view REST fallback normalizes mergeable=true to MERGEABLE" \
		"output=${pr_view_mergeable} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_VIEW_FIXTURE

# =============================================================================
# Test 25d: REST PR view normalizes null mergeable to UNKNOWN
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_VIEW_FIXTURE='{"number":123,"mergeable":null}'

pr_view_mergeable=$(gh_pr_view 123 --repo "owner/repo" --json mergeable --jq '.mergeable' 2>/dev/null || true)

if [[ "$pr_view_mergeable" == "UNKNOWN" ]]; then
	pass "gh_pr_view REST fallback normalizes mergeable=null to UNKNOWN"
else
	fail "gh_pr_view REST fallback normalizes mergeable=null to UNKNOWN" \
		"output=${pr_view_mergeable} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_VIEW_FIXTURE

# =============================================================================
# Test 25e: PR view cache coalesces duplicate REST reads for the same repo#PR
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_VIEW_FIXTURE='{"number":123,"title":"cached title","mergeable":true}'
export AIDEVOPS_GH_PR_VIEW_CACHE=1
export AIDEVOPS_GH_PR_VIEW_CACHE_DIR="${TMP}/pr_view_cache"
rm -rf "$AIDEVOPS_GH_PR_VIEW_CACHE_DIR"

pr_view_cached_title=$(gh_pr_view 123 --repo "owner/repo" --json title --jq '.title' 2>/dev/null || true)
pr_view_cached_mergeable=$(gh_pr_view 123 --repo "owner/repo" --json mergeable --jq '.mergeable' 2>/dev/null || true)
pr_view_rest_calls=$(grep -cE '^api /repos/owner/repo/pulls/123$' "$GH_CALLS" 2>/dev/null || true)

if [[ "$pr_view_cached_title" == "cached title" && "$pr_view_cached_mergeable" == "MERGEABLE" && "$pr_view_rest_calls" == "1" ]]; then
	pass "gh_pr_view cache coalesces duplicate REST reads for same repo#PR"
else
	fail "gh_pr_view cache coalesces duplicate REST reads for same repo#PR" \
		"title=${pr_view_cached_title} mergeable=${pr_view_cached_mergeable} rest_calls=${pr_view_rest_calls} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_VIEW_FIXTURE
unset AIDEVOPS_GH_PR_VIEW_CACHE
unset AIDEVOPS_GH_PR_VIEW_CACHE_DIR

# =============================================================================
# Test 25c: REST PR list normalizes REST boolean mergeable to gh GraphQL enum
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_LIST_FIXTURE='[{"number":22337,"mergeable":false,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"feature/rest-mergeable"},"base":{"ref":"main"}}]'

pr_list_mergeable=$(gh_pr_list --repo "owner/repo" --state open --json mergeable --jq '.[0].mergeable' 2>/dev/null || true)

if [[ "$pr_list_mergeable" == "CONFLICTING" || "$pr_list_mergeable" == '"CONFLICTING"' ]]; then
	pass "gh_pr_list REST fallback normalizes mergeable=false to CONFLICTING"
else
	fail "gh_pr_list REST fallback normalizes mergeable=false to CONFLICTING" \
		"output=${pr_list_mergeable} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_LIST_FIXTURE

# =============================================================================
# Test 25e: REST PR list normalizes missing mergeable to UNKNOWN
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=0
export STUB_PR_LIST_FIXTURE='[{"number":22337,"state":"open","merged_at":null,"html_url":"https://github.com/owner/repo/pull/22337","head":{"ref":"feature/rest-mergeable"},"base":{"ref":"main"}}]'

pr_list_mergeable=$(gh_pr_list --repo "owner/repo" --state open --json mergeable --jq '.[0].mergeable' 2>/dev/null || true)

if [[ "$pr_list_mergeable" == "UNKNOWN" || "$pr_list_mergeable" == '"UNKNOWN"' ]]; then
	pass "gh_pr_list REST fallback normalizes missing mergeable to UNKNOWN"
else
	fail "gh_pr_list REST fallback normalizes missing mergeable to UNKNOWN" \
		"output=${pr_list_mergeable} GH_CALLS=$(cat "$GH_CALLS")"
fi
unset STUB_PR_LIST_FIXTURE

# =============================================================================
# Test 26: forced REST read mode routes supported list calls without rate_limit
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=5000
export AIDEVOPS_GH_FORCE_REST_READS=1

gh_issue_list --repo "owner/repo" --state open --json number --jq length >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/issues\?' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue list' "$GH_CALLS" 2>/dev/null; then
	pass "AIDEVOPS_GH_FORCE_REST_READS routes issue list to REST without rate_limit probe"
else
	fail "AIDEVOPS_GH_FORCE_REST_READS routes issue list to REST without rate_limit probe" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi
unset AIDEVOPS_GH_FORCE_REST_READS

# =============================================================================
# Test 27: REST-first read mode shares pools without probing GraphQL budget
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_RATE_LIMIT_REMAINING=5000
export AIDEVOPS_GH_REST_FIRST_READS=1

gh_issue_list --repo "owner/repo" --state open --json number --jq length >/dev/null 2>&1 || true
gh_pr_list --repo "owner/repo" --state all --json createdAt --limit 200 >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/issues\?' "$GH_CALLS" 2>/dev/null &&
	grep -qE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api rate_limit' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^(issue|pr) list' "$GH_CALLS" 2>/dev/null; then
	pass "AIDEVOPS_GH_REST_FIRST_READS routes REST-equivalent reads without rate_limit probe"
else
	fail "AIDEVOPS_GH_REST_FIRST_READS routes REST-equivalent reads without rate_limit probe" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
gh_pr_list --repo "owner/repo" --state open --json number,reviewDecision,headRefOid --limit 30 >/dev/null 2>&1 || true

if grep -qE '^pr list' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null; then
	pass "AIDEVOPS_GH_REST_FIRST_READS leaves GraphQL-only pr list fields on GraphQL"
else
	fail "AIDEVOPS_GH_REST_FIRST_READS leaves GraphQL-only pr list fields on GraphQL" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export AIDEVOPS_GH_PR_LIST_CACHE_DIR="$TMP/pr-list-cache"
export AIDEVOPS_GH_PR_LIST_CACHE_TTL=30
gh_pr_list --repo "owner/repo" --state open --json number --jq length --limit 200 >/dev/null 2>&1 || true
gh_pr_list --repo "owner/repo" --state open --json number --jq length --limit 200 >/dev/null 2>&1 || true

pr_pull_calls=$(grep -cE '^api /repos/owner/repo/pulls\?' "$GH_CALLS" 2>/dev/null || true)
if [[ "$pr_pull_calls" == "1" ]]; then
	pass "gh_pr_list short-lived snapshot cache coalesces identical open PR reads"
else
	fail "gh_pr_list short-lived snapshot cache coalesces identical open PR reads" \
		"pull_calls=${pr_pull_calls} GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi
unset AIDEVOPS_GH_PR_LIST_CACHE_DIR AIDEVOPS_GH_PR_LIST_CACHE_TTL

unset AIDEVOPS_GH_REST_FIRST_READS

# =============================================================================
# Test 28: gh_pr_list --search → no non-equivalent REST fallback
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
export STUB_PRIMARY_FAIL=1
export STUB_RATE_LIMIT_REMAINING=0

gh_pr_list --repo "owner/repo" --state open --search "Resolves #42 in:body" \
	--json number --limit 5 >/dev/null 2>&1 || true

if grep -qE '^pr list' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^api /repos/owner/repo/pulls' "$GH_CALLS" 2>/dev/null; then
	pass "gh_pr_list --search preserves semantics by skipping REST fallback"
else
	fail "gh_pr_list --search preserves semantics by skipping REST fallback" \
		"GH_CALLS=$(cat "$GH_CALLS") | INFO=$(cat "$GH_INFO_OUTPUT")"
fi

unset STUB_PRIMARY_FAIL
export STUB_RATE_LIMIT_REMAINING=5000

# =============================================================================
# Test 27: GitHub App auth routes REST-equivalent reads through app token
# =============================================================================
: >"$GH_CALLS"
: >"$GH_INFO_OUTPUT"
: >"$GH_APP_TOKEN_CALLS"
export AIDEVOPS_GITHUB_APP_CACHE_DIR="$TMP/app-cache"
export AIDEVOPS_GITHUB_APP_ENABLED=1
export AIDEVOPS_GITHUB_APP_ID=123
export AIDEVOPS_GITHUB_APP_INSTALLATION_ID=456
export AIDEVOPS_GITHUB_APP_REST_FIRST=1
_github_app_cache_token "456" "cached-app-token" "2099-01-01T00:00:00Z"

gh_issue_view 4243 --repo "owner/repo" --json number --jq '.number' >/dev/null 2>&1 || true

if grep -qE '^api /repos/owner/repo/issues/4243' "$GH_CALLS" 2>/dev/null &&
	! grep -qE '^issue view 4243' "$GH_CALLS" 2>/dev/null &&
	grep -q 'cached-app-token' "$GH_APP_TOKEN_CALLS" 2>/dev/null; then
	pass "GitHub App auth routes REST-equivalent issue view through app token"
else
	fail "GitHub App auth routes REST-equivalent issue view through app token" \
		"GH_CALLS=$(cat "$GH_CALLS") | TOKENS=$(cat "$GH_APP_TOKEN_CALLS")"
fi

unset AIDEVOPS_GITHUB_APP_ENABLED AIDEVOPS_GITHUB_APP_ID AIDEVOPS_GITHUB_APP_INSTALLATION_ID AIDEVOPS_GITHUB_APP_REST_FIRST

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
