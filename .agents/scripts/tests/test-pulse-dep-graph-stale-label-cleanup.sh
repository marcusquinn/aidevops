#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25922: resolved dependencies should retire stale
# direct issue-number blocker labels even when the issue is already available.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
DEP_GRAPH="${SCRIPT_DIR}/../pulse-dep-graph.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""
STATUS_LOG=""
GH_LABELS_CSV=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name" >&2
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message" >&2
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

reset_logs() {
	: >"$GH_LOG"
	: >"$STATUS_LOG"
	return 0
}

setup_test() {
	TEST_ROOT=$(mktemp -d)
	GH_LOG="${TEST_ROOT}/gh.log"
	STATUS_LOG="${TEST_ROOT}/status.log"
	LOGFILE="${TEST_ROOT}/pulse.log"
	DEP_GRAPH_CACHE_FILE="${TEST_ROOT}/dep-graph.json"
	DEP_GRAPH_CACHE_TTL_SECS=300
	export LOGFILE DEP_GRAPH_CACHE_FILE DEP_GRAPH_CACHE_TTL_SECS
	reset_logs
	return 0
}

teardown_test() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

gh() {
	local top_command="${1:-}"
	shift || true
	if [[ "$top_command" == "issue" ]]; then
		local issue_command="${1:-}"
		shift || true
		case "$issue_command" in
		view)
			local issue_num="${1:-}"
			shift || true
			if [[ "$*" == *"--json labels"* ]]; then
				printf '%s\n' "$GH_LABELS_CSV"
				return 0
			fi
			if [[ "$*" == *"--json comments"* ]]; then
				printf '\n'
				return 0
			fi
			printf 'unsupported issue view %s %s\n' "$issue_num" "$*" >&2
			return 1
			;;
		edit)
			printf 'issue edit %s\n' "$*" >>"$GH_LOG"
			return 0
			;;
		esac
	fi
	printf 'unsupported gh %s %s\n' "$top_command" "$*" >&2
	return 1
}

set_issue_status() {
	local issue_num="$1"
	local repo_slug="$2"
	local status_name="$3"
	printf 'set_issue_status %s %s %s\n' "$issue_num" "$repo_slug" "$status_name" >>"$STATUS_LOG"
	return 0
}

assert_log_contains() {
	local test_name="$1"
	local file_path="$2"
	local expected="$3"
	local text=""
	if [[ -f "$file_path" ]]; then
		text=$(tr '\n' ' ' <"$file_path")
	fi
	if [[ "$text" == *"$expected"* ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "expected ${expected}; got ${text}"
	return 0
}

assert_log_not_contains() {
	local test_name="$1"
	local file_path="$2"
	local unexpected="$3"
	local text=""
	if [[ -f "$file_path" ]]; then
		text=$(tr '\n' ' ' <"$file_path")
	fi
	if [[ "$text" != *"$unexpected"* ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "unexpected ${unexpected}; got ${text}"
	return 0
}

test_label_only_blocker_enters_graph() {
	local issue_json acc_json result nums
	issue_json='{"number":3,"title":"t003: child","body":"No body blockers.","labels":[{"name":"blocked-by:#2"},{"name":"auto-dispatch"}]}'
	acc_json='{"open_nums":[],"task_to_issue":{},"blocked_by_map":{},"defer_flags_map":{}}'
	result=$(_dep_graph_process_issue_json "$issue_json" "$acc_json")
	nums=$(printf '%s' "$result" | jq -r '.blocked_by_map["3"].issue_nums | join(",")')
	[[ "$nums" == "2" ]] && print_result "label-only blocker enters dep graph" 0 || print_result "label-only blocker enters dep graph" 1 "$result"
	return 0
}

test_available_issue_stale_label_removed() {
	local entry_json
	entry_json='{"task_ids":[],"issue_nums":["2"],"has_defer_marker":false}'
	GH_LABELS_CSV='status:available,auto-dispatch,blocked-by:#2'
	reset_logs
	if _refresh_try_unblock_issue "example/repo" "3" "$entry_json" '{}'; then
		print_result "available issue cleanup returns changed" 0
	else
		print_result "available issue cleanup returns changed" 1
	fi
	assert_log_contains "available issue removes stale label" "$GH_LOG" "--remove-label blocked-by:#2"
	assert_log_not_contains "available issue does not change status" "$STATUS_LOG" "set_issue_status"
	return 0
}

test_blocked_issue_label_removed_and_status_available() {
	local entry_json
	entry_json='{"task_ids":[],"issue_nums":["2"],"has_defer_marker":false}'
	GH_LABELS_CSV='status:blocked,auto-dispatch,blocked-by:#2'
	reset_logs
	_refresh_try_unblock_issue "example/repo" "3" "$entry_json" '{}' >/dev/null
	assert_log_contains "blocked issue removes stale label" "$GH_LOG" "--remove-label blocked-by:#2"
	assert_log_contains "blocked issue status set available" "$STATUS_LOG" "set_issue_status 3 example/repo available"
	return 0
}

test_defer_marker_preserves_label() {
	local entry_json
	entry_json='{"task_ids":[],"issue_nums":["2"],"has_defer_marker":true}'
	GH_LABELS_CSV='status:blocked,auto-dispatch,blocked-by:#2'
	reset_logs
	if _refresh_try_unblock_issue "example/repo" "3" "$entry_json" '{}'; then
		print_result "defer marker returns skipped" 1
	else
		print_result "defer marker returns skipped" 0
	fi
	assert_log_not_contains "defer marker preserves label" "$GH_LOG" "--remove-label blocked-by:#2"
	assert_log_not_contains "defer marker preserves status" "$STATUS_LOG" "set_issue_status"
	return 0
}

setup_test
trap teardown_test EXIT

# shellcheck source=/dev/null
source "$DEP_GRAPH"

test_label_only_blocker_enters_graph
test_available_issue_stale_label_removed
test_blocked_issue_label_removed_and_status_available
test_defer_marker_preserves_label

printf '\nTests run: %s\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	printf 'Tests failed: %s\n' "$TESTS_FAILED" >&2
	exit 1
fi

printf 'All pulse dep-graph stale label cleanup tests passed.\n'
exit 0
