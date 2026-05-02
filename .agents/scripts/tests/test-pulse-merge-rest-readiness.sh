#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
MERGE_PROCESS="${SCRIPT_DIR}/../pulse-merge-process.sh"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local ok="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$ok" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

define_functions_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_pmp_enrich_prs_with_rest_check_status\(\) \{/,/^}$/ { print }
	' "$MERGE_PROCESS")
	[[ -n "$fn_src" ]] || return 1
	# shellcheck disable=SC1090
	eval "$fn_src"
	return 0
}

gh_pr_check_status_rest_batch() {
	local slug="$1"
	local pr_json="$2"
	[[ "$slug" == "owner/repo" && -n "$pr_json" ]] || return 1
	printf '%s\n' '[{"number":1,"status":"PASS"},{"number":2,"status":"FAIL"},{"number":3,"status":"PENDING"},{"number":4,"status":"none"}]'
	return 0
}

assert_rollup() {
	local name="$1"
	local number="$2"
	local expected="$3"
	local output="$4"
	local actual
	actual=$(printf '%s' "$output" | jq -r --argjson n "$number" '.[] | select(.number == $n) | (.statusCheckRollup[0].conclusion // .statusCheckRollup[0].status // "none")') || actual=""
	[[ "$actual" == "$expected" ]]
	print_result "$name" "$?" "expected=${expected} actual=${actual}"
	return 0
}

main() {
	define_functions_under_test || { printf 'failed to load function\n' >&2; return 1; }
	local prs output
	prs='[{"number":1,"headRefOid":"a"},{"number":2,"headRefOid":"b"},{"number":3,"headRefOid":"c"},{"number":4,"headRefOid":"d"}]'
	output=$(_pmp_enrich_prs_with_rest_check_status "owner/repo" "$prs")
	assert_rollup "green REST check maps to success rollup" 1 "SUCCESS" "$output"
	assert_rollup "failing REST check maps to failure rollup" 2 "FAILURE" "$output"
	assert_rollup "pending REST check maps to in-progress rollup" 3 "IN_PROGRESS" "$output"
	assert_rollup "missing REST check stays ambiguous/empty" 4 "none" "$output"
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
