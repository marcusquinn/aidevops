#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-dispatch-lib.sh -- Fill-floor helpers for dispatch_max
# =============================================================================
# Sub-library extracted from pulse-dispatch-engine.sh (GH#21738) so the
# orchestrator stays under the 1500-line file-size threshold. Contains all
# `_dispatch_*` helper functions plus the shared debug logger that supports
# `dispatch_max` (which remains in the orchestrator
# because its 110-line body would re-register as a new function-complexity
# violation if moved).
#
# Module-level `_DISPATCH_*` round-state counters are defined here so the helpers
# and orchestrator share a single source of truth via the `_DISPATCH_` prefix
# (avoids bash 4.3+ namerefs).
#
# Usage: source "${SCRIPT_DIR}/pulse-dispatch-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (LOGFILE, color/status helpers, gh wrappers)
#   - worker-lifecycle-common.sh (capacity helpers, model resolution)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_DISPATCH_FILL_FLOOR_LIB_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_FILL_FLOOR_LIB_LOADED=1

# --- Helper functions and module-level round-state vars (extracted) ---

# -----------------------------------------------------------------------------
# Helpers for dispatch_max (GH#18656)
# -----------------------------------------------------------------------------
# The helpers below are split out so the orchestrator stays under 100 lines
# and each discrete responsibility (capacity planning, pre-passes, per-candidate
# skip checks, launch-outcome tracking, post-round throttle) can be read and
# reviewed in isolation. Behavior is byte-for-byte equivalent to the pre-split
# monolithic function — see git log for the refactor commit.
#
# The round-state counters (_round_dispatched, _round_no_worker_failures,
# _consecutive_no_worker) are module-level with a `_DISPATCH_` prefix so the
# helpers can update them without needing bash 4.3+ namerefs.

_DISPATCH_ROUND_DISPATCHED=0
_DISPATCH_ROUND_NO_WORKER_FAILURES=0
_DISPATCH_CONSECUTIVE_NO_WORKER=0
_DISPATCH_THROTTLE_FILE=""
_DISPATCH_CANARY_CACHE=""
# Out-parameter set by _dispatch_process_candidate when a successful launch clears
# the throttle file. The orchestrator loop reads this and restores
# _effective_slots to the unthrottled available_slots value.
_DISPATCH_THROTTLE_CLEARED=0

#######################################
# Emit per-candidate debug output for the dispatch_max (GH#18804).
#
# Always writes to LOGFILE (so the operator sees it in pulse.log). When
# PULSE_DEBUG is set to a truthy value, the message is prefixed with DEBUG:
# and emitted unconditionally — useful for one-off operator runs that need
# verbose per-candidate visibility into label state, dedup probes, and skip
# decisions.
#
# Arguments:
#   $1 - message body (plain text, no leading prefix)
# Returns: 0 always
#######################################
pulse_dispatch_debug_log() {
	local message="$1"
	case "${PULSE_DEBUG:-}" in
	1 | true | TRUE | yes | YES | on | ON)
		echo "[pulse-wrapper] DFF DEBUG: ${message}" >>"$LOGFILE"
		;;
	esac
	return 0
}

#######################################
# Increment a pulse-stats counter when the stats helper is loaded.
#
# Arguments:
#   $1 - counter name
# Returns: 0 always (telemetry must never block dispatch).
#######################################
_dispatch_stats_increment() {
	local counter_name="$1"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "$counter_name" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Increment the aggregate dispatch-candidate failure counter plus a stable
# reason-coded counter.
#
# Arguments:
#   $1 - low-cardinality reason token
# Returns: 0 always (telemetry must never block dispatch).
#######################################
_dispatch_stats_increment_candidate_failed() {
	local reason="$1"
	case "$reason" in
		dedup_active_claim | cost_budget_exceeded | cooldown_no_worker_process | graphql_circuit_breaker | runner_health_circuit_breaker | ever_nmr_without_approval | canary_failed | launch_error | missing_worker_context | local_capacity_gate | policy_gate | no_recent_log_evidence | provider_rate_limit_pressure | repeated_failure_pressure | healthy_pr_backlog | no_dispatchable_evidence | unclassified_signal)
			;;
		*)
			reason="unclassified_signal"
			;;
	esac
	_dispatch_stats_increment "dispatch_candidate_failed"
	_dispatch_stats_increment "dispatch_candidate_failed_reason_${reason}"
	return 0
}

#######################################
# Classify a failed dispatch_with_dedup return using recent candidate log lines.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - dispatch rc
# Stdout: low-cardinality reason token
#######################################
_dispatch_candidate_failure_reason() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_rc="$3"
	local recent_lines=""
	local reason="no_recent_log_evidence"

	if [[ "$dispatch_rc" -eq 124 ]]; then
		printf 'launch_error\n'
		return 0
	fi
	if [[ "$dispatch_rc" -eq 2 ]]; then
		printf 'canary_failed\n'
		return 0
	fi

	if [[ -n "${LOGFILE:-}" && -f "$LOGFILE" ]]; then
		recent_lines=$(awk -v issue="#${issue_number}" -v repo="$repo_slug" '
			index($0, issue) && index($0, repo) { lines[++n] = $0 }
			END {
				start = n - 20
				if (start < 1) { start = 1 }
				for (i = start; i <= n; i++) { print lines[i] }
			}
		' "$LOGFILE" 2>/dev/null) || recent_lines=""
	fi

	if [[ "$recent_lines" == *"has active dispatch comment"* || "$recent_lines" == *"active claim"* ]]; then
		printf 'dedup_active_claim\n'
		return 0
	fi

	if [[ "$recent_lines" == *"DISPATCH_BLOCK_REASON reason="* ]]; then
		reason=$(printf '%s\n' "$recent_lines" | awk '
			match($0, /DISPATCH_BLOCK_REASON reason=[a-z_]+/) {
				reason = substr($0, RSTART, RLENGTH)
				sub(/^DISPATCH_BLOCK_REASON reason=/, "", reason)
			}
			END { if (reason != "") { print reason } }
		') || reason="unclassified_signal"
		[[ -n "$reason" ]] || reason="unclassified_signal"
		printf '%s\n' "$reason"
		return 0
	fi

	if [[ -x "${SCRIPT_DIR:-}/dispatch-dedup-helper.sh" && -n "$recent_lines" ]]; then
		reason=$("${SCRIPT_DIR}/dispatch-dedup-helper.sh" classify-blocker "$recent_lines" 2>/dev/null) || reason="unclassified_signal"
		[[ -n "$reason" ]] || reason="unclassified_signal"
	fi

	printf '%s\n' "$reason"
	return 0
}

#######################################
# Set a pulse-stats gauge when the stats helper is loaded.
#
# Arguments:
#   $1 - gauge name
#   $2 - integer value
# Returns: 0 always (telemetry must never block dispatch).
#######################################
_dispatch_stats_gauge() {
	local gauge_name="$1"
	local gauge_value="${2:-0}"
	if declare -F pulse_stats_set_gauge >/dev/null 2>&1; then
		pulse_stats_set_gauge "$gauge_name" "$gauge_value" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Return the latest numeric headless-runtime metric value for a key.
#
# Arguments:
#   $1 - metric key
# Stdout: numeric value, or blank when unavailable.
#######################################
_dispatch_latest_metric_value() {
	local metric_key="$1"
	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	[[ -f "$metrics_file" ]] || { printf '\n'; return 0; }
	python3 - "$metrics_file" "$metric_key" <<'PY'
import json
import sys
from collections import deque

path, key = sys.argv[1], sys.argv[2]
value = ""
try:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in deque(handle, 1000):
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            candidate = item.get(key)
            if isinstance(candidate, (int, float)):
                value = str(candidate)
except OSError:
    pass
print(value)
PY
	return 0
}

#######################################
# Count recent worker failure/rate-limit metrics for launch pacing.
#
# Stdout: "<failures> <rate_limits>".
#######################################
_dispatch_recent_worker_pressure_counts() {
	local failure_override="${PULSE_DISPATCH_STAGGER_RECENT_FAILURES:-}"
	local rate_limit_override="${PULSE_DISPATCH_STAGGER_RECENT_RATE_LIMITS:-}"
	if [[ "$failure_override" =~ ^[0-9]+$ || "$rate_limit_override" =~ ^[0-9]+$ ]]; then
		[[ "$failure_override" =~ ^[0-9]+$ ]] || failure_override=0
		[[ "$rate_limit_override" =~ ^[0-9]+$ ]] || rate_limit_override=0
		printf '%s %s\n' "$failure_override" "$rate_limit_override"
		return 0
	fi

	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	local ttl_seconds="${PULSE_DISPATCH_STAGGER_FAILURE_WINDOW_SECONDS:-900}"
	[[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=900
	[[ -f "$metrics_file" ]] || { printf '0 0\n'; return 0; }
	python3 - "$metrics_file" "$ttl_seconds" <<'PY'
import json
import sys
import time
from collections import deque

path, ttl = sys.argv[1], int(sys.argv[2])
since = time.time() - ttl
failures = 0
rate_limits = 0
try:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw in deque(handle, 1000):
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            ts = float(item.get("ts") or 0)
            if ts < since:
                continue
            result = str(item.get("result") or "")
            failure_reason = str(item.get("failure_reason") or "")
            exit_code = item.get("exit_code")
            if result in {"rate_limit", "rate_limit_fast"} or "rate_limit" in failure_reason:
                rate_limits += 1
            if not (result == "success" and exit_code == 0) and result not in {"worker_noop", "no_work", "noop"}:
                failures += 1
except (OSError, ValueError):
    pass
print(f"{failures} {rate_limits}")
PY
	return 0
}

#######################################
# Return cached GraphQL remaining budget for launch pacing.
#
# Stdout: integer remaining budget, or blank when unavailable.
#######################################
_dispatch_graphql_remaining_cached() {
	if [[ -n "${PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING:-}" ]]; then
		printf '%s\n' "$PULSE_DISPATCH_STAGGER_GRAPHQL_REMAINING"
		return 0
	fi
	if [[ -n "${_DISPATCH_STAGGER_GRAPHQL_REMAINING:-}" ]]; then
		printf '%s\n' "$_DISPATCH_STAGGER_GRAPHQL_REMAINING"
		return 0
	fi
	_DISPATCH_STAGGER_GRAPHQL_REMAINING=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null || printf '\n')
	printf '%s\n' "$_DISPATCH_STAGGER_GRAPHQL_REMAINING"
	return 0
}

_dispatch_float_scaled() {
	local float_value="${1:-0}"
	local fallback="${2:-0}"
	python3 - "$float_value" "$fallback" <<'PY'
import sys
try:
    print(int(float(sys.argv[1]) * 100))
except (ValueError, IndexError):
    print(int(float(sys.argv[2]) * 100))
PY
	return 0
}

_dispatch_load_pressure_points() {
	local load_per_cpu="${PULSE_DISPATCH_STAGGER_LOAD_PER_CPU:-}"
	[[ -n "$load_per_cpu" ]] || load_per_cpu=$(_dispatch_latest_metric_value "load_per_cpu")
	local load_scaled=0 high_scaled moderate_scaled
	[[ -n "$load_per_cpu" ]] && load_scaled=$(_dispatch_float_scaled "$load_per_cpu" 0)
	high_scaled=$(_dispatch_float_scaled "${PULSE_DISPATCH_STAGGER_LOAD_HIGH:-8}" 8)
	moderate_scaled=$(_dispatch_float_scaled "${PULSE_DISPATCH_STAGGER_LOAD_MODERATE:-4}" 4)
	if ((load_scaled >= high_scaled && load_scaled > 0)); then
		printf '4\n'
		return 0
	fi
	if ((load_scaled >= moderate_scaled && load_scaled > 0)); then
		printf '2\n'
		return 0
	fi
	printf '0\n'
	return 0
}

_dispatch_failure_pressure_points() {
	local recent_failures="$1"
	[[ "$recent_failures" =~ ^[0-9]+$ ]] || recent_failures=0
	if ((recent_failures >= 3)); then
		printf '4\n'
		return 0
	fi
	if ((recent_failures >= 1)); then
		printf '2\n'
		return 0
	fi
	printf '0\n'
	return 0
}

_dispatch_provider_pressure_points() {
	local recent_rate_limits="$1"
	local provider_backoff_active="${PULSE_DISPATCH_PROVIDER_BACKOFF_ACTIVE:-0}"
	[[ "$recent_rate_limits" =~ ^[0-9]+$ ]] || recent_rate_limits=0
	if [[ "$provider_backoff_active" == "1" || "$recent_rate_limits" -gt 0 || -f "${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}" ]]; then
		printf '6\n'
		return 0
	fi
	printf '0\n'
	return 0
}

_dispatch_graphql_pressure_points() {
	local graphql_remaining="" graphql_low="" graphql_critical=""
	graphql_remaining=$(_dispatch_graphql_remaining_cached)
	graphql_low="${PULSE_DISPATCH_STAGGER_GRAPHQL_LOW:-1250}"
	graphql_critical="${PULSE_DISPATCH_STAGGER_GRAPHQL_CRITICAL:-750}"
	[[ "$graphql_low" =~ ^[0-9]+$ ]] || graphql_low=1250
	[[ "$graphql_critical" =~ ^[0-9]+$ ]] || graphql_critical=750
	if [[ "$graphql_remaining" =~ ^[0-9]+$ ]]; then
		if ((graphql_remaining < graphql_critical)); then
			printf '4\n'
			return 0
		fi
		if ((graphql_remaining < graphql_low)); then
			printf '2\n'
			return 0
		fi
	fi
	printf '0\n'
	return 0
}

_dispatch_finalize_stagger_delay() {
	local pressure_points="$1"
	local launches_so_far="$2"
	local candidate_index="$3"
	local candidate_json="$4"
	[[ "$pressure_points" =~ ^[0-9]+$ ]] || pressure_points=0
	if ((pressure_points <= 0)); then
		printf '0\n'
		return 0
	fi
	local issue_number="" jitter_max="" jitter="" delay="" cap=""
	issue_number=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
	[[ "$issue_number" =~ ^[0-9]+$ ]] || issue_number=0
	jitter_max="${PULSE_DISPATCH_STAGGER_JITTER_MAX_SECONDS:-3}"
	cap="${PULSE_DISPATCH_STAGGER_MAX_SECONDS:-20}"
	[[ "$jitter_max" =~ ^[0-9]+$ ]] || jitter_max=3
	[[ "$cap" =~ ^[0-9]+$ ]] || cap=20
	jitter=0
	if ((jitter_max > 0)); then
		jitter=$(((issue_number + candidate_index + launches_so_far) % (jitter_max + 1)))
	fi
	delay=$((pressure_points + jitter))
	((delay > cap)) && delay="$cap"
	_dispatch_stats_gauge "dispatch_inter_launch_delay_seconds" "$delay"
	printf '%d\n' "$delay"
	return 0
}

#######################################
# Compute adaptive inter-launch delay for parallel worker dispatch.
#
# Arguments:
#   $1 - launches already started in this round
#   $2 - candidate index in this loop
#   $3 - candidate JSON
#   $4 - max parallelism for this round
# Stdout: integer seconds to sleep before launching this candidate.
#######################################
_dispatch_inter_launch_delay() {
	local launches_so_far="${1:-0}"
	local candidate_index="${2:-0}"
	local candidate_json="${3:-}"
	local max_parallel="${4:-1}"
	[[ "$launches_so_far" =~ ^[0-9]+$ ]] || launches_so_far=0
	[[ "$candidate_index" =~ ^[0-9]+$ ]] || candidate_index=0
	[[ "$max_parallel" =~ ^[0-9]+$ ]] || max_parallel=1
	if [[ "${PULSE_DISPATCH_STAGGER_ADAPTIVE:-1}" == "0" || "$launches_so_far" -eq 0 ]]; then
		printf '0\n'
		return 0
	fi

	local pressure_points=0
	pressure_points=$((pressure_points + $(_dispatch_load_pressure_points)))
	local recent_failures="" recent_rate_limits="" pressure_line=""
	pressure_line=$(_dispatch_recent_worker_pressure_counts)
	read -r recent_failures recent_rate_limits <<<"$pressure_line"
	[[ "$recent_failures" =~ ^[0-9]+$ ]] || recent_failures=0
	[[ "$recent_rate_limits" =~ ^[0-9]+$ ]] || recent_rate_limits=0
	pressure_points=$((pressure_points + $(_dispatch_failure_pressure_points "$recent_failures")))
	pressure_points=$((pressure_points + $(_dispatch_provider_pressure_points "$recent_rate_limits")))
	pressure_points=$((pressure_points + $(_dispatch_graphql_pressure_points)))

	if ((max_parallel >= 4 && launches_so_far >= 4 && pressure_points > 0)); then
		pressure_points=$((pressure_points + 1))
	fi
	_dispatch_finalize_stagger_delay "$pressure_points" "$launches_so_far" "$candidate_index" "$candidate_json"
	return 0
}

#######################################
# Compute the dispatch capacity for this round.
#
# Stdout: "<max_workers> <active_workers> <available_slots>" on success.
# Returns:
#   0 - capacity computed (caller checks available_slots > 0 before dispatch)
#   1 - stop flag present; caller should short-circuit
#######################################
_dispatch_compute_capacity() {
	_DISPATCH_MIN_WORKER_FLOOR_ACTIVE=0
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Dispatch_max skipped: stop flag present" >>"$LOGFILE"
		return 1
	fi

	# t2690/t3424: Proactive rate-limit circuit breaker — pause dispatch when
	# GraphQL budget is nearly exhausted unless REST-backed dispatch fallback is
	# active and REST core has enough headroom for issue/comment/label calls.
	if declare -F is_graphql_budget_sufficient >/dev/null 2>&1; then
		local _cb_rc=0
		is_graphql_budget_sufficient || _cb_rc=$?
		if [[ "$_cb_rc" -eq 1 ]]; then
			echo "[pulse-wrapper] Dispatch_max skipped: GraphQL rate-limit circuit breaker tripped (t2690)" >>"$LOGFILE"
			_dispatch_stats_increment "dispatch_graphql_circuit_blocked"
			return 1
		fi
		# _cb_rc == 2 means API error — fail-open, proceed with dispatch.
	fi

	local max_workers="" active_workers="" available_slots=""
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0

	# t3418/GH#23038: Keep a minimum implementation worker floor eligible only
	# while provider/account health and host load are good enough. The pressure
	# helper caps the final target by OAuth account availability, recent
	# provider failures, load, and long-session runway before dispatch slots are
	# exposed to the candidate loop.
	local min_worker_floor="${AIDEVOPS_MIN_WORKER_CONCURRENCY:-6}"
	if ! [[ "$min_worker_floor" =~ ^[0-9]+$ ]]; then
		min_worker_floor=6
	fi
	if declare -F pulse_apply_provider_load_capacity_cap >/dev/null 2>&1; then
		local capacity_cap_line=""
		capacity_cap_line=$(pulse_apply_provider_load_capacity_cap "$max_workers" "$active_workers" "$min_worker_floor") || capacity_cap_line="${max_workers} 0"
		read -r max_workers _DISPATCH_MIN_WORKER_FLOOR_ACTIVE <<<"$capacity_cap_line"
		[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
		[[ "$_DISPATCH_MIN_WORKER_FLOOR_ACTIVE" =~ ^[0-9]+$ ]] || _DISPATCH_MIN_WORKER_FLOOR_ACTIVE=0
	elif ((min_worker_floor > 0 && active_workers < min_worker_floor)); then
		_DISPATCH_MIN_WORKER_FLOOR_ACTIVE=1
		if ((max_workers < min_worker_floor)); then
			echo "[pulse-wrapper] Dispatch_min_floor active: max_workers=${max_workers} raised to ${min_worker_floor} while active=${active_workers}" >>"$LOGFILE"
			max_workers="$min_worker_floor"
		fi
	fi
	available_slots=$((max_workers - active_workers))

	local guardrail_line=""
	guardrail_line=$(_dispatch_apply_current_state_guardrails "$max_workers" "$active_workers" "$available_slots") || guardrail_line="${max_workers} ${active_workers} ${available_slots}"
	read -r max_workers active_workers available_slots <<<"$guardrail_line"
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$available_slots" =~ ^-?[0-9]+$ ]] || available_slots=0

	printf '%s %s %s\n' "$max_workers" "$active_workers" "$available_slots"
	return 0
}

#######################################
# Run the triage + enrichment pre-passes, subtracting their dispatches from the
# implementation slot budget. Triage runs first (community responsiveness) and
# enrichment runs second (so enriched issues get better context on the next
# attempt).
#
# Arguments:
#   $1 - available slots before pre-passes
# Stdout: "<remaining_slots> <triage_dispatched>"
#######################################
_dispatch_run_prepasses() {
	local available_slots="$1"

	local triage_remaining
	triage_remaining=$(dispatch_triage_reviews "$available_slots" 2>>"$LOGFILE") || triage_remaining="$available_slots"
	[[ "$triage_remaining" =~ ^[0-9]+$ ]] || triage_remaining="$available_slots"
	local triage_dispatched=$((available_slots - triage_remaining))
	if [[ "$triage_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: dispatched ${triage_dispatched} triage review(s), ${triage_remaining} slots remaining for implementation" >>"$LOGFILE"
	fi
	available_slots="$triage_remaining"

	local enrichment_remaining
	enrichment_remaining=$(dispatch_enrichment_workers "$available_slots" 2>>"$LOGFILE") || enrichment_remaining="$available_slots"
	[[ "$enrichment_remaining" =~ ^[0-9]+$ ]] || enrichment_remaining="$available_slots"
	local enrichment_dispatched=$((available_slots - enrichment_remaining))
	if [[ "$enrichment_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: dispatched ${enrichment_dispatched} enrichment worker(s), ${enrichment_remaining} slots remaining for implementation" >>"$LOGFILE"
	fi
	available_slots="$enrichment_remaining"

	printf '%s %s\n' "$available_slots" "$triage_dispatched"
	return 0
}

#######################################
# Per-candidate skip checks: terminal blockers (t1888), fast-fail (t1888), and
# placeholder/empty issue body (t1899/t1937). Emits the same skip log lines
# the monolithic function used so operator tooling that greps $LOGFILE keeps
# working.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should proceed to dispatch
#######################################
_dispatch_should_skip_candidate() {
	local issue_number="$1"
	local repo_slug="$2"

	pulse_dispatch_debug_log "evaluating skip checks for #${issue_number} (${repo_slug})"

	# GH#18804: previously this call used `>/dev/null 2>&1` which suppressed
	# the helper's own log lines AND, more dangerously, masked silent
	# false-positive matches across every candidate in a round. The only
	# observable symptom was `candidates=N` followed immediately by
	# `Adaptive settle wait: 0 dispatches` with nothing between.
	#
	# The set -e-safe capture idiom here is REQUIRED, not stylistic:
	# `_dispatch_should_skip_candidate` runs inside the dispatch loop, which
	# itself runs inside the `dispatch_max` subshell
	# created by `fill_dispatched=$(dispatch_max)`.
	# Under `set -euo pipefail` an unguarded `if helper; then` is fine,
	# but ANY internal capture or assignment that fails would abort the
	# subshell silently. Capturing the rc explicitly keeps the failure
	# mode visible in LOGFILE rather than swallowed by the outer `||`.
	# Same bug class as GH#18770, GH#18784, GH#18786 — see
	# `.agents/reference/bash-compat.md` pre-merge checklist item 4.
	local terminal_rc=0
	check_terminal_blockers "$issue_number" "$repo_slug" >>"$LOGFILE" 2>&1 || terminal_rc=$?
	pulse_dispatch_debug_log "#${issue_number}: check_terminal_blockers rc=${terminal_rc}"
	if [[ "$terminal_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — terminal blocker detected (check_terminal_blockers rc=0)" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_terminal_blocker"
		return 0
	fi

	# t2397: Age-out HARD STOP'd issues that have been quiet for >=24h so
	# transient failures (model availability, CI flakes, stale framework bugs)
	# don't permanently strand issues. Called before fast_fail_is_skipped so
	# a just-reset counter allows dispatch in the same cycle.
	fast_fail_age_out "$issue_number" "$repo_slug" || true

	if fast_fail_is_skipped "$issue_number" "$repo_slug"; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — fast-fail threshold reached" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_fast_fail"
		return 0
	fi

	# t2781: Per-issue rate_limit backoff — graduated cooldown based on recent
	# rate_limit exits in headless-runtime-metrics.jsonl. Prevents repeated dispatch
	# of issues where every account in the pool rate-limits (the existing fast_fail
	# rate_limit path does an immediate retry when other accounts are available,
	# producing 0s cooldown. This gate adds a per-issue floor independent of pool state).
	if declare -F check_dispatch_backoff >/dev/null 2>&1; then
		local _backoff_output="" _backoff_rc=0
		_backoff_output=$(check_dispatch_backoff "$issue_number" "$repo_slug" 2>&1 >/dev/null) || _backoff_rc=$?
		if [[ "$_backoff_rc" -eq 1 ]]; then
			echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — ${_backoff_output}" >>"$LOGFILE"
			_dispatch_stats_increment "dispatch_candidate_skipped_backoff"
			# Apply NMR when the backoff helper signals 4th+ failure threshold.
			if printf '%s' "$_backoff_output" | grep -q 'NMR_REQUIRED'; then
				local _backoff_count=""
				_backoff_count=$(printf '%s' "$_backoff_output" | grep -oE 'count=[0-9]+' | head -1 | cut -d= -f2)
				[[ "$_backoff_count" =~ ^[0-9]+$ ]] || _backoff_count="${DISPATCH_BACKOFF_NMR_THRESHOLD:-4}"
				declare -F _db_apply_nmr_if_needed >/dev/null 2>&1 && \
					_db_apply_nmr_if_needed "$issue_number" "$repo_slug" "$_backoff_count" || true
			fi
			return 0
		fi
		# rc=2 → error; fail-open (log warning, continue to dispatch)
		if [[ "$_backoff_rc" -eq 2 ]]; then
			echo "[pulse-wrapper] Dispatch_max: backoff check error for #${issue_number} — proceeding (fail-open)" >>"$LOGFILE"
		fi
	fi

	# t1899/t1937: Skip issues with placeholder/empty bodies — dispatching a
	# worker to an undescribed issue wastes a session. Use REST here instead of
	# `gh issue view --json body`: this pre-dedup fast-fail runs once per
	# candidate, so a GraphQL-backed CLI read can drain the shared GraphQL budget
	# before workers ever launch.
	local issue_body
	declare -F gh_record_call >/dev/null 2>&1 && gh_record_call rest "pulse-dispatch-lib.sh" || true
	issue_body=$(gh api "repos/${repo_slug}/issues/${issue_number}" --jq '.body // ""' 2>/dev/null) || issue_body=""
	pulse_dispatch_debug_log "#${issue_number}: body length=${#issue_body}"
	if [[ -z "$issue_body" || "$issue_body" == "Task created via claim-task-id.sh" ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — placeholder/empty issue body, needs enrichment before dispatch" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_empty_body"
		return 0
	fi
	if [[ "$issue_body" == *"no description provided — enrich before dispatch"* ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — claim-task-id.sh stub body, needs enrichment before dispatch" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_empty_body"
		return 0
	fi
	if _dispatch_issue_body_missing_worker_context "$issue_body"; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — missing Worker Guidance/How implementation context, needs enrichment before dispatch" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_missing_worker_context"
		return 0
	fi

	pulse_dispatch_debug_log "#${issue_number}: passed all skip checks — proceeding to dispatch"
	return 1
}

#######################################
# Detect issue bodies that explicitly say implementation context is missing and
# would therefore deterministically make /full-loop stop with BLOCKED before
# implementation. Do not reject every body that lacks Worker Guidance here:
# dispatch_with_dedup has a later brief-enrichment layer that can repair older
# issue bodies when a local task brief exists.
#
# Arguments:
#   $1 - issue body
# Returns:
#   0 - body is missing worker implementation context
#   1 - body appears dispatchable
#######################################
_dispatch_issue_body_missing_worker_context() {
	local issue_body="$1"

	if [[ -z "$issue_body" ]]; then
		return 0
	fi
	case "$issue_body" in
	*"needs enrichment before dispatch"* | *"Needs enrichment before dispatch"* | \
		*"missing Worker Guidance/How implementation context"* | \
		*"Missing Worker Guidance/How implementation context"* | \
		*"needs implementation context before dispatch"* | \
		*"Needs implementation context before dispatch"* | \
		*"no implementation details provided"* | \
		*"No implementation details provided"* | \
		*"no worker guidance provided"* | *"No worker guidance provided"*)
		return 0
		;;
	esac
	return 1
}

#######################################
# Record a check_worker_launch failure. Updates the round counters and, on
# three consecutive no_worker_process failures, invalidates the canary cache
# so the next dispatch forces a re-test instead of trusting a stale "passed N
# minutes ago" signal (t1959).
#######################################
_dispatch_record_launch_failure() {
	if [[ "$_PULSE_LAST_LAUNCH_FAILURE" == "no_worker_process" ]]; then
		_DISPATCH_ROUND_NO_WORKER_FAILURES=$((_DISPATCH_ROUND_NO_WORKER_FAILURES + 1))
		_DISPATCH_CONSECUTIVE_NO_WORKER=$((_DISPATCH_CONSECUTIVE_NO_WORKER + 1))
		if [[ "$_DISPATCH_CONSECUTIVE_NO_WORKER" -ge 3 ]]; then
			if [[ -f "$_DISPATCH_CANARY_CACHE" ]]; then
				rm -f "$_DISPATCH_CANARY_CACHE"
				echo "[pulse-wrapper] Canary cache invalidated after ${_DISPATCH_CONSECUTIVE_NO_WORKER} consecutive no_worker_process failures in round — next dispatch will re-run canary" >>"$LOGFILE"
			fi
			_DISPATCH_CONSECUTIVE_NO_WORKER=0
		fi
	else
		# cli_usage_output or other launch-class failure: don't count toward
		# the consecutive no_worker_process streak.
		_DISPATCH_CONSECUTIVE_NO_WORKER=0
	fi
	return 0
}

#######################################
# t2989: Run dispatch_with_dedup with a per-candidate wall-clock timeout.
#
# Wraps the call in run_stage_with_timeout (default 30s, env override
# DISPATCH_PER_CANDIDATE_TIMEOUT). On timeout, kills the entire process
# tree, emits a distinct log line, and bumps the
# dispatch_per_candidate_timeout counter in pulse-stats.json so cycle
# cadence regressions are visible to operators without a deep log dive.
#
# GH#18804 isolation contract preserved: dispatch_with_dedup has no
# shared-variable contract with the caller; it only mutates GitHub state
# via gh API and fork-execs the worker via nohup, both of which survive
# subshell isolation. run_stage_with_timeout backgrounds the call via
# "$@ &" — strictly stronger isolation than the previous (...) subshell
# while still capturing rc via ||.
#
# Arguments:
#   $1 - issue_number (used for stage name + log lines AND passed through)
#   $2 - repo_slug    (used for log lines AND passed through)
#   $3..$9 - remaining dispatch_with_dedup positional args (dispatch_title,
#            issue_title, self_login, repo_path, prompt, dedup_key,
#            model_override). All "$@" forwarded verbatim to
#            dispatch_with_dedup.
#
# Returns:
#   0     - dispatch_with_dedup completed successfully
#   124   - per-candidate timeout (already logged + counter bumped)
#   other - dispatch_with_dedup non-zero rc (failed dedup check, etc.)
#######################################
_dispatch_with_timeout() {
	local issue_number="$1"
	local repo_slug="$2"

	# t3003: adaptive per-candidate timeout. When DISPATCH_TIMING_ADAPTIVE=1
	# (default), dispatch-timing-helper.sh recommends a budget based on the
	# EWMA + p95 of recent successful dispatches; on timeouts it switches to
	# probe mode (2x last_timeout). Old fixed DISPATCH_PER_CANDIDATE_TIMEOUT
	# is preserved as the legacy fallback when the helper is unavailable or
	# DISPATCH_TIMING_ADAPTIVE=0.
	local timeout_seconds="$DISPATCH_PER_CANDIDATE_TIMEOUT"
	local timeout_ms=$((timeout_seconds * 1000))
	local probe_mode="false"
	if [[ "${DISPATCH_TIMING_ADAPTIVE:-1}" == "1" ]] && command -v dispatch-timing-helper.sh >/dev/null 2>&1; then
		local recommended_output
		recommended_output=$(dispatch-timing-helper.sh recommend --repo "$repo_slug" 2>/dev/null || echo "")
		# Output is two lines: timeout_ms and probe_bool
		local recommended_ms="" probe_bool="false"
		mapfile -t -n 2 < <(printf '%s\n' "$recommended_output")
		recommended_ms="${MAPFILE[0]:-}"
		probe_bool="${MAPFILE[1]:-false}"
		if [[ "$recommended_ms" =~ ^[0-9]+$ ]] && ((recommended_ms > 0)); then
			timeout_ms="$recommended_ms"
			timeout_seconds=$((recommended_ms / 1000))
			((timeout_seconds < 1)) && timeout_seconds=1
			probe_mode="$probe_bool"
		fi
	fi

	# t3026: floor per-candidate timeout to cover full ceremony cost.
	# Pulse dispatch ceremony (gh issue view + brief check + eligibility +
	# pre-dispatch validators + CLAIM_WON audit comment + body composition
	# with footer + worker spawn / npm install / node startup) takes ~75-160s
	# baseline; with backpressure it adds 20-40s. The adaptive helper's MIN
	# (DISPATCH_TIMING_MIN_TIMEOUT_MS, default 30s) is sized for the simplest
	# case (dedup-skip path that returns in <5s) and is too low for the full
	# ceremony — when adaptive recommended drops below ceremony cost, EVERY
	# candidate timeouts at rc=124 and dispatched=0/N. Canonical failure:
	# 2026-04-28 dispatch cycle iter=62, 148 candidates, dispatched=0,
	# adaptive timeout collapsed to 180s. Floor at 360s was insufficient
	# (post-t3040 evidence: ceremony_total avg=341s, max=341s — every
	# candidate hit rc=124 timeout). t3043 raises to 600s to give the
	# 419s avg ceremony (gh_issue_view 3s + dedup_check 134s + assign 35s
	# + precreate_worktree 75s + lock 7s + eligibility 11s + predispatch 8s
	# + tier 4s + worker_launch 142s) ~50% headroom for tail variance.
	# Follow-up t3043 (#21659) targets reducing per-stage cost to <60s.
	local floor_seconds="${DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR:-600}"
	if [[ "$floor_seconds" =~ ^[0-9]+$ ]] && ((timeout_seconds < floor_seconds)); then
		timeout_seconds="$floor_seconds"
		timeout_ms=$((floor_seconds * 1000))
	fi

	local start_ms dispatch_rc=0 outcome elapsed_ms
	start_ms=$(_dispatch_now_ms)
	run_stage_with_timeout "dispatch_candidate_${issue_number}" "$timeout_seconds" \
		dispatch_with_dedup "$@" || dispatch_rc=$?
	elapsed_ms=$(($(_dispatch_now_ms) - start_ms))
	echo "[pulse-wrapper] Dispatch_max: dispatch_with_dedup returned rc=${dispatch_rc} for #${issue_number} elapsed_ms=${elapsed_ms} timeout_used_ms=${timeout_ms}" >>"$LOGFILE"

	if [[ "$dispatch_rc" -eq 124 ]]; then
		outcome="timeout"
		# t2989 + t3003: per-candidate timeout — log distinctly, bump counter,
		# record outcome so the next recommendation enters probe mode.
		# t3056 / GH#21781: Structured lifecycle line for kill-reason telemetry
		printf '[lifecycle] worker_killed pid=dispatch reason=wait_loop_timeout_%ss trigger_age=%sms session=issue-%s ts=%s\n' \
			"$timeout_seconds" "$elapsed_ms" "$issue_number" \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			>>"${LOGFILE:-/dev/null}" 2>/dev/null || true
		echo "[pulse-wrapper] Dispatch_max: per-candidate timeout (${timeout_seconds}s) on #${issue_number} (${repo_slug}) — killing candidate, continuing loop" >>"$LOGFILE"
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "dispatch_per_candidate_timeout" 2>/dev/null || true
		fi
	elif [[ "$dispatch_rc" -eq 0 ]]; then
		outcome="success"
	elif [[ "$dispatch_rc" -eq 2 ]]; then
		outcome="noop"
	else
		outcome="skip"
	fi

	# t3003: record outcome for adaptive timing. Non-fatal — never block the
	# dispatch loop on a recording failure. Pass --probe flag when escalated.
	if command -v dispatch-timing-helper.sh >/dev/null 2>&1; then
		dispatch-timing-helper.sh record \
			--repo "$repo_slug" --issue "$issue_number" --outcome "$outcome" \
			--elapsed-ms "$elapsed_ms" --timeout-used-ms "$timeout_ms" \
			--probe "$probe_mode" \
			>/dev/null 2>&1 || true
	fi

	return "$dispatch_rc"
}

#######################################
# Stop dispatch loops when the GraphQL reserve is already below the circuit
# breaker threshold. The rate_limit endpoint is free, so this protects the
# high-fanout loop without spending additional GraphQL points.
#
# Returns:
#   0 — budget is sufficient, unavailable, or checker is not loaded
#   1 — budget is below threshold; caller should stop the loop
#######################################
_dispatch_graphql_budget_allows_next() {
	if ! declare -F is_graphql_budget_sufficient >/dev/null 2>&1; then
		return 0
	fi

	local _budget_rc=0
	is_graphql_budget_sufficient >/dev/null 2>&1 || _budget_rc=$?
	if [[ "$_budget_rc" -eq 1 ]]; then
		_dispatch_stats_increment "dispatch_graphql_circuit_blocked"
		_dispatch_stats_increment_candidate_failed "graphql_circuit_breaker"
		return 1
	fi
	return 0
}

#######################################
# t3003: bash 3.2-compatible millisecond timestamp.
# GNU date supports %N (nanoseconds); macOS BSD date does not. We strip the
# trailing 6 digits to convert ns→ms when GNU date is present, otherwise fall
# back to seconds×1000 (sufficient resolution for ≥1s timeouts).
#######################################
_dispatch_now_ms() {
	local ns
	ns=$(date +%s%N 2>/dev/null)
	if [[ "$ns" =~ ^[0-9]+$ ]] && ((${#ns} >= 13)); then
		# GNU date: epoch_seconds + 9-digit nanoseconds → strip 6 → ms
		echo "${ns%??????}"
	else
		# BSD date or unsupported %N — fall back to second resolution
		echo $(($(date +%s) * 1000))
	fi
	return 0
}

#######################################
# t3022: Per-model concurrency cap guard.
#
# Prevents 429 rate-limit cascades when multiple opus-tier workers are
# launched simultaneously. A single Anthropic account sustains many
# concurrent sonnet workers but only ~3-4 concurrent opus before hitting
# 429s that make workers 20-min zombies (observed: 3 opus-4-6 workers
# killed at the same minute with rate_limit, ts=1777397345-1777397359).
#
# Counts in-flight opus workers by probing the process list for opencode's
# '-m anthropic/claude-opus' flag (the literal flag opencode receives from
# _build_run_cmd in headless-runtime-model.sh). Returns 1 (deferred) when
# the candidate's model is opus and inflight >= cap. Sonnet/haiku and
# auto-routed candidates (empty model_override) always return 0.
#
# Deferred candidates are retried next pulse cycle — they are NOT NMR'd
# or fast-fail penalised. This is a temporary yield, not a block.
#
# Cap resolution order (highest to lowest):
#   1. AIDEVOPS_OPUS_CONCURRENCY_CAP env var
#   2. OPUS_CONCURRENCY_CAP in .agents/configs/dispatch-model-caps.conf
#   3. Built-in default (4)
#
# Arguments:
#   $1 - issue_number (for logging)
#   $2 - repo_slug (for logging)
#   $3 - resolved_model (e.g. "anthropic/claude-opus-4-6" or "" for auto)
# Returns:
#   0 - proceed with dispatch (not opus, or inflight < cap)
#   1 - deferred (opus inflight >= cap); caller should `return 1`
#######################################
_dispatch_check_model_concurrency_cap() {
	local issue_number="$1"
	local repo_slug="$2"
	local resolved_model="$3"

	# Empty model = auto round-robin (no explicit model:* label) — skip cap check.
	[[ -z "$resolved_model" ]] && return 0

	# Only cap opus-tier models; sonnet and haiku are unaffected.
	case "$resolved_model" in
	*claude-opus*) ;;  # fall through to cap enforcement below
	*) return 0 ;;
	esac

	# Load per-model caps from config with inline defaults.
	# Defaults match the documented values in dispatch-model-caps.conf.
	local OPUS_CONCURRENCY_CAP=4
	local _caps_conf="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../configs/dispatch-model-caps.conf"
	if [[ -f "$_caps_conf" ]]; then
		# shellcheck disable=SC1090
		source "$_caps_conf" 2>/dev/null || true
	fi
	# Env var takes highest precedence (overrides both default and conf file).
	local opus_cap="${AIDEVOPS_OPUS_CONCURRENCY_CAP:-${OPUS_CONCURRENCY_CAP}}"

	# Count in-flight opus workers from the process list.
	# opencode is launched with '-m anthropic/claude-opus-4-6' (or -4-7) by
	# _build_run_cmd in headless-runtime-model.sh:412. pgrep -f matches the
	# full cmdline so it catches both 4-6 and 4-7 variants in one probe.
	#
	# pgrep exits 1 with no output when no processes match — perfectly normal.
	# Assign to a variable first with || true to avoid triggering set -o pipefail.
	local _opus_pids=""
	_opus_pids=$(pgrep -f 'opencode.*-m anthropic/claude-opus' 2>/dev/null) || true
	local opus_inflight=0
	if [[ -n "$_opus_pids" ]]; then
		opus_inflight=$(printf '%s\n' "$_opus_pids" | wc -l | tr -d ' ')
		[[ "$opus_inflight" =~ ^[0-9]+$ ]] || opus_inflight=0
	fi

	pulse_dispatch_debug_log "#${issue_number}: opus_concurrency_cap check inflight=${opus_inflight} cap=${opus_cap} model=${resolved_model}"

	if ((opus_inflight >= opus_cap)); then
		echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) deferred — opus_concurrency_cap: inflight=${opus_inflight} cap=${opus_cap} model=${resolved_model} (retry next cycle)" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_deferred_model_cap"
		return 1
	fi
	return 0
}

#######################################
# Process a single dispatch candidate: extract fields, skip if ineligible,
# dispatch via dispatch_with_dedup, verify worker launch, and track the
# outcome for adaptive batch throttling.
#
# Arguments:
#   $1 - candidate JSON object (one line of `jq -c '.[]'`)
#   $2 - self_login (GitHub user for dedup)
#   $3 - available_slots (for throttle-clear log message)
#
# Returns:
#   0 - candidate dispatched and launch verified (caller should increment
#       dispatched_count; if _DISPATCH_THROTTLE_CLEARED=1 also restore
#       _effective_slots)
#   1 - candidate skipped or dispatch failed (caller should `continue`)
#
# Side effects:
#   - Updates _DISPATCH_ROUND_DISPATCHED / _DISPATCH_ROUND_NO_WORKER_FAILURES /
#     _DISPATCH_CONSECUTIVE_NO_WORKER for the round.
#   - Clears _DISPATCH_THROTTLE_FILE and sets _DISPATCH_THROTTLE_CLEARED=1 on a
#     successful launch while throttle was active.
#######################################
_dispatch_process_candidate() {
	local candidate_json="$1"
	local self_login="$2"
	local available_slots="$3"
	_DISPATCH_THROTTLE_CLEARED=0

	local issue_number="" repo_slug="" repo_path="" issue_url="" issue_title="" dispatch_title="" prompt="" labels_csv="" model_override=""
	issue_number=$(printf '%s' "$candidate_json" | jq -r '.number // empty' 2>/dev/null)
	repo_slug=$(printf '%s' "$candidate_json" | jq -r '.repo_slug // empty' 2>/dev/null)
	repo_path=$(printf '%s' "$candidate_json" | jq -r '.repo_path // empty' 2>/dev/null)
	issue_url=$(printf '%s' "$candidate_json" | jq -r '.url // empty' 2>/dev/null)
	issue_title=$(printf '%s' "$candidate_json" | jq -r '.title // empty' 2>/dev/null | tr '\n' ' ')
	labels_csv=$(printf '%s' "$candidate_json" | jq -r '(.labels // []) | join(",")' 2>/dev/null)

	# GH#18804: previously the next two checks silently `return 1`-ed without
	# logging. Operators saw `candidates=N` but no per-candidate skip lines,
	# making malformed candidate JSON impossible to diagnose from pulse.log.
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping malformed candidate — issue_number='${issue_number}' is not numeric (candidate_json prefix: ${candidate_json:0:120})" >>"$LOGFILE"
		return 1
	fi
	if [[ -z "$repo_slug" || -z "$repo_path" ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} — missing repo_slug='${repo_slug}' or repo_path='${repo_path}'" >>"$LOGFILE"
		return 1
	fi

	pulse_dispatch_debug_log "processing #${issue_number} (${repo_slug}) labels=[${labels_csv}]"

	if _dispatch_should_skip_candidate "$issue_number" "$repo_slug"; then
		return 1
	fi

	dispatch_title="Issue #${issue_number}"
	prompt="/full-loop Implement issue #${issue_number}"
	if [[ -n "$issue_url" ]]; then
		prompt="${prompt} (${issue_url})"
	fi
	model_override=$(resolve_dispatch_model_for_labels "$labels_csv")
	pulse_dispatch_debug_log "#${issue_number}: model_override=${model_override:-<auto>} — calling dispatch_with_dedup"

	# t3022: Defer opus candidates when the per-model concurrency cap is reached.
	# Prevents 429 cascades from simultaneous opus worker launches. Sonnet/haiku
	# candidates are unaffected. Deferred candidates retry next pulse cycle.
	local _concurrency_cap_rc=0
	_dispatch_check_model_concurrency_cap "$issue_number" "$repo_slug" "$model_override" >>"$LOGFILE" 2>&1 || _concurrency_cap_rc=$?
	if [[ "$_concurrency_cap_rc" -ne 0 ]]; then
		return 1
	fi

	# t2433/GH#20071: Refresh the repo before the large-file gate (inside
	# dispatch_with_dedup → _dispatch_dedup_check_layers → _issue_targets_large_files)
	# measures file sizes. Sentinel prevents multiple pulls for the same repo
	# within a single dispatch_max subshell execution.
	_pulse_refresh_repo "$repo_path"

	# GH#18804 + t2989: dispatch with isolation + per-candidate timeout.
	# Detail (subshell isolation, hang signature, 30s default rationale):
	# see _dispatch_with_timeout doc comment above.
	local dispatch_rc=0
	_dispatch_with_timeout "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$prompt" "issue-${issue_number}" "$model_override" || dispatch_rc=$?
	if [[ "$dispatch_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — dispatch_with_dedup returned rc=${dispatch_rc}" >>"$LOGFILE"
		if [[ "$dispatch_rc" -eq 2 ]]; then
			_dispatch_stats_increment "dispatch_candidate_noop"
		else
			local failure_reason
			failure_reason=$(_dispatch_candidate_failure_reason "$issue_number" "$repo_slug" "$dispatch_rc")
			echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) pre-launch failure reason=${failure_reason}" >>"$LOGFILE"
			_dispatch_stats_increment_candidate_failed "$failure_reason"
		fi
		return 1
	fi

	# Count every successful dispatch attempt as a round denominator (t1959)
	_DISPATCH_ROUND_DISPATCHED=$((_DISPATCH_ROUND_DISPATCHED + 1))
	_PULSE_LAST_LAUNCH_FAILURE=""

	local launch_rc=0
	check_worker_launch "$issue_number" "$repo_slug" >/dev/null 2>&1 || launch_rc=$?
	if [[ "$launch_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) launch validation failed (rc=${launch_rc}, last_failure='${_PULSE_LAST_LAUNCH_FAILURE}')" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_worker_launch_failed"
		_dispatch_record_launch_failure
		return 1
	fi
	_dispatch_stats_increment "dispatch_worker_spawned"

	# Launch confirmed. Reset consecutive streak and clear throttle if active.
	_DISPATCH_CONSECUTIVE_NO_WORKER=0
	# t1959: A single successful launch proves the runtime is back.
	# Restore full batch immediately — do not wait for N successes.
	if [[ -f "$_DISPATCH_THROTTLE_FILE" ]]; then
		rm -f "$_DISPATCH_THROTTLE_FILE"
		echo "[pulse-wrapper] Dispatch throttle CLEARED: launch success in throttled mode — restoring full batch=${available_slots}" >>"$LOGFILE"
		_DISPATCH_THROTTLE_CLEARED=1
	fi
	return 0
}

#######################################
# After the dispatch loop finishes, compute the no_worker_process failure
# ratio for this round. If >80% of dispatches ended with no_worker_process,
# engage the adaptive batch throttle so the next round is limited to batch=1
# to avoid wasted dispatch cycles during runtime breakage (t1959).
#######################################
_dispatch_maybe_engage_throttle() {
	if [[ "$_DISPATCH_ROUND_DISPATCHED" -gt 0 ]]; then
		local ratio_pct=$((_DISPATCH_ROUND_NO_WORKER_FAILURES * 100 / _DISPATCH_ROUND_DISPATCHED))
		if [[ "$ratio_pct" -gt 80 ]]; then
			echo "1" >"$_DISPATCH_THROTTLE_FILE" 2>/dev/null || true
			echo "[pulse-wrapper] Dispatch throttle ENGAGED: ${ratio_pct}% no_worker_process in round (${_DISPATCH_ROUND_NO_WORKER_FAILURES}/${_DISPATCH_ROUND_DISPATCHED}) — next round limited to batch=1" >>"$LOGFILE"
		fi
	fi
	return 0
}

#######################################
# t3005/t3014: Decide the parallelism level for the dispatch_max loop.
#
# Defaults to DISPATCH_MAX_PARALLEL when set to a positive integer.
# When unset, empty, or non-numeric, defaults to effective_slots — i.e. the
# full slot budget — so the parallel loop saturates the worker pool in one
# cycle (t3014). The pre-t3014 default of 6 capped throughput at 6 dispatches
# per cycle even when the slot budget was 24, leaving ~17 idle slots per cycle
# under adaptive-timeout / probe-mode regimes that produce 30-180s per-candidate
# dispatch latency.
#
# Always capped at the effective slot budget — never schedule more concurrent
# dispatches than slots we'd consume. Forced to 1 when the adaptive throttle
# file is present (degraded runtime — the existing serial throttle behavior is
# preserved as the regression escape hatch and the "test the waters" semantics).
#
# Arguments:
#   $1 - effective_slots (already throttle-aware: 1 in throttle mode)
# Stdout: integer parallelism level (>= 1)
#######################################
_dispatch_max_compute_parallel() {
	local effective_slots="$1"
	# t3015 back-compat: honour deprecated DISPATCH_FILL_FLOOR_PARALLEL name.
	# Operators who set the old name in their environment / launchd plist
	# before upgrading should not silently lose their override. Bridge the
	# value into DISPATCH_MAX_PARALLEL on first invocation. Removed in v4.0.
	if [[ -n "${DISPATCH_FILL_FLOOR_PARALLEL:-}" && -z "${DISPATCH_MAX_PARALLEL:-}" ]]; then
		echo "[pulse-wrapper] WARNING: DISPATCH_FILL_FLOOR_PARALLEL is deprecated — use DISPATCH_MAX_PARALLEL (t3015)" >&2
		DISPATCH_MAX_PARALLEL="$DISPATCH_FILL_FLOOR_PARALLEL"
		export DISPATCH_MAX_PARALLEL
	fi
	# t3014: when unset/empty/invalid, default to effective_slots (full budget)
	# instead of the historical 6. Env override still wins when set to a valid
	# positive integer; the cap below still clamps at effective_slots.
	local max_parallel="${DISPATCH_MAX_PARALLEL:-}"
	if ! [[ "$max_parallel" =~ ^[1-9][0-9]*$ ]]; then
		max_parallel="$effective_slots"
	fi
	if ((max_parallel > effective_slots)); then
		max_parallel="$effective_slots"
	fi
	# In throttle mode, _effective_slots is already 1 → max_parallel=1 (serial).
	# t3418/t3558: when the minimum worker floor is active, launch throttles
	# are soft signals; keep parallelism eligible until the floor is reached.
	# Defensive: also short-circuit on direct file presence in case caller
	# passes a non-throttled effective_slots while throttle is active.
	if [[ -f "$_DISPATCH_THROTTLE_FILE" && "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" != "1" ]]; then
		max_parallel=1
	fi
	((max_parallel < 1)) && max_parallel=1
	printf '%d\n' "$max_parallel"
	return 0
}

#######################################
# t3005: Serial dispatch loop (original behavior, refactored into a helper).
#
# Iterates candidates one at a time, calling _dispatch_process_candidate inline.
# Module-global state mutations (_DISPATCH_ROUND_DISPATCHED, _DISPATCH_THROTTLE_CLEARED,
# _PULSE_LAST_LAUNCH_FAILURE, _DISPATCH_CONSECUTIVE_NO_WORKER) propagate normally
# because the loop runs in the parent shell, not a backgrounded subshell.
#
# Arguments:
#   $1 - candidate_file (one JSON candidate per line)
#   $2 - effective_slots (slot budget at loop start, may be throttled to 1)
#   $3 - available_slots (unthrottled slot budget — restored if throttle clears)
#   $4 - self_login (GitHub login for dedup)
# Stdout: "<dispatched_count> <processed_count>"
#######################################
_dispatch_floor_loop() {
	local candidate_file="$1"
	local effective_slots="$2"
	local available_slots="$3"
	local self_login="$4"

	local dispatched_count=0 processed_count=0 candidate_json
	while IFS= read -r candidate_json; do
		[[ -n "$candidate_json" ]] || continue
		processed_count=$((processed_count + 1))
		echo "[pulse-wrapper] Dispatch_max: loop iter=${processed_count} — entering body" >>"$LOGFILE"
		if [[ "$dispatched_count" -ge "$effective_slots" ]]; then
			echo "[pulse-wrapper] Dispatch_max: loop iter=${processed_count} — stopping (dispatched=${dispatched_count} >= effective_slots=${effective_slots})" >>"$LOGFILE"
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Dispatch_max stopping early: stop flag appeared" >>"$LOGFILE"
			break
		fi
		if ! _dispatch_graphql_budget_allows_next; then
			echo "[pulse-wrapper] Dispatch_max stopping early: GraphQL circuit breaker tripped during serial loop" >>"$LOGFILE"
			break
		fi
		local _dispatch_proc_rc=0
		_dispatch_process_candidate "$candidate_json" "$self_login" "$available_slots" || _dispatch_proc_rc=$?
		echo "[pulse-wrapper] Dispatch_max: loop iter=${processed_count} — _dispatch_process_candidate rc=${_dispatch_proc_rc}" >>"$LOGFILE"
		if [[ "$_dispatch_proc_rc" -eq 0 ]]; then
			dispatched_count=$((dispatched_count + 1))
			# Throttle cleared mid-round by a successful launch — restore
			# the unthrottled slot budget so subsequent iterations dispatch.
			if [[ "$_DISPATCH_THROTTLE_CLEARED" -eq 1 ]]; then
				effective_slots="$available_slots"
			fi
		fi
	done <"$candidate_file"
	printf '%d %d\n' "$dispatched_count" "$processed_count"
	return 0
}

#######################################
# t3005: Parallel dispatch loop with bounded concurrency and outcomes file.
#
# Each candidate is dispatched in a backgrounded subshell. Module-global
# mutations inside _dispatch_process_candidate are isolated to the subshell and
# lost — we re-derive aggregate state from an outcomes file written by each
# subshell on completion. POSIX O_APPEND guarantees atomic short-line writes
# (lines are <100 bytes, well under PIPE_BUF=512 on macOS / 4096 on Linux).
#
# Concurrency cap is enforced via `wait -n` (bash 4.3+). A modern bash is
# guaranteed at runtime by setup.sh's bash-upgrade-helper.sh + the
# shared-constants.sh re-exec guard.
#
# Each candidate's outcome line format:
#   success|<issue>           — dispatched + launch validated
#   fail|<issue>|rc=<n>|<reason>  — pre-skip, dispatch failure, or launch failure
#
# Arguments:
#   $1 - candidate_file
#   $2 - effective_slots (slot budget — never throttled in this path)
#   $3 - available_slots (passed through to _dispatch_process_candidate)
#   $4 - self_login
#   $5 - max_parallel (bounded concurrency level)
#   $6 - outcomes_file (created by caller, parent reads it post-loop)
# Stdout: "<dispatched_count> <processed_count>"
#######################################
_dispatch_max_loop() {
	local candidate_file="$1"
	local effective_slots="$2"
	local available_slots="$3"
	local self_login="$4"
	local max_parallel="$5"
	local outcomes_file="$6"

	local processed_count=0 candidate_json pid
	local _pids=()
	local _alive_pids=()
	while IFS= read -r candidate_json; do
		[[ -n "$candidate_json" ]] || continue
		processed_count=$((processed_count + 1))
		echo "[pulse-wrapper] Dispatch_max: parallel iter=${processed_count} — entering body" >>"$LOGFILE"

		# Reap finished pids so the array reflects current in-flight count.
		# Bash 3.2-safe: while-read via process substitution avoids SC2207
		# (no array splitting) and handles empty input cleanly.
		_alive_pids=()
		while IFS= read -r pid; do
			[[ -n "$pid" ]] && _alive_pids+=("$pid")
		done < <(_dispatch_max_reap_pids "${_pids[@]+${_pids[@]}}")
		_pids=("${_alive_pids[@]+${_alive_pids[@]}}")

		# Wait for one to finish if we're at the concurrency cap.
		# GH#21729: reap dead PIDs BEFORE calling wait -n, and handle the
		# PID-reuse scenario where kill -0 succeeds (PID recycled by OS for
		# a different process) but wait -n fails ("not a child of this shell").
		# Without this guard, the loop spins millions of times per minute,
		# growing pulse-wrapper.log to hundreds of GB.
		while ((${#_pids[@]} >= max_parallel)); do
			# Reap finished PIDs first — may drop below cap without blocking.
			_alive_pids=()
			while IFS= read -r pid; do
				[[ -n "$pid" ]] && _alive_pids+=("$pid")
			done < <(_dispatch_max_reap_pids "${_pids[@]+${_pids[@]}}")
			_pids=("${_alive_pids[@]+${_alive_pids[@]}}")

			# Re-check after reaping — may have dropped below cap.
			((${#_pids[@]} >= max_parallel)) || break

			# Block until the next child exits. If wait -n fails, all
			# remaining PIDs in _pids are stale (PID reuse: kill -0 succeeds
			# because the OS recycled the PID for a different process, but
			# it's not a child of this shell). Purge them to break the loop.
			if ! wait -n 2>/dev/null; then
				echo "[pulse-wrapper] Dispatch_max: wait -n found no children, purging ${#_pids[@]} stale PIDs from _pids (GH#21729)" >>"$LOGFILE"
				_pids=()
				sleep 1
			fi
		done

		# Budget check: successes already recorded + currently in flight
		# must stay below effective_slots. Reading the file is cheap (<1KB).
		local successes_so_far
		successes_so_far=$(_dispatch_max_count_outcomes "$outcomes_file")
		if ((successes_so_far + ${#_pids[@]} >= effective_slots)); then
			echo "[pulse-wrapper] Dispatch_max: parallel iter=${processed_count} — stopping (successes=${successes_so_far} + in_flight=${#_pids[@]} >= effective_slots=${effective_slots})" >>"$LOGFILE"
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Dispatch_max stopping early: stop flag appeared" >>"$LOGFILE"
			break
		fi
		if ! _dispatch_graphql_budget_allows_next; then
			echo "[pulse-wrapper] Dispatch_max stopping early: GraphQL circuit breaker tripped during parallel loop" >>"$LOGFILE"
			break
		fi

		local inter_launch_delay
		inter_launch_delay=$(_dispatch_inter_launch_delay "$((successes_so_far + ${#_pids[@]}))" "$processed_count" "$candidate_json" "$max_parallel")
		[[ "$inter_launch_delay" =~ ^[0-9]+$ ]] || inter_launch_delay=0
		if ((inter_launch_delay > 0)); then
			local issue_num_for_delay
			issue_num_for_delay=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
			_dispatch_stats_increment "dispatch_inter_launch_staggered"
			echo "[pulse-wrapper] Dispatch_max: adaptive inter-launch stagger issue=#${issue_num_for_delay} delay=${inter_launch_delay}s launched_so_far=$((successes_so_far + ${#_pids[@]})) max_parallel=${max_parallel}" >>"$LOGFILE"
			sleep "$inter_launch_delay"
		fi

		# Background dispatch with outcomes-file write.
		# The subshell isolates _dispatch_process_candidate's module-global
		# mutations; only the file system mutations (throttle removal,
		# canary cache) and the outcomes file write propagate.
		(
			local _rc=0
			_dispatch_process_candidate "$candidate_json" "$self_login" "$available_slots" >>"$LOGFILE" 2>&1 || _rc=$?
			local issue_num
			issue_num=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
			if [[ "$_rc" -eq 0 ]]; then
				printf 'success|%s\n' "$issue_num" >>"$outcomes_file"
			else
				printf 'fail|%s|rc=%d|reason=%s\n' "$issue_num" "$_rc" "${_PULSE_LAST_LAUNCH_FAILURE:-none}" >>"$outcomes_file"
			fi
		) &
		_pids+=($!)
	done <"$candidate_file"

	# Wait only for tracked in-flight dispatches. A bare wait can repeat
	# stale child diagnostics into pulse-wrapper.log after another wait site
	# has already reaped a child (GH#22919).
	_dispatch_max_wait_tracked_pids "${_pids[@]+${_pids[@]}}"
	_pids=()
	local dispatched_count
	dispatched_count=$(_dispatch_max_count_outcomes "$outcomes_file")
	printf '%d %d\n' "$dispatched_count" "$processed_count"
	return 0
}

#######################################
# t3005/GH#22919: Wait only for tracked parallel-dispatch children.
#
# Avoids bare `wait`, which can emit repeated "pid is not a child" diagnostics
# when tracked PIDs were already reaped by earlier cap-loop cleanup.
#
# Arguments: $@ - pids to wait for
#######################################
_dispatch_max_wait_tracked_pids() {
	local pid
	for pid in "$@"; do
		[[ -n "$pid" ]] || continue
		wait "$pid" 2>/dev/null || true
	done
	return 0
}

#######################################
# t3005: Count outcome lines of a given type in the parallel-dispatch
# outcomes file. Extracted to avoid repeating the awk literal across
# call sites (the pre-commit string-literal validator counts "success"
# inside awk scripts as a shell-level repeated literal).
#
# Arguments:
#   $1 - outcomes_file
#   $2 - outcome type to count (literal match on field 1, default "success")
# Stdout: integer count (0 if file missing or empty)
#######################################
_dispatch_max_count_outcomes() {
	local outcomes_file="$1"
	local outcome_type="${2:-success}"
	local count
	count=$(awk -F'|' -v t="$outcome_type" '$1==t{c++} END{print c+0}' "$outcomes_file" 2>/dev/null)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%d\n' "$count"
	return 0
}

#######################################
# t3005: Reap completed pids — return only those still alive.
#
# Bash 3.2-safe array passing: handles empty input via the
# "${arr[@]+${arr[@]}}" idiom (set -u safe). Echoes alive pids one per line.
#
# Arguments: $@ - pids to check
# Stdout: alive pids (whitespace-separated)
#######################################
_dispatch_max_reap_pids() {
	local pid
	for pid in "$@"; do
		[[ -n "$pid" ]] || continue
		if kill -0 "$pid" 2>/dev/null; then
			printf '%s\n' "$pid"
		fi
	done
	return 0
}

#######################################
# t3005: Aggregate parallel-dispatch outcomes into module-global counters.
#
# After the parallel loop returns, _DISPATCH_ROUND_DISPATCHED and
# _DISPATCH_ROUND_NO_WORKER_FAILURES are still 0 because the subshells couldn't
# mutate them. Re-derive both from the outcomes file.
#
# Also handles canary-cache invalidation (parallel approximation of the
# serial path's "3 consecutive no_worker_process" rule — uses total count
# in the round). Idempotent file removal: invalidating an already-gone
# cache is a no-op.
#
# Arguments:
#   $1 - outcomes_file
# Side effects:
#   - Sets _DISPATCH_ROUND_DISPATCHED, _DISPATCH_ROUND_NO_WORKER_FAILURES
#   - Removes _DISPATCH_CANARY_CACHE if no_worker_failures >= 3
#   - Removes _DISPATCH_THROTTLE_FILE if any successes (parallel can only run when
#     throttle was already off, but defensive cleanup is cheap)
#######################################
_dispatch_max_aggregate_outcomes() {
	local outcomes_file="$1"
	local successes="" fails="" no_worker_failures=""
	successes=$(_dispatch_max_count_outcomes "$outcomes_file" "success")
	fails=$(_dispatch_max_count_outcomes "$outcomes_file" "fail")
	# no_worker_process is identified via the reason field embedded in the
	# fail line — match the substring rather than adding another field.
	no_worker_failures=$(awk -F'|' -v t="fail" '$1==t && /no_worker_process/{c++} END{print c+0}' "$outcomes_file" 2>/dev/null)
	[[ "$no_worker_failures" =~ ^[0-9]+$ ]] || no_worker_failures=0

	_DISPATCH_ROUND_DISPATCHED=$((successes + fails))
	_DISPATCH_ROUND_NO_WORKER_FAILURES="$no_worker_failures"

	if ((no_worker_failures >= 3)); then
		if [[ -f "$_DISPATCH_CANARY_CACHE" ]]; then
			rm -f "$_DISPATCH_CANARY_CACHE"
			echo "[pulse-wrapper] Canary cache invalidated after ${no_worker_failures} no_worker_process failures in parallel round — next dispatch will re-run canary" >>"$LOGFILE"
		fi
	fi

	if ((successes > 0)) && [[ -f "$_DISPATCH_THROTTLE_FILE" ]]; then
		rm -f "$_DISPATCH_THROTTLE_FILE"
		echo "[pulse-wrapper] Dispatch throttle CLEARED: parallel round had ${successes} successful launches" >>"$LOGFILE"
	fi
	return 0
}
