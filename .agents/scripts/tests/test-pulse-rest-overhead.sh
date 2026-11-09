#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}/.."
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_PULSE_REVIEW_CACHE_DIR="$TEST_ROOT/reviews"
export AIDEVOPS_GH_API_LOG="$TEST_ROOT/calls.tsv"
source "$SCRIPT_DIR/shared-gh-collaborator-permission.sh"
source "$SCRIPT_DIR/shared-gh-budget-policy.sh"
source "$SCRIPT_DIR/pulse-merge-rest-state.sh"
source "$SCRIPT_DIR/pulse-diagnose-api-budget.sh"
source "$SCRIPT_DIR/gh-api-instrument.sh"

permission_calls=0
# User reads execute in command substitutions, so count them in a file.
gh() {
	local command="$1" endpoint="${2:-}"
	if [[ "$command" == auth && "$endpoint" == token ]]; then
		printf '%s' "${KEYCHAIN_TOKEN:-}"
		return 0
	fi
	if [[ "$command" == api && "$endpoint" == user ]]; then
		printf 'user\n' >>"$TEST_ROOT/users"
		printf 'same-login\n'
		return 0
	fi
	return 1
}
_gh_collaborator_permission_lookup() {
	local repo="$1" user="$2" destination="$3"
	[[ -n "$repo" && -n "$user" ]] || return 1
	permission_calls=$((permission_calls + 1))
	if [[ "${GH_ENTERPRISE_TOKEN:-$GH_TOKEN}" == token-a ]]; then
		printf -v "$destination" '%s' write
	else
		printf -v "$destination" '%s' read
	fi
	return 0
}
export GH_TOKEN=token-a
_gh_current_user_allows_repo_write owner/repo
_gh_current_user_allows_repo_write owner/repo
[[ "$permission_calls" == 1 ]]
_gh_current_user_allows_repo_write owner/other
[[ "$permission_calls" == 2 ]]
export GH_TOKEN=token-b
if _gh_current_user_allows_repo_write owner/repo; then exit 1; fi
[[ "$permission_calls" == 3 && "$AIDEVOPS_GH_WRITE_PERMISSION_LEVEL" == read ]]
if _gh_current_user_allows_repo_write owner/repo; then exit 1; fi
[[ "$permission_calls" == 3 ]]
export GH_TOKEN=token-a
_gh_current_user_allows_repo_write owner/repo
[[ "$permission_calls" == 3 ]]
[[ "$(wc -l <"$TEST_ROOT/users" | tr -d ' ')" == 2 ]]
printf 'PASS credential-keyed login and per-repository permission memoization, including rotation\n'

export GH_HOST=enterprise.invalid GH_ENTERPRISE_TOKEN=token-a
_gh_current_user_allows_repo_write owner/repo
[[ "$permission_calls" == 4 ]]
export GH_ENTERPRISE_TOKEN=token-b
if _gh_current_user_allows_repo_write owner/repo; then exit 1; fi
[[ "$permission_calls" == 5 ]]
unset GH_HOST GH_ENTERPRISE_TOKEN GH_TOKEN
KEYCHAIN_TOKEN=token-a
_gh_current_user_allows_repo_write owner/keychain
KEYCHAIN_TOKEN=token-b
if _gh_current_user_allows_repo_write owner/keychain; then exit 1; fi
[[ "$permission_calls" == 7 ]]
export GH_TOKEN=token-a
printf 'PASS keychain and enterprise credential rotation never reuses another credential authority\n'

gh_budget_worker_reserve_allows 1001 5000
if gh_budget_worker_reserve_allows 1000 5000 2>"$TEST_ROOT/defer"; then exit 1; fi
[[ -s "$TEST_ROOT/defer" ]]
if gh_budget_worker_reserve_allows 999 5000 2>/dev/null; then exit 1; fi
source "$SCRIPT_DIR/pulse-budget-priority.sh"
export AIDEVOPS_PULSE_REST_CORE_BUDGET_REMAINING=1000 AIDEVOPS_PULSE_REST_CORE_BUDGET_LIMIT=5000
_pulse_rest_core_budget_defers_priority deferrable
if _pulse_rest_core_budget_defers_priority critical; then exit 1; fi
printf 'PASS optional stage reserve boundary leaves critical dispatch eligible\n'
export AIDEVOPS_PULSE_REST_CORE_BUDGET_REMAINING=5000

_pmrs_gh_call() {
	printf 'reviews\n' >>"$TEST_ROOT/review-calls"
	printf '[]'
	return 0
}
pr='[{"number":1,"headRefOid":"head-a","updatedAt":"2026-11-09T01:00:00Z"}]'
_pmp_enrich_prs_with_review_decisions owner/repo "$pr" | jq -e '.[0].reviewDecision == "NONE"' >/dev/null
_pmp_enrich_prs_with_review_decisions owner/repo "$pr" | jq -e '.[0].reviewDecision == "NONE"' >/dev/null
[[ "$(wc -l <"$TEST_ROOT/review-calls" | tr -d ' ')" == 1 ]]
_pmp_enrich_prs_with_review_decisions owner/repo "${pr/head-a/head-b}" >/dev/null
_pmp_enrich_prs_with_review_decisions owner/repo "${pr/01:00:00/01:01:00}" >/dev/null
[[ "$(wc -l <"$TEST_ROOT/review-calls" | tr -d ' ')" == 3 ]]
# Safety-critical final reconciliation never consumes the enrichment cache.
_pmp_rest_reviews_json 1 owner/repo >/dev/null
[[ "$(wc -l <"$TEST_ROOT/review-calls" | tr -d ' ')" == 4 ]]
export AIDEVOPS_PULSE_REST_CORE_BUDGET_REMAINING=1000
if _pmp_rest_reviews_json 2 owner/repo; then exit 1; fi
[[ "$(wc -l <"$TEST_ROOT/review-calls" | tr -d ' ')" == 4 ]]
printf 'PASS unchanged PR review reuse, SHA/timestamp invalidation, fresh final reconciliation and reserve\n'

export AIDEVOPS_PULSE_REST_CORE_BUDGET_REMAINING=5000
unset GH_TOKEN
KEYCHAIN_TOKEN=token-a
_pmp_enrich_prs_with_review_decisions owner/repo "$pr" >/dev/null
[[ "$(wc -l <"$TEST_ROOT/review-calls" | tr -d ' ')" == 4 ]]
KEYCHAIN_TOKEN=token-b
_pmp_enrich_prs_with_review_decisions owner/repo "$pr" >/dev/null
[[ "$(wc -l <"$TEST_ROOT/review-calls" | tr -d ' ')" == 5 ]]
python3 - "$AIDEVOPS_PULSE_REVIEW_CACHE_DIR" <<'PY'
import json
import pathlib
import sys
for path in pathlib.Path(sys.argv[1]).glob('*.json'):
    row = json.loads(path.read_text())
    row['at'] = 0
    path.write_text(json.dumps(row))
PY
_pmp_enrich_prs_with_review_decisions owner/repo "$pr" >/dev/null
[[ "$(wc -l <"$TEST_ROOT/review-calls" | tr -d ' ')" == 6 ]]
export GH_TOKEN=token-a
printf 'PASS review cache isolates keychain identities and expires stale decisions\n'

gh_record_attempt rest test logical attempt-1 1 0 success 200 1 1 gh-pat rest-core test 4000 '' '' '' '' GET repos-pulls 'repos/:o/:r/pulls/:id/reviews'
gh_record_attempt rest test logical attempt-2 1 0 success 200 1 1 gh-pat rest-core test 4000 '' '' '' '' GET repos-other 'repos/:o/:r/collaborators/:u/permission'
gh_record_attempt rest test logical attempt-3 1 0 success 200 1 1 gh-pat rest-core test 4000 '' '' '' '' GET repos-other 'private/secret?token=value'
_api_budget_top_rest_families_json "$AIDEVOPS_GH_API_LOG" | jq -e 'length == 3 and any(.family == "repos/:o/:r/pulls/:id/reviews") and any(.family == "unknown")' >/dev/null
python3 - "$SCRIPT_DIR" <<'PY'
import runpy
import sys
sys.path.insert(0, sys.argv[1])
family = runpy.run_path(sys.argv[1] + '/gh-quota-debug-filter.py')['_endpoint_family']
assert family(b'/repos/private/private/pulls/123/reviews?secret=value') == 'repos/:o/:r/pulls/:id/reviews'
assert family(b'/repos/private/private/collaborators/private/permission') == 'repos/:o/:r/collaborators/:u/permission'
assert family(b'/user') == 'user'
PY
printf 'PASS sanitized native endpoint families and 60-minute report\n'
