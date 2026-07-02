#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#26113/GH#26127: gh-failure-miner must not cluster GitHub
# runner-echoed shell comments as failure signatures.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_equals() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected: %s\n' "$(printf '%q' "$expected")"
		printf '  actual:   %s\n' "$(printf '%q' "$actual")"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="$SCRIPT_DIR/gh-failure-miner-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf '%sFATAL%s: %s not found\n' "$TEST_RED" "$TEST_NC" "$HELPER" >&2
	exit 1
fi

set -- help
# shellcheck source=/dev/null
source "$HELPER" >/dev/null

gh() {
	local first="${1:-}" second="${2:-}" endpoint="${3:-}"
	if [[ "$first" == "api" && "$endpoint" == "repos/marcusquinn/aidevops/actions/runs/28472942857/jobs" ]]; then
		printf '%s\n' '{"jobs":[{"id":84390104069,"conclusion":"failure","check_run_url":"https://api.github.com/repos/marcusquinn/aidevops/check-runs/84390104069","steps":[{"name":"Gate result","conclusion":"failure"}]}]}'
		return 0
	fi
	if [[ "$first" == "run" && "$second" == "view" ]]; then
		printf 'gate / review-bot-gate\tUNKNOWN STEP\t2026-06-30T20:14:24.8559907Z\t\033[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.\033[0m\n'
		printf 'gate / review-bot-gate\tGate result\t2026-06-30T20:14:25.0000000Z\t::error::No AI review bots have posted a real, settled review on this PR yet.\n'
		return 0
	fi
	return 1
}

signature=$(extract_failure_signature "marcusquinn/aidevops" "28472942857" "84390104069")
assert_equals "runner-echoed shell comment is skipped" "gate / review-bot-gate Gate result 2026-06-30T20:14:25.0000000Z ::error::No AI review bots have posted a real, settled review on this PR yet." "$signature"

filtered=$(filter_signature_noise_lines $'job\tUNKNOWN STEP\ttime\t\033[36;1m# comment cannot merge\033[0m\njob\tStep\ttime\treal error')
assert_equals "comment-only log lines are filtered" $'job\tStep\ttime\treal error' "$filtered"

filtered=$(filter_signature_noise_lines $'job\tUNKNOWN STEP\ttime\t+ # rate-limit grace is disabled — they cannot merge on rate-limit-only.\njob\tStep\ttime\treal error')
assert_equals "xtrace-prefixed shell comments are filtered" $'job\tStep\ttime\treal error' "$filtered"

filtered=$(filter_signature_noise_lines $'gate / review-bot-gate\tUNKNOWN STEP\t2026-06-30T20:14:24.8559907Z\t\033[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.\033[0m')
signature=$(normalize_signature_line "$filtered")
assert_equals "GH#26127 comment-only systemic signature normalizes empty" "no_error_signature_detected" "$signature"

filtered=$(filter_signature_noise_lines $'2026-06-30T20:14:24.8559907Z \033[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.\033[0m\n2026-06-30T20:14:25.0000000Z ::error::No AI review bots have posted a real, settled review on this PR yet.')
assert_equals "GH#26144 timestamp-prefixed shell comments are filtered" $'2026-06-30T20:14:25.0000000Z ::error::No AI review bots have posted a real, settled review on this PR yet.' "$filtered"

filtered=$(filter_signature_noise_lines $'gate / review-bot-gate\tUNKNOWN STEP\t2026-07-02T07:13:54.3733546Z\t^[[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.^[[0m')
signature=$(normalize_signature_line "$filtered")
assert_equals "GH#26308 caret-escaped ANSI comment-only signature normalizes empty" "no_error_signature_detected" "$signature"

signature=$(normalize_signature_line $'^[[36;1m# rate-limit grace is disabled — they cannot merge on rate-limit-only.^[[0m')
assert_equals "GH#26308 caret-escaped ANSI is stripped during normalization" "# rate-limit grace is disabled — they cannot merge on rate-limit-only." "$signature"

printf '\nTests run: %s, failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	exit 1
fi
exit 0
