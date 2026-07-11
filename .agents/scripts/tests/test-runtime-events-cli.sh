#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
RUNTIME_EVENTS="${SCRIPT_DIR}/../runtime-events.mjs"
WORKER_LAUNCH="${SCRIPT_DIR}/../pulse-dispatch-worker-launch.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export AIDEVOPS_OBS_DB_OVERRIDE="${TEST_ROOT}/observability.db"
export AIDEVOPS_WORKER_ID="worker:child"
export AIDEVOPS_PARENT_WORKER_ID="worker:parent"
export AIDEVOPS_ROOT_WORKER_ID="worker:root"
export AIDEVOPS_CORRELATION_ID="correlation:root"

node "$RUNTIME_EVENTS" emit worker.started --status running \
	--payload '{"repo":"owner/private","cwd":"/Users/example/private"}' >/dev/null
node "$RUNTIME_EVENTS" state auto pulse:current '{"workers":{"active":1},"private_path":"/Users/example/private"}' >/dev/null
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
# shellcheck source=../pulse-dispatch-worker-launch.sh
source "$WORKER_LAUNCH"
CAPTURED_LAUNCH_ARGS="${TEST_ROOT}/launch-args"
HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-runtime-helper.sh"
self_login="runner"
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
	"${TEST_ROOT}/worktree" "feature/gh-27030")
[[ "$launch_pid" == "43210" ]]
grep -Eq '^AIDEVOPS_WORKER_ID=worker:issue-27030:' "$CAPTURED_LAUNCH_ARGS"
grep -q '^AIDEVOPS_PARENT_WORKER_ID=worker:child$' "$CAPTURED_LAUNCH_ARGS"
grep -q '^AIDEVOPS_ROOT_WORKER_ID=worker:root$' "$CAPTURED_LAUNCH_ARGS"
grep -q '^AIDEVOPS_CORRELATION_ID=correlation:root$' "$CAPTURED_LAUNCH_ARGS"

printf 'PASS runtime-events CLI and lineage\n'
