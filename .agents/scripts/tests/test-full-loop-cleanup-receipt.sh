#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Resolve symlinks (macOS /var -> /private/var) so recorded worktree paths match
# what `git rev-parse --show-toplevel` reports, as they do in production.
TEST_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
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
export WORKTREE_REGISTRY_DIR="${TEST_ROOT}/registry"
export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
mkdir -p "$HOME" "${TEST_ROOT}/worktree-one" "${TEST_ROOT}/worktree-two"

# shellcheck source=../full-loop-cleanup-receipt.sh
source "${SCRIPTS_DIR}/full-loop-cleanup-receipt.sh"
# shellcheck source=../shared-worktree-registry.sh
source "${SCRIPTS_DIR}/shared-worktree-registry.sh"

sleep 30 &
OWNER_PID=$!

receipt_lock_dir="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/.mutation.lock.d"
mkdir -p "$receipt_lock_dir"
if _full_loop_receipt_reclaim_stale_ownerless_lock "$receipt_lock_dir" 5; then
	printf 'FAIL fresh ownerless receipt lock was reclaimed\n'
	exit 1
fi
[[ -d "$receipt_lock_dir" && ! -e "${receipt_lock_dir}/owner" ]]
rmdir "$receipt_lock_dir"
printf 'PASS fresh ownerless receipt lock remains untouched\n'

mkdir -p "$receipt_lock_dir"
touch -t 202001010000 "$receipt_lock_dir"
_full_loop_receipt_reclaim_stale_ownerless_lock "$receipt_lock_dir" 5
[[ ! -e "$receipt_lock_dir" ]]
printf 'PASS stale ownerless receipt lock is reclaimed\n'

mkdir -p "$receipt_lock_dir"
printf '%s\n' "$OWNER_PID" >"${receipt_lock_dir}/owner"
if _full_loop_receipt_reclaim_stale_ownerless_lock "$receipt_lock_dir" 5; then
	printf 'FAIL live receipt lock owner was reclaimed\n'
	exit 1
fi
[[ -f "${receipt_lock_dir}/owner" ]]
rm -f "${receipt_lock_dir}/owner"
rmdir "$receipt_lock_dir"
printf 'PASS live receipt lock owner remains protected\n'

mkdir -p "$receipt_lock_dir"
printf '%s\n' '99999999' >"${receipt_lock_dir}/owner"
_full_loop_receipt_lock_acquire
_full_loop_receipt_lock_release
[[ ! -e "$receipt_lock_dir" ]]
printf 'PASS dead numeric receipt lock owner is reclaimed\n'

mkdir -p "$receipt_lock_dir"
touch -t 202001010000 "$receipt_lock_dir"
(
	while [[ ! -d "${receipt_lock_dir}/.reclaim" ]]; do
		:
	done
	printf '%s\n' "$OWNER_PID" >"${receipt_lock_dir}/owner"
) &
owner_publication_pid=$!
if _full_loop_receipt_reclaim_stale_ownerless_lock "$receipt_lock_dir" 5; then
	printf 'FAIL concurrent receipt lock owner publication was reclaimed\n'
	exit 1
fi
wait "$owner_publication_pid"
[[ -f "${receipt_lock_dir}/owner" ]]
rm -f "${receipt_lock_dir}/owner"
rmdir "$receipt_lock_dir"
printf 'PASS concurrent receipt lock owner publication prevents reclamation\n'

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
[[ "$_FULL_LOOP_CLEANUP_OWNER_PID" == "$OWNER_PID" ]]
printf 'PASS deferred receipt persists external owner identity and pending lease\n'

cp "$receipt_one" "${TEST_ROOT}/receipt-idempotent.json"
replayed_receipt=$(full_loop_write_cleanup_deferred example/repo 101 "${TEST_ROOT}/worktree-one" feature/one \
	"$OWNER_PID" session-one not-requested)
[[ "$replayed_receipt" == "$receipt_one" ]]
cmp -s "$receipt_one" "${TEST_ROOT}/receipt-idempotent.json"
printf 'PASS identical deferred receipt replay is idempotent\n'

finalizing_receipt=$(full_loop_write_cleanup_deferred example/repo 104 "${TEST_ROOT}/worktree-two" feature/finalize \
	"$OWNER_PID" session-finalize not-requested FINALIZATION_PENDING)
full_loop_finalize_cleanup_receipt example/repo 104 not-requested "${TEST_ROOT}/worktree-two" feature/finalize \
	"$OWNER_PID" session-finalize
jq -e '.executor_completion_state == "COMPLETE" and .resource_cleanup_state == "CLEANUP_DEFERRED"' \
	"$finalizing_receipt" >/dev/null
cp "$finalizing_receipt" "${TEST_ROOT}/receipt-finalized.json"
full_loop_finalize_cleanup_receipt example/repo 104 not-requested "${TEST_ROOT}/worktree-two" feature/finalize \
	"$OWNER_PID" session-finalize
cmp -s "$finalizing_receipt" "${TEST_ROOT}/receipt-finalized.json"
printf 'PASS exact deferred receipt finalization is idempotent\n'

for conflict_filter in \
	'.repository = "wrong/repo"' \
	'.pr_number = 999' \
	'.worktree = "/wrong/worktree"' \
	'.branch = "feature/wrong"' \
	'.owner.pid = 99999999' \
	'.owner.process_identity = "wrong process generation"' \
	'.owner.session = "wrong-session"' \
	'.release_status = "published"' \
	'.resource_cleanup_state = "CLEANUP_LEASED"' \
	'.cleanup_lease = {state:"acquired",pid:99999999,acquired_at:"2026-08-02T00:00:00Z"}'; do
	cp "${TEST_ROOT}/receipt-finalized.json" "$finalizing_receipt"
	jq "$conflict_filter" "$finalizing_receipt" >"${finalizing_receipt}.tmp"
	mv "${finalizing_receipt}.tmp" "$finalizing_receipt"
	cp "$finalizing_receipt" "${TEST_ROOT}/receipt-finalize-conflict.json"
	if full_loop_finalize_cleanup_receipt example/repo 104 not-requested "${TEST_ROOT}/worktree-two" feature/finalize \
		"$OWNER_PID" session-finalize >/dev/null 2>&1; then
		printf 'FAIL conflicting exact receipt evidence was finalized: %s\n' "$conflict_filter"
		exit 1
	fi
	cmp -s "$finalizing_receipt" "${TEST_ROOT}/receipt-finalize-conflict.json"
done
rm -f "$finalizing_receipt"
printf 'PASS exact finalization preserves conflicting repository, PR, worktree, branch, owner, release, and cleanup evidence\n'

pending_release_receipt=$(full_loop_write_cleanup_deferred example/repo 105 "${TEST_ROOT}/worktree-two" \
	feature/pending-release "$OWNER_PID" session-pending-release pending FINALIZATION_PENDING)
full_loop_finalize_cleanup_receipt example/repo 105 not-requested "${TEST_ROOT}/worktree-two" \
	feature/pending-release "$OWNER_PID" session-pending-release
jq -e '.executor_completion_state == "COMPLETE" and .release_status == "not-requested"' \
	"$pending_release_receipt" >/dev/null
printf 'PASS exact finalization atomically converges pending cleanup release evidence\n'

_WTAR_SKIPPED="skipped"
_WTAR_WH_CALLER="test"
_WT_CLEAN_MODE_SKIPPED="skipped"
_WT_CLEAN_REASON_OWNED_SKIP="owned-skip"
log_worktree_removal_event() { return 0; }
# shellcheck source=../worktree-clean-lib.sh
source "${SCRIPTS_DIR}/worktree-clean-lib.sh"
_clean_deferred_parent_alive "${TEST_ROOT}/worktree-one"
printf 'PASS guarded cleanup observes the external live-owner receipt\n'

# GH#32528: live interactive owners must not pin merged worktrees forever.
registry_row_count() {
	local wt_path=""
	wt_path=$(_wt_registry_lookup_path "$1")
	sqlite3 "$WORKTREE_REGISTRY_DB" \
		"SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = '$(_wt_sql_escape "$wt_path")';"
	return 0
}
cp "$receipt_one" "${TEST_ROOT}/receipt-live-owner.json"
claim_worktree_ownership "${TEST_ROOT}/worktree-one" feature/one --owner-pid "$OWNER_PID" \
	--session session-one --task post-merge-cleanup
jq '.created_at = "2020-01-01T00:00:00Z"' "$receipt_one" >"${receipt_one}.tmp"
mv "${receipt_one}.tmp" "$receipt_one"
deferred_state=0
_clean_deferred_parent_alive "${TEST_ROOT}/worktree-one" 2>/dev/null || deferred_state=$?
[[ "$deferred_state" -eq 2 && "$(registry_row_count "${TEST_ROOT}/worktree-one")" == "0" ]]
printf 'PASS aged live-owner lease expires and releases only its post-merge registry claim\n'

cp "${TEST_ROOT}/receipt-live-owner.json" "$receipt_one"
claim_worktree_ownership "${TEST_ROOT}/worktree-one" feature/one --owner-pid "$OWNER_PID" \
	--session session-one --task post-merge-cleanup
claim_worktree_ownership "${TEST_ROOT}/worktree-two" feature/two --owner-pid "$OWNER_PID" \
	--session session-one --task next-task
sqlite3 "$WORKTREE_REGISTRY_DB" "UPDATE worktree_owners SET created_at = '2099-01-01T00:00:00Z'
	WHERE worktree_path = '$(_wt_sql_escape "$(_wt_registry_lookup_path "${TEST_ROOT}/worktree-two")")';"
jq '.owner.session = "full-loop-lifecycle"' "$receipt_one" >"${receipt_one}.tmp"
mv "${receipt_one}.tmp" "$receipt_one"
_clean_deferred_parent_alive "${TEST_ROOT}/worktree-one"
printf 'PASS generic shared session never infers that the owner moved on\n'

cp "${TEST_ROOT}/receipt-live-owner.json" "$receipt_one"
deferred_state=0
_clean_deferred_parent_alive "${TEST_ROOT}/worktree-one" 2>/dev/null || deferred_state=$?
[[ "$deferred_state" -eq 2 && "$(registry_row_count "${TEST_ROOT}/worktree-one")" == "0" ]]
[[ "$(registry_row_count "${TEST_ROOT}/worktree-two")" == "1" ]]
printf 'PASS newer claim by the same session expires the older post-merge lease\n'
sqlite3 "$WORKTREE_REGISTRY_DB" "DELETE FROM worktree_owners;"
cp "${TEST_ROOT}/receipt-live-owner.json" "$receipt_one"

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

cp "$receipt_one" "${TEST_ROOT}/receipt-conflict.json"
if full_loop_write_cleanup_deferred example/repo 101 "${TEST_ROOT}/worktree-one" feature/one \
	"$OWNER_PID" session-one not-requested >/dev/null; then
	printf 'FAIL conflicting owner generation was overwritten by receipt replay\n'
	exit 1
fi
cmp -s "$receipt_one" "${TEST_ROOT}/receipt-conflict.json"
printf 'PASS conflicting owner generation fails closed without mutation\n'

rm -f "$receipt_one"
receipt_one=$(full_loop_write_cleanup_deferred example/repo 101 "${TEST_ROOT}/worktree-one" feature/one \
	"$OWNER_PID" session-one not-requested)
export OPENCODE_PID="$OWNER_PID"
_clean_acquire_removal_lease "${TEST_ROOT}/worktree-one" feature/one
if ! _clean_has_exact_removal_lease "${TEST_ROOT}/worktree-one"; then
	printf 'FAIL cleanup exact-PID owner check rejected its own registry lease\n'
	exit 1
fi
if ! is_worktree_owned_by_others "${TEST_ROOT}/worktree-one"; then
	printf 'FAIL generic stable-runtime owner check unexpectedly matched the leaf cleanup lease\n'
	exit 1
fi
jq -e --argjson lease_pid "$$" \
	'.resource_cleanup_state == "CLEANUP_LEASED" and .cleanup_lease.state == "acquired" and .cleanup_lease.pid == $lease_pid' \
	"$receipt_one" >/dev/null
printf 'PASS cleanup supervisor acquires a durable lease\n'
printf 'PASS cleanup lease survives a real registry round trip with distinct runtime and leaf PIDs\n'

printf '[2026-07-21T00:00:00Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' \
	"${TEST_ROOT}/worktree-one" >>"$AIDEVOPS_CLEANUP_LOG"
rm -rf "${TEST_ROOT}/worktree-one"
if full_loop_mark_cleanup_cleaned_for_identity wrong/repo 101 "${TEST_ROOT}/worktree-one"; then
	printf 'FAIL conflicting repository identity transitioned the cleanup receipt\n'
	exit 1
fi
if full_loop_mark_cleanup_cleaned_for_identity example/repo 999 "${TEST_ROOT}/worktree-one"; then
	printf 'FAIL conflicting PR identity transitioned the cleanup receipt\n'
	exit 1
fi
if full_loop_mark_cleanup_cleaned_for_identity example/repo 101 "${TEST_ROOT}/different-worktree"; then
	printf 'FAIL conflicting worktree identity transitioned the cleanup receipt\n'
	exit 1
fi
full_loop_mark_cleanup_cleaned_for_identity example/repo 101 "${TEST_ROOT}/worktree-one"
full_loop_mark_cleanup_cleaned_for_worktree "${TEST_ROOT}/worktree-one"
jq -e '.resource_cleanup_state == "CLEANED" and .cleanup_lease.state == "released" and (.cleaned_at | length > 0)' \
	"$receipt_one" >/dev/null
if full_loop_transition_cleanup_receipt "$receipt_one" "$_FULL_LOOP_CLEANUP_DEFERRED"; then
	printf 'FAIL terminal CLEANED receipt regressed to CLEANUP_DEFERRED\n'
	exit 1
fi
printf 'PASS conflicting repository, PR, and worktree identities fail closed\n'
printf 'PASS CLEANED transition is idempotent and irreversible\n'

sleep 1
newest_receipt=$(full_loop_write_cleanup_deferred example/repo 103 "${TEST_ROOT}/worktree-one" feature/reused \
	"$OWNER_PID" session-reused not-requested)
selected_receipt=$(full_loop_cleanup_receipt_for_worktree "${TEST_ROOT}/worktree-one")
[[ "$selected_receipt" == "$newest_receipt" ]]
printf 'PASS reused worktree paths select the newest lifecycle receipt\n'

migrated_receipt="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/example_migrated-104.json"
jq '.repository = "example/migrated" | .pr_number = 104
	| .migration = {from_repository:"example/repo",to_repository:"example/migrated",migrated_at:.created_at}' \
	"$newest_receipt" >"$migrated_receipt"
selected_receipt=$(full_loop_cleanup_receipt_for_worktree "${TEST_ROOT}/worktree-one")
[[ "$selected_receipt" == "$migrated_receipt" ]]
printf 'PASS equal-time receipt lookup preserves migrated-receipt preference\n'

lookup_bin="${TEST_ROOT}/lookup-bin"
lookup_counter="${TEST_ROOT}/lookup-jq-count"
lookup_original_path="$PATH"
real_jq=$(command -v jq)
mkdir -p "$lookup_bin"
cat >"${lookup_bin}/jq" <<'LOOKUP_JQ'
#!/usr/bin/env bash
set -euo pipefail
lookup_count=0
if [[ -f "$AIDEVOPS_TEST_LOOKUP_JQ_COUNTER" ]]; then
	IFS= read -r lookup_count <"$AIDEVOPS_TEST_LOOKUP_JQ_COUNTER" || lookup_count=0
fi
[[ "$lookup_count" =~ ^[0-9]+$ ]] || lookup_count=0
printf '%s\n' "$((lookup_count + 1))" >"$AIDEVOPS_TEST_LOOKUP_JQ_COUNTER"
exec "$AIDEVOPS_TEST_REAL_JQ" "$@"
LOOKUP_JQ
chmod +x "${lookup_bin}/jq"
export AIDEVOPS_TEST_LOOKUP_JQ_COUNTER="$lookup_counter"
export AIDEVOPS_TEST_REAL_JQ="$real_jq"
export PATH="${lookup_bin}:${PATH}"
selected_receipt=$(full_loop_cleanup_receipt_for_worktree "${TEST_ROOT}/worktree-one")
export PATH="$lookup_original_path"
unset AIDEVOPS_TEST_LOOKUP_JQ_COUNTER AIDEVOPS_TEST_REAL_JQ
IFS= read -r lookup_count <"$lookup_counter"
[[ "$selected_receipt" == "$migrated_receipt" && "$lookup_count" -eq 1 ]]
printf 'PASS receipt lookup scans all valid receipts with one jq process\n'

invalid_receipt="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/invalid.json"
printf '%s\n' '{invalid-json' >"$invalid_receipt"
selected_receipt=$(full_loop_cleanup_receipt_for_worktree "${TEST_ROOT}/worktree-one")
rm -f "$invalid_receipt"
[[ "$selected_receipt" == "$migrated_receipt" ]]
printf 'PASS malformed receipt falls back without hiding a valid lifecycle receipt\n'

atomic_worktree="${TEST_ROOT}/atomic-worktree"
mkdir -p "$atomic_worktree"
atomic_receipt_one=$(full_loop_write_cleanup_deferred example/atomic-one 201 "$atomic_worktree" feature/atomic \
	"$OWNER_PID" atomic-session not-requested)
atomic_receipt_two=$(full_loop_write_cleanup_deferred example/atomic-two 202 "$atomic_worktree" feature/atomic \
	"$OWNER_PID" atomic-session not-requested)
full_loop_transition_cleanup_receipt "$atomic_receipt_one" "$_FULL_LOOP_CLEANUP_CLEANED"
full_loop_transition_cleanup_receipt "$atomic_receipt_two" "$_FULL_LOOP_CLEANUP_CLEANED"
cp "$atomic_receipt_one" "${TEST_ROOT}/atomic-receipt-one.original"
cp "$atomic_receipt_two" "${TEST_ROOT}/atomic-receipt-two.original"

mock_bin="${TEST_ROOT}/mock-bin"
mkdir -p "$mock_bin"
real_mv=$(command -v mv)
cat >"${mock_bin}/mv" <<'MOCK_MV'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${AIDEVOPS_TEST_RECEIPT_MV_COUNTER:-}" && "$#" -eq 2 &&
	"$1" == "${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}"/.recreated-receipts.*/publish/*.json &&
	"$2" == "${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}"/*.json ]]; then
	publication_count=0
	if [[ -f "$AIDEVOPS_TEST_RECEIPT_MV_COUNTER" ]]; then
		IFS= read -r publication_count <"$AIDEVOPS_TEST_RECEIPT_MV_COUNTER" || publication_count=0
	fi
	[[ "$publication_count" =~ ^[0-9]+$ ]] || publication_count=0
	publication_count=$((publication_count + 1))
	printf '%s\n' "$publication_count" >"$AIDEVOPS_TEST_RECEIPT_MV_COUNTER"
	if [[ "$publication_count" -eq "${AIDEVOPS_TEST_FAIL_RECEIPT_PUBLICATION_AT:-0}" ]]; then
		exit 1
	fi
fi
exec "$AIDEVOPS_TEST_REAL_MV" "$@"
MOCK_MV
chmod +x "${mock_bin}/mv"

original_path="$PATH"
export AIDEVOPS_TEST_REAL_MV="$real_mv"
export AIDEVOPS_TEST_RECEIPT_MV_COUNTER="${TEST_ROOT}/receipt-publication-count"
export AIDEVOPS_TEST_FAIL_RECEIPT_PUBLICATION_AT=2
export PATH="${mock_bin}:${PATH}"
atomic_result=0
_full_loop_receipt_lock_acquire
if _full_loop_supersede_recreated_receipt_files "$AIDEVOPS_FULL_LOOP_CLEANUP_DIR" "$atomic_worktree" \
	feature/atomic aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$OWNER_PID" atomic-session \
	'2026-08-01T00:00:00Z'; then
	atomic_result=0
else
	atomic_result=$?
fi
_full_loop_receipt_lock_release
export PATH="$original_path"
unset AIDEVOPS_TEST_REAL_MV AIDEVOPS_TEST_RECEIPT_MV_COUNTER AIDEVOPS_TEST_FAIL_RECEIPT_PUBLICATION_AT

if [[ "$atomic_result" -eq 0 ]]; then
	printf 'FAIL second receipt publication failure was accepted\n'
	exit 1
fi
cmp -s "$atomic_receipt_one" "${TEST_ROOT}/atomic-receipt-one.original"
cmp -s "$atomic_receipt_two" "${TEST_ROOT}/atomic-receipt-two.original"
jq -e '(.receipt_disposition // null) == null' "$atomic_receipt_one" "$atomic_receipt_two" >/dev/null
for atomic_transaction in "$AIDEVOPS_FULL_LOOP_CLEANUP_DIR"/.recreated-receipts.*; do
	[[ -e "$atomic_transaction" || -L "$atomic_transaction" ]] || continue
	printf 'FAIL failed receipt publication left transaction state: %s\n' "$atomic_transaction"
	exit 1
done
printf 'PASS multi-receipt publication failure restores every original receipt\n'

recovery_transaction="${AIDEVOPS_FULL_LOOP_CLEANUP_DIR}/.recreated-receipts.recovery-fixture"
mkdir -p "${recovery_transaction}/backup" "${recovery_transaction}/staged" \
	"${recovery_transaction}/publish" "${recovery_transaction}/restore"
printf '%s\n' "$_FULL_LOOP_RECREATED_RECEIPT_TRANSACTION_SCHEMA" >"${recovery_transaction}/schema"
for recovery_receipt in "$atomic_receipt_one" "$atomic_receipt_two"; do
	recovery_name="${recovery_receipt##*/}"
	cp "$recovery_receipt" "${recovery_transaction}/backup/${recovery_name}"
	jq '.receipt_disposition = {state:"INTERRUPTED_TEST_PUBLICATION"}' "$recovery_receipt" \
		>"${recovery_transaction}/staged/${recovery_name}"
done
: >"${recovery_transaction}/state.prepared"
cp "${recovery_transaction}/staged/${atomic_receipt_one##*/}" "$atomic_receipt_one"
jq -e '.receipt_disposition.state == "INTERRUPTED_TEST_PUBLICATION"' "$atomic_receipt_one" >/dev/null
selected_after_recovery=$(full_loop_cleanup_receipt_for_worktree "$atomic_worktree")
[[ -n "$selected_after_recovery" ]]
cmp -s "$atomic_receipt_one" "${TEST_ROOT}/atomic-receipt-one.original"
cmp -s "$atomic_receipt_two" "${TEST_ROOT}/atomic-receipt-two.original"
[[ ! -e "$recovery_transaction" && ! -L "$recovery_transaction" ]]
printf 'PASS lock acquisition recovers an interrupted prepared receipt transaction\n'

receipt_two=$(full_loop_write_cleanup_deferred example/repo 102 "${TEST_ROOT}/worktree-two" feature/two \
	"$OWNER_PID" session-two not-requested)
full_loop_transition_cleanup_receipt "$receipt_two" "$_FULL_LOOP_CLEANUP_LEASED" "$$"
cp "$receipt_two" "${TEST_ROOT}/receipt-leased.json"
if full_loop_write_cleanup_deferred example/repo 102 "${TEST_ROOT}/worktree-two" feature/two \
	"$OWNER_PID" session-two not-requested >/dev/null; then
	printf 'FAIL leased receipt was overwritten by receipt replay\n'
	exit 1
fi
cmp -s "$receipt_two" "${TEST_ROOT}/receipt-leased.json"
printf 'PASS leased receipt rejects replay without mutation\n'
printf '[2026-07-21T00:00:01Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' \
	"${TEST_ROOT}/worktree-two" >>"$AIDEVOPS_CLEANUP_LOG"
rm -rf "${TEST_ROOT}/worktree-two"
full_loop_reconcile_cleanup_receipts
jq -e '.resource_cleanup_state == "CLEANED"' "$receipt_two" >/dev/null
printf 'PASS audit reconciliation repairs a crash between removal and CLEANED persistence\n'

SCRIPT_DIR="$SCRIPTS_DIR"
export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/release-receipts"
# shellcheck source=../full-loop-helper-state.sh
source "${SCRIPTS_DIR}/full-loop-helper-state.sh"
expected_sources='28993@23667f1e351981e4e6ecfeb03dd4c7a52ecfd100,29006@da5fec68b034be737bbf1f8d7ccf05a8dbf64a10,29010@4745adde8faa4a92aa4e27763c52e2c1a02a5e76,29013@de9e0b1b76f8dbeb97ccb8d2c3d57020b41adbd0'
observed_sources='29010@4745adde8faa4a92aa4e27763c52e2c1a02a5e76'
_full_loop_persist_release_authorization example/repo 29040 "$expected_sources"
if _full_loop_persist_release_authorization example/repo 29040 "$observed_sources" >/dev/null 2>&1; then
	printf 'FAIL retry replaced the persisted trusted release authorization set\n'
	exit 1
fi
[[ "$(_full_loop_read_release_authorization example/repo 29040)" == "$expected_sources" ]]
printf 'PASS retries reuse persisted release authorization and reject conflicting intent\n'
authorization_path=$(_full_loop_release_authorization_path example/repo 29040)
cp "$authorization_path" "${TEST_ROOT}/authorization-original.json"
expanded_sources="${expected_sources},29014@1111111111111111111111111111111111111111"
_full_loop_expand_release_authorization_for_aggregate example/repo 29040 "$expected_sources" "$expanded_sources"
[[ "$(_full_loop_read_release_authorization example/repo 29040)" == "$expanded_sources" ]]
_full_loop_restore_release_authorization_after_aggregate example/repo 29040 "$expanded_sources" "$expected_sources"
[[ "$(_full_loop_read_release_authorization example/repo 29040)" == "$expected_sources" ]]
cmp -s "$authorization_path" "${TEST_ROOT}/authorization-original.json"
if _full_loop_expand_release_authorization_for_aggregate example/repo 29040 "$expected_sources" "$observed_sources"; then
	printf 'FAIL aggregate recovery narrowed trusted release authorization\n'
	exit 1
fi
printf 'PASS reviewed aggregate recovery expands and transactionally restores authorization\n'
_full_loop_write_release_authorization_gap_evidence example/repo 29010 "$expected_sources" "$observed_sources" \
	1901024bf5b675e4c6b680a801ea402b75f1f355 0050022840d6ab7df25608a8a16e50b54e12efec \
	'published tag omitted explicitly authorized sources'
gap_path=$(_full_loop_release_evidence_path example/repo 29010 authorization-gap)
jq -e '
	.status == "authorization-gap"
	and (.expected_sources | length) == 4
	and (.observed_sources | length) == 1
	and .terminal_cleanup_evidence == false
' "$gap_path" >/dev/null
mkdir -p "${TEST_ROOT}/gap-worktree"
gap_cleanup_receipt=$(full_loop_write_cleanup_deferred example/repo 29010 "${TEST_ROOT}/gap-worktree" \
	feature/gap "$OWNER_PID" session-gap pending)
cp "$gap_cleanup_receipt" "${TEST_ROOT}/gap-cleanup-original.json"
if full_loop_update_cleanup_release_status example/repo 29010 authorization-gap >/dev/null 2>&1; then
	printf 'FAIL authorization-gap evidence became a terminal cleanup status\n'
	exit 1
fi
cmp -s "$gap_cleanup_receipt" "${TEST_ROOT}/gap-cleanup-original.json"
[[ ! -f "${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/example_repo-29010.status" ]]
printf 'PASS authorization-gap evidence remains detached from terminal cleanup receipts\n'

# GH#33627: finalization removes only a verified legacy marker; native manual
# removal still owns all dirty-state, lock, activity and archive safeguards.
(
	export HOME="${TEST_ROOT}/marker-home"
	export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="${TEST_ROOT}/marker-receipts"
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/marker-release-receipts"
	export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/marker-cleanup.log"
	export AIDEVOPS_SESSION_ID="marker-session"
	export WORKTREE_REGISTRY_DIR="${TEST_ROOT}/marker-registry"
	export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
	marker_repo="${TEST_ROOT}/marker-repo"
	marker_worktree="${TEST_ROOT}/marker-linked"
	mkdir -p "$HOME" "$marker_repo"
	/usr/bin/git -C "$marker_repo" init -q -b main
	/usr/bin/git -C "$marker_repo" config user.name Test
	/usr/bin/git -C "$marker_repo" config user.email test@example.invalid
	/usr/bin/git -C "$marker_repo" config commit.gpgsign false
	printf 'seed\n' >"${marker_repo}/README.md"
	/usr/bin/git -C "$marker_repo" add README.md
	/usr/bin/git -C "$marker_repo" commit -q -m seed
	/usr/bin/git -C "$marker_repo" remote add origin git@github.com:example/repo.git
	/usr/bin/git -C "$marker_repo" worktree add -q -b feature/marker "$marker_worktree"
	# shellcheck source=../shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
	# shellcheck source=../full-loop-helper-merge.sh
	source "${SCRIPT_DIR}/full-loop-helper-merge.sh"
	marker_head=$(/usr/bin/git -C "$marker_worktree" rev-parse HEAD)
	# Supply only GitHub's exact merged PR metadata; local identity resolution,
	# receipt finalization and targeted removal use the production code paths.
	gh() {
		jq -n --arg head "$marker_head" '{state:"MERGED", mergedAt:"2026-10-05T00:00:00Z",
			mergeCommit:{oid:$head}, headRefName:"feature/marker", headRefOid:$head,
			headRepository:{nameWithOwner:"example/repo"}, isCrossRepository:false}'
		return 0
	}
	# Keep nested Bash cleanup helpers offline too.
	export marker_head
	export -f gh
	marker_receipt=$(full_loop_write_cleanup_deferred example/repo 106 "$marker_worktree" feature/marker \
		"$$" marker-session not-requested FINALIZATION_PENDING)
	_full_loop_write_release_receipt example/repo 106 not-requested
	mkdir -p "${marker_worktree}/.agents"
	marker_path="${marker_worktree}/.agents/.full-loop-cleanup-deferred"
	printf '%s\n' "$$" >"$marker_path"
	cd "$marker_worktree"
	if /usr/bin/git -C "$marker_repo" worktree remove "$marker_worktree" >/dev/null 2>&1; then
		printf 'FAIL native Git accepted marker-only dirty state before finalization\n'
		exit 1
	fi
	cp "$marker_receipt" "${TEST_ROOT}/marker-pending.json"
	if _full_loop_retire_finalized_cleanup_marker example/repo 106 not-requested; then
		printf 'FAIL pending receipt retired the marker\n'
		exit 1
	fi
	[[ -f "$marker_path" ]]
	full_loop_finalize_cleanup_receipt example/repo 106 not-requested
	cp "$marker_receipt" "${TEST_ROOT}/marker-complete.json"
	for marker_conflict in \
		'.schema_version = 99' '.repository = "wrong/repo"' '.pr_number = 999' \
		'.worktree = "/wrong/worktree"' '.branch = "feature/wrong"' \
		'.owner.pid = 99999999' '.owner.session = "wrong-session"' \
		'.owner.process_identity = "wrong-generation"' '.release_status = "pending"' \
		'.resource_cleanup_state = "CLEANUP_LEASED"' '.cleanup_lease.state = "acquired"'; do
		jq "$marker_conflict" "${TEST_ROOT}/marker-complete.json" >"$marker_receipt"
		if _full_loop_retire_finalized_cleanup_marker example/repo 106 not-requested; then
			printf 'FAIL conflicting marker evidence was retired: %s\n' "$marker_conflict"
			exit 1
		fi
		[[ -f "$marker_path" ]]
	done
	printf '{invalid-json\n' >"$marker_receipt"
	if _full_loop_retire_finalized_cleanup_marker example/repo 106 not-requested; then exit 1; fi
	rm "$marker_receipt"
	if _full_loop_retire_finalized_cleanup_marker example/repo 106 not-requested; then exit 1; fi
	cp "${TEST_ROOT}/marker-complete.json" "$marker_receipt"
	printf '%s\nextra\n' "$$" >"$marker_path"
	if _full_loop_retire_finalized_cleanup_marker example/repo 106 not-requested; then exit 1; fi
	rm "$marker_path"
	printf '%s\n' "$$" >"${TEST_ROOT}/marker-symlink-target"
	ln -s "${TEST_ROOT}/marker-symlink-target" "$marker_path"
	if _full_loop_retire_finalized_cleanup_marker example/repo 106 not-requested; then exit 1; fi
	[[ -L "$marker_path" && -f "${TEST_ROOT}/marker-symlink-target" ]]
	rm "$marker_path"
	printf '%s\n' "$$" >"$marker_path"
	marker_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	if _full_loop_retire_finalized_cleanup_marker example/repo 106 not-requested; then exit 1; fi
	marker_head=$(/usr/bin/git rev-parse HEAD)
	printf 'PASS pending, missing, malformed, mismatched and symlink marker evidence remains protected\n'
	cp "${TEST_ROOT}/marker-pending.json" "$marker_receipt"
	cmd_finalize_receipt 106 example/repo
	[[ ! -e "$marker_path" && -z "$(/usr/bin/git status --porcelain)" ]]
	cmd_finalize_receipt 106 example/repo
	jq -e '.executor_completion_state == "COMPLETE" and .resource_cleanup_state == "CLEANUP_DEFERRED"' \
		"$marker_receipt" >/dev/null
	# Finalization is not permission to delete unrelated data or locked worktrees.
	cd "$marker_repo"
	# Reuse the existing offline process-inventory seam. Host /proc visibility is
	# not deterministic in restricted runners; the real guard consumes this list.
	# shellcheck source=../worktree-helper.sh
	source "${SCRIPT_DIR}/worktree-helper.sh" help >/dev/null
	fixture_cwd="$marker_worktree"
	capture_worktree_process_cwds() {
		printf '%s\n' "$fixture_cwd"
		return 0
	}
	if cmd_remove "$marker_worktree" >/dev/null 2>&1; then exit 1; fi
	[[ -d "$marker_worktree" ]]
	fixture_cwd="$marker_repo"
	printf 'modified\n' >"${marker_worktree}/README.md"
	export AIDEVOPS_WORKTREE_TRASH_ROOT="${TEST_ROOT}/marker-modified-archive"
	if cmd_remove "$marker_worktree" >/dev/null 2>&1; then exit 1; fi
	[[ "$(/usr/bin/git -C "$marker_worktree" diff --name-only)" == "README.md" ]]
	/usr/bin/git -C "$marker_worktree" restore -- README.md
	printf 'keep\n' >"${marker_worktree}/unrelated.txt"
	export AIDEVOPS_WORKTREE_TRASH_ROOT="${TEST_ROOT}/marker-untracked-archive"
	if cmd_remove "$marker_worktree" >/dev/null 2>&1; then exit 1; fi
	[[ -f "${marker_worktree}/unrelated.txt" ]]
	rm "${marker_worktree}/unrelated.txt"
	/usr/bin/git -C "$marker_repo" worktree lock "$marker_worktree"
	if cmd_remove "$marker_worktree" >/dev/null 2>&1; then exit 1; fi
	[[ -d "$marker_worktree" ]]
	/usr/bin/git -C "$marker_repo" worktree unlock "$marker_worktree"
	export AIDEVOPS_WORKTREE_TRASH_ROOT="${TEST_ROOT}/marker-clean-archive"
	if ! cmd_remove "$marker_worktree"; then
		/usr/bin/git -C "$marker_worktree" status --short
		printf 'FAIL finalized marker-only manual removal\n'
		exit 1
	fi
	[[ ! -e "$marker_worktree" ]]
	jq -e '.resource_cleanup_state == "CLEANED" and .cleanup_lease.state == "released"' "$marker_receipt" >/dev/null
	printf 'PASS finalized marker-only worktree removes without force and records durable cleanup\n'
)

# GH#33890: merge cleanup records a same-repository alias (local repair branch
# at the exact PR head). Finalization must retire that marker, while adoption
# stays strict and foreign or mismatched evidence still keeps the marker.
(
	export HOME="${TEST_ROOT}/alias-home"
	export AIDEVOPS_FULL_LOOP_CLEANUP_DIR="${TEST_ROOT}/alias-receipts"
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/alias-release-receipts"
	export AIDEVOPS_CLEANUP_LOG="${TEST_ROOT}/alias-cleanup.log"
	export AIDEVOPS_SESSION_ID="alias-session"
	export WORKTREE_REGISTRY_DIR="${TEST_ROOT}/alias-registry"
	export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
	alias_repo="${TEST_ROOT}/alias-repo"
	alias_worktree="${TEST_ROOT}/alias-linked"
	mkdir -p "$HOME" "$alias_repo"
	/usr/bin/git -C "$alias_repo" init -q -b main
	/usr/bin/git -C "$alias_repo" config user.name Test
	/usr/bin/git -C "$alias_repo" config user.email test@example.invalid
	/usr/bin/git -C "$alias_repo" config commit.gpgsign false
	printf 'seed\n' >"${alias_repo}/README.md"
	/usr/bin/git -C "$alias_repo" add README.md
	/usr/bin/git -C "$alias_repo" commit -q -m seed
	/usr/bin/git -C "$alias_repo" remote add origin git@github.com:example/repo.git
	/usr/bin/git -C "$alias_repo" worktree add -q -b feature/alias-repair "$alias_worktree"
	# shellcheck source=../shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
	# shellcheck source=../full-loop-helper-merge.sh
	source "${SCRIPT_DIR}/full-loop-helper-merge.sh"
	alias_head=$(/usr/bin/git -C "$alias_worktree" rev-parse HEAD)
	alias_head_repo="example/repo"
	# The PR head ref differs from the local branch: this is the alias case.
	gh() {
		jq -n --arg head "$alias_head" --arg head_repo "$alias_head_repo" '{state:"MERGED",
			mergedAt:"2026-10-07T00:00:00Z", mergeCommit:{oid:$head}, headRefName:"feature/alias",
			headRefOid:$head, headRepository:{nameWithOwner:$head_repo}, isCrossRepository:false}'
		return 0
	}
	export alias_head alias_head_repo
	export -f gh
	cd "$alias_worktree"
	if _merge_fresh_adopted_worktree_cleanup_target 107 example/repo >/dev/null; then
		printf 'FAIL adoption accepted a renamed local branch\n'
		exit 1
	fi
	alias_target=$(_merge_fresh_retirement_worktree_cleanup_target 107 example/repo)
	[[ "$alias_target" == "$(/usr/bin/git rev-parse --show-toplevel)"$'\t'"feature/alias-repair"$'\t'"0" ]] || {
		printf 'FAIL retirement resolver did not return the recorded alias target: %s\n' "$alias_target"
		exit 1
	}
	# Record exactly what merge cleanup records for the alias target.
	alias_receipt=$(full_loop_write_cleanup_deferred example/repo 107 "$(/usr/bin/git rev-parse --show-toplevel)" \
		feature/alias-repair "$$" alias-session not-requested FINALIZATION_PENDING)
	_full_loop_write_release_receipt example/repo 107 not-requested
	mkdir -p .agents
	alias_marker="${alias_worktree}/.agents/.full-loop-cleanup-deferred"
	printf '%s\n' "$$" >"$alias_marker"
	# Reproduce the pre-fix stuck state: receipt COMPLETE, marker still present.
	full_loop_finalize_cleanup_receipt example/repo 107 not-requested
	cp "$alias_receipt" "${TEST_ROOT}/alias-complete.json"
	jq '.branch = "feature/alias"' "${TEST_ROOT}/alias-complete.json" >"$alias_receipt"
	if _full_loop_retire_finalized_cleanup_marker example/repo 107 not-requested; then
		printf 'FAIL alias marker retired against a receipt recording another branch\n'
		exit 1
	fi
	[[ -f "$alias_marker" ]]
	cp "${TEST_ROOT}/alias-complete.json" "$alias_receipt"
	alias_head_repo="fork/repo"
	if _full_loop_retire_finalized_cleanup_marker example/repo 107 not-requested; then
		printf 'FAIL alias marker retired for a cross-repository PR head\n'
		exit 1
	fi
	[[ -f "$alias_marker" ]]
	alias_head_repo="example/repo"
	printf 'PASS alias adoption stays strict; mismatched branch and foreign head keep the marker\n'
	if ! cmd_finalize_receipt 107 example/repo; then
		printf 'FAIL finalize-receipt retry did not retire the recorded alias marker\n'
		exit 1
	fi
	[[ ! -e "$alias_marker" && -z "$(/usr/bin/git status --porcelain)" ]]
	cmd_finalize_receipt 107 example/repo
	jq -e '.executor_completion_state == "COMPLETE" and .resource_cleanup_state == "CLEANUP_DEFERRED"
		and .branch == "feature/alias-repair"' "$alias_receipt" >/dev/null
	printf 'PASS finalize-receipt retires the recorded alias marker and retries idempotently\n'
)

exit 0
