#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COORDINATOR="${SCRIPT_DIR}/../task-coordinator.mjs"
RECONCILE="${SCRIPT_DIR}/../forge-event-reconcile-helper.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/coordinator.db"

task_id=$(node "$COORDINATOR" allocate --operation-id reconcile-task | jq -r '.tasks[0].taskId')
node "$COORDINATOR" bind-issue --task-id "$task_id" --repository-id R_reconcile --repository-slug owner/repo \
	--issue-id I_42 --display-number 42 --state-cursor 2026-07-12T10:00:00Z >/dev/null

mkdir "${TEST_ROOT}/bin"
cat >"${TEST_ROOT}/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALL_LOG"
printf '{"state":"closed","updated_at":"2026-07-12T15:00:00Z"}\n'
GH
chmod +x "${TEST_ROOT}/bin/gh"
export GH_CALL_LOG="${TEST_ROOT}/api.log"

env PATH="${TEST_ROOT}/bin:$(dirname "$(command -v node)"):/usr/bin:/bin" REPOSITORY_ID=R_reconcile REPOSITORY_SLUG=owner/repo \
	REPOSITORY_PATH="$TEST_ROOT" GITHUB_RUN_ID=90 GITHUB_RUN_ATTEMPT=1 AIDEVOPS_RECONCILE_MAX_ISSUES=1 \
	bash "$RECONCILE" audit
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(*) FROM forge_event_cursors;')" == "0" ]]

env PATH="${TEST_ROOT}/bin:$(dirname "$(command -v node)"):/usr/bin:/bin" REPOSITORY_ID=R_reconcile REPOSITORY_SLUG=owner/repo \
	REPOSITORY_PATH="$TEST_ROOT" GITHUB_RUN_ID=91 GITHUB_RUN_ATTEMPT=1 AIDEVOPS_RECONCILE_MAX_ISSUES=1 \
	bash "$RECONCILE" reconcile
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT transition_kind FROM forge_event_cursors;')" == "task.completed" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" 'SELECT COUNT(*) FROM publication_queue;')" == "1" ]]
[[ "$(grep -c '^api repos/owner/repo/issues/42$' "$GH_CALL_LOG")" == "2" ]]
if grep -q 'issue list' "$GH_CALL_LOG"; then
	printf 'FAIL reconciliation performed a broad issue scan\n' >&2
	exit 1
fi

printf 'PASS bounded cursor reconciliation uses mapped API targets and audit is read-only\n'
