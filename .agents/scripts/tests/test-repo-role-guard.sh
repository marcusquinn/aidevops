#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-repo-role-guard.sh — Unit tests for get_repo_role_by_slug (t2145)
#
# Validates that the role field in repos.json correctly gates scanner
# functions for maintainer vs contributor instances.
#
# Usage: bash .agents/scripts/tests/test-repo-role-guard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="${SCRIPT_DIR}/.."

# --- Test harness ---
_TESTS_RUN=0
_TESTS_PASSED=0
_TESTS_FAILED=0

assert_eq() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	_TESTS_RUN=$((_TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		_TESTS_PASSED=$((_TESTS_PASSED + 1))
		printf '  PASS: %s\n' "$description"
	else
		_TESTS_FAILED=$((_TESTS_FAILED + 1))
		printf '  FAIL: %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
	fi
	return 0
}

# --- Setup ---
# Create a temp repos.json for testing
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
TEST_REPOS_JSON="${TMPDIR_TEST}/repos.json"

cat >"$TEST_REPOS_JSON" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "alice/owned-repo",
      "pulse": true,
      "role": "maintainer"
    },
    {
      "slug": "bob/external-repo",
      "pulse": true,
      "role": "contributor"
    },
    {
      "slug": "alice/auto-detect-repo",
      "pulse": true
    },
    {
      "slug": "charlie/auto-detect-other",
      "pulse": true
    }
  ],
  "git_parent_dirs": []
}
JSON

# Source shared-constants (provides REPOS_JSON variable path)
# shellcheck source=../shared-constants.sh
[[ -f "${PARENT_DIR}/shared-constants.sh" ]] && source "${PARENT_DIR}/shared-constants.sh"

# Override REPOS_JSON to point at our test fixture
REPOS_JSON="$TEST_REPOS_JSON"

# Source the module under test
# shellcheck source=../pulse-repo-meta.sh
_PULSE_REPO_META_LOADED=""
source "${PARENT_DIR}/pulse-repo-meta.sh"

# Override the cached gh user for deterministic testing
_CACHED_GH_USER="alice"

# --- Tests ---

echo "=== get_repo_role_by_slug ==="

# Test 1: Explicit maintainer role
role=$(get_repo_role_by_slug "alice/owned-repo")
assert_eq "explicit role=maintainer returns maintainer" "maintainer" "$role"

# Test 2: Explicit contributor role
role=$(get_repo_role_by_slug "bob/external-repo")
assert_eq "explicit role=contributor returns contributor" "contributor" "$role"

# Test 3: Auto-detect — slug owner matches gh user → maintainer
role=$(get_repo_role_by_slug "alice/auto-detect-repo")
assert_eq "auto-detect: slug owner matches gh user → maintainer" "maintainer" "$role"

# Test 4: Auto-detect — slug owner differs from gh user → contributor
role=$(get_repo_role_by_slug "charlie/auto-detect-other")
assert_eq "auto-detect: slug owner differs → contributor" "contributor" "$role"

# Test 5: Empty slug → contributor (safe default)
role=$(get_repo_role_by_slug "")
assert_eq "empty slug → contributor" "contributor" "$role"

# Test 6: Unknown slug (not in repos.json) — auto-detect from slug owner
role=$(get_repo_role_by_slug "alice/unknown-repo")
assert_eq "unknown slug, owner matches gh user → maintainer" "maintainer" "$role"

# Test 7: Unknown slug, different owner → contributor
role=$(get_repo_role_by_slug "stranger/unknown-repo")
assert_eq "unknown slug, different owner → contributor" "contributor" "$role"

echo ""
echo "Results: ${_TESTS_PASSED}/${_TESTS_RUN} passed, ${_TESTS_FAILED} failed"

if [[ "$_TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
