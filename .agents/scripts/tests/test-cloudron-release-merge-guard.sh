#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#37955: every merge transport must require release authority for an
# unlabelled Cloudron manifest version bump.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${TEST_DIR}/.."
# shellcheck source=../cloudron-release-approval-helper.sh
source "${SOURCE_DIR}/cloudron-release-approval-helper.sh"
# shellcheck source=../cloudron-release-merge-guard-lib.sh
source "${SOURCE_DIR}/cloudron-release-merge-guard-lib.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CALLS="${TEST_ROOT}/calls"
SCENARIO=""
AUTHORIZED=false

gh() {
	printf '%s\n' "$*" >>"$CALLS"
	case "$*" in
	'api repos/owner/app/pulls/7')
		local head="$HEAD_SHA"
		[[ "$SCENARIO" != head_moved ]] || head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
		jq -cn --arg head "$head" --arg scenario "$SCENARIO" '{head:{sha:$head,repo:{full_name:"owner/app"}},base:{ref:"main",repo:{full_name:"owner/app"}},draft:false}
			| if $scenario == "fork" then .head.repo.full_name = "other/app" else . end'
		;;
	'api repos/owner/app/pulls/7/files?per_page=100 --paginate')
		[[ "$SCENARIO" != files_error ]] || return 1
		if [[ "$SCENARIO" == no_manifest ]]; then
			printf '[{"filename":"README.md"}]\n'
		else
			printf '[{"filename":"Dockerfile"}][{"filename":"CloudronManifest.json"}]\n'
		fi
		;;
	"api repos/owner/app/contents/CloudronManifest.json?ref=${HEAD_SHA} --jq .content | @base64d")
		if [[ "$SCENARIO" == same_version ]]; then
			printf '{"version":"1.2.2","memoryLimit":1}\n'
		else
			printf '{"version":"1.2.3"}\n'
		fi
		;;
	'api repos/owner/app/contents/CloudronManifest.json?ref=main --jq .content | @base64d')
		printf '{"version":"1.2.2"}\n'
		;;
	*)
		printf 'Unexpected gh call: %s\n' "$*" >&2
		return 9
		;;
	esac
	return 0
}

release_authorize() {
	printf 'authorize %s\n' "$*" >>"$CALLS"
	[[ "$AUTHORIZED" == true ]] || return 1
	return 0
}

release_ensure_labels() {
	printf 'ensure-labels %s\n' "$*" >>"$CALLS"
	return 0
}

gh_pr_edit_safe() {
	printf 'pr-edit %s\n' "$*" >>"$CALLS"
	return 0
}

run_guard() {
	local scenario="$1" authorized="$2" expected_rc="$3" expect_hold="$4" dry_run="${5:-0}"
	local rc=0 held=false calls=""
	SCENARIO="$scenario"
	AUTHORIZED="$authorized"
	: >"$CALLS"
	DRY_RUN="$dry_run" release_merge_guard owner/app 7 "$HEAD_SHA" 2>/dev/null || rc=$?
	calls=$(<"$CALLS")
	[[ "$calls" != *'pr-edit 7 --repo owner/app --add-label release-approval-required --add-label hold-for-review'* ]] || held=true
	if [[ "$rc" -ne "$expected_rc" || "$held" != "$expect_hold" ]]; then
		printf 'FAIL %s authorized=%s rc=%s held=%s\n' "$scenario" "$authorized" "$rc" "$held"
		return 1
	fi
	printf 'PASS %s authorized=%s dry_run=%s\n' "$scenario" "$authorized" "$dry_run"
	return 0
}

run_guard no_manifest false 0 false
if grep -q '^authorize' "$CALLS"; then exit 1; fi
run_guard same_version false 0 false
run_guard bump true 0 false
run_guard bump false 1 true
run_guard bump false 1 false 1
run_guard head_moved true 1 false
run_guard files_error true 1 false
run_guard fork true 1 false
if grep -q '^authorize' "$CALLS"; then exit 1; fi
printf 'PASS indeterminate evidence never reaches authorization\n'

# Library routing: unregistered repos make no helper/API calls; an unreadable
# registry fails closed.
printf '%s\n' '{"initialized_repos":[{"slug":"owner/other","app_type":"cloudron-package"}]}' >"${TEST_ROOT}/repos.json"
AIDEVOPS_REPOS_FILE="${TEST_ROOT}/repos.json" cloudron_release_merge_guard owner/app 7 "$HEAD_SHA" ',bug,'
printf '%s\n' '{"initialized_repos":[{"slug":"owner/app","app_type":"cloudron-package","maintenance":false}]}' >"${TEST_ROOT}/repos.json"
AIDEVOPS_REPOS_FILE="${TEST_ROOT}/repos.json" cloudron_release_merge_guard owner/app 7 "$HEAD_SHA" ''
AIDEVOPS_REPOS_FILE="${TEST_ROOT}/missing.json" cloudron_release_merge_guard owner/app 7 "$HEAD_SHA" ''
printf 'PASS unregistered or unmaintained repos skip the gate\n'
printf 'not json\n' >"${TEST_ROOT}/repos.json"
if AIDEVOPS_REPOS_FILE="${TEST_ROOT}/repos.json" cloudron_release_merge_guard owner/app 7 "$HEAD_SHA" '' 2>/dev/null; then
	printf 'FAIL unreadable registry allowed merge\n'
	exit 1
fi
printf 'PASS unreadable registry fails closed\n'
