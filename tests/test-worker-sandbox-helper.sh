#!/usr/bin/env bash
# test-worker-sandbox-helper.sh — sandbox lifecycle + auditability checks (t1412)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_DIR}/.agents/scripts/worker-sandbox-helper.sh"

PASS_COUNT=0
FAIL_COUNT=0
TEST_TMPDIR=""

pass() {
	local name="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	echo "  PASS: $name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "  FAIL: $name"
	if [[ -n "$detail" ]]; then
		echo "        $detail"
	fi
	return 0
}

cleanup() {
	if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
		rm -rf "$TEST_TMPDIR"
	fi
	return 0
}
trap cleanup EXIT

setup() {
	TEST_TMPDIR="$(mktemp -d)"
	mkdir -p "$TEST_TMPDIR/real-home/.config/opencode"
	mkdir -p "$TEST_TMPDIR/real-home/.claude"
	mkdir -p "$TEST_TMPDIR/audit"
	echo '{"mcpServers":{}}' >"$TEST_TMPDIR/real-home/.config/opencode/opencode.json"
	echo '{}' >"$TEST_TMPDIR/real-home/.claude/settings.json"
	return 0
}

run_sandbox_cmd() {
	local action="$1"
	shift

	HOME="$TEST_TMPDIR/real-home" \
		REAL_HOME="$TEST_TMPDIR/real-home" \
		WORKER_SANDBOX_BASE="$TEST_TMPDIR/sandbox-base" \
		AUDIT_LOG_DIR="$TEST_TMPDIR/audit" \
		AUDIT_LOG_FILE="$TEST_TMPDIR/audit/audit.jsonl" \
		AUDIT_QUIET="true" \
		bash "$SCRIPT" "$action" "$@"
	return $?
}

test_create_records_audit_event() {
	echo "Test: sandbox create records audit event"
	setup

	local sandbox_dir
	sandbox_dir="$(run_sandbox_cmd create t1412-create)"

	if [[ -d "$sandbox_dir" && -f "$sandbox_dir/.aidevops-sandbox" ]]; then
		pass "sandbox directory and sentinel created"
	else
		fail "sandbox directory or sentinel missing"
		cleanup
		return 0
	fi

	if grep -q '^task_id=t1412-create$' "$sandbox_dir/.aidevops-sandbox"; then
		pass "sentinel stores task id"
	else
		fail "sentinel missing expected task id"
	fi

	if jq -e 'select(.msg == "worker_sandbox_created" and .detail.task_id == "t1412-create")' \
		"$TEST_TMPDIR/audit/audit.jsonl" >/dev/null 2>&1; then
		pass "audit log contains sandbox create event with correct task_id"
	else
		fail "missing sandbox create audit event or incorrect task_id"
	fi

	run_sandbox_cmd cleanup "$sandbox_dir" >/dev/null
	cleanup
	return 0
}

test_cleanup_records_audit_event() {
	echo "Test: sandbox cleanup records audit event"
	setup

	local sandbox_dir
	sandbox_dir="$(run_sandbox_cmd create t1412-cleanup)"
	run_sandbox_cmd cleanup "$sandbox_dir" >/dev/null

	if [[ ! -d "$sandbox_dir" ]]; then
		pass "sandbox directory removed"
	else
		fail "sandbox directory still exists after cleanup"
	fi

	if jq -e 'select(.msg == "worker_sandbox_cleaned" and .detail.task_id == "t1412-cleanup")' \
		"$TEST_TMPDIR/audit/audit.jsonl" >/dev/null 2>&1; then
		pass "audit log contains sandbox cleanup event with correct task_id"
	else
		fail "missing sandbox cleanup audit event or incorrect task_id"
	fi

	cleanup
	return 0
}

main() {
	echo "=== test-worker-sandbox-helper.sh ==="
	test_create_records_audit_event
	test_cleanup_records_audit_event
	echo ""
	echo "Passed: ${PASS_COUNT}"
	echo "Failed: ${FAIL_COUNT}"

	if [[ "$FAIL_COUNT" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main
