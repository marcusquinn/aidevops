#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-complexity-scan-runner-standalone.sh — standalone runner bootstrap guard.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

RUNNER_FILE="${SCRIPTS_DIR}/complexity-scan-runner.sh"
SHARED_CONSTANTS_FILE="${SCRIPTS_DIR}/shared-constants.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$name"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

if [[ ! -f "$RUNNER_FILE" ]]; then
	printf '%sFATAL%s complexity-scan-runner.sh not found at %s\n' \
		"$TEST_RED" "$TEST_NC" "$RUNNER_FILE"
	exit 1
fi

printf '%sRunning complexity-scan-runner standalone tests%s\n' \
	"$TEST_GREEN" "$TEST_NC"

unset PULSE_START_EPOCH

test_home=""
test_home=$(mktemp -d)

help_stderr=$(HOME="$test_home" LC_ALL=C timeout 30 "$RUNNER_FILE" help 2>&1 >/dev/null) || true
help_exit=$(HOME="$test_home" LC_ALL=C timeout 30 "$RUNNER_FILE" help >/dev/null 2>&1; printf '%s' "$?")

if [[ "$help_exit" == "0" ]]; then
	pass "1: help exits 0 with PULSE_START_EPOCH unset"
else
	fail "1: help exits 0 with PULSE_START_EPOCH unset" \
		"exit=$help_exit, stderr=$help_stderr"
fi

if printf '%s\n' "$help_stderr" | grep -q 'unbound variable'; then
	fail "2: no unbound variable during standalone bootstrap" \
		"stderr=$help_stderr"
else
	pass "2: no unbound variable during standalone bootstrap"
fi

if grep -qE '^aidevops_ensure_pulse_start_epoch\(\) \{' "$SHARED_CONSTANTS_FILE"; then
	pass "3: shared PULSE_START_EPOCH bootstrap helper exists"
else
	fail "3: shared PULSE_START_EPOCH bootstrap helper exists" \
		"missing aidevops_ensure_pulse_start_epoch definition"
fi

if grep -qE '^aidevops_ensure_pulse_start_epoch$' "$RUNNER_FILE"; then
	pass "4: complexity runner calls shared PULSE_START_EPOCH bootstrap"
else
	fail "4: complexity runner calls shared PULSE_START_EPOCH bootstrap" \
		"missing aidevops_ensure_pulse_start_epoch call"
fi

rm -rf "$test_home"

printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	exit 1
fi

exit 0
