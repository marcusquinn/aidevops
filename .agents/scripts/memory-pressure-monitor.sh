#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# memory-pressure-monitor.sh — Process-focused memory pressure monitor
#
# Monitors aidevops process health: individual RSS, process runtime, process count.
# This is the RIGHT signal — the March 3 kernel panic was caused by aidevops
# processes (ShellCheck at 5.7 GB, zombie pulses, session accumulation), not by
# generic OS memory pressure.
#
# Process classification (GH#2992):
#   - "App" processes (Claude, Electron, ShipIt, OpenCode): long-running by design.
#     Runtime alerts are skipped — only RSS is monitored. These processes run for
#     hours/days and runtime warnings are 100% false positives (~5,400/day noise).
#   - "Tool" processes (shellcheck, language servers, node workers): short-lived.
#     Both RSS and runtime alerts are active.
#
# Auto-kill (GH#2915): ShellCheck processes that hit CRITICAL RSS or exceed
# runtime limits are automatically killed. This is safe because the bash
# language server respawns them. The root cause (source-path=SCRIPTDIR in
# .shellcheckrc causing recursive expansion) has been removed — SC1091 is
# now globally disabled instead. This monitor remains as defense-in-depth.
#
# The primary defense is now shellcheck-wrapper.sh which has a background
# RSS watchdog (kills at 1 GB) and respawn rate limiting (exponential backoff).
# This monitor is the secondary safety net with higher thresholds (2 GB).
#
# kern.memorystatus_level is a secondary/informational signal only. macOS runs
# fine with compression + swap; aggressive thresholds on that metric cause false
# alarms. The primary signals are process-level.
#
# Usage:
#   memory-pressure-monitor.sh              # Single check (for launchd)
#   memory-pressure-monitor.sh --status     # Print current process + memory state
#   memory-pressure-monitor.sh --daemon     # Continuous monitoring (60s interval)
#   memory-pressure-monitor.sh --stop       # Stop a running daemon
#   memory-pressure-monitor.sh --restart    # Stop existing daemon and start a new one
#   memory-pressure-monitor.sh --install    # Install launchd plist
#   memory-pressure-monitor.sh --uninstall  # Remove launchd plist and state files
#   memory-pressure-monitor.sh --help       # Show usage
#
# Process-level thresholds (primary signals):
#   RSS per process:  > 1 GB  → warning, > 2 GB → critical (kill candidate)
#   Runtime (tools):  > 5 min for shellcheck, > 30 min for other tools
#   Runtime (apps):   skipped — long-running by design
#   Session count:    > 8 concurrent interactive sessions → warning
#   Total aidevops:   > 8 GB aggregate RSS → warning
#
# OS-level thresholds (secondary, informational only):
#   kern.memorystatus_level: logged but NOT used for alerts (too noisy)
#   Swap file count:  > 10 → informational warning
#
# Environment:
#   PROCESS_RSS_WARN_MB       Per-process RSS warning (default: 1024)
#   PROCESS_RSS_CRIT_MB       Per-process RSS critical (default: 2048)
#   SHELLCHECK_RUNTIME_MAX    ShellCheck max runtime in seconds (default: 300)
#   TOOL_RUNTIME_MAX          Other tool max runtime in seconds (default: 1800)
#   SESSION_COUNT_WARN        Interactive session warning threshold (default: 8)
#   AGGREGATE_RSS_WARN_MB     Total aidevops RSS warning (default: 8192)
#   AUTO_KILL_SHELLCHECK       Auto-kill runaway ShellCheck (default: true)
#   MEMORY_COOLDOWN_SECS      Notification cooldown per category (default: 300)
#   MEMORY_NOTIFY             Set to "false" to disable notifications (log only)
#   MEMORY_LOG_DIR            Override log directory

set -euo pipefail

# --- Configuration -----------------------------------------------------------

readonly SCRIPT_NAME="memory-pressure-monitor"
readonly SCRIPT_VERSION="2.1.0"

# Per-process RSS thresholds (MB)
# Lowered from 2048/4096 after Mar 7 crash: shellcheck grew to 18.5 GB in <60s.
# The wrapper's watchdog kills at 1 GB; these are the secondary safety net.
PROCESS_RSS_WARN_MB="${PROCESS_RSS_WARN_MB:-1024}"
PROCESS_RSS_CRIT_MB="${PROCESS_RSS_CRIT_MB:-2048}"

# Runtime thresholds (seconds)
# Lowered shellcheck from 600s to 300s — wrapper has 120s hard timeout,
# so any shellcheck surviving 5 min has bypassed the wrapper.
SHELLCHECK_RUNTIME_MAX="${SHELLCHECK_RUNTIME_MAX:-300}" # 5 min
TOOL_RUNTIME_MAX="${TOOL_RUNTIME_MAX:-1800}"            # 30 min

# Session/aggregate thresholds
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-8}"
AGGREGATE_RSS_WARN_MB="${AGGREGATE_RSS_WARN_MB:-8192}" # 8 GB total

# Auto-kill: ShellCheck processes are safe to kill (language server respawns them)
readonly AUTO_KILL_SHELLCHECK="${AUTO_KILL_SHELLCHECK:-true}"

# Notification — COOLDOWN_SECS and DAEMON_INTERVAL validated below with _validate_int
COOLDOWN_SECS="${MEMORY_COOLDOWN_SECS:-300}"
readonly NOTIFY_ENABLED="${MEMORY_NOTIFY:-false}"
DAEMON_INTERVAL="${MEMORY_DAEMON_INTERVAL:-60}"

# Paths
readonly LOG_DIR="${MEMORY_LOG_DIR:-${HOME}/.aidevops/logs}"
readonly LOG_FILE="${LOG_DIR}/memory-pressure.log"
readonly STATE_DIR="${HOME}/.aidevops/.agent-workspace/tmp"

readonly LAUNCHD_LABEL="sh.aidevops.memory-pressure-monitor"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

# Process name patterns to monitor (aidevops ecosystem)
# These are the processes that caused the March 3 kernel panic
readonly MONITORED_PATTERNS=(
	"opencode"
	"claude"
	"shellcheck"
	"node.*language-server"
	"typescript-language-server"
	"bash-language-server"
)

# App processes: long-running by design, runtime alerts are false positives (GH#2992).
# Only RSS is monitored for these. Matched against the short command name (basename).
# Case-insensitive matching via _is_app_process().
readonly APP_PROCESS_NAMES=(
	"claude"
	"electron"
	"shipit"
	"opencode"
)

# --- Validation ---------------------------------------------------------------

# Validate numeric configuration — prevent command injection via $(( )) expansion.
_validate_int() {
	local name="$1" value="$2" default="$3" min="${4:-0}"
	if ! [[ "$value" =~ ^[0-9]+$ ]]; then
		echo "[${SCRIPT_NAME}] Invalid ${name}: '${value}' — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	local canonical
	canonical=$(printf '%d' "$((10#$value))")
	if ((canonical < min)); then
		echo "[${SCRIPT_NAME}] ${name}=${canonical} below minimum ${min} — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	printf '%s' "$canonical"
	return 0
}

PROCESS_RSS_WARN_MB=$(_validate_int PROCESS_RSS_WARN_MB "$PROCESS_RSS_WARN_MB" 1024 256)
PROCESS_RSS_CRIT_MB=$(_validate_int PROCESS_RSS_CRIT_MB "$PROCESS_RSS_CRIT_MB" 2048 512)
SHELLCHECK_RUNTIME_MAX=$(_validate_int SHELLCHECK_RUNTIME_MAX "$SHELLCHECK_RUNTIME_MAX" 300 60)
TOOL_RUNTIME_MAX=$(_validate_int TOOL_RUNTIME_MAX "$TOOL_RUNTIME_MAX" 1800 120)
SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 8 2)
AGGREGATE_RSS_WARN_MB=$(_validate_int AGGREGATE_RSS_WARN_MB "$AGGREGATE_RSS_WARN_MB" 8192 1024)
COOLDOWN_SECS=$(_validate_int COOLDOWN_SECS "$COOLDOWN_SECS" 300 30)
DAEMON_INTERVAL=$(_validate_int DAEMON_INTERVAL "$DAEMON_INTERVAL" 60 10)
readonly COOLDOWN_SECS DAEMON_INTERVAL

# --- Helpers ------------------------------------------------------------------

# Log a timestamped message to the log file
# Arguments: $1=level (INFO|WARN|CRIT), remaining args=message text
log_msg() {
	local level="$1"
	shift
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	printf '[%s] [%s] %s\n' "$timestamp" "$level" "$*" >>"${LOG_FILE}"
	return 0
}

# Create required log and state directories if they don't exist
ensure_dirs() {
	mkdir -p "${LOG_DIR}" "${STATE_DIR}"
	return 0
}

# Send desktop notification (macOS)
# Arguments: $1=title, $2=message, $3=urgency (normal|critical)
# Security: uses printf %s to avoid injection in osascript
notify() {
	local title="$1"
	local message="$2"
	local urgency="${3:-normal}"

	if [[ "${NOTIFY_ENABLED}" != "true" ]]; then
		return 0
	fi

	# terminal-notifier (preferred — clickable, persistent)
	# Sound disabled — visual popup only. Was causing repeated system beeps
	# every 5 min (cooldown interval) when thresholds were breached.
	# To re-enable: add -sound "${sound}" back to the terminal-notifier call.
	if command -v terminal-notifier &>/dev/null; then
		terminal-notifier \
			-title "${title}" \
			-message "${message}" \
			-group "${SCRIPT_NAME}" \
			-sender "com.apple.ActivityMonitor" 2>/dev/null || true
		return 0
	fi

	# Fallback: osascript — pass title/message as positional arguments via
	# 'on run argv', piping the AppleScript via stdin. This prevents injection
	# because the values are never interpolated into the AppleScript source code.
	# Previous approach used -e with string interpolation, which allowed breakout
	# via crafted process names (e.g., '"; do shell script "...').
	if command -v osascript &>/dev/null; then
		osascript - "$title" "$message" <<-'APPLESCRIPT' 2>/dev/null || true
			on run argv
				set theTitle to item 1 of argv
				set theMessage to item 2 of argv
				display notification theMessage with title theTitle
			end run
		APPLESCRIPT
		return 0
	fi

	return 0
}

# Cooldown check — prevents notification spam
# Arguments: $1=category name (used as filename suffix)
# Returns: 0 if cooldown expired (ok to notify), 1 if still in cooldown
check_cooldown() {
	local category="$1"
	local cooldown_file="${STATE_DIR}/memory-pressure-${category}.cooldown"
	if [[ -f "${cooldown_file}" ]]; then
		local last_notify
		last_notify="$(cat "${cooldown_file}" || echo 0)"
		if ! [[ "$last_notify" =~ ^[0-9]+$ ]]; then
			last_notify=0
		fi
		local now
		now="$(date +%s)"
		local elapsed=$((now - last_notify))
		if [[ ${elapsed} -lt ${COOLDOWN_SECS} ]]; then
			return 1
		fi
	fi
	return 0
}

# Record current time as cooldown start for a notification category
# Arguments: $1=category name (used as filename suffix)
set_cooldown() {
	local category="$1"
	local cooldown_file="${STATE_DIR}/memory-pressure-${category}.cooldown"
	date +%s >"${cooldown_file}"
	return 0
}

# Remove cooldown file for a category, allowing immediate re-notification
# Arguments: $1=category name (used as filename suffix)
clear_cooldown() {
	local category="$1"
	local cooldown_file="${STATE_DIR}/memory-pressure-${category}.cooldown"
	rm -f "${cooldown_file}"
	return 0
}

# --- Process Data Collection --------------------------------------------------

# Get process age in seconds (macOS + Linux compatible)
# Arguments: $1=PID
# Output: elapsed seconds to stdout
_get_process_age() {
	local pid="$1"

	# Linux: read from /proc if available (most accurate)
	if [[ -f "/proc/${pid}/stat" ]]; then
		local start_time
		start_time=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || echo "")
		if [[ -n "$start_time" ]]; then
			local clk_tck
			clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
			local uptime_secs
			uptime_secs=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
			[[ "$start_time" =~ ^[0-9]+$ ]] || start_time=0
			[[ "$clk_tck" =~ ^[0-9]+$ ]] || clk_tck=100
			[[ "$uptime_secs" =~ ^[0-9]+$ ]] || uptime_secs=0
			if [[ "$clk_tck" -gt 0 ]]; then
				local start_secs=$((start_time / clk_tck))
				echo $((uptime_secs - start_secs))
				return 0
			fi
		fi
	fi

	# macOS/fallback: parse ps etime
	local etime
	etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ') || etime=""

	if [[ -z "$etime" ]]; then
		echo "0"
		return 0
	fi

	local days=0 hours=0 minutes=0 seconds=0

	if [[ "$etime" == *-* ]]; then
		days="${etime%%-*}"
		etime="${etime#*-}"
	fi

	local colon_count
	colon_count=$(printf '%s' "$etime" | tr -cd ':' | wc -c | tr -d ' ')

	if [[ "$colon_count" -eq 2 ]]; then
		IFS=':' read -r hours minutes seconds <<<"$etime"
	elif [[ "$colon_count" -eq 1 ]]; then
		IFS=':' read -r minutes seconds <<<"$etime"
	else
		seconds="$etime"
	fi

	[[ "$days" =~ ^[0-9]+$ ]] || days=0
	[[ "$hours" =~ ^[0-9]+$ ]] || hours=0
	[[ "$minutes" =~ ^[0-9]+$ ]] || minutes=0
	[[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0

	days=$((10#${days}))
	hours=$((10#${hours}))
	minutes=$((10#${minutes}))
	seconds=$((10#${seconds}))

	echo $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
	return 0
}

# Format seconds as human-readable duration
_format_duration() {
	local secs="$1"
	if [[ "$secs" -ge 86400 ]]; then
		printf '%dd%dh%dm' $((secs / 86400)) $(((secs % 86400) / 3600)) $(((secs % 3600) / 60))
	elif [[ "$secs" -ge 3600 ]]; then
		printf '%dh%dm' $((secs / 3600)) $(((secs % 3600) / 60))
	elif [[ "$secs" -ge 60 ]]; then
		printf '%dm%ds' $((secs / 60)) $((secs % 60))
	else
		printf '%ds' "$secs"
	fi
	return 0
}

# Check if a command name is an "app" process (long-running by design).
# App processes only get RSS monitoring — runtime alerts are skipped.
# Arguments: $1=command name (short basename)
# Returns: 0 if app process, 1 if tool process
_is_app_process() {
	local cmd_name="$1"
	# Strip leading dot (e.g., ".opencode" → "opencode") — some binaries
	# are installed with a dot-prefixed wrapper name
	cmd_name="${cmd_name#.}"
	# Case-insensitive fixed-string match against the app process list
	# Single grep invocation avoids per-item tr subshells in a loop
	printf '%s\n' "${APP_PROCESS_NAMES[@]}" | grep -qixF -- "$cmd_name"
}

# Collect all monitored processes with their RSS and runtime
# Output: one line per process: PID|RSS_MB|RUNTIME_SECS|COMMAND_NAME|FULL_COMMAND
#
# Pattern matching: MONITORED_PATTERNS are matched against the COMMAND BASENAME
# only (not the full command line with arguments). This prevents false positives
# like zsh processes whose arguments contain "opencode" (e.g., `zsh -l -c opencode`).
_collect_monitored_processes() {
	# Collect all processes once, then filter by pattern against basename
	local ps_output
	ps_output=$(ps axo pid=,rss=,command= 2>/dev/null || true)

	# Track PIDs we've already emitted to avoid duplicates from overlapping patterns
	local -a seen_pids=()

	local pattern
	for pattern in "${MONITORED_PATTERNS[@]}"; do
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			# Parse with read builtin — avoids spawning echo/awk/cut subshells per line
			local pid rss_kb cmd
			read -r pid rss_kb cmd <<<"$line"

			# Validate PID and RSS are numeric
			[[ "$pid" =~ ^[0-9]+$ ]] || continue
			[[ "$rss_kb" =~ ^[0-9]+$ ]] || rss_kb=0

			# Extract short command name (basename of the executable path)
			local cmd_path="${cmd%% *}"
			local cmd_name
			cmd_name=$(basename "$cmd_path" 2>/dev/null || echo "unknown")

			# Match pattern against the command basename, NOT the full command line.
			# This prevents false positives like `zsh -l -c "opencode"` matching
			# the "opencode" pattern — zsh is not an opencode process.
			# Exception: patterns containing ".*" (regex) are matched against full
			# command for cases like "node.*language-server".
			local match=false
			if [[ "$pattern" == *".*"* ]]; then
				# Regex pattern — match against full command line
				if echo "$cmd" | grep -iqE "$pattern"; then
					match=true
				fi
			else
				# Simple pattern — match against basename only
				local cmd_lower pattern_lower
				cmd_lower=$(printf '%s' "$cmd_name" | tr '[:upper:]' '[:lower:]')
				pattern_lower=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
				if [[ "$cmd_lower" == *"$pattern_lower"* ]]; then
					match=true
				fi
			fi

			if [[ "$match" != "true" ]]; then
				continue
			fi

			# Skip grep, this script, and already-seen PIDs
			if [[ "$cmd_name" == "grep" ]] || [[ "$cmd" == *"${SCRIPT_NAME}"* ]]; then
				continue
			fi
			local seen_pid
			local is_dup=false
			for seen_pid in "${seen_pids[@]+"${seen_pids[@]}"}"; do
				if [[ "$seen_pid" == "$pid" ]]; then
					is_dup=true
					break
				fi
			done
			if [[ "$is_dup" == "true" ]]; then
				continue
			fi
			seen_pids+=("$pid")

			local rss_mb=$((rss_kb / 1024))
			local runtime
			runtime=$(_get_process_age "$pid")

			printf '%s|%s|%s|%s|%s\n' "$pid" "$rss_mb" "$runtime" "$cmd_name" "$cmd"
		done <<<"$ps_output"
	done | sort -t'|' -k2 -rn
	return 0
}

# Count interactive sessions (opencode/claude with a TTY)
_count_interactive_sessions() {
	local count=0
	local ps_output
	ps_output=$(ps axo pid=,tty=,command= 2>/dev/null | grep -iE "(opencode|claude)" | grep -v "grep" | grep -v "run " || true)

	while read -r _ tty _; do
		# Parse with read builtin — avoids spawning echo/awk subshells per line
		# Interactive sessions have a TTY (not "??" on macOS or "?" on Linux)
		if [[ "$tty" != "??" && "$tty" != "?" ]]; then
			count=$((count + 1))
		fi
	done <<<"$ps_output"

	echo "$count"
	return 0
}

# Get OS-level memory info (secondary signal)
# Output: memorystatus_level|total_gb|swap_used_mb|swap_files
_get_os_memory_info() {
	local mem_level="n/a"
	local total_gb="?"
	local swap_used_mb="0"
	local swap_files="0"

	if [[ "$(uname)" == "Darwin" ]]; then
		mem_level=$(sysctl -n kern.memorystatus_level 2>/dev/null || echo "n/a")
		local bytes
		bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
		[[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
		if [[ "$bytes" -gt 0 ]]; then
			total_gb=$(echo "scale=0; ${bytes} / 1073741824" | bc 2>/dev/null || echo "?")
		fi
		local swap_line
		swap_line=$(sysctl -n vm.swapusage 2>/dev/null || echo "")
		if [[ -n "$swap_line" ]]; then
			swap_used_mb=$(echo "$swap_line" | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p' || echo "0")
			swap_used_mb="${swap_used_mb%%.*}" # truncate to integer
		fi
		swap_files=$(find /private/var/vm -name 'swapfile*' 2>/dev/null | wc -l | tr -d ' ')
	elif [[ -f /proc/meminfo ]]; then
		local total_kb
		total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
		[[ "$total_kb" =~ ^[0-9]+$ ]] || total_kb=0
		total_gb=$((total_kb / 1048576))
		local avail_kb
		avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
		[[ "$avail_kb" =~ ^[0-9]+$ ]] || avail_kb=0
		if [[ "$total_kb" -gt 0 ]]; then
			mem_level=$(((avail_kb * 100) / total_kb))
		fi
		local swap_total_kb swap_free_kb
		swap_total_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
		swap_free_kb=$(awk '/SwapFree/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
		[[ "$swap_total_kb" =~ ^[0-9]+$ ]] || swap_total_kb=0
		[[ "$swap_free_kb" =~ ^[0-9]+$ ]] || swap_free_kb=0
		swap_used_mb=$(((swap_total_kb - swap_free_kb) / 1024))
	fi

	[[ "$swap_files" =~ ^[0-9]+$ ]] || swap_files=0
	[[ "$swap_used_mb" =~ ^[0-9]+$ ]] || swap_used_mb=0

	printf '%s|%s|%s|%s' "$mem_level" "$total_gb" "$swap_used_mb" "$swap_files"
	return 0
}

# --- Auto-Kill ----------------------------------------------------------------

# Kill a runaway process and log the action.
# Arguments: $1=PID, $2=reason (human-readable)
# Returns: 0 on success, 1 if process not found or kill failed
_auto_kill_process() {
	local pid="$1"
	local reason="$2"

	# Verify process still exists before killing
	if ! kill -0 "$pid" 2>/dev/null; then
		log_msg "INFO" "Auto-kill: PID ${pid} already gone (${reason})"
		return 1
	fi

	# SIGTERM first (graceful), then SIGKILL after 2 seconds if still alive
	log_msg "CRITICAL" "Auto-kill: sending SIGTERM to PID ${pid} (${reason})"
	kill -TERM "$pid" 2>/dev/null || true
	sleep 2

	if kill -0 "$pid" 2>/dev/null; then
		log_msg "CRITICAL" "Auto-kill: PID ${pid} survived SIGTERM, sending SIGKILL"
		kill -KILL "$pid" 2>/dev/null || true
	fi

	log_msg "CRITICAL" "Auto-kill: PID ${pid} terminated (${reason})"
	notify "Process Killed" "ShellCheck PID ${pid} killed: ${reason}" "critical"
	return 0
}

# --- Core Logic ---------------------------------------------------------------

# Phase 1: Check a single process for RSS and runtime violations.
# Appends findings to the module-level `_check_findings` array and sets
# `_check_has_critical`/`_check_has_warning` flags.
# Called once per process from do_check().
# Arguments: $1=pid $2=rss_mb $3=runtime $4=cmd_name
# Modifies: _check_findings[], _check_has_critical, _check_has_warning
_check_process_rss_and_runtime() {
	local pid="$1"
	local rss_mb="$2"
	local runtime="$3"
	local cmd_name="$4"

	# RSS check
	if [[ "$rss_mb" -ge "$PROCESS_RSS_CRIT_MB" ]]; then
		_check_findings+=("CRITICAL|rss|${pid}|${cmd_name} using ${rss_mb} MB RSS (limit: ${PROCESS_RSS_CRIT_MB} MB)")
		_check_has_critical=true
		# Auto-kill ShellCheck at CRITICAL RSS — safe, language server respawns
		if [[ "$cmd_name" == "shellcheck" && "$AUTO_KILL_SHELLCHECK" == "true" ]]; then
			_auto_kill_process "$pid" "RSS ${rss_mb} MB exceeds ${PROCESS_RSS_CRIT_MB} MB limit"
		fi
	elif [[ "$rss_mb" -ge "$PROCESS_RSS_WARN_MB" ]]; then
		_check_findings+=("WARNING|rss|${pid}|${cmd_name} using ${rss_mb} MB RSS (limit: ${PROCESS_RSS_WARN_MB} MB)")
		_check_has_warning=true
	fi

	# Runtime check — skip for app processes (long-running by design, GH#2992)
	if ! _is_app_process "$cmd_name"; then
		local runtime_limit="$TOOL_RUNTIME_MAX"
		if [[ "$cmd_name" == "shellcheck" ]]; then
			runtime_limit="$SHELLCHECK_RUNTIME_MAX"
		fi

		if [[ "$runtime" -gt "$runtime_limit" ]]; then
			local duration limit_duration
			duration=$(_format_duration "$runtime")
			limit_duration=$(_format_duration "$runtime_limit")
			_check_findings+=("WARNING|runtime|${pid}|${cmd_name} running for ${duration} (limit: ${limit_duration})")
			_check_has_warning=true
			# Auto-kill ShellCheck exceeding runtime — stuck in source chain expansion
			if [[ "$cmd_name" == "shellcheck" && "$AUTO_KILL_SHELLCHECK" == "true" ]]; then
				_auto_kill_process "$pid" "runtime ${duration} exceeds ${limit_duration} limit"
			fi
		fi
	fi
	return 0
}

# Phase 2+3: Aggregate RSS, session count, and swap file checks.
# Appends findings to _check_findings[]; sets _check_has_warning.
# Arguments: $1=total_rss_mb $2=process_count
_check_aggregate_and_os() {
	local total_rss_mb="$1"
	local process_count="$2"

	# Total RSS
	if [[ "$total_rss_mb" -ge "$AGGREGATE_RSS_WARN_MB" ]]; then
		_check_findings+=("WARNING|aggregate|0|Total aidevops RSS: ${total_rss_mb} MB across ${process_count} processes (limit: ${AGGREGATE_RSS_WARN_MB} MB)")
		_check_has_warning=true
	fi

	# Session count
	local session_count
	session_count=$(_count_interactive_sessions)
	if [[ "$session_count" -ge "$SESSION_COUNT_WARN" ]]; then
		_check_findings+=("WARNING|sessions|0|${session_count} interactive sessions open (limit: ${SESSION_COUNT_WARN})")
		_check_has_warning=true
	fi

	# OS-level info (secondary, logged but not primary alert trigger)
	local os_info swap_files
	os_info=$(_get_os_memory_info)
	IFS='|' read -r _ _ _ swap_files <<<"$os_info"
	if [[ "$swap_files" =~ ^[0-9]+$ ]] && [[ "$swap_files" -gt 10 ]]; then
		_check_findings+=("INFO|swap|0|${swap_files} swap files detected (elevated)")
	fi
	return 0
}

# Phase 4: Log and notify for each finding; clear cooldowns on all-clear.
# Reads _check_findings[], _check_has_critical, _check_has_warning,
# total_rss_mb, process_count, session_count from caller scope.
# Returns: 0=ok, 1=warnings, 2=critical
_act_on_findings() {
	local total_rss_mb="$1"
	local process_count="$2"
	local session_count="$3"

	if [[ ${#_check_findings[@]} -eq 0 ]]; then
		# All clear — clear cooldowns if recovering from a previous alert
		if [[ -f "${STATE_DIR}/memory-pressure-rss.cooldown" ]] ||
			[[ -f "${STATE_DIR}/memory-pressure-runtime.cooldown" ]] ||
			[[ -f "${STATE_DIR}/memory-pressure-sessions.cooldown" ]] ||
			[[ -f "${STATE_DIR}/memory-pressure-aggregate.cooldown" ]]; then
			log_msg "INFO" "All clear — ${process_count} processes, ${total_rss_mb} MB total RSS, ${session_count} sessions"
			clear_cooldown "rss"
			clear_cooldown "runtime"
			clear_cooldown "sessions"
			clear_cooldown "aggregate"
		fi
		return 0
	fi

	local finding
	for finding in "${_check_findings[@]}"; do
		local severity category detail
		IFS='|' read -r severity category _ detail <<<"$finding"

		log_msg "$severity" "$detail"

		# Only notify for WARNING and CRITICAL (not INFO)
		if [[ "$severity" == "INFO" ]]; then
			continue
		fi

		if check_cooldown "$category"; then
			local notify_title="Memory Monitor"
			if [[ "$severity" == "CRITICAL" ]]; then
				notify_title="CRITICAL: Memory Monitor"
			fi
			notify "$notify_title" "$detail" "$(printf '%s' "$severity" | tr '[:upper:]' '[:lower:]')"
			set_cooldown "$category"
		fi
	done

	if [[ "$_check_has_critical" == true ]]; then
		return 2
	elif [[ "$_check_has_warning" == true ]]; then
		return 1
	fi
	return 0
}

# Iterate over monitored processes, accumulate RSS/count, run per-process checks.
# Modifies caller-scope total_rss_mb and process_count (must be declared before call).
# Also populates _check_findings[], _check_has_critical, _check_has_warning via
# _check_process_rss_and_runtime().
_do_check_per_process() {
	local processes
	processes=$(_collect_monitored_processes)

	while IFS='|' read -r pid rss_mb runtime cmd_name full_cmd; do
		[[ -z "$pid" ]] && continue
		process_count=$((process_count + 1))
		total_rss_mb=$((total_rss_mb + rss_mb))
		_check_process_rss_and_runtime "$pid" "$rss_mb" "$runtime" "$cmd_name"
	done <<<"$processes"
	return 0
}

# Evaluate all monitored processes and generate alerts.
# Returns: 0=ok, 1=warnings found, 2=critical findings
do_check() {
	ensure_dirs

	# Module-level state shared with helper functions above (avoids subshell/nameref)
	_check_findings=()
	_check_has_critical=false
	_check_has_warning=false

	local total_rss_mb=0
	local process_count=0

	# Phase 1: Per-process checks
	_do_check_per_process

	# Phases 2+3: Aggregate and OS checks
	_check_aggregate_and_os "$total_rss_mb" "$process_count"

	# Resolve session count for the all-clear log message
	local session_count
	session_count=$(_count_interactive_sessions)

	# Phase 4: Act on findings — capture exit code explicitly so set -e
	# does not abort when _act_on_findings returns 1 (warning) or 2 (critical).
	local check_rc=0
	_act_on_findings "$total_rss_mb" "$process_count" "$session_count" || check_rc=$?
	return "$check_rc"
}

# --- Commands -----------------------------------------------------------------

# Run a single check pass — collect processes, evaluate thresholds, notify/kill
# Returns: 0=ok, 1=warnings found, 2=critical findings
cmd_check() {
	# do_check returns non-zero for warnings/critical — that's informational,
	# not a script failure. Capture the exit code for callers that want it.
	local exit_code=0
	do_check || exit_code=$?
	return "$exit_code"
}

# Print the monitored-processes table section of --status output.
_status_print_processes() {
	echo "--- Monitored Processes ---"
	echo ""

	local processes
	processes=$(_collect_monitored_processes)
	local total_rss=0
	local count=0

	if [[ -z "$processes" ]]; then
		echo "  No monitored processes running"
		return 0
	fi

	printf "  %-8s %-8s %-12s %-20s %-6s %s\n" "PID" "RSS MB" "Runtime" "Command" "Type" "Status"
	printf "  %-8s %-8s %-12s %-20s %-6s %s\n" "---" "------" "-------" "-------" "----" "------"

	while IFS='|' read -r pid rss_mb runtime cmd_name full_cmd; do
		[[ -z "$pid" ]] && continue
		count=$((count + 1))
		total_rss=$((total_rss + rss_mb))

		local duration proc_type status runtime_limit
		duration=$(_format_duration "$runtime")
		proc_type="tool"
		_is_app_process "$cmd_name" && proc_type="app"

		status="ok"
		if [[ "$rss_mb" -ge "$PROCESS_RSS_CRIT_MB" ]]; then
			status="CRITICAL (RSS)"
		elif [[ "$rss_mb" -ge "$PROCESS_RSS_WARN_MB" ]]; then
			status="WARNING (RSS)"
		fi

		# Runtime check only for tool processes (apps are long-running by design)
		if [[ "$proc_type" == "tool" ]]; then
			runtime_limit="$TOOL_RUNTIME_MAX"
			[[ "$cmd_name" == "shellcheck" ]] && runtime_limit="$SHELLCHECK_RUNTIME_MAX"
			if [[ "$runtime" -gt "$runtime_limit" ]]; then
				if [[ "$status" == "ok" ]]; then
					status="WARNING (runtime)"
				else
					status="${status}, WARNING (runtime)"
				fi
			fi
		fi

		printf "  %-8s %-8s %-12s %-20s %-6s %s\n" "$pid" "$rss_mb" "$duration" "$cmd_name" "$proc_type" "$status"
	done <<<"$processes"

	echo ""
	echo "  Total: ${count} processes, ${total_rss} MB RSS"
	return 0
}

# Print the interactive-sessions section of --status output.
_status_print_sessions() {
	echo "--- Interactive Sessions ---"
	echo ""
	local session_count session_status
	session_count=$(_count_interactive_sessions)
	session_status="ok"
	if [[ "$session_count" -ge "$SESSION_COUNT_WARN" ]]; then
		session_status="WARNING (>= ${SESSION_COUNT_WARN})"
	fi
	echo "  Count: ${session_count} (${session_status})"
	return 0
}

# Print the OS memory, configuration, and launchd sections of --status output.
_status_print_os_and_config() {
	echo "--- OS Memory (secondary) ---"
	echo ""
	local os_info mem_level total_gb swap_used_mb swap_files
	os_info=$(_get_os_memory_info)
	IFS='|' read -r mem_level total_gb swap_used_mb swap_files <<<"$os_info"
	echo "  Total RAM: ${total_gb} GB"
	echo "  Memory level: ${mem_level}% free (kern.memorystatus_level)"
	echo "  Swap used: ${swap_used_mb} MB"
	echo "  Swap files: ${swap_files}"

	echo ""
	echo "--- Configuration ---"
	echo ""
	echo "  Per-process RSS warning:  ${PROCESS_RSS_WARN_MB} MB"
	echo "  Per-process RSS critical: ${PROCESS_RSS_CRIT_MB} MB"
	echo "  ShellCheck runtime max:   $(_format_duration "$SHELLCHECK_RUNTIME_MAX")"
	echo "  Tool runtime max:         $(_format_duration "$TOOL_RUNTIME_MAX")"
	echo "  Session count warning:    ${SESSION_COUNT_WARN}"
	echo "  Aggregate RSS warning:    ${AGGREGATE_RSS_WARN_MB} MB"
	echo "  Auto-kill ShellCheck:     ${AUTO_KILL_SHELLCHECK}"
	echo "  Notification cooldown:    ${COOLDOWN_SECS}s"
	echo "  Notifications:            ${NOTIFY_ENABLED}"

	echo ""
	echo "--- Daemon ---"
	echo ""
	local pid_file="${STATE_DIR}/memory-pressure-monitor.pid"
	if [[ -f "${pid_file}" ]]; then
		local daemon_pid
		daemon_pid=$(cat "${pid_file}" 2>/dev/null || echo "")
		if [[ -n "$daemon_pid" ]] && [[ "$daemon_pid" =~ ^[0-9]+$ ]] && kill -0 "$daemon_pid" 2>/dev/null; then
			echo "  Daemon: running (PID ${daemon_pid})"
		else
			echo "  Daemon: not running (stale PID file)"
		fi
	else
		echo "  Daemon: not running"
	fi

	echo ""
	echo "--- Launchd ---"
	echo ""
	if [[ -f "${PLIST_PATH}" ]]; then
		if launchctl list 2>/dev/null | grep -q "${LAUNCHD_LABEL}"; then
			echo "  Status: installed and loaded"
		else
			echo "  Status: installed but NOT loaded"
		fi
	else
		echo "  Status: not installed (run --install)"
	fi
	return 0
}

# Print detailed status of all monitored processes, sessions, and OS memory.
cmd_status() {
	ensure_dirs

	echo "=== Memory Pressure Monitor v${SCRIPT_VERSION} ==="
	echo ""
	_status_print_processes
	echo ""
	_status_print_sessions
	echo ""
	_status_print_os_and_config
	echo ""
	return 0
}

# Run continuous monitoring loop with adaptive polling (faster when shellcheck detected)
# Prevents multiple concurrent daemon instances via a PID file (GH#17408).
cmd_daemon() {
	ensure_dirs
	local pid_file="${STATE_DIR}/memory-pressure-monitor.pid"

	# Guard: prevent multiple daemon instances
	if [[ -f "${pid_file}" ]]; then
		local old_pid
		old_pid=$(cat "${pid_file}" 2>/dev/null || echo "")
		if [[ -n "$old_pid" ]] && [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
			echo "[${SCRIPT_NAME}] Daemon already running (PID ${old_pid}). Use --stop or --restart to control it." >&2
			return 1
		else
			# Stale PID file — remove it and continue
			rm -f "${pid_file}"
		fi
	fi

	# Write our PID before entering the loop
	echo $$ >"${pid_file}"

	# Remove PID file on exit (Ctrl+C, SIGTERM, or normal exit)
	trap 'rm -f "${pid_file}"; trap - EXIT INT TERM' EXIT INT TERM

	echo "[${SCRIPT_NAME}] Starting daemon mode (PID $$, interval: ${DAEMON_INTERVAL}s, fast: 10s when shellcheck detected)"
	echo "[${SCRIPT_NAME}] Press Ctrl+C to stop"

	while true; do
		local check_exit=0
		cmd_check || check_exit=$?

		# Adaptive polling: if shellcheck processes are running, poll every 10s
		# instead of the normal 60s interval. ShellCheck can grow from 0 to 18 GB
		# in under 60s (observed Mar 7 crash), so the normal interval is too slow.
		local interval="$DAEMON_INTERVAL"
		if pgrep -x shellcheck >/dev/null 2>&1; then
			interval=10
		fi

		sleep "$interval"
	done
}

# Stop a running daemon by sending SIGTERM to the PID in the PID file.
cmd_stop() {
	ensure_dirs
	local pid_file="${STATE_DIR}/memory-pressure-monitor.pid"

	if [[ ! -f "${pid_file}" ]]; then
		echo "[${SCRIPT_NAME}] No PID file found. Is the daemon running?" >&2
		return 1
	fi

	local pid
	pid=$(cat "${pid_file}" 2>/dev/null || echo "")
	if [[ -z "$pid" ]] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
		echo "[${SCRIPT_NAME}] PID file is invalid. Removing stale file." >&2
		rm -f "${pid_file}"
		return 1
	fi

	if ! kill -0 "$pid" 2>/dev/null; then
		echo "[${SCRIPT_NAME}] No running daemon found (PID ${pid} is gone). Removing stale PID file."
		rm -f "${pid_file}"
		return 0
	fi

	echo "[${SCRIPT_NAME}] Stopping daemon (PID ${pid})..."
	kill -TERM "$pid" 2>/dev/null || true

	# Wait up to 5 seconds for the process to exit
	local waited=0
	while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt 5 ]]; do
		sleep 1
		waited=$((waited + 1))
	done

	if kill -0 "$pid" 2>/dev/null; then
		echo "[${SCRIPT_NAME}] Daemon did not stop after SIGTERM, sending SIGKILL..."
		kill -KILL "$pid" 2>/dev/null || true
	fi

	rm -f "${pid_file}"
	echo "[${SCRIPT_NAME}] Daemon stopped."
	return 0
}

# Stop any running daemon and start a fresh one.
cmd_restart() {
	local stop_rc=0
	cmd_stop 2>/dev/null || stop_rc=$?
	# stop_rc=1 is acceptable (no daemon was running)
	cmd_daemon
	return $?
}

# Install launchd plist for periodic monitoring (every 30 seconds)
cmd_install() {
	# Resolve script path — prefer installed location
	local script_path
	script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
	local installed_path="${HOME}/.aidevops/agents/scripts/${SCRIPT_NAME}.sh"
	if [[ -x "${installed_path}" ]]; then
		script_path="${installed_path}"
	fi

	ensure_dirs
	mkdir -p "$(dirname "${PLIST_PATH}")"

	# Generate plist — use heredoc with literal content (no variable expansion
	# in the XML structure) to prevent XML injection
	local home_escaped="${HOME}"

	cat >"${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${script_path}</string>
	</array>
	<key>StartInterval</key>
	<integer>30</integer>
	<key>StandardOutPath</key>
	<string>${home_escaped}/.aidevops/logs/memory-pressure-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${home_escaped}/.aidevops/logs/memory-pressure-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${home_escaped}</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityBackgroundIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
</dict>
</plist>
EOF

	# Load the plist
	launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
	launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"

	echo "Installed and loaded: ${LAUNCHD_LABEL}"
	echo "Plist: ${PLIST_PATH}"
	echo "Log: ${LOG_FILE}"
	echo "Check interval: 30 seconds"
	return 0
}

# Remove launchd plist and clean up state files
cmd_uninstall() {
	if [[ -f "${PLIST_PATH}" ]]; then
		launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
		rm -f "${PLIST_PATH}"
		echo "Uninstalled: ${LAUNCHD_LABEL}"
	else
		echo "Not installed"
	fi

	# Stop any running daemon before cleaning up
	local pid_file="${STATE_DIR}/memory-pressure-monitor.pid"
	if [[ -f "${pid_file}" ]]; then
		cmd_stop 2>/dev/null || true
	fi

	# Clean up state files
	rm -f "${STATE_DIR}"/memory-pressure-*.cooldown
	rm -f "${pid_file}"
	echo "Cleaned up state files"
	return 0
}

# Display usage information and current configuration
cmd_help() {
	cat <<HELP
Usage: ${SCRIPT_NAME}.sh [COMMAND]

Commands:
  --check, -c       Single check (default, for launchd)
  --status, -s      Print current process + memory state
  --daemon, -d      Continuous monitoring (${DAEMON_INTERVAL}s interval)
  --stop            Stop a running daemon (via PID file)
  --restart         Stop existing daemon and start a new one
  --install, -i     Install launchd plist (runs every 60s)
  --uninstall, -u   Remove launchd plist and state files
  --help, -h        Show this help

Process classification (GH#2992):
  App processes (claude, electron, shipit, opencode): RSS only, no runtime alerts
  Tool processes (shellcheck, language servers): RSS + runtime alerts

Process-level thresholds (primary):
  Per-process RSS:  warning=${PROCESS_RSS_WARN_MB}MB, critical=${PROCESS_RSS_CRIT_MB}MB
  ShellCheck max:   $(_format_duration "$SHELLCHECK_RUNTIME_MAX") (tool)
  Tool runtime max: $(_format_duration "$TOOL_RUNTIME_MAX") (tool)
  App runtime:      not checked (long-running by design)
  Session count:    warning >= ${SESSION_COUNT_WARN}
  Aggregate RSS:    warning >= ${AGGREGATE_RSS_WARN_MB}MB

Auto-kill (GH#2915):
  ShellCheck processes are auto-killed when they hit CRITICAL RSS (>${PROCESS_RSS_CRIT_MB}MB)
  or exceed runtime limit (>$(_format_duration "$SHELLCHECK_RUNTIME_MAX")).
  Safe because the language server respawns them. Disable: AUTO_KILL_SHELLCHECK=false

Environment variables:
  PROCESS_RSS_WARN_MB       Per-process RSS warning (default: 1024)
  PROCESS_RSS_CRIT_MB       Per-process RSS critical (default: 2048)
  SHELLCHECK_RUNTIME_MAX    ShellCheck max runtime in seconds (default: 300)
  TOOL_RUNTIME_MAX          Other tool max runtime in seconds (default: 1800)
  SESSION_COUNT_WARN        Interactive session warning threshold (default: 8)
  AGGREGATE_RSS_WARN_MB     Total aidevops RSS warning (default: 8192)
  AUTO_KILL_SHELLCHECK      Auto-kill runaway ShellCheck (default: true)
  MEMORY_COOLDOWN_SECS      Notification cooldown per category (default: 300)
  MEMORY_NOTIFY             Set to "false" to disable notifications
  MEMORY_LOG_DIR            Override log directory
HELP
	return 0
}

# --- Main ---------------------------------------------------------------------

# Parse command-line arguments and dispatch to the appropriate subcommand
main() {
	local cmd="${1:-check}"

	case "${cmd}" in
	--status | -s | status)
		cmd_status
		;;
	--daemon | -d | daemon)
		cmd_daemon
		;;
	--stop | stop)
		cmd_stop
		;;
	--restart | restart)
		cmd_restart
		;;
	--install | -i | install)
		cmd_install
		;;
	--uninstall | -u | uninstall)
		cmd_uninstall
		;;
	--check | -c | check)
		cmd_check
		;;
	--help | -h | help)
		cmd_help
		;;
	*)
		echo "Unknown command: ${cmd}" >&2
		echo "Run with --help for usage" >&2
		return 1
		;;
	esac
}

main "$@"
