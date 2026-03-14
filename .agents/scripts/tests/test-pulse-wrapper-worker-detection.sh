#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PULSE_WRAPPER_SCRIPT="${SCRIPT_DIR}/../pulse-wrapper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
PS_FIXTURE_FILE=""
GH_SEARCH_FIXTURES=""

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
	PS_FIXTURE_FILE="${TEST_ROOT}/ps-fixture.txt"
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"

	export REPOS_JSON="${TEST_ROOT}/repos.json"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops"
    }
  ]
}
JSON

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

set_ps_fixture() {
	local content="$1"
	printf '%s\n' "$content" >"$PS_FIXTURE_FILE"
	return 0
}

ps() {
	if [[ "${1:-}" == "axo" && "${2:-}" == "pid,etime,command" ]]; then
		cat "$PS_FIXTURE_FILE"
		return 0
	fi
	command ps "$@"
	return 0
}

set_gh_search_fixtures() {
	local fixtures="$1"
	GH_SEARCH_FIXTURES="$fixtures"
	return 0
}

gh() {
	if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
		local repo_slug="" state_filter="" search_query=""
		shift 2
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--repo)
				repo_slug="${2:-}"
				shift 2
				;;
			--state)
				state_filter="${2:-}"
				shift 2
				;;
			--search)
				search_query="${2:-}"
				shift 2
				;;
			*)
				shift
				;;
			esac
		done

		# Fail loudly if the function under test omits --repo, --state, or --search
		if [[ -z "$repo_slug" || -z "$state_filter" || -z "$search_query" ]]; then
			printf 'unexpected gh pr list args in test stub: repo=%s state=%s search=%s\n' \
				"$repo_slug" "$state_filter" "$search_query" >&2
			return 1
		fi

		local compound_key="${repo_slug}|${state_filter}|${search_query}"
		local line fixture_key fixture_payload
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			# Fixture format: repo|state|query|payload
			# Strip last field to get the compound key; last field is the payload
			fixture_key="${line%|*}"
			fixture_payload="${line##*|}"
			if [[ "$fixture_key" == "$compound_key" ]]; then
				printf '%s\n' "$fixture_payload"
				return 0
			fi
		done <<<"$GH_SEARCH_FIXTURES"

		printf '[]\n'
		return 0
	fi

	command gh "$@"
	return 0
}

test_counts_plain_and_dot_prefixed_opencode_workers() {
	# Line 125: supervisor /pulse — excluded by standalone /pulse filter
	# Line 126: worker whose session-key contains /pulse-related (not standalone) — must be counted
	set_ps_fixture "123 00:10 opencode run --dir /tmp/aidevops --title Issue #4342 \"/full-loop Implement issue #4342\"
124 00:11 /Users/test/.opencode/bin/opencode run --dir /tmp/aidevops --title Issue #4343 \"/full-loop Implement issue #4343\"
125 00:20 opencode run --dir /tmp/aidevops --title Supervisor Pulse \"/pulse\"
126 00:05 opencode run --dir /tmp/aidevops --session-key issue-4344 --title Issue #4344 \"/full-loop Implement issue #4344 -- fix /pulse-related bug\""

	local count
	count=$(count_active_workers)
	# Lines 123, 124, 126 are workers; line 125 is the supervisor /pulse (excluded)
	if [[ "$count" != "3" ]]; then
		print_result "count_active_workers excludes supervisor /pulse but counts worker with /pulse in args" 1 "Expected 3, got ${count}"
		return 0
	fi

	print_result "count_active_workers excludes supervisor /pulse but counts worker with /pulse in args" 0
	return 0
}

test_repo_issue_detection_uses_filtered_worker_list() {
	set_ps_fixture "211 00:31 opencode run --dir /tmp/aidevops --session-key issue-4342 --title Issue #4342: fix \"/full-loop Implement issue #4342\"
212 00:31 opencode run --dir /tmp/other --session-key issue-4342 --title Issue #4342: other \"/full-loop Implement issue #4342\"
213 00:05 opencode run --dir /tmp/aidevops --title Supervisor Pulse \"/pulse\"
214 00:12 opencode run --dir /tmp/aidevops-tools --session-key issue-4342 --title Issue #4342: tools \"/full-loop Implement issue #4342\""

	if ! has_worker_for_repo_issue "4342" "marcusquinn/aidevops"; then
		print_result "has_worker_for_repo_issue matches scoped worker process" 1 "Expected worker match for repo issue"
		return 0
	fi

	if has_worker_for_repo_issue "9999" "marcusquinn/aidevops"; then
		print_result "has_worker_for_repo_issue rejects unrelated issues" 1 "Expected no worker match for issue 9999"
		return 0
	fi

	# Line 214 uses /tmp/aidevops-tools — a prefix of /tmp/aidevops — must NOT match
	# Add a second repo entry for aidevops-tools to verify exact path matching
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops"
    },
    {
      "slug": "marcusquinn/aidevops-tools",
      "path": "/tmp/aidevops-tools"
    }
  ]
}
JSON
	# Worker 214 is for aidevops-tools, not aidevops — should not count for aidevops
	local count_aidevops
	count_aidevops=$(list_active_worker_processes | awk -v path="/tmp/aidevops" '
		BEGIN { esc = path; gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc) }
		$0 ~ ("--dir[[:space:]]+" esc "([[:space:]]|$)") { count++ }
		END { print count + 0 }
	')
	if [[ "$count_aidevops" != "1" ]]; then
		print_result "has_worker_for_repo_issue does not match prefix-sibling repo path" 1 "Expected 1 match for /tmp/aidevops, got ${count_aidevops}"
		return 0
	fi

	print_result "has_worker_for_repo_issue matches scoped worker process" 0
	print_result "has_worker_for_repo_issue rejects unrelated issues" 0
	print_result "has_worker_for_repo_issue does not match prefix-sibling repo path" 0
	return 0
}

test_has_merged_pr_for_issue_detects_closing_keyword() {
	set_gh_search_fixtures "marcusquinn/aidevops|merged|closes #4527 in:body|[{\"number\":1145}]"

	if has_merged_pr_for_issue "4527" "marcusquinn/aidevops" "t4527: prevent duplicate dispatch"; then
		print_result "has_merged_pr_for_issue detects merged PR via closes keyword" 0
		return 0
	fi

	print_result "has_merged_pr_for_issue detects merged PR via closes keyword" 1 "Expected merged PR match for issue #4527"
	return 0
}

test_has_merged_pr_for_issue_detects_task_id_fallback() {
	set_gh_search_fixtures "marcusquinn/aidevops|merged|t063.1 in:title|[{\"number\":1059}]"

	if has_merged_pr_for_issue "9999" "marcusquinn/aidevops" "t063.1: fix awardsapp duplicate PR dispatch"; then
		print_result "has_merged_pr_for_issue detects merged PR via task-id fallback" 0
		return 0
	fi

	print_result "has_merged_pr_for_issue detects merged PR via task-id fallback" 1 "Expected merged PR match via task ID fallback"
	return 0
}

test_check_dispatch_dedup_treats_merged_pr_as_duplicate() {
	set_ps_fixture ""
	set_gh_search_fixtures "marcusquinn/aidevops|merged|closes #4527 in:body|[{\"number\":1145}]"

	if check_dispatch_dedup "4527" "marcusquinn/aidevops" "Issue #4527: prevent redispatch" "t4527: prevent redispatch"; then
		print_result "check_dispatch_dedup skips dispatch when merged PR exists" 0
		return 0
	fi

	print_result "check_dispatch_dedup skips dispatch when merged PR exists" 1 "Expected dedup check to block merged issue"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	# shellcheck source=/dev/null
	source "$PULSE_WRAPPER_SCRIPT"

	test_counts_plain_and_dot_prefixed_opencode_workers
	test_repo_issue_detection_uses_filtered_worker_list
	test_has_merged_pr_for_issue_detects_closing_keyword
	test_has_merged_pr_for_issue_detects_task_id_fallback
	test_check_dispatch_dedup_treats_merged_pr_as_duplicate

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
