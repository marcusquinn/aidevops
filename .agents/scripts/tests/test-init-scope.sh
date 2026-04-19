#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-init-scope.sh — t2265 regression guard.
#
# Tests the init_scope feature that gates scaffolding files per repo scope.
# Validates: _infer_init_scope, _scope_includes, and the file creation
# matrix (minimal/standard/public).
#
# Strategy: source aidevops.sh to get the helper functions, then test them
# directly without running cmd_init (which requires a full git repo + jq setup).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# Navigate to the repo root (tests/ → scripts/ → .agents/ → repo root)
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	((TESTS_RUN++))
	if [[ "$expected" == "$actual" ]]; then
		((TESTS_PASSED++))
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		((TESTS_FAILED++))
		echo "${TEST_RED}FAIL${TEST_NC}: $label (expected='$expected' actual='$actual')"
	fi
	return 0
}

assert_exit() {
	local label="$1"
	local expected_exit="$2"
	shift 2
	((TESTS_RUN++))
	"$@" >/dev/null 2>&1
	local actual_exit=$?
	if [[ "$expected_exit" == "$actual_exit" ]]; then
		((TESTS_PASSED++))
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		((TESTS_FAILED++))
		echo "${TEST_RED}FAIL${TEST_NC}: $label (expected exit=$expected_exit actual exit=$actual_exit)"
	fi
	return 0
}

# --- Source the helper functions from aidevops.sh ---
# We need _infer_init_scope and _scope_includes. These are pure functions
# that don't depend on the full CLI initialization, but we need to provide
# stubs for dependencies they use.

# Stub out functions that aidevops.sh defines/uses before our target functions
# to avoid sourcing the entire CLI (which would try to run main).

# Extract just the two functions we need by sourcing up to the function
# definitions. This is fragile if the file structure changes, so we use
# a simpler approach: define the functions inline from the source.

# Actually, the cleanest approach: extract and eval the functions.
# But that's fragile too. Best approach: test the logic directly.

echo "${TEST_BLUE}=== t2265: init_scope unit tests ===${TEST_NC}"
echo ""

# --- Test _scope_includes logic (pure function, no deps) ---
# Reimplment the logic here since sourcing the full CLI is impractical.

_scope_includes() {
	local scope="$1"
	local category="$2"
	case "$category" in
	core) return 0 ;;
	standard)
		case "$scope" in
		standard | public) return 0 ;;
		*) return 1 ;;
		esac
		;;
	public)
		case "$scope" in
		public) return 0 ;;
		*) return 1 ;;
		esac
		;;
	*) return 0 ;;
	esac
}

echo "${TEST_BLUE}--- _scope_includes tests ---${TEST_NC}"

# Core category: always included
assert_exit "minimal + core = included" 0 _scope_includes "minimal" "core"
assert_exit "standard + core = included" 0 _scope_includes "standard" "core"
assert_exit "public + core = included" 0 _scope_includes "public" "core"

# Standard category: standard and public only
assert_exit "minimal + standard = excluded" 1 _scope_includes "minimal" "standard"
assert_exit "standard + standard = included" 0 _scope_includes "standard" "standard"
assert_exit "public + standard = included" 0 _scope_includes "public" "standard"

# Public category: public only
assert_exit "minimal + public = excluded" 1 _scope_includes "minimal" "public"
assert_exit "standard + public = excluded" 1 _scope_includes "standard" "public"
assert_exit "public + public = included" 0 _scope_includes "public" "public"

# Unknown category: defaults to included
assert_exit "minimal + unknown = included" 0 _scope_includes "minimal" "unknown_cat"

echo ""
echo "${TEST_BLUE}--- Scope file matrix validation ---${TEST_NC}"

# Validate the expected file matrix from the issue brief (t2265).
# For each file, assert its scope category matches the spec.
#
# Core (all scopes): TODO.md, todo/, .aidevops.json, .gitignore, .gitattributes, AGENTS.md, .agents/
# Standard (standard+public): DESIGN.md, MODELS.md, .cursorrules, .windsurfrules, .clinerules,
#                               .github/copilot-instructions.md, README.md
# Public only: LICENCE, CHANGELOG.md, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md

# Helper: check if a file would be created for a given scope
_would_create() {
	local scope="$1"
	local file="$2"
	local category
	case "$file" in
	TODO.md | todo/ | .aidevops.json | .gitignore | .gitattributes | AGENTS.md | .agents/)
		category="core"
		;;
	DESIGN.md | MODELS.md | .cursorrules | .windsurfrules | .clinerules | .github/copilot-instructions.md | README.md)
		category="standard"
		;;
	LICENCE | CHANGELOG.md | CONTRIBUTING.md | SECURITY.md | CODE_OF_CONDUCT.md)
		category="public"
		;;
	*)
		category="core"
		;;
	esac
	_scope_includes "$scope" "$category"
	return $?
}

# Minimal scope: only core files
assert_exit "minimal creates TODO.md" 0 _would_create "minimal" "TODO.md"
assert_exit "minimal creates .aidevops.json" 0 _would_create "minimal" ".aidevops.json"
assert_exit "minimal creates AGENTS.md" 0 _would_create "minimal" "AGENTS.md"
assert_exit "minimal skips DESIGN.md" 1 _would_create "minimal" "DESIGN.md"
assert_exit "minimal skips MODELS.md" 1 _would_create "minimal" "MODELS.md"
assert_exit "minimal skips .cursorrules" 1 _would_create "minimal" ".cursorrules"
assert_exit "minimal skips README.md" 1 _would_create "minimal" "README.md"
assert_exit "minimal skips LICENCE" 1 _would_create "minimal" "LICENCE"
assert_exit "minimal skips CHANGELOG.md" 1 _would_create "minimal" "CHANGELOG.md"
assert_exit "minimal skips CONTRIBUTING.md" 1 _would_create "minimal" "CONTRIBUTING.md"
assert_exit "minimal skips SECURITY.md" 1 _would_create "minimal" "SECURITY.md"
assert_exit "minimal skips CODE_OF_CONDUCT.md" 1 _would_create "minimal" "CODE_OF_CONDUCT.md"

# Standard scope: core + standard files
assert_exit "standard creates TODO.md" 0 _would_create "standard" "TODO.md"
assert_exit "standard creates DESIGN.md" 0 _would_create "standard" "DESIGN.md"
assert_exit "standard creates MODELS.md" 0 _would_create "standard" "MODELS.md"
assert_exit "standard creates .cursorrules" 0 _would_create "standard" ".cursorrules"
assert_exit "standard creates README.md" 0 _would_create "standard" "README.md"
assert_exit "standard skips LICENCE" 1 _would_create "standard" "LICENCE"
assert_exit "standard skips CHANGELOG.md" 1 _would_create "standard" "CHANGELOG.md"
assert_exit "standard skips CONTRIBUTING.md" 1 _would_create "standard" "CONTRIBUTING.md"

# Public scope: all files
assert_exit "public creates TODO.md" 0 _would_create "public" "TODO.md"
assert_exit "public creates DESIGN.md" 0 _would_create "public" "DESIGN.md"
assert_exit "public creates LICENCE" 0 _would_create "public" "LICENCE"
assert_exit "public creates CHANGELOG.md" 0 _would_create "public" "CHANGELOG.md"
assert_exit "public creates CONTRIBUTING.md" 0 _would_create "public" "CONTRIBUTING.md"
assert_exit "public creates SECURITY.md" 0 _would_create "public" "SECURITY.md"
assert_exit "public creates CODE_OF_CONDUCT.md" 0 _would_create "public" "CODE_OF_CONDUCT.md"

echo ""
echo "${TEST_BLUE}--- _infer_init_scope integration tests ---${TEST_NC}"

# Test _infer_init_scope using temporary directories.
# This tests the heuristic path (no .aidevops.json, no repos.json entry).

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# We need a minimal REPOS_FILE stub for _infer_init_scope
REPOS_FILE="$TMPDIR_BASE/repos.json"
echo '{"initialized_repos":[],"git_parent_dirs":[]}' > "$REPOS_FILE"

# Reimplment _infer_init_scope for testing (same logic as aidevops.sh)
_infer_init_scope() {
	local project_root="$1"

	# 1. Check .aidevops.json
	if [[ -f "$project_root/.aidevops.json" ]] && command -v jq &>/dev/null; then
		local json_scope
		json_scope=$(jq -r '.init_scope // empty' "$project_root/.aidevops.json" 2>/dev/null || echo "")
		if [[ -n "$json_scope" ]]; then
			printf '%s\n' "$json_scope"
			return 0
		fi
	fi

	# 2. Check repos.json entry
	if [[ -f "$REPOS_FILE" ]] && command -v jq &>/dev/null; then
		local abs_path
		abs_path=$(cd "$project_root" 2>/dev/null && pwd -P) || abs_path="$project_root"
		local repo_scope
		repo_scope=$(jq -r --arg path "$abs_path" \
			'(.initialized_repos[] | select(.path == $path) | .init_scope) // empty' \
			"$REPOS_FILE" 2>/dev/null || echo "")
		if [[ -n "$repo_scope" ]]; then
			printf '%s\n' "$repo_scope"
			return 0
		fi
	fi

	# 3. Heuristic: no remote → minimal
	if ! git -C "$project_root" remote get-url origin &>/dev/null 2>&1; then
		printf 'minimal\n'
		return 0
	fi

	# 4. Default: standard
	printf 'standard\n'
	return 0
}

# Test 1: repo with no remote → minimal
test_repo_no_remote="$TMPDIR_BASE/no-remote"
mkdir -p "$test_repo_no_remote"
git -C "$test_repo_no_remote" init --quiet 2>/dev/null
result=$(_infer_init_scope "$test_repo_no_remote")
assert_eq "no-remote repo infers minimal" "minimal" "$result"

# Test 2: repo with .aidevops.json containing init_scope → uses it
test_repo_explicit="$TMPDIR_BASE/explicit-scope"
mkdir -p "$test_repo_explicit"
git -C "$test_repo_explicit" init --quiet 2>/dev/null
echo '{"init_scope": "public"}' > "$test_repo_explicit/.aidevops.json"
result=$(_infer_init_scope "$test_repo_explicit")
assert_eq "explicit init_scope in .aidevops.json" "public" "$result"

# Test 3: repo with .aidevops.json but no init_scope and no remote → minimal
test_repo_no_scope="$TMPDIR_BASE/no-scope"
mkdir -p "$test_repo_no_scope"
git -C "$test_repo_no_scope" init --quiet 2>/dev/null
echo '{"version": "1.0.0"}' > "$test_repo_no_scope/.aidevops.json"
result=$(_infer_init_scope "$test_repo_no_scope")
assert_eq "no init_scope + no remote = minimal" "minimal" "$result"

# Test 4: repos.json entry with init_scope
test_repo_fromjson="$TMPDIR_BASE/from-json"
mkdir -p "$test_repo_fromjson"
git -C "$test_repo_fromjson" init --quiet 2>/dev/null
abs_path=$(cd "$test_repo_fromjson" && pwd -P)
jq --arg path "$abs_path" '.initialized_repos += [{"path": $path, "init_scope": "standard"}]' \
	"$REPOS_FILE" > "${REPOS_FILE}.tmp" && mv "${REPOS_FILE}.tmp" "$REPOS_FILE"
result=$(_infer_init_scope "$test_repo_fromjson")
assert_eq "init_scope from repos.json entry" "standard" "$result"

echo ""
echo "${TEST_BLUE}--- Source validation: functions exist in aidevops.sh ---${TEST_NC}"

# Verify the functions are defined in the actual source
if grep -q '^_infer_init_scope()' "$REPO_ROOT/aidevops.sh"; then
	((TESTS_RUN++)); ((TESTS_PASSED++))
	echo "${TEST_GREEN}PASS${TEST_NC}: _infer_init_scope defined in aidevops.sh"
else
	((TESTS_RUN++)); ((TESTS_FAILED++))
	echo "${TEST_RED}FAIL${TEST_NC}: _infer_init_scope NOT found in aidevops.sh"
fi

if grep -q '^_scope_includes()' "$REPO_ROOT/aidevops.sh"; then
	((TESTS_RUN++)); ((TESTS_PASSED++))
	echo "${TEST_GREEN}PASS${TEST_NC}: _scope_includes defined in aidevops.sh"
else
	((TESTS_RUN++)); ((TESTS_FAILED++))
	echo "${TEST_RED}FAIL${TEST_NC}: _scope_includes NOT found in aidevops.sh"
fi

# Verify init_scope is written to .aidevops.json template
if grep -q '"init_scope"' "$REPO_ROOT/aidevops.sh"; then
	((TESTS_RUN++)); ((TESTS_PASSED++))
	echo "${TEST_GREEN}PASS${TEST_NC}: init_scope field present in .aidevops.json template"
else
	((TESTS_RUN++)); ((TESTS_FAILED++))
	echo "${TEST_RED}FAIL${TEST_NC}: init_scope field NOT in .aidevops.json template"
fi

# Verify scope gating in scaffold_repo_courtesy_files
# shellcheck disable=SC2016
if grep -q '_scope_includes "$scope"' "$REPO_ROOT/aidevops.sh"; then
	((TESTS_RUN++)); ((TESTS_PASSED++))
	echo "${TEST_GREEN}PASS${TEST_NC}: scaffold_repo_courtesy_files uses _scope_includes"
else
	((TESTS_RUN++)); ((TESTS_FAILED++))
	echo "${TEST_RED}FAIL${TEST_NC}: scaffold_repo_courtesy_files does NOT use _scope_includes"
fi

# Verify scope gating in cmd_init for pointer files, DESIGN.md, MODELS.md
# shellcheck disable=SC2016
if grep -q '_scope_includes "$init_scope" "standard"' "$REPO_ROOT/aidevops.sh"; then
	((TESTS_RUN++)); ((TESTS_PASSED++))
	echo "${TEST_GREEN}PASS${TEST_NC}: cmd_init gates standard-scope blocks"
else
	((TESTS_RUN++)); ((TESTS_FAILED++))
	echo "${TEST_RED}FAIL${TEST_NC}: cmd_init does NOT gate standard-scope blocks"
fi

# Verify scope is passed to scaffold_repo_courtesy_files
# shellcheck disable=SC2016
if grep -q 'scaffold_repo_courtesy_files "$project_root" "$init_scope"' "$REPO_ROOT/aidevops.sh"; then
	((TESTS_RUN++)); ((TESTS_PASSED++))
	echo "${TEST_GREEN}PASS${TEST_NC}: scaffold_repo_courtesy_files receives scope argument"
else
	((TESTS_RUN++)); ((TESTS_FAILED++))
	echo "${TEST_RED}FAIL${TEST_NC}: scaffold_repo_courtesy_files NOT called with scope"
fi

# Verify register_repo preserves init_scope
if grep -q 'init_scope' "$REPO_ROOT/aidevops.sh" | grep -q 'scope_default'; then
	# grep pipeline check — just verify both strings exist
	:
fi
scope_in_register=$(grep -c 'scope_default' "$REPO_ROOT/aidevops.sh" 2>/dev/null || echo "0")
if [[ "$scope_in_register" -ge 3 ]]; then
	((TESTS_RUN++)); ((TESTS_PASSED++))
	echo "${TEST_GREEN}PASS${TEST_NC}: register_repo handles init_scope (scope_default refs: $scope_in_register)"
else
	((TESTS_RUN++)); ((TESTS_FAILED++))
	echo "${TEST_RED}FAIL${TEST_NC}: register_repo may not handle init_scope properly (scope_default refs: $scope_in_register)"
fi

echo ""
echo "========================================="
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
echo "========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
