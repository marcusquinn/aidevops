#!/usr/bin/env bash
# memory-pressure-monitor.sh — Early warning system for macOS memory pressure
#
# Monitors kern.memorystatus_level and swap/compressor state.
# Sends notifications at warning/critical thresholds with top memory consumers.
# Designed to catch the cascade that leads to kernel panics from memory exhaustion.
#
# Usage:
#   memory-pressure-monitor.sh              # Single check (for launchd)
#   memory-pressure-monitor.sh --daemon     # Continuous monitoring (60s interval)
#   memory-pressure-monitor.sh --status     # Print current memory state
#   memory-pressure-monitor.sh --install    # Install launchd plist
#   memory-pressure-monitor.sh --uninstall  # Remove launchd plist
#
# Thresholds (kern.memorystatus_level is 0-100, higher = more free):
#   Normal:   > 40
#   Warning:  21-40  (notify, log top consumers)
#   Critical: 1-20   (notify urgently, log full state, suggest actions)
#
# Environment:
#   MEMORY_WARN_THRESHOLD   Override warning level (default: 40)
#   MEMORY_CRIT_THRESHOLD   Override critical level (default: 20)
#   MEMORY_LOG_DIR          Override log directory
#   MEMORY_COOLDOWN_SECS    Minimum seconds between notifications per level (default: 300)
#   MEMORY_NOTIFY           Set to "false" to disable notifications (log only)

set -euo pipefail

# --- Configuration -----------------------------------------------------------

readonly SCRIPT_NAME="memory-pressure-monitor"
readonly WARN_THRESHOLD="${MEMORY_WARN_THRESHOLD:-40}"
readonly CRIT_THRESHOLD="${MEMORY_CRIT_THRESHOLD:-20}"
readonly COOLDOWN_SECS="${MEMORY_COOLDOWN_SECS:-300}"
readonly NOTIFY_ENABLED="${MEMORY_NOTIFY:-true}"
readonly DAEMON_INTERVAL=60

readonly LOG_DIR="${MEMORY_LOG_DIR:-${HOME}/.aidevops/logs}"
readonly LOG_FILE="${LOG_DIR}/memory-pressure.log"
readonly STATE_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
readonly COOLDOWN_FILE_WARN="${STATE_DIR}/memory-pressure-warn.cooldown"
readonly COOLDOWN_FILE_CRIT="${STATE_DIR}/memory-pressure-crit.cooldown"

readonly LAUNCHD_LABEL="sh.aidevops.memory-pressure-monitor"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

# --- Helpers ------------------------------------------------------------------

log_msg() {
	local level="$1"
	shift
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	echo "[${timestamp}] [${level}] $*" >>"${LOG_FILE}"
}

ensure_dirs() {
	mkdir -p "${LOG_DIR}" "${STATE_DIR}"
}

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
			-title "Memory Pressure: ${title}" \
			-message "${message}" \
			-sound "${sound}" \
			-group "${SCRIPT_NAME}" \
			-sender "com.apple.ActivityMonitor" 2>/dev/null || true
		return 0
	fi

	# Fallback: osascript
	if command -v osascript &>/dev/null; then
		osascript -e "display notification \"${message}\" with title \"Memory Pressure: ${title}\"" 2>/dev/null || true
		return 0
	fi

	return 0
}

check_cooldown() {
	local cooldown_file="$1"
	if [[ -f "${cooldown_file}" ]]; then
		local last_notify
		last_notify="$(cat "${cooldown_file}" 2>/dev/null || echo 0)"
		local now
		now="$(date +%s)"
		local elapsed=$((now - last_notify))
		if [[ ${elapsed} -lt ${COOLDOWN_SECS} ]]; then
			return 1 # Still in cooldown
		fi
	fi
	return 0 # Cooldown expired or no file
}

set_cooldown() {
	local cooldown_file="$1"
	date +%s >"${cooldown_file}"
}

# --- Data Collection ----------------------------------------------------------

get_memory_level() {
	# kern.memorystatus_level: 0-100, percentage of memory considered "free"
	# by the kernel (includes purgeable, inactive, free pages)
	sysctl -n kern.memorystatus_level 2>/dev/null || echo "0"
}

get_total_memory_gb() {
	local bytes
	bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
	echo "scale=1; ${bytes} / 1073741824" | bc
}

get_swap_info() {
	# Returns: total_mb used_mb
	local swap_line
	swap_line="$(sysctl -n vm.swapusage 2>/dev/null || echo "total = 0.00M  used = 0.00M  free = 0.00M")"
	local total used
	total="$(echo "${swap_line}" | sed -n 's/.*total = \([0-9.]*\)M.*/\1/p')"
	used="$(echo "${swap_line}" | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')"
	echo "${total:-0} ${used:-0}"
}

get_compressor_segments() {
	sysctl -n vm.compressor.segment.total 2>/dev/null || echo "0"
}

get_swap_file_count() {
	local count
	count="$(find /private/var/vm -name 'swapfile*' 2>/dev/null | wc -l | tr -d ' ')"
	echo "${count:-0}"
}

get_top_memory_consumers() {
	local count="${1:-5}"
	# ps output: RSS (KB), %MEM, COMMAND — sorted by RSS descending
	# Use process substitution to avoid SIGPIPE from head closing the pipe
	local ps_output
	ps_output="$(ps -eo rss=,pmem=,comm= -r 2>/dev/null | head -n "${count}" || true)"
	while read -r rss pmem comm; do
		[[ -z "${rss}" ]] && continue
		local mb
		mb="$(echo "scale=0; ${rss} / 1024" | bc)"
		printf "  %6s MB (%5s%%) %s\n" "${mb}" "${pmem}" "${comm}"
	done <<<"${ps_output}"
}

# --- Core Logic ---------------------------------------------------------------

collect_state() {
	local level
	level="$(get_memory_level)"
	local total_gb
	total_gb="$(get_total_memory_gb)"
	local swap_info
	swap_info="$(get_swap_info)"
	local swap_total swap_used
	swap_total="$(echo "${swap_info}" | awk '{print $1}')"
	swap_used="$(echo "${swap_info}" | awk '{print $2}')"
	local compressor_segments
	compressor_segments="$(get_compressor_segments)"
	local swap_files
	swap_files="$(get_swap_file_count)"

	echo "${level}|${total_gb}|${swap_total}|${swap_used}|${compressor_segments}|${swap_files}"
}

evaluate_state() {
	local state="$1"
	local level total_gb swap_total swap_used compressor_segments swap_files
	IFS='|' read -r level total_gb swap_total swap_used compressor_segments swap_files <<<"${state}"

	if [[ ${level} -le ${CRIT_THRESHOLD} ]]; then
		echo "critical"
	elif [[ ${level} -le ${WARN_THRESHOLD} ]]; then
		echo "warning"
	else
		echo "normal"
	fi
}

format_state() {
	local state="$1"
	local level total_gb swap_total swap_used compressor_segments swap_files
	IFS='|' read -r level total_gb swap_total swap_used compressor_segments swap_files <<<"${state}"

	echo "Memory level: ${level}% free (of ${total_gb} GB)"
	echo "Swap: ${swap_used}M used / ${swap_total}M total (${swap_files} swap files)"
	echo "Compressor segments: ${compressor_segments}"
	echo ""
	echo "Top memory consumers:"
	get_top_memory_consumers 8
}

do_check() {
	ensure_dirs

	local state
	state="$(collect_state)"
	local severity
	severity="$(evaluate_state "${state}")"
	local level
	level="$(echo "${state}" | cut -d'|' -f1)"

	case "${severity}" in
	critical)
		if check_cooldown "${COOLDOWN_FILE_CRIT}"; then
			local detail
			detail="$(format_state "${state}")"
			log_msg "CRITICAL" "Memory level at ${level}% — system at risk of panic"
			log_msg "CRITICAL" "${detail}"
			notify "CRITICAL" "Memory at ${level}% free — risk of kernel panic. Open Activity Monitor." "critical"
			set_cooldown "${COOLDOWN_FILE_CRIT}"
			# Also reset warn cooldown so we re-warn if it recovers then drops again
			rm -f "${COOLDOWN_FILE_WARN}"
		fi
		;;
	warning)
		if check_cooldown "${COOLDOWN_FILE_WARN}"; then
			local detail
			detail="$(format_state "${state}")"
			log_msg "WARNING" "Memory level at ${level}% — approaching pressure zone"
			log_msg "WARNING" "${detail}"
			notify "Warning" "Memory at ${level}% free. Consider closing heavy apps." "normal"
			set_cooldown "${COOLDOWN_FILE_WARN}"
		fi
		# Clear critical cooldown so we re-alert if it worsens
		rm -f "${COOLDOWN_FILE_CRIT}"
		;;
	normal)
		# If recovering from a pressure event, log the recovery
		if [[ -f "${COOLDOWN_FILE_WARN}" ]] || [[ -f "${COOLDOWN_FILE_CRIT}" ]]; then
			log_msg "INFO" "Memory pressure resolved — level at ${level}%"
			rm -f "${COOLDOWN_FILE_WARN}" "${COOLDOWN_FILE_CRIT}"
		fi
		;;
	esac

	return 0
}

# --- Commands -----------------------------------------------------------------

cmd_status() {
	local state
	state="$(collect_state)"
	local severity
	severity="$(evaluate_state "${state}")"

	echo "=== Memory Pressure Monitor ==="
	echo ""
	format_state "${state}"
	echo ""

	local upper_severity
	upper_severity="$(echo "${severity}" | tr '[:lower:]' '[:upper:]')"
	echo "Status: ${upper_severity}"
	echo "Thresholds: warning <= ${WARN_THRESHOLD}%, critical <= ${CRIT_THRESHOLD}%"
	echo "Cooldown: ${COOLDOWN_SECS}s between notifications"
	echo ""

	if [[ -f "${PLIST_PATH}" ]]; then
		local loaded
		loaded="$(launchctl list 2>/dev/null | grep -c "${LAUNCHD_LABEL}" || true)"
		if [[ "${loaded}" -gt 0 ]]; then
			echo "Launchd: installed and loaded"
		else
			echo "Launchd: installed but NOT loaded"
		fi
	else
		echo "Launchd: not installed (run --install)"
	fi
}

cmd_daemon() {
	echo "[${SCRIPT_NAME}] Starting daemon mode (interval: ${DAEMON_INTERVAL}s)"
	echo "[${SCRIPT_NAME}] Thresholds: warn=${WARN_THRESHOLD}%, crit=${CRIT_THRESHOLD}%"
	echo "[${SCRIPT_NAME}] Press Ctrl+C to stop"

	while true; do
		do_check
		sleep "${DAEMON_INTERVAL}"
	done
}

cmd_install() {
	local script_path
	script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

	# Verify the script exists at the expected installed location
	local installed_path="${HOME}/.aidevops/agents/scripts/${SCRIPT_NAME}.sh"
	if [[ -x "${installed_path}" ]]; then
		script_path="${installed_path}"
	fi

	cat >"${PLIST_PATH}" <<PLIST
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
	<string>${LOG_DIR}/memory-pressure-launchd.log</string>
	<key>StandardErrorPath</key>
	<string>${LOG_DIR}/memory-pressure-launchd.log</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
		<key>HOME</key>
		<string>${HOME}</string>
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
PLIST

	launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null || true
	launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"

	echo "Installed and loaded: ${LAUNCHD_LABEL}"
	echo "Plist: ${PLIST_PATH}"
	echo "Log: ${LOG_FILE}"
	echo "Check interval: 60 seconds"
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
	rm -f "${COOLDOWN_FILE_WARN}" "${COOLDOWN_FILE_CRIT}"
}

# --- Main ---------------------------------------------------------------------

main() {
	local cmd="${1:-check}"

	case "${cmd}" in
	--status | -s)
		cmd_status
		;;
	--daemon | -d)
		cmd_daemon
		;;
	--install | -i)
		cmd_install
		;;
	--uninstall | -u)
		cmd_uninstall
		;;
	check | --check | -c)
		do_check
		;;
	--help | -h)
		echo "Usage: ${SCRIPT_NAME}.sh [--check|--status|--daemon|--install|--uninstall|--help]"
		echo ""
		echo "  --check     Single check (default, for launchd)"
		echo "  --status    Print current memory state and monitor status"
		echo "  --daemon    Continuous monitoring (60s interval)"
		echo "  --install   Install launchd plist (runs every 60s)"
		echo "  --uninstall Remove launchd plist and state files"
		echo ""
		echo "Environment:"
		echo "  MEMORY_WARN_THRESHOLD   Warning level (default: 40)"
		echo "  MEMORY_CRIT_THRESHOLD   Critical level (default: 20)"
		echo "  MEMORY_COOLDOWN_SECS    Notification cooldown (default: 300)"
		echo "  MEMORY_NOTIFY           Set to 'false' to disable notifications"
		;;
	*)
		echo "Unknown command: ${cmd}" >&2
		echo "Run with --help for usage" >&2
		return 1
		;;
	esac
}

main "$@"
