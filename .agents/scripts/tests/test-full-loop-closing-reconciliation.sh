#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_DIR="$SCRIPTS_DIR"
# shellcheck source=../full-loop-helper-merge.sh
source "${SCRIPTS_DIR}/full-loop-helper-merge.sh"

PASS=0
FAIL=0
RECONCILED=""
RELEASED=""
FINALIZED=0

pass() {
	printf 'PASS: %s\n' "$1"
	PASS=$((PASS + 1))
	return 0
}
fail() {
	printf 'FAIL: %s\n' "$1"
	FAIL=$((FAIL + 1))
	return 0
}
assert_eq() {
	local expected="$1"
	local actual="$2"
	local name="$3"
	[[ "$expected" == "$actual" ]] && pass "$name" || fail "$name (expected '$expected', got '$actual')"
	return 0
}

gh() {
	local command="$1"
	shift
	if [[ "$command $1" == "pr view" ]]; then
		printf 'Resolves #10 and closes #11\n'
		return 0
	fi
	if [[ "$command $1" == "api graphql" ]]; then
		printf '%s\n' '{"data":{"repository":{"nameWithOwner":"owner/repo","pullRequest":{"state":"MERGED","merged":true,"closingIssuesReferences":{"totalCount":2,"pageInfo":{"hasNextPage":false},"nodes":[{"number":10,"state":"CLOSED","repository":{"nameWithOwner":"owner/repo"}},{"number":11,"state":"CLOSED","repository":{"nameWithOwner":"owner/repo"}}]}}}}}'
		return 0
	fi
	return 1
}

release_interactive_claim_on_merge() {
	RELEASED="$3"
	return 0
}
reconcile_dependants_after_verified_closure() {
	RECONCILED="${RECONCILED}${RECONCILED:+ }$2"
	return 0
}
auto_file_next_phase() { return 0; }
_merge_unlock_resources() { return 0; }

# shellcheck disable=SC2218  # The test intentionally replaces this function below.
_merge_finalize_post_merge 77 owner/repo 0 ""
assert_eq "10" "$RELEASED" "primary body-linked issue retains claim-release semantics"
assert_eq "10 11" "$RECONCILED" "all confirmed closing references are reconciled"

gh() {
	local command="$1"
	shift
	[[ "$command $1" == "api graphql" ]] || return 1
	printf '%s\n' '{"data":{"repository":{"nameWithOwner":"owner/repo","pullRequest":{"state":"MERGED","merged":true,"closingIssuesReferences":{"totalCount":101,"pageInfo":{"hasNextPage":true},"nodes":[]}}}}}'
	return 0
}
if _merge_confirmed_closing_issue_numbers 77 owner/repo >/dev/null 2>&1; then
	fail "truncated closing-reference connection fails closed"
else
	pass "truncated closing-reference connection fails closed"
fi

_merge_resolve_repo() {
	printf 'owner/repo\n'
	return 0
}
cmd_pre_merge_gate() { return 0; }
_retarget_stacked_children_interactive() { return 0; }
_merge_execute() { return 0; }
_merge_verify_completed_state() { return 1; }
print_info() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
_merge_finalize_post_merge() {
	FINALIZED=$((FINALIZED + 1))
	return 0
}

cmd_merge 77 owner/repo --auto
assert_eq "0" "$FINALIZED" "queued auto-merge does not invoke closure reconciliation"

if grep -A10 'if gh issue close --repo' "${SCRIPTS_DIR}/github-cli-helper.sh" | grep -q 'reconcile_dependants_after_verified_closure'; then
	pass "independent github helper close command invokes shared reconciler after success"
else
	fail "independent github helper close command invokes shared reconciler after success"
fi
if grep -A3 '"close-issue")' "${SCRIPTS_DIR}/github-cli-helper.sh" | grep -q 'close_issue'; then
	pass "github helper close command remains an independently exposed managed path"
else
	fail "github helper close command remains an independently exposed managed path"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
exit $?
