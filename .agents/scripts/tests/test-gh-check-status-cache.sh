#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for t18128: aggregate PR check-state caching by exact
# repository/auth-scope/head-SHA/projection identity. The cached rollup is
# observational only; named required-check and merge-authority reads stay live.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)"
CHECKS_LIB="${SCRIPTS_DIR}/shared-gh-wrappers-checks.sh"
MERGE_REQUIRED_LIB="${SCRIPTS_DIR}/pulse-merge-required-checks.sh"
TEST_ROOT="$(mktemp -d)"
ORIGINAL_HOME="${HOME}"

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_GH_CHECK_STATUS_CACHE_DIR="${TEST_ROOT}/cache"
export AIDEVOPS_GH_CHECK_STATUS_CACHE_TERMINAL_TTL=60
export AIDEVOPS_GH_CHECK_STATUS_CACHE_ACTIONABLE_TTL=10
export AIDEVOPS_GH_AUTH_MODE=gh
export AIDEVOPS_GH_AUTH_PRINCIPAL=default
mkdir -p "$HOME"

API_CALLS="${TEST_ROOT}/api-calls.log"
CHECK_NOW=100
CHECK_API_MODE=success
CHECK_API_DELAY=0
CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"completed","conclusion":"success"}]}'

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA_C="cccccccccccccccccccccccccccccccccccccccc"
SHA_D="dddddddddddddddddddddddddddddddddddddddd"
SHA_E="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
SHA_F="ffffffffffffffffffffffffffffffffffffffff"
SHA_G="1111111111111111111111111111111111111111"
SHA_H="2222222222222222222222222222222222222222"

# shellcheck source=../shared-gh-wrappers-checks.sh
source "$CHECKS_LIB"

cleanup() {
	export HOME="$ORIGINAL_HOME"
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

# Deterministic clock seam used by the cache expiry helpers.
_gh_pr_check_status_cache_now() {
	printf '%s\n' "$CHECK_NOW"
	return 0
}

# Stub the transport while preserving the production jq projection contract.
_gh_checks_api_read() {
	local endpoint="$1"
	shift
	printf '%s\n' "$endpoint" >>"$API_CALLS"
	[[ "$CHECK_API_DELAY" == "0" ]] || sleep "$CHECK_API_DELAY"

	case "$CHECK_API_MODE" in
	failure)
		return 1
		;;
	malformed)
		printf 'NOT_A_CHECK_STATE\n'
		return 0
		;;
	success) ;;
	*)
		printf 'unexpected CHECK_API_MODE: %s\n' "$CHECK_API_MODE" >&2
		return 1
		;;
	esac

	local jq_filter=""
	while [[ "$#" -gt 0 ]]; do
		local arg="$1"
		shift
		if [[ "$arg" == "--jq" && "$#" -gt 0 ]]; then
			jq_filter="$1"
			shift
		fi
	done
	[[ -n "$jq_filter" ]] || return 1
	printf '%s\n' "$CHECK_SUITES_FIXTURE" | jq -r "$jq_filter"
	return $?
}

api_call_count() {
	local count=0
	if [[ -f "$API_CALLS" ]]; then
		count=$(wc -l <"$API_CALLS")
		count="${count//[!0-9]/}"
	fi
	printf '%s\n' "${count:-0}"
	return 0
}

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual" >&2
		return 1
	fi
	printf 'PASS: %s\n' "$name"
	return 0
}

assert_json_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	local expected_compact="" actual_compact=""
	expected_compact=$(printf '%s' "$expected" | jq -c '.')
	actual_compact=$(printf '%s' "$actual" | jq -c '.')
	assert_eq "$name" "$expected_compact" "$actual_compact"
	return $?
}

cache_path() {
	local slug="$1"
	local sha="$2"
	_gh_pr_check_status_cache_path "$slug" "$sha"
	return $?
}

file_mode() {
	local path="$1"
	local mode=""
	mode=$(stat -f '%Lp' "$path" 2>/dev/null) || mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
	printf '%s\n' "$mode"
	return 0
}

test_terminal_reuse_dedup_and_order() {
	local prs='[{"number":9,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"number":3,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
	local result=""
	result=$(gh_pr_check_status_rest_batch "owner/repo" "$prs")
	assert_json_eq "duplicate heads preserve PR order and cardinality" \
		'[{"number":9,"status":"PASS"},{"number":3,"status":"PASS"}]' "$result"
	assert_eq "duplicate heads make one transport attempt" "1" "$(api_call_count)"

	result=$(gh_pr_check_status_rest_batch "owner/repo" "$prs")
	assert_json_eq "unchanged terminal heads reuse cached aggregate state" \
		'[{"number":9,"status":"PASS"},{"number":3,"status":"PASS"}]' "$result"
	assert_eq "unchanged terminal heads make zero additional attempts" "1" "$(api_call_count)"
	return 0
}

test_new_head_repo_and_auth_scope_miss() {
	local result=""
	CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"completed","conclusion":"failure"}]}'
	result=$(gh_pr_check_status_rest_batch "owner/repo" \
		'[{"number":4,"headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]')
	assert_json_eq "new full head SHA misses prior-head cache" '[{"number":4,"status":"FAIL"}]' "$result"
	assert_eq "new head performs one additional attempt" "2" "$(api_call_count)"

	result=$(gh_pr_check_status_rest_batch "other/repo" \
		'[{"number":5,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]')
	assert_json_eq "same head does not leak across repositories" '[{"number":5,"status":"FAIL"}]' "$result"
	assert_eq "repository scope performs one additional attempt" "3" "$(api_call_count)"

	AIDEVOPS_GH_AUTH_PRINCIPAL=alternate
	result=$(gh_pr_check_status_rest_batch "owner/repo" \
		'[{"number":6,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]')
	assert_json_eq "same repo and head do not leak across auth scopes" '[{"number":6,"status":"FAIL"}]' "$result"
	assert_eq "auth scope performs one additional attempt" "4" "$(api_call_count)"
	AIDEVOPS_GH_AUTH_PRINCIPAL=default

	result=$(gh_pr_check_status_rest_batch "owner/repo" \
		'[{"number":7,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]')
	assert_json_eq "original auth scope retains its terminal entry" '[{"number":7,"status":"PASS"}]' "$result"
	assert_eq "returning to original auth scope is transport-free" "4" "$(api_call_count)"
	return 0
}

test_actionable_and_terminal_expiry() {
	local result=""
	CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"in_progress","conclusion":null}]}'
	CHECK_NOW=200
	result=$(gh_pr_check_status_rest_batch "owner/repo" \
		'[{"number":8,"headRefOid":"cccccccccccccccccccccccccccccccccccccccc"}]')
	assert_json_eq "pending state is cached briefly" '[{"number":8,"status":"PENDING"}]' "$result"
	assert_eq "initial pending observation is fetched" "5" "$(api_call_count)"

	CHECK_NOW=209
	result=$(gh_pr_check_status_rest_batch "owner/repo" \
		'[{"number":8,"headRefOid":"cccccccccccccccccccccccccccccccccccccccc"}]')
	assert_json_eq "pending state is reused inside actionable TTL" '[{"number":8,"status":"PENDING"}]' "$result"
	assert_eq "fresh pending entry makes no additional attempt" "5" "$(api_call_count)"

	CHECK_NOW=211
	CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"completed","conclusion":"success"}]}'
	result=$(gh_pr_check_status_rest_batch "owner/repo" \
		'[{"number":8,"headRefOid":"cccccccccccccccccccccccccccccccccccccccc"}]')
	assert_json_eq "expired pending state refreshes to terminal" '[{"number":8,"status":"PASS"}]' "$result"
	assert_eq "expired pending entry performs one refresh" "6" "$(api_call_count)"

	CHECK_NOW=300
	CHECK_SUITES_FIXTURE='{}'
	result=$(gh_pr_check_status_rest_batch "owner/repo" \
		'[{"number":10,"headRefOid":"dddddddddddddddddddddddddddddddddddddddd"}]')
	assert_json_eq "none state remains an explicit actionable observation" '[{"number":10,"status":"none"}]' "$result"
	assert_eq "initial none observation is fetched" "7" "$(api_call_count)"

	CHECK_NOW=311
	CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"completed","conclusion":"success"}]}'
	result=$(gh_pr_check_status_rest_batch "owner/repo" \
		'[{"number":10,"headRefOid":"dddddddddddddddddddddddddddddddddddddddd"}]')
	assert_json_eq "expired none state refreshes" '[{"number":10,"status":"PASS"}]' "$result"
	assert_eq "expired none entry performs one refresh" "8" "$(api_call_count)"

	CHECK_NOW=372
	CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"completed","conclusion":"failure"}]}'
	result=$(gh_pr_check_status_rest_batch "owner/repo" \
		'[{"number":10,"headRefOid":"dddddddddddddddddddddddddddddddddddddddd"}]')
	assert_json_eq "terminal state refreshes after bounded terminal TTL" '[{"number":10,"status":"FAIL"}]' "$result"
	assert_eq "expired terminal entry performs one refresh" "9" "$(api_call_count)"
	return 0
}

test_corruption_failure_and_invalidation() {
	local path="" result="" before="" after=""
	CHECK_NOW=400
	path=$(cache_path "owner/repo" "$SHA_E")
	printf '{broken json\n' >"$path"
	CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"completed","conclusion":"success"}]}'
	result=$(gh_pr_check_status_rest "owner/repo" "$SHA_E")
	assert_eq "malformed cache entry is a miss" "PASS" "$result"
	assert_eq "malformed cache entry triggers a live fetch" "10" "$(api_call_count)"
	if ! jq -e --arg sha "$SHA_E" '.head_sha == $sha and .state == "PASS"' "$path" >/dev/null; then
		printf 'FAIL: malformed cache entry was not replaced atomically\n' >&2
		return 1
	fi
	printf 'PASS: malformed cache entry is replaced with validated schema\n'

	CHECK_NOW=500
	result=$(gh_pr_check_status_rest "owner/repo" "$SHA_F")
	assert_eq "terminal fixture seeds API-failure scenario" "PASS" "$result"
	path=$(cache_path "owner/repo" "$SHA_F")
	before=$(jq -c '.' "$path")
	CHECK_NOW=561
	CHECK_API_MODE=failure
	result=$(gh_pr_check_status_rest "owner/repo" "$SHA_F")
	assert_eq "API failure returns non-authoritative none" "none" "$result"
	after=$(jq -c '.' "$path")
	assert_eq "API failure does not overwrite prior terminal entry" "$before" "$after"
	assert_eq "failed refresh still records one transport attempt" "12" "$(api_call_count)"

	CHECK_API_MODE=malformed
	CHECK_NOW=600
	result=$(gh_pr_check_status_rest "owner/repo" "$SHA_G")
	assert_eq "malformed API projection is not trusted" "none" "$result"
	path=$(cache_path "owner/repo" "$SHA_G")
	assert_eq "malformed API projection is not stored" "false" "$([[ -f "$path" ]] && printf true || printf false)"
	assert_eq "malformed API projection performs one attempt" "13" "$(api_call_count)"

	CHECK_API_MODE=success
	CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"completed","conclusion":"success"}]}'
	CHECK_NOW=700
	result=$(gh_pr_check_status_rest "owner/repo" "$SHA_H")
	assert_eq "invalidation fixture starts terminal" "PASS" "$result"
	gh_pr_check_status_cache_invalidate "owner/repo" "$SHA_H"
	gh_pr_check_status_cache_invalidate "owner/repo" "$SHA_H"
	CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"completed","conclusion":"failure"}]}'
	result=$(gh_pr_check_status_rest "owner/repo" "$SHA_H")
	assert_eq "idempotent explicit invalidation forces refresh" "FAIL" "$result"
	assert_eq "explicit invalidation adds exactly one fetch" "15" "$(api_call_count)"
	return 0
}

test_private_atomic_cache_and_authority_boundary() {
	local path="" dir="" result="" job="" before="" after="" expected=""
	path=$(cache_path "owner/repo" "$SHA_H")
	dir="${path%/*}"
	assert_eq "cache directory is private" "700" "$(file_mode "$dir")"
	assert_eq "cache entry is private" "600" "$(file_mode "$path")"

	gh_pr_check_status_cache_invalidate "owner/repo" "$SHA_H"
	CHECK_NOW=800
	CHECK_SUITES_FIXTURE='{"check_suites":[{"status":"completed","conclusion":"success"}]}'
	CHECK_API_DELAY=0.25
	before=$(api_call_count)
	for job in 1 2 3 4; do
		gh_pr_check_status_rest "owner/repo" "$SHA_H" >/dev/null &
	done
	wait
	CHECK_API_DELAY=0
	after=$(api_call_count)
	expected=$((before + 1))
	assert_eq "concurrent aggregate misses perform one transport" "$expected" "$after"
	path=$(cache_path "owner/repo" "$SHA_H")
	result=$(jq -r --arg sha "$SHA_H" 'select(.head_sha == $sha and .state == "PASS") | .state' "$path")
	assert_eq "concurrent last-writer-wins cache remains valid" "PASS" "$result"
	if compgen -G "${dir}/.pr-check-status.*" >/dev/null; then
		printf 'FAIL: atomic cache write left temporary files behind\n' >&2
		return 1
	fi
	printf 'PASS: atomic cache writes leave no temporary files\n'

	before=$(api_call_count)
	CHECK_API_DELAY=0.1
	gh_pr_check_runs_rest "owner/repo" "$SHA_H" >/dev/null &
	gh_pr_check_runs_rest "owner/repo" "$SHA_H" >/dev/null &
	wait
	CHECK_API_DELAY=0
	after=$(api_call_count)
	expected=$((before + 4))
	assert_eq "named check reads remain live and uncoalesced" "$expected" "$after"

	if grep -q 'gh_pr_check_status_rest' "$MERGE_REQUIRED_LIB"; then
		printf 'FAIL: final required-check module references aggregate cached status\n' >&2
		return 1
	fi
	if ! grep -q 'gh_pr_check_runs_rest' "$MERGE_REQUIRED_LIB"; then
		printf 'FAIL: final required-check module lacks live named check-run reads\n' >&2
		return 1
	fi
	printf 'PASS: final required-check authority remains on live named checks\n'
	return 0
}

main() {
	test_terminal_reuse_dedup_and_order
	test_new_head_repo_and_auth_scope_miss
	test_actionable_and_terminal_expiry
	test_corruption_failure_and_invalidation
	test_private_atomic_cache_and_authority_boundary
	printf 'PASS: PR check-status cache regression suite\n'
	return 0
}

main "$@"
