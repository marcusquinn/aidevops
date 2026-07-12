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

python3 - "$WORKFLOW" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as stream:
    workflow = yaml.safe_load(stream)
jobs = workflow["jobs"]
assert set(jobs) == {"forge-event", "cursor-reconciliation"}
normal = yaml.safe_dump(jobs["forge-event"])
assert "forge-event-helper.sh" in normal
for forbidden in ("issue list", "state=open", "state=closed", "git commit", "git reset", "git checkout"):
    assert forbidden not in normal, forbidden
repair = jobs["cursor-reconciliation"]
assert "workflow_dispatch" in repair["if"]
assert repair["timeout-minutes"] <= 10
PY

for caller in "$SELF_CALLER" "$CALLER_TEMPLATE"; do
	grep -q 'types: \[opened, edited, assigned, closed, reopened\]' "$caller"
	grep -q 'types: \[opened, edited, closed, reopened\]' "$caller"
	grep -q 'subject_id:' "$caller"
	grep -q 'cursor:' "$caller"
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
	EVENT_CURSOR=2026-07-12T12:00:00Z EVENT_OPERATION_ID=delivery-42 REPOSITORY_ID=R_1 \
	REPOSITORY_SLUG=owner/repo bash "${test_root}/scripts/forge-event-helper.sh"
grep -q -- '--repository-id R_1' "$args_file"
grep -q -- '--event-kind issue --action assigned --subject-id I_42' "$args_file"

FORGE_EVENT_ARGS_FILE="$args_file" EVENT_NAME=pull_request_target EVENT_ACTION=closed EVENT_MERGED=true \
	EVENT_SUBJECT_ID=PR_7 EVENT_CURSOR=2026-07-12T13:00:00Z EVENT_OPERATION_ID=delivery-7 \
	REPOSITORY_ID=R_1 REPOSITORY_SLUG=owner/repo bash "${test_root}/scripts/forge-event-helper.sh"
grep -q -- '--event-kind pull_request --action merged --subject-id PR_7' "$args_file"

printf 'PASS forge event workflow is targeted, repository-bound, and repair scans are manual only\n'
