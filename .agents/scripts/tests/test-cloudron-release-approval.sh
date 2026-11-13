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
unsigned | request_unsigned | request_retry | policy_*) printf 'NO_APPROVAL\n'; exit 1 ;;
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
	[[ "$SCENARIO" != request_issues_error ]] || return 1
	if [[ "$SCENARIO" == request_existing || "$SCENARIO" == request_unsigned || "$SCENARIO" == request_signed || ("$SCENARIO" == request_retry && -f "${TEST_ROOT}/request") ]]; then
		jq -cn --rawfile body "${TEST_ROOT}/request" '[{number:12,html_url:"https://example.invalid/issue/12",body:$body}]'
	elif [[ "$SCENARIO" == request* ]]; then
		printf '[]\n'
	else
		gh api repos/owner/app/issues/12 | jq -c '[. + {number:12}]'
	fi
	return 0
}

pull_request_json() {
	local head="$HEAD_SHA" merged=false state=open labels='[]'
	if [[ "$SCENARIO" == request_bare_hold ]]; then
		labels='[{"name":"hold-for-review"}]'
	elif [[ "$SCENARIO" == request_retry && -f "${TEST_ROOT}/held-labels" ]]; then
		labels=$(<"${TEST_ROOT}/held-labels")
	fi
	[[ "$SCENARIO" != changed && "$SCENARIO" != policy_changed ]] || head="$OTHER_SHA"
	if [[ -f "${TEST_ROOT}/merged" || "$SCENARIO" == resumed || "$SCENARIO" == policy_resumed* ]]; then
		merged=true
		state=closed
	fi
	[[ "$SCENARIO" != pr_error ]] || return 1
	jq -cn --arg head "$head" --arg state "$state" --argjson merged "$merged" --arg scenario "$SCENARIO" --argjson labels "$labels" '
		{head:{sha:$head,repo:{full_name:"owner/app"}},base:{ref:"main",repo:{full_name:"owner/app"}},state:$state,merged:$merged,merge_commit_sha:$head,draft:false,labels:$labels,auto_merge:null}
		| if $scenario == "draft" then .draft = true
		  elif $scenario == "fork" then .head.repo.full_name = "other/app"
		  elif $scenario == "wrong_repo" then .base.repo.full_name = "other/app"
		  elif $scenario == "wrong_base" then .base.ref = "develop"
		  elif $scenario == "invalid_head" then .head.sha = "invalid"
		  elif $scenario == "closed" then .state = "closed"
		  else . end'
	return 0
}

# Release request issue #12; an outsider author must never reach the policy.
request_issue_json() {
	local body="" author=OWNER
	body=$(jq -cn --arg head "$HEAD_SHA" '{schema:1,repository:"owner/app",pr:7,head:$head,version:"1.2.3",upstream:"4.5.6",owns_hold:true}')
	[[ "$SCENARIO" != policy_outsider_request ]] || author=CONTRIBUTOR
	jq -cn --arg body "$body" --arg author "$author" '{state:"open",author_association:$author,body:$body,labels:[{name:"release-approval-required"}]}'
	return 0
}

# Comments on request issue #12; the merge-authority record is OWNER-trusted
# unless the scenario plants an outsider copy.
request_comments_json() {
	local author=OWNER
	case "$SCENARIO" in
	policy_resumed_recorded | policy_resumed_outsider_record)
		[[ "$SCENARIO" != policy_resumed_outsider_record ]] || author=CONTRIBUTOR
		jq -cn --arg head "$HEAD_SHA" --arg author "$author" \
			'[{author_association:$author,body:("<!-- aidevops:cloudron-release-merge-authority " + $head + " policy #50 -->\nMerged")}]'
		;;
	*) printf '[]\n' ;;
	esac
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
	'api repos/owner/app/issues/12/comments?'*) request_comments_json ;;
	'api repos/owner/app/issues/12') request_issue_json ;;
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
	'api repos/owner/app/labels?'*)
		[[ "$SCENARIO" != request_labels_error ]] || return 1
		# GH#36292: a package repo without aidevops system labels.
		if [[ "$SCENARIO" == request ]]; then
			printf 'release-approval-required\nbug\n'
		else
			printf 'release-approval-required\nhold-for-review\nno-auto-dispatch\n'
		fi
		;;
	'label create') return 0 ;;
	# No held worker PRs: approval processing alone (GH#36268 cases run below).
	'pr list')
		if [[ "$SCENARIO" == request_retry ]]; then
			jq -cn --arg head "$HEAD_SHA" --slurpfile labels "${TEST_ROOT}/held-labels" '[{number:7,isDraft:false,isCrossRepository:false,headRefOid:$head,labels:$labels[0],closingIssuesReferences:[]}]'
		else
			printf '[]\n'
		fi
		;;
	*)
		printf 'Unexpected gh call: %s\n' "$*" >&2
		return 9
		;;
	esac
	return 0
}

gh_pr_edit_safe() {
	printf 'pr-edit %s\n' "$*" >>"${TEST_ROOT}/calls"
	if [[ "$SCENARIO" == request_create_error || "$SCENARIO" == request_retry ]]; then
		[[ "$*" == '7 --repo owner/app --add-label release-approval-required --add-label hold-for-review' ]] || return 9
		printf '[{"name":"release-approval-required"},{"name":"hold-for-review"}]\n' >"${TEST_ROOT}/held-labels"
	fi
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
	[[ "$SCENARIO" != request_create_error ]] || return 1
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
# GH#36292: only absent labels are created, before the first PR label write.
grep -q '^label create hold-for-review --repo owner/app ' "${TEST_ROOT}/calls"
grep -q '^label create no-auto-dispatch --repo owner/app ' "${TEST_ROOT}/calls"
if grep -q '^label create release-approval-required ' "${TEST_ROOT}/calls"; then exit 1; fi
[[ "$(grep -n '^label create no-auto-dispatch ' "${TEST_ROOT}/calls" | cut -d: -f1)" -lt "$(grep -n '^pr-edit ' "${TEST_ROOT}/calls" | cut -d: -f1)" ]]
grep -q 'cloudron-release-approval 1.2.3' "${TEST_ROOT}/request"
grep -q "$HEAD_SHA" "${TEST_ROOT}/request"
if grep -q 'Old entry' "${TEST_ROOT}/request"; then exit 1; fi
printf 'PASS request records exact head, changelog and dispatch hold\n'

# A converged repo costs one label read and no label writes.
export SCENARIO=request_converged
: >"${TEST_ROOT}/calls"
release_request owner/app 7 >/dev/null
if grep -q '^label create ' "${TEST_ROOT}/calls"; then exit 1; fi
# Unknown label state fails closed before any hold or issue write.
export SCENARIO=request_labels_error
: >"${TEST_ROOT}/calls"
rc=0
output=$(release_request owner/app 7 2>&1) || rc=$?
[[ "$rc" -eq 4 && "$output" == *'Unable to provision release approval labels in owner/app'* ]]
[[ "$output" == *'--add-label release-approval-required --add-label hold-for-review'* ]]
if grep -Eq '^(label create |pr-edit |create )' "${TEST_ROOT}/calls"; then exit 1; fi
printf 'PASS request provisions only missing labels and fails closed on unknown label state\n'

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

# GH#36402: a failed create leaves both labels; repo-wide processing retries
# a non-worker PR once, without a signature or permission to release its hold.
export SCENARIO=request_create_error
rm -f "${TEST_ROOT}/request" "${TEST_ROOT}/held-labels"
: >"${TEST_ROOT}/calls"
if release_request owner/app 7; then exit 1; fi
[[ ! -f "${TEST_ROOT}/request" ]]
jq -e 'any(.[]; .name == "release-approval-required") and any(.[]; .name == "hold-for-review")' "${TEST_ROOT}/held-labels" >/dev/null
export SCENARIO=request_retry
release_process false
[[ ! -f "${TEST_ROOT}/request" ]]
release_process true
[[ -f "${TEST_ROOT}/request" ]]
release_process true
[[ "$(grep -c '^create ' "${TEST_ROOT}/calls")" -eq 1 ]]
if grep -Eq 'merge$|--remove-label|issue close' "${TEST_ROOT}/calls"; then exit 1; fi
printf 'PASS interrupted request retries exactly once and retains unsigned hold\n'
export SCENARIO=request_issues_error
rc=0
output=$(main request owner/app 7 2>&1) || rc=$?
[[ "$rc" -eq 4 && "$output" == *'--add-label release-approval-required --add-label hold-for-review'* ]]
printf 'PASS pre-hold API failure preserves distinct CLI recovery status\n'
export SCENARIO=request_bare_hold
: >"${TEST_ROOT}/calls"
if release_request owner/app 7; then exit 1; fi
if grep -Eq '^pr-edit |^create ' "${TEST_ROOT}/calls"; then exit 1; fi
printf 'PASS bare unrelated hold still refuses request\n'

export SCENARIO=unsigned
if release_authorize owner/app 7 "$HEAD_SHA"; then exit 1; fi
export SCENARIO=approved
release_authorize owner/app 7 "$HEAD_SHA"
if release_authorize owner/app 7 "$OTHER_SHA"; then exit 1; fi
printf 'PASS common release authorization requires signature and matching head\n'

# GH#37697: an unsigned request releases only through the signed standing
# policy; the predicate plumbing is exercised separately below.
(
	release_policy_authorizes() {
		printf 'policy-check %s %s %s\n' "$@" >>"${TEST_ROOT}/calls"
		case "$SCENARIO" in policy_denied | policy_changed | policy_inactive) return 1 ;; esac
		[[ "$1" == owner/app && "$2" == 7 && "$3" == "$HEAD_SHA" ]] || return 1
		printf '50\n'
		return 0
	}
	release_policy_active() {
		[[ "$SCENARIO" != policy_inactive ]] || return 1
		printf '50\t{}\n'
		return 0
	}
	run_case policy_unsigned 0 true true true
	grep -q 'authority: standing policy #50' "${TEST_ROOT}/calls"
	# Proven once to select the path and again immediately before merge.
	[[ "$(grep -c '^policy-check owner/app 7 ' "${TEST_ROOT}/calls")" -ge 2 ]]
	printf 'PASS policy: unsigned routine bump merges, publishes and records its authority\n'
	run_case policy_denied 0 false false false
	printf 'PASS policy: a non-routine change still waits for a per-release signature\n'
	run_case stale 0 false false false
	if grep -q '^policy-check ' "${TEST_ROOT}/calls"; then exit 1; fi
	run_case api_error 1 false false false
	if grep -q '^policy-check ' "${TEST_ROOT}/calls"; then exit 1; fi
	printf 'PASS policy: stale or unverifiable signatures never fall back to the policy\n'
	run_case policy_outsider_request 0 false false false
	if grep -q '^policy-check ' "${TEST_ROOT}/calls"; then exit 1; fi
	printf 'PASS policy: an outsider-authored request never reaches the policy\n'
	run_case policy_resumed 0 false true true
	grep -q 'authority: publication verification only; merge authority not recorded' "${TEST_ROOT}/calls"
	if grep -qi 'outside' "${TEST_ROOT}/calls"; then exit 1; fi
	if grep -q '^policy-check ' "${TEST_ROOT}/calls"; then exit 1; fi
	run_case policy_resumed_outsider_record 0 false true true
	grep -q 'authority: publication verification only; merge authority not recorded' "${TEST_ROOT}/calls"
	run_case policy_resumed_recorded 0 false true true
	grep -q "authority: standing policy #50 (merge recorded at ${HEAD_SHA}); publication verified" "${TEST_ROOT}/calls"
	if grep -qi 'outside' "${TEST_ROOT}/calls"; then exit 1; fi
	if grep -q '^policy-check ' "${TEST_ROOT}/calls"; then exit 1; fi
	printf 'PASS policy: a merged exact head reports a trusted recorded authority, else neutral wording, and never authorizes\n'
	run_case policy_changed 0 false true true
	grep -q 'issue close 12 --repo owner/app --reason not planned' "${TEST_ROOT}/calls"
	printf 'PASS policy: an unsigned request whose head moved is retired for a fresh request\n'
	export SCENARIO=policy_inactive
	: >"${TEST_ROOT}/calls"
	pull_request_json() {
		jq -cn --arg head "$OTHER_SHA" '{head:{sha:$head,repo:{full_name:"owner/app"}},base:{ref:"main",repo:{full_name:"owner/app"}},state:"open",merged:false,draft:false,labels:[],auto_merge:null}'
		return 0
	}
	release_process true
	if grep -q 'issue close' "${TEST_ROOT}/calls"; then exit 1; fi
	printf 'PASS policy: without an active policy a moved unsigned request is left alone\n'
	unset -f pull_request_json
	export SCENARIO=policy_unsigned
	release_authorize owner/app 7 "$HEAD_SHA"
	if release_authorize owner/app 7 "$OTHER_SHA"; then exit 1; fi
	export SCENARIO=policy_denied
	if release_authorize owner/app 7 "$HEAD_SHA"; then exit 1; fi
	export SCENARIO=stale
	if release_authorize owner/app 7 "$HEAD_SHA"; then exit 1; fi
	export SCENARIO=policy_outsider_request
	if release_authorize owner/app 7 "$HEAD_SHA"; then exit 1; fi
	printf 'PASS policy: the merge-authority guard accepts only a policy-proven exact head from a trusted request\n'
)

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
	release_retry_interrupted() {
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
		[[ "$HELD_SCENARIO" != request_error ]] || return 1
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

	# GH#36292: a failed request fails the run without blocking independent work.
	run_held request_error true 1
	has_call 'request owner/app 22'
	has_call 'pr-close 20'
	no_call 'pr-close 21'
	no_call 'gh issue close 31 --repo owner/app --reason not planned'
	printf 'PASS held: a failed request is counted; bumps main bundles are still superseded\n'

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

# GH#37697: the routine-bump predicate. The fixture mirrors a real upstream-only
# bump (manifest, Dockerfile pin, changelogs and test assertions).
b64() {
	printf '%s' "$1" | base64 | tr -d '\n'
	return 0
}
# The policy is the helper's real default, so its insertion pattern is tested
# against realistic check-file lines.
POLICY_JSON=$(
	# shellcheck source=../cloudron-release-approval-helper.sh
	source "${SOURCE_DIR}/cloudron-release-approval-helper.sh"
	release_policy_metadata "$(release_policy_body owner/app 'Maintainer command: x')" owner/app
)
BASE_MANIFEST='{"id":"io.example.app","version":"0.1.43","upstreamVersion":"3.39.87","changelog":"file://CHANGELOG"}'
HEAD_MANIFEST='{"id":"io.example.app","version":"0.1.44","upstreamVersion":"3.39.114","changelog":"file://CHANGELOG"}'
BASE_DOCKERFILE=$'FROM base@sha256:abc\nARG NODE_VERSION=10.1.43\nARG AIDEVOPS_VERSION=3.39.87\n'
HEAD_DOCKERFILE=$'FROM base@sha256:abc\nARG NODE_VERSION=10.1.43\nARG AIDEVOPS_VERSION=3.39.114\n'
CHECK_PREFIX=$'main() {\n\tjq -e \'.version == "'
BASE_CHECK="${CHECK_PREFIX}"$'0.1.43" and .upstreamVersion == "3.39.87"\' m || return 1\n\tassert_contains CHANGELOG \'[0.1.43]\' || return 1\n\tassert_contains Dockerfile \'ARG AIDEVOPS_VERSION=3.39.87\' || return 1\n}\n'
CHECK_INSERTED=$'\tassert_contains CHANGELOG \'* Update the bundled aidevops CLI to 3.39.114.\' || return 1\n\tassert_contains CHANGELOG.md "- Updated and pinned the bundled aidevops CLI to \\`3.39.114\\`." || return 1\n'
HEAD_CHECK="${CHECK_PREFIX}"$'0.1.44" and .upstreamVersion == "3.39.114"\' m || return 1\n\tassert_contains CHANGELOG \'[0.1.44]\' || return 1\n'"${CHECK_INSERTED}"$'\tassert_contains Dockerfile \'ARG AIDEVOPS_VERSION=3.39.114\' || return 1\n}\n'
routine_doc() {
	local filter="${1:-.}"
	jq -cn --argjson policy "$POLICY_JSON" --arg bm "$(b64 "$BASE_MANIFEST")" --arg hm "$(b64 "$HEAD_MANIFEST")" \
		--arg bd "$(b64 "$BASE_DOCKERFILE")" --arg hd "$(b64 "$HEAD_DOCKERFILE")" \
		--arg bc "$(b64 "$BASE_CHECK")" --arg hc "$(b64 "$HEAD_CHECK")" '
		{policy: $policy, finding_upstream: "3.39.114",
		 files: [{filename: "CHANGELOG", status: "modified", additions: 3, deletions: 0},
		         {filename: "CHANGELOG.md", status: "modified", additions: 6, deletions: 0},
		         {filename: "CloudronManifest.json", status: "modified", additions: 2, deletions: 2},
		         {filename: "Dockerfile", status: "modified", additions: 2, deletions: 2},
		         {filename: "test/package-test.sh", status: "modified", additions: 6, deletions: 4}],
		 contents: {"CloudronManifest.json": {base: $bm, head: $hm}, Dockerfile: {base: $bd, head: $hd},
		            "test/package-test.sh": {base: $bc, head: $hc}}}
		| '"$filter"
	return 0
}
# Rejections must name the expected reason so a removed guard cannot pass
# silently through a different one.
assert_routine() {
	local expected="$1" label="$2" filter="${3:-.}" reason="${4:-}" output="" rc=0
	output=$(routine_doc "$filter" | python3 "${SOURCE_DIR}/cloudron_routine_bump.py" --repository owner/app) || rc=$?
	if [[ "$expected" == routine ]]; then
		[[ "$rc" -eq 0 && "$output" == ROUTINE_BUMP ]] || { printf 'FAIL routine %s: %s\n' "$label" "$output"; return 1; }
	else
		[[ -n "$reason" && "$rc" -eq 1 && "$output" == NOT_ROUTINE:*"$reason"* ]] || { printf 'FAIL not-routine %s rc=%s: %s\n' "$label" "$rc" "$output"; return 1; }
	fi
	printf 'PASS predicate %s: %s\n' "$label" "$output"
	return 0
}
manifest_head() {
	printf '.contents["CloudronManifest.json"].head = "%s"' "$(b64 "$1")"
	return 0
}
dockerfile_head() {
	printf '.contents.Dockerfile.head = "%s"' "$(b64 "$1")"
	return 0
}
check_head() {
	printf '.contents["test/package-test.sh"].head = "%s"' "$(b64 "$1")"
	return 0
}
manifest_base() {
	printf '.contents["CloudronManifest.json"].base = "%s"' "$(b64 "$1")"
	return 0
}
assert_routine routine 'upstream-only bump'
assert_routine routine 'without a pinned-file change' 'del(.files[3]) | del(.contents.Dockerfile)'
assert_routine routine 'check file with substitution only' "$(check_head "${HEAD_CHECK//"$CHECK_INSERTED"/}")"
assert_routine not 'extra file' '.files += [{filename: "start.sh", status: "modified", additions: 1, deletions: 0}]' 'outside the standing policy'
assert_routine not 'added check file' '.files[4].status = "added"' 'only in-place modifications'
assert_routine not 'renamed pinned file' '.files[3].previous_filename = "Dockerfile.old"' 'only in-place modifications'
assert_routine not 'manifest unchanged' 'del(.files[2])' 'the manifest must change'
assert_routine not 'no changelog entry' 'del(.files[0, 1])' 'a changelog entry is required'
assert_routine not 'changelog deletion' '.files[0].deletions = 1' 'changelog edits must only add lines'
assert_routine not 'too many files' '.files += [range(0; 20) | {filename: "CHANGELOG", status: "modified", additions: 1, deletions: 0}]' 'empty or too large'
assert_routine not 'other manifest field' "$(manifest_head '{"id":"io.example.other","version":"0.1.44","upstreamVersion":"3.39.114","changelog":"file://CHANGELOG"}')" 'manifest changes beyond'
assert_routine not 'added manifest field' "$(manifest_head '{"id":"io.example.app","version":"0.1.44","upstreamVersion":"3.39.114","changelog":"file://CHANGELOG","tcpPorts":{}}')" 'manifest changes beyond'
assert_routine not 'boolean to integer manifest field' "$(manifest_base '{"id":"io.example.app","version":"0.1.43","upstreamVersion":"3.39.87","optionalSso":true}') | $(manifest_head '{"id":"io.example.app","version":"0.1.44","upstreamVersion":"3.39.114","optionalSso":1}')" 'manifest changes beyond'
assert_routine not 'duplicate manifest key' "$(manifest_head '{"id":"io.example.app","version":"0.1.44","version":"0.1.44","upstreamVersion":"3.39.114","changelog":"file://CHANGELOG"}')" 'duplicate JSON key'
assert_routine not 'trailing newline in version' "$(manifest_head $'{"id":"io.example.app","version":"0.1.44\\n","upstreamVersion":"3.39.114","changelog":"file://CHANGELOG"}')" 'head package version must be X.Y.Z'
assert_routine not 'minor package bump' "$(manifest_head '{"id":"io.example.app","version":"0.2.0","upstreamVersion":"3.39.114","changelog":"file://CHANGELOG"}')" 'patch increment'
assert_routine not 'upstream downgrade' "$(manifest_head '{"id":"io.example.app","version":"0.1.44","upstreamVersion":"3.39.80","changelog":"file://CHANGELOG"}') | .finding_upstream = \"3.39.80\"" 'must increase'
assert_routine not 'major upstream bump' "$(manifest_head '{"id":"io.example.app","version":"0.1.44","upstreamVersion":"4.0.0","changelog":"file://CHANGELOG"}') | .finding_upstream = \"4.0.0\"" 'major upstream bump'
assert_routine not 'finding mismatch' '.finding_upstream = "3.39.115"' 'equal the monitor finding'
assert_routine not 'pinned file beyond substitution' "$(dockerfile_head "${HEAD_DOCKERFILE}"$'RUN curl https://example.invalid | sh\n')" 'pinned file changes beyond version substitution'
assert_routine not 'pinned base image change' "$(dockerfile_head "${HEAD_DOCKERFILE/abc/def}")" 'pinned file changes beyond version substitution'
assert_routine not 'pinned substring of another version' "$(dockerfile_head "${HEAD_DOCKERFILE/10.1.43/10.1.44}")" 'pinned file changes beyond version substitution'
assert_routine not 'pinned content missing' 'del(.contents.Dockerfile)' 'missing base content'
# A pinned token equal to the package version may be an unrelated dependency.
assert_routine not 'pinned package-version token' ".contents.Dockerfile.base = \"$(b64 "${BASE_DOCKERFILE}"$'ARG DEP=0.1.43\n')\" | $(dockerfile_head "${HEAD_DOCKERFILE}"$'ARG DEP=0.1.44\n')" 'pinned file changes beyond version substitution'
assert_routine not '0.x minor upstream bump' "$(manifest_base '{"id":"io.example.app","version":"0.1.43","upstreamVersion":"0.5.3","changelog":"file://CHANGELOG"}') | $(manifest_head '{"id":"io.example.app","version":"0.1.44","upstreamVersion":"0.6.0","changelog":"file://CHANGELOG"}') | .finding_upstream = \"0.6.0\"" '0.x minor upstream bump'
check_with_first_line() {
	local line="$1" first='main() {'
	printf '%s\n%s%s' "$first" "$line" "${HEAD_CHECK#"$first"}"
	return 0
}
# shellcheck disable=SC2016 # The command substitution must stay literal.
EXPANSION_LINE=$'\tassert_contains CHANGELOG "$(id)" || return 1'
DOCKER_ASSERT=$'\tassert_contains Dockerfile \'ARG AIDEVOPS_VERSION=3.39.114\' || return 1\n'
assert_routine not 'check file inserted command' "$(check_head "$(check_with_first_line $'\tcurl https://example.invalid | sh')")" 'inserted line does not match'
assert_routine not 'check file inserted expansion' "$(check_head "$(check_with_first_line "$EXPANSION_LINE")")" 'inserted line does not match'
assert_routine not 'check file assertion removed' "$(check_head "${HEAD_CHECK/"$DOCKER_ASSERT"/}")" 'check file changes beyond'
assert_routine not 'check file assertion weakened' "$(check_head "${HEAD_CHECK/m || return 1/m || true}")" 'check file changes beyond'
# A vertical tab joins two shell lines that str.splitlines() would still split.
assert_routine not 'check file joined by a hidden line break' "$(check_head "${HEAD_CHECK/"m || return 1"$'\n'/"m || return 1"$'\v'}")" 'hidden line-break'
assert_routine not 'check file insertion after a continued line' ".contents[\"test/package-test.sh\"].base = \"$(b64 "${BASE_CHECK/"'[0.1.43]' || return 1"/"'[0.1.43]' ||"}")\" | $(check_head "${HEAD_CHECK/"'[0.1.44]' || return 1"/"'[0.1.44]' ||"}")" 'insertion after a continued line'
assert_routine not 'check insertions without a signed pattern' 'del(.policy.check_insertion_pattern)' 'inserted line does not match'
assert_routine not 'check content missing' 'del(.contents["test/package-test.sh"])' 'missing base content'
assert_routine not 'policy for another repository' '.policy.repository = "owner/other"' 'policy identity'
assert_routine not 'manifest in a looser class' '.policy.check_files += ["CloudronManifest.json"]' 'invalid path'
assert_routine not 'path traversal in policy' '.policy.check_files += ["../start.sh"]' 'invalid path'
assert_routine not 'overlapping policy classes' '.policy.check_files += ["Dockerfile"]' 'overlap'

# GH#38013: SHA policies require a fresh signed mode and repository. A commit
# fingerprint alone is not ancestry evidence, and prefixes are whole tokens.
OLD_UPSTREAM=1234567aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEW_UPSTREAM=abcdef1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
(
	POLICY_JSON=$(jq -c '. + {upstream_mode:"commits",upstream_repository:"upstream/project"}' <<<"$POLICY_JSON")
	BASE_MANIFEST="${BASE_MANIFEST//3.39.87/1234567}"
	HEAD_MANIFEST="${HEAD_MANIFEST//3.39.114/abcdef1}"
	BASE_DOCKERFILE="${BASE_DOCKERFILE//3.39.87/1234567}"
	HEAD_DOCKERFILE="${HEAD_DOCKERFILE//3.39.114/abcdef1}"
	BASE_CHECK="${BASE_CHECK//3.39.87/1234567}"
	HEAD_CHECK="${HEAD_CHECK//3.39.114/abcdef1}"
	commit_filter=".finding_upstream = \"$NEW_UPSTREAM\" | .upstream_proof = {repository:\"upstream/project\",base:\"$OLD_UPSTREAM\",head:\"$NEW_UPSTREAM\",status:\"ahead\",merge_base:\"$OLD_UPSTREAM\"}"
	assert_routine routine 'commit forward ancestry' "$commit_filter"
	for status in diverged behind identical; do
		assert_routine not "commit $status" "$commit_filter | .upstream_proof.status = \"$status\"" 'strictly ahead'
	done
	assert_routine not 'commit missing proof' "$commit_filter | del(.upstream_proof)" 'proof repository mismatch'
	assert_routine not 'commit wrong upstream' "$commit_filter | .upstream_proof.repository = \"other/project\"" 'proof repository mismatch'
	assert_routine not 'commit finding mismatch' "$commit_filter | .finding_upstream = \"$OLD_UPSTREAM\"" 'equal the monitor finding'
	assert_routine not 'commit resolved head mismatch' "$commit_filter | .upstream_proof.head = \"$OLD_UPSTREAM\"" 'proof commit mismatch'
	assert_routine not 'commit wrong base' "$commit_filter | .upstream_proof.base = \"$NEW_UPSTREAM\"" 'proof commit mismatch'
	assert_routine not 'commit wrong merge base' "$commit_filter | .upstream_proof.merge_base = \"$NEW_UPSTREAM\"" 'strictly ahead'
	assert_routine not 'commit no signed mode' "$commit_filter | del(.policy.upstream_mode)" 'head upstreamVersion must be X.Y.Z'
	assert_routine not 'commit unknown mode' "$commit_filter | .policy.upstream_mode = \"tags\"" 'unsupported upstream mode'
	assert_routine not 'commit no signed upstream' "$commit_filter | del(.policy.upstream_repository)" 'needs an upstream repository'
	assert_routine not 'commit extra file' "$commit_filter | .files += [{filename:\"start.sh\",status:\"modified\"}]" 'outside the standing policy'
	for token in 1234567a a1234567 pin1234567 1234567_extra; do
		assert_routine not "commit partial token $token" "$commit_filter | .contents.Dockerfile.base = \"$(b64 "ARG DEP=$token")\" | .contents.Dockerfile.head = \"$(b64 "ARG DEP=${token/1234567/abcdef1}")\"" 'pinned file changes beyond version substitution'
	done
)
# Main-build suffixes cannot borrow tag authority; the documented migration
# needs one per-release signature before strict-tag routine bumps can start.
assert_routine not 'Buzz main-build cannot use a tag finding' "$(manifest_base '{"version":"0.1.43","upstreamVersion":"0.5.28-main.2cd40ba"}') | $(manifest_head '{"version":"0.1.44","upstreamVersion":"0.5.29"}') | .finding_upstream = \"0.5.29\"" 'base upstreamVersion must be X.Y.Z'
assert_routine routine 'Buzz after signed strict-tag migration' "del(.files[3,4]) | $(manifest_base '{"version":"0.1.43","upstreamVersion":"0.5.28"}') | $(manifest_head '{"version":"0.1.44","upstreamVersion":"0.5.29"}') | .finding_upstream = \"0.5.29\""

# GH#37697: release_policy_authorizes plumbing against stubbed GitHub reads.
(
	# shellcheck source=../cloudron-release-approval-helper.sh
	source "${SOURCE_DIR}/cloudron-release-approval-helper.sh"
	SCRIPT_DIR="$SOURCE_DIR"
	BASE_SHA=cccccccccccccccccccccccccccccccccccccccc
	MAIN_SHA=dddddddddddddddddddddddddddddddddddddddd
	policy_issue_json() {
		local number="$1" author="$2" repo="${3:-owner/app}"
		jq -cn --argjson number "$number" --arg author "$author" \
			--arg body "$(release_policy_body "$repo" "Maintainer command: \`sudo aidevops approve issue ${number} ${repo}\`" "${POLICY_MODE:-semver}" "${POLICY_UPSTREAM:-}")" \
			'{number: $number, html_url: ("https://example.invalid/issue/" + ($number | tostring)), author_association: $author, body: $body,
			  state: "open", closed_at: null, updated_at: "2026-11-11T00:00:00Z", labels: [{name: "release-standing-policy"}]}'
		return 0
	}
	# Base64 file contents at the merge base or exact head ("<path>?ref=<sha>").
	policy_contents_stub() {
		local path="${1%%\?ref=*}" ref="${1##*\?ref=}" docker="$HEAD_DOCKERFILE" check="$HEAD_CHECK"
		[[ "$POLICY_CASE" != docker_tamper ]] || docker="${HEAD_DOCKERFILE/abc/def}"
		[[ "$POLICY_CASE" != check_tamper ]] || check="${HEAD_CHECK/m || return 1/m || true}"
		case "${path}@${ref}" in
		"CloudronManifest.json@${BASE_SHA}") b64 "$BASE_MANIFEST" ;;
		"CloudronManifest.json@${HEAD_SHA}") b64 "$HEAD_MANIFEST" ;;
		"Dockerfile@${BASE_SHA}") b64 "$BASE_DOCKERFILE" ;;
		"Dockerfile@${HEAD_SHA}") b64 "$docker" ;;
		"test/package-test.sh@${BASE_SHA}") b64 "$BASE_CHECK" ;;
		"test/package-test.sh@${HEAD_SHA}") b64 "$check" ;;
		*) return 1 ;;
		esac
		printf '\n'
		return 0
	}
	gh() {
		local command="$1" target="${2:-}"
		printf 'gh %s\n' "$*" >>"${TEST_ROOT}/calls"
		case "$command $target" in
		'api repos/owner/app/issues/50')
			# The post-verification re-read; "swapped" serves a different body.
			case "$POLICY_CASE" in
			swapped) policy_issue_json 50 OWNER | jq -c '.body |= sub("Dockerfile"; "start.sh")' ;;
			*) policy_issue_json 50 OWNER ;;
			esac
			;;
		'api repos/owner/app/git/ref/heads/main') printf '%s\n' "$MAIN_SHA" ;;
		'api repos/owner/app/issues?state=open&labels=release-standing-policy&per_page=100')
			case "$POLICY_CASE" in
			none | create) printf '[]\n' ;;
			multiple) jq -cn --argjson a "$(policy_issue_json 50 OWNER)" --argjson b "$(policy_issue_json 51 OWNER)" '[$a, $b]' ;;
			outsider) jq -cn --argjson a "$(policy_issue_json 50 CONTRIBUTOR)" '[$a]' ;;
			other_repo) jq -cn --argjson a "$(policy_issue_json 50 OWNER owner/other)" '[$a]' ;;
			unfinished) jq -cn --argjson a "$(policy_issue_json 50 OWNER)" '[$a | .body |= sub("Maintainer command:[^\n]*"; "Policy finalization pending. Do not sign until the maintainer command appears.")]' ;;
			*) jq -cn --argjson a "$(policy_issue_json 50 OWNER)" '[$a]' ;;
			esac
			;;
		'api repos/owner/app/pulls/7')
			jq -cn --arg head "$HEAD_SHA" --arg scenario "$POLICY_CASE" '{state: "open", closed_at: null, merged: false, draft: false, author_association: "OWNER",
				head: {sha: $head, repo: {full_name: "owner/app"}}, base: {ref: "main", repo: {full_name: "owner/app"}},
				auto_merge: null, labels: [{name: "release-approval-required"}, {name: "hold-for-review"}]}
				| if $scenario == "auto_merge" then .auto_merge = {merge_method: "squash"}
				  elif $scenario == "maintainer_brake" then .labels += [{name: "needs-maintainer-review"}]
				  elif $scenario == "no_release_hold" then .labels = [{name: "hold-for-review"}]
				  else . end'
			;;
		'pr view') jq -cn --arg head "$HEAD_SHA" '{closingIssuesReferences: [{number: 30}], headRefOid: $head}' ;;
		'api repos/owner/app/issues/30')
			if [[ "${POLICY_MODE:-semver}" == commits ]]; then
				jq -cn --arg sha "$NEW_UPSTREAM" --arg scenario "$POLICY_CASE" '{state:"open",author_association:"OWNER",
				 body:("Finding\n<!-- aidevops:cloudron-package-monitor upstream-commit-" + $sha + " -->\nUpstream `" + (if $scenario == "commit_wrong_repo" then "other/project" else "upstream/project" end) + "` branch `main` head is `" + $sha + "` (date): update")}'
			else
				jq -cn --arg scenario "$POLICY_CASE" '{state: (if $scenario == "finding_closed" then "closed" else "open" end), author_association: "OWNER",
				body: "Finding\n<!-- aidevops:cloudron-package-monitor upstream-v3.39.114 -->\n"}'
			fi
			;;
		'api repos/upstream/project/commits/1234567')
			[[ "$POLICY_CASE" != commit_api_error ]] || return 1
			printf '%s\n' "$OLD_UPSTREAM"
			;;
		'api repos/upstream/project/commits/abcdef1')
			if [[ "$POLICY_CASE" == commit_resolved_mismatch ]]; then printf '%s\n' "$OLD_UPSTREAM"; else printf '%s\n' "$NEW_UPSTREAM"; fi
			;;
		"api repos/upstream/project/compare/${OLD_UPSTREAM}...${NEW_UPSTREAM}")
			jq -cn --arg base "$OLD_UPSTREAM" --arg scenario "$POLICY_CASE" '{status:(if $scenario == "commit_diverged" then "diverged" else "ahead" end), merge_base_commit:{sha:$base}}'
			;;
		"api repos/owner/app/compare/${MAIN_SHA}...${HEAD_SHA}")
			jq -cn --arg base "$BASE_SHA" --arg scenario "$POLICY_CASE" '{merge_base_commit: {sha: $base},
				files: ([{filename: "CHANGELOG", status: "modified", additions: 3, deletions: 0},
				         {filename: "CloudronManifest.json", status: "modified", additions: 2, deletions: 2},
				         {filename: "Dockerfile", status: "modified", additions: 2, deletions: 2},
				         {filename: "test/package-test.sh", status: "modified", additions: 6, deletions: 4}]
				        + if $scenario == "extra_file" then [{filename: "start.sh", status: "modified", additions: 1, deletions: 0}] else [] end)}'
			;;
		'api repos/owner/app/contents/'*) policy_contents_stub "${target#repos/owner/app/contents/}" || return 1 ;;
		'api repos/owner/app/labels?per_page=100') printf 'bug\n' ;;
		'label create') return 0 ;;
		*)
			printf 'Unexpected gh call: %s\n' "$*" >&2
			return 9
			;;
		esac
		return 0
	}
	release_checks() {
		[[ "$POLICY_CASE" != pending ]] || return 1
		printf '[]\n'
		return 0
	}
	release_verify() {
		local repo="$1" issue="$2"
		printf 'verify %s\n' "$issue" >>"${TEST_ROOT}/calls"
		case "$POLICY_CASE" in
		stale) printf 'STALE_APPROVAL\n'; return 2 ;;
		api_error) printf 'API_ERROR\n'; return 6 ;;
		unsigned | create | unfinished) printf 'NO_APPROVAL\n'; return 1 ;;
		revoked)
			# Signed at the start of the proof, revoked before its end.
			if [[ "$(grep -c '^verify ' "${TEST_ROOT}/calls")" -gt 1 ]]; then printf 'NO_APPROVAL\n'; return 1; fi
			;;
		esac
		printf 'VERIFIED\n'
		return 0
	}
	assert_policy() {
		local case_name="$1" expected_rc="$2" head="${3:-$HEAD_SHA}" output="" rc=0
		export POLICY_CASE="$case_name"
		: >"${TEST_ROOT}/calls"
		output=$(release_policy_authorizes owner/app 7 "$head" 2>"${TEST_ROOT}/policy-err") || rc=$?
		[[ "$rc" -eq "$expected_rc" ]] || { printf 'FAIL policy %s rc=%s\n' "$case_name" "$rc"; cat "${TEST_ROOT}/policy-err"; return 1; }
		[[ "$expected_rc" -ne 0 || "$output" == 50 ]] || return 1
		# Authorization is read-only: no label, comment, close or edit writes.
		if grep -Eq '^gh (issue|pr) (close|edit|comment|merge)|^gh label' "${TEST_ROOT}/calls"; then return 1; fi
		printf 'PASS policy authorization %s rc=%s\n' "$case_name" "$rc"
		return 0
	}
	assert_policy verified 0
	# The compare base is the resolved main SHA, never the bare branch name.
	grep -q "^gh api repos/owner/app/compare/${MAIN_SHA}\.\.\.${HEAD_SHA}\$" "${TEST_ROOT}/calls"
	assert_policy docker_tamper 1
	grep -q 'pinned file changes beyond version substitution' "${TEST_ROOT}/policy-err"
	assert_policy check_tamper 1
	grep -q 'check file changes beyond version substitution' "${TEST_ROOT}/policy-err"
	assert_policy swapped 1
	assert_policy revoked 1
	assert_policy finding_closed 1
	assert_policy auto_merge 1
	assert_policy maintainer_brake 1
	assert_policy no_release_hold 1
	assert_policy extra_file 1
	assert_policy pending 1
	assert_policy unsigned 1
	assert_policy stale 1
	assert_policy api_error 1
	assert_policy multiple 1
	assert_policy outsider 1
	assert_policy other_repo 1
	assert_policy none 1
	assert_policy verified 1 "$OTHER_SHA"

	(
		POLICY_MODE=commits
		POLICY_UPSTREAM=upstream/project
		BASE_MANIFEST="${BASE_MANIFEST//3.39.87/1234567}"
		HEAD_MANIFEST="${HEAD_MANIFEST//3.39.114/abcdef1}"
		BASE_DOCKERFILE="${BASE_DOCKERFILE//3.39.87/1234567}"
		HEAD_DOCKERFILE="${HEAD_DOCKERFILE//3.39.114/abcdef1}"
		BASE_CHECK="${BASE_CHECK//3.39.87/1234567}"
		HEAD_CHECK="${HEAD_CHECK//3.39.114/abcdef1}"
		assert_policy commit_ahead 0
		grep -Fq "gh api repos/upstream/project/compare/${OLD_UPSTREAM}...${NEW_UPSTREAM}" "${TEST_ROOT}/calls"
		assert_policy commit_diverged 1
		assert_policy commit_wrong_repo 1
		assert_policy commit_resolved_mismatch 1
		assert_policy commit_api_error 1
	)

	gh_create_issue() {
		local body=""
		body=$(</dev/stdin)
		printf '%s\n' "$body" >"${TEST_ROOT}/policy-body"
		printf 'create %s\n' "$*" >>"${TEST_ROOT}/calls"
		printf 'https://example.invalid/issue/50\n'
		return 0
	}
	gh_issue_edit_safe() {
		local body=""
		body=$(</dev/stdin)
		[[ "$*" == '50 --repo owner/app --body-file -' ]] || return 9
		printf '%s\n' "$body" >"${TEST_ROOT}/policy-body"
		printf 'issue-edit %s\n' "$*" >>"${TEST_ROOT}/calls"
		return 0
	}
	release_authority() {
		return 0
	}
	expected_policy_output=$'https://example.invalid/issue/50\nAPPROVAL_COMMAND=sudo aidevops approve issue 50 owner/app'
	export POLICY_CASE=create
	: >"${TEST_ROOT}/calls"
	[[ "$(release_policy_request owner/app)" == "$expected_policy_output" ]]
	grep -q -- '--label release-standing-policy --label persistent --label no-auto-dispatch' "${TEST_ROOT}/calls"
	grep -q '^gh label create release-standing-policy --repo owner/app ' "${TEST_ROOT}/calls"
	grep -q '^gh label create persistent --repo owner/app ' "${TEST_ROOT}/calls"
	[[ "$(release_policy_metadata "$(<"${TEST_ROOT}/policy-body")" owner/app)" == "$POLICY_JSON" ]]
	# shellcheck disable=SC2016 # Markdown command backticks are literal.
	grep -q 'Maintainer command: `sudo aidevops approve issue 50 owner/app`' "${TEST_ROOT}/policy-body"
	grep -qx -- '<!-- aidevops:cloudron-release-policy v1 -->' "${TEST_ROOT}/policy-body"
	printf 'PASS policy request creates a finalized, parseable approval-only policy issue\n'
	export POLICY_CASE=verified
	: >"${TEST_ROOT}/calls"
	[[ "$(release_policy_request owner/app)" == "$expected_policy_output" ]]
	if grep -Eq '^(create |issue-edit )|^verify ' "${TEST_ROOT}/calls"; then exit 1; fi
	printf 'PASS repeated policy request is read-only\n'
	export POLICY_CASE=unfinished
	: >"${TEST_ROOT}/calls"
	[[ "$(release_policy_request owner/app)" == "$expected_policy_output" ]]
	grep -q '^issue-edit 50 ' "${TEST_ROOT}/calls"
	printf 'PASS interrupted unsigned policy request is finalized\n'
	export POLICY_CASE=create
	: >"${TEST_ROOT}/calls"
	[[ "$(release_policy_request owner/app commits upstream/project)" == "$expected_policy_output" ]]
	release_policy_metadata "$(<"${TEST_ROOT}/policy-body")" owner/app |
		jq -e '.upstream_mode == "commits" and .upstream_repository == "upstream/project"' >/dev/null
	grep -q 'commits have no major boundary' "${TEST_ROOT}/policy-body"
	grep -q 'Maintainer command:' "${TEST_ROOT}/policy-body"
	printf 'PASS commit policy creation records the signed upstream, ancestry rule and signing command\n'
	# Migration may finalize an unsigned policy, but must never edit a signed,
	# stale or unverifiable legacy semver policy to expand its authorization.
	for POLICY_CASE in verified stale api_error; do
		export POLICY_CASE
		: >"${TEST_ROOT}/calls"
		if release_policy_request owner/app commits upstream/project 2>/dev/null; then exit 1; fi
		if grep -q '^issue-edit ' "${TEST_ROOT}/calls"; then exit 1; fi
	done
	export POLICY_CASE=unsigned
	: >"${TEST_ROOT}/calls"
	[[ "$(release_policy_request owner/app commits upstream/project)" == "$expected_policy_output" ]]
	grep -q '^issue-edit 50 ' "${TEST_ROOT}/calls"
	release_policy_metadata "$(<"${TEST_ROOT}/policy-body")" owner/app |
		jq -e '.upstream_mode == "commits" and .upstream_repository == "upstream/project"' >/dev/null
	printf 'PASS only an unsigned legacy policy can be finalized as a new commit policy for signing\n'
	: >"${TEST_ROOT}/calls"
	if release_policy_request owner/app commits '../unsafe' 2>/dev/null; then exit 1; fi
	if grep -Eq '^(create |issue-edit )' "${TEST_ROOT}/calls"; then exit 1; fi
	gh() {
		printf 'gh %s\n' "$*" >>"${TEST_ROOT}/calls"
		# A non-canonical body that still carries the maintainer command.
		jq -cn --argjson a "$(policy_issue_json 50 OWNER)" '[$a | .body |= sub("Dockerfile"; "start.sh")]'
		return 0
	}
	for POLICY_CASE in verified stale api_error; do
		export POLICY_CASE
		: >"${TEST_ROOT}/calls"
		if release_policy_request owner/app 2>/dev/null; then exit 1; fi
		if grep -q '^issue-edit ' "${TEST_ROOT}/calls"; then exit 1; fi
	done
	printf 'PASS a non-canonical signed, stale or unverifiable policy body is never rewritten or offered for signing\n'
)
