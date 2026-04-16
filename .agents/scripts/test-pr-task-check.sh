#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pr-task-check.sh — Local test harness for PR task ID CI check (t318.5)
#
# Validates the logic from the pr-task-check job in code-quality.yml
# by simulating various PR scenarios against the real TODO.md.
#
# Usage: .agents/scripts/test-pr-task-check.sh [--verbose]

set -euo pipefail

VERBOSE="${1:-}"
PASS=0
FAIL=0
TOTAL=0

# Colors (Pattern C — prefixed names, test harness only)
readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_YELLOW=$'\033[0;33m'
readonly TEST_RESET=$'\033[0m'

log() {
	echo -e "$1"
	return 0
}
verbose() {
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "  %s\n" "${TEST_YELLOW}$1${TEST_RESET}"
	fi
	return 0
}

# Run a single check_pr_task_id test case using a temporary TODO file.
# Creates the temp file, registers a trap for cleanup, runs the test, then
# removes the file.  This ensures the temp file is always cleaned up even if
# the script exits unexpectedly (style-guide line 33).
#
# Usage: run_with_temp_todo "<todo_content>" "<pr_title>" "<pr_branch>" "<expected>"
run_with_temp_todo() {
	local todo_content="$1"
	local pr_title="$2"
	local pr_branch="$3"
	local expected="$4"

	local temp_todo
	temp_todo=$(mktemp)
	# shellcheck disable=SC2064  # intentional: expand $temp_todo now so the
	#                              trap removes the correct file even if the
	#                              variable is later reassigned.
	trap "rm -f '$temp_todo'" EXIT
	printf '%s\n' "$todo_content" >"$temp_todo"
	check_pr_task_id "$pr_title" "$pr_branch" "$temp_todo" "$expected"
	rm -f "$temp_todo"
	trap - EXIT
	return 0
}

# --- Core logic extracted from code-quality.yml pr-task-check job ---

check_pr_task_id() {
	local pr_title="$1"
	local pr_branch="$2"
	local todo_file="$3"
	local expected="$4" # "pass", "fail-no-id", "fail-not-found", "fail-declined", "exempt"

	TOTAL=$((TOTAL + 1))
	local result=""
	local task_id=""

	# Exempted branch patterns (must match code-quality.yml exactly)
	local exempt_patterns=(
		"^dependabot/"
		"^auto-fix/"
		"^release/"
		"^hotfix/.*-emergency-"
	)

	for pattern in "${exempt_patterns[@]}"; do
		if [[ "$pr_branch" =~ $pattern ]]; then
			result="exempt"
			verbose "Branch '${pr_branch}' matches exemption '${pattern}'"
			break
		fi
	done

	if [[ -z "$result" ]]; then
		# Extract task ID from PR title first, then branch name
		if [[ "$pr_title" =~ (t[0-9]+(\.[0-9]+)*) ]]; then
			task_id="${BASH_REMATCH[1]}"
			verbose "Found task ID '${task_id}' in PR title"
		elif [[ "$pr_branch" =~ (t[0-9]+(\.[0-9]+)*) ]]; then
			task_id="${BASH_REMATCH[1]}"
			verbose "Found task ID '${task_id}' in branch name"
		fi

		if [[ -z "$task_id" ]]; then
			result="fail-no-id"
		elif [[ ! -f "$todo_file" ]]; then
			result="pass" # No TODO.md = skip check (graceful)
		elif grep -qE "^[[:space:]]*- \[-\] ${task_id} " "$todo_file"; then
			result="fail-declined"
		elif grep -qE "^[[:space:]]*- \[[ x]\] ${task_id} " "$todo_file"; then
			result="pass"
		else
			result="fail-not-found"
		fi
	fi

	if [[ "$result" == "$expected" ]]; then
		PASS=$((PASS + 1))
		log "${TEST_GREEN}PASS${TEST_RESET} [$result] title='$pr_title' branch='$pr_branch'"
	else
		FAIL=$((FAIL + 1))
		log "${TEST_RED}FAIL${TEST_RESET} expected=$expected got=$result title='$pr_title' branch='$pr_branch'"
	fi
	return 0
}

# --- Test cases ---

log ""
log "PR Task ID Check — Local Test Harness"
log "======================================"
log ""

TODO_FILE="TODO.md"

if [[ ! -f "$TODO_FILE" ]]; then
	log "${TEST_RED}ERROR: TODO.md not found. Run from repo root.${TEST_RESET}"
	exit 1
fi

log "Using TODO.md: $(wc -l <"$TODO_FILE") lines"
log ""

# --- Test Group 1: PRs WITHOUT task ID should FAIL ---
log "--- Test Group 1: PRs without task ID (should fail) ---"

check_pr_task_id \
	"Fix some random thing" \
	"feature/fix-random-thing" \
	"$TODO_FILE" \
	"fail-no-id"

check_pr_task_id \
	"Update documentation" \
	"docs/update-readme" \
	"$TODO_FILE" \
	"fail-no-id"

check_pr_task_id \
	"Refactor the auth module" \
	"refactor/auth-cleanup" \
	"$TODO_FILE" \
	"fail-no-id"

# --- Test Group 2: PRs WITH valid task ID should PASS ---
log ""
log "--- Test Group 2: PRs with valid task ID (should pass) ---"

check_pr_task_id \
	"t318.5: Test end-to-end PR task ID validation" \
	"feature/t318.5" \
	"$TODO_FILE" \
	"pass"

check_pr_task_id \
	"t318: Enforce TODO entry for all PRs" \
	"feature/t318-enforce-todo" \
	"$TODO_FILE" \
	"pass"

check_pr_task_id \
	"t318.1: Create GitHub Action CI check" \
	"feature/t318.1" \
	"$TODO_FILE" \
	"pass"

# Task ID in branch only (no title)
check_pr_task_id \
	"Some descriptive title without ID" \
	"feature/t318.3-update-workflow" \
	"$TODO_FILE" \
	"pass"

# --- Test Group 3: PRs with task ID NOT in TODO.md should FAIL ---
log ""
log "--- Test Group 3: PRs with non-existent task ID (should fail) ---"

check_pr_task_id \
	"t9999: This task does not exist" \
	"feature/t9999-nonexistent" \
	"$TODO_FILE" \
	"fail-not-found"

check_pr_task_id \
	"t0: Zero task" \
	"feature/t0" \
	"$TODO_FILE" \
	"fail-not-found"

check_pr_task_id \
	"t99999: Very high number" \
	"feature/t99999" \
	"$TODO_FILE" \
	"fail-not-found"

# --- Test Group 4: Exempted branches should PASS regardless ---
log ""
log "--- Test Group 4: Exempted branches (should be exempt) ---"

check_pr_task_id \
	"Bump lodash from 4.17.20 to 4.17.21" \
	"dependabot/npm_and_yarn/lodash-4.17.21" \
	"$TODO_FILE" \
	"exempt"

check_pr_task_id \
	"Auto-fix linting issues" \
	"auto-fix/shellcheck-2026-02-12" \
	"$TODO_FILE" \
	"exempt"

check_pr_task_id \
	"Release v2.111.0" \
	"release/v2.111.0" \
	"$TODO_FILE" \
	"exempt"

check_pr_task_id \
	"Emergency hotfix for auth" \
	"hotfix/auth-emergency-fix" \
	"$TODO_FILE" \
	"exempt"

# Non-emergency hotfix should NOT be exempt
check_pr_task_id \
	"Regular hotfix" \
	"hotfix/regular-fix" \
	"$TODO_FILE" \
	"fail-no-id"

# --- Test Group 5: Edge cases ---
log ""
log "--- Test Group 5: Edge cases ---"

# Task ID t318 should NOT match t318.5 (boundary check)
run_with_temp_todo \
	"- [ ] t318.5 Test task" \
	"t318: Parent task" \
	"feature/t318" \
	"fail-not-found"

# Task ID t318.5 should NOT match t318.50
run_with_temp_todo \
	"- [ ] t318.50 Different task" \
	"t318.5: Should not match t318.50" \
	"feature/t318.5" \
	"fail-not-found"

# Completed task [x] should still pass
run_with_temp_todo \
	"- [x] t999 Completed task" \
	"t999: Work on completed task" \
	"feature/t999" \
	"pass"

# Declined task [-] should fail
run_with_temp_todo \
	"- [-] t888 Declined task" \
	"t888: Work on declined task" \
	"feature/t888" \
	"fail-declined"

# Subtask with indentation
run_with_temp_todo \
	"  - [ ] t100.1 Indented subtask" \
	"t100.1: Subtask" \
	"feature/t100.1" \
	"pass"

# Sub-subtask (t100.1.1)
run_with_temp_todo \
	"    - [ ] t100.1.1 Deep subtask" \
	"t100.1.1: Deep subtask" \
	"feature/t100.1.1" \
	"pass"

# --- Test Group 6: Supervisor-created PR patterns ---
log ""
log "--- Test Group 6: Supervisor-created PR patterns ---"

check_pr_task_id \
	"t318.3: Update interactive PR workflow to require task ID in PR title" \
	"feature/t318.3" \
	"$TODO_FILE" \
	"pass"

check_pr_task_id \
	"t318.4: PR task ID backfill audit" \
	"feature/t318.4" \
	"$TODO_FILE" \
	"pass"

# --- Test Group 7: Real-world PR audit (recent PRs from this repo) ---
log ""
log "--- Test Group 7: Real-world PR patterns from this repo ---"

# Supervisor-dispatched worker PRs (should pass)
check_pr_task_id \
	"t318.2: Verify supervisor worker PRs include task ID" \
	"feature/t318.2" \
	"$TODO_FILE" \
	"pass"

# Full-loop worker PRs (should pass)
check_pr_task_id \
	"t318.1: Add PR task ID check GitHub Action" \
	"feature/t318.1" \
	"$TODO_FILE" \
	"pass"

# --- Summary ---
log ""
log "======================================"
log "Results: ${TEST_GREEN}${PASS} passed${TEST_RESET}, ${TEST_RED}${FAIL} failed${TEST_RESET}, ${TOTAL} total"
log ""

if [[ "$FAIL" -gt 0 ]]; then
	log "${TEST_RED}SOME TESTS FAILED${TEST_RESET}"
	exit 1
else
	log "${TEST_GREEN}ALL TESTS PASSED${TEST_RESET}"
	exit 0
fi
