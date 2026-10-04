#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-edit-safety.sh — regression tests for GH#19857
#
# Asserts the framework-wide safety invariant: gh_issue_edit_safe,
# gh_pr_edit_safe, gh_create_issue, and gh_create_pr all reject
# empty titles, empty bodies, stub titles, and /dev/null body-files.
#
# Strategy:
#   - Source shared-constants.sh with stubbed external commands.
#   - Call the validation function directly and the wrapper functions.
#   - Assert rejection (return 1) for invalid args, acceptance (return 0)
#     for valid args.

# shellcheck disable=SC2181  # Deliberate $? pattern for testing specific exit codes
set -u
set +e

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
TEST_ROOT="$(mktemp -d -t aidevops-gh-edit-safety-XXXXXX)" || exit 1
export GH_AUDIT_LOG_FILE="${TEST_ROOT}/gh-audit.log"

cleanup() {
	rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

pass() {
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

section() {
	local title="$1"
	printf '\n%s%s%s\n' "$TEST_BLUE" "$title" "$TEST_NC"
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1

# ── Stub externals so we can source shared-constants.sh in isolation ──

# Stub gh so it never hits the network
gh() {
	# Record what was called for assertions
	GH_CALLS+=("$*")
	echo "https://github.com/test/repo/issues/999"
	return 0
}
export -f gh

# Keep audit records produced by integration calls inside the test sandbox.
AUDIT_LOG_CALLS=()

# Stub jq for config loading
if ! command -v jq &>/dev/null; then
	jq() {
		echo "{}"
		return 0
	}
	export -f jq
fi

# Prevent the config loader from failing
export AIDEVOPS_CONFIG_FILE="${SCRIPT_DIR}/nonexistent-config.jsonc"

# Source shared-constants.sh (need the validation functions)
# shellcheck disable=SC1091
source "${SCRIPTS_DIR}/shared-constants.sh" 2>/dev/null || {
	printf 'FATAL: cannot source shared-constants.sh\n' >&2
	exit 1
}

# ── Tests ──

section "0. shared-gh-wrappers-safe-edit standalone dependency loading"

SAFE_EDIT_FILE="${SCRIPTS_DIR}/shared-gh-wrappers-safe-edit.sh"
standalone_output=$(bash -c '
set -u
safe_edit_file="$1"
calls_file="$(mktemp)"
export calls_file
gh() {
	local arg1="${1:-}"
	local arg2="${2:-}"
	printf "%s\n" "$*" >>"$calls_file"
	if [[ "$arg1 $arg2" == "issue view" || "$arg1 $arg2" == "pr view" ]]; then
		printf "%s\n" "{\"title\":\"Existing\",\"body\":\"Existing\",\"labels\":[]}"
	fi
	return 0
}
export -f gh
source "$safe_edit_file"
gh_issue_edit_safe 123 --repo "test/repo" --body "body"
rc=$?
calls=$(wc -l <"$calls_file" | tr -d "[:space:]")
rm -f "$calls_file"
printf "rc=%s calls=%s\n" "$rc" "$calls"
exit "$rc"
' -- "$SAFE_EDIT_FILE" 2>&1)
standalone_rc=$?
if [[ $standalone_rc -eq 0 && "$standalone_output" == *"rc=0"* ]]; then
	pass "standalone safe-edit source loads validation dependencies"
else
	fail "standalone safe-edit source should edit with valid args" \
		"rc=${standalone_rc}; output: ${standalone_output}"
fi

section "1. _gh_validate_edit_args — empty title rejection"

_gh_validate_edit_args --title "" --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects empty string title"
else
	fail "should reject empty string title"
fi

_gh_validate_edit_args --title "   " --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects whitespace-only title"
else
	fail "should reject whitespace-only title"
fi

_gh_validate_edit_args --title="" --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects empty title (= form)"
else
	fail "should reject empty title (= form)"
fi

section "2. _gh_validate_edit_args — stub title rejection"

_gh_validate_edit_args --title "t1234: " --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects stub title 't1234: '"
else
	fail "should reject stub title 't1234: '"
fi

_gh_validate_edit_args --title "t001:  " --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects stub title 't001:  ' (trailing spaces)"
else
	fail "should reject stub title 't001:  ' (trailing spaces)"
fi

_gh_validate_edit_args --title "GH#9999: " --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects stub title 'GH#9999: '"
else
	fail "should reject stub title 'GH#9999: '"
fi

_gh_validate_edit_args --title "GH#123:" --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects stub title 'GH#123:' (no space after colon)"
else
	fail "should reject stub title 'GH#123:' (no space after colon)"
fi

section "3. _gh_validate_edit_args — valid title acceptance"

_gh_validate_edit_args --title "t1234: Fix the bug" --repo "test/repo" 2>/dev/null
if [[ $? -eq 0 ]]; then
	pass "accepts valid title 't1234: Fix the bug'"
else
	fail "should accept valid title 't1234: Fix the bug'"
fi

_gh_validate_edit_args --title "A normal title" --repo "test/repo" 2>/dev/null
if [[ $? -eq 0 ]]; then
	pass "accepts valid title 'A normal title'"
else
	fail "should accept valid title 'A normal title'"
fi

_gh_validate_edit_args --repo "test/repo" --add-label "bug" 2>/dev/null
if [[ $? -eq 0 ]]; then
	pass "accepts label-only edit (no title/body)"
else
	fail "should accept label-only edit (no title/body)"
fi

section "4. _gh_validate_edit_args — empty body rejection"

_gh_validate_edit_args --body "" --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects empty string body"
else
	fail "should reject empty string body"
fi

_gh_validate_edit_args --body "   " --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects whitespace-only body"
else
	fail "should reject whitespace-only body"
fi

_gh_validate_edit_args --body="" --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects empty body (= form)"
else
	fail "should reject empty body (= form)"
fi

section "5. _gh_validate_edit_args — valid body acceptance"

_gh_validate_edit_args --body "Some content here" --repo "test/repo" 2>/dev/null
if [[ $? -eq 0 ]]; then
	pass "accepts valid body"
else
	fail "should accept valid body"
fi

section "6. _gh_validate_edit_args — body-file validation"

_gh_validate_edit_args --body-file "/dev/null" --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects --body-file /dev/null"
else
	fail "should reject --body-file /dev/null"
fi

# Create a temp empty file
TMPFILE=$(mktemp)
: >"$TMPFILE"
_gh_validate_edit_args --body-file "$TMPFILE" --repo "test/repo" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects --body-file pointing to empty file"
else
	fail "should reject --body-file pointing to empty file"
fi

# Write content to the temp file
printf 'Some body content' >"$TMPFILE"
_gh_validate_edit_args --body-file "$TMPFILE" --repo "test/repo" 2>/dev/null
if [[ $? -eq 0 ]]; then
	pass "accepts --body-file with content"
else
	fail "should accept --body-file with content"
fi
rm -f "$TMPFILE"

section "7. gh_issue_edit_safe — integration"

GH_CALLS=()
gh_issue_edit_safe 123 --repo "test/repo" --title "" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "gh_issue_edit_safe rejects empty title"
else
	fail "gh_issue_edit_safe should reject empty title"
fi

# Verify gh was NOT called
if [[ ${#GH_CALLS[@]} -eq 0 ]]; then
	pass "gh was not invoked on rejection"
else
	fail "gh should not be invoked on rejection" "got: ${GH_CALLS[*]}"
fi

GH_CALLS=()
gh_issue_edit_safe 123 --repo "test/repo" --title "t001: Real fix" 2>/dev/null
if [[ $? -eq 0 ]]; then
	pass "gh_issue_edit_safe accepts valid args and delegates to gh"
else
	fail "gh_issue_edit_safe should accept valid args"
fi

if [[ ${#GH_CALLS[@]} -gt 0 ]]; then
	pass "gh was invoked on valid args"
else
	fail "gh should be invoked on valid args"
fi

section "8. gh_pr_edit_safe — integration"

GH_CALLS=()
gh_pr_edit_safe 456 --repo "test/repo" --body "" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "gh_pr_edit_safe rejects empty body"
else
	fail "gh_pr_edit_safe should reject empty body"
fi

GH_CALLS=()
gh_pr_edit_safe 456 --repo "test/repo" --title "t002: Update docs" 2>/dev/null
if [[ $? -eq 0 ]]; then
	pass "gh_pr_edit_safe accepts valid args"
else
	fail "gh_pr_edit_safe should accept valid args"
fi

section "9. _gh_validate_edit_args — combined title + body"

_gh_validate_edit_args --title "t001: Fix" --body "Real content" 2>/dev/null
if [[ $? -eq 0 ]]; then
	pass "accepts valid title + body combo"
else
	fail "should accept valid title + body combo"
fi

_gh_validate_edit_args --title "t001: Fix" --body "" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects valid title with empty body"
else
	fail "should reject valid title with empty body"
fi

_gh_validate_edit_args --title "" --body "Real content" 2>/dev/null
if [[ $? -eq 1 ]]; then
	pass "rejects empty title with valid body"
else
	fail "should reject empty title with valid body"
fi

section "10. _GH_EDIT_REJECTION_REASON is set on failure"

_gh_validate_edit_args --title "" 2>/dev/null
if [[ -n "$_GH_EDIT_REJECTION_REASON" ]]; then
	pass "rejection reason is set: '${_GH_EDIT_REJECTION_REASON}'"
else
	fail "rejection reason should be set on failure"
fi

_gh_validate_edit_args --title "Valid title" 2>/dev/null
if [[ -z "$_GH_EDIT_REJECTION_REASON" ]]; then
	pass "rejection reason is cleared on success"
else
	fail "rejection reason should be cleared on success" "got: '${_GH_EDIT_REJECTION_REASON}'"
fi

section "11. GH#33539 — negated closing keywords in PR bodies"

for negated_body in "Do not close #123 from this PR" "Do not resolve #123" "Never fixes #123" \
	"This PR doesn't fix owner/repo#123." "We won't close: #123 yet"; do
	_gh_validate_pr_closing_keywords --repo "test/repo" --body "$negated_body" 2>/dev/null
	if [[ $? -eq 1 ]]; then
		pass "rejects negated closing keyword: '${negated_body}'"
	else
		fail "should reject negated closing keyword: '${negated_body}'"
	fi
done

for safe_body in "Ref #123. The parent issue remains open." "Resolves #123" \
	"For #123 — do not close the parent until phase 3 merges." \
	$'Example only:\n```\nDo not close #123\n```\nRef #123' "Docs mention \`Do not close #123\` as a trap. Ref #123"; do
	_gh_validate_pr_closing_keywords --repo "test/repo" --body "$safe_body" 2>/dev/null
	if [[ $? -eq 0 ]]; then
		pass "accepts safe PR body: '${safe_body%%$'\n'*}'"
	else
		fail "should accept safe PR body: '${safe_body%%$'\n'*}'"
	fi
done

NEG_BODY_FILE="${TEST_ROOT}/negated-pr-body.md"
printf '## Summary\n\nPartial work. Do not close #123 from this PR.\n' >"$NEG_BODY_FILE"
GH_CALLS=()
gh_pr_edit_safe 456 --repo "test/repo" --body-file "$NEG_BODY_FILE" 2>/dev/null
if [[ $? -eq 1 && ${#GH_CALLS[@]} -eq 0 ]]; then
	pass "gh_pr_edit_safe rejects negated closing keyword body-file before any gh call"
else
	fail "gh_pr_edit_safe should reject negated closing keyword body-file before gh" "calls: ${GH_CALLS[*]:-none}"
fi

GH_CALLS=()
gh_create_pr --repo "test/repo" --title "t003: Partial docs" --body "Do not close #123 from this PR" 2>/dev/null
if [[ $? -eq 1 && ${#GH_CALLS[@]} -eq 0 ]]; then
	pass "gh_create_pr rejects negated closing keyword before any gh call"
else
	fail "gh_create_pr should reject negated closing keyword before gh" "calls: ${GH_CALLS[*]:-none}"
fi

# Later wrapper stages (e.g. the public-write privacy guard) are environment
# dependent, so assert only that the closing-keyword check did not reject.
GH_CALLS=()
gh_pr_edit_safe 456 --repo "test/repo" --body "Resolves #123" >/dev/null 2>&1
if [[ "${_GH_EDIT_REJECTION_REASON:-}" != *"closing keyword"* ]]; then
	pass "gh_pr_edit_safe does not reject legitimate leaf closure 'Resolves #123'"
else
	fail "gh_pr_edit_safe should not reject 'Resolves #123'" "reason: ${_GH_EDIT_REJECTION_REASON}"
fi

GH_CALLS=()
gh_issue_edit_safe 123 --repo "test/repo" --body "Do not close #123 until the parent completes" >/dev/null 2>&1
if [[ "${_GH_EDIT_REJECTION_REASON:-}" != *"closing keyword"* ]]; then
	pass "issue body edits are not subject to the PR closing-keyword check"
else
	fail "issue body edits should not be subject to the PR closing-keyword check" "reason: ${_GH_EDIT_REJECTION_REASON}"
fi

# ── Summary ──

printf '\n%s/%s tests passed' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
if [[ $TESTS_FAILED -gt 0 ]]; then
	printf ' (%s%d FAILED%s)' "$TEST_RED" "$TESTS_FAILED" "$TEST_NC"
	printf '\n'
	exit 1
else
	printf ' %s✓%s\n' "$TEST_GREEN" "$TEST_NC"
	exit 0
fi
