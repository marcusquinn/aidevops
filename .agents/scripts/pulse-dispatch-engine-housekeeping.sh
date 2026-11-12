#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Post-dispatch housekeeping: lock ownership, resumable stages and async launch.
# Sourced by pulse-dispatch-engine.sh; uses its defaults and caller-provided
# stage adapters. No maintenance runs merely by sourcing this library.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DISPATCH_ENGINE_HOUSEKEEPING_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_ENGINE_HOUSEKEEPING_LOADED=1
_PULSE_BRIEF_HOLD_RELEASE_STAGE="release_repaired_brief_holds"

#######################################
# Return the async post-dispatch housekeeping lock directory path.
#
# Returns 0 always; emits path on stdout.
#######################################
_pulse_post_dispatch_housekeeping_lockdir() {
	# pulse-lifecycle-helper.sh reads this lock's async-pid file to tell the
	# async run apart from a main cycle (_PULSE_HOUSEKEEPING_LOCK_DIR); keep
	# both in step.
	printf '%s\n' "${HOME}/.aidevops/logs/pulse-post-dispatch-housekeeping.lock"
	return 0
}

#######################################
# Record the housekeeping lock owner in a freshly created lock directory.
#
# The async run is a subshell of the cycle. Bash 3.2 has no BASHPID and $$
# stays the cycle PID there, so resolve the executing shell as in
# pulse-logging.sh; recording the cycle PID would make the duplicate check
# follow the cycle instead of the run. The async run also writes async-pid:
# it outlives the cycle with the bare wrapper argv, and that marker is how
# pulse-lifecycle-helper.sh keeps it out of the main-cycle PID set. A
	# direct run records only pid. With an outer lane watchdog, async-pid names
	# the supervisor that can outlive the cycle; pid still owns the stage lock.
#
# Args:
#   $1 - lock directory path
# Returns 0 always.
#######################################
_pulse_record_post_dispatch_housekeeping_owner() {
	local lockdir="$1"
	local owner_pid="${BASHPID:-}"
	if [[ -z "$owner_pid" ]]; then
		owner_pid="$(exec sh -c 'printf "%s" "$PPID"')" || owner_pid=""
	fi
	[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || owner_pid="$$"
	printf '%s\n' "$owner_pid" >"${lockdir}/pid" 2>/dev/null || true
	if [[ "${_PULSE_HOUSEKEEPING_ASYNC:-0}" == "1" ]]; then
		printf '%s\n' "${_PULSE_HOUSEKEEPING_SUPERVISOR_PID:-$owner_pid}" >"${lockdir}/async-pid" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Acquire the post-dispatch housekeeping lock.
#
# Args:
#   $1 - lock directory path
# Returns 0 if acquired, 1 if another live runner owns it.
#######################################
_pulse_acquire_post_dispatch_housekeeping_lock() {
	local lockdir="$1"
	local lock_parent
	lock_parent="$(dirname "$lockdir")"
	mkdir -p "$lock_parent" 2>/dev/null || return 1

	if mkdir "$lockdir" 2>/dev/null; then
		_pulse_record_post_dispatch_housekeeping_owner "$lockdir"
		return 0
	fi

	local lock_pid=""
	if [[ -f "${lockdir}/pid" ]]; then
		read -r lock_pid <"${lockdir}/pid" 2>/dev/null || lock_pid=""
	fi
	if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
		echo "[pulse-wrapper] Async post-dispatch housekeeping already running (pid=${lock_pid}) — skipping duplicate" >>"$LOGFILE"
		return 1
	fi

	echo "[pulse-wrapper] Async post-dispatch housekeeping: reclaiming stale lock (pid=${lock_pid:-missing})" >>"$LOGFILE"
	rm -rf "$lockdir" 2>/dev/null || true
	if mkdir "$lockdir" 2>/dev/null; then
		_pulse_record_post_dispatch_housekeeping_owner "$lockdir"
		return 0
	fi
	return 1
}

#######################################
# Release the post-dispatch housekeeping lock.
#
# Args:
#   $1 - lock directory path
# Returns 0 always.
#######################################
_pulse_release_post_dispatch_housekeeping_lock() {
	local lockdir="$1"
	rm -rf "$lockdir" 2>/dev/null || true
	return 0
}

#######################################
# Return 0 when blocked-status maintenance has been starved (GH#33246).
#
# The in-cycle dependency-graph build, blocked refresh and brief-hold release
# run late in the deterministic pipeline and are deferred whenever preflight
# consumes the cycle budget. A missing or old cache triggers catch-up; a pending
# marker keeps downstream recovery eligible even after a graph rebuild.
# AIDEVOPS_PULSE_BLOCKER_REFRESH_MAX_AGE_S=0 disables the catch-up.
#######################################
_pulse_blocker_refresh_starved() {
	local max_age="${AIDEVOPS_PULSE_BLOCKER_REFRESH_MAX_AGE_S:-1800}"
	local cache_file="${DEP_GRAPH_CACHE_FILE:-}"
	[[ "$max_age" =~ ^[0-9]+$ ]] || max_age=1800
	[[ "$max_age" -gt 0 && -n "$cache_file" ]] || return 1
	# Rebuilding the graph freshens the cache before downstream recovery finishes.
	# Pending work survives failures and signals independently of that mtime.
	[[ -f "$(_pulse_post_dispatch_housekeeping_statefile).blocker-refresh-pending" ]] && return 0
	[[ -f "$cache_file" ]] || return 0
	# Per-repository checkpoints update mtime without completing the rebuild.
	jq -e '.rebuild_complete == false' "$cache_file" >/dev/null 2>&1 && return 0
	local now="" mtime=""
	now=$(date +%s 2>/dev/null) || return 1
	mtime=$(date -r "$cache_file" +%s 2>/dev/null) || return 0
	[[ "$now" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ ]] || return 1
	[[ $((now - mtime)) -ge "$max_age" ]] && return 0
	return 1
}

#######################################
# Catch up starved blocked-status maintenance outside the cycle clamp.
#
# Reuses the in-cycle stage names so GraphQL/REST budget priority still
# classifies them as deferrable. Runs graph rebuild -> blocked refresh ->
# repaired brief-hold release, matching the deterministic pipeline order.
#
# Args:
#   $1 - per-stage timeout seconds
#   $2 - graph rebuild timeout seconds (defaults to $1)
# Returns 0 when no catch-up is needed or all available steps succeed;
# returns 1 when a prerequisite fails or is deferred.
#######################################
_pulse_run_blocker_refresh_catchup() {
	local stage_timeout="${1:-${PRE_RUN_STAGE_TIMEOUT:-600}}"
	[[ "$stage_timeout" =~ ^[0-9]+$ ]] || stage_timeout=600
	local graph_timeout="${2:-$stage_timeout}"
	[[ "$graph_timeout" =~ ^[0-9]+$ ]] || graph_timeout="$stage_timeout"
	_pulse_blocker_refresh_starved || return 0
	declare -F build_dependency_graph_cache >/dev/null 2>&1 || return 0
	local pending_file="" progress_file="" graph_stage="build_dependency_graph_cache"
	pending_file="$(_pulse_post_dispatch_housekeeping_statefile).blocker-refresh-pending"
	progress_file="${pending_file}.stages"
	# Persist before any cache write; do not start work we cannot resume safely.
	touch "$pending_file" || return 1
	# Keep completed inner stages across the outer 180s watchdog. Repeating a
	# costly successful rebuild on every retry can starve downstream recovery.
	# Check actual per-repo freshness, not just a newly written cache's mtime:
	# failed fetches can preserve older repo data in an otherwise fresh file.
	if [[ -f "$progress_file" ]] &&
		{ ! _pulse_housekeeping_stage_recently_done "$graph_stage" "$progress_file" >/dev/null || ! jq -e \
			--argjson max_age "$((${DEP_GRAPH_CACHE_TTL_SECS:-300} * 2))" '
		now as $now | .rebuild_complete != false and (.repos | length) > 0 and all(.repos[];
			(.built_at | type) == "number" and .built_at > 0
			and .built_at <= $now and $now - .built_at < $max_age)
	' "${DEP_GRAPH_CACHE_FILE:-}" >/dev/null 2>&1; }; then
		rm -f "$progress_file" || return 1
	fi
	echo "[pulse-wrapper] Blocker refresh catch-up: dependency graph cache stale, missing or recovery pending — running starved stages (GH#33246)" >>"$LOGFILE"
	PULSE_DEP_GRAPH_FORCE_REBUILD=1 _pulse_run_resumable_housekeeping_stage "$graph_stage" "$progress_file" \
		_pulse_run_budget_priority_stage_with_timeout "$graph_stage" "$graph_timeout" build_dependency_graph_cache || return 1
	if declare -F refresh_blocked_status_from_graph >/dev/null 2>&1; then
		# Refresh has its own 30s candidate budget before an in-flight safety
		# check finishes. A cheap scanner slice (12s by default) kills the batch
		# before it can checkpoint; retain the graph batch ceiling instead.
		_pulse_run_resumable_housekeeping_stage "refresh_blocked_status_from_graph" "$progress_file" \
			_pulse_run_budget_priority_stage_with_timeout "refresh_blocked_status_from_graph" "$graph_timeout" refresh_blocked_status_from_graph || return 1
	fi
	if declare -F release_repaired_brief_holds >/dev/null 2>&1; then
		_pulse_run_resumable_housekeeping_stage "$_PULSE_BRIEF_HOLD_RELEASE_STAGE" "$progress_file" \
			_pulse_run_budget_priority_stage_with_timeout "$_PULSE_BRIEF_HOLD_RELEASE_STAGE" "$stage_timeout" release_repaired_brief_holds || return 1
		_pulse_housekeeping_mark_stage_done "$_PULSE_BRIEF_HOLD_RELEASE_STAGE" "$(_pulse_post_dispatch_housekeeping_statefile)"
	fi
	rm -f "$pending_file" "$progress_file" || return 1
	return 0
}

#######################################
# Compatibility entrypoint: recovery now has its own background budget on
# Linux as well as launchd. Never spend up to 180s recovering briefs before
# dispatch; the locked post-dispatch lane cannot be starved by the cycle clamp.
#######################################
_pulse_run_pre_dispatch_blocker_refresh() {
	return 0
}

#######################################
# Reuse the housekeeping lock for the bounded pre-dispatch recovery attempt.
# A watchdog-killed runner leaves a dead-owner lock for existing stale-lock
# reclamation; the pending marker is kept until every recovery step succeeds.
#
# Args: $1 - per-stage timeout ceiling (also bounded by the outer watchdog)
# Returns the catch-up status, or 0 when another runner owns the lock.
#######################################
_pulse_run_locked_blocker_refresh_catchup() {
	local stage_timeout="$1"
	local lockdir="" stage_rc=0
	lockdir="$(_pulse_post_dispatch_housekeeping_lockdir)"
	_pulse_acquire_post_dispatch_housekeeping_lock "$lockdir" || return 0
	_pulse_run_blocker_refresh_catchup "$stage_timeout" || stage_rc=$?
	_pulse_release_post_dispatch_housekeeping_lock "$lockdir"
	return "$stage_rc"
}

#######################################
# Return the post-dispatch housekeeping stage-progress state file path.
#
# Lives next to (not inside) the lock directory so a stale-lock reclaim, which
# removes the lock directory, keeps the interrupted run's progress (GH#34287).
#
# Returns 0 always; emits path on stdout.
#######################################
_pulse_post_dispatch_housekeeping_statefile() {
	printf '%s\n' "${HOME}/.aidevops/logs/pulse-post-dispatch-housekeeping.state"
	return 0
}

#######################################
# Return 0 when a housekeeping stage completed within the resume window.
#
# The state file holds `stage=epoch` lines written after each stage finishes
# and is removed by a clean, complete run. Fresh entries therefore only exist
# after an interrupted run (deploy reconciliation SIGTERM, crash, reboot).
# AIDEVOPS_PULSE_HOUSEKEEPING_RESUME_WINDOW_S=0 disables resume.
#
# Args:
#   $1 - stage name
#   $2 - state file path
# Returns 0 if recently completed, 1 otherwise; emits age seconds on stdout.
#######################################
_pulse_housekeeping_stage_recently_done() {
	local stage_name="$1"
	local state_file="$2"
	local window="${AIDEVOPS_PULSE_HOUSEKEEPING_RESUME_WINDOW_S:-1800}"
	[[ "$window" =~ ^[0-9]+$ ]] || window=1800
	[[ "$window" -gt 0 && -f "$state_file" ]] || return 1

	local line="" done_epoch=""
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "${stage_name}="* ]]; then
			done_epoch="${line#*=}"
		fi
	done <"$state_file"
	[[ "$done_epoch" =~ ^[0-9]+$ ]] || return 1

	local now=""
	now=$(date +%s 2>/dev/null) || return 1
	[[ "$now" =~ ^[0-9]+$ ]] || return 1
	local age=$((now - done_epoch))
	[[ "$age" -ge 0 && "$age" -lt "$window" ]] || return 1
	printf '%s\n' "$age"
	return 0
}

#######################################
# Record a finished housekeeping stage in the state file (stage=epoch).
#
# Args:
#   $1 - stage name
#   $2 - state file path
# Returns 0 always (progress persistence is best-effort).
#######################################
_pulse_housekeeping_mark_stage_done() {
	local stage_name="$1"
	local state_file="$2"
	local now=""
	now=$(date +%s 2>/dev/null) || return 0
	[[ "$now" =~ ^[0-9]+$ ]] || return 0

	local tmp_file="${state_file}.tmp.${BASHPID:-$$}"
	local line=""
	{
		if [[ -f "$state_file" ]]; then
			while IFS= read -r line || [[ -n "$line" ]]; do
				[[ -n "$line" && "$line" != "${stage_name}="* ]] && printf '%s\n' "$line"
			done <"$state_file"
		fi
		printf '%s=%s\n' "$stage_name" "$now"
	} >"$tmp_file" 2>/dev/null || {
		rm -f "$tmp_file" 2>/dev/null || true
		return 0
	}
	mv -f "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null || true
	return 0
}

#######################################
# Run one resumable housekeeping stage.
#
# Skips the stage when an interrupted earlier run already completed it within
# the resume window; otherwise records it as the current stage (for the
# signal trap), runs it, and persists its completion.
#
# Args:
#   $1 - stage name (state key)
#   $2 - state file path
#   $@ - stage command and arguments
# Returns 0 for completed work (including a fresh checkpoint), 1 otherwise.
#######################################
_pulse_run_resumable_housekeeping_stage() {
	local stage_name="$1"
	local state_file="$2"
	shift 2
	local age=""
	# A catch-up checkpoint may represent a no-op while the cache was fresh.
	# Recheck freshness on resume so later interrupted scans cannot starve it.
	if age=$(_pulse_housekeeping_stage_recently_done "$stage_name" "$state_file") &&
		{ [[ "$stage_name" != "blocker_refresh_catchup" ]] || ! _pulse_blocker_refresh_starved; }; then
		echo "[pulse-wrapper] Async post-dispatch housekeeping: resume — skipping ${stage_name} (completed ${age}s ago by an interrupted run)" >>"$LOGFILE"
		return 0
	fi
	_PULSE_HOUSEKEEPING_CURRENT_STAGE="$stage_name"
	local stage_rc=0
	# Scope the budget adapter's result to this invocation; a previous stage's
	# deferral must not leak into the next stage or the enclosing Pulse cycle.
	local _PULSE_BUDGET_STAGE_DEFERRED=0
	"$@" || stage_rc=$?
	_PULSE_HOUSEKEEPING_CURRENT_STAGE="between_stages"
	if [[ "$stage_rc" -ne 0 || "$_PULSE_BUDGET_STAGE_DEFERRED" -ne 0 ]]; then
		echo "[pulse-wrapper] Async post-dispatch housekeeping: ${stage_name} incomplete (rc=${stage_rc}, deferred=${_PULSE_BUDGET_STAGE_DEFERRED}) — not recorded as complete" >>"$LOGFILE"
		return 1
	fi
	_pulse_housekeeping_mark_stage_done "$stage_name" "$state_file"
	return 0
}

#######################################
# Log and exit when the async housekeeping subshell receives a signal.
#
# Setup reconciliation SIGTERMs every Pulse runtime process on deploy
# (intended: old-bundle code must be replaced). Logging the signal and the
# active stage makes those deaths attributable from pulse.log (GH#34287).
#
# Args:
#   $1 - signal name (TERM or HUP)
# Exits 143 for TERM, 129 for HUP.
#######################################
_pulse_housekeeping_on_signal() {
	local signal_name="$1"
	trap - TERM HUP
	echo "[pulse-wrapper] Async post-dispatch housekeeping: terminated by SIG${signal_name} during ${_PULSE_HOUSEKEEPING_CURRENT_STAGE:-unknown}" >>"$LOGFILE"
	if [[ "$signal_name" == "HUP" ]]; then
		exit 129
	fi
	exit 143
}

#######################################
# Run non-dispatch post-dispatch housekeeping stages.
#
# These stages are intentionally after early dispatch and do not protect the
# immediate worker claim/ledger safety boundary. They can therefore run under a
# separate lock while the main pulse proceeds to prefetch + the next refill.
#
# GH#34287: deploy reconciliation kills long runs, so per-stage completion is
# persisted and a following run resumes at the first incomplete stage. The
# cheap terminal reconciles (preflight_ownership_reconcile) run before the
# slow GH#33246 blocker-refresh catch-up so they are not starved behind it.
# Both recovery stages precede optional scans: synchronous housekeeping shares
# the cycle deadline, which long scans can exhaust before recovery is reached.
#
# Args:
#   $1 - per-stage timeout seconds
#   $2 - graph rebuild/cache prime timeout seconds (defaults to $1)
#   $3 - ownership reconcile timeout seconds (defaults to $1)
# Returns 0 always.
#######################################
_pulse_run_post_dispatch_housekeeping_stages() {
	local stage_timeout="${1:-${PREFLIGHT_GROUP_TIMEOUT:-${PRE_RUN_STAGE_TIMEOUT:-600}}}"
	[[ "$stage_timeout" =~ ^[0-9]+$ ]] || stage_timeout=600
	local heavy_timeout="${2:-$stage_timeout}"
	[[ "$heavy_timeout" =~ ^[0-9]+$ ]] || heavy_timeout="$stage_timeout"
	local ownership_timeout="${3:-$stage_timeout}"
	[[ "$ownership_timeout" =~ ^[0-9]+$ ]] || ownership_timeout="$stage_timeout"

	local lockdir="" state_file=""
	lockdir="$(_pulse_post_dispatch_housekeeping_lockdir)"
	state_file="$(_pulse_post_dispatch_housekeeping_statefile)"
	if ! _pulse_acquire_post_dispatch_housekeeping_lock "$lockdir"; then
		return 0
	fi

	# Aggregate explicit results without stopping independent maintenance.
	local incomplete=0
	_PULSE_HOUSEKEEPING_CURRENT_STAGE="startup"
	echo "[pulse-wrapper] Async post-dispatch housekeeping: started (timeout=${stage_timeout}s)" >>"$LOGFILE"
	_pulse_run_resumable_housekeeping_stage "preflight_ownership_reconcile" "$state_file" \
		run_stage_with_timeout "preflight_ownership_reconcile" "$ownership_timeout" \
		_preflight_ownership_reconcile "$ownership_timeout" || incomplete=1
	local catchup_rc=0
	_pulse_run_resumable_housekeeping_stage "blocker_refresh_catchup" "$state_file" \
		_pulse_run_blocker_refresh_catchup "$stage_timeout" "$heavy_timeout" || catchup_rc=$?
	[[ "$catchup_rc" -eq 0 ]] || incomplete=1
	# Brief edits need recovery even when the dependency graph is fresh. The
	# catch-up's inner checkpoint alone must not leave them on admission's path.
	if [[ "$catchup_rc" -eq 0 ]] && declare -F release_repaired_brief_holds >/dev/null 2>&1; then
		_pulse_run_resumable_housekeeping_stage "$_PULSE_BRIEF_HOLD_RELEASE_STAGE" "$state_file" \
			_pulse_run_budget_priority_stage_with_timeout "$_PULSE_BRIEF_HOLD_RELEASE_STAGE" "$stage_timeout" release_repaired_brief_holds || incomplete=1
	fi
	_pulse_run_resumable_housekeeping_stage "post_merge_scanner" "$state_file" \
		_pulse_run_optional_stage_with_timeout "post_merge_scanner" "$stage_timeout" _run_post_merge_review_scanner || incomplete=1
	_pulse_run_resumable_housekeeping_stage "pr_review_thread_response" "$state_file" \
		_pulse_run_optional_stage_with_timeout "pr_review_thread_response" "$stage_timeout" _run_pr_review_thread_response_scanner || incomplete=1
	_pulse_run_resumable_housekeeping_stage "auto_decomposer_scanner" "$state_file" \
		_pulse_run_optional_stage_with_timeout "auto_decomposer_scanner" "$heavy_timeout" _run_auto_decomposer_scanner || incomplete=1
	_pulse_run_resumable_housekeeping_stage "dedup_cleanup" "$state_file" \
		_pulse_run_optional_stage_with_timeout "dedup_cleanup" "$stage_timeout" run_simplification_dedup_cleanup || incomplete=1
	_pulse_run_resumable_housekeeping_stage "fast_fail_prune_expired" "$state_file" \
		_pulse_run_optional_stage_with_timeout "fast_fail_prune_expired" "$stage_timeout" fast_fail_prune_expired || incomplete=1
	if declare -F _pulse_prime_caches_if_stale >/dev/null 2>&1; then
		local prime_timeout="${PULSE_CACHE_PRIME_TIMEOUT:-300}"
		[[ "$prime_timeout" =~ ^[1-9][0-9]{0,3}$ ]] || prime_timeout=300
		[[ "$prime_timeout" -le "$heavy_timeout" ]] || prime_timeout="$heavy_timeout"
		_pulse_run_resumable_housekeeping_stage "cache_prime" "$state_file" \
			_pulse_run_optional_stage_with_timeout "cache_prime" "$prime_timeout" _pulse_prime_caches_if_stale || incomplete=1
	fi
	_PULSE_HOUSEKEEPING_CURRENT_STAGE="finishing"
	if [[ "$incomplete" -eq 0 ]]; then
		rm -f "$state_file" 2>/dev/null || true
		echo "[pulse-wrapper] Async post-dispatch housekeeping: complete" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Async post-dispatch housekeeping: incomplete — preserving successful stages for resume" >>"$LOGFILE"
	fi

	_pulse_release_post_dispatch_housekeeping_lock "$lockdir"
	return 0
}

#######################################
# Join service-owned housekeeping after dispatch, never during admission.
# The lane has its own total watchdog, so this wait is bounded independently
# of the number of scanner stages. Detached launchd lanes are not joined.
#######################################
_pulse_finish_post_dispatch_housekeeping() {
	local housekeeping_pid="${_PULSE_OWNED_HOUSEKEEPING_PID:-}"
	[[ "$housekeeping_pid" =~ ^[1-9][0-9]*$ ]] || return 0
	wait "$housekeeping_pid" 2>/dev/null || true
	_PULSE_OWNED_HOUSEKEEPING_PID=""
	return 0
}

#######################################
# Start post-dispatch housekeeping in a bounded independent lane.
# Lane watchdog = PULSE_HOUSEKEEPING_BUDGET_SECONDS (scanner shares, 300) +
# PULSE_HOUSEKEEPING_OWNERSHIP_BUDGET_SECONDS (ownership reconcile, 600).
#
# Args:
#   $1 - per-stage timeout seconds
# Returns 0 always.
#######################################
_pulse_start_post_dispatch_housekeeping() {
	local stage_timeout="${1:-${PREFLIGHT_GROUP_TIMEOUT:-${PRE_RUN_STAGE_TIMEOUT:-600}}}"
	[[ "$stage_timeout" =~ ^[0-9]+$ ]] || stage_timeout=600
	local lane_budget="${PULSE_HOUSEKEEPING_BUDGET_SECONDS:-300}"
	[[ "$lane_budget" =~ ^[1-9][0-9]{0,3}$ ]] || lane_budget=300
	# GH#37549: ownership reconcile (intake, single-pass reconcile, then
	# assignment normalization with the dead-stamp reaper and stranded-claim
	# recovery) routinely needs minutes and returns 124 until normalization
	# runs, so a scanner share starved it on every cycle. Give it its own
	# allowance on top of the scanner lane; the caller's ceiling still wins.
	local ownership_timeout="${PULSE_HOUSEKEEPING_OWNERSHIP_BUDGET_SECONDS:-600}"
	[[ "$ownership_timeout" =~ ^[1-9][0-9]{0,3}$ ]] || ownership_timeout=600
	[[ "$ownership_timeout" -le "$stage_timeout" ]] || ownership_timeout="$stage_timeout"
	local lane_watchdog=$((lane_budget + ownership_timeout))
	# Batch ceilings are six times the cheap scanner slice. Graph rebuild,
	# blocked refresh, decomposition and cache prime need a full batch before
	# checkpointing. These are per-call ceilings, not reserved time: the outer
	# watchdog bounds the whole lane and successful checkpoints survive it.
	# Keep the caller's ceiling, ownership allowance and total lane unchanged.
	local stage_slice=$((lane_budget / 24))
	[[ "$stage_slice" -ge 1 ]] || stage_slice=1
	local heavy_timeout="$stage_timeout" heavy_slice=$((stage_slice * 6))
	[[ "$heavy_timeout" -le "$heavy_slice" ]] || heavy_timeout="$heavy_slice"
	[[ "$stage_timeout" -le "$stage_slice" ]] || stage_timeout="$stage_slice"
	# Repeated preflight calls in one service cycle must not lose the PID that
	# owns the join, or launch another lane before the first acquires its lock.
	if [[ "${_PULSE_OWNED_HOUSEKEEPING_PID:-}" =~ ^[1-9][0-9]*$ ]] && kill -0 "$_PULSE_OWNED_HOUSEKEEPING_PID" 2>/dev/null; then
		return 0
	fi

	# GH#33256: launchd tears down the pulse job's process group when the
	# wrapper exits, which killed ~3 of 4 housekeeping runs mid-stage (and the
	# GH#33246 catch-up with them). Job control only around the launch gives
	# the subshell its own process group; stage timeouts kill by parent tree,
	# so they are unaffected. Restore the caller's monitor mode afterwards.
	local monitor_was_on=false
	[[ $- == *m* ]] && monitor_was_on=true
	set -m 2>/dev/null || true
	(
		set +m 2>/dev/null || true
		trap - EXIT INT
		# GH#34287: attribute deploy-reconciliation kills in pulse.log.
		_PULSE_HOUSEKEEPING_CURRENT_STAGE="launch"
		trap '_pulse_housekeeping_on_signal TERM' TERM
		trap '_pulse_housekeeping_on_signal HUP' HUP
		AIDEVOPS_PULSE_STAGE_CYCLE_CLAMP=0
		_PULSE_HOUSEKEEPING_ASYNC=1
		_PULSE_HOUSEKEEPING_SUPERVISOR_PID="${BASHPID:-}"
		if [[ -z "$_PULSE_HOUSEKEEPING_SUPERVISOR_PID" ]]; then
			_PULSE_HOUSEKEEPING_SUPERVISOR_PID="$(exec sh -c 'printf "%s" "$PPID"')"
		fi
		run_stage_with_timeout "post_dispatch_housekeeping" "$lane_watchdog" \
			_pulse_run_post_dispatch_housekeeping_stages "$stage_timeout" "$heavy_timeout" "$ownership_timeout"
	) >>"$LOGFILE" 2>&1 &
	local housekeeping_pid=$!
	[[ "$monitor_was_on" == true ]] || set +m 2>/dev/null || true
	echo "[pulse-wrapper] Async post-dispatch housekeeping: launched pid=${housekeeping_pid}" >>"$LOGFILE"
	if [[ "${AIDEVOPS_PULSE_ASYNC_POST_DISPATCH_HOUSEKEEPING:-1}" != "1" ]]; then
		# systemd kills service cgroup descendants at wrapper exit. Keep the
		# lane owned and join at cycle end rather than serialising admission.
		_PULSE_OWNED_HOUSEKEEPING_PID="$housekeeping_pid"
		return 0
	fi
	disown "$housekeeping_pid" 2>/dev/null || true
	return 0
}
