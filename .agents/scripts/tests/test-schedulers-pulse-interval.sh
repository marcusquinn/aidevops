#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Test setup scheduler pulse interval settings precedence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit
SETUP_MODULES_DIR="${REPO_SCRIPTS_DIR}/setup/modules"

# shellcheck source=../shared-constants.sh
source "${REPO_SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=../setup/modules/schedulers-pulse.sh
source "${SETUP_MODULES_DIR}/schedulers-pulse.sh"

TESTS_RUN=0
TESTS_FAILED=0
ORIGINAL_HOME="$HOME"
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_home() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	mkdir -p "$HOME/.config/aidevops"
	return 0
}

teardown_home() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	return 0
}

test_orchestration_interval_wins() {
	setup_home
	printf '%s\n' '{"orchestration":{"pulse_interval_seconds":240},"supervisor":{"pulse_interval_seconds":120}}' >"$HOME/.config/aidevops/settings.json"
	local output=""
	output=$(_read_pulse_interval_seconds)
	teardown_home

	if [[ "$output" == "240" ]]; then
		print_result "orchestration pulse interval wins" 0
	else
		print_result "orchestration pulse interval wins" 1 "Expected 240, got: $output"
	fi
	return 0
}

test_legacy_supervisor_interval_fallback() {
	setup_home
	printf '%s\n' '{"supervisor":{"pulse_interval_seconds":120}}' >"$HOME/.config/aidevops/settings.json"
	local output=""
	output=$(_read_pulse_interval_seconds)
	teardown_home

	if [[ "$output" == "120" ]]; then
		print_result "legacy supervisor pulse interval fallback" 0
	else
		print_result "legacy supervisor pulse interval fallback" 1 "Expected 120, got: $output"
	fi
	return 0
}

test_default_interval_is_180() {
	setup_home
	local output=""
	output=$(_read_pulse_interval_seconds)
	teardown_home

	if [[ "$output" == "180" ]]; then
		print_result "default pulse interval is 180" 0
	else
		print_result "default pulse interval is 180" 1 "Expected 180, got: $output"
	fi
	return 0
}

main() {
	printf 'Running scheduler pulse interval tests...\n\n'
	test_orchestration_interval_wins
	test_legacy_supervisor_interval_fallback
	test_default_interval_is_180

	printf '\n%s/%s tests passed.\n' \
		"$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
