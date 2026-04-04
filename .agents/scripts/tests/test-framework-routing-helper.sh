#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-framework-routing-helper.sh - Tests for framework-routing-helper.sh
#
# Tests the is-framework detection logic with known framework and project
# task descriptions. Does NOT test log-framework-issue (requires gh CLI
# and network access).
#
# Usage: bash test-framework-routing-helper.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../framework-routing-helper.sh"

PASS=0
FAIL=0

assert_result() {
	local description="$1"
	local expected="$2"
	local input="$3"

	local actual
	actual=$("$HELPER" is-framework "$input" 2>/dev/null) || true

	if [[ "$actual" == "$expected" ]]; then
		PASS=$((PASS + 1))
		echo "  PASS: $description"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL: $description"
		echo "    Expected: $expected"
		echo "    Actual:   $actual"
		echo "    Input:    $input"
	fi
}

echo "=== Framework Routing Helper Tests ==="
echo ""

# --- Framework-level tasks (should return "framework") ---
echo "Framework-level tasks (expect: framework):"

assert_result "pulse-wrapper + dispatch" "framework" \
	"fix pulse-wrapper dispatch logic for model tier escalation"

assert_result "ai-lifecycle + supervisor" "framework" \
	"bug in ai-lifecycle.sh supervisor pipeline stdin consumption"

# shellcheck disable=SC2088 # Tilde is intentional — matching literal text
assert_result "~/.aidevops path + agent prompt" "framework" \
	"update ~/.aidevops/ agent prompt for cross-repo orchestration"

assert_result "claim-task-id + framework-routing" "framework" \
	"claim-task-id.sh should warn about framework-routing mismatches"

assert_result "pre-edit-check + worktree management" "framework" \
	"pre-edit-check.sh fails with worktree management edge case"

assert_result ".agents/ path + headless-runtime" "framework" \
	"fix .agents/scripts/headless-runtime-helper.sh provider rotation"

assert_result "prompts/build.txt + worker dispatch" "framework" \
	"update prompts/build.txt worker dispatch rules"

assert_result "session-miner + cross-repo" "framework" \
	"session-miner pulse fails with cross-repo orchestration"

echo ""

# --- Project-level tasks (should return "project") ---
echo "Project-level tasks (expect: project):"

assert_result "React component fix" "project" \
	"fix broken login form validation in React component"

assert_result "Database migration" "project" \
	"add database migration for user preferences table"

assert_result "CI pipeline fix" "project" \
	"fix failing Jest tests in the auth module"

assert_result "API endpoint" "project" \
	"implement REST API endpoint for user profile updates"

assert_result "CSS styling" "project" \
	"fix responsive layout issues on mobile devices"

assert_result "Package dependency" "project" \
	"upgrade lodash to fix security vulnerability CVE-2024-1234"

echo ""

# --- Uncertain tasks (should return "uncertain" — single indicator) ---
echo "Uncertain tasks (expect: uncertain):"

assert_result "Single mention of .agents/" "uncertain" \
	"check if .agents/ directory has correct permissions"

assert_result "Single mention of supervisor" "uncertain" \
	"supervisor process seems slow today"

echo ""

# --- Edge cases ---
echo "Edge cases:"

# Empty string: the script exits with error (usage message), producing no stdout
# This is correct behaviour — empty input is rejected, not classified
empty_result=$("$HELPER" is-framework "" 2>/dev/null) || true
if [[ -z "$empty_result" ]]; then
	PASS=$((PASS + 1))
	echo "  PASS: Empty string rejected (no output, exit 1)"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: Empty string should be rejected but got: $empty_result"
fi

assert_result "Mixed case indicators" "framework" \
	"Fix PULSE-WRAPPER dispatch for AI-LIFECYCLE model tier"

echo ""

# --- get-aidevops-path and get-aidevops-slug ---
echo "Path/slug resolution:"

aidevops_path=$("$HELPER" get-aidevops-path 2>/dev/null) || aidevops_path=""
if [[ -n "$aidevops_path" && -d "$aidevops_path" ]]; then
	PASS=$((PASS + 1))
	echo "  PASS: get-aidevops-path returned valid path: $aidevops_path"
else
	# This may fail in CI where the repo isn't at the expected path
	echo "  SKIP: get-aidevops-path (repo not found at expected location)"
fi

aidevops_slug=$("$HELPER" get-aidevops-slug 2>/dev/null) || aidevops_slug=""
if [[ -n "$aidevops_slug" && "$aidevops_slug" == *"aidevops"* ]]; then
	PASS=$((PASS + 1))
	echo "  PASS: get-aidevops-slug returned: $aidevops_slug"
else
	echo "  SKIP: get-aidevops-slug (slug not resolvable in this environment)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi

exit 0
