#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36174: exercise real merge gates with synthetic PR metadata, no network.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared-gh-wrappers-safe-edit.sh
source "${SCRIPT_DIR}/../shared-gh-wrappers-safe-edit.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="${TEST_ROOT}/pulse.log"
FIXTURE="" ROUTES=0 REVIEWS=0 READ_FAIL=0 LAST_ERROR=""

# Match the existing merge-pass harness: load only the function under test.
eval "$(awk '/^_check_pr_merge_gates\(\)/ { capture=1 } capture { print } capture && /^}/ { exit }' "${SCRIPT_DIR}/../pulse-merge.sh")"
eval "$(awk '/^_merge_check_closure_metadata\(\)/ { capture=1 } capture { print } capture && /^}/ { exit }' "${SCRIPT_DIR}/../full-loop-helper-merge.sh")"
eval "$(awk '/^cmd_merge\(\)/ { capture=1 } capture { print } capture && /^}/ { exit }' "${SCRIPT_DIR}/../full-loop-helper-merge.sh")"

gh_pr_view() {
	local read_command="${1:-}"
	# Raw gh reads do not use the gh_pr_view wrapper cache.
	if [[ "$read_command" != gh && "$*" == *"body,closingIssuesReferences"* ]]; then
		[[ "${AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE:-0}" == 1 ]] || return 1
	fi
	[[ "$READ_FAIL" -eq 0 ]] || return 1
	printf '%s\n' "$FIXTURE"
	return 0
}
_interactive_claim_fence_blocks_merge() { return 1; }
_pm_gate_review_mode() { return 0; }
_pm_gate_author_trust() { return 0; }
_pm_gate_repository_and_issue() { return 0; }
_pm_gate_origin_authority() { return 0; }
_pm_gate_review_bot() { REVIEWS=$((REVIEWS + 1)); return 0; }
_route_pr_to_fix_worker() { ROUTES=$((ROUTES + 1)); return 0; }
# First exercise failed safe writes falling back to the existing repair route.
gh_pr_edit_safe() { return 1; }
print_error() { local message="$1"; LAST_ERROR="$message"; return 0; }
_merge_parse_command_args() {
	FULL_LOOP_MERGE_PARSED_REPO="test/repo"
	FULL_LOOP_MERGE_PARSED_METHOD="squash"
	FULL_LOOP_MERGE_PARSED_ADMIN=0
	FULL_LOOP_MERGE_PARSED_AUTO=0
	FULL_LOOP_MERGE_PARSED_BODY_FILE=""
	return 0
}
_merge_resolve_repo() { printf '%s' 'test/repo'; return 0; }
_merge_handle_already_merged_provenance() { return 2; }
_flm_gh_read() { gh_pr_view "$@"; return $?; }
_merge_pre_merge_gate_with_admission_retry() { REVIEWS=$((REVIEWS + 1)); return 1; }
_merge_report_pre_merge_gate_failure() { return 0; }

check_case() {
	local description="$1" body="$2" refs="$3" expected="$4"
	local result=0 before_routes="$ROUTES" before_reviews="$REVIEWS"
	FIXTURE=$(jq -cn --arg body "$body" --argjson refs "$refs" '{body:$body, closingIssuesReferences:$refs}')
	_check_pr_merge_gates 456 test/repo author APPROVED 123 origin:worker head || result=$?
	[[ "$result" -eq "$expected" ]] || { printf 'FAIL %s (rc=%s)\n' "$description" "$result"; return 1; }
	if [[ "$expected" -eq 1 ]]; then
		[[ "$ROUTES" -eq $((before_routes + 1)) && "$REVIEWS" -eq "$before_reviews" ]] || return 1
		# Interactive merge must stop before review gates or merge writes too.
		cmd_merge 456 test/repo && return 1
		[[ "$REVIEWS" -eq "$before_reviews" ]] || return 1
	else
		# The unrelated review gate deliberately stops cmd_merge; reaching it
		# proves valid leaf closure is not held by the new interactive guard.
		cmd_merge 456 test/repo && return 1
		[[ "$REVIEWS" -eq $((before_reviews + 2)) && "$ROUTES" -eq "$before_routes" ]] || return 1
	fi
	printf 'PASS %s\n' "$description"
	return 0
}

LOCAL_REFS='[{"number":123,"repository":{"owner":{"login":"test"},"name":"repo"}}]'
check_case 'partial-delivery negation held and routed' 'For #123. Merge records retry evidence only and must not close #123' "$LOCAL_REFS" 1
check_case 'For/native contradiction held' $'For #123\nResolves #123' "$LOCAL_REFS" 1
check_case 'For colon/native contradiction held' $'For: #123\nResolves #123' "$LOCAL_REFS" 1
check_case 'Ref colon/native contradiction held' $'Ref: #123\nResolves #123' "$LOCAL_REFS" 1
check_case 'inline code between negation and keyword routed without looping' "Do not \`x\` close #123" "$LOCAL_REFS" 1
check_case 'case-insensitive Ref/native contradiction held' 'rEf #123' "$LOCAL_REFS" 1
check_case 'qualified same-repo contradiction held' 'For test/repo#123' "$LOCAL_REFS" 1
check_case 'legitimate leaf closure allowed' 'Resolves #123' "$LOCAL_REFS" 0
check_case 'different For issue allowed' $'For #124\nResolves #123' "$LOCAL_REFS" 0
check_case 'same number in other repo allowed' 'For other/repo#123' "$LOCAL_REFS" 0
check_case 'native cross-repo identity preserved' 'For #123' '[{"number":123,"repository":{"nameWithOwner":"other/repo"}}]' 0
check_case 'gh CLI cross-repo identity preserved' 'For #123' '[{"number":123,"repository":{"owner":{"login":"other"},"name":"repo"}}]' 0
check_case 'fenced negation and references ignored' $'~~~\nFor #123\nDo not close #123\n~~~\nResolves #123' "$LOCAL_REFS" 0
check_case 'inline code ignored' "Example \`For #123 must not close #123\`. Resolves #123" "$LOCAL_REFS" 0
check_case 'non-closing partial work allowed' 'For #123. The issue remains open.' '[]' 0
check_case 'negation held even without native refs' 'Never resolve #123' '[]' 1

# Now exercise successful safe edits with real repair generation. No GitHub
# command is allowed: the wrapper records only the generated body-file bytes.
gh_pr_edit_safe() {
	local body_file="${5:-}"
	[[ "$*" == "456 --repo test/repo --body-file "* ]] || return 1
	cp "$body_file" "${TEST_ROOT}/repaired.md" || return 1
	return 0
}
FIXTURE=$(jq -cn --arg body $'For: #123\nMust not close #123.\nResolves #123\nResolves #124\n`Resolves #123`\n~~~\nResolves #123\n~~~' --argjson refs "$LOCAL_REFS" '{body:$body,closingIssuesReferences:$refs}')
before_routes="$ROUTES"
before_reviews="$REVIEWS"
if _check_pr_merge_gates 456 test/repo author APPROVED 123 origin:worker head; then
	printf 'FAIL repaired PR must remain held this pass\n'
	exit 1
fi
[[ "$ROUTES" -eq "$before_routes" && "$REVIEWS" -eq "$before_reviews" ]]
expected=$'For: #123\nMust leave the issue open.\nRef #123\nResolves #124\n`Resolves #123`\n~~~\nResolves #123\n~~~'
[[ "$(<"${TEST_ROOT}/repaired.md")" == "$expected" ]]
printf 'PASS safe repair preserves For, unrelated leaf closure, and code without comments or worker routing\n'

READ_FAIL=1
before_routes="$ROUTES"
if _check_pr_merge_gates 456 test/repo author APPROVED 123 origin:worker head; then
	printf 'FAIL unavailable metadata must hold\n'
	exit 1
fi
[[ "$ROUTES" -eq "$before_routes" ]]
printf 'PASS unavailable metadata held without destructive repair routing\n'
cmd_merge 456 test/repo && exit 1
[[ "$LAST_ERROR" == 'Merge blocked for PR #456: closing-reference metadata unavailable' ]]
printf 'PASS interactive metadata read failure reports its cause\n'
if _gh_pr_merge_closure_check '{}' test/repo >/dev/null; then
	printf 'FAIL malformed metadata must hold\n'
	exit 1
fi
printf 'PASS malformed metadata held\n'
