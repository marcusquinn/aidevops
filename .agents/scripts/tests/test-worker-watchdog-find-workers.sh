#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for legacy discovery (GH#21091) and managed workers
# without prose in argv (GH#35692). Exercise the real canonical inventory and
# watchdog ownership gate using synthetic process snapshots only.
#
# Stubs ps via PATH override so the test is hermetic and does not depend
# on the live system's process table.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
LIB_DIR="${SCRIPT_DIR}/.."

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_PATH="${PATH}"

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

# One synthetic snapshot includes ancestry. No live worker is inspected.
write_ps_stub() {
	local stub_dir="$1"
	cat >"${stub_dir}/ps" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" != 'axwwo uid,pid,ppid,stat,etime,command' ]]; then exit 1; fi
while read -r pid row; do
	parent=1
	case "$pid" in
	81235) parent=81234 ;;
	85679) parent=85678 ;;
	85680) parent=85679 ;;
	87891) parent=87890 ;;
	88902) parent=88901 ;;
	89013) parent=89012 ;;
	90124) parent=90123 ;;
	94568) parent=94567 ;;
	98902) parent=98901 ;;
	esac
	printf '%s %s %s %s\n' "$TEST_WORKER_UID" "$pid" "$parent" "$row"
done <<ROWS
81234 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --dir $TEST_WORKER_DIR /full-loop Implement issue #1 --model anthropic/claude-sonnet-5-5
81235 S 02:03 /bin/opencode run --dir $TEST_WORKER_DIR --title Issue #1: child
82345 S 02:03 node /bin/opencode run --dir $TEST_WORKER_DIR /full-loop Implement issue #2
83456 S 02:03 /bin/.opencode run --dir $TEST_WORKER_DIR /full-loop Implement issue #3
84567 S 02:03 /bin/claude run --dir $TEST_WORKER_DIR /full-loop GH#4
70001 S 02:03 /Applications/Claude.app/Contents/MacOS/Claude
70002 S 02:03 grep -E opencode|claude|Claude
70003 S 02:03 bash /agents/worker-watchdog.sh --check
70004 S 02:03 /bin/opencode
70005 S 02:03 /bin/zsh -l -i -c opencode
70006 S 02:03 sshd: user@pts/0
85680 S 02:03 /bin/opencode run --dir $TEST_WORKER_DIR --title Issue #5: managed
85679 S 02:03 node /bin/opencode run --dir $TEST_WORKER_DIR /full-loop Implement issue #5
85678 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --session-key issue-5 --dir $TEST_WORKER_DIR --title Issue #5: managed --model openai/example --prompt Fix worker-watchdog.sh; investigate issue #99 without changing it
86789 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --session-key issue-6 --dir $TEST_WORKER_DIR
87890 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --session-key issue-7 --dir $TEST_WORKER_DIR
88901 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --session-key issue-8 --dir $TEST_WORKER_DIR
88902 Z 02:03 /bin/opencode run --dir $TEST_WORKER_DIR --title Issue #8: zombie
89012 S 02:03 bash /agents/headless-runtime-helper.sh run --role pulse --session-key issue-9 --dir $TEST_WORKER_DIR /full-loop Implement issue #9
89013 S 02:03 /bin/opencode run --dir $TEST_WORKER_DIR /full-loop Implement issue #9
90123 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --session-key issue-10 --dir $TEST_WORKER_DIR --title Issue #11: conflicting
90124 S 02:03 /bin/opencode run --dir $TEST_WORKER_DIR /full-loop Implement issue #10
91234 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --dir $TEST_WORKER_DIR
92345 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --session-key issue-12 --dir /nonexistent-fixture
93456 T 02:03 bash /agents/headless-runtime-helper.sh run --role worker --session-key issue-13 --dir $TEST_WORKER_DIR
94568 S 02:03 /bin/opencode run --dir $TEST_WORKER_DIR /full-loop Implement issue #14
94567 S 02:03 bash /agents/headless-runtime-helper.sh run --role supervisor --session-key issue-14 --dir $TEST_WORKER_DIR --prompt /full-loop Implement issue #14 using --role worker
96789 S 02:03 /bin/opencode run example headless-runtime-helper.sh run --role worker --session-key issue-15 --dir $TEST_WORKER_DIR
97890 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --session-key issue-16 --dir $TEST_WORKER_DIR
97891 S 02:03 /bin/opencode run --dir $TEST_WORKER_DIR /full-loop Implement issue #16
98901 T 02:03 bash /agents/headless-runtime-helper.sh run --role supervisor --session-key issue-17 --dir $TEST_WORKER_DIR
98902 S 02:03 /bin/opencode run --dir $TEST_WORKER_DIR /full-loop Implement issue #17
ROWS
# A foreign user with an identical identity must not suppress the owned worker.
printf '%s\n' "99999 95678 1 S 02:03 bash /agents/headless-runtime-helper.sh run --role worker --session-key issue-5 --dir $TEST_WORKER_DIR" \
	"99999 87891 87890 S 02:03 /bin/opencode run --title Issue #7: foreign"
STUB
	chmod +x "${stub_dir}/ps"
	cat >"${stub_dir}/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "-C $TEST_WORKER_DIR remote get-url origin" ]]; then
	printf '%s\n' 'https://github.com/example/fixture.git'
	exit 0
fi
exit 1
STUB
	chmod +x "${stub_dir}/git"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export TEST_WORKER_DIR="$TEST_ROOT"
	TEST_WORKER_UID=$(id -u)
	export TEST_WORKER_UID
	write_ps_stub "$TEST_ROOT"
	export PATH="${TEST_ROOT}:${ORIGINAL_PATH}"
	# Source the real canonical process detector before overriding age lookup.
	# shellcheck source=/dev/null
	source "${LIB_DIR}/worker-lifecycle-common.sh" >/dev/null 2>&1
	# Stub _get_process_age so find_workers does not need real PIDs.
	_get_process_age() { printf '%s\n' 123; return 0; }
	export -f _get_process_age
	# Source shared-constants for WORKER_PROCESS_PATTERN.
	# shellcheck source=/dev/null
	source "${LIB_DIR}/shared-constants.sh" >/dev/null 2>&1
	# Source the detect lib under test.
	# shellcheck source=/dev/null
	SCRIPT_DIR="$LIB_DIR"
	source "${LIB_DIR}/worker-watchdog-detect.sh" >/dev/null 2>&1
	return 0
}

teardown_test_env() {
	export PATH="${ORIGINAL_PATH}"
	unset -f _get_process_age 2>/dev/null || true
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Tests
# ──────────────────────────────────────────────────────────────────────────────

test_alternation_pattern_matches_headless_with_model_flag() {
	# Bash wrapper proc carries `--model anthropic/claude-...` -> matches `claude`.
	local output
	output=$(find_workers)
	if [[ "$output" == *"81234|"* ]]; then
		print_result "alternation matches headless wrapper via --model claude (81234)" 0
		return 0
	fi
	print_result "alternation matches headless wrapper via --model claude" 1 "expected 81234 in: $output"
	return 0
}

test_alternation_pattern_matches_opencode_workers() {
	local output
	output=$(find_workers)
	if [[ "$output" == *"82345|"* && "$output" == *"83456|"* ]]; then
		print_result "alternation matches opencode workers (82345, 83456)" 0
		return 0
	fi
	print_result "alternation matches opencode workers" 1 "missing 82345/83456 in: $output"
	return 0
}

test_alternation_pattern_matches_claude_worker() {
	local output
	output=$(find_workers)
	if [[ "$output" == *"84567|"* ]]; then
		print_result "alternation matches claude worker (84567)" 0
		return 0
	fi
	print_result "alternation matches claude worker" 1 "expected 84567 in: $output"
	return 0
}

test_grep_self_excluded() {
	# The `grep -E opencode|claude|Claude` pipeline appears in its own ps view;
	# must be filtered or it self-detects and skews active-worker counts.
	local output
	output=$(find_workers)
	if [[ "$output" != *"70002|"* ]]; then
		print_result "grep -E pipeline self-match excluded (PID 70002)" 0
		return 0
	fi
	print_result "grep -E pipeline self-match excluded" 1 "PID 70002 leaked through: $output"
	return 0
}

test_watchdog_excluded() {
	# worker-watchdog.sh itself contains "opencode" in its substring search,
	# so the regex matches; the `*worker-watchdog*` skip in the loop must drop it.
	local output
	output=$(find_workers)
	if [[ "$output" != *"70003|"* ]]; then
		print_result "worker-watchdog process excluded (PID 70003)" 0
		return 0
	fi
	print_result "worker-watchdog process excluded" 1 "PID 70003 leaked through: $output"
	return 0
}

test_interactive_opencode_excluded() {
	# Bare opencode / shell launchers without `/full-loop` in argv are interactive
	# user sessions, NOT headless workers — must NOT show up.
	local output
	output=$(find_workers)
	if [[ "$output" != *"70001|"* && "$output" != *"70004|"* && "$output" != *"70005|"* ]]; then
		print_result "interactive opencode/Claude procs excluded (70001, 70004, 70005)" 0
		return 0
	fi
	print_result "interactive opencode/Claude procs excluded" 1 "leaked: $output"
	return 0
}

test_unrelated_process_excluded() {
	local output
	output=$(find_workers)
	if [[ "$output" != *"70006|"* ]]; then
		print_result "unrelated process excluded (PID 70006)" 0
		return 0
	fi
	print_result "unrelated process excluded" 1 "PID 70006 leaked: $output"
	return 0
}

test_output_shape_pid_elapsed_command() {
	local output first_line
	output=$(find_workers)
	first_line="${output%%$'\n'*}"
	# Format: PID|ELAPSED|COMMAND  with elapsed=123 from stub
	if [[ "$first_line" == *"|123|"* ]]; then
		print_result "output shape PID|ELAPSED|COMMAND honoured" 0
		return 0
	fi
	print_result "output shape PID|ELAPSED|COMMAND honoured" 1 "first line: $first_line"
	return 0
}

test_managed_worker_identity_and_attribution() {
	local output row count=0 cmd
	output=$(find_workers)
	while IFS= read -r row; do
		[[ -n "$row" ]] && count=$((count + 1))
	done <<<"$output"
	if [[ "$count" -eq 6 && "$output" == *'85678|123|'* && "$output" != *'85679|'* && "$output" != *'85680|'* && "$output" == *'97891|'* ]]; then
		print_result "managed argv without prose/prompt-file counted once; legacy workers retained" 0
	else
		print_result "managed worker deduplication" 1 "$output"
	fi
	cmd="headless-runtime-helper.sh run --role worker --session-key issue-5 --dir $TEST_WORKER_DIR --model openai/example"
	if [[ "$(extract_issue_number "$cmd")" == 5 && "$(extract_repo_slug "$cmd")" == example/fixture && "$(extract_provider_from_cmd "$cmd")" == openai ]]; then
		print_result "session-key-only task, repository and provider attribution retained" 0
	else
		print_result "managed metadata attribution" 1
	fi
	return 0
}

test_unsafe_candidates_excluded() {
	local output pid
	output=$(find_workers)
	for pid in 86789 87890 88901 89012 89013 90123 90124 91234 92345 93456 94567 94568 95678 96789 97890 98901 98902; do
		if [[ "$output" == *"${pid}|"* ]]; then
			print_result "unsafe candidate $pid excluded" 1
		else
			print_result "unsafe candidate $pid excluded" 0
		fi
	done
	return 0
}

test_worker_watchdog_script_dir_retry_present() {
	local watchdog_script="${LIB_DIR}/worker-watchdog.sh"
	if grep -qF '_resolve_script_dir_with_retry' "$watchdog_script" && \
		grep -qF 'AIDEVOPS_SCRIPT_DIR_ATTEMPTS' "$watchdog_script" && \
		grep -qF '/.aidevops/agents/scripts' "$watchdog_script"; then
		print_result "worker-watchdog retries script-dir resolution during deploy races" 0
		return 0
	fi
	print_result "worker-watchdog retries script-dir resolution during deploy races" 1 \
		"Expected retry helper and deployed-dir fallback in worker-watchdog.sh"
	return 0
}

run_all() {
	setup_test_env
	test_alternation_pattern_matches_headless_with_model_flag
	test_alternation_pattern_matches_opencode_workers
	test_alternation_pattern_matches_claude_worker
	test_grep_self_excluded
	test_watchdog_excluded
	test_interactive_opencode_excluded
	test_unrelated_process_excluded
	test_output_shape_pid_elapsed_command
	test_managed_worker_identity_and_attribution
	test_unsafe_candidates_excluded
	test_worker_watchdog_script_dir_retry_present
	teardown_test_env
	return 0
}

main() {
	run_all
	printf '\nSummary: %d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
