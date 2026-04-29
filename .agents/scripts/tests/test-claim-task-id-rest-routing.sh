#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-rest-routing.sh — t3039 regression guard.
#
# Verifies that issue creation in both claim-task-id.sh and
# issue-sync-helper-push.sh routes through REST when GraphQL is exhausted.
#
# Problem (GH#21627, t3039): when GraphQL budget was 0/5000, the
# claim-task-id.sh bare fallback path used raw `gh issue create` which
# is itself GraphQL-backed and fails with the same rate-limit error.
# issue-sync-helper-push.sh had the same gap: _push_create_issue called
# `gh issue create` directly with no REST escape hatch.
#
# Fix:
#   - claim-task-id.sh: bare fallback now calls gh_create_issue
#     (REST-aware wrapper from shared-gh-wrappers.sh). gh_create_issue
#     detects exhaustion via _gh_should_fallback_to_rest and retries via
#     _gh_issue_create_rest (POST /repos/.../issues).
#   - issue-sync-helper-push.sh: _push_create_issue adds an inline REST
#     fallback after a non-zero exit from gh issue create: calls
#     _gh_issue_create_rest directly when _gh_should_fallback_to_rest.
#
# Tests:
#   1. gh_create_issue routes to REST (gh api -X POST) when GraphQL exhausted
#      and primary gh issue create fails — baseline for the claim-task-id path.
#   2. gh_create_issue does NOT call REST when primary succeeds.
#   3. gh_create_issue does NOT call REST when primary fails but GraphQL healthy.
#   4. _push_create_issue falls back to REST when GraphQL exhausted + primary fails.
#   5. _push_create_issue does NOT fall back when primary succeeds.
#   6. _push_create_issue does NOT fall back when primary fails but GraphQL healthy.
#
# Stub strategy: define `gh` as a shell function after sourcing helpers.
# Shell functions take precedence over PATH binaries.
# _GH_SHOULD_FALLBACK_OVERRIDE=1 forces _gh_should_fallback_to_rest to return
# true without requiring a real rate_limit call.
#
# Cross-references: GH#21627 / t3039 (fix), t2574 (REST fallback system).

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
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t3039.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"
GH_INFO_OUTPUT="${TMP}/info_output.log"

# Suppress output noise from sourced libraries before sourcing.
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
log_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
log_warn() { printf '[WARN] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
export -f print_info print_warning print_error print_success log_verbose
export -f log_info log_warn

export AIDEVOPS_SESSION_ORIGIN=worker
export AIDEVOPS_SESSION_USER=testuser

# Lock REST threshold to 10 so the tests exercise the logic without
# requiring a real rate_limit call (matching test-gh-wrapper-rest-fallback.sh).
export AIDEVOPS_GH_REST_FALLBACK_THRESHOLD=10

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true

# Re-override print_info AFTER sourcing to restore our capturing stub.
# shellcheck disable=SC2317
print_info() { printf '[INFO] %s\n' "$*" >>"${GH_INFO_OUTPUT}"; return 0; }
export -f print_info

# =============================================================================
# Stubs for issue-sync-helper-push.sh dependencies
# =============================================================================
# These are used only in Tests 4-6 when _push_create_issue is tested.
ensure_labels_exist() { return 0; }
gh_create_label() { return 0; }
gh_find_issue_by_title() { printf '%s\n' ""; return 0; }
add_gh_ref_to_todo() { return 0; }
strip_code_fences() { cat; return 0; }
export -f ensure_labels_exist gh_create_label gh_find_issue_by_title
export -f add_gh_ref_to_todo strip_code_fences

# Source issue-sync-helper-push.sh for _push_create_issue
# shellcheck source=../issue-sync-helper-push.sh
source "${SCRIPTS_DIR}/issue-sync-helper-push.sh" >/dev/null 2>&1 || true

# =============================================================================
# gh stub — configurable via env vars:
#   STUB_PRIMARY_FAIL=1   → make `gh issue create` return non-zero
#   STUB_REST_FAIL=1      → make REST POST fail
# =============================================================================
gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"

	# Rate limit endpoint — returns configured remaining value
	if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
		printf '%s\n' "${STUB_RATE_LIMIT_REMAINING:-5000}"
		return 0
	fi

	# User endpoint — for _gh_wrapper_auto_assignee
	if [[ "$1" == "api" && "$2" == "user" ]]; then
		printf '"testuser"\n'
		return 0
	fi

	# REST API calls: POST/PATCH endpoints — succeed unless STUB_REST_FAIL=1
	if [[ "$1" == "api" && ( "${2:-}" == "-X" || "${2:-}" =~ ^-X ) ]]; then
		if [[ "${STUB_REST_FAIL:-0}" == "1" ]]; then
			printf 'REST stub forced failure\n' >&2
			return 1
		fi
		printf 'https://github.com/owner/repo/issues/9999\n'
		return 0
	fi

	# gh issue create — primary path; fail if STUB_PRIMARY_FAIL=1
	if [[ "$1" == "issue" && "$2" == "create" ]]; then
		if [[ "${STUB_PRIMARY_FAIL:-0}" == "1" ]]; then
			printf 'GraphQL: API rate limit already exceeded\n' >&2
			return 1
		fi
		printf 'https://github.com/owner/repo/issues/9000\n'
		return 0
	fi

	# gh label create, gh issue edit, and other side-effect calls — silent success
	return 0
}
export -f gh

printf '%sRunning claim-task-id REST routing tests (t3039 / GH#21627)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Tests 1-3: gh_create_issue REST routing (covers the claim-task-id.sh path)
# gh_create_issue is the wrapper now called by create_github_issue's fallback.
# These tests verify the wrapper itself routes correctly.
# =============================================================================

# Test 1: gh_create_issue → REST when GraphQL exhausted AND primary fails
: >"$GH_CALLS"
STUB_PRIMARY_FAIL=1 STUB_RATE_LIMIT_REMAINING=0 \
	gh_create_issue \
		--repo "owner/repo" \
		--title "t9991: rest-routing test" \
		--body "test body" \
		--label "bug,status:available" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null; then
	pass "gh_create_issue routes to REST when GraphQL exhausted (issue create path)"
else
	fail "gh_create_issue routes to REST when GraphQL exhausted (issue create path)" \
		"expected 'api -X POST /repos/owner/repo/issues' in GH_CALLS; got: $(cat "$GH_CALLS")"
fi

# Test 2: gh_create_issue does NOT call REST when primary succeeds
: >"$GH_CALLS"
STUB_PRIMARY_FAIL=0 STUB_RATE_LIMIT_REMAINING=0 \
	gh_create_issue \
		--repo "owner/repo" \
		--title "t9992: no-rest-if-primary-ok" \
		--body "test body" \
		--label "bug,status:available" >/dev/null 2>&1 || true

if ! grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null; then
	pass "gh_create_issue does NOT call REST when primary succeeds"
else
	fail "gh_create_issue does NOT call REST when primary succeeds" \
		"REST was called despite primary success"
fi

# Test 3: gh_create_issue does NOT fall back when GraphQL healthy (> threshold)
: >"$GH_CALLS"
STUB_PRIMARY_FAIL=1 STUB_RATE_LIMIT_REMAINING=5000 \
	gh_create_issue \
		--repo "owner/repo" \
		--title "t9993: no-rest-if-graphql-ok" \
		--body "test body" \
		--label "bug,status:available" >/dev/null 2>&1 || true

if ! grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null; then
	pass "gh_create_issue does NOT fall back when GraphQL budget is healthy"
else
	fail "gh_create_issue does NOT fall back when GraphQL budget is healthy" \
		"REST was called despite healthy GraphQL budget"
fi

# =============================================================================
# Tests 4-6: _push_create_issue REST routing (issue-sync-helper-push.sh path)
# =============================================================================

# Helper: reset shared state between _push_create_issue calls
reset_push_state() {
	_PUSH_CREATED_NUM=""
	: >"$GH_CALLS"
	: >"$GH_INFO_OUTPUT"
	return 0
}

# Create a minimal todo file for _push_create_issue
TODO_FILE="${TMP}/TODO.md"
printf '%s\n' '- [ ] t9994 Test task ref:GH#0' >"$TODO_FILE"

# Test 4: _push_create_issue falls back to REST when GraphQL exhausted + primary fails
reset_push_state
STUB_PRIMARY_FAIL=1 STUB_RATE_LIMIT_REMAINING=0 \
	_push_create_issue \
		"t9994" "owner/repo" "$TODO_FILE" \
		"t9994: rest fallback test" \
		"test body" \
		"bug,status:available" \
		"" >/dev/null 2>&1 || true

if grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null; then
	pass "_push_create_issue falls back to REST when GraphQL exhausted + primary fails"
else
	fail "_push_create_issue falls back to REST when GraphQL exhausted + primary fails" \
		"expected 'api -X POST /repos/owner/repo/issues' in GH_CALLS; got: $(cat "$GH_CALLS")"
fi

# Test 5: _push_create_issue does NOT call REST when primary succeeds
reset_push_state
STUB_PRIMARY_FAIL=0 STUB_RATE_LIMIT_REMAINING=0 \
	_push_create_issue \
		"t9994" "owner/repo" "$TODO_FILE" \
		"t9994: no-rest-if-primary-ok" \
		"test body" \
		"bug,status:available" \
		"" >/dev/null 2>&1 || true

if ! grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null; then
	pass "_push_create_issue does NOT call REST when primary succeeds"
else
	fail "_push_create_issue does NOT call REST when primary succeeds" \
		"REST was called despite primary success in _push_create_issue"
fi

# Test 6: _push_create_issue does NOT fall back when GraphQL budget is healthy
reset_push_state
STUB_PRIMARY_FAIL=1 STUB_RATE_LIMIT_REMAINING=5000 \
	_push_create_issue \
		"t9994" "owner/repo" "$TODO_FILE" \
		"t9994: no-rest-if-graphql-ok" \
		"test body" \
		"bug,status:available" \
		"" >/dev/null 2>&1 || true

if ! grep -qE '^api.*-X POST.*/repos/owner/repo/issues' "$GH_CALLS" 2>/dev/null; then
	pass "_push_create_issue does NOT fall back when GraphQL budget is healthy"
else
	fail "_push_create_issue does NOT fall back when GraphQL budget is healthy" \
		"REST was called despite healthy GraphQL budget in _push_create_issue"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%s%d/%d tests passed%s\n' \
	"$TEST_BLUE" "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TEST_NC"

if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi
exit 0
