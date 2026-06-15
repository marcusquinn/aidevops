#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-design-guidelines-helper.sh — DESIGN.md helper regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$REPO_ROOT/.agents/scripts/design-guidelines-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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
	if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

trap cleanup EXIT

assert_file() {
	local file_path="$1"
	local test_name="$2"
	[[ -f "$file_path" ]] && { print_result "$test_name" 0; return 0; }
	print_result "$test_name" 1 "missing: $file_path"
	return 0
}

test_detect_interface_markers() {
	TEST_ROOT=$(mktemp -d)
	local ui_repo="$TEST_ROOT/ui"
	local cli_repo="$TEST_ROOT/cli"
	mkdir -p "$ui_repo/src" "$cli_repo"
	git -C "$ui_repo" init --quiet 2>/dev/null
	git -C "$cli_repo" init --quiet 2>/dev/null
	touch "$ui_repo/src/App.tsx"

	if "$HELPER" detect "$ui_repo" >/dev/null; then
		print_result "detect finds React UI marker" 0
	else
		print_result "detect finds React UI marker" 1
	fi

	if "$HELPER" detect "$cli_repo" >/dev/null 2>&1; then
		print_result "detect ignores CLI-only repo" 1 "unexpected interface result"
	else
		print_result "detect ignores CLI-only repo" 0
	fi

	rm -rf "$TEST_ROOT"
	TEST_ROOT=""
	return 0
}

test_scaffold_and_guidelines() {
	TEST_ROOT=$(mktemp -d)
	local repo_dir="$TEST_ROOT/product"
	mkdir -p "$repo_dir/src"
	git -C "$repo_dir" init --quiet 2>/dev/null
	git -C "$repo_dir" remote add origin "https://github.com/example/product.git"
	touch "$repo_dir/src/App.tsx"

	"$HELPER" scaffold "$repo_dir" >/dev/null
	assert_file "$repo_dir/DESIGN.md" "scaffold creates DESIGN.md"

	local output_dir="$repo_dir/_reports/brand-guidelines"
	"$HELPER" guidelines "$repo_dir" --output-dir "$output_dir" --template basic --no-pdf >/dev/null
	assert_file "$output_dir/brand-guidelines.md" "guidelines creates Markdown handoff"
	assert_file "$output_dir/brand-guidelines.html" "guidelines creates HTML handoff"

	rm -rf "$TEST_ROOT"
	TEST_ROOT=""
	return 0
}

echo "test-design-guidelines-helper.sh — DESIGN.md helper tests"
echo "========================================================"

if [[ ! -x "$HELPER" ]]; then
	printf 'ERROR: helper not executable: %s\n' "$HELPER" >&2
	exit 1
fi

test_detect_interface_markers
test_scaffold_and_guidelines

echo ""
echo "========================================================"
echo "Results: $TESTS_RUN tests, $TESTS_FAILED failures"

if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi

exit 0
