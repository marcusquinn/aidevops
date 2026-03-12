#!/usr/bin/env bash
# stats-wrapper.sh - Separate process for statistics and health updates
#
# Runs quality sweep, health issue updates, and person-stats independently
# of the supervisor pulse. These operations depend on GitHub Search API
# (30 req/min limit) and can block for extended periods when rate-limited.
# Running them in-process with the pulse prevented dispatch and merge work
# from ever executing. See t1429 for the full root cause analysis.
#
# Called by cron/launchd every 15 minutes. Has its own PID dedup and hard timeout.

set -euo pipefail

#######################################
# PATH normalisation — same as pulse-wrapper.sh
#######################################
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
# in zsh (MCP shell environment). See GH#3931.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || return 2>/dev/null || exit
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

#######################################
# Configuration
#######################################
STATS_TIMEOUT="${STATS_TIMEOUT:-600}" # 10 min hard ceiling
STATS_TIMEOUT=$(_validate_int STATS_TIMEOUT "$STATS_TIMEOUT" 600 60)

STATS_PIDFILE="${HOME}/.aidevops/logs/stats.pid"
STATS_LOGFILE="${HOME}/.aidevops/logs/stats.log"

mkdir -p "$(dirname "$STATS_PIDFILE")"

#######################################
# Portable elapsed-seconds lookup for a running PID
#######################################
_stats_process_elapsed_seconds() {
	local pid="$1"
	local elapsed=""

	elapsed=$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d '[:space:]' || true)
	if [[ "$elapsed" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$elapsed"
		return 0
	fi

	local etime=""
	etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d '[:space:]' || true)
	if [[ -z "$etime" ]]; then
		return 1
	fi

	elapsed=$(awk -v value="$etime" '
		BEGIN {
			n = split(value, parts, /[-:]/)
			if (index(value, "-") > 0) {
				if (n != 4) { exit 1 }
				total = (parts[1] * 86400) + (parts[2] * 3600) + (parts[3] * 60) + parts[4]
			} else if (n == 3) {
				total = (parts[1] * 3600) + (parts[2] * 60) + parts[3]
			} else if (n == 2) {
				total = (parts[1] * 60) + parts[2]
			} else {
				exit 1
			}
			print total
		}
	' || true)

	if [[ "$elapsed" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$elapsed"
		return 0
	fi

	return 1
}

#######################################
# PID-based dedup — same pattern as pulse-wrapper check_dedup()
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

	# Prefer stored epoch, but validate it before use. Invalid epochs used to
	# compute huge elapsed values and incorrectly kill healthy stats workers.
	local now elapsed
	now=$(date +%s)
	if [[ "$old_epoch" =~ ^[0-9]+$ ]] && [[ "$old_epoch" -gt 0 ]] && [[ "$old_epoch" -le "$now" ]]; then
		elapsed=$((now - old_epoch))
	else
		elapsed=$(_stats_process_elapsed_seconds "$old_pid") || {
			if kill -0 "$old_pid" 2>/dev/null; then
				echo "[stats-wrapper] Unable to determine elapsed time for live PID $old_pid; preserving pidfile and skipping." >>"$STATS_LOGFILE"
				return 1
			fi
			rm -f "$STATS_PIDFILE"
			return 0
		}
	fi

	if [[ "$elapsed" -gt "$STATS_TIMEOUT" ]]; then
		echo "[stats-wrapper] Killing stale stats process $old_pid (${elapsed}s)" >>"$STATS_LOGFILE"
		_kill_tree "$old_pid" || true
		sleep 2
		if kill -0 "$old_pid" 2>/dev/null; then
			_force_kill_tree "$old_pid" || true
		fi
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

	# Source stats-functions.sh for health dashboard and quality sweep functions.
	# After t1431, these functions live in their own file instead of pulse-wrapper.sh.
	# LOGFILE is set to STATS_LOGFILE so all function logging goes to stats.log.
	LOGFILE="$STATS_LOGFILE"
	# shellcheck source=stats-functions.sh
	source "${SCRIPT_DIR}/stats-functions.sh" || {
		echo "[stats-wrapper] Failed to source stats-functions.sh" >>"$STATS_LOGFILE"
		return 1
	}

	run_daily_quality_sweep || true
	update_health_issues || true

	echo "[stats-wrapper] Finished at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATS_LOGFILE"
	return 0
}

# Shell-portable source detection — same as pulse-wrapper (GH#3931)
_stats_is_sourced() {
	if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
		[[ "${BASH_SOURCE[0]}" != "${0}" ]]
	elif [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
		[[ ":${ZSH_EVAL_CONTEXT}:" == *":file:"* ]]
	else
		return 1
	fi
}
if ! _stats_is_sourced; then
	main "$@"
fi
