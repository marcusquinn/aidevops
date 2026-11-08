#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# LLM supervisor scheduling, terminal-blocker recovery and backlog snapshots.
# Sourced by pulse-dispatch-engine.sh; uses its defaults and caller-provided
# API and health adapters. No supervisor work runs merely by sourcing this library.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DISPATCH_ENGINE_SUPERVISOR_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_ENGINE_SUPERVISOR_LOADED=1

_pulse_read_epoch_file() {
	local file_path="$1"
	local epoch="0"
	if [[ -f "$file_path" ]]; then
		epoch=$(cat "$file_path" 2>/dev/null) || epoch="0"
	fi
	[[ "$epoch" =~ ^[0-9]+$ ]] || epoch="0"
	printf '%s\n' "$epoch"
	return 0
}

_pulse_write_trigger_mode() {
	local trigger_mode="$1"
	printf '%s\n' "$trigger_mode" >"${PULSE_DIR}/llm_trigger_mode" 2>/dev/null || return 1
	return 0
}

_pulse_llm_failure_cooldown_active() {
	local now_epoch="$1"
	local last_success_epoch="$2"
	local last_attempt_epoch="$3"
	local retry_interval="${PULSE_LLM_FAILURE_RETRY_INTERVAL:-1800}"
	[[ "$retry_interval" =~ ^[0-9]+$ ]] || retry_interval=1800

	if [[ "$last_attempt_epoch" -gt "$last_success_epoch" ]]; then
		local attempt_age=$((now_epoch - last_attempt_epoch))
		if [[ "$attempt_age" -lt "$retry_interval" ]]; then
			echo "[pulse-wrapper] LLM supervisor: previous attempt failed ${attempt_age}s ago; retry cooldown ${retry_interval}s" >>"$LOGFILE"
			return 0
		fi
	fi
	return 1
}

#######################################
# GH#34000 follow-up: an incomplete prefetch defers the LLM supervisor because
# its prompt points at STATE_FILE. A runner whose prefetch degrades on every
# cycle would then never run the supervisor, starving the daily sweep and
# terminal-blocker recovery indefinitely. Admit a degraded-prefetch supervisor
# decision once the latest attempt/success is older than
# PULSE_LLM_DEGRADED_ESCAPE_SECONDS (default 6h; 0 disables). The normal
# _should_run_llm_supervisor gates and failure cooldown still apply, and the
# prompt marks the state file incomplete.
# Returns: 0 when a degraded-prefetch supervisor run is admitted, 1 otherwise
#######################################
_pulse_degraded_prefetch_supervisor_escape_due() {
	local escape_seconds="${PULSE_LLM_DEGRADED_ESCAPE_SECONDS:-21600}"
	local now_epoch="" last_success="" last_attempt="" latest=0
	[[ "$escape_seconds" =~ ^[0-9]+$ && "$escape_seconds" -gt 0 ]] || return 1
	now_epoch=$(date +%s)
	last_success=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_success_epoch")
	last_attempt=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_attempt_epoch")
	latest="$last_success"
	[[ "$last_attempt" -gt "$latest" ]] && latest="$last_attempt"
	[[ $((now_epoch - latest)) -ge "$escape_seconds" ]] || return 1
	return 0
}

_should_run_llm_supervisor() {
	local now_epoch
	now_epoch=$(date +%s)

	# 1. Daily sweep: only a successful daily sweep advances its cadence.
	# last_llm_run_epoch remains as the legacy success timestamp for older installs;
	# last_llm_attempt_epoch is separate so failed runs do not suppress retries for
	# a full daily interval.
	local last_llm_success_epoch="" last_llm_attempt_epoch=""
	last_llm_success_epoch=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_success_epoch")
	if [[ "$last_llm_success_epoch" -eq 0 ]]; then
		last_llm_success_epoch=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_run_epoch")
	fi
	last_llm_attempt_epoch=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_attempt_epoch")

	local last_daily_epoch="" last_success_mode=""
	last_daily_epoch=$(_pulse_read_epoch_file "${PULSE_DIR}/last_daily_sweep_success_epoch")
	if [[ "$last_daily_epoch" -eq 0 && -f "${PULSE_DIR}/last_llm_success_mode" ]]; then
		IFS= read -r last_success_mode <"${PULSE_DIR}/last_llm_success_mode" || true
		# Migrate only positively identified daily completion evidence. A recent
		# stall/first-run success must not postpone an unobserved daily sweep.
		if [[ "$last_success_mode" == "daily_sweep" ]]; then
			last_daily_epoch="$last_llm_success_epoch"
		fi
	fi
	local llm_age=$((now_epoch - last_daily_epoch))
	if [[ "$llm_age" -ge "$PULSE_LLM_DAILY_INTERVAL" ]]; then
		if _pulse_llm_failure_cooldown_active "$now_epoch" "$last_llm_success_epoch" "$last_llm_attempt_epoch"; then
			return 1
		fi
		echo "[pulse-wrapper] LLM supervisor: daily sweep due (last run ${llm_age}s ago)" >>"$LOGFILE"
		_pulse_write_trigger_mode "daily_sweep" || return 1
		return 0
	fi

	# 1b. t18514: circuit-held issues owned by this runner need the AI brief
	# owner. Rate-limit the (GitHub-verified) pending count by interval.
	if _pulse_blocker_recovery_due "$now_epoch" "$last_llm_success_epoch" "$last_llm_attempt_epoch"; then
		return 0
	fi

	# 2. Backlog stall: check if issue+PR count has changed
	local snapshot_file="${PULSE_DIR}/backlog_snapshot.txt"
	if [[ ! -f "$snapshot_file" ]]; then
		# First run — take snapshot and run LLM
		_update_backlog_snapshot "$now_epoch"
		echo "[pulse-wrapper] LLM supervisor: first run (no snapshot)" >>"$LOGFILE"
		_pulse_write_trigger_mode "first_run" || return 1
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
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$REPOS_JSON" 2>/dev/null)

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
		# A paused dispatch backlog cannot progress. Keep non-stall supervisor
		# work eligible, and fail open when the shared health gate is unavailable.
		if declare -F _pulse_dispatch_runner_health_paused >/dev/null 2>&1 && RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE=false _pulse_dispatch_runner_health_paused; then
			echo "[pulse-wrapper] LLM supervisor: stall trigger suppressed — runner-health breaker paused (t2897)" >>"$LOGFILE"
			return 1
		fi
		echo "[pulse-wrapper] LLM supervisor: backlog stalled for ${snap_age}s (issues=${current_issues} prs=${current_prs}, unchanged from ${snap_issues}+${snap_prs})" >>"$LOGFILE"
		_update_backlog_snapshot "$now_epoch" "$current_issues" "$current_prs"
		_pulse_write_trigger_mode "stall" || return 1
		return 0
	fi

	# Stalled but not long enough yet
	return 1
}

#######################################
# GH#36026: release positively re-armed queued holds independently of LLM
# scheduling. Use cached API-pressure state only; never probe to bypass a fuse.
#######################################
_pulse_rearm_blocker_holds() {
	local now_epoch="${1:-$(date +%s)}"
	local interval="${PULSE_BLOCKER_REARM_INTERVAL:-600}"
	local stamp="${PULSE_DIR}/last_blocker_rearm_check_epoch"
	local helper="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/terminal-blocker-recovery-helper.sh"
	local last_check=0 rc=0
	[[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || return 0
	[[ -f "$helper" ]] || return 0
	[[ ! -f "${_CIRCUIT_BREAKER_STATE_FILE:-${HOME}/.aidevops/logs/pulse-graphql-circuit-breaker.state}" ]] || return 0
	if declare -F _gh_secondary_cooldown_active >/dev/null 2>&1 && _gh_secondary_cooldown_active; then
		return 0
	fi
	last_check=$(_pulse_read_epoch_file "$stamp")
	[[ $((now_epoch - last_check)) -ge "$interval" ]] || return 0
	printf '%s\n' "$now_epoch" >"$stamp" 2>/dev/null || return 1
	# The helper bounds identity and queue work with the existing recovery
	# budget and saves an independent cursor on partial passes.
	bash "$helper" rearm >>"$LOGFILE" 2>&1 || rc=$?
	[[ "$rc" -eq 0 ]] || printf '[pulse-wrapper] Blocker rearm pass incomplete (rc=%s)\n' "$rc" >>"$LOGFILE"
	return 0
}

#######################################
# t18514/GH#32754: decide whether pending terminal-blocker recovery entries
# warrant an LLM supervisor run. Checks at most once per interval so the
# GitHub-verified count never runs on every pulse cycle.
# Args: now_epoch last_success_epoch last_attempt_epoch
# Returns: 0 when a recovery run should start (trigger mode written), 1 otherwise
#######################################
_pulse_blocker_recovery_due() {
	local now_epoch="$1"
	local last_success_epoch="$2"
	local last_attempt_epoch="$3"
	local interval="${PULSE_LLM_RECOVERY_INTERVAL:-10800}"
	local stamp="${PULSE_DIR}/last_blocker_recovery_check_epoch"
	local helper="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/terminal-blocker-recovery-helper.sh"
	local last_check=0 pending=0 pending_rc=0 scan_note=""
	[[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || return 1
	[[ -f "$helper" ]] || return 1
	[[ -f "$stamp" ]] && read -r last_check <"$stamp"
	[[ "$last_check" =~ ^[0-9]+$ ]] || last_check=0
	[[ $((now_epoch - last_check)) -ge "$interval" ]] || return 1
	printf '%s\n' "$now_epoch" >"$stamp" 2>/dev/null || return 1
	# GH#35945: exit 2 is an incomplete scan whose stdout is still the partial
	# count (helper contract). The bounded seed spans every pulse repo and
	# rarely finishes in one call, so discarding that count kept this trigger
	# from ever firing. Any other failure means nothing is known to be pending.
	pending=$(bash "$helper" pending --count 2>/dev/null) || pending_rc=$?
	case "$pending_rc" in
	0) ;;
	2) scan_note=" (partial scan)" ;;
	*) pending=0 ;;
	esac
	[[ "$pending" =~ ^[0-9]+$ && "$pending" -gt 0 ]] || return 1
	if _pulse_llm_failure_cooldown_active "$now_epoch" "$last_success_epoch" "$last_attempt_epoch"; then
		return 1
	fi
	echo "[pulse-wrapper] LLM supervisor: ${pending} terminal-blocker recovery entr$([[ "$pending" -eq 1 ]] && printf 'y' || printf 'ies') pending${scan_note} (t18514)" >>"$LOGFILE"
	_pulse_write_trigger_mode "blocker_recovery" || return 1
	return 0
}

_update_backlog_snapshot() {
	local epoch="${1:-$(date +%s)}"
	local issues="${2:-0}"
	local prs="${3:-0}"
	printf '%s %s %s\n' "$epoch" "$issues" "$prs" >"${PULSE_DIR}/backlog_snapshot.txt"
	return 0
}
