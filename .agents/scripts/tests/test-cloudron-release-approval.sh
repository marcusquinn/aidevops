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
cp "${SOURCE_DIR}/cloudron-release-evidence.py" "${SOURCE_DIR}/cloudron_caller_policy.py" "$TEST_ROOT/"
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
unsigned | request_unsigned) printf 'NO_APPROVAL\n'; exit 1 ;;
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

request_issues() {
	if [[ "$SCENARIO" == request_existing || "$SCENARIO" == request_unsigned || "$SCENARIO" == request_signed ]]; then
		jq -cn --rawfile body "${TEST_ROOT}/request" '[{number:12,html_url:"https://example.invalid/issue/12",body:$body}]'
	elif [[ "$SCENARIO" == request* ]]; then
		printf '[]\n'
	else
		gh api repos/owner/app/issues/12 | jq -c '[. + {number:12}]'
	fi
	return 0
}

pull_request_json() {
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
	return 0
}

gh() {
	local command="$1" target="${2:-}"
	printf '%s\n' "$*" >>"${TEST_ROOT}/calls"
	case "$command $target" in
	'api repos/owner/app/rules/branches/main')
		[[ "$SCENARIO" != rules_error ]] || return 1
		# Only rules that block a direct job-token push make the PAT required.
		case "$SCENARIO" in
		missing_secret | secret_error | pat_present) printf '[{"type":"deletion"},{"type":"pull_request"}]\n' ;;
		*) printf '[{"type":"non_fast_forward"},{"type":"deletion"}]\n' ;;
		esac
		;;
	'secret list')
		[[ "$*" == 'secret list --repo owner/app --app actions --json name' ]] || return 9
		[[ "$SCENARIO" != secret_error ]] || return 1
		if [[ "$SCENARIO" == missing_secret ]]; then
			printf '[{"name":"OTHER_SECRET"}]\n'
		else
			printf '[{"name":"CLOUDRON_RELEASE_PAT"}]\n'
		fi
		;;
	'api repos/owner/app')
		[[ "$SCENARIO" != permission_error ]] || return 1
		if [[ "$SCENARIO" == no_permission ]]; then
			printf 'false\n'
		else
			printf 'true\n'
		fi
		;;
	'api repos/owner/app/issues?'*)
		request_issues
		;;
	'api repos/owner/app/issues/12/comments?'*) printf '[]\n' ;;
	'api repos/owner/app/issues/12')
		local body=""
		body=$(jq -cn --arg head "$HEAD_SHA" '{schema:1,repository:"owner/app",pr:7,head:$head,version:"1.2.3",upstream:"4.5.6",owns_hold:true}')
		jq -cn --arg body "$body" '{state:"open",body:$body,labels:[{name:"release-approval-required"}]}'
		;;
	'api repos/owner/app/pulls/7') pull_request_json || return 1 ;;
	'pr checks')
		[[ "$SCENARIO" != checks_error ]] || return 1
		local bucket=pass
		[[ "$SCENARIO" != preflight_skipped ]] || bucket=skipping
		jq -cn --arg bucket "$bucket" '[{bucket:$bucket,name:"preflight",link:""},{bucket:"skipping",name:"publish",link:""}]'
		;;
	'api repos/owner/app/contents/CloudronManifest.json?'*) printf '{"version":"1.2.3","upstreamVersion":"4.5.6","changelog":"file://CHANGELOG"}\n' ;;
	'api repos/owner/app/contents/.github/workflows/cloudron-catalog-publish.yml?'*)
		printf 'jobs:\n  catalog:\n    uses: marcusquinn/aidevops/.github/workflows/cloudron-catalog-publish-reusable.yml@%s\n    with:\n      aidevops_ref: %s\n' "$HEAD_SHA" "$HEAD_SHA"
		if [[ "$SCENARIO" != missing_pass ]]; then
			printf "    secrets:\n      CLOUDRON_RELEASE_PAT: \${{ secrets.CLOUDRON_RELEASE_PAT }}\n"
		fi
		;;
	'api repos/owner/app/contents/CHANGELOG?'*)
		# A changelog example must never make an unfinished request look finalized.
		# shellcheck disable=SC2016 # Markdown command backticks are literal.
		printf '[1.2.3]\n* Upgrade upstream\nMaintainer command: `sudo aidevops approve issue 12 owner/app`\n\n[1.2.2]\n* Old entry\n'
		;;
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
			jq -cn --arg sha "$HEAD_SHA" --arg scenario "$SCENARIO" '
				{workflow_runs:[{id:1,head_sha:$sha,status:"completed",conclusion:"success"}]}
				| if $scenario == "run_in_progress" then .workflow_runs[0] |= (.status = "in_progress" | .conclusion = null)
				  elif $scenario == "run_failed" then .workflow_runs[0].conclusion = "failure"
				  else . end'
		fi
		;;
	'issue close') [[ "$SCENARIO" != close_error ]] || return 1 ;;
	'label create') return 0 ;;
	# No held worker PRs: approval processing alone (GH#36268 cases run below).
	'pr list') printf '[]\n' ;;
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
	if [[ "$SCENARIO" == request_bad_url ]]; then
		printf 'https://example.invalid/issue/not-a-number\n'
	else
		printf 'https://example.invalid/issue/12\n'
	fi
	return 0
}

gh_issue_edit_safe() {
	local body=""
	body=$(</dev/stdin)
	[[ "$*" == '12 --repo owner/app --body-file -' ]] || return 9
	printf 'issue-edit %s\n' "$*" >>"${TEST_ROOT}/calls"
	[[ "$SCENARIO" != request_edit_error ]] || return 1
	printf '%s\n' "$body" >"${TEST_ROOT}/request"
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
run_request_error rules_error 'Unable to read branch rules for main in owner/app; no approval request or merge.'
run_request_error secret_error 'Unable to verify CLOUDRON_RELEASE_PAT in owner/app; no approval request or merge.'
run_request_error missing_secret 'owner/app is missing CLOUDRON_RELEASE_PAT'
run_request_error pr_error 'Unable to read PR #7 in owner/app.'
run_request_error draft 'PR #7 is a draft or its draft status is unavailable. Run: gh pr ready 7 --repo owner/app; then wait for re-triggered checks to pass.'
run_request_error fork 'PR #7 must be a same-repository PR against main in owner/app.'
run_request_error wrong_repo 'PR #7 must be a same-repository PR against main in owner/app.'
run_request_error wrong_base 'PR #7 must be a same-repository PR against main in owner/app.'
run_request_error invalid_head 'PR #7 has an invalid head SHA.'
run_request_error closed 'PR #7 must be open before requesting approval.'
export SCENARIO=missing_pass
if release_request owner/app 7; then exit 1; fi
printf 'PASS missing caller secret forwarding refuses approval\n'

run_case unsigned 0 false false false
run_case api_error 1 false false false
run_case bad_exit 1 false false false
run_case stale 0 false false false
run_case changed 0 false true false
run_case missing_secret 1 false false false
run_case secret_error 1 false false false
run_case rules_error 1 false false false
run_case pat_present 0 true true true
# The baseline rules publish with the job token: no secret lookup at all.
grep -q 'secret list' "${TEST_ROOT}/calls" || exit 1
run_case approved 0 true true true
if grep -q 'secret list' "${TEST_ROOT}/calls"; then exit 1; fi
printf 'PASS baseline rules need no CLOUDRON_RELEASE_PAT\n'
run_case missing_pass 1 false false false
run_case approved 0 true true true
run_case checks_error 1 false false false
run_case preflight_skipped 1 false false false
run_case merge_error 1 true false false
grep -q -- '--add-label hold-for-review' "${TEST_ROOT}/calls"
printf 'PASS failed merge restores hold\n'
run_case resumed 0 false true true
run_case catalog_error 0 true false false
run_case run_in_progress 0 true false false
run_case run_failed 1 true false false
run_case close_error 1 true false true
printf 'PASS close failure posts no approval-invalidating comment\n'

export SCENARIO=approved
: >"${TEST_ROOT}/calls"
release_process false
if grep -Eq 'merge$|pr-edit|comment |issue close' "${TEST_ROOT}/calls"; then exit 1; fi
printf 'PASS dry run never writes\n'
main process --repo owner/app --issue 12
if grep -Eq 'merge$|pr-edit|comment |issue close' "${TEST_ROOT}/calls"; then exit 1; fi
printf 'PASS scoped dry run retains approval checks and never writes\n'
export SCENARIO=request
rm -f "${TEST_ROOT}/merged"
request_output=$(release_request owner/app 7)
[[ "$request_output" == $'https://example.invalid/issue/12\nAPPROVAL_COMMAND=sudo aidevops approve issue 12 owner/app' ]]
grep -q 'issue-edit 12 --repo owner/app --body-file -' "${TEST_ROOT}/calls"
# shellcheck disable=SC2016 # Markdown command backticks are literal.
grep -q 'Maintainer command: `sudo aidevops approve issue 12 owner/app`' "${TEST_ROOT}/request"
grep -q -- '--label no-auto-dispatch' "${TEST_ROOT}/calls"
if grep -q -- '--label auto-dispatch' "${TEST_ROOT}/calls"; then exit 1; fi
grep -q 'cloudron-release-approval 1.2.3' "${TEST_ROOT}/request"
grep -q "$HEAD_SHA" "${TEST_ROOT}/request"
if grep -q 'Old entry' "${TEST_ROOT}/request"; then exit 1; fi
printf 'PASS request records exact head, changelog and dispatch hold\n'

# An already finalized request is read-only, preserving its signed digest.
export SCENARIO=request_existing
: >"${TEST_ROOT}/calls"
[[ "$(release_request owner/app 7)" == "$request_output" ]]
if grep -Eq 'create |issue-edit |verify' "${TEST_ROOT}/calls"; then exit 1; fi
printf 'PASS repeated request returns the ready command without editing\n'

for scenario in request_bad_url request_edit_error; do
	export SCENARIO="$scenario"
	rc=0
	output=$(release_request owner/app 7) || rc=$?
	[[ "$rc" -eq 1 && -z "$output" ]]
done
printf 'PASS invalid URL and failed finalization expose no approval command\n'

# The failed edit above left an unfinished issue. Never rewrite it if signed.
export SCENARIO=request_signed
: >"${TEST_ROOT}/calls"
if release_request owner/app 7; then exit 1; fi
if grep -q 'issue-edit ' "${TEST_ROOT}/calls"; then exit 1; fi
export SCENARIO=request_unsigned
[[ "$(release_request owner/app 7)" == "$request_output" ]]
# shellcheck disable=SC2016 # Markdown command backticks are literal.
grep -q 'Maintainer command: `sudo aidevops approve issue 12 owner/app`' "${TEST_ROOT}/request"
if grep -q 'Request finalization pending\.' "${TEST_ROOT}/request"; then exit 1; fi
grep -q 'issue-edit 12 --repo owner/app --body-file -' "${TEST_ROOT}/calls"
printf 'PASS interrupted unsigned request recovers; signed body is not rewritten\n'

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

# Isolate selection from publication in the existing harness: no network or merge.
(
	# Routine helpers above define their own main; restore the CLI under test.
	# shellcheck source=../cloudron-release-approval-helper.sh
	source "${SOURCE_DIR}/cloudron-release-approval-helper.sh"
	REPOS_FILE="${TEST_ROOT}/repos.json"
	printf '%s\n' '{"initialized_repos":[{"slug":"owner/app","app_type":"cloudron-package"},{"slug":"owner/other","app_type":"cloudron-package"},{"slug":"owner/disabled","app_type":"cloudron-package","maintenance":false}]}' >"$REPOS_FILE"
	gh() {
		local command="$1" target="${2:-}"
		printf '%s\n' "$*" >>"${TEST_ROOT}/calls"
		[[ "$command" == api && ("$target" == repos/owner/app || "$target" == repos/owner/other) ]] || return 9
		[[ "${SCENARIO:-}" != scope_denied ]] || { printf 'false\n'; return 0; }
		printf 'true\n'
		return 0
	}
	release_issues() {
		local repo="$1"
		printf 'list %s\n' "$repo" >>"${TEST_ROOT}/calls"
		printf '[{"number":12},{"number":13}]\n'
		return 0
	}
	release_process_issue() {
		local repo="$1" issue="$2" apply="$3"
		printf '%s %s %s\n' "$repo" "$issue" "$apply"
		return 0
	}
	# Scope selection only; held-PR reconciliation is exercised separately below.
	release_reconcile_held() {
		return 0
	}
	assert_scope() {
		local expected="$1"
		shift
		local output=""
		: >"${TEST_ROOT}/calls"
		output=$(main process "$@") || return 1
		[[ "$output" == "$expected" ]] || { printf 'FAIL scope: %s\n' "$output"; return 1; }
		printf 'PASS scope: process %s\n' "$*"
		return 0
	}
	assert_scope $'owner/app 12 false\nowner/app 13 false\nowner/other 12 false\nowner/other 13 false'
	assert_scope $'owner/app 12 true\nowner/app 13 true\nowner/other 12 true\nowner/other 13 true' --apply
	assert_scope $'owner/other 12 false\nowner/other 13 false' --repo owner/other
	if grep -q 'repos/owner/app\|list owner/app' "${TEST_ROOT}/calls"; then exit 1; fi
	assert_scope $'owner/app 12 false\nowner/other 12 false' --issue 12
	assert_scope 'owner/app 12 true' --repo owner/app --issue 12 --apply
	assert_scope 'owner/other 13 true' --apply --issue 13 --repo owner/other
	assert_scope '' --repo owner/app --issue 99
	for args in missing_repo missing_issue invalid_repo invalid_issue zero_issue duplicate_repo duplicate_issue unknown; do
		: >"${TEST_ROOT}/calls"
		case "$args" in
		missing_repo) set -- --apply --repo ;;
		missing_issue) set -- --apply --issue ;;
		invalid_repo) set -- --apply --repo invalid ;;
		invalid_issue) set -- --apply --issue nope ;;
		zero_issue) set -- --apply --issue 0 ;;
		duplicate_repo) set -- --repo owner/app --repo owner/other ;;
		duplicate_issue) set -- --issue 12 --issue 13 ;;
		unknown) set -- --apply --unknown ;;
		esac
		if main process "$@"; then exit 1; fi
		[[ ! -s "${TEST_ROOT}/calls" ]]
		printf 'PASS invalid scope rejected before processing: %s\n' "$args"
	done
	if main process --repo owner/unregistered --apply; then exit 1; fi
	if main process --repo owner/disabled --apply; then exit 1; fi
	export SCENARIO=scope_denied
	if main process --repo owner/app --issue 12 --apply; then exit 1; fi
	printf 'PASS scoped processing retains registration, maintenance and authority gates\n'
)

# GH#36268: held worker PRs get their deferred approval request, and older
# unsigned upstream bumps that main or the requested PR bundles are superseded.
# Worker PRs 20/21/22 link findings 30/31/32 (v1.0.0/v2.0.0/v3.0.0); main
# bundles 1.5.0. Human PR 25 and draft PR 26 are never candidates.
(
	# shellcheck source=../cloudron-release-approval-helper.sh
	source "${SOURCE_DIR}/cloudron-release-approval-helper.sh"
	held_request_body() {
		local pr="$1"
		jq -cn --argjson pr "$pr" --arg head "$HEAD_SHA" \
			'{schema:1,repository:"owner/app",pr:$pr,head:$head,version:"1.2.3",upstream:"3.0.0",owns_hold:true}'
		return 0
	}
	gh() {
		local command="$1" target="${2:-}" number="" version="" author=OWNER head=""
		printf 'gh %s\n' "$*" >>"${TEST_ROOT}/calls"
		case "$command $target" in
		'pr list')
			[[ "$HELD_SCENARIO" != list_error ]] || return 1
			# unmarked: PR 21 also links trusted, marker-less issue 37 ahead of finding 31.
			jq -cn --arg scenario "$HELD_SCENARIO" '[20,21,22] | map({number:., isDraft:false, isCrossRepository:false, headRefOid:("head-" + tostring),
				labels:[{name:"release-approval-required"},{name:"origin:worker"}], closingIssuesReferences:[{number:(. + 10)}]})
				| map(if $scenario == "unmarked" and .number == 21 then .closingIssuesReferences |= [{number:37}] + . else . end)
				+ [{number:25,isDraft:false,isCrossRepository:false,headRefOid:"head-25",labels:[{name:"release-approval-required"}],closingIssuesReferences:[{number:35}]},
				   {number:26,isDraft:true,isCrossRepository:false,headRefOid:"head-26",labels:[{name:"release-approval-required"},{name:"origin:worker"}],closingIssuesReferences:[{number:36}]}]'
			;;
		'api repos/owner/app/issues/37') printf '{"state":"open","author_association":"OWNER","body":"Related tracking issue"}\n' ;;
		'api repos/owner/app/issues/3'[0-2])
			number="${target##*/}"
			[[ "$HELD_SCENARIO" != finding_error || "$number" != 31 ]] || return 1
			case "$number" in 30) version=1.0.0 ;; 31) version=2.0.0 ;; *) version=3.0.0 ;; esac
			[[ "$HELD_SCENARIO" != untrusted || "$number" != 31 ]] || author=CONTRIBUTOR
			jq -cn --arg version "$version" --arg author "$author" \
				'{state:"open",author_association:$author,body:("Finding\n<!-- aidevops:cloudron-package-monitor upstream-v" + $version + " -->\n")}'
			;;
		'api repos/owner/app/contents/CloudronManifest.json?ref=main') printf '{"version":"1.2.3","upstreamVersion":"1.5.0"}\n' ;;
		'api repos/owner/app/pulls/'*)
			number="${target##*/}"
			head="head-${number}"
			[[ "$HELD_SCENARIO" != changed || "$number" != 21 ]] || head=moved
			jq -cn --arg head "$head" '{state:"open",merged:false,draft:false,author_association:"OWNER",
				head:{sha:$head,repo:{full_name:"owner/app"}},base:{repo:{full_name:"owner/app"}},
				labels:[{name:"release-approval-required"},{name:"origin:worker"}]}'
			;;
		'issue close') return 0 ;;
		*)
			printf 'Unexpected gh call: %s\n' "$*" >&2
			return 9
			;;
		esac
		return 0
	}
	release_checks() {
		[[ "$HELD_SCENARIO" != pending ]] || return 1
		printf '[]\n'
		return 0
	}
	release_request() {
		local repo="$1" pr="$2"
		printf 'request %s %s\n' "$repo" "$pr" >>"${TEST_ROOT}/calls"
		touch "${TEST_ROOT}/requested"
		return 0
	}
	release_issues() {
		local out='[]'
		if [[ -f "${TEST_ROOT}/requested" || "$HELD_SCENARIO" == signed ]]; then
			out=$(jq -c --arg body "$(held_request_body 22)" '. + [{number:40,body:$body}]' <<<"$out")
		fi
		if [[ "$HELD_SCENARIO" == signed || "$HELD_SCENARIO" == unsigned_request ]]; then
			out=$(jq -c --arg body "$(held_request_body 21)" '. + [{number:41,body:$body}]' <<<"$out")
		fi
		printf '%s\n' "$out"
		return 0
	}
	release_verify() {
		local repo="$1" issue="$2"
		if [[ "$HELD_SCENARIO" == signed && "$issue" == 41 ]]; then
			printf 'VERIFIED\n'
			return 0
		fi
		printf 'NO_APPROVAL\n'
		return 1
	}
	release_comment() {
		local repo="$1" issue="$2"
		printf 'comment %s\n' "$issue" >>"${TEST_ROOT}/calls"
		return 0
	}
	gh_pr_close_safe() {
		printf 'pr-close %s\n' "$1" >>"${TEST_ROOT}/calls"
		return 0
	}
	gh_pr_comment() {
		cat >/dev/null
		printf 'pr-comment %s\n' "$1" >>"${TEST_ROOT}/calls"
		return 0
	}
	run_held() {
		local scenario="$1" apply="$2" expected_rc="$3" rc=0
		export HELD_SCENARIO="$scenario"
		rm -f "${TEST_ROOT}/requested"
		: >"${TEST_ROOT}/calls"
		release_reconcile_held owner/app "$apply" "$(release_issues owner/app)" >"${TEST_ROOT}/held-out" 2>&1 || rc=$?
		[[ "$rc" -eq "$expected_rc" ]] || {
			printf 'FAIL held %s rc=%s\n' "$scenario" "$rc"
			cat "${TEST_ROOT}/held-out"
			return 1
		}
		return 0
	}
	has_call() {
		grep -qx -- "$1" "${TEST_ROOT}/calls"
		return $?
	}
	no_call() {
		if grep -qx -- "$1" "${TEST_ROOT}/calls"; then
			printf 'FAIL held %s: unexpected call %s\n' "$HELD_SCENARIO" "$1"
			return 1
		fi
		return 0
	}
	line_of() {
		grep -nx -- "$1" "${TEST_ROOT}/calls" | cut -d: -f1
		return 0
	}

	run_held request true 0
	has_call 'request owner/app 22'
	no_call 'request owner/app 25'
	no_call 'request owner/app 26'
	# One assertion per line: set -e ignores failures on the left of &&.
	has_call 'pr-close 20'
	has_call 'pr-close 21'
	no_call 'pr-close 22'
	no_call 'pr-close 25'
	no_call 'pr-close 26'
	has_call 'gh issue close 30 --repo owner/app --reason not planned'
	has_call 'gh issue close 31 --repo owner/app --reason not planned'
	no_call 'gh issue close 32 --repo owner/app --reason not planned'
	has_call 'comment 30'
	has_call 'comment 31'
	has_call 'pr-comment 21'
	# Close before comment: an interrupted run never repeats a comment.
	[[ "$(line_of 'pr-close 21')" -lt "$(line_of 'pr-comment 21')" ]]
	[[ "$(line_of 'gh issue close 31 --repo owner/app --reason not planned')" -lt "$(line_of 'comment 31')" ]]
	grep -q 'main already bundles upstream 1.5.0' "${TEST_ROOT}/held-out"
	grep -q 'PR #22 bundles newer v3.0.0 (finding #32)' "${TEST_ROOT}/held-out"
	printf 'PASS held: newest worker PR requested; older bumps superseded by main or the request\n'

	run_held pending true 0
	no_call 'request owner/app 22'
	has_call 'pr-close 20'
	no_call 'pr-close 21'
	grep -q 'waits for terminal-green checks' "${TEST_ROOT}/held-out"
	printf 'PASS held: pending checks wait; only bumps main already bundles are superseded\n'

	run_held signed true 0
	no_call 'request owner/app 22'
	has_call 'pr-close 20'
	no_call 'pr-close 21'
	no_call 'gh issue close 41 --repo owner/app --reason not planned'
	no_call 'gh issue close 31 --repo owner/app --reason not planned'
	grep -q 'PR #21: retained; approval request #41 is VERIFIED' "${TEST_ROOT}/held-out"
	printf 'PASS held: a signed approval is never superseded\n'

	run_held unsigned_request true 0
	has_call 'request owner/app 22'
	has_call 'pr-close 21'
	has_call 'gh issue close 41 --repo owner/app --reason not planned'
	has_call 'comment 41'
	printf 'PASS held: an older unsigned request closes with its superseded PR\n'

	run_held dry false 0
	if grep -Eq '^(request |pr-close |pr-comment |comment )|^gh issue close' "${TEST_ROOT}/calls"; then exit 1; fi
	grep -q 'PR #22: would request release approval (dry run)' "${TEST_ROOT}/held-out"
	grep -q 'PR #20: would supersede' "${TEST_ROOT}/held-out"
	grep -q 'PR #21: would supersede' "${TEST_ROOT}/held-out"
	printf 'PASS held: dry run reports and never writes\n'

	run_held changed true 0
	has_call 'pr-close 20'
	no_call 'pr-close 21'
	no_call 'gh issue close 31 --repo owner/app --reason not planned'
	printf 'PASS held: a PR that changed after listing is retained\n'

	run_held untrusted true 0
	no_call 'pr-close 21'
	printf 'PASS held: an outsider-authored finding marker never authorizes supersession\n'

	run_held unmarked true 0
	has_call 'pr-close 21'
	has_call 'gh issue close 31 --repo owner/app --reason not planned'
	no_call 'gh issue close 37 --repo owner/app --reason not planned'
	printf 'PASS held: a trusted linked issue without a monitor marker is not a finding\n'

	for scenario in finding_error list_error; do
		run_held "$scenario" true 1
		if grep -Eq '^(request |pr-close |pr-comment |comment )|^gh issue close' "${TEST_ROOT}/calls"; then exit 1; fi
	done
	printf 'PASS held: API errors fail closed before any write\n'
)
