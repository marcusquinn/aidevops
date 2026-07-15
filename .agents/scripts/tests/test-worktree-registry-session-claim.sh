#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worktree-registry-session-claim.sh — GH#26950 regression guard.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REGISTRY_LIB="${SCRIPT_DIR}/../shared-worktree-registry.sh"
TEST_ROOT=$(mktemp -d)
WORKTREE_REGISTRY_DIR="${TEST_ROOT}/registry"
WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
export WORKTREE_REGISTRY_DIR WORKTREE_REGISTRY_DB

TESTS_RUN=0
TESTS_FAILED=0
OWNER_PID=""
CLAIM_PID=""

cleanup() {
	[[ -n "$OWNER_PID" ]] && kill "$OWNER_PID" >/dev/null 2>&1 || true
	[[ -n "$CLAIM_PID" ]] && kill "$CLAIM_PID" >/dev/null 2>&1 || true
	wait "$OWNER_PID" "$CLAIM_PID" 2>/dev/null || true
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

# shellcheck source=../shared-worktree-registry.sh
source "$REGISTRY_LIB"

print_result() {
	local name="$1"
	local rc="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

start_live_pids() {
	sleep 30 &
	OWNER_PID=$!
	sleep 30 &
	CLAIM_PID=$!
	return 0
}

reset_registry() {
	rm -rf "$WORKTREE_REGISTRY_DIR"
	return 0
}

owner_info() {
	local wt_path="$1"
	check_worktree_owner "$wt_path" 2>/dev/null || true
	return 0
}

test_same_opencode_session_rolls_owner_pid() {
	local wt_path="${TEST_ROOT}/same-session"
	mkdir -p "$wt_path"
	export OPENCODE_SESSION_ID="ses_same_session"
	register_worktree "$wt_path" "feature/same-session" --owner-pid "$OWNER_PID" --session "$OPENCODE_SESSION_ID"

	local rc=0
	claim_worktree_ownership "$wt_path" "feature/same-session" --owner-pid "$CLAIM_PID" --session "$OPENCODE_SESSION_ID" || rc=1
	[[ "$(owner_info "$wt_path")" == "${CLAIM_PID}|${OPENCODE_SESSION_ID}|"* ]] || rc=1
	print_result "same trusted OpenCode session rolls owner PID" "$rc"
	return 0
}

test_parameterized_claim_preserves_metacharacters() {
	reset_registry
	local wt_path="${TEST_ROOT}/quote-'|worktree"
	local session_id="ses_quote_'|session"
	mkdir -p "$wt_path"
	export OPENCODE_SESSION_ID="$session_id"
	register_worktree "$wt_path" "feature/original" --owner-pid "$OWNER_PID" --session "$session_id"

	local rc=0
	claim_worktree_ownership "$wt_path" "feature/quote-'branch" --owner-pid "$CLAIM_PID" \
		--session "$session_id" --batch "batch-'value" --task "task-'value" || rc=1
	local registry_path=""
	registry_path=$(_wt_registry_lookup_path "$wt_path")
	local stored_metadata=""
	stored_metadata=$(python3 - "$WORKTREE_REGISTRY_DB" "$registry_path" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute(
        """SELECT branch, owner_session, owner_batch, task_id
           FROM worktree_owners WHERE worktree_path = ?""",
        (sys.argv[2],),
    ).fetchone()
print("|".join(row) if row else "")
PY
	) || rc=1
	[[ "$stored_metadata" == "feature/quote-'branch|${session_id}|batch-'value|task-'value" ]] || rc=1
	print_result "parameterized claim preserves SQL metacharacters" "$rc"
	return 0
}

test_different_session_stays_blocked() {
	reset_registry
	local wt_path="${TEST_ROOT}/different-session"
	mkdir -p "$wt_path"
	register_worktree "$wt_path" "feature/different-session" --owner-pid "$OWNER_PID" --session "ses_original"
	export OPENCODE_SESSION_ID="ses_other"

	local rc=0
	if claim_worktree_ownership "$wt_path" "feature/different-session" --owner-pid "$CLAIM_PID" --session "$OPENCODE_SESSION_ID"; then
		rc=1
	fi
	[[ "$(owner_info "$wt_path")" == "${OWNER_PID}|ses_original|"* ]] || rc=1
	print_result "different live session remains blocked" "$rc"
	return 0
}

test_empty_session_cannot_roll_owner_pid() {
	reset_registry
	local wt_path="${TEST_ROOT}/empty-session"
	mkdir -p "$wt_path"
	unset OPENCODE_SESSION_ID
	register_worktree "$wt_path" "feature/empty-session" --owner-pid "$OWNER_PID" --session ""

	local rc=0
	if claim_worktree_ownership "$wt_path" "feature/empty-session" --owner-pid "$CLAIM_PID" --session ""; then
		rc=1
	fi
	[[ "$(owner_info "$wt_path")" == "${OWNER_PID}||"* ]] || rc=1
	print_result "empty session cannot bypass live owner" "$rc"
	return 0
}

test_untrusted_session_cannot_roll_owner_pid() {
	reset_registry
	local wt_path="${TEST_ROOT}/untrusted-session"
	mkdir -p "$wt_path"
	register_worktree "$wt_path" "feature/untrusted-session" --owner-pid "$OWNER_PID" --session "caller-supplied"
	unset OPENCODE_SESSION_ID

	local rc=0
	if claim_worktree_ownership "$wt_path" "feature/untrusted-session" --owner-pid "$CLAIM_PID" --session "caller-supplied"; then
		rc=1
	fi
	[[ "$(owner_info "$wt_path")" == "${OWNER_PID}|caller-supplied|"* ]] || rc=1
	print_result "untrusted session cannot bypass live owner" "$rc"
	return 0
}

main() {
	start_live_pids
	test_same_opencode_session_rolls_owner_pid
	test_parameterized_claim_preserves_metacharacters
	test_different_session_stays_blocked
	test_empty_session_cannot_roll_owner_pid
	test_untrusted_session_cannot_roll_owner_pid
	printf 'Results: %s/%s passed, %s failed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] && return 0
	return 1
}

main "$@"
