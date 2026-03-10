#!/usr/bin/env bash
# stats-wrapper.sh - Separate process for statistics and health updates
#
# Runs quality sweep, health issue updates, and person-stats independently
# of the supervisor pulse. These operations depend on GitHub Search API
# (30 req/min limit) and can block for extended periods when rate-limited.
# Running them in-process with the pulse prevented dispatch and merge work
# from ever executing. See t1429 for the full root cause analysis.
#
# Called by cron every 15 minutes. Has its own PID dedup and hard timeout.

set -euo pipefail

export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

#######################################
# Configuration
#######################################
STATS_TIMEOUT="${STATS_TIMEOUT:-600}" # 10 min hard ceiling
STATS_PIDFILE="${HOME}/.aidevops/logs/stats.pid"
STATS_LOGFILE="${HOME}/.aidevops/logs/stats.log"

mkdir -p "$(dirname "$STATS_PIDFILE")"

#######################################
# PID-based dedup — same pattern as pulse-wrapper
#######################################
check_stats_dedup() {
	if [[ ! -f "$STATS_PIDFILE" ]]; then
		return 0
	fi

	# PID file format: "PID EPOCH" (PID + start timestamp)
	local old_pid old_epoch
	read -r old_pid old_epoch <"$STATS_PIDFILE" 2>/dev/null || {
		rm -f "$STATS_PIDFILE"
		return 0
	}

	if [[ -z "$old_pid" ]]; then
		rm -f "$STATS_PIDFILE"
		return 0
	fi

	if ! ps -p "$old_pid" >/dev/null 2>&1; then
		rm -f "$STATS_PIDFILE"
		return 0
	fi

	# Check age using stored epoch (portable — no date -d)
	old_epoch="${old_epoch:-0}"
	local now
	now=$(date +%s)
	local elapsed=$((now - old_epoch))

	if [[ "$elapsed" -gt "$STATS_TIMEOUT" ]]; then
		echo "[stats-wrapper] Killing stale stats process $old_pid (${elapsed}s)" >>"$STATS_LOGFILE"
		kill "$old_pid" 2>/dev/null || true
		sleep 2
		kill -9 "$old_pid" 2>/dev/null || true
		rm -f "$STATS_PIDFILE"
		return 0
	fi

	echo "[stats-wrapper] Stats already running (PID $old_pid, ${elapsed}s). Skipping." >>"$STATS_LOGFILE"
	return 1
}

#######################################
# Main
#######################################
main() {
	if ! check_stats_dedup; then
		return 0
	fi

	echo "$$ $(date +%s)" >"$STATS_PIDFILE"
	trap 'rm -f "$STATS_PIDFILE"' EXIT

	echo "[stats-wrapper] Starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATS_LOGFILE"

	# Source pulse-wrapper to reuse its functions
	# (update_health_issues, run_daily_quality_sweep, etc.)
	# pulse-wrapper.sh has a source guard — main() won't execute on source.
	# shellcheck source=pulse-wrapper.sh
	source "${SCRIPT_DIR}/pulse-wrapper.sh" || {
		echo "[stats-wrapper] Failed to source pulse-wrapper.sh" >>"$STATS_LOGFILE"
		return 1
	}

	run_daily_quality_sweep || true
	update_health_issues || true

	echo "[stats-wrapper] Finished at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATS_LOGFILE"
	return 0
}

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
	main
fi
