#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-idle-backoff-helper.sh — Adaptive backoff for idle pulse cycles (t3027)
# =============================================================================
#
# Background (GH#21584):
#   The pulse fires every PULSE_MIN_INTERVAL_S (default 90s) regardless of
#   whether the prior cycle did any work. Production data over a 4-day
#   sample showed 70.5% of cycles (1457/2066) ended with dispatched=0 —
#   each consuming 100-200 GraphQL points on prefetch_state, accumulating
#   to circuit-breaker fires (50+ in 3 days). A static interval is the
#   wrong default for an event-driven system whose load is bursty.
#
# Design:
#   Track consecutive idle cycles in a small state file. When the count
#   crosses a threshold, extend the effective minimum interval. Reset to
#   the base interval on the first active cycle. Schedule (env-overridable):
#
#       0-4 idle:    90s   (base, no backoff)
#       5-9:        180s   (~2x)
#      10-19:       300s   (~3x)
#      20-29:       600s   (~7x)
#      30+:        1800s   (cap = 20x)
#
#   This compresses high-idle-ratio backlogs into ~20% of their original
#   GraphQL cost while staying responsive: any active cycle resets the
#   backoff to base immediately.
#
# Why a separate helper (not inline):
#   - Testable in isolation (test-pulse-idle-backoff.sh).
#   - Can be invoked from interactive sessions / diagnostics
#     (`pulse-idle-backoff-helper.sh status`) without sourcing pulse-wrapper.sh.
#   - Mirrors the pulse-runner-health-helper.sh / pulse-rate-limit-circuit-breaker.sh
#     pattern (state file + tiny CLI surface, called from pulse-wrapper.sh
#     gates).
#
# CLI:
#   pulse-idle-backoff-helper.sh record-cycle <idle|active>
#       Update consecutive-idle counter based on cycle outcome. Emits to
#       stderr a one-line summary; never prints to stdout (other code may
#       capture stdout). Exit 0 always.
#
#   pulse-idle-backoff-helper.sh should-skip <last-run-epoch>
#       Decide whether the next cycle should be skipped because the
#       effective backoff interval has not elapsed since <last-run-epoch>.
#       Prints one TSV line to stdout describing the decision:
#         decision=skip|proceed effective_interval_s=N consecutive_idle=N elapsed_s=N
#       Exit 0 if cycle should be SKIPPED, exit 1 if cycle should PROCEED.
#       (Exit code matches pulse-runner-health-helper.sh::is-paused: 0=block.)
#
#   pulse-idle-backoff-helper.sh state
#       Print state JSON to stdout. Used by diagnostics + tests.
#
#   pulse-idle-backoff-helper.sh status
#       Human-readable summary to stdout.
#
#   pulse-idle-backoff-helper.sh reset
#       Clear state (resets backoff to base). Useful after deploying
#       changes that may invalidate prior idle-cycle measurements.
#
# State file:
#   ${AIDEVOPS_PULSE_IDLE_STATE_FILE:-~/.aidevops/cache/pulse-idle-state.json}
#
# Env overrides:
#   AIDEVOPS_PULSE_IDLE_BASE_INTERVAL_S      (default 90, base interval)
#   AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_5  (default 5,   step-1 trigger)
#   AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_5_S     (default 180, step-1 interval)
#   AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_10 (default 10,  step-2 trigger)
#   AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_10_S    (default 300, step-2 interval)
#   AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_20 (default 20,  step-3 trigger)
#   AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_20_S    (default 600, step-3 interval)
#   AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_30 (default 30,  step-4 trigger)
#   AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_30_S    (default 1800,step-4 interval / cap)
#   AIDEVOPS_SKIP_PULSE_IDLE_BACKOFF         (default 0;   set to 1 to disable
#                                              all backoff — should-skip always
#                                              exits 1 / proceed)
#
# Failure mode:
#   Fail-OPEN. Any I/O error, malformed JSON, missing jq, etc. → should-skip
#   exits 1 (proceed with cycle). The pulse must never be wedged closed by
#   this helper. record-cycle silently no-ops on failure. status / state
#   may print partial info but always exit 0.
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
_PIB_BASE_INTERVAL_S="${AIDEVOPS_PULSE_IDLE_BASE_INTERVAL_S:-90}"
_PIB_THRESHOLD_5="${AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_5:-5}"
_PIB_STEP_5_S="${AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_5_S:-180}"
_PIB_THRESHOLD_10="${AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_10:-10}"
_PIB_STEP_10_S="${AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_10_S:-300}"
_PIB_THRESHOLD_20="${AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_20:-20}"
_PIB_STEP_20_S="${AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_20_S:-600}"
_PIB_THRESHOLD_30="${AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_30:-30}"
_PIB_STEP_30_S="${AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_30_S:-1800}"

_PIB_STATE_FILE="${AIDEVOPS_PULSE_IDLE_STATE_FILE:-${HOME}/.aidevops/cache/pulse-idle-state.json}"

# Sentinel string for missing/unparseable last-cycle outcome. Centralised so
# jq-default, bash-fallback, and synthesised-state JSON all reference one
# source of truth (S1192 ratchet — keeps the literal under the threshold).
_PIB_OUTCOME_UNKNOWN="unknown"

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

# _pib_ensure_dir — best-effort mkdir for state file parent directory.
_pib_ensure_dir() {
	local _dir
	_dir=$(dirname "$_PIB_STATE_FILE")
	mkdir -p "$_dir" 2>/dev/null || true
	return 0
}

# _pib_read_count — return current consecutive_idle count, 0 on any failure.
_pib_read_count() {
	if [[ ! -f "$_PIB_STATE_FILE" ]]; then
		printf '0\n'
		return 0
	fi
	local _count
	_count=$(jq -r '.consecutive_idle // 0' "$_PIB_STATE_FILE" 2>/dev/null) || _count=0
	[[ "$_count" =~ ^[0-9]+$ ]] || _count=0
	printf '%s\n' "$_count"
	return 0
}

# _pib_read_last_outcome — return last cycle outcome (active/idle/sentinel).
_pib_read_last_outcome() {
	if [[ ! -f "$_PIB_STATE_FILE" ]]; then
		printf '%s\n' "$_PIB_OUTCOME_UNKNOWN"
		return 0
	fi
	local _outcome
	_outcome=$(jq -r ".last_cycle_outcome // \"${_PIB_OUTCOME_UNKNOWN}\"" "$_PIB_STATE_FILE" 2>/dev/null) || _outcome="$_PIB_OUTCOME_UNKNOWN"
	printf '%s\n' "$_outcome"
	return 0
}

# _pib_compute_interval <consecutive_idle> — print effective interval seconds.
# Pure function: no I/O. Schedule defined in module header.
_pib_compute_interval() {
	local _idle="${1:-0}"
	[[ "$_idle" =~ ^[0-9]+$ ]] || _idle=0

	if [[ "$_idle" -ge "$_PIB_THRESHOLD_30" ]]; then
		printf '%s\n' "$_PIB_STEP_30_S"
		return 0
	fi
	if [[ "$_idle" -ge "$_PIB_THRESHOLD_20" ]]; then
		printf '%s\n' "$_PIB_STEP_20_S"
		return 0
	fi
	if [[ "$_idle" -ge "$_PIB_THRESHOLD_10" ]]; then
		printf '%s\n' "$_PIB_STEP_10_S"
		return 0
	fi
	if [[ "$_idle" -ge "$_PIB_THRESHOLD_5" ]]; then
		printf '%s\n' "$_PIB_STEP_5_S"
		return 0
	fi
	printf '%s\n' "$_PIB_BASE_INTERVAL_S"
	return 0
}

# _pib_write_state <consecutive_idle> <last_outcome>
# Atomic write via temp file + mv. Fail-open on any I/O error.
_pib_write_state() {
	local _idle="${1:-0}"
	local _outcome="${2:-${_PIB_OUTCOME_UNKNOWN}}"
	[[ "$_idle" =~ ^[0-9]+$ ]] || _idle=0
	case "$_outcome" in
		active|idle|"${_PIB_OUTCOME_UNKNOWN}") ;;
		*) _outcome="$_PIB_OUTCOME_UNKNOWN" ;;
	esac

	_pib_ensure_dir

	local _now
	_now=$(date +%s 2>/dev/null) || _now=0

	local _interval
	_interval=$(_pib_compute_interval "$_idle")

	local _tmp
	_tmp=$(mktemp "${_PIB_STATE_FILE}.XXXXXX") || return 0

	cat >"$_tmp" 2>/dev/null <<EOF
{
  "consecutive_idle": ${_idle},
  "last_cycle_outcome": "${_outcome}",
  "last_update_epoch": ${_now},
  "current_effective_interval_s": ${_interval},
  "_schema_version": 1
}
EOF

	mv "$_tmp" "$_PIB_STATE_FILE" 2>/dev/null || rm -f "$_tmp"
	return 0
}

# -----------------------------------------------------------------------------
# CLI commands
# -----------------------------------------------------------------------------

cmd_record_cycle() {
	local _outcome="${1:-}"
	if [[ -z "$_outcome" ]]; then
		echo "Usage: $0 record-cycle <idle|active>" >&2
		return 0
	fi
	case "$_outcome" in
		idle|active) ;;
		*)
			echo "[pulse-idle-backoff] record-cycle: invalid outcome '$_outcome' (expected idle|active)" >&2
			return 0
			;;
	esac

	local _count
	_count=$(_pib_read_count)
	local _new_count
	if [[ "$_outcome" == "idle" ]]; then
		_new_count=$((_count + 1))
	else
		# active cycle — reset the backoff to base
		_new_count=0
	fi

	_pib_write_state "$_new_count" "$_outcome"

	local _interval
	_interval=$(_pib_compute_interval "$_new_count")
	echo "[pulse-idle-backoff] outcome=${_outcome} consecutive_idle=${_new_count} effective_interval_s=${_interval}" >&2
	return 0
}

cmd_should_skip() {
	# Fail-OPEN gate: any error path returns exit 1 (proceed with cycle).
	# The pulse must never be wedged closed by this helper.
	if [[ "${AIDEVOPS_SKIP_PULSE_IDLE_BACKOFF:-0}" == "1" ]]; then
		printf 'decision=proceed reason=disabled effective_interval_s=%s consecutive_idle=0 elapsed_s=unknown\n' \
			"$_PIB_BASE_INTERVAL_S"
		return 1
	fi

	local _last_run="${1:-0}"
	[[ "$_last_run" =~ ^[0-9]+$ ]] || _last_run=0

	if [[ "$_last_run" -eq 0 ]]; then
		# No prior run timestamp known → proceed (cold start).
		printf 'decision=proceed reason=no_prior_run effective_interval_s=%s consecutive_idle=0 elapsed_s=unknown\n' \
			"$_PIB_BASE_INTERVAL_S"
		return 1
	fi

	local _now
	_now=$(date +%s 2>/dev/null) || _now=0
	local _elapsed=$(( _now - _last_run ))
	[[ "$_elapsed" -lt 0 ]] && _elapsed=0

	local _count
	_count=$(_pib_read_count)
	local _interval
	_interval=$(_pib_compute_interval "$_count")

	# Base interval has its own gate upstream (PULSE_MIN_INTERVAL_S). This
	# helper only adds backoff when the effective interval EXCEEDS the base
	# AND the elapsed time hasn't reached the effective interval.
	if [[ "$_interval" -le "$_PIB_BASE_INTERVAL_S" ]]; then
		printf 'decision=proceed reason=no_backoff_active effective_interval_s=%s consecutive_idle=%s elapsed_s=%s\n' \
			"$_interval" "$_count" "$_elapsed"
		return 1
	fi

	if [[ "$_elapsed" -lt "$_interval" ]]; then
		printf 'decision=skip reason=backoff_active effective_interval_s=%s consecutive_idle=%s elapsed_s=%s\n' \
			"$_interval" "$_count" "$_elapsed"
		return 0
	fi

	printf 'decision=proceed reason=interval_elapsed effective_interval_s=%s consecutive_idle=%s elapsed_s=%s\n' \
		"$_interval" "$_count" "$_elapsed"
	return 1
}

# ---------------------------------------------------------------------------
# _pib_synthesise_empty_state <flag-name>
#
# Emit a synthesised empty-state JSON record with one of the diagnostic
# flags set to true (`_state_file_missing` or `_state_file_malformed`).
# Centralised here so the JSON shape (keys, schema version) is defined in
# exactly one place — the only OTHER place these keys appear is the live
# state writer in `_pib_write_state`. Two occurrences each keeps us under
# the duplicate-string-literal ratchet threshold.
# ---------------------------------------------------------------------------
_pib_synthesise_empty_state() {
	local _flag="$1"
	printf '{"consecutive_idle":0,"last_cycle_outcome":"%s","last_update_epoch":0,"current_effective_interval_s":%s,"_schema_version":1,"%s":true}\n' \
		"$_PIB_OUTCOME_UNKNOWN" "$_PIB_BASE_INTERVAL_S" "$_flag"
	return 0
}

cmd_state() {
	if [[ ! -f "$_PIB_STATE_FILE" ]]; then
		_pib_synthesise_empty_state "_state_file_missing"
		return 0
	fi
	if jq -c . "$_PIB_STATE_FILE" 2>/dev/null; then
		return 0
	fi
	# malformed file — print synthesized empty state and continue
	_pib_synthesise_empty_state "_state_file_malformed"
	return 0
}

cmd_status() {
	local _count _outcome _interval
	_count=$(_pib_read_count)
	_outcome=$(_pib_read_last_outcome)
	_interval=$(_pib_compute_interval "$_count")

	printf 'pulse-idle-backoff status\n'
	printf '  consecutive_idle:        %s cycle(s)\n' "$_count"
	printf '  last_cycle_outcome:      %s\n' "$_outcome"
	printf '  effective_interval_s:    %s (base=%s)\n' "$_interval" "$_PIB_BASE_INTERVAL_S"
	printf '  state_file:              %s\n' "$_PIB_STATE_FILE"

	if [[ -f "$_PIB_STATE_FILE" ]]; then
		local _ts
		_ts=$(jq -r '.last_update_epoch // 0' "$_PIB_STATE_FILE" 2>/dev/null) || _ts=0
		[[ "$_ts" =~ ^[0-9]+$ ]] || _ts=0
		if [[ "$_ts" -gt 0 ]]; then
			local _now _age
			_now=$(date +%s 2>/dev/null) || _now=0
			_age=$(( _now - _ts ))
			printf '  last_update_age_s:       %s\n' "$_age"
		fi
	fi
	return 0
}

cmd_reset() {
	if [[ -f "$_PIB_STATE_FILE" ]]; then
		rm -f "$_PIB_STATE_FILE" 2>/dev/null || true
	fi
	echo "[pulse-idle-backoff] state reset" >&2
	return 0
}

cmd_help() {
	cat <<'EOF'
pulse-idle-backoff-helper.sh — Adaptive backoff for idle pulse cycles (t3027)

USAGE:
  pulse-idle-backoff-helper.sh record-cycle <idle|active>
  pulse-idle-backoff-helper.sh should-skip <last-run-epoch>
  pulse-idle-backoff-helper.sh state
  pulse-idle-backoff-helper.sh status
  pulse-idle-backoff-helper.sh reset
  pulse-idle-backoff-helper.sh help

EXIT CODES:
  record-cycle: always 0
  should-skip:  0 = SKIP cycle (backoff active)
                1 = PROCEED with cycle
  state:        always 0
  status:       always 0
  reset:        always 0

ENVIRONMENT (overrides for backoff schedule):
  AIDEVOPS_PULSE_IDLE_BASE_INTERVAL_S      (default 90)
  AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_5  (default 5)
  AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_5_S     (default 180)
  AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_10 (default 10)
  AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_10_S    (default 300)
  AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_20 (default 20)
  AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_20_S    (default 600)
  AIDEVOPS_PULSE_IDLE_BACKOFF_THRESHOLD_30 (default 30)
  AIDEVOPS_PULSE_IDLE_BACKOFF_STEP_30_S    (default 1800)
  AIDEVOPS_SKIP_PULSE_IDLE_BACKOFF         (default 0; set 1 to disable)
  AIDEVOPS_PULSE_IDLE_STATE_FILE           (default ~/.aidevops/cache/pulse-idle-state.json)
EOF
	return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
	local _cmd="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$_cmd" in
		record-cycle) cmd_record_cycle "$@" ;;
		should-skip)  cmd_should_skip "$@"  ;;
		state)        cmd_state            ;;
		status)       cmd_status           ;;
		reset)        cmd_reset            ;;
		help|-h|--help) cmd_help            ;;
		*)
			echo "Unknown command: $_cmd" >&2
			cmd_help >&2
			return 2
			;;
	esac
}

# Only execute main when called directly, not when sourced (for testing).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
	main "$@"
fi
