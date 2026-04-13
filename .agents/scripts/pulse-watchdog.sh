#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-watchdog.sh — Pulse watchdog — child-process guard, per-command/stage timeouts, progress/idle checks, watchdog runner.
#
# Extracted from pulse-wrapper.sh in Phase 3 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants and mutable
# _PULSE_HEALTH_* counters in the bootstrap section.
#
# Functions in this module (in source order):
#   - guard_child_processes
#   - run_cmd_with_timeout
#   - run_stage_with_timeout
#   - _watchdog_check_progress
#   - _watchdog_check_idle
#   - _check_watchdog_conditions
#   - _run_pulse_watchdog
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_WATCHDOG_LOADED:-}" ]] && return 0
_PULSE_WATCHDOG_LOADED=1

#######################################
# Process guard: kill child processes exceeding RSS or runtime limits (t1398)
#
# Scans all child processes of the current pulse (and their descendants)
# for resource violations. ShellCheck processes get stricter limits due
# to their known exponential expansion risk (see t1398.2).
#
# This is a secondary defense — the primary defense is the hardened
# ShellCheck invocation (no -x, --norc, per-file timeout, ulimit -v).
# This guard catches any ShellCheck process that escapes those limits.
#
# Called from the watchdog loop inside run_pulse() every 60s.
#
# Arguments:
#   $1 - (optional) PID of the primary pulse process to exempt from
#        CHILD_RUNTIME_LIMIT (governed by PULSE_STALE_THRESHOLD instead)
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
guard_child_processes() {
	local pulse_pid="${1:-}"
	local killed=0
	local total_freed_mb=0

	# Get all descendant PIDs of the current shell process.
	# Use 'command' (full command line) instead of 'comm' (basename only)
	# so that patterns like 'node.*opencode' can match. (CodeRabbit review)
	local descendants
	descendants=$(ps -eo pid,ppid,rss,etime,command | awk -v parent=$$ '
		BEGIN { pids[parent]=1 }
		{ if ($2 in pids) { pids[$1]=1; print $0 } }
	') || return 0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue

		# Fields from ps -eo pid,ppid,rss,etime,command
		# command is last and may contain spaces — read captures the rest
		local pid _ppid rss etime cmd_full
		read -r pid _ppid rss etime cmd_full <<<"$line"

		# Validate numeric fields
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0

		local age_seconds
		age_seconds=$(_get_process_age "$pid")

		# Extract basename for limit selection (e.g., /usr/bin/shellcheck → shellcheck)
		local cmd_base="${cmd_full%% *}"
		cmd_base="${cmd_base##*/}"

		# Determine limits: ShellCheck gets stricter limits
		local rss_limit="$CHILD_RSS_LIMIT_KB"
		local runtime_limit="$CHILD_RUNTIME_LIMIT"
		if [[ "$cmd_base" == "shellcheck" ]]; then
			rss_limit="$SHELLCHECK_RSS_LIMIT_KB"
			runtime_limit="$SHELLCHECK_RUNTIME_LIMIT"
		fi

		local violation=""
		if [[ "$rss" -gt "$rss_limit" ]]; then
			local rss_mb=$((rss / 1024))
			local limit_mb=$((rss_limit / 1024))
			violation="RSS ${rss_mb}MB > ${limit_mb}MB limit"
		elif [[ -n "$pulse_pid" && "$pid" == "$pulse_pid" ]]; then
			# Primary pulse process — runtime governed by PULSE_STALE_THRESHOLD,
			# not CHILD_RUNTIME_LIMIT. Skip runtime check but keep RSS check.
			:
		elif [[ "$age_seconds" -gt "$runtime_limit" ]]; then
			violation="runtime ${age_seconds}s > ${runtime_limit}s limit"
		fi

		if [[ -n "$violation" ]]; then
			local rss_mb=$((rss / 1024))
			# Sanitise cmd_base before logging to prevent log injection via
			# crafted process names containing control characters. (GH#2892)
			local safe_cmd_base
			safe_cmd_base=$(_sanitize_log_field "$cmd_base")
			echo "[pulse-wrapper] Process guard: killing PID $pid ($safe_cmd_base) — $violation" >>"$LOGFILE"
			_kill_tree "$pid" || true
			sleep 1
			if kill -0 "$pid" 2>/dev/null; then
				_force_kill_tree "$pid" || true
			fi
			killed=$((killed + 1))
			total_freed_mb=$((total_freed_mb + rss_mb))
		fi
	done <<<"$descendants"

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Process guard: killed $killed process(es), freed ~${total_freed_mb}MB" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Run a command with a per-call timeout (t1482)
#
# Lighter than run_stage_with_timeout — no logging, no stage semantics.
# Designed for sub-helpers inside prefetch_state that can hang on gh API
# calls. Kills the entire process group on timeout.
#
# Arguments:
#   $1 - timeout in seconds
#   $2..N - command and arguments
#
# Returns:
#   0   - command completed successfully
#   124 - command timed out and was killed
#   else- command exit code
#######################################
run_cmd_with_timeout() {
	local timeout_secs="$1"
	shift
	[[ "$timeout_secs" =~ ^[0-9]+$ ]] || timeout_secs=60

	"$@" &
	local cmd_pid=$!

	local elapsed=0
	while kill -0 "$cmd_pid" 2>/dev/null; do
		if [[ "$elapsed" -ge "$timeout_secs" ]]; then
			_kill_tree "$cmd_pid" || true
			sleep 1
			if kill -0 "$cmd_pid" 2>/dev/null; then
				_force_kill_tree "$cmd_pid" || true
			fi
			wait "$cmd_pid" 2>/dev/null || true
			return 124
		fi
		sleep 2
		elapsed=$((elapsed + 2))
	done

	wait "$cmd_pid"
	return $?
}

#######################################
# Run a stage with a wall-clock timeout
#
# Arguments:
#   $1 - stage name (for logs)
#   $2 - timeout seconds
#   $3... - command/function to execute
#
# Exit codes:
#   0   - stage completed successfully
#   124 - stage timed out and was killed
#   else- stage exited with command exit code
#######################################
run_stage_with_timeout() {
	local stage_name="$1"
	local timeout_seconds="$2"
	shift 2

	if [[ -z "$stage_name" ]] || [[ "$#" -lt 1 ]]; then
		echo "[pulse-wrapper] run_stage_with_timeout: invalid arguments" >>"$LOGFILE"
		return 1
	fi
	[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds="$PRE_RUN_STAGE_TIMEOUT"
	if [[ "$timeout_seconds" -lt 1 ]]; then
		timeout_seconds=1
	fi

	local stage_start
	stage_start=$(date +%s)
	echo "[pulse-wrapper] Stage start: ${stage_name} (timeout ${timeout_seconds}s)" >>"$LOGFILE"

	"$@" &
	local stage_pid=$!

	while kill -0 "$stage_pid" 2>/dev/null; do
		local now
		now=$(date +%s)
		local elapsed=$((now - stage_start))
		if [[ "$elapsed" -gt "$timeout_seconds" ]]; then
			echo "[pulse-wrapper] Stage timeout: ${stage_name} exceeded ${timeout_seconds}s (pid ${stage_pid})" >>"$LOGFILE"
			_kill_tree "$stage_pid" || true
			sleep 2
			if kill -0 "$stage_pid" 2>/dev/null; then
				_force_kill_tree "$stage_pid" || true
			fi
			wait "$stage_pid" 2>/dev/null || true
			return 124
		fi
		sleep 2
	done

	wait "$stage_pid"
	local stage_status=$?
	if [[ "$stage_status" -ne 0 ]]; then
		echo "[pulse-wrapper] Stage failed: ${stage_name} exited with ${stage_status}" >>"$LOGFILE"
		return "$stage_status"
	fi

	local stage_end
	stage_end=$(date +%s)
	echo "[pulse-wrapper] Stage complete: ${stage_name} (${stage_status}, $((stage_end - stage_start))s)" >>"$LOGFILE"
	return 0
}

#######################################
# Run the pulse — with internal watchdog timeout (t1397, t1398, t1398.3, GH#2958)
#
# The pulse runs until opencode exits naturally. A watchdog loop checks
# every 60s for three termination conditions:
#
#   1. Wall-clock timeout (t1397): kills if elapsed > PULSE_STALE_THRESHOLD.
#      This is the hard ceiling — no pulse should ever run longer than this.
#      Raised to 60 min (from 30 min) because quality sweeps across 8+ repos
#      legitimately need more time (GH#2958).
#
#   2. Idle detection (t1398.3): tracks consecutive seconds where the
#      process tree's CPU usage is below PULSE_IDLE_CPU_THRESHOLD. When
#      idle time exceeds PULSE_IDLE_TIMEOUT, the process is killed. This
#      catches the opencode idle-state bug much faster than the wall-clock
#      timeout — typically within 5 minutes of the pulse completing, vs
#      60 minutes for the stale threshold.
#
#   3. Progress detection (GH#2958): tracks whether the log file is growing.
#      If the log file size hasn't changed for PULSE_PROGRESS_TIMEOUT seconds,
#      the process is stuck — producing no output despite running. This catches
#      cases where CPU is nonzero (network I/O wait, spinning) but no actual
#      work is being done. Resets whenever new output appears.
#
# The watchdog also runs guard_child_processes() every 60s to kill any
# child process exceeding RSS or runtime limits (t1398).
#
# Previous design relied on the NEXT launchd invocation's check_dedup()
# to kill stale processes. This failed because launchd StartInterval only
# fires when the previous invocation has exited — and the wrapper blocks
# on `wait`, so the next invocation never starts. The watchdog is now
# internal to the same process that spawned opencode.
#######################################
#######################################
# Check watchdog termination conditions for a single poll iteration (GH#5627)
#
# Evaluates stop flag, wall-clock, progress, and idle conditions.
# Returns the kill reason via stdout (empty if no kill needed).
#
# Arguments (positional — avoids associative arrays for bash 3.2):
#   $1 - opencode_pid
#   $2 - start_epoch
#   $3 - effective_cold_start_timeout
#   $4 - last_log_size (current value)
#   $5 - progress_stall_seconds (current value)
#   $6 - has_seen_progress ("true" or "false")
#   $7 - idle_seconds (current value)
#
# Outputs (3 lines to stdout, read by caller):
#   Line 1: kill_reason (empty string if none)
#   Line 2: updated last_log_size
#   Line 3: updated progress_stall_seconds
#   Line 4: updated has_seen_progress
#   Line 5: updated idle_seconds
#######################################
#######################################
# Check log progress and detect stalls (GH#2958).
# Updates WD_LAST_LOG_SIZE, WD_PROGRESS_STALL_SECONDS,
# WD_HAS_SEEN_PROGRESS, WD_KILL_REASON via dynamic scoping.
# Arguments: $1=effective_cold_start_timeout
#######################################
_watchdog_check_progress() {
	local effective_cold_start_timeout="$1"

	local current_log_size=0
	if [[ -f "$LOGFILE" ]]; then
		current_log_size=$(wc -c <"$LOGFILE" 2>/dev/null || echo "0")
		current_log_size="${current_log_size// /}"
	fi
	[[ "$current_log_size" =~ ^[0-9]+$ ]] || current_log_size=0

	# Log grew — process is making progress
	if [[ "$current_log_size" -gt "$WD_LAST_LOG_SIZE" ]]; then
		WD_HAS_SEEN_PROGRESS=true
		if [[ "$WD_PROGRESS_STALL_SECONDS" -gt 0 ]]; then
			echo "[pulse-wrapper] Progress resumed after ${WD_PROGRESS_STALL_SECONDS}s stall (log grew by $((current_log_size - WD_LAST_LOG_SIZE)) bytes)" >>"$LOGFILE"
		fi
		WD_LAST_LOG_SIZE="$current_log_size"
		WD_PROGRESS_STALL_SECONDS=0
		return 0
	fi

	# Log hasn't grown — increment stall counter
	WD_PROGRESS_STALL_SECONDS=$((WD_PROGRESS_STALL_SECONDS + 60))
	local progress_timeout="$PULSE_PROGRESS_TIMEOUT"
	if [[ "$WD_HAS_SEEN_PROGRESS" == false ]]; then
		progress_timeout="$effective_cold_start_timeout"
	fi

	if [[ "$WD_PROGRESS_STALL_SECONDS" -lt "$progress_timeout" ]]; then
		return 0
	fi

	if [[ "$WD_HAS_SEEN_PROGRESS" == false ]]; then
		WD_KILL_REASON="Pulse cold-start stalled for ${WD_PROGRESS_STALL_SECONDS}s — no first output (log size: ${current_log_size} bytes, threshold: ${effective_cold_start_timeout}s)"
	else
		WD_KILL_REASON="Pulse stalled for ${WD_PROGRESS_STALL_SECONDS}s — no log output (log size: ${current_log_size} bytes, threshold: ${PULSE_PROGRESS_TIMEOUT}s) (GH#2958)"
	fi
	return 0
}

#######################################
# Check CPU idle detection (t1398.3).
# Updates WD_IDLE_SECONDS, WD_KILL_REASON via dynamic scoping.
# Arguments: $1=opencode_pid
#######################################
_watchdog_check_idle() {
	local opencode_pid="$1"

	if [[ "$WD_HAS_SEEN_PROGRESS" != true ]]; then
		WD_IDLE_SECONDS=0
		return 0
	fi

	local tree_cpu
	tree_cpu=$(_get_process_tree_cpu "$opencode_pid")

	# Process is active — reset idle counter
	if [[ "$tree_cpu" -ge "$PULSE_IDLE_CPU_THRESHOLD" ]]; then
		if [[ "$WD_IDLE_SECONDS" -gt 0 ]]; then
			echo "[pulse-wrapper] Pulse active again (CPU ${tree_cpu}%) after ${WD_IDLE_SECONDS}s idle — resetting idle counter" >>"$LOGFILE"
		fi
		WD_IDLE_SECONDS=0
		return 0
	fi

	WD_IDLE_SECONDS=$((WD_IDLE_SECONDS + 60))
	if [[ "$WD_IDLE_SECONDS" -ge "$PULSE_IDLE_TIMEOUT" ]]; then
		WD_KILL_REASON="Pulse idle for ${WD_IDLE_SECONDS}s (CPU ${tree_cpu}% < ${PULSE_IDLE_CPU_THRESHOLD}%, threshold ${PULSE_IDLE_TIMEOUT}s) (t1398.3)"
	fi
	return 0
}

_check_watchdog_conditions() {
	local opencode_pid="$1"
	local start_epoch="$2"
	local effective_cold_start_timeout="$3"
	local last_log_size="$4"
	local progress_stall_seconds="$5"
	local has_seen_progress="$6"
	local idle_seconds="$7"

	local now
	now=$(date +%s)
	local elapsed=$((now - start_epoch))

	# Use WD_ prefixed vars for dynamic scoping with sub-helpers
	WD_KILL_REASON=""
	WD_LAST_LOG_SIZE="$last_log_size"
	WD_PROGRESS_STALL_SECONDS="$progress_stall_seconds"
	WD_HAS_SEEN_PROGRESS="$has_seen_progress"
	WD_IDLE_SECONDS="$idle_seconds"

	# Check 0: Stop flag — user ran `aidevops pulse stop` during this cycle (t2943)
	if [[ -f "$STOP_FLAG" ]]; then
		WD_KILL_REASON="Stop flag detected during active pulse — user requested stop"
	# Check 1: Wall-clock stale threshold (hard ceiling)
	elif [[ "$elapsed" -gt "$PULSE_STALE_THRESHOLD" ]]; then
		WD_KILL_REASON="Pulse exceeded stale threshold (${elapsed}s > ${PULSE_STALE_THRESHOLD}s)"
	# Skip checks 2 and 3 during the first 3 minutes to allow startup/init.
	elif [[ "$elapsed" -ge 180 ]]; then
		_watchdog_check_progress "$effective_cold_start_timeout"
		if [[ -z "$WD_KILL_REASON" ]]; then
			_watchdog_check_idle "$opencode_pid"
		fi
	fi

	# Output updated state (one value per line for caller to read)
	echo "$WD_KILL_REASON"
	echo "$WD_LAST_LOG_SIZE"
	echo "$WD_PROGRESS_STALL_SECONDS"
	echo "$WD_HAS_SEEN_PROGRESS"
	echo "$WD_IDLE_SECONDS"
	return 0
}

#######################################
# Run the pulse watchdog loop (GH#5627, extracted from run_pulse)
#
# Polls every 60s for termination conditions and resource violations.
# Kills the pulse process when any condition triggers.
#
# Arguments:
#   $1 - opencode_pid
#   $2 - start_epoch
#   $3 - effective_cold_start_timeout
#######################################
_run_pulse_watchdog() {
	local opencode_pid="$1"
	local start_epoch="$2"
	local effective_cold_start_timeout="$3"
	local last_active_refill_epoch=0

	# Idle detection state (t1398.3)
	local idle_seconds=0

	# Progress detection state (GH#2958)
	local last_log_size=0
	local progress_stall_seconds=0
	local has_seen_progress=false
	if [[ -f "$LOGFILE" ]]; then
		last_log_size=$(wc -c <"$LOGFILE" 2>/dev/null || echo "0")
		last_log_size="${last_log_size// /}"
	fi

	while ps -p "$opencode_pid" >/dev/null; do
		# Read watchdog state from the check function.
		# _check_watchdog_conditions outputs 5 lines; we read them back.
		# This avoids subshell variable scoping issues while keeping the
		# check logic in a testable function.
		local watchdog_output
		watchdog_output=$(_check_watchdog_conditions "$opencode_pid" "$start_epoch" \
			"$effective_cold_start_timeout" "$last_log_size" "$progress_stall_seconds" \
			"$has_seen_progress" "$idle_seconds")

		local kill_reason
		kill_reason=$(echo "$watchdog_output" | sed -n '1p')
		last_log_size=$(echo "$watchdog_output" | sed -n '2p')
		progress_stall_seconds=$(echo "$watchdog_output" | sed -n '3p')
		has_seen_progress=$(echo "$watchdog_output" | sed -n '4p')
		idle_seconds=$(echo "$watchdog_output" | sed -n '5p')

		# Single kill block — avoids duplicating the kill+force-kill sequence.
		if [[ -n "$kill_reason" ]]; then
			echo "[pulse-wrapper] ${kill_reason} — killing" >>"$LOGFILE"
			_kill_tree "$opencode_pid" || true
			sleep 2
			if kill -0 "$opencode_pid" 2>/dev/null; then
				_force_kill_tree "$opencode_pid" || true
			fi
			break
		fi

		# Process guard: kill children exceeding RSS/runtime limits (t1398)
		guard_child_processes "$opencode_pid"

		if [[ -z "$kill_reason" ]]; then
			last_active_refill_epoch=$(maybe_refill_underfilled_pool_during_active_pulse \
				"$last_active_refill_epoch" "$progress_stall_seconds" "$idle_seconds" "$has_seen_progress")
		fi
		# Sleep 60s then re-check. Portable across bash 3.2+ (macOS default).
		sleep 60
	done

	# Reap the process (may already be dead)
	wait "$opencode_pid" 2>/dev/null || true
	return 0
}
