#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36899: exercise head-scoped retry recovery without GitHub writes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
grep -v '^main "\$@"' "${SCRIPT_DIR}/../review-bot-gate-helper.sh" >"${TEST_ROOT}/helper.sh"
_RBG_SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${TEST_ROOT}/helper.sh"

HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OLD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REVIEWS='[]'
COMMENTS='[]'
REVIEW_COMMENTS='[]'
QUERY_FAILURE=""
POSTED="${TEST_ROOT}/posted"
REPO="testorg/testrepo"
REQUESTED="REQUESTED"
ALREADY="ALREADY_REQUESTED"
LEGACY_MARKER='<!-- review-bot-retry-requested -->'
REVIEW_BODY='Reviewed changes; no blocking findings.'

gh() {
	local service="$1"
	local action="${2:-}"
	shift 2
	case "${service}/${action}" in
	pr/view)
		printf '%s\n' "$HEAD_SHA"
		;;
	pr/list)
		local query="" arg=""
		while [[ $# -gt 0 ]]; do
			arg="$1"
			if [[ "$arg" == "--jq" ]]; then
				query="$2"
				break
			fi
			shift
		done
		# A PR with historical reviews must still reach request-retry.
		printf '%s\n' '[{"number":7,"reviews":[{}]}]' | jq -r "$query"
		;;
	*) return 1 ;;
	esac
	return 0
}

_rbg_query_evidence_collection() {
	local pr_number="$1"
	local repo="$2"
	local collection="$3"
	local query="$4"
	[[ "$pr_number" == 7 && "$repo" == "$REPO" ]] || return 1
	[[ "$collection" != "$QUERY_FAILURE" ]] || return 1
	local data
	case "$collection" in
	reviews) data="$REVIEWS" ;;
	issue-comments) data="$COMMENTS" ;;
	review-comments) data="$REVIEW_COMMENTS" ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$data" | jq -r "$query" || return 1
	return 0
}

gh_pr_comment() {
	printf '%s\n' "$*" >>"$POSTED"
	return 0
}

_get_min_edit_lag() {
	printf '0\n'
	return 0
}

_requires_success_status_completion() {
	return 1
}

set_review() {
	local commit="$1"
	REVIEWS=$(jq -nc --arg commit "$commit" --arg body "$REVIEW_BODY" \
		'[{user:{login:"coderabbitai[bot]"},commit_id:$commit,body:$body,submitted_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:02:00Z"}]')
	return 0
}

set_comment() {
	local body="$1"
	COMMENTS=$(jq -nc --arg body "$body" '[{user:{login:"coderabbitai[bot]"},body:$body}]')
	return 0
}

assert_retry() {
	local name="$1"
	local expected="$2"
	local expected_posts="$3"
	local expected_rc="${4:-0}"
	local output rc=0 posts=0
	rm -f "$POSTED"
	output=$(do_request_retry 7 "$REPO") || rc=$?
	[[ ! -f "$POSTED" ]] || posts=1
	if [[ "$output" != "$expected" || "$posts" != "$expected_posts" || "$rc" != "$expected_rc" ]]; then
		printf 'FAIL %s: output=%s posts=%s rc=%s\n' "$name" "$output" "$posts" "$rc" >&2
		return 1
	fi
	if [[ "$posts" == 1 ]]; then
		grep -qF "<!-- review-bot-retry-requested head=${HEAD_SHA} -->" "$POSTED" || return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

set_comment 'Review skipped due to rate limit exceeded'
assert_retry 'no reviews allows retry' "$REQUESTED" 1
set_review "$OLD_SHA"
assert_retry 'superseded formal review allows retry' "$REQUESTED" 1
set_review "$HEAD_SHA"
assert_retry 'current formal review suppresses retry' HAS_REVIEWS 0
REVIEWS='[]'$'\n'"$REVIEWS"$'\n'"$REVIEWS"
assert_retry 'paginated formal reviews suppress retry' HAS_REVIEWS 0
set_review "$OLD_SHA"
REVIEW_COMMENTS="$REVIEWS"
REVIEWS='[]'
assert_retry 'superseded inline reviews allow retry' "$REQUESTED" 1
set_review "$HEAD_SHA"
REVIEW_COMMENTS="$REVIEWS"
REVIEWS='[]'
assert_retry 'settled current inline review prevents redundant retry' NO_ACTION 0
REVIEW_COMMENTS='[]'
set_comment "<!-- review-bot-retry-requested head=${HEAD_SHA} -->"
assert_retry 'same head marker suppresses duplicate' "$ALREADY" 0
set_comment "<!-- review-bot-retry-requested head=${OLD_SHA} -->"
assert_retry 'prior head marker permits retry' "$REQUESTED" 1
set_comment "$LEGACY_MARKER"
assert_retry 'legacy PR-wide marker permits retry' "$REQUESTED" 1
# The comment endpoint has no commit identity, so old conversation review text
# cannot prove that the current head has been reviewed.
set_comment "$REVIEW_BODY"
assert_retry 'unscoped conversation review cannot suppress retry' "$REQUESTED" 1
COMMENTS='[]'
assert_retry 'no bot activity means no action' NO_ACTION 0
set_comment "$LEGACY_MARKER"
HEAD_SHA='null'
assert_retry 'missing head fails closed' '' 0 2
HEAD_SHA="$OLD_SHA"
QUERY_FAILURE=reviews
assert_retry 'unavailable reviews fail closed' '' 0 2
QUERY_FAILURE=issue-comments
assert_retry 'unavailable markers fail closed' '' 0 2
QUERY_FAILURE=''
set_review aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
rm -f "$POSTED"
batch_output=$(BATCH_RETRY_STAGGER=0 do_batch_retry "$REPO")
[[ "$batch_output" == REQUESTED_1 && -s "$POSTED" ]]
printf 'PASS batch includes PRs with superseded reviews\n'
printf 'All 15 request-retry regressions passed\n'
