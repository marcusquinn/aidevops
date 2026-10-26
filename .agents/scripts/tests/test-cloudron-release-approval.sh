#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${TEST_DIR}/.."
# shellcheck source=../cloudron-release-approval-helper.sh
source "${SOURCE_DIR}/cloudron-release-approval-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT
SCRIPT_DIR="$TEST_ROOT"
REPOS_FILE="${TEST_ROOT}/repos.json"
printf '%s\n' '{"initialized_repos":[{"slug":"owner/app","app_type":"cloudron-package"}]}' >"$REPOS_FILE"
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export HEAD_SHA OTHER_SHA
cat >"${TEST_ROOT}/approval-helper.sh" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == 'verify issue 12 owner/app --require-authority' ]] || exit 9
printf 'verify\n' >>"${TEST_ROOT}/calls"
case "$SCENARIO" in
unsigned) printf 'NO_APPROVAL\n'; exit 1 ;;
api_error) printf 'API_ERROR\n'; exit 6 ;;
bad_exit) printf 'VERIFIED\n'; exit 6 ;;
stale) printf 'STALE_APPROVAL\n'; exit 2 ;;
*) printf 'VERIFIED\n' ;;
esac
STUB
cat >"${TEST_ROOT}/full-loop-helper.sh" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == 'merge 7 owner/app --squash' && "$FULL_LOOP_EXPECTED_PR_HEAD_SHA" == "$HEAD_SHA" ]] || exit 9
printf 'merge\n' >>"${TEST_ROOT}/calls"
[[ "$SCENARIO" != merge_error ]] || exit 1
touch "${TEST_ROOT}/merged"
STUB
chmod +x "${TEST_ROOT}/approval-helper.sh" "${TEST_ROOT}/full-loop-helper.sh"

gh() {
	local command="$1" target="${2:-}"
	printf '%s\n' "$*" >>"${TEST_ROOT}/calls"
	case "$command $target" in
	'api repos/owner/app')
		[[ "$SCENARIO" != permission_error ]] || return 1
		if [[ "$SCENARIO" == no_permission ]]; then
			printf 'false\n'
		else
			printf 'true\n'
		fi
		;;
	'api repos/owner/app/issues?'*)
		if [[ "$SCENARIO" == request ]]; then
			printf '[]\n'
		else
			gh api repos/owner/app/issues/12 | jq -c '[. + {number:12}]'
		fi
		;;
	'api repos/owner/app/issues/12/comments?'*) printf '[]\n' ;;
	'api repos/owner/app/issues/12')
		local body=""
		body=$(jq -cn --arg head "$HEAD_SHA" '{schema:1,repository:"owner/app",pr:7,head:$head,version:"1.2.3",upstream:"4.5.6",owns_hold:true}')
		jq -cn --arg body "$body" '{state:"open",body:$body,labels:[{name:"release-approval-required"}]}'
		;;
	'api repos/owner/app/pulls/7')
		local head="$HEAD_SHA" merged=false state=open
		[[ "$SCENARIO" != changed ]] || head="$OTHER_SHA"
		if [[ -f "${TEST_ROOT}/merged" || "$SCENARIO" == resumed ]]; then
			merged=true
			state=closed
		fi
		[[ "$SCENARIO" != pr_error ]] || return 1
		jq -cn --arg head "$head" --arg state "$state" --argjson merged "$merged" --arg scenario "$SCENARIO" '
			{head:{sha:$head,repo:{full_name:"owner/app"}},base:{ref:"main",repo:{full_name:"owner/app"}},state:$state,merged:$merged,merge_commit_sha:$head,draft:false,labels:[],auto_merge:null}
			| if $scenario == "draft" then .draft = true
			  elif $scenario == "fork" then .head.repo.full_name = "other/app"
			  elif $scenario == "wrong_repo" then .base.repo.full_name = "other/app"
			  elif $scenario == "wrong_base" then .base.ref = "develop"
			  elif $scenario == "invalid_head" then .head.sha = "invalid"
			  elif $scenario == "closed" then .state = "closed"
			  else . end'
		;;
	'pr checks')
		[[ "$SCENARIO" != checks_error ]] || return 1
		local bucket=pass
		[[ "$SCENARIO" != preflight_skipped ]] || bucket=skipping
		jq -cn --arg bucket "$bucket" '[{bucket:$bucket,name:"preflight",link:""},{bucket:"skipping",name:"publish",link:""}]'
		;;
	'api repos/owner/app/contents/CloudronManifest.json?'*) printf '{"version":"1.2.3","upstreamVersion":"4.5.6","changelog":"file://CHANGELOG"}\n' ;;
	'api repos/owner/app/contents/CHANGELOG?'*) printf '[1.2.3]\n* Upgrade upstream\n\n[1.2.2]\n* Old entry\n' ;;
	'api repos/owner/app/contents/CloudronVersions.json?'*)
		[[ "$SCENARIO" != catalog_error ]] || return 1
		printf '{"versions":{"1.2.3":{"manifest":{"version":"1.2.3"}}}}\n'
		;;
	'api repos/owner/app/git/ref/tags/v1.2.3') jq -cn --arg sha "$HEAD_SHA" '{object:{sha:$sha}}' ;;
	'api repos/owner/app/releases/tags/v1.2.3') printf '{"tag_name":"v1.2.3","draft":false,"html_url":"https://example.invalid/release"}\n' ;;
	'api repos/owner/app/compare/'*) printf 'ahead\n' ;;
	'api repos/owner/app/actions/workflows/'*)
		if [[ "$SCENARIO" == catalog_error ]]; then
			printf '{"workflow_runs":[]}\n'
		else
			jq -cn --arg sha "$HEAD_SHA" '{workflow_runs:[{id:1,head_sha:$sha,status:"completed",conclusion:"success"}]}'
		fi
		;;
	'issue close') [[ "$SCENARIO" != close_error ]] || return 1 ;;
	'label create') return 0 ;;
	*)
		printf 'Unexpected gh call: %s\n' "$*" >&2
		return 9
		;;
	esac
	return 0
}

gh_pr_edit_safe() {
	printf 'pr-edit %s\n' "$*" >>"${TEST_ROOT}/calls"
	return 0
}

gh_issue_comment() {
	local body=""
	body=$(</dev/stdin)
	printf 'comment %s\n' "$body" >>"${TEST_ROOT}/calls"
	return 0
}

gh_create_issue() {
	local body=""
	body=$(</dev/stdin)
	printf '%s\n' "$body" >"${TEST_ROOT}/request"
	printf 'create %s\n' "$*" >>"${TEST_ROOT}/calls"
	printf 'https://example.invalid/issue/12\n'
	return 0
}

run_case() {
	local scenario="$1" expected_rc="$2" merge_expected="$3" comment_expected="$4" close_expected="$5"
	export SCENARIO="$scenario"
	rm -f "${TEST_ROOT}/merged"
	: >"${TEST_ROOT}/calls"
	local rc=0 calls=""
	release_process true || rc=$?
	[[ "$rc" -eq "$expected_rc" ]] || {
		printf 'FAIL %s rc=%s\n' "$scenario" "$rc"
		return 1
	}
	calls=$(<"${TEST_ROOT}/calls")
	local merged=false commented=false closed=false
	[[ "$calls" != *$'\nmerge'* ]] || merged=true
	[[ "$calls" != *'comment '* ]] || commented=true
	[[ "$calls" != *'issue close '* ]] || closed=true
	[[ "$merged" == "$merge_expected" && "$commented" == "$comment_expected" && "$closed" == "$close_expected" ]] || return 1
	printf 'PASS %s\n' "$scenario"
	return 0
}

run_request_error() {
	local scenario="$1" expected="$2" registration="${3:-}"
	local repo="${4:-owner/app}" pr="${5:-7}" rc=0 output="" calls=""
	export SCENARIO="$scenario"
	[[ -n "$registration" ]] || registration='{"slug":"owner/app","app_type":"cloudron-package"}'
	jq -cn --argjson registration "$registration" '{initialized_repos:[$registration]}' >"$REPOS_FILE"
	: >"${TEST_ROOT}/calls"
	output=$(release_request "$repo" "$pr" 2>&1) || rc=$?
	[[ "$rc" -eq 1 && "$output" == *"ERROR: ${expected}"* ]] || {
		printf 'FAIL %s rc=%s output=%s\n' "$scenario" "$rc" "$output"
		return 1
	}
	calls=$(<"${TEST_ROOT}/calls")
	[[ "$calls" != *'pr checks'* && "$calls" != *'label create'* && "$calls" != *'pr-edit '* && "$calls" != *'create '* ]] || return 1
	printf 'PASS request %s: %s\n' "$scenario" "$output"
	return 0
}

run_request_error invalid_repo 'Repository must be in owner/repo format.' '{}' invalid
run_request_error invalid_pr 'PR number must be a positive integer.' '{}' owner/app 0
run_request_error unregistered 'Repository owner/app is not registered as a maintained cloudron-package.' '{}'
run_request_error wrong_app_type 'Repository owner/app is not registered as a maintained cloudron-package.' '{"slug":"owner/app","app_type":"other"}'
run_request_error not_maintained 'Repository owner/app is not registered as a maintained cloudron-package.' '{"slug":"owner/app","app_type":"cloudron-package","maintenance":false}'
run_request_error permission_error 'Unable to verify admin/maintain permission for owner/app.'
run_request_error no_permission 'Admin or maintain permission is required for owner/app.'
run_request_error pr_error 'Unable to read PR #7 in owner/app.'
run_request_error draft 'PR #7 is a draft or its draft status is unavailable. Run: gh pr ready 7 --repo owner/app; then wait for re-triggered checks to pass.'
run_request_error fork 'PR #7 must be a same-repository PR against main in owner/app.'
run_request_error wrong_repo 'PR #7 must be a same-repository PR against main in owner/app.'
run_request_error wrong_base 'PR #7 must be a same-repository PR against main in owner/app.'
run_request_error invalid_head 'PR #7 has an invalid head SHA.'
run_request_error closed 'PR #7 must be open before requesting approval.'

run_case unsigned 0 false false false
run_case api_error 1 false false false
run_case bad_exit 1 false false false
run_case stale 0 false false false
run_case changed 0 false true false
run_case approved 0 true true true
run_case checks_error 1 false false false
run_case preflight_skipped 1 false false false
run_case merge_error 1 true false false
grep -q -- '--add-label hold-for-review' "${TEST_ROOT}/calls"
printf 'PASS failed merge restores hold\n'
run_case resumed 0 false true true
run_case catalog_error 0 true false false
run_case close_error 1 true false true
printf 'PASS close failure posts no approval-invalidating comment\n'

export SCENARIO=approved
: >"${TEST_ROOT}/calls"
release_process false
if grep -Eq 'merge$|pr-edit|comment |issue close' "${TEST_ROOT}/calls"; then exit 1; fi
printf 'PASS dry run never writes\n'
export SCENARIO=request
rm -f "${TEST_ROOT}/merged"
release_request owner/app 7
grep -q -- '--label no-auto-dispatch' "${TEST_ROOT}/calls"
if grep -q -- '--label auto-dispatch' "${TEST_ROOT}/calls"; then exit 1; fi
grep -q 'cloudron-release-approval 1.2.3' "${TEST_ROOT}/request"
grep -q "$HEAD_SHA" "${TEST_ROOT}/request"
if grep -q 'Old entry' "${TEST_ROOT}/request"; then exit 1; fi
printf 'PASS request records exact head, changelog and dispatch hold\n'

export SCENARIO=unsigned
if release_authorize owner/app 7 "$HEAD_SHA"; then exit 1; fi
export SCENARIO=approved
release_authorize owner/app 7 "$HEAD_SHA"
if release_authorize owner/app 7 "$OTHER_SHA"; then exit 1; fi
printf 'PASS common release authorization requires signature and matching head\n'

# Exercise the real final transport-head guard, not just the merge stub.
SCRIPT_DIR="$SOURCE_DIR"
# shellcheck source=../full-loop-helper-merge.sh
source "${SOURCE_DIR}/full-loop-helper-merge.sh"
_merge_read_head_sha_with_admission_retry() {
	FULL_LOOP_MERGE_READ_HEAD_SHA="$OTHER_SHA"
	return 0
}
FULL_LOOP_EXPECTED_PR_HEAD_SHA="$HEAD_SHA"
FULL_LOOP_VERIFIED_PR_HEAD_SHA="$OTHER_SHA"
if _merge_resolve_match_head 7 owner/app; then
	printf 'FAIL unsigned head accepted during merge readiness\n'
	exit 1
fi
printf 'PASS changed head during readiness rejected by merge transport\n'

# The new routine's exact command and description remain discoverable.
# shellcheck source=../routines/core-routines.sh
source "${SOURCE_DIR}/routines/core-routines.sh"
get_core_routine_entries | grep -F 'r924|x|Cloudron releases — process signed approvals|repeat:cron(*/30 * * * *)' >/dev/null
describe_r924 linux | grep -F 'scripts/cloudron-release-approval-helper.sh process --apply' >/dev/null
printf 'PASS half-hour approval routine registered\n'
