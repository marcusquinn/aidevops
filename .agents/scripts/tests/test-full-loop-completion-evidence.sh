#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "${ROOT}/bin"
receipt_dir="${ROOT}/receipts"

cat >"${ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${COMPLETION_PR_STATE:-MERGED}" == "MERGED" ]]; then
	printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","mergeCommit":{"oid":"merge123"}}'
else
	printf '%s\n' '{"state":"OPEN","mergedAt":null,"mergeCommit":null}'
fi
exit 0
STUB
chmod +x "${ROOT}/bin/gh"

cat >"${ROOT}/release-runner.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${RELEASE_CALL_LOG:?}"
exit "${RELEASE_RUNNER_EXIT:-0}"
STUB
chmod +x "${ROOT}/release-runner.sh"

runner="${ROOT}/runner.sh"
cat >"$runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
source '${SCRIPTS_DIR}/shared-constants.sh'
[[ -z "\${BOLD+x}" ]] && BOLD=''
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
cmd_complete_after_cleanup "\$@"
RUNNER
chmod +x "$runner"

removed_path="${ROOT}/removed-worktree"
cleanup_log="${ROOT}/cleanup.log"
printf '[2026-07-11T00:00:01Z] [test] worktree-removed: %s — branch-merged — mode=permanent\n' "$removed_path" >"$cleanup_log"

state_runner="${ROOT}/state-runner.sh"
cat >"$state_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
print_phase() { return 0; }
is_headless() { return 1; }
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
mkdir -p "\$STATE_DIR"
RELEASE_INTENT="\${TEST_RELEASE_INTENT:-true}"
RELEASE_TYPE="\${TEST_RELEASE_TYPE:-patch}"
DEPLOYMENT_SCOPE="\${TEST_DEPLOYMENT_SCOPE:-incremental}"
RELEASE_STATUS="\${TEST_RELEASE_STATUS:-authorized}"
CURRENT_PHASE=pr-review
SAVED_PROMPT=test
PR_NUMBER=42
STARTED_AT=2026-07-11T00:00:00Z
save_state pr-review test 42 "\$STARTED_AT"
cmd_resume
load_state
printf '%s\n' "\$RELEASE_STATUS"
RUNNER
chmod +x "$state_runner"

: >"${ROOT}/release-calls.log"
flow_env=(AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_FULL_LOOP_REPO=marcusquinn/aidevops AIDEVOPS_FULL_LOOP_RELEASE_RUNNER="${ROOT}/release-runner.sh" RELEASE_CALL_LOG="${ROOT}/release-calls.log")
output=$(env "${flow_env[@]}" TEST_RELEASE_TYPE=minor TEST_DEPLOYMENT_SCOPE=full bash "$state_runner")
status="${output##*$'\n'}"
[[ "$status" == "published" ]]
grep -qx 'minor 42 full' "${ROOT}/release-calls.log"
grep -qx 'published' "${receipt_dir}/marcusquinn_aidevops-42.status"
printf 'PASS authorized lifecycle invokes release and persists published status\n'

: >"${ROOT}/release-calls.log"
output=$(env "${flow_env[@]}" TEST_RELEASE_INTENT=false TEST_RELEASE_STATUS=not-requested bash "$state_runner")
status="${output##*$'\n'}"
[[ "$status" == "not-requested" && ! -s "${ROOT}/release-calls.log" ]]
grep -qx 'not-requested' "${receipt_dir}/marcusquinn_aidevops-42.status"
printf 'PASS merge-only lifecycle persists skipped publication without invoking release\n'

if env "${flow_env[@]}" RELEASE_RUNNER_EXIT=1 bash "$state_runner" >/dev/null 2>&1; then
	printf 'FAIL failed release transition returned success\n'
	exit 1
fi
grep -qx 'failed' "${receipt_dir}/marcusquinn_aidevops-42.status"
printf 'PASS failed publication persists failed status and stops transition\n'

complete_runner="${ROOT}/complete-runner.sh"
cat >"$complete_runner" <<RUNNER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR='${SCRIPTS_DIR}'
STATE_DIR='${ROOT}/state'
STATE_FILE='${ROOT}/state/full-loop.state'
DEFAULT_MAX_TASK_ITERATIONS=50
DEFAULT_MAX_PREFLIGHT_ITERATIONS=5
DEFAULT_MAX_PR_ITERATIONS=20
HEADLESS=false
source '${SCRIPTS_DIR}/shared-constants.sh'
source '${SCRIPTS_DIR}/full-loop-helper-state.sh'
cmd_complete
RUNNER
chmod +x "$complete_runner"
if bash "$complete_runner" >/dev/null 2>&1; then
	printf 'FAIL release:failed allowed cleanup handoff\n'
	exit 1
fi
printf 'PASS release:failed blocks cleanup before worktree removal\n'

AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null || {
	printf 'FAIL complete merged and cleaned evidence was rejected\n'
	exit 1
}
printf 'PASS merged and cleaned evidence completes lifecycle\n'

printf '%s\n' not-requested >"${receipt_dir}/marcusquinn_aidevops-42.status"
AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" marcusquinn/aidevops >/dev/null || {
	printf 'FAIL merge-only aidevops lifecycle did not complete with release:not-requested\n'
	exit 1
}
printf 'PASS merge-only aidevops lifecycle skips publication evidence\n'

printf '%s\n' failed >"${receipt_dir}/marcusquinn_aidevops-42.status"
if AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$receipt_dir" AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" marcusquinn/aidevops >/dev/null; then
	printf 'FAIL release:failed lifecycle was accepted as complete\n'
	exit 1
fi
printf 'PASS release:failed keeps lifecycle open\n'

mkdir -p "$removed_path"
if AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL existing worktree was accepted as cleaned\n'
	exit 1
fi
printf 'PASS existing worktree keeps cleanup pending\n'
rm -rf "$removed_path"

if COMPLETION_PR_STATE=OPEN AIDEVOPS_CLEANUP_LOG="$cleanup_log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL open PR was accepted as complete\n'
	exit 1
fi
printf 'PASS open PR blocks lifecycle completion\n'

if AIDEVOPS_CLEANUP_LOG="${ROOT}/missing.log" PATH="${ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$runner" 42 "$removed_path" testorg/repo >/dev/null; then
	printf 'FAIL absent cleanup audit was accepted as complete\n'
	exit 1
fi
printf 'PASS absent cleanup audit blocks lifecycle completion\n'

exit 0
