#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Static regression checks for stale dashboard LaunchAgent cleanup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
MIGRATIONS_SH="${REPO_ROOT}/.agents/scripts/setup/modules/migrations.sh"
SETUP_SH="${REPO_ROOT}/setup.sh"

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

test_cleanup_function_is_guarded_by_r912_state() {
	local snippet
	snippet=$(awk '
		/^cleanup_legacy_dashboard_launchagent\(\) \{/ { in_fn=1 }
		in_fn { print }
		in_fn && /^[[:space:]]*}/ { exit }
	' "$MIGRATIONS_SH")
	if printf '%s' "$snippet" | grep -qF 'com.aidevops.dashboard' && \
		printf '%s' "$snippet" | grep -qF 'aidevops-routines/TODO.md' && \
		printf '%s' "$snippet" | grep -qE 'r912' && \
		printf '%s' "$snippet" | grep -qF 'launchctl bootout'; then
		print_result "legacy dashboard cleanup is gated by r912 disabled state" 0
		return 0
	fi
	print_result "legacy dashboard cleanup is gated by r912 disabled state" 1 \
		"Expected label, routines TODO guard, r912 check, and launchctl bootout"
	return 0
}

test_cleanup_runs_in_setup_paths() {
	local count
	count=$(grep -cF 'cleanup_legacy_dashboard_launchagent' "$SETUP_SH")
	if [[ "$count" -ge 2 ]]; then
		print_result "legacy dashboard cleanup runs in interactive and non-interactive setup" 0
		return 0
	fi
	print_result "legacy dashboard cleanup runs in interactive and non-interactive setup" 1 \
		"Expected cleanup_legacy_dashboard_launchagent in both setup paths, found $count"
	return 0
}

main() {
	test_cleanup_function_is_guarded_by_r912_state
	test_cleanup_runs_in_setup_paths
	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
