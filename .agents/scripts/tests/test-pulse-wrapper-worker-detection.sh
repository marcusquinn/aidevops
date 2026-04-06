#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

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

test_has_worker_for_repo_issue_session_key_fallback() {
	# GH#6453: When get_repo_path_by_slug returns empty (slug not in repos.json),
	# has_worker_for_repo_issue must fall back to matching by --session-key.
	# This prevents false-negatives that cause the backfill cycle to re-dispatch
	# already-running workers.
	local original_repos_json="$REPOS_JSON"

	# Use a repos.json that does NOT contain the slug being tested
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/other-repo",
      "path": "/tmp/other-repo"
    }
  ]
}
JSON

	# Worker process with --session-key issue-6426 but slug not in repos.json
	set_ps_fixture "500 S 00:15 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- opencode run \"/full-loop Implement issue #6426\" --dir /tmp/aidevops --session-key issue-6426 --title Issue #6426"

	# Should detect the worker via session-key fallback even though slug is not in repos.json
	if ! has_worker_for_repo_issue "6426" "marcusquinn/aidevops"; then
		REPOS_JSON="$original_repos_json"
		print_result "has_worker_for_repo_issue session-key fallback detects worker when slug not in repos.json" 1 "Expected worker match via session-key fallback"
		return 0
	fi

	# Should not match a different issue number
	if has_worker_for_repo_issue "9999" "marcusquinn/aidevops"; then
		REPOS_JSON="$original_repos_json"
		print_result "has_worker_for_repo_issue session-key fallback rejects wrong issue number" 1 "Expected no match for issue 9999"
		return 0
	fi

	REPOS_JSON="$original_repos_json"
	print_result "has_worker_for_repo_issue session-key fallback detects worker when slug not in repos.json" 0
	print_result "has_worker_for_repo_issue session-key fallback rejects wrong issue number" 0
	return 0
}

test_counts_standalone_opencode_binary_workers() {
	# GH#12361: Workers dispatched via headless-runtime-helper.sh without
	# sandbox-exec-helper.sh run as /bin/.opencode processes directly.
	# These must be counted as active workers, not excluded.
	set_ps_fixture "600 S 00:15 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #12361\" --dir /tmp/aidevops --session-key issue-12361 --title Issue #12361
601 S 00:20 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #12362\" --dir /tmp/aidevops --session-key issue-12362 --title Issue #12362
602 S 00:25 opencode run --dir /tmp/aidevops --title Issue #12363 \"/full-loop Implement issue #12363\""

	local count
	count=$(count_active_workers)
	# All three are standalone workers (no sandbox launcher) — all must be counted
	if [[ "$count" != "3" ]]; then
		print_result "count_active_workers counts standalone /bin/.opencode workers (GH#12361)" 1 "Expected 3, got ${count}"
		return 0
	fi

	print_result "count_active_workers counts standalone /bin/.opencode workers (GH#12361)" 0
	return 0
}

test_counts_headless_runtime_helper_wrapper_without_child_process() {
	# GH#14944: The live worker may be visible only as the outer
	# headless-runtime-helper.sh wrapper before/without an opencode child in ps.
	set_ps_fixture "650 S 00:18 bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key issue-14944 --dir /tmp/aidevops --title Issue #14944 --prompt-file /tmp/pulse-14944.prompt"

	local count output
	count=$(count_active_workers)
	if [[ "$count" != "1" ]]; then
		print_result "count_active_workers counts wrapper-only headless-runtime-helper worker (GH#14944)" 1 "Expected 1, got ${count}"
		return 0
	fi

	output=$(list_active_worker_processes)
	if ! echo "$output" | grep -q "^650 "; then
		print_result "count_active_workers counts wrapper-only headless-runtime-helper worker (GH#14944)" 1 "Expected wrapper PID 650 in output"
		return 0
	fi

	print_result "count_active_workers counts wrapper-only headless-runtime-helper worker (GH#14944)" 0
	return 0
}

test_deduplicates_headless_runtime_helper_wrapper_with_child_processes() {
	# GH#14944: Wrapper + sandbox + opencode child chain should count as one
	# logical worker, keeping the outer headless-runtime-helper wrapper PID.
	set_ps_fixture "660 S 00:20 bash /Users/test/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker --session-key issue-14944 --dir /tmp/aidevops --title Issue #14944 --prompt-file /tmp/pulse-14944.prompt
661 S 00:19 bash /Users/test/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #14944\" --dir /tmp/aidevops --session-key issue-14944 --title Issue #14944
662 S 00:19 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #14944\" --dir /tmp/aidevops --session-key issue-14944 --title Issue #14944"

	local count output
	count=$(count_active_workers)
	if [[ "$count" != "1" ]]; then
		print_result "count_active_workers deduplicates headless-runtime-helper wrapper with children (GH#14944)" 1 "Expected 1, got ${count}"
		return 0
	fi

	output=$(list_active_worker_processes)
	if ! echo "$output" | grep -q "^660 "; then
		print_result "count_active_workers deduplicates headless-runtime-helper wrapper with children (GH#14944)" 1 "Expected wrapper PID 660 in output"
		return 0
	fi
	if echo "$output" | grep -q "^661 \|^662 "; then
		print_result "count_active_workers deduplicates headless-runtime-helper wrapper with children (GH#14944)" 1 "Expected child PIDs 661/662 to be deduplicated away"
		return 0
	fi

	print_result "count_active_workers deduplicates headless-runtime-helper wrapper with children (GH#14944)" 0
	return 0
}

test_deduplicates_chain_but_keeps_standalone_opencode_binary() {
	# GH#12361: Mix of sandbox-launched chain and standalone /bin/.opencode worker.
	# The chain (issue #5001) should deduplicate to 1; the standalone (issue #12361)
	# should be kept — total 2 logical workers.
	set_ps_fixture "700 S 01:00 bash /home/user/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io -- /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
701 S 01:00 node /opt/homebrew/bin/opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
702 S 01:00 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #5001\" --dir /tmp/aidevops --title Issue #5001
710 S 00:15 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #12361\" --dir /tmp/aidevops --session-key issue-12361 --title Issue #12361"

	local count
	count=$(count_active_workers)
	if [[ "$count" != "2" ]]; then
		print_result "count_active_workers deduplicates chain but keeps standalone /bin/.opencode worker" 1 "Expected 2, got ${count}"
		return 0
	fi

	# Verify the sandbox launcher (PID 700) is kept for the chain, not the binary child
	local output
	output=$(list_active_worker_processes)
	if ! echo "$output" | grep -q "^700 "; then
		print_result "count_active_workers deduplicates chain but keeps standalone /bin/.opencode worker" 1 "Expected sandbox launcher PID 700 in output"
		return 0
	fi
	# Verify the standalone worker (PID 710) is kept
	if ! echo "$output" | grep -q "^710 "; then
		print_result "count_active_workers deduplicates chain but keeps standalone /bin/.opencode worker" 1 "Expected standalone worker PID 710 in output"
		return 0
	fi

	print_result "count_active_workers deduplicates chain but keeps standalone /bin/.opencode worker" 0
	return 0
}

test_counts_review_issue_pr_workers() {
	# GH#12374: Workers running /review-issue-pr must be counted by
	# count_active_workers, not just /full-loop workers.
	set_ps_fixture "800 S 00:10 opencode run --dir /tmp/aidevops --title Issue #9001 \"/review-issue-pr Review issue #9001\"
801 S 00:20 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run \"/full-loop Implement issue #9002\" --dir /tmp/aidevops --session-key issue-9002 --title Issue #9002
802 S 00:15 opencode run --dir /tmp/aidevops --title Issue #9003 \"/review-issue-pr Review issue #9003\""

	local count
	count=$(count_active_workers)
	# 2 review-issue-pr + 1 full-loop = 3 workers
	if [[ "$count" != "3" ]]; then
		print_result "count_active_workers counts /review-issue-pr workers (GH#12374)" 1 "Expected 3, got ${count}"
		return 0
	fi

	print_result "count_active_workers counts /review-issue-pr workers (GH#12374)" 0
	return 0
}

test_review_issue_pr_session_key_fallback_dedup() {
	# GH#12374 CodeRabbit feedback: /review-issue-pr workers may not carry
	# "Issue #NNN" markers but DO have --session-key issue-NNN. The dedup_key
	# extraction must fall back to --session-key so these workers are
	# deduplicated and counted correctly.
	set_ps_fixture "900 S 00:10 opencode run --dir /tmp/aidevops --session-key issue-9010 --title review-9010 \"/review-issue-pr 9010\"
901 S 00:10 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run --dir /tmp/aidevops --session-key issue-9010 --title review-9010 \"/review-issue-pr 9010\"
902 S 00:15 opencode run --dir /tmp/aidevops --session-key issue-9011 --title review-9011 \"/review-issue-pr 9011\""

	local count
	count=$(count_active_workers)
	# PIDs 900+901 share session-key issue-9010 + same --dir → deduplicate to 1
	# PID 902 is a separate worker (issue-9011) → 1
	# Total: 2
	if [[ "$count" != "2" ]]; then
		print_result "review-issue-pr session-key fallback deduplicates correctly (GH#12374)" 1 "Expected 2, got ${count}"
		return 0
	fi

	print_result "review-issue-pr session-key fallback deduplicates correctly (GH#12374)" 0
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

test_dispatch_with_dedup_blocks_when_duplicate() {
	local original_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""
	# Dedup helper returns 0 for has-open-pr → duplicate detected → check_dispatch_dedup returns 0
	set_dedup_helper_fixture 0 'merged PR #1145 references issue #9999 via "closes" keyword'

	local dispatch_rc=0
	dispatch_with_dedup "9999" "marcusquinn/aidevops" "Issue #9999: test dedup" "t9999: test dedup" \
		"testuser" "/tmp/aidevops" "/full-loop test" || dispatch_rc=$?

	SCRIPT_DIR="$original_script_dir"

	if [[ "$dispatch_rc" -eq 1 ]]; then
		print_result "dispatch_with_dedup blocks when dedup detects duplicate (GH#12436)" 0
		return 0
	fi

	print_result "dispatch_with_dedup blocks when dedup detects duplicate (GH#12436)" 1 \
		"Expected exit 1 (blocked), got ${dispatch_rc}"
	return 0
}

test_dispatch_with_dedup_fails_closed_when_issue_metadata_missing() {
	local original_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""

	# Stub gh issue view to fail so metadata cannot be loaded.
	gh() {
		if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
			return 1
		fi
		return 0
	}
	export -f gh

	local dispatch_rc=0
	dispatch_with_dedup "7777" "marcusquinn/aidevops" "Issue #7777: fail-closed" "t7777: fail-closed" \
		"testuser" "/tmp/aidevops" "/full-loop test" || dispatch_rc=$?

	SCRIPT_DIR="$original_script_dir"
	unset -f gh

	if [[ "$dispatch_rc" -eq 1 ]]; then
		print_result "dispatch_with_dedup fails closed when issue metadata lookup fails (GH#14409)" 0
		return 0
	fi

	print_result "dispatch_with_dedup fails closed when issue metadata lookup fails (GH#14409)" 1 \
		"Expected exit 1 (blocked), got ${dispatch_rc}"
	return 0
}

test_dispatch_with_dedup_proceeds_when_no_duplicate() {
	local original_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""

	# Create a dedup helper that passes all layers (no duplicate):
	# - is-duplicate → exit 1 (no match)
	# - has-open-pr → exit 1 (no PR)
	# - has-dispatch-comment → exit 1 (no comment)
	# - is-assigned → exit 1 (not assigned)
	# - claim → exit 0 (claim won)
	cat >"${TEST_ROOT}/dispatch-dedup-helper.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1:-}"
case "$command_name" in
claim) exit 0 ;;
*) exit 1 ;;
esac
FIXTURE
	chmod +x "${TEST_ROOT}/dispatch-dedup-helper.sh"

	# Create a no-op HEADLESS_RUNTIME_HELPER stub so the worker launch succeeds
	local original_helper="$HEADLESS_RUNTIME_HELPER"
	HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-stub.sh"
	cat >"$HEADLESS_RUNTIME_HELPER" <<'STUB'
#!/usr/bin/env bash
# Stub: do nothing, exit immediately
exit 0
STUB
	chmod +x "$HEADLESS_RUNTIME_HELPER"

	# Create dispatch-ledger-helper.sh stub:
	# check-issue → exit 1 (no in-flight entry, layer 1 passes)
	# record → exit 0 (success, used after dispatch)
	cat >"${TEST_ROOT}/dispatch-ledger-helper.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
check-issue) exit 1 ;;
*) exit 0 ;;
esac
STUB
	chmod +x "${TEST_ROOT}/dispatch-ledger-helper.sh"

	# Stub gh to avoid real API calls
	gh() {
		if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
			printf '{"state":"OPEN","title":"t8888: test pass","labels":[]}\n'
			return 0
		fi
		return 0
	}
	export -f gh

	local dispatch_rc=0
	dispatch_with_dedup "8888" "marcusquinn/aidevops" "Issue #8888: test pass" "t8888: test pass" \
		"testuser" "/tmp/aidevops" "/full-loop test" || dispatch_rc=$?

	# Restore
	HEADLESS_RUNTIME_HELPER="$original_helper"
	SCRIPT_DIR="$original_script_dir"
	unset -f gh

	if [[ "$dispatch_rc" -eq 0 ]]; then
		print_result "dispatch_with_dedup proceeds when no duplicate detected (GH#12436)" 0
		return 0
	fi

	print_result "dispatch_with_dedup proceeds when no duplicate detected (GH#12436)" 1 \
		"Expected exit 0 (dispatched), got ${dispatch_rc}"
	return 0
}

test_dispatch_with_dedup_detaches_worker_stdio() {
	local original_script_dir="$SCRIPT_DIR"
	local original_helper="$HEADLESS_RUNTIME_HELPER"
	local stdin_capture="${TEST_ROOT}/worker-stdin.txt"
	local issue_log="/tmp/pulse-marcusquinn-aidevops-8890.log"
	local fallback_log="/tmp/pulse-8890.log"
	SCRIPT_DIR="$TEST_ROOT"

	rm -f "$stdin_capture" "$issue_log" "$fallback_log"
	set_ps_fixture ""

	cat >"${TEST_ROOT}/dispatch-dedup-helper.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1:-}"
case "$command_name" in
claim) exit 0 ;;
*) exit 1 ;;
esac
FIXTURE
	chmod +x "${TEST_ROOT}/dispatch-dedup-helper.sh"

	cat >"${TEST_ROOT}/dispatch-ledger-helper.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
check-issue) exit 1 ;;
*) exit 0 ;;
esac
STUB
	chmod +x "${TEST_ROOT}/dispatch-ledger-helper.sh"

	HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-stdin-stub.sh"
	cat >"$HEADLESS_RUNTIME_HELPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cat >"${stdin_capture}"
printf 'stub worker output\n'
exit 0
EOF
	chmod +x "$HEADLESS_RUNTIME_HELPER"

	gh() {
		if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
			printf '{"state":"OPEN","title":"t8890: stdio detach","labels":[]}\n'
			return 0
		fi
		return 0
	}
	export -f gh

	local dispatch_rc=0
	dispatch_with_dedup "8890" "marcusquinn/aidevops" "Issue #8890: stdio detach" "t8890: stdio detach" \
		"testuser" "/tmp/aidevops" "/full-loop test" <<<"candidate-stream-must-not-leak" || dispatch_rc=$?

	local stdin_contents=""
	if [[ -f "$stdin_capture" ]]; then
		stdin_contents=$(tr '\n' ' ' <"$stdin_capture")
	fi
	local issue_log_contents=""
	if [[ -f "$issue_log" ]]; then
		issue_log_contents=$(tr '\n' ' ' <"$issue_log")
	fi

	HEADLESS_RUNTIME_HELPER="$original_helper"
	SCRIPT_DIR="$original_script_dir"
	unset -f gh
	rm -f "$issue_log" "$fallback_log"

	if [[ "$dispatch_rc" -eq 0 && -z "$stdin_contents" && "$issue_log_contents" == *"stub worker output"* ]]; then
		print_result "dispatch_with_dedup detaches stdin and captures worker output to issue log (GH#14483)" 0
		return 0
	fi

	print_result "dispatch_with_dedup detaches stdin and captures worker output to issue log (GH#14483)" 1 \
		"dispatch_rc=${dispatch_rc}, stdin='${stdin_contents}', issue_log='${issue_log_contents}'"
	return 0
}

test_dispatch_with_dedup_passes_explicit_model_override() {
	local original_script_dir="$SCRIPT_DIR"
	local original_helper="$HEADLESS_RUNTIME_HELPER"
	local args_log="${TEST_ROOT}/worker-args.log"
	SCRIPT_DIR="$TEST_ROOT"

	set_ps_fixture ""
	: >"$args_log"

	cat >"${TEST_ROOT}/dispatch-dedup-helper.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
claim) exit 0 ;;
*) exit 1 ;;
esac
FIXTURE
	chmod +x "${TEST_ROOT}/dispatch-dedup-helper.sh"

	cat >"${TEST_ROOT}/dispatch-ledger-helper.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
check-issue) exit 1 ;;
*) exit 0 ;;
esac
STUB
	chmod +x "${TEST_ROOT}/dispatch-ledger-helper.sh"

	HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-model-stub.sh"
	cat >"$HEADLESS_RUNTIME_HELPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >"${args_log}"
exit 0
EOF
	chmod +x "$HEADLESS_RUNTIME_HELPER"

	gh() {
		if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
			printf '{"state":"OPEN","title":"t8891: model override","labels":[{"name":"tier:simple"}]}'
			return 0
		fi
		return 0
	}
	export -f gh

	local dispatch_rc=0
	dispatch_with_dedup "8891" "marcusquinn/aidevops" "Issue #8891: model override" "t8891: model override" \
		"testuser" "/tmp/aidevops" "/full-loop test" "issue-8891" "anthropic/claude-haiku-4-5" || dispatch_rc=$?

	local args_contents=""
	if [[ -f "$args_log" ]]; then
		args_contents=$(tr '\n' ' ' <"$args_log")
	fi

	HEADLESS_RUNTIME_HELPER="$original_helper"
	SCRIPT_DIR="$original_script_dir"
	unset -f gh

	if [[ "$dispatch_rc" -eq 0 && "$args_contents" == *"--model anthropic/claude-haiku-4-5"* ]]; then
		print_result "dispatch_with_dedup forwards explicit model override to worker launch" 0
		return 0
	fi

	print_result "dispatch_with_dedup forwards explicit model override to worker launch" 1 \
		"dispatch_rc=${dispatch_rc}, args='${args_contents}'"
	return 0
}

test_build_ranked_dispatch_candidates_json_scores_candidates() {
	local original_repos_json="$REPOS_JSON"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true,
      "priority": "tooling",
      "maintainer": "marcusquinn"
    },
    {
      "slug": "awardsapp/awardsapp",
      "path": "/tmp/awardsapp",
      "pulse": true,
      "priority": "product",
      "maintainer": "marcusquinn"
    }
  ]
}
JSON

	gh() {
		if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
			if [[ "${4:-}" == "marcusquinn/aidevops" ]]; then
				printf '%s\n' '[
				  {"number":7001,"title":"tooling simplification","url":"https://github.com/marcusquinn/aidevops/issues/7001","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"simplification-debt"}]},
				  {"number":7002,"title":"tooling bug","url":"https://github.com/marcusquinn/aidevops/issues/7002","updatedAt":"2026-03-31T00:01:00Z","assignees":[],"labels":[{"name":"bug"}]}
				]'
				return 0
			fi
			if [[ "${4:-}" == "awardsapp/awardsapp" ]]; then
				printf '%s\n' '[
				  {"number":8001,"title":"product simplification","url":"https://github.com/awardsapp/awardsapp/issues/8001","updatedAt":"2026-03-31T00:02:00Z","assignees":[],"labels":[{"name":"simplification-debt"}]}
				]'
				return 0
			fi
		fi
		return 1
	}
	export -f gh

	local ordered_numbers
	ordered_numbers=$(build_ranked_dispatch_candidates_json 20 | jq -r '.[].number' 2>/dev/null || true)

	unset -f gh
	REPOS_JSON="$original_repos_json"

	if [[ "$ordered_numbers" == $'7002\n8001\n7001' ]]; then
		print_result "build_ranked_dispatch_candidates_json orders bug before product simplification before tooling simplification" 0
		return 0
	fi

	print_result "build_ranked_dispatch_candidates_json orders bug before product simplification before tooling simplification" 1 \
		"Unexpected order: ${ordered_numbers}"
	return 0
}

test_dispatch_deterministic_fill_floor_dispatches_up_to_capacity() {
	local dispatch_log="${TEST_ROOT}/deterministic-dispatch.log"
	: >"$dispatch_log"

	resolve_dispatch_model_for_labels() {
		# Tier label resolution — tier:thinking is backward-compat alias for tier:reasoning
		case ",${1}," in
		*,tier:reasoning,* | *,tier:thinking,*)
			echo "anthropic/claude-opus-4-6"
			return 0
			;;
		*,tier:standard,*)
			echo "anthropic/claude-sonnet-4-6"
			return 0
			;;
		*,tier:simple,*)
			echo "anthropic/claude-haiku-4-5"
			return 0
			;;
		esac
		echo ""
		return 0
	}

	build_ranked_dispatch_candidates_json() {
		printf '%s\n' '[
		  {"number":9101,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9101","title":"candidate one","labels":["bug"],"updatedAt":"2026-03-31T00:00:00Z","score":8000},
		  {"number":9102,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9102","title":"candidate two","labels":["simplification-debt","tier:simple"],"updatedAt":"2026-03-31T00:01:00Z","score":4000},
		  {"number":9103,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9103","title":"candidate three","labels":["simplification-debt"],"updatedAt":"2026-03-31T00:02:00Z","score":4000}
		]'
	}
	get_max_workers_target() { echo 2; }
	count_active_workers() { echo 0; }
	count_runnable_candidates() { echo 3; }
	count_queued_without_worker() { echo 0; }
	check_terminal_blockers() { return 1; }
	dispatch_with_dedup() {
		printf '%s|%s\n' "$1" "${9:-}" >>"$dispatch_log"
		return 0
	}
	check_worker_launch() { return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
			printf 'testuser\n'
			return 0
		fi
		return 0
	}
	export -f gh

	local dispatch_count dispatched_numbers
	dispatch_count=$(dispatch_deterministic_fill_floor)
	dispatched_numbers=$(tr '\n' ',' <"$dispatch_log" | sed 's/,$//')

	unset -f gh build_ranked_dispatch_candidates_json get_max_workers_target count_active_workers count_runnable_candidates count_queued_without_worker check_terminal_blockers dispatch_with_dedup check_worker_launch

	if [[ "$dispatch_count" == "2" && "$dispatched_numbers" == "9101|,9102|anthropic/claude-haiku-4-5" ]]; then
		print_result "dispatch_deterministic_fill_floor dispatches ranked candidates up to capacity and honors simple-tier override" 0
		return 0
	fi

	print_result "dispatch_deterministic_fill_floor dispatches ranked candidates up to capacity and honors simple-tier override" 1 \
		"Expected count=2 and issues 9101,9102; got count=${dispatch_count}, issues=${dispatched_numbers}"
	return 0
}

test_build_ranked_dispatch_candidates_json_respects_schedule_gate() {
	local original_repos_json="$REPOS_JSON"
	cat >"${REPOS_JSON}" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "marcusquinn/aidevops",
      "path": "/tmp/aidevops",
      "pulse": true,
      "priority": "tooling"
    },
    {
      "slug": "awardsapp/awardsapp",
      "path": "/tmp/awardsapp",
      "pulse": true,
      "priority": "product"
    }
  ]
}
JSON

	check_repo_pulse_schedule() {
		[[ "$1" == "marcusquinn/aidevops" ]]
	}
	gh() {
		if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
			if [[ "${4:-}" == "marcusquinn/aidevops" ]]; then
				printf '%s\n' '[{"number":9201,"title":"allowed","url":"https://github.com/marcusquinn/aidevops/issues/9201","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"bug"}]}]'
				return 0
			fi
			if [[ "${4:-}" == "awardsapp/awardsapp" ]]; then
				printf '%s\n' '[{"number":9202,"title":"blocked by schedule","url":"https://github.com/awardsapp/awardsapp/issues/9202","updatedAt":"2026-03-31T00:00:00Z","assignees":[],"labels":[{"name":"bug"}]}]'
				return 0
			fi
		fi
		return 1
	}
	export -f gh

	local candidate_numbers
	candidate_numbers=$(build_ranked_dispatch_candidates_json 20 | jq -r '.[].number' 2>/dev/null || true)

	unset -f gh check_repo_pulse_schedule
	REPOS_JSON="$original_repos_json"

	if [[ "$candidate_numbers" == "9201" ]]; then
		print_result "build_ranked_dispatch_candidates_json skips repos outside schedule gate" 0
		return 0
	fi

	print_result "build_ranked_dispatch_candidates_json skips repos outside schedule gate" 1 \
		"Unexpected scheduled candidate set: ${candidate_numbers}"
	return 0
}

test_dispatch_deterministic_fill_floor_honors_stop_flag() {
	local dispatch_log="${TEST_ROOT}/deterministic-stop.log"
	: >"$dispatch_log"
	touch "$STOP_FLAG"

	build_ranked_dispatch_candidates_json() {
		printf '%s\n' '[{"number":9301,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9301","title":"candidate one","labels":["bug"],"updatedAt":"2026-03-31T00:00:00Z","score":8000}]'
	}
	dispatch_with_dedup() {
		printf '%s\n' "$1" >>"$dispatch_log"
		return 0
	}

	local dispatch_count dispatched_numbers
	dispatch_count=$(dispatch_deterministic_fill_floor)
	dispatched_numbers=$(tr '\n' ',' <"$dispatch_log" | sed 's/,$//')

	rm -f "$STOP_FLAG"
	unset -f build_ranked_dispatch_candidates_json dispatch_with_dedup

	if [[ "$dispatch_count" == "0" && -z "$dispatched_numbers" ]]; then
		print_result "dispatch_deterministic_fill_floor skips dispatch when stop flag is present" 0
		return 0
	fi

	print_result "dispatch_deterministic_fill_floor skips dispatch when stop flag is present" 1 \
		"Expected no dispatch with stop flag; got count=${dispatch_count}, issues=${dispatched_numbers}"
	return 0
}

test_dispatch_deterministic_fill_floor_ignores_noisy_count_output() {
	local dispatch_log="${TEST_ROOT}/deterministic-noisy-counts.log"
	: >"$dispatch_log"

	build_ranked_dispatch_candidates_json() {
		printf '%s\n' '[
		  {"number":9401,"repo_slug":"marcusquinn/aidevops","repo_path":"/tmp/aidevops","url":"https://github.com/marcusquinn/aidevops/issues/9401","title":"candidate one","labels":["bug"],"updatedAt":"2026-03-31T00:00:00Z","score":8000}
		]'
	}
	get_max_workers_target() { echo 2; }
	count_active_workers() { echo 0; }
	count_runnable_candidates() {
		printf 'DEBUG: prefetched runnable backlog\n'
		echo 5
	}
	count_queued_without_worker() {
		printf 'TRACE: queued scan complete\n'
		echo 0
	}
	check_terminal_blockers() { return 1; }
	dispatch_with_dedup() {
		printf '%s\n' "$1" >>"$dispatch_log"
		return 0
	}
	check_worker_launch() { return 0; }
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
			printf 'testuser\n'
			return 0
		fi
		return 0
	}
	export -f gh

	local dispatch_count dispatched_numbers
	dispatch_count=$(dispatch_deterministic_fill_floor)
	dispatched_numbers=$(tr '\n' ',' <"$dispatch_log" | sed 's/,$//')

	unset -f gh build_ranked_dispatch_candidates_json get_max_workers_target count_active_workers count_runnable_candidates count_queued_without_worker check_terminal_blockers dispatch_with_dedup check_worker_launch

	if [[ "$dispatch_count" == "1" && "$dispatched_numbers" == "9401" ]]; then
		print_result "dispatch_deterministic_fill_floor ignores noisy count helper output" 0
		return 0
	fi

	print_result "dispatch_deterministic_fill_floor ignores noisy count helper output" 1 \
		"Expected count=1 and issue 9401; got count=${dispatch_count}, issues=${dispatched_numbers}"
	return 0
}

test_active_pulse_refill_skips_without_idle_or_stall_signal() {
	get_max_workers_target() { echo 4; }
	count_active_workers() { echo 1; }
	count_runnable_candidates() { echo 9; }
	count_queued_without_worker() { echo 2; }
	run_underfill_worker_recycler() {
		printf 'recycler\n' >>"${TEST_ROOT}/active-refill-skip.log"
		return 0
	}
	dispatch_deterministic_fill_floor() {
		printf 'dispatch\n' >>"${TEST_ROOT}/active-refill-skip.log"
		return 0
	}

	local last_refill_epoch
	last_refill_epoch=$(maybe_refill_underfilled_pool_during_active_pulse 0 60 0 true)

	unset -f get_max_workers_target count_active_workers count_runnable_candidates count_queued_without_worker run_underfill_worker_recycler dispatch_deterministic_fill_floor

	if [[ "$last_refill_epoch" == "0" && ! -e "${TEST_ROOT}/active-refill-skip.log" ]]; then
		print_result "maybe_refill_underfilled_pool_during_active_pulse waits for idle or stall evidence" 0
		return 0
	fi

	print_result "maybe_refill_underfilled_pool_during_active_pulse waits for idle or stall evidence" 1 \
		"Expected no refill without idle/stall; got epoch=${last_refill_epoch}"
	return 0
}

test_active_pulse_refill_dispatches_when_underfilled_and_idle() {
	local action_log="${TEST_ROOT}/active-refill.log"
	: >"$action_log"
	export PULSE_ACTIVE_REFILL_INTERVAL=120

	get_max_workers_target() { echo 6; }
	count_active_workers() { echo 1; }
	count_runnable_candidates() { echo 12; }
	count_queued_without_worker() { echo 3; }
	run_underfill_worker_recycler() {
		printf 'recycler\n' >>"$action_log"
		return 0
	}
	dispatch_deterministic_fill_floor() {
		printf 'dispatch\n' >>"$action_log"
		return 0
	}

	local first_refill second_refill actions
	first_refill=$(maybe_refill_underfilled_pool_during_active_pulse 0 0 60 true)
	second_refill=$(maybe_refill_underfilled_pool_during_active_pulse "$first_refill" 0 60 true)
	actions=$(tr '\n' ',' <"$action_log" | sed 's/,$//')

	unset -f get_max_workers_target count_active_workers count_runnable_candidates count_queued_without_worker run_underfill_worker_recycler dispatch_deterministic_fill_floor
	unset PULSE_ACTIVE_REFILL_INTERVAL

	if [[ "$first_refill" =~ ^[0-9]+$ && "$first_refill" -gt 0 && "$second_refill" == "$first_refill" && "$actions" == "recycler,dispatch" ]]; then
		print_result "maybe_refill_underfilled_pool_during_active_pulse refills once per interval when idle" 0
		return 0
	fi

	print_result "maybe_refill_underfilled_pool_during_active_pulse refills once per interval when idle" 1 \
		"Expected one recycler+dispatch pass with cooldown; got first=${first_refill}, second=${second_refill}, actions=${actions}"
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
	test_has_worker_for_repo_issue_session_key_fallback
	test_counts_standalone_opencode_binary_workers
	test_deduplicates_chain_but_keeps_standalone_opencode_binary
	test_counts_review_issue_pr_workers
	test_review_issue_pr_session_key_fallback_dedup
	test_check_dispatch_dedup_treats_merged_pr_as_duplicate
	test_dispatch_with_dedup_blocks_when_duplicate
	test_dispatch_with_dedup_fails_closed_when_issue_metadata_missing
	test_dispatch_with_dedup_proceeds_when_no_duplicate
	test_dispatch_with_dedup_detaches_worker_stdio
	test_dispatch_with_dedup_passes_explicit_model_override
	test_build_ranked_dispatch_candidates_json_scores_candidates
	test_build_ranked_dispatch_candidates_json_respects_schedule_gate
	test_dispatch_deterministic_fill_floor_dispatches_up_to_capacity
	test_dispatch_deterministic_fill_floor_honors_stop_flag
	test_dispatch_deterministic_fill_floor_ignores_noisy_count_output
	test_active_pulse_refill_skips_without_idle_or_stall_signal
	test_active_pulse_refill_dispatches_when_underfilled_and_idle

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
