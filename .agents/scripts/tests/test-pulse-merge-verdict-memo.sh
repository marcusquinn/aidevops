#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#38774: negative-only scheduling hints and fail-open empty-repo batching.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d "${AIDEVOPS_TEMP_DIR:-${TMPDIR:-/tmp}}/merge-verdict-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home" LOGFILE="$TEST_ROOT/pulse.log"
export AIDEVOPS_MERGE_VERDICT_DIR="$TEST_ROOT/memos"
mkdir -p "$HOME"
gh() { return 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/pulse-merge.sh"
_pulse_merge_queue_begin_object() { return 0; }
_pulse_merge_queue_finish() { return 0; }
_pulse_merge_queue_priority_keys() { return 0; }
_pmp_now_epoch_into() {
	local destination="$1"
	printf -v "$destination" '%s' "$CLOCK"
	return 0
}
CLOCK=10000
evaluations=0
_pmp_evaluate_pr_with_deadline() {
	local repo="$1" object="$2"
	evaluations=$((evaluations + 1))
	if jq -e '.isDraft' <<<"$object" >/dev/null; then
		_process_single_ready_pr "$repo" "$object"
		return $?
	fi
	return 0
}
expect_skip() {
	local object="$1" result=0
	_pmp_evaluate_pr_with_memo owner/repo "$object" test_ || result=$?
	[[ "$result" -eq 1 ]]
	return 0
}
draft='{"number":42,"state":"OPEN","headRefOid":"abc","updatedAt":"2026-11-17T00:00:00Z","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":true,"labels":[{"name":"b"},{"name":"a"}],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
test_memo_skips=0
_PMP_PASS_MEMO_SKIPS=0
expect_skip "$draft"
[[ "$evaluations" -eq 1 ]]
expect_skip "$draft"
[[ "$evaluations" -eq 1 && "$test_memo_skips" -eq 1 && "$_PMP_PASS_MEMO_SKIPS" -eq 1 ]]
if _pmp_negative_verdict_hit owner/repo "$(jq -c '._pulseDeferredRetry=true' <<<"$draft")"; then exit 1; fi
_pmp_negative_verdict_hit owner/repo "$(jq -c '.labels |= reverse' <<<"$draft")"
for mutation in '.headRefOid="def"' '.updatedAt="later"' '.mergeStateStatus="BLOCKED"' \
	'.mergeable="UNKNOWN"' '.reviewDecision="CHANGES_REQUESTED"' \
	'.labels += [{"name":"new"}]' '.statusCheckRollup[0].conclusion="FAILURE"' '.isDraft=false'; do
	if _pmp_negative_verdict_hit owner/repo "$(jq -c "$mutation" <<<"$draft")"; then
		printf 'FAIL: key mutation did not invalidate memo: %s\n' "$mutation"
		exit 1
	fi
done
if _pmp_negative_verdict_hit other/repo "$draft"; then exit 1; fi
CLOCK=11799
expect_skip "$draft"
[[ "$evaluations" -eq 1 ]]
CLOCK=11800
expect_skip "$draft"
[[ "$evaluations" -eq 2 ]]
AIDEVOPS_MERGE_VERDICT_TTL_S=0 expect_skip "$draft"
[[ "$evaluations" -eq 3 ]]

# A green, non-draft PR must reach evaluation, even if a memo writer was
# mistakenly called with a passing outcome or an inapplicable negative verdict.
green=$(jq -c '.isDraft=false' <<<"$draft")
for verdict in pass eligible merged checks_pending terminal_failure conflict_cooldown remediation draft mergeable_unknown review_unknown; do
	_pmp_record_negative_verdict owner/repo "$green" "$verdict"
	before="$evaluations"
	_pmp_evaluate_pr_with_memo owner/repo "$green" test_
	[[ "$evaluations" -eq $((before + 1)) ]]
done
unknown=$(jq -c '.mergeable="UNKNOWN"' <<<"$green")
_pmp_record_negative_verdict owner/repo "$unknown" mergeable_unknown
_pmp_negative_verdict_hit owner/repo "$unknown"
unknown_review=$(jq -c '.reviewDecision="UNKNOWN"' <<<"$green")
_pmp_record_negative_verdict owner/repo "$unknown_review" review_unknown
_pmp_negative_verdict_hit owner/repo "$unknown_review"
memo_file=$(_pmp_verdict_file owner/repo "$unknown_review")
printf 'invalid json' >"$memo_file"
if _pmp_negative_verdict_hit owner/repo "$unknown_review"; then exit 1; fi

# Fail-open GraphQL prefilter: no real GitHub reads in this suite.
_pmp_apply_merge_api_deadline() { return 0; }
_gh_with_timeout() {
	printf 'call\n' >>"$TEST_ROOT/queries"
	case "$RESPONSE" in
	failure) return 1 ;;
	malformed) printf 'not-json' ;;
	errors) printf '%s' '{"errors":[{"message":"unavailable"}],"data":{"r0":{"pullRequests":{"totalCount":0}}}}' ;;
	partial) printf '%s' '{"data":{"r0":null,"r1":{"pullRequests":{"totalCount":0}}}}' ;;
	*) printf '%s' '{"data":{"r0":{"pullRequests":{"totalCount":0}},"r1":{"pullRequests":{"totalCount":2}}}}' ;;
	esac
	return 0
}
rows=$'owner/empty|unused\nowner/full|unused'
filtered_rows=""
RESPONSE=success
_PMP_PREFILTER_SKIPPED_REPOS=0
_pmp_filter_empty_merge_repos "$rows" filtered_rows
[[ "$filtered_rows" == $'owner/full|unused\n' && "$_PMP_PREFILTER_SKIPPED_REPOS" -eq 1 ]]
# Skipped repos advance the original walk's checkpoint, rather than making a
# saved empty-repo checkpoint look removed and restarting from the first repo.
cursor_cleared=0 enrichment_cleared=0
_pmp_clear_merge_pr_cursor() { cursor_cleared=1; return 0; }
_pmp_clear_merge_enrichment_state() { enrichment_cleared=1; return 0; }
_pmp_skip_prefiltered_repo owner/empty "$TEST_ROOT/checkpoint"
[[ "$(<"$TEST_ROOT/checkpoint")" == owner/empty ]]
[[ "$cursor_cleared" -eq 1 && "$enrichment_cleared" -eq 1 ]]
_pulse_merge_queue_priority_keys() { printf '|42|'; return 0; }
_pmp_filter_empty_merge_repos "$rows" filtered_rows
[[ "$filtered_rows" == "$rows"$'\n' ]]
_pulse_merge_queue_priority_keys() { return 0; }
for RESPONSE in failure malformed errors; do
	_PMP_PREFILTER_SKIPPED_REPOS=0
	_pmp_filter_empty_merge_repos "$rows" filtered_rows
	[[ "$filtered_rows" == "$rows"$'\n' && "$_PMP_PREFILTER_SKIPPED_REPOS" -eq 0 ]]
done
RESPONSE=partial
_pmp_filter_empty_merge_repos "$rows" filtered_rows
[[ "$filtered_rows" == $'owner/empty|unused\n' ]]
RESPONSE=success
: >"$TEST_ROOT/queries"
many_rows=""
for ((i=0; i<101; i++)); do many_rows="${many_rows}owner/repo${i}|unused"$'\n'; done
_pmp_empty_repo_prefilter "$many_rows" >/dev/null
[[ "$(wc -l <"$TEST_ROOT/queries")" -eq 3 ]]
printf 'PASS: verdict TTL, invalidation, negative-only safety, prefilter batching and fallback\n'
