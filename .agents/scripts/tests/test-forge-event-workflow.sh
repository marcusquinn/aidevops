#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
WORKFLOW="${REPO_ROOT}/.github/workflows/issue-sync-reusable.yml"
SELF_CALLER="${REPO_ROOT}/.github/workflows/issue-sync.yml"
CALLER_TEMPLATE="${REPO_ROOT}/.agents/templates/workflows/issue-sync-caller.yml"
HELPER="${SCRIPT_DIR}/../forge-event-helper.sh"
STATE_HELPER="${SCRIPT_DIR}/../forge-coordinator-state-helper.sh"

python3 - "$WORKFLOW" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as stream:
    workflow = yaml.safe_load(stream)
jobs = workflow["jobs"]
assert "forge-event" in jobs
assert {"sync-on-push", "sync-on-issue", "manual-sync", "sync-on-pr-merge", "label-pr", "check-issue-link", "guard-persistent-issues", "label-closure-reason"} <= set(jobs)
normal = yaml.safe_dump(jobs["forge-event"])
assert "forge-event-helper.sh" in normal
assert "forge-event-mapping-helper.sh" in normal
assert "task-publication-worker-helper.sh" in normal
assert "forge-coordinator-state-helper.sh" in normal
assert "upload-artifact" in normal
PY

for caller in "$SELF_CALLER" "$CALLER_TEMPLATE"; do
	grep -q 'types: \[opened, edited, assigned, closed, reopened\]' "$caller"
	grep -q 'types: \[opened, edited, closed, reopened\]' "$caller"
	grep -q 'subject_id:' "$caller"
	grep -q 'cursor:' "$caller"
	grep -q 'task_id:' "$caller"
done

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "${test_root}/scripts"
cp "$HELPER" "${test_root}/scripts/forge-event-helper.sh"
cat >"${test_root}/scripts/task-coordinator.mjs" <<'STUB'
#!/usr/bin/env node
import { writeFileSync } from "node:fs";
writeFileSync(process.env.FORGE_EVENT_ARGS_FILE, `${process.argv.slice(2).join(" ")}\n`);
STUB
chmod +x "${test_root}/scripts/task-coordinator.mjs"

args_file="${test_root}/args"
FORGE_EVENT_ARGS_FILE="$args_file" EVENT_NAME=issues EVENT_ACTION=assigned EVENT_SUBJECT_ID=I_42 \
	EVENT_CURSOR=2026-07-12T12:00:00Z EVENT_OPERATION_ID=delivery-42 EVENT_DELIVERY_ID=delivery-42 \
	EVENT_CURSOR_TIEBREAKER=run-42 REPOSITORY_ID=R_1 REPOSITORY_PATH="$test_root" \
	REPOSITORY_SLUG=owner/repo bash "${test_root}/scripts/forge-event-helper.sh"
grep -q -- '--repository-id R_1' "$args_file"
grep -q -- '--event-kind issue --action assigned --subject-id I_42' "$args_file"
grep -q -- '--delivery-id delivery-42 --cursor-tiebreaker run-42' "$args_file"

FORGE_EVENT_ARGS_FILE="$args_file" EVENT_NAME=pull_request_target EVENT_ACTION=closed EVENT_MERGED=true \
	EVENT_SUBJECT_ID=PR_7 EVENT_CURSOR=2026-07-12T13:00:00Z EVENT_OPERATION_ID=delivery-7 \
	EVENT_DELIVERY_ID=delivery-7 EVENT_CURSOR_TIEBREAKER=run-7 \
	REPOSITORY_ID=R_1 REPOSITORY_SLUG=owner/repo bash "${test_root}/scripts/forge-event-helper.sh"
grep -q -- '--event-kind pull_request --action merged --subject-id PR_7' "$args_file"

# Artifact restore selects the newest repository-scoped state and logs exact API calls.
mkdir -p "${test_root}/bin" "${test_root}/state"
cat >"${test_root}/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALL_LOG"
if [[ "$*" == *"actions/artifacts?per_page=100"* ]]; then
	if [[ "${GH_ARTIFACT_FIXTURE:-pages}" == "malformed" ]]; then
		printf '22\n23\n'
	else
		[[ "$*" == *'sort_by([.created_at, .id])'* ]]
		[[ "$*" == *'.expired // false'* ]]
		printf '24\n'
	fi
	exit 0
fi
[[ "$*" != *$'\n'* ]] || exit 1
printf 'fixture archive'
GH
cat >"${test_root}/bin/unzip" <<'UNZIP'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALL_LOG"
printf 'durable-db\n' >"${@: -1}/tasks.db"
UNZIP
chmod +x "${test_root}/bin/gh" "${test_root}/bin/unzip"
GH_CALL_LOG="${test_root}/api.log" PATH="${test_root}/bin:/usr/bin:/bin" bash "$STATE_HELPER" restore "${test_root}/state" owner/repo R_1
[[ "$(cat "${test_root}/state/tasks.db")" == "durable-db" ]]
grep -q 'repos/owner/repo/actions/artifacts?per_page=100' "${test_root}/api.log"
grep -q -- '--paginate --slurp' "${test_root}/api.log"
grep -q 'repos/owner/repo/actions/artifacts/24/zip' "${test_root}/api.log"
[[ "$(grep -c '/zip' "${test_root}/api.log")" -eq 1 ]]

# A malformed multi-line selector result must fail before URL construction.
: >"${test_root}/api.log"
if GH_ARTIFACT_FIXTURE=malformed GH_CALL_LOG="${test_root}/api.log" PATH="${test_root}/bin:/usr/bin:/bin" \
	bash "$STATE_HELPER" restore "${test_root}/state" owner/repo R_1 2>"${test_root}/restore-error"; then
	printf 'FAIL malformed artifact ID unexpectedly restored\n' >&2
	exit 1
fi
grep -q 'Invalid coordinator artifact ID' "${test_root}/restore-error"
if grep -q '/zip' "${test_root}/api.log"; then
	printf 'FAIL malformed artifact ID reached the download endpoint\n' >&2
	exit 1
fi

printf 'PASS forge event workflow is targeted, repository-bound, and repair scans are manual only\n'
