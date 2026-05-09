#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-dispatch-current-state-guardrails.sh -- Current-state dispatch caps.
# =============================================================================

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DISPATCH_CURRENT_STATE_GUARDRAILS_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_CURRENT_STATE_GUARDRAILS_LOADED=1

#######################################
# Count recent current-state signals that should shape launch capacity.
#
# Stdout: "<successes> <failures> <rate_limits> <healthy_prs> <no_dispatchable>".
#######################################
_dispatch_recent_current_state_counts() {
	local override_line="${PULSE_DISPATCH_CURRENT_STATE_COUNTS:-}"
	if [[ -n "$override_line" ]]; then
		printf '%s\n' "$override_line"
		return 0
	fi

	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	local log_file="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	local window_seconds="${PULSE_DISPATCH_CURRENT_STATE_WINDOW_SECONDS:-900}"
	[[ "$window_seconds" =~ ^[0-9]+$ ]] || window_seconds=900
	python3 - "$metrics_file" "$log_file" "$window_seconds" <<'PY'
import json
import sys
import time
from collections import deque

metrics_path, log_path, window = sys.argv[1], sys.argv[2], int(sys.argv[3])
since = time.time() - window
successes = failures = rate_limits = 0
try:
    with open(metrics_path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in deque(handle, 2000):
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            ts = float(item.get("ts") or 0)
            if ts < since:
                continue
            result = str(item.get("result") or "")
            failure_reason = str(item.get("failure_reason") or "")
            provider_error_type = str(item.get("provider_error_type") or "")
            provider_status = str(item.get("provider_status") or "")
            exit_code = item.get("exit_code")
            if result == "success" and exit_code == 0:
                successes += 1
            elif result not in {"worker_noop", "no_work", "noop"}:
                failures += 1
            if result in {"rate_limit", "rate_limit_fast"} or "rate_limit" in failure_reason or provider_error_type == "rate_limit" or provider_status == "429":
                rate_limits += 1
except (OSError, ValueError):
    pass

healthy_prs = no_dispatchable = 0
try:
    # pulse.log lines usually do not carry machine timestamps, so use the recent tail
    # as a bounded local current-state proxy rather than issuing API reads.
    with open(log_path, "r", encoding="utf-8", errors="replace") as handle:
        lines = deque(handle, 2000)
    for raw in lines:
        line = raw.lower()
        if "pr opened" in line or "opened pr" in line or "pr merged" in line or "merged pr" in line:
            healthy_prs += 1
        if "no ranked candidates" in line or "no eligible candidates" in line or "no dispatchable" in line:
            no_dispatchable += 1
except OSError:
    pass

print(f"{successes} {failures} {rate_limits} {healthy_prs} {no_dispatchable}")
PY
	return 0
}

#######################################
# Apply current-state guardrails to available worker slots.
#
# Args:
#   $1 - max workers
#   $2 - active workers
#   $3 - available slots
# Stdout: "<max_workers> <active_workers> <available_slots>" after capping.
#######################################
_dispatch_apply_current_state_guardrails() {
	local max_workers="$1"
	local active_workers="$2"
	local available_slots="$3"
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$available_slots" =~ ^-?[0-9]+$ ]] || available_slots=0

	if [[ "${AIDEVOPS_SKIP_PULSE_CURRENT_STATE_GUARDRAILS:-0}" == "1" || "$available_slots" -le 0 ]]; then
		printf '%s %s %s\n' "$max_workers" "$active_workers" "$available_slots"
		return 0
	fi

	local counts_line="" successes="" failures="" rate_limits="" healthy_prs="" no_dispatchable=""
	counts_line=$(_dispatch_recent_current_state_counts) || counts_line="0 0 0 0 0"
	read -r successes failures rate_limits healthy_prs no_dispatchable <<<"$counts_line"
	[[ "$successes" =~ ^[0-9]+$ ]] || successes=0
	[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
	[[ "$rate_limits" =~ ^[0-9]+$ ]] || rate_limits=0
	[[ "$healthy_prs" =~ ^[0-9]+$ ]] || healthy_prs=0
	[[ "$no_dispatchable" =~ ^[0-9]+$ ]] || no_dispatchable=0

	local rl_threshold="${PULSE_DISPATCH_GUARDRAIL_RATE_LIMIT_THRESHOLD:-4}"
	local failure_threshold="${PULSE_DISPATCH_GUARDRAIL_FAILURE_THRESHOLD:-6}"
	local pr_threshold="${PULSE_DISPATCH_GUARDRAIL_HEALTHY_PR_THRESHOLD:-3}"
	local empty_threshold="${PULSE_DISPATCH_GUARDRAIL_NO_DISPATCHABLE_THRESHOLD:-2}"
	[[ "$rl_threshold" =~ ^[0-9]+$ ]] || rl_threshold=4
	[[ "$failure_threshold" =~ ^[0-9]+$ ]] || failure_threshold=6
	[[ "$pr_threshold" =~ ^[0-9]+$ ]] || pr_threshold=3
	[[ "$empty_threshold" =~ ^[0-9]+$ ]] || empty_threshold=2

	local capped_slots="$available_slots" reason=""
	if ((empty_threshold > 0 && no_dispatchable >= empty_threshold && successes == 0)); then
		capped_slots=0
		reason="no_dispatchable_evidence"
	elif ((rl_threshold > 0 && rate_limits >= rl_threshold && successes == 0)); then
		capped_slots=0
		reason="provider_rate_limit_pressure"
	elif ((rl_threshold > 0 && rate_limits >= rl_threshold && capped_slots > 1)); then
		capped_slots=1
		reason="provider_rate_limit_pressure"
	elif ((failure_threshold > 0 && failures >= failure_threshold && successes == 0)); then
		capped_slots=0
		reason="repeated_failure_pressure"
	elif ((failure_threshold > 0 && failures >= failure_threshold && capped_slots > 1)); then
		capped_slots=1
		reason="repeated_failure_pressure"
	elif ((pr_threshold > 0 && healthy_prs >= pr_threshold && failures > successes && capped_slots > 1)); then
		capped_slots=1
		reason="healthy_pr_backlog"
	fi

	if ((capped_slots < available_slots)); then
		max_workers=$((active_workers + capped_slots))
		echo "[pulse-wrapper] Dispatch current-state guardrail: reason=${reason} capped_available=${capped_slots}/${available_slots} successes=${successes} failures=${failures} rate_limits=${rate_limits} healthy_prs=${healthy_prs} no_dispatchable=${no_dispatchable}" >>"$LOGFILE"
		_dispatch_stats_increment "pulse_dispatch_current_state_guardrail_applied"
		_dispatch_stats_increment_candidate_failed "$reason"
	fi
	_dispatch_stats_gauge "pulse_dispatch_guardrail_available_slots" "$capped_slots"

	printf '%s %s %s\n' "$max_workers" "$active_workers" "$capped_slots"
	return 0
}
