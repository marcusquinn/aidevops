#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
OWNER_PID=""

teardown() {
	if [[ "$OWNER_PID" =~ ^[0-9]+$ ]]; then
		kill "$OWNER_PID" 2>/dev/null || true
		wait "$OWNER_PID" 2>/dev/null || true
	fi
	rm -rf "$TEST_ROOT"
	return 0
}
trap teardown EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="${TEST_ROOT}/cleanup-receipts"
export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/cleanup.log"
mkdir -p "$HOME" "${TEST_ROOT}/worktree-one" "${TEST_ROOT}/worktree-two"

# shellcheck source=../full-loop-cleanup-receipt.sh
source "${SCRIPTS_DIR}/full-loop-cleanup-receipt.sh"

sleep 30 &
OWNER_PID=$!

receipt_one=$(full_loop_write_cleanup_deferred example/repo 101 "${TEST_ROOT}/worktree-one" feature/one \
	"$OWNER_PID" session-one not-requested)
jq -e --argjson owner_pid "$OWNER_PID" '
	.schema_version == 1
	and .executor_completion_state == "COMPLETE"
	and .resource_cleanup_state == "CLEANUP_DEFERRED"
	and .cleanup_lease.state == "pending"
	and .owner.pid == $owner_pid
	and (.owner.process_identity | length > 0)
' "$receipt_one" >/dev/null
full_loop_cleanup_owner_alive "$receipt_one"
printf 'PASS deferred receipt persists external owner identity and pending lease\n'

_WTAR_SKIPPED="skipped"
_WTAR_WH_CALLER="test"
_WT_CLEAN_MODE_SKIPPED="skipped"
_WT_CLEAN_REASON_OWNED_SKIP="owned-skip"
log_worktree_removal_event() { return 0; }
claim_worktree_ownership() { return 0; }
unregister_worktree_if_owner_pid() { return 0; }
is_worktree_owned_by_others() { return 1; }
# shellcheck source=../worktree-clean-lib.sh
source "${SCRIPTS_DIR}/worktree-clean-lib.sh"
_clean_deferred_parent_alive "${TEST_ROOT}/worktree-one"
printf 'PASS guarded cleanup observes the external live-owner receipt\n'

jq '.owner.process_identity = "different process generation"' "$receipt_one" >"${receipt_one}.tmp"
mv "${receipt_one}.tmp" "$receipt_one"
if full_loop_cleanup_owner_alive "$receipt_one"; then
	printf 'FAIL PID reuse identity mismatch was accepted as the original owner\n'
	exit 1
fi
printf 'PASS process-generation mismatch prevents PID reuse from extending ownership\n'

deferred_state=0
_clean_deferred_parent_alive "${TEST_ROOT}/worktree-one" || deferred_state=$?
[[ "$deferred_state" -eq 2 ]]
printf 'PASS guarded cleanup treats PID reuse as an expired owner generation\n'

receipt_one=$(full_loop_write_cleanup_deferred example/repo 101 "${TEST_ROOT}/worktree-one" feature/one \
	"$OWNER_PID" session-one not-requested)
_clean_acquire_removal_lease "${TEST_ROOT}/worktree-one" feature/one
jq -e --argjson lease_pid "$$" \
	'.resource_cleanup_state == "CLEANUP_LEASED" and .cleanup_lease.state == "acquired" and .cleanup_lease.pid == $lease_pid' \
	"$receipt_one" >/dev/null
printf 'PASS cleanup supervisor acquires a durable lease\n'

printf '[2026-07-21T00:00:00Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' \
	"${TEST_ROOT}/worktree-one" >>"$AIDEVOPS_CLEANUP_LOG"
rm -rf "${TEST_ROOT}/worktree-one"
full_loop_mark_cleanup_cleaned_for_worktree "${TEST_ROOT}/worktree-one"
full_loop_mark_cleanup_cleaned_for_worktree "${TEST_ROOT}/worktree-one"
jq -e '.resource_cleanup_state == "CLEANED" and .cleanup_lease.state == "released" and (.cleaned_at | length > 0)' \
	"$receipt_one" >/dev/null
if full_loop_transition_cleanup_receipt "$receipt_one" "$_FULL_LOOP_CLEANUP_DEFERRED"; then
	printf 'FAIL terminal CLEANED receipt regressed to CLEANUP_DEFERRED\n'
	exit 1
fi
printf 'PASS CLEANED transition is idempotent and irreversible\n'

sleep 1
newest_receipt=$(full_loop_write_cleanup_deferred example/repo 103 "${TEST_ROOT}/worktree-one" feature/reused \
	"$OWNER_PID" session-reused not-requested)
selected_receipt=$(full_loop_cleanup_receipt_for_worktree "${TEST_ROOT}/worktree-one")
[[ "$selected_receipt" == "$newest_receipt" ]]
printf 'PASS reused worktree paths select the newest lifecycle receipt\n'

receipt_two=$(full_loop_write_cleanup_deferred example/repo 102 "${TEST_ROOT}/worktree-two" feature/two \
	"$OWNER_PID" session-two not-requested)
full_loop_transition_cleanup_receipt "$receipt_two" "$_FULL_LOOP_CLEANUP_LEASED" "$$"
printf '[2026-07-21T00:00:01Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' \
	"${TEST_ROOT}/worktree-two" >>"$AIDEVOPS_CLEANUP_LOG"
rm -rf "${TEST_ROOT}/worktree-two"
full_loop_reconcile_cleanup_receipts
jq -e '.resource_cleanup_state == "CLEANED"' "$receipt_two" >/dev/null
printf 'PASS audit reconciliation repairs a crash between removal and CLEANED persistence\n'

exit 0
