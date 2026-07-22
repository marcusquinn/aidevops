#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MAPPING_HELPER="${SCRIPT_DIR}/../forge-event-mapping-helper.sh"
COORDINATOR="${SCRIPT_DIR}/../task-coordinator.mjs"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_TASK_COORDINATOR_DB="${TEST_ROOT}/coordinator.db"
printf '%s\n' '- [ ] t42 mapped fixture ref:GH#7' >"${TEST_ROOT}/TODO.md"
mkdir "${TEST_ROOT}/bin"
cat >"${TEST_ROOT}/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALL_LOG"
printf '{"id":"I_7","number":7,"state":"OPEN","updatedAt":"%s"}\n' "${GH_UPDATED_AT:-2026-07-12T15:00:00Z}"
GH
chmod +x "${TEST_ROOT}/bin/gh"
export GH_CALL_LOG="${TEST_ROOT}/api.log"

(
	cd "$TEST_ROOT"
	env PATH="${TEST_ROOT}/bin:$(dirname "$(command -v node)"):/usr/bin:/bin" EVENT_NAME=issues EVENT_DISPLAY_NUMBER=7 \
		EVENT_SUBJECT_ID=I_7 REPOSITORY_ID=R_7 REPOSITORY_SLUG=owner/repo bash "$MAPPING_HELPER"
)
[[ "$(node "$COORDINATOR" resolve-issue --task-id t42 --repository-id R_7 | jq -r '.issueId')" == "I_7" ]]
[[ "$(grep -c '^issue view 7 --repo owner/repo --json id,number,state,updatedAt$' "$GH_CALL_LOG")" == "1" ]]
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT repository_id FROM legacy_task_adoptions WHERE task_id='t42';")" == "R_7" ]]

# Duplicate mapping is idempotent, while the adopted task identity cannot be
# reused by another immutable repository identity.
(
	cd "$TEST_ROOT"
	env PATH="${TEST_ROOT}/bin:$(dirname "$(command -v node)"):/usr/bin:/bin" EVENT_NAME=issues EVENT_DISPLAY_NUMBER=7 \
		EVENT_SUBJECT_ID=I_7 REPOSITORY_ID=R_7 REPOSITORY_SLUG=owner/repo bash "$MAPPING_HELPER"
)
[[ "$(sqlite3 "$AIDEVOPS_TASK_COORDINATOR_DB" "SELECT COUNT(*) FROM tasks WHERE task_id='t42';")" == "1" ]]

if (
	cd "$TEST_ROOT"
	env PATH="${TEST_ROOT}/bin:$(dirname "$(command -v node)"):/usr/bin:/bin" GH_UPDATED_AT=2026-07-12T14:00:00Z \
		EVENT_NAME=issues EVENT_DISPLAY_NUMBER=7 EVENT_SUBJECT_ID=I_7 REPOSITORY_ID=R_7 \
		REPOSITORY_SLUG=owner/repo bash "$MAPPING_HELPER"
); then
	printf 'FAIL stale issue mapping was adopted\n' >&2
	exit 1
fi
[[ "$(node "$COORDINATOR" resolve-issue --task-id t42 --repository-id R_7 | jq -r '.stateCursor')" == "2026-07-12T15:00:00.000Z" ]]
if (
	cd "$TEST_ROOT"
	env PATH="${TEST_ROOT}/bin:$(dirname "$(command -v node)"):/usr/bin:/bin" EVENT_NAME=issues EVENT_DISPLAY_NUMBER=7 \
		EVENT_SUBJECT_ID=I_7 REPOSITORY_ID=R_other REPOSITORY_SLUG=owner/other bash "$MAPPING_HELPER"
); then
	printf 'FAIL adopted legacy task crossed repository identities\n' >&2
	exit 1
fi

if (
	cd "$TEST_ROOT"
	env PATH="${TEST_ROOT}/bin:$(dirname "$(command -v node)"):/usr/bin:/bin" EVENT_NAME=issues EVENT_DISPLAY_NUMBER=7 \
		EVENT_SUBJECT_ID=I_attacker REPOSITORY_ID=R_7 REPOSITORY_SLUG=owner/repo bash "$MAPPING_HELPER"
); then
	printf 'FAIL mismatched immutable subject was bound\n' >&2
	exit 1
fi

printf 'PASS event mapping requires repository projection and immutable API identity\n'
