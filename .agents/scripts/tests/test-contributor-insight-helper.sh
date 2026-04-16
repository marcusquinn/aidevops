#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-contributor-insight-helper.sh — Unit tests for contributor-insight-helper.sh (t2147)
#
# Tests privacy sanitization, issue body composition, and dry-run filing.
#
# Usage: bash .agents/scripts/tests/test-contributor-insight-helper.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="${SCRIPT_DIR}/.."
HELPER="${PARENT_DIR}/contributor-insight-helper.sh"

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
		printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$description" "$expected" "$actual"
	fi
	return 0
}

assert_contains() {
	local description="$1"
	local needle="$2"
	local haystack="$3"
	_TESTS_RUN=$((_TESTS_RUN + 1))
	if [[ "$haystack" == *"$needle"* ]]; then
		_TESTS_PASSED=$((_TESTS_PASSED + 1))
		printf '  PASS: %s\n' "$description"
	else
		_TESTS_FAILED=$((_TESTS_FAILED + 1))
		printf '  FAIL: %s (needle not found in output)\n    needle: %s\n' "$description" "$needle"
	fi
	return 0
}

assert_not_contains() {
	local description="$1"
	local needle="$2"
	local haystack="$3"
	_TESTS_RUN=$((_TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		_TESTS_PASSED=$((_TESTS_PASSED + 1))
		printf '  PASS: %s\n' "$description"
	else
		_TESTS_FAILED=$((_TESTS_FAILED + 1))
		printf '  FAIL: %s (needle should NOT be present but was found)\n    needle: %s\n' "$description" "$needle"
	fi
	return 0
}

# --- Setup ---
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create test repos.json with a private repo
TEST_REPOS_JSON="${TMPDIR_TEST}/repos.json"
cat >"$TEST_REPOS_JSON" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "secret-corp/private-api",
      "local_only": true,
      "pulse": false
    },
    {
      "slug": "client/secret-project",
      "mirror_upstream": true,
      "pulse": false
    }
  ],
  "git_parent_dirs": []
}
JSON

# Create test compressed_signals.json
TEST_SIGNALS="${TMPDIR_TEST}/compressed_signals.json"
cat >"$TEST_SIGNALS" <<'JSON'
{
  "instruction_candidates": {
    ".agents/prompts/build.txt": [
      {
        "text": "we should always use worktrees, never branches directly at /Users/testuser/Git/secret-corp/private-api",
        "confidence": 0.80,
        "category": "git_workflow",
        "session_title": "Working on secret-corp/private-api feature"
      },
      {
        "text": "prefer printf over echo -e for bash 3.2 compat",
        "confidence": 0.75,
        "category": "code_style",
        "session_title": "Shell hardening session"
      },
      {
        "text": "low confidence throwaway",
        "confidence": 0.40,
        "category": "general",
        "session_title": "Random session"
      }
    ]
  },
  "errors": {
    "patterns": [
      {
        "tool": "edit",
        "error_category": "not_read_first",
        "count": 50,
        "model_count": 3,
        "models": ["sonnet", "haiku", "opus"],
        "severity": "high"
      },
      {
        "tool": "bash",
        "error_category": "file_not_found",
        "count": 200,
        "model_count": 4,
        "models": ["sonnet", "haiku", "opus", "gpt-4o"],
        "severity": "medium"
      },
      {
        "tool": "glob",
        "error_category": "other",
        "count": 5,
        "model_count": 1,
        "models": ["sonnet"],
        "severity": "low"
      }
    ]
  },
  "steerage": {}
}
JSON

echo "=== Sanitization Tests ==="

# Override REPOS_JSON for the helper
export REPOS_JSON="$TEST_REPOS_JSON"

# Source the helper functions for direct testing
# We can't source the whole file (it has main "$@"), so test via the CLI

# Test 1: Private slugs are redacted
result=$(bash "$HELPER" sanitize "Check secret-corp/private-api and client/secret-project repos")
assert_not_contains "private slug 1 redacted" "secret-corp/private-api" "$result"
assert_not_contains "private slug 2 redacted" "client/secret-project" "$result"
assert_contains "replacement present" "[private-repo]" "$result"

# Test 2: Home directory paths are redacted
result=$(bash "$HELPER" sanitize "Error at /Users/marcusquinn/Git/myproject/src/main.rs:42")
assert_not_contains "home path redacted" "/Users/marcusquinn" "$result"
assert_contains "path replacement present" "[local-path]" "$result"

# Test 3: API keys are redacted
result=$(bash "$HELPER" sanitize "Set OPENAI_API_KEY=sk-abc123def456ghi789jkl012mno345pqr678stu901vwx in your env")
assert_not_contains "API key redacted" "sk-abc123" "$result"
assert_contains "credential replacement present" "[redacted-credential]" "$result"

# Test 4: GitHub tokens are redacted
result=$(bash "$HELPER" sanitize "Use ghp_1234567890abcdefghijklmnop for auth")
assert_not_contains "GH token redacted" "ghp_1234567890" "$result"

# Test 5: Email addresses are redacted
result=$(bash "$HELPER" sanitize "Contact user@company.com for access")
assert_not_contains "email redacted" "user@company.com" "$result"
assert_contains "email replacement present" "[email]" "$result"

# Test 6: Safe text passes through unchanged
result=$(bash "$HELPER" sanitize "always use worktrees instead of branches")
assert_eq "safe text unchanged" "always use worktrees instead of branches" "$result"

echo ""
echo "=== Dry-Run Filing Tests ==="

# Test 7: dry-run with instruction candidates
output=$(bash "$HELPER" file --dry-run "$TEST_SIGNALS" "marcusquinn/aidevops" 2>&1) || true
assert_contains "dry-run mentions instruction candidates" "instruction candidate" "$output"
assert_contains "dry-run creates issue" "DRY RUN" "$output"

# Test 8: dry-run sanitizes content in issue body
assert_not_contains "issue body has no private slugs" "secret-corp/private-api" "$output"
assert_not_contains "issue body has no home paths" "/Users/testuser" "$output"

# Test 9: low-confidence candidates filtered out
assert_not_contains "low confidence filtered" "low confidence throwaway" "$output"

# Test 10: high-confidence candidates included
assert_contains "high confidence included" "worktrees" "$output"
assert_contains "bash compat included" "printf" "$output"

echo ""
echo "=== Error Pattern Tests ==="

# Test 11: high-frequency error patterns are included
assert_contains "edit:not_read_first in output" "not_read_first" "$output"
assert_contains "bash:file_not_found in output" "file_not_found" "$output"

# Test 12: low-frequency errors filtered (count < 20 or model_count < 2)
assert_not_contains "low-freq glob:other filtered" "glob:other" "$output"

echo ""
echo "=== Help Command ==="

# Test 13: help command works
help_output=$(bash "$HELPER" help 2>&1) || true
assert_contains "help shows usage" "Usage:" "$help_output"

echo ""
echo "Results: ${_TESTS_PASSED}/${_TESTS_RUN} passed, ${_TESTS_FAILED} failed"

if [[ "$_TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
