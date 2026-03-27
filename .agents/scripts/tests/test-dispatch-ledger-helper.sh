#!/usr/bin/env bash
# test-dispatch-ledger-helper.sh — Tests for dispatch-ledger-helper.sh (GH#6696)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
LEDGER_HELPER="${SCRIPT_DIR}/../dispatch-ledger-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""

#######################################
# Run a helper command without triggering set -e on failure.
# Captures exit status so test bodies can check it explicitly.
# Usage: run_helper [args...]; LAST_EXIT=$?
#######################################
run_helper() {
	set +e
	"$@"
	LAST_EXIT=$?
	set -e
	return 0
}

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export AIDEVOPS_DISPATCH_LEDGER_DIR="${TEST_ROOT}/ledger"
	mkdir -p "${TEST_ROOT}/ledger"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

#######################################
# Test: register creates a ledger entry
#######################################
test_register_creates_entry() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$

	local entry_count
	entry_count=$(wc -l <"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" | tr -d ' ')

	local result=0
	if [[ "$entry_count" -ne 1 ]]; then
		result=1
	fi

	# Verify fields
	local status
	status=$(jq -r '.status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status" != "in-flight" ]]; then
		result=1
	fi

	local session_key
	session_key=$(jq -r '.session_key' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$session_key" != "issue-42" ]]; then
		result=1
	fi

	print_result "register creates a ledger entry with correct fields" "$result" "count=${entry_count}, status=${status}, key=${session_key}"
	teardown_test_env
	return 0
}

#######################################
# Test: check detects in-flight entry
#######################################
test_check_detects_inflight() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-99" --issue 99 --repo "owner/repo" --pid $$

	local result=1
	if "$LEDGER_HELPER" check --session-key "issue-99" >/dev/null 2>&1; then
		result=0
	fi

	print_result "check detects in-flight entry" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: check returns 1 for unknown session key
#######################################
test_check_returns_1_for_unknown() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$

	local result=0
	if "$LEDGER_HELPER" check --session-key "issue-999" >/dev/null 2>&1; then
		result=1
	fi

	print_result "check returns 1 for unknown session key" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: check-issue detects in-flight by issue number
#######################################
test_check_issue_detects_inflight() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-55" --issue 55 --repo "owner/repo" --pid $$

	local result=1
	if "$LEDGER_HELPER" check-issue --issue 55 --repo "owner/repo" >/dev/null 2>&1; then
		result=0
	fi

	print_result "check-issue detects in-flight by issue number" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: check-issue returns 1 for different repo
#######################################
test_check_issue_different_repo() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-55" --issue 55 --repo "owner/repo-a" --pid $$

	local result=0
	if "$LEDGER_HELPER" check-issue --issue 55 --repo "owner/repo-b" >/dev/null 2>&1; then
		result=1
	fi

	print_result "check-issue returns 1 for different repo" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: complete marks entry as completed
#######################################
test_complete_marks_entry() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" complete --session-key "issue-42"

	# A late fail (e.g., from dead-PID cleanup) must NOT overwrite completed status
	run_helper "$LEDGER_HELPER" fail --session-key "issue-42"

	# check should still return 1 (no in-flight entry)
	local result=0
	if "$LEDGER_HELPER" check --session-key "issue-42" >/dev/null 2>&1; then
		result=1
	fi

	# Verify status is still "completed" — not downgraded to "failed"
	local status
	status=$(jq -r '.status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status" != "completed" ]]; then
		result=1
	fi

	print_result "complete marks entry as completed (terminal state immutable)" "$result" "status=${status}"
	teardown_test_env
	return 0
}

#######################################
# Test: fail marks entry as failed
#######################################
test_fail_marks_entry() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" fail --session-key "issue-42"

	local status
	status=$(jq -r '.status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)

	local result=0
	if [[ "$status" != "failed" ]]; then
		result=1
	fi

	print_result "fail marks entry as failed" "$result" "status=${status}"
	teardown_test_env
	return 0
}

#######################################
# Test: terminal status immutability — fail cannot overwrite completed,
# complete cannot overwrite failed (regression for CodeRabbit review)
#######################################
test_terminal_state_immutability() {
	setup_test_env

	local result=0

	# Case 1: fail must not overwrite completed
	run_helper "$LEDGER_HELPER" register --session-key "issue-77" --issue 77 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" complete --session-key "issue-77"
	run_helper "$LEDGER_HELPER" fail --session-key "issue-77"

	local status1
	status1=$(jq -r 'select(.session_key == "issue-77") | .status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status1" != "completed" ]]; then
		result=1
	fi

	# Case 2: complete must not overwrite failed
	run_helper "$LEDGER_HELPER" register --session-key "issue-78" --issue 78 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" fail --session-key "issue-78"
	run_helper "$LEDGER_HELPER" complete --session-key "issue-78"

	local status2
	status2=$(jq -r 'select(.session_key == "issue-78") | .status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status2" != "failed" ]]; then
		result=1
	fi

	print_result "terminal status immutability (completed/failed are final)" "$result" "completed_after_fail=${status1}, failed_after_complete=${status2}"
	teardown_test_env
	return 0
}

#######################################
# Test: register is idempotent (re-register overwrites)
#######################################
test_register_idempotent() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$

	local entry_count
	entry_count=$(wc -l <"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" | tr -d ' ')

	local result=0
	if [[ "$entry_count" -ne 1 ]]; then
		result=1
	fi

	print_result "register is idempotent (re-register overwrites)" "$result" "count=${entry_count}"
	teardown_test_env
	return 0
}

#######################################
# Test: count returns correct number of in-flight entries
#######################################
test_count_inflight() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-1" --issue 1 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" register --session-key "issue-2" --issue 2 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" register --session-key "issue-3" --issue 3 --repo "owner/repo" --pid $$
	run_helper "$LEDGER_HELPER" complete --session-key "issue-2"

	local count
	count=$("$LEDGER_HELPER" count)

	local result=0
	if [[ "$count" -ne 2 ]]; then
		result=1
	fi

	print_result "count returns correct number of in-flight entries" "$result" "count=${count} (expected 2)"
	teardown_test_env
	return 0
}

#######################################
# Test: expire removes stale entries by TTL
#######################################
test_expire_by_ttl() {
	setup_test_env

	# Create an entry with a timestamp 2 hours ago
	local old_ts
	old_ts=$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-2H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "2020-01-01T00:00:00Z")

	printf '{"session_key":"issue-old","issue_number":"100","repo_slug":"owner/repo","pid":99999999,"dispatched_at":"%s","status":"in-flight","updated_at":"%s"}\n' "$old_ts" "$old_ts" >"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"

	local expired_count
	expired_count=$("$LEDGER_HELPER" expire --ttl 60)

	local result=0
	if [[ "$expired_count" -ne 1 ]]; then
		result=1
	fi

	# Verify status changed to failed
	local status
	status=$(jq -r '.status' "${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" 2>/dev/null | head -1)
	if [[ "$status" != "failed" ]]; then
		result=1
	fi

	print_result "expire removes stale entries by TTL" "$result" "expired=${expired_count}, status=${status}"
	teardown_test_env
	return 0
}

#######################################
# Test: expire detects dead PIDs
#######################################
test_expire_dead_pid() {
	setup_test_env

	local now_ts
	now_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# Use a PID that definitely doesn't exist (99999999)
	printf '{"session_key":"issue-dead","issue_number":"200","repo_slug":"owner/repo","pid":99999999,"dispatched_at":"%s","status":"in-flight","updated_at":"%s"}\n' "$now_ts" "$now_ts" >"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"

	local expired_count
	expired_count=$("$LEDGER_HELPER" expire --ttl 99999)

	local result=0
	if [[ "$expired_count" -ne 1 ]]; then
		result=1
	fi

	print_result "expire detects dead PIDs" "$result" "expired=${expired_count}"
	teardown_test_env
	return 0
}

#######################################
# Test: check detects dead PID and marks as failed
#######################################
test_check_dead_pid_marks_failed() {
	setup_test_env

	local now_ts
	now_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# Register with a dead PID
	printf '{"session_key":"issue-dead","issue_number":"300","repo_slug":"owner/repo","pid":99999999,"dispatched_at":"%s","status":"in-flight","updated_at":"%s"}\n' "$now_ts" "$now_ts" >"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"

	# check should return 1 (safe to dispatch) because PID is dead
	local result=0
	if "$LEDGER_HELPER" check --session-key "issue-dead" >/dev/null 2>&1; then
		result=1
	fi

	print_result "check detects dead PID and returns safe-to-dispatch" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: prune removes old completed/failed entries
#######################################
test_prune_old_entries() {
	setup_test_env

	local old_ts
	old_ts=$(date -u -d '48 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-48H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "2020-01-01T00:00:00Z")
	local now_ts
	now_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

	# One old completed entry, one recent in-flight entry
	{
		printf '{"session_key":"issue-old","issue_number":"100","repo_slug":"owner/repo","pid":1,"dispatched_at":"%s","status":"completed","updated_at":"%s"}\n' "$old_ts" "$old_ts"
		printf '{"session_key":"issue-new","issue_number":"200","repo_slug":"owner/repo","pid":%d,"dispatched_at":"%s","status":"in-flight","updated_at":"%s"}\n' "$$" "$now_ts" "$now_ts"
	} >"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl"

	local pruned_count
	pruned_count=$("$LEDGER_HELPER" prune)

	local remaining
	remaining=$(wc -l <"${AIDEVOPS_DISPATCH_LEDGER_DIR}/dispatch-ledger.jsonl" | tr -d ' ')

	local result=0
	if [[ "$pruned_count" -ne 1 ]]; then
		result=1
	fi
	if [[ "$remaining" -ne 1 ]]; then
		result=1
	fi

	print_result "prune removes old completed/failed entries" "$result" "pruned=${pruned_count}, remaining=${remaining}"
	teardown_test_env
	return 0
}

#######################################
# Test: status command runs without error
#######################################
test_status_runs() {
	setup_test_env

	run_helper "$LEDGER_HELPER" register --session-key "issue-42" --issue 42 --repo "owner/repo" --pid $$

	local output
	output=$("$LEDGER_HELPER" status 2>&1)
	local exit_code=$?

	local result=0
	if [[ "$exit_code" -ne 0 ]]; then
		result=1
	fi

	print_result "status command runs without error" "$result"
	teardown_test_env
	return 0
}

#######################################
# Test: empty ledger operations don't fail
#######################################
test_empty_ledger_operations() {
	setup_test_env

	local result=0

	# All operations should succeed on empty ledger
	if "$LEDGER_HELPER" check --session-key "nonexistent" >/dev/null 2>&1; then
		result=1 # Should return 1 (not found)
	fi

	local count
	count=$("$LEDGER_HELPER" count)
	if [[ "$count" -ne 0 ]]; then
		result=1
	fi

	local expired
	expired=$("$LEDGER_HELPER" expire)
	if [[ "$expired" -ne 0 ]]; then
		result=1
	fi

	"$LEDGER_HELPER" status >/dev/null 2>&1 || result=1

	print_result "empty ledger operations don't fail" "$result" "count=${count}"
	teardown_test_env
	return 0
}

#######################################
# Run all tests
#######################################
main() {
	echo "=== dispatch-ledger-helper.sh tests (GH#6696) ==="
	echo ""

	# Verify helper exists
	if [[ ! -x "$LEDGER_HELPER" ]]; then
		echo "ERROR: dispatch-ledger-helper.sh not found at $LEDGER_HELPER"
		exit 1
	fi

	# Verify jq is available
	if ! command -v jq &>/dev/null; then
		echo "ERROR: jq is required for tests"
		exit 1
	fi

	test_register_creates_entry
	test_check_detects_inflight
	test_check_returns_1_for_unknown
	test_check_issue_detects_inflight
	test_check_issue_different_repo
	test_complete_marks_entry
	test_terminal_state_immutability
	test_fail_marks_entry
	test_register_idempotent
	test_count_inflight
	test_expire_by_ttl
	test_expire_dead_pid
	test_check_dead_pid_marks_failed
	test_prune_old_entries
	test_status_runs
	test_empty_ledger_operations

	echo ""
	echo "=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ==="

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
