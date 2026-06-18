#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="${SCRIPT_DIR}/.."

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	return 0
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pulse-pr-list-cache-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

GH_CALLS="${TMP_DIR}/gh-calls.log"
: >"$GH_CALLS"
unset PULSE_PR_LIST_PROVIDER_CACHE_DISABLE

gh_pr_list() {
	printf '%s\n' "$*" >>"$GH_CALLS"
	printf '[{"number":1,"reviewDecision":"APPROVED","headRefOid":"abc123"}]'
	return 0
}

# shellcheck source=../pulse-pr-list-cache.sh
source "${SCRIPTS_DIR}/pulse-pr-list-cache.sh"

export PULSE_PR_LIST_PROVIDER_CACHE_DIR="${TMP_DIR}/cache"
export PULSE_PR_LIST_PROVIDER_CACHE_TTL=3600

first_output=$(pulse_pr_list_get --repo owner/repo --state open --json number,reviewDecision,headRefOid --limit 200)
second_output=$(pulse_pr_list_get --repo owner/repo --state open --json number,reviewDecision,headRefOid --limit 200)
backend_calls=$(grep -c -- '--json number,reviewDecision,headRefOid' "$GH_CALLS" 2>/dev/null || true)
if [[ "$first_output" == "$second_output" && "$backend_calls" == "1" ]]; then
	pass "provider cache coalesces identical GraphQL-field PR list calls"
else
	fail "provider cache coalesces identical GraphQL-field PR list calls" \
		"first=${first_output} second=${second_output} backend_calls=${backend_calls} calls=$(<"$GH_CALLS")"
fi

third_output=$(pulse_pr_list_get --repo owner/repo --state open --json number,title --limit 200)
different_shape_calls=$(grep -c -- '--json number,title' "$GH_CALLS" 2>/dev/null || true)
if [[ "$third_output" == '[{"number":1,"reviewDecision":"APPROVED","headRefOid":"abc123"}]' && "$different_shape_calls" == "1" ]]; then
	pass "provider cache keys different field sets separately"
else
	fail "provider cache keys different field sets separately" \
		"third=${third_output} different_shape_calls=${different_shape_calls} calls=$(<"$GH_CALLS")"
fi

: >"$GH_CALLS"
pulse_pr_list_get --repo owner/repo --state open --head branch-a --json number --limit 10 >/dev/null
pulse_pr_list_get --repo owner/repo --state open --head branch-a --json number --limit 10 >/dev/null
pulse_pr_list_get --repo owner/repo --state open --head branch-b --json number --limit 10 >/dev/null
head_a_calls=$(grep -c -- '--head branch-a' "$GH_CALLS" 2>/dev/null || true)
head_b_calls=$(grep -c -- '--head branch-b' "$GH_CALLS" 2>/dev/null || true)
if [[ "$head_a_calls" == "1" && "$head_b_calls" == "1" ]]; then
	pass "provider cache keys different filter arguments separately"
else
	fail "provider cache keys different filter arguments separately" \
		"head_a_calls=${head_a_calls} head_b_calls=${head_b_calls} calls=$(<"$GH_CALLS")"
fi

: >"$GH_CALLS"
export PULSE_PR_LIST_PROVIDER_CACHE_DISABLE=1
pulse_pr_list_get --repo owner/repo --state open --json number,reviewDecision,headRefOid --limit 200 >/dev/null
pulse_pr_list_get --repo owner/repo --state open --json number,reviewDecision,headRefOid --limit 200 >/dev/null
disabled_calls=$(grep -c -- '--json number,reviewDecision,headRefOid' "$GH_CALLS" 2>/dev/null || true)
unset PULSE_PR_LIST_PROVIDER_CACHE_DISABLE
if [[ "$disabled_calls" == "2" ]]; then
	pass "provider cache disable bypasses exact-output cache"
else
	fail "provider cache disable bypasses exact-output cache" \
		"disabled_calls=${disabled_calls} calls=$(<"$GH_CALLS")"
fi

: >"$GH_CALLS"
unset PULSE_PR_LIST_PROVIDER_CACHE_DIR PULSE_PR_LIST_PROVIDER_CACHE_TTL
export PULSE_PR_LIST_PROVIDER_CACHE_DISABLE=1
pulse_pr_list_get --repo owner/repo --state open --json number,reviewDecision,headRefOid --limit 200 >/dev/null
pulse_pr_list_get --repo owner/repo --state open --json number,reviewDecision,headRefOid --limit 200 >/dev/null
wrapper_disabled_calls=$(grep -c -- '--json number,reviewDecision,headRefOid' "$GH_CALLS" 2>/dev/null || true)
unset PULSE_PR_LIST_PROVIDER_CACHE_DISABLE
if [[ "$wrapper_disabled_calls" == "2" ]]; then
	pass "provider cache remains disabled when wrapper exports disable without cache dir"
else
	fail "provider cache remains disabled when wrapper exports disable without cache dir" \
		"wrapper_disabled_calls=${wrapper_disabled_calls} calls=$(<"$GH_CALLS")"
fi

printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
