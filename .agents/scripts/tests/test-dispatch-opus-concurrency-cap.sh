#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#33976 regression tests for the opus concurrency cap: in-flight opus
# workers are counted once per worker process chain (sandbox wrapper,
# opencode launcher, native binary), not once per OS process.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
LIB_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-lib-candidates.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
PS_FIXTURE=""
DEBUG_LOG=""
LOGFILE=""

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

define_function_under_test() {
	local fn_name="$1"
	local fn_src
	fn_src=$(awk -v fn="$fn_name" '
		$0 ~ "^" fn "\\(\\) \\{" { capture = 1 }
		capture { print }
		capture && /^}$/ { exit }
	' "$LIB_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract %s from %s\n' "$fn_name" "$LIB_SCRIPT" >&2
		return 1
	fi
	eval "$fn_src"
	return 0
}

# Stubs for the dispatch environment.
ps() {
	printf '%s\n' "$PS_FIXTURE"
	return 0
}
id() {
	printf '501\n'
	return 0
}
pulse_dispatch_debug_log() {
	DEBUG_LOG="$1"
	return 0
}
_dispatch_stats_increment() {
	return 0
}

readonly SANDBOX='bash /Users/u/.aidevops/agents/scripts/sandbox-exec-helper.sh run --timeout 3600 --allow-secret-io --'
readonly PROMPT='/full-loop Implement issue #1 --session-key issue-1'

# Worker A: native install behind the sandbox wrapper (2 matching processes).
# Worker B: npm install — wrapper, node launcher, native .opencode (3).
# Worker C: unsandboxed v2 profile binary with a model#variant suffix (1).
three_worker_fixture() {
	printf '%s\n' \
		"501 100 50 S ${SANDBOX} /opt/homebrew/bin/opencode run ${PROMPT} -m anthropic/claude-opus-5-5 --title Issue #1 --format json --dir /w/a" \
		"501 101 100 S /opt/homebrew/bin/opencode run ${PROMPT} -m anthropic/claude-opus-5-5 --title Issue #1 --format json --dir /w/a" \
		"501 105 100 S bash --norc --noprofile -c source sandbox-watchdog /Users/u/.aidevops/agents/scripts/sandbox-exec-helper.sh 3600 101" \
		"501 200 60 S ${SANDBOX} opencode run ${PROMPT} -m anthropic/claude-opus-4-7 --dir /w/b" \
		"501 201 200 S node /usr/local/bin/opencode run ${PROMPT} -m anthropic/claude-opus-4-7 --dir /w/b" \
		"501 202 201 S /usr/local/lib/node_modules/opencode-ai/bin/.opencode run ${PROMPT} -m anthropic/claude-opus-4-7 --dir /w/b" \
		"501 300 70 S opencode2 run ${PROMPT} -m anthropic/claude-opus-5-5#high --standalone" \
		"501 400 80 S ${SANDBOX} opencode run ${PROMPT} -m anthropic/claude-sonnet-5-5 --dir /w/s" \
		"501 401 400 S opencode run ${PROMPT} -m anthropic/claude-sonnet-5-5 --dir /w/s" \
		"502 500 1 S /opt/homebrew/bin/opencode run ${PROMPT} -m anthropic/claude-opus-5-5 --dir /w/foreign" \
		"501 600 1 Z opencode run ${PROMPT} -m anthropic/claude-opus-5-5 --dir /w/zombie" \
		"501 700 1 S rg opencode.*-m anthropic/claude-opus" \
		"501 701 1 S pgrep -f opencode.*-m anthropic/claude-opus" \
		"501 800 1 S opencode -m anthropic/claude-opus-5-5"
	return 0
}

test_counts_worker_chains_not_processes() {
	local count
	count=$(three_worker_fixture | _dispatch_count_opus_worker_roots 501)
	if [[ "$count" == "3" ]]; then
		print_result "counts one per opus worker chain" 0
		return 0
	fi
	print_result "counts one per opus worker chain" 1 "expected 3, got '${count}'"
	return 0
}

test_empty_snapshot_counts_zero() {
	local count
	count=$(printf '' | _dispatch_count_opus_worker_roots 501)
	if [[ "$count" == "0" ]]; then
		print_result "empty snapshot counts zero" 0
		return 0
	fi
	print_result "empty snapshot counts zero" 1 "expected 0, got '${count}'"
	return 0
}

test_cap_admits_fourth_worker() {
	PS_FIXTURE=$(three_worker_fixture)
	DEBUG_LOG=""
	if AIDEVOPS_OPUS_CONCURRENCY_CAP=4 _dispatch_check_model_concurrency_cap 9 owner/repo anthropic/claude-opus-5-5 &&
		[[ "$DEBUG_LOG" == *"inflight=3 cap=4"* ]]; then
		print_result "cap 4 with 3 workers admits a 4th" 0
		return 0
	fi
	print_result "cap 4 with 3 workers admits a 4th" 1 "debug log: ${DEBUG_LOG}"
	return 0
}

test_cap_defers_at_limit() {
	PS_FIXTURE="$(three_worker_fixture)
501 900 90 S ${SANDBOX} opencode run ${PROMPT} -m anthropic/claude-opus-5-5 --dir /w/d
501 901 900 S opencode run ${PROMPT} -m anthropic/claude-opus-5-5 --dir /w/d"
	: >"$LOGFILE"
	if ! AIDEVOPS_OPUS_CONCURRENCY_CAP=4 _dispatch_check_model_concurrency_cap 9 owner/repo anthropic/claude-opus-5-5 &&
		grep -q 'inflight=4 cap=4' "$LOGFILE"; then
		print_result "cap 4 with 4 workers defers" 0
		return 0
	fi
	print_result "cap 4 with 4 workers defers" 1 "log: $(cat "$LOGFILE")"
	return 0
}

main() {
	define_function_under_test _dispatch_count_opus_worker_roots || return 1
	define_function_under_test _dispatch_check_model_concurrency_cap || return 1
	LOGFILE=$(mktemp)
	trap 'rm -f "$LOGFILE"' EXIT

	test_counts_worker_chains_not_processes
	test_empty_snapshot_counts_zero
	test_cap_admits_fourth_worker
	test_cap_defers_at_limit

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
