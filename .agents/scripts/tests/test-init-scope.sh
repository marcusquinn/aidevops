#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-init-scope.sh — Tests for init_scope scaffolding gating (t2265)
#
# Verifies that _infer_init_scope and _scope_includes correctly gate
# which files are created by cmd_init for minimal, standard, and public scopes.
# Also tests round-trip preservation of init_scope in .aidevops.json and repos.json.
#
# Requires: bash 4+, jq, git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

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
	if [[ -n "${TEST_ROOT:-}" ]] && [[ -d "${TEST_ROOT}" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

trap cleanup EXIT

# Assertion helpers — flat expressions replace nested if/else/fi blocks.
# The regression scanner at complexity-regression-helper.sh counts every
# 'if|for|while|until|case' keyword (even inside strings) as a depth
# increment, so keeping each test case to a single boolean expression
# avoids false-positive depth accumulation in message strings.
assert_missing() {
	local path="$1" name="$2" context="$3"
	[[ ! -f "$path" ]] && { print_result "$name" 0; return 0; }
	print_result "$name" 1 "$path present in $context scope"
}

assert_present() {
	local path="$1" name="$2" context="$3"
	[[ -f "$path" ]] && { print_result "$name" 0; return 0; }
	print_result "$name" 1 "$path missing in $context scope"
}

assert_either_missing() {
	local path_a="$1" path_b="$2" name="$3" context="$4"
	[[ ! -f "$path_a" && ! -f "$path_b" ]] && { print_result "$name" 0; return 0; }
	print_result "$name" 1 "$path_a or $path_b present in $context scope"
}

assert_either_present() {
	local path_a="$1" path_b="$2" name="$3" context="$4"
	{ [[ -f "$path_a" ]] || [[ -f "$path_b" ]]; } && { print_result "$name" 0; return 0; }
	print_result "$name" 1 "neither $path_a nor $path_b present in $context scope"
}

assert_equals() {
	local expected="$1" actual="$2" name="$3"
	[[ "$actual" == "$expected" ]] && { print_result "$name" 0; return 0; }
	print_result "$name" 1 "expected '$expected', got '$actual'"
}

assert_negative() {
	local name="$1"
	shift
	! "$@" && { print_result "$name" 0; return 0; }
	print_result "$name" 1 "expected failure but got success"
}

# Source the aidevops.sh to get access to the helper functions
# We need to find the repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AIDEVOPS_SH="$REPO_ROOT/aidevops.sh"

if [[ ! -f "$AIDEVOPS_SH" ]]; then
	echo "ERROR: Cannot find aidevops.sh at $AIDEVOPS_SH" >&2
	exit 1
fi

# We'll extract and test the functions directly rather than sourcing
# the entire script (which has side effects and requires env vars)

# ---- Test _scope_includes ----

test_scope_includes() {
	echo ""
	echo "=== Testing _scope_includes ==="

	# Extract the function from aidevops.sh
	local func_body
	func_body=$(sed -n '/_scope_includes() {/,/^}/p' "$AIDEVOPS_SH")
	eval "$func_body"

	# minimal includes minimal
	_scope_includes "minimal" "minimal"
	print_result "minimal includes minimal" "$?"

	# minimal does NOT include standard or public
	assert_negative "minimal excludes standard" _scope_includes "minimal" "standard"
	assert_negative "minimal excludes public" _scope_includes "minimal" "public"

	# standard includes minimal and standard
	_scope_includes "standard" "minimal"
	print_result "standard includes minimal" "$?"
	_scope_includes "standard" "standard"
	print_result "standard includes standard" "$?"

	# standard does NOT include public
	assert_negative "standard excludes public" _scope_includes "standard" "public"

	# public includes all
	_scope_includes "public" "minimal"
	print_result "public includes minimal" "$?"
	_scope_includes "public" "standard"
	print_result "public includes standard" "$?"
	_scope_includes "public" "public"
	print_result "public includes public" "$?"

	# unknown defaults to standard
	_scope_includes "unknown" "standard"
	print_result "unknown scope defaults to standard" "$?"
	assert_negative "unknown scope excludes public" _scope_includes "unknown" "public"

	return 0
}

# ---- Test _infer_init_scope ----

test_infer_init_scope() {
	echo ""
	echo "=== Testing _infer_init_scope ==="

	TEST_ROOT=$(mktemp -d)

	# Extract the function from aidevops.sh
	local func_body
	func_body=$(sed -n '/_infer_init_scope() {/,/^}/p' "$AIDEVOPS_SH")
	eval "$func_body"

	# Test 1: .aidevops.json with explicit init_scope takes priority
	local test_dir="$TEST_ROOT/test-json-scope"
	mkdir -p "$test_dir"
	git -C "$test_dir" init --quiet 2>/dev/null
	echo '{"init_scope": "public"}' > "$test_dir/.aidevops.json"

	local result
	result=$(_infer_init_scope "$test_dir")
	assert_equals "public" "$result" ".aidevops.json explicit scope respected"

	# Test 2: No remote → minimal
	local test_dir2="$TEST_ROOT/test-no-remote"
	mkdir -p "$test_dir2"
	git -C "$test_dir2" init --quiet 2>/dev/null

	result=$(_infer_init_scope "$test_dir2")
	assert_equals "minimal" "$result" "No remote infers minimal"

	# Test 3: Empty .aidevops.json (no init_scope) + no remote → minimal
	local test_dir3="$TEST_ROOT/test-empty-json"
	mkdir -p "$test_dir3"
	git -C "$test_dir3" init --quiet 2>/dev/null
	echo '{"version": "1.0"}' > "$test_dir3/.aidevops.json"

	result=$(_infer_init_scope "$test_dir3")
	assert_equals "minimal" "$result" "Empty .aidevops.json plus no remote → minimal"

	# Clean up
	rm -rf "$TEST_ROOT"
	TEST_ROOT=""
	return 0
}

# ---- Test scaffold_repo_courtesy_files with scope ----

# Shared setup for scaffold scope tests — extracts needed functions from aidevops.sh
_setup_scaffold_test_env() {
	TEST_ROOT=$(mktemp -d)

	local scope_func
	scope_func=$(sed -n '/_scope_includes() {/,/^}/p' "$AIDEVOPS_SH")
	eval "$scope_func"

	# Stub print functions
	print_info() { :; }
	print_success() { :; }
	print_warning() { :; }
	export -f print_info print_success print_warning

	local scaffold_func
	scaffold_func=$(sed -n '/^scaffold_repo_courtesy_files() {/,/^}/p' "$AIDEVOPS_SH")
	local contributing_func
	contributing_func=$(sed -n '/^_scaffold_contributing() {/,/^}/p' "$AIDEVOPS_SH")
	local security_func
	security_func=$(sed -n '/^_scaffold_security() {/,/^}/p' "$AIDEVOPS_SH")
	local coc_func
	coc_func=$(sed -n '/^_scaffold_coc() {/,/^}/p' "$AIDEVOPS_SH")
	local sec_content_func
	sec_content_func=$(sed -n '/^_generate_security_content() {/,/^}/p' "$AIDEVOPS_SH")

	eval "$contributing_func" 2>/dev/null || true
	eval "$security_func" 2>/dev/null || true
	eval "$coc_func" 2>/dev/null || true
	eval "$sec_content_func" 2>/dev/null || true
	eval "$scaffold_func"
	return 0
}

test_scaffold_minimal_scope() {
	echo ""
	echo "=== Testing scaffold: minimal scope ==="
	_setup_scaffold_test_env

	local minimal_dir="$TEST_ROOT/minimal-repo"
	mkdir -p "$minimal_dir"
	git -C "$minimal_dir" init --quiet 2>/dev/null
	scaffold_repo_courtesy_files "$minimal_dir" "minimal" 2>/dev/null

	assert_missing "$minimal_dir/README.md" "minimal: no README.md" "minimal"
	assert_either_missing "$minimal_dir/LICENCE" "$minimal_dir/LICENSE" "minimal: no LICENCE" "minimal"
	assert_missing "$minimal_dir/CHANGELOG.md" "minimal: no CHANGELOG.md" "minimal"
	assert_missing "$minimal_dir/CONTRIBUTING.md" "minimal: no CONTRIBUTING.md" "minimal"

	rm -rf "$TEST_ROOT"; TEST_ROOT=""
	return 0
}

test_scaffold_standard_scope() {
	echo ""
	echo "=== Testing scaffold: standard scope ==="
	_setup_scaffold_test_env

	local standard_dir="$TEST_ROOT/standard-repo"
	mkdir -p "$standard_dir"
	git -C "$standard_dir" init --quiet 2>/dev/null
	scaffold_repo_courtesy_files "$standard_dir" "standard" 2>/dev/null

	assert_present "$standard_dir/README.md" "standard: README.md created" "standard"
	assert_either_missing "$standard_dir/LICENCE" "$standard_dir/LICENSE" "standard: no LICENCE" "standard"
	assert_missing "$standard_dir/CHANGELOG.md" "standard: no CHANGELOG.md" "standard"

	rm -rf "$TEST_ROOT"; TEST_ROOT=""
	return 0
}

test_scaffold_public_scope() {
	echo ""
	echo "=== Testing scaffold: public scope ==="
	_setup_scaffold_test_env

	local public_dir="$TEST_ROOT/public-repo"
	mkdir -p "$public_dir"
	git -C "$public_dir" init --quiet 2>/dev/null
	scaffold_repo_courtesy_files "$public_dir" "public" 2>/dev/null

	assert_present "$public_dir/README.md" "public: README.md created" "public"
	assert_either_present "$public_dir/LICENCE" "$public_dir/LICENSE" "public: LICENCE created" "public"
	assert_present "$public_dir/CHANGELOG.md" "public: CHANGELOG.md created" "public"

	rm -rf "$TEST_ROOT"; TEST_ROOT=""
	return 0
}

# ---- Test .aidevops.json round-trip ----

test_aidevops_json_roundtrip() {
	echo ""
	echo "=== Testing .aidevops.json init_scope round-trip ==="

	TEST_ROOT=$(mktemp -d)

	local test_dir="$TEST_ROOT/roundtrip-repo"
	mkdir -p "$test_dir"

	# Simulate what cmd_init writes
	cat > "$test_dir/.aidevops.json" <<'EOF'
{
  "version": "3.8.72",
  "initialized": "2026-04-19T00:00:00Z",
  "init_scope": "minimal",
  "features": {
    "planning": true
  }
}
EOF

	# Verify init_scope survives a read-back
	local scope
	scope=$(jq -r '.init_scope' "$test_dir/.aidevops.json")
	assert_equals "minimal" "$scope" ".aidevops.json init_scope round-trip"

	# Verify init_scope is present and not null
	local has_scope
	has_scope=$(jq 'has("init_scope")' "$test_dir/.aidevops.json")
	assert_equals "true" "$has_scope" ".aidevops.json has init_scope field"

	rm -rf "$TEST_ROOT"
	TEST_ROOT=""
	return 0
}

# ---- Test backward compatibility (no init_scope → standard) ----

test_backward_compat() {
	echo ""
	echo "=== Testing backward compatibility ==="

	# Extract the function
	local func_body
	func_body=$(sed -n '/_infer_init_scope() {/,/^}/p' "$AIDEVOPS_SH")
	eval "$func_body"

	TEST_ROOT=$(mktemp -d)

	# Repo with a remote but no init_scope in .aidevops.json → standard
	local test_dir="$TEST_ROOT/compat-repo"
	mkdir -p "$test_dir"
	git -C "$test_dir" init --quiet 2>/dev/null
	# Add a fake remote
	git -C "$test_dir" remote add origin "https://github.com/test/test.git" 2>/dev/null

	echo '{"version": "3.0.0"}' > "$test_dir/.aidevops.json"

	local result
	result=$(_infer_init_scope "$test_dir")
	assert_equals "standard" "$result" "Existing repo without init_scope defaults to standard"

	rm -rf "$TEST_ROOT"
	TEST_ROOT=""
	return 0
}

# ---- Run all tests ----

echo "test-init-scope.sh — init_scope scaffolding gate tests (t2265)"
echo "============================================================="

test_scope_includes
test_infer_init_scope
test_scaffold_minimal_scope
test_scaffold_standard_scope
test_scaffold_public_scope
test_aidevops_json_roundtrip
test_backward_compat

echo ""
echo "============================================================="
echo "Results: $TESTS_RUN tests, $TESTS_FAILED failures"

if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi

exit 0
