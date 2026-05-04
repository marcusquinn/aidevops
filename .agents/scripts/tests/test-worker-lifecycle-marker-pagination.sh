#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for awardsapp/awardsapp#4007 / t2769 no_work loops.
# Long issue threads push breaker markers onto later GitHub comment pages;
# worker-lifecycle marker idempotency must slurp all pages before counting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
LIFECYCLE_SCRIPT="${REPO_ROOT}/.agents/scripts/worker-lifecycle-common.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMP=""
GH_CALL_LOG=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '  %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_TMP="$(mktemp -d -t worker-marker-pagination.XXXXXX)"
	GH_CALL_LOG="${TEST_TMP}/gh-calls.log"
	: >"$GH_CALL_LOG"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
	return 0
}

define_marker_counter() {
	local helper_src=""
	helper_src=$(awk '
		/^_count_issue_comments_containing_marker\(\) \{/,/^\}/ { print }
	' "$LIFECYCLE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _count_issue_comments_containing_marker\n' >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

gh() {
	local cmd="${1:-}"
	shift || true
	if [[ "$cmd" != "api" ]]; then
		printf '{}\n'
		return 0
	fi

	local api_path="${1:-}"
	shift || true
	if [[ "$api_path" != "repos/owner/repo/issues/4007/comments" ]]; then
		printf '[]\n'
		return 0
	fi

	local has_paginate=0
	local has_slurp=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--paginate)
			has_paginate=1
			shift
			;;
		--slurp)
			has_slurp=1
			shift
			;;
		--jq)
			shift 2 || true
			;;
		*)
			shift
			;;
		esac
	done

	if [[ "$has_paginate" -eq 1 && "$has_slurp" -eq 1 ]]; then
		printf 'comments_slurped\n' >>"$GH_CALL_LOG"
		printf '[[{"body":"old dispatch claim"}],[{"body":"<!-- cost-circuit-breaker:no_work_loop -->\\n## no_work Circuit Breaker Fired"}]]\n'
		return 0
	fi

	if [[ "$has_paginate" -eq 1 ]]; then
		printf 'comments_paginated_without_slurp\n' >>"$GH_CALL_LOG"
		printf '[{"body":"old dispatch claim"}]\n[{"body":"<!-- cost-circuit-breaker:no_work_loop -->"}]\n'
		return 0
	fi

	printf 'comments_unpaginated\n' >>"$GH_CALL_LOG"
	printf '[{"body":"old dispatch claim"}]\n'
	return 0
}

test_marker_count_slurps_paginated_comments() {
	local marker="cost-circuit-breaker:no_work_loop"
	local count=""
	count=$(_count_issue_comments_containing_marker "4007" "owner/repo" "$marker") || count=""

	if [[ "$count" != "1" ]]; then
		print_result "marker count sees page-2 no_work marker" 1 \
			"expected count=1, got '${count:-empty}'"
		return 0
	fi

	if ! grep -q '^comments_slurped$' "$GH_CALL_LOG" 2>/dev/null; then
		print_result "marker count requests paginated slurp" 1 \
			"gh mock did not observe --paginate --slurp"
		return 0
	fi

	print_result "marker count sees page-2 no_work marker" 0
	print_result "marker count requests paginated slurp" 0
	return 0
}

test_marker_count_returns_zero_when_absent() {
	local marker="missing-marker"
	local count=""
	: >"$GH_CALL_LOG"
	count=$(_count_issue_comments_containing_marker "4007" "owner/repo" "$marker") || count=""

	if [[ "$count" != "0" ]]; then
		print_result "marker count returns zero when absent" 1 \
			"expected count=0, got '${count:-empty}'"
		return 0
	fi

	print_result "marker count returns zero when absent" 0
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT

	if ! define_marker_counter; then
		return 1
	fi

	test_marker_count_slurps_paginated_comments
	test_marker_count_returns_zero_when_absent

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
