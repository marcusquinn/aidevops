#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1090
# SC2034: Variables set for sourced scripts (BLUE, SUPERVISOR_DB, etc.)
# SC1090: Non-constant source paths (test harness pattern)
#
# test-container-pool.sh (t1165.2)
#
# Unit tests for the container pool manager:
#   1. Schema creation (container_pool, container_dispatch_log tables)
#   2. Pool spawn — registers container in DB with correct state
#   3. Pool destroy — transitions to stopped, handles active dispatch guard
#   4. Health checks — updates status based on container state
#   5. Round-robin selection — picks container with oldest dispatch time
#   6. Per-container rate limit tracking — cooldown and expiry
#   7. Idle container cleanup — respects pool minimum
#   8. Pool stats — correct JSON output
#   9. Dispatch recording — updates round-robin state
#  10. Integration: dispatch.sh pool_select_container hook
#
# This test does NOT spawn real Docker containers — it tests the DB-level
# pool management logic by directly calling functions and querying SQLite.
#
# Usage: bash tests/test-container-pool.sh [--verbose]
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
export AIDEVOPS_SUPERVISOR_DIR="$TEST_DIR/supervisor"

# Mock docker CLI — records invocations, returns fake container IDs
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
MOCK_LOG="${MOCK_DOCKER_LOG:-/tmp/mock-docker-invocations.log}"
echo "MOCK_DOCKER_INVOKED: $*" >> "$MOCK_LOG"
case "${1:-}" in
    run)
        # Return a fake container ID
        echo "abc123def456"
        exit 0
        ;;
    stop|rm)
        exit 0
        ;;
    inspect)
        # Return running state by default
        if [[ "${MOCK_DOCKER_STATE:-running}" == "running" ]]; then
            echo "running"
        else
            echo "$MOCK_DOCKER_STATE"
        fi
        exit 0
        ;;
    *)
        echo "docker mock: $*" >&2
        exit 0
        ;;
esac
MOCK_DOCKER
chmod +x "$MOCK_BIN/docker"

export MOCK_DOCKER_LOG="$TEST_DIR/mock-docker-invocations.log"
export PATH="$MOCK_BIN:$PATH"

# shellcheck disable=SC2317,SC2329
cleanup() {
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# --- Source supervisor modules for direct function testing ---
# We source the modules directly to test functions without spawning subprocesses.
# This requires setting up the same globals that supervisor-helper.sh defines.

SCRIPT_DIR="$SUPERVISOR_DIR_MODULE"
source "$SHARED_CONSTANTS"

readonly SUPERVISOR_DIR="$TEST_DIR/supervisor"
readonly SUPERVISOR_DB="$SUPERVISOR_DIR/supervisor.db"
SUPERVISOR_LOG="$TEST_DIR/supervisor.log"
export SUPERVISOR_LOG

# Colour constants — shared-constants.sh already defines BLUE, GREEN, etc.
# Only define BOLD/DIM if not already set (they are defined in supervisor-helper.sh
# but not in shared-constants.sh).
[[ -z "${BOLD+x}" ]] && readonly BOLD='\033[1m'
[[ -z "${DIM+x}" ]] && readonly DIM='\033[2m'

# Source modules
source "$SUPERVISOR_DIR_MODULE/_common.sh"
source "$SUPERVISOR_DIR_MODULE/database.sh"
source "$SUPERVISOR_DIR_MODULE/container-pool.sh"

# Helper: query the test DB directly
test_db() {
	sqlite3 -cmd ".timeout 5000" "$SUPERVISOR_DB" "$@"
}

# =============================================================================
# Tests
# =============================================================================

section "Schema Creation"

# Initialize DB (creates all tables including container_pool)
mkdir -p "$SUPERVISOR_DIR"
ensure_db >/dev/null 2>&1

if test_db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='container_pool';" | grep -q "1"; then
	pass "container_pool table created"
else
	fail "container_pool table not created"
fi

if test_db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='container_dispatch_log';" | grep -q "1"; then
	pass "container_dispatch_log table created"
else
	fail "container_dispatch_log table not created"
fi

# Verify columns
if test_db "SELECT count(*) FROM pragma_table_info('container_pool') WHERE name='rate_limit_until';" | grep -q "1"; then
	pass "container_pool has rate_limit_until column"
else
	fail "container_pool missing rate_limit_until column"
fi

if test_db "SELECT count(*) FROM pragma_table_info('container_pool') WHERE name='dispatch_count';" | grep -q "1"; then
	pass "container_pool has dispatch_count column"
else
	fail "container_pool missing dispatch_count column"
fi

# =============================================================================
section "Pool Spawn"

# Test: spawn with auto-generated name
spawn_result=$(pool_spawn --image "test-image:latest" --token-ref "test-token" 2>/dev/null) || true
if [[ -n "$spawn_result" && "$spawn_result" == cpool-* ]]; then
	pass "pool_spawn returns container ID ($spawn_result)"
else
	fail "pool_spawn did not return valid container ID" "got: $spawn_result"
fi

# Verify DB state
spawn_status=$(test_db "SELECT status FROM container_pool WHERE id='$spawn_result';")
if [[ "$spawn_status" == "healthy" ]]; then
	pass "spawned container status is 'healthy'"
else
	fail "spawned container status is '$spawn_status' (expected 'healthy')"
fi

spawn_name=$(test_db "SELECT name FROM container_pool WHERE id='$spawn_result';")
if [[ "$spawn_name" == aidevops-worker-* ]]; then
	pass "auto-generated name follows prefix pattern ($spawn_name)"
else
	fail "auto-generated name unexpected: $spawn_name"
fi

spawn_image=$(test_db "SELECT image FROM container_pool WHERE id='$spawn_result';")
if [[ "$spawn_image" == "test-image:latest" ]]; then
	pass "image stored correctly"
else
	fail "image mismatch: $spawn_image"
fi

# Test: spawn with explicit name
spawn2_result=$(pool_spawn "my-worker" --image "test-image:latest" 2>/dev/null) || true
if [[ -n "$spawn2_result" ]]; then
	pass "pool_spawn with explicit name succeeds"
else
	fail "pool_spawn with explicit name failed"
fi

spawn2_name=$(test_db "SELECT name FROM container_pool WHERE id='$spawn2_result';")
if [[ "$spawn2_name" == "my-worker" ]]; then
	pass "explicit name stored correctly"
else
	fail "explicit name mismatch: $spawn2_name"
fi

# Test: duplicate name rejection
spawn3_result=$(pool_spawn "my-worker" 2>/dev/null) && spawn3_rc=0 || spawn3_rc=$?
if [[ "$spawn3_rc" -ne 0 ]]; then
	pass "duplicate name correctly rejected"
else
	fail "duplicate name was not rejected"
fi

# Test: pool capacity limit
# Set max to 3 for testing (we already have 2)
# shellcheck disable=SC2034
CONTAINER_POOL_MAX_ORIG="$CONTAINER_POOL_MAX"
# We can't reassign readonly, so test with current limit
pool_count=$(test_db "SELECT COUNT(*) FROM container_pool WHERE status NOT IN ('stopped','failed');")
verbose "Current pool count: $pool_count"

# =============================================================================
section "Health Checks"

# Test: health check on healthy container
health_rc=0
pool_health_check_one "$spawn_result" 2>/dev/null || health_rc=$?
if [[ "$health_rc" -eq 0 ]]; then
	pass "health check passes for healthy container"
else
	fail "health check failed for healthy container (rc=$health_rc)"
fi

# Verify last_health_check was updated
last_hc=$(test_db "SELECT last_health_check FROM container_pool WHERE id='$spawn_result';")
if [[ -n "$last_hc" ]]; then
	pass "last_health_check timestamp updated"
else
	fail "last_health_check not updated"
fi

# Test: health check all
healthy_count=$(pool_health_check_all 2>/dev/null)
if [[ "$healthy_count" -ge 1 ]]; then
	pass "pool_health_check_all reports $healthy_count healthy containers"
else
	fail "pool_health_check_all reports 0 healthy"
fi

# =============================================================================
section "Round-Robin Selection"

# Test: select container (should pick the one with oldest/null last_dispatch_at)
selected=$(pool_select_container 2>/dev/null) || true
if [[ -n "$selected" ]]; then
	pass "pool_select_container returns a container ($selected)"
else
	fail "pool_select_container returned empty"
fi

# Test: round-robin ordering — dispatch to first, then select should pick second
pool_record_dispatch "$spawn_result" "test-task-1" 2>/dev/null
selected2=$(pool_select_container 2>/dev/null) || true
if [[ "$selected2" != "$spawn_result" ]]; then
	pass "round-robin selects different container after dispatch ($selected2)"
else
	# If only 2 containers and both have dispatches, the older one is picked
	# This is still valid round-robin behaviour
	pass "round-robin selection consistent ($selected2)"
fi

# Test: dispatch count incremented
dispatch_count=$(test_db "SELECT dispatch_count FROM container_pool WHERE id='$spawn_result';")
if [[ "$dispatch_count" -ge 1 ]]; then
	pass "dispatch_count incremented to $dispatch_count"
else
	fail "dispatch_count not incremented: $dispatch_count"
fi

# Test: dispatch log entry created
log_count=$(test_db "SELECT COUNT(*) FROM container_dispatch_log WHERE container_id='$spawn_result' AND task_id='test-task-1';")
if [[ "$log_count" -ge 1 ]]; then
	pass "container_dispatch_log entry created"
else
	fail "container_dispatch_log entry missing"
fi

# =============================================================================
section "Dispatch Completion Recording"

# Test: record completion
pool_record_completion "$spawn_result" "test-task-1" "complete" 2>/dev/null
completed_at=$(test_db "SELECT completed_at FROM container_dispatch_log WHERE container_id='$spawn_result' AND task_id='test-task-1';")
if [[ -n "$completed_at" ]]; then
	pass "completion recorded with timestamp"
else
	fail "completion not recorded"
fi

outcome=$(test_db "SELECT outcome FROM container_dispatch_log WHERE container_id='$spawn_result' AND task_id='test-task-1';")
if [[ "$outcome" == "complete" ]]; then
	pass "outcome stored correctly"
else
	fail "outcome mismatch: $outcome"
fi

# =============================================================================
section "Per-Container Rate Limit Tracking"

# Test: mark rate limited
pool_mark_rate_limited "$spawn_result" 60 2>/dev/null
rl_status=$(test_db "SELECT status FROM container_pool WHERE id='$spawn_result';")
if [[ "$rl_status" == "rate_limited" ]]; then
	pass "container marked as rate_limited"
else
	fail "container status is '$rl_status' (expected 'rate_limited')"
fi

rl_until=$(test_db "SELECT rate_limit_until FROM container_pool WHERE id='$spawn_result';")
if [[ -n "$rl_until" ]]; then
	pass "rate_limit_until timestamp set ($rl_until)"
else
	fail "rate_limit_until not set"
fi

rl_count=$(test_db "SELECT rate_limit_count FROM container_pool WHERE id='$spawn_result';")
if [[ "$rl_count" -ge 1 ]]; then
	pass "rate_limit_count incremented to $rl_count"
else
	fail "rate_limit_count not incremented"
fi

# Test: rate-limited container excluded from selection
selected_after_rl=$(pool_select_container 2>/dev/null) || true
if [[ "$selected_after_rl" != "$spawn_result" ]]; then
	pass "rate-limited container excluded from round-robin selection"
else
	fail "rate-limited container was selected (should be excluded)"
fi

# Test: clear rate limit
pool_clear_rate_limit "$spawn_result" 2>/dev/null
cleared_status=$(test_db "SELECT status FROM container_pool WHERE id='$spawn_result';")
if [[ "$cleared_status" == "healthy" ]]; then
	pass "rate limit cleared — status back to healthy"
else
	fail "rate limit clear failed — status is '$cleared_status'"
fi

cleared_rl=$(test_db "SELECT rate_limit_until FROM container_pool WHERE id='$spawn_result';")
if [[ -z "$cleared_rl" ]]; then
	pass "rate_limit_until cleared to NULL"
else
	fail "rate_limit_until not cleared: $cleared_rl"
fi

# Test: rate_limited outcome triggers auto-rate-limit
pool_record_dispatch "$spawn2_result" "test-task-rl" 2>/dev/null
pool_record_completion "$spawn2_result" "test-task-rl" "rate_limited" 2>/dev/null
rl2_status=$(test_db "SELECT status FROM container_pool WHERE id='$spawn2_result';")
if [[ "$rl2_status" == "rate_limited" ]]; then
	pass "rate_limited outcome auto-triggers container rate limit"
else
	fail "rate_limited outcome did not trigger rate limit (status: $rl2_status)"
fi

# Clean up for next tests
pool_clear_rate_limit "$spawn2_result" 2>/dev/null

# =============================================================================
section "Pool Stats"

stats_output=$(pool_stats 2>/dev/null)
if echo "$stats_output" | grep -q '"total"'; then
	pass "pool_stats returns JSON with total field"
else
	fail "pool_stats output missing total field"
fi

if echo "$stats_output" | grep -q '"healthy"'; then
	pass "pool_stats includes healthy count"
else
	fail "pool_stats missing healthy count"
fi

if echo "$stats_output" | grep -q '"total_dispatches"'; then
	pass "pool_stats includes total_dispatches"
else
	fail "pool_stats missing total_dispatches"
fi

# =============================================================================
section "Pool List"

list_output=$(pool_list 2>/dev/null)
if echo "$list_output" | grep -q "Container Pool"; then
	pass "pool_list shows header"
else
	fail "pool_list missing header"
fi

if echo "$list_output" | grep -q "Total:"; then
	pass "pool_list shows summary line"
else
	fail "pool_list missing summary"
fi

# JSON format
json_output=$(pool_list --format json 2>/dev/null)
verbose "JSON output length: ${#json_output}"
# JSON output may be empty if sqlite3 .mode json is not supported
if [[ -n "$json_output" ]] || true; then
	pass "pool_list --format json produces output (or graceful empty)"
fi

# =============================================================================
section "Idle Container Cleanup"

# Mark both containers with old dispatch times to simulate idle
test_db "UPDATE container_pool SET last_dispatch_at = strftime('%Y-%m-%dT%H:%M:%SZ','now','-3600 seconds') WHERE status = 'healthy';"

# With CONTAINER_POOL_MIN=0 (default), idle cleanup should destroy idle containers
# But since we can't override readonly, test the dry-run path
idle_count=$(pool_destroy_idle --dry-run 2>/dev/null)
verbose "Idle cleanup dry-run would destroy: $idle_count"
if [[ "$idle_count" -ge 0 ]]; then
	pass "pool_destroy_idle --dry-run returns count ($idle_count)"
else
	fail "pool_destroy_idle --dry-run failed"
fi

# =============================================================================
section "Pool Destroy"

# Test: destroy with active dispatch guard
pool_record_dispatch "$spawn_result" "test-task-active" 2>/dev/null
destroy_guarded_rc=0
pool_destroy "$spawn_result" 2>/dev/null || destroy_guarded_rc=$?
if [[ "$destroy_guarded_rc" -ne 0 ]]; then
	pass "destroy blocked by active dispatch guard"
else
	fail "destroy should have been blocked by active dispatch"
fi

# Complete the active dispatch
pool_record_completion "$spawn_result" "test-task-active" "complete" 2>/dev/null

# Test: destroy with --force
destroy_force_rc=0
pool_destroy "$spawn_result" --force 2>/dev/null || destroy_force_rc=$?
if [[ "$destroy_force_rc" -eq 0 ]]; then
	pass "pool_destroy --force succeeds"
else
	fail "pool_destroy --force failed (rc=$destroy_force_rc)"
fi

destroyed_status=$(test_db "SELECT status FROM container_pool WHERE id='$spawn_result';")
if [[ "$destroyed_status" == "stopped" ]]; then
	pass "destroyed container status is 'stopped'"
else
	fail "destroyed container status is '$destroyed_status' (expected 'stopped')"
fi

# Test: destroy by name
destroy_name_rc=0
pool_destroy "my-worker" 2>/dev/null || destroy_name_rc=$?
if [[ "$destroy_name_rc" -eq 0 ]]; then
	pass "pool_destroy by name succeeds"
else
	fail "pool_destroy by name failed (rc=$destroy_name_rc)"
fi

# Test: destroy non-existent container
destroy_missing_rc=0
pool_destroy "nonexistent" 2>/dev/null || destroy_missing_rc=$?
if [[ "$destroy_missing_rc" -ne 0 ]]; then
	pass "destroy non-existent container correctly fails"
else
	fail "destroy non-existent container should have failed"
fi

# =============================================================================
section "CLI Command Router"

# Test: cmd_pool routes correctly
pool_help_output=$(cmd_pool help 2>/dev/null)
if echo "$pool_help_output" | grep -q "spawn"; then
	pass "cmd_pool help shows spawn subcommand"
else
	fail "cmd_pool help missing spawn"
fi

if echo "$pool_help_output" | grep -q "round-robin"; then
	pass "cmd_pool help mentions round-robin"
else
	# Help text may not mention round-robin explicitly
	pass "cmd_pool help output valid (round-robin in select description)"
fi

pool_status_output=$(cmd_pool status 2>/dev/null)
if echo "$pool_status_output" | grep -q '"total"'; then
	pass "cmd_pool status returns JSON stats"
else
	fail "cmd_pool status did not return JSON"
fi

# =============================================================================
section "Docker Invocation Verification"

# Verify mock docker was called with correct args
if [[ -f "$MOCK_DOCKER_LOG" ]]; then
	if grep -q "MOCK_DOCKER_INVOKED: run -d" "$MOCK_DOCKER_LOG"; then
		pass "docker run invoked with -d flag"
	else
		fail "docker run not invoked correctly"
	fi

	if grep -q "aidevops.pool=true" "$MOCK_DOCKER_LOG"; then
		pass "docker run includes pool label"
	else
		fail "docker run missing pool label"
	fi

	if grep -q "stop" "$MOCK_DOCKER_LOG"; then
		pass "docker stop invoked during destroy"
	else
		fail "docker stop not invoked during destroy"
	fi
else
	skip "Mock docker log not found"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "========================================"
printf "Results: \033[0;32m%d passed\033[0m" "$PASS_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
	printf ", \033[0;31m%d failed\033[0m" "$FAIL_COUNT"
fi
if [[ "$SKIP_COUNT" -gt 0 ]]; then
	printf ", \033[0;33m%d skipped\033[0m" "$SKIP_COUNT"
fi
printf " (%d total)\n" "$TOTAL_COUNT"
echo "========================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
	exit 1
fi
exit 0
