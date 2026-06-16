#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Wrapper Cycle Gates -- idle/backoff, prefetch, and cycle outcome helpers
# =============================================================================
# Focused helper library for pulse-wrapper.sh. The parent wrapper keeps the
# large, identity-key-sensitive functions in place while this module holds the
# smaller cycle gate and health-counter helpers used by main cycle orchestration.
#
# Usage: source "${SCRIPT_DIR}/pulse-wrapper-cycle-gates.sh"
#
# Dependencies:
#   - pulse-wrapper-config.sh globals (LOGFILE, WRAPPER_LOGFILE, SCOPE_FILE,
#     REPOS_JSON, _PULSE_HEALTH_* counters, _file_mtime_epoch)
#   - gh, jq, tr, date, mkdir, touch, rm
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced).
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_WRAPPER_CYCLE_GATES_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_CYCLE_GATES_LOADED=1

# Resolve SCRIPT_DIR defensively for tests/direct sourcing.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_pulse_scope_repos_for_available_work_gate() {
	local _scope="${PULSE_SCOPE_REPOS:-}"
	if [[ -z "$_scope" && -f "${SCOPE_FILE:-}" ]]; then
		read -r _scope <"$SCOPE_FILE" 2>/dev/null || _scope=""
	fi
	if [[ -z "$_scope" && -f "${REPOS_JSON:-}" ]]; then
		_scope=$(jq -r '[.initialized_repos[]? | select(.pulse == true and (.local_only // false) == false and (.slug // "") != "") | .slug] | join(",")' "$REPOS_JSON" 2>/dev/null) || _scope=""
	fi
	local _slug=""
	while IFS= read -r _slug; do
		_slug="${_slug// /}"
		[[ -n "$_slug" ]] || continue
		printf '%s\n' "$_slug"
	done < <(printf '%s\n' "$_scope" | tr ',' '\n')
	return 0
}

_pulse_available_auto_dispatch_work_exists() {
	[[ "${AIDEVOPS_SKIP_PULSE_IDLE_AVAILABLE_WORK_CHECK:-0}" == "1" ]] && return 1
	local _slug=""
	while IFS= read -r _slug; do
		[[ -n "$_slug" ]] || continue
		local _count=""
		_count=$(gh api -X GET search/issues \
			-f "q=repo:${_slug} is:issue is:open label:auto-dispatch label:status:available no:assignee" \
			-f per_page=1 \
			--jq '.total_count // 0' 2>/dev/null) || _count=""
		[[ "$_count" =~ ^[0-9]+$ ]] || _count=0
		if [[ "$_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Idle backoff bypass: eligible auto-dispatch work is visible in ${_slug} (GH#22631)" >>"$WRAPPER_LOGFILE"
			return 0
		fi
	done < <(_pulse_scope_repos_for_available_work_gate)
	return 1
}

_pulse_check_idle_backoff_gate() {
	local _ib_helper="${SCRIPT_DIR}/pulse-idle-backoff-helper.sh"
	[[ -x "$_ib_helper" ]] || return 0
	local _ib_available_work=0
	if _pulse_available_auto_dispatch_work_exists; then
		_ib_available_work=1
	fi
	local _ib_ts_file="${HOME}/.aidevops/logs/pulse-wrapper-last-run.ts"
	local _ib_last=0
	if [[ -f "$_ib_ts_file" ]]; then
		read -r _ib_last <"$_ib_ts_file" || _ib_last=0
		[[ "$_ib_last" =~ ^[0-9]+$ ]] || _ib_last=0
	fi
	# Helper convention: exit 0 = "skip this cycle", exit 1 = "proceed".
	# Mirrors should-skip semantics so the helper composes naturally with
	# `if helper should-skip; then return; fi` at the call site.
	if AIDEVOPS_PULSE_IDLE_AVAILABLE_WORK="$_ib_available_work" "$_ib_helper" should-skip "$_ib_last" >/dev/null 2>&1; then
		local _ib_state="" _ib_count="" _ib_interval=""
		_ib_state=$("$_ib_helper" state 2>/dev/null || echo '{}')
		_ib_count=$(echo "$_ib_state" | jq -r '.consecutive_idle // 0' 2>/dev/null || echo "0")
		_ib_interval=$(echo "$_ib_state" | jq -r '.current_effective_interval_s // 90' 2>/dev/null || echo "90")
		echo "[pulse-wrapper] Idle backoff: skipping cycle (consecutive_idle=${_ib_count}, effective_interval=${_ib_interval}s) (t3027)" >>"$WRAPPER_LOGFILE"
		_PULSE_HEALTH_IDLE_CYCLE_SKIPPED=$((_PULSE_HEALTH_IDLE_CYCLE_SKIPPED + 1))
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "pulse_idle_cycle_skipped" 2>/dev/null || true
		fi
		return 1
	fi
	return 0
}

_pulse_refresh_supervisor_circuit_breaker() {
	local _cb_helper="${SCRIPT_DIR}/circuit-breaker-helper.sh"
	[[ -x "$_cb_helper" ]] || return 0
	local _cb_rc=0
	"$_cb_helper" check >/dev/null 2>>"$WRAPPER_LOGFILE" || _cb_rc=$?
	if [[ "$_cb_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] Supervisor circuit breaker check passed or auto-reset completed (GH#22631)" >>"$WRAPPER_LOGFILE"
		return 0
	fi
	echo "[pulse-wrapper] Supervisor circuit breaker remains open after check (rc=${_cb_rc}) (GH#22631)" >>"$WRAPPER_LOGFILE"
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_drain_prefetch_counters (t3027 / GH#21584)
#
# Drains the prefetch counter temp file written by pulse-prefetch.sh::
# _prefetch_batch_refresh and accumulates into the cycle-scoped
# _PULSE_HEALTH_* vars. Required because prefetch_state runs inside a
# run_stage_with_timeout subshell — direct shell-var updates are lost
# at subshell exit. Counterpart: pulse-prefetch.sh:246-264 (writer).
#
# File format (single line, 7 space-separated integers, fixed positional
# order — DO NOT change without updating the writer):
#   search_calls cache_hits tickle_fresh tickle_stale conditional_304 conditional_refreshes conditional_misses
# ---------------------------------------------------------------------------
_pulse_drain_prefetch_counters() {
	local _pf_file="${TMPDIR:-/tmp}/pulse-health-prefetch-$$.tmp"
	[[ -f "$_pf_file" ]] || return 0
	local _pf_search=0 _pf_hits=0 _pf_fresh=0 _pf_stale=0
	local _pf_cond_304=0 _pf_cond_refreshes=0 _pf_cond_misses=0
	read -r _pf_search _pf_hits _pf_fresh _pf_stale _pf_cond_304 _pf_cond_refreshes _pf_cond_misses <"$_pf_file" || true
	[[ "$_pf_search" =~ ^[0-9]+$ ]] || _pf_search=0
	[[ "$_pf_hits" =~ ^[0-9]+$ ]] || _pf_hits=0
	[[ "$_pf_fresh" =~ ^[0-9]+$ ]] || _pf_fresh=0
	[[ "$_pf_stale" =~ ^[0-9]+$ ]] || _pf_stale=0
	[[ "$_pf_cond_304" =~ ^[0-9]+$ ]] || _pf_cond_304=0
	[[ "$_pf_cond_refreshes" =~ ^[0-9]+$ ]] || _pf_cond_refreshes=0
	[[ "$_pf_cond_misses" =~ ^[0-9]+$ ]] || _pf_cond_misses=0
	# Replace rather than add: prefetch_state writes its own running totals
	# (cumulative within the call), and these vars were 0-initialised at
	# cycle start with prefetch_state as the sole writer this cycle.
	_PULSE_HEALTH_BATCH_SEARCH_CALLS="$_pf_search"
	_PULSE_HEALTH_BATCH_CACHE_HITS="$_pf_hits"
	_PULSE_HEALTH_EVENTS_TICKLE_FRESH="$_pf_fresh"
	_PULSE_HEALTH_EVENTS_TICKLE_STALE="$_pf_stale"
	_PULSE_HEALTH_CONDITIONAL_304="$_pf_cond_304"
	_PULSE_HEALTH_CONDITIONAL_REFRESHES="$_pf_cond_refreshes"
	_PULSE_HEALTH_CONDITIONAL_MISSES="$_pf_cond_misses"
	rm -f "$_pf_file" || true
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_run_fix_the_fixer_detector_if_stale (t3077)
#
# Sentinel-gated invocation of pulse-fix-the-fixer-detector.sh. The detector
# uses a haiku LLM call to classify whether each new auto-dispatch issue
# modifies the worker dispatch system itself; when YES it applies the
# `fix-the-fixer` label so headless-runtime-helper.sh can enable verbose
# lifecycle, tighten the watchdog, and write a preflight sentinel.
#
# Sentinel: ~/.aidevops/cache/pulse-fix-the-fixer-last-run (mtime).
# Default cadence: 3600s (1 hour). Override via env:
#   AIDEVOPS_PULSE_FIX_THE_FIXER_MAX_AGE  — staleness threshold in seconds
#   AIDEVOPS_SKIP_FIX_THE_FIXER_DETECTOR  — set to 1 to short-circuit
#
# Modelled on _pulse_prime_caches_if_stale (t2994) and _pulse_check_runaway_log
# (GH#21756). Fail-open everywhere — a detector failure must never break the
# pulse cycle.
# ---------------------------------------------------------------------------
_pulse_run_fix_the_fixer_detector_if_stale() {
	[[ "${AIDEVOPS_SKIP_FIX_THE_FIXER_DETECTOR:-0}" == "1" ]] && return 0

	local _ftf_helper=""
	local _ftf_sentinel=""
	local _ftf_max_age=""
	_ftf_helper="${SCRIPT_DIR}/pulse-fix-the-fixer-detector.sh"
	_ftf_sentinel="${HOME}/.aidevops/cache/pulse-fix-the-fixer-last-run"
	_ftf_max_age="${AIDEVOPS_PULSE_FIX_THE_FIXER_MAX_AGE:-3600}"
	[[ "$_ftf_max_age" =~ ^[0-9]+$ ]] || _ftf_max_age=3600

	mkdir -p "$(dirname "$_ftf_sentinel")" 2>/dev/null || return 0
	[[ ! -x "$_ftf_helper" ]] && return 0

	local _should_run=0
	if [[ ! -f "$_ftf_sentinel" ]]; then
		_should_run=1
	else
		local _now_epoch="" _stamp_epoch="" _age_s=""
		_now_epoch=$(date +%s 2>/dev/null)
		_stamp_epoch=$(_file_mtime_epoch "$_ftf_sentinel")
		_age_s=$(( ${_now_epoch:-0} - ${_stamp_epoch:-0} ))
		[[ "$_age_s" -gt "$_ftf_max_age" ]] && _should_run=1
	fi

	if [[ "$_should_run" == "1" ]]; then
		"$_ftf_helper" run 2>>"${WRAPPER_LOGFILE:-/dev/null}" || true
		# Touch sentinel regardless of outcome (fail-open).
		touch "$_ftf_sentinel" 2>/dev/null || true
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_record_cycle_outcome (t3027 / GH#21584)
#
# Determines whether this cycle was active (did meaningful work) or idle
# (no merges, no closes, no new dispatches) and records the outcome with
# pulse-idle-backoff-helper.sh. The helper accumulates consecutive_idle,
# which the next cycle's _pulse_check_idle_backoff_gate consults.
#
# Active definition (any one suffices):
#   - merged ≥ 1 PR (_PULSE_HEALTH_PRS_MERGED)
#   - closed ≥ 1 conflicting PR (_PULSE_HEALTH_PRS_CLOSED_CONFLICTING)
#   - dispatched ≥ 1 new worker (ledger_after > ledger_before)
#
# Workers completing without new dispatches counts as IDLE — bookkeeping
# alone is not "useful work".
#
# Arguments:
#   $1 — ledger_count_before (captured at cycle start)
# ---------------------------------------------------------------------------
_pulse_record_cycle_outcome() {
	local _ledger_before="${1:-0}"
	[[ "$_ledger_before" =~ ^[0-9]+$ ]] || _ledger_before=0
	local _ib_helper="${SCRIPT_DIR}/pulse-idle-backoff-helper.sh"
	[[ -x "$_ib_helper" ]] || return 0
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	local _ledger_after=0
	if [[ -x "$_ledger_helper" ]]; then
		local _lc
		_lc=$("$_ledger_helper" count 2>/dev/null || echo "0")
		[[ "$_lc" =~ ^[0-9]+$ ]] && _ledger_after="$_lc"
	fi
	local _outcome="idle"
	if [[ "$_PULSE_HEALTH_PRS_MERGED" -gt 0 ]] \
		|| [[ "$_PULSE_HEALTH_PRS_CLOSED_CONFLICTING" -gt 0 ]] \
		|| [[ "$_ledger_after" -gt "$_ledger_before" ]]; then
		_outcome="active"
	fi
	"$_ib_helper" record-cycle "$_outcome" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Cycle outcome: ${_outcome} (merged=${_PULSE_HEALTH_PRS_MERGED} closed=${_PULSE_HEALTH_PRS_CLOSED_CONFLICTING} ledger=${_ledger_before}→${_ledger_after}) (t3027)" >>"$LOGFILE"
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_capture_ledger_count (t3027 / GH#21584)
#
# Returns current dispatch ledger count via stdout. Caller captures with $().
# Used by main() to snapshot ledger state at cycle start for outcome detection.
# ---------------------------------------------------------------------------
_pulse_capture_ledger_count() {
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$_ledger_helper" ]]; then
		local _lc
		_lc=$("$_ledger_helper" count 2>/dev/null || echo "0")
		if [[ "$_lc" =~ ^[0-9]+$ ]]; then
			printf '%d\n' "$_lc"
			return 0
		fi
	fi
	printf '0\n'
	return 0
}
