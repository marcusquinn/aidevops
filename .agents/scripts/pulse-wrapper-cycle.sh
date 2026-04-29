#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Wrapper Cycle Helpers -- Per-cycle execution helpers
# =============================================================================
# Repo refresh, pulse runner, LLM supervisor wrapper, cache priming, TODO
# ref sync, and the sourced-detection helper. Extracted from
# pulse-wrapper.sh (GH#21311 / t2936-child) to bring the orchestrator
# below the 1500-line file-size-debt threshold. No behavioural changes.
#
# Usage: source "${SCRIPT_DIR}/pulse-wrapper-cycle.sh"
#
# Dependencies:
#   - shared-constants.sh (logging primitives via worker-lifecycle-common.sh)
#   - pulse-wrapper-config.sh (LOGFILE, WRAPPER_LOGFILE, PULSE_DIR, PIDFILE,
#     LOCKDIR, STATE_FILE, HEADLESS_RUNTIME_HELPER, PULSE_MODEL,
#     PULSE_COLD_START_TIMEOUT[_UNDERFILLED], _PULSE_REFRESHED_THIS_CYCLE
#     associative array)
#   - pulse-watchdog.sh (_run_pulse_watchdog)
#   - pulse-instance-lock.sh (release_instance_lock, _handle_stale_llm_lock)
#   - pulse-capacity.sh (_compute_initial_underfill, _run_early_exit_recycle_loop)
#   - pulse-canonical-recovery.sh (pulse_canonical_recover, optional)
#   - pulse-cache-prime.sh (companion script invoked at runtime)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_WRAPPER_CYCLE_LIB_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_CYCLE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# t2433/GH#20071: Refresh a repo from remote before the large-file gate
# measures it. Without this, stale local checkouts (post-split-PR) cause
# the gate to fire on pre-split line counts, creating spurious file-size-debt
# issues every cycle until a worker dispatch triggers a pull independently.
#
# Idempotent within a process: uses _PULSE_REFRESHED_THIS_CYCLE (associative
# array declared in pulse-wrapper-config.sh) as a cycle-scoped sentinel
# keyed by repo_path. The first call for a given path fetches +
# fast-forwards; subsequent calls in the same process are no-ops. The
# array is inherited empty by every subshell (dispatch subshell,
# run_stage_with_timeout fork) so each independent context starts fresh
# — this is intentional: each context needs at most one pull per repo.
#
# Uses --ff-only to avoid catastrophic rebase conflicts in the pulse checkout.
# Uses git fetch before pull so the local is always in sync with origin/HEAD.
#
# GH#17584 context preserved: the original motivation for pulling before
# worker dispatch (workers close issues as "Invalid — file does not exist"
# on stale checkouts) is covered here at the EARLIER point — before any
# gate evaluation — rather than the later worker-launch point.
#
# Arguments:
#   $1 - repo_path: absolute path to the git working tree to refresh
# Returns: always 0 (failures are logged but never fatal — callers proceed
#   with current checkout, same as the previous git pull || { warn; } pattern)
#######################################
_pulse_refresh_repo() {
	local repo_path="$1"
	[[ -n "$repo_path" ]] || return 0

	# Sentinel: already refreshed this repo in this process context.
	if [[ "${_PULSE_REFRESHED_THIS_CYCLE[$repo_path]+_}" ]]; then
		return 0
	fi
	# Mark immediately so concurrent callers in the same process don't double-pull.
	_PULSE_REFRESHED_THIS_CYCLE[$repo_path]=1

	if ! git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "[pulse-wrapper] _pulse_refresh_repo: ${repo_path} is not a git work-tree — skipping" >>"$LOGFILE"
		return 0
	fi

	git -C "$repo_path" fetch --quiet origin >>"$LOGFILE" 2>&1 || {
		echo "[pulse-wrapper] _pulse_refresh_repo: git fetch failed for ${repo_path} — proceeding with current checkout" >>"$LOGFILE"
		return 0
	}
	if ! git -C "$repo_path" pull --ff-only --no-rebase >>"$LOGFILE" 2>&1; then
		# t2865 (GH#20922): pull may fail because of unmerged files (UU state)
		# or local uncommitted changes that would be overwritten. Try
		# canonical-recovery (stash + retry pull + pop) before giving up so the
		# repo doesn't silently degrade across pulse cycles. Recovery is
		# content-safe (no auto-resolve); on persistent failure it files an
		# advisory issue and we proceed with the current checkout.
		echo "[pulse-wrapper] _pulse_refresh_repo: git pull --ff-only failed for ${repo_path} — attempting canonical-recovery" >>"$LOGFILE"
		if declare -F pulse_canonical_recover >/dev/null 2>&1; then
			pulse_canonical_recover "$repo_path" >>"$LOGFILE" 2>&1 \
				|| echo "[pulse-wrapper] _pulse_refresh_repo: canonical-recovery did not heal ${repo_path} — proceeding with current checkout (advisory filed)" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] _pulse_refresh_repo: pulse_canonical_recover unavailable — proceeding with current checkout" >>"$LOGFILE"
		fi
	fi
	return 0
}

run_pulse() {
	local underfilled_mode="${1:-0}"
	local underfill_pct="${2:-0}"
	# trigger_mode: "daily_sweep" uses /pulse-sweep (full edge-case agent);
	# "stall" and "first_run" use /pulse (lightweight dispatch+merge agent).
	local trigger_mode="${3:-stall}"
	local effective_cold_start_timeout="$PULSE_COLD_START_TIMEOUT"
	if [[ "$underfilled_mode" == "1" ]]; then
		effective_cold_start_timeout="$PULSE_COLD_START_TIMEOUT_UNDERFILLED"
	fi
	[[ "$underfill_pct" =~ ^[0-9]+$ ]] || underfill_pct=0
	if [[ "$effective_cold_start_timeout" -gt "$PULSE_COLD_START_TIMEOUT" ]]; then
		effective_cold_start_timeout="$PULSE_COLD_START_TIMEOUT"
	fi

	local start_epoch
	start_epoch=$(date +%s)
	echo "[pulse-wrapper] Starting pulse at $(date -u +%Y-%m-%dT%H:%M:%SZ) (trigger=${trigger_mode})" >>"$WRAPPER_LOGFILE"
	echo "[pulse-wrapper] Watchdog cold-start timeout: ${effective_cold_start_timeout}s (underfilled_mode=${underfilled_mode}, underfill_pct=${underfill_pct})" >>"$LOGFILE"

	# Select agent prompt based on trigger mode:
	#   daily_sweep → /pulse-sweep (full edge-case triage, quality review, mission awareness)
	#   stall / first_run → /pulse (lightweight dispatch+merge, unblocks the stall faster)
	# The state is NOT inlined into the prompt — on Linux, execve() enforces
	# MAX_ARG_STRLEN (128KB per argument) and the state routinely exceeds this,
	# causing "Argument list too long" on every pulse invocation. The agent
	# reads the file via its Read tool instead. See: #4257
	local pulse_command="/pulse"
	if [[ "$trigger_mode" == "daily_sweep" ]]; then
		pulse_command="/pulse-sweep"
	fi
	local prompt="$pulse_command"
	if [[ -f "$STATE_FILE" ]]; then
		prompt="${pulse_command}

Pre-fetched state file: ${STATE_FILE}
Read this file before proceeding — it contains the current repo/PR/issue state
gathered by pulse-wrapper.sh BEFORE this session started."
	fi

	# Run the provider-aware headless wrapper in background.
	local -a pulse_cmd=("$HEADLESS_RUNTIME_HELPER" run --role pulse --session-key supervisor-pulse --dir "$PULSE_DIR" --title "Supervisor Pulse" --agent Automate --prompt "$prompt" --tier sonnet)
	if [[ -n "$PULSE_MODEL" ]]; then
		pulse_cmd+=(--model "$PULSE_MODEL")
	fi
	"${pulse_cmd[@]}" >>"$LOGFILE" 2>&1 &

	local opencode_pid=$!
	echo "$opencode_pid" >"$PIDFILE"

	echo "[pulse-wrapper] opencode PID: $opencode_pid" >>"$LOGFILE"

	# Run the watchdog loop (checks stale/idle/progress, guards children)
	_run_pulse_watchdog "$opencode_pid" "$start_epoch" "$effective_cold_start_timeout"

	# Write IDLE sentinel — never delete the PID file (GH#4324).
	echo "IDLE:$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PIDFILE"

	local end_epoch
	end_epoch=$(date +%s)
	local duration=$((end_epoch - start_epoch))
	echo "[pulse-wrapper] Pulse completed at $(date -u +%Y-%m-%dT%H:%M:%SZ) (ran ${duration}s)" >>"$LOGFILE"
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_maybe_run_llm_supervisor
#
# Guarded LLM supervisor invocation. When _should_run_llm_supervisor signals
# the deterministic backlog is stalled or the daily sweep is due (or
# PULSE_FORCE_LLM=1 overrides), acquires the LLM lock (separate from the
# instance lock so deterministic 2-min cycles aren't blocked) and invokes
# run_pulse() with the appropriate trigger_mode. Records the run epoch and
# kicks off the early-exit recycle loop on completion.
# ---------------------------------------------------------------------------
_pulse_maybe_run_llm_supervisor() {
	local skip_llm=false
	local llm_trigger_mode="stall"
	if [[ "${PULSE_FORCE_LLM:-0}" != "1" ]] && ! _should_run_llm_supervisor; then
		skip_llm=true
		echo "[pulse-wrapper] Skipping LLM supervisor (backlog progressing, daily sweep not due)" >>"$LOGFILE"
	else
		if [[ -f "${PULSE_DIR}/llm_trigger_mode" ]]; then
			llm_trigger_mode=$(cat "${PULSE_DIR}/llm_trigger_mode" 2>/dev/null) || llm_trigger_mode="stall"
		fi
		if [[ "${PULSE_FORCE_LLM:-0}" == "1" && "$llm_trigger_mode" == "stall" ]]; then
			llm_trigger_mode="daily_sweep"
		fi
	fi

	if [[ "$skip_llm" == "false" ]]; then
		# Use a separate LLM lock so only one LLM session runs at a time,
		# without blocking the deterministic 2-min cycle.
		local llm_lockdir="${LOCKDIR}.llm"
		local _llm_lock_acquired=false

		if mkdir "$llm_lockdir" 2>/dev/null; then
			_llm_lock_acquired=true
		elif _handle_stale_llm_lock "$llm_lockdir"; then
			# GH#20613: stale lock reclaimed — we now own it
			_llm_lock_acquired=true
		fi

		if [[ "$_llm_lock_acquired" == "true" ]]; then
			echo "$$" >"${llm_lockdir}/pid" 2>/dev/null || true
			# shellcheck disable=SC2064
			trap "rm -rf '$llm_lockdir' 2>/dev/null; release_instance_lock" EXIT

			local underfill_output
			underfill_output=$(_compute_initial_underfill)
			local initial_underfilled_mode initial_underfill_pct
			initial_underfilled_mode=$(echo "$underfill_output" | sed -n '1p')
			initial_underfill_pct=$(echo "$underfill_output" | sed -n '2p')

			local pulse_start_epoch
			pulse_start_epoch=$(date +%s)
			run_pulse "$initial_underfilled_mode" "$initial_underfill_pct" "$llm_trigger_mode"
			local pulse_end_epoch
			pulse_end_epoch=$(date +%s)
			local pulse_duration=$((pulse_end_epoch - pulse_start_epoch))

			date +%s >"${PULSE_DIR}/last_llm_run_epoch"
			_run_early_exit_recycle_loop "$pulse_duration"
			rm -rf "$llm_lockdir" 2>/dev/null || true
		fi
	fi
	return 0
}

# t2994: cache priming with staleness gate. Called from main() once per
# launchd invocation, but only fires if the sentinel is missing or older
# than $_prime_max_age seconds (default 1800 = 30 min, override via
# AIDEVOPS_PULSE_PRIME_MAX_AGE). Steady-state launchd respawns (every 120s)
# hit a fresh sentinel and skip — prefetch_state inside the cycle keeps
# caches warm naturally. Post-deploy first invocations and long quiet
# periods trigger an actual prime. Non-fatal — a prime failure must not
# abort the cycle. Honours AIDEVOPS_SKIP_CACHE_PRIME=1 for debug.
#
# Moved here from pulse-lifecycle-helper.sh::_start (t2992) because
# launchd's KeepAlive bypasses the helper — auto-respawn within the
# helper's stop→sleep→start window means _start's _is_running early-return
# skips priming entirely, and the original t2992 hook never fired during
# launchd-managed restarts (the canonical path on macOS).
_pulse_prime_caches_if_stale() {
	[[ "${AIDEVOPS_SKIP_CACHE_PRIME:-0}" == "1" ]] && return 0

	local _prime_helper=""
	local _prime_sentinel=""
	local _prime_max_age=""
	_prime_helper="${SCRIPT_DIR}/pulse-cache-prime.sh"
	_prime_sentinel="${HOME}/.aidevops/cache/pulse-cache-prime-last-run"
	_prime_max_age="${AIDEVOPS_PULSE_PRIME_MAX_AGE:-1800}"
	[[ "$_prime_max_age" =~ ^[0-9]+$ ]] || _prime_max_age=1800

	mkdir -p "$(dirname "$_prime_sentinel")"
	[[ ! -x "$_prime_helper" ]] && return 0

	local _should_prime=0
	if [[ ! -f "$_prime_sentinel" ]]; then
		_should_prime=1
	else
		local _now_epoch="" _stamp_epoch="" _age_s=""
		_now_epoch=$(date +%s 2>/dev/null)
		_stamp_epoch=$(_file_mtime_epoch "$_prime_sentinel")
		_age_s=$(( ${_now_epoch:-0} - ${_stamp_epoch:-0} ))
		[[ "$_age_s" -gt "$_prime_max_age" ]] && _should_prime=1
	fi

	if [[ "$_should_prime" == "1" ]]; then
		printf '[pulse-wrapper] Pre-warming pulse caches (t2992 + t2994 stale-gate)...\n' >&2
		"$_prime_helper" >/dev/null 2>&1 || printf '[pulse-wrapper] WARN: cache prime returned non-zero (non-fatal — first cycle may be slow)\n' >&2
	fi
	return 0
}

#######################################
# _pulse_check_runaway_log — sentinel-gated runaway-log detector (GH#21756)
#
# Calls pulse-log-runaway-detector.sh check-and-heal every 5 minutes
# (configurable via PULSE_RUNAWAY_LOG_CHECK_INTERVAL). Catches wrapper
# log growing at MB/s from tight error loops before disk fills.
# Modelled on _pulse_prime_caches_if_stale (t2994).
#
# Fail-open: any internal error returns 0. Never blocks the pulse cycle.
#######################################
_pulse_check_runaway_log() {
	[[ "${AIDEVOPS_SKIP_RUNAWAY_LOG_CHECK:-0}" == "1" ]] && return 0

	local _detector_helper=""
	local _detector_sentinel=""
	local _detector_max_age=""
	_detector_helper="${SCRIPT_DIR}/pulse-log-runaway-detector.sh"
	_detector_sentinel="${HOME}/.aidevops/cache/pulse-runaway-log-check-last-run"
	_detector_max_age="${PULSE_RUNAWAY_LOG_CHECK_INTERVAL:-300}"
	[[ "$_detector_max_age" =~ ^[0-9]+$ ]] || _detector_max_age=300

	mkdir -p "$(dirname "$_detector_sentinel")" 2>/dev/null || return 0
	[[ ! -x "$_detector_helper" ]] && return 0

	local _should_check=0
	if [[ ! -f "$_detector_sentinel" ]]; then
		_should_check=1
	else
		local _now_epoch="" _stamp_epoch="" _age_s=""
		_now_epoch=$(date +%s 2>/dev/null)
		_stamp_epoch=$(_file_mtime_epoch "$_detector_sentinel")
		_age_s=$(( ${_now_epoch:-0} - ${_stamp_epoch:-0} ))
		[[ "$_age_s" -gt "$_detector_max_age" ]] && _should_check=1
	fi

	if [[ "$_should_check" == "1" ]]; then
		"$_detector_helper" check-and-heal 2>>"$WRAPPER_LOGFILE" || true
		# Touch sentinel regardless of outcome (fail-open)
		touch "$_detector_sentinel" 2>/dev/null || true
	fi
	return 0
}

#######################################
# sync_todo_refs_for_repo
#
# Pull issue→TODO refs, close completed entries, and reopen entries whose
# linked issue reopened. If TODO.md changed, commit and push. All steps
# are best-effort (errors swallowed) so a single repo failure can't abort
# the cycle's other repos.
#######################################
sync_todo_refs_for_repo() {
	local repo_slug="$1"
	local repo_path="$2"
	local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

	/bin/bash "${script_dir}/issue-sync-helper.sh" pull --repo "$repo_slug" 2>&1 || true
	/bin/bash "${script_dir}/issue-sync-helper.sh" close --repo "$repo_slug" 2>&1 || true
	/bin/bash "${script_dir}/issue-sync-helper.sh" reopen --repo "$repo_slug" 2>&1 || true
	git -C "$repo_path" diff --quiet TODO.md 2>/dev/null || {
		git -C "$repo_path" add TODO.md &&
			git -C "$repo_path" commit -m "chore: sync GitHub issue refs to TODO.md [skip ci]" &&
			git -C "$repo_path" push
	} 2>/dev/null || true
	return 0
}

# Only run main when executed directly, not when sourced.
# The pulse agent sources this file to access helper functions
# (check_external_contributor_pr, check_permission_failure_pr)
# without triggering the full pulse lifecycle.
#
# Shell-portable source detection (GH#3931):
#   bash: BASH_SOURCE[0] differs from $0 when sourced
#   zsh:  BASH_SOURCE is undefined; use ZSH_EVAL_CONTEXT instead
#         (contains "file" when sourced, "toplevel" when executed)
_pulse_is_sourced() {
	if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
		[[ "${BASH_SOURCE[0]}" != "${0}" ]]
	elif [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
		[[ ":${ZSH_EVAL_CONTEXT}:" == *":file:"* ]]
	else
		return 1
	fi
}
