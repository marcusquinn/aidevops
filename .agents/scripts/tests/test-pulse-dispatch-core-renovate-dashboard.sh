#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the Renovate Dependency Dashboard early-skip helper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../renovate-dependency-dashboard-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_is_renovate_dependency_dashboard_issue\(\) \{/,/^}$/ { print }
	' "$HELPER_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _is_renovate_dependency_dashboard_issue from %s\n' "$HELPER_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

test_detects_renovate_dependency_dashboard() {
	local meta='{"number":24975,"title":"Dependency Dashboard","author":{"login":"renovate[bot]"},"labels":[{"name":"enhancement"}]}'
	if _is_renovate_dependency_dashboard_issue "$meta"; then
		print_result "detects renovate Dependency Dashboard issue" 0
		return 0
	fi
	print_result "detects renovate Dependency Dashboard issue" 1 \
		"Expected exit 0 for renovate[bot] Dependency Dashboard metadata issue"
	return 0
}

test_ignores_normal_renovate_update_issue() {
	local meta='{"number":24976,"title":"chore(deps): bump lodash from 4.17.21 to 4.17.22","author":{"login":"renovate[bot]"},"labels":[{"name":"dependencies"}]}'
	if _is_renovate_dependency_dashboard_issue "$meta"; then
		print_result "ignores normal renovate dependency update issue" 1 \
			"Expected exit 1 for a regular renovate update issue"
		return 0
	fi
	print_result "ignores normal renovate dependency update issue" 0
	return 0
}

# GH#38544: gh GraphQL emits App authors as app/<slug>, REST as <slug>[bot];
# self-hosted Renovate apps use their own slug (e.g. <org>-renovate).
test_detects_dashboard_for_app_login_shapes() {
	local login="" meta=""
	for login in 'app/renovate' 'app/example-renovate' 'example-renovate[bot]' 'Example-Renovate[bot]'; do
		meta=$(jq -cn --arg login "$login" '{number:38544,title:"Dependency Dashboard",author:{is_bot:true,login:$login}}')
		if _is_renovate_dependency_dashboard_issue "$meta"; then
			print_result "detects Dependency Dashboard authored by ${login}" 0
		else
			print_result "detects Dependency Dashboard authored by ${login}" 1 \
				"Expected exit 0 for ${login} Dependency Dashboard metadata issue"
		fi
	done
	return 0
}

test_ignores_dashboard_title_from_non_renovate_authors() {
	local login="" meta=""
	for login in 'renovate' 'renovate-fan' 'app/dependabot' 'dependabot[bot]'; do
		meta=$(jq -cn --arg login "$login" '{number:38545,title:"Dependency Dashboard",author:{login:$login}}')
		if _is_renovate_dependency_dashboard_issue "$meta"; then
			print_result "ignores Dependency Dashboard title from ${login}" 1 \
				"Expected exit 1 for non-Renovate-App author ${login}"
		else
			print_result "ignores Dependency Dashboard title from ${login}" 0
		fi
	done
	return 0
}

main() {
	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_detects_renovate_dependency_dashboard
	test_ignores_normal_renovate_update_issue
	test_detects_dashboard_for_app_login_shapes
	test_ignores_dashboard_title_from_non_renovate_authors

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
