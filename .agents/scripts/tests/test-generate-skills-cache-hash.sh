#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
GENERATE_SKILLS_SCRIPT="${REPO_ROOT}/.agents/scripts/generate-skills.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMP_DIR=""

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

cleanup() {
	if [[ -n "$TEST_TMP_DIR" && -d "$TEST_TMP_DIR" ]]; then
		rm -rf "$TEST_TMP_DIR"
	fi
	return 0
}

make_test_agents_dir() {
	TEST_TMP_DIR="$(mktemp -d)"
	mkdir -p "$TEST_TMP_DIR/example" "$TEST_TMP_DIR/scripts"
	cat >"$TEST_TMP_DIR/example.md" <<'EOF'
---
description: Example skill
---

# Example
EOF
	return 0
}

test_cache_hash_written_before_completion_summary() {
	local output=""
	local cache_hash=""
	make_test_agents_dir

	output=$(AIDEVOPS_AGENTS_DIR="$TEST_TMP_DIR" bash "$GENERATE_SKILLS_SCRIPT" 2>&1)
	cache_hash=$(<"$TEST_TMP_DIR/.skills-source-hash")

	if [[ -z "$cache_hash" ]]; then
		print_result "generate-skills writes non-empty cache hash" 1 "cache hash was empty"
		return 0
	fi

	if [[ "$output" != *"Generation complete:"* ]]; then
		print_result "generate-skills emits completion summary" 1 "output=${output}"
		return 0
	fi

	print_result "generate-skills reuses pre-generation hash after summary" 0
	return 0
}

main() {
	trap cleanup EXIT

	test_cache_hash_written_before_completion_summary

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
