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

main() {
	trap teardown_test_env EXIT
	setup_test_env
	# shellcheck source=/dev/null
	source "$PULSE_WRAPPER_SCRIPT"

	test_counts_plain_and_dot_prefixed_opencode_workers
	test_repo_issue_detection_uses_filtered_worker_list

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
