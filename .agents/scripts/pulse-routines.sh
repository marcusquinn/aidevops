#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-routines.sh — Recurring routine scheduler (repeat:/run:/agent: TODO entries).
#
# Extracted from pulse-wrapper.sh in Phase 1 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _routine_last_run_epoch
#   - _routine_update_state
#   - _routine_launch_detached (systemd-run --scope escape from pulse cgroup)
#   - _routine_execute
#   - _routine_extract_section
#   - _routine_parse_line
#   - _routine_schedule_is_due
#   - evaluate_routines
#   - evaluate_routines_locked (routines.lockdir serialization, GH#35349)
#
# Keep behavioral changes in this module covered by the focused selector and
# lifecycle regression suites.

# Include guard — prevent double-sourcing. pulse-wrapper.sh sources every
# module unconditionally on start, and characterization tests re-source to
# verify idempotency.
[[ -n "${_PULSE_ROUTINES_LOADED:-}" ]] && return 0
if ! declare -F _file_mtime_epoch >/dev/null 2>&1; then
	# Detached runners source this module without the orchestrator's helpers.
	# shellcheck source=./portable-stat.sh
	source "${BASH_SOURCE[0]%/*}/portable-stat.sh" || return 1
fi
if ! declare -F _gh_secondary_cooldown_expires_at >/dev/null 2>&1; then
	# Detached runners also need the shared cooldown reset so deferred routines
	# honour GitHub's reset instead of the fixed fallback. Non-fatal: the
	# deferral path already falls back when the reset is unavailable.
	# shellcheck source=./shared-gh-secondary-cooldown.sh
	source "${BASH_SOURCE[0]%/*}/shared-gh-secondary-cooldown.sh" || true
fi
# Shared transient-scope launcher (GH#35760). Non-fatal: without it, routines
# keep the session-detach launcher.
# shellcheck source=./systemd-scope-launch.sh
source "${BASH_SOURCE[0]%/*}/systemd-scope-launch.sh" || true
_PULSE_ROUTINES_LOADED=1
_ROUTINE_STATUS_SUCCESS="success"
_ROUTINE_STATUS_FAILURE="failure"
_ROUTINE_STATUS_DEFERRED="deferred"
_ROUTINE_STATUS_RUNNING="running"
_ROUTINE_TEMPFAIL_EXIT=75

_routine_now_epoch() {
	local configured="${AIDEVOPS_ROUTINE_NOW_EPOCH:-}"
	if [[ "$configured" =~ ^[0-9]+$ ]]; then
		printf '%s' "$configured"
		return 0
	fi
	date +%s
	return 0
}

_routine_epoch_to_iso() {
	local epoch="$1"
	date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
	return $?
}

_routine_deferred_until() {
	local routine_id="$1"
	local reset_epoch=""
	local now_epoch=0
	local jitter_max="${AIDEVOPS_ROUTINE_COOLDOWN_JITTER_MAX_SECONDS:-60}"
	local fallback_seconds="${AIDEVOPS_ROUTINE_FAILURE_RETRY_SECONDS:-900}"
	local checksum=""
	local jitter=0
	now_epoch=$(_routine_now_epoch)
	reset_epoch="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
	[[ "$fallback_seconds" =~ ^[0-9]+$ ]] || fallback_seconds=900
	if ! [[ "$reset_epoch" =~ ^[0-9]+$ && "$reset_epoch" -gt "$now_epoch" ]]; then
		reset_epoch=$((now_epoch + fallback_seconds))
	fi
	[[ "$jitter_max" =~ ^[0-9]+$ ]] || jitter_max=60
	if [[ "$jitter_max" -gt 0 ]]; then
		checksum=$(printf '%s' "${routine_id}:${reset_epoch}" | cksum)
		checksum="${checksum%% *}"
		[[ "$checksum" =~ ^[0-9]+$ ]] || checksum=0
		jitter=$((checksum % (jitter_max + 1)))
	fi
	printf '%s' $((reset_epoch + jitter))
	return 0
}

#######################################
# Read last-run epoch for a routine ID from state file
# Arguments: $1 - routine ID (e.g., r001)
# Output: epoch (0 if never run)
#######################################
_routine_last_run_epoch() {
	local routine_id="$1"
	local epoch="" platform_epoch=""
	if [[ -f "$ROUTINE_STATE_FILE" ]]; then
		epoch=$(jq -r --arg id "$routine_id" '.[$id].last_run // ""' "$ROUTINE_STATE_FILE" 2>/dev/null) || epoch=""
	fi
	# Platform wrappers log to per-routine tracking state, not Pulse's state.
	# Read both successful boundaries without introducing competing writers.
	local tracking_file="${HOME}/.aidevops/.agent-workspace/cron/${routine_id}/routine-state.json"
	if [[ -f "$tracking_file" ]]; then
		platform_epoch=$(jq -r '.last_success // (if .last_status == "success" then .last_run else "" end) // ""' "$tracking_file" 2>/dev/null) || platform_epoch=""
		[[ "$platform_epoch" > "$epoch" ]] && epoch="$platform_epoch"
	fi
	if [[ -z "$epoch" ]]; then
		printf '0'
		return 0
	fi
	# Convert ISO to epoch
	local epoch_num
	epoch_num=$(date -d "$epoch" +%s 2>/dev/null) || epoch_num=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$epoch" +%s 2>/dev/null) || epoch_num=0
	printf '%s' "$epoch_num"
	return 0
}

#######################################
# Detect a launchd job that cannot start, from `launchctl list <label>` output.
# Only "cannot start" signals count: missing program, missing script path in a
# -c/-lc command, or last exit 126/127 (raw 32256/32512). Ordinary non-zero
# exits and a missing LastExitStatus (never run) still count as owned.
# systemd timers and cron entries are not checked: their units/entries are
# generated by setup against the canonical helper, so a dead legacy label
# is a launchd-specific failure mode.
# Arguments: $1 - launchctl list output
# Output: reason on stdout (empty when the job can start)
#######################################
_routine_launchd_cannot_start() {
	local info="$1"
	local program="" expect_cmd=0 first_arg=1 cmd_path=""
	local status=""
	if [[ "$info" =~ \"LastExitStatus\"[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
		status="${BASH_REMATCH[1]}"
		if [[ "$status" == "32256" || "$status" == "32512" || "$status" == "126" || "$status" == "127" ]]; then
			printf 'exit %s' $((status > 255 ? status / 256 : status))
			return 0
		fi
	fi
	if [[ "$info" =~ \"Program\"[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
		program="${BASH_REMATCH[1]}"
		if [[ ! -e "$program" ]]; then
			printf 'program %s missing' "$program"
			return 0
		fi
	fi
	local rest="" arg=""
	if [[ "$info" =~ \"ProgramArguments\"[[:space:]]*=[[:space:]]*\(([^\)]*)\) ]]; then
		rest="${BASH_REMATCH[1]}"
	fi
	while [[ "$rest" =~ \"([^\"]*)\" ]]; do
		arg="${BASH_REMATCH[1]}"
		rest="${rest#*\""$arg"\"}"
		if [[ "$expect_cmd" -eq 1 ]]; then
			# Only the command's first word (after one optional `exec`) is a
			# script path; assignments, builtins and substitutions stay owned.
			cmd_path="${arg#"${arg%%[![:space:]]*}"}"
			if [[ "$cmd_path" == exec[[:space:]]* ]]; then
				cmd_path="${cmd_path#exec}"
				cmd_path="${cmd_path#"${cmd_path%%[![:space:]]*}"}"
			fi
			cmd_path="${cmd_path%%[[:space:]]*}"
			cmd_path="${cmd_path#[\"\']}"
			cmd_path="${cmd_path%[\"\']}"
			if [[ "$cmd_path" == /* && ! -e "$cmd_path" ]]; then
				printf 'script %s missing' "$cmd_path"
				return 0
			fi
			expect_cmd=0
		elif [[ "$first_arg" -eq 1 && "$arg" == /* && -z "$program" && ! -e "$arg" ]]; then
			printf 'program %s missing' "$arg"
			return 0
		elif [[ "$arg" == "-c" || "$arg" == "-lc" ]]; then
			expect_cmd=1
		fi
		first_arg=0
	done
	return 0
}

# Only the canonical core ID/target pair can inherit platform ownership. A
# custom routine reusing a core ID must not disappear from the evaluator.
_routine_platform_owned() {
	local routine_id="$1"
	local run_command="$2"
	local target="${run_command%% *}"
	local name="" label=""
	# Accept only top-level framework scripts/binaries, not nested custom paths.
	local relative_target="${target#"${HOME}/.aidevops/agents/"}"
	case "$relative_target" in
	scripts/* | bin/*)
		[[ "${relative_target#*/}" != */* ]] || return 1
		;;
	*) return 1 ;;
	esac
	case "${routine_id}:${target##*/}" in
	r902:aidevops-auto-update)
		name=auto-update
		label=com.aidevops.aidevops-auto-update
		;;
	r903:process-guard-helper.sh) name=process-guard ;;
	r904:worker-watchdog.sh) name=worker-watchdog ;;
	r905:memory-pressure-monitor.sh) name=memory-pressure-monitor ;;
	r906:aidevops-repo-sync)
		name=repo-sync
		label=com.aidevops.aidevops-repo-sync
		;;
	r907:contribution-watch-helper.sh) name=contribution-watch ;;
	r908:profile-readme-helper.sh) name=profile-readme-update ;;
	r909:screen-time-helper.sh) name=screen-time-snapshot ;;
	r910:aidevops-skills-sync) name=skills-sync ;;
	r911:oauth-pool-helper.sh) name=token-refresh ;;
	r913:opencode-db-maintenance-helper.sh) name=opencode-db-maintenance ;;
	r914:repo-aidevops-health-helper.sh) name=repo-aidevops-health ;;
	r915:pulse-check-helper.sh) name=pulse-check ;;
	r919:mirror-sync-helper.sh) name=mirror-sync ;;
	r920:memory-audit-pulse.sh) name=memory-audit ;;
	r922:storage-cleanup-helper.sh) name=storage-hygiene ;;
	*) return 1 ;;
	esac
	label="${label:-sh.aidevops.${name}}"
	if command -v launchctl >/dev/null 2>&1; then
		local candidate="" launchd_info="" reason=""
		local candidates="$label"
		[[ "$label" == "sh.aidevops.${name}" ]] || candidates="${label} sh.aidevops.${name}"
		for candidate in $candidates; do
			launchd_info=$(launchctl list "$candidate" 2>/dev/null) || continue
			reason=$(_routine_launchd_cannot_start "$launchd_info")
			if [[ -z "$reason" ]]; then
				return 0
			fi
			# A dead job must not suppress the Pulse fallback (GH#34888).
			echo "[pulse-wrapper] routine ${routine_id}: platform job ${candidate} cannot start (${reason}); using Pulse fallback" >>"${LOGFILE:-/dev/null}"
		done
	fi
	if command -v systemctl >/dev/null 2>&1; then
		if systemctl --user is-enabled "aidevops-${name}.timer" >/dev/null 2>&1 ||
			systemctl --user is-active "aidevops-${name}.timer" >/dev/null 2>&1; then
			return 0
		fi
	fi
	if command -v crontab >/dev/null 2>&1 &&
		crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -F 'aidevops' | grep -F "${target##*/}" >/dev/null; then
		return 0
	fi
	return 1
}

#######################################
# Update routine state after execution
# Arguments:
#   $1 - routine ID
#   $2 - status (success|failure)
#######################################
_routine_update_state() {
	local routine_id="$1"
	local status="$2"
	local deferred_until="${3:-0}"
	local now_epoch=0
	local now_iso
	now_epoch=$(_routine_now_epoch)
	now_iso=$(_routine_epoch_to_iso "$now_epoch") || now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	[[ "$deferred_until" =~ ^[0-9]+$ ]] || deferred_until=0

	mkdir -p "$(dirname "$ROUTINE_STATE_FILE")" 2>/dev/null || true

	local existing="{}"
	if [[ -f "$ROUTINE_STATE_FILE" ]]; then
		existing=$(cat "$ROUTINE_STATE_FILE" 2>/dev/null) || existing="{}"
		echo "$existing" | jq empty 2>/dev/null || existing="{}"
	fi

	local tmp_file
	tmp_file=$(mktemp "$(dirname "$ROUTINE_STATE_FILE")/.routine-state.XXXXXX")
	if echo "$existing" | jq --arg id "$routine_id" --arg ts "$now_iso" --arg st "$status" \
		--arg success "$_ROUTINE_STATUS_SUCCESS" --arg deferred "$_ROUTINE_STATUS_DEFERRED" \
		--argjson deferred_until "$deferred_until" '
		.[$id] = ((.[$id] // {}) + {"last_attempt": $ts, "last_status": $st})
		| if $st == $success then .[$id].last_run = $ts else . end
		| if $st == "failure" then .[$id].consecutive_failures = ((.[$id].consecutive_failures // 0) + 1)
		  elif $st == $success then del(.[$id].consecutive_failures)
		  else . end
		| if $st == $deferred then
			.[$id].deferred_until = ([.[$id].deferred_until // 0, $deferred_until] | max)
		  else del(.[$id].deferred_until)
		  end
	' >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$ROUTINE_STATE_FILE"
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _routine_update_state: failed to write state for ${routine_id}" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Block duplicate active executions and apply an explicit failure retry
# cooldown without moving the successful calendar boundary marker.
#
# Consecutive failures back off exponentially (retry, 2x, 4x ... capped).
# Running routines are detached before Pulse dispatch, so this gate prevents
# the next cycle from launching a second runner while the first is active.
#######################################
_routine_retry_blocked() {
	local routine_id="$1"
	local retry_seconds="${AIDEVOPS_ROUTINE_FAILURE_RETRY_SECONDS:-900}"
	local retry_max_seconds="${AIDEVOPS_ROUTINE_FAILURE_RETRY_MAX_SECONDS:-21600}"
	local running_seconds="${AIDEVOPS_ROUTINE_RUNNING_TIMEOUT_SECONDS:-21600}"
	local status=""
	local attempt_iso=""
	local attempt_epoch=0
	local now_epoch=0
	local deferred_until=0
	local failures=0
	[[ "$retry_seconds" =~ ^[0-9]+$ ]] || retry_seconds=900
	[[ "$retry_max_seconds" =~ ^[0-9]+$ ]] || retry_max_seconds=21600
	[[ "$running_seconds" =~ ^[0-9]+$ ]] || running_seconds=21600
	[[ -f "$ROUTINE_STATE_FILE" ]] || return 1
	status=$(jq -r --arg id "$routine_id" '.[$id].last_status // empty' "$ROUTINE_STATE_FILE" 2>/dev/null || true)
	attempt_iso=$(jq -r --arg id "$routine_id" '.[$id].last_attempt // empty' "$ROUTINE_STATE_FILE" 2>/dev/null || true)
	[[ -n "$attempt_iso" ]] || return 1
	attempt_epoch=$(date -d "$attempt_iso" +%s 2>/dev/null) || attempt_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$attempt_iso" +%s 2>/dev/null) || return 1
	now_epoch=$(_routine_now_epoch)
	# A live runner always holds its lock while state is running, so a running
	# state without a lock (signal kill, pre-lock upgrade) is a dead runner once
	# past the 60-second launch grace.
	if [[ "$status" == "running" ]] && {
		[[ -d "${ROUTINE_STATE_FILE}.${routine_id}.runner" ]] || [[ $((now_epoch - attempt_epoch)) -ge 60 ]]
	}; then
		# Claim only dead locks older than the launch grace. This also serializes
		# recovery against detached runners and another scheduler's recovery.
		local lock_dir="${ROUTINE_STATE_FILE}.${routine_id}.runner"
		if _routine_claim_runner_lock "$lock_dir"; then
			# A finishing runner may have removed its lock since our state read.
			if ! jq -e --arg id "$routine_id" --arg ts "$attempt_iso" \
				'.[$id].last_status == "running" and .[$id].last_attempt == $ts' "$ROUTINE_STATE_FILE" >/dev/null; then
				rm -f -- "$lock_dir/pid-${BASHPID:-$$}"
				rmdir -- "$lock_dir" 2>/dev/null || true
				return 0
			fi
			_routine_finalize_terminal "$routine_id" "$_ROUTINE_STATUS_FAILURE" "$attempt_epoch" "routine-${routine_id}"
			rm -f -- "$lock_dir/pid-${BASHPID:-$$}"
			rmdir -- "$lock_dir" 2>/dev/null || true
			status="$_ROUTINE_STATUS_FAILURE"
			attempt_epoch="$now_epoch"
		else
			return 0
		fi
	fi
	case "$status" in
	running) [[ $((now_epoch - attempt_epoch)) -lt "$running_seconds" ]] ;;
	failure)
		failures=$(jq -r --arg id "$routine_id" '.[$id].consecutive_failures // 1' "$ROUTINE_STATE_FILE" 2>/dev/null || true)
		[[ "$failures" =~ ^[0-9]+$ && "$failures" -ge 1 ]] || failures=1
		while [[ "$failures" -gt 1 && "$retry_seconds" -lt "$retry_max_seconds" ]]; do
			retry_seconds=$((retry_seconds * 2))
			failures=$((failures - 1))
		done
		[[ "$retry_seconds" -le "$retry_max_seconds" || "$retry_max_seconds" -eq 0 ]] || retry_seconds="$retry_max_seconds"
		[[ $((now_epoch - attempt_epoch)) -lt "$retry_seconds" ]]
		;;
	deferred)
		deferred_until=$(jq -r --arg id "$routine_id" '.[$id].deferred_until // 0' "$ROUTINE_STATE_FILE" 2>/dev/null || true)
		[[ "$deferred_until" =~ ^[0-9]+$ && "$now_epoch" -lt "$deferred_until" ]]
		;;
	*) return 1 ;;
	esac
	return $?
}

_routine_record_lifecycle() {
	local routine_id="$1"
	local status="$2"
	local duration="$3"
	local session_key="${4:-}"
	local -a args=(update "$routine_id" --status "$status" --duration "$duration")
	[[ -z "$session_key" ]] || args+=(--session-key "$session_key")
	if [[ -x "$ROUTINE_LOG_HELPER" ]]; then
		"$ROUTINE_LOG_HELPER" "${args[@]}" 2>/dev/null || true
	fi
	return 0
}

_routine_finalize_terminal() {
	local routine_id="$1"
	local status="$2"
	local started_epoch="$3"
	local session_key="${4:-}"
	local deferred_until="${5:-0}"
	local ended_epoch=0
	local duration=0
	ended_epoch=$(date +%s)
	duration=$((ended_epoch - started_epoch))
	[[ "$duration" -ge 0 ]] || duration=0
	_routine_update_state "$routine_id" "$status" "$deferred_until"
	_routine_record_lifecycle "$routine_id" "$status" "$duration" "$session_key"
	return 0
}

#######################################
# Launch a detached routine runner outside the pulse unit cgroup (GH#33993 class).
# setsid/nohup alone stay in aidevops-supervisor-pulse.service's cgroup, so
# KillMode=control-group SIGTERMs long routines when a short event-refill wake ends.
# The backend is chosen BEFORE launching and the runner is launched exactly once:
# a fast routine exits before cgroup membership can be confirmed, so treating
# that as a failed launch would rerun it. A launch that really failed is
# recovered by the dispatched-state and runner-lock retry path.
# Args: $1=routine_id $2=runner_log $3=kind (script|agent) $4..=runner argv
#######################################
_routine_launch_detached() {
	local routine_id="$1"
	local runner_log="$2"
	local kind="$3"
	shift 3
	local runner_pid="" scope_name="" launch_result=""
	local monitor_was_enabled=false

	if declare -F systemd_scope_available >/dev/null 2>&1 && systemd_scope_available; then
		scope_name="aidevops-routine-$(printf '%s' "$routine_id" | tr -c 'A-Za-z0-9_.-' '-')-$$-${RANDOM:-0}"
		launch_result=$(systemd_scope_launch "$scope_name" "aidevops routine ${routine_id}" "$runner_log" "$@")
		echo "[pulse-wrapper] routine ${routine_id}: detached ${kind} runner pid ${launch_result%% *} isolation=${launch_result#* } unit=${scope_name}.scope" >>"$LOGFILE"
		return 0
	fi

	if command -v setsid >/dev/null 2>&1; then
		setsid nohup "$@" </dev/null >>"$runner_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	elif command -v perl >/dev/null 2>&1; then
		perl -MPOSIX -e 'POSIX::setsid() >= 0 or exit 126; exec @ARGV or exit 127' nohup "$@" \
			</dev/null >>"$runner_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	else
		# Job control gives the child its own process group even without setsid.
		[[ "$-" != *m* ]] || monitor_was_enabled=true
		set -m
		nohup "$@" </dev/null >>"$runner_log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
		[[ "$monitor_was_enabled" == true ]] || set +m
	fi
	runner_pid=$!
	disown "$runner_pid" 2>/dev/null || true
	echo "[pulse-wrapper] routine ${routine_id}: detached ${kind} runner pid ${runner_pid} isolation=session" >>"$LOGFILE"
	return 0
}

_routine_dispatch_agent() {
	local routine_id="$1"
	local module_path="${BASH_SOURCE[0]}"
	local runner_log="${LOGFILE}.routine-${routine_id}.log"
	mkdir -p "$(dirname "$ROUTINE_STATE_FILE")" || return 1
	export LOGFILE ROUTINE_STATE_FILE ROUTINE_LOG_HELPER HEADLESS_RUNTIME_HELPER
	# shellcheck disable=SC2016 # Expand positional arguments in the child.
	_routine_launch_detached "$routine_id" "$runner_log" "agent" \
		bash -c 'source "$1" && shift && _routine_run_detached_agent "$@"' \
		_ "$module_path" "$@"
	return 0
}

_routine_run_detached_agent() {
	local routine_id="$1"
	local description="$2"
	local agent_name="$3"
	local dispatch_dir="$4"
	local session_key="routine-${routine_id}"
	local started_epoch=0
	local lock_dir="${ROUTINE_STATE_FILE}.${routine_id}.runner"
	local pid_file="$lock_dir/pid-${BASHPID:-$$}"
	local exit_code=0
	local status="$_ROUTINE_STATUS_SUCCESS"
	_routine_claim_runner_lock "$lock_dir" || return 0
	[[ -n "$agent_name" ]] || agent_name="Build+"
	started_epoch=$(date +%s)
	_routine_runner_arm_traps "$routine_id" "$started_epoch" "$session_key" "$pid_file" "$lock_dir"
	_routine_update_state "$routine_id" "$_ROUTINE_STATUS_RUNNING"
	_routine_record_lifecycle "$routine_id" "$_ROUTINE_STATUS_RUNNING" 0 "$session_key"
	if [[ ! -x "$HEADLESS_RUNTIME_HELPER" ]]; then
		echo "[pulse-wrapper] routine ${routine_id}: headless runtime helper unavailable" >>"$LOGFILE"
		_ROUTINE_RUNNER_FINALIZED=true
		_routine_finalize_terminal "$routine_id" "$_ROUTINE_STATUS_FAILURE" "$started_epoch" "$session_key"
		return 1
	fi
	echo "[pulse-wrapper] routine ${routine_id}: dispatching agent '${agent_name}' for '${description}'" >>"$LOGFILE"
	# Run in the background and wait so a TERM/INT/HUP trap fires immediately.
	"$HEADLESS_RUNTIME_HELPER" run \
		--role worker \
		--session-key "$session_key" \
		--dir "$dispatch_dir" \
		--agent "$agent_name" \
		--title "Routine ${routine_id}: ${description}" \
		--prompt "Execute routine ${routine_id}: ${description}" >>"$LOGFILE" 2>&1 &
	_ROUTINE_RUNNER_CHILD_PID=$!
	wait "$_ROUTINE_RUNNER_CHILD_PID" || exit_code=$?
	_ROUTINE_RUNNER_CHILD_PID=""
	if [[ "$exit_code" -ne 0 ]]; then
		status="$_ROUTINE_STATUS_FAILURE"
		echo "[pulse-wrapper] routine ${routine_id}: agent exited with code ${exit_code}" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] routine ${routine_id}: agent completed successfully" >>"$LOGFILE"
	fi
	_ROUTINE_RUNNER_FINALIZED=true
	_routine_finalize_terminal "$routine_id" "$status" "$started_epoch" "$session_key"
	rm -f -- "$pid_file"
	rmdir -- "$lock_dir" 2>/dev/null || true
	trap - EXIT TERM INT HUP
	return 0
}

#######################################
# Detached-runner trap support. Each runner is its own process, so module
# globals carry the state the EXIT trap needs after the function frame is gone.
# An unfinalized exit (signal, unexpected error) records a terminal failure
# with the real end time, then releases the PID marker and lock.
#######################################
_ROUTINE_RUNNER_ID=""
_ROUTINE_RUNNER_STARTED=0
_ROUTINE_RUNNER_SESSION=""
_ROUTINE_RUNNER_PID_FILE=""
_ROUTINE_RUNNER_LOCK_DIR=""
_ROUTINE_RUNNER_FINALIZED=false
_ROUTINE_RUNNER_CHILD_PID=""

_routine_runner_arm_traps() {
	local routine_id="$1"
	local started_epoch="$2"
	local session_key="$3"
	local pid_file="$4"
	local lock_dir="$5"
	_ROUTINE_RUNNER_ID="$routine_id"
	_ROUTINE_RUNNER_STARTED="$started_epoch"
	_ROUTINE_RUNNER_SESSION="$session_key"
	_ROUTINE_RUNNER_PID_FILE="$pid_file"
	_ROUTINE_RUNNER_LOCK_DIR="$lock_dir"
	_ROUTINE_RUNNER_FINALIZED=false
	_ROUTINE_RUNNER_CHILD_PID=""
	trap '_routine_runner_on_exit' EXIT
	trap '_routine_runner_on_signal 143' TERM
	trap '_routine_runner_on_signal 130' INT
	trap '_routine_runner_on_signal 129' HUP
	return 0
}

_routine_runner_on_signal() {
	local code="$1"
	if [[ -n "$_ROUTINE_RUNNER_CHILD_PID" ]]; then
		kill "$_ROUTINE_RUNNER_CHILD_PID" 2>/dev/null || true
	fi
	exit "$code"
}

_routine_runner_on_exit() {
	if [[ "$_ROUTINE_RUNNER_FINALIZED" != true && -n "$_ROUTINE_RUNNER_ID" ]]; then
		_ROUTINE_RUNNER_FINALIZED=true
		_routine_finalize_terminal "$_ROUTINE_RUNNER_ID" "$_ROUTINE_STATUS_FAILURE" "$_ROUTINE_RUNNER_STARTED" "$_ROUTINE_RUNNER_SESSION"
	fi
	rm -f -- "$_ROUTINE_RUNNER_PID_FILE"
	rmdir -- "$_ROUTINE_RUNNER_LOCK_DIR" 2>/dev/null || true
	return 0
}

#######################################
# Publish an already-populated lock atomically. POSIX rename refuses to
# replace a nonempty directory, closing the mkdir-to-owner-marker race.
#######################################
_routine_acquire_runner_lock() {
	local lock_dir="$1"
	local owner_pid="${BASHPID:-$$}"
	local candidate=""
	candidate=$(mktemp -d "${lock_dir}.XXXXXX") || return 1
	if printf '%s\n' "$owner_pid" >"$candidate/pid-$owner_pid"; then
		if command -v perl >/dev/null 2>&1; then
			if perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' "$candidate" "$lock_dir"; then
				return 0
			fi
		elif mv -T -- "$candidate" "$lock_dir" 2>/dev/null; then
			# GNU mv provides the same no-directory-nesting rename semantics.
			return 0
		fi
	fi
	rm -f -- "$candidate/pid-$owner_pid"
	rmdir -- "$candidate" 2>/dev/null || true
	return 1
}

#######################################
# Claim a runner lock, reclaiming dead owners only after the launch grace.
#######################################
_routine_claim_runner_lock() {
	local lock_dir="$1"
	local owner_pid=""
	local owner_file=""
	local lock_epoch=0
	local now_epoch=0

	if [[ -e "$lock_dir" ]] || ! _routine_acquire_runner_lock "$lock_dir"; then
		for owner_file in "$lock_dir"/pid-*; do
			[[ -f "$owner_file" ]] || continue
			owner_pid="${owner_file##*/pid-}"
			if [[ ! "$owner_pid" =~ ^[1-9][0-9]*$ ]] || kill -0 "$owner_pid" 2>/dev/null; then
				return 1
			fi
		done
		lock_epoch=$(_file_mtime_epoch "$lock_dir") || lock_epoch=0
		now_epoch=$(date +%s)
		# Fail closed when age cannot be determined; allow the mkdir-to-PID gap.
		if [[ ! "$lock_epoch" =~ ^[0-9]+$ || "$lock_epoch" -eq 0 || $((now_epoch - lock_epoch)) -lt 60 ]]; then
			return 1
		fi
		# PID-specific names prevent a losing reclaimer from unlinking a new
		# owner's marker. rmdir refuses any populated replacement lock.
		[[ -z "$owner_pid" ]] || rm -f -- "$lock_dir/pid-$owner_pid"
		if ! _routine_acquire_runner_lock "$lock_dir"; then
			return 1
		fi
	fi
	return 0
}

_routine_run_detached_script() {
	local routine_id="$1"
	local script_path="$2"
	local repo_path="$3"
	shift 3
	local started_epoch="$1"
	shift
	local lock_dir="${ROUTINE_STATE_FILE}.${routine_id}.runner"
	local status="$_ROUTINE_STATUS_SUCCESS"
	local exit_code=0
	local deferred_until=0
	local pid_file="$lock_dir/pid-${BASHPID:-$$}"
	_routine_claim_runner_lock "$lock_dir" || return 0
	_routine_runner_arm_traps "$routine_id" "$started_epoch" "" "$pid_file" "$lock_dir"
	_routine_update_state "$routine_id" "$_ROUTINE_STATUS_RUNNING"
	_routine_record_lifecycle "$routine_id" "$_ROUTINE_STATUS_RUNNING" 0
	# Background + wait so a TERM/INT/HUP trap fires immediately.
	if [[ "$#" -gt 0 ]]; then
		(cd "$repo_path" && "$script_path" "$@") >>"$LOGFILE" 2>&1 &
	else
		(cd "$repo_path" && "$script_path") >>"$LOGFILE" 2>&1 &
	fi
	_ROUTINE_RUNNER_CHILD_PID=$!
	wait "$_ROUTINE_RUNNER_CHILD_PID" || exit_code=$?
	_ROUTINE_RUNNER_CHILD_PID=""
	if [[ "$exit_code" -eq "$_ROUTINE_TEMPFAIL_EXIT" ]]; then
		status="$_ROUTINE_STATUS_DEFERRED"
		deferred_until=$(_routine_deferred_until "$routine_id")
		echo "[pulse-wrapper] routine ${routine_id}: deferred by GitHub API cooldown until epoch ${deferred_until}" >>"$LOGFILE"
	elif [[ "$exit_code" -ne 0 ]]; then
		status="$_ROUTINE_STATUS_FAILURE"
		echo "[pulse-wrapper] routine ${routine_id}: script exited with code ${exit_code}" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] routine ${routine_id}: script completed successfully" >>"$LOGFILE"
	fi
	_ROUTINE_RUNNER_FINALIZED=true
	_routine_finalize_terminal "$routine_id" "$status" "$started_epoch" "" "$deferred_until"
	rm -f -- "$pid_file"
	rmdir -- "$lock_dir" 2>/dev/null || true
	trap - EXIT TERM INT HUP
	return 0
}

_routine_dispatch_script() {
	local routine_id="$1"
	local script_path="$2"
	local repo_path="$3"
	shift 3
	local started_epoch="$1"
	shift
	local module_path="${BASH_SOURCE[0]}"
	local runner_log="${LOGFILE}.routine-${routine_id}.log"

	export LOGFILE ROUTINE_STATE_FILE ROUTINE_LOG_HELPER
	# shellcheck disable=SC2016 # The child shell must expand its own positional arguments.
	_routine_launch_detached "$routine_id" "$runner_log" "script" \
		bash -c 'source "$1" && shift && _routine_run_detached_script "$@"' \
		_ "$module_path" "$routine_id" "$script_path" "$repo_path" "$started_epoch" "$@"
	return 0
}

#######################################
# Execute a single routine. Script and agent routines detach wrappers that
# record their terminal result without delaying Pulse's first dispatch pass.
#######################################
_routine_execute() {
	local routine_id="$1"
	local description="$2"
	local run_script="$3"
	local agent_name="$4"
	local repo_path="$5"
	local agents_dir="${HOME}/.aidevops/agents"
	local status="$_ROUTINE_STATUS_SUCCESS"
	local started_epoch=0
	local exit_code=0
	local deferred_until=0
	started_epoch=$(date +%s)

	if [[ -n "$run_script" ]]; then
		if [[ ! -d "$repo_path" ]]; then
			echo "[pulse-wrapper] routine ${routine_id}: repository directory not found or not a directory: ${repo_path}" >>"$LOGFILE"
			_routine_finalize_terminal "$routine_id" "$_ROUTINE_STATUS_FAILURE" "$started_epoch"
			return 1
		fi
		local run_parts=()
		IFS=' ' read -r -a run_parts <<<"$run_script"
		local script_path="${agents_dir}/${run_parts[0]}"
		# Missing host-private adapters identify non-owner hosts. Broken symlinks,
		# traversal paths and installed but non-executable adapters remain errors.
		if [[ "${run_parts[0]}" == custom/scripts/* && "${run_parts[0]}/" != */../* && ! -e "$script_path" && ! -L "$script_path" ]]; then
			echo "[pulse-wrapper] routine ${routine_id}: owner adapter not installed on this host; skipping" >>"$LOGFILE"
			# No execution occurred, so record host-local state only, not a lifecycle
			# success or failure. Preserve the last successful calendar boundary.
			_routine_update_state "$routine_id" "skipped_not_owner"
			return 0
		fi
		if [[ ! -x "$script_path" ]]; then
			echo "[pulse-wrapper] routine ${routine_id}: script not found or not executable: ${script_path}" >>"$LOGFILE"
			_routine_finalize_terminal "$routine_id" "$_ROUTINE_STATUS_FAILURE" "$started_epoch"
			return 1
		fi
		_routine_mark_dispatched "$routine_id"
		# Bash 3.2 with nounset treats expansion of an empty array as an unbound
		# variable. Keep the zero-argument path separate instead of expanding it.
		if [[ "${#run_parts[@]}" -gt 1 ]]; then
			local script_args=("${run_parts[@]:1}")
			echo "[pulse-wrapper] routine ${routine_id}: dispatching script ${script_path} ${script_args[*]}" >>"$LOGFILE"
			_routine_dispatch_script "$routine_id" "$script_path" "$repo_path" "$started_epoch" "${script_args[@]}"
		else
			echo "[pulse-wrapper] routine ${routine_id}: dispatching script ${script_path}" >>"$LOGFILE"
			_routine_dispatch_script "$routine_id" "$script_path" "$repo_path" "$started_epoch"
		fi
		return 0
	fi

	local custom_script="${agents_dir}/custom/scripts/${routine_id}.sh"
	if [[ -z "$agent_name" && -x "$custom_script" ]]; then
		if [[ ! -d "$repo_path" ]]; then
			echo "[pulse-wrapper] routine ${routine_id}: repository directory not found or not a directory: ${repo_path}" >>"$LOGFILE"
			_routine_finalize_terminal "$routine_id" "$_ROUTINE_STATUS_FAILURE" "$started_epoch"
			return 1
		fi
		echo "[pulse-wrapper] routine ${routine_id}: executing custom script ${custom_script}" >>"$LOGFILE"
		(cd "$repo_path" && "$custom_script") >>"$LOGFILE" 2>&1 || exit_code=$?
		[[ "$exit_code" -eq 0 ]] || status="$_ROUTINE_STATUS_FAILURE"
		_routine_finalize_terminal "$routine_id" "$status" "$started_epoch"
		return 0
	fi

	_routine_mark_dispatched "$routine_id"
	_routine_dispatch_agent "$routine_id" "$description" "${agent_name:-Build+}" "${repo_path:-$PULSE_DIR}"
	return $?
}

#######################################
# Record the running status before a detached runner starts (GH#35349). The runner
# rewrites the same state once it holds its lock; until then this marker makes
# _routine_retry_blocked hold every other evaluator off the slot, including one
# that starts before the runner has claimed its lock. A runner that never
# starts is reclaimed as a failure after the 60-second launch grace.
#######################################
_routine_mark_dispatched() {
	local routine_id="$1"
	_routine_update_state "$routine_id" "$_ROUTINE_STATUS_RUNNING"
	return 0
}

# Module-scope variables set by _routine_parse_line (prefixed to avoid collision).
# These are intentionally module-scope rather than nameref — avoids bash 4.3+ requirement
# for the re-exec guard fallback path, and matches the existing pattern in pulse-wrapper.sh.
_RPL_ID=""
_RPL_REPEAT=""
_RPL_RUN=""
_RPL_AGENT=""
_RPL_DESC=""
_RPL_TIMEZONE=""

#######################################
# Normalize one Markdown line before registry parsing.
#
# Fenced content is opaque, HTML comments are removed, and indented code is
# excluded. Parser state is held in _RML_* globals so updates survive the call.
#
# Arguments: $1 - raw Markdown line
# Output: none; _RML_ACTIVE_LINE and _RML_TRIMMED_LINE contain active content
# Returns: 0 for active content, 1 when the line must be ignored
#######################################
_routine_normalize_markdown_line() {
	local line="$1"
	local comment_prefix="" leading_spaces="" fence_remainder=""
	local current_fence_length=0
	_RML_ACTIVE_LINE=""
	_RML_TRIMMED_LINE=""

	if [[ -n "$_RML_FENCE_CHAR" ]]; then
		leading_spaces="${line%%[! ]*}"
		_RML_TRIMMED_LINE="${line#"$leading_spaces"}"
		if [[ "${#leading_spaces}" -le 3 && "${_RML_TRIMMED_LINE:0:1}" == "$_RML_FENCE_CHAR" ]]; then
			while [[ "${_RML_TRIMMED_LINE:${current_fence_length}:1}" == "$_RML_FENCE_CHAR" ]]; do
				current_fence_length=$((current_fence_length + 1))
			done
			fence_remainder="${_RML_TRIMMED_LINE:${current_fence_length}}"
			if [[ "$current_fence_length" -ge "$_RML_FENCE_LENGTH" && "$fence_remainder" =~ ^[[:space:]]*$ ]]; then
				_RML_FENCE_CHAR=""
				_RML_FENCE_LENGTH=0
			fi
		fi
		return 1
	fi

	_RML_ACTIVE_LINE="$line"
	while true; do
		if [[ "$_RML_IN_COMMENT" -eq 1 ]]; then
			if [[ "$_RML_ACTIVE_LINE" == *"-->"* ]]; then
				_RML_ACTIVE_LINE="${_RML_ACTIVE_LINE#*-->}"
				_RML_IN_COMMENT=0
				continue
			fi
			_RML_ACTIVE_LINE="$comment_prefix"
			break
		fi
		if [[ "$_RML_ACTIVE_LINE" == *"<!--"* ]]; then
			comment_prefix="${comment_prefix}${_RML_ACTIVE_LINE%%<!--*}"
			_RML_ACTIVE_LINE="${_RML_ACTIVE_LINE#*<!--}"
			_RML_IN_COMMENT=1
			continue
		fi
		_RML_ACTIVE_LINE="${comment_prefix}${_RML_ACTIVE_LINE}"
		break
	done

	leading_spaces="${_RML_ACTIVE_LINE%%[! ]*}"
	_RML_TRIMMED_LINE="${_RML_ACTIVE_LINE#"$leading_spaces"}"
	[[ "${#leading_spaces}" -le 3 ]] || return 1
	if [[ "$_RML_TRIMMED_LINE" == '```'* || "$_RML_TRIMMED_LINE" == '~~~'* ]]; then
		_RML_FENCE_CHAR="${_RML_TRIMMED_LINE:0:1}"
		while [[ "${_RML_TRIMMED_LINE:${_RML_FENCE_LENGTH}:1}" == "$_RML_FENCE_CHAR" ]]; do
			_RML_FENCE_LENGTH=$((_RML_FENCE_LENGTH + 1))
		done
		return 1
	fi
	return 0
}

#######################################
# Validate and advance a dedicated routines-repository subsection heading.
#
# Arguments: $1 - current phase, $2 - active heading
# Output: next phase and section-open flag, separated by a colon
# Returns: 0 for the next expected heading, 1 otherwise
#######################################
_routine_dedicated_heading_transition() {
	local current_phase="$1"
	local heading="$2"
	case "${current_phase}:${heading}" in
	"0:## Core Routines (framework-managed)") printf '1:1' ;;
	"1:## User Routines") printf '2:1' ;;
	"2:## Tasks") printf '3:0' ;;
	*) return 1 ;;
	esac
	return 0
}

#######################################
# Extract active Markdown content from one supported routine registry shape.
#
# The complete file is validated before output so duplicate headings, unclosed
# structures, or malformed dedicated layouts cannot partially dispatch. General
# TODO files use `## Routines`; the generated routines repository uses its
# controlled `# Routines` document and ordered core/user/tasks subsections.
#
# Arguments: $1 - path to TODO.md
# Output: active, non-indented lines inside the routine registry
# Returns: 0 for one supported registry, 1 for duplicate/malformed input or
#          routine-shaped lines outside any registry, 2 when the file simply
#          has no registry and no routine-shaped lines (nothing to schedule)
#######################################
_routine_extract_section() {
	local todo_file="$1"
	[[ -f "$todo_file" ]] || return 1
	local line="" section_content="" section_style="" heading_transition=""
	local dedicated_style="dedicated" project_style="project" routine_shape_re='^[-*][[:space:]]+\[[[:space:]xX]\][[:space:]]+r[^[:space:]]*[[:space:]].*repeat:'
	local in_section=0 section_count=0 structure_error=0 dedicated_phase=0 pre_registry_heading=0 stray_routine=0
	_RML_ACTIVE_LINE="" _RML_TRIMMED_LINE="" _RML_FENCE_CHAR="" _RML_FENCE_LENGTH=0 _RML_IN_COMMENT=0

	while IFS= read -r line || [[ -n "$line" ]]; do
		if ! _routine_normalize_markdown_line "$line"; then
			continue
		fi

		if [[ "$_RML_TRIMMED_LINE" =~ ^(##|#)[[:space:]]+Routines[[:space:]]*$ ]]; then
			section_count=$((section_count + 1))
			if [[ -n "$section_style" ]]; then
				structure_error=1
			elif [[ "${BASH_REMATCH[1]}" == "##" ]]; then
				section_style="$project_style"
				in_section=1
			else
				section_style="$dedicated_style"
				in_section=0
				[[ "$pre_registry_heading" -eq 0 ]] || structure_error=1
			fi
			continue
		fi

		if [[ -z "$section_style" ]] &&
			[[ "$_RML_TRIMMED_LINE" =~ ^#[[:space:]]+ || "$_RML_TRIMMED_LINE" =~ ^##[[:space:]]+ ]]; then
			pre_registry_heading=1
			continue
		fi
		[[ -z "$section_style" && "$_RML_TRIMMED_LINE" =~ $routine_shape_re ]] && stray_routine=1

		if [[ "$section_style" == "$dedicated_style" ]] &&
			[[ "$_RML_TRIMMED_LINE" =~ ^#[[:space:]]+ || "$_RML_TRIMMED_LINE" =~ ^##[[:space:]]+ ]]; then
			if heading_transition=$(_routine_dedicated_heading_transition "$dedicated_phase" "$_RML_TRIMMED_LINE"); then
				dedicated_phase="${heading_transition%%:*}"
				in_section="${heading_transition#*:}"
			else
				structure_error=1
				in_section=0
			fi
			continue
		fi

		# Level-one and level-two headings close a general-project registry.
		if [[ "$section_style" == "$project_style" ]] &&
			[[ "$_RML_TRIMMED_LINE" =~ ^#[[:space:]]+ || "$_RML_TRIMMED_LINE" =~ ^##[[:space:]]+ ]]; then
			in_section=0
			continue
		fi
		if [[ "$in_section" -eq 1 ]]; then
			section_content="${section_content}${_RML_ACTIVE_LINE}"$'\n'
		fi
	done <"$todo_file"

	if [[ "$section_style" == "$dedicated_style" && "$dedicated_phase" -ne 3 ]]; then
		structure_error=1
	fi
	# GH#34169: an absent registry is the normal state for repos without
	# routines (the default TODO template has none). Only misplaced
	# routine-shaped lines or ambiguous boundaries warrant a diagnostic.
	if [[ "$section_count" -eq 0 && "$stray_routine" -eq 0 && -z "$_RML_FENCE_CHAR" && "$_RML_IN_COMMENT" -eq 0 ]]; then
		return 2
	fi
	if [[ "$section_count" -ne 1 || "$structure_error" -ne 0 || -n "$_RML_FENCE_CHAR" || "$_RML_IN_COMMENT" -ne 0 ]]; then
		return 1
	fi
	printf '%s' "$section_content"
	return 0
}

#######################################
# Return success when a routine run target would invoke the supervisor that is
# currently evaluating routines. This protects existing generated TODO files
# that still carry the pre-GH#28544 cron-form r901 entry.
#######################################
_routine_targets_supervisor() {
	local run_script="$1"
	local run_command="${run_script%% *}"
	if [[ "$run_command" == "scripts/pulse-wrapper.sh" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Parse a single routine TODO line into its component fields.
#
# Extracts routine_id, repeat expression, run script, agent name, and
# optional timezone from a TODO.md routine line. Sets module-scope variables
# (_RPL_ID, _RPL_REPEAT, _RPL_RUN, _RPL_AGENT, _RPL_DESC, _RPL_TIMEZONE) on
# success.
#
# Arguments: $1 - a TODO.md line matching the routine pattern
# Returns: 0 if the line was successfully parsed, 1 if it should be skipped
#######################################
_routine_parse_line() {
	local line="$1"
	_RPL_ID=""
	_RPL_REPEAT=""
	_RPL_RUN=""
	_RPL_AGENT=""
	_RPL_DESC=""
	_RPL_TIMEZONE=""

	# Live routine definitions are top-level Markdown list items. Four-space
	# indentation is a code block and must not become scheduler input.
	local leading_spaces="${line%%[! ]*}"
	[[ "${#leading_spaces}" -le 3 ]] || return 1

	# Extract a stable r-prefixed routine ID immediately after [x]. IDs may be
	# numeric (r040) or descriptive (r-gh-audit-scan), but must be a complete
	# whitespace-delimited token so task prose cannot create a false match.
	local _re_routine_id='^[ ]*-[[:space:]]*\[x\][[:space:]]+(r([[:alnum:]][[:alnum:]_-]*|-[[:alnum:]][[:alnum:]_-]*))[[:space:]]'
	if [[ "$line" =~ $_re_routine_id ]]; then
		_RPL_ID="${BASH_REMATCH[1]}"
	else
		return 1
	fi

	# Extract repeat: field
	# Use a variable to hold the regex so bash does not misparse the
	# literal ')' inside the character class [^)] as the closing '))'
	# of the [[ ]] compound.  The alternation handles cron(min hr …)
	# which contains spaces inside the parentheses — a plain
	# [^[:space:]]+ regex truncates at the first space (bug t2160).
	local _re_repeat='repeat:(cron\([^)]*\)|[^[:space:]]+)'
	if [[ "$line" =~ $_re_repeat ]]; then
		_RPL_REPEAT="${BASH_REMATCH[1]}"
	else
		return 1
	fi

	# Persistent: lifecycle-managed externally (launchd/systemd/supervisor).
	# The pulse never schedules these — skip silently (bug t2175).
	if [[ "$_RPL_REPEAT" == "persistent" ]]; then
		return 1
	fi

	# Extract optional run: field — captures script path and any trailing
	# space-separated argument tokens. Field keywords (agent:, repeat:,
	# timezone:, started:, blocked-by:) always contain a colon, so we stop when
	# we encounter a token with a colon embedded.
	if [[ "$line" =~ run:([^[:space:]]+) ]]; then
		_RPL_RUN="${BASH_REMATCH[1]}"
		# Append optional argument tokens that follow the script path.
		# Stop when a token contains ':' (field keyword) or starts with '#'.
		local _run_rest="${line#*run:"${_RPL_RUN}"}"
		local _arg_token
		while [[ "$_run_rest" =~ ^[[:space:]]+([^[:space:]]+)(.*)$ ]]; do
			_arg_token="${BASH_REMATCH[1]}"
			[[ "$_arg_token" == *:* || "$_arg_token" == "#"* || "$_arg_token" == "~"* || "$_arg_token" == "@"* ]] && break
			_RPL_RUN="${_RPL_RUN} ${_arg_token}"
			_run_rest="${BASH_REMATCH[2]}"
		done
	fi

	# Extract optional agent: field
	if [[ "$line" =~ agent:([^[:space:]]+) ]]; then
		_RPL_AGENT="${BASH_REMATCH[1]}"
	fi

	# Per-routine timezone tokens are intentionally data-only. The scheduler
	# receives the value through one environment assignment, never interpolation.
	local _re_timezone='(^|[[:space:]])timezone:([^[:space:]]*)'
	local _re_timezone_token='^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9][A-Za-z0-9._+-]*)*$'
	if [[ "$line" =~ $_re_timezone ]]; then
		_RPL_TIMEZONE="${BASH_REMATCH[2]}"
		if [[ -z "$_RPL_TIMEZONE" ]] || ! [[ "$_RPL_TIMEZONE" =~ $_re_timezone_token ]]; then
			printf 'ERROR: routine %s has malformed timezone field\n' "$_RPL_ID" >&2
			_RPL_TIMEZONE=""
			return 1
		fi
	fi

	# Extract description (text between ID and first field tag).
	local description_tail="${line#*"${_RPL_ID}"}"
	_RPL_DESC=$(printf '%s' "$description_tail" | sed -E 's/^[[:space:]]*//' | sed -E 's/[[:space:]]*(repeat:|run:|agent:|timezone:|#|~|@|started:|blocked-by:).*//')

	return 0
}

#######################################
# Check one routine schedule with an optional timezone override.
# Arguments: $1 - expression, $2 - last-run epoch, $3 - timezone or empty
# Returns: schedule helper status
#######################################
_routine_schedule_is_due() {
	local expression="$1"
	local last_run_epoch="$2"
	local timezone="$3"
	local routine_id="${4:-unknown}"
	local rc=0
	if [[ -n "$timezone" ]]; then
		AIDEVOPS_SCHEDULE_TIMEZONE="$timezone" "$ROUTINE_SCHEDULE_HELPER" is-due "$expression" "$last_run_epoch" || rc=$?
	else
		"$ROUTINE_SCHEDULE_HELPER" is-due "$expression" "$last_run_epoch" || rc=$?
	fi
	if [[ "$rc" -eq 2 ]]; then
		echo "[pulse-wrapper] routine ${routine_id}: schedule '${expression}' could not be evaluated (exit 2) — not dispatched" >>"$LOGFILE"
	fi
	return "$rc"
}

#######################################
# Return whether another deferrable routine work unit may start.
#######################################
_routine_rest_core_allows_next() {
	local context="$1"
	local budget_rc=0
	if declare -F pulse_rest_core_priority_allows_next >/dev/null 2>&1; then
		pulse_rest_core_priority_allows_next deferrable "$context" || budget_rc=$?
	elif declare -F pulse_rest_core_priority_allows >/dev/null 2>&1; then
		pulse_rest_core_priority_allows deferrable || budget_rc=$?
	else
		return 0
	fi
	[[ "$budget_rc" -eq 0 ]] && return 0
	echo "[pulse-wrapper] evaluate_routines: REST-core reserve reached at ${context}; remaining routine work deferred (GH#29742)" >>"$LOGFILE"
	return 1
}

#######################################
# Evaluate the framework-managed session miner through the same deterministic
# calendar, retry, lifecycle, and REST-budget path as repository routines.
#######################################
_evaluate_session_miner_routine() {
	local routine_id="r-session-miner"
	local schedule="${AIDEVOPS_SESSION_MINER_SCHEDULE:-daily(@04:40)}"
	local last_epoch=0
	if _routine_retry_blocked "$routine_id"; then
		return 0
	fi
	last_epoch=$(_routine_last_run_epoch "$routine_id")
	if ! _routine_schedule_is_due "$schedule" "$last_epoch" "" "$routine_id"; then
		return 0
	fi
	if ! _routine_rest_core_allows_next "routine_execute:${routine_id}"; then
		return 0
	fi
	echo "[pulse-wrapper] routine ${routine_id} is due (expr=${schedule}, last_run_epoch=${last_epoch})" >>"$LOGFILE"
	_routine_execute "$routine_id" "Incremental session insight mining" \
		"scripts/session-miner-pulse.sh --create-issues" "" "$PULSE_DIR"
	return $?
}

#######################################
# Evaluate the framework-managed issue/PR discussion archive (t18571). One
# pulse host is the single writer; the helper itself selects pulse-enabled
# registered repos and honours the per-repo `issue_archive: false` opt-out.
# AIDEVOPS_ISSUE_ARCHIVE_ENABLED=0 disables the routine on this host.
#######################################
_evaluate_issue_archive_routine() {
	local routine_id="r-issue-archive"
	local schedule="${AIDEVOPS_ISSUE_ARCHIVE_SCHEDULE:-daily(@05:20)}"
	local last_epoch=0
	if [[ "${AIDEVOPS_ISSUE_ARCHIVE_ENABLED:-1}" == "0" ]]; then
		return 0
	fi
	if _routine_retry_blocked "$routine_id"; then
		return 0
	fi
	last_epoch=$(_routine_last_run_epoch "$routine_id")
	if ! _routine_schedule_is_due "$schedule" "$last_epoch" "" "$routine_id"; then
		return 0
	fi
	if ! _routine_rest_core_allows_next "routine_execute:${routine_id}"; then
		return 0
	fi
	echo "[pulse-wrapper] routine ${routine_id} is due (expr=${schedule}, last_run_epoch=${last_epoch})" >>"$LOGFILE"
	_routine_execute "$routine_id" "Archive issue and PR discussions to orphan branch" \
		"scripts/issue-archive-helper.sh run" "" "$PULSE_DIR"
	return $?
}

#######################################
# Evaluate routines across all pulse-enabled repos
#
# Reads TODO.md from each pulse-enabled repo, extracts enabled routines
# ([x] lines with repeat: fields), checks if due, and dispatches.
#######################################
evaluate_routines() {
	local publication_worker="${SCRIPT_DIR}/task-publication-worker-helper.sh"
	local run_publication=1
	# Busy-lock passes (GH#35349) run every scheduler tick; they evaluate
	# calendar slots only and leave the publication worker to full cycles.
	[[ "${1:-}" != "--skip-publication" ]] || run_publication=0
	if [[ "$run_publication" -eq 1 && -x "$publication_worker" ]]; then
		if ! _routine_rest_core_allows_next "routine_publication_worker"; then
			return 0
		fi
		"$publication_worker" run >>"$LOGFILE" 2>&1 || echo "[pulse-wrapper] publication worker pass failed" >>"$LOGFILE"
	fi
	if [[ ! -x "$ROUTINE_SCHEDULE_HELPER" ]]; then
		echo "[pulse-wrapper] evaluate_routines: schedule helper not found at ${ROUTINE_SCHEDULE_HELPER} — skipping" >>"$LOGFILE"
		return 0
	fi

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		echo "[pulse-wrapper] evaluate_routines: repos.json not found — skipping" >>"$LOGFILE"
		return 0
	fi
	_evaluate_session_miner_routine
	_evaluate_issue_archive_routine

	local routines_dispatched=0
	local _routine_slug repo_path

	while IFS='|' read -r _routine_slug repo_path; do
		[[ -z "$repo_path" ]] && continue
		local todo_file="${repo_path}/TODO.md"
		[[ -f "$todo_file" ]] || continue

		# Validate and buffer the complete canonical Markdown section before any
		# routine dispatch. This prevents fenced examples, other TODO sections,
		# and malformed/duplicate boundaries from becoming scheduler input.
		local routine_section="" extract_rc=0
		routine_section=$(_routine_extract_section "$todo_file") || extract_rc=$?
		if [[ "$extract_rc" -eq 2 ]]; then
			# No registry and no routine-shaped lines: nothing to schedule (GH#34169).
			continue
		elif [[ "$extract_rc" -ne 0 ]]; then
			echo "[pulse-wrapper] evaluate_routines: ${_routine_slug} TODO.md has a duplicate or malformed routines registry, or routine lines outside it — skipping" >>"$LOGFILE"
			continue
		fi

		local line
		while IFS= read -r line; do
			if ! _routine_parse_line "$line"; then
				continue
			fi

			# The supervisor is launched by launchd/systemd and must never be
			# invoked synchronously from its own evaluator. Keep this runtime
			# guard for stale generated TODO files that predate GH#28544.
			if _routine_targets_supervisor "$_RPL_RUN"; then
				echo "[pulse-wrapper] routine ${_RPL_ID}: skipping self-recursive supervisor target ${_RPL_RUN%% *} (GH#28544)" >>"$LOGFILE"
				continue
			fi
			if _routine_platform_owned "$_RPL_ID" "$_RPL_RUN"; then
				echo "[pulse-wrapper] routine ${_RPL_ID}: skipping platform-owned routine" >>"$LOGFILE"
				continue
			fi

			# Active runs and recent failures have their own bounded retry policy;
			# only successful runs advance the calendar boundary marker.
			if _routine_retry_blocked "$_RPL_ID"; then
				continue
			fi

			# Check if due
			local last_epoch
			local timezone_context=""
			last_epoch=$(_routine_last_run_epoch "$_RPL_ID")
			timezone_context="${_RPL_TIMEZONE:-inherited}"

			if _routine_schedule_is_due "$_RPL_REPEAT" "$last_epoch" "$_RPL_TIMEZONE" "$_RPL_ID"; then
				if ! _routine_rest_core_allows_next "routine_execute:${_RPL_ID}"; then
					return 0
				fi
				echo "[pulse-wrapper] routine ${_RPL_ID} is due (expr=${_RPL_REPEAT}, timezone=${timezone_context}, last_run_epoch=${last_epoch})" >>"$LOGFILE"
				_routine_execute "$_RPL_ID" "$_RPL_DESC" "$_RPL_RUN" "$_RPL_AGENT" "$repo_path"
				routines_dispatched=$((routines_dispatched + 1))
			fi
		done <<<"$routine_section"

	# Routine evaluation only reads TODO.md and runs local scripts/agents;
	# unlike code-automation dispatch it needs no GitHub remote, so
	# local_only repos (e.g. a private routines-only repo created via
	# init-routines-helper.sh --local) must still be evaluated here.
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true) | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || true)

	if [[ "$routines_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] evaluate_routines: dispatched ${routines_dispatched} routine(s)" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Run evaluate_routines under the dedicated routines.lockdir (GH#35349).
#
# Routines are evaluated by the full cycle (backstop) and by routines-only
# passes that run while another process holds the Pulse instance lock. This
# lock serializes those evaluators. It lives beside ROUTINE_STATE_FILE, so
# hosts that share routine state also share it. A live holder means another
# evaluator is already handling the due slots: skip rather than wait. Dead
# holders are reclaimed after the launch grace (_routine_claim_runner_lock).
#
# Arguments: passed through to evaluate_routines
#######################################
evaluate_routines_locked() {
	local lock_dir="${ROUTINE_EVALUATOR_LOCKDIR:-${ROUTINE_STATE_FILE%/*}/routines.lockdir}"
	local owner_file=""
	local rc=0
	mkdir -p "${lock_dir%/*}" 2>/dev/null || true
	if ! _routine_claim_runner_lock "$lock_dir"; then
		echo "[pulse-wrapper] evaluate_routines: another evaluator holds ${lock_dir##*/}; skipping this pass (GH#35349)" >>"$LOGFILE"
		return 0
	fi
	owner_file="${lock_dir}/pid-${BASHPID:-$$}"
	evaluate_routines "$@" || rc=$?
	rm -f -- "$owner_file"
	rmdir -- "$lock_dir" 2>/dev/null || true
	return "$rc"
}
