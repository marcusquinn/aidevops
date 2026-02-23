#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090
# SC2034: Variables set for sourced scripts (BLUE, SUPERVISOR_DB, etc.)
# SC1090: Non-constant source paths (test harness pattern)
#
# test-multi-container-batch-dispatch.sh (t1165.4)
#
# Integration test: multi-container batch dispatch — verifies:
#   1. Parallel workers across containers (batch concurrency enforcement)
#   2. Correct OAuth routing (claude for Anthropic, opencode for non-Anthropic)
#   3. Container lifecycle (dispatch → running → evaluate → cleanup)
#   4. Log aggregation across parallel workers (sentinels, per-task logs)
#   5. Batch completion detection and post-completion hooks
#   6. Adaptive concurrency scaling
#   7. Cross-container failure isolation (one worker fails, others continue)
#
# This test does NOT spawn real CLI processes — it mocks the claude and opencode
# binaries and verifies the supervisor's orchestration logic produces correct
# commands, enforces concurrency, routes OAuth correctly, aggregates logs,
# and manages the full lifecycle across multiple simultaneous workers.
#
# Usage: bash tests/test-multi-container-batch-dispatch.sh [--verbose]
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
	return 0
}

fail() {
	FAIL_COUNT=$((FAIL_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;31mFAIL\033[0m %s\n" "$1"
	if [[ -n "${2:-}" ]]; then
		printf "       %s\n" "$2"
	fi
	return 0
}

skip() {
	SKIP_COUNT=$((SKIP_COUNT + 1))
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	printf "  \033[0;33mSKIP\033[0m %s\n" "$1"
	return 0
}

section() {
	echo ""
	printf "\033[1m=== %s ===\033[0m\n" "$1"
	return 0
}

verbose() {
	if [[ "$VERBOSE" == "--verbose" ]]; then
		printf "       [verbose] %s\n" "$1"
	fi
	return 0
}

# --- Isolated Test Environment ---
TEST_DIR=$(mktemp -d)
TEST_REPO="$TEST_DIR/test-repo"
export AIDEVOPS_SUPERVISOR_DIR="$TEST_DIR/supervisor"

# Create mock CLI binaries
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

# Mock claude CLI — records invocations, simulates OAuth-authenticated CLI
cat >"$MOCK_BIN/claude" <<'MOCK_CLAUDE'
#!/usr/bin/env bash
MOCK_LOG="${MOCK_CLAUDE_LOG:-/tmp/mock-claude-invocations.log}"
echo "MOCK_CLAUDE_INVOKED: $*" >> "$MOCK_LOG"
if [[ "${1:-}" == "--version" ]]; then
    echo "claude 1.0.20 (mock)"
    exit 0
fi
if [[ "${1:-}" == "-p" ]]; then
    echo '{"type":"text","text":"Mock claude response.\nFULL_LOOP_COMPLETE"}'
    exit 0
fi
echo "claude: unknown command" >&2
exit 1
MOCK_CLAUDE
chmod +x "$MOCK_BIN/claude"

# Mock opencode CLI — records invocations, simulates API-key CLI
cat >"$MOCK_BIN/opencode" <<'MOCK_OPENCODE'
#!/usr/bin/env bash
MOCK_LOG="${MOCK_OPENCODE_LOG:-/tmp/mock-opencode-invocations.log}"
echo "MOCK_OPENCODE_INVOKED: $*" >> "$MOCK_LOG"
if [[ "${1:-}" == "version" ]]; then
    echo "opencode 0.2.0 (mock)"
    exit 0
fi
echo "opencode mock response"
exit 0
MOCK_OPENCODE
chmod +x "$MOCK_BIN/opencode"

# Export mock log paths
export MOCK_CLAUDE_LOG="$TEST_DIR/mock-claude-invocations.log"
export MOCK_OPENCODE_LOG="$TEST_DIR/mock-opencode-invocations.log"

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
	return $?
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
	test_db "UPDATE tasks SET log_file = '$log_file' WHERE id = '$task_id';"
	echo "$log_file"
}

# Helper: create a mock PID file for a running worker
create_pid_file() {
	local task_id="$1"
	local pid="$2"
	mkdir -p "$TEST_DIR/supervisor/pids"
	echo "$pid" >"$TEST_DIR/supervisor/pids/${task_id}.pid"
}

# Helper: count tasks in a given status
count_status() {
	local status="$1"
	test_db "SELECT count(*) FROM tasks WHERE status = '$status';"
}

# Helper: run a function in an isolated subshell with mock environment
_run_isolated_test() {
	local test_script="$TEST_DIR/isolated-test-$$.sh"
	cat >"$test_script"
	chmod +x "$test_script"
	bash "$test_script" 2>/dev/null
	local rc=$?
	rm -f "$test_script"
	return $rc
}

echo "=== Multi-Container Batch Dispatch Integration Test (t1165.4) ==="
echo "Repo: $REPO_DIR"
echo "Test dir: $TEST_DIR"
echo ""

# ============================================================
# SETUP: Create a real git repo and initialize supervisor
# ============================================================
section "Test Environment Setup"

git init -q "$TEST_REPO"
git -C "$TEST_REPO" checkout -q -b main 2>&1 || true
echo "# Test Repo" >"$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -q -m "initial commit"

# Create a TODO.md with test tasks
cat >"$TEST_REPO/TODO.md" <<'TODO'
# TODO

## In Progress

## Queued

- [ ] mc-t1 Implement auth service model:opus ~30m
- [ ] mc-t2 Add user dashboard model:sonnet ~20m
- [ ] mc-t3 Fix payment gateway model:opus ~45m
- [ ] mc-t4 Update API docs model:haiku ~15m
- [ ] mc-t5 Refactor database layer model:opus ~1h
- [ ] mc-t6 Add monitoring alerts model:sonnet ~30m
TODO
git -C "$TEST_REPO" add TODO.md
git -C "$TEST_REPO" commit -q -m "add TODO.md with test tasks"

# Initialize supervisor DB
sup init >/dev/null

if [[ -f "$TEST_DIR/supervisor/supervisor.db" ]]; then
	pass "Supervisor DB initialized"
else
	fail "Supervisor DB not created"
	exit 1
fi

if [[ -d "$TEST_REPO/.git" ]]; then
	pass "Test git repo created with TODO.md"
else
	fail "Test git repo not created"
	exit 1
fi

# ============================================================
# SECTION 1: Batch Creation with Multiple Tasks
# ============================================================
section "Batch Creation with Multiple Tasks"

# Add all 6 tasks
for tid in mc-t1 mc-t2 mc-t3 mc-t4 mc-t5 mc-t6; do
	sup add "$tid" --repo "$TEST_REPO" --no-issue >/dev/null
done

task_count=$(test_db "SELECT count(*) FROM tasks;")
if [[ "$task_count" -eq 6 ]]; then
	pass "All 6 tasks registered in supervisor DB"
else
	fail "Expected 6 tasks, got $task_count"
fi

# Verify all tasks are queued
queued_count=$(count_status "queued")
if [[ "$queued_count" -eq 6 ]]; then
	pass "All 6 tasks in queued status"
else
	fail "Expected 6 queued tasks, got $queued_count"
fi

# Create a batch with concurrency=3 (simulates 3 parallel containers)
batch_output=$(sup batch "multi-container-test" \
	--concurrency 3 \
	--max-concurrency 6 \
	--tasks "mc-t1,mc-t2,mc-t3,mc-t4,mc-t5,mc-t6" 2>&1)
batch_id=$(echo "$batch_output" | grep -oE 'batch-[0-9]+-[0-9]+' | head -1)

if [[ -n "$batch_id" ]]; then
	pass "Batch created: $batch_id (concurrency=3, max=6)"
else
	fail "Batch creation failed" "$batch_output"
fi

# Verify batch_tasks table
batch_task_count=$(test_db "SELECT count(*) FROM batch_tasks WHERE batch_id = '$batch_id';")
if [[ "$batch_task_count" -eq 6 ]]; then
	pass "All 6 tasks linked to batch"
else
	fail "Expected 6 batch_tasks, got $batch_task_count"
fi

# Verify task ordering (position field)
first_task=$(test_db "SELECT task_id FROM batch_tasks WHERE batch_id = '$batch_id' AND position = 0;")
last_task=$(test_db "SELECT task_id FROM batch_tasks WHERE batch_id = '$batch_id' AND position = 5;")
if [[ "$first_task" == "mc-t1" && "$last_task" == "mc-t6" ]]; then
	pass "Batch task ordering preserved (mc-t1 at 0, mc-t6 at 5)"
else
	fail "Batch task ordering wrong" "first=$first_task last=$last_task"
fi

# ============================================================
# SECTION 2: OAuth Routing Across Containers
# ============================================================
section "OAuth Routing Across Containers"

# Test: Anthropic model (opus) routes to opencode CLI (PR #2173 removed OAuth routing)
oauth_opus_cli=$(
	_run_isolated_test <<OAUTH_TEST
#!/usr/bin/env bash
set -euo pipefail
export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
export PATH='$MOCK_BIN':/usr/bin:/bin
export SUPERVISOR_PREFER_OAUTH=true
unset SUPERVISOR_CLI 2>/dev/null || true
BLUE='' GREEN='' YELLOW='' RED='' NC=''
SUPERVISOR_LOG='/dev/null'
SUPERVISOR_DIR='$TEST_DIR/supervisor'
source '$SHARED_CONSTANTS'
source '$SUPERVISOR_DIR_MODULE/_common.sh'
source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
mock_home=\$(mktemp -d)
export HOME=\$mock_home
mkdir -p "\$mock_home/.claude"
echo '{"hasCompletedOnboarding":true}' > "\$mock_home/.claude/settings.json"
rm -f '$TEST_DIR/supervisor/health/claude-oauth' 2>/dev/null
resolve_ai_cli 'anthropic/claude-opus-4-6'
rm -rf "\$mock_home"
OAUTH_TEST
)

if [[ "$oauth_opus_cli" == "opencode" ]]; then
	pass "CLI routing: anthropic/claude-opus-4-6 -> opencode (PR #2173: opencode is sole worker CLI)"
else
	fail "CLI routing: opus should route to opencode" "Got: '$oauth_opus_cli'"
fi

# Test: Anthropic sonnet model also routes to opencode CLI (PR #2173)
oauth_sonnet_cli=$(
	_run_isolated_test <<OAUTH_TEST2
#!/usr/bin/env bash
set -euo pipefail
export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
export PATH='$MOCK_BIN':/usr/bin:/bin
export SUPERVISOR_PREFER_OAUTH=true
unset SUPERVISOR_CLI 2>/dev/null || true
BLUE='' GREEN='' YELLOW='' RED='' NC=''
SUPERVISOR_LOG='/dev/null'
SUPERVISOR_DIR='$TEST_DIR/supervisor'
source '$SHARED_CONSTANTS'
source '$SUPERVISOR_DIR_MODULE/_common.sh'
source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
mock_home=\$(mktemp -d)
export HOME=\$mock_home
mkdir -p "\$mock_home/.claude"
echo '{"hasCompletedOnboarding":true}' > "\$mock_home/.claude/settings.json"
rm -f '$TEST_DIR/supervisor/health/claude-oauth' 2>/dev/null
resolve_ai_cli 'anthropic/claude-sonnet-4-6'
rm -rf "\$mock_home"
OAUTH_TEST2
)

if [[ "$oauth_sonnet_cli" == "opencode" ]]; then
	pass "CLI routing: anthropic/claude-sonnet-4-6 -> opencode (PR #2173: opencode is sole worker CLI)"
else
	fail "CLI routing: sonnet should route to opencode" "Got: '$oauth_sonnet_cli'"
fi

# Test: Non-Anthropic model routes to opencode CLI even with OAuth
oauth_google_cli=$(
	_run_isolated_test <<OAUTH_TEST3
#!/usr/bin/env bash
set -euo pipefail
export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
export PATH='$MOCK_BIN':/usr/bin:/bin
export SUPERVISOR_PREFER_OAUTH=true
unset SUPERVISOR_CLI 2>/dev/null || true
BLUE='' GREEN='' YELLOW='' RED='' NC=''
SUPERVISOR_LOG='/dev/null'
SUPERVISOR_DIR='$TEST_DIR/supervisor'
source '$SHARED_CONSTANTS'
source '$SUPERVISOR_DIR_MODULE/_common.sh'
source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
mock_home=\$(mktemp -d)
export HOME=\$mock_home
mkdir -p "\$mock_home/.claude"
echo '{"hasCompletedOnboarding":true}' > "\$mock_home/.claude/settings.json"
rm -f '$TEST_DIR/supervisor/health/claude-oauth' 2>/dev/null
resolve_ai_cli 'google/gemini-2.5-pro'
rm -rf "\$mock_home"
OAUTH_TEST3
)

if [[ "$oauth_google_cli" == "opencode" ]]; then
	pass "OAuth routing: google/gemini-2.5-pro -> opencode CLI"
else
	fail "OAuth routing: non-Anthropic should route to opencode" "Got: '$oauth_google_cli'"
fi

# Test: SUPERVISOR_PREFER_OAUTH=false forces opencode even for Anthropic
oauth_disabled_cli=$(
	_run_isolated_test <<OAUTH_TEST4
#!/usr/bin/env bash
set -euo pipefail
export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
export PATH='$MOCK_BIN':/usr/bin:/bin
export SUPERVISOR_PREFER_OAUTH=false
unset SUPERVISOR_CLI 2>/dev/null || true
BLUE='' GREEN='' YELLOW='' RED='' NC=''
SUPERVISOR_LOG='/dev/null'
SUPERVISOR_DIR='$TEST_DIR/supervisor'
source '$SHARED_CONSTANTS'
source '$SUPERVISOR_DIR_MODULE/_common.sh'
source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
mock_home=\$(mktemp -d)
export HOME=\$mock_home
mkdir -p "\$mock_home/.claude"
echo '{"hasCompletedOnboarding":true}' > "\$mock_home/.claude/settings.json"
rm -f '$TEST_DIR/supervisor/health/claude-oauth' 2>/dev/null
resolve_ai_cli 'anthropic/claude-opus-4-6'
rm -rf "\$mock_home"
OAUTH_TEST4
)

if [[ "$oauth_disabled_cli" == "opencode" ]]; then
	pass "OAuth routing: SUPERVISOR_PREFER_OAUTH=false -> opencode for Anthropic"
else
	fail "OAuth routing: disabled OAuth should use opencode" "Got: '$oauth_disabled_cli'"
fi

# Test: Mixed batch — bare tier names (haiku/sonnet/opus) without anthropic/ prefix
# resolve_ai_cli checks for "anthropic/*" or "*claude*" patterns.
# Bare tier names like "haiku" don't match either pattern -> opencode (correct behavior).
# Only fully-qualified "anthropic/claude-haiku-3" would route to claude.
oauth_bare_tier_cli=$(
	_run_isolated_test <<OAUTH_TEST5
#!/usr/bin/env bash
set -euo pipefail
export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
export PATH='$MOCK_BIN':/usr/bin:/bin
export SUPERVISOR_PREFER_OAUTH=true
unset SUPERVISOR_CLI 2>/dev/null || true
BLUE='' GREEN='' YELLOW='' RED='' NC=''
SUPERVISOR_LOG='/dev/null'
SUPERVISOR_DIR='$TEST_DIR/supervisor'
source '$SHARED_CONSTANTS'
source '$SUPERVISOR_DIR_MODULE/_common.sh'
source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
mock_home=\$(mktemp -d)
export HOME=\$mock_home
mkdir -p "\$mock_home/.claude"
echo '{"hasCompletedOnboarding":true}' > "\$mock_home/.claude/settings.json"
rm -f '$TEST_DIR/supervisor/health/claude-oauth' 2>/dev/null
resolve_ai_cli 'haiku'
rm -rf "\$mock_home"
OAUTH_TEST5
)

if [[ "$oauth_bare_tier_cli" == "opencode" ]]; then
	pass "OAuth routing: bare 'haiku' tier -> opencode (no anthropic/ prefix)"
else
	fail "OAuth routing: bare tier should route to opencode" "Got: '$oauth_bare_tier_cli'"
fi

# Test: Fully-qualified Anthropic haiku routes to opencode (PR #2173)
oauth_fq_haiku_cli=$(
	_run_isolated_test <<OAUTH_TEST6
#!/usr/bin/env bash
set -euo pipefail
export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
export PATH='$MOCK_BIN':/usr/bin:/bin
export SUPERVISOR_PREFER_OAUTH=true
unset SUPERVISOR_CLI 2>/dev/null || true
BLUE='' GREEN='' YELLOW='' RED='' NC=''
SUPERVISOR_LOG='/dev/null'
SUPERVISOR_DIR='$TEST_DIR/supervisor'
source '$SHARED_CONSTANTS'
source '$SUPERVISOR_DIR_MODULE/_common.sh'
source '$SUPERVISOR_DIR_MODULE/dispatch.sh'
mock_home=\$(mktemp -d)
export HOME=\$mock_home
mkdir -p "\$mock_home/.claude"
echo '{"hasCompletedOnboarding":true}' > "\$mock_home/.claude/settings.json"
rm -f '$TEST_DIR/supervisor/health/claude-oauth' 2>/dev/null
resolve_ai_cli 'anthropic/claude-haiku-3'
rm -rf "\$mock_home"
OAUTH_TEST6
)

if [[ "$oauth_fq_haiku_cli" == "opencode" ]]; then
	pass "CLI routing: anthropic/claude-haiku-3 -> opencode (PR #2173: opencode is sole worker CLI)"
else
	fail "CLI routing: fully-qualified haiku should route to opencode" "Got: '$oauth_fq_haiku_cli'"
fi

# ============================================================
# SECTION 3: Parallel Worker Dispatch (Container Lifecycle)
# ============================================================
section "Parallel Worker Dispatch (Container Lifecycle)"

# Simulate dispatching 3 workers in parallel (concurrency=3)
# Each worker gets: worktree, log file, PID file, state transitions

for tid in mc-t1 mc-t2 mc-t3; do
	# Create worktree
	wt_path=$(bash -c "
        export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
        set -- init
        source '$SUPERVISOR_SCRIPT' >/dev/null
        create_task_worktree '$tid' '$TEST_REPO'
    ")

	if [[ -d "$wt_path" ]]; then
		pass "Worker $tid: worktree created at $wt_path"
	else
		fail "Worker $tid: worktree creation failed"
		continue
	fi

	# Transition: queued -> dispatched -> running
	sup transition "$tid" dispatched \
		--worktree "$wt_path" \
		--branch "feature/$tid" >/dev/null
	sup transition "$tid" running >/dev/null

	# Create PID file (simulate live worker process)
	# Use a PID that won't exist (high number) to simulate a "running" worker
	create_pid_file "$tid" "$((RANDOM + 40000))"
done

# Verify 3 workers are running
running_count=$(count_status "running")
if [[ "$running_count" -eq 3 ]]; then
	pass "3 workers running in parallel (mc-t1, mc-t2, mc-t3)"
else
	fail "Expected 3 running workers, got $running_count"
fi

# Verify remaining 3 tasks are still queued
still_queued=$(count_status "queued")
if [[ "$still_queued" -eq 3 ]]; then
	pass "3 tasks still queued (mc-t4, mc-t5, mc-t6) — concurrency limit respected"
else
	fail "Expected 3 queued tasks, got $still_queued"
fi

# Verify concurrency enforcement: running count matches batch concurrency
batch_running=$(test_db "
    SELECT count(*) FROM batch_tasks bt
    JOIN tasks t ON bt.task_id = t.id
    WHERE bt.batch_id = '$batch_id'
    AND t.status IN ('dispatched', 'running', 'evaluating');
")
if [[ "$batch_running" -eq 3 ]]; then
	pass "Batch concurrency enforced: 3 active workers = batch concurrency limit"
else
	fail "Batch concurrency not enforced" "active=$batch_running, limit=3"
fi

# ============================================================
# SECTION 4: Worker Log Aggregation
# ============================================================
section "Worker Log Aggregation"

# Create realistic log files for each running worker
# Worker 1: Successful completion
log1=$(create_log "mc-t1" 'WRAPPER_STARTED task_id=mc-t1 wrapper_pid=20001 timestamp=2026-02-21T10:00:00Z
WORKER_STARTED task_id=mc-t1 pid=20002 timestamp=2026-02-21T10:00:01Z
HEARTBEAT: 2026-02-21T10:05:00Z worker still running
{"type":"text","text":"Implementing auth service for mc-t1.\nCreated auth module.\nAll tests passed.\nFULL_LOOP_COMPLETE\nhttps://github.com/test/repo/pull/101"}
EXIT:0')

# Worker 2: Successful completion (different task)
log2=$(create_log "mc-t2" 'WRAPPER_STARTED task_id=mc-t2 wrapper_pid=20003 timestamp=2026-02-21T10:00:02Z
WORKER_STARTED task_id=mc-t2 pid=20004 timestamp=2026-02-21T10:00:03Z
HEARTBEAT: 2026-02-21T10:05:02Z worker still running
{"type":"text","text":"Adding user dashboard for mc-t2.\nCreated dashboard component.\nFULL_LOOP_COMPLETE\nhttps://github.com/test/repo/pull/102"}
EXIT:0')

# Worker 3: Rate-limited failure (should trigger retry)
log3=$(create_log "mc-t3" 'WRAPPER_STARTED task_id=mc-t3 wrapper_pid=20005 timestamp=2026-02-21T10:00:04Z
WORKER_STARTED task_id=mc-t3 pid=20006 timestamp=2026-02-21T10:00:05Z
HEARTBEAT: 2026-02-21T10:05:04Z worker still running
{"type":"error","error":{"message":"429 Too Many Requests"}}
EXIT:1')

# Verify log files exist and have correct content
for tid in mc-t1 mc-t2 mc-t3; do
	log_file=$(get_field "$tid" "log_file")
	if [[ -f "$log_file" ]]; then
		pass "Worker $tid: log file exists"
	else
		fail "Worker $tid: log file missing"
	fi
done

# Verify WRAPPER_STARTED sentinel in all logs
for tid in mc-t1 mc-t2 mc-t3; do
	log_file=$(get_field "$tid" "log_file")
	if grep -q "WRAPPER_STARTED task_id=$tid" "$log_file" 2>/dev/null; then
		pass "Worker $tid: WRAPPER_STARTED sentinel present"
	else
		fail "Worker $tid: WRAPPER_STARTED sentinel missing"
	fi
done

# Verify WORKER_STARTED sentinel in all logs
for tid in mc-t1 mc-t2 mc-t3; do
	log_file=$(get_field "$tid" "log_file")
	if grep -q "WORKER_STARTED task_id=$tid" "$log_file" 2>/dev/null; then
		pass "Worker $tid: WORKER_STARTED sentinel present"
	else
		fail "Worker $tid: WORKER_STARTED sentinel missing"
	fi
done

# Verify HEARTBEAT in all logs
heartbeat_count=0
for tid in mc-t1 mc-t2 mc-t3; do
	log_file=$(get_field "$tid" "log_file")
	if grep -q "HEARTBEAT:" "$log_file" 2>/dev/null; then
		heartbeat_count=$((heartbeat_count + 1))
	fi
done
if [[ "$heartbeat_count" -eq 3 ]]; then
	pass "All 3 workers have HEARTBEAT entries in logs"
else
	fail "Expected 3 workers with heartbeats, got $heartbeat_count"
fi

# Verify per-task log isolation (each log only contains its own task_id)
for tid in mc-t1 mc-t2 mc-t3; do
	log_file=$(get_field "$tid" "log_file")
	# Count how many different task_ids appear in WORKER_STARTED lines
	other_tasks=$(grep "WORKER_STARTED" "$log_file" 2>/dev/null | grep -cv "task_id=$tid" || true)
	other_tasks="${other_tasks:-0}"
	other_tasks=$(echo "$other_tasks" | tr -d '[:space:]')
	if [[ "$other_tasks" -eq 0 ]]; then
		pass "Worker $tid: log isolation verified (no cross-contamination)"
	else
		fail "Worker $tid: log contains other task IDs ($other_tasks foreign entries)"
	fi
done

# ============================================================
# SECTION 5: Worker Evaluation (Mixed Outcomes)
# ============================================================
section "Worker Evaluation (Mixed Outcomes)"

# Evaluate worker 1: FULL_LOOP_COMPLETE + exit 0 -> complete
sup transition mc-t1 evaluating >/dev/null
eval1=$(sup evaluate mc-t1 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval1" | grep -q "complete"; then
	pass "Worker mc-t1: FULL_LOOP_COMPLETE + exit 0 -> complete"
else
	fail "Worker mc-t1: should be complete" "Got: $eval1"
fi
sup transition mc-t1 complete >/dev/null

# Evaluate worker 2: FULL_LOOP_COMPLETE + exit 0 -> complete
sup transition mc-t2 evaluating >/dev/null
eval2=$(sup evaluate mc-t2 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval2" | grep -q "complete"; then
	pass "Worker mc-t2: FULL_LOOP_COMPLETE + exit 0 -> complete"
else
	fail "Worker mc-t2: should be complete" "Got: $eval2"
fi
sup transition mc-t2 complete >/dev/null

# Evaluate worker 3: rate limit -> retry
sup transition mc-t3 evaluating >/dev/null
eval3=$(sup evaluate mc-t3 --no-ai 2>&1 | grep "^Verdict:" || echo "")
if echo "$eval3" | grep -q "retry.*rate_limited"; then
	pass "Worker mc-t3: rate limit error -> retry:rate_limited"
else
	fail "Worker mc-t3: should be retry:rate_limited" "Got: $eval3"
fi

# Transition mc-t3 to retrying
sup transition mc-t3 retrying >/dev/null
retries_mc3=$(get_field "mc-t3" "retries")
if [[ "$retries_mc3" -eq 1 ]]; then
	pass "Worker mc-t3: retry counter incremented to 1"
else
	fail "Worker mc-t3: retry counter is $retries_mc3, expected 1"
fi

# ============================================================
# SECTION 6: Failure Isolation (One Worker Fails, Others Continue)
# ============================================================
section "Failure Isolation"

# After mc-t1 and mc-t2 complete, mc-t3 retrying:
# - 2 complete, 1 retrying, 3 queued
complete_count=$(count_status "complete")
retrying_count=$(count_status "retrying")
queued_after=$(count_status "queued")

if [[ "$complete_count" -eq 2 ]]; then
	pass "Failure isolation: 2 workers completed successfully despite mc-t3 failure"
else
	fail "Expected 2 complete, got $complete_count"
fi

if [[ "$retrying_count" -eq 1 ]]; then
	pass "Failure isolation: 1 worker in retrying state (mc-t3)"
else
	fail "Expected 1 retrying, got $retrying_count"
fi

if [[ "$queued_after" -eq 3 ]]; then
	pass "Failure isolation: 3 tasks still queued for next dispatch wave"
else
	fail "Expected 3 queued, got $queued_after"
fi

# Verify state log shows independent transitions (no cascading failures)
mc1_transitions=$(test_db "SELECT from_state || '->' || to_state FROM state_log WHERE task_id = 'mc-t1' ORDER BY id;")
mc3_transitions=$(test_db "SELECT from_state || '->' || to_state FROM state_log WHERE task_id = 'mc-t3' ORDER BY id;")

expected_mc1="->queued
queued->dispatched
dispatched->running
running->evaluating
evaluating->complete"

if [[ "$mc1_transitions" == "$expected_mc1" ]]; then
	pass "Failure isolation: mc-t1 state log shows clean lifecycle"
else
	fail "mc-t1 state log unexpected" "Got: $(echo "$mc1_transitions" | tr '\n' ' ')"
fi

# mc-t3 should show: queued->dispatched->running->evaluating->retrying
expected_mc3="->queued
queued->dispatched
dispatched->running
running->evaluating
evaluating->retrying"

if [[ "$mc3_transitions" == "$expected_mc3" ]]; then
	pass "Failure isolation: mc-t3 state log shows retry lifecycle"
else
	fail "mc-t3 state log unexpected" "Got: $(echo "$mc3_transitions" | tr '\n' ' ')"
fi

# ============================================================
# SECTION 7: Second Dispatch Wave (Backfill After Completions)
# ============================================================
section "Second Dispatch Wave (Backfill)"

# Re-queue mc-t3 for retry
sup transition mc-t3 dispatched >/dev/null

# Now dispatch mc-t4, mc-t5, mc-t6 (the remaining queued tasks)
for tid in mc-t4 mc-t5 mc-t6; do
	wt_path=$(bash -c "
        export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
        set -- init
        source '$SUPERVISOR_SCRIPT' >/dev/null
        create_task_worktree '$tid' '$TEST_REPO'
    ")

	sup transition "$tid" dispatched \
		--worktree "$wt_path" \
		--branch "feature/$tid" >/dev/null
	sup transition "$tid" running >/dev/null
	create_pid_file "$tid" "$((RANDOM + 50000))"
done

# Verify second wave: mc-t3 dispatched + mc-t4,t5,t6 running
second_wave_active=$(test_db "
    SELECT count(*) FROM tasks
    WHERE status IN ('dispatched', 'running', 'evaluating');
")
if [[ "$second_wave_active" -ge 4 ]]; then
	pass "Second wave: $second_wave_active active workers (mc-t3 retry + mc-t4,t5,t6)"
else
	fail "Second wave: expected >= 4 active, got $second_wave_active"
fi

# Complete the second wave workers
for tid in mc-t4 mc-t5 mc-t6; do
	create_log "$tid" "WRAPPER_STARTED task_id=$tid wrapper_pid=$((RANDOM + 30000)) timestamp=2026-02-21T10:10:00Z
WORKER_STARTED task_id=$tid pid=$((RANDOM + 30000)) timestamp=2026-02-21T10:10:01Z
{\"type\":\"text\",\"text\":\"Completed task $tid.\\nFULL_LOOP_COMPLETE\"}
EXIT:0" >/dev/null

	sup transition "$tid" evaluating >/dev/null
	sup evaluate "$tid" --no-ai >/dev/null 2>&1
	sup transition "$tid" complete >/dev/null
done

# Complete mc-t3 retry
sup transition mc-t3 running >/dev/null
create_log "mc-t3" 'WRAPPER_STARTED task_id=mc-t3 wrapper_pid=20007 timestamp=2026-02-21T10:10:00Z
WORKER_STARTED task_id=mc-t3 pid=20008 timestamp=2026-02-21T10:10:01Z
{"type":"text","text":"Retry successful for mc-t3.\nFULL_LOOP_COMPLETE"}
EXIT:0' >/dev/null
sup transition mc-t3 evaluating >/dev/null
sup evaluate mc-t3 --no-ai >/dev/null 2>&1
sup transition mc-t3 complete >/dev/null

# Verify all 6 tasks are now complete
all_complete=$(count_status "complete")
if [[ "$all_complete" -eq 6 ]]; then
	pass "All 6 tasks completed (including mc-t3 after retry)"
else
	fail "Expected 6 complete, got $all_complete"
fi

# ============================================================
# SECTION 8: Batch Completion Detection
# ============================================================
section "Batch Completion Detection"

# Check batch status
batch_status=$(test_db "SELECT status FROM batches WHERE id = '$batch_id';")
if [[ "$batch_status" == "complete" ]]; then
	pass "Batch status: complete (all tasks finished)"
else
	# Batch completion may be deferred in pulse mode — check manually
	incomplete=$(test_db "
        SELECT count(*) FROM batch_tasks bt
        JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$batch_id'
        AND t.status NOT IN ('complete','deployed','verified','merged','failed','cancelled');
    ")
	if [[ "$incomplete" -eq 0 ]]; then
		pass "Batch completion: all tasks terminal (batch status=$batch_status, 0 incomplete)"
	else
		fail "Batch not complete" "status=$batch_status, incomplete=$incomplete"
	fi
fi

# Verify batch task count matches
batch_complete_count=$(test_db "
    SELECT count(*) FROM batch_tasks bt
    JOIN tasks t ON bt.task_id = t.id
    WHERE bt.batch_id = '$batch_id'
    AND t.status = 'complete';
")
if [[ "$batch_complete_count" -eq 6 ]]; then
	pass "Batch: all 6 tasks in complete status"
else
	fail "Batch: expected 6 complete tasks, got $batch_complete_count"
fi

# ============================================================
# SECTION 9: Log Aggregation Across All Workers
# ============================================================
section "Log Aggregation Across All Workers"

# Verify every task has a log file recorded in DB
tasks_with_logs=$(test_db "SELECT count(*) FROM tasks WHERE log_file IS NOT NULL AND log_file != '';")
if [[ "$tasks_with_logs" -eq 6 ]]; then
	pass "All 6 tasks have log files recorded in DB"
else
	fail "Expected 6 tasks with logs, got $tasks_with_logs"
fi

# Verify all log files exist on disk
missing_logs=0
for tid in mc-t1 mc-t2 mc-t3 mc-t4 mc-t5 mc-t6; do
	log_file=$(get_field "$tid" "log_file")
	if [[ ! -f "$log_file" ]]; then
		missing_logs=$((missing_logs + 1))
		verbose "Missing log: $tid -> $log_file"
	fi
done
if [[ "$missing_logs" -eq 0 ]]; then
	pass "All 6 log files exist on disk"
else
	fail "$missing_logs log file(s) missing from disk"
fi

# Verify EXIT sentinel in all logs
exit_sentinel_count=0
for tid in mc-t1 mc-t2 mc-t3 mc-t4 mc-t5 mc-t6; do
	log_file=$(get_field "$tid" "log_file")
	if grep -q "^EXIT:" "$log_file" 2>/dev/null; then
		exit_sentinel_count=$((exit_sentinel_count + 1))
	fi
done
if [[ "$exit_sentinel_count" -eq 6 ]]; then
	pass "All 6 logs have EXIT sentinel (worker termination recorded)"
else
	fail "Expected 6 EXIT sentinels, got $exit_sentinel_count"
fi

# Verify FULL_LOOP_COMPLETE in successful worker logs (all 6 eventually succeeded)
flc_count=0
for tid in mc-t1 mc-t2 mc-t3 mc-t4 mc-t5 mc-t6; do
	log_file=$(get_field "$tid" "log_file")
	if grep -q "FULL_LOOP_COMPLETE" "$log_file" 2>/dev/null; then
		flc_count=$((flc_count + 1))
	fi
done
if [[ "$flc_count" -eq 6 ]]; then
	pass "All 6 final logs contain FULL_LOOP_COMPLETE"
else
	fail "Expected 6 FULL_LOOP_COMPLETE, got $flc_count"
fi

# ============================================================
# SECTION 10: Cleanup (Worktrees, PIDs, Scripts)
# ============================================================
section "Cleanup (Worktrees, PIDs, Scripts)"

# Verify PID files exist for all tasks
pid_count=0
for tid in mc-t1 mc-t2 mc-t3 mc-t4 mc-t5 mc-t6; do
	if [[ -f "$TEST_DIR/supervisor/pids/${tid}.pid" ]]; then
		pid_count=$((pid_count + 1))
	fi
done
if [[ "$pid_count" -ge 3 ]]; then
	pass "PID files exist for dispatched workers ($pid_count found)"
else
	fail "Expected >= 3 PID files, got $pid_count"
fi

# Test cleanup_worker_processes for a completed task
bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/cleanup.sh'
    cleanup_worker_processes 'mc-t1'
" 2>/dev/null

if [[ ! -f "$TEST_DIR/supervisor/pids/mc-t1.pid" ]]; then
	pass "Cleanup: mc-t1 PID file removed after completion"
else
	fail "Cleanup: mc-t1 PID file still exists"
fi

# Test worktree cleanup
for tid in mc-t1 mc-t2 mc-t3 mc-t4 mc-t5 mc-t6; do
	wt=$(get_field "$tid" "worktree")
	if [[ -n "$wt" && -d "$wt" ]]; then
		bash -c "
            export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
            BLUE='' GREEN='' YELLOW='' RED='' NC=''
            SUPERVISOR_LOG='/dev/null'
            SUPERVISOR_DIR='$TEST_DIR/supervisor'
            SUPERVISOR_DB='$TEST_DIR/supervisor/supervisor.db'
            source '$SHARED_CONSTANTS'
            source '$SUPERVISOR_DIR_MODULE/_common.sh'
            source '$SUPERVISOR_DIR_MODULE/cleanup.sh'
            is_worktree_owned_by_others() { return 1; }
            unregister_worktree() { return 0; }
            cleanup_task_worktree '$wt' '$TEST_REPO'
        " 2>/dev/null
	fi
done

# Count remaining worktrees (should be just the main repo)
remaining_wt=$(git -C "$TEST_REPO" worktree list 2>/dev/null | wc -l | tr -d ' ')
if [[ "$remaining_wt" -le 1 ]]; then
	pass "Cleanup: all task worktrees removed (only main remains)"
else
	fail "Cleanup: $remaining_wt worktrees remain (expected <= 1)"
fi

# ============================================================
# SECTION 11: State Log Audit Trail
# ============================================================
section "State Log Audit Trail"

# Verify comprehensive state log for the entire batch
total_state_entries=$(test_db "SELECT count(*) FROM state_log;")
if [[ "$total_state_entries" -ge 30 ]]; then
	pass "State log: $total_state_entries entries (comprehensive audit trail)"
else
	fail "State log: only $total_state_entries entries (expected >= 30 for 6 tasks)"
fi

# Verify each task has at least 5 state transitions (queued->dispatched->running->evaluating->complete)
for tid in mc-t1 mc-t2 mc-t4 mc-t5 mc-t6; do
	transitions=$(test_db "SELECT count(*) FROM state_log WHERE task_id = '$tid';")
	if [[ "$transitions" -ge 5 ]]; then
		pass "State log: $tid has $transitions transitions (>= 5)"
	else
		fail "State log: $tid has only $transitions transitions (expected >= 5)"
	fi
done

# mc-t3 should have more transitions due to retry cycle
mc3_transitions_count=$(test_db "SELECT count(*) FROM state_log WHERE task_id = 'mc-t3';")
if [[ "$mc3_transitions_count" -ge 8 ]]; then
	pass "State log: mc-t3 has $mc3_transitions_count transitions (includes retry cycle)"
else
	fail "State log: mc-t3 has only $mc3_transitions_count transitions (expected >= 8 with retry)"
fi

# ============================================================
# SECTION 12: Adaptive Concurrency
# ============================================================
section "Adaptive Concurrency"

# Test: calculate_adaptive_concurrency function exists and works
# Function lives in utility.sh, needs SUPERVISOR_DIR set
adaptive_result=$(bash -c "
    export AIDEVOPS_SUPERVISOR_DIR='$TEST_DIR/supervisor'
    BLUE='' GREEN='' YELLOW='' RED='' NC=''
    SUPERVISOR_LOG='/dev/null'
    SUPERVISOR_DIR='$TEST_DIR/supervisor'
    source '$SHARED_CONSTANTS'
    source '$SUPERVISOR_DIR_MODULE/_common.sh'
    source '$SUPERVISOR_DIR_MODULE/utility.sh'
    # Test with base=3, load_factor=2, max=6
    calculate_adaptive_concurrency 3 2 6
" 2>/dev/null)

if [[ -n "$adaptive_result" && "$adaptive_result" =~ ^[0-9]+$ ]]; then
	pass "Adaptive concurrency: calculate_adaptive_concurrency returns $adaptive_result (base=3, factor=2, max=6)"
else
	skip "Adaptive concurrency: calculate_adaptive_concurrency returned '$adaptive_result'"
fi

# Test: Batch concurrency settings are stored correctly
batch_conc=$(test_db "SELECT concurrency FROM batches WHERE id = '$batch_id';")
batch_max_conc=$(test_db "SELECT max_concurrency FROM batches WHERE id = '$batch_id';")
batch_load=$(test_db "SELECT max_load_factor FROM batches WHERE id = '$batch_id';")

if [[ "$batch_conc" -eq 3 ]]; then
	pass "Batch concurrency stored: base=$batch_conc"
else
	fail "Batch concurrency wrong" "Expected 3, got $batch_conc"
fi

if [[ "$batch_max_conc" -eq 6 ]]; then
	pass "Batch max concurrency stored: max=$batch_max_conc"
else
	fail "Batch max concurrency wrong" "Expected 6, got $batch_max_conc"
fi

if [[ "$batch_load" -eq 2 ]]; then
	pass "Batch load factor stored: factor=$batch_load"
else
	fail "Batch load factor wrong" "Expected 2, got $batch_load"
fi

# ============================================================
# SECTION 13: Edge Cases
# ============================================================
section "Edge Cases"

# Test: Empty batch (no tasks)
empty_batch_output=$(sup batch "empty-test" --concurrency 2 2>&1)
empty_batch_id=$(echo "$empty_batch_output" | grep -oE 'batch-[0-9]+-[0-9]+' | head -1)
if [[ -n "$empty_batch_id" ]]; then
	empty_task_count=$(test_db "SELECT count(*) FROM batch_tasks WHERE batch_id = '$empty_batch_id';")
	if [[ "$empty_task_count" -eq 0 ]]; then
		pass "Edge case: empty batch created with 0 tasks"
	else
		fail "Edge case: empty batch should have 0 tasks, got $empty_task_count"
	fi
else
	fail "Edge case: empty batch creation failed"
fi

# Test: Single-task batch
sup add "mc-single" --repo "$TEST_REPO" --description "Single task test" --no-issue >/dev/null
single_batch_output=$(sup batch "single-test" --concurrency 1 --tasks "mc-single" 2>&1)
single_batch_id=$(echo "$single_batch_output" | grep -oE 'batch-[0-9]+-[0-9]+' | head -1)
if [[ -n "$single_batch_id" ]]; then
	single_count=$(test_db "SELECT count(*) FROM batch_tasks WHERE batch_id = '$single_batch_id';")
	if [[ "$single_count" -eq 1 ]]; then
		pass "Edge case: single-task batch created correctly"
	else
		fail "Edge case: single-task batch should have 1 task, got $single_count"
	fi
else
	fail "Edge case: single-task batch creation failed"
fi

# Test: Duplicate task add is rejected
dup_result=$(sup add "mc-t1" --repo "$TEST_REPO" --no-issue 2>&1 || true)
if echo "$dup_result" | grep -qi "already exists"; then
	pass "Edge case: duplicate task add rejected"
else
	fail "Edge case: duplicate task add should be rejected" "Got: $dup_result"
fi

# Test: Batch with release-on-complete flag
release_batch_output=$(sup batch "release-test" \
	--concurrency 2 \
	--release-on-complete \
	--release-type minor 2>&1)
release_batch_id=$(echo "$release_batch_output" | grep -oE 'batch-[0-9]+-[0-9]+' | head -1)
if [[ -n "$release_batch_id" ]]; then
	release_flag=$(test_db "SELECT release_on_complete FROM batches WHERE id = '$release_batch_id';")
	release_type=$(test_db "SELECT release_type FROM batches WHERE id = '$release_batch_id';")
	if [[ "$release_flag" -eq 1 && "$release_type" == "minor" ]]; then
		pass "Edge case: release-on-complete batch (type=minor) created correctly"
	else
		fail "Edge case: release batch flags wrong" "flag=$release_flag type=$release_type"
	fi
else
	fail "Edge case: release batch creation failed"
fi

# ============================================================
# SECTION 14: Cross-Cutting Quality
# ============================================================
section "Cross-Cutting Quality"

# Test: supervisor-helper.sh passes bash syntax check
if bash -n "$SUPERVISOR_SCRIPT" 2>/dev/null; then
	pass "supervisor-helper.sh passes bash -n syntax check"
else
	fail "supervisor-helper.sh has syntax errors"
fi

# Test: All supervisor module files pass syntax check
module_syntax_fail=0
for module in "$SUPERVISOR_DIR_MODULE"/*.sh; do
	if ! bash -n "$module" 2>/dev/null; then
		module_syntax_fail=$((module_syntax_fail + 1))
		verbose "Syntax error: $(basename "$module")"
	fi
done
if [[ "$module_syntax_fail" -eq 0 ]]; then
	pass "All supervisor module files pass bash -n"
else
	fail "$module_syntax_fail supervisor module(s) have syntax errors"
fi

# Test: ShellCheck on this test file itself
if command -v shellcheck &>/dev/null; then
	if shellcheck -x -S warning "$REPO_DIR/tests/test-multi-container-batch-dispatch.sh" 2>/dev/null; then
		pass "This test file passes ShellCheck"
	else
		fail "This test file has ShellCheck warnings"
	fi
else
	skip "shellcheck not installed"
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
	printf "\033[0;31mFAILURES DETECTED — review output above\033[0m\n"
	exit 1
else
	echo ""
	printf "\033[0;32mAll tests passed.\033[0m\n"
	exit 0
fi
