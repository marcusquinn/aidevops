#!/usr/bin/env bash
# shellcheck disable=SC2034
# test-dispatch-worktree-evaluate.sh
#
# Integration test for the dispatch-worktree-evaluate pipeline (t177).
#
# Tests the end-to-end cycle that the supervisor performs for each task:
#   1. Task addition and batch creation
#   2. Worktree creation via create_task_worktree()
#   3. State transitions through the dispatch pipeline
#   4. Simulated worker output (log files with various outcomes)
#   5. Evaluation via evaluate_worker() with deterministic + heuristic tiers
#   6. Retry cycle (evaluate -> retrying -> dispatched -> running -> evaluate)
#   7. Batch completion detection after all tasks finish
#   8. Worktree cleanup
#
# Unlike test-supervisor-state-machine.sh (unit tests for state transitions),
# this test exercises real git repos, real worktrees, and the full evaluation
# pipeline with simulated worker logs.
#
# Usage: bash tests/test-dispatch-worktree-evaluate.sh [--verbose]
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

# --- Isolated Test Environment ---
TEST_DIR=$(mktemp -d)
TEST_REPO="$TEST_DIR/test-repo"
export AIDEVOPS_SUPERVISOR_DIR="$TEST_DIR/supervisor"

# shellcheck disable=SC2317,SC2329
cleanup() {
    # Remove all worktrees before deleting the repo
    if [[ -d "$TEST_REPO" ]]; then
        git -C "$TEST_REPO" worktree list --porcelain 2>/dev/null | \
            grep "^worktree " | cut -d' ' -f2- | while IFS= read -r wt_path; do
            if [[ "$wt_path" != "$TEST_REPO" && -d "$wt_path" ]]; then
                git -C "$TEST_REPO" worktree remove "$wt_path" --force 2>/dev/null || rm -rf "$wt_path"
            fi
        done
        git -C "$TEST_REPO" worktree prune 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Helper: run supervisor command with isolated DB
sup() {
    bash "$SUPERVISOR_SCRIPT" "$@" 2>&1
}

# Helper: query the test DB directly
test_db() {
    sqlite3 -cmd ".timeout 5000" "$TEST_DIR/supervisor/supervisor.db" "$@"
}

# Helper: get task status
get_status() {
    test_db "SELECT status FROM tasks WHERE id = '$1';"
}

# Helper: get task field
get_field() {
    test_db "SELECT $2 FROM tasks WHERE id = '$1';"
}

# Helper: create a mock worker log file
create_log() {
    local task_id="$1"
    local content="$2"
    local log_file="$TEST_DIR/supervisor/logs/${task_id}.log"
    mkdir -p "$TEST_DIR/supervisor/logs"
    echo "$content" > "$log_file"
    # Update the task's log_file in DB
    test_db "UPDATE tasks SET log_file = '$log_file' WHERE id = '$task_id';"
    echo "$log_file"
}

# ============================================================
# SETUP: Create a real git repo for worktree testing
# ============================================================
section "Test Environment Setup"

# Initialize a real git repo with a commit on main
git init "$TEST_REPO" &>/dev/null
git -C "$TEST_REPO" checkout -b main &>/dev/null 2>&1 || true
echo "# Test Repo" > "$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md &>/dev/null
git -C "$TEST_REPO" commit -m "initial commit" &>/dev/null

# Initialize supervisor DB
sup init >/dev/null

if [[ -f "$TEST_DIR/supervisor/supervisor.db" ]]; then
    pass "Supervisor DB initialized"
else
    fail "Supervisor DB not created"
    exit 1
fi

if [[ -d "$TEST_REPO/.git" ]]; then
    pass "Test git repo created with initial commit"
else
    fail "Test git repo not created"
    exit 1
fi

# ============================================================
# SECTION 1: Worktree Creation via create_task_worktree()
# ============================================================
section "Worktree Creation (create_task_worktree)"

# Add a task to the supervisor
sup add integ-t001 --repo "$TEST_REPO" --description "Integration test task 1" --no-issue >/dev/null
if [[ "$(get_status integ-t001)" == "queued" ]]; then
    pass "Task integ-t001 added in queued state"
else
    fail "Task integ-t001 not in queued state: $(get_status integ-t001)"
fi

# Call create_task_worktree directly via sourcing
worktree_output=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-t001' '$TEST_REPO'
" 2>/dev/null)

# Verify single-line output (no stdout pollution)
line_count=$(echo "$worktree_output" | wc -l | tr -d ' ')
if [[ "$line_count" -eq 1 ]]; then
    pass "create_task_worktree returns exactly 1 line"
else
    fail "create_task_worktree returned $line_count lines" "Output: $(echo "$worktree_output" | head -3)"
fi

# Verify the worktree path is a real directory
if [[ -d "$worktree_output" ]]; then
    pass "Worktree directory exists: $worktree_output"
else
    fail "Worktree directory does not exist: '$worktree_output'"
fi

# Verify the worktree is on the correct branch
worktree_branch=$(git -C "$worktree_output" branch --show-current 2>/dev/null || echo "")
if [[ "$worktree_branch" == "feature/integ-t001" ]]; then
    pass "Worktree is on branch feature/integ-t001"
else
    fail "Worktree branch is '$worktree_branch', expected 'feature/integ-t001'"
fi

# Verify the worktree shares the same git database
main_commit=$(git -C "$TEST_REPO" rev-parse HEAD 2>/dev/null)
wt_commit=$(git -C "$worktree_output" rev-parse HEAD 2>/dev/null)
if [[ "$main_commit" == "$wt_commit" ]]; then
    pass "Worktree shares commit history with main repo"
else
    fail "Worktree commit mismatch: main=$main_commit wt=$wt_commit"
fi

# Verify idempotent re-call returns same path
worktree_output2=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-t001' '$TEST_REPO'
" 2>/dev/null)

if [[ "$worktree_output" == "$worktree_output2" ]]; then
    pass "Idempotent re-call returns same worktree path"
else
    fail "Re-call returned different path" "First: $worktree_output, Second: $worktree_output2"
fi

# Clean up worktree for next tests
WORKTREE_T001="$worktree_output"
git -C "$TEST_REPO" worktree remove "$WORKTREE_T001" --force &>/dev/null || rm -rf "$WORKTREE_T001"
git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/integ-t001" &>/dev/null || true

# ============================================================
# SECTION 2: Force-Fresh Worktree (retry with clean slate)
# ============================================================
section "Force-Fresh Worktree (retry scenario)"

# Create a worktree with some commits (simulates a failed first attempt)
sup add integ-t002 --repo "$TEST_REPO" --description "Force-fresh test" --no-issue >/dev/null

wt_path=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-t002' '$TEST_REPO'
" 2>/dev/null)

# Add a commit in the worktree (simulates partial work)
echo "partial work" > "$wt_path/partial.txt"
git -C "$wt_path" add partial.txt &>/dev/null
git -C "$wt_path" commit -m "partial work" &>/dev/null

# Verify the worktree has commits ahead of main
ahead=$(git -C "$wt_path" rev-list --count "main..HEAD" 2>/dev/null || echo "0")
if [[ "$ahead" -gt 0 ]]; then
    pass "Worktree has $ahead commit(s) ahead of main (simulated partial work)"
else
    fail "Worktree should have commits ahead of main"
fi

# Force-fresh should recreate the worktree from scratch
fresh_path=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-t002' '$TEST_REPO' 'true'
" 2>/dev/null)

if [[ -d "$fresh_path" ]]; then
    pass "Force-fresh created new worktree"
else
    fail "Force-fresh worktree not created: '$fresh_path'"
fi

# Verify the fresh worktree has no commits ahead of main
fresh_ahead=$(git -C "$fresh_path" rev-list --count "main..HEAD" 2>/dev/null || echo "0")
if [[ "$fresh_ahead" -eq 0 ]]; then
    pass "Force-fresh worktree starts clean (0 commits ahead of main)"
else
    fail "Force-fresh worktree has $fresh_ahead commits ahead, expected 0"
fi

# Clean up
WORKTREE_T002="$fresh_path"
git -C "$TEST_REPO" worktree remove "$WORKTREE_T002" --force &>/dev/null || rm -rf "$WORKTREE_T002"
git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/integ-t002" &>/dev/null || true

# ============================================================
# SECTION 3: Full Dispatch Pipeline (state transitions + worktree)
# ============================================================
section "Full Dispatch Pipeline (simulated)"

# Add task and create worktree (simulating what cmd_dispatch does)
sup add integ-t003 --repo "$TEST_REPO" --description "Full pipeline test" --no-issue >/dev/null

# Create worktree
wt_t003=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-t003' '$TEST_REPO'
" 2>/dev/null)

# Simulate the dispatch pipeline transitions
sup transition integ-t003 dispatched \
    --worktree "$wt_t003" \
    --branch "feature/integ-t003" >/dev/null

if [[ "$(get_status integ-t003)" == "dispatched" ]]; then
    pass "Task dispatched with worktree metadata"
else
    fail "Task not in dispatched state: $(get_status integ-t003)"
fi

# Verify metadata was stored
stored_wt=$(get_field "integ-t003" "worktree")
stored_branch=$(get_field "integ-t003" "branch")
if [[ "$stored_wt" == "$wt_t003" ]]; then
    pass "Worktree path stored in DB"
else
    fail "Worktree path mismatch: stored='$stored_wt' expected='$wt_t003'"
fi
if [[ "$stored_branch" == "feature/integ-t003" ]]; then
    pass "Branch name stored in DB"
else
    fail "Branch mismatch: stored='$stored_branch' expected='feature/integ-t003'"
fi

# Transition to running (simulates worker starting)
sup transition integ-t003 running >/dev/null
if [[ "$(get_status integ-t003)" == "running" ]]; then
    pass "Task transitioned to running"
else
    fail "Task not in running state"
fi

# Simulate worker creating a commit in the worktree
echo "feature code" > "$wt_t003/feature.txt"
git -C "$wt_t003" add feature.txt &>/dev/null
git -C "$wt_t003" commit -m "feat: add feature code" &>/dev/null

# Create a successful worker log
create_log "integ-t003" "Working on task integ-t003...
Created feature.txt
Running tests...
All tests passed
FULL_LOOP_COMPLETE
EXIT:0" >/dev/null

# Transition to evaluating
sup transition integ-t003 evaluating >/dev/null
if [[ "$(get_status integ-t003)" == "evaluating" ]]; then
    pass "Task transitioned to evaluating"
else
    fail "Task not in evaluating state"
fi

# Run evaluation
eval_result=$(sup evaluate integ-t003 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete"; then
    pass "Evaluation verdict: complete (FULL_LOOP_COMPLETE signal detected)"
else
    fail "Evaluation should be complete" "Got: $eval_result"
fi

# Transition to complete
sup transition integ-t003 complete >/dev/null
if [[ "$(get_status integ-t003)" == "complete" ]]; then
    pass "Task transitioned to complete"
else
    fail "Task not in complete state"
fi

# Verify the worktree has the feature commit
wt_ahead=$(git -C "$wt_t003" rev-list --count "main..HEAD" 2>/dev/null || echo "0")
if [[ "$wt_ahead" -gt 0 ]]; then
    pass "Worktree has $wt_ahead commit(s) from simulated worker"
else
    fail "Worktree should have commits from simulated worker"
fi

# Clean up worktree
git -C "$TEST_REPO" worktree remove "$wt_t003" --force &>/dev/null || rm -rf "$wt_t003"
git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/integ-t003" &>/dev/null || true

# ============================================================
# SECTION 4: Retry Cycle (evaluate -> retry -> re-dispatch)
# ============================================================
section "Retry Cycle (clean_exit_no_signal -> retry -> re-dispatch)"

sup add integ-t004 --repo "$TEST_REPO" --description "Retry cycle test" --no-issue >/dev/null

# First dispatch cycle
wt_t004=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-t004' '$TEST_REPO'
" 2>/dev/null)

sup transition integ-t004 dispatched --worktree "$wt_t004" --branch "feature/integ-t004" >/dev/null
sup transition integ-t004 running >/dev/null

# Create a log with clean exit but no completion signal (triggers retry)
create_log "integ-t004" "Working on task integ-t004...
Started processing
EXIT:0" >/dev/null

# Evaluate — should recommend retry
sup transition integ-t004 evaluating >/dev/null
eval_result=$(sup evaluate integ-t004 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*clean_exit_no_signal"; then
    pass "First attempt: retry:clean_exit_no_signal (no signal, no PR)"
else
    fail "First attempt should be retry:clean_exit_no_signal" "Got: $eval_result"
fi

# Execute retry transition
sup transition integ-t004 retrying >/dev/null
retries=$(get_field "integ-t004" "retries")
if [[ "$retries" -eq 1 ]]; then
    pass "Retry counter incremented to 1"
else
    fail "Retry counter is $retries, expected 1"
fi

# Re-dispatch (simulates supervisor re-dispatching after retry)
sup transition integ-t004 dispatched >/dev/null

# Force-fresh worktree for retry
wt_t004_retry=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-t004' '$TEST_REPO' 'true'
" 2>/dev/null)

if [[ -d "$wt_t004_retry" ]]; then
    pass "Retry worktree created (force-fresh)"
else
    fail "Retry worktree not created"
fi

# Second attempt: worker succeeds
sup transition integ-t004 running >/dev/null

echo "retry feature" > "$wt_t004_retry/retry-feature.txt"
git -C "$wt_t004_retry" add retry-feature.txt &>/dev/null
git -C "$wt_t004_retry" commit -m "feat: retry success" &>/dev/null

create_log "integ-t004" "Working on task integ-t004 (retry)...
Created retry-feature.txt
FULL_LOOP_COMPLETE
EXIT:0" >/dev/null

sup transition integ-t004 evaluating >/dev/null
eval_result2=$(sup evaluate integ-t004 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result2" | grep -q "complete"; then
    pass "Second attempt: complete (FULL_LOOP_COMPLETE after retry)"
else
    fail "Second attempt should be complete" "Got: $eval_result2"
fi

sup transition integ-t004 complete >/dev/null
if [[ "$(get_status integ-t004)" == "complete" ]]; then
    pass "Task completed after retry cycle"
else
    fail "Task not complete after retry"
fi

# Clean up
git -C "$TEST_REPO" worktree remove "$wt_t004_retry" --force &>/dev/null || rm -rf "$wt_t004_retry"
git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/integ-t004" &>/dev/null || true

# ============================================================
# SECTION 5: Evaluation Outcomes with Real Worktrees
# ============================================================
section "Evaluation Outcomes (various worker scenarios)"

# Test: TASK_COMPLETE signal
sup add integ-t005a --repo "$TEST_REPO" --description "TASK_COMPLETE test" --no-issue >/dev/null
sup transition integ-t005a dispatched >/dev/null
sup transition integ-t005a running >/dev/null
create_log "integ-t005a" "Working...
TASK_COMPLETE
EXIT:0" >/dev/null
eval_result=$(sup evaluate integ-t005a --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete.*task_only"; then
    pass "TASK_COMPLETE + exit 0 -> complete:task_only"
else
    fail "TASK_COMPLETE should be complete:task_only" "Got: $eval_result"
fi

# Test: Rate limit error
sup add integ-t005b --repo "$TEST_REPO" --description "Rate limit test" --no-issue >/dev/null
sup transition integ-t005b dispatched >/dev/null
sup transition integ-t005b running >/dev/null
create_log "integ-t005b" "Working...
429 Too Many Requests
EXIT:1" >/dev/null
eval_result=$(sup evaluate integ-t005b --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*rate_limited"; then
    pass "Rate limit + exit 1 -> retry:rate_limited"
else
    fail "Rate limit should be retry:rate_limited" "Got: $eval_result"
fi

# Test: Auth error (blocked)
sup add integ-t005c --repo "$TEST_REPO" --description "Auth error test" --no-issue >/dev/null
sup transition integ-t005c dispatched >/dev/null
sup transition integ-t005c running >/dev/null
create_log "integ-t005c" "Working...
permission denied
EXIT:1" >/dev/null
eval_result=$(sup evaluate integ-t005c --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*auth_error"; then
    pass "Auth error + exit 1 -> blocked:auth_error"
else
    fail "Auth error should be blocked:auth_error" "Got: $eval_result"
fi

# Test: Merge conflict (blocked)
sup add integ-t005d --repo "$TEST_REPO" --description "Merge conflict test" --no-issue >/dev/null
sup transition integ-t005d dispatched >/dev/null
sup transition integ-t005d running >/dev/null
create_log "integ-t005d" "Working...
CONFLICT (content): Merge conflict in main.py
EXIT:1" >/dev/null
eval_result=$(sup evaluate integ-t005d --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*merge_conflict"; then
    pass "Merge conflict + exit 1 -> blocked:merge_conflict"
else
    fail "Merge conflict should be blocked:merge_conflict" "Got: $eval_result"
fi

# Test: SIGINT (exit 130)
sup add integ-t005e --repo "$TEST_REPO" --description "SIGINT test" --no-issue >/dev/null
sup transition integ-t005e dispatched >/dev/null
sup transition integ-t005e running >/dev/null
create_log "integ-t005e" "Working...
EXIT:130" >/dev/null
eval_result=$(sup evaluate integ-t005e --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*interrupted_sigint"; then
    pass "Exit 130 -> retry:interrupted_sigint"
else
    fail "Exit 130 should be retry:interrupted_sigint" "Got: $eval_result"
fi

# Test: Backend infrastructure error
sup add integ-t005f --repo "$TEST_REPO" --description "Backend error test" --no-issue >/dev/null
sup transition integ-t005f dispatched >/dev/null
sup transition integ-t005f running >/dev/null
create_log "integ-t005f" "Working...
HTTP 503 Service Unavailable
EXIT:1" >/dev/null
eval_result=$(sup evaluate integ-t005f --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*backend_infrastructure_error"; then
    pass "Backend error + exit 1 -> retry:backend_infrastructure_error"
else
    fail "Backend error should be retry:backend_infrastructure_error" "Got: $eval_result"
fi

# Test: No log file (failed)
sup add integ-t005g --repo "$TEST_REPO" --description "No log test" --no-issue >/dev/null
sup transition integ-t005g dispatched >/dev/null
sup transition integ-t005g running >/dev/null
# Don't create a log file
eval_result=$(sup evaluate integ-t005g --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "failed.*no_log_file"; then
    pass "No log file -> failed:no_log_file"
else
    fail "No log file should be failed:no_log_file" "Got: $eval_result"
fi

# ============================================================
# SECTION 6: Batch with Multiple Tasks (end-to-end)
# ============================================================
section "Batch Pipeline (multi-task end-to-end)"

# Add tasks
sup add integ-batch-t1 --repo "$TEST_REPO" --description "Batch task 1" --no-issue >/dev/null
sup add integ-batch-t2 --repo "$TEST_REPO" --description "Batch task 2" --no-issue >/dev/null
sup add integ-batch-t3 --repo "$TEST_REPO" --description "Batch task 3" --no-issue >/dev/null

# Create batch
batch_output=$(sup batch integ-test-batch --concurrency 2 --tasks "integ-batch-t1,integ-batch-t2,integ-batch-t3" 2>&1)
batch_id=$(echo "$batch_output" | grep -oE 'batch-[0-9]+-[0-9]+' | head -1)

if [[ -n "$batch_id" ]]; then
    pass "Batch created: $batch_id"
else
    fail "Batch creation failed" "$batch_output"
fi

# Verify batch is active
batch_status=$(test_db "SELECT status FROM batches WHERE id = '$batch_id';" 2>/dev/null || echo "")
if [[ "$batch_status" == "active" ]]; then
    pass "Batch is in active state"
else
    fail "Batch status is '$batch_status', expected 'active'"
fi

# Dispatch and complete task 1 (with worktree)
wt_bt1=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-batch-t1' '$TEST_REPO'
" 2>/dev/null)

sup transition integ-batch-t1 dispatched --worktree "$wt_bt1" --branch "feature/integ-batch-t1" >/dev/null
sup transition integ-batch-t1 running >/dev/null

echo "batch task 1 work" > "$wt_bt1/task1.txt"
git -C "$wt_bt1" add task1.txt &>/dev/null
git -C "$wt_bt1" commit -m "feat: batch task 1" &>/dev/null

create_log "integ-batch-t1" "Batch task 1 complete
FULL_LOOP_COMPLETE
EXIT:0" >/dev/null

sup transition integ-batch-t1 evaluating >/dev/null
sup transition integ-batch-t1 complete >/dev/null

# Batch should still be active (2 tasks remaining)
batch_status=$(test_db "SELECT status FROM batches WHERE id = '$batch_id';")
if [[ "$batch_status" == "active" ]]; then
    pass "Batch stays active after 1/3 tasks complete"
else
    fail "Batch status is '$batch_status', expected 'active'"
fi

# Dispatch and complete task 2 (with worktree)
wt_bt2=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-batch-t2' '$TEST_REPO'
" 2>/dev/null)

sup transition integ-batch-t2 dispatched --worktree "$wt_bt2" --branch "feature/integ-batch-t2" >/dev/null
sup transition integ-batch-t2 running >/dev/null

echo "batch task 2 work" > "$wt_bt2/task2.txt"
git -C "$wt_bt2" add task2.txt &>/dev/null
git -C "$wt_bt2" commit -m "feat: batch task 2" &>/dev/null

create_log "integ-batch-t2" "Batch task 2 complete
FULL_LOOP_COMPLETE
EXIT:0" >/dev/null

sup transition integ-batch-t2 evaluating >/dev/null
sup transition integ-batch-t2 complete >/dev/null

# Batch should still be active (1 task remaining)
batch_status=$(test_db "SELECT status FROM batches WHERE id = '$batch_id';")
if [[ "$batch_status" == "active" ]]; then
    pass "Batch stays active after 2/3 tasks complete"
else
    fail "Batch status is '$batch_status', expected 'active'"
fi

# Dispatch and complete task 3 (with worktree)
wt_bt3=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-batch-t3' '$TEST_REPO'
" 2>/dev/null)

sup transition integ-batch-t3 dispatched --worktree "$wt_bt3" --branch "feature/integ-batch-t3" >/dev/null
sup transition integ-batch-t3 running >/dev/null

echo "batch task 3 work" > "$wt_bt3/task3.txt"
git -C "$wt_bt3" add task3.txt &>/dev/null
git -C "$wt_bt3" commit -m "feat: batch task 3" &>/dev/null

create_log "integ-batch-t3" "Batch task 3 complete
FULL_LOOP_COMPLETE
EXIT:0" >/dev/null

sup transition integ-batch-t3 evaluating >/dev/null
sup transition integ-batch-t3 complete >/dev/null

# Batch should now be complete
batch_status=$(test_db "SELECT status FROM batches WHERE id = '$batch_id';")
if [[ "$batch_status" == "complete" ]]; then
    pass "Batch auto-completes when all 3 tasks finish"
else
    fail "Batch status is '$batch_status', expected 'complete'"
fi

# Verify all tasks are complete
for tid in integ-batch-t1 integ-batch-t2 integ-batch-t3; do
    if [[ "$(get_status "$tid")" == "complete" ]]; then
        pass "Task $tid is complete"
    else
        fail "Task $tid is $(get_status "$tid"), expected complete"
    fi
done

# Clean up batch worktrees
for wt in "$wt_bt1" "$wt_bt2" "$wt_bt3"; do
    git -C "$TEST_REPO" worktree remove "$wt" --force &>/dev/null || rm -rf "$wt"
done
git -C "$TEST_REPO" worktree prune &>/dev/null || true
for branch in feature/integ-batch-t1 feature/integ-batch-t2 feature/integ-batch-t3; do
    git -C "$TEST_REPO" branch -D "$branch" &>/dev/null || true
done

# ============================================================
# SECTION 7: cmd_next and Running Count Integration
# ============================================================
section "cmd_next and Running Count"

# Add queued tasks to a new batch
sup add integ-next-t1 --repo "$TEST_REPO" --description "Next test 1" --no-issue >/dev/null
sup add integ-next-t2 --repo "$TEST_REPO" --description "Next test 2" --no-issue >/dev/null
sup add integ-next-t3 --repo "$TEST_REPO" --description "Next test 3" --no-issue >/dev/null

next_batch_output=$(sup batch integ-next-batch --concurrency 2 --tasks "integ-next-t1,integ-next-t2,integ-next-t3" 2>&1)
next_batch_id=$(echo "$next_batch_output" | grep -oE 'batch-[0-9]+-[0-9]+' | head -1)

if [[ -n "$next_batch_id" ]]; then
    pass "Next-test batch created"
else
    skip "Could not create next-test batch"
fi

# cmd_next should return queued tasks
next_output=$(sup next "$next_batch_id" 5 2>&1)
next_count=$(echo "$next_output" | grep -c "integ-next" || echo "0")
if [[ "$next_count" -ge 3 ]]; then
    pass "cmd_next returns all 3 queued tasks"
else
    fail "cmd_next returned $next_count tasks, expected >= 3" "Output: $next_output"
fi

# Dispatch one task — running count should be 1
sup transition integ-next-t1 dispatched >/dev/null
sup transition integ-next-t1 running >/dev/null

running=$(sup running-count "$next_batch_id" 2>&1 | tail -1)
if [[ "$running" == "1" ]]; then
    pass "running-count reports 1 active task"
else
    fail "running-count is '$running', expected '1'"
fi

# cmd_next should still return remaining queued tasks (no concurrency check in cmd_next)
next_output2=$(sup next "$next_batch_id" 5 2>&1)
next_count2=$(echo "$next_output2" | grep -c "integ-next-t[23]" || echo "0")
if [[ "$next_count2" -ge 2 ]]; then
    pass "cmd_next returns remaining queued tasks (concurrency delegated to cmd_dispatch)"
else
    fail "cmd_next returned $next_count2 remaining tasks, expected >= 2"
fi

# ============================================================
# SECTION 8: State Log Audit Trail (integration)
# ============================================================
section "State Log Audit Trail (integration)"

# Check state log for integ-t003 (went through full pipeline)
log_count=$(test_db "SELECT count(*) FROM state_log WHERE task_id = 'integ-t003';")
if [[ "$log_count" -ge 5 ]]; then
    pass "State log has $log_count entries for full pipeline task (integ-t003)"
else
    fail "State log has only $log_count entries, expected >= 5"
fi

# Verify the transitions are in correct order
transitions=$(test_db "SELECT from_state || '->' || to_state FROM state_log WHERE task_id = 'integ-t003' ORDER BY id;")
expected_sequence="->queued
queued->dispatched
dispatched->running
running->evaluating
evaluating->complete"

if [[ "$transitions" == "$expected_sequence" ]]; then
    pass "State log transitions match expected sequence"
else
    fail "State log transitions don't match" "Got: $(echo "$transitions" | tr '\n' ' ')"
fi

# Check retry task log (integ-t004 went through retry cycle)
retry_log_count=$(test_db "SELECT count(*) FROM state_log WHERE task_id = 'integ-t004';")
if [[ "$retry_log_count" -ge 8 ]]; then
    pass "Retry task state log has $retry_log_count entries (includes retry cycle)"
else
    fail "Retry task state log has only $retry_log_count entries, expected >= 8"
fi

# ============================================================
# SECTION 9: Error Strings in Exit-0 Logs (content discussion)
# ============================================================
section "Error Strings in Exit-0 Logs (false positive guard)"

sup add integ-t006 --repo "$TEST_REPO" --description "Content discussion test" --no-issue >/dev/null
sup transition integ-t006 dispatched >/dev/null
sup transition integ-t006 running >/dev/null

# Log discusses auth errors as content (not real failures)
create_log "integ-t006" "Documenting authentication flows:
The API returns 401 unauthorized when token expires
permission denied errors should be handled gracefully
Rate limit: 429 responses need exponential backoff
EXIT:0" >/dev/null

eval_result=$(sup evaluate integ-t006 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*clean_exit_no_signal"; then
    pass "Exit 0 + error strings in content -> retry:clean_exit_no_signal (not blocked)"
else
    fail "Exit 0 with error strings should NOT be blocked" "Got: $eval_result"
fi

# ============================================================
# SECTION: Backend Error in Retry Logs (t198)
# ============================================================
section "Backend Error in Retry Logs (t198)"

# Integration test: backend error with REPROMPT METADATA header
sup add integ-t198a --repo "$TEST_REPO" --description "Backend error retry test" --no-issue >/dev/null
sup transition integ-t198a dispatched >/dev/null
sup transition integ-t198a running >/dev/null

create_log "integ-t198a" '=== REPROMPT METADATA (t183) ===
task_id=integ-t198a
timestamp=2026-02-09T23:30:27Z
retry=1/3
work_dir=/tmp/test
previous_error=clean_exit_no_signal
fresh_worktree=true
=== END REPROMPT METADATA ===

WORKER_STARTED task_id=integ-t198a retry=1 pid=$$ timestamp=2026-02-09T23:30:27Z
{"type":"error","error":{"message":"Error: All Antigravity endpoints failed"}}
EXIT:0' >/dev/null

sup transition integ-t198a evaluating >/dev/null
eval_result=$(sup evaluate integ-t198a --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*backend_quota_error"; then
    pass "Backend error + REPROMPT METADATA -> backend_quota_error (t198)"
else
    fail "Backend error in retry log should be backend_quota_error" "Got: $eval_result"
fi

# ============================================================
# SECTION: GitHub Auth Failure Detection (t198)
# ============================================================
section "GitHub Auth Failure Detection (t198)"

# Integration test: worker completes work but gh auth is expired
sup add integ-t198b --repo "$TEST_REPO" --description "GH auth failure test" --no-issue >/dev/null
sup transition integ-t198b dispatched >/dev/null
sup transition integ-t198b running >/dev/null

create_log "integ-t198b" 'WORKER_STARTED task_id=integ-t198b pid=12345 timestamp=2026-02-09T03:00:00Z
{"type":"step_start","timestamp":1770606000000,"part":{"type":"step-start"}}
{"type":"text","timestamp":1770606100000,"part":{"type":"text","text":"All implementation complete. Files created and committed."}}
{"type":"tool_use","timestamp":1770606200000,"part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"gh auth status"},"output":"You are not logged in to any GitHub hosts. Run gh auth login to authenticate.","metadata":{"exit":1}}}}
{"type":"text","timestamp":1770606300000,"part":{"type":"text","text":"GitHub authentication has expired. Cannot create PR."}}
{"type":"step_finish","timestamp":1770606400000,"part":{"type":"step-finish","reason":"stop"}}
EXIT:0' >/dev/null

sup transition integ-t198b evaluating >/dev/null
eval_result=$(sup evaluate integ-t198b --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*gh_auth_expired"; then
    pass "Worker + gh auth failure -> blocked:gh_auth_expired (t198)"
else
    fail "Worker with gh auth failure should be blocked:gh_auth_expired" "Got: $eval_result"
fi

# ============================================================
# SECTION 10: Concurrent Worktrees (parallel tasks)
# ============================================================
section "Concurrent Worktrees (parallel task isolation)"

sup add integ-para-t1 --repo "$TEST_REPO" --description "Parallel task 1" --no-issue >/dev/null
sup add integ-para-t2 --repo "$TEST_REPO" --description "Parallel task 2" --no-issue >/dev/null

# Create two worktrees simultaneously
wt_para1=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-para-t1' '$TEST_REPO'
" 2>/dev/null)

wt_para2=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'integ-para-t2' '$TEST_REPO'
" 2>/dev/null)

# Both should exist and be on different branches
if [[ -d "$wt_para1" && -d "$wt_para2" ]]; then
    pass "Two concurrent worktrees created"
else
    fail "Failed to create concurrent worktrees" "wt1=$wt_para1 wt2=$wt_para2"
fi

branch_para1=$(git -C "$wt_para1" branch --show-current 2>/dev/null || echo "")
branch_para2=$(git -C "$wt_para2" branch --show-current 2>/dev/null || echo "")

if [[ "$branch_para1" == "feature/integ-para-t1" && "$branch_para2" == "feature/integ-para-t2" ]]; then
    pass "Concurrent worktrees on separate branches"
else
    fail "Branch mismatch" "wt1=$branch_para1 wt2=$branch_para2"
fi

# Changes in one worktree don't affect the other
echo "parallel work 1" > "$wt_para1/para1.txt"
git -C "$wt_para1" add para1.txt &>/dev/null
git -C "$wt_para1" commit -m "parallel 1" &>/dev/null

if [[ ! -f "$wt_para2/para1.txt" ]]; then
    pass "Worktree isolation: changes in wt1 don't appear in wt2"
else
    fail "Worktree isolation broken: wt1 changes visible in wt2"
fi

# Clean up
for wt in "$wt_para1" "$wt_para2"; do
    git -C "$TEST_REPO" worktree remove "$wt" --force &>/dev/null || rm -rf "$wt"
done
git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/integ-para-t1" &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/integ-para-t2" &>/dev/null || true

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
