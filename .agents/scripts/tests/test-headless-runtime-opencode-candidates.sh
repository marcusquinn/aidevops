#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for platform-aware headless OpenCode fallback candidates.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_REPO_ROOT="$(cd "$TEST_SCRIPTS_DIR/../.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

run_candidate_list_for_platform() {
	local platform="$1"
	(
		export AIDEVOPS_TEST_UNAME_S="$platform"
		# shellcheck disable=SC1091
		source "$TEST_REPO_ROOT/.agents/scripts/headless-runtime-lib.sh"
		_opencode_fixed_candidate_paths
	)
	return 0
}

run_warning_dirs_for_platform() {
	local platform="$1"
	(
		export AIDEVOPS_TEST_UNAME_S="$platform"
		# shellcheck disable=SC1091
		source "$TEST_REPO_ROOT/.agents/scripts/headless-runtime-lib.sh"
		_opencode_fixed_candidate_dirs_for_warning
	)
	return 0
}

# Darwin must not include Linux-only Snap paths.
darwin_candidates=$(run_candidate_list_for_platform "Darwin")
if [[ "$darwin_candidates" != *"/snap/bin/opencode"* ]]; then
	print_result "Darwin candidate list excludes /snap/bin/opencode" 0
else
	print_result "Darwin candidate list excludes /snap/bin/opencode" 1 "$darwin_candidates"
fi

darwin_warning=$(run_warning_dirs_for_platform "Darwin")
if [[ "$darwin_warning" != *"/snap/bin"* ]]; then
	print_result "Darwin warning text excludes /snap/bin" 0
else
	print_result "Darwin warning text excludes /snap/bin" 1 "$darwin_warning"
fi

# Linux keeps Snap-installed OpenCode discoverable.
linux_candidates=$(run_candidate_list_for_platform "Linux")
if [[ "$linux_candidates" == *"/snap/bin/opencode"* ]]; then
	print_result "Linux candidate list includes /snap/bin/opencode" 0
else
	print_result "Linux candidate list includes /snap/bin/opencode" 1 "$linux_candidates"
fi

linux_warning=$(run_warning_dirs_for_platform "Linux")
if [[ "$linux_warning" == *"/snap/bin"* ]]; then
	print_result "Linux warning text includes /snap/bin" 0
else
	print_result "Linux warning text includes /snap/bin" 1 "$linux_warning"
fi

echo ""
echo "Tests run: $TESTS_RUN"
echo "Failed:    $TESTS_FAILED"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
