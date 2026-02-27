#!/usr/bin/env bash
# pulse-wrapper.sh - Wrapper for supervisor pulse with timeout and dedup
#
# Solves: opencode run enters idle state after completing the pulse prompt
# but never exits, blocking all future pulses via the pgrep dedup guard.
#
# This wrapper:
#   1. Uses a PID file with staleness check (not pgrep) for dedup
#   2. Runs opencode run with a hard timeout (default: 10 min)
#   3. Guarantees the process is killed if it hangs after completion
#
# Called by launchd every 120s via the supervisor-pulse plist.

set -euo pipefail

#######################################
# Configuration
#######################################
PULSE_TIMEOUT="${PULSE_TIMEOUT:-600}"                 # 10 minutes max per pulse
PULSE_STALE_THRESHOLD="${PULSE_STALE_THRESHOLD:-900}" # 15 min = definitely stuck
PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
OPENCODE_BIN="${OPENCODE_BIN:-/opt/homebrew/bin/opencode}"
PULSE_DIR="${PULSE_DIR:-${HOME}/Git/aidevops}"
PULSE_MODEL="${PULSE_MODEL:-anthropic/claude-sonnet-4-6}"

#######################################
# Ensure log directory exists
#######################################
mkdir -p "$(dirname "$PIDFILE")"

#######################################
# Check for stale PID file and clean up
# Returns: 0 if safe to proceed, 1 if another pulse is genuinely running
#######################################
check_dedup() {
	if [[ ! -f "$PIDFILE" ]]; then
		return 0
	fi

	local old_pid
	old_pid=$(cat "$PIDFILE" 2>/dev/null || echo "")

	if [[ -z "$old_pid" ]]; then
		rm -f "$PIDFILE"
		return 0
	fi

	# Check if the process is still running
	if ! kill -0 "$old_pid" 2>/dev/null; then
		# Process is dead, clean up stale PID file
		rm -f "$PIDFILE"
		return 0
	fi

	# Process is running — check how long
	local elapsed_seconds
	elapsed_seconds=$(_get_process_age "$old_pid")

	if [[ "$elapsed_seconds" -gt "$PULSE_STALE_THRESHOLD" ]]; then
		# Process has been running too long — it's stuck
		echo "[pulse-wrapper] Killing stale pulse process $old_pid (running ${elapsed_seconds}s, threshold ${PULSE_STALE_THRESHOLD}s)" >>"$LOGFILE"
		_kill_tree "$old_pid"
		sleep 2
		# Force kill if still alive
		if kill -0 "$old_pid" 2>/dev/null; then
			_force_kill_tree "$old_pid"
		fi
		rm -f "$PIDFILE"
		return 0
	fi

	# Process is running and within time limit — genuine dedup
	echo "[pulse-wrapper] Pulse already running (PID $old_pid, ${elapsed_seconds}s elapsed). Skipping." >>"$LOGFILE"
	return 1
}

#######################################
# Kill a process and all its children (macOS-compatible)
# Arguments:
#   $1 - PID to kill
#######################################
_kill_tree() {
	local pid="$1"
	# Find all child processes recursively
	local children
	children=$(pgrep -P "$pid" 2>/dev/null || true)
	for child in $children; do
		_kill_tree "$child"
	done
	kill "$pid" 2>/dev/null || true
	return 0
}

#######################################
# Force kill a process and all its children
# Arguments:
#   $1 - PID to kill
#######################################
_force_kill_tree() {
	local pid="$1"
	local children
	children=$(pgrep -P "$pid" 2>/dev/null || true)
	for child in $children; do
		_force_kill_tree "$child"
	done
	kill -9 "$pid" 2>/dev/null || true
	return 0
}

#######################################
# Get process age in seconds
# Arguments:
#   $1 - PID
# Returns: elapsed seconds via stdout
#######################################
_get_process_age() {
	local pid="$1"
	local etime
	# macOS ps etime format: MM:SS or HH:MM:SS or D-HH:MM:SS
	etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ') || echo "0"

	if [[ -z "$etime" || "$etime" == "0" ]]; then
		echo "0"
		return 0
	fi

	local days=0 hours=0 minutes=0 seconds=0

	# Parse D-HH:MM:SS format
	if [[ "$etime" == *-* ]]; then
		days="${etime%%-*}"
		etime="${etime#*-}"
	fi

	# Count colons to determine format
	local colon_count
	colon_count=$(echo "$etime" | tr -cd ':' | wc -c | tr -d ' ')

	if [[ "$colon_count" -eq 2 ]]; then
		# HH:MM:SS
		IFS=':' read -r hours minutes seconds <<<"$etime"
	elif [[ "$colon_count" -eq 1 ]]; then
		# MM:SS
		IFS=':' read -r minutes seconds <<<"$etime"
	else
		seconds="$etime"
	fi

	# Remove leading zeros to avoid octal interpretation
	days=$((10#${days}))
	hours=$((10#${hours}))
	minutes=$((10#${minutes}))
	seconds=$((10#${seconds}))

	echo $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
	return 0
}

#######################################
# Run the pulse with timeout
#######################################
run_pulse() {
	echo "[pulse-wrapper] Starting pulse at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOGFILE"

	# Start opencode run in background
	"$OPENCODE_BIN" run "/pulse" \
		--dir "$PULSE_DIR" \
		-m "$PULSE_MODEL" \
		--title "Supervisor Pulse" \
		>>"$LOGFILE" 2>&1 &

	local opencode_pid=$!
	echo "$opencode_pid" >"$PIDFILE"

	echo "[pulse-wrapper] opencode PID: $opencode_pid, timeout: ${PULSE_TIMEOUT}s" >>"$LOGFILE"

	# Wait for completion OR timeout
	local waited=0
	local check_interval=5

	while kill -0 "$opencode_pid" 2>/dev/null; do
		if [[ "$waited" -ge "$PULSE_TIMEOUT" ]]; then
			echo "[pulse-wrapper] Timeout after ${PULSE_TIMEOUT}s — killing opencode PID $opencode_pid and children" >>"$LOGFILE"
			_kill_tree "$opencode_pid"
			sleep 2
			# Force kill if graceful shutdown didn't work
			if kill -0 "$opencode_pid" 2>/dev/null; then
				echo "[pulse-wrapper] Force killing PID $opencode_pid" >>"$LOGFILE"
				_force_kill_tree "$opencode_pid"
			fi
			break
		fi
		sleep "$check_interval"
		waited=$((waited + check_interval))
	done

	# Clean up PID file
	rm -f "$PIDFILE"

	# Wait to collect exit status (avoid zombie)
	wait "$opencode_pid" 2>/dev/null || true

	echo "[pulse-wrapper] Pulse completed at $(date -u +%Y-%m-%dT%H:%M:%SZ) (ran ${waited}s)" >>"$LOGFILE"
	return 0
}

#######################################
# Main
#######################################
main() {
	if ! check_dedup; then
		return 0
	fi

	run_pulse
	return 0
}

main "$@"
