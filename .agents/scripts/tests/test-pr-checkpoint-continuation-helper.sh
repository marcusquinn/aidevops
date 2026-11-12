#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)/pr-checkpoint-continuation-helper.sh"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_PR_CHECKPOINT_CONTINUATION_STATE_DIR="${TEST_ROOT}/state"
mkdir -p "${HOME}" "${TEST_ROOT}/bin" "${TEST_ROOT}/repo" "$AIDEVOPS_PR_CHECKPOINT_CONTINUATION_STATE_DIR"

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s%s\n' "$name" "${detail:+ — $detail}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
	[[ "${STUB_METADATA_FAILURE:-}" != pr || "${7:-}" == author ]] || exit 1
	printf '%s\n' "${STUB_PR_JSON:-}"
	exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/123" ]]; then
	[[ "${STUB_METADATA_FAILURE:-}" != issue ]] || exit 1
	if [[ "${3:-}" == "--jq" ]]; then
		printf '%s\n' "${STUB_ISSUE_JSON:-}" | jq -r "$4"
		exit $?
	fi
	printf '%s\n' "${STUB_ISSUE_JSON:-}"
	exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/123/comments?per_page=100" ]]; then
	[[ "${STUB_METADATA_FAILURE:-}" != comments ]] || exit 1
	if [[ -n "${STUB_CLAIM_FILE:-}" ]]; then
		own='[]'
		if [[ -r "${STUB_CLAIM_FILE}.base" && "$(<"${STUB_CLAIM_FILE}.base")" == "${STUB_COMMENTS_JSON:-[]}" ]]; then
			own="$(<"$STUB_CLAIM_FILE")"
		fi
		jq -nc --argjson base "${STUB_COMMENTS_JSON:-[]}" --argjson own "$own" '
			[($base | flatten) + $own | map(.node_id //= ("fixture-" + (.id | tostring)))]'
		exit $?
	fi
	printf '%s\n' "${STUB_COMMENTS_JSON:-[]}"
	exit 0
fi
if [[ -n "${STUB_CLAIM_FILE:-}" ]]; then
	if [[ "$1 $2" == "api user" ]]; then
		printf '%s\n' "$STUB_AUTH_LOGIN"
		exit 0
	fi
	if [[ "$1 $2" == "api graphql" ]]; then
		for arg in "$@"; do
			[[ "$arg" != ids\[\]=* ]] || printf '%s\n' "${arg#ids\[\]=}"
		done | jq -Rsc '{data:{nodes:(split("\n") | map(select(length > 0) | {id:.,lastEditedAt:null}))}}'
		exit 0
	fi
	if [[ "$1" == api && "$2" == repos/owner/repo/collaborators/*/permission ]]; then
		printf 'write\n'
		exit 0
	fi
	if [[ "$1 $2 $3 $4" == "api repos/owner/repo/issues/123/comments --method POST" &&
		( "$6" == body=DISPATCH_* || "$6" == *$'\n'DISPATCH_* ) ]]; then
		if [[ ! -r "${STUB_CLAIM_FILE}.base" || "$(<"${STUB_CLAIM_FILE}.base")" != "${STUB_COMMENTS_JSON:-[]}" ]]; then
			printf '[]' >"$STUB_CLAIM_FILE"
			printf '%s' "${STUB_COMMENTS_JSON:-[]}" >"${STUB_CLAIM_FILE}.base"
		fi
		jq --arg body "${6#body=}" --arg actor "$STUB_AUTH_LOGIN" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
			((map(.id) + [1000000]) | max + 1) as $id |
			. + [{id:$id,node_id:("fixture-" + ($id | tostring)),body:$body,user:{login:$actor},
			author_association:"MEMBER",created_at:$now}]' "$STUB_CLAIM_FILE" >"${STUB_CLAIM_FILE}.next"
		mv "${STUB_CLAIM_FILE}.next" "$STUB_CLAIM_FILE"
		jq -r 'last.id' "$STUB_CLAIM_FILE"
		exit 0
	fi
fi
if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/123/comments" && "$3" == "--method" && "$4" == "POST" ]]; then
	[[ -n "${STUB_POST_DIR:-}" ]] || exit 1
	post_count=$(find "$STUB_POST_DIR" -type f | wc -l | tr -d ' ')
	printf '%s' "${6#body=}" >"${STUB_POST_DIR}/post-$((post_count + 1))"
	exit 0
fi
exit 1
GH_STUB
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:${PATH}"

# shellcheck source=../pr-checkpoint-continuation-helper.sh
source "$HELPER"
# Fixture comments carry fixed historical dates, so keep the attention re-arm
# window closed except in the tests that exercise it.
ATTENTION_REARM_CLOSED=3153600000
_PCC_ATTENTION_REARM_SECONDS="$ATTENTION_REARM_CLOSED"

valid_pr_json() {
	local body="${1:-Resolves #123}"
	local labels="${2:-}"
	local closing_refs="${3:-}"
	local author="${4:-worker-bot}"
	[[ -n "$labels" ]] || labels='[{"name":"origin:worker"}]'
	[[ -n "$closing_refs" ]] || closing_refs='[{"number":123,"repository":{"name":"repo","owner":{"login":"owner"}}}]'
	printf '{"number":42,"state":"OPEN","title":"Continue existing work","body":"%s","closingIssuesReferences":%s,"isDraft":true,"isCrossRepository":false,"labels":%s,"headRefName":"worker/issue-123","headRefOid":"1111111111111111111111111111111111111111","author":{"login":"%s"}}\n' \
		"$body" "$closing_refs" "$labels" "$author"
	return 0
}

valid_issue_json() {
	local labels="${1:-}"
	local assignee="${2:-worker-bot}"
	[[ -n "$labels" ]] || labels='[{"name":"status:in-review"}]'
	printf '{"number":123,"body":"Preserve checkpoint scope","state":"open","labels":%s,"assignees":[{"login":"%s"}]}\n' "$labels" "$assignee"
	return 0
}

valid_checkpoint_comments() {
	local runner="worker-bot"
	printf '[[{"id":10,"created_at":"2026-08-04T22:29:37Z","author_association":"COLLABORATOR","body":"CLAIM_RELEASED reason=worker_draft_checkpoint runner=%s ts=2026-08-04T22:29:36Z"}]]\n' "$runner"
	return 0
}

STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'
export STUB_PR_JSON STUB_ISSUE_JSON STUB_COMMENTS_JSON

# Test groups live in sibling modules sourced in order (shared fixtures/state).
# shellcheck source=test-pr-checkpoint-continuation-dispatch.sh
source "${TEST_SCRIPT_DIR}/test-pr-checkpoint-continuation-dispatch.sh"
# shellcheck source=test-pr-checkpoint-continuation-selfhold.sh
source "${TEST_SCRIPT_DIR}/test-pr-checkpoint-continuation-selfhold.sh"
# shellcheck source=test-pr-checkpoint-continuation-attention.sh
source "${TEST_SCRIPT_DIR}/test-pr-checkpoint-continuation-attention.sh"
# shellcheck source=test-pr-checkpoint-continuation-fuse.sh
source "${TEST_SCRIPT_DIR}/test-pr-checkpoint-continuation-fuse.sh"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
