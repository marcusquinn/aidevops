#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#33796: fixture-backed production local gate, merge transport and waiter.
set -euo pipefail

SCRIPTS_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export REPOS_FILE="$TEST_ROOT/repos.json"
HEAD_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
OTHER_SHA='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
MODE='billing'
PERMISSION='write'
RECEIPT=""
MERGE_CALLS=0

# shellcheck source=../repo-actions-capability-lib.sh
source "$SCRIPTS_DIR/repo-actions-capability-lib.sh"
# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
source "$SCRIPTS_DIR/aidevops-cli/aidevops-repos-lib.sh"

init_repos_file() { return 0; }
print_error() { printf '%s\n' "$*" >&2; return 0; }
print_info() { return 0; }
print_success() { return 0; }

reset_fixture() {
	printf '%s\n' '{"initialized_repos":[{"slug":"test/repo","path":"/fixture","maintenance":true,"pulse":true}]}' >"$REPOS_FILE"
	set_repo_actions test/repo unavailable 'billing blocked'
	RECEIPT=$(jq -cn --arg head "$HEAD_SHA" '{head:$head,status:"passed",checks_complete:true,
		checks:[{command:"bash scripts/lint.sh",exit_code:0,result:"clean"}]}')
	RECEIPT=$'<!-- aidevops:local-verification:v1 -->\n'"$RECEIPT"
	MODE='billing'
	PERMISSION='write'
	return 0
}

gh() {
	local kind="${1:-}" target="${2:-}"
	if [[ "$kind" == 'pr' ]]; then
		printf '%s\n' "$HEAD_SHA"
		return 0
	fi
	case "$target" in
	'repos/test/repo/pulls/1')
		if [[ "${3:-}" == '--jq' ]]; then
			if [[ "$MODE" == 'drift' ]]; then printf '%s\n' "$OTHER_SHA"; else printf '%s\n' "$HEAD_SHA"; fi
		else
			local association='OWNER'
			[[ "$MODE" != 'external' ]] || association='NONE'
			jq -cn --arg head "$HEAD_SHA" --arg body "$RECEIPT" --arg association "$association" \
				'{head:{sha:$head},body:$body,user:{login:"owner"},author_association:$association}'
		fi
		;;
	'repos/test/repo/issues/1/comments?per_page=100') printf '[[]]\n' ;;
	'repos/test/repo/collaborators/owner/permission') printf '%s\n' "$PERMISSION" ;;
	'repos/test/repo/commits/'*'/check-runs?per_page=100')
		if [[ "$MODE" == 'api-error' ]]; then return 1; fi
		if [[ "$MODE" == 'empty' ]]; then printf '[{"total_count":0,"check_runs":[]}]\n'; return 0; fi
		local app='github-actions' status='completed' conclusion='failure'
		[[ "$MODE" != 'other-provider' ]] || app='external-ci'
		[[ "$MODE" != 'cancelled' ]] || conclusion='cancelled'
		if [[ "$MODE" == 'pending' ]]; then status='queued'; conclusion=''; fi
		[[ "$MODE" != 'malformed' ]] || status='complete'
		jq -cn --arg head "$HEAD_SHA" --arg app "$app" --arg status "$status" --arg conclusion "$conclusion" \
			'[{total_count:1,check_runs:[{id:42,head_sha:$head,status:$status,conclusion:(if $conclusion == "" then null else $conclusion end),app:{slug:$app}}]}]'
		;;
	'repos/test/repo/commits/'*'/statuses?per_page=100')
		if [[ "$MODE" == 'status-failure' ]]; then printf '[[{"id":1,"context":"optional","state":"failure"}]]\n'; else printf '[[]]\n'; fi
		;;
	'repos/test/repo/check-runs/42/annotations')
		if [[ "$MODE" == 'non-billing' ]]; then printf '[{"message":"unit tests failed"}]\n'; else printf '[{"message":"account payments have failed"}]\n'; fi
		;;
	*) printf 'Unexpected gh call: %s\n' "$*" >&2; return 1 ;;
	esac
	return 0
}

assert_blocked() {
	local name="$1"
	if repo_actions_verify_local test/repo 1 "$HEAD_SHA"; then
		printf 'FAIL: %s was accepted\n' "$name" >&2
		exit 1
	fi
	printf 'PASS: %s blocks\n' "$name"
	return 0
}

reset_fixture
repo_actions_unavailable test/repo
jq -e '.initialized_repos[0] | .maintenance and .pulse and .actions_reason == "billing blocked"' "$REPOS_FILE" >/dev/null
set_repo_actions test/repo available
repo_actions_unavailable test/repo && exit 1
jq -e '.initialized_repos[0] | (has("actions") or has("actions_reason")) | not' "$REPOS_FILE" >/dev/null
set_repo_actions missing/repo unavailable && exit 1
printf 'PASS: registry defaults, enable/disable, reason and unrelated fields\n'

reset_fixture
repo_actions_verify_local test/repo 1 "$HEAD_SHA"
for MODE in non-billing other-provider cancelled status-failure api-error drift external malformed; do
	assert_blocked "$MODE"
done
MODE='billing'
PERMISSION='read'
assert_blocked 'receipt author lacks write permission'
PERMISSION='write'
RECEIPT='tested locally'
assert_blocked 'prose without receipt'
reset_fixture
repo_actions_receipt_valid "$RECEIPT" "$OTHER_SHA" && exit 1
repo_actions_receipt_valid $'<!-- aidevops:local-verification:v1 -->\n{"checks":[]}' "$HEAD_SHA" && exit 1
printf 'PASS: stale and malformed receipts rejected\n'
MODE='empty'
repo_actions_verify_local test/repo 1 "$HEAD_SHA"
MODE='pending'
repo_actions_verify_local test/repo 1 "$HEAD_SHA"

# Load the real waiter and redefine gh after shared-constants initialization.
# shellcheck source=../gh-checks-wait-helper.sh
source "$SCRIPTS_DIR/gh-checks-wait-helper.sh" help >/dev/null
MODE='billing'
cmd_wait 1 --repo test/repo --timeout 300
MODE='non-billing'
cmd_wait 1 --repo test/repo --timeout 300 && exit 1
printf 'PASS: unavailable waiter returns immediately without polling\n'

# The real readiness entrypoint selects the local gate; only unrelated snapshot
# plumbing and merge authority/transport are stubbed. Existing author gate tests
# independently cover external approval invariants.
# shellcheck source=../full-loop-helper-readiness.sh
source "$SCRIPTS_DIR/full-loop-helper-readiness.sh"
_full_loop_read_pr_readiness() {
	FULL_LOOP_PR_READINESS_JSON=$(jq -cn --arg head "$HEAD_SHA" \
		'{state:"OPEN",isDraft:false,headRefOid:$head,headRefName:"fixture",reviewDecision:"APPROVED"}')
	return 0
}
_full_loop_persist_pr_check_evidence() { return 0; }
_FULL_LOOP_CHECK_PENDING='pending'
MODE='billing'
_full_loop_verify_pr_readiness 1 test/repo
[[ "$FULL_LOOP_VERIFIED_PR_HEAD_SHA" == "$HEAD_SHA" ]]
MODE='non-billing'
_full_loop_verify_pr_readiness 1 test/repo && exit 1

# shellcheck source=../full-loop-helper-merge.sh
source "$SCRIPTS_DIR/full-loop-helper-merge.sh"
_merge_resolve_subject_for_method() { printf 'feat: fixture\n'; return 0; }
_merge_resolve_match_head() { printf '%s\n' "$FULL_LOOP_VERIFIED_PR_HEAD_SHA"; return 0; }
_merge_revalidate_transport_authority() { return 0; }
_merge_run_bounded_write() { MERGE_CALLS=$((MERGE_CALLS + 1)); _MERGE_WRITE_OUTPUT='merged'; return 0; }
MODE='billing'
_full_loop_verify_pr_readiness 1 test/repo && _merge_execute 1 test/repo --squash 0 0
[[ "$MERGE_CALLS" == 1 ]]
MODE='non-billing'
if _full_loop_verify_pr_readiness 1 test/repo; then _merge_execute 1 test/repo --squash 0 0; fi
[[ "$MERGE_CALLS" == 1 ]]
printf 'PASS: merge transport runs only after valid local readiness\n'

_merge_with_admission_retry() {
	[[ "${AIDEVOPS_ACTIONS_NATIVE_CHECKS_ONLY:-0}" == 1 ]] || exit 1
	return 1
}
MODE='billing'
_merge_execute 1 test/repo --squash 1 0 && exit 1
[[ "$MERGE_CALLS" == 1 ]]
printf 'PASS: explicit admin cannot use local evidence to bypass native checks\n'
