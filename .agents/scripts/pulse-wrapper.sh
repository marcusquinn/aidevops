#!/usr/bin/env bash
# pulse-wrapper.sh - Wrapper for supervisor pulse with dedup and lifecycle management
#
# Solves: opencode run enters idle state after completing the pulse prompt
# but never exits, blocking all future pulses via the pgrep dedup guard.
#
# This wrapper:
#   1. Uses a PID file with staleness check (not pgrep) for dedup
#   2. Cleans up orphaned opencode processes before each pulse
#   3. Calculates dynamic worker concurrency from available RAM
#   4. Lets the pulse run to completion — no hard timeout
#
# Lifecycle: launchd fires every 120s. If a pulse is still running, the
# dedup check skips. If a pulse has been running longer than PULSE_STALE_THRESHOLD
# (default 30 min), it's assumed stuck (opencode idle bug) and killed so the
# next invocation can start fresh. This is the ONLY kill mechanism — no
# arbitrary timeouts that would interrupt active work.
#
# Called by launchd every 120s via the supervisor-pulse plist.

set -euo pipefail

#######################################
# Configuration
#######################################
PULSE_STALE_THRESHOLD="${PULSE_STALE_THRESHOLD:-1800}" # 30 min = definitely stuck (opencode idle bug)

# Validate numeric configuration
if ! [[ "$PULSE_STALE_THRESHOLD" =~ ^[0-9]+$ ]]; then
	echo "[pulse-wrapper] Invalid PULSE_STALE_THRESHOLD: $PULSE_STALE_THRESHOLD — using default 1800" >&2
	PULSE_STALE_THRESHOLD=1800
fi
PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
OPENCODE_BIN="${OPENCODE_BIN:-/opt/homebrew/bin/opencode}"
PULSE_DIR="${PULSE_DIR:-${HOME}/Git/aidevops}"
PULSE_MODEL="${PULSE_MODEL:-anthropic/claude-sonnet-4-6}"
ORPHAN_MAX_AGE="${ORPHAN_MAX_AGE:-7200}"       # 2 hours — kill orphans older than this
RAM_PER_WORKER_MB="${RAM_PER_WORKER_MB:-1024}" # 1 GB per worker
RAM_RESERVE_MB="${RAM_RESERVE_MB:-8192}"       # 8 GB reserved for OS + user apps
MAX_WORKERS_CAP="${MAX_WORKERS_CAP:-8}"        # Hard ceiling regardless of RAM

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
	# Find all child processes recursively (bash 3.2 compatible — no mapfile)
	local child
	while IFS= read -r child; do
		[[ -n "$child" ]] && _kill_tree "$child"
	done < <(pgrep -P "$pid" 2>/dev/null || true)
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
	local child
	while IFS= read -r child; do
		[[ -n "$child" ]] && _force_kill_tree "$child"
	done < <(pgrep -P "$pid" 2>/dev/null || true)
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
	etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ') || etime=""

	if [[ -z "$etime" ]]; then
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
# Run the pulse — no hard timeout
#
# The pulse runs until opencode exits naturally. If opencode enters its
# idle-state bug (file watcher keeps process alive after session completes),
# the NEXT launchd invocation's check_dedup() will detect the stale process
# (age > PULSE_STALE_THRESHOLD) and kill it. This is correct because:
#   - Active pulses doing real work are never interrupted
#   - Stuck pulses are detected by the next invocation (120s later)
#   - The stale threshold (30 min) is generous enough for any real workload
#######################################
run_pulse() {
	local start_epoch
	start_epoch=$(date +%s)
	echo "[pulse-wrapper] Starting pulse at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOGFILE"

	# Run opencode — blocks until it exits (or is killed by next invocation's stale check)
	"$OPENCODE_BIN" run "/pulse" \
		--dir "$PULSE_DIR" \
		-m "$PULSE_MODEL" \
		--title "Supervisor Pulse" \
		>>"$LOGFILE" 2>&1 &

	local opencode_pid=$!
	echo "$opencode_pid" >"$PIDFILE"

	echo "[pulse-wrapper] opencode PID: $opencode_pid" >>"$LOGFILE"

	# Wait for natural exit
	wait "$opencode_pid" 2>/dev/null || true

	# Clean up PID file
	rm -f "$PIDFILE"

	local end_epoch
	end_epoch=$(date +%s)
	local duration=$((end_epoch - start_epoch))
	echo "[pulse-wrapper] Pulse completed at $(date -u +%Y-%m-%dT%H:%M:%SZ) (ran ${duration}s)" >>"$LOGFILE"
	return 0
}

#######################################
# Main
#######################################
main() {
	if ! check_dedup; then
		return 0
	fi

	cleanup_orphans
	calculate_max_workers
	run_pulse
	return 0
}

#######################################
# Kill orphaned opencode processes
#
# Criteria (ALL must be true):
#   - No TTY (headless — not a user's terminal tab)
#   - Not a current worker (/full-loop not in command)
#   - Not the supervisor pulse (Supervisor Pulse not in command)
#   - Not a strategic review (Strategic Review not in command)
#   - Older than ORPHAN_MAX_AGE seconds
#
# These are completed headless sessions where opencode entered idle
# state with a file watcher and never exited.
#######################################
cleanup_orphans() {
	local killed=0
	local total_mb=0

	while IFS= read -r line; do
		local pid tty etime rss cmd
		pid=$(echo "$line" | awk '{print $1}')
		tty=$(echo "$line" | awk '{print $2}')
		etime=$(echo "$line" | awk '{print $3}')
		rss=$(echo "$line" | awk '{print $4}')
		cmd=$(echo "$line" | cut -d' ' -f5-)

		# Skip interactive sessions (has a real TTY)
		if [[ "$tty" != "??" ]]; then
			continue
		fi

		# Skip active workers, pulse, strategic reviews, and language servers
		if echo "$cmd" | grep -qE '/full-loop|Supervisor Pulse|Strategic Review|language-server|eslintServer'; then
			continue
		fi

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]]; then
			continue
		fi

		# This is an orphan — kill it
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep '\.opencode' | grep -v grep | grep -v 'bash-language-server')

	# Also kill orphaned node launchers (parent of .opencode processes)
	while IFS= read -r line; do
		local pid tty etime rss cmd
		pid=$(echo "$line" | awk '{print $1}')
		tty=$(echo "$line" | awk '{print $2}')
		etime=$(echo "$line" | awk '{print $3}')
		rss=$(echo "$line" | awk '{print $4}')
		cmd=$(echo "$line" | cut -d' ' -f5-)

		[[ "$tty" != "??" ]] && continue
		echo "$cmd" | grep -qE '/full-loop|Supervisor Pulse|Strategic Review|language-server|eslintServer' && continue

		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		[[ "$age_seconds" -lt "$ORPHAN_MAX_AGE" ]] && continue

		kill "$pid" 2>/dev/null || true
		local mb=$((rss / 1024))
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axo pid,tty,etime,rss,command | grep 'node.*opencode' | grep -v grep | grep -v '\.opencode')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed orphaned opencode processes (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Calculate max workers from available RAM
#
# Formula: (free_ram - RAM_RESERVE_MB) / RAM_PER_WORKER_MB
# Clamped to [1, MAX_WORKERS_CAP]
#
# Writes MAX_WORKERS to a file that pulse.md reads via bash.
#######################################
calculate_max_workers() {
	local free_mb
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS: use vm_stat for free + inactive (reclaimable) pages
		local page_size free_pages inactive_pages
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
		free_pages=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		inactive_pages=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		free_mb=$(((free_pages + inactive_pages) * page_size / 1024 / 1024))
	else
		# Linux: use MemAvailable from /proc/meminfo
		free_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)
	fi

	local available_mb=$((free_mb - RAM_RESERVE_MB))
	local max_workers=$((available_mb / RAM_PER_WORKER_MB))

	# Clamp to [1, MAX_WORKERS_CAP]
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	elif [[ "$max_workers" -gt "$MAX_WORKERS_CAP" ]]; then
		max_workers="$MAX_WORKERS_CAP"
	fi

	# Write to a file that pulse.md can read
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	echo "$max_workers" >"$max_workers_file"

	echo "[pulse-wrapper] Available RAM: ${free_mb}MB, reserve: ${RAM_RESERVE_MB}MB, max workers: ${max_workers}" >>"$LOGFILE"
	return 0
}

main "$@"
