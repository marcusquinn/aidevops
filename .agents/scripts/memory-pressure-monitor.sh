#!/usr/bin/env bash
# memory-pressure-monitor.sh — Process-focused memory pressure monitor
#
# Monitors aidevops process health: individual RSS, process runtime, process count.
# This is the RIGHT signal — the March 3 kernel panic was caused by aidevops
# processes (ShellCheck at 5.7 GB, zombie pulses, session accumulation), not by
# generic OS memory pressure.
#
# Auto-kill (GH#2915): ShellCheck processes that hit CRITICAL RSS or exceed
# runtime limits are automatically killed. This is safe because the bash
# language server respawns them. The root cause (source-path=SCRIPTDIR in
# .shellcheckrc causing recursive expansion) has been removed — SC1091 is
# now globally disabled instead. This monitor remains as defense-in-depth.
#
# kern.memorystatus_level is a secondary/informational signal only. macOS runs
# fine with compression + swap; aggressive thresholds on that metric cause false
# alarms. The primary signals are process-level.
#
# Usage:
#   memory-pressure-monitor.sh              # Single check (for launchd)
#   memory-pressure-monitor.sh --status     # Print current process + memory state
#   memory-pressure-monitor.sh --daemon     # Continuous monitoring (60s interval)
#   memory-pressure-monitor.sh --install    # Install launchd plist
#   memory-pressure-monitor.sh --uninstall  # Remove launchd plist and state files
#   memory-pressure-monitor.sh --help       # Show usage
#
# Process-level thresholds (primary signals):
#   RSS per process:  > 2 GB  → warning, > 4 GB → critical (kill candidate)
#   Runtime:          > 10 min for shellcheck, > 30 min for other tools
#   Session count:    > 5 concurrent interactive sessions → warning
#   Total aidevops:   > 8 GB aggregate RSS → warning
#
# OS-level thresholds (secondary, informational only):
#   kern.memorystatus_level: logged but NOT used for alerts (too noisy)
#   Swap file count:  > 10 → informational warning
#
# Environment:
#   PROCESS_RSS_WARN_MB       Per-process RSS warning (default: 2048)
#   PROCESS_RSS_CRIT_MB       Per-process RSS critical (default: 4096)
#   SHELLCHECK_RUNTIME_MAX    ShellCheck max runtime in seconds (default: 600)
#   TOOL_RUNTIME_MAX          Other tool max runtime in seconds (default: 1800)
#   SESSION_COUNT_WARN        Interactive session warning threshold (default: 5)
#   AGGREGATE_RSS_WARN_MB     Total aidevops RSS warning (default: 8192)
#   AUTO_KILL_SHELLCHECK       Auto-kill runaway ShellCheck (default: true)
#   MEMORY_COOLDOWN_SECS      Notification cooldown per category (default: 300)
#   MEMORY_NOTIFY             Set to "false" to disable notifications (log only)
#   MEMORY_LOG_DIR            Override log directory

set -euo pipefail

# --- Configuration -----------------------------------------------------------

readonly SCRIPT_NAME="memory-pressure-monitor"
readonly SCRIPT_VERSION="1.1.0"

# Per-process RSS thresholds (MB)
PROCESS_RSS_WARN_MB="${PROCESS_RSS_WARN_MB:-2048}"
PROCESS_RSS_CRIT_MB="${PROCESS_RSS_CRIT_MB:-4096}"

# Runtime thresholds (seconds)
SHELLCHECK_RUNTIME_MAX="${SHELLCHECK_RUNTIME_MAX:-600}" # 10 min
TOOL_RUNTIME_MAX="${TOOL_RUNTIME_MAX:-1800}"            # 30 min

# Session/aggregate thresholds
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-5}"
AGGREGATE_RSS_WARN_MB="${AGGREGATE_RSS_WARN_MB:-8192}" # 8 GB total

# Auto-kill: ShellCheck processes are safe to kill (language server respawns them)
readonly AUTO_KILL_SHELLCHECK="${AUTO_KILL_SHELLCHECK:-true}"

# Notification — COOLDOWN_SECS and DAEMON_INTERVAL validated below with _validate_int
COOLDOWN_SECS="${MEMORY_COOLDOWN_SECS:-300}"
readonly NOTIFY_ENABLED="${MEMORY_NOTIFY:-true}"
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

PROCESS_RSS_WARN_MB=$(_validate_int PROCESS_RSS_WARN_MB "$PROCESS_RSS_WARN_MB" 2048 256)
PROCESS_RSS_CRIT_MB=$(_validate_int PROCESS_RSS_CRIT_MB "$PROCESS_RSS_CRIT_MB" 4096 512)
SHELLCHECK_RUNTIME_MAX=$(_validate_int SHELLCHECK_RUNTIME_MAX "$SHELLCHECK_RUNTIME_MAX" 600 60)
TOOL_RUNTIME_MAX=$(_validate_int TOOL_RUNTIME_MAX "$TOOL_RUNTIME_MAX" 1800 120)
SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 5 2)
AGGREGATE_RSS_WARN_MB=$(_validate_int AGGREGATE_RSS_WARN_MB "$AGGREGATE_RSS_WARN_MB" 8192 1024)
COOLDOWN_SECS=$(_validate_int COOLDOWN_SECS "$COOLDOWN_SECS" 300 30)
DAEMON_INTERVAL=$(_validate_int DAEMON_INTERVAL "$DAEMON_INTERVAL" 60 10)
readonly COOLDOWN_SECS DAEMON_INTERVAL

# --- Helpers ------------------------------------------------------------------

log_msg() {
	local level="$1"
	shift
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	printf '[%s] [%s] %s\n' "$timestamp" "$level" "$*" >>"${LOG_FILE}"
	return 0
}

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
	if command -v terminal-notifier &>/dev/null; then
		local sound="default"
		if [[ "${urgency}" == "critical" ]]; then
			sound="Sosumi"
		fi
		terminal-notifier \
			-title "${title}" \
			-message "${message}" \
			-sound "${sound}" \
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

set_cooldown() {
	local category="$1"
	local cooldown_file="${STATE_DIR}/memory-pressure-${category}.cooldown"
	date +%s >"${cooldown_file}"
	return 0
}

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

# Collect all monitored processes with their RSS and runtime
# Output: one line per process: PID|RSS_MB|RUNTIME_SECS|COMMAND_NAME|FULL_COMMAND
_collect_monitored_processes() {
	local pattern
	for pattern in "${MONITORED_PATTERNS[@]}"; do
		# Use ps to get PID, RSS (KB), and command
		# Filter by pattern, exclude grep itself and this script
		local ps_output
		ps_output=$(ps axo pid=,rss=,command= 2>/dev/null | grep -iE "$pattern" | grep -v "grep" | grep -v "${SCRIPT_NAME}" || true)

		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			# Parse with read builtin — avoids spawning echo/awk/cut subshells per line
			local pid rss_kb cmd
			read -r pid rss_kb cmd <<<"$line"

			# Validate PID and RSS are numeric
			[[ "$pid" =~ ^[0-9]+$ ]] || continue
			[[ "$rss_kb" =~ ^[0-9]+$ ]] || rss_kb=0

			local rss_mb=$((rss_kb / 1024))
			local runtime
			runtime=$(_get_process_age "$pid")

			# Extract short command name via parameter expansion (no subshell)
			local cmd_path="${cmd%% *}"
			local cmd_name
			cmd_name=$(basename "$cmd_path" 2>/dev/null || echo "unknown")

			printf '%s|%s|%s|%s|%s\n' "$pid" "$rss_mb" "$runtime" "$cmd_name" "$cmd"
		done <<<"$ps_output"
	done | sort -t'|' -k2 -rn | uniq
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

# Evaluate all monitored processes and generate alerts
# Returns findings as structured output, one per line:
#   SEVERITY|CATEGORY|PID|DETAIL
do_check() {
	ensure_dirs

	local findings=()
	local total_rss_mb=0
	local process_count=0
	local has_critical=false
	local has_warning=false

	# --- Phase 1: Per-process checks ---
	local processes
	processes=$(_collect_monitored_processes)

	while IFS='|' read -r pid rss_mb runtime cmd_name full_cmd; do
		[[ -z "$pid" ]] && continue
		process_count=$((process_count + 1))
		total_rss_mb=$((total_rss_mb + rss_mb))

		# RSS check
		if [[ "$rss_mb" -ge "$PROCESS_RSS_CRIT_MB" ]]; then
			findings+=("CRITICAL|rss|${pid}|${cmd_name} using ${rss_mb} MB RSS (limit: ${PROCESS_RSS_CRIT_MB} MB)")
			has_critical=true
			# Auto-kill ShellCheck at CRITICAL RSS — safe, language server respawns
			if [[ "$cmd_name" == "shellcheck" && "$AUTO_KILL_SHELLCHECK" == "true" ]]; then
				_auto_kill_process "$pid" "RSS ${rss_mb} MB exceeds ${PROCESS_RSS_CRIT_MB} MB limit"
			fi
		elif [[ "$rss_mb" -ge "$PROCESS_RSS_WARN_MB" ]]; then
			findings+=("WARNING|rss|${pid}|${cmd_name} using ${rss_mb} MB RSS (limit: ${PROCESS_RSS_WARN_MB} MB)")
			has_warning=true
		fi

		# Runtime check — different limits for shellcheck vs other tools
		local runtime_limit="$TOOL_RUNTIME_MAX"
		if [[ "$cmd_name" == "shellcheck" ]]; then
			runtime_limit="$SHELLCHECK_RUNTIME_MAX"
		fi

		if [[ "$runtime" -gt "$runtime_limit" ]]; then
			local duration
			duration=$(_format_duration "$runtime")
			local limit_duration
			limit_duration=$(_format_duration "$runtime_limit")
			findings+=("WARNING|runtime|${pid}|${cmd_name} running for ${duration} (limit: ${limit_duration})")
			has_warning=true
			# Auto-kill ShellCheck exceeding runtime — stuck in source chain expansion
			if [[ "$cmd_name" == "shellcheck" && "$AUTO_KILL_SHELLCHECK" == "true" ]]; then
				_auto_kill_process "$pid" "runtime ${duration} exceeds ${limit_duration} limit"
			fi
		fi
	done <<<"$processes"

	# --- Phase 2: Aggregate checks ---

	# Total RSS
	if [[ "$total_rss_mb" -ge "$AGGREGATE_RSS_WARN_MB" ]]; then
		findings+=("WARNING|aggregate|0|Total aidevops RSS: ${total_rss_mb} MB across ${process_count} processes (limit: ${AGGREGATE_RSS_WARN_MB} MB)")
		has_warning=true
	fi

	# Session count
	local session_count
	session_count=$(_count_interactive_sessions)
	if [[ "$session_count" -ge "$SESSION_COUNT_WARN" ]]; then
		findings+=("WARNING|sessions|0|${session_count} interactive sessions open (limit: ${SESSION_COUNT_WARN})")
		has_warning=true
	fi

	# --- Phase 3: OS-level info (secondary, logged but not primary alert trigger) ---
	local os_info
	os_info=$(_get_os_memory_info)
	local mem_level swap_used_mb swap_files
	IFS='|' read -r mem_level _ swap_used_mb swap_files <<<"$os_info"

	if [[ "$swap_files" =~ ^[0-9]+$ ]] && [[ "$swap_files" -gt 10 ]]; then
		findings+=("INFO|swap|0|${swap_files} swap files detected (elevated)")
	fi

	# --- Phase 4: Act on findings ---
	if [[ ${#findings[@]} -eq 0 ]]; then
		# All clear — check if recovering from a previous alert
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

	# Process findings
	local finding
	for finding in "${findings[@]}"; do
		local severity category pid detail
		IFS='|' read -r severity category pid detail <<<"$finding"

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
			notify "$notify_title" "$detail" "$(echo "$severity" | tr '[:upper:]' '[:lower:]')"
			set_cooldown "$category"
		fi
	done

	# Return appropriate exit code for callers
	if [[ "$has_critical" == true ]]; then
		return 2
	elif [[ "$has_warning" == true ]]; then
		return 1
	fi
	return 0
}

# --- Commands -----------------------------------------------------------------

cmd_check() {
	# do_check returns non-zero for warnings/critical — that's informational,
	# not a script failure. Capture the exit code for callers that want it.
	local exit_code=0
	do_check || exit_code=$?
	return "$exit_code"
}

cmd_status() {
	ensure_dirs

	echo "=== Memory Pressure Monitor v${SCRIPT_VERSION} ==="
	echo ""
	echo "--- Monitored Processes ---"
	echo ""

	local processes
	processes=$(_collect_monitored_processes)
	local total_rss=0
	local count=0

	if [[ -z "$processes" ]]; then
		echo "  No monitored processes running"
	else
		printf "  %-8s %-8s %-12s %-20s %s\n" "PID" "RSS MB" "Runtime" "Command" "Status"
		printf "  %-8s %-8s %-12s %-20s %s\n" "---" "------" "-------" "-------" "------"

		while IFS='|' read -r pid rss_mb runtime cmd_name full_cmd; do
			[[ -z "$pid" ]] && continue
			count=$((count + 1))
			total_rss=$((total_rss + rss_mb))

			local duration
			duration=$(_format_duration "$runtime")

			local status="ok"
			if [[ "$rss_mb" -ge "$PROCESS_RSS_CRIT_MB" ]]; then
				status="CRITICAL (RSS)"
			elif [[ "$rss_mb" -ge "$PROCESS_RSS_WARN_MB" ]]; then
				status="WARNING (RSS)"
			fi

			local runtime_limit="$TOOL_RUNTIME_MAX"
			[[ "$cmd_name" == "shellcheck" ]] && runtime_limit="$SHELLCHECK_RUNTIME_MAX"
			if [[ "$runtime" -gt "$runtime_limit" ]]; then
				if [[ "$status" == "ok" ]]; then
					status="WARNING (runtime)"
				else
					status="${status}, WARNING (runtime)"
				fi
			fi

			printf "  %-8s %-8s %-12s %-20s %s\n" "$pid" "$rss_mb" "$duration" "$cmd_name" "$status"
		done <<<"$processes"

		echo ""
		echo "  Total: ${count} processes, ${total_rss} MB RSS"
	fi

	echo ""
	echo "--- Interactive Sessions ---"
	echo ""
	local session_count
	session_count=$(_count_interactive_sessions)
	local session_status="ok"
	if [[ "$session_count" -ge "$SESSION_COUNT_WARN" ]]; then
		session_status="WARNING (>= ${SESSION_COUNT_WARN})"
	fi
	echo "  Count: ${session_count} (${session_status})"

	echo ""
	echo "--- OS Memory (secondary) ---"
	echo ""
	local os_info
	os_info=$(_get_os_memory_info)
	local mem_level total_gb swap_used_mb swap_files
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

	echo ""
	return 0
}

cmd_daemon() {
	echo "[${SCRIPT_NAME}] Starting daemon mode (interval: ${DAEMON_INTERVAL}s)"
	echo "[${SCRIPT_NAME}] Press Ctrl+C to stop"

	while true; do
		cmd_check || true
		sleep "${DAEMON_INTERVAL}"
	done
}

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
	<integer>60</integer>
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
	echo "Check interval: 60 seconds"
	return 0
}

cmd_uninstall() {
	if [[ -f "${PLIST_PATH}" ]]; then
		launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
		rm -f "${PLIST_PATH}"
		echo "Uninstalled: ${LAUNCHD_LABEL}"
	else
		echo "Not installed"
	fi

	# Clean up state files
	rm -f "${STATE_DIR}"/memory-pressure-*.cooldown
	echo "Cleaned up state files"
	return 0
}

cmd_help() {
	cat <<HELP
Usage: ${SCRIPT_NAME}.sh [COMMAND]

Commands:
  --check, -c       Single check (default, for launchd)
  --status, -s      Print current process + memory state
  --daemon, -d      Continuous monitoring (${DAEMON_INTERVAL}s interval)
  --install, -i     Install launchd plist (runs every 60s)
  --uninstall, -u   Remove launchd plist and state files
  --help, -h        Show this help

Process-level thresholds (primary):
  Per-process RSS:  warning=${PROCESS_RSS_WARN_MB}MB, critical=${PROCESS_RSS_CRIT_MB}MB
  ShellCheck max:   $(_format_duration "$SHELLCHECK_RUNTIME_MAX")
  Tool runtime max: $(_format_duration "$TOOL_RUNTIME_MAX")
  Session count:    warning >= ${SESSION_COUNT_WARN}
  Aggregate RSS:    warning >= ${AGGREGATE_RSS_WARN_MB}MB

Auto-kill (GH#2915):
  ShellCheck processes are auto-killed when they hit CRITICAL RSS (>${PROCESS_RSS_CRIT_MB}MB)
  or exceed runtime limit (>$(_format_duration "$SHELLCHECK_RUNTIME_MAX")).
  Safe because the language server respawns them. Disable: AUTO_KILL_SHELLCHECK=false

Environment variables:
  PROCESS_RSS_WARN_MB       Per-process RSS warning (default: 2048)
  PROCESS_RSS_CRIT_MB       Per-process RSS critical (default: 4096)
  SHELLCHECK_RUNTIME_MAX    ShellCheck max runtime in seconds (default: 600)
  TOOL_RUNTIME_MAX          Other tool max runtime in seconds (default: 1800)
  SESSION_COUNT_WARN        Interactive session warning threshold (default: 5)
  AGGREGATE_RSS_WARN_MB     Total aidevops RSS warning (default: 8192)
  AUTO_KILL_SHELLCHECK      Auto-kill runaway ShellCheck (default: true)
  MEMORY_COOLDOWN_SECS      Notification cooldown per category (default: 300)
  MEMORY_NOTIFY             Set to "false" to disable notifications
  MEMORY_LOG_DIR            Override log directory
HELP
	return 0
}

# --- Main ---------------------------------------------------------------------

main() {
	local cmd="${1:-check}"

	case "${cmd}" in
	--status | -s | status)
		cmd_status
		;;
	--daemon | -d | daemon)
		cmd_daemon
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
