#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
RUNTIME_EVENTS="${SCRIPT_DIR}/../runtime-events.mjs"
WORKER_LAUNCH="${SCRIPT_DIR}/../pulse-dispatch-worker-launch.sh"
WORKER_LIFECYCLE="${SCRIPT_DIR}/../worker-lifecycle-common.sh"
WORKER_FAILURE="${SCRIPT_DIR}/../headless-runtime-failure.sh"
WORKER_RUNTIME="${SCRIPT_DIR}/../headless-runtime-worker.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_OBS_DB_OVERRIDE="${TEST_ROOT}/observability.db"
export AIDEVOPS_WORKER_ID="worker:child"
export AIDEVOPS_PARENT_WORKER_ID="worker:parent"
export AIDEVOPS_ROOT_WORKER_ID="worker:root"
export AIDEVOPS_CORRELATION_ID="correlation:root"
unset AIDEVOPS_CAUSATION_ID AIDEVOPS_PARENT_EVENT_ID AIDEVOPS_ROOT_EVENT_ID 2>/dev/null || true

node "$RUNTIME_EVENTS" emit worker.started --status running \
	--payload '{"repo":"owner/private","cwd":"/Users/example/private"}' >/dev/null
node "$RUNTIME_EVENTS" state auto pulse:current '{"workers":{"active":1},"private_path":"/Users/example/private"}' >/dev/null
node "$RUNTIME_EVENTS" state auto pulse:current '{"workers":{"active":2}}' >/dev/null
node "$RUNTIME_EVENTS" state auto pulse:current '{"workers":{"active":2}}' >/dev/null

query_json="$(node "$RUNTIME_EVENTS" query --worker worker:child --limit 10)"
[[ "$(printf '%s' "$query_json" | jq -r '.[0].parent_worker_id')" == "worker:parent" ]]
[[ "$(printf '%s' "$query_json" | jq -r '.[0].root_worker_id')" == "worker:root" ]]
[[ "$(printf '%s' "$query_json" | jq -r '.[0].correlation_id')" == "correlation:root" ]]

lineage_json="$(node "$RUNTIME_EVENTS" lineage worker:root)"
[[ "$(printf '%s' "$lineage_json" | jq 'length')" -ge 1 ]]
[[ "$(sqlite3 "$AIDEVOPS_OBS_DB_OVERRIDE" "SELECT group_concat(event_type, ',') FROM runtime_events WHERE subject_id='pulse:current' ORDER BY state_version;")" == "state.snapshot,state.delta" ]]
if sqlite3 "$AIDEVOPS_OBS_DB_OVERRIDE" "SELECT payload_json FROM runtime_events;" | grep -Eq '/Users/example/private|owner/private'; then
	printf 'FAIL runtime events retained private repository or path data\n' >&2
	exit 1
fi
node "$RUNTIME_EVENTS" verify | jq -e '.ok == true' >/dev/null

unset _PULSE_DISPATCH_WORKER_LAUNCH_LOADED 2>/dev/null || true
unset _WORKER_LIFECYCLE_COMMON_LOADED 2>/dev/null || true
# shellcheck source=../worker-lifecycle-common.sh
source "$WORKER_LIFECYCLE"
# shellcheck source=../pulse-dispatch-worker-launch.sh
source "$WORKER_LAUNCH"
CAPTURED_LAUNCH_ARGS="${TEST_ROOT}/launch-args"
HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-runtime-helper.sh"
LOGFILE="${TEST_ROOT}/pulse.log"
self_login="runner"
mkdir -p "${TEST_ROOT}/worktree"
_dlw_prewarm_opencode_db() {
	local worker_log="$1"
	[[ -n "$worker_log" ]] || return 1
	_DLW_PREWARM_DIR=""
	return 0
}
_dlw_min_worker_floor_active() {
	return 1
}
_dlw_bundle_agent_name() {
	local repo_path="$1"
	local issue_title="$2"
	local prompt="$3"
	[[ -n "$repo_path" && -n "$issue_title" && -n "$prompt" ]] || return 1
	return 0
}
_dlw_exec_detached() {
	local worker_log="$1"
	local issue_number="$2"
	shift 2
	[[ -n "$worker_log" && -n "$issue_number" ]] || return 1
	printf '%s\n' "$@" >"$CAPTURED_LAUNCH_ARGS"
	printf '43210\n'
	return 0
}

launch_pid=$(_dlw_nohup_launch \
	"27030" "owner/repo" "dispatch" "lineage" "issue-27030" \
	"${TEST_ROOT}/worker.log" "prompt" "${TEST_ROOT}/repo" "sonnet" "" \
	"${TEST_ROOT}/worktree" "feature/gh-27030" "attempt-test" "12345")
[[ "$launch_pid" == "43210" ]]
grep -Eq '^AIDEVOPS_WORKER_ID=worker:issue-27030:' "$CAPTURED_LAUNCH_ARGS"
grep -q '^AIDEVOPS_PARENT_WORKER_ID=worker:child$' "$CAPTURED_LAUNCH_ARGS"
grep -q '^AIDEVOPS_ROOT_WORKER_ID=worker:root$' "$CAPTURED_LAUNCH_ARGS"
grep -q '^AIDEVOPS_CORRELATION_ID=correlation:root$' "$CAPTURED_LAUNCH_ARGS"
dispatch_event_id=$(sed -n 's/^AIDEVOPS_PARENT_EVENT_ID=//p' "$CAPTURED_LAUNCH_ARGS")
root_event_id=$(sed -n 's/^AIDEVOPS_ROOT_EVENT_ID=//p' "$CAPTURED_LAUNCH_ARGS")
child_worker_id=$(sed -n 's/^AIDEVOPS_WORKER_ID=//p' "$CAPTURED_LAUNCH_ARGS")
[[ -n "$dispatch_event_id" && "$root_event_id" == "$dispatch_event_id" ]]
grep -q "^AIDEVOPS_CAUSATION_ID=${dispatch_event_id}$" "$CAPTURED_LAUNCH_ARGS"

AIDEVOPS_WORKER_ID="$child_worker_id" \
	AIDEVOPS_PARENT_WORKER_ID="worker:child" \
	AIDEVOPS_ROOT_WORKER_ID="worker:root" \
	AIDEVOPS_CORRELATION_ID="correlation:root" \
	AIDEVOPS_ROOT_EVENT_ID="$root_event_id" \
	AIDEVOPS_PARENT_EVENT_ID="$dispatch_event_id" \
	AIDEVOPS_CAUSATION_ID="$dispatch_event_id" \
	node "$RUNTIME_EVENTS" emit worker.started --status running \
	--source worker_self_reported >/dev/null

causal_rows=$(node "$RUNTIME_EVENTS" query --worker "$child_worker_id" --limit 10)
[[ "$(printf '%s' "$causal_rows" | jq -r 'map(select(.event_type == "worker.dispatched"))[0].event_id')" == "$dispatch_event_id" ]]
[[ "$(printf '%s' "$causal_rows" | jq -r 'map(select(.event_type == "worker.started"))[0].root_event_id')" == "$root_event_id" ]]
[[ "$(printf '%s' "$causal_rows" | jq -r 'map(select(.event_type == "worker.started"))[0].parent_event_id')" == "$dispatch_event_id" ]]
[[ "$(printf '%s' "$causal_rows" | jq -r 'map(select(.event_type == "worker.started"))[0].causation_id')" == "$dispatch_event_id" ]]
[[ "$(printf '%s' "$causal_rows" | jq -r 'map(select(.event_type == "worker.dispatched"))[0].payload_json | fromjson | .source')" == "supervisor_observed" ]]
[[ "$(printf '%s' "$causal_rows" | jq -r 'map(select(.event_type == "worker.started"))[0].payload_json | fromjson | .source')" == "worker_self_reported" ]]

python3 - "$WORKER_FAILURE" "$WORKER_RUNTIME" <<'PY'
import pathlib
import sys

failure = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
handler = failure[failure.index("_exit_trap_handler()") : failure.index("_recover_dirty_worker_pr()")]
assert "worker.exited" not in handler
assert "_hrff_finalize_exit_trap" in handler
finalizer = failure[failure.index("_hrff_finalize_exit_trap()") : failure.index("_exit_trap_handler()")]
assert finalizer.index("_push_wip_commits_on_exit") < finalizer.index("_emit_worker_runtime_event")
assert finalizer.index('reason="worker_complete"') < finalizer.index("_emit_worker_runtime_event")

worker = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
finish = worker[worker.index("_cmd_run_finish()") : worker.index("_cmd_run_prepare()")]
assert finish.index("_hrw_finish_failed_run") < finish.index("_emit_worker_runtime_event")
assert "_HRW_FINAL_RUNTIME_EVENT" in finish
PY

printf 'PASS runtime-events CLI and lineage\n'
