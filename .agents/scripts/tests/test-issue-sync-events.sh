#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COORDINATOR="${SCRIPT_DIR}/../task-coordinator.mjs"
EVENT_HELPER="${SCRIPT_DIR}/../issue-sync-event-helper.mjs"
FIXTURES="${SCRIPT_DIR}/fixtures/issue-sync-events"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/coordinator.db"

issue_task=$(node "$COORDINATOR" allocate --operation-id fixture-issue-task --legacy-id t4101 | jq -r '.tasks[0].taskId')
pr_task=$(node "$COORDINATOR" allocate --operation-id fixture-pr-task --legacy-id t4102 | jq -r '.tasks[0].taskId')
other_task=$(node "$COORDINATOR" allocate --operation-id fixture-other-task --legacy-id t4103 | jq -r '.tasks[0].taskId')
reconcile_task=$(node "$COORDINATOR" allocate --operation-id fixture-reconcile-task --legacy-id t4104 | jq -r '.tasks[0].taskId')
node "$COORDINATOR" bind-issue --task-id "$issue_task" --repository-id R_fixture --repository-slug owner/repo --issue-id I_fixture_42 --display-number 42 >/dev/null
node "$COORDINATOR" bind-issue --task-id "$pr_task" --repository-id R_fixture --repository-slug owner/repo --role implementation --issue-id PR_fixture_7 --display-number 7 >/dev/null
node "$COORDINATOR" bind-issue --task-id "$other_task" --repository-id R_other --repository-slug owner/other --issue-id I_other_42 --display-number 42 >/dev/null
node "$COORDINATOR" bind-issue --task-id "$reconcile_task" --repository-id R_fixture --repository-slug owner/repo --issue-id I_fixture_88 --display-number 88 >/dev/null

ingest() {
	local event_name="$1"
	local action="$2"
	local fixture="$3"
	local delivery_id="${4:-}"
	local delivery_args=()
	if [[ -n "$delivery_id" ]]; then delivery_args=(--delivery-id "$delivery_id"); fi
	node "$EVENT_HELPER" ingest --event-name "$event_name" --action "$action" \
		--event-file "${FIXTURES}/${fixture}" --repository-id R_fixture \
		--repository-slug owner/repo --repository-path "$TEST_ROOT" "${delivery_args[@]}"
	return $?
}

opened=$(ingest issues opened issue-opened.json)
[[ "$(jq -r '.outcome' <<<"$opened")" == "applied" ]]
[[ "$(ingest issues opened issue-opened.json)" == "$opened" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(*) FROM forge_event_deliveries;')" == "1" ]]

for event in edited assigned closed reopened; do
	result=$(ingest issues "$event" "issue-${event}.json")
	[[ "$(jq -r '.taskId' <<<"$result")" == "$issue_task" ]]
	[[ "$(jq -r '.outcome' <<<"$result")" == "applied" ]]
done
merged=$(ingest pull_request closed pr-merged.json)
[[ "$(jq -r '.taskId' <<<"$merged")" == "$pr_task" ]]
[[ "$(jq -r '.action' <<<"$merged")" == "merged" ]]

# A late delivery is durable but cannot overwrite the newer reopened state.
late=$(ingest issues assigned issue-assigned.json late-assigned-delivery)
[[ "$(jq -r '.outcome' <<<"$late")" == "stale" ]]
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$issue_task" --repository-id R_fixture | jq -r '.syncMetadata.projection.state')" == "open" ]]
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$other_task" --repository-id R_other | jq -r '.syncMetadata | length')" == "0" ]]

# The immutable workflow repository context wins over every payload field.
if ingest issues closed cross-repository.json >/dev/null 2>&1; then
	printf 'FAIL cross-repository payload selected a target\n' >&2
	exit 1
fi

# Reusing one delivery ID with changed intent fails instead of mutating state.
ingest issues opened issue-opened.json fixed-delivery >/dev/null
if ingest issues edited issue-edited.json fixed-delivery >/dev/null 2>&1; then
	printf 'FAIL changed payload reused a delivery ID\n' >&2
	exit 1
fi

# Repair mode is explicit and bounded. It orders missed deliveries by cursor so
# the final projection converges even when the forge returns events out of order.
reconciled=$(node "$EVENT_HELPER" reconcile --events-file "${FIXTURES}/reconcile-events.json" \
	--max-events 10 --repository-id R_fixture --repository-slug owner/repo --repository-path "$TEST_ROOT")
[[ "$(jq -r '.bounded' <<<"$reconciled")" == "true" ]]
[[ "$(jq -r '.processed' <<<"$reconciled")" == "2" ]]
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$reconcile_task" --repository-id R_fixture | jq -r '.syncMetadata.projection.state')" == "open" ]]

# Applied issue/PR events flow through the serialized publication outbox; stale
# events and repository mismatches do not enqueue work.
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM publication_queue;")" == "8" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(DISTINCT task_id) FROM publication_intents;")" == "3" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT event_cursor FROM forge_reconciliation_cursors WHERE repository_id='R_fixture' AND object_id='I_fixture_42';")" == "2026-07-12T10:40:00.000Z" ]]

# The normal workflow job fetches only framework code and invokes no issue-list,
# checkout mutation, commit, or reset path. Bulk sync remains a manual repair.
python3 - "$REPO_ROOT/.github/workflows/issue-sync-reusable.yml" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
section = text.split("  targeted-event:\n", 1)[1].split("  sync-on-push:\n", 1)[0]
for forbidden in ("gh issue list", "issue-sync-helper.sh", "git commit", "git reset", "ref: main"):
    if forbidden in section:
        raise SystemExit(f"normal targeted event job contains forbidden path: {forbidden}")
if "issue-sync-event-helper.mjs ingest" not in section:
    raise SystemExit("targeted event helper is not wired into the reusable workflow")
PY

printf 'PASS targeted idempotent issue-sync event ingestion\n'
