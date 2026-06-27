#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)"
CHECKS_LIB="${SCRIPTS_DIR}/shared-gh-wrappers-checks.sh"

# shellcheck source=../shared-gh-wrappers-checks.sh
source "$CHECKS_LIB"

CHECK_SUITES_FIXTURE='{}'

_gh_checks_api_read() {
	local endpoint="$1"
	shift
	local jq_filter=""

	if [[ "$endpoint" != "repos/owner/repo/commits/abc123/check-suites" ]]; then
		printf 'FAIL: unexpected endpoint: %s\n' "$endpoint" >&2
		return 1
	fi

	while [[ "$#" -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--jq)
			shift
			local filter_arg="$1"
			jq_filter="$filter_arg"
			;;
		esac
		if [[ "$#" -gt 0 ]]; then
			shift
		fi
	done

	if [[ -z "$jq_filter" ]]; then
		printf 'FAIL: missing jq filter\n' >&2
		return 1
	fi

	printf '%s\n' "$CHECK_SUITES_FIXTURE" | jq -r "$jq_filter"
	return $?
}

assert_status() {
	local name="$1"
	local expected="$2"
	local fixture="$3"

	CHECK_SUITES_FIXTURE="$fixture"
	local actual
	actual="$(gh_pr_check_status_rest "owner/repo" "abc123")"

	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: %s expected %s, got %s\n' "$name" "$expected" "$actual" >&2
		return 1
	fi

	return 0
}

main() {
	assert_status "missing check_suites defaults to none" "none" '{}'
	assert_status "null check_suites defaults to none" "none" '{"check_suites":null}'
	assert_status "null queued app suites ignored when actions passed" "PASS" '{"check_suites":[{"app":{"slug":"github-actions"},"status":"completed","conclusion":"success"},{"app":{"slug":"coderabbitai"},"status":"queued","conclusion":null}]}'
	assert_status "all null suites mean no active checks" "none" '{"check_suites":[{"app":{"slug":"coderabbitai"},"status":"queued","conclusion":null}]}'
	assert_status "terminal failure still fails" "FAIL" '{"check_suites":[{"app":{"slug":"github-actions"},"status":"completed","conclusion":"success"},{"app":{"slug":"github-actions"},"status":"completed","conclusion":"failure"},{"app":{"slug":"coderabbitai"},"status":"queued","conclusion":null}]}'
	assert_status "in-progress null suite remains pending" "PENDING" '{"check_suites":[{"app":{"slug":"github-actions"},"status":"completed","conclusion":"success"},{"app":{"slug":"github-actions"},"status":"in_progress","conclusion":null}]}'

	printf 'PASS shared-gh-wrappers-checks null-conclusion suites ignored\n'
	return 0
}

main "$@"
