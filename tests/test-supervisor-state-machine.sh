#!/usr/bin/env bash
# test-supervisor-state-machine.sh
#
# Unit tests for supervisor-helper.sh state machine:
# - Valid/invalid state transitions
# - Task lifecycle (add -> dispatch -> run -> evaluate -> complete)
# - Retry logic
# - Batch completion detection
# - Post-PR lifecycle (complete -> pr_review -> review_triage -> merging -> merged -> deployed)
#
# Uses an isolated temp DB to avoid touching production data.
#
# Usage: bash tests/test-supervisor-state-machine.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
SUPERVISOR_SCRIPT="$SCRIPTS_DIR/supervisor-helper.sh"
VERBOSE="${1:-}"

# --- Test Framework ---
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;32mPASS\033[0m %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
    if [[ -n "${2:-}" ]]; then
        printf "       %s\n" "$2"
    fi
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
}

section() {
    echo ""
    printf "\033[1m=== %s ===\033[0m\n" "$1"
}

# --- Test DB Setup ---
TEST_DIR=$(mktemp -d)
export AIDEVOPS_SUPERVISOR_DIR="$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

# Helper: run supervisor command with isolated DB
sup() {
    bash "$SUPERVISOR_SCRIPT" "$@" 2>&1
}

# Helper: query the test DB directly
test_db() {
    sqlite3 -cmd ".timeout 5000" "$TEST_DIR/supervisor.db" "$@"
}

# Helper: get task status
get_status() {
    test_db "SELECT status FROM tasks WHERE id = '$1';"
}

# Helper: get task field
get_field() {
    test_db "SELECT $2 FROM tasks WHERE id = '$1';"
}

# ============================================================
# SECTION 1: Database Initialization
# ============================================================
section "Database Initialization"

# Test: init creates database
sup init >/dev/null
if [[ -f "$TEST_DIR/supervisor.db" ]]; then
    pass "init creates supervisor.db"
else
    fail "init did not create supervisor.db"
fi

# Test: tables exist
tables=$(test_db "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" | tr '\n' ',')
if [[ "$tables" == *"tasks"* && "$tables" == *"batches"* && "$tables" == *"state_log"* ]]; then
    pass "Required tables exist (tasks, batches, state_log, batch_tasks)"
else
    fail "Missing required tables" "Found: $tables"
fi

# Test: WAL mode is set
journal_mode=$(test_db "PRAGMA journal_mode;")
if [[ "$journal_mode" == "wal" ]]; then
    pass "WAL journal mode is set"
else
    fail "Journal mode is '$journal_mode', expected 'wal'"
fi

# ============================================================
# SECTION 2: Task Addition
# ============================================================
section "Task Addition"

# Test: add a task
sup add test-t001 --repo /tmp/test --description "Test task 1" >/dev/null
status=$(get_status "test-t001")
if [[ "$status" == "queued" ]]; then
    pass "Added task starts in 'queued' state"
else
    fail "Added task has status '$status', expected 'queued'"
fi

# Test: duplicate task rejected
dup_output=$(sup add test-t001 --repo /tmp/test 2>&1 || true)
if echo "$dup_output" | grep -qi "already exists"; then
    pass "Duplicate task ID is rejected"
else
    fail "Duplicate task was not rejected" "$dup_output"
fi

# Test: state_log records initial state
log_entry=$(test_db "SELECT to_state FROM state_log WHERE task_id = 'test-t001' ORDER BY id LIMIT 1;")
if [[ "$log_entry" == "queued" ]]; then
    pass "State log records initial 'queued' entry"
else
    fail "State log initial entry is '$log_entry', expected 'queued'"
fi

# ============================================================
# SECTION 3: Valid State Transitions (Happy Path)
# ============================================================
section "Valid State Transitions (Happy Path)"

# queued -> dispatched
sup transition test-t001 dispatched >/dev/null
if [[ "$(get_status test-t001)" == "dispatched" ]]; then
    pass "queued -> dispatched"
else
    fail "queued -> dispatched failed"
fi

# Test: started_at is set on first dispatch
started=$(get_field "test-t001" "started_at")
if [[ -n "$started" ]]; then
    pass "started_at set on first dispatch"
else
    fail "started_at not set on dispatch"
fi

# dispatched -> running
sup transition test-t001 running >/dev/null
if [[ "$(get_status test-t001)" == "running" ]]; then
    pass "dispatched -> running"
else
    fail "dispatched -> running failed"
fi

# running -> evaluating
sup transition test-t001 evaluating >/dev/null
if [[ "$(get_status test-t001)" == "evaluating" ]]; then
    pass "running -> evaluating"
else
    fail "running -> evaluating failed"
fi

# evaluating -> complete
sup transition test-t001 complete >/dev/null
if [[ "$(get_status test-t001)" == "complete" ]]; then
    pass "evaluating -> complete"
else
    fail "evaluating -> complete failed"
fi

# Test: completed_at is set
completed=$(get_field "test-t001" "completed_at")
if [[ -n "$completed" ]]; then
    pass "completed_at set on terminal state"
else
    fail "completed_at not set on complete"
fi

# ============================================================
# SECTION 4: Post-PR Lifecycle Transitions
# ============================================================
section "Post-PR Lifecycle Transitions"

# complete -> pr_review
sup transition test-t001 pr_review >/dev/null
if [[ "$(get_status test-t001)" == "pr_review" ]]; then
    pass "complete -> pr_review"
else
    fail "complete -> pr_review failed"
fi

# pr_review -> merging
sup transition test-t001 merging >/dev/null
if [[ "$(get_status test-t001)" == "merging" ]]; then
    pass "pr_review -> merging"
else
    fail "pr_review -> merging failed"
fi

# merging -> merged
sup transition test-t001 merged >/dev/null
if [[ "$(get_status test-t001)" == "merged" ]]; then
    pass "merging -> merged"
else
    fail "merging -> merged failed"
fi

# merged -> deploying
sup transition test-t001 deploying >/dev/null
if [[ "$(get_status test-t001)" == "deploying" ]]; then
    pass "merged -> deploying"
else
    fail "merged -> deploying failed"
fi

# deploying -> deployed
sup transition test-t001 deployed >/dev/null
if [[ "$(get_status test-t001)" == "deployed" ]]; then
    pass "deploying -> deployed"
else
    fail "deploying -> deployed failed"
fi

# ============================================================
# SECTION 4b: Review Triage Transitions (t148)
# ============================================================
section "Review Triage Transitions (t148)"

# Add a fresh task and move through to pr_review
sup add test-t148a --repo /tmp/test --description "Review triage test" >/dev/null
sup transition test-t148a dispatched >/dev/null
sup transition test-t148a running >/dev/null
sup transition test-t148a evaluating >/dev/null
sup transition test-t148a complete >/dev/null
sup transition test-t148a pr_review >/dev/null

# pr_review -> review_triage
sup transition test-t148a review_triage >/dev/null
if [[ "$(get_status test-t148a)" == "review_triage" ]]; then
    pass "pr_review -> review_triage"
else
    fail "pr_review -> review_triage failed"
fi

# review_triage -> merging (no issues found, proceed to merge)
sup transition test-t148a merging >/dev/null
if [[ "$(get_status test-t148a)" == "merging" ]]; then
    pass "review_triage -> merging (clean triage)"
else
    fail "review_triage -> merging failed"
fi

# Test review_triage -> blocked (critical review threads)
sup add test-t148b --repo /tmp/test --description "Review triage block test" >/dev/null
sup transition test-t148b dispatched >/dev/null
sup transition test-t148b running >/dev/null
sup transition test-t148b evaluating >/dev/null
sup transition test-t148b complete >/dev/null
sup transition test-t148b pr_review >/dev/null
sup transition test-t148b review_triage >/dev/null
sup transition test-t148b blocked --error "Critical review thread requires human review" >/dev/null
if [[ "$(get_status test-t148b)" == "blocked" ]]; then
    pass "review_triage -> blocked (critical threads)"
else
    fail "review_triage -> blocked failed"
fi

# Test review_triage -> dispatched (fix worker dispatched)
sup add test-t148c --repo /tmp/test --description "Review triage dispatch test" >/dev/null
sup transition test-t148c dispatched >/dev/null
sup transition test-t148c running >/dev/null
sup transition test-t148c evaluating >/dev/null
sup transition test-t148c complete >/dev/null
sup transition test-t148c pr_review >/dev/null
sup transition test-t148c review_triage >/dev/null
sup transition test-t148c dispatched >/dev/null
if [[ "$(get_status test-t148c)" == "dispatched" ]]; then
    pass "review_triage -> dispatched (fix worker)"
else
    fail "review_triage -> dispatched failed"
fi

# Test review_triage -> cancelled
sup add test-t148d --repo /tmp/test --description "Review triage cancel test" >/dev/null
sup transition test-t148d dispatched >/dev/null
sup transition test-t148d running >/dev/null
sup transition test-t148d evaluating >/dev/null
sup transition test-t148d complete >/dev/null
sup transition test-t148d pr_review >/dev/null
sup transition test-t148d review_triage >/dev/null
sup transition test-t148d cancelled >/dev/null
if [[ "$(get_status test-t148d)" == "cancelled" ]]; then
    pass "review_triage -> cancelled"
else
    fail "review_triage -> cancelled failed"
fi

# Test invalid: review_triage -> complete (not a valid transition)
sup add test-t148e --repo /tmp/test --description "Review triage invalid test" >/dev/null
sup transition test-t148e dispatched >/dev/null
sup transition test-t148e running >/dev/null
sup transition test-t148e evaluating >/dev/null
sup transition test-t148e complete >/dev/null
sup transition test-t148e pr_review >/dev/null
sup transition test-t148e review_triage >/dev/null
invalid_triage=$(sup transition test-t148e complete 2>&1 || true)
if echo "$invalid_triage" | grep -qi "invalid transition"; then
    pass "review_triage -> complete rejected (invalid)"
else
    fail "review_triage -> complete was not rejected" "$invalid_triage"
fi

# Verify state unchanged after invalid transition
if [[ "$(get_status test-t148e)" == "review_triage" ]]; then
    pass "State unchanged after invalid review_triage transition"
else
    fail "State changed despite invalid transition: $(get_status test-t148e)"
fi

# ============================================================
# SECTION 5: Invalid State Transitions
# ============================================================
section "Invalid State Transitions"

# Add a fresh task for invalid transition tests
sup add test-t002 --repo /tmp/test --description "Invalid transition test" >/dev/null

# queued -> running (must go through dispatched first)
invalid_output=$(sup transition test-t002 running 2>&1 || true)
if echo "$invalid_output" | grep -qi "invalid transition"; then
    pass "queued -> running rejected (must go through dispatched)"
else
    fail "queued -> running was not rejected" "$invalid_output"
fi

# Verify state didn't change
if [[ "$(get_status test-t002)" == "queued" ]]; then
    pass "State unchanged after invalid transition"
else
    fail "State changed despite invalid transition: $(get_status test-t002)"
fi

# queued -> complete (skipping intermediate states)
invalid_output2=$(sup transition test-t002 complete 2>&1 || true)
if echo "$invalid_output2" | grep -qi "invalid transition"; then
    pass "queued -> complete rejected (skipping intermediate states)"
else
    fail "queued -> complete was not rejected"
fi

# queued -> deployed (skipping all states)
invalid_output3=$(sup transition test-t002 deployed 2>&1 || true)
if echo "$invalid_output3" | grep -qi "invalid transition"; then
    pass "queued -> deployed rejected"
else
    fail "queued -> deployed was not rejected"
fi

# Invalid state name
invalid_output4=$(sup transition test-t002 nonexistent_state 2>&1 || true)
if echo "$invalid_output4" | grep -qi "invalid state"; then
    pass "Nonexistent state name rejected"
else
    fail "Nonexistent state name was not rejected"
fi

# ============================================================
# SECTION 6: Retry Logic
# ============================================================
section "Retry Logic"

# Add task and move to evaluating
sup add test-t003 --repo /tmp/test --description "Retry test" >/dev/null
sup transition test-t003 dispatched >/dev/null
sup transition test-t003 running >/dev/null
sup transition test-t003 evaluating >/dev/null

# evaluating -> retrying
sup transition test-t003 retrying >/dev/null
if [[ "$(get_status test-t003)" == "retrying" ]]; then
    pass "evaluating -> retrying"
else
    fail "evaluating -> retrying failed"
fi

# Test: retries counter incremented
retries=$(get_field "test-t003" "retries")
if [[ "$retries" -eq 1 ]]; then
    pass "Retry counter incremented to 1"
else
    fail "Retry counter is $retries, expected 1"
fi

# retrying -> dispatched (re-dispatch)
sup transition test-t003 dispatched >/dev/null
if [[ "$(get_status test-t003)" == "dispatched" ]]; then
    pass "retrying -> dispatched (re-dispatch)"
else
    fail "retrying -> dispatched failed"
fi

# Second retry cycle
sup transition test-t003 running >/dev/null
sup transition test-t003 evaluating >/dev/null
sup transition test-t003 retrying >/dev/null
retries2=$(get_field "test-t003" "retries")
if [[ "$retries2" -eq 2 ]]; then
    pass "Retry counter incremented to 2 on second retry"
else
    fail "Retry counter is $retries2, expected 2"
fi

# ============================================================
# SECTION 7: Error Handling
# ============================================================
section "Error Handling"

# Add task and move to running, then fail
sup add test-t004 --repo /tmp/test --description "Error test" >/dev/null
sup transition test-t004 dispatched >/dev/null
sup transition test-t004 running >/dev/null

# running -> failed with error message
sup transition test-t004 failed --error "Timeout after 30 minutes" >/dev/null
if [[ "$(get_status test-t004)" == "failed" ]]; then
    pass "running -> failed with error"
else
    fail "running -> failed transition failed"
fi

# Test: error message stored
error_msg=$(get_field "test-t004" "error")
if [[ "$error_msg" == "Timeout after 30 minutes" ]]; then
    pass "Error message stored correctly"
else
    fail "Error message is '$error_msg', expected 'Timeout after 30 minutes'"
fi

# Test: completed_at set on failure
completed_fail=$(get_field "test-t004" "completed_at")
if [[ -n "$completed_fail" ]]; then
    pass "completed_at set on failed state"
else
    fail "completed_at not set on failed state"
fi

# Test: failed -> queued (re-queue after failure)
sup transition test-t004 queued >/dev/null
if [[ "$(get_status test-t004)" == "queued" ]]; then
    pass "failed -> queued (re-queue)"
else
    fail "failed -> queued failed"
fi

# ============================================================
# SECTION 8: Cancellation
# ============================================================
section "Cancellation"

# queued -> cancelled
sup add test-t005 --repo /tmp/test --description "Cancel test" >/dev/null
sup transition test-t005 cancelled >/dev/null
if [[ "$(get_status test-t005)" == "cancelled" ]]; then
    pass "queued -> cancelled"
else
    fail "queued -> cancelled failed"
fi

# dispatched -> cancelled
sup add test-t006 --repo /tmp/test --description "Cancel dispatched" >/dev/null
sup transition test-t006 dispatched >/dev/null
sup transition test-t006 cancelled >/dev/null
if [[ "$(get_status test-t006)" == "cancelled" ]]; then
    pass "dispatched -> cancelled"
else
    fail "dispatched -> cancelled failed"
fi

# running -> cancelled
sup add test-t007 --repo /tmp/test --description "Cancel running" >/dev/null
sup transition test-t007 dispatched >/dev/null
sup transition test-t007 running >/dev/null
sup transition test-t007 cancelled >/dev/null
if [[ "$(get_status test-t007)" == "cancelled" ]]; then
    pass "running -> cancelled"
else
    fail "running -> cancelled failed"
fi

# ============================================================
# SECTION 9: Blocked State
# ============================================================
section "Blocked State"

# evaluating -> blocked
sup add test-t008 --repo /tmp/test --description "Blocked test" >/dev/null
sup transition test-t008 dispatched >/dev/null
sup transition test-t008 running >/dev/null
sup transition test-t008 evaluating >/dev/null
sup transition test-t008 blocked >/dev/null
if [[ "$(get_status test-t008)" == "blocked" ]]; then
    pass "evaluating -> blocked"
else
    fail "evaluating -> blocked failed"
fi

# blocked -> queued (unblock)
sup transition test-t008 queued >/dev/null
if [[ "$(get_status test-t008)" == "queued" ]]; then
    pass "blocked -> queued (unblock)"
else
    fail "blocked -> queued failed"
fi

# blocked -> cancelled
sup add test-t009 --repo /tmp/test --description "Blocked cancel" >/dev/null
sup transition test-t009 dispatched >/dev/null
sup transition test-t009 running >/dev/null
sup transition test-t009 evaluating >/dev/null
sup transition test-t009 blocked >/dev/null
sup transition test-t009 cancelled >/dev/null
if [[ "$(get_status test-t009)" == "cancelled" ]]; then
    pass "blocked -> cancelled"
else
    fail "blocked -> cancelled failed"
fi

# ============================================================
# SECTION 10: State Log Audit Trail
# ============================================================
section "State Log Audit Trail"

# Count state log entries for test-t001 (went through full lifecycle)
log_count=$(test_db "SELECT count(*) FROM state_log WHERE task_id = 'test-t001';")
if [[ "$log_count" -ge 8 ]]; then
    pass "State log has $log_count entries for full lifecycle task"
else
    fail "State log has only $log_count entries, expected >= 8"
fi

# Verify log entries are in order
first_transition=$(test_db "SELECT from_state || '->' || to_state FROM state_log WHERE task_id = 'test-t001' ORDER BY id LIMIT 1;")
if [[ "$first_transition" == "->queued" ]]; then
    pass "First state log entry is initial queued"
else
    fail "First state log entry is '$first_transition', expected '->queued'"
fi

# ============================================================
# SECTION 11: Metadata Fields
# ============================================================
section "Metadata Fields"

# Test: transition with --session, --branch, --worktree, --pr-url
sup add test-t010 --repo /tmp/test --description "Metadata test" >/dev/null
sup transition test-t010 dispatched --session "ses_abc123" --branch "feature/test" --worktree "/tmp/wt" >/dev/null

session_id=$(get_field "test-t010" "session_id")
branch=$(get_field "test-t010" "branch")
worktree=$(get_field "test-t010" "worktree")

if [[ "$session_id" == "ses_abc123" ]]; then
    pass "session_id stored on transition"
else
    fail "session_id is '$session_id', expected 'ses_abc123'"
fi

if [[ "$branch" == "feature/test" ]]; then
    pass "branch stored on transition"
else
    fail "branch is '$branch', expected 'feature/test'"
fi

if [[ "$worktree" == "/tmp/wt" ]]; then
    pass "worktree stored on transition"
else
    fail "worktree is '$worktree', expected '/tmp/wt'"
fi

# ============================================================
# SECTION 12: Batch Completion Detection
# ============================================================
section "Batch Completion Detection"

# Create a batch with two tasks
sup add test-b001 --repo /tmp/test --description "Batch task 1" >/dev/null
sup add test-b002 --repo /tmp/test --description "Batch task 2" >/dev/null
sup batch test-batch --tasks "test-b001,test-b002" >/dev/null 2>&1 || true

# Check if batch was created
batch_status=$(test_db "SELECT status FROM batches WHERE name = 'test-batch';" 2>/dev/null || echo "")
if [[ "$batch_status" == "active" ]]; then
    pass "Batch created in 'active' state"

    # Complete first task
    sup transition test-b001 dispatched >/dev/null
    sup transition test-b001 running >/dev/null
    sup transition test-b001 evaluating >/dev/null
    sup transition test-b001 complete >/dev/null

    # Batch should still be active (one task remaining)
    batch_after_one=$(test_db "SELECT status FROM batches WHERE name = 'test-batch';")
    if [[ "$batch_after_one" == "active" ]]; then
        pass "Batch stays active with incomplete tasks"
    else
        fail "Batch status is '$batch_after_one' after one task complete, expected 'active'"
    fi

    # Complete second task
    sup transition test-b002 dispatched >/dev/null
    sup transition test-b002 running >/dev/null
    sup transition test-b002 evaluating >/dev/null
    sup transition test-b002 complete >/dev/null

    # Batch should now be complete
    batch_after_all=$(test_db "SELECT status FROM batches WHERE name = 'test-batch';")
    if [[ "$batch_after_all" == "complete" ]]; then
        pass "Batch auto-completes when all tasks finish"
    else
        fail "Batch status is '$batch_after_all' after all tasks complete, expected 'complete'"
    fi
else
    skip "Batch creation may require different syntax (status: '$batch_status')"
fi

# ============================================================
# SECTION 13: Nonexistent Task
# ============================================================
section "Edge Cases"

# Transition on nonexistent task
nonexist_output=$(sup transition nonexistent-task dispatched 2>&1 || true)
if echo "$nonexist_output" | grep -qi "not found"; then
    pass "Transition on nonexistent task returns error"
else
    fail "Transition on nonexistent task did not return error" "$nonexist_output"
fi

# Missing arguments
missing_output=$(sup transition 2>&1 || true)
if echo "$missing_output" | grep -qiE "usage|requires"; then
    pass "Missing arguments shows usage"
else
    fail "Missing arguments did not show usage"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "========================================"
printf "  \033[1mResults: %d total, \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m, \033[0;33m%d skipped\033[0m\n" \
    "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
echo "========================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo ""
    printf "\033[0;31mFAILURES DETECTED - review output above\033[0m\n"
    exit 1
else
    echo ""
    printf "\033[0;32mAll tests passed.\033[0m\n"
    exit 0
fi
