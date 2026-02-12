#!/usr/bin/env bash
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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "$1"; }
verbose() { [[ "$VERBOSE" == "--verbose" ]] && echo -e "  ${YELLOW}$1${NC}" || true; }

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
        log "${GREEN}PASS${NC} [$result] title='$pr_title' branch='$pr_branch'"
    else
        FAIL=$((FAIL + 1))
        log "${RED}FAIL${NC} expected=$expected got=$result title='$pr_title' branch='$pr_branch'"
    fi
}

# --- Test cases ---

log ""
log "PR Task ID Check — Local Test Harness"
log "======================================"
log ""

TODO_FILE="TODO.md"

if [[ ! -f "$TODO_FILE" ]]; then
    log "${RED}ERROR: TODO.md not found. Run from repo root.${NC}"
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
TEMP_TODO=$(mktemp)
echo "- [ ] t318.5 Test task" >"$TEMP_TODO"
check_pr_task_id \
    "t318: Parent task" \
    "feature/t318" \
    "$TEMP_TODO" \
    "fail-not-found"
rm -f "$TEMP_TODO"

# Task ID t318.5 should NOT match t318.50
TEMP_TODO=$(mktemp)
echo "- [ ] t318.50 Different task" >"$TEMP_TODO"
check_pr_task_id \
    "t318.5: Should not match t318.50" \
    "feature/t318.5" \
    "$TEMP_TODO" \
    "fail-not-found"
rm -f "$TEMP_TODO"

# Completed task [x] should still pass
TEMP_TODO=$(mktemp)
echo "- [x] t999 Completed task" >"$TEMP_TODO"
check_pr_task_id \
    "t999: Work on completed task" \
    "feature/t999" \
    "$TEMP_TODO" \
    "pass"
rm -f "$TEMP_TODO"

# Declined task [-] should fail
TEMP_TODO=$(mktemp)
echo "- [-] t888 Declined task" >"$TEMP_TODO"
check_pr_task_id \
    "t888: Work on declined task" \
    "feature/t888" \
    "$TEMP_TODO" \
    "fail-declined"
rm -f "$TEMP_TODO"

# Subtask with indentation
TEMP_TODO=$(mktemp)
echo "  - [ ] t100.1 Indented subtask" >"$TEMP_TODO"
check_pr_task_id \
    "t100.1: Subtask" \
    "feature/t100.1" \
    "$TEMP_TODO" \
    "pass"
rm -f "$TEMP_TODO"

# Sub-subtask (t100.1.1)
TEMP_TODO=$(mktemp)
echo "    - [ ] t100.1.1 Deep subtask" >"$TEMP_TODO"
check_pr_task_id \
    "t100.1.1: Deep subtask" \
    "feature/t100.1.1" \
    "$TEMP_TODO" \
    "pass"
rm -f "$TEMP_TODO"

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
log "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${TOTAL} total"
log ""

if [[ "$FAIL" -gt 0 ]]; then
    log "${RED}SOME TESTS FAILED${NC}"
    exit 1
else
    log "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
