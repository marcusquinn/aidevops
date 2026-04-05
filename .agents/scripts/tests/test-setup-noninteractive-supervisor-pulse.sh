#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SETUP_SCRIPT="${REPO_ROOT}/setup.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

load_setup_functions() {
	local helper_definition=""
	helper_definition="$(awk '
		/^_should_setup_noninteractive_supervisor_pulse\(\) \{/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$SETUP_SCRIPT")"

	if [[ -z "$helper_definition" ]]; then
		printf 'failed to load helper from %s\n' "$SETUP_SCRIPT" >&2
		return 1
	fi

	eval "$helper_definition"
	return 0
}

test_uses_existing_installation_signal() {
	local output=""

	output=$(
		load_setup_functions
		_scheduler_detect_installed() { return 0; }
		config_enabled() { return 1; }

		if _should_setup_noninteractive_supervisor_pulse; then
			printf 'result=true\n'
		else
			printf 'result=false\n'
		fi
	) || true

	if [[ "$output" == *"result=true"* ]]; then
		print_result "non-interactive pulse setup regenerates existing scheduler" 0
		return 0
	fi

	print_result "non-interactive pulse setup regenerates existing scheduler" 1 "output=${output}"
	return 0
}

test_uses_explicit_config_consent_for_first_install() {
	local output=""

	output=$(
		load_setup_functions
		_scheduler_detect_installed() { return 1; }
		config_enabled() {
			local key="$1"
			[[ "$key" == "orchestration.supervisor_pulse" ]]
			return $?
		}

		if _should_setup_noninteractive_supervisor_pulse; then
			printf 'result=true\n'
		else
			printf 'result=false\n'
		fi
	) || true

	if [[ "$output" == *"result=true"* ]]; then
		print_result "non-interactive pulse setup honors explicit config consent" 0
		return 0
	fi

	print_result "non-interactive pulse setup honors explicit config consent" 1 "output=${output}"
	return 0
}

test_skips_without_existing_install_or_config_consent() {
	local output=""

	output=$(
		load_setup_functions
		_scheduler_detect_installed() { return 1; }
		config_enabled() { return 1; }

		if _should_setup_noninteractive_supervisor_pulse; then
			printf 'result=true\n'
		else
			printf 'result=false\n'
		fi
	) || true

	if [[ "$output" == *"result=false"* ]]; then
		print_result "non-interactive pulse setup preserves consent gate" 0
		return 0
	fi

	print_result "non-interactive pulse setup preserves consent gate" 1 "output=${output}"
	return 0
}

main() {
	test_uses_existing_installation_signal
	test_uses_explicit_config_consent_for_first_install
	test_skips_without_existing_install_or_config_consent

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
