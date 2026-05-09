#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-init-coderabbit.sh — regression tests for CodeRabbit init config updates

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AIDEVOPS_INIT_LIB="$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-init-lib.sh"

TEST_ROOT=""

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

trap cleanup EXIT

print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }

load_coderabbit_function() {
	local func_body
	func_body=$(sed -n '/^_init_configure_coderabbit_abort_on_close() {/,/^}/p' "$AIDEVOPS_INIT_LIB")
	eval "$func_body"
	return 0
}

assert_contains_once() {
	local file_path="$1"
	local pattern="$2"
	local name="$3"
	local count
	count=$(grep -Ec "$pattern" "$file_path" || true)
	if [[ "$count" == "1" ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s: expected one match for %s, got %s\n' "$name" "$pattern" "$count" >&2
	return 1
}

test_reviews_with_inline_comment_is_reused() {
	TEST_ROOT=$(mktemp -d)
	local project_root="$TEST_ROOT/project"
	mkdir -p "$project_root"
	printf 'reviews: # existing CodeRabbit settings\n  auto_review: true\n' > "$project_root/.coderabbit.yaml"

	AIDEVOPS_CODERABBIT_ABORT_ON_CLOSE=false _init_configure_coderabbit_abort_on_close "$project_root" "true"

	assert_contains_once "$project_root/.coderabbit.yaml" '^reviews:' "keeps one reviews section with inline comment"
	assert_contains_once "$project_root/.coderabbit.yaml" '^  abort_on_close: false$' "adds abort_on_close under existing reviews"
	cleanup
	TEST_ROOT=""
	return 0
}

test_existing_abort_preserves_trailing_comment() {
	TEST_ROOT=$(mktemp -d)
	local project_root="$TEST_ROOT/project"
	mkdir -p "$project_root"
	printf 'reviews:\n  abort_on_close: true # keep note\n' > "$project_root/.coderabbit.yaml"

	AIDEVOPS_CODERABBIT_ABORT_ON_CLOSE=false _init_configure_coderabbit_abort_on_close "$project_root" "true"

	assert_contains_once "$project_root/.coderabbit.yaml" '^  abort_on_close: false # keep note$' "updates abort_on_close and preserves comments"
	cleanup
	TEST_ROOT=""
	return 0
}

test_empty_abort_value_is_updated() {
	TEST_ROOT=$(mktemp -d)
	local project_root="$TEST_ROOT/project"
	mkdir -p "$project_root"
	printf 'reviews:\n  abort_on_close:  # keep empty note\n' > "$project_root/.coderabbit.yaml"

	AIDEVOPS_CODERABBIT_ABORT_ON_CLOSE=false _init_configure_coderabbit_abort_on_close "$project_root" "true"

	assert_contains_once "$project_root/.coderabbit.yaml" '^  abort_on_close: false # keep empty note$' "updates empty abort_on_close value"
	cleanup
	TEST_ROOT=""
	return 0
}

test_indented_reviews_preserves_child_indentation() {
	TEST_ROOT=$(mktemp -d)
	local project_root="$TEST_ROOT/project"
	mkdir -p "$project_root"
	printf 'root:\n  reviews: # nested settings\n    auto_review: true\n' > "$project_root/.coderabbit.yaml"

	AIDEVOPS_CODERABBIT_ABORT_ON_CLOSE=false _init_configure_coderabbit_abort_on_close "$project_root" "true"

	assert_contains_once "$project_root/.coderabbit.yaml" '^    abort_on_close: false$' "adds abort_on_close using reviews indentation"
	cleanup
	TEST_ROOT=""
	return 0
}

load_coderabbit_function
test_reviews_with_inline_comment_is_reused
test_existing_abort_preserves_trailing_comment
test_empty_abort_value_is_updated
test_indented_reviews_preserves_child_indentation
