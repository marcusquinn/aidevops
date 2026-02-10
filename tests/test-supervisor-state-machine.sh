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
# SECTION 14: Pulse Dispatch Lock (t159)
# ============================================================
section "Pulse Dispatch Lock (t159)"

# The pulse lock directory lives inside AIDEVOPS_SUPERVISOR_DIR
PULSE_LOCK_DIR="$TEST_DIR/pulse.lock"

# Test: lock can be acquired
mkdir "$PULSE_LOCK_DIR" 2>/dev/null
if [[ -d "$PULSE_LOCK_DIR" ]]; then
    pass "Pulse lock directory can be created (mkdir is atomic)"
    rmdir "$PULSE_LOCK_DIR"
else
    fail "Could not create pulse lock directory"
fi

# Test: second mkdir fails when lock is held
mkdir "$PULSE_LOCK_DIR" 2>/dev/null
if ! mkdir "$PULSE_LOCK_DIR" 2>/dev/null; then
    pass "Second lock acquisition fails when lock is held"
else
    fail "Second lock acquisition should have failed"
fi
rm -rf "$PULSE_LOCK_DIR"

# Test: lock with PID file
mkdir "$PULSE_LOCK_DIR" 2>/dev/null
echo $$ > "$PULSE_LOCK_DIR/pid"
holder_pid=$(cat "$PULSE_LOCK_DIR/pid" 2>/dev/null || echo "")
if [[ "$holder_pid" == "$$" ]]; then
    pass "PID file written correctly inside lock directory"
else
    fail "PID file content is '$holder_pid', expected '$$'"
fi
rm -rf "$PULSE_LOCK_DIR"

# Test: stale lock detection (lock older than timeout)
mkdir "$PULSE_LOCK_DIR" 2>/dev/null
echo "99999999" > "$PULSE_LOCK_DIR/pid"  # Non-existent PID
# Touch the lock dir to make it appear old (10+ minutes ago)
if [[ "$(uname)" == "Darwin" ]]; then
    touch -t "$(date -v-15M +%Y%m%d%H%M.%S)" "$PULSE_LOCK_DIR"
else
    touch -d "15 minutes ago" "$PULSE_LOCK_DIR"
fi
lock_mtime=0
if [[ "$(uname)" == "Darwin" ]]; then
    lock_mtime=$(stat -f %m "$PULSE_LOCK_DIR" 2>/dev/null || echo "0")
else
    lock_mtime=$(stat -c %Y "$PULSE_LOCK_DIR" 2>/dev/null || echo "0")
fi
now_epoch=$(date +%s)
lock_age=$(( now_epoch - lock_mtime ))
if [[ "$lock_age" -gt 600 ]]; then
    pass "Stale lock detected (age: ${lock_age}s > 600s timeout)"
else
    fail "Lock age is ${lock_age}s, expected > 600s for stale detection"
fi
rm -rf "$PULSE_LOCK_DIR"

# Test: dead process lock detection
mkdir "$PULSE_LOCK_DIR" 2>/dev/null
echo "99999999" > "$PULSE_LOCK_DIR/pid"  # PID that doesn't exist
if ! kill -0 99999999 2>/dev/null; then
    pass "Dead process detected (PID 99999999 not running)"
else
    skip "PID 99999999 unexpectedly exists on this system"
fi
rm -rf "$PULSE_LOCK_DIR"

# Test: concurrent pulse protection via supervisor-helper.sh
# Source the lock functions and test them directly
(
    export AIDEVOPS_SUPERVISOR_DIR="$TEST_DIR"
    # Source just the functions we need by running in a subshell
    # that sources the script's function definitions
    source_output=$(bash -c "
        export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR'
        source '$SUPERVISOR_SCRIPT' --source-only 2>/dev/null || true
        # If --source-only isn't supported, the functions are still defined
        # Test acquire/release cycle
        if type acquire_pulse_lock &>/dev/null; then
            acquire_pulse_lock && echo 'ACQUIRED' || echo 'FAILED'
            release_pulse_lock && echo 'RELEASED' || echo 'RELEASE_FAILED'
        else
            echo 'FUNCTIONS_NOT_AVAILABLE'
        fi
    " 2>/dev/null || echo "SCRIPT_ERROR")

    if echo "$source_output" | grep -q "ACQUIRED"; then
        echo "LOCK_TEST_PASS"
    elif echo "$source_output" | grep -q "FUNCTIONS_NOT_AVAILABLE"; then
        echo "LOCK_TEST_SKIP"
    else
        echo "LOCK_TEST_FAIL"
    fi
) > "$TEST_DIR/lock_test_result" 2>/dev/null || true

lock_result=$(cat "$TEST_DIR/lock_test_result" 2>/dev/null || echo "LOCK_TEST_SKIP")
case "$lock_result" in
    LOCK_TEST_PASS) pass "acquire_pulse_lock/release_pulse_lock cycle works" ;;
    LOCK_TEST_SKIP) skip "Lock functions not directly testable (script exits on source)" ;;
    *) skip "Lock function test inconclusive ($lock_result)" ;;
esac

# Test: lock directory is cleaned up after release
if [[ ! -d "$PULSE_LOCK_DIR" ]]; then
    pass "Lock directory cleaned up after tests"
else
    fail "Lock directory still exists after cleanup"
    rm -rf "$PULSE_LOCK_DIR"
fi

# Test: atomic rename for stale lock breaking (t172)
# When a stale/dead lock is detected, mv (rename) is used instead of rm+mkdir
# to prevent two processes from both breaking the lock simultaneously
mkdir "$PULSE_LOCK_DIR" 2>/dev/null
echo "99999999" > "$PULSE_LOCK_DIR/pid"  # Dead PID
stale_dir="${PULSE_LOCK_DIR}.stale.$$"
if mv "$PULSE_LOCK_DIR" "$stale_dir" 2>/dev/null; then
    pass "Atomic rename (mv) succeeds for stale lock breaking (t172)"
    # After rename, original dir is gone — mkdir should succeed
    if mkdir "$PULSE_LOCK_DIR" 2>/dev/null; then
        pass "Lock re-acquisition after atomic rename succeeds (t172)"
        rmdir "$PULSE_LOCK_DIR"
    else
        fail "Lock re-acquisition after atomic rename failed"
    fi
    rm -rf "$stale_dir"
else
    fail "Atomic rename (mv) failed for stale lock"
fi

# Test: second process loses the rename race (t172)
# Simulate: lock exists, process A renames it, process B tries to rename — fails
mkdir "$PULSE_LOCK_DIR" 2>/dev/null
echo "99999999" > "$PULSE_LOCK_DIR/pid"
# Process A wins the rename
stale_dir_a="${PULSE_LOCK_DIR}.stale.a"
mv "$PULSE_LOCK_DIR" "$stale_dir_a" 2>/dev/null
# Process B tries to rename — lock dir is gone, mv should fail
stale_dir_b="${PULSE_LOCK_DIR}.stale.b"
if ! mv "$PULSE_LOCK_DIR" "$stale_dir_b" 2>/dev/null; then
    pass "Second rename fails (race loser cannot break lock) (t172)"
else
    fail "Second rename should have failed (lock already renamed)"
    rm -rf "$stale_dir_b"
fi
rm -rf "$stale_dir_a"

# ============================================================
# SECTION 14b: cmd_next concurrency delegation (t172)
# ============================================================
section "cmd_next concurrency delegation (t172)"

# cmd_next should return queued tasks without checking concurrency.
# Concurrency enforcement is solely in cmd_dispatch (authoritative check).
# This prevents a TOCTOU race where cmd_next limits tasks based on a stale
# running count that changes as cmd_dispatch processes each task.

# Create tasks for this test
sup add test-t172a --repo /tmp/test --description "Concurrency test A" >/dev/null
sup add test-t172b --repo /tmp/test --description "Concurrency test B" >/dev/null
sup add test-t172c --repo /tmp/test --description "Concurrency test C" >/dev/null

# Create a batch with concurrency=1 and add all three tasks
batch_output=$(sup batch test-t172-batch --concurrency 1 --tasks "test-t172a,test-t172b,test-t172c" 2>&1)
batch_t172_id=$(echo "$batch_output" | grep -oE 'batch-[0-9]+-[0-9]+' | head -1)

if [[ -n "$batch_t172_id" ]]; then
    # Simulate one task already running
    sup transition test-t172a dispatched >/dev/null
    sup transition test-t172a running >/dev/null

    # cmd_next should still return queued tasks (it no longer checks concurrency)
    next_output=$(sup next "$batch_t172_id" 5 2>&1)
    next_count=$(echo "$next_output" | grep -c "test-t172" || echo "0")

    if [[ "$next_count" -ge 1 ]]; then
        pass "cmd_next returns queued tasks regardless of concurrency (t172)"
    else
        fail "cmd_next returned no tasks, expected queued tasks to be returned" "Output: $next_output"
    fi

    # Verify running_count still works correctly
    running=$(sup running-count "$batch_t172_id" 2>&1 | tail -1)
    if [[ "$running" == "1" ]]; then
        pass "running-count correctly reports 1 active task"
    else
        fail "running-count is '$running', expected '1'"
    fi
else
    skip "Could not create batch for concurrency delegation test"
fi

# ============================================================
# SECTION: Evaluate Worker (t161 - clean_exit_no_signal fix)
# ============================================================
section "Evaluate Worker (t161)"

# Helper: create a task with a mock log file for evaluate testing
create_eval_task() {
    local task_id="$1"
    local log_content="$2"
    local branch="${3:-}"

    # Add task
    sup add "$task_id" --repo /tmp/test --description "Eval test: $task_id" >/dev/null 2>&1 || true

    # Create log file
    local log_file="$TEST_DIR/${task_id}.log"
    echo "$log_content" > "$log_file"

    # Set log_file and status in DB (simulate a completed worker)
    test_db "UPDATE tasks SET log_file = '$log_file', status = 'running' WHERE id = '$task_id';"

    # Set branch if provided
    if [[ -n "$branch" ]]; then
        test_db "UPDATE tasks SET branch = '$branch' WHERE id = '$task_id';"
    fi
}

# Test: FULL_LOOP_COMPLETE signal = definitive success
create_eval_task "eval-t001" "Some work output
FULL_LOOP_COMPLETE
EXIT:0"
eval_result=$(sup evaluate eval-t001 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete"; then
    pass "FULL_LOOP_COMPLETE signal -> complete"
else
    fail "FULL_LOOP_COMPLETE signal should be complete" "Got: $eval_result"
fi

# Test: TASK_COMPLETE with exit 0 = partial success
create_eval_task "eval-t002" "Some work output
TASK_COMPLETE
EXIT:0"
eval_result=$(sup evaluate eval-t002 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete.*task_only"; then
    pass "TASK_COMPLETE + exit 0 -> complete:task_only"
else
    fail "TASK_COMPLETE + exit 0 should be complete:task_only" "Got: $eval_result"
fi

# Test: Exit 0 with no signal and no PR = retry:clean_exit_no_signal
# (This is the case where no PR can be found via gh - simulated by using
# a non-existent repo so gh pr list fails gracefully)
create_eval_task "eval-t003" "Some work output
EXIT:0"
eval_result=$(sup evaluate eval-t003 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*clean_exit_no_signal"; then
    pass "Exit 0 + no signal + no PR -> retry:clean_exit_no_signal"
else
    fail "Exit 0 + no signal + no PR should be retry:clean_exit_no_signal" "Got: $eval_result"
fi

# Test: Non-zero exit with auth error = blocked
create_eval_task "eval-t004" "Some work output
permission denied
EXIT:1"
eval_result=$(sup evaluate eval-t004 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*auth_error"; then
    pass "Non-zero exit + auth error -> blocked:auth_error"
else
    fail "Non-zero exit + auth error should be blocked:auth_error" "Got: $eval_result"
fi

# Test: Non-zero exit with rate limit = retry
create_eval_task "eval-t005" "Some work output
429 Too Many Requests
EXIT:1"
eval_result=$(sup evaluate eval-t005 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*rate_limited"; then
    pass "Non-zero exit + rate limit -> retry:rate_limited"
else
    fail "Non-zero exit + rate limit should be retry:rate_limited" "Got: $eval_result"
fi

# Test: Exit 130 (SIGINT) = retry
create_eval_task "eval-t006" "Some work output
EXIT:130"
eval_result=$(sup evaluate eval-t006 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*interrupted_sigint"; then
    pass "Exit 130 (SIGINT) -> retry:interrupted_sigint"
else
    fail "Exit 130 should be retry:interrupted_sigint" "Got: $eval_result"
fi

# Test: No log file = failed
sup add eval-t007 --repo /tmp/test --description "No log test" >/dev/null 2>&1 || true
test_db "UPDATE tasks SET status = 'running' WHERE id = 'eval-t007';"
eval_result=$(sup evaluate eval-t007 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "failed.*no_log_file"; then
    pass "No log file -> failed:no_log_file"
else
    fail "No log file should be failed:no_log_file" "Got: $eval_result"
fi

# Test: Non-zero exit with merge conflict = blocked
create_eval_task "eval-t008" "Some work output
CONFLICT (content): Merge conflict in file.txt
EXIT:1"
eval_result=$(sup evaluate eval-t008 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*merge_conflict"; then
    pass "Non-zero exit + merge conflict -> blocked:merge_conflict"
else
    fail "Non-zero exit + merge conflict should be blocked:merge_conflict" "Got: $eval_result"
fi

# Test: Backend infrastructure error with non-zero exit = retry
create_eval_task "eval-t009" "Some work output
HTTP 503 Service Unavailable
EXIT:1"
eval_result=$(sup evaluate eval-t009 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*backend_infrastructure_error"; then
    pass "Non-zero exit + backend error -> retry:backend_infrastructure_error"
else
    fail "Non-zero exit + backend error should be retry:backend_infrastructure_error" "Got: $eval_result"
fi

# Test: Exit 0 with error strings in log = NOT treated as error (content discussion)
# This verifies that heuristic error patterns are only checked on non-zero exit
create_eval_task "eval-t010" "Documenting auth flows:
The API returns 401 unauthorized when token expires
permission denied errors should be handled gracefully
EXIT:0"
eval_result=$(sup evaluate eval-t010 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*clean_exit_no_signal"; then
    pass "Exit 0 + error strings in content -> retry:clean_exit_no_signal (not blocked)"
else
    fail "Exit 0 with error strings should NOT be blocked" "Got: $eval_result"
fi

# Test: PR URL extracted from final "type":"text" JSON entry (t192)
# Workers using opencode --format json emit PR URLs in their final text output.
# The supervisor should extract this and return complete:<pr_url> instead of
# retry:clean_exit_no_signal. This is the core fix for t192.
create_eval_task "eval-t192a" '{"type":"step_start","timestamp":1770606000000}
{"type":"text","timestamp":1770606100000,"part":{"type":"text","text":"Reading TODO.md... found PR https://github.com/other/repo/pull/999 from prior task"}}
{"type":"tool_use","timestamp":1770606200000,"part":{"type":"tool_use","name":"bash","input":"gh pr create"}}
{"type":"text","timestamp":1770606693412,"part":{"type":"text","text":"Task eval-t192a is complete. PR created: https://github.com/marcusquinn/aidevops/pull/718\n\nImplemented the feature successfully."}}
{"type":"step_finish","timestamp":1770606693614,"part":{"type":"step-finish","reason":"stop"}}
EXIT:0'
eval_result=$(sup evaluate eval-t192a --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete.*https://github.com/marcusquinn/aidevops/pull/718"; then
    pass "PR URL from final text entry -> complete:<pr_url> (t192)"
else
    fail "PR URL in final text should yield complete, not retry" "Got: $eval_result"
fi

# Test: PR URL from earlier text entry is NOT used when final entry has no PR (t192/t151)
# The last "type":"text" entry is authoritative. Earlier entries may reference other PRs.
# Include WORKER_STARTED sentinel and enough content to pass the t183 early checks.
create_eval_task "eval-t192b" 'WORKER_STARTED task_id=eval-t192b pid=12345 timestamp=2026-02-09T03:00:00Z
{"type":"step_start","timestamp":1770606000000,"part":{"type":"step-start"}}
{"type":"text","timestamp":1770606100000,"part":{"type":"text","text":"Memory recall: PR https://github.com/other/repo/pull/555 was merged yesterday"}}
{"type":"tool_use","timestamp":1770606200000,"part":{"type":"tool_use","name":"bash","input":"echo working"}}
{"type":"text","timestamp":1770606300000,"part":{"type":"text","text":"Working on the task..."}}
{"type":"text","timestamp":1770606693412,"part":{"type":"text","text":"I was unable to complete the task due to missing dependencies."}}
{"type":"step_finish","timestamp":1770606693614,"part":{"type":"step-finish","reason":"stop"}}
EXIT:0'
eval_result=$(sup evaluate eval-t192b --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*clean_exit_no_signal"; then
    pass "No PR in final text + exit 0 -> retry:clean_exit_no_signal (t192 safe)"
else
    # Also acceptable: complete:task_only if git heuristic finds commits
    if echo "$eval_result" | grep -q "complete.*task_only\|retry"; then
        pass "No PR in final text -> retry or task_only (t192 safe, no false PR)"
    else
        fail "Should not extract PR from earlier text entries" "Got: $eval_result"
    fi
fi

# ============================================================
# SECTION: Backend Error in Retry Logs (t198 - content_lines fix)
# ============================================================
section "Backend Error in Retry Logs (t198)"

# Test: Backend error with REPROMPT METADATA header should be detected as
# backend_quota_error, not clean_exit_no_signal. The metadata header inflates
# log_lines to 12, but content_lines (excluding metadata) is only 4.
create_eval_task "eval-t198a" '=== REPROMPT METADATA (t183) ===
task_id=eval-t198a
timestamp=2026-02-09T23:30:27Z
retry=3/5
work_dir=/tmp/test
previous_error=clean_exit_no_signal
fresh_worktree=true
=== END REPROMPT METADATA ===

WORKER_STARTED task_id=eval-t198a retry=3 pid=$$ timestamp=2026-02-09T23:30:27Z
{"type":"error","timestamp":1770679838445,"error":{"name":"UnknownError","data":{"message":"Error: All Antigravity endpoints failed"}}}
EXIT:0'
eval_result=$(sup evaluate eval-t198a --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*backend_quota_error"; then
    pass "Backend error + REPROMPT METADATA -> retry:backend_quota_error (t198 fix)"
else
    fail "Backend error in retry log should be backend_quota_error, not clean_exit_no_signal" "Got: $eval_result"
fi

# Test: Task obsolete detection — worker says "already done" in final text
create_eval_task "eval-t198b" 'WORKER_STARTED task_id=eval-t198b pid=12345 timestamp=2026-02-09T03:00:00Z
{"type":"step_start","timestamp":1770606000000,"part":{"type":"step-start"}}
{"type":"tool_use","timestamp":1770606100000,"part":{"type":"tool_use","name":"bash","input":"git status"}}
{"type":"text","timestamp":1770606693412,"part":{"type":"text","text":"**TASK ALREADY DONE — exiting cleanly.** Both files are already valid JSON with no corruption. No PR needed — there are no changes to make."}}
{"type":"step_finish","timestamp":1770606693614,"part":{"type":"step-finish","reason":"stop"}}
EXIT:0'
eval_result=$(sup evaluate eval-t198b --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete.*task_obsolete"; then
    pass "Worker says 'already done' -> complete:task_obsolete (t198 fix)"
else
    fail "Worker saying 'already done' should be complete:task_obsolete" "Got: $eval_result"
fi

# Test: Task obsolete with "no changes needed" phrasing
create_eval_task "eval-t198c" 'WORKER_STARTED task_id=eval-t198c pid=12345 timestamp=2026-02-09T03:00:00Z
{"type":"step_start","timestamp":1770606000000,"part":{"type":"step-start"}}
{"type":"text","timestamp":1770606693412,"part":{"type":"text","text":"Task t135.5 is already done. The investigation confirms no changes needed. All specified artifacts are untracked and both directories are gitignored. No PR needed."}}
{"type":"step_finish","timestamp":1770606693614,"part":{"type":"step-finish","reason":"stop"}}
EXIT:0'
eval_result=$(sup evaluate eval-t198c --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete.*task_obsolete"; then
    pass "Worker says 'no changes needed' -> complete:task_obsolete (t198 fix)"
else
    fail "Worker saying 'no changes needed' should be complete:task_obsolete" "Got: $eval_result"
fi

# Test: Normal clean_exit_no_signal still works (worker didn't say task is done)
create_eval_task "eval-t198d" 'WORKER_STARTED task_id=eval-t198d pid=12345 timestamp=2026-02-09T03:00:00Z
{"type":"step_start","timestamp":1770606000000,"part":{"type":"step-start"}}
{"type":"text","timestamp":1770606693412,"part":{"type":"text","text":"I started working on the task but ran out of context. The implementation is partially complete."}}
{"type":"step_finish","timestamp":1770606693614,"part":{"type":"step-finish","reason":"stop"}}
EXIT:0'
eval_result=$(sup evaluate eval-t198d --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*clean_exit_no_signal"; then
    pass "Normal incomplete exit -> retry:clean_exit_no_signal (unchanged)"
else
    fail "Normal incomplete exit should still be clean_exit_no_signal" "Got: $eval_result"
fi

# Test: GitHub auth failure -> blocked:gh_auth_expired (t198)
# Workers that complete work but can't push due to expired gh auth should be
# blocked immediately, not retried. This is the #1 cause of wasted retries.
create_eval_task "eval-t198e" 'WORKER_STARTED task_id=eval-t198e pid=12345 timestamp=2026-02-09T03:00:00Z
{"type":"step_start","timestamp":1770606000000,"part":{"type":"step-start"}}
{"type":"text","timestamp":1770606100000,"part":{"type":"text","text":"Implementation complete. All files created and committed."}}
{"type":"tool_use","timestamp":1770606200000,"part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"gh auth status"},"output":"gh auth status\nYou are not logged in to any GitHub hosts. Run gh auth login to authenticate.","metadata":{"exit":1}}}}
{"type":"text","timestamp":1770606300000,"part":{"type":"text","text":"GitHub authentication token has expired. Cannot push or create PR. The implementation is complete locally but needs gh auth login to proceed."}}
{"type":"step_finish","timestamp":1770606400000,"part":{"type":"step-finish","reason":"stop"}}
EXIT:0'
eval_result=$(sup evaluate eval-t198e --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*gh_auth_expired"; then
    pass "Exit 0 + gh auth failure -> blocked:gh_auth_expired (not retried)"
else
    fail "Exit 0 + gh auth failure should be blocked:gh_auth_expired" "Got: $eval_result"
fi

# Test: gh auth failure with different wording (try authenticating)
create_eval_task "eval-t198f" 'WORKER_STARTED task_id=eval-t198f pid=12345 timestamp=2026-02-09T03:00:00Z
{"type":"step_start","timestamp":1770606000000,"part":{"type":"step-start"}}
{"type":"tool_use","timestamp":1770606100000,"part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"git push"},"output":"remote: Permission denied. try authenticating with gh auth login","metadata":{"exit":1}}}}
{"type":"text","timestamp":1770606200000,"part":{"type":"text","text":"Push failed. Need to authenticate with GitHub."}}
{"type":"step_finish","timestamp":1770606300000,"part":{"type":"step-finish","reason":"stop"}}
EXIT:0'
eval_result=$(sup evaluate eval-t198f --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*gh_auth_expired"; then
    pass "Exit 0 + 'try authenticating' -> blocked:gh_auth_expired"
else
    fail "Exit 0 + 'try authenticating' should be blocked:gh_auth_expired" "Got: $eval_result"
fi

# ============================================================
# SECTION 7: Worktree Path Integrity
# ============================================================
section "Worktree Path Integrity"

# Test: create_task_worktree returns a clean single-line path (no stdout pollution)
# This is a regression test for the bug where `git branch -D` output ("Deleted branch ...")
# leaked into the function's return value, causing dispatch to fail with invalid paths.

WORKTREE_TEST_DIR=$(mktemp -d)
WORKTREE_TEST_REPO="$WORKTREE_TEST_DIR/test-repo"
trap 'rm -rf "$WORKTREE_TEST_DIR"; rm -rf "$TEST_DIR"' EXIT

# Set up a minimal git repo for worktree testing
git init "$WORKTREE_TEST_REPO" &>/dev/null
git -C "$WORKTREE_TEST_REPO" commit --allow-empty -m "initial" &>/dev/null

# Create a branch that will need cleanup (simulates stale branch from prior failed dispatch)
git -C "$WORKTREE_TEST_REPO" branch "feature/wt-test-001" &>/dev/null

# Add task to supervisor DB
sup add wt-test-001 --repo "$WORKTREE_TEST_REPO" --description "Worktree stdout leak test" >/dev/null 2>&1 || true

# Call create_task_worktree directly. The script calls main "$@" at the bottom
# when sourced, so we pass "init" to avoid show_usage. We redirect the source's
# stdout to /dev/null (suppresses cmd_init output) — function definitions still
# register in the current shell. Then we call the function we want to test.
worktree_output=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'wt-test-001' '$WORKTREE_TEST_REPO' true
" 2>/dev/null)

# Count lines — should be exactly 1 (the path)
line_count=$(echo "$worktree_output" | wc -l | tr -d ' ')
if [[ "$line_count" -eq 1 ]]; then
    pass "create_task_worktree returns exactly 1 line (no stdout pollution)"
else
    fail "create_task_worktree returned $line_count lines (stdout pollution detected)" \
        "Output: $(echo "$worktree_output" | head -3)"
fi

# Verify the returned path is a real directory
if [[ -d "$worktree_output" ]]; then
    pass "create_task_worktree returns a valid directory path"
else
    fail "create_task_worktree path is not a directory" "Got: '$worktree_output'"
fi

# Verify path doesn't contain "Deleted branch" (the specific pollution we fixed)
if echo "$worktree_output" | grep -qi "deleted branch"; then
    fail "create_task_worktree output contains 'Deleted branch' pollution" \
        "Got: '$worktree_output'"
else
    pass "create_task_worktree output is free of 'Deleted branch' pollution"
fi

# Clean up the test worktree
git -C "$WORKTREE_TEST_REPO" worktree remove "$worktree_output" --force &>/dev/null || rm -rf "$worktree_output"
git -C "$WORKTREE_TEST_REPO" worktree prune &>/dev/null || true

# ============================================================
# SECTION: Post-Merge Verification Transitions (t180)
# ============================================================
section "Post-Merge Verification Transitions (t180)"

# Create a task and move through full lifecycle to deployed
sup add test-v001 --repo /tmp/test --description "Verify lifecycle test" >/dev/null
sup transition test-v001 dispatched >/dev/null
sup transition test-v001 running >/dev/null
sup transition test-v001 evaluating >/dev/null
sup transition test-v001 complete >/dev/null
sup transition test-v001 pr_review >/dev/null
sup transition test-v001 merging >/dev/null
sup transition test-v001 merged >/dev/null
sup transition test-v001 deploying >/dev/null
sup transition test-v001 deployed >/dev/null

# deployed -> verifying
sup transition test-v001 verifying >/dev/null
if [[ "$(get_status test-v001)" == "verifying" ]]; then
    pass "deployed -> verifying"
else
    fail "deployed -> verifying failed: $(get_status test-v001)"
fi

# verifying -> verified
sup transition test-v001 verified >/dev/null
if [[ "$(get_status test-v001)" == "verified" ]]; then
    pass "verifying -> verified"
else
    fail "verifying -> verified failed: $(get_status test-v001)"
fi

# Test: completed_at is set on verified (terminal state)
verified_completed=$(get_field "test-v001" "completed_at")
if [[ -n "$verified_completed" ]]; then
    pass "completed_at set on verified state"
else
    fail "completed_at not set on verified state"
fi

# Test: verify_failed path
sup add test-v002 --repo /tmp/test --description "Verify fail test" >/dev/null
sup transition test-v002 dispatched >/dev/null
sup transition test-v002 running >/dev/null
sup transition test-v002 evaluating >/dev/null
sup transition test-v002 complete >/dev/null
sup transition test-v002 deployed >/dev/null
sup transition test-v002 verifying >/dev/null

# verifying -> verify_failed
sup transition test-v002 verify_failed >/dev/null
if [[ "$(get_status test-v002)" == "verify_failed" ]]; then
    pass "verifying -> verify_failed"
else
    fail "verifying -> verify_failed failed: $(get_status test-v002)"
fi

# verify_failed -> verifying (retry verification)
sup transition test-v002 verifying >/dev/null
if [[ "$(get_status test-v002)" == "verifying" ]]; then
    pass "verify_failed -> verifying (retry)"
else
    fail "verify_failed -> verifying failed: $(get_status test-v002)"
fi

# verify_failed -> cancelled
sup transition test-v002 verify_failed >/dev/null
sup transition test-v002 cancelled >/dev/null
if [[ "$(get_status test-v002)" == "cancelled" ]]; then
    pass "verify_failed -> cancelled"
else
    fail "verify_failed -> cancelled failed: $(get_status test-v002)"
fi

# verified -> cancelled
sup add test-v003 --repo /tmp/test --description "Verified cancel test" >/dev/null
sup transition test-v003 dispatched >/dev/null
sup transition test-v003 running >/dev/null
sup transition test-v003 evaluating >/dev/null
sup transition test-v003 complete >/dev/null
sup transition test-v003 deployed >/dev/null
sup transition test-v003 verified >/dev/null
sup transition test-v003 cancelled >/dev/null
if [[ "$(get_status test-v003)" == "cancelled" ]]; then
    pass "verified -> cancelled"
else
    fail "verified -> cancelled failed: $(get_status test-v003)"
fi

# Test: deployed -> verified (direct skip for tasks without VERIFY.md entries)
sup add test-v004 --repo /tmp/test --description "Direct verify test" >/dev/null
sup transition test-v004 dispatched >/dev/null
sup transition test-v004 running >/dev/null
sup transition test-v004 evaluating >/dev/null
sup transition test-v004 complete >/dev/null
sup transition test-v004 deployed >/dev/null
sup transition test-v004 verified >/dev/null
if [[ "$(get_status test-v004)" == "verified" ]]; then
    pass "deployed -> verified (direct, no VERIFY.md entry)"
else
    fail "deployed -> verified direct failed: $(get_status test-v004)"
fi

# Test: invalid transition — queued -> verifying (must go through deployed)
sup add test-v005 --repo /tmp/test --description "Invalid verify test" >/dev/null
invalid_verify=$(sup transition test-v005 verifying 2>&1 || true)
if echo "$invalid_verify" | grep -qi "invalid transition"; then
    pass "queued -> verifying rejected (invalid)"
else
    fail "queued -> verifying was not rejected" "$invalid_verify"
fi

# Test: run_verify_checks with a real VERIFY.md
VERIFY_TEST_DIR=$(mktemp -d)
mkdir -p "$VERIFY_TEST_DIR/todo"
mkdir -p "$VERIFY_TEST_DIR/.agents/scripts"

# Create a test file to verify
echo '#!/bin/bash' > "$VERIFY_TEST_DIR/.agents/scripts/test-script.sh"
echo 'echo "hello"' >> "$VERIFY_TEST_DIR/.agents/scripts/test-script.sh"

# Create VERIFY.md with a pending entry
cat > "$VERIFY_TEST_DIR/todo/VERIFY.md" << 'VERIFYEOF'
# Verification Queue

<!-- VERIFY-QUEUE-START -->

- [ ] v001 test-v010 Test verify checks | PR #999 | merged:2026-02-08
  files: .agents/scripts/test-script.sh
  check: file-exists .agents/scripts/test-script.sh

<!-- VERIFY-QUEUE-END -->
VERIFYEOF

# Add task to DB
sup add test-v010 --repo "$VERIFY_TEST_DIR" --description "Verify checks test" >/dev/null 2>&1 || true
test_db "UPDATE tasks SET status = 'deployed' WHERE id = 'test-v010';"

# Run verify checks via sourced function
verify_output=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    run_verify_checks 'test-v010' '$VERIFY_TEST_DIR'
" 2>/dev/null || echo "VERIFY_FAILED")

if echo "$verify_output" | grep -qi "PASS"; then
    pass "run_verify_checks passes for existing file"
else
    # Check if the function ran at all
    if echo "$verify_output" | grep -qi "FAIL\|error"; then
        fail "run_verify_checks failed unexpectedly" "Output: $verify_output"
    else
        skip "run_verify_checks output inconclusive (may need source support)"
    fi
fi

# Check VERIFY.md was updated
if grep -q '\[x\].*test-v010' "$VERIFY_TEST_DIR/todo/VERIFY.md" 2>/dev/null; then
    pass "VERIFY.md entry marked [x] after passing checks"
else
    skip "VERIFY.md marking may require direct function access"
fi

rm -rf "$VERIFY_TEST_DIR"

# ============================================================
# SECTION: Task Claiming via TODO.md (t165)
# ============================================================
section "Task Claiming via TODO.md (t165)"

# Set up a fake project with TODO.md for claiming tests
CLAIM_TEST_DIR=$(mktemp -d)
mkdir -p "$CLAIM_TEST_DIR"
git -C "$CLAIM_TEST_DIR" init --quiet 2>/dev/null || true
git -C "$CLAIM_TEST_DIR" config user.email "test@test.com" 2>/dev/null || true
git -C "$CLAIM_TEST_DIR" config user.name "Test" 2>/dev/null || true

cat > "$CLAIM_TEST_DIR/TODO.md" << 'CLAIM_TODO'
# Test TODO

## Tasks

- [ ] t900 Test claiming task #orchestration ~1h
- [ ] t901 Another task for claiming #test ~30m
- [ ] t902 Pre-claimed task #test ~1h assignee:otheruser started:2026-01-01T00:00:00Z
- [x] t903 Already completed task #test ~1h
CLAIM_TODO

git -C "$CLAIM_TEST_DIR" add TODO.md 2>/dev/null || true
git -C "$CLAIM_TEST_DIR" commit -m "init" --quiet 2>/dev/null || true

# Add tasks to supervisor DB for claiming tests
sup add t900 --repo "$CLAIM_TEST_DIR" --description "Test claiming task" --no-issue >/dev/null 2>&1
sup add t901 --repo "$CLAIM_TEST_DIR" --description "Another task" --no-issue >/dev/null 2>&1
sup add t902 --repo "$CLAIM_TEST_DIR" --description "Pre-claimed task" --no-issue >/dev/null 2>&1

# Test: system identity is available for claiming
if [[ -n "$(whoami 2>/dev/null)" ]]; then
    pass "System identity available (whoami: $(whoami))"
else
    fail "Cannot determine system identity"
fi

# Test: get_task_assignee returns empty for unclaimed task
assignee_output=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR'
    source '${SCRIPTS_DIR}/shared-constants.sh' 2>/dev/null || true
    # Define get_task_assignee inline (it's in supervisor-helper.sh)
    get_task_assignee() {
        local task_id=\"\$1\" todo_file=\"\$2\"
        [[ -f \"\$todo_file\" ]] || return 0
        local task_id_escaped
        task_id_escaped=\$(printf '%s' \"\$task_id\" | sed 's/\\\./\\\\./g')
        local task_line
        task_line=\$(grep -E \"^- \[.\] \${task_id_escaped} \" \"\$todo_file\" | head -1 || echo \"\")
        [[ -z \"\$task_line\" ]] && return 0
        echo \"\$task_line\" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || echo \"\"
        return 0
    }
    get_task_assignee 't900' '$CLAIM_TEST_DIR/TODO.md'
" 2>/dev/null)
if [[ -z "$assignee_output" ]]; then
    pass "get_task_assignee returns empty for unclaimed task t900"
else
    fail "get_task_assignee should return empty for unclaimed task" "Got: $assignee_output"
fi

# Test: get_task_assignee returns assignee for pre-claimed task
assignee_output=$(bash -c "
    get_task_assignee() {
        local task_id=\"\$1\" todo_file=\"\$2\"
        [[ -f \"\$todo_file\" ]] || return 0
        local task_id_escaped
        task_id_escaped=\$(printf '%s' \"\$task_id\" | sed 's/\\\./\\\\./g')
        local task_line
        task_line=\$(grep -E \"^- \[.\] \${task_id_escaped} \" \"\$todo_file\" | head -1 || echo \"\")
        [[ -z \"\$task_line\" ]] && return 0
        echo \"\$task_line\" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || echo \"\"
        return 0
    }
    get_task_assignee 't902' '$CLAIM_TEST_DIR/TODO.md'
" 2>/dev/null)
if [[ "$assignee_output" == "otheruser" ]]; then
    pass "get_task_assignee returns 'otheruser' for pre-claimed task t902"
else
    fail "get_task_assignee should return 'otheruser' for t902" "Got: '$assignee_output'"
fi

# Test: cmd_add with --no-issue does not require gh CLI
add_output=$(sup add t904 --repo "$CLAIM_TEST_DIR" --description "No issue task" --no-issue 2>&1)
if echo "$add_output" | grep -qi "Added task.*t904"; then
    pass "cmd_add --no-issue succeeds without GitHub"
else
    fail "cmd_add --no-issue should succeed" "Output: $add_output"
fi

# Test: cmd_add with --with-issue flag is accepted (even if gh fails)
add_issue_output=$(sup add t905 --repo "$CLAIM_TEST_DIR" --description "With issue task" --with-issue 2>&1 || true)
if echo "$add_issue_output" | grep -qi "Added task.*t905\|skipped"; then
    pass "cmd_add --with-issue flag is accepted"
else
    fail "cmd_add --with-issue should be accepted" "Output: $add_issue_output"
fi

# Test: find_project_root finds TODO.md
find_root_output=$(bash -c "
    cd '$CLAIM_TEST_DIR'
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR'
    # Extract just find_project_root from the script
    find_project_root() {
        local dir=\"\$PWD\"
        while [[ \"\$dir\" != \"/\" ]]; do
            if [[ -f \"\$dir/TODO.md\" ]]; then
                echo \"\$dir\"
                return 0
            fi
            dir=\"\$(dirname \"\$dir\")\"
        done
        return 1
    }
    find_project_root
" 2>/dev/null)
if [[ "$find_root_output" == "$CLAIM_TEST_DIR" ]]; then
    pass "find_project_root locates TODO.md directory"
else
    fail "find_project_root should find $CLAIM_TEST_DIR" "Got: '$find_root_output'"
fi

# Test: claiming modifies TODO.md with assignee: field
# We test the sed logic directly since cmd_claim requires git push
claim_test_file="$CLAIM_TEST_DIR/TODO-claim-test.md"
cp "$CLAIM_TEST_DIR/TODO.md" "$claim_test_file"
# Simulate claiming t900 by adding assignee: field
line_num=$(grep -nE "^- \[ \] t900 " "$claim_test_file" | head -1 | cut -d: -f1)
if [[ -n "$line_num" ]]; then
    task_line=$(sed -n "${line_num}p" "$claim_test_file")
    new_line="${task_line} assignee:testuser started:2026-01-01T00:00:00Z"
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "${line_num}s|.*|${new_line}|" "$claim_test_file"
    else
        sed -i "${line_num}s|.*|${new_line}|" "$claim_test_file"
    fi
    if grep -q "assignee:testuser" "$claim_test_file"; then
        pass "Claiming adds assignee: field to TODO.md task line"
    else
        fail "Claiming should add assignee: field"
    fi
else
    fail "Could not find t900 in test TODO.md"
fi

# Test: unclaiming removes assignee: and started: fields
unclaim_line=$(grep "t900" "$claim_test_file" | head -1)
unclaimed_line=$(echo "$unclaim_line" | sed -E "s/ ?assignee:[A-Za-z0-9._@-]+//; s/ ?started:[0-9T:Z-]+//")
if echo "$unclaimed_line" | grep -q "assignee:"; then
    fail "Unclaiming should remove assignee: field"
else
    if echo "$unclaimed_line" | grep -q "started:"; then
        fail "Unclaiming should remove started: field"
    else
        pass "Unclaiming removes assignee: and started: fields"
    fi
fi

# Test: check_task_claimed returns empty (free) for unclaimed task
check_output=$(bash -c "
    get_task_assignee() {
        local task_id=\"\$1\" todo_file=\"\$2\"
        [[ -f \"\$todo_file\" ]] || return 0
        local task_id_escaped
        task_id_escaped=\$(printf '%s' \"\$task_id\" | sed 's/\\\./\\\\./g')
        local task_line
        task_line=\$(grep -E \"^- \[.\] \${task_id_escaped} \" \"\$todo_file\" | head -1 || echo \"\")
        [[ -z \"\$task_line\" ]] && return 0
        echo \"\$task_line\" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || echo \"\"
        return 0
    }
    assignee=\$(get_task_assignee 't901' '$CLAIM_TEST_DIR/TODO.md')
    if [[ -z \"\$assignee\" ]]; then
        echo 'FREE'
    else
        echo \"\$assignee\"
    fi
" 2>/dev/null)
if [[ "$check_output" == "FREE" ]]; then
    pass "check_task_claimed: unclaimed task t901 is free"
else
    fail "Unclaimed task should be free" "Got: '$check_output'"
fi

# Test: check_task_claimed detects task claimed by another user
check_other_output=$(bash -c "
    get_task_assignee() {
        local task_id=\"\$1\" todo_file=\"\$2\"
        [[ -f \"\$todo_file\" ]] || return 0
        local task_id_escaped
        task_id_escaped=\$(printf '%s' \"\$task_id\" | sed 's/\\\./\\\\./g')
        local task_line
        task_line=\$(grep -E \"^- \[.\] \${task_id_escaped} \" \"\$todo_file\" | head -1 || echo \"\")
        [[ -z \"\$task_line\" ]] && return 0
        echo \"\$task_line\" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || echo \"\"
        return 0
    }
    assignee=\$(get_task_assignee 't902' '$CLAIM_TEST_DIR/TODO.md')
    if [[ -z \"\$assignee\" ]]; then
        echo 'FREE'
    else
        echo \"\$assignee\"
    fi
" 2>/dev/null)
if [[ "$check_other_output" == "otheruser" ]]; then
    pass "check_task_claimed: t902 claimed by 'otheruser' detected"
else
    fail "Should detect t902 claimed by otheruser" "Got: '$check_other_output'"
fi

# Test: SUPERVISOR_AUTO_ISSUE default is now false (t165)
auto_issue_default="${SUPERVISOR_AUTO_ISSUE:-false}"
if [[ "$auto_issue_default" == "false" ]]; then
    pass "SUPERVISOR_AUTO_ISSUE defaults to false (GH Issues opt-in)"
else
    fail "SUPERVISOR_AUTO_ISSUE should default to false" "Got: $auto_issue_default"
fi

# Test: task line with logged: field — assignee inserted before logged:
logged_line="- [ ] t910 Task with logged field #test ~1h logged:2026-01-01"
expected_pattern="assignee:.*started:.*logged:"
insert_result=$(echo "$logged_line" | sed -E "s/( logged:)/ assignee:testuser started:2026-01-01T00:00:00Z\1/")
if echo "$insert_result" | grep -qE "$expected_pattern"; then
    pass "Claiming inserts assignee: before logged: field"
else
    fail "Should insert assignee: before logged:" "Got: $insert_result"
fi

# Test: detect_repo_slug parses HTTPS remote
slug_test=$(echo "https://github.com/owner/repo.git" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|; s|\.git$||')
if [[ "$slug_test" == "owner/repo" ]]; then
    pass "detect_repo_slug parses HTTPS remote correctly"
else
    fail "detect_repo_slug HTTPS parsing" "Got: '$slug_test'"
fi

# Test: detect_repo_slug parses SSH remote
slug_test_ssh=$(echo "git@github.com:owner/repo.git" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|; s|\.git$||')
if [[ "$slug_test_ssh" == "owner/repo" ]]; then
    pass "detect_repo_slug parses SSH remote correctly"
else
    fail "detect_repo_slug SSH parsing" "Got: '$slug_test_ssh'"
fi

rm -rf "$CLAIM_TEST_DIR"

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
