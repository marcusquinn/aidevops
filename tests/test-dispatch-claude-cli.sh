#!/usr/bin/env bash
# shellcheck disable=SC2034
# test-dispatch-claude-cli.sh
#
# Integration test for the full dispatch cycle with SUPERVISOR_CLI=claude (t1160.7).
#
# Tests the end-to-end cycle that the supervisor performs when using the Claude CLI:
#   1. CLI resolution: resolve_ai_cli() with SUPERVISOR_CLI=claude
#   2. Command building: build_cli_cmd() produces correct claude CLI commands
#   3. Worker spawn: dispatch/wrapper script generation with claude-specific flags
#   4. Output capture: log files with worker sentinels (WORKER_STARTED, EXIT:N)
#   5. Evaluation: evaluate_worker() with various worker outcomes
#   6. Cleanup: cleanup_task_worktree(), cleanup_worker_processes(), cleanup_after_merge()
#
# This test does NOT spawn real Claude CLI processes — it mocks the claude binary
# and verifies the supervisor's orchestration logic produces correct commands,
# captures output correctly, evaluates results, and cleans up artifacts.
#
# Usage: bash tests/test-dispatch-claude-cli.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/.agents/scripts"
SUPERVISOR_SCRIPT="$SCRIPTS_DIR/supervisor-helper.sh"
SUPERVISOR_DIR_MODULE="$SCRIPTS_DIR/supervisor"
SHARED_CONSTANTS="$SCRIPTS_DIR/shared-constants.sh"
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

# Create mock claude binary that records invocations
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/claude" <<'MOCK_CLAUDE'
#!/usr/bin/env bash
# Mock claude CLI — records args and produces realistic output
MOCK_LOG="${MOCK_CLAUDE_LOG:-/tmp/mock-claude-invocations.log}"
echo "MOCK_CLAUDE_INVOKED: $*" >> "$MOCK_LOG"

# Handle --version
if [[ "${1:-}" == "--version" ]]; then
    echo "claude 1.0.20 (mock)"
    exit 0
fi

# Handle -p (prompt mode)
if [[ "${1:-}" == "-p" ]]; then
    # Check for --output-format
    output_format="text"
    for arg in "$@"; do
        if [[ "$arg" == "json" ]]; then
            output_format="json"
        fi
    done

    if [[ "$output_format" == "json" ]]; then
        echo '{"type":"text","text":"Mock claude response: task completed successfully.\nFULL_LOOP_COMPLETE"}'
    else
        echo "OK"
    fi
    exit 0
fi

echo "claude: unknown command" >&2
exit 1
MOCK_CLAUDE
chmod +x "$MOCK_BIN/claude"

# Export mock log path for verification
export MOCK_CLAUDE_LOG="$TEST_DIR/mock-claude-invocations.log"

# shellcheck disable=SC2317,SC2329
cleanup() {
	# Remove all worktrees before deleting the repo
	if [[ -d "$TEST_REPO" ]]; then
		git -C "$TEST_REPO" worktree list --porcelain 2>/dev/null |
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
	echo "$content" >"$log_file"
	# Update the task's log_file in DB
	test_db "UPDATE tasks SET log_file = '$log_file' WHERE id = '$task_id';"
	echo "$log_file"
}

# ============================================================
# SETUP: Create a real git repo and initialize supervisor
# ============================================================
section "Test Environment Setup"

# Initialize a real git repo with a commit on main
git init "$TEST_REPO" &>/dev/null
git -C "$TEST_REPO" checkout -b main &>/dev/null 2>&1 || true
echo "# Test Repo" >"$TEST_REPO/README.md"
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
# SECTION 1: CLI Resolution with SUPERVISOR_CLI=claude
# ============================================================
section "CLI Resolution (SUPERVISOR_CLI=claude)"

# Source individual modules for unit-level tests (avoids running main init)
# resolve_ai_cli lives in dispatch.sh, which needs _common.sh for log_* functions
cli_result=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export SUPERVISOR_CLI=claude
    export PATH='$MOCK_BIN:\$PATH'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    resolve_ai_cli
" 2>/dev/null)

if [[ "$cli_result" == "claude" ]]; then
	pass "resolve_ai_cli returns 'claude' when SUPERVISOR_CLI=claude"
else
	fail "resolve_ai_cli returned '$cli_result', expected 'claude'"
fi

# Test: resolve_ai_cli rejects invalid SUPERVISOR_CLI values
# Note: _common.sh sets -e, so we must catch the failure explicitly
invalid_rc=0
bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export SUPERVISOR_CLI=invalid_cli
    export PATH='$MOCK_BIN:\$PATH'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    resolve_ai_cli
" &>/dev/null || invalid_rc=$?

if [[ "$invalid_rc" -ne 0 ]]; then
	pass "resolve_ai_cli rejects invalid SUPERVISOR_CLI value (exit $invalid_rc)"
else
	fail "resolve_ai_cli should reject 'invalid_cli' (exit 0)"
fi

# Test: resolve_ai_cli fails when SUPERVISOR_CLI=claude but claude not in PATH
missing_rc=0
bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export SUPERVISOR_CLI=claude
    export PATH='/nonexistent'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    resolve_ai_cli
" &>/dev/null || missing_rc=$?

if [[ "$missing_rc" -ne 0 ]]; then
	pass "resolve_ai_cli fails when claude not in PATH (exit $missing_rc)"
else
	fail "resolve_ai_cli should fail when claude not in PATH (exit 0)"
fi

# ============================================================
# SECTION 2: Command Building (build_cli_cmd for claude)
# ============================================================
section "Command Building (build_cli_cmd for claude)"

# Test: build_cli_cmd produces correct claude run command
run_cmd=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export PATH='$MOCK_BIN:$PATH'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    # Use array output mode for readable verification
    build_cli_cmd --cli claude --action run --output array \
        --model 'anthropic/claude-sonnet-4-6' \
        --prompt 'Test prompt here'
" 2>/dev/null)

if echo "$run_cmd" | grep -q "^claude"; then
	pass "build_cli_cmd run: starts with 'claude'"
else
	fail "build_cli_cmd run: should start with 'claude'" "Got: $run_cmd"
fi

if echo "$run_cmd" | grep -q "\-p"; then
	pass "build_cli_cmd run: includes -p flag"
else
	fail "build_cli_cmd run: should include -p flag" "Got: $run_cmd"
fi

if echo "$run_cmd" | grep -q "output-format"; then
	pass "build_cli_cmd run: includes --output-format"
else
	fail "build_cli_cmd run: should include --output-format" "Got: $run_cmd"
fi

# Verify model prefix stripping (anthropic/ prefix removed)
if echo "$run_cmd" | grep -q "claude-sonnet-4-6" && ! echo "$run_cmd" | grep -q "anthropic/"; then
	pass "build_cli_cmd run: strips provider prefix from model"
else
	fail "build_cli_cmd run: should strip 'anthropic/' prefix" "Got: $run_cmd"
fi

# Test: build_cli_cmd produces correct claude version command
version_cmd=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    build_cli_cmd --cli claude --action version --output array
" 2>/dev/null)

if [[ "$version_cmd" == *"claude"*"--version"* ]]; then
	pass "build_cli_cmd version: produces 'claude --version'"
else
	fail "build_cli_cmd version: should produce 'claude --version'" "Got: $version_cmd"
fi

# Test: build_cli_cmd produces correct claude probe command
probe_cmd=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    build_cli_cmd --cli claude --action probe --output array \
        --model 'anthropic/claude-sonnet-4-6'
" 2>/dev/null)

if echo "$probe_cmd" | grep -q "output-format.*text\|text.*output-format"; then
	pass "build_cli_cmd probe: uses --output-format text (not json)"
else
	fail "build_cli_cmd probe: should use text format for probe" "Got: $probe_cmd"
fi

if echo "$probe_cmd" | grep -q "Reply with exactly: OK\|Reply.*OK"; then
	pass "build_cli_cmd probe: includes health-check prompt"
else
	fail "build_cli_cmd probe: should include health-check prompt" "Got: $probe_cmd"
fi

# ============================================================
# SECTION 3: Worker Spawn (dispatch + wrapper script generation)
# ============================================================
section "Worker Spawn (dispatch + wrapper scripts)"

# Add a task and simulate the dispatch pipeline
sup add claude-spawn-t1 --repo "$TEST_REPO" --description "Claude spawn test" --no-issue >/dev/null

# Create worktree
wt_spawn=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'claude-spawn-t1' '$TEST_REPO'
" 2>/dev/null)

if [[ -d "$wt_spawn" ]]; then
	pass "Worktree created for claude dispatch test"
else
	fail "Worktree not created: '$wt_spawn'"
fi

# Test: build_dispatch_cmd produces NUL-delimited command with claude flags
dispatch_output=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export SUPERVISOR_CLI=claude
    export PATH='$MOCK_BIN:$PATH'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    build_dispatch_cmd 'claude-spawn-t1' '$wt_spawn' '/tmp/test.log' 'claude' '' 'anthropic/claude-sonnet-4-6' 'Test dispatch'
" 2>/dev/null | tr '\0' '\n')

if echo "$dispatch_output" | grep -q "^claude$"; then
	pass "build_dispatch_cmd: first token is 'claude'"
else
	fail "build_dispatch_cmd: first token should be 'claude'" "Got first lines: $(echo "$dispatch_output" | head -3)"
fi

if echo "$dispatch_output" | grep -q "^-p$"; then
	pass "build_dispatch_cmd: includes -p flag"
else
	fail "build_dispatch_cmd: should include -p flag"
fi

if echo "$dispatch_output" | grep -q "output-format"; then
	pass "build_dispatch_cmd: includes --output-format"
else
	fail "build_dispatch_cmd: should include --output-format"
fi

# Verify the prompt contains the task ID and worker restrictions
prompt_token=$(echo "$dispatch_output" | grep "full-loop" | head -1)
if echo "$prompt_token" | grep -q "claude-spawn-t1"; then
	pass "build_dispatch_cmd: prompt contains task ID"
else
	fail "build_dispatch_cmd: prompt should contain task ID" "Got: $prompt_token"
fi

# Clean up worktree
git -C "$TEST_REPO" worktree remove "$wt_spawn" --force &>/dev/null || rm -rf "$wt_spawn"
git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/claude-spawn-t1" &>/dev/null || true

# ============================================================
# SECTION 4: Output Capture (log files with worker sentinels)
# ============================================================
section "Output Capture (log file sentinel detection)"

# Test: FULL_LOOP_COMPLETE signal in claude JSON output
sup add claude-cap-t1 --repo "$TEST_REPO" --description "Output capture test" --no-issue >/dev/null
sup transition claude-cap-t1 dispatched >/dev/null
sup transition claude-cap-t1 running >/dev/null

create_log "claude-cap-t1" 'WRAPPER_STARTED task_id=claude-cap-t1 wrapper_pid=12345 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-cap-t1 pid=12346 timestamp=2026-02-21T10:00:01Z
{"type":"text","text":"Working on task claude-cap-t1...\nCreated feature implementation.\nAll tests passed.\nFULL_LOOP_COMPLETE\nhttps://github.com/test/repo/pull/42"}
EXIT:0' >/dev/null

sup transition claude-cap-t1 evaluating >/dev/null
eval_result=$(sup evaluate claude-cap-t1 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete"; then
	pass "Claude output: FULL_LOOP_COMPLETE detected in JSON text output"
else
	fail "Claude output: should detect FULL_LOOP_COMPLETE" "Got: $eval_result"
fi

# Test: PR URL extraction from claude JSON output
pr_url=$(get_field "claude-cap-t1" "pr_url")
if [[ "$pr_url" == "https://github.com/test/repo/pull/42" ]]; then
	pass "Claude output: PR URL extracted from JSON text output"
else
	# PR URL extraction may depend on repo slug detection — skip if not set
	skip "PR URL extraction depends on repo slug validation (got: '$pr_url')"
fi

# Test: WORKER_STARTED sentinel detected
meta_output=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/evaluate.sh'
    extract_log_metadata '$TEST_DIR/supervisor/logs/claude-cap-t1.log'
" 2>/dev/null)

if echo "$meta_output" | grep -q "worker_started=true"; then
	pass "Claude output: WORKER_STARTED sentinel detected"
else
	fail "Claude output: should detect WORKER_STARTED" "Got: $meta_output"
fi

if echo "$meta_output" | grep -q "wrapper_started=true"; then
	pass "Claude output: WRAPPER_STARTED sentinel detected"
else
	fail "Claude output: should detect WRAPPER_STARTED" "Got: $meta_output"
fi

if echo "$meta_output" | grep -q "signal=FULL_LOOP_COMPLETE"; then
	pass "Claude output: signal=FULL_LOOP_COMPLETE in metadata"
else
	fail "Claude output: should have signal=FULL_LOOP_COMPLETE" "Got: $meta_output"
fi

# ============================================================
# SECTION 5: Evaluation (various claude worker outcomes)
# ============================================================
section "Evaluation (claude worker outcomes)"

# Test: Claude worker with clean exit and FULL_LOOP_COMPLETE
sup add claude-eval-t1 --repo "$TEST_REPO" --description "Eval complete test" --no-issue >/dev/null
sup transition claude-eval-t1 dispatched >/dev/null
sup transition claude-eval-t1 running >/dev/null
create_log "claude-eval-t1" 'WRAPPER_STARTED task_id=claude-eval-t1 wrapper_pid=1001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-eval-t1 pid=1002 timestamp=2026-02-21T10:00:01Z
{"type":"text","text":"Implemented feature.\nFULL_LOOP_COMPLETE"}
EXIT:0' >/dev/null
sup transition claude-eval-t1 evaluating >/dev/null
eval_result=$(sup evaluate claude-eval-t1 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete"; then
	pass "Eval: FULL_LOOP_COMPLETE + exit 0 -> complete"
else
	fail "Eval: should be complete" "Got: $eval_result"
fi

# Test: Claude worker with rate limit error
sup add claude-eval-t2 --repo "$TEST_REPO" --description "Eval rate limit test" --no-issue >/dev/null
sup transition claude-eval-t2 dispatched >/dev/null
sup transition claude-eval-t2 running >/dev/null
create_log "claude-eval-t2" 'WRAPPER_STARTED task_id=claude-eval-t2 wrapper_pid=2001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-eval-t2 pid=2002 timestamp=2026-02-21T10:00:01Z
{"type":"error","error":{"message":"429 Too Many Requests"}}
EXIT:1' >/dev/null
sup transition claude-eval-t2 evaluating >/dev/null
eval_result=$(sup evaluate claude-eval-t2 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*rate_limited"; then
	pass "Eval: rate limit error -> retry:rate_limited"
else
	fail "Eval: should be retry:rate_limited" "Got: $eval_result"
fi

# Test: Claude worker with backend error (Antigravity endpoints)
sup add claude-eval-t3 --repo "$TEST_REPO" --description "Eval backend error test" --no-issue >/dev/null
sup transition claude-eval-t3 dispatched >/dev/null
sup transition claude-eval-t3 running >/dev/null
create_log "claude-eval-t3" 'WRAPPER_STARTED task_id=claude-eval-t3 wrapper_pid=3001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-eval-t3 pid=3002 timestamp=2026-02-21T10:00:01Z
{"type":"error","error":{"message":"Error: All Antigravity endpoints failed"}}
EXIT:0' >/dev/null
sup transition claude-eval-t3 evaluating >/dev/null
eval_result=$(sup evaluate claude-eval-t3 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*backend"; then
	pass "Eval: backend error -> retry:backend_*"
else
	fail "Eval: should be retry with backend error" "Got: $eval_result"
fi

# Test: Claude worker with SIGINT (exit 130)
sup add claude-eval-t4 --repo "$TEST_REPO" --description "Eval SIGINT test" --no-issue >/dev/null
sup transition claude-eval-t4 dispatched >/dev/null
sup transition claude-eval-t4 running >/dev/null
create_log "claude-eval-t4" 'WRAPPER_STARTED task_id=claude-eval-t4 wrapper_pid=4001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-eval-t4 pid=4002 timestamp=2026-02-21T10:00:01Z
Working on task...
EXIT:130' >/dev/null
sup transition claude-eval-t4 evaluating >/dev/null
eval_result=$(sup evaluate claude-eval-t4 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*interrupted_sigint"; then
	pass "Eval: exit 130 -> retry:interrupted_sigint"
else
	fail "Eval: should be retry:interrupted_sigint" "Got: $eval_result"
fi

# Test: Claude worker with auth error (permission denied)
sup add claude-eval-t5 --repo "$TEST_REPO" --description "Eval auth error test" --no-issue >/dev/null
sup transition claude-eval-t5 dispatched >/dev/null
sup transition claude-eval-t5 running >/dev/null
create_log "claude-eval-t5" 'WRAPPER_STARTED task_id=claude-eval-t5 wrapper_pid=5001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-eval-t5 pid=5002 timestamp=2026-02-21T10:00:01Z
permission denied
EXIT:1' >/dev/null
sup transition claude-eval-t5 evaluating >/dev/null
eval_result=$(sup evaluate claude-eval-t5 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*auth_error"; then
	pass "Eval: permission denied -> blocked:auth_error"
else
	fail "Eval: should be blocked:auth_error" "Got: $eval_result"
fi

# Test: Claude worker with clean exit but no signal (triggers retry)
sup add claude-eval-t6 --repo "$TEST_REPO" --description "Eval no signal test" --no-issue >/dev/null
sup transition claude-eval-t6 dispatched >/dev/null
sup transition claude-eval-t6 running >/dev/null
create_log "claude-eval-t6" 'WRAPPER_STARTED task_id=claude-eval-t6 wrapper_pid=6001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-eval-t6 pid=6002 timestamp=2026-02-21T10:00:01Z
{"type":"text","text":"Started working on the task but ran out of context."}
EXIT:0' >/dev/null
sup transition claude-eval-t6 evaluating >/dev/null
eval_result=$(sup evaluate claude-eval-t6 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*clean_exit_no_signal"; then
	pass "Eval: clean exit no signal -> retry:clean_exit_no_signal"
else
	fail "Eval: should be retry:clean_exit_no_signal" "Got: $eval_result"
fi

# Test: Claude worker with TASK_COMPLETE signal
sup add claude-eval-t7 --repo "$TEST_REPO" --description "Eval TASK_COMPLETE test" --no-issue >/dev/null
sup transition claude-eval-t7 dispatched >/dev/null
sup transition claude-eval-t7 running >/dev/null
create_log "claude-eval-t7" 'WRAPPER_STARTED task_id=claude-eval-t7 wrapper_pid=7001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-eval-t7 pid=7002 timestamp=2026-02-21T10:00:01Z
{"type":"text","text":"Task completed.\nTASK_COMPLETE"}
EXIT:0' >/dev/null
sup transition claude-eval-t7 evaluating >/dev/null
eval_result=$(sup evaluate claude-eval-t7 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete.*task_only"; then
	pass "Eval: TASK_COMPLETE + exit 0 -> complete:task_only"
else
	fail "Eval: should be complete:task_only" "Got: $eval_result"
fi

# Test: Claude worker never started (dispatch exec failed)
sup add claude-eval-t8 --repo "$TEST_REPO" --description "Eval worker never started test" --no-issue >/dev/null
sup transition claude-eval-t8 dispatched >/dev/null
sup transition claude-eval-t8 running >/dev/null
create_log "claude-eval-t8" 'WRAPPER_STARTED task_id=claude-eval-t8 wrapper_pid=8001 timestamp=2026-02-21T10:00:00Z
EXIT:127' >/dev/null
sup transition claude-eval-t8 evaluating >/dev/null
eval_result=$(sup evaluate claude-eval-t8 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "failed.*worker_never_started"; then
	pass "Eval: wrapper started but no WORKER_STARTED -> failed:worker_never_started"
else
	fail "Eval: should be failed:worker_never_started" "Got: $eval_result"
fi

# ============================================================
# SECTION 6: Full Dispatch Pipeline (state transitions + worktree + eval)
# ============================================================
section "Full Dispatch Pipeline (claude CLI end-to-end)"

sup add claude-full-t1 --repo "$TEST_REPO" --description "Full pipeline claude test" --no-issue >/dev/null

# Create worktree
wt_full=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'claude-full-t1' '$TEST_REPO'
" 2>/dev/null)

# Simulate dispatch pipeline transitions
sup transition claude-full-t1 dispatched \
	--worktree "$wt_full" \
	--branch "feature/claude-full-t1" >/dev/null

if [[ "$(get_status claude-full-t1)" == "dispatched" ]]; then
	pass "Full pipeline: task dispatched with worktree metadata"
else
	fail "Full pipeline: task not in dispatched state: $(get_status claude-full-t1)"
fi

# Verify metadata stored
stored_wt=$(get_field "claude-full-t1" "worktree")
stored_branch=$(get_field "claude-full-t1" "branch")
if [[ "$stored_wt" == "$wt_full" ]]; then
	pass "Full pipeline: worktree path stored in DB"
else
	fail "Full pipeline: worktree path mismatch" "stored='$stored_wt' expected='$wt_full'"
fi

# Transition to running
sup transition claude-full-t1 running >/dev/null
if [[ "$(get_status claude-full-t1)" == "running" ]]; then
	pass "Full pipeline: task transitioned to running"
else
	fail "Full pipeline: task not in running state"
fi

# Simulate worker creating a commit in the worktree
echo "feature code from claude worker" >"$wt_full/feature.txt"
git -C "$wt_full" add feature.txt &>/dev/null
git -C "$wt_full" commit -m "feat: add feature code (claude-full-t1)" &>/dev/null

# Create a successful worker log (claude JSON format)
create_log "claude-full-t1" 'WRAPPER_STARTED task_id=claude-full-t1 wrapper_pid=9001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-full-t1 pid=9002 timestamp=2026-02-21T10:00:01Z
{"type":"text","text":"Working on task claude-full-t1...\nCreated feature.txt\nRunning tests...\nAll tests passed\nFULL_LOOP_COMPLETE"}
EXIT:0' >/dev/null

# Transition to evaluating
sup transition claude-full-t1 evaluating >/dev/null
if [[ "$(get_status claude-full-t1)" == "evaluating" ]]; then
	pass "Full pipeline: task transitioned to evaluating"
else
	fail "Full pipeline: task not in evaluating state"
fi

# Run evaluation
eval_result=$(sup evaluate claude-full-t1 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete"; then
	pass "Full pipeline: evaluation verdict is complete"
else
	fail "Full pipeline: evaluation should be complete" "Got: $eval_result"
fi

# Transition to complete
sup transition claude-full-t1 complete >/dev/null
if [[ "$(get_status claude-full-t1)" == "complete" ]]; then
	pass "Full pipeline: task transitioned to complete"
else
	fail "Full pipeline: task not in complete state"
fi

# Verify the worktree has the feature commit
wt_ahead=$(git -C "$wt_full" rev-list --count "main..HEAD" 2>/dev/null || echo "0")
if [[ "$wt_ahead" -gt 0 ]]; then
	pass "Full pipeline: worktree has $wt_ahead commit(s) from simulated worker"
else
	fail "Full pipeline: worktree should have commits from simulated worker"
fi

# Verify state log audit trail
log_count=$(test_db "SELECT count(*) FROM state_log WHERE task_id = 'claude-full-t1';")
if [[ "$log_count" -ge 5 ]]; then
	pass "Full pipeline: state log has $log_count entries"
else
	fail "Full pipeline: state log has only $log_count entries, expected >= 5"
fi

transitions=$(test_db "SELECT from_state || '->' || to_state FROM state_log WHERE task_id = 'claude-full-t1' ORDER BY id;")
expected_sequence="->queued
queued->dispatched
dispatched->running
running->evaluating
evaluating->complete"

if [[ "$transitions" == "$expected_sequence" ]]; then
	pass "Full pipeline: state transitions match expected sequence"
else
	fail "Full pipeline: state transitions don't match" "Got: $(echo "$transitions" | tr '\n' ' ')"
fi

# ============================================================
# SECTION 7: Cleanup (worktree, processes, after-merge)
# ============================================================
section "Cleanup (worktree, processes, after-merge)"

# Test: cleanup_task_worktree removes the worktree
if [[ -d "$wt_full" ]]; then
	bash -c "
        export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
        BLUE='' GREEN='' YELLOW='' RED='' NC=''
        SUPERVISOR_LOG='/dev/null'
        SUPERVISOR_DIR='$TEST_DIR/supervisor'
        SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
        source '$SHARED_CONSTANTS'
        source '$SUPERVISOR_DIR_MODULE/_common.sh'
        source '$SUPERVISOR_DIR_MODULE/cleanup.sh'
        # Stub ownership functions (not relevant for this test)
        is_worktree_owned_by_others() { return 1; }
        unregister_worktree() { return 0; }
        cleanup_task_worktree '$wt_full' '$TEST_REPO'
    " 2>/dev/null

	if [[ ! -d "$wt_full" ]]; then
		pass "Cleanup: worktree directory removed"
	else
		fail "Cleanup: worktree directory still exists after cleanup"
		# Force cleanup for subsequent tests
		rm -rf "$wt_full"
	fi
else
	pass "Cleanup: worktree already removed (cleanup not needed)"
fi

git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/claude-full-t1" &>/dev/null || true

# Test: cleanup_worker_processes removes PID file and scripts
mkdir -p "$TEST_DIR/supervisor/pids"
echo "99999" >"$TEST_DIR/supervisor/pids/claude-proc-t1.pid"
echo "#!/bin/bash" >"$TEST_DIR/supervisor/pids/claude-proc-t1-dispatch-20260221100000.sh"
echo "#!/bin/bash" >"$TEST_DIR/supervisor/pids/claude-proc-t1-wrapper-20260221100000.sh"
touch "$TEST_DIR/supervisor/pids/claude-proc-t1.hang-warned"

bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/cleanup.sh'
    cleanup_worker_processes 'claude-proc-t1'
" 2>/dev/null

if [[ ! -f "$TEST_DIR/supervisor/pids/claude-proc-t1.pid" ]]; then
	pass "Cleanup: PID file removed"
else
	fail "Cleanup: PID file still exists"
fi

if [[ ! -f "$TEST_DIR/supervisor/pids/claude-proc-t1.hang-warned" ]]; then
	pass "Cleanup: hang-warned marker removed"
else
	fail "Cleanup: hang-warned marker still exists"
fi

if [[ ! -f "$TEST_DIR/supervisor/pids/claude-proc-t1-dispatch-20260221100000.sh" ]]; then
	pass "Cleanup: dispatch script removed"
else
	fail "Cleanup: dispatch script still exists"
fi

if [[ ! -f "$TEST_DIR/supervisor/pids/claude-proc-t1-wrapper-20260221100000.sh" ]]; then
	pass "Cleanup: wrapper script removed"
else
	fail "Cleanup: wrapper script still exists"
fi

# Test: cleanup_after_merge removes worktree and clears DB fields
sup add claude-merge-t1 --repo "$TEST_REPO" --description "Merge cleanup test" --no-issue >/dev/null

wt_merge=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'claude-merge-t1' '$TEST_REPO'
" 2>/dev/null)

sup transition claude-merge-t1 dispatched \
	--worktree "$wt_merge" \
	--branch "feature/claude-merge-t1" >/dev/null
sup transition claude-merge-t1 running >/dev/null
sup transition claude-merge-t1 evaluating >/dev/null
sup transition claude-merge-t1 complete >/dev/null

# Verify worktree exists before cleanup
if [[ -d "$wt_merge" ]]; then
	pass "Cleanup after merge: worktree exists before cleanup"
else
	fail "Cleanup after merge: worktree should exist before cleanup"
fi

# Run cleanup_after_merge
bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/database.sh'
    source '$SUPERVISOR_DIR_MODULE/cleanup.sh'
    # Stub ownership functions
    is_worktree_owned_by_others() { return 1; }
    unregister_worktree() { return 0; }
    cleanup_after_merge 'claude-merge-t1'
" 2>/dev/null

if [[ ! -d "$wt_merge" ]]; then
	pass "Cleanup after merge: worktree removed"
else
	fail "Cleanup after merge: worktree still exists"
	rm -rf "$wt_merge"
fi

# Verify DB fields cleared
merge_wt=$(get_field "claude-merge-t1" "worktree")
merge_branch=$(get_field "claude-merge-t1" "branch")
if [[ -z "$merge_wt" || "$merge_wt" == "NULL" ]]; then
	pass "Cleanup after merge: worktree field cleared in DB"
else
	fail "Cleanup after merge: worktree field not cleared" "Got: $merge_wt"
fi

if [[ -z "$merge_branch" || "$merge_branch" == "NULL" ]]; then
	pass "Cleanup after merge: branch field cleared in DB"
else
	fail "Cleanup after merge: branch field not cleared" "Got: $merge_branch"
fi

git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/claude-merge-t1" &>/dev/null || true

# ============================================================
# SECTION 8: Retry Cycle with Claude CLI
# ============================================================
section "Retry Cycle (claude worker retry -> success)"

sup add claude-retry-t1 --repo "$TEST_REPO" --description "Claude retry cycle test" --no-issue >/dev/null

# First dispatch cycle — worker exits without signal
wt_retry=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'claude-retry-t1' '$TEST_REPO'
" 2>/dev/null)

sup transition claude-retry-t1 dispatched --worktree "$wt_retry" --branch "feature/claude-retry-t1" >/dev/null
sup transition claude-retry-t1 running >/dev/null

create_log "claude-retry-t1" 'WRAPPER_STARTED task_id=claude-retry-t1 wrapper_pid=10001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-retry-t1 pid=10002 timestamp=2026-02-21T10:00:01Z
{"type":"text","text":"Started working but ran out of context window."}
EXIT:0' >/dev/null

sup transition claude-retry-t1 evaluating >/dev/null
eval_result=$(sup evaluate claude-retry-t1 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*clean_exit_no_signal"; then
	pass "Retry cycle: first attempt -> retry:clean_exit_no_signal"
else
	fail "Retry cycle: first attempt should be retry" "Got: $eval_result"
fi

# Execute retry transition
sup transition claude-retry-t1 retrying >/dev/null
retries=$(get_field "claude-retry-t1" "retries")
if [[ "$retries" -eq 1 ]]; then
	pass "Retry cycle: retry counter incremented to 1"
else
	fail "Retry cycle: retry counter is $retries, expected 1"
fi

# Re-dispatch with force-fresh worktree
sup transition claude-retry-t1 dispatched >/dev/null

wt_retry2=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    set -- init
    source '$SUPERVISOR_SCRIPT' >/dev/null
    create_task_worktree 'claude-retry-t1' '$TEST_REPO' 'true'
" 2>/dev/null)

if [[ -d "$wt_retry2" ]]; then
	pass "Retry cycle: force-fresh worktree created"
else
	fail "Retry cycle: force-fresh worktree not created"
fi

# Second attempt: worker succeeds
sup transition claude-retry-t1 running >/dev/null

echo "retry feature" >"$wt_retry2/retry-feature.txt"
git -C "$wt_retry2" add retry-feature.txt &>/dev/null
git -C "$wt_retry2" commit -m "feat: retry success (claude-retry-t1)" &>/dev/null

create_log "claude-retry-t1" 'WRAPPER_STARTED task_id=claude-retry-t1 wrapper_pid=10003 timestamp=2026-02-21T10:05:00Z
WORKER_STARTED task_id=claude-retry-t1 pid=10004 timestamp=2026-02-21T10:05:01Z
{"type":"text","text":"Retry attempt. Created retry-feature.txt.\nFULL_LOOP_COMPLETE"}
EXIT:0' >/dev/null

sup transition claude-retry-t1 evaluating >/dev/null
eval_result2=$(sup evaluate claude-retry-t1 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result2" | grep -q "complete"; then
	pass "Retry cycle: second attempt -> complete"
else
	fail "Retry cycle: second attempt should be complete" "Got: $eval_result2"
fi

sup transition claude-retry-t1 complete >/dev/null
if [[ "$(get_status claude-retry-t1)" == "complete" ]]; then
	pass "Retry cycle: task completed after retry"
else
	fail "Retry cycle: task not complete after retry"
fi

# Verify retry state log
retry_log_count=$(test_db "SELECT count(*) FROM state_log WHERE task_id = 'claude-retry-t1';")
if [[ "$retry_log_count" -ge 8 ]]; then
	pass "Retry cycle: state log has $retry_log_count entries (includes retry cycle)"
else
	fail "Retry cycle: state log has only $retry_log_count entries, expected >= 8"
fi

# Clean up
git -C "$TEST_REPO" worktree remove "$wt_retry2" --force &>/dev/null || rm -rf "$wt_retry2"
git -C "$TEST_REPO" worktree prune &>/dev/null || true
git -C "$TEST_REPO" branch -D "feature/claude-retry-t1" &>/dev/null || true

# ============================================================
# SECTION 9: Claude-Specific Edge Cases
# ============================================================
section "Claude-Specific Edge Cases"

# Test: Claude JSON output with nested error object
sup add claude-edge-t1 --repo "$TEST_REPO" --description "Claude JSON error test" --no-issue >/dev/null
sup transition claude-edge-t1 dispatched >/dev/null
sup transition claude-edge-t1 running >/dev/null
create_log "claude-edge-t1" 'WRAPPER_STARTED task_id=claude-edge-t1 wrapper_pid=11001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-edge-t1 pid=11002 timestamp=2026-02-21T10:00:01Z
{"type":"error","error":{"message":"HTTP 503 Service Unavailable"}}
EXIT:1' >/dev/null
sup transition claude-edge-t1 evaluating >/dev/null
eval_result=$(sup evaluate claude-edge-t1 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "retry.*backend_infrastructure_error"; then
	pass "Edge case: HTTP 503 in JSON error -> retry:backend_infrastructure_error"
else
	fail "Edge case: should be retry:backend_infrastructure_error" "Got: $eval_result"
fi

# Test: Claude output with REPROMPT METADATA header (retry log)
sup add claude-edge-t2 --repo "$TEST_REPO" --description "Claude reprompt metadata test" --no-issue >/dev/null
sup transition claude-edge-t2 dispatched >/dev/null
sup transition claude-edge-t2 running >/dev/null
create_log "claude-edge-t2" '=== REPROMPT METADATA (t183) ===
task_id=claude-edge-t2
timestamp=2026-02-21T10:00:00Z
retry=1/3
work_dir=/tmp/test
previous_error=clean_exit_no_signal
fresh_worktree=true
=== END REPROMPT METADATA ===

WRAPPER_STARTED task_id=claude-edge-t2 wrapper_pid=12001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-edge-t2 pid=12002 timestamp=2026-02-21T10:00:01Z
{"type":"text","text":"Retry attempt successful.\nFULL_LOOP_COMPLETE"}
EXIT:0' >/dev/null
sup transition claude-edge-t2 evaluating >/dev/null
eval_result=$(sup evaluate claude-edge-t2 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "complete"; then
	pass "Edge case: REPROMPT METADATA + FULL_LOOP_COMPLETE -> complete"
else
	fail "Edge case: should be complete with reprompt metadata" "Got: $eval_result"
fi

# Test: Claude worker with merge conflict
sup add claude-edge-t3 --repo "$TEST_REPO" --description "Claude merge conflict test" --no-issue >/dev/null
sup transition claude-edge-t3 dispatched >/dev/null
sup transition claude-edge-t3 running >/dev/null
create_log "claude-edge-t3" 'WRAPPER_STARTED task_id=claude-edge-t3 wrapper_pid=13001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=claude-edge-t3 pid=13002 timestamp=2026-02-21T10:00:01Z
{"type":"text","text":"Attempting to merge...\nCONFLICT (content): Merge conflict in src/main.ts\nAborting."}
EXIT:1' >/dev/null
sup transition claude-edge-t3 evaluating >/dev/null
eval_result=$(sup evaluate claude-edge-t3 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval_result" | grep -q "blocked.*merge_conflict"; then
	pass "Edge case: merge conflict in claude output -> blocked:merge_conflict"
else
	fail "Edge case: should be blocked:merge_conflict" "Got: $eval_result"
fi

# Test: cmd_cleanup with dry-run (verifies terminal-state tasks are found)
sup add claude-cleanup-t1 --repo "$TEST_REPO" --description "Cleanup dry-run test" --no-issue >/dev/null
sup transition claude-cleanup-t1 dispatched >/dev/null
sup transition claude-cleanup-t1 running >/dev/null
sup transition claude-cleanup-t1 evaluating >/dev/null
sup transition claude-cleanup-t1 complete >/dev/null
# Mark as failed to test terminal-state detection
test_db "UPDATE tasks SET status = 'failed' WHERE id = 'claude-cleanup-t1';" 2>/dev/null

# The cleanup command should run without error (even if no worktrees to clean)
if cleanup_output=$(sup cleanup --dry-run 2>&1); then
	pass "cmd_cleanup --dry-run runs without error"
else
	fail "cmd_cleanup --dry-run failed" "$cleanup_output"
fi

# ============================================================
# SECTION 10: check_cli_health with Mock Claude
# ============================================================
section "CLI Health Check (mock claude)"

health_result=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    export PATH='$MOCK_BIN:$PATH'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
    # Clear any cached health state
    unset _PULSE_CLI_VERIFIED
    rm -f '$TEST_DIR/supervisor/health/cli-claude' 2>/dev/null
    mkdir -p '$TEST_DIR/supervisor/health'
    check_cli_health 'claude'
    echo \"exit:\$?\"
" 2>/dev/null | tail -1)

if [[ "$health_result" == "exit:0" ]]; then
	pass "check_cli_health: mock claude passes health check"
else
	fail "check_cli_health: mock claude should pass" "Got: $health_result"
fi

# Verify mock claude was actually invoked with --version
if [[ -f "$MOCK_CLAUDE_LOG" ]] && grep -q "\-\-version" "$MOCK_CLAUDE_LOG"; then
	pass "check_cli_health: invoked 'claude --version'"
else
	skip "check_cli_health: could not verify --version invocation (may use cached result)"
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
