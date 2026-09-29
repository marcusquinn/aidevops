#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Extracted from pulse-dispatch-lib.sh; source the orchestrator, not this file.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DISPATCH_CANDIDATES_LIB_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_CANDIDATES_LIB_LOADED=1

# Names-only credential admission. Return 0 only when every declared name is
# present; 1 means this runner must yield. The issue JSON is never evaluated.
_dispatch_secret_missing_names() {
	local issue_json="$1"
	local declared="" listing="" name="" missing="" line=""
	declared=$(printf '%s' "$issue_json" | jq -r '
		. as $issue | [.labels[]? | if type == "object" then .name else . end |
		 select(type == "string" and startswith("needs-secret:")) |
		 sub("^needs-secret:"; "")] | if length > 0 then .[]
		 else ($issue.body // "" | capture("<!-- aidevops:needs-secrets (?<names>[A-Za-z_0-9 ]+) -->")? | .names // "" | split(" ")[]) end
	' 2>/dev/null) || return 1
	[[ -n "$declared" ]] || return 0
	# Fail closed on malformed declarations or an unavailable local name store.
	listing=$(aidevops secret list 2>/dev/null) || return 1
	while IFS= read -r name; do
		[[ "$name" =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]] || return 1
		local found=0
		while IFS= read -r line; do
			line="${line#"${line%%[![:space:]]*}"}"
			[[ "$line" == "$name" ]] && found=1
		done <<<"$listing"
		[[ "$found" -eq 1 ]] || missing="${missing:+$missing }$name"
	done <<<"$declared"
	printf '%s' "$missing"
	return 0
}

_dispatch_skip_for_secrets() {
	local issue_number="$1" repo_slug="$2" issue_json="" missing="" created="" age=0 threshold=""
	issue_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 0
	missing=$(_dispatch_secret_missing_names "$issue_json") || {
		echo "[pulse-wrapper] #${issue_number}: secret name evidence unavailable; yielding" >>"$LOGFILE"
		return 0
	}
	[[ -n "$missing" ]] || return 1
	echo "[pulse-wrapper] #${issue_number}: runner lacks declared secret names; yielding" >>"$LOGFILE"
	threshold="${AIDEVOPS_SECRET_STARVATION_SECONDS:-86400}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=86400
	created=$(printf '%s' "$issue_json" | jq -r '.updated_at // .created_at // ""')
	created=$(date -u -d "$created" +%s 2>/dev/null) || \
		created=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$created" +%s 2>/dev/null) || created=0
	[[ "$created" -gt 0 ]] || return 0
	age=$(($(date -u +%s) - created))
	if [[ "$age" -ge "$threshold" ]]; then
		_dispatch_secret_starvation_notice "$issue_number" "$repo_slug" "$missing" "$issue_json" || true
	fi
	return 0
}

_dispatch_secret_starvation_notice() {
	local issue_number="$1" repo_slug="$2" missing="$3" issue_json="$4" comments="" marker="<!-- aidevops:secret-starvation -->"
	local comments_endpoint="repos/${repo_slug}/issues/${issue_number}/comments"
	comments=$(gh api "$comments_endpoint" --paginate --jq '.[].body' 2>/dev/null) || return 1
	if [[ "$comments" != *"$marker"* ]]; then
		gh api "$comments_endpoint" --method POST \
			--field body="$(printf '%s\n%s' "$marker" "Dispatch has waited for a runner with these required secret names: ${missing}. No secret values were accessed.")" >/dev/null || return 1
	fi
	if ! printf '%s' "$issue_json" | jq -e '.labels[]? | (if type == "object" then .name else . end) == "status:blocked"' >/dev/null; then
		gh issue edit "$issue_number" --repo "$repo_slug" --add-label status:blocked >/dev/null || return 1
	fi
	return 0
}

_dispatch_run_prepasses() {
	local available_slots="$1"

	local triage_outcome="" prior_outcome="" cumulative_outcome=""
	local triage_attempted=0 triage_posted=0 triage_infrastructure_failed=0
	local prior_attempted=0 remaining_budget=0 marker_exists=0 run_triage=0 refresh_state=0
	local triage_budget="${PULSE_TRIAGE_BUDGET_PER_CYCLE:-2}" triage_marker=""
	triage_outcome=$(_dispatch_triage_fallback_outcome 0)
	prior_outcome=$(_dispatch_triage_fallback_outcome 0)
	[[ "$triage_budget" =~ ^[0-9]+$ ]] || triage_budget=2
	triage_marker=$(_dispatch_cycle_cache_path "pulse-triage-prepass" ".done" 2>/dev/null || true)
	if [[ -n "$triage_marker" && -L "$triage_marker" ]]; then
		rm -f "$triage_marker" 2>/dev/null || triage_marker=""
	elif [[ -n "$triage_marker" && -f "$triage_marker" ]]; then
		marker_exists=1
		prior_outcome=$(<"$triage_marker")
		if ! _dispatch_triage_outcome_is_valid "$prior_outcome"; then
			echo "[pulse-wrapper] Dispatch_max: invalid cumulative triage marker — rebuilding it" >>"$LOGFILE"
			prior_outcome=$(_dispatch_triage_fallback_outcome 0)
			marker_exists=0
		fi
	fi
	prior_attempted=$(printf '%s' "$prior_outcome" | jq -r '.attempted // 0' 2>/dev/null || printf '0')
	[[ "$prior_attempted" =~ ^[0-9]+$ ]] || prior_attempted=0
	remaining_budget=$((triage_budget - prior_attempted))
	((remaining_budget < 0)) && remaining_budget=0

	if [[ "$marker_exists" -eq 0 ]]; then
		run_triage=1
	elif [[ "$remaining_budget" -gt 0 ]] && _dispatch_triage_marker_refresh_is_due "$triage_marker"; then
		run_triage=1
		refresh_state=1
	elif [[ "$remaining_budget" -le 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: triage prepass already consumed this cycle's independent budget" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Dispatch_max: triage prepass snapshot is still fresh" >>"$LOGFILE"
	fi

	if [[ "$run_triage" -eq 1 ]]; then
		if ! _dispatch_rest_core_progress_allows_next "dispatch_triage_prepass"; then
			printf '%s %s %s\n' "$available_slots" "$triage_attempted" "$triage_infrastructure_failed"
			return 0
		fi
		if [[ "$refresh_state" -eq 1 ]] && \
			{ ! command -v refresh_triage_review_state >/dev/null 2>&1 || ! refresh_triage_review_state; }; then
			echo "[pulse-wrapper] Dispatch_max: triage state refresh failed — preserving prior snapshot and recording one infrastructure failure" >>"$LOGFILE"
			triage_outcome=$(_dispatch_triage_fallback_outcome 1)
		else
			triage_outcome=$(dispatch_triage_reviews "$remaining_budget" 2>>"$LOGFILE") || triage_outcome=$(_dispatch_triage_fallback_outcome 1)
		fi
		if ! _dispatch_triage_outcome_is_valid "$triage_outcome"; then
			echo "[pulse-wrapper] Dispatch_max: invalid triage outcome envelope — recording one infrastructure failure" >>"$LOGFILE"
			triage_outcome=$(_dispatch_triage_fallback_outcome 1)
		fi
		cumulative_outcome=$(_dispatch_triage_outcomes_sum "$prior_outcome" "$triage_outcome") || cumulative_outcome="$triage_outcome"
		[[ -z "$triage_marker" ]] || _dispatch_write_triage_marker "$triage_marker" "$cumulative_outcome" || true
	fi
	triage_attempted=$(printf '%s' "$triage_outcome" | jq -r '.attempted // 0' 2>/dev/null || printf '0')
	triage_posted=$(printf '%s' "$triage_outcome" | jq -r '.posted // 0' 2>/dev/null || printf '0')
	triage_infrastructure_failed=$(printf '%s' "$triage_outcome" | jq -r '.infrastructure_failed // 0' 2>/dev/null || printf '0')
	[[ "$triage_attempted" =~ ^[0-9]+$ ]] || triage_attempted=0
	[[ "$triage_posted" =~ ^[0-9]+$ ]] || triage_posted=0
	[[ "$triage_infrastructure_failed" =~ ^[0-9]+$ ]] || triage_infrastructure_failed=0
	if [[ "$triage_attempted" -gt 0 || "$triage_infrastructure_failed" -gt 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: triage attempted=${triage_attempted} posted=${triage_posted} infrastructure_failed=${triage_infrastructure_failed} implementation_slots_consumed=0 implementation_slots_available=${available_slots}" >>"$LOGFILE"
	fi
	if [[ "$triage_posted" -gt 0 ]]; then
		_dispatch_invalidate_candidate_snapshot "triage_state_changed" || true
	fi

	local enrichment_remaining
	if ! _dispatch_rest_core_progress_allows_next "dispatch_enrichment_prepass"; then
		printf '%s %s %s\n' "$available_slots" "$triage_attempted" "$triage_infrastructure_failed"
		return 0
	fi
	enrichment_remaining=$(dispatch_enrichment_workers "$available_slots" 2>>"$LOGFILE") || enrichment_remaining="$available_slots"
	[[ "$enrichment_remaining" =~ ^[0-9]+$ ]] || enrichment_remaining="$available_slots"
	local enrichment_dispatched=$((available_slots - enrichment_remaining))
	if [[ "$enrichment_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: dispatched ${enrichment_dispatched} enrichment worker(s), ${enrichment_remaining} slots remaining for implementation" >>"$LOGFILE"
	fi
	available_slots="$enrichment_remaining"

	printf '%s %s %s\n' "$available_slots" "$triage_attempted" "$triage_infrastructure_failed"
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
	if _dispatch_skip_for_secrets "$issue_number" "$repo_slug"; then
		return 0
	fi

	if _dispatch_skip_for_benign_block "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_terminal_blocker "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_dirty_worktree_recovery "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_fast_fail "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_backoff "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _dispatch_skip_for_issue_body "$issue_number" "$repo_slug"; then
		return 0
	fi

	pulse_dispatch_debug_log "#${issue_number}: passed all skip checks — proceeding to dispatch"
	return 1
}

#######################################
# Skip candidates with a recent unresolved worker-dirty-worktree marker.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_dirty_worktree_recovery() {
	local issue_number="$1"
	local repo_slug="$2"

	if _dispatch_recent_dirty_worktree_marker_active "$issue_number" "$repo_slug"; then
		if [[ "${_DISPATCH_DIRTY_MARKER_STATE:-$_DISPATCH_VALUE_UNKNOWN}" == "$_DISPATCH_VALUE_UNKNOWN" ]]; then
			echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — DISPATCH_BLOCK_REASON reason=dirty_worktree_evidence_unavailable evidence_kind=${_DISPATCH_DIRTY_MARKER_EVIDENCE_KIND:-$_DISPATCH_VALUE_UNKNOWN} attempted=${_DISPATCH_DIRTY_MARKER_REQUEST_ATTEMPTED:-$_DISPATCH_VALUE_UNKNOWN} deferred_by=${_DISPATCH_DIRTY_MARKER_DEFERRED_BY:-none} retry_at=${_DISPATCH_DIRTY_MARKER_RETRY_AT:-$_DISPATCH_VALUE_UNKNOWN} exit_code=${_DISPATCH_DIRTY_MARKER_EXIT_CODE:-0}" >>"$LOGFILE"
			_dispatch_stats_increment "dispatch_candidate_blocked_dirty_worktree_evidence_unavailable"
			return 0
		fi
		local marker_runner_key=""
		if [[ "${_DISPATCH_DIRTY_MARKER_STATE:-}" == *":runner_key="* ]]; then
			marker_runner_key="${_DISPATCH_DIRTY_MARKER_STATE##*runner_key=}"
		fi
		local local_runner_key=""
		if declare -F runner_identity_key >/dev/null 2>&1; then
			local_runner_key=$(runner_identity_key)
		fi
		if [[ -n "$marker_runner_key" && "$marker_runner_key" == "$local_runner_key" ]]; then
			echo "[pulse-wrapper] Dispatch_max: resuming #${issue_number} (${repo_slug}) on owning runner with preserved dirty worktree" >>"$LOGFILE"
			_dispatch_stats_increment "dispatch_candidate_dirty_worktree_same_runner_resume"
			return 1
		fi
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — recent worker dirty-worktree recovery marker is unresolved" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_skipped_dirty_worktree_recovery"
		return 0
	fi
	if [[ "${_DISPATCH_DIRTY_MARKER_STATE:-}" == expired:* ]]; then
		local resolution_body=""
		resolution_body=$(printf '<!-- ops:start -->\n<!-- worker-dirty-worktree:resolved -->\nWORKER_DIRTY_WORKTREE_RESOLVED reason=owning-runner-window-expired ts=%s\n\nThe bounded same-runner recovery window expired without a pushed checkpoint. The runner-local ledger/archive remains the audit record; this marker is cleared once so cross-runner redispatch can proceed deterministically.\n<!-- ops:end -->' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
		gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
			--method POST \
			--field body="$resolution_body" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Dispatch_max: cleared expired dirty-worktree marker for #${issue_number} (${repo_slug}); cross-runner takeover may proceed" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_dirty_worktree_recovery_expired"
	fi
	return 1
}

#######################################
# Skip candidates that are benignly blocked by current assignment/block state.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_benign_block() {
	local issue_number="$1"
	local repo_slug="$2"

	local benign_block_reason=""
	if benign_block_reason=$(_dispatch_benign_blocked_candidate_reason "$issue_number" "$repo_slug"); then
		_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_INELIGIBLE"
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — skip:already_assigned blocked:${benign_block_reason} from current pulse cycle" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_blocked_${benign_block_reason}"
		return 0
	fi
	return 1
}

#######################################
# Skip a candidate covered by an unchanged durable footprint-overlap defer.
# State errors and wake conditions fall through to the authoritative live gate.
# Arguments: issue number, repo slug, prefetched candidate JSON
# Returns: 0 to skip, 1 to continue
#######################################
_dispatch_skip_for_footprint_defer() {
	local issue_number="$1"
	local repo_slug="$2"
	local candidate_json="$3"
	declare -F _footprint_defer_should_suppress >/dev/null 2>&1 || return 1
	_footprint_defer_should_suppress "$issue_number" "$repo_slug" "$candidate_json" || return 1
	_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_INELIGIBLE"
	_dispatch_stats_increment "dispatch_candidate_footprint_defer_suppressed"
	return 0
}

#######################################
# Skip candidates with terminal blockers.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_terminal_blocker() {
	local issue_number="$1"
	local repo_slug="$2"

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
	return 1
}

#######################################
# Skip candidates at the fast-fail threshold after applying age-out repair.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_fast_fail() {
	local issue_number="$1"
	local repo_slug="$2"

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
	return 1
}

#######################################
# Skip candidates that are under per-issue dispatch backoff.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through skip checks
#######################################
_dispatch_skip_for_backoff() {
	local issue_number="$1"
	local repo_slug="$2"

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
			# Record the extended cooldown once at the 4th+ failure threshold.
			if printf '%s' "$_backoff_output" | grep -q 'BACKOFF_NOTICE_REQUIRED'; then
				local _backoff_count=""
				_backoff_count=$(printf '%s' "$_backoff_output" | grep -oE 'count=[0-9]+' | head -1 | cut -d= -f2)
				[[ "$_backoff_count" =~ ^[0-9]+$ ]] || _backoff_count="${DISPATCH_BACKOFF_NMR_THRESHOLD:-4}"
				declare -F _db_record_extended_backoff_notice >/dev/null 2>&1 && \
					_db_record_extended_backoff_notice "$issue_number" "$repo_slug" "$_backoff_count" || true
			fi
			return 0
		fi
		# rc=2 → error; fail-open (log warning, continue to dispatch)
		if [[ "$_backoff_rc" -eq 2 ]]; then
			echo "[pulse-wrapper] Dispatch_max: backoff check error for #${issue_number} — proceeding (fail-open)" >>"$LOGFILE"
		fi
	fi
	return 1
}

#######################################
# Skip candidates whose issue body is empty, placeholder, or explicitly lacks
# worker-ready implementation context.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns:
#   0 - candidate is skippable
#   1 - candidate should continue through dispatch
#######################################
_dispatch_skip_for_issue_body() {
	local issue_number="$1"
	local repo_slug="$2"

	# t1899/t1937: Skip issues with placeholder/empty bodies — dispatching a
	# worker to an undescribed issue wastes a session. Use REST here instead of
	# `gh issue view --json body`: this pre-dedup fast-fail runs once per
	# candidate, so a GraphQL-backed CLI read can drain the shared GraphQL budget
	# before workers ever launch.
	local issue_body="" body_read_rc=0
	declare -F gh_record_call >/dev/null 2>&1 && gh_record_call rest "pulse-dispatch-lib.sh" || true
	issue_body=$(gh api "repos/${repo_slug}/issues/${issue_number}" --jq '.body // ""' 2>/dev/null) || body_read_rc=$?
	if [[ "$body_read_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — DISPATCH_BLOCK_REASON reason=issue_body_evidence_unavailable exit_code=${body_read_rc}" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_blocked_issue_body_evidence_unavailable"
		return 0
	fi
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
		*"no implementation details for a worker"* | \
		*"No implementation details for a worker"* | \
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
	local stage_rc=0 raw_rc_file=""
	raw_rc_file=$(mktemp 2>/dev/null || printf '/tmp/aidevops-dispatch-raw-rc.%s.%s' "$$" "$issue_number")
	start_ms=$(_dispatch_now_ms)
	run_stage_with_timeout "dispatch_candidate_${issue_number}" "$timeout_seconds" \
		_dispatch_stage_rc_adapter "$raw_rc_file" dispatch_with_dedup "$@" || stage_rc=$?
	if [[ -s "$raw_rc_file" ]]; then
		read -r dispatch_rc <"$raw_rc_file" || dispatch_rc="$stage_rc"
	else
		dispatch_rc="$stage_rc"
	fi
	rm -f "$raw_rc_file" 2>/dev/null || true
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
		outcome="$_DISPATCH_OUTCOME_SUCCESS"
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
# Stop dispatch loops when REST-core launch headroom is unavailable.
#######################################
_dispatch_rest_core_progress_allows_next() {
	local context="$1"
	local budget_rc=0
	if declare -F pulse_rest_core_priority_allows_next >/dev/null 2>&1; then
		pulse_rest_core_priority_allows_next progress "$context" || budget_rc=$?
	elif declare -F pulse_rest_core_priority_allows >/dev/null 2>&1; then
		pulse_rest_core_priority_allows progress || budget_rc=$?
	else
		return 0
	fi
	[[ "$budget_rc" -eq 0 ]] && return 0
	_dispatch_stats_increment "dispatch_rest_core_circuit_blocked"
	_dispatch_stats_increment_candidate_failed "rest_core_circuit_breaker"
	return 1
}

#######################################
# Return 0 when dispatch ceremony should be serialized near the REST reserve.
# The serial zone includes the soft cap plus the in-flight allowance so a large
# parallel batch cannot arrive at the progress launch floor simultaneously.
#######################################
_dispatch_rest_core_requires_serial() {
	declare -F pulse_rest_core_priority_snapshot >/dev/null 2>&1 || return 1
	local gate_ttl=""
	if declare -F _cb_rest_core_gate_probe_ttl >/dev/null 2>&1; then
		gate_ttl=$(_cb_rest_core_gate_probe_ttl)
	fi
	local decision="" mode="" remaining="" limit="" adaptive="" soft_cap="" hard_floor="" reset_epoch=""
	decision=$(pulse_rest_core_priority_snapshot "$gate_ttl") || decision="unknown ? ? ? ? ? ?"
	read -r mode remaining limit adaptive soft_cap hard_floor reset_epoch <<<"$decision"
	case "$mode" in
	disabled) return 1 ;;
	unknown | reserve | emergency) return 0 ;;
	esac
	if [[ ! "$remaining" =~ ^[0-9]+$ || ! "$soft_cap" =~ ^[0-9]+$ ]]; then
		return 0
	fi
	local allowance=250
	if declare -F _cb_rest_core_in_flight_allowance >/dev/null 2>&1; then
		allowance=$(_cb_rest_core_in_flight_allowance)
	fi
	[[ "$allowance" =~ ^[0-9]+$ ]] || allowance=250
	[[ "$remaining" -le $((soft_cap + allowance)) ]] && return 0
	return 1
}

#######################################
# Stop dispatch loops when the GraphQL reserve is already below the circuit
# breaker threshold. The rate_limit endpoint is free, so this protects the
# high-fanout loop without spending additional GraphQL points.
#
# Returns:
#   0 — budget is sufficient, unavailable, or checker is not loaded
#   1 — GraphQL budget is below threshold; caller should stop the loop
#   2 — cycle wall-clock budget is below the per-candidate floor (logged here)
#######################################
_dispatch_graphql_budget_allows_next() {
	# Both serial and parallel candidate loops call this before any candidate
	# API work. Keep the 600s ceremony floor; defer instead of shrinking it.
	local cycle_remaining="" floor_seconds="${DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR:-600}"
	[[ "$floor_seconds" =~ ^[1-9][0-9]*$ ]] || floor_seconds=600
	if declare -F _pulse_cycle_remaining_seconds >/dev/null 2>&1 && cycle_remaining=$(_pulse_cycle_remaining_seconds "${AIDEVOPS_PULSE_CYCLE_FINALISE_RESERVE_S:-90}"); then
		if [[ "$cycle_remaining" -lt "$floor_seconds" ]]; then
			echo "[pulse-wrapper] Dispatch_max stopping early: cycle wall-clock budget below per-candidate floor (remaining=${cycle_remaining}s floor=${floor_seconds}s)" >>"$LOGFILE"
			return 2
		fi
	fi
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
# Prevents 429 rate-limit cascades when multiple thinking-tier workers are
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

	# Empty model = ordered auto-selection (no explicit model:* label) — skip cap check.
	[[ -z "$resolved_model" ]] && return 0

	# Only cap thinking-tier work; standard and simple are unaffected.
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
	# opencode is launched with '-m anthropic/claude-opus-<version>' by
	# _build_run_cmd in headless-runtime-model.sh. pgrep -f matches the full
	# cmdline, so one probe counts every opus version, including opus workers
	# chosen by auto-routing (only explicitly pinned candidates are deferred).
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
# Record a non-zero dispatch_with_dedup outcome for one candidate.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - dispatch_with_dedup return code
# Returns: 0 always (caller handles the skip/continue decision).
#######################################
_dispatch_record_nonzero_dispatch_result() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_rc="$3"
	local recent_lines=""

	recent_lines=$(_dispatch_candidate_recent_lines "$issue_number" "$repo_slug") || recent_lines=""
	echo "[pulse-wrapper] Dispatch_max: skipping #${issue_number} (${repo_slug}) — dispatch_with_dedup returned rc=${dispatch_rc}" >>"$LOGFILE"
	if [[ "$recent_lines" == *"worker_launch_rc_"* ]]; then
		echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) launch failed before validation" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_worker_launch_failed"
		_dispatch_stats_increment_candidate_failed "launch_error"
		return 0
	fi
	if [[ "$dispatch_rc" -eq 2 ]]; then
		if [[ "$recent_lines" == *"blocked_by_native_lookup_unavailable"* ]]; then
			echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) pre-launch failure reason=blocked_by_native_lookup_unavailable" >>"$LOGFILE"
			_dispatch_stats_increment_candidate_failed "blocked_by_native_lookup_unavailable"
			return 0
		fi
		_dispatch_stats_increment "dispatch_candidate_noop"
		return 0
	fi

	local failure_reason
	failure_reason=$(_dispatch_candidate_failure_reason "$issue_number" "$repo_slug" "$dispatch_rc" "$recent_lines")
	if _dispatch_candidate_benign_block_reason "$failure_reason"; then
		_DISPATCH_CANDIDATE_ELIGIBILITY="$_DISPATCH_ELIGIBILITY_INELIGIBLE"
		_dispatch_mark_benign_blocked_candidate "$issue_number" "$repo_slug" "$failure_reason"
		echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) blocked:${failure_reason} benign dispatch block" >>"$LOGFILE"
		_dispatch_stats_increment "dispatch_candidate_blocked_${failure_reason}"
		return 0
	fi

	echo "[pulse-wrapper] Dispatch_max: #${issue_number} (${repo_slug}) pre-launch failure stage=dispatch_with_dedup rc=${dispatch_rc} reason=${failure_reason}" >>"$LOGFILE"
	_dispatch_stats_increment_candidate_failed "$failure_reason"
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
