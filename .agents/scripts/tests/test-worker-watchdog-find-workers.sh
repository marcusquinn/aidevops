#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-worker-watchdog-find-workers.sh — Regression test for t2921 (GH#21091)
#
# Verifies find_workers in worker-watchdog-detect.sh handles the
# WORKER_PROCESS_PATTERN alternation introduced in t2421/PR #20126
# (`opencode|claude|Claude` in shared-constants.sh:1088).
#
# The historical pattern used basic `grep "$bracket_trick_pattern"` which
# silently failed on alternation:
#   - basic regex treats `|` as literal -> pattern matched nothing
#   - watchdog became silent no-op (last log entry 2026-04-20 17:14:18)
#
# This test catches regression of:
#   1. Missing `-E` flag on the worker-binary grep
#   2. Self-match where the grep pipeline appears in its own ps output
#   3. False positives on processes lacking `/full-loop` (interactive opencode)
#   4. False positives on the watchdog's own ps line
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

# Build a stub `ps` whose canned output exercises the filter chain.
# The fixture rows are documented inline so future regressions land
# exactly the row they violate.
write_ps_stub() {
	local stub_dir="$1"
	cat >"${stub_dir}/ps" <<'STUB'
#!/usr/bin/env bash
# Stub ps for find_workers regression test (t2921).
# Ignore all flags — find_workers only cares about pid,command output.
#
# PIDs picked to be mutually non-substring (no "1000" inside "41000")
# so simple glob assertions cannot false-positive.
printf '%s\n' \
	'81234 bash /Users/u/.aidevops/agents/scripts/headless-runtime-helper.sh run --role worker /full-loop Implement issue #1 --model anthropic/claude-sonnet-4-6' \
	'82345 node /opt/homebrew/bin/opencode run --print-logs /full-loop Implement issue #2' \
	'83456 /opt/homebrew/lib/node_modules/opencode-ai/bin/.opencode run /full-loop Implement issue #3' \
	'84567 /opt/homebrew/bin/claude run /full-loop Implement issue #4' \
	'70001 /Applications/Claude.app/Contents/MacOS/Claude' \
	'70002 grep -E opencode|claude|Claude' \
	'70003 bash /home/u/.aidevops/agents/scripts/worker-watchdog.sh --check' \
	'70004 /opt/homebrew/bin/opencode' \
	'70005 /bin/zsh -l -i -c opencode' \
	'70006 sshd: user@pts/0' \
	''
STUB
	chmod +x "${stub_dir}/ps"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	write_ps_stub "$TEST_ROOT"
	export PATH="${TEST_ROOT}:${ORIGINAL_PATH}"
	# Stub _get_process_age so find_workers does not need real PIDs.
	_get_process_age() { echo 123; }
	export -f _get_process_age
	# Source shared-constants for WORKER_PROCESS_PATTERN.
	# shellcheck source=/dev/null
	source "${LIB_DIR}/shared-constants.sh" >/dev/null 2>&1
	# Source the detect lib under test.
	# shellcheck source=/dev/null
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
