#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38162: the pulse LLM supervisor must not starve behind cooperative drains
# or degraded prefetch. Exercises _pulse_run_supervisor_phase and the
# queue-triggers-only branch of _should_run_llm_supervisor with stubbed drain,
# supervisor, blocker-recovery and epoch state.

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
	_pulse_supervisor_starved_for _pulse_degraded_prefetch_supervisor_escape_due; do
	if ! declare -F "$required_fn" >/dev/null 2>&1; then
		printf 'FAIL %s is not defined after sourcing pulse-wrapper.sh\n' "$required_fn"
		exit 1
	fi
done

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
	RECOVERY_CALLS=0
	_PULSE_PREFETCH_DEGRADED=0
	unset PULSE_LLM_DRAIN_ESCAPE_SECONDS PULSE_LLM_DEGRADED_ESCAPE_SECONDS PULSE_LLM_DRAIN_ESCAPE_DEFER
	return 0
}

DEFERRAL_MARKER="${PULSE_DIR}/llm_drain_escape_deferred"

REPOS_JSON="${TEST_ROOT}/repos.json"
printf '{"initialized_repos":[]}\n' >"$REPOS_JSON"
PULSE_LLM_DAILY_INTERVAL=86400
PULSE_LLM_STALL_THRESHOLD=999999
PULSE_FORCE_LLM=0

# (a) drain with a recent attempt skips and reports the starvation age.
reset_case 60
STUB_DRAIN_BUNDLE="bundle-next"
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 ]] &&
	grep -Eq 'Skipping LLM supervisor: cooperative drain requested.*last_attempt_age_s=[0-9]+' "$LOGFILE" && rc=0
check "(a) drain with recent attempt skips with last_attempt_age_s" "$rc"

# (b) GH#38210: drain with a stale attempt defers the escape, so the drained
# cycle exits and the activated bundle's first dispatch wave goes first.
reset_case 7300
STUB_DRAIN_BUNDLE="bundle-next"
STUB_RECOVERY_DUE=0
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 && -f "$DEFERRAL_MARKER" ]] &&
	grep -q 'deferring the GH#38162 escape until after bundle bundle-next' "$LOGFILE" &&
	! grep -q 'GH#38162 starvation escape' "$LOGFILE" && rc=0
check "(b) drain with stale attempt defers the escape past the activated bundle's first wave" "$rc"

# (b1) the activated bundle's cycle (no drain) evaluates the deferred escape
# after its dispatch wave, in that same cycle, and clears the deferral.
STUB_DRAIN_BUNDLE=""
: >"$LOGFILE"
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_CALLS" -eq 1 && "$SUPERVISOR_ADMITTED" == "blocker_recovery" && ! -f "$DEFERRAL_MARKER" ]] &&
	grep -q 'evaluating the deferred drain escape' "$LOGFILE" && rc=0
check "(b1) activated bundle cycle runs the deferred supervisor and clears the deferral" "$rc"

# (b2a) a drained activated cycle runs the already-deferred escape itself.
reset_case 7300
STUB_DRAIN_BUNDLE="bundle-next"
STUB_RECOVERY_DUE=0
_pulse_run_supervisor_phase
STUB_DRAIN_BUNDLE="bundle-after"
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_CALLS" -eq 1 && "$SUPERVISOR_ADMITTED" == "blocker_recovery" && "$SUPERVISOR_QUEUE_ONLY" == "0" && ! -f "$DEFERRAL_MARKER" ]] &&
	grep -q 'GH#38162 starvation escape' "$LOGFILE" && rc=0
check "(b2a) a second drained cycle runs the deferred escape" "$rc"

# (b3) PULSE_LLM_DRAIN_ESCAPE_DEFER=0 runs the escape in the drained cycle.
reset_case 7300
STUB_DRAIN_BUNDLE="bundle-next"
STUB_RECOVERY_DUE=0
PULSE_LLM_DRAIN_ESCAPE_DEFER=0
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_CALLS" -eq 1 && "$SUPERVISOR_ADMITTED" == "blocker_recovery" && ! -f "$DEFERRAL_MARKER" ]] &&
	grep -q 'GH#38162 starvation escape' "$LOGFILE" && rc=0
check "(b3) PULSE_LLM_DRAIN_ESCAPE_DEFER=0 runs the escape immediately" "$rc"

# (b4) the supervisor phase follows the cycle's dispatch pipeline in main().
rc=1
pipeline_line=$(grep -n '^[[:space:]]*_pulse_run_deterministic_pipeline$' "${PULSE_SCRIPTS_DIR}/pulse-wrapper.sh" | head -1 | cut -d: -f1)
phase_line=$(grep -n '^[[:space:]]*_pulse_run_supervisor_phase$' "${PULSE_SCRIPTS_DIR}/pulse-wrapper.sh" | head -1 | cut -d: -f1)
[[ -n "$pipeline_line" && -n "$phase_line" && "$pipeline_line" -lt "$phase_line" ]] && rc=0
check "(b4) the supervisor phase runs after the dispatch pipeline" "$rc"

# (b2) PULSE_LLM_DRAIN_ESCAPE_SECONDS=0 disables the drain escape.
reset_case 999999
STUB_DRAIN_BUNDLE="bundle-next"
PULSE_LLM_DRAIN_ESCAPE_SECONDS=0
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_CALLS" -eq 0 ]] && grep -q 'Skipping LLM supervisor: cooperative drain requested' "$LOGFILE" && rc=0
check "(b2) PULSE_LLM_DRAIN_ESCAPE_SECONDS=0 disables drain escape" "$rc"

# (c) degraded prefetch with recovery due runs with state marked incomplete.
reset_case 60
_PULSE_PREFETCH_DEGRADED=1
STUB_RECOVERY_DUE=0
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_CALLS" -eq 1 && "$SUPERVISOR_ADMITTED" == "blocker_recovery" &&
	"$SUPERVISOR_STATE_INCOMPLETE" == "1" && "$SUPERVISOR_QUEUE_ONLY" == "1" && "$RECOVERY_CALLS" -eq 1 ]] && rc=0
check "(c) degraded prefetch with recovery due runs, state incomplete, one recovery probe" "$rc"

# (d) degraded prefetch without recovery due and without a stale attempt skips.
reset_case 60
_PULSE_PREFETCH_DEGRADED=1
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_ADMITTED" == "none" && "$RECOVERY_CALLS" -eq 1 ]] &&
	grep -Eq 'Skipping LLM supervisor: prefetch state incomplete.*last_attempt_age_s=[0-9]+' "$LOGFILE" && rc=0
check "(d) degraded prefetch without recovery due skips with last_attempt_age_s" "$rc"

# (e) queue-triggers-only never admits a due daily sweep.
reset_case 60
rm -f "${PULSE_DIR}/last_daily_sweep_success_epoch"
_PULSE_PREFETCH_DEGRADED=1
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_QUEUE_ONLY" == "1" && "$SUPERVISOR_ADMITTED" == "none" && "$RECOVERY_CALLS" -eq 1 ]] && rc=0
check "(e) queue-triggers-only does not admit daily sweep" "$rc"

# (f) the 6h degraded escape still runs the full trigger set.
reset_case 30000
rm -f "${PULSE_DIR}/last_daily_sweep_success_epoch"
_PULSE_PREFETCH_DEGRADED=1
_pulse_run_supervisor_phase
rc=1
[[ "$SUPERVISOR_QUEUE_ONLY" == "0" && "$SUPERVISOR_STATE_INCOMPLETE" == "1" && "$SUPERVISOR_ADMITTED" == "daily_sweep" ]] && rc=0
check "(f) degraded 6h escape keeps full trigger set" "$rc"

printf '%s/%s tests passed\n' "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
