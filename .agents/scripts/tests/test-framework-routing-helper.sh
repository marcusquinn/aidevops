#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-framework-routing-helper.sh - Tests for framework-routing-helper.sh
#
# Tests the is-framework detection logic with known framework and project
# task descriptions, plus offline log-framework-issue regression paths with a
# stubbed gh CLI.
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
	return 0
}

assert_contains() {
	local output="$1"
	local expected="$2"
	local description="$3"

	if grep -Fq -- "$expected" <<<"$output"; then
		PASS=$((PASS + 1))
		echo "  PASS: $description"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL: $description"
		echo "    Expected output to contain: $expected"
		echo "    Output: $output"
	fi
	return 0
}

assert_not_contains() {
	local output="$1"
	local unexpected="$2"
	local description="$3"

	if grep -Fq -- "$unexpected" <<<"$output"; then
		FAIL=$((FAIL + 1))
		echo "  FAIL: $description"
		echo "    Output unexpectedly contained: $unexpected"
		echo "    Output: $output"
	else
		PASS=$((PASS + 1))
		echo "  PASS: $description"
	fi
	return 0
}

run_log_framework_issue_case() {
	local duplicate_value="$1"
	local output_file="$2"
	local trace_file="$3"
	local tmp_home="$4"
	local stub_dir="$5"

	mkdir -p "$stub_dir"
	cat >"${stub_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$TEST_GH_TRACE"

if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	case "${TEST_DUPLICATE_VALUE:-}" in
		"[]"|"null")
			printf '\n'
			;;
		*)
			printf '%s\n' "${TEST_DUPLICATE_VALUE:-}"
			;;
	esac
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
	printf '%s\n' "https://github.com/marcusquinn/aidevops/issues/9104"
	exit 0
fi

if [[ "${1:-}" == "api" ]]; then
	printf '{}\n'
	exit 0
fi

exit 0
EOF
	chmod +x "${stub_dir}/gh"

	mkdir -p "${tmp_home}/.config/aidevops"
	cat >"${tmp_home}/.config/aidevops/repos.json" <<'EOF'
{"initialized_repos":[{"slug":"marcusquinn/aidevops","path":"/tmp/aidevops"}]}
EOF

	if HOME="$tmp_home" \
		PATH="${stub_dir}:$PATH" \
		TEST_DUPLICATE_VALUE="$duplicate_value" \
		TEST_GH_TRACE="$trace_file" \
		LOG_ISSUE_DEDUP_FILE="${tmp_home}/dedup.jsonl" \
		"$HELPER" log-framework-issue \
			--title "fix: no result dedup" \
			--body "body" \
			--labels "bug" >"$output_file" 2>&1; then
		return 0
	fi

	return 1
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

# --- log-framework-issue dedup parsing ---
echo "log-framework-issue dedup parsing:"

TMP_DIR=$(mktemp -d -t framework-routing-helper-test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

empty_array_output="${TMP_DIR}/empty-array.out"
empty_array_trace="${TMP_DIR}/empty-array.trace"
if run_log_framework_issue_case "[]" "$empty_array_output" "$empty_array_trace" "${TMP_DIR}/home-empty-array" "${TMP_DIR}/stub-empty-array"; then
	empty_array_text=$(<"$empty_array_output")
	empty_array_calls=$(<"$empty_array_trace")
	assert_contains "$empty_array_text" "https://github.com/marcusquinn/aidevops/issues/9104" "empty array issue-list result creates issue"
	assert_contains "$empty_array_calls" "issue create" "empty array issue-list result reaches issue creation"
	assert_not_contains "$empty_array_text" "Duplicate found (search): []" "empty array issue-list result is not duplicate"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: empty array issue-list result creates issue"
	cat "$empty_array_output" 2>/dev/null || true
fi

null_output="${TMP_DIR}/null.out"
null_trace="${TMP_DIR}/null.trace"
if run_log_framework_issue_case "null" "$null_output" "$null_trace" "${TMP_DIR}/home-null" "${TMP_DIR}/stub-null"; then
	null_text=$(<"$null_output")
	null_calls=$(<"$null_trace")
	assert_contains "$null_text" "https://github.com/marcusquinn/aidevops/issues/9104" "null issue-list result creates issue"
	assert_contains "$null_calls" "issue create" "null issue-list result reaches issue creation"
	assert_not_contains "$null_text" "Duplicate found (search): null" "null issue-list result is not duplicate"
else
	FAIL=$((FAIL + 1))
	echo "  FAIL: null issue-list result creates issue"
	cat "$null_output" 2>/dev/null || true
fi

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
