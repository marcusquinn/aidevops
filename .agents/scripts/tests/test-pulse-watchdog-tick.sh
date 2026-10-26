#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Regression tests for systemd-owned Pulse watchdog liveness.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
WATCHDOG="${SCRIPT_DIR}/../pulse-watchdog-tick.sh"
TEST_ROOT=$(mktemp -d -t pulse-watchdog-tick.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/home/.aidevops/logs" "${TEST_ROOT}/agents/scripts"
SYSTEMCTL_LOG="${TEST_ROOT}/systemctl.log"
LIFECYCLE_STATE="${TEST_ROOT}/lifecycle.state"

cat >"${TEST_ROOT}/bin/systemctl" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"--property=LoadState"* ]]; then
	printf 'loaded\n'
	exit 0
fi
if [[ "$*" == *"--property=ActiveState"* ]]; then
	printf 'inactive\n'
	exit 0
fi
if [[ "$*" == *" start "* ]]; then
	printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
	exit 0
fi
exit 1
SH
chmod +x "${TEST_ROOT}/bin/systemctl"

cat >"${TEST_ROOT}/agents/scripts/pulse-lifecycle-helper.sh" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "is-running" ]] || exit 2
[[ "$(<"$LIFECYCLE_STATE")" == "running" ]]
SH
chmod +x "${TEST_ROOT}/agents/scripts/pulse-lifecycle-helper.sh"

run_watchdog() {
	PATH="${TEST_ROOT}/bin:${PATH}" \
		HOME="${TEST_ROOT}/home" \
		AIDEVOPS_AGENTS_DIR="${TEST_ROOT}/agents" \
		AIDEVOPS_PULSE_WATCHDOG_GRACE=0 \
		SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
		LIFECYCLE_STATE="$LIFECYCLE_STATE" \
		"$WATCHDOG"
}

printf 'running\n' >"$LIFECYCLE_STATE"
: >"$SYSTEMCTL_LOG"
run_watchdog
if [[ -s "$SYSTEMCTL_LOG" ]]; then
	printf 'FAIL: inactive systemd unit revived despite live Pulse process\n' >&2
	exit 1
fi
printf 'PASS: inactive systemd unit accepts live Pulse process evidence\n'

printf 'stopped\n' >"$LIFECYCLE_STATE"
: >"$SYSTEMCTL_LOG"
run_watchdog
if [[ ! -s "$SYSTEMCTL_LOG" ]]; then
	printf 'FAIL: dead systemd-owned Pulse was not revived\n' >&2
	exit 1
fi
printf 'PASS: dead systemd-owned Pulse is revived\n'

# GH#35704: the supervisor watchdog's optional heartbeat is best effort, not
# a replacement for termination checks, child status, guards or refill work.
(
	# shellcheck source=../pulse-watchdog.sh
	source "${SCRIPT_DIR}/../pulse-watchdog.sh"
	LOGFILE="${TEST_ROOT}/supervisor.log"
	STOP_FLAG="${TEST_ROOT}/stop"
	PULSE_STALE_THRESHOLD=3600
	watchdog_ticks=0
	heartbeat_calls=0
	guard_calls=0
	kill_calls=0
	child_status=0
	ps() { [[ "$watchdog_ticks" -lt 2 ]]; }
	wait() { return "$child_status"; }
	sleep() {
		local interval="$1"
		[[ "$interval" == 60 || "$interval" == 2 ]] || exit 1
		watchdog_ticks=$((watchdog_ticks + 1))
		return 0
	}
	_pulse_cycle_state_stage_heartbeat() {
		heartbeat_calls=$((heartbeat_calls + 1))
		return 1
	}
	guard_child_processes() {
		guard_calls=$((guard_calls + 1))
		return 0
	}
	maybe_refill_underfilled_pool_during_active_pulse() {
		local previous_epoch="$1"
		printf '%s\n' "$previous_epoch" >>"${TEST_ROOT}/refill-calls"
		printf '%s\n' "$((previous_epoch + 1))"
		return 0
	}
	_kill_tree() {
		kill_calls=$((kill_calls + 1))
		return 0
	}
	_force_kill_tree() { return 1; }
	start_epoch=$(date +%s)
	_run_pulse_watchdog sandbox "$start_epoch" 1800
	[[ "$heartbeat_calls" == 2 && "$guard_calls" == 2 && "$kill_calls" == 0 ]]
	[[ "$(wc -l <"${TEST_ROOT}/refill-calls")" -eq 2 ]]
	[[ ! -s "$LOGFILE" ]]
	printf 'PASS: failed heartbeat preserves watchdog cadence, guards and refill without log progress\n'

	# Optional callback absence and callback failure both preserve child failures.
	unset -f _pulse_cycle_state_stage_heartbeat
	watchdog_ticks=0
	child_status=9
	watchdog_rc=0
	_run_pulse_watchdog sandbox "$start_epoch" 1800 || watchdog_rc=$?
	[[ "$watchdog_rc" == 9 && "$watchdog_ticks" == 2 ]]
	printf 'PASS: absent heartbeat callback preserves supervisor failure status\n'

	# A stop wins before heartbeat/guard/refill and cannot turn a child exit 0
	# into success. No real supervisor or external process is terminated here.
	: >"$STOP_FLAG"
	watchdog_ticks=0
	child_status=0
	guard_calls=0
	watchdog_rc=0
	_run_pulse_watchdog sandbox "$start_epoch" 1800 || watchdog_rc=$?
	[[ "$watchdog_rc" == 1 && "$kill_calls" == 1 && "$guard_calls" == 0 ]]
	printf 'PASS: stop flag retains priority and unsuccessful watchdog status\n'
)
