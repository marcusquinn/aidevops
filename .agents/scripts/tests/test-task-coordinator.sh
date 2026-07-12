#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COORDINATOR="${SCRIPT_DIR}/../task-coordinator.mjs"
CLAIM="${SCRIPT_DIR}/../claim-task-id.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/coordinator.db"

# Multiprocess WAL allocation and offline uniqueness.
for i in $(seq 1 24); do
	node "$COORDINATOR" allocate --operation-id "parallel-${i}" --payload "{\"worker\":${i}}" >"${TEST_ROOT}/parallel-${i}.json" &
done
wait
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(DISTINCT task_id) FROM tasks;')" == "24" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT MAX(sequence) FROM tasks;')" == "24" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'PRAGMA journal_mode;')" == "wal" ]]
[[ "$(stat -f '%Lp' "$AIDEVOPS_TASK_COORDINATOR_DB" 2>/dev/null || stat -c '%a' "$AIDEVOPS_TASK_COORDINATOR_DB")" == "600" ]]

# Concurrent delivery of one operation returns one complete, identical result.
for i in $(seq 1 12); do
	node "$COORDINATOR" allocate --operation-id same-operation --payload '{"same":true}' >"${TEST_ROOT}/same-${i}.json" 2>"${TEST_ROOT}/same-${i}.err" &
done
wait
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM tasks WHERE created_operation_id='same-operation';")" == "1" ]]
same_expected=$(jq -cS . "${TEST_ROOT}/same-1.json")
[[ "$same_expected" != "{}" ]]
for i in $(seq 2 12); do
	[[ "$(jq -cS . "${TEST_ROOT}/same-${i}.json")" == "$same_expected" ]]
done
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT status FROM operations WHERE operation_id='same-operation';")" == "terminal" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT result_json FROM operations WHERE operation_id='same-operation';")" != "{}" ]]

# Idempotency and conflict preserve the original immutable task.
first=$(node "$COORDINATOR" allocate --operation-id idem --payload '{"value":1}')
again=$(node "$COORDINATOR" allocate --operation-id idem --payload '{"value":1}')
[[ "$first" == "$again" ]]
if node "$COORDINATOR" allocate --operation-id idem --payload '{"value":2}' >/dev/null 2>&1; then
	printf 'FAIL changed payload reused an operation ID\n' >&2
	exit 1
fi

# Crash before commit leaves no allocation; crash after commit replays the durable result.
before=$(printf '%s' "$first" | jq -r '.tasks[0].sequence')
if AIDEVOPS_TASK_COORDINATOR_TEST_CRASH=before-commit node "$COORDINATOR" allocate --operation-id crash-before >/dev/null 2>&1; then
	printf 'FAIL crash-before hook returned success\n' >&2
	exit 1
fi
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM operations WHERE operation_id='crash-before';")" == "0" ]]
if AIDEVOPS_TASK_COORDINATOR_TEST_CRASH=after-commit node "$COORDINATOR" allocate --operation-id crash-after >/dev/null 2>&1; then
	printf 'FAIL crash-after hook returned success\n' >&2
	exit 1
fi
crash_after=$(node "$COORDINATOR" allocate --operation-id crash-after)
[[ "$(printf '%s' "$crash_after" | jq '.tasks | length')" == "1" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM tasks WHERE created_operation_id='crash-after';")" == "1" ]]
after=$(node "$COORDINATOR" allocate --operation-id restart --payload '{}' | jq -r '.tasks[0].sequence')
[[ "$after" -gt "$before" ]]
node "$COORDINATOR" verify | jq -e '.ok == true' >/dev/null

# Strict identifiers, canonical legacy IDs, JSON object shape, and payload limits.
for invalid_args in \
	"--operation-id ../escape" \
	"--operation-id valid --legacy-id t001" \
	"--operation-id valid-array --payload []"; do
	# shellcheck disable=SC2086
	if node "$COORDINATOR" allocate $invalid_args >/dev/null 2>&1; then
		printf 'FAIL invalid allocation input accepted: %s\n' "$invalid_args" >&2
		exit 1
	fi
done
large_payload=$(printf 'x%.0s' $(seq 1 65536))
if node "$COORDINATOR" allocate --operation-id too-large --payload "{\"value\":\"${large_payload}\"}" >/dev/null 2>&1; then
	printf 'FAIL oversized payload accepted\n' >&2
	exit 1
fi

# Independent reinstall/clone state creates a new CSPRNG origin at the same sequence.
origin_one=$(node "$COORDINATOR" status | jq -r '.origin_id')
AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/clone.db" node "$COORDINATOR" allocate --operation-id clone >/dev/null
origin_two=$(AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/clone.db" node "$COORDINATOR" status | jq -r '.origin_id')
[[ "$origin_one" != "$origin_two" ]]

# Publication intent/attempt evidence reaches a durable terminal result.
task_id=$(printf '%s' "$first" | jq -r '.tasks[0].taskId')
intent=$(node "$COORDINATOR" publication-intent --operation-id publish-1 --task-id "$task_id" --payload '{"projection":"issue"}' | jq -r '.intentId')
node "$COORDINATOR" attempt --intent-id "$intent" --status retryable --evidence '{"timeout":true}' >/dev/null
node "$COORDINATOR" attempt --intent-id "$intent" --status published --evidence '{"marker":"verified"}' >/dev/null
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM terminal_evidence WHERE operation_id='publish-1';")" == "1" ]]
[[ "$(node "$COORDINATOR" publication-intent --operation-id publish-1 --task-id "$task_id" --payload '{"projection":"issue"}' | jq -r '.status')" == "published" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT json_extract(result_json,'$.status') FROM operations WHERE operation_id='publish-1';")" == "published" ]]

# Backups are integrity-checked; restore requires a newer fenced ownership epoch.
backup="${TEST_ROOT}/verified-backup.db"
sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" ".backup '$backup'"
fence=$(node "$COORDINATOR" status | jq -r '.fencing_token')
node "$COORDINATOR" transition --state read-only --fencing-token "$fence" --evidence '{"reason":"restore-test"}' >/dev/null
if node "$COORDINATOR" restore --backup "$backup" --registry-evidence '{}' --prior-epoch 1 --new-epoch 1 --fencing-token stale >/dev/null 2>&1; then
	printf 'FAIL stale restore epoch accepted\n' >&2
	exit 1
fi
if node "$COORDINATOR" restore --backup "$backup" --registry-evidence '{"cas":"winner","prior_revoked":true}' --prior-epoch 1 --new-epoch 2 --fencing-token restore-fence >/dev/null 2>&1; then
	printf 'FAIL incomplete registry evidence accepted\n' >&2
	exit 1
fi
node "$COORDINATOR" restore --backup "$backup" --registry-evidence '{"cas":"winner","prior_revoked":true,"fencing_token":"restore-fence","transfer_record_id":"transfer-1"}' --prior-epoch 1 --new-epoch 2 --fencing-token restore-fence --published-high-water 100 >/dev/null
[[ "$(node "$COORDINATOR" status | jq -r '.sequence')" == "100" ]]
[[ -n "$(ls "${TEST_ROOT}"/coordinator.db-backup-*-pre-restore.db)" ]]

# A real v1 schema migrates through v2 to v3 only after verified backups.
migration_db="${TEST_ROOT}/migration.db"
AIDEVOPS_TASK_COORDINATOR_DB="$migration_db" node "$COORDINATOR" status >/dev/null
sqlite3 "$migration_db" "DROP TABLE issue_mappings; ALTER TABLE operations DROP COLUMN result_hash; ALTER TABLE restore_controls DROP COLUMN backup_high_water; UPDATE coordinator_meta SET value='1' WHERE key='schema_version'; UPDATE migration_history SET version=1 WHERE version=3;"
AIDEVOPS_TASK_COORDINATOR_DB="$migration_db" node "$COORDINATOR" status >/dev/null
[[ "$(sqlite3 "$migration_db" "SELECT value FROM coordinator_meta WHERE key='schema_version';")" == "3" ]]
[[ "$(sqlite3 "$migration_db" "SELECT COUNT(*) FROM pragma_table_info('operations') WHERE name='result_hash';")" == "1" ]]
[[ -n "$(ls "${TEST_ROOT}"/migration.db-backup-*-pre-migrate-v2.db)" ]]
[[ -n "$(ls "${TEST_ROOT}"/migration.db-backup-*-pre-migrate-v3.db)" ]]

# Immutable task/repository identities isolate equal display numbers and allow
# one task to retain home, implementation, and upstream issue projections.
mapping_task=$(node "$COORDINATOR" allocate --operation-id mapping-task --payload '{}' | jq -r '.tasks[0].taskId')
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug owner/home \
	--role home --issue-id I_home --project-id P_home --display-number 42 --state-cursor cursor-home \
	--sync-metadata '{"state":"OPEN","source":"backfill"}' >/dev/null
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_impl --repository-slug owner/implementation \
	--role implementation --issue-id I_impl --display-number 42 --sync-metadata '{"state":"OPEN"}' >/dev/null
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_upstream --repository-slug upstream/project \
	--role upstream --issue-id I_upstream --display-number 42 >/dev/null
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_home | jq -r '.issueId')" == "I_home" ]]
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_impl | jq -r '.issueId')" == "I_impl" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM issue_mappings WHERE task_id='${mapping_task}';")" == "3" ]]

# A renamed slug updates display metadata without changing repository identity;
# conflicting issue identity or an unvalidated repository fails closed.
node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug renamed/home \
	--role home --issue-id I_home --display-number 42 >/dev/null
[[ "$(node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_home | jq -r '.repositorySlug')" == "renamed/home" ]]
if node "$COORDINATOR" bind-issue --task-id "$mapping_task" --repository-id R_home --repository-slug renamed/home \
	--role home --issue-id I_conflict --display-number 42 >/dev/null 2>&1; then
	printf 'FAIL conflicting issue mapping was accepted\n' >&2
	exit 1
fi
if node "$COORDINATOR" resolve-issue --task-id "$mapping_task" --repository-id R_missing >/dev/null 2>&1; then
	printf 'FAIL missing repository mapping resolved\n' >&2
	exit 1
fi

# Integration defaults to legacy, shadow is additive, and emission needs two gates.
if AIDEVOPS_TASK_COORDINATOR_MODE=namespaced bash "$CLAIM" --no-issue --title test >/dev/null 2>&1; then
	printf 'FAIL namespaced emission worked without explicit emission gate\n' >&2
	exit 1
fi
repo_fixture="${TEST_ROOT}/repo-fixture"
mkdir "$repo_fixture"
printf 'unchanged\n' >"${repo_fixture}/sentinel"
before_fixture=$(cksum "${repo_fixture}/sentinel")
dry_count=$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(*) FROM tasks;')
AIDEVOPS_TASK_COORDINATOR_MODE=namespaced AIDEVOPS_TASK_COORDINATOR_NAMESPACED_EMISSION_ENABLED=1 \
	bash "$CLAIM" --no-issue --dry-run --title test --repo-path "$repo_fixture" | grep -q '^task_id=tDRY_RUN$'
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(*) FROM tasks;')" == "$dry_count" ]]
namespaced=$(AIDEVOPS_TASK_COORDINATOR_MODE=namespaced AIDEVOPS_TASK_COORDINATOR_NAMESPACED_EMISSION_ENABLED=1 \
	bash "$CLAIM" --no-issue --count 3 --title test --repo-path "$repo_fixture")
printf '%s' "$namespaced" | grep -Eq '^task_id=to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]*$'
printf '%s' "$namespaced" | grep -Eq '^task_id_last=to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]*$'
printf '%s' "$namespaced" | grep -q '^task_count=3$'
[[ "$(cksum "${repo_fixture}/sentinel")" == "$before_fixture" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT value FROM coordinator_meta WHERE key='namespaced_emitted';")" == "1" ]]

# Shadow mode records the legacy identity but never replaces CAS output.
(
	SCRIPT_DIR="${SCRIPT_DIR}/.."
	log_info() { :; return 0; }
	log_warn() { :; return 0; }
	log_error() { :; return 0; }
	# shellcheck source=../claim-task-id-counter.sh
	source "${SCRIPT_DIR}/claim-task-id-counter.sh"
	AIDEVOPS_TASK_COORDINATOR_MODE=shadow AIDEVOPS_TASK_COORDINATOR_SHADOW_ENABLED=1 _task_coordinator_shadow_legacy 321 1
)
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM tasks WHERE task_id='t321';")" == "1" ]]

printf 'PASS task coordinator allocation, replay, recovery, restore, and integration gates\n'
