#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-commit-and-pr-partial-success.sh — t2767 regression guard.
#
# Verifies that _create_pr() and _post_merge_summary() in full-loop-helper.sh
# handle partial-success failures correctly:
#
#   1. PR creation partial-success recovery:
#      When gh_create_pr returns non-zero but a PR already exists for the
#      current branch (e.g. GitHub created the PR but a follow-up GraphQL
#      mutation failed), _create_pr() must recover and return 0 with the
#      correct PR number — not bail with exit 1.
#
#   2. PR creation hard failure:
#      When gh_create_pr returns non-zero AND no PR exists for the branch,
#      _create_pr() must return 1 with an error message.
#
#   3. Merge-summary idempotency:
#      When _post_merge_summary() is called a second time and a MERGE_SUMMARY
#      comment already exists on the PR, it must skip posting and return 0
#      (no duplicate comment).
#
#   4. Merge-summary first post:
#      When no MERGE_SUMMARY comment exists, _post_merge_summary() must
#      post the comment and return 0.
#
# Stub strategy: define gh, gh_create_pr, _gh_recover_pr_if_exists,
# gh_pr_comment, and git as shell functions AFTER extracting the tested
# functions. Shell functions take precedence over PATH binaries. The
# _SOURCING_FOR_TEST guard prevents full-loop-helper.sh's main entrypoint
# from running during extraction.
#
# Cross-reference: GH#20634 / t2767 (fix), PR #20616 (original failure).

# NOT using set -e — negative assertions rely on non-zero exits
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
TMP=$(mktemp -d -t t2767.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

STUB_LOG="${TMP}/stub_calls.log"
GH_API_RESPONSE="${TMP}/gh_api_response.txt"
: >"$STUB_LOG"
printf '0\n' >"$GH_API_RESPONSE"  # default: 0 existing MERGE_SUMMARY comments

# =============================================================================
# Minimal stubs for shared-constants.sh symbols required by full-loop-helper.sh
# =============================================================================
if [[ -z "${NC+x}" ]]; then
	NC=$'\033[0m'
	RED=$'\033[0;31m'
	GREEN=$'\033[0;32m'
	YELLOW=$'\033[0;33m'
	BLUE=$'\033[0;34m'
	PURPLE=$'\033[0;35m'
	CYAN=$'\033[0;36m'
	WHITE=$'\033[0;37m'
	BOLD=$'\033[1m'
fi

# Quiet print stubs — capture to log for assertions
print_info()    { printf '[INFO] %s\n' "$*" >>"$STUB_LOG"; return 0; }
print_error()   { printf '[ERROR] %s\n' "$*" >>"$STUB_LOG"; return 0; }
print_warning() { printf '[WARN] %s\n' "$*" >>"$STUB_LOG"; return 0; }
print_success() { printf '[OK] %s\n' "$*" >>"$STUB_LOG"; return 0; }

# =============================================================================
# Extract the functions under test directly from the helper.
# Extraction uses sed to pull from function declaration to closing brace.
# The _SOURCING_FOR_TEST sentinel prevents main entrypoint execution.
# =============================================================================
_SOURCING_FOR_TEST=1

# Extract _create_pr
# shellcheck disable=SC2312
eval "$(sed -n '/^_create_pr() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper.sh")"

# Extract _post_merge_summary
# shellcheck disable=SC2312
eval "$(sed -n '/^_post_merge_summary() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper.sh")"

# =============================================================================
# Post-extraction stubs (override PATH binaries and define missing deps).
# Defined after eval so they take precedence over any stubs extracted from helper.
# =============================================================================

# Stub: git branch --show-current → always returns "feature/t2767-test"
git() {
	if [[ "${1:-}" == "branch" && "${2:-}" == "--show-current" ]]; then
		printf 'feature/t2767-test\n'
		return 0
	fi
	command git "$@"
	return $?
}
export -f git

# Control variable: set to 1 to simulate gh_create_pr partial success
GH_CREATE_PR_FAIL=0
# Control variable: the URL to return from gh_create_pr on success
GH_CREATE_PR_URL="https://github.com/owner/repo/pull/999"

# Stub: gh_create_pr — honours GH_CREATE_PR_FAIL
# On failure, outputs an error message (like real gh does) and returns 1.
gh_create_pr() {
	printf 'gh_create_pr %s\n' "$*" >>"$STUB_LOG"
	if [[ "$GH_CREATE_PR_FAIL" -eq 1 ]]; then
		printf 'pull request update failed: GraphQL: Something went wrong\n' >&2
		return 1
	fi
	printf '%s\n' "$GH_CREATE_PR_URL"
	return 0
}
export -f gh_create_pr

# Control variable: PR URL to return from _gh_recover_pr_if_exists
GH_RECOVER_PR_URL=""

# Stub: _gh_recover_pr_if_exists — honours GH_RECOVER_PR_URL
# Returns the URL if set (simulating PR exists), empty string otherwise.
_gh_recover_pr_if_exists() {
	printf '_gh_recover_pr_if_exists branch=%s repo=%s\n' "${1:-}" "${2:-}" >>"$STUB_LOG"
	printf '%s\n' "${GH_RECOVER_PR_URL:-}"
	return 0
}
export -f _gh_recover_pr_if_exists

# Control variable: set to non-empty to simulate MERGE_SUMMARY already existing
GH_EXISTING_MERGE_SUMMARY_COUNT=0

# Stub: gh — handles the gh api call for MERGE_SUMMARY check, plus pr comment
gh() {
	printf 'gh %s\n' "$*" >>"$STUB_LOG"
	# Handle: gh api repos/.../issues/.../comments --jq '...'
	if [[ "${1:-}" == "api" ]]; then
		printf '%s\n' "$GH_EXISTING_MERGE_SUMMARY_COUNT"
		return 0
	fi
	# Handle: gh pr comment ... (simulated via gh_pr_comment stub below)
	return 0
}
export -f gh

# Stub: gh_pr_comment — records call, returns 0
gh_pr_comment() {
	printf 'gh_pr_comment pr=%s\n' "${1:-}" >>"$STUB_LOG"
	return 0
}
export -f gh_pr_comment

# =============================================================================
# Test 1: _create_pr partial-success recovery
# gh_create_pr returns non-zero, but _gh_recover_pr_if_exists finds the PR.
# Expected: _create_pr returns 0 and outputs the correct PR number (999).
# =============================================================================
: >"$STUB_LOG"
GH_CREATE_PR_FAIL=1
GH_RECOVER_PR_URL="https://github.com/owner/repo/pull/999"

actual_pr_number=""
actual_rc=0
actual_pr_number=$(_create_pr "owner/repo" "t2767: test" "body text" "origin:worker") || actual_rc=$?

if [[ "$actual_rc" -eq 0 ]]; then
	pass "partial-success recovery: _create_pr returns 0 when PR exists after create failure"
else
	fail "partial-success recovery: _create_pr returns 0 when PR exists after create failure" \
		"got exit $actual_rc; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if [[ "$actual_pr_number" == "999" ]]; then
	pass "partial-success recovery: _create_pr outputs correct PR number (999)"
else
	fail "partial-success recovery: _create_pr outputs correct PR number (999)" \
		"got '${actual_pr_number}'; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "recovering (t2767)" "$STUB_LOG" 2>/dev/null; then
	pass "partial-success recovery: recovery log message emitted"
else
	fail "partial-success recovery: recovery log message emitted" \
		"expected '[INFO] ... recovering (t2767)' in log; got: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 2: _create_pr hard failure
# gh_create_pr returns non-zero AND _gh_recover_pr_if_exists finds nothing.
# Expected: _create_pr returns non-zero with an error.
# =============================================================================
: >"$STUB_LOG"
GH_CREATE_PR_FAIL=1
GH_RECOVER_PR_URL=""

hard_fail_rc=0
_create_pr "owner/repo" "t2767: test" "body text" "origin:worker" >/dev/null 2>&1 || hard_fail_rc=$?

if [[ "$hard_fail_rc" -ne 0 ]]; then
	pass "hard failure: _create_pr returns non-zero when no PR exists after failure"
else
	fail "hard failure: _create_pr returns non-zero when no PR exists after failure" \
		"expected non-zero exit, got 0; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "\[ERROR\] PR creation failed" "$STUB_LOG" 2>/dev/null; then
	pass "hard failure: error message emitted"
else
	fail "hard failure: error message emitted" \
		"expected '[ERROR] PR creation failed' in log; got: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 3: _create_pr success (no recovery needed)
# gh_create_pr succeeds. Expected: _create_pr returns 0, outputs PR number.
# =============================================================================
: >"$STUB_LOG"
GH_CREATE_PR_FAIL=0
GH_RECOVER_PR_URL=""
GH_CREATE_PR_URL="https://github.com/owner/repo/pull/888"

success_pr_number=""
success_rc=0
success_pr_number=$(_create_pr "owner/repo" "t2767: test" "body text" "origin:worker") || success_rc=$?

if [[ "$success_rc" -eq 0 ]]; then
	pass "normal success: _create_pr returns 0 on clean create"
else
	fail "normal success: _create_pr returns 0 on clean create" \
		"got exit $success_rc"
fi

if [[ "$success_pr_number" == "888" ]]; then
	pass "normal success: _create_pr outputs correct PR number (888)"
else
	fail "normal success: _create_pr outputs correct PR number (888)" \
		"got '${success_pr_number}'"
fi

# =============================================================================
# Test 4: _post_merge_summary idempotency — skip when comment already exists
# GH_EXISTING_MERGE_SUMMARY_COUNT=1 simulates an existing MERGE_SUMMARY comment.
# Expected: gh_pr_comment NOT called, returns 0.
# =============================================================================
: >"$STUB_LOG"
GH_EXISTING_MERGE_SUMMARY_COUNT=1

idem_rc=0
_post_merge_summary "999" "owner/repo" "42" "impl" "file.sh" "shellcheck" "none" || idem_rc=$?

if [[ "$idem_rc" -eq 0 ]]; then
	pass "idempotency: _post_merge_summary returns 0 when comment already exists"
else
	fail "idempotency: _post_merge_summary returns 0 when comment already exists" \
		"got exit $idem_rc"
fi

if ! grep -q "gh_pr_comment" "$STUB_LOG" 2>/dev/null; then
	pass "idempotency: gh_pr_comment NOT called when MERGE_SUMMARY already exists"
else
	fail "idempotency: gh_pr_comment NOT called when MERGE_SUMMARY already exists" \
		"gh_pr_comment was called; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "skipping duplicate (t2767)" "$STUB_LOG" 2>/dev/null; then
	pass "idempotency: skip message logged"
else
	fail "idempotency: skip message logged" \
		"expected 'skipping duplicate (t2767)' in log; got: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 5: _post_merge_summary first post — no existing comment
# GH_EXISTING_MERGE_SUMMARY_COUNT=0 simulates no existing MERGE_SUMMARY comment.
# Expected: gh_pr_comment IS called, returns 0.
# =============================================================================
: >"$STUB_LOG"
GH_EXISTING_MERGE_SUMMARY_COUNT=0

first_post_rc=0
_post_merge_summary "999" "owner/repo" "42" "impl" "file.sh" "shellcheck" "none" || first_post_rc=$?

if [[ "$first_post_rc" -eq 0 ]]; then
	pass "first post: _post_merge_summary returns 0 on fresh PR"
else
	fail "first post: _post_merge_summary returns 0 on fresh PR" \
		"got exit $first_post_rc"
fi

if grep -q "gh_pr_comment" "$STUB_LOG" 2>/dev/null; then
	pass "first post: gh_pr_comment IS called when no MERGE_SUMMARY exists"
else
	fail "first post: gh_pr_comment IS called when no MERGE_SUMMARY exists" \
		"gh_pr_comment was NOT called; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
