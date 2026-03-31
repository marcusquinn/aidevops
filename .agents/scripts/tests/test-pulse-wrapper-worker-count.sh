#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
PS_MOCK_OUTPUT=""
GH_ISSUE_LIST_JSON="[]"
GH_PR_LIST_JSON="[]"
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	# shellcheck source=/dev/null
	source "$WRAPPER_SCRIPT"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

ps() {
	printf '%s\n' "$PS_MOCK_OUTPUT"
	return 0
}

gh() {
	if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
		printf '%s\n' "$GH_ISSUE_LIST_JSON"
		return 0
	fi

	if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
		printf '%s\n' "$GH_PR_LIST_JSON"
		return 0
	fi

	if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
		printf 'owner\n'
		return 0
	fi

	printf 'unsupported gh invocation in test stub\n' >&2
	return 1
}

run_count() {
	local mock_output="$1"
	PS_MOCK_OUTPUT="$mock_output"
	count_active_workers
	return 0
}

test_counts_workers_and_ignores_supervisor_session() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101 mentions /pulse\" \"/full-loop Implement issue #101 -- pulse reliability\"
/usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse state includes /full-loop markers\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Routine\" \"/routine check\"")

	if [[ "$output" == "2" ]]; then
		print_result "counts full-loop workers without broad /pulse exclusions" 0
		return 0
	fi

	print_result "counts full-loop workers without broad /pulse exclusions" 1 "Expected 2 active workers, got '${output}'"
	return 0
}

test_returns_zero_when_no_full_loop_workers() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Routine\" \"/routine check\"")

	if [[ "$output" == "0" ]]; then
		print_result "returns zero when no matching workers exist" 0
		return 0
	fi

	print_result "returns zero when no matching workers exist" 1 "Expected 0 active workers, got '${output}'"
	return 0
}

test_does_not_exclude_non_supervisor_role_pulse_commands() {
	local output
	output=$(run_count "/usr/local/bin/.opencode run --role pulse --session-key another-session --dir /repo-a --title \"Issue #200\" \"/full-loop Implement issue #200\"")

	if [[ "$output" == "1" ]]; then
		print_result "keeps non-supervisor role pulse commands countable" 0
		return 0
	fi

	print_result "keeps non-supervisor role pulse commands countable" 1 "Expected 1 active worker, got '${output}'"
	return 0
}

# Fix #1 & #2: prefetch_active_workers must use the same filter as count_active_workers
# so the snapshot count is consistent with the global capacity counter and the
# supervisor pulse is excluded via token-boundary matching (not substring grep).
test_prefetch_active_workers_excludes_supervisor() {
	PS_MOCK_OUTPUT="1 00:01 /usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
2 00:02 /usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse state includes /full-loop markers\"
3 00:03 /usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101\" \"/full-loop Implement issue #101\""

	local prefetch_out
	prefetch_out=$(prefetch_active_workers 2>/dev/null)

	# Supervisor pulse must not appear in the snapshot
	if echo "$prefetch_out" | grep -q 'supervisor-pulse'; then
		print_result "prefetch_active_workers excludes supervisor pulse" 1 \
			"Supervisor pulse appeared in prefetch output"
		return 0
	fi

	# Both worker PIDs (1 and 3) must appear
	if echo "$prefetch_out" | grep -q 'PID 1' && echo "$prefetch_out" | grep -q 'PID 3'; then
		print_result "prefetch_active_workers excludes supervisor pulse" 0
		return 0
	fi

	print_result "prefetch_active_workers excludes supervisor pulse" 1 \
		"Expected PIDs 1 and 3 in prefetch output, got: $(echo "$prefetch_out" | grep 'PID' || echo 'none')"
	return 0
}

test_prefetch_active_workers_consistent_with_count() {
	PS_MOCK_OUTPUT="1 00:01 /usr/local/bin/.opencode run --dir /repo-a --title \"Issue #100\" \"/full-loop Implement issue #100\"
2 00:02 /usr/local/bin/.opencode run --role pulse --session-key supervisor-pulse --dir /repo-a --title \"Supervisor Pulse\" --prompt \"/pulse\"
3 00:03 /usr/local/bin/.opencode run --dir /repo-b --title \"Issue #101\" \"/full-loop Implement issue #101\""

	local count_out prefetch_worker_count
	count_out=$(count_active_workers)
	prefetch_worker_count=$(prefetch_active_workers 2>/dev/null | grep -c '^- PID' || echo "0")

	if [[ "$count_out" == "$prefetch_worker_count" ]]; then
		print_result "prefetch_active_workers count matches count_active_workers" 0
		return 0
	fi

	print_result "prefetch_active_workers count matches count_active_workers" 1 \
		"count_active_workers=${count_out}, prefetch worker lines=${prefetch_worker_count}"
	return 0
}

# Fix #3: has_worker_for_repo_issue must use exact --dir matching to prevent
# sibling-path false positives (e.g. /tmp/aidevops matching /tmp/aidevops-tools).
test_has_worker_exact_dir_match_no_sibling_false_positive() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/aidevops","pulse":true}]}\n' \
		>"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	# Sibling repo path — must NOT match
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /tmp/aidevops-tools --title \"Issue #42\" \"/full-loop Implement issue #42\""

	if has_worker_for_repo_issue "42" "owner/repo"; then
		print_result "has_worker_for_repo_issue rejects sibling-path match" 1 \
			"Sibling path /tmp/aidevops-tools incorrectly matched repo /tmp/aidevops"
		return 0
	fi

	print_result "has_worker_for_repo_issue rejects sibling-path match" 0
	return 0
}

test_has_worker_exact_dir_match_accepts_correct_path() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/aidevops","pulse":true}]}\n' \
		>"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	# Exact repo path — must match
	PS_MOCK_OUTPUT="/usr/local/bin/.opencode run --dir /tmp/aidevops --title \"Issue #42\" \"/full-loop Implement issue #42\""

	if has_worker_for_repo_issue "42" "owner/repo"; then
		print_result "has_worker_for_repo_issue accepts exact path match" 0
		return 0
	fi

	print_result "has_worker_for_repo_issue accepts exact path match" 1 \
		"Exact path /tmp/aidevops was not matched"
	return 0
}

test_counts_review_issue_pr_workers() {
	# GH#12374: /review-issue-pr workers must be counted alongside /full-loop workers.
	local output
	output=$(run_count "/usr/local/bin/.opencode run --dir /repo-a --title \"Issue #300\" \"/review-issue-pr Review issue #300\"
/usr/local/bin/.opencode run --dir /repo-b --title \"Issue #301\" \"/full-loop Implement issue #301\"
/usr/local/bin/.opencode run --dir /repo-c --title \"Issue #302\" \"/review-issue-pr Review issue #302\"")

	if [[ "$output" == "3" ]]; then
		print_result "counts /review-issue-pr workers alongside /full-loop (GH#12374)" 0
		return 0
	fi

	print_result "counts /review-issue-pr workers alongside /full-loop (GH#12374)" 1 "Expected 3 active workers, got '${output}'"
	return 0
}

test_list_dispatchable_candidates_include_passive_assignees() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"maintainer":"maintainer-bot"}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":1,"title":"unassigned","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"priority:high"}]},
	  {"number":2,"title":"owner assigned","updatedAt":"2026-03-31T00:01:00Z","assignees":[{"login":"owner"}],"labels":[{"name":"quality-debt"}]},
	  {"number":3,"title":"maintainer assigned","updatedAt":"2026-03-31T00:02:00Z","assignees":[{"login":"maintainer-bot"}],"labels":[{"name":"simplification-debt"}]},
	  {"number":4,"title":"runner assigned","updatedAt":"2026-03-31T00:03:00Z","assignees":[{"login":"other-runner"}],"labels":[{"name":"priority:high"}]},
	  {"number":5,"title":"owner queued","updatedAt":"2026-03-31T00:04:00Z","assignees":[{"login":"owner"}],"labels":[{"name":"status:queued"}]},
	  {"number":6,"title":"needs review","updatedAt":"2026-03-31T00:05:00Z","assignees":[],"labels":[{"name":"needs-maintainer-review"}]},
	  {"number":7,"title":"supervisor telemetry","updatedAt":"2026-03-31T00:06:00Z","assignees":[],"labels":[{"name":"supervisor"}]}
	]'
	GH_PR_LIST_JSON='[]'

	local output
	output=$(list_dispatchable_issue_candidates "owner/repo" 100)

	if [[ "$output" == *$'1|unassigned'* && "$output" == *$'2|owner assigned'* && "$output" == *$'3|maintainer assigned'* && "$output" != *$'4|runner assigned'* && "$output" != *$'5|owner queued'* && "$output" != *$'6|needs review'* && "$output" != *$'7|supervisor telemetry'* ]]; then
		print_result "list_dispatchable_issue_candidates includes passive assignees only" 0
		return 0
	fi

	print_result "list_dispatchable_issue_candidates includes passive assignees only" 1 "Unexpected candidate set: ${output}"
	return 0
}

test_count_runnable_candidates_counts_passive_assignee_backlog() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"maintainer":"maintainer-bot"}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":1,"title":"unassigned","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[]},
	  {"number":2,"title":"owner assigned","updatedAt":"2026-03-31T00:01:00Z","assignees":[{"login":"owner"}],"labels":[]},
	  {"number":3,"title":"maintainer assigned","updatedAt":"2026-03-31T00:02:00Z","assignees":[{"login":"maintainer-bot"}],"labels":[]},
	  {"number":4,"title":"runner assigned","updatedAt":"2026-03-31T00:03:00Z","assignees":[{"login":"other-runner"}],"labels":[]}
	]'
	GH_PR_LIST_JSON='[
	  {"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[]},
	  {"reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"FAILURE"}]}
	]'

	local count
	count=$(count_runnable_candidates)

	if [[ "$count" == "5" ]]; then
		print_result "count_runnable_candidates counts passive assignee backlog" 0
		return 0
	fi

	print_result "count_runnable_candidates counts passive assignee backlog" 1 "Expected 5 runnable items, got '${count}'"
	return 0
}

test_count_runnable_candidates_keeps_stdout_numeric_with_debug() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true,"maintainer":"maintainer-bot"}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":1,"title":"unassigned","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[]}
	]'
	GH_PR_LIST_JSON='[
	  {"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[]}
	]'

	local count stderr_file
	stderr_file="${TEST_ROOT}/count-runnable-debug.stderr"
	PULSE_DEBUG=1 count=$(count_runnable_candidates 2>"$stderr_file")

	if [[ "$count" == "2" ]] && grep -q 'count_runnable_candidates repo=owner/repo issues=1 prs=1 total=2' "$stderr_file"; then
		print_result "count_runnable_candidates keeps stdout numeric with debug enabled" 0
		return 0
	fi

	print_result "count_runnable_candidates keeps stdout numeric with debug enabled" 1 \
		"Expected numeric stdout 2 with stderr debug log; got count='${count}', stderr='$(tr '\n' '|' <"$stderr_file")'"
	return 0
}

test_count_queued_without_worker_keeps_stdout_numeric_with_debug() {
	local repos_json_path="${HOME}/.config/aidevops/repos.json"
	mkdir -p "$(dirname "$repos_json_path")"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"/tmp/repo","pulse":true}]}\n' >"$repos_json_path"
	REPOS_JSON="$repos_json_path"

	GH_ISSUE_LIST_JSON='[
	  {"number":11,"assignees":[]}
	]'
	has_worker_for_repo_issue() {
		return 1
	}

	local count stderr_file
	stderr_file="${TEST_ROOT}/count-queued-debug.stderr"
	PULSE_DEBUG=1 count=$(count_queued_without_worker 2>"$stderr_file")
	unset -f has_worker_for_repo_issue

	if [[ "$count" == "1" ]] && grep -q 'count_queued_without_worker repo=owner/repo queued=1' "$stderr_file" && grep -q 'count_queued_without_worker repo=owner/repo issue=11 missing_worker=true' "$stderr_file"; then
		print_result "count_queued_without_worker keeps stdout numeric with debug enabled" 0
		return 0
	fi

	print_result "count_queued_without_worker keeps stdout numeric with debug enabled" 1 \
		"Expected numeric stdout 1 with stderr debug logs; got count='${count}', stderr='$(tr '\n' '|' <"$stderr_file")'"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_counts_workers_and_ignores_supervisor_session
	test_returns_zero_when_no_full_loop_workers
	test_does_not_exclude_non_supervisor_role_pulse_commands
	test_prefetch_active_workers_excludes_supervisor
	test_prefetch_active_workers_consistent_with_count
	test_has_worker_exact_dir_match_no_sibling_false_positive
	test_has_worker_exact_dir_match_accepts_correct_path
	test_counts_review_issue_pr_workers
	test_list_dispatchable_candidates_include_passive_assignees
	test_count_runnable_candidates_counts_passive_assignee_backlog
	test_count_runnable_candidates_keeps_stdout_numeric_with_debug
	test_count_queued_without_worker_keeps_stdout_numeric_with_debug

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
