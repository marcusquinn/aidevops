#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#23601.
#
# The tier:simple body-shape validator can mutate labels on GitHub after
# dispatch_with_dedup has captured the t2996 issue_meta_json bundle. These tests
# exercise the refresh helper in isolation so downstream gates receive the
# updated tier labels without needing a live GitHub issue or worker launch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
GH_ISSUE_VIEW_CALLS_FILE=""

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
		/^_refresh_issue_meta_after_tier_body_shape_check\(\) \{/,/^}$/ { print }
	' "$CORE_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _refresh_issue_meta_after_tier_body_shape_check from %s\n' "$CORE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$helper_src"
	return 0
}

gh_issue_view() {
	local issue_number="$1"
	shift
	if [[ -n "$GH_ISSUE_VIEW_CALLS_FILE" ]]; then
		printf 'call\n' >>"$GH_ISSUE_VIEW_CALLS_FILE"
	fi
	if [[ "$issue_number" != "23601" ]]; then
		return 1
	fi
	printf '%s' '{"number":23601,"title":"stale tier","state":"OPEN","labels":[{"name":"tier:standard"},{"name":"auto-dispatch"}],"assignees":[],"body":"brief"}'
	return 0
}

reset_gh_issue_view_calls() {
	: >"$GH_ISSUE_VIEW_CALLS_FILE"
	return 0
}

count_gh_issue_view_calls() {
	local calls
	calls=$(wc -l <"$GH_ISSUE_VIEW_CALLS_FILE") || calls=0
	printf '%s' "$calls"
	return 0
}

test_refreshes_precheck_tier_simple_snapshot() {
	local initial_meta='{"number":23601,"title":"stale tier","state":"OPEN","labels":[{"name":"tier:simple"},{"name":"auto-dispatch"}],"assignees":[],"body":"brief"}'
	local refreshed_meta
	reset_gh_issue_view_calls
	refreshed_meta=$(_refresh_issue_meta_after_tier_body_shape_check "23601" "marcusquinn/aidevops" "$initial_meta")

	local resolved_tier
	local calls
	resolved_tier=$(printf '%s' "$refreshed_meta" | jq -r '.labels | map(.name) | join(",")')
	calls=$(count_gh_issue_view_calls)
	if [[ "$resolved_tier" == "tier:standard,auto-dispatch" && "$calls" -eq 1 ]]; then
		print_result "refreshes original tier:simple metadata to post-validator labels" 0
		return 0
	fi
	print_result "refreshes original tier:simple metadata to post-validator labels" 1 \
		"Expected refreshed tier:standard labels and one gh_issue_view call; got labels='${resolved_tier}' calls=${calls}"
	return 0
}

test_skips_refresh_when_original_snapshot_not_tier_simple() {
	local initial_meta='{"number":23601,"title":"standard tier","state":"OPEN","labels":[{"name":"tier:standard"},{"name":"auto-dispatch"}],"assignees":[],"body":"brief"}'
	local refreshed_meta
	reset_gh_issue_view_calls
	refreshed_meta=$(_refresh_issue_meta_after_tier_body_shape_check "23601" "marcusquinn/aidevops" "$initial_meta")

	local calls
	calls=$(count_gh_issue_view_calls)
	if [[ "$refreshed_meta" == "$initial_meta" && "$calls" -eq 0 ]]; then
		print_result "skips gh refresh for non-tier:simple snapshots" 0
		return 0
	fi
	print_result "skips gh refresh for non-tier:simple snapshots" 1 \
		"Expected original metadata and zero gh_issue_view calls; calls=${calls}"
	return 0
}

main() {
	LOGFILE="$(mktemp)"
	GH_ISSUE_VIEW_CALLS_FILE="$(mktemp)"
	export LOGFILE
	export GH_ISSUE_VIEW_CALLS_FILE

	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_refreshes_precheck_tier_simple_snapshot
	test_skips_refresh_when_original_snapshot_not_tier_simple

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
