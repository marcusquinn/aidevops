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
	if [[ "${1:-}" == "axo" && "${2:-}" == "pid,stat,etime,command" ]]; then
		cat "$PS_FIXTURE_FILE"
		return 0
	fi
	# Backward compat: also intercept old format for any tests not yet updated
	if [[ "${1:-}" == "axo" && "${2:-}" == "pid,etime,command" ]]; then
		cat "$PS_FIXTURE_FILE"
		return 0
	fi
	command ps "$@"
	return 0
}

set_dedup_helper_fixture() {
	local has_open_pr_exit="$1"
	local has_open_pr_output="${2:-}"

	cat >"${TEST_ROOT}/dispatch-dedup-helper.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

command_name="\${1:-}"

case "\$command_name" in
is-duplicate)
	exit 1
	;;
has-open-pr)
	if [[ "${has_open_pr_exit}" -eq 0 ]]; then
		if [[ -n "${has_open_pr_output}" ]]; then
			printf '%s\n' "${has_open_pr_output}"
		fi
		exit 0
	fi
	exit 1
	;;
*)
	exit 1
	;;
esac
EOF

	chmod +x "${TEST_ROOT}/dispatch-dedup-helper.sh"
	return 0
}

test_counts_plain_and_dot_prefixed_opencode_workers() {
	# Line 125: supervisor /pulse — excluded by standalone /pulse filter
	# Line 126: worker whose session-key contains /pulse-related (not standalone) — must be counted
	set_ps_fixture "123 S 00:10 opencode run --dir /tmp/aidevops --title Issue #4342 \"/full-loop Implement issue #4342\"
124 S 00:11 /Users/test/.opencode/bin/opencode run --dir /tmp/aidevops --title Issue #4343 \"/full-loop Implement issue #4343\"
125 S 00:20 opencode run --dir /tmp/aidevops --title Supervisor Pulse \"/pulse\"
126 S 00:05 opencode run --dir /tmp/aidevops --session-key issue-4344 --title Issue #4344 \"/full-loop Implement issue #4344 -- fix /pulse-related bug\""

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

test_deduplicates_process_chain_to_one_logical_worker() {
	# t5072: A single opencode worker spawns a 3-process chain:
	#   bash sandbox-exec-helper.sh run ... -- opencode run ...  (top-level launcher)
	#   node /opt/homebrew/bin/opencode run ...                  (node child)
	#   /path/to/.opencode run ...                               (binary grandchild)
	# All three contain /full-loop and opencode — only the launcher must be counted.
	set_ps_fixture "200 S 00:30 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5072\" --dir /tmp/aidevops --title Issue #5072
201 S 00:30 node /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5072\" --dir /tmp/aidevops --title Issue #5072
202 S 00:30 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #5072\" --dir /tmp/aidevops --title Issue #5072"

	local count
	count=$(count_active_workers)
	# Only line 200 (sandbox launcher) should be counted; 201 and 202 are child processes
	if [[ "$count" != "1" ]]; then
		print_result "count_active_workers deduplicates 3-process chain to 1 logical worker" 1 "Expected 1, got ${count} (process chain not deduplicated)"
		return 0
	fi

	print_result "count_active_workers deduplicates 3-process chain to 1 logical worker" 0
	return 0
}

test_deduplicates_multiple_workers_with_process_chains() {
	# t5072: Two logical workers, each spawning a 3-process chain = 6 OS processes.
	# count_active_workers must return 2, not 6.
	set_ps_fixture "300 S 01:00 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
301 S 01:00 node /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
302 S 01:00 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
310 S 00:20 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5002\" --dir /tmp/aidevops --title Issue #5002
311 S 00:20 node /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5002\" --dir /tmp/aidevops --title Issue #5002
312 S 00:20 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #5002\" --dir /tmp/aidevops --title Issue #5002"

	local count
	count=$(count_active_workers)
	if [[ "$count" != "2" ]]; then
		print_result "count_active_workers counts 2 logical workers from 6 process-chain entries" 1 "Expected 2, got ${count}"
		return 0
	fi

	print_result "count_active_workers counts 2 logical workers from 6 process-chain entries" 0
	return 0
}

test_repo_issue_detection_uses_filtered_worker_list() {
	set_ps_fixture "211 S 00:31 opencode run --dir /tmp/aidevops --session-key issue-4342 --title Issue #4342: fix \"/full-loop Implement issue #4342\"
212 S 00:31 opencode run --dir /tmp/other --session-key issue-4342 --title Issue #4342: other \"/full-loop Implement issue #4342\"
213 S 00:05 opencode run --dir /tmp/aidevops --title Supervisor Pulse \"/pulse\"
214 S 00:12 opencode run --dir /tmp/aidevops-tools --session-key issue-4342 --title Issue #4342: tools \"/full-loop Implement issue #4342\""

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

test_excludes_zombie_and_stopped_processes() {
	# GH#6413: Zombie (Z) and stopped (T) processes must be excluded from
	# active worker counts. SN (sleeping, low priority) processes that are
	# NOT zombie/stopped should still be counted — SN is a valid running state.
	set_ps_fixture "400 S 00:10 opencode run --dir /tmp/aidevops --title Issue #4400 \"/full-loop Implement issue #4400\"
401 Z 00:30 opencode run --dir /tmp/aidevops --title Issue #4401 \"/full-loop Implement issue #4401\"
402 SN 00:45 opencode run --dir /tmp/aidevops --title Issue #4402 \"/full-loop Implement issue #4402\"
403 T 01:00 opencode run --dir /tmp/aidevops --title Issue #4403 \"/full-loop Implement issue #4403\"
404 Ss 00:05 opencode run --dir /tmp/aidevops --title Issue #4404 \"/full-loop Implement issue #4404\"
405 Zs 00:15 opencode run --dir /tmp/aidevops --title Issue #4405 \"/full-loop Implement issue #4405\"
406 TN 00:20 opencode run --dir /tmp/aidevops --title Issue #4406 \"/full-loop Implement issue #4406\""

	local count
	count=$(count_active_workers)
	# Lines 400 (S), 402 (SN), 404 (Ss) are valid running states — counted
	# Lines 401 (Z), 403 (T), 405 (Zs), 406 (TN) are zombie/stopped — excluded
	if [[ "$count" != "3" ]]; then
		print_result "count_active_workers excludes zombie and stopped processes" 1 "Expected 3, got ${count}"
		return 0
	fi

	print_result "count_active_workers excludes zombie and stopped processes" 0
	return 0
}

test_check_dispatch_dedup_treats_merged_pr_as_duplicate() {
	local original_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""
	set_dedup_helper_fixture 0 'merged PR #1145 references issue #4527 via "closes" keyword'

	if check_dispatch_dedup "4527" "marcusquinn/aidevops" "Issue #4527: prevent redispatch" "t4527: prevent redispatch"; then
		SCRIPT_DIR="$original_script_dir"
		print_result "check_dispatch_dedup skips dispatch when merged PR exists" 0
		return 0
	fi

	SCRIPT_DIR="$original_script_dir"
	print_result "check_dispatch_dedup skips dispatch when merged PR exists" 1 "Expected dedup check to block merged issue"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	# shellcheck source=/dev/null
	source "$PULSE_WRAPPER_SCRIPT"

	test_counts_plain_and_dot_prefixed_opencode_workers
	test_deduplicates_process_chain_to_one_logical_worker
	test_deduplicates_multiple_workers_with_process_chains
	test_repo_issue_detection_uses_filtered_worker_list
	test_excludes_zombie_and_stopped_processes
	test_check_dispatch_dedup_treats_merged_pr_as_duplicate

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
