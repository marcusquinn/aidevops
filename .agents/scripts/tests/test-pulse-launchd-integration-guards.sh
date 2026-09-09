#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/test-pulse-launchd-integration.sh"
TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$1"
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

test_skip_requires_no_macos_service() {
	local output
	output=$(bash "$RUNNER") || return 1
	[[ "$output" == *'SKIP: real launchd integration requires explicit --run'* ]]
}

test_help_and_unknown_options() {
	bash "$RUNNER" --help | grep -Fq 'Usage:' || return 1
	if bash "$RUNNER" --unexpected >/dev/null 2>&1; then return 1; fi
}

test_source_is_production_backed_and_owned() {
	grep -Fq 'setup/modules/schedulers-pulse.sh' "$RUNNER" || return 1
	grep -Fq 'scripts/pulse-lifecycle-helper.sh' "$RUNNER" || return 1
	grep -Fq '_install_pulse_launchd' "$RUNNER" || return 1
	grep -Fq '_pulse_start_managed' "$RUNNER" || return 1
	grep -Fq 'com.aidevops.test.pulse.' "$RUNNER" || return 1
	! grep -Fq 'com.aidevops.aidevops-supervisor-pulse' "$RUNNER"
}

test_cleanup_and_override_guards() {
	grep -Fq 'trap cleanup EXIT INT TERM' "$RUNNER" || return 1
	grep -Fq 'launchctl bootout' "$RUNNER" || return 1
	grep -Fq 'launchctl enable' "$RUNNER" || return 1
	grep -Fq 'write_recovery_record' "$RUNNER" || return 1
	grep -Fq 'unset AIDEVOPS_AGENTS_DIR' "$RUNNER" || return 1
	grep -Fq 'pgrep -f' "$RUNNER"
}

for test_name in test_skip_requires_no_macos_service test_help_and_unknown_options test_source_is_production_backed_and_owned test_cleanup_and_override_guards; do
	if "$test_name"; then pass "$test_name"; else fail "$test_name"; fi
done
printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
