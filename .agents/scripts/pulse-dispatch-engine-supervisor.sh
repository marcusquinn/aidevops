#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Dispatch cadence: supervisor state, blocker recovery and launch pacing.
# Sourced by pulse-dispatch-engine.sh; uses its defaults and caller-provided
# API and health adapters. No supervisor work runs merely by sourcing this library.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DISPATCH_ENGINE_SUPERVISOR_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_ENGINE_SUPERVISOR_LOADED=1

_pulse_read_epoch_file() {
	local file_path="$1"
	local epoch="0"
	if [[ -f "$file_path" ]]; then
		epoch=$(cat "$file_path" 2>/dev/null) || epoch="0"
	fi
	[[ "$epoch" =~ ^[0-9]+$ ]] || epoch="0"
	printf '%s\n' "$epoch"
	return 0
}

_pulse_write_trigger_mode() {
	local trigger_mode="$1"
	printf '%s\n' "$trigger_mode" >"${PULSE_DIR}/llm_trigger_mode" 2>/dev/null || return 1
	return 0
}

_pulse_llm_failure_cooldown_active() {
	local now_epoch="$1"
	local last_success_epoch="$2"
	local last_attempt_epoch="$3"
	local retry_interval="${PULSE_LLM_FAILURE_RETRY_INTERVAL:-1800}"
	[[ "$retry_interval" =~ ^[0-9]+$ ]] || retry_interval=1800

	if [[ "$last_attempt_epoch" -gt "$last_success_epoch" ]]; then
		local attempt_age=$((now_epoch - last_attempt_epoch))
		if [[ "$attempt_age" -lt "$retry_interval" ]]; then
			echo "[pulse-wrapper] LLM supervisor: previous attempt failed ${attempt_age}s ago; retry cooldown ${retry_interval}s" >>"$LOGFILE"
			return 0
		fi
	fi
	return 1
}

#######################################
# GH#34000 follow-up: an incomplete prefetch defers the LLM supervisor because
# its prompt points at STATE_FILE. A runner whose prefetch degrades on every
# cycle would then never run the supervisor, starving the daily sweep and
# terminal-blocker recovery indefinitely. Admit a degraded-prefetch supervisor
# decision once the latest attempt/success is older than
# PULSE_LLM_DEGRADED_ESCAPE_SECONDS (default 6h; 0 disables). The normal
# _should_run_llm_supervisor gates and failure cooldown still apply, and the
# prompt marks the state file incomplete.
# Returns: 0 when a degraded-prefetch supervisor run is admitted, 1 otherwise
#######################################
_pulse_degraded_prefetch_supervisor_escape_due() {
	local escape_seconds="${PULSE_LLM_DEGRADED_ESCAPE_SECONDS:-21600}"
	local now_epoch="" last_success="" last_attempt="" latest=0
	[[ "$escape_seconds" =~ ^[0-9]+$ && "$escape_seconds" -gt 0 ]] || return 1
	now_epoch=$(date +%s)
	last_success=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_success_epoch")
	last_attempt=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_attempt_epoch")
	latest="$last_success"
	[[ "$last_attempt" -gt "$latest" ]] && latest="$last_attempt"
	[[ $((now_epoch - latest)) -ge "$escape_seconds" ]] || return 1
	return 0
}

#######################################
# GH#36026: release positively re-armed queued holds independently of LLM
# scheduling. Use cached API-pressure state only; never probe to bypass a fuse.
#######################################
_pulse_rearm_blocker_holds() {
	local now_epoch="${1:-$(date +%s)}"
	local interval="${PULSE_BLOCKER_REARM_INTERVAL:-600}"
	local stamp="${PULSE_DIR}/last_blocker_rearm_check_epoch"
	local helper="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/terminal-blocker-recovery-helper.sh"
	local last_check=0 rc=0
	[[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || return 0
	[[ -f "$helper" ]] || return 0
	[[ ! -f "${_CIRCUIT_BREAKER_STATE_FILE:-${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state}" ]] || return 0
	if declare -F _gh_secondary_cooldown_active >/dev/null 2>&1 && _gh_secondary_cooldown_active; then
		return 0
	fi
	last_check=$(_pulse_read_epoch_file "$stamp")
	[[ $((now_epoch - last_check)) -ge "$interval" ]] || return 0
	printf '%s\n' "$now_epoch" >"$stamp" 2>/dev/null || return 1
	# The helper bounds identity and queue work with the existing recovery
	# budget and saves an independent cursor on partial passes.
	bash "$helper" rearm >>"$LOGFILE" 2>&1 || rc=$?
	[[ "$rc" -eq 0 ]] || printf '[pulse-wrapper] Blocker rearm pass incomplete (rc=%s)\n' "$rc" >>"$LOGFILE"
	return 0
}

#######################################
# t18514/GH#32754: decide whether pending terminal-blocker recovery entries
# warrant an LLM supervisor run. Checks at most once per interval so the
# GitHub-verified count never runs on every pulse cycle.
# Args: now_epoch last_success_epoch last_attempt_epoch
# Returns: 0 when a recovery run should start (trigger mode written), 1 otherwise
#######################################
_pulse_blocker_recovery_due() {
	local now_epoch="$1"
	local last_success_epoch="$2"
	local last_attempt_epoch="$3"
	local interval="${PULSE_LLM_RECOVERY_INTERVAL:-10800}"
	local stamp="${PULSE_DIR}/last_blocker_recovery_check_epoch"
	local helper="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/terminal-blocker-recovery-helper.sh"
	local last_check=0 pending=0 pending_rc=0 scan_note=""
	[[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || return 1
	[[ -f "$helper" ]] || return 1
	[[ -f "$stamp" ]] && read -r last_check <"$stamp"
	[[ "$last_check" =~ ^[0-9]+$ ]] || last_check=0
	[[ $((now_epoch - last_check)) -ge "$interval" ]] || return 1
	printf '%s\n' "$now_epoch" >"$stamp" 2>/dev/null || return 1
	# GH#35945: exit 2 is an incomplete scan whose stdout is still the partial
	# count (helper contract). The bounded seed spans every pulse repo and
	# rarely finishes in one call, so discarding that count kept this trigger
	# from ever firing. Any other failure means nothing is known to be pending.
	pending=$(bash "$helper" pending --count 2>/dev/null) || pending_rc=$?
	case "$pending_rc" in
	0) ;;
	2) scan_note=" (partial scan)" ;;
	*) pending=0 ;;
	esac
	[[ "$pending" =~ ^[0-9]+$ && "$pending" -gt 0 ]] || return 1
	if _pulse_llm_failure_cooldown_active "$now_epoch" "$last_success_epoch" "$last_attempt_epoch"; then
		return 1
	fi
	echo "[pulse-wrapper] LLM supervisor: ${pending} terminal-blocker recovery entr$([[ "$pending" -eq 1 ]] && printf 'y' || printf 'ies') pending${scan_note} (t18514)" >>"$LOGFILE"
	_pulse_write_trigger_mode "blocker_recovery" || return 1
	return 0
}

_update_backlog_snapshot() {
	local epoch="${1:-$(date +%s)}"
	local issues="${2:-0}"
	local prs="${3:-0}"
	printf '%s %s %s\n' "$epoch" "$issues" "$prs" >"${PULSE_DIR}/backlog_snapshot.txt"
	return 0
}

#######################################
# t3015: Returns 0 (true) if the dispatch loop should take the floor path
# (forced-serial, "test the waters" semantics) rather than the max path
# (parallel saturation). Two triggers:
#   1. Adaptive throttle file present at $_DISPATCH_THROTTLE_FILE — runtime is
#      degraded (recent worker launch failures), so we want serial dispatch
#      to verify the runtime is healthy before saturating again.
#   2. _DISPATCH_FORCE_FLOOR=1 set by an explicit dispatch_floor() caller —
#      lets diagnostic / single-shot callers force the slow-and-careful path
#      without modifying the throttle file.
#
# Returns 1 (false) otherwise — the default max path dispatches in parallel.
#
# Caller contract: $_DISPATCH_THROTTLE_FILE must be set before this function
# is called. dispatch_max() sets it just before checking; dispatch_floor()
# inherits via export.
#######################################
_dispatch_should_use_floor_path() {
	[[ -n "${_DISPATCH_FORCE_FLOOR:-}" ]] && return 0
	[[ -f "${_DISPATCH_THROTTLE_FILE:-${HOME}/.aidevops/logs/dispatch-throttle}" ]] && return 0
	return 1
}

#######################################
# t3015: Public entry point for the forced-serial dispatch path.
#
# Thin wrapper around dispatch_max() that sets _DISPATCH_FORCE_FLOOR=1 so the
# orchestrator delegates to the serial (`floor`) loop regardless of whether the
# adaptive throttle file is present. Use this when an external caller wants
# the slow-and-careful "one at a time, verify it lands" behaviour — e.g. a
# diagnostic harness, a single-issue dispatch test, or a regression escape
# hatch for operators who want to bypass the parallel max loop without
# manually creating a throttle file.
#
# Pre-t3015 the only way to get serial behaviour was DISPATCH_MAX_PARALLEL=1,
# which is a runtime tuning knob, not a public API. dispatch_floor() is the
# named API for "force serial regardless of tuning".
#
# Arguments / return value: forwarded as-is to dispatch_max().
#######################################
dispatch_floor() {
	_DISPATCH_FORCE_FLOOR=1 dispatch_max "$@"
}

#######################################
# Compute and apply an adaptive launch-settle wait (t1887).
#
# Scales the wait from 0s (0 dispatches) to PULSE_LAUNCH_GRACE_SECONDS
# (PULSE_LAUNCH_SETTLE_BATCH_MAX or more dispatches) using linear
# interpolation. This avoids the static 35s wait when no workers were
# launched, saving ~35s per idle cycle.
#
# Formula: wait = ceil(dispatched / batch_max * grace_max)
# Examples (grace_max=35, batch_max=5):
#   0 dispatches → 0s
#   1 dispatch   → 7s
#   2 dispatches → 14s
#   3 dispatches → 21s
#   4 dispatches → 28s
#   5+ dispatches → 35s
#
# Arguments:
#   $1 - dispatched_count (integer, number of workers just launched)
#   $2 - context label for log (e.g. "dispatch_max", "recycle loop")
#######################################
_adaptive_launch_settle_wait() {
	local dispatched_count="${1:-0}"
	local context_label="${2:-dispatch}"

	[[ "$dispatched_count" =~ ^[0-9]+$ ]] || dispatched_count=0
	if [[ "$dispatched_count" -eq 0 ]]; then
		echo "[pulse-wrapper] Adaptive settle wait (${context_label}): 0 dispatches — skipping wait" >>"$LOGFILE"
		return 0
	fi

	local grace_max="$PULSE_LAUNCH_GRACE_SECONDS"
	local batch_max="$PULSE_LAUNCH_SETTLE_BATCH_MAX"
	[[ "$grace_max" =~ ^[0-9]+$ ]] || grace_max=35
	[[ "$batch_max" =~ ^[0-9]+$ ]] || batch_max=5
	[[ "$batch_max" -lt 1 ]] && batch_max=1

	# Clamp dispatched_count to batch_max ceiling
	local clamped="$dispatched_count"
	if [[ "$clamped" -gt "$batch_max" ]]; then
		clamped="$batch_max"
	fi

	# Linear interpolation: ceil(clamped / batch_max * grace_max)
	# Integer arithmetic: (clamped * grace_max + batch_max - 1) / batch_max
	local wait_seconds=$(((clamped * grace_max + batch_max - 1) / batch_max))
	[[ "$wait_seconds" -gt "$grace_max" ]] && wait_seconds="$grace_max"

	echo "[pulse-wrapper] Adaptive settle wait (${context_label}): ${dispatched_count} dispatch(es) → waiting ${wait_seconds}s (max ${grace_max}s at ${batch_max}+ dispatches)" >>"$LOGFILE"
	sleep "$wait_seconds"
	return 0
}
