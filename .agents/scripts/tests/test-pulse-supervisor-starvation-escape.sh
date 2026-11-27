#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38162: the pulse LLM supervisor must not starve behind cooperative drains
# or degraded prefetch. GH#40536: the supervisor runs in a detached lane, so a
# drained or undrained cycle only wakes the lane (no drain-escape layers).
# Exercises _pulse_run_supervisor_phase, the lane wake/entry/tick helpers and
# the queue-triggers-only branch of _should_run_llm_supervisor with stubbed
# drain, supervisor, blocker-recovery and epoch state.

set -uo pipefail

PULSE_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor" \
	"${HOME}/.aidevops/.agent-workspace/tmp/triage-cache" "${HOME}/.config/aidevops"
export PULSE_JITTER_MAX=0
unset PULSE_DIR

# shellcheck source=/dev/null
source "${PULSE_SCRIPTS_DIR}/pulse-wrapper.sh" 2>/dev/null || true
set +e

PULSE_DIR="${TEST_ROOT}/supervisor"
LOGFILE="${TEST_ROOT}/pulse.log"
mkdir -p "$PULSE_DIR"

TESTS_RUN=0
TESTS_FAILED=0

check() {
	local name="$1"
	local result="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$result" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

for required_fn in _pulse_run_supervisor_phase _should_run_llm_supervisor \
	_pulse_supervisor_starved_for _pulse_degraded_prefetch_supervisor_escape_due \
	_pulse_supervisor_lane_wake _pulse_run_supervisor_lane _pulse_supervisor_lane_tick; do
	if ! declare -F "$required_fn" >/dev/null 2>&1; then
		printf 'FAIL %s is not defined after sourcing pulse-wrapper.sh\n' "$required_fn"
		exit 1
	fi
done

# GH#38779: keep the real recovery-cadence decision before the stub below
# replaces it for the phase cases.
eval "_real_pulse_blocker_recovery_due() $(declare -f _pulse_blocker_recovery_due | tail -n +2)"

# --- stubs -----------------------------------------------------------------
STUB_DRAIN_BUNDLE=""
STUB_RECOVERY_DUE=1
SUPERVISOR_CALLS=0
SUPERVISOR_ADMITTED=""
SUPERVISOR_STATE_INCOMPLETE=""
SUPERVISOR_QUEUE_ONLY=""
RECOVERY_CALLS=0

_pulse_cycle_state_publish() { return 0; }
release_instance_lock() { return 0; }
_pulse_finish_post_dispatch_housekeeping() { return 0; }
_dispatch_cleanup_cycle_cache() { return 0; }
_pulse_drain_requested_bundle() {
	[[ -n "$STUB_DRAIN_BUNDLE" ]] || return 1
	printf '%s\n' "$STUB_DRAIN_BUNDLE"
	return 0
}
_pulse_run_optional_stage() {
	shift
	"$@"
	return $?
}
_pulse_blocker_recovery_due() {
	RECOVERY_CALLS=$((RECOVERY_CALLS + 1))
	[[ "$STUB_RECOVERY_DUE" -eq 0 ]] || return 1
	_pulse_write_trigger_mode "blocker_recovery" || return 1
	return 0
}
# Records the flags the phase passed and the real trigger decision.
_pulse_maybe_run_llm_supervisor() {
	SUPERVISOR_CALLS=$((SUPERVISOR_CALLS + 1))
	SUPERVISOR_STATE_INCOMPLETE="${_PULSE_SUPERVISOR_STATE_INCOMPLETE:-0}"
	SUPERVISOR_QUEUE_ONLY="${_PULSE_SUPERVISOR_QUEUE_TRIGGERS_ONLY:-0}"
	SUPERVISOR_LANE_RUN="${_PULSE_SUPERVISOR_LANE_RUN:-0}"
	rm -f "${PULSE_DIR}/llm_trigger_mode"
	if _should_run_llm_supervisor; then
		SUPERVISOR_ADMITTED="$(cat "${PULSE_DIR}/llm_trigger_mode" 2>/dev/null)"
	else
		SUPERVISOR_ADMITTED="none"
	fi
	return 0
}

reset_case() {
	local attempt_age="$1"
	local now_epoch=""
	now_epoch=$(date +%s)
	rm -f "${PULSE_DIR}"/* "$LOGFILE"
	printf '%s\n' "$((now_epoch - attempt_age))" >"${PULSE_DIR}/last_llm_attempt_epoch"
	printf '%s\n' "$((now_epoch - attempt_age))" >"${PULSE_DIR}/last_llm_success_epoch"
	# Daily sweep completed recently and the backlog snapshot is fresh, so only
	# the queue-driven trigger can admit a run unless a case overrides this.
	printf '%s\n' "$now_epoch" >"${PULSE_DIR}/last_daily_sweep_success_epoch"
	printf '%s 0 0\n' "$now_epoch" >"${PULSE_DIR}/backlog_snapshot.txt"
	STUB_DRAIN_BUNDLE=""
	STUB_RECOVERY_DUE=1
	SUPERVISOR_CALLS=0
	SUPERVISOR_ADMITTED=""
	SUPERVISOR_STATE_INCOMPLETE=""
	SUPERVISOR_QUEUE_ONLY=""
	SUPERVISOR_LANE_RUN=""
	RECOVERY_CALLS=0
	STUB_TRANSITION_ACTIVE=1
	_PULSE_PREFETCH_DEGRADED=0
	unset PULSE_LLM_DEGRADED_ESCAPE_SECONDS PULSE_SUPERVISOR_LANE PULSE_SUPERVISOR_LANE_TICK_SECONDS \
		PULSE_SUPERVISOR_LANE_MODE PULSE_SUPERVISOR_LANE_SOURCE
	rm -rf "${LOCKDIR}.llm"
	rm -f "$LANE_RECORD" "$WRAPPER_LOGFILE"
	return 0
}

DEFERRAL_MARKER="${PULSE_DIR}/llm_drain_escape_deferred"

# --- GH#40536 lane stubs: a recording wrapper, no systemd, no API probes -----
LOCKDIR="${TEST_ROOT}/pulse-wrapper.lockdir"
WRAPPER_LOGFILE="${TEST_ROOT}/wrapper.log"
STOP_FLAG="${TEST_ROOT}/pulse-stop.flag"
export LANE_RECORD="${TEST_ROOT}/lane-record"
LANE_WRAPPER="${TEST_ROOT}/lane-wrapper.sh"
# shellcheck disable=SC2016 # the stub expands these when it runs
printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "$1" "${PULSE_SUPERVISOR_LANE_SOURCE:-}" >>"$LANE_RECORD"\nexit 0\n' >"$LANE_WRAPPER"
chmod +x "$LANE_WRAPPER"
STUB_TRANSITION_ACTIVE=1
_pulse_supervisor_lane_wrapper() {
	printf '%s\n' "$LANE_WRAPPER"
	return 0
}
_dlw_systemd_user_service_available() { return 1; }
_pulse_event_refill_runtime_transition_active() { return "$STUB_TRANSITION_ACTIVE"; }
_pulse_set_graphql_budget_priority() { return 0; }
_pulse_set_rest_core_budget_priority() { return 0; }

# Wait up to 5s for the detached lane stub to record its invocation.
wait_for_lane() {
	local tries=0
	while [[ ! -s "$LANE_RECORD" && "$tries" -lt 50 ]]; do
		sleep 0.1
		tries=$((tries + 1))
	done
	return 0
}

REPOS_JSON="${TEST_ROOT}/repos.json"
printf '{"initialized_repos":[]}\n' >"$REPOS_JSON"
PULSE_LLM_DAILY_INTERVAL=86400
PULSE_LLM_STALL_THRESHOLD=999999
PULSE_FORCE_LLM=0

# (a) GH#40536: an undrained cycle wakes a full-mode lane and runs no
# supervisor itself.
reset_case 60
_pulse_run_supervisor_phase
wait_for_lane
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 && "$(cat "$LANE_RECORD" 2>/dev/null)" == "--supervisor-lane=full cycle" ]] &&
	grep -q 'Supervisor lane: waking mode=full source=cycle ' "$LOGFILE" && rc=0
check "(a) undrained cycle wakes a full-mode lane without an in-cycle supervisor" "$rc"

# (b) a drained cycle with a starved supervisor wakes the lane too: no drain
# skip, no escape, no deferral marker (the retired marker is removed).
reset_case 7300
STUB_DRAIN_BUNDLE="bundle-next"
STUB_RECOVERY_DUE=0
printf '%s bundle-old\n' "$(date +%s)" >"$DEFERRAL_MARKER"
_pulse_run_supervisor_phase
wait_for_lane
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 && ! -f "$DEFERRAL_MARKER" ]] &&
	[[ "$(cat "$LANE_RECORD" 2>/dev/null)" == "--supervisor-lane=full cycle-drained" ]] &&
	! grep -Eq 'starvation escape|deferr|Skipping LLM supervisor' "$LOGFILE" && rc=0
check "(b) drained starved cycle wakes the lane with no escape or deferral" "$rc"

# (b1) a degraded-prefetch cycle wakes a degraded-mode lane.
reset_case 60
_PULSE_PREFETCH_DEGRADED=1
_pulse_run_supervisor_phase
wait_for_lane
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 && "$(cat "$LANE_RECORD" 2>/dev/null)" == "--supervisor-lane=degraded cycle" ]] && rc=0
check "(b1) degraded-prefetch cycle wakes a degraded-mode lane" "$rc"

# (b2a) one session per runner: a live LLM lock holder suppresses the wake.
reset_case 60
mkdir -p "${LOCKDIR}.llm"
sleep 30 &
llm_holder_pid=$!
printf '%s\n' "$llm_holder_pid" >"${LOCKDIR}.llm/pid"
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 && ! -e "$LANE_RECORD" ]] &&
	grep -q 'wake skipped (LLM session already running, source=cycle' "$WRAPPER_LOGFILE" && rc=0
check "(b2a) a live LLM session suppresses the lane wake" "$rc"

# (b2a1) the lane entry yields to that live session as well.
PULSE_SUPERVISOR_LANE_MODE=full
_pulse_run_supervisor_lane
trap 'rm -rf "$TEST_ROOT"' EXIT
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 ]] && grep -q 'mode=full source=manual yielding' "$WRAPPER_LOGFILE" && rc=0
check "(b2a1) the lane yields to a live LLM session" "$rc"
kill "$llm_holder_pid" 2>/dev/null || true
wait "$llm_holder_pid" 2>/dev/null || true

# (b2b) a dead LLM lock owner does not suppress the wake.
reset_case 60
mkdir -p "${LOCKDIR}.llm"
printf '%s\n' "$llm_holder_pid" >"${LOCKDIR}.llm/pid"
_pulse_run_supervisor_phase
wait_for_lane
rc=1
[[ "$(cat "$LANE_RECORD" 2>/dev/null)" == "--supervisor-lane=full cycle" ]] && rc=0
check "(b2b) a dead LLM lock owner does not suppress the wake" "$rc"

# (b2c) the runtime transition lock and the stop flag suppress the wake.
reset_case 60
STUB_TRANSITION_ACTIVE=0
_pulse_run_supervisor_phase
STUB_TRANSITION_ACTIVE=1
touch "$STOP_FLAG"
_pulse_run_supervisor_phase
rm -f "$STOP_FLAG"
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 && ! -e "$LANE_RECORD" ]] &&
	grep -q 'wake skipped (runtime transition' "$WRAPPER_LOGFILE" &&
	grep -q 'wake skipped (stop flag' "$WRAPPER_LOGFILE" && rc=0
check "(b2c) runtime transition and stop flag suppress the wake" "$rc"

# Run the lane entry in this shell, then restore the test's EXIT trap.
run_lane() {
	PULSE_SUPERVISOR_LANE_MODE="$1"
	_pulse_run_supervisor_lane
	LANE_RC=$?
	trap 'rm -rf "$TEST_ROOT"' EXIT
	return 0
}

# (b2d) a full-mode lane runs one normally gated decision flagged as a lane
# run (no recycle dispatch), with its own pid file.
reset_case 60
STUB_RECOVERY_DUE=0
run_lane full
rc=1
[[ "$LANE_RC" -eq 0 && "$SUPERVISOR_CALLS" -eq 1 && "$SUPERVISOR_LANE_RUN" == "1" &&
	"$SUPERVISOR_QUEUE_ONLY" == "0" && "$SUPERVISOR_STATE_INCOMPLETE" == "0" &&
	"$SUPERVISOR_ADMITTED" == "blocker_recovery" && "$PIDFILE" == *pulse-supervisor-lane.pid ]] && rc=0
check "(b2d) full-mode lane runs one gated decision as a lane run" "$rc"

# (b2e) a queue-mode lane evaluates queue-driven triggers with state incomplete.
reset_case 60
rm -f "${PULSE_DIR}/last_daily_sweep_success_epoch"
run_lane queue
rc=1
[[ "$SUPERVISOR_CALLS" -eq 1 && "$SUPERVISOR_QUEUE_ONLY" == "1" && "$SUPERVISOR_STATE_INCOMPLETE" == "1" &&
	"$SUPERVISOR_ADMITTED" == "none" && "$RECOVERY_CALLS" -eq 1 ]] && rc=0
check "(b2e) queue-mode lane never admits the snapshot-driven daily sweep" "$rc"

# (b2f) an unknown lane mode is rejected without a decision.
reset_case 60
run_lane bogus 2>/dev/null
rc=1
[[ "$LANE_RC" -eq 2 && "$SUPERVISOR_CALLS" -eq 0 ]] && rc=0
check "(b2f) unknown lane mode is rejected" "$rc"

# (b3) the routines ticker wakes a queue lane at most once per interval.
reset_case 60
rm -f "${PULSE_DIR}/supervisor_lane_tick_epoch"
_pulse_supervisor_lane_tick
wait_for_lane
first_record=$(cat "$LANE_RECORD" 2>/dev/null)
rm -f "$LANE_RECORD"
_pulse_supervisor_lane_tick
sleep 0.3
rc=1
[[ "$first_record" == "--supervisor-lane=queue routines-tick" && ! -e "$LANE_RECORD" ]] && rc=0
check "(b3) routines tick wakes one queue lane per interval" "$rc"

# (b3a) PULSE_SUPERVISOR_LANE_TICK_SECONDS=0 disables the ticker wake.
reset_case 60
rm -f "${PULSE_DIR}/supervisor_lane_tick_epoch"
PULSE_SUPERVISOR_LANE_TICK_SECONDS=0 _pulse_supervisor_lane_tick
sleep 0.3
rc=1
[[ ! -e "$LANE_RECORD" ]] && rc=0
check "(b3a) PULSE_SUPERVISOR_LANE_TICK_SECONDS=0 disables the ticker wake" "$rc"

# (b4) the supervisor phase follows the cycle's dispatch pipeline in main().
rc=1
pipeline_line=$(grep -n -m1 '^[[:space:]]*_pulse_run_deterministic_pipeline$' "${PULSE_SCRIPTS_DIR}/pulse-wrapper.sh" | cut -d: -f1)
phase_line=$(grep -n -m1 '^[[:space:]]*_pulse_run_supervisor_phase$' "${PULSE_SCRIPTS_DIR}/pulse-wrapper.sh" | cut -d: -f1)
[[ -n "$pipeline_line" && -n "$phase_line" && "$pipeline_line" -lt "$phase_line" ]] && rc=0
check "(b4) the supervisor phase runs after the dispatch pipeline" "$rc"

# (b5) the ticker loop wakes the lane after its routines pass.
rc=1
grep -q '_pulse_supervisor_lane_tick || true' "${PULSE_SCRIPTS_DIR}/pulse-routines-tick.sh" && rc=0
check "(b5) the routines ticker calls the lane tick" "$rc"

# (b6) PULSE_SUPERVISOR_LANE=0 rollback: a drained cycle skips (plain GH#37907,
# no escape even when starved); an undrained cycle runs the supervisor in-cycle.
reset_case 999999
STUB_DRAIN_BUNDLE="bundle-next"
STUB_RECOVERY_DUE=0
PULSE_SUPERVISOR_LANE=0
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 && ! -e "$LANE_RECORD" ]] &&
	grep -q 'Skipping LLM supervisor: cooperative drain requested' "$LOGFILE" && rc=0
STUB_DRAIN_BUNDLE=""
_pulse_run_supervisor_phase
[[ "$SUPERVISOR_CALLS" -eq 1 && "$SUPERVISOR_LANE_RUN" == "0" && ! -e "$LANE_RECORD" ]] || rc=1
check "(b6) PULSE_SUPERVISOR_LANE=0 restores the in-cycle supervisor without escapes" "$rc"

# (c) degraded prefetch with recovery due runs with state marked incomplete.
reset_case 60
STUB_RECOVERY_DUE=0
run_lane degraded
rc=1
[[ "$SUPERVISOR_CALLS" -eq 1 && "$SUPERVISOR_ADMITTED" == "blocker_recovery" &&
	"$SUPERVISOR_STATE_INCOMPLETE" == "1" && "$SUPERVISOR_QUEUE_ONLY" == "1" && "$RECOVERY_CALLS" -eq 1 ]] && rc=0
check "(c) degraded prefetch with recovery due runs, state incomplete, one recovery probe" "$rc"

# (d) degraded prefetch without recovery due and without a stale attempt skips.
reset_case 60
run_lane degraded
rc=1
[[ "$SUPERVISOR_ADMITTED" == "none" && "$RECOVERY_CALLS" -eq 1 ]] &&
	grep -Eq 'Skipping LLM supervisor: prefetch state incomplete.*last_attempt_age_s=[0-9]+' "$LOGFILE" && rc=0
check "(d) degraded prefetch without recovery due skips with last_attempt_age_s" "$rc"

# (e) queue-triggers-only never admits a due daily sweep.
reset_case 60
rm -f "${PULSE_DIR}/last_daily_sweep_success_epoch"
run_lane degraded
rc=1
[[ "$SUPERVISOR_QUEUE_ONLY" == "1" && "$SUPERVISOR_ADMITTED" == "none" && "$RECOVERY_CALLS" -eq 1 ]] && rc=0
check "(e) queue-triggers-only does not admit daily sweep" "$rc"

# (f) the 6h degraded escape still runs the full trigger set.
reset_case 30000
rm -f "${PULSE_DIR}/last_daily_sweep_success_epoch"
run_lane degraded
rc=1
[[ "$SUPERVISOR_QUEUE_ONLY" == "0" && "$SUPERVISOR_STATE_INCOMPLETE" == "1" && "$SUPERVISOR_ADMITTED" == "daily_sweep" ]] && rc=0
check "(f) degraded 6h escape keeps full trigger set" "$rc"

# --- GH#38779: recovery cadence after a failed attempt ----------------------
RECOVERY_STUB_DIR="${TEST_ROOT}/recovery-helper"
mkdir -p "$RECOVERY_STUB_DIR"
printf '#!/usr/bin/env bash\nprintf "3\\n"\nexit 0\n' >"${RECOVERY_STUB_DIR}/terminal-blocker-recovery-helper.sh"
RECOVERY_STAMP="${PULSE_DIR}/last_blocker_recovery_check_epoch"
NOW_EPOCH=$(date +%s)

# (g) a failed attempt 40 min ago, last check 40 min ago: the 30 min failure
# retry admits recovery instead of waiting for the 3h interval.
reset_case 60
printf '%s\n' "$((NOW_EPOCH - 2400))" >"$RECOVERY_STAMP"
rc=1
SCRIPT_DIR="$RECOVERY_STUB_DIR" _real_pulse_blocker_recovery_due "$NOW_EPOCH" "$((NOW_EPOCH - 90000))" "$((NOW_EPOCH - 2400))" &&
	[[ "$(cat "${PULSE_DIR}/llm_trigger_mode" 2>/dev/null)" == "blocker_recovery" ]] && rc=0
check "(g) failed attempt retries recovery after the failure interval, not 3h" "$rc"

# (h) after a success, the same 40 min gap still waits for the 3h interval.
reset_case 60
printf '%s\n' "$((NOW_EPOCH - 2400))" >"$RECOVERY_STAMP"
rc=1
if ! SCRIPT_DIR="$RECOVERY_STUB_DIR" _real_pulse_blocker_recovery_due "$NOW_EPOCH" "$((NOW_EPOCH - 2400))" "$((NOW_EPOCH - 2400))"; then
	[[ "$(cat "$RECOVERY_STAMP")" == "$((NOW_EPOCH - 2400))" ]] && rc=0
fi
check "(h) successful attempt keeps the 3h recovery interval" "$rc"

# (i) a check inside the failure cooldown leaves the stamp untouched.
reset_case 60
printf '%s\n' "$((NOW_EPOCH - 20000))" >"$RECOVERY_STAMP"
rc=1
if ! SCRIPT_DIR="$RECOVERY_STUB_DIR" _real_pulse_blocker_recovery_due "$NOW_EPOCH" "$((NOW_EPOCH - 90000))" "$((NOW_EPOCH - 600))"; then
	[[ "$(cat "$RECOVERY_STAMP")" == "$((NOW_EPOCH - 20000))" ]] && rc=0
fi
check "(i) failure cooldown does not spend the recovery window" "$rc"

# (j) supervisor tier fallback gate: fast rc=75 only, never pinned or long runs.
rc=1
if PULSE_MODEL="" _pulse_supervisor_tier_fallback_due 75 60 &&
	! _pulse_supervisor_tier_fallback_due 75 900 &&
	! _pulse_supervisor_tier_fallback_due 1 60 &&
	! PULSE_MODEL="anthropic/pinned" _pulse_supervisor_tier_fallback_due 75 60 &&
	! PULSE_SUPERVISOR_FALLBACK_TIER="" _pulse_supervisor_tier_fallback_due 75 60; then
	rc=0
fi
check "(j) tier fallback only for fast rc=75 without a model pin" "$rc"

printf '%s/%s tests passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
