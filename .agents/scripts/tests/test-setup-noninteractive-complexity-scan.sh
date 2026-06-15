#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
RUNTIME_HELPERS_SCRIPT="${REPO_ROOT}/.agents/scripts/setup/_runtime_helpers.sh"
SETUP_FILE="${REPO_ROOT}/setup.sh"

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
	local helper_definitions=""
	helper_definitions="$(awk '
		/^_should_setup_noninteractive_supervisor_pulse\(\) \{/ { emit=1 }
		/^_should_setup_noninteractive_scheduler\(\) \{/ { emit=1 }
		/^_should_setup_noninteractive_complexity_scan\(\) \{/ { emit=1 }
		emit { print }
		emit && /^}/ { emit=0 }
	' "$RUNTIME_HELPERS_SCRIPT")"

	if [[ -z "$helper_definitions" ]]; then
		printf 'failed to load helpers from %s\n' "$RUNTIME_HELPERS_SCRIPT" >&2
		return 1
	fi

	eval "$helper_definitions"
	return 0
}

test_regenerates_existing_complexity_scheduler() {
	local output=""

	output=$(
		load_setup_functions
		_scheduler_detect_installed() {
			local name="$1"
			[[ "$name" == "Complexity scan" ]]
			return $?
		}
		config_enabled() { return 1; }

		if _should_setup_noninteractive_complexity_scan; then
			printf 'result=true\n'
		else
			printf 'result=false\n'
		fi
	) || true

	if [[ "$output" == *"result=true"* ]]; then
		print_result "complexity scan regenerates existing scheduler" 0
		return 0
	fi

	print_result "complexity scan regenerates existing scheduler" 1 "output=${output}"
	return 0
}

test_installs_when_supervisor_pulse_enabled() {
	local output=""

	output=$(
		load_setup_functions
		_scheduler_detect_installed() { return 1; }
		config_enabled() {
			local key="$1"
			[[ "$key" == "orchestration.supervisor_pulse" ]]
			return $?
		}

		if _should_setup_noninteractive_complexity_scan; then
			printf 'result=true\n'
		else
			printf 'result=false\n'
		fi
	) || true

	if [[ "$output" == *"result=true"* ]]; then
		print_result "complexity scan installs when supervisor pulse is enabled" 0
		return 0
	fi

	print_result "complexity scan installs when supervisor pulse is enabled" 1 "output=${output}"
	return 0
}

test_preserves_noninteractive_consent_gate() {
	local output=""

	output=$(
		load_setup_functions
		_scheduler_detect_installed() { return 1; }
		config_enabled() { return 1; }

		if _should_setup_noninteractive_complexity_scan; then
			printf 'result=true\n'
		else
			printf 'result=false\n'
		fi
	) || true

	if [[ "$output" == *"result=false"* ]]; then
		print_result "complexity scan preserves non-interactive consent gate" 0
		return 0
	fi

	print_result "complexity scan preserves non-interactive consent gate" 1 "output=${output}"
	return 0
}

test_setup_uses_complexity_helper() {
	if awk '
		BEGIN { in_block=0; lines_since_gate=0; found_call=0 }
		/^[[:space:]]*if _should_setup_noninteractive_complexity_scan[;[:space:]]/ {
			in_block=1
			lines_since_gate=0
			next
		}
		in_block {
			lines_since_gate++
			if ($0 ~ /_time_step[[:space:]]+"setup_complexity_scan"/ &&
				$0 ~ /setup_complexity_scan([[:space:]]|$)/) {
				found_call=1
				exit
			}
			if (lines_since_gate > 3 || /^[[:space:]]*fi[[:space:]]*$/) {
				in_block=0
			}
		}
		END { exit (found_call) ? 0 : 1 }
	' "$SETUP_FILE"; then
		print_result "setup.sh complexity scan call site uses dedicated helper" 0
		return 0
	fi

	print_result "setup.sh complexity scan call site uses dedicated helper" 1 \
		"missing helper-gated setup_complexity_scan call"
	return 0
}

main() {
	test_regenerates_existing_complexity_scheduler
	test_installs_when_supervisor_pulse_enabled
	test_preserves_noninteractive_consent_gate
	test_setup_uses_complexity_helper

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
