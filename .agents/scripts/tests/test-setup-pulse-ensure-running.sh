#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SETUP_SCRIPT="${REPO_ROOT}/setup.sh"

TESTS_RUN=0
TESTS_FAILED=0

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

extract_setup_restart_function() {
	awk '
		/^_setup_restart_pulse_if_running\(\) \{/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$SETUP_SCRIPT"
	return 0
}

test_setup_restart_path_restarts_then_starts() {
	local helper_definition=""
	helper_definition="$(extract_setup_restart_function)"

	if [[ -z "$helper_definition" ]]; then
		print_result "setup pulse restart function is discoverable" 1 \
			"missing _setup_restart_pulse_if_running in setup.sh"
		return 0
	fi

	if ! printf '%s\n' "$helper_definition" | grep -Fq 'restart-if-running'; then
		print_result "setup pulse path refreshes running pulse" 1 \
			"missing restart-if-running call"
		return 0
	fi

	# shellcheck disable=SC2016 # checking literal setup.sh source text
	if ! printf '%s\n' "$helper_definition" | grep -Fq '"$_pulse_helper" start'; then
		print_result "setup pulse path starts dead pulse idempotently" 1 \
			"missing start call after restart-if-running"
		return 0
	fi

	print_result "setup pulse path restarts running pulse then starts dead pulse" 0
	return 0
}

main() {
	test_setup_restart_path_restarts_then_starts

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
