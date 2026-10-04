#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse wrapper dispatch gates: cross-issue no-work circuit breaker.
# Sourced by pulse-wrapper.sh; requires LOGFILE and optional pulse_stats_increment.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_WRAPPER_DISPATCH_GATES_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_DISPATCH_GATES_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# is_no_work_rate_acceptable — cross-issue no_work rate circuit breaker.
# t2770 (GH#20640): pulse-level rate breaker for no_work storms.
#
# Counts fast_fail_record crash_type=no_work events in a rolling window
# (default: 10 events in 10 minutes). If exceeded, pauses all dispatch for
# this cycle with one alert line — prevents chasing an infrastructure outage
# with more workers that will also fail.
#
# Unlike the per-issue no_work escalation (GH#20639), this fires on population-
# wide anomalies: many DIFFERENT issues returning no_work simultaneously,
# signalling auth outage, GraphQL exhaustion, or wrapper stall recurrence.
#
# State file: ~/.aidevops/logs/pulse-no-work-breaker.state
# Format: line 1 = "EPOCH TOTAL_LOG_COUNT"; line 2+ = epoch timestamps of
# no_work events in the rolling window (pruned on each check).
#
# Counter: pulse_dispatch_no_work_breaker_tripped in pulse-stats.json
#
# Exit codes:
#   0 — rate acceptable; dispatch may proceed
#   1 — no_work rate exceeded; dispatch should be deferred this cycle
#
# Environment overrides:
#   AIDEVOPS_NO_WORK_WINDOW_SECS  — rolling window duration (default 600)
#   AIDEVOPS_NO_WORK_WINDOW_MAX   — max events in window (default 10; 0=disable)
#   AIDEVOPS_SKIP_NO_WORK_BREAKER=1 — emergency bypass
#######################################
is_no_work_rate_acceptable() {
	# Emergency bypass.
	if [[ "${AIDEVOPS_SKIP_NO_WORK_BREAKER:-0}" == "1" ]]; then
		echo "[pulse-wrapper] AIDEVOPS_SKIP_NO_WORK_BREAKER=1 — bypassing no_work rate check (t2770)" >>"$LOGFILE"
		return 0
	fi

	local window_secs="${NO_WORK_WINDOW_SECS:-600}"
	local max_events="${NO_WORK_WINDOW_MAX:-10}"
	window_secs="${AIDEVOPS_NO_WORK_WINDOW_SECS:-$window_secs}"
	max_events="${AIDEVOPS_NO_WORK_WINDOW_MAX:-$max_events}"

	# Disabled if max is 0.
	if [[ "$max_events" -eq 0 ]]; then
		return 0
	fi

	local state_file="${HOME}/.aidevops/logs/pulse-no-work-breaker.state"
	local logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	local now
	now=$(date +%s)
	local cutoff=$((now - window_secs))

	# Count total no_work events in pulse.log (grep -c exits 1 on zero matches).
	local current_count=0
	if [[ -f "$logfile" ]]; then
		current_count=$(grep -c "crash_type=no_work" "$logfile" 2>/dev/null) || current_count=0
		[[ "$current_count" =~ ^[0-9]+$ ]] || current_count=0
	fi

	# Read state file: line 1 = last_scan_epoch last_total_count;
	# subsequent lines = epoch timestamps of recent no_work events.
	local last_total=0
	local -a window_timestamps=()
	if [[ -f "$state_file" ]]; then
		local sf_epoch="" sf_count=""
		read -r sf_epoch sf_count <"$state_file" 2>/dev/null || true
		[[ "$sf_epoch" =~ ^[0-9]+$ ]] || sf_epoch="0"
		[[ "$sf_count" =~ ^[0-9]+$ ]] || sf_count="0"
		last_total="$sf_count"

		# Load timestamps from state file (lines 2+), pruning those outside window.
		local ts_line
		while IFS= read -r ts_line; do
			[[ "$ts_line" =~ ^[0-9]+$ ]] || continue
			[[ "$ts_line" -ge "$cutoff" ]] && window_timestamps+=("$ts_line")
		done < <(tail -n +2 "$state_file" 2>/dev/null) || true
	fi

	# Compute new events since last check.
	local new_events=0
	if [[ "$current_count" -lt "$last_total" ]]; then
		# Log was rotated — reset baseline, treat all current events as new.
		last_total=0
	fi
	if [[ "$current_count" -gt "$last_total" ]]; then
		new_events=$((current_count - last_total))
	fi
	# Cap to max_events to bound state file growth.
	if [[ "$new_events" -gt "$max_events" ]]; then
		new_events="$max_events"
	fi

	# Append current timestamp for each new event.
	local i=0
	while [[ "$i" -lt "$new_events" ]]; do
		window_timestamps+=("$now")
		i=$((i + 1))
	done

	local window_count=${#window_timestamps[@]}

	# Write updated state file (atomic via temp file).
	local tmp_state="${state_file}.tmp.$$"
	{
		printf '%s %s\n' "$now" "$current_count"
		local ts
		for ts in ${window_timestamps[@]+"${window_timestamps[@]}"}; do
			printf '%s\n' "$ts"
		done
	} >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$state_file" 2>/dev/null || rm -f "$tmp_state" 2>/dev/null || true

	# Check threshold.
	if [[ "$window_count" -ge "$max_events" ]]; then
		echo "[pulse-wrapper] no_work rate circuit breaker TRIPPED: ${window_count} events in ${window_secs}s window (max=${max_events}) — deferring dispatch this cycle (t2770)" >>"$LOGFILE"

		# Increment stats counter.
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_dispatch_no_work_breaker_tripped" 2>/dev/null || true
		fi

		return 1
	fi

	return 0
}
