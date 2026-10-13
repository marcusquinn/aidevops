#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"
export LOGFILE="$TEST_ROOT/pulse.log"
export REPOS_JSON="$TEST_ROOT/repos.json"
export STATE_FILE="$TEST_ROOT/state.txt"
export SCOPE_FILE="$TEST_ROOT/scope.txt"
export PRE_RUN_STAGE_TIMEOUT=23
export AIDEVOPS_PULSE_STAGE_CYCLE_CLAMP=0
trap 'rm -rf "$TEST_ROOT"' EXIT

SCRIPT_DIR="$SCRIPTS_DIR"
# shellcheck source=../worker-lifecycle-common.sh
source "$SCRIPTS_DIR/worker-lifecycle-common.sh"
# shellcheck source=../pulse-watchdog.sh
source "$SCRIPTS_DIR/pulse-watchdog.sh"
# shellcheck source=../pulse-prefetch.sh
source "$SCRIPTS_DIR/pulse-prefetch.sh"

# Exercise the real orchestrator and timeout/process-tree helpers without API
# calls or reading real repositories. Many repo shards plus a slow optional
# tail reproduce the phase-budget problem inside a short watchdog window.
jq -n '[range(0; 24) | {slug:("example/repo-" + tostring), path:"/unused",
	maintenance:true, pulse:true}] | {initialized_repos:.}' >"$REPOS_JSON"
_prefetch_record_efficiency_population() { return 0; }
check_repo_pulse_schedule() { return 0; }
_prefetch_single_repo() {
	local slug="$1" path="$2" output="$3"
	printf '## %s (%s)\n' "$slug" "$path" >"$output"
	if [[ "${TEST_SLOW_PRIMARY:-0}" == 1 ]]; then
		sleep 300
	fi
	return 0
}
_append_prefetch_sub_helpers() {
	local entries="$1"
	[[ -n "$entries" ]]
	if [[ "${TEST_SLOW_SECONDARY:-0}" == 1 ]]; then
		printf '%s\n' "$BASHPID" >"$TEST_ROOT/secondary.pid"
		sleep 300 &
		printf '%s\n' "$!" >"$TEST_ROOT/secondary-child.pid"
		wait "$!"
	fi
	printf 'optional completed\n' >>"$STATE_FILE"
	return 0
}

# No deadline (standalone invocation) and invalid clocks retain legacy caps.
unset PULSE_STAGE_DEADLINE_EPOCH
[[ "$(_prefetch_remaining_seconds 120)" == 120 ]]
[[ "$(PULSE_STAGE_DEADLINE_EPOCH=invalid _prefetch_remaining_seconds 120)" == 120 ]]
PULSE_BATCH_PREFETCH_ENABLED=0 prefetch_state
[[ "$(grep -c '^## example/repo-' "$STATE_FILE")" == 24 ]]
grep -q 'optional completed' "$STATE_FILE"
printf 'PASS standalone caps and complete primary state\n'

# Expired budget must not launch work; batch warmup must leave primary room.
PULSE_STAGE_DEADLINE_EPOCH="$(date +%s)"
export PULSE_STAGE_DEADLINE_EPOCH
if _prefetch_remaining_seconds 120; then
	printf 'expired deadline admitted work\n' >&2
	exit 1
fi
_prefetch_batch_refresh
grep -q 'reserving primary fetch budget' "$LOGFILE"
rc=0
prefetch_state || rc=$?
[[ "$rc" == 124 ]]
printf 'PASS expired deadline and batch budget reserve\n'

# The optional tail is stopped inside the deadline, not by the outer watchdog.
unset PULSE_STAGE_DEADLINE_EPOCH
export TEST_SLOW_SECONDARY=1
started_at=$SECONDS
run_stage_with_timeout prefetch_state "$PRE_RUN_STAGE_TIMEOUT" prefetch_state
[[ "$((SECONDS - started_at))" -lt "$PRE_RUN_STAGE_TIMEOUT" ]]
[[ "$(grep -c '^## example/repo-' "$STATE_FILE")" == 24 ]]
[[ "$(tr ',' '\n' <"$SCOPE_FILE" | wc -l)" -eq 24 ]]
grep -q 'primary state and scope preserved' "$LOGFILE"
for pid_file in "$TEST_ROOT/secondary.pid" "$TEST_ROOT/secondary-child.pid"; do
	pid=$(<"$pid_file")
	if kill -0 "$pid" 2>/dev/null; then
		printf 'optional timeout left process %s alive\n' "$pid" >&2
		exit 1
	fi
done
printf 'PASS slow optional tail preserves complete primary state and scope\n'

# A primary timeout is not transformed into success just because shards exist.
export TEST_SLOW_PRIMARY=1 TEST_SLOW_SECONDARY=0
rc=0
run_stage_with_timeout prefetch_state 18 prefetch_state || rc=$?
[[ "$rc" == 124 ]]
grep -q 'INCOMPLETE primary repo fetch' "$STATE_FILE"
[[ -s "$SCOPE_FILE" ]]
printf 'PASS incomplete primary results retain timeout classification\n'

# Re-clamp after launch rather than granting the initial 120s cap again.
PULSE_STAGE_DEADLINE_EPOCH=$(($(date +%s) + 16))
export PULSE_STAGE_DEADLINE_EPOCH
sleep 300 &
primary_pid=$!
started_at=$SECONDS
rc=0
_wait_parallel_pids 120 "$primary_pid" || rc=$?
[[ "$rc" == 124 && "$((SECONDS - started_at))" -lt 8 ]]
if kill -0 "$primary_pid" 2>/dev/null; then
	exit 1
fi
printf 'PASS primary wait respects absolute deadline after worker launch\n'

# Completion during the last polling sleep is success; failed workers are not.
unset PULSE_STAGE_DEADLINE_EPOCH
sleep 0.1 &
_wait_parallel_pids 1 "$!"
bash -c 'exit 1' &
rc=0
_wait_parallel_pids 2 "$!" || rc=$?
[[ "$rc" == 1 ]]
printf 'PASS completion boundary and failed primary worker classification\n'
