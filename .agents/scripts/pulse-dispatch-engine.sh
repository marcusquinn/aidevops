#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-engine.sh — High-level dispatch engine — worker launch check, ranked candidate build, deterministic fill-floor, LLM supervisor gate, backlog snapshot, adaptive launch settle wait, utilization invariants, underfill recycler + re-fill during active cycle, pre-flight stages, initial underfill computation, early-exit recycle loop.
#
# Extracted from pulse-wrapper.sh in Phase 9 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
# Phase 9 is the highest-risk phase — core dispatch logic.
#
# This module is sourced by pulse-wrapper.sh. Depends on shared-constants.sh
# and worker-lifecycle-common.sh being sourced first by the orchestrator.
#
# Public functions in this module (in source order):
#   - check_worker_launch
#   - build_ranked_dispatch_candidates_json
#   - dispatch_deterministic_fill_floor
#   - _should_run_llm_supervisor
#   - _update_backlog_snapshot
#   - _adaptive_launch_settle_wait
#   - apply_deterministic_fill_floor
#   - enforce_utilization_invariants
#   - run_underfill_worker_recycler
#   - maybe_refill_underfilled_pool_during_active_pulse
#   - _run_preflight_stages
#   - _compute_initial_underfill
#   - _run_early_exit_recycle_loop
#
# Internal helpers (GH#18656 function decomposition):
#   _dff_*                 — helpers for dispatch_deterministic_fill_floor
#   _preflight_*           — helpers for _run_preflight_stages
#
# Phase 9 origin: pure move from pulse-wrapper.sh, byte-identical bodies.
# GH#18656 split the two functions that still exceeded 100 lines
# (dispatch_deterministic_fill_floor=202, _run_preflight_stages=134)
# into focused helpers while preserving byte-for-byte behavior.

[[ -n "${_PULSE_DISPATCH_ENGINE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_ENGINE_LOADED=1

# t2863: Module-level variable defaults (set -u guards).
# These vars are normally set by pulse-wrapper.sh bootstrap and pulse-wrapper-config.sh.
# Guard them here so dispatch engine functions survive standalone sourcing (test
# harnesses, pulse-merge-routine.sh, or any caller that doesn't run the full bootstrap).
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${REPOS_JSON:=${HOME}/.config/aidevops/repos.json}"
: "${PIDFILE:=${HOME}/.aidevops/logs/pulse.pid}"
: "${PRE_RUN_STAGE_TIMEOUT:=600}"
# t2989: per-candidate cap inside dispatch_deterministic_fill_floor so a single
# hung dispatch_with_dedup call cannot consume the parent stage's full 600s
# budget. Canonical failure: preflight_early_dispatch 0/8 success rate after
# 07:00Z 2026-04-27 — single hung iter consumed the whole stage; cycle
# cadence collapsed from ~2min to ~40min. 30s is generous: dedup check +
# nohup worker spawn normally completes in <5s.
: "${FILL_FLOOR_PER_CANDIDATE_TIMEOUT:=30}"
# t3005: parallel dispatch concurrency for dispatch_deterministic_fill_floor.
# Each successful dispatch takes ~100s (most in worktree-helper.sh add) so the
# previous serial loop capped throughput at ~1 dispatch per pulse cycle.
# 6 concurrent dispatches × ~100s = full 24-slot pool reachable in ~1 cycle.
# Set to 1 to retain the legacy serial behavior (regression escape hatch).
# Capped at _effective_slots inside the function so parallelism never exceeds
# the slot budget.
: "${DISPATCH_FILL_FLOOR_PARALLEL:=6}"
: "${PULSE_ACTIVE_REFILL_INTERVAL:=120}"
: "${PULSE_ACTIVE_REFILL_IDLE_MIN:=60}"
: "${PULSE_ACTIVE_REFILL_STALL_MIN:=120}"
: "${PULSE_BACKFILL_MAX_ATTEMPTS:=3}"
: "${PULSE_LAUNCH_GRACE_SECONDS:=35}"
: "${PULSE_LAUNCH_SETTLE_BATCH_MAX:=5}"
: "${PULSE_LLM_DAILY_INTERVAL:=86400}"
: "${PULSE_LLM_STALL_THRESHOLD:=3600}"
: "${PULSE_RATE_LIMIT_FLAG:=${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}"
: "${PULSE_RUNNABLE_ISSUE_LIMIT:=1000}"

# t2690: Source rate-limit circuit breaker (proactive dispatch pause on GraphQL exhaustion).
# shellcheck source=pulse-rate-limit-circuit-breaker.sh
if [[ -f "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/pulse-rate-limit-circuit-breaker.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/pulse-rate-limit-circuit-breaker.sh"
fi

# t2781: Source per-issue rate_limit backoff helper (graduated cooldown by failure count).
# shellcheck source=dispatch-backoff-helper.sh
if [[ -f "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/dispatch-backoff-helper.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/dispatch-backoff-helper.sh"
fi

# t1959: Module-level variable to communicate launch failure reason to callers.
# Set by check_worker_launch before each return 1; read by dispatch loop for
# per-round no_worker_process tracking and canary cache invalidation.
_PULSE_LAST_LAUNCH_FAILURE=""

#######################################
# Launch validation gate for pulse dispatches (t1453)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional grace timeout in seconds
#
# Exit codes:
#   0 - worker launch appears valid (process observed, no CLI usage output marker)
#   1 - launch invalid (no process within grace window or usage output detected)
#######################################
check_worker_launch() {
	local issue_number="$1"
	local repo_slug="$2"
	local grace_seconds="${3:-$PULSE_LAUNCH_GRACE_SECONDS}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_worker_launch: invalid arguments issue='$issue_number' repo='$repo_slug'" >>"$LOGFILE"
		return 1
	fi
	[[ "$grace_seconds" =~ ^[0-9]+$ ]] || grace_seconds="$PULSE_LAUNCH_GRACE_SECONDS"
	if [[ "$grace_seconds" -lt 1 ]]; then
		grace_seconds=1
	fi

	local safe_slug
	safe_slug=$(echo "$repo_slug" | tr '/:' '--')
	local -a log_candidates=(
		"/tmp/pulse-${safe_slug}-${issue_number}.log"
		"/tmp/pulse-${issue_number}.log"
	)

	local elapsed=0
	local poll_seconds=2
	while [[ "$elapsed" -lt "$grace_seconds" ]]; do
		if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
			local candidate
			for candidate in "${log_candidates[@]}"; do
				if [[ -f "$candidate" ]] && rg -q '^opencode run \[message\.\.\]|^run opencode with a message|^Options:' "$candidate"; then
					recover_failed_launch_state "$issue_number" "$repo_slug" "cli_usage_output"
					echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — CLI usage output detected in ${candidate}" >>"$LOGFILE"
					_PULSE_LAST_LAUNCH_FAILURE="cli_usage_output"
					return 1
				fi
			done
			# Launch confirmed — do NOT reset fast-fail counter here.
			# A successful launch does not mean successful completion.
			# The counter is reset only when the issue is closed or a PR
			# is confirmed. Resetting on launch defeated the counter
			# entirely — workers that launched but died during execution
			# were invisible. (GH#2076, GH#17378)
			return 0
		fi
		sleep "$poll_seconds"
		elapsed=$((elapsed + poll_seconds))
	done

	recover_failed_launch_state "$issue_number" "$repo_slug" "no_worker_process"
	echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — no active worker process within ${grace_seconds}s" >>"$LOGFILE"
	_PULSE_LAST_LAUNCH_FAILURE="no_worker_process"
	return 1
}

#######################################
# Build ranked deterministic dispatch candidates across all pulse repos.
# Arguments:
#   $1 - max issues to fetch per repo (optional)
# Returns: JSON array sorted by score desc, updatedAt asc
#######################################
build_ranked_dispatch_candidates_json() {
	local per_repo_limit="${1:-$PULSE_RUNNABLE_ISSUE_LIMIT}"
	[[ "$per_repo_limit" =~ ^[0-9]+$ ]] || per_repo_limit="$PULSE_RUNNABLE_ISSUE_LIMIT"

	if [[ ! -f "$REPOS_JSON" ]]; then
		printf '[]\n'
		return 0
	fi

	local tmp_candidates
	tmp_candidates=$(mktemp 2>/dev/null || echo "/tmp/aidevops-pulse-candidates.$$")
	: >"$tmp_candidates"

	while IFS='|' read -r repo_slug repo_path repo_priority ph_start ph_end expires repo_interval; do
		[[ -n "$repo_slug" && -n "$repo_path" ]] || continue
		if ! check_repo_pulse_schedule "$repo_slug" "$ph_start" "$ph_end" "$expires" "$REPOS_JSON"; then
			continue
		fi
		# Per-repo interval throttle (GH#20660): skip if polled too recently
		if ! check_repo_pulse_interval "$repo_slug" "$repo_interval"; then
			continue
		fi
		# Record that we are polling this repo now (atomic write, non-fatal)
		update_repo_pulse_timestamp "$repo_slug"
		local repo_candidates_json
		repo_candidates_json=$(list_dispatchable_issue_candidates_json "$repo_slug" "$per_repo_limit") || repo_candidates_json='[]'
		if [[ -z "$repo_candidates_json" || "$repo_candidates_json" == "[]" ]]; then
			continue
		fi

		printf '%s' "$repo_candidates_json" | jq -c --arg slug "$repo_slug" --arg path "$repo_path" --arg priority "$repo_priority" '
			.[] |
			. + {
				repo_slug: $slug,
				repo_path: $path,
				repo_priority: $priority,
				score: (
					(if $priority == "tooling" then 2000 elif $priority == "product" then 1000 else 0 end) +
					(if (.labels | index("priority:critical")) != null then 10000
					 elif (.labels | index("priority:high")) != null then 8000
					 elif (.labels | index("bug")) != null then 7000
					 elif (.labels | index("enhancement")) != null then 6000
					 elif (.labels | index("quality-debt")) != null then 5000
					 elif ((.labels | index("file-size-debt")) != null or (.labels | index("function-complexity-debt")) != null) then 4000
					 else 3000 end)
				)
			}
		' >>"$tmp_candidates" 2>/dev/null || true
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "" and .path != "") | [(.slug), (.path), (.priority // "tooling"), (if .pulse_hours then (.pulse_hours.start | tostring) else "" end), (if .pulse_hours then (.pulse_hours.end | tostring) else "" end), (.pulse_expires // ""), (.pulse_interval // "")] | join("|")' "$REPOS_JSON" 2>/dev/null)

	if [[ ! -s "$tmp_candidates" ]]; then
		rm -f "$tmp_candidates"
		printf '[]\n'
		return 0
	fi

	jq -cs 'sort_by([-.score, (.updatedAt // "")])' "$tmp_candidates" 2>/dev/null || printf '[]\n'
	rm -f "$tmp_candidates"
	return 0
}

# -----------------------------------------------------------------------------
# Helpers for dispatch_deterministic_fill_floor (GH#18656)
# -----------------------------------------------------------------------------
# The helpers below are split out so the orchestrator stays under 100 lines
# and each discrete responsibility (capacity planning, pre-passes, per-candidate
# skip checks, launch-outcome tracking, post-round throttle) can be read and
# reviewed in isolation. Behavior is byte-for-byte equivalent to the pre-split
# monolithic function — see git log for the refactor commit.
#
# The round-state counters (_round_dispatched, _round_no_worker_failures,
# _consecutive_no_worker) are module-level with a `_DFF_` prefix so the
# helpers can update them without needing bash 4.3+ namerefs.

_DFF_ROUND_DISPATCHED=0
_DFF_ROUND_NO_WORKER_FAILURES=0
_DFF_CONSECUTIVE_NO_WORKER=0
_DFF_THROTTLE_FILE=""
_DFF_CANARY_CACHE=""
# Out-parameter set by _dff_process_candidate when a successful launch clears
# the throttle file. The orchestrator loop reads this and restores
# _effective_slots to the unthrottled available_slots value.
_DFF_THROTTLE_CLEARED=0

#######################################
# Emit per-candidate debug output for the deterministic fill floor (GH#18804).
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
# Compute the dispatch capacity for this round.
#
# Stdout: "<max_workers> <active_workers> <available_slots>" on success.
# Returns:
#   0 - capacity computed (caller checks available_slots > 0 before dispatch)
#   1 - stop flag present; caller should short-circuit
#######################################
_dff_compute_capacity() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor skipped: stop flag present" >>"$LOGFILE"
		return 1
	fi

	# t2690: Proactive rate-limit circuit breaker — pause dispatch when GraphQL
	# budget is nearly exhausted. One cheap API call (free endpoint) prevents
	# spawning workers that would fail at step 1 and burn $0.05-$0.25 each.
	if declare -F is_graphql_budget_sufficient >/dev/null 2>&1; then
		local _cb_rc=0
		is_graphql_budget_sufficient || _cb_rc=$?
		if [[ "$_cb_rc" -eq 1 ]]; then
			echo "[pulse-wrapper] Deterministic fill floor skipped: GraphQL rate-limit circuit breaker tripped (t2690)" >>"$LOGFILE"
			return 1
		fi
		# _cb_rc == 2 means API error — fail-open, proceed with dispatch.
	fi

	local max_workers active_workers available_slots
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	available_slots=$((max_workers - active_workers))

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
_dff_run_prepasses() {
	local available_slots="$1"

	local triage_remaining
	triage_remaining=$(dispatch_triage_reviews "$available_slots" 2>>"$LOGFILE") || triage_remaining="$available_slots"
	[[ "$triage_remaining" =~ ^[0-9]+$ ]] || triage_remaining="$available_slots"
	local triage_dispatched=$((available_slots - triage_remaining))
	if [[ "$triage_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: dispatched ${triage_dispatched} triage review(s), ${triage_remaining} slots remaining for implementation" >>"$LOGFILE"
	fi
	available_slots="$triage_remaining"

	local enrichment_remaining
	enrichment_remaining=$(dispatch_enrichment_workers "$available_slots" 2>>"$LOGFILE") || enrichment_remaining="$available_slots"
	[[ "$enrichment_remaining" =~ ^[0-9]+$ ]] || enrichment_remaining="$available_slots"
	local enrichment_dispatched=$((available_slots - enrichment_remaining))
	if [[ "$enrichment_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: dispatched ${enrichment_dispatched} enrichment worker(s), ${enrichment_remaining} slots remaining for implementation" >>"$LOGFILE"
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
_dff_should_skip_candidate() {
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
	# `_dff_should_skip_candidate` runs inside the dispatch loop, which
	# itself runs inside the `dispatch_deterministic_fill_floor` subshell
	# created by `fill_dispatched=$(dispatch_deterministic_fill_floor)`.
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
		echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — terminal blocker detected (check_terminal_blockers rc=0)" >>"$LOGFILE"
		return 0
	fi

	# t2397: Age-out HARD STOP'd issues that have been quiet for >=24h so
	# transient failures (model availability, CI flakes, stale framework bugs)
	# don't permanently strand issues. Called before fast_fail_is_skipped so
	# a just-reset counter allows dispatch in the same cycle.
	fast_fail_age_out "$issue_number" "$repo_slug" || true

	if fast_fail_is_skipped "$issue_number" "$repo_slug"; then
		echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — fast-fail threshold reached" >>"$LOGFILE"
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
			echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — ${_backoff_output}" >>"$LOGFILE"
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
			echo "[pulse-wrapper] Deterministic fill floor: backoff check error for #${issue_number} — proceeding (fail-open)" >>"$LOGFILE"
		fi
	fi

	# t1899/t1937: Skip issues with placeholder/empty bodies — dispatching a
	# worker to an undescribed issue wastes a session. The body check is
	# a single API call per candidate. Detects both the legacy GitLab stub
	# and the current claim-task-id.sh stub marker.
	local issue_body
	issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body --jq '.body // ""' 2>/dev/null) || issue_body=""
	pulse_dispatch_debug_log "#${issue_number}: body length=${#issue_body}"
	if [[ -z "$issue_body" || "$issue_body" == "Task created via claim-task-id.sh" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — placeholder/empty issue body, needs enrichment before dispatch" >>"$LOGFILE"
		return 0
	fi
	if [[ "$issue_body" == *"no description provided — enrich before dispatch"* ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — claim-task-id.sh stub body, needs enrichment before dispatch" >>"$LOGFILE"
		return 0
	fi

	pulse_dispatch_debug_log "#${issue_number}: passed all skip checks — proceeding to dispatch"
	return 1
}

#######################################
# Record a check_worker_launch failure. Updates the round counters and, on
# three consecutive no_worker_process failures, invalidates the canary cache
# so the next dispatch forces a re-test instead of trusting a stale "passed N
# minutes ago" signal (t1959).
#######################################
_dff_record_launch_failure() {
	if [[ "$_PULSE_LAST_LAUNCH_FAILURE" == "no_worker_process" ]]; then
		_DFF_ROUND_NO_WORKER_FAILURES=$((_DFF_ROUND_NO_WORKER_FAILURES + 1))
		_DFF_CONSECUTIVE_NO_WORKER=$((_DFF_CONSECUTIVE_NO_WORKER + 1))
		if [[ "$_DFF_CONSECUTIVE_NO_WORKER" -ge 3 ]]; then
			if [[ -f "$_DFF_CANARY_CACHE" ]]; then
				rm -f "$_DFF_CANARY_CACHE"
				echo "[pulse-wrapper] Canary cache invalidated after ${_DFF_CONSECUTIVE_NO_WORKER} consecutive no_worker_process failures in round — next dispatch will re-run canary" >>"$LOGFILE"
			fi
			_DFF_CONSECUTIVE_NO_WORKER=0
		fi
	else
		# cli_usage_output or other launch-class failure: don't count toward
		# the consecutive no_worker_process streak.
		_DFF_CONSECUTIVE_NO_WORKER=0
	fi
	return 0
}

#######################################
# t2989: Run dispatch_with_dedup with a per-candidate wall-clock timeout.
#
# Wraps the call in run_stage_with_timeout (default 30s, env override
# FILL_FLOOR_PER_CANDIDATE_TIMEOUT). On timeout, kills the entire process
# tree, emits a distinct log line, and bumps the
# fill_floor_per_candidate_timeout counter in pulse-stats.json so cycle
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
_dff_dispatch_with_timeout() {
	local issue_number="$1"
	local repo_slug="$2"

	# t3003: adaptive per-candidate timeout. When DISPATCH_TIMING_ADAPTIVE=1
	# (default), dispatch-timing-helper.sh recommends a budget based on the
	# EWMA + p95 of recent successful dispatches; on timeouts it switches to
	# probe mode (2x last_timeout). Old fixed FILL_FLOOR_PER_CANDIDATE_TIMEOUT
	# is preserved as the legacy fallback when the helper is unavailable or
	# DISPATCH_TIMING_ADAPTIVE=0.
	local timeout_seconds="$FILL_FLOOR_PER_CANDIDATE_TIMEOUT"
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

	local start_ms dispatch_rc=0 outcome elapsed_ms
	start_ms=$(_dff_now_ms)
	run_stage_with_timeout "fill_floor_candidate_${issue_number}" "$timeout_seconds" \
		dispatch_with_dedup "$@" || dispatch_rc=$?
	elapsed_ms=$(($(_dff_now_ms) - start_ms))
	echo "[pulse-wrapper] Deterministic fill floor: dispatch_with_dedup returned rc=${dispatch_rc} for #${issue_number} elapsed_ms=${elapsed_ms} timeout_used_ms=${timeout_ms}" >>"$LOGFILE"

	if [[ "$dispatch_rc" -eq 124 ]]; then
		outcome="timeout"
		# t2989 + t3003: per-candidate timeout — log distinctly, bump counter,
		# record outcome so the next recommendation enters probe mode.
		echo "[pulse-wrapper] Deterministic fill floor: per-candidate timeout (${timeout_seconds}s) on #${issue_number} (${repo_slug}) — killing candidate, continuing loop" >>"$LOGFILE"
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "fill_floor_per_candidate_timeout" 2>/dev/null || true
		fi
	elif [[ "$dispatch_rc" -eq 0 ]]; then
		outcome="success"
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
# t3003: bash 3.2-compatible millisecond timestamp.
# GNU date supports %N (nanoseconds); macOS BSD date does not. We strip the
# trailing 6 digits to convert ns→ms when GNU date is present, otherwise fall
# back to seconds×1000 (sufficient resolution for ≥1s timeouts).
#######################################
_dff_now_ms() {
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
#       dispatched_count; if _DFF_THROTTLE_CLEARED=1 also restore
#       _effective_slots)
#   1 - candidate skipped or dispatch failed (caller should `continue`)
#
# Side effects:
#   - Updates _DFF_ROUND_DISPATCHED / _DFF_ROUND_NO_WORKER_FAILURES /
#     _DFF_CONSECUTIVE_NO_WORKER for the round.
#   - Clears _DFF_THROTTLE_FILE and sets _DFF_THROTTLE_CLEARED=1 on a
#     successful launch while throttle was active.
#######################################
_dff_process_candidate() {
	local candidate_json="$1"
	local self_login="$2"
	local available_slots="$3"
	_DFF_THROTTLE_CLEARED=0

	local issue_number repo_slug repo_path issue_url issue_title dispatch_title prompt labels_csv model_override
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
		echo "[pulse-wrapper] Deterministic fill floor: skipping malformed candidate — issue_number='${issue_number}' is not numeric (candidate_json prefix: ${candidate_json:0:120})" >>"$LOGFILE"
		return 1
	fi
	if [[ -z "$repo_slug" || -z "$repo_path" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} — missing repo_slug='${repo_slug}' or repo_path='${repo_path}'" >>"$LOGFILE"
		return 1
	fi

	pulse_dispatch_debug_log "processing #${issue_number} (${repo_slug}) labels=[${labels_csv}]"

	if _dff_should_skip_candidate "$issue_number" "$repo_slug"; then
		return 1
	fi

	dispatch_title="Issue #${issue_number}"
	prompt="/full-loop Implement issue #${issue_number}"
	if [[ -n "$issue_url" ]]; then
		prompt="${prompt} (${issue_url})"
	fi
	model_override=$(resolve_dispatch_model_for_labels "$labels_csv")
	pulse_dispatch_debug_log "#${issue_number}: model_override=${model_override:-<auto>} — calling dispatch_with_dedup"

	# t2433/GH#20071: Refresh the repo before the large-file gate (inside
	# dispatch_with_dedup → _dispatch_dedup_check_layers → _issue_targets_large_files)
	# measures file sizes. Sentinel prevents multiple pulls for the same repo
	# within a single dispatch_deterministic_fill_floor subshell execution.
	_pulse_refresh_repo "$repo_path"

	# GH#18804 + t2989: dispatch with isolation + per-candidate timeout.
	# Detail (subshell isolation, hang signature, 30s default rationale):
	# see _dff_dispatch_with_timeout doc comment above.
	local dispatch_rc=0
	_dff_dispatch_with_timeout "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$prompt" "issue-${issue_number}" "$model_override" || dispatch_rc=$?
	if [[ "$dispatch_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: skipping #${issue_number} (${repo_slug}) — dispatch_with_dedup returned rc=${dispatch_rc}" >>"$LOGFILE"
		return 1
	fi

	# Count every successful dispatch attempt as a round denominator (t1959)
	_DFF_ROUND_DISPATCHED=$((_DFF_ROUND_DISPATCHED + 1))
	_PULSE_LAST_LAUNCH_FAILURE=""

	local launch_rc=0
	check_worker_launch "$issue_number" "$repo_slug" >/dev/null 2>&1 || launch_rc=$?
	if [[ "$launch_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Deterministic fill floor: #${issue_number} (${repo_slug}) launch validation failed (rc=${launch_rc}, last_failure='${_PULSE_LAST_LAUNCH_FAILURE}')" >>"$LOGFILE"
		_dff_record_launch_failure
		return 1
	fi

	# Launch confirmed. Reset consecutive streak and clear throttle if active.
	_DFF_CONSECUTIVE_NO_WORKER=0
	# t1959: A single successful launch proves the runtime is back.
	# Restore full batch immediately — do not wait for N successes.
	if [[ -f "$_DFF_THROTTLE_FILE" ]]; then
		rm -f "$_DFF_THROTTLE_FILE"
		echo "[pulse-wrapper] Dispatch throttle CLEARED: launch success in throttled mode — restoring full batch=${available_slots}" >>"$LOGFILE"
		_DFF_THROTTLE_CLEARED=1
	fi
	return 0
}

#######################################
# After the dispatch loop finishes, compute the no_worker_process failure
# ratio for this round. If >80% of dispatches ended with no_worker_process,
# engage the adaptive batch throttle so the next round is limited to batch=1
# to avoid wasted dispatch cycles during runtime breakage (t1959).
#######################################
_dff_maybe_engage_throttle() {
	if [[ "$_DFF_ROUND_DISPATCHED" -gt 0 ]]; then
		local ratio_pct=$((_DFF_ROUND_NO_WORKER_FAILURES * 100 / _DFF_ROUND_DISPATCHED))
		if [[ "$ratio_pct" -gt 80 ]]; then
			echo "1" >"$_DFF_THROTTLE_FILE" 2>/dev/null || true
			echo "[pulse-wrapper] Dispatch throttle ENGAGED: ${ratio_pct}% no_worker_process in round (${_DFF_ROUND_NO_WORKER_FAILURES}/${_DFF_ROUND_DISPATCHED}) — next round limited to batch=1" >>"$LOGFILE"
		fi
	fi
	return 0
}

#######################################
# t3005: Decide the parallelism level for the deterministic fill-floor loop.
#
# Defaults to DISPATCH_FILL_FLOOR_PARALLEL (env, default 6). Capped at the
# effective slot budget — never schedule more concurrent dispatches than
# slots we'd consume. Forced to 1 when the adaptive throttle file is present
# (degraded runtime — the existing serial throttle behavior is preserved as
# the regression escape hatch and the "test the waters" semantics).
#
# Arguments:
#   $1 - effective_slots (already throttle-aware: 1 in throttle mode)
# Stdout: integer parallelism level (>= 1)
#######################################
_dff_compute_max_parallel() {
	local effective_slots="$1"
	local max_parallel="${DISPATCH_FILL_FLOOR_PARALLEL:-6}"
	[[ "$max_parallel" =~ ^[1-9][0-9]*$ ]] || max_parallel=6
	if ((max_parallel > effective_slots)); then
		max_parallel="$effective_slots"
	fi
	# In throttle mode, _effective_slots is already 1 → max_parallel=1 (serial).
	# Defensive: also short-circuit on direct file presence in case caller
	# passes a non-throttled effective_slots while throttle is active.
	if [[ -f "$_DFF_THROTTLE_FILE" ]]; then
		max_parallel=1
	fi
	((max_parallel < 1)) && max_parallel=1
	printf '%d\n' "$max_parallel"
	return 0
}

#######################################
# t3005: Serial dispatch loop (original behavior, refactored into a helper).
#
# Iterates candidates one at a time, calling _dff_process_candidate inline.
# Module-global state mutations (_DFF_ROUND_DISPATCHED, _DFF_THROTTLE_CLEARED,
# _PULSE_LAST_LAUNCH_FAILURE, _DFF_CONSECUTIVE_NO_WORKER) propagate normally
# because the loop runs in the parent shell, not a backgrounded subshell.
#
# Arguments:
#   $1 - candidate_file (one JSON candidate per line)
#   $2 - effective_slots (slot budget at loop start, may be throttled to 1)
#   $3 - available_slots (unthrottled slot budget — restored if throttle clears)
#   $4 - self_login (GitHub login for dedup)
# Stdout: "<dispatched_count> <processed_count>"
#######################################
_dff_dispatch_loop_serial() {
	local candidate_file="$1"
	local effective_slots="$2"
	local available_slots="$3"
	local self_login="$4"

	local dispatched_count=0 processed_count=0 candidate_json
	while IFS= read -r candidate_json; do
		[[ -n "$candidate_json" ]] || continue
		processed_count=$((processed_count + 1))
		echo "[pulse-wrapper] Deterministic fill floor: loop iter=${processed_count} — entering body" >>"$LOGFILE"
		if [[ "$dispatched_count" -ge "$effective_slots" ]]; then
			echo "[pulse-wrapper] Deterministic fill floor: loop iter=${processed_count} — stopping (dispatched=${dispatched_count} >= effective_slots=${effective_slots})" >>"$LOGFILE"
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Deterministic fill floor stopping early: stop flag appeared" >>"$LOGFILE"
			break
		fi
		local _dff_proc_rc=0
		_dff_process_candidate "$candidate_json" "$self_login" "$available_slots" || _dff_proc_rc=$?
		echo "[pulse-wrapper] Deterministic fill floor: loop iter=${processed_count} — _dff_process_candidate rc=${_dff_proc_rc}" >>"$LOGFILE"
		if [[ "$_dff_proc_rc" -eq 0 ]]; then
			dispatched_count=$((dispatched_count + 1))
			# Throttle cleared mid-round by a successful launch — restore
			# the unthrottled slot budget so subsequent iterations dispatch.
			if [[ "$_DFF_THROTTLE_CLEARED" -eq 1 ]]; then
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
# mutations inside _dff_process_candidate are isolated to the subshell and
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
#   $3 - available_slots (passed through to _dff_process_candidate)
#   $4 - self_login
#   $5 - max_parallel (bounded concurrency level)
#   $6 - outcomes_file (created by caller, parent reads it post-loop)
# Stdout: "<dispatched_count> <processed_count>"
#######################################
_dff_dispatch_loop_parallel() {
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
		echo "[pulse-wrapper] Deterministic fill floor: parallel iter=${processed_count} — entering body" >>"$LOGFILE"

		# Reap finished pids so the array reflects current in-flight count.
		# Bash 3.2-safe: while-read via process substitution avoids SC2207
		# (no array splitting) and handles empty input cleanly.
		_alive_pids=()
		while IFS= read -r pid; do
			[[ -n "$pid" ]] && _alive_pids+=("$pid")
		done < <(_dff_reap_pids "${_pids[@]+${_pids[@]}}")
		_pids=("${_alive_pids[@]+${_alive_pids[@]}}")

		# Wait for one to finish if we're at the concurrency cap
		while ((${#_pids[@]} >= max_parallel)); do
			wait -n 2>/dev/null || true
			_alive_pids=()
			while IFS= read -r pid; do
				[[ -n "$pid" ]] && _alive_pids+=("$pid")
			done < <(_dff_reap_pids "${_pids[@]+${_pids[@]}}")
			_pids=("${_alive_pids[@]+${_alive_pids[@]}}")
		done

		# Budget check: successes already recorded + currently in flight
		# must stay below effective_slots. Reading the file is cheap (<1KB).
		local successes_so_far
		successes_so_far=$(_dff_count_outcomes "$outcomes_file")
		if ((successes_so_far + ${#_pids[@]} >= effective_slots)); then
			echo "[pulse-wrapper] Deterministic fill floor: parallel iter=${processed_count} — stopping (successes=${successes_so_far} + in_flight=${#_pids[@]} >= effective_slots=${effective_slots})" >>"$LOGFILE"
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Deterministic fill floor stopping early: stop flag appeared" >>"$LOGFILE"
			break
		fi

		# Background dispatch with outcomes-file write.
		# The subshell isolates _dff_process_candidate's module-global
		# mutations; only the file system mutations (throttle removal,
		# canary cache) and the outcomes file write propagate.
		(
			local _rc=0
			_dff_process_candidate "$candidate_json" "$self_login" "$available_slots" || _rc=$?
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

	# Wait for all in-flight dispatches to complete
	wait
	local dispatched_count
	dispatched_count=$(_dff_count_outcomes "$outcomes_file")
	printf '%d %d\n' "$dispatched_count" "$processed_count"
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
_dff_count_outcomes() {
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
_dff_reap_pids() {
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
# After the parallel loop returns, _DFF_ROUND_DISPATCHED and
# _DFF_ROUND_NO_WORKER_FAILURES are still 0 because the subshells couldn't
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
#   - Sets _DFF_ROUND_DISPATCHED, _DFF_ROUND_NO_WORKER_FAILURES
#   - Removes _DFF_CANARY_CACHE if no_worker_failures >= 3
#   - Removes _DFF_THROTTLE_FILE if any successes (parallel can only run when
#     throttle was already off, but defensive cleanup is cheap)
#######################################
_dff_aggregate_outcomes() {
	local outcomes_file="$1"
	local successes="" fails="" no_worker_failures=""
	successes=$(_dff_count_outcomes "$outcomes_file" "success")
	fails=$(_dff_count_outcomes "$outcomes_file" "fail")
	# no_worker_process is identified via the reason field embedded in the
	# fail line — match the substring rather than adding another field.
	no_worker_failures=$(awk -F'|' -v t="fail" '$1==t && /no_worker_process/{c++} END{print c+0}' "$outcomes_file" 2>/dev/null)
	[[ "$no_worker_failures" =~ ^[0-9]+$ ]] || no_worker_failures=0

	_DFF_ROUND_DISPATCHED=$((successes + fails))
	_DFF_ROUND_NO_WORKER_FAILURES="$no_worker_failures"

	if ((no_worker_failures >= 3)); then
		if [[ -f "$_DFF_CANARY_CACHE" ]]; then
			rm -f "$_DFF_CANARY_CACHE"
			echo "[pulse-wrapper] Canary cache invalidated after ${no_worker_failures} no_worker_process failures in parallel round — next dispatch will re-run canary" >>"$LOGFILE"
		fi
	fi

	if ((successes > 0)) && [[ -f "$_DFF_THROTTLE_FILE" ]]; then
		rm -f "$_DFF_THROTTLE_FILE"
		echo "[pulse-wrapper] Dispatch throttle CLEARED: parallel round had ${successes} successful launches" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Deterministic fill floor for obvious backlog.
#
# This is intentionally narrow: it only materializes already-eligible issues
# and fills empty local slots. Ranking remains simple and auditable; judgment
# stays with the pulse LLM for merges, blockers, and unusual edge cases.
#
# t3005: Loop body extracted into _dff_dispatch_loop_serial /
# _dff_dispatch_loop_parallel — the orchestrator picks one based on
# DISPATCH_FILL_FLOOR_PARALLEL (default 6) and adaptive throttle state.
# Throttle mode forces serial (1 dispatch per round) to preserve the existing
# "test the waters" recovery semantics; otherwise parallel is preferred so
# the 24-slot pool fills in 1-2 cycles instead of 40 minutes.
#
# Returns: dispatched worker count via stdout
#######################################
dispatch_deterministic_fill_floor() {
	local capacity_line
	capacity_line=$(_dff_compute_capacity) || {
		echo 0
		return 0
	}
	local max_workers active_workers available_slots
	read -r max_workers active_workers available_slots <<<"$capacity_line"
	if [[ "$available_slots" -le 0 ]]; then
		echo 0
		return 0
	fi

	local runnable_count queued_without_worker
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$self_login" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor skipped: unable to resolve GitHub login" >>"$LOGFILE"
		echo 0
		return 0
	fi

	local candidates_json candidate_count
	candidates_json=$(build_ranked_dispatch_candidates_json "$PULSE_RUNNABLE_ISSUE_LIMIT") || candidates_json='[]'
	candidate_count=$(printf '%s' "$candidates_json" | jq 'length' 2>/dev/null) || candidate_count=0
	[[ "$candidate_count" =~ ^[0-9]+$ ]] || candidate_count=0
	if [[ "$candidate_count" -eq 0 ]]; then
		echo 0
		return 0
	fi

	echo "[pulse-wrapper] Deterministic fill floor: available=${available_slots}, runnable=${runnable_count}, queued_without_worker=${queued_without_worker}, candidates=${candidate_count}" >>"$LOGFILE"

	local prepass_line=""
	local triage_dispatched=0
	if ! prepass_line=$(_dff_run_prepasses "$available_slots" 2>>"$LOGFILE"); then
		echo "[pulse-wrapper] Deterministic fill floor: _dff_run_prepasses returned non-zero — assuming 0 triage/enrichment, full slot budget" >>"$LOGFILE"
		prepass_line="${available_slots} 0"
	fi
	read -r available_slots triage_dispatched <<<"$prepass_line"
	[[ "$available_slots" =~ ^[0-9]+$ ]] || available_slots=0
	[[ "$triage_dispatched" =~ ^[0-9]+$ ]] || triage_dispatched=0
	pulse_dispatch_debug_log "post-prepasses available_slots=${available_slots} triage_dispatched=${triage_dispatched}"

	# Reset module-level round state before the dispatch loop (t1959).
	_DFF_ROUND_DISPATCHED=0
	_DFF_ROUND_NO_WORKER_FAILURES=0
	_DFF_CONSECUTIVE_NO_WORKER=0
	_DFF_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DFF_CANARY_CACHE="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}/canary-last-pass"

	# Honour adaptive batch throttle — limit to 1 when runtime is degraded.
	local _effective_slots="$available_slots"
	if [[ -f "$_DFF_THROTTLE_FILE" ]]; then
		_effective_slots=1
		echo "[pulse-wrapper] Dispatch throttle active: limiting implementation batch to 1 (runtime degraded)" >>"$LOGFILE"
	fi

	# t3005: pick parallelism level (1 = serial, >1 = parallel via wait -n).
	local _dff_max_parallel
	_dff_max_parallel=$(_dff_compute_max_parallel "$_effective_slots")

	echo "[pulse-wrapper] Deterministic fill floor: entering candidate loop with effective_slots=${_effective_slots}, max_parallel=${_dff_max_parallel}, candidates=${candidate_count}" >>"$LOGFILE"
	local _dff_first_candidate_preview
	_dff_first_candidate_preview=$(printf '%s' "$candidates_json" | jq -c '.[0]' 2>/dev/null || echo "<jq error>")
	echo "[pulse-wrapper] Deterministic fill floor: first candidate preview (240 bytes): ${_dff_first_candidate_preview:0:240}" >>"$LOGFILE"

	# GH#18804 follow-up: feed candidates from a tempfile rather than process substitution.
	local _dff_candidate_file=""
	_dff_candidate_file=$(mktemp 2>/dev/null || echo "/tmp/aidevops-dff-candidates.$$")
	if ! printf '%s' "$candidates_json" | jq -c '.[]' >"$_dff_candidate_file" 2>>"$LOGFILE"; then
		echo "[pulse-wrapper] Deterministic fill floor: jq failed to enumerate candidates_json — aborting loop with 0 dispatches" >>"$LOGFILE"
		rm -f "$_dff_candidate_file"
		_dff_maybe_engage_throttle
		echo "[pulse-wrapper] Deterministic fill floor complete: dispatched=${triage_dispatched} (${triage_dispatched} triage + 0 implementation), processed=0/${candidate_count}, target_available=${available_slots}" >>"$LOGFILE"
		echo "$triage_dispatched"
		return 0
	fi
	local _dff_line_count
	_dff_line_count=$(wc -l <"$_dff_candidate_file" 2>/dev/null | tr -d ' ' || echo 0)
	echo "[pulse-wrapper] Deterministic fill floor: candidate enumeration produced ${_dff_line_count} lines in ${_dff_candidate_file}" >>"$LOGFILE"

	# Branch: serial (legacy / throttle / DISPATCH_FILL_FLOOR_PARALLEL=1) vs parallel.
	local dispatched_count=0 processed_count=0 loop_output=""
	local _dff_outcomes_file=""
	if ((_dff_max_parallel <= 1)); then
		loop_output=$(_dff_dispatch_loop_serial "$_dff_candidate_file" "$_effective_slots" "$available_slots" "$self_login")
	else
		_dff_outcomes_file=$(mktemp 2>/dev/null || echo "/tmp/aidevops-dff-outcomes.$$")
		: >"$_dff_outcomes_file"
		loop_output=$(_dff_dispatch_loop_parallel "$_dff_candidate_file" "$_effective_slots" "$available_slots" "$self_login" "$_dff_max_parallel" "$_dff_outcomes_file")
		_dff_aggregate_outcomes "$_dff_outcomes_file"
		rm -f "$_dff_outcomes_file"
	fi
	read -r dispatched_count processed_count <<<"$loop_output"
	[[ "$dispatched_count" =~ ^[0-9]+$ ]] || dispatched_count=0
	[[ "$processed_count" =~ ^[0-9]+$ ]] || processed_count=0
	rm -f "$_dff_candidate_file"

	echo "[pulse-wrapper] Deterministic fill floor: loop body finished — processed=${processed_count} dispatched=${dispatched_count} mode=$( ((_dff_max_parallel <= 1)) && echo serial || echo "parallel(${_dff_max_parallel})")" >>"$LOGFILE"
	_dff_maybe_engage_throttle

	local total_dispatched=$((dispatched_count + triage_dispatched))
	echo "[pulse-wrapper] Deterministic fill floor complete: dispatched=${total_dispatched} (${triage_dispatched} triage + ${dispatched_count} implementation), processed=${processed_count}/${candidate_count}, target_available=${available_slots}" >>"$LOGFILE"
	echo "$total_dispatched"
	return 0
}

_should_run_llm_supervisor() {
	local now_epoch
	now_epoch=$(date +%s)

	# 1. Daily sweep: always run if last LLM was >24h ago
	local last_llm_epoch=0
	if [[ -f "${PULSE_DIR}/last_llm_run_epoch" ]]; then
		last_llm_epoch=$(cat "${PULSE_DIR}/last_llm_run_epoch" 2>/dev/null) || last_llm_epoch=0
	fi
	[[ "$last_llm_epoch" =~ ^[0-9]+$ ]] || last_llm_epoch=0

	local llm_age=$((now_epoch - last_llm_epoch))
	if [[ "$llm_age" -ge "$PULSE_LLM_DAILY_INTERVAL" ]]; then
		echo "[pulse-wrapper] LLM supervisor: daily sweep due (last run ${llm_age}s ago)" >>"$LOGFILE"
		printf 'daily_sweep\n' >"${PULSE_DIR}/llm_trigger_mode"
		return 0
	fi

	# 2. Backlog stall: check if issue+PR count has changed
	local snapshot_file="${PULSE_DIR}/backlog_snapshot.txt"
	if [[ ! -f "$snapshot_file" ]]; then
		# First run — take snapshot and run LLM
		_update_backlog_snapshot "$now_epoch"
		echo "[pulse-wrapper] LLM supervisor: first run (no snapshot)" >>"$LOGFILE"
		printf 'first_run\n' >"${PULSE_DIR}/llm_trigger_mode"
		return 0
	fi

	local snap_epoch snap_issues snap_prs
	read -r snap_epoch snap_issues snap_prs <"$snapshot_file" 2>/dev/null || snap_epoch=0
	[[ "$snap_epoch" =~ ^[0-9]+$ ]] || snap_epoch=0
	[[ "$snap_issues" =~ ^[0-9]+$ ]] || snap_issues=0
	[[ "$snap_prs" =~ ^[0-9]+$ ]] || snap_prs=0

	# Get current counts (fast — single API call per repo, cached in prefetch)
	# t1890: exclude persistent/supervisor/contributor issues from stall detection.
	# These management issues never close, so including them inflates the count
	# and makes the backlog appear stalled even when all actionable work is done.
	local current_issues=0 current_prs=0
	while IFS='|' read -r slug _; do
		[[ -n "$slug" ]] || continue
		local ic pc
		ic=$(gh_issue_list --repo "$slug" --state open --json number,labels --limit 500 \
			--jq '[.[] | select(.labels | map(.name) | (index("persistent")) | not)] | length' 2>/dev/null) || ic=0
		pc=$(gh_pr_list --repo "$slug" --state open --json number --jq 'length' --limit 200 2>/dev/null) || pc=0
		[[ "$ic" =~ ^[0-9]+$ ]] || ic=0
		[[ "$pc" =~ ^[0-9]+$ ]] || pc=0
		current_issues=$((current_issues + ic))
		current_prs=$((current_prs + pc))
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$REPOS_JSON" 2>/dev/null)

	local snap_age=$((now_epoch - snap_epoch))
	local total_before=$((snap_issues + snap_prs))
	local total_now=$((current_issues + current_prs))

	# Backlog is progressing — update snapshot, skip LLM
	if [[ "$total_now" -lt "$total_before" ]]; then
		_update_backlog_snapshot "$now_epoch" "$current_issues" "$current_prs"
		return 1
	fi

	# Backlog unchanged — check if stalled long enough
	if [[ "$snap_age" -ge "$PULSE_LLM_STALL_THRESHOLD" ]]; then
		echo "[pulse-wrapper] LLM supervisor: backlog stalled for ${snap_age}s (issues=${current_issues} prs=${current_prs}, unchanged from ${snap_issues}+${snap_prs})" >>"$LOGFILE"
		_update_backlog_snapshot "$now_epoch" "$current_issues" "$current_prs"
		printf 'stall\n' >"${PULSE_DIR}/llm_trigger_mode"
		return 0
	fi

	# Stalled but not long enough yet
	return 1
}

_update_backlog_snapshot() {
	local epoch="${1:-$(date +%s)}"
	local issues="${2:-0}"
	local prs="${3:-0}"
	printf '%s %s %s\n' "$epoch" "$issues" "$prs" >"${PULSE_DIR}/backlog_snapshot.txt"
	return 0
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
#   $2 - context label for log (e.g. "fill floor", "recycle loop")
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

#
# Dispatches deterministic fill floor, then waits adaptively based on
# how many workers were launched so they can appear in process lists
# before the next worker count.
#
# t2749: Two-phase fill floor. Phase 1 is the existing candidate loop.
# Phase 2 fires when _dispatch_issue_consolidation created a new child
# during Phase 1 (detected via a per-cycle sentinel file). The child is
# not in Phase 1's candidate list (enumeration ran before the loop), so
# Phase 2 re-enumerates and dispatches it in the same cycle. Without
# Phase 2, the child waits a minimum of one additional pulse cycle
# (3–7 min stable; 10–20 min when wrapper cycles are unstable).
#######################################
apply_deterministic_fill_floor() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Deterministic fill floor skipped: stop flag present" >>"$LOGFILE"
		return 0
	fi

	local fill_dispatched
	fill_dispatched=$(dispatch_deterministic_fill_floor) || fill_dispatched=0
	[[ "$fill_dispatched" =~ ^[0-9]+$ ]] || fill_dispatched=0

	_adaptive_launch_settle_wait "$fill_dispatched" "fill floor"

	# t2749: Phase 2 — re-enumerate when consolidation created a child during
	# Phase 1. The sentinel is written by _dispatch_issue_consolidation in
	# pulse-triage.sh. Named with $$ (top-level PID) so it is cycle-scoped.
	# Consume it before checking worker slots to prevent double Phase 2 when
	# apply_deterministic_fill_floor is called again in the same cycle
	# (early dispatch pass + main fill floor both invoke this function).
	local _p2_sentinel="${HOME}/.aidevops/cache/pulse-cycle-$$-consolidation-fired"
	if [[ -f "$_p2_sentinel" && ! -f "$STOP_FLAG" ]]; then
		rm -f "$_p2_sentinel" 2>/dev/null || true
		local _p2_active _p2_max
		_p2_active=$(count_active_workers)
		_p2_max=$(get_max_workers_target)
		[[ "$_p2_active" =~ ^[0-9]+$ ]] || _p2_active=0
		[[ "$_p2_max" =~ ^[0-9]+$ ]] || _p2_max=1
		if [[ "$_p2_active" -lt "$_p2_max" ]]; then
			echo "[pulse-wrapper] Deterministic fill floor Phase 2: consolidation child created during Phase 1 (active=${_p2_active}, max=${_p2_max}) — re-enumerating candidates (t2749)" >>"$LOGFILE"
			local fill_dispatched_p2
			fill_dispatched_p2=$(dispatch_deterministic_fill_floor) || fill_dispatched_p2=0
			[[ "$fill_dispatched_p2" =~ ^[0-9]+$ ]] || fill_dispatched_p2=0
			_adaptive_launch_settle_wait "$fill_dispatched_p2" "fill floor phase 2"
		else
			echo "[pulse-wrapper] Deterministic fill floor Phase 2: consolidation child created but slots full (active=${_p2_active}, max=${_p2_max}) — skipping (t2749)" >>"$LOGFILE"
		fi
	fi
	return 0
}

#######################################
# Enforce utilization invariants post-pulse (DEPRECATED — t1453)
#
# The LLM pulse session now runs a monitoring loop (sleep 60s, check
# slots, backfill) for up to 60 minutes, making this wrapper-level
# backfill loop redundant. The function is kept as a no-op stub for
# backward compatibility (pulse.md sources this file).
#
# Previously: re-launched run_pulse() in a loop until active workers
# >= MAX_WORKERS or no runnable work remained. Each iteration paid
# the full LLM cold-start penalty (~125s). The monitoring loop inside
# the LLM session eliminates this overhead — each backfill iteration
# costs ~3K tokens instead of a full session restart.
#######################################
enforce_utilization_invariants() {
	echo "[pulse-wrapper] enforce_utilization_invariants is deprecated — LLM session handles continuous slot filling" >>"$LOGFILE"
	return 0
}

#######################################
# Recycle stale workers aggressively when underfill is severe
#
# During deep underfill, long-running workers can occupy slots while making
# no mergeable progress. Run worker-watchdog with stricter thresholds so
# stale workers are recycled before the next pulse dispatch attempt.
#
# Throttle (t1885): when runnable+queued candidates are scarce
# (<= UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD) and underfill is not severe
# (< UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT), skip the watchdog run if it was
# called within UNDERFILL_RECYCLE_THROTTLE_SECS (default 5 min). This avoids
# repeated no-op watchdog scans when there is little work to dispatch.
# Severe underfill (>= 75% deficit) always bypasses the throttle.
#
# Arguments:
#   $1 - max workers
#   $2 - active workers
#   $3 - runnable candidate count
#   $4 - queued_without_worker count
#######################################
run_underfill_worker_recycler() {
	local max_workers="$1"
	local active_workers="$2"
	local runnable_count="$3"
	local queued_without_worker="$4"

	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$runnable_count" =~ ^[0-9]+$ ]] || runnable_count=0
	[[ "$queued_without_worker" =~ ^[0-9]+$ ]] || queued_without_worker=0

	if [[ "$active_workers" -ge "$max_workers" ]]; then
		return 0
	fi

	if [[ "$runnable_count" -eq 0 && "$queued_without_worker" -eq 0 ]]; then
		return 0
	fi

	if [[ ! -x "$WORKER_WATCHDOG_HELPER" ]]; then
		echo "[pulse-wrapper] Underfill recycler skipped: worker-watchdog helper missing or not executable (${WORKER_WATCHDOG_HELPER})" >>"$LOGFILE"
		return 0
	fi

	local deficit_pct
	deficit_pct=$(((max_workers - active_workers) * 100 / max_workers))
	if [[ "$deficit_pct" -lt "$UNDERFILL_RECYCLE_DEFICIT_MIN_PCT" ]]; then
		return 0
	fi

	# Time-based throttle (t1885): when runnable candidates are scarce and underfill
	# is not severe, avoid hammering worker-watchdog on every pulse cycle. Running
	# watchdog with few candidates produces no kills but still pays the process-scan
	# cost and generates noisy log entries. Bypass throttle for severe underfill
	# (>= UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT) so critical slot recovery is never delayed.
	local recycle_throttle_file="${HOME}/.aidevops/logs/underfill-recycle-last-run"
	local total_candidates=$((runnable_count + queued_without_worker))
	if [[ "$total_candidates" -le "$UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD" &&
		"$deficit_pct" -lt "$UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT" ]]; then
		local now_epoch
		now_epoch=$(date +%s)
		local last_run_epoch=0
		if [[ -f "$recycle_throttle_file" ]]; then
			last_run_epoch=$(cat "$recycle_throttle_file" 2>/dev/null || echo "0")
			[[ "$last_run_epoch" =~ ^[0-9]+$ ]] || last_run_epoch=0
		fi
		local secs_since_last=$((now_epoch - last_run_epoch))
		if [[ "$secs_since_last" -lt "$UNDERFILL_RECYCLE_THROTTLE_SECS" ]]; then
			echo "[pulse-wrapper] Underfill recycler throttled: candidates=${total_candidates} (threshold=${UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD}), deficit=${deficit_pct}% (<${UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT}% severe), last_run=${secs_since_last}s ago (throttle=${UNDERFILL_RECYCLE_THROTTLE_SECS}s)" >>"$LOGFILE"
			return 0
		fi
	fi

	local thrash_elapsed_threshold
	local thrash_message_threshold
	local progress_timeout
	local max_runtime
	if [[ "$deficit_pct" -ge 50 ]]; then
		thrash_elapsed_threshold=1800
		thrash_message_threshold=90
		progress_timeout=420
		max_runtime=7200
	else
		thrash_elapsed_threshold=3600
		thrash_message_threshold=120
		progress_timeout=480
		max_runtime=9000
	fi

	echo "[pulse-wrapper] Underfill recycler: running worker-watchdog (active ${active_workers}/${max_workers}, deficit ${deficit_pct}%, runnable=${runnable_count}, queued_without_worker=${queued_without_worker})" >>"$LOGFILE"

	if WORKER_WATCHDOG_NOTIFY=false \
		WORKER_THRASH_ELAPSED_THRESHOLD="$thrash_elapsed_threshold" \
		WORKER_THRASH_MESSAGE_THRESHOLD="$thrash_message_threshold" \
		WORKER_PROGRESS_TIMEOUT="$progress_timeout" \
		WORKER_MAX_RUNTIME="$max_runtime" \
		"$WORKER_WATCHDOG_HELPER" --check >>"$LOGFILE" 2>&1; then
		echo "[pulse-wrapper] Underfill recycler complete: worker-watchdog check finished" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Underfill recycler warning: worker-watchdog returned non-zero" >>"$LOGFILE"
	fi

	# Update throttle timestamp after each run (t1885)
	date +%s >"$recycle_throttle_file" 2>/dev/null || true

	return 0
}

#######################################
# Refill an underfilled worker pool while the pulse session is still alive.
#
# The pulse prompt asks the LLM to monitor every 60s, but the live session can
# still sleep or focus on a narrow thread while local slots sit idle. When the
# wrapper sees sustained idle/stall signals plus runnable work, it performs a
# bounded deterministic refill instead of waiting for the session to exit.
#
# Arguments:
#   $1 - last refill epoch (0 if never)
#   $2 - progress stall seconds
#   $3 - idle seconds
#   $4 - has_seen_progress (true/false)
#
# Returns: updated last refill epoch via stdout
#######################################
maybe_refill_underfilled_pool_during_active_pulse() {
	local last_refill_epoch="${1:-0}"
	local progress_stall_seconds="${2:-0}"
	local idle_seconds="${3:-0}"
	local has_seen_progress="${4:-false}"

	[[ "$last_refill_epoch" =~ ^[0-9]+$ ]] || last_refill_epoch=0
	[[ "$progress_stall_seconds" =~ ^[0-9]+$ ]] || progress_stall_seconds=0
	[[ "$idle_seconds" =~ ^[0-9]+$ ]] || idle_seconds=0
	[[ "$PULSE_ACTIVE_REFILL_INTERVAL" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_INTERVAL=120
	[[ "$PULSE_ACTIVE_REFILL_IDLE_MIN" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_IDLE_MIN=60
	[[ "$PULSE_ACTIVE_REFILL_STALL_MIN" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_STALL_MIN=120

	if [[ -f "$STOP_FLAG" || "$has_seen_progress" != "true" ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	if [[ "$idle_seconds" -lt "$PULSE_ACTIVE_REFILL_IDLE_MIN" && "$progress_stall_seconds" -lt "$PULSE_ACTIVE_REFILL_STALL_MIN" ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s)
	if [[ "$last_refill_epoch" -gt 0 ]]; then
		local since_last_refill=$((now_epoch - last_refill_epoch))
		if [[ "$since_last_refill" -lt "$PULSE_ACTIVE_REFILL_INTERVAL" ]]; then
			echo "$last_refill_epoch"
			return 0
		fi
	fi

	local max_workers active_workers runnable_count queued_without_worker
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0

	if [[ "$active_workers" -ge "$max_workers" || ("$runnable_count" -eq 0 && "$queued_without_worker" -eq 0) ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	echo "[pulse-wrapper] Active pulse refill: underfilled ${active_workers}/${max_workers} with runnable=${runnable_count}, queued_without_worker=${queued_without_worker}, idle=${idle_seconds}s, stall=${progress_stall_seconds}s" >>"$LOGFILE"
	run_underfill_worker_recycler "$max_workers" "$active_workers" "$runnable_count" "$queued_without_worker"
	dispatch_deterministic_fill_floor >/dev/null || true

	echo "$now_epoch"
	return 0
}

#######################################
# Main
#
# Execution order (t1429, GH#4513, GH#5628):
#   0. Instance lock (mkdir-based atomic — prevents concurrent pulses on macOS+Linux)
#   1. Gate checks (consent, dedup)
#   2. Cleanup (orphans, worktrees, stashes)
#   2.5. Daily complexity scan — .sh functions + .md agent docs (creates function-complexity-debt issues)
#   3. Prefetch state (parallel gh API calls)
#   4. Run pulse (LLM session — dispatch workers, merge PRs)
#
# Statistics (quality sweep, health issues, person-stats) run in a
# SEPARATE process — stats-wrapper.sh — on its own cron schedule.
# They must never share a process with the pulse because they depend
# on GitHub Search API (30 req/min limit). When budget is exhausted,
# contributor-activity-helper.sh bails out with partial results, but
# even the API calls themselves add latency that delays dispatch.
#######################################
# -----------------------------------------------------------------------------
# Helpers for _run_preflight_stages (GH#18656)
# -----------------------------------------------------------------------------
# The helpers below group related preflight work so _run_preflight_stages
# stays under 100 lines and each group (cleanup/reap, capacity/labels, early
# dispatch, daily scans, ownership reconcile, prefetch+scope) can be read
# independently. Behavior is byte-for-byte equivalent to the pre-split
# monolithic function — see git log for the refactor commit.

#######################################
# Cleanup + zombie reap + ledger maintenance. Runs before worker counting
# so count_active_workers sees accurate slot availability.
#######################################
_preflight_cleanup_and_ledger() {
	run_stage_with_timeout "cleanup_orphans" "$PRE_RUN_STAGE_TIMEOUT" cleanup_orphans || true
	run_stage_with_timeout "cleanup_stale_opencode" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stale_opencode || true
	run_stage_with_timeout "cleanup_stalled_workers" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stalled_workers || true
	# GH#20554: Worktree cleanup is moved to an async background job so a slow
	# cleanup (20+ worktrees × 2-5s gh API calls each) never hits a hard timeout
	# and blocks the pulse cycle. The helper enforces a single-runner lock and
	# a cadence gate (CLEANUP_WORKTREES_ASYNC_CADENCE_MIN, default 10 min) so
	# concurrent pulse invocations do not spawn duplicate cleanup processes.
	# Progress and last-run timestamp: ~/.aidevops/logs/cleanup_worktrees.*
	local _cleanup_async_helper="${SCRIPT_DIR}/cleanup-worktrees-async-helper.sh"
	if [[ -x "$_cleanup_async_helper" ]]; then
		nohup "$_cleanup_async_helper" \
			>>"${HOME}/.aidevops/logs/cleanup_worktrees.log" 2>&1 &
		disown $! 2>/dev/null || true
	else
		# Fallback: synchronous with short timeout (old GH#18979 behaviour)
		run_stage_with_timeout "cleanup_worktrees" 60 cleanup_worktrees || true
	fi
	run_stage_with_timeout "cleanup_stashes" "$PRE_RUN_STAGE_TIMEOUT" cleanup_stashes || true

	# GH#17549: Archive old OpenCode sessions to keep the active DB small.
	# Concurrent workers hit SQLITE_BUSY on a bloated DB (busy_timeout=0).
	# GH#21105: Moved to an async background job so the per-cycle 30s budget
	# stops contributing to preflight_cleanup_and_ledger wall time. The async
	# helper enforces a single-runner lock and a cadence gate
	# (OPENCODE_DB_ARCHIVE_ASYNC_CADENCE_MIN, default 10 min) so concurrent
	# pulse invocations do not spawn duplicate archive processes. With archiving
	# off the critical path, each invocation can use a larger budget
	# (OPENCODE_DB_ARCHIVE_ASYNC_BUDGET_SEC, default 60s) and still not block
	# dispatch. Progress and last-run timestamp: ~/.aidevops/logs/opencode-db-archive.*
	local _archive_async_helper="${SCRIPT_DIR}/opencode-db-archive-async-helper.sh"
	if [[ -x "$_archive_async_helper" ]]; then
		nohup "$_archive_async_helper" \
			>>"${HOME}/.aidevops/logs/opencode-db-archive.log" 2>&1 &
		disown $! 2>/dev/null || true
	else
		# Fallback: synchronous with short timeout (pre-GH#21105 behaviour)
		local _archive_helper="${SCRIPT_DIR}/opencode-db-archive.sh"
		if [[ -x "$_archive_helper" ]]; then
			"$_archive_helper" archive --max-duration-seconds 30 >>"$LOGFILE" 2>&1 || true
		fi
	fi

	# t1751: Reap zombie workers whose PRs have been merged by the deterministic merge pass.
	# Runs before worker counting so count_active_workers sees accurate slot availability.
	run_stage_with_timeout "reap_zombie_workers" "$PRE_RUN_STAGE_TIMEOUT" reap_zombie_workers || true

	# GH#6696: Expire stale in-flight ledger entries and prune old completed/failed ones.
	# This runs before worker counting so count_active_workers sees accurate ledger state.
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$_ledger_helper" ]]; then
		local expired_count
		expired_count=$("$_ledger_helper" expire 2>/dev/null) || expired_count=0
		"$_ledger_helper" prune >/dev/null 2>&1 || true
		if [[ "${expired_count:-0}" -gt 0 ]]; then
			echo "[pulse-wrapper] Dispatch ledger: expired ${expired_count} stale in-flight entries (GH#6696)" >>"$LOGFILE"
		fi
	fi
	return 0
}

#######################################
# Capacity calculation + session count warning + needs-* label
# re-evaluation. Must run before the early dispatch pass so max workers
# and priority allocations are current.
#######################################
_preflight_capacity_and_labels() {
	calculate_max_workers
	calculate_priority_allocations
	local _session_ct
	_session_ct=$(check_session_count)
	if [[ "${_session_ct:-0}" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "[pulse-wrapper] Session warning: $_session_ct interactive sessions open (threshold: $SESSION_COUNT_WARN). Each consumes 100-440MB + language servers. Consider closing unused tabs." >>"$LOGFILE"
	fi

	# Re-evaluate needs-consolidation labels before dispatch. Issues labeled
	# by an earlier (less precise) filter may no longer trigger under the
	# current filter. Auto-clearing here makes them dispatchable immediately
	# instead of stuck forever behind a label that list_dispatchable_issue_candidates_json
	# filters out (needs-* exclusion at line 6703).
	_reevaluate_consolidation_labels
	# t1982: Backfill pass for stuck needs-consolidation issues that never
	# got a consolidation-task child created (pre-t1982 dispatches just
	# labelled and returned). Dispatches a child retroactively so the
	# parent can actually be consolidated instead of sitting forever.
	_backfill_stale_consolidation_labels
	_reevaluate_simplification_labels
	return 0
}

#######################################
# Early dispatch pass + routine comment responses.
#
# Fills available worker slots BEFORE heavy housekeeping. Workers take
# 25-30s to cold-start (sandbox-exec + opencode), so dispatching here lets
# them boot in parallel with the remaining housekeeping stages
# (close_issues_with_merged_prs ~260s, prefetch_state ~130s, etc.).
# The main fill floor at the end of the cycle catches any slots freed by
# housekeeping. Without this, workers sit idle for ~7 minutes of cleanup.
#######################################
_preflight_early_dispatch() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Stop flag present — skipping early fill floor" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Early fill floor: dispatching workers before housekeeping" >>"$LOGFILE"
		apply_deterministic_fill_floor
	fi

	# Routine comment responses: scan routine-tracking issues for unanswered
	# user comments and dispatch lightweight Haiku workers to respond.
	# Runs before heavy housekeeping so responses are fast.
	dispatch_routine_comment_responses || true
	return 0
}

# t2443: _preflight_daily_scans() was removed here. Its children (complexity_scan,
# coderabbit_review, post_merge_scanner, auto_decomposer_scanner, dedup_cleanup,
# fast_fail_prune_expired) are now promoted to top-level stages in
# _run_preflight_stages() with independent timeouts. See the call site below.

#######################################
# Ownership normalization + issue reconciliation stages.
# Ensures active labels reflect ownership (prevents multi-worker overlap),
# closes issues whose linked PRs already merged, reconciles status:done
# stuck states, and auto-approves maintainer-created issues.
#######################################
_preflight_ownership_reconcile() {
	# Contribution watch: lightweight scan of external issues/PRs (t1419).
	prefetch_contribution_watch

	# Ensure active labels reflect ownership to prevent multi-worker overlap.
	run_stage_with_timeout "normalize_active_issue_assignments" "$PRE_RUN_STAGE_TIMEOUT" normalize_active_issue_assignments || true

	# t2776: single-pass reconcile — iterates the issue list ONCE per repo and
	# applies all five reconcile checks in sub-stage order (close-merged-PR,
	# stale-done, open-with-merged-PR, parent-task, labelless backfill).
	# Replaces the five sequential stage calls that each had their own per-repo
	# fetch loop; now 5N → N iterations per cycle.
	run_stage_with_timeout "reconcile_issues_single_pass" "$PRE_RUN_STAGE_TIMEOUT" reconcile_issues_single_pass || true

	# Auto-approve maintainer issues: remove needs-maintainer-review when
	# the maintainer created or commented on the issue (GH#16842).
	run_stage_with_timeout "auto_approve_maintainer_issues" "$PRE_RUN_STAGE_TIMEOUT" auto_approve_maintainer_issues || true
	return 0
}

#######################################
# Prefetch GitHub state + restore persisted PULSE_SCOPE_REPOS.
#
# Returns:
#   0 - prefetch succeeded (or succeeded with warnings)
#   1 - prefetch failed; caller should abort this cycle to avoid stale
#       dispatch decisions
#######################################
_preflight_prefetch_and_scope() {
	# GH#18979 (t2097): clear any stale flag from a previous cycle before
	# prefetch runs. Only the current cycle's prefetch should set the flag —
	# leftover files from a previous cycle would cause false aborts.
	rm -f "$PULSE_RATE_LIMIT_FLAG" 2>/dev/null || true

	if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
		echo "[pulse-wrapper] prefetch_state did not complete successfully — aborting this cycle to avoid stale dispatch decisions" >>"$LOGFILE"
		_PULSE_HEALTH_PREFETCH_ERRORS=$((_PULSE_HEALTH_PREFETCH_ERRORS + 1))
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 1
	fi

	# GH#18979 (t2097): if any prefetch site detected GraphQL rate-limit
	# exhaustion, abort the cycle cleanly. Empty prefetch data is
	# indistinguishable from a genuinely quiet backlog; proceeding would run
	# the deterministic pipeline on stale state while the instance lock is
	# held for the full cycle duration. Existing return-1 path releases the
	# lock and increments the health counter.
	if [[ -f "$PULSE_RATE_LIMIT_FLAG" ]]; then
		local _rl_affected_sites
		_rl_affected_sites=$(wc -l <"$PULSE_RATE_LIMIT_FLAG" 2>/dev/null | tr -d ' ')
		[[ "$_rl_affected_sites" =~ ^[0-9]+$ ]] || _rl_affected_sites="?"
		echo "[pulse-wrapper] Prefetch aborted: GraphQL RATE_LIMIT_EXHAUSTED (${_rl_affected_sites} site(s) affected) — skipping cycle to avoid stale dispatch decisions" >>"$LOGFILE"
		_PULSE_HEALTH_PREFETCH_ERRORS=$((_PULSE_HEALTH_PREFETCH_ERRORS + 1))
		echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"
		return 1
	fi

	if [[ -f "$SCOPE_FILE" ]]; then
		local persisted_scope
		persisted_scope=$(cat "$SCOPE_FILE" 2>/dev/null || echo "")
		if [[ -n "$persisted_scope" ]]; then
			export PULSE_SCOPE_REPOS="$persisted_scope"
			echo "[pulse-wrapper] Restored PULSE_SCOPE_REPOS from ${SCOPE_FILE}" >>"$LOGFILE"
		fi
	fi
	return 0
}

#######################################
# Run pre-flight stages: cleanup, calculations, normalization (GH#5627)
#
# Returns: 0 if prefetch succeeded, 1 if prefetch failed (abort cycle)
#######################################
_run_preflight_stages() {
	# t1425, t1482: Write SETUP sentinel during pre-flight stages.
	echo "SETUP:$$" >"$PIDFILE"

	# GH#20025 Phase B + t2443: Each preflight stage wrapped in
	# run_stage_with_timeout so overruns are killed without blocking
	# the entire pulse cycle. Daily scans (complexity, coderabbit,
	# post-merge, auto-decomposer, dedup, fast-fail prune) were
	# previously grouped in _preflight_daily_scans() with a shared
	# budget — t2443 promoted them to independent top-level stages
	# so one slow scanner cannot starve downstream scanners.
	local _pflt_timeout="${PREFLIGHT_GROUP_TIMEOUT:-${PRE_RUN_STAGE_TIMEOUT:-600}}"

	run_stage_with_timeout "preflight_cleanup_and_ledger" "$_pflt_timeout" \
		_preflight_cleanup_and_ledger || true
	run_stage_with_timeout "preflight_capacity_and_labels" "$_pflt_timeout" \
		_preflight_capacity_and_labels || true
	run_stage_with_timeout "preflight_early_dispatch" "$_pflt_timeout" \
		_preflight_early_dispatch || true
	# t2443: Daily scans promoted to independent top-level stages so each
	# scanner gets its own timeout budget. Previously wrapped in a single
	# _preflight_daily_scans() group with a shared 600s budget — a slow
	# complexity_scan (200-340s) would starve downstream scanners
	# (auto_decomposer, post_merge, dedup) from ever running.
	# t2903 (#21049): complexity_scan extracted to its own launchd plist
	# (sh.aidevops.complexity-scan, hourly) via complexity-scan-runner.sh.
	# Observed cost was 470s per cycle — 26%+ of the 1800s pulse stale
	# ceiling — so promoting it to its own schedule prevents preflight
	# starvation entirely. The function still lives in pulse-simplification.sh
	# and is invoked by the standalone runner.
	run_stage_with_timeout "coderabbit_review" "$_pflt_timeout" \
		run_daily_codebase_review || true
	run_stage_with_timeout "post_merge_scanner" "$_pflt_timeout" \
		_run_post_merge_review_scanner || true
	run_stage_with_timeout "auto_decomposer_scanner" "$_pflt_timeout" \
		_run_auto_decomposer_scanner || true
	run_stage_with_timeout "dedup_cleanup" "$_pflt_timeout" \
		run_simplification_dedup_cleanup || true
	run_stage_with_timeout "fast_fail_prune_expired" "$_pflt_timeout" \
		fast_fail_prune_expired || true
	run_stage_with_timeout "preflight_ownership_reconcile" "$_pflt_timeout" \
		_preflight_ownership_reconcile || true
	# prefetch_and_scope is the only preflight stage whose failure aborts
	# the cycle — preserve the non-zero return so main() skips run_pulse().
	if ! run_stage_with_timeout "preflight_prefetch_and_scope" "$_pflt_timeout" \
		_preflight_prefetch_and_scope; then
		return 1
	fi
	return 0
}

#######################################
# Compute initial underfill state and run recycler (GH#5627)
#
# Outputs 2 lines: underfilled_mode, underfill_pct
#######################################
_compute_initial_underfill() {
	local max_workers active_workers underfilled_mode underfill_pct

	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	underfilled_mode=0
	underfill_pct=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		underfilled_mode=1
		underfill_pct=$(((max_workers - active_workers) * 100 / max_workers))
	fi

	local runnable_count queued_without_worker
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	run_underfill_worker_recycler "$max_workers" "$active_workers" "$runnable_count" "$queued_without_worker"

	# Re-check after recycler
	active_workers=$(count_active_workers)
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		underfilled_mode=1
		underfill_pct=$(((max_workers - active_workers) * 100 / max_workers))
	else
		underfilled_mode=0
		underfill_pct=0
	fi

	echo "$underfilled_mode"
	echo "$underfill_pct"
	return 0
}

#######################################
# Early-exit recycle loop (GH#5627, extracted from main)
#
# If the LLM exited quickly (<5 min) and the pool is still underfilled
# with runnable work, restart the pulse. Capped at PULSE_BACKFILL_MAX_ATTEMPTS.
#
# GH#6453: A grace-period wait is inserted before re-counting workers.
# Workers dispatched by the LLM pulse take several seconds to appear in
# list_active_worker_processes (sandbox-exec + opencode startup latency).
# Without this wait, count_active_workers() returns the pre-dispatch count,
# making the pool appear underfilled and triggering a second LLM pass that
# re-dispatches the same issues — doubling compute cost and causing branch
# conflicts. The wait duration is PULSE_LAUNCH_GRACE_SECONDS (default 20s).
#
# Arguments:
#   $1 - initial pulse_duration in seconds
#######################################
_run_early_exit_recycle_loop() {
	local pulse_duration="$1"
	local recycle_attempt=0

	while [[ "$recycle_attempt" -lt "$PULSE_BACKFILL_MAX_ATTEMPTS" ]]; do
		# Only recycle if the pulse ran for less than 5 minutes
		if [[ "$pulse_duration" -ge 300 ]]; then
			break
		fi

		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Stop flag set — skipping early-exit recycle" >>"$LOGFILE"
			break
		fi

		# GH#6453: Wait for newly-dispatched workers to appear in the process list
		# before re-counting. Workers dispatched by the LLM pulse take up to
		# PULSE_LAUNCH_GRACE_SECONDS to start (sandbox-exec + opencode startup).
		# Counting immediately after the LLM exits produces a false-negative
		# (workers running but not yet visible) that triggers duplicate dispatch.
		# t1887: LLM dispatch count is unknown here — use full grace to preserve
		# the GH#6453 safety guarantee.
		local grace_wait="$PULSE_LAUNCH_GRACE_SECONDS"
		[[ "$grace_wait" =~ ^[0-9]+$ ]] || grace_wait=35
		if [[ "$grace_wait" -gt 0 ]]; then
			echo "[pulse-wrapper] Early-exit recycle: waiting ${grace_wait}s for dispatched workers to appear (GH#6453)" >>"$LOGFILE"
			sleep "$grace_wait"
		fi

		# Re-check worker state
		local post_max post_active post_runnable post_queued
		post_max=$(get_max_workers_target)
		post_active=$(count_active_workers)
		post_runnable=$(normalize_count_output "$(count_runnable_candidates)")
		post_queued=$(normalize_count_output "$(count_queued_without_worker)")
		[[ "$post_max" =~ ^[0-9]+$ ]] || post_max=1
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0

		if [[ "$post_active" -ge "$post_max" ]]; then
			break
		fi
		if [[ "$post_runnable" -eq 0 && "$post_queued" -eq 0 ]]; then
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Early-exit recycle: stop flag appeared before deterministic fill" >>"$LOGFILE"
			break
		fi

		dispatch_deterministic_fill_floor >/dev/null || true
		post_active=$(count_active_workers)
		post_runnable=$(normalize_count_output "$(count_runnable_candidates)")
		post_queued=$(normalize_count_output "$(count_queued_without_worker)")
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		if [[ "$post_active" -ge "$post_max" ]]; then
			break
		fi
		if [[ "$post_runnable" -eq 0 && "$post_queued" -eq 0 ]]; then
			break
		fi

		local post_deficit_pct=$(((post_max - post_active) * 100 / post_max))
		recycle_attempt=$((recycle_attempt + 1))
		echo "[pulse-wrapper] Early-exit recycle attempt ${recycle_attempt}/${PULSE_BACKFILL_MAX_ATTEMPTS}: pulse ran ${pulse_duration}s (<300s), pool underfilled (active ${post_active}/${post_max}, deficit ${post_deficit_pct}%, runnable=${post_runnable}, queued=${post_queued})" >>"$LOGFILE"

		run_underfill_worker_recycler "$post_max" "$post_active" "$post_runnable" "$post_queued"

		if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
			echo "[pulse-wrapper] Early-exit recycle: prefetch_state failed — aborting recycle" >>"$LOGFILE"
			break
		fi

		# Recalculate underfill for the new pulse
		post_active=$(count_active_workers)
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		local recycle_underfilled_mode=0
		local recycle_underfill_pct=0
		if [[ "$post_active" -lt "$post_max" ]]; then
			recycle_underfilled_mode=1
			recycle_underfill_pct=$(((post_max - post_active) * 100 / post_max))
		fi

		local recycle_start_epoch
		recycle_start_epoch=$(date +%s)
		run_pulse "$recycle_underfilled_mode" "$recycle_underfill_pct"

		local recycle_end_epoch
		recycle_end_epoch=$(date +%s)
		pulse_duration=$((recycle_end_epoch - recycle_start_epoch))
	done

	if [[ "$recycle_attempt" -gt 0 ]]; then
		echo "[pulse-wrapper] Early-exit recycle completed after ${recycle_attempt} attempt(s)" >>"$LOGFILE"
	fi

	return 0
}
