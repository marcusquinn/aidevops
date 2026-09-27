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
#   - portable-stat.sh (legacy scratch age checks)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_DISPATCH_FILL_FLOOR_LIB_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_FILL_FLOOR_LIB_LOADED=1

_PULSE_DISPATCH_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_PULSE_DISPATCH_LIB_DIR" == "${BASH_SOURCE[0]}" ]] && _PULSE_DISPATCH_LIB_DIR="."
# shellcheck source=shared-runner-identity.sh
source "${_PULSE_DISPATCH_LIB_DIR}/shared-runner-identity.sh"
if ! command -v _file_mtime_epoch >/dev/null 2>&1; then
	# shellcheck source=portable-stat.sh
	source "${_PULSE_DISPATCH_LIB_DIR}/portable-stat.sh"
fi

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
_DISPATCH_BENIGN_BLOCKS_FILE=""
_DISPATCH_BENIGN_BLOCKS_FILE_OWNED="0"
_DISPATCH_BENIGN_BLOCKS_SCRATCH_DIR=""
_DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS="${AIDEVOPS_PULSE_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS:-3600}"
[[ "$_DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS" =~ ^[0-9]+$ ]] || _DISPATCH_BENIGN_BLOCKS_LEGACY_MIN_AGE_SECONDS=3600
_DISPATCH_DEPENDENCY_NORMALIZATION_SKIP="skip"
# Out-parameter set by _dispatch_process_candidate when a successful launch clears
# the throttle file. The orchestrator loop reads this and restores
# _effective_slots to the unthrottled available_slots value.
_DISPATCH_THROTTLE_CLEARED=0
_DISPATCH_TRIAGE_OUTCOME_SCHEMA="aidevops.pulse-triage-outcome/v1"
_DISPATCH_OUTCOME_SUCCESS="success"
_DISPATCH_OUTCOME_FAILED="fail"
_DISPATCH_PRIORITY_PRODUCT="product"
_DISPATCH_ELIGIBILITY_INELIGIBLE="ineligible"
_DISPATCH_VALUE_UNKNOWN="unknown"
_DISPATCH_ELIGIBILITY_UNKNOWN="$_DISPATCH_VALUE_UNKNOWN"
_DISPATCH_DIRTY_MARKER_EVIDENCE_KIND="not_checked"
_DISPATCH_DIRTY_MARKER_REQUEST_ATTEMPTED="$_DISPATCH_VALUE_UNKNOWN"
_DISPATCH_DIRTY_MARKER_DEFERRED_BY="none"
_DISPATCH_DIRTY_MARKER_RETRY_AT="$_DISPATCH_VALUE_UNKNOWN"
_DISPATCH_DIRTY_MARKER_EXIT_CODE="0"

# Cohesive fill-floor helpers; resolved relative to this library, not the caller.
# shellcheck source=./pulse-dispatch-lib-capacity.sh
# shellcheck disable=SC1091  # sibling library resolved at runtime
source "${_PULSE_DISPATCH_LIB_DIR}/pulse-dispatch-lib-capacity.sh"
# shellcheck source=./pulse-dispatch-lib-candidates.sh
# shellcheck disable=SC1091  # sibling library resolved at runtime
source "${_PULSE_DISPATCH_LIB_DIR}/pulse-dispatch-lib-candidates.sh"

_dispatch_compute_capacity() {
	_DISPATCH_MIN_WORKER_FLOOR_ACTIVE=0
	if [[ -f "${STOP_FLAG:-}" ]]; then
		echo "[pulse-wrapper] Dispatch_max skipped: stop flag present" >>"$LOGFILE"
		return 1
	fi
	if ! _dispatch_rest_core_progress_allows_next "dispatch_capacity"; then
		echo "[pulse-wrapper] Dispatch_max skipped: REST-core launch headroom is unavailable" >>"$LOGFILE"
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
	local min_worker_floor="${AIDEVOPS_MIN_WORKER_CONCURRENCY:-}"
	if [[ -z "$min_worker_floor" ]] && declare -F config_get >/dev/null 2>&1; then
		min_worker_floor=$(config_get "orchestration.min_worker_concurrency" "6")
	fi
	[[ -n "$min_worker_floor" ]] || min_worker_floor=6
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
	max_workers="$(_dispatch_apply_startup_capacity_ramp "$max_workers" "$active_workers")"
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	available_slots=$((max_workers - active_workers))

	local guardrail_line=""
	guardrail_line=$(_dispatch_apply_current_state_guardrails "$max_workers" "$active_workers" "$available_slots" "$_DISPATCH_MIN_WORKER_FLOOR_ACTIVE") || guardrail_line="${max_workers} ${active_workers} ${available_slots}"
	read -r max_workers active_workers available_slots <<<"$guardrail_line"
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$available_slots" =~ ^-?[0-9]+$ ]] || available_slots=0
	if ((available_slots < 0)); then
		available_slots=0
	fi

	printf '%s %s %s\n' "$max_workers" "$active_workers" "$available_slots"
	return 0
}

#######################################
# Run triage under one cumulative Pulse-cycle budget, refreshing stale triage
# state at bounded intervals while unspent attempts remain. Typed outcomes never
# reduce worker slots or count as live implementation launches.
#
# Arguments:
#   $1 - available slots before pre-passes
# Stdout: "<remaining_slots> <triage_attempted> <triage_infrastructure_failed>"
#######################################
_dispatch_process_candidate() {
	local candidate_json="$1"
	local self_login="$2"
	local available_slots="$3"
	_DISPATCH_THROTTLE_CLEARED=0
	_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_UNKNOWN"

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

	# GH#30619: suppress unchanged overlap before expensive candidate ceremony.
	if _dispatch_skip_for_footprint_defer "$issue_number" "$repo_slug" "$candidate_json"; then
		return 1
	fi

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
		_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_INELIGIBLE"
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
	echo "[pulse-wrapper] DISPATCH_CANDIDATE_ATTEMPT #${issue_number} (${repo_slug})" >>"$LOGFILE"
	local dispatch_rc=0
	_dispatch_with_timeout "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$prompt" "issue-${issue_number}" "$model_override" || dispatch_rc=$?
	if [[ "$dispatch_rc" -ne 0 ]]; then
		_dispatch_record_nonzero_dispatch_result "$issue_number" "$repo_slug" "$dispatch_rc"
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
	_DISPATCH_CANDIDATE_ELIGIBILITY="eligible"

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
# t3005/t3014/GH#29234: Decide the parallelism level for dispatch_max.
#
# Defaults to DISPATCH_MAX_PARALLEL when set to a positive integer.
# When unset, empty, or non-numeric, defaults to 6 (GH#29234), then clamps to
# effective_slots. Worker slots represent settled worker capacity, not the safe
# number of concurrent API/worktree/runtime-start ceremony process trees. An
# explicit positive override remains available for larger or smaller hosts.
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
	# GH#29234: use a conservative ceremony cap when unset/empty/invalid. An env
	# override still wins when it is a positive integer; the effective-slot cap
	# below remains authoritative.
	local max_parallel="${DISPATCH_MAX_PARALLEL:-}"
	if ! [[ "$max_parallel" =~ ^[1-9][0-9]*$ ]]; then
		max_parallel=6
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
	if _dispatch_rest_core_requires_serial; then
		max_parallel=1
		echo "[pulse-wrapper] Dispatch_max: REST-core reserve-adjacent mode forces serial launch ceremony (GH#29742)" >>"$LOGFILE"
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
	local outcomes_file="${5:-}"

	local dispatched_count=0 processed_count=0 candidate_json
	while IFS= read -r candidate_json; do
		[[ -n "$candidate_json" ]] || continue
		processed_count=$((processed_count + 1))
		echo "[pulse-wrapper] Dispatch_max: loop iter=${processed_count} — entering body" >>"$LOGFILE"
		if [[ "$dispatched_count" -ge "$effective_slots" ]]; then
			echo "[pulse-wrapper] Dispatch_max: loop iter=${processed_count} — stopping (dispatched=${dispatched_count} >= effective_slots=${effective_slots})" >>"$LOGFILE"
			break
		fi
		if [[ -f "${STOP_FLAG:-}" ]]; then
			echo "[pulse-wrapper] Dispatch_max stopping early: stop flag appeared" >>"$LOGFILE"
			break
		fi
		if ! _dispatch_graphql_budget_allows_next; then
			echo "[pulse-wrapper] Dispatch_max stopping early: GraphQL circuit breaker tripped during serial loop" >>"$LOGFILE"
			break
		fi
		if ! _dispatch_rest_core_progress_allows_next "dispatch_serial_candidate"; then
			echo "[pulse-wrapper] Dispatch_max stopping early: REST-core launch headroom unavailable during serial loop" >>"$LOGFILE"
			break
		fi
		local _dispatch_proc_rc=0
		_dispatch_process_candidate "$candidate_json" "$self_login" "$available_slots" >>"$LOGFILE" 2>&1 || _dispatch_proc_rc=$?
		if [[ -n "$outcomes_file" ]]; then
			_dispatch_record_candidate_outcome "$candidate_json" "$_dispatch_proc_rc" "$outcomes_file" || return 1
		fi
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

	local processed_count=0 candidate_json
	local _pids=()
	while IFS= read -r candidate_json; do
		[[ -n "$candidate_json" ]] || continue
		processed_count=$((processed_count + 1))
		echo "[pulse-wrapper] Dispatch_max: parallel iter=${processed_count} — entering body" >>"$LOGFILE"

		_dispatch_max_refresh_pids _pids
		_dispatch_max_wait_for_capacity _pids "$max_parallel"

		local successes_so_far=0
		successes_so_far=$(_dispatch_max_count_outcomes "$outcomes_file")
		if _dispatch_max_should_stop "$processed_count" "$successes_so_far" "$effective_slots"; then
			break
		fi
		# Pending ceremonies reserve slots only until their outcomes are known.
		# Wait and reconcile the current candidate rather than ending the round:
		# a rejected ceremony frees its reservation for this unconsumed candidate.
		while ((successes_so_far + ${#_pids[@]} >= effective_slots)); do
			_dispatch_max_wait_for_reservation _pids
			successes_so_far=$(_dispatch_max_count_outcomes "$outcomes_file")
			if _dispatch_max_should_stop "$processed_count" "$successes_so_far" "$effective_slots"; then
				break 2
			fi
		done

		_dispatch_max_apply_inter_launch_delay "$successes_so_far" "${#_pids[@]}" "$processed_count" "$candidate_json" "$max_parallel"
		_dispatch_max_spawn_candidate "$candidate_json" "$self_login" "$available_slots" "$outcomes_file" &
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
# Wait for a pending admission reservation to finish, then remove completed
# children so its terminal outcome can free capacity for the current candidate.
#
# Arguments:
#   $1 - nameref-style array variable name
#######################################
_dispatch_max_wait_for_reservation() {
	local target_array_name="$1"

	if ! wait -n 2>/dev/null; then
		echo "[pulse-wrapper] Dispatch_max: wait -n found no children while reconciling reservations" >>"$LOGFILE"
	fi
	_dispatch_max_refresh_pids "$target_array_name"
	return 0
}

#######################################
# Refresh an array variable of tracked PIDs by removing children that already
# finished.
#
# Arguments:
#   $1 - nameref-style array variable name
#######################################
_dispatch_max_refresh_pids() {
	local target_array_name="$1"
	local pid
	local _alive_pids=()
	local _current_pids=()
	eval "_current_pids=(\"\${${target_array_name}[@]+\${${target_array_name}[@]}}\")"
	while IFS= read -r pid; do
		[[ -n "$pid" ]] && _alive_pids+=("$pid")
	done < <(_dispatch_max_reap_pids "${_current_pids[@]+${_current_pids[@]}}")
	eval "${target_array_name}=(\"\${_alive_pids[@]+\${_alive_pids[@]}}\")"
	return 0
}

#######################################
# Wait until tracked PIDs fall below the parallel dispatch concurrency cap.
#
# Arguments:
#   $1 - nameref-style array variable name
#   $2 - max parallel workers
#######################################
_dispatch_max_wait_for_capacity() {
	local target_array_name="$1"
	local max_parallel="$2"
	local current_count=0

	eval "current_count=\${#${target_array_name}[@]}"
	while ((current_count >= max_parallel)); do
		_dispatch_max_refresh_pids "$target_array_name"
		eval "current_count=\${#${target_array_name}[@]}"
		((current_count >= max_parallel)) || break

		# GH#21729: if wait -n fails, remaining PIDs are stale (PID reuse: kill
		# -0 succeeds for another process, but it is not this shell's child).
		if ! wait -n 2>/dev/null; then
			echo "[pulse-wrapper] Dispatch_max: wait -n found no children, purging ${current_count} stale PIDs from _pids (GH#21729)" >>"$LOGFILE"
			eval "${target_array_name}=()"
			sleep 1
		fi
		eval "current_count=\${#${target_array_name}[@]}"
	done
	return 0
}

#######################################
# Check whether the parallel dispatch loop should stop before launching another
# candidate.
#
# Arguments:
#   $1 - processed count
#   $2 - successes so far
#   $3 - effective slot budget
# Returns:
#   0 - stop the loop
#   1 - continue dispatching
#######################################
_dispatch_max_should_stop() {
	local processed_count="$1"
	local successes_so_far="$2"
	local effective_slots="$3"

	if ((successes_so_far >= effective_slots)); then
		echo "[pulse-wrapper] Dispatch_max: parallel iter=${processed_count} — stopping (successes=${successes_so_far} >= effective_slots=${effective_slots})" >>"$LOGFILE"
		return 0
	fi
	if [[ -f "${STOP_FLAG:-}" ]]; then
		echo "[pulse-wrapper] Dispatch_max stopping early: stop flag appeared" >>"$LOGFILE"
		return 0
	fi
	if ! _dispatch_graphql_budget_allows_next; then
		echo "[pulse-wrapper] Dispatch_max stopping early: GraphQL circuit breaker tripped during parallel loop" >>"$LOGFILE"
		return 0
	fi
	if ! _dispatch_rest_core_progress_allows_next "dispatch_parallel_candidate"; then
		echo "[pulse-wrapper] Dispatch_max stopping early: REST-core launch headroom unavailable during parallel loop" >>"$LOGFILE"
		return 0
	fi
	return 1
}

#######################################
# Apply adaptive inter-launch delay before spawning another dispatch worker.
#
# Arguments:
#   $1 - successes so far
#   $2 - in-flight dispatch count
#   $3 - processed count
#   $4 - candidate JSON
#   $5 - max parallel workers
#######################################
_dispatch_max_apply_inter_launch_delay() {
	local successes_so_far="$1"
	local in_flight_count="$2"
	local processed_count="$3"
	local candidate_json="$4"
	local max_parallel="$5"

	local launched_so_far=$((successes_so_far + in_flight_count))
	local inter_launch_delay
	inter_launch_delay=$(_dispatch_inter_launch_delay "$launched_so_far" "$processed_count" "$candidate_json" "$max_parallel")
	[[ "$inter_launch_delay" =~ ^[0-9]+$ ]] || inter_launch_delay=0
	if ((inter_launch_delay > 0)); then
		local issue_num_for_delay
		issue_num_for_delay=$(printf '%s' "$candidate_json" | jq -r '.number // 0' 2>/dev/null)
		_dispatch_stats_increment "dispatch_inter_launch_staggered"
		echo "[pulse-wrapper] Dispatch_max: adaptive inter-launch stagger issue=#${issue_num_for_delay} delay=${inter_launch_delay}s launched_so_far=${launched_so_far} max_parallel=${max_parallel}" >>"$LOGFILE"
		sleep "$inter_launch_delay"
	fi
	return 0
}

#######################################
# Dispatch one candidate and append its outcome to the parallel loop outcomes
# file. Intended to be backgrounded by _dispatch_max_loop.
#
# Arguments:
#   $1 - candidate JSON
#   $2 - self login
#   $3 - available slot budget
#   $4 - outcomes file
#######################################
_dispatch_max_spawn_candidate() {
	local candidate_json="$1"
	local self_login="$2"
	local available_slots="$3"
	local outcomes_file="$4"
	local _rc=0

	_dispatch_process_candidate "$candidate_json" "$self_login" "$available_slots" >>"$LOGFILE" 2>&1 || _rc=$?
	_dispatch_record_candidate_outcome "$candidate_json" "$_rc" "$outcomes_file"
	return $?
}

# Preserve repository/class identity and proven ineligibility across subshells.
# Args: candidate JSON, return code, existing outcomes file
_dispatch_record_candidate_outcome() {
	local candidate_json="$1" result_code="$2" outcomes_file="$3"
	local issue_num="" repo_slug="" priority="" fields="" eligibility="${_DISPATCH_CANDIDATE_ELIGIBILITY:-unknown}"
	fields=$(jq -r --arg unknown "$_DISPATCH_ELIGIBILITY_UNKNOWN" '[(.number // 0), (.repo_slug // $unknown), (.repo_priority // "tooling")] | @tsv' <<<"$candidate_json") || return 1
	IFS=$'\t' read -r issue_num repo_slug priority <<<"$fields"
	[[ "$repo_slug" =~ ^[A-Za-z0-9._/-]+$ ]] || repo_slug=unknown
	[[ "$priority" == product ]] || priority=tooling
	[[ "$eligibility" == ineligible ]] || eligibility=unknown
	if [[ "$result_code" -eq 0 ]]; then
		printf 'success|%s|repo=%s|priority=%s\n' "$issue_num" "$repo_slug" "$priority" >>"$outcomes_file" || return 1
	else
		printf 'fail|%s|rc=%d|reason=%s|repo=%s|priority=%s|eligibility=%s\n' \
			"$issue_num" "$result_code" "${_PULSE_LAST_LAUNCH_FAILURE:-none}" "$repo_slug" "$priority" "$eligibility" >>"$outcomes_file" || return 1
	fi
	return 0
}

# Run one bounded phase using the existing safety-checked serial/parallel loops.
# Args: candidate file, phase budget, login, parallelism, phase outcomes
_dispatch_run_priority_phase() {
	local candidates="$1" budget="$2" login="$3" parallel="$4" outcomes="$5"
	if ((budget <= 0)) || [[ ! -s "$candidates" ]]; then
		printf '0 0\n'
		return 0
	fi
	((parallel <= budget)) || parallel="$budget"
	if ((parallel <= 1)); then
		_dispatch_floor_loop "$candidates" "$budget" "$budget" "$login" "$outcomes"
	else
		_dispatch_max_loop "$candidates" "$budget" "$budget" "$login" "$parallel" "$outcomes"
	fi
	return $?
}

# Emit unattempted candidates in a selected phase, retaining ranking within it.
# Args: original candidates JSONL, accumulated outcomes, phase
_dispatch_priority_phase_candidates() {
	local candidates="$1" outcomes="$2" phase="$3"
	jq -sc --rawfile outcomes "$outcomes" --arg phase "$phase" --arg product "$_DISPATCH_PRIORITY_PRODUCT" \
		--arg success "$_DISPATCH_OUTCOME_SUCCESS" --arg failed "$_DISPATCH_OUTCOME_FAILED" '
		def urgent: ((.labels // []) | map(.name? // .)) | any(. == "priority:critical" or . == "priority:high");
		($outcomes | split("\n") | map(split("|")) |
		 map(select(.[0] == $success or .[0] == $failed) |
			.[1] as $number | .[] | select(startswith("repo=")) | [ltrimstr("repo="), $number])) as $attempted |
		.[] | . as $candidate |
		select(any($attempted[]; . == [$candidate.repo_slug, ($candidate.number | tostring)]) | not) |
		select(if $phase == "urgent" then urgent
			elif $phase == $product then .repo_priority == $product and (urgent | not)
			elif $phase == "ordinary" then .repo_priority != $product and (urgent | not)
			else true end)
	' "$candidates"
	return $?
}

# Product outcomes distinguish exhausted ineligible work from infrastructure failure.
_dispatch_priority_product_outcomes() {
	local outcomes="$1"
	awk -F'|' -v succeeded="$_DISPATCH_OUTCOME_SUCCESS" -v failed="$_DISPATCH_OUTCOME_FAILED" '
		{ product=0; ineligible=0
		  for (i=3; i<=NF; i++) {
			if ($i == "priority=product") product=1
			if ($i == "eligibility=ineligible") ineligible=1
		  }
		  if (product && $1 == succeeded) success++
		  if (product && $1 == failed && !ineligible) unknown++
		}
		END { print success+0, unknown+0 }
	' "$outcomes"
	return $?
}

# Start disjoint reserved/unreserved pools together, sharing one ceremony cap.
# Join before any borrowing: slow product probes cannot idle unreserved slots.
# Args: candidates, accumulated outcomes, capacity, reserved, login, parallelism,
#       caller-owned phase directory
_dispatch_priority_reserved_pools() {
	local candidates="$1" outcomes="$2" budget="$3" reserved="$4" login="$5" parallel="$6" phase_dir="$7"
	local ordinary=0 product_parallel=1 ordinary_parallel=1 product_pid="" ordinary_pid="" result=0
	((reserved <= budget)) || reserved="$budget"
	ordinary=$((budget - reserved))
	_dispatch_priority_phase_candidates "$candidates" "$outcomes" product >"$phase_dir/product.candidates" || return 1
	_dispatch_priority_phase_candidates "$candidates" "$outcomes" ordinary >"$phase_dir/ordinary.candidates" || return 1
	: >"$phase_dir/product.outcomes"
	: >"$phase_dir/ordinary.outcomes"
	if ((parallel > 1 && reserved > 0 && ordinary > 0)) &&
		[[ -s "$phase_dir/product.candidates" && -s "$phase_dir/ordinary.candidates" ]]; then
		product_parallel=$(((parallel * reserved + budget - 1) / budget))
		((product_parallel < parallel)) || product_parallel=$((parallel - 1))
		ordinary_parallel=$((parallel - product_parallel))
		_dispatch_run_priority_phase "$phase_dir/product.candidates" "$reserved" "$login" "$product_parallel" \
			"$phase_dir/product.outcomes" >"$phase_dir/product.result" &
		product_pid=$!
		_dispatch_run_priority_phase "$phase_dir/ordinary.candidates" "$ordinary" "$login" "$ordinary_parallel" \
			"$phase_dir/ordinary.outcomes" >"$phase_dir/ordinary.result" &
		ordinary_pid=$!
		wait "$product_pid" || result=1
		wait "$ordinary_pid" || result=1
	else
		_dispatch_run_priority_phase "$phase_dir/product.candidates" "$reserved" "$login" "$parallel" \
			"$phase_dir/product.outcomes" >"$phase_dir/product.result" || result=1
		_dispatch_run_priority_phase "$phase_dir/ordinary.candidates" "$ordinary" "$login" "$parallel" \
			"$phase_dir/ordinary.outcomes" >"$phase_dir/ordinary.result" || result=1
	fi
	cat "$phase_dir/product.outcomes" "$phase_dir/ordinary.outcomes" >>"$outcomes" || return 1
	return "$result"
}

# Fulfil product reservations using verified launches, then lend only proven slack.
# Urgent work is exempt. Every phase retains the existing bounded concurrency and
# API/resource/ownership gates; no candidate is attempted twice in a round.
# Args: candidates, budget, login, parallelism, outcomes, reserved product slots,
#       complete product discovery (true/false)
_dispatch_priority_loop() {
	local candidates="$1" budget="$2" login="$3" parallel="$4" outcomes="$5"
	local reserved="$6" complete="$7"
	local phase_dir="" phase="" phase_budget=0 launched=0 processed=0 result=""
	local phase_launched=0 phase_processed=0 product_launched=0 product_unknown=0 held=0
	phase_dir=$(mktemp -d) || return 1
	for phase in urgent pools remainder; do
		phase_budget=$((budget - launched))
		((phase_budget > 0)) || break
		read -r product_launched product_unknown < <(_dispatch_priority_product_outcomes "$outcomes")
		held=$((reserved - product_launched))
		((held >= 0)) || held=0
		if [[ "$phase" == pools ]]; then
			if [[ "$complete" == true && "$product_unknown" -eq 0 ]] &&
				! jq -se --arg product "$_DISPATCH_PRIORITY_PRODUCT" 'any(.[]; .repo_priority == $product)' "$candidates" >/dev/null; then
				held=0
			fi
			_dispatch_priority_reserved_pools "$candidates" "$outcomes" "$phase_budget" "$held" "$login" "$parallel" "$phase_dir" || {
				rm -rf "$phase_dir"; return 1;
			}
			launched=$(_dispatch_max_count_outcomes "$outcomes")
			continue
		fi
		_dispatch_priority_phase_candidates "$candidates" "$outcomes" "$phase" >"$phase_dir/candidates" || {
			rm -rf "$phase_dir"; return 1;
		}
		if [[ "$phase" == remainder && "$held" -gt 0 ]]; then
			if [[ "$complete" == true && "$product_unknown" -eq 0 ]] &&
				! jq -se --arg product "$_DISPATCH_PRIORITY_PRODUCT" 'any(.[]; .repo_priority == $product)' "$phase_dir/candidates" >/dev/null; then
				held=0
			fi
			phase_budget=$((phase_budget - held))
		fi
		: >"$phase_dir/outcomes"
		result=$(_dispatch_run_priority_phase "$phase_dir/candidates" "$phase_budget" "$login" "$parallel" "$phase_dir/outcomes") || {
			rm -rf "$phase_dir"; return 1;
		}
		read -r phase_launched phase_processed <<<"$result"
		launched=$((launched + phase_launched))
		processed=$((processed + phase_processed))
		cat "$phase_dir/outcomes" >>"$outcomes" || { rm -rf "$phase_dir"; return 1; }
	done
	read -r product_launched product_unknown < <(_dispatch_priority_product_outcomes "$outcomes")
	processed=$(awk -F'|' -v succeeded="$_DISPATCH_OUTCOME_SUCCESS" -v failed="$_DISPATCH_OUTCOME_FAILED" \
		'$1 == succeeded || $1 == failed { n++ } END { print n+0 }' "$outcomes")
	((held <= budget - launched)) || held=$((budget - launched))
	echo "[pulse-wrapper] PRIORITY_RESERVATION requested=${reserved} product_launched=${product_launched} held=${held} discovery_complete=${complete} launched=${launched}" >>"$LOGFILE"
	rm -rf "$phase_dir"
	printf '%s %s\n' "$launched" "$processed"
	return 0
}

# Compute the existing operator policy against local, verified active occupancy.
# Missing/unclassifiable workers never falsely satisfy the product minimum.
# Args: total worker capacity, active worker count, available slots
_dispatch_product_reservation_slots() {
	local max_workers="$1" active_workers="$2" available_slots="$3"
	local pct="${PRODUCT_RESERVATION_PCT:-60}" product_active=0 target=0 required=0
	local repos_file="${REPOS_JSON:-}" ledger="${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/dispatch-ledger.jsonl"
	if [[ ! -f "$repos_file" ]] || ! jq -e --arg product "$_DISPATCH_PRIORITY_PRODUCT" 'any(.initialized_repos[]?;
		.pulse == true and .maintenance != false and .priority == $product and
		(.local_only // false) == false and (.slug // "") != "")' "$repos_file" >/dev/null 2>&1; then
		printf '0\n'
		return 0
	fi
	[[ "$pct" =~ ^[0-9]+$ ]] || pct=60
	((pct <= 100)) || pct=100
	if ((active_workers > 0)) && [[ -f "$ledger" ]] && declare -F _process_start_token >/dev/null; then
		local pid="" recorded_start="" live_start="" active_rows=""
		active_rows=$(jq -sr --slurpfile repos "$repos_file" --argjson now "$(date +%s)" --arg priority "$_DISPATCH_PRIORITY_PRODUCT" '
			[$repos[0].initialized_repos[]? | select(.priority == $priority) | .slug] as $product |
			group_by(.session_key) | map(last) | map(
				select(.status == "in-flight" and .lease_phase == "ready" and (.lease_expires_at // 0) >= $now) |
				select(.repo_slug as $repo | $product | index($repo)) |
				select((.owner_process_start // "") != "")) |
			unique_by([.pid, .owner_process_start]) | .[] | [.pid, .owner_process_start] | @tsv
		' "$ledger" 2>/dev/null) || active_rows=""
		while IFS=$'\t' read -r pid recorded_start; do
			[[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
			kill -0 "$pid" 2>/dev/null || continue
			live_start=$(_process_start_token "$pid" 2>/dev/null) || continue
			[[ "$live_start" == "$recorded_start" ]] || continue
			product_active=$((product_active + 1))
		done <<<"$active_rows"
	fi
	((product_active <= active_workers)) || product_active="$active_workers"
	target=$(((max_workers * pct + 99) / 100))
	required=$((target - product_active))
	((required >= 0)) || required=0
	((required <= available_slots)) || required="$available_slots"
	echo "[pulse-wrapper] PRIORITY_CAPACITY product_target=${target} product_active_verified=${product_active} reserved_new=${required}" >>"$LOGFILE"
	printf '%s\n' "$required"
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
	successes=$(_dispatch_max_count_outcomes "$outcomes_file" "$_DISPATCH_OUTCOME_SUCCESS")
	fails=$(_dispatch_max_count_outcomes "$outcomes_file" "$_DISPATCH_OUTCOME_FAILED")
	# no_worker_process is identified via the reason field embedded in the
	# fail line — match the substring rather than adding another field.
	no_worker_failures=$(awk -F'|' -v t="$_DISPATCH_OUTCOME_FAILED" '$1==t && /no_worker_process/{c++} END{print c+0}' "$outcomes_file" 2>/dev/null)
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
