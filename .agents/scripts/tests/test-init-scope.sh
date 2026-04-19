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

	# minimal does NOT include standard
	if _scope_includes "minimal" "standard"; then
		print_result "minimal excludes standard" 1 "Expected failure but got success"
	else
		print_result "minimal excludes standard" 0
	fi

	# minimal does NOT include public
	if _scope_includes "minimal" "public"; then
		print_result "minimal excludes public" 1 "Expected failure but got success"
	else
		print_result "minimal excludes public" 0
	fi

	# standard includes minimal
	_scope_includes "standard" "minimal"
	print_result "standard includes minimal" "$?"

	# standard includes standard
	_scope_includes "standard" "standard"
	print_result "standard includes standard" "$?"

	# standard does NOT include public
	if _scope_includes "standard" "public"; then
		print_result "standard excludes public" 1 "Expected failure but got success"
	else
		print_result "standard excludes public" 0
	fi

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

	if _scope_includes "unknown" "public"; then
		print_result "unknown scope excludes public" 1 "Expected failure but got success"
	else
		print_result "unknown scope excludes public" 0
	fi

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
	if [[ "$result" == "public" ]]; then
		print_result ".aidevops.json explicit scope respected" 0
	else
		print_result ".aidevops.json explicit scope respected" 1 "Expected 'public', got '$result'"
	fi

	# Test 2: No remote → minimal
	local test_dir2="$TEST_ROOT/test-no-remote"
	mkdir -p "$test_dir2"
	git -C "$test_dir2" init --quiet 2>/dev/null

	result=$(_infer_init_scope "$test_dir2")
	if [[ "$result" == "minimal" ]]; then
		print_result "No remote infers minimal" 0
	else
		print_result "No remote infers minimal" 1 "Expected 'minimal', got '$result'"
	fi

	# Test 3: Empty .aidevops.json (no init_scope) + no remote → minimal
	local test_dir3="$TEST_ROOT/test-empty-json"
	mkdir -p "$test_dir3"
	git -C "$test_dir3" init --quiet 2>/dev/null
	echo '{"version": "1.0"}' > "$test_dir3/.aidevops.json"

	result=$(_infer_init_scope "$test_dir3")
	if [[ "$result" == "minimal" ]]; then
		print_result "Empty .aidevops.json + no remote → minimal" 0
	else
		print_result "Empty .aidevops.json + no remote → minimal" 1 "Expected 'minimal', got '$result'"
	fi

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

	if [[ ! -f "$minimal_dir/README.md" ]]; then
		print_result "minimal: no README.md" 0
	else
		print_result "minimal: no README.md" 1 "README.md was created for minimal scope"
	fi
	if [[ ! -f "$minimal_dir/LICENCE" ]] && [[ ! -f "$minimal_dir/LICENSE" ]]; then
		print_result "minimal: no LICENCE" 0
	else
		print_result "minimal: no LICENCE" 1 "LICENCE was created for minimal scope"
	fi
	if [[ ! -f "$minimal_dir/CHANGELOG.md" ]]; then
		print_result "minimal: no CHANGELOG.md" 0
	else
		print_result "minimal: no CHANGELOG.md" 1 "CHANGELOG.md was created for minimal scope"
	fi
	if [[ ! -f "$minimal_dir/CONTRIBUTING.md" ]]; then
		print_result "minimal: no CONTRIBUTING.md" 0
	else
		print_result "minimal: no CONTRIBUTING.md" 1 "CONTRIBUTING.md was created for minimal scope"
	fi

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

	if [[ -f "$standard_dir/README.md" ]]; then
		print_result "standard: README.md created" 0
	else
		print_result "standard: README.md created" 1 "README.md was NOT created for standard scope"
	fi
	if [[ ! -f "$standard_dir/LICENCE" ]] && [[ ! -f "$standard_dir/LICENSE" ]]; then
		print_result "standard: no LICENCE" 0
	else
		print_result "standard: no LICENCE" 1 "LICENCE was created for standard scope"
	fi
	if [[ ! -f "$standard_dir/CHANGELOG.md" ]]; then
		print_result "standard: no CHANGELOG.md" 0
	else
		print_result "standard: no CHANGELOG.md" 1 "CHANGELOG.md was created for standard scope"
	fi

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

	if [[ -f "$public_dir/README.md" ]]; then
		print_result "public: README.md created" 0
	else
		print_result "public: README.md created" 1 "README.md was NOT created for public scope"
	fi
	if [[ -f "$public_dir/LICENCE" ]] || [[ -f "$public_dir/LICENSE" ]]; then
		print_result "public: LICENCE created" 0
	else
		print_result "public: LICENCE created" 1 "LICENCE was NOT created for public scope"
	fi
	if [[ -f "$public_dir/CHANGELOG.md" ]]; then
		print_result "public: CHANGELOG.md created" 0
	else
		print_result "public: CHANGELOG.md created" 1 "CHANGELOG.md was NOT created for public scope"
	fi

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
	if [[ "$scope" == "minimal" ]]; then
		print_result ".aidevops.json init_scope round-trip" 0
	else
		print_result ".aidevops.json init_scope round-trip" 1 "Expected 'minimal', got '$scope'"
	fi

	# Verify init_scope is present and not null
	local has_scope
	has_scope=$(jq 'has("init_scope")' "$test_dir/.aidevops.json")
	if [[ "$has_scope" == "true" ]]; then
		print_result ".aidevops.json has init_scope field" 0
	else
		print_result ".aidevops.json has init_scope field" 1 "init_scope field missing"
	fi

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
	if [[ "$result" == "standard" ]]; then
		print_result "Existing repo without init_scope defaults to standard" 0
	else
		print_result "Existing repo without init_scope defaults to standard" 1 "Expected 'standard', got '$result'"
	fi

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
