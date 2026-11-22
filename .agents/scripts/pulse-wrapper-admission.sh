#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse wrapper admission: session consent and dispatch wall-clock reserves.
# Sourced by pulse-wrapper.sh after configuration and dispatch helpers load.
# Dependencies: config_enabled, _dispatch_prestage_margin_seconds (optional),
# _dispatch_enumeration_expected_seconds, _dispatch_cycle_budget_admits_round.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_WRAPPER_ADMISSION_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_ADMISSION_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Check if the pulse is allowed to run.
#
# Consent model (layered, highest priority first):
#   1. Session stop flag — `aidevops pulse stop` creates this to pause
#      the pulse without uninstalling it. Checked first so stop always wins.
#   2. Session start flag — `aidevops pulse start` creates this. If present,
#      the pulse runs regardless of config (explicit user action).
#   3. Config consent — setup.sh writes orchestration.supervisor_pulse=true
#      when the user consents. This is the persistent, reboot-surviving gate.
#
# If none of the above are set, the pulse was installed without config
# consent (shouldn't happen after GH#2926) — skip as a safety fallback.
#
# Returns: 0 if pulse should run, 1 if not
#######################################
check_session_gate() {
	# Stop flag takes priority — user explicitly paused
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Pulse paused (stop flag present) — resume with: aidevops pulse start" >>"$LOGFILE"
		return 1
	fi

	# Session start flag — explicit user action, always allowed
	if [[ -f "$SESSION_FLAG" ]]; then
		return 0
	fi

	# Config consent — the persistent gate that survives reboots.
	# Delegates to config_enabled from config-helper.sh (sourced via
	# shared-constants.sh), which handles: env var override
	# (AIDEVOPS_SUPERVISOR_PULSE) > user JSONC config > defaults.
	# Single canonical implementation shared with pulse-session-helper.sh.
	if type config_enabled &>/dev/null && config_enabled "orchestration.supervisor_pulse"; then
		return 0
	fi

	echo "[pulse-wrapper] Pulse not enabled — set orchestration.supervisor_pulse=true in config or run: aidevops pulse start" >>"$LOGFILE"
	return 1
}

# ---------------------------------------------------------------------------
# GH#33307: dispatch wall-clock reserve.
#
# Dispatch_max refuses each candidate when the cycle budget is below the
# per-candidate floor (DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR, default 600s;
# the floor itself is unchanged here). Two cycle-level gaps starved batch
# dispatch for 45+ minutes:
#   1. Pre-dispatch merge stages could spend the floor that dispatch_max
#      needs later in the same cycle.
#   2. Once the budget was spent, dispatch_max, its minimum-floor refill and
#      the cycle-final event drain each re-enumerated every candidate
#      (~250s apiece) only to stop at the floor, then consumed the refill
#      trigger. That pushed the cycle ~750s past its budget, delaying the
#      next fresh-budget cycle.
# The reserve leaves one floor (plus the GH#36603 pre-stage margin) for
# dispatch before merge-only stages run; the
# admission gate skips enumeration entirely when no candidate could launch,
# preserving the existing per-candidate early-stop for genuinely overrun
# cycles. Missing/invalid cycle clocks fail open (legacy behaviour).
# ---------------------------------------------------------------------------
_pulse_dispatch_floor_seconds() {
	local floor_seconds="${DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR:-600}"
	[[ "$floor_seconds" =~ ^[1-9][0-9]*$ ]] || floor_seconds=600
	printf '%s\n' "$floor_seconds"
	return 0
}

# GH#36603: one dispatch floor plus the pre-stage margin that candidate
# admission requires on top of it (_dispatch_prestage_margin_seconds). A
# reserve of the bare floor let clamped stages land dispatch exactly on the
# floor, so pre-stage checks pushed every candidate below the stage guard.
# The margin is 0 when the dispatch library (which defines both the margin and
# the admission gate that requires it) is not loaded.
_pulse_dispatch_admission_seconds() {
	local margin_seconds=0
	if declare -F _dispatch_prestage_margin_seconds >/dev/null 2>&1; then
		margin_seconds=$(_dispatch_prestage_margin_seconds) || margin_seconds=0
	fi
	[[ "$margin_seconds" =~ ^[0-9]+$ ]] || margin_seconds=0
	printf '%s\n' "$(($(_pulse_dispatch_floor_seconds) + margin_seconds))"
	return 0
}

# Stdout: finalisation reserve plus one dispatch admission budget (floor +
# pre-stage margin), for stages that must leave dispatch_max a launchable budget.
_pulse_dispatch_reserved_finalise_seconds() {
	local finalise_seconds="${AIDEVOPS_PULSE_CYCLE_FINALISE_RESERVE_S:-90}" admission_seconds=""
	[[ "$finalise_seconds" =~ ^[0-9]+$ ]] || finalise_seconds=90
	admission_seconds=$(_pulse_dispatch_admission_seconds)
	if [[ "${AIDEVOPS_PULSE_DISPATCH_BUDGET_RESERVE:-1}" != "1" ]]; then
		printf '%s\n' "$finalise_seconds"
		return 0
	fi
	printf '%s\n' "$((finalise_seconds + admission_seconds + $(_dispatch_enumeration_expected_seconds)))"
	return 0
}

# GH#33737: optional stages that run before the early (first-wave) dispatch
# must leave that fill its admission reserve. Cache prime ran unbounded here
# (822-1624s) and left early dispatch with too little budget every cycle.
# Stdout: finalisation reserve + dispatch admission budget (floor + pre-stage
# margin, GH#36603) + first-wave enumeration estimate.
_pulse_first_wave_dispatch_reserve_seconds() {
	local _PULSE_FIRST_DISPATCH_WAVE=1 finalise_seconds="${AIDEVOPS_PULSE_CYCLE_FINALISE_RESERVE_S:-90}"
	local enumeration_seconds=300
	[[ "$finalise_seconds" =~ ^[0-9]+$ ]] || finalise_seconds=90
	if [[ "${AIDEVOPS_PULSE_DISPATCH_BUDGET_RESERVE:-1}" != "1" ]]; then
		printf '%s\n' "$finalise_seconds"
		return 0
	fi
	if declare -F _dispatch_enumeration_expected_seconds >/dev/null 2>&1; then
		enumeration_seconds=$(_dispatch_enumeration_expected_seconds) || enumeration_seconds=300
	fi
	[[ "$enumeration_seconds" =~ ^[0-9]+$ ]] || enumeration_seconds=300
	printf '%s\n' "$((finalise_seconds + $(_pulse_dispatch_admission_seconds) + enumeration_seconds))"
	return 0
}

# Returns 0 when one dispatch candidate can still be admitted this cycle (or
# the cycle clock is unavailable), 1 after logging a skip.
# Args: $1=dispatch context for the log line
_pulse_cycle_budget_admits_dispatch() {
	local dispatch_context="$1"
	_dispatch_cycle_budget_admits_round "$dispatch_context" before || return 1
	return 0
}
