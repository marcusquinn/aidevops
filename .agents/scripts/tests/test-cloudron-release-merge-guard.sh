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
		jq -cn --arg head "$head" --arg scenario "$SCENARIO" '{head:{sha:$head},base:{ref:"main"},auto_merge:null}
			| if $scenario == "stacked" then .base.ref = "feature/x"
			  elif $scenario == "auto" or $scenario == "files_error_auto" then .auto_merge = {merge_method:"squash"}
			  elif $scenario == "review_hold" then .labels = [{name:"hold-for-review"}]
			  else . end'
		;;
	'pr merge 7 --repo owner/app --disable-auto') ;;
	'api repos/owner/app/pulls/7/files?per_page=100 --paginate')
		[[ "$SCENARIO" != files_error && "$SCENARIO" != files_error_auto ]] || return 1
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
if grep -q '^authorize' "$CALLS"; then exit 1; fi
printf 'PASS indeterminate evidence never reaches authorization\n'
# A stacked base cannot publish; its later PR into main is gated instead.
run_guard stacked false 0 false
if grep -q 'files' "$CALLS"; then exit 1; fi
run_guard auto false 1 true
grep -q -- '--disable-auto' "$CALLS" || exit 1
run_guard bump false 1 true
if grep -q -- '--disable-auto' "$CALLS"; then exit 1; fi
printf 'PASS held bump cancels pending native auto-merge only\n'
run_guard files_error_auto true 1 false
grep -q -- '--disable-auto' "$CALLS" || exit 1
printf 'PASS unknown evidence still cancels pending native auto-merge\n'
# An independent review hold must not be adopted (and later cleared) by
# release processing, so the guard blocks without adding release labels.
run_guard review_hold false 1 false
if grep -q 'pr-edit' "$CALLS"; then exit 1; fi
printf 'PASS independent hold-for-review is preserved\n'
: >"$CALLS"
if CLOUDRON_RELEASE_GUARD_READ_ONLY=1 release_merge_guard owner/app 7 "$HEAD_SHA" 2>/dev/null; then exit 1; fi
if grep -q 'pr-edit' "$CALLS"; then exit 1; fi
printf 'PASS diagnostic read-only mode blocks without writing holds\n'

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

# A labelled release whose authorization fails also cancels native auto-merge.
mkdir -p "${TEST_ROOT}/fake"
cat >"${TEST_ROOT}/fake/cloudron-release-approval-helper.sh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CALLS}"
[[ "$1" == authorize && "${FAKE_AUTHORIZED:-false}" == true ]] && exit 0
[[ "$1" == cancel-auto-merge ]] && exit 0
exit 1
FAKE
chmod +x "${TEST_ROOT}/fake/cloudron-release-approval-helper.sh"
_CLOUDRON_RELEASE_MERGE_GUARD_DIR="${TEST_ROOT}/fake"
export FAKE_CALLS="${TEST_ROOT}/fake-calls"
: >"$FAKE_CALLS"
if FAKE_AUTHORIZED=false cloudron_release_merge_guard owner/app 7 "$HEAD_SHA" ',release-approval-required,'; then exit 1; fi
grep -qx 'cancel-auto-merge owner/app 7' "$FAKE_CALLS" || exit 1
: >"$FAKE_CALLS"
FAKE_AUTHORIZED=true cloudron_release_merge_guard owner/app 7 "$HEAD_SHA" ',release-approval-required,'
if grep -q 'cancel-auto-merge' "$FAKE_CALLS"; then exit 1; fi
printf 'PASS labelled authorization failure cancels native auto-merge\n'
