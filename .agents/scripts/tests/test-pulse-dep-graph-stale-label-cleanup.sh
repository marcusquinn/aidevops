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
	DEP_GRAPH_REFRESH_CURSOR_DIR="${TEST_ROOT}/refresh-cursors"
	export LOGFILE DEP_GRAPH_CACHE_FILE DEP_GRAPH_CACHE_TTL_SECS DEP_GRAPH_REFRESH_CURSOR_DIR
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
	if [[ "$top_command" == "api" ]]; then
		printf 'api|%s|%s|%s|%s\n' \
			"${AIDEVOPS_GH_QUOTA_COST:-}" \
			"${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" \
			"${AIDEVOPS_GH_ROUTE_DECISION:-}" "$*" >>"$GH_LOG"
	fi
	if [[ "$top_command" == "api" && "${1:-}" == "graphql" ]]; then
		printf '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[{"number":2,"state":"%s"}],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}\n' "${GH_NATIVE_STATE:-CLOSED}"
		return 0
	fi
	if [[ "$top_command" == "api" && "${1:-}" == "repos/example/repo" ]]; then
		printf '%s\n' R_example
		return 0
	fi
	if [[ "$top_command" == "api" && "${1:-}" == repos/example/repo/issues/*/comments\?per_page=100 ]]; then
		printf '%s\n' "${GH_COMMENTS_JSON:-[[]]}"
		return 0
	fi
	if [[ "$top_command" == "api" && "${1:-}" == repos/example/repo/issues/* ]]; then
		local issue_num="${1##*/}"
		printf '%s\tI_%s\n' "$issue_num" "$issue_num"
		return 0
	fi
	if [[ "$top_command" == "issue" ]]; then
		local issue_command="${1:-}"
		shift || true
		case "$issue_command" in
		view)
			local issue_num="${1:-}"
			shift || true
			if [[ "$*" == *"--json labels"* ]]; then
				printf 'labels %s\n' "$issue_num" >>"$GH_LOG"
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

test_unvalidated_repository_fails_closed() {
	if _dep_validate_issue_target "local/only" "3"; then
		print_result "unvalidated dependency repository fails closed" 1
	else
		print_result "unvalidated dependency repository fails closed" 0
	fi
	return 0
}

test_repository_identity_is_cached() {
	local api_calls=0 line=""
	_DEP_CACHED_REPO_SLUG=""
	_DEP_CACHED_REPO_ID=""
	reset_logs
	_dep_validate_issue_target "example/repo" "3"
	_dep_validate_issue_target "example/repo" "4"
	while IFS= read -r line; do
		if [[ "$line" == *'|repos/example/repo --jq .node_id // ""' ]]; then
			api_calls=$((api_calls + 1))
		fi
	done <"$GH_LOG"
	[[ "$api_calls" -eq 1 ]] && print_result "repository identity is cached" 0 || print_result "repository identity is cached" 1 "expected 1 API call; got ${api_calls}"
	assert_log_contains "issue identity uses exact-cost REST" "$GH_LOG" \
		"api|1||pulse-dep-issue-identity-rest|repos/example/repo/issues/3"
	assert_log_not_contains "issue identity avoids native GraphQL view" "$GH_LOG" \
		"--json id,number"
	return 0
}

test_native_relationships_use_response_cost() {
	local rc=0
	reset_logs
	_blocked_by_check_native_relationships "example/repo" "3" || rc=$?
	if [[ "$rc" -eq 2 ]]; then
		print_result "closed native relationship resolves positively" 0
	else
		print_result "closed native relationship resolves positively" 1 "expected rc=2; got ${rc}"
	fi
	assert_log_contains "native relationship query reports response-owned cost" "$GH_LOG" \
		"api||1|pulse-blocked-by-exact-cost|graphql"
	return 0
}

test_complete_native_relationships_override_stale_body_numbers() {
	local entry_json='{"task_ids":[],"issue_nums":["999"],"has_defer_marker":false}'
	if _refresh_dependency_is_resolved "example/repo" "3" "$entry_json" '{}' '[]' '[999]'; then
		print_result "complete native relationships override stale body issue numbers" 0
	else
		print_result "complete native relationships override stale body issue numbers" 1
	fi
	return 0
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
	assert_log_contains "blocked issue status set available" "$GH_LOG" "--remove-label status:blocked --add-label status:available"
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

test_brief_hold_preserves_dependency_labels() {
	local entry_json='{"task_ids":[],"issue_nums":["2"],"has_defer_marker":false}'
	GH_LABELS_CSV='status:blocked,auto-dispatch,blocked-by:#2'
	issue_brief_hold_blocks_auto_release() { return 0; }
	reset_logs
	_refresh_try_unblock_issue "example/repo" "3" "$entry_json" '{}' >/dev/null || true
	assert_log_not_contains "brief hold preserves dependency label" "$GH_LOG" "--remove-label blocked-by:#2"
	assert_log_not_contains "brief hold preserves blocked status" "$STATUS_LOG" "set_issue_status"
	unset -f issue_brief_hold_blocks_auto_release
	return 0
}

# GH#34055: traversal fixtures run in subshells so their cheap candidate mocks
# never replace the real safety guards exercised above and below.
refresh_fixture() {
	local entry='{"task_ids":[],"issue_nums":["2"],"has_defer_marker":false}'
	jq -cn --argjson entry "$entry" '{repos:{"example/repo":{closed_issues:[2],known_issues:[2],blocked_by:{"2":$entry,"10":$entry,"11":$entry}},"example/second":{blocked_by:{"2":$entry,"10":$entry,"11":$entry}}}}' >"$DEP_GRAPH_CACHE_FILE"
	DEP_GRAPH_REFRESH_CURSOR_DIR="${TEST_ROOT}/cursor-${TESTS_RUN}"
	DEP_GRAPH_REFRESH_MAX_CANDIDATES=1
	DEP_GRAPH_REFRESH_BUDGET_SECS=30
	reset_logs
	return 0
}

mock_refresh_candidates() {
	_refresh_dependency_is_resolved() { return 0; }
	_refresh_try_unblock_issue() {
		local slug="$1" issue="$2"
		printf '%s:%s\n' "$slug" "$issue" >>"$STATUS_LOG"
		# Simulate an abrupt process exit during a later candidate, not a clean
		# batch stop. Earlier candidates must already be on disk.
		[[ "${INTERRUPT_REFRESH:-}" != "$issue" ]] || exit 73
		SECONDS=$((SECONDS + ${ADVANCE_REFRESH_SECONDS:-0}))
		return 1
	}
	return 0
}

test_refresh_batches() {
	if (
		refresh_fixture
		mock_refresh_candidates
		refresh_blocked_status_from_graph
		[[ "$(_refresh_graph_cursor_read "$DEP_GRAPH_REFRESH_CURSOR_DIR/example/repo.cursor")" == 2 ]] || exit 1
		[[ "$(_refresh_graph_cursor_read "$DEP_GRAPH_REFRESH_CURSOR_DIR/example/second.cursor")" == 2 ]] || exit 1
		refresh_blocked_status_from_graph
		[[ "$(_refresh_graph_cursor_read "$DEP_GRAPH_REFRESH_CURSOR_DIR/example/repo.cursor")" == 10 ]] || exit 1
		refresh_blocked_status_from_graph
		[[ "$(_refresh_graph_cursor_read "$DEP_GRAPH_REFRESH_CURSOR_DIR/example/repo.cursor")" == 0 ]] || exit 1
		[[ "$(tr '\n' ' ' <"$STATUS_LOG")" == 'example/repo:2 example/second:2 example/repo:10 example/second:10 example/repo:11 example/second:11 ' ]] || exit 1
		reset_logs
		refresh_blocked_status_from_graph
		[[ "$(tr '\n' ' ' <"$STATUS_LOG")" == 'example/repo:2 example/second:2 ' ]]
	); then
		print_result "bounded numeric traversal reaches later entries in every repo and wraps" 0
	else
		print_result "bounded numeric traversal reaches later entries in every repo and wraps" 1
	fi
	return 0
}

test_refresh_interruption() {
	if (
		refresh_fixture
		mock_refresh_candidates
		DEP_GRAPH_REFRESH_MAX_CANDIDATES=10
		local rc=0
		(
			INTERRUPT_REFRESH=10
			refresh_blocked_status_from_graph
		) || rc=$?
		[[ "$rc" == 73 ]] || exit 1
		[[ "$(_refresh_graph_cursor_read "$DEP_GRAPH_REFRESH_CURSOR_DIR/example/repo.cursor")" == 2 ]] || exit 1
		reset_logs
		refresh_blocked_status_from_graph
		[[ "$(tr '\n' ' ' <"$STATUS_LOG")" == 'example/repo:10 example/repo:11 example/second:2 example/second:10 example/second:11 ' ]]
	); then
		print_result "abrupt interruption resumes after durably completed candidate" 0
	else
		print_result "abrupt interruption resumes after durably completed candidate" 1
	fi
	return 0
}

test_refresh_elapsed_budget() {
	if (
		refresh_fixture
		mock_refresh_candidates
		DEP_GRAPH_REFRESH_MAX_CANDIDATES=10
		DEP_GRAPH_REFRESH_BUDGET_SECS=2
		ADVANCE_REFRESH_SECONDS=5
		refresh_blocked_status_from_graph
		[[ "$(tr '\n' ' ' <"$STATUS_LOG")" == 'example/repo:2 example/second:2 ' ]] || exit 1
		[[ "$(tr '\n' ' ' <"$LOGFILE")" == *'visited=1 blocked=0 unblocked=0 batch_limit=10 budget_secs=1 complete=false cursor_write_failed=false'* ]]
	); then
		print_result "elapsed budget stops new work but gives later repos a fair share" 0
	else
		print_result "elapsed budget stops new work but gives later repos a fair share" 1
	fi
	return 0
}

test_refresh_cursor_validation() {
	local value="" file="${TEST_ROOT}/invalid.cursor" failed=0
	for value in '-1' '01' '1e9' '999999999999999999999' '../escape' 'broken'; do
		printf '%s\n' "$value" >"$file"
		[[ "$(_refresh_graph_cursor_read "$file")" == 0 ]] || failed=1
	done
	_refresh_graph_cursor_file '../escape' >/dev/null && failed=1
	_refresh_graph_cursor_file 'example/..' >/dev/null && failed=1
	_refresh_graph_cursor_write "$file" '01' && failed=1
	print_result "cursor rejects corrupt decimals and unsafe repository paths" "$failed"
	return 0
}

test_refresh_cursor_write_failure() {
	if (
		refresh_fixture
		mock_refresh_candidates
		DEP_GRAPH_REFRESH_MAX_CANDIDATES=10
		printf 'not a directory\n' >"$DEP_GRAPH_REFRESH_CURSOR_DIR"
		refresh_blocked_status_from_graph
		[[ "$(tr '\n' ' ' <"$STATUS_LOG")" == 'example/repo:2 example/second:2 ' ]] || exit 1
		[[ "$(tr '\n' ' ' <"$LOGFILE")" == *'complete=false cursor_write_failed=true'* ]]
	); then
		print_result "cursor persistence failure is reported and stops each batch" 0
	else
		print_result "cursor persistence failure is reported and stops each batch" 1
	fi
	return 0
}

test_refresh_preserves_guards() {
	local entry='{"task_ids":[],"issue_nums":["2"],"has_defer_marker":false}'
	local data=""
	data=$(jq -cn --argjson entry "$entry" '{closed_issues:[2],known_issues:[2],blocked_by:{"3":$entry}}')
	DEP_GRAPH_REFRESH_CURSOR_DIR="${TEST_ROOT}/guard-cursors"
	GH_LABELS_CSV='status:blocked,status:in-progress,blocked-by:#2'
	reset_logs
	_refresh_graph_repo "example/repo" "$data" 10 30
	assert_log_not_contains "refresh preserves active lifecycle status" "$GH_LOG" '--add-label status:available'
	GH_LABELS_CSV='status:blocked,blocked-by:#2'
	GH_COMMENTS_JSON='[[{"author_association":"COLLABORATOR","body":"**BLOCKED** — cannot proceed autonomously. Evidence: permission required"}]]'
	reset_logs
	_refresh_graph_repo "example/repo" "$data" 10 30
	assert_log_not_contains "refresh preserves trusted comment hold" "$GH_LOG" 'issue edit'
	unset GH_COMMENTS_JSON
	GH_NATIVE_STATE=OPEN
	reset_logs
	_refresh_graph_repo "example/repo" "$data" 10 30
	assert_log_not_contains "refresh preserves unresolved dependencies" "$GH_LOG" 'issue edit'
	unset GH_NATIVE_STATE
	return 0
}

setup_test
trap teardown_test EXIT

# shellcheck source=/dev/null
source "$DEP_GRAPH"

test_label_only_blocker_enters_graph
test_unvalidated_repository_fails_closed
test_repository_identity_is_cached
test_native_relationships_use_response_cost
test_complete_native_relationships_override_stale_body_numbers
test_available_issue_stale_label_removed
test_blocked_issue_label_removed_and_status_available
test_defer_marker_preserves_label
test_brief_hold_preserves_dependency_labels
test_refresh_batches
test_refresh_interruption
test_refresh_elapsed_budget
test_refresh_cursor_validation
test_refresh_cursor_write_failure
test_refresh_preserves_guards

printf '\nTests run: %s\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	printf 'Tests failed: %s\n' "$TESTS_FAILED" >&2
	exit 1
fi

printf 'All pulse dep-graph stale label cleanup tests passed.\n'
exit 0
