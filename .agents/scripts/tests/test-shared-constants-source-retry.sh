#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression checks for launchd/update race hardening in shared-constants.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SHARED_CONSTANTS="${SCRIPT_DIR}/../shared-constants.sh"

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

test_split_modules_use_retry_helper() {
	local missing=""
	local module
	for module in portable-stat shared-gh-wrappers shared-todo-commit shared-model-tier shared-feature-toggles; do
		if ! grep -qF "_source_shared_module_with_retry \"\${_SC_SELF%/*}/${module}.sh\"" "$SHARED_CONSTANTS"; then
			missing="${missing:+$missing }${module}"
		fi
	done

	if [[ -z "$missing" ]]; then
		print_result "shared split modules source through retry helper" 0
		return 0
	fi
	print_result "shared split modules source through retry helper" 1 "missing retry for: $missing"
	return 0
}

test_retry_helper_has_bounded_attempts() {
	local snippet
	snippet=$(awk '
		/^_source_shared_module_with_retry\(\) \{/ { in_helper=1 }
		in_helper { print }
		in_helper && /^[[:space:]]*}/ { exit }
	' "$SHARED_CONSTANTS")
	if printf '%s' "$snippet" | grep -qF 'AIDEVOPS_SHARED_SOURCE_ATTEMPTS' && \
		printf '%s' "$snippet" | grep -qF 'shared module missing after' && \
		printf '%s' "$snippet" | grep -qE '^[[:space:]]*return 1'; then
		print_result "shared source retry is bounded and reports persistent corruption" 0
		return 0
	fi
	print_result "shared source retry is bounded and reports persistent corruption" 1 \
		"Expected bounded attempts, diagnostic message, and return 1"
	return 0
}

main() {
	test_split_modules_use_retry_helper
	test_retry_helper_has_bounded_attempts
	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
