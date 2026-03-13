#!/usr/bin/env bash
# =============================================================================
# Process Guard Helper - Monitor and kill runaway aidevops processes (t1398)
# =============================================================================
# Replaces the concept from PR #2792 (memory-pressure-monitor.sh) with a
# script that monitors the RIGHT signals: individual process RSS, process
# runtime, process count, and session count — not kern.memorystatus_level.
#
# Usage:
#   process-guard-helper.sh scan              # One-shot scan and report
#   process-guard-helper.sh kill-runaways     # Kill processes exceeding limits
#   process-guard-helper.sh sessions          # Report interactive session count
#   process-guard-helper.sh status            # Full status report (JSON)
#   process-guard-helper.sh help
#
# Integration:
#   - pulse-wrapper.sh calls guard_child_processes() every 60s (inline)
#   - This script provides standalone/cron usage for the same logic
#   - Cron: */5 * * * * ~/.aidevops/agents/scripts/process-guard-helper.sh kill-runaways
#
# Configuration (environment variables):
#   CHILD_RSS_LIMIT_KB     - Max RSS per child process (default: 2097152 = 2GB)
#   CHILD_RUNTIME_LIMIT    - Max runtime in seconds (default: 600 = 10min)
#   SHELLCHECK_RSS_LIMIT_KB - ShellCheck-specific RSS limit (default: 1048576 = 1GB)
#   SHELLCHECK_RUNTIME_LIMIT - ShellCheck-specific runtime (default: 300 = 5min)
#   SESSION_COUNT_WARN     - Warn when >N interactive sessions (default: 5)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Source shared constants for print_* functions
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Validate integer config: prevents command injection via arithmetic expansion.
# Same pattern as pulse-wrapper.sh _validate_int.
_validate_int() {
	local name="$1" value="$2" default="$3" min="${4:-0}"
	if ! [[ "$value" =~ ^[0-9]+$ ]]; then
		echo "[process-guard] Invalid ${name}: ${value} — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	local canonical
	canonical=$(printf '%d' "$((10#$value))")
	if ((canonical < min)); then
		echo "[process-guard] ${name}=${canonical} below minimum ${min} — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	printf '%s' "$canonical"
	return 0
}

# Configuration defaults
CHILD_RSS_LIMIT_KB="${CHILD_RSS_LIMIT_KB:-2097152}"
CHILD_RUNTIME_LIMIT="${CHILD_RUNTIME_LIMIT:-600}"
SHELLCHECK_RSS_LIMIT_KB="${SHELLCHECK_RSS_LIMIT_KB:-1048576}"
SHELLCHECK_RUNTIME_LIMIT="${SHELLCHECK_RUNTIME_LIMIT:-300}"
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-5}"

# Validate all numeric config to prevent command injection via arithmetic expansion
CHILD_RSS_LIMIT_KB=$(_validate_int CHILD_RSS_LIMIT_KB "$CHILD_RSS_LIMIT_KB" 2097152 1)
CHILD_RUNTIME_LIMIT=$(_validate_int CHILD_RUNTIME_LIMIT "$CHILD_RUNTIME_LIMIT" 600 1)
SHELLCHECK_RSS_LIMIT_KB=$(_validate_int SHELLCHECK_RSS_LIMIT_KB "$SHELLCHECK_RSS_LIMIT_KB" 1048576 1)
SHELLCHECK_RUNTIME_LIMIT=$(_validate_int SHELLCHECK_RUNTIME_LIMIT "$SHELLCHECK_RUNTIME_LIMIT" 300 1)
SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 5 1)

LOGFILE="${HOME}/.aidevops/logs/process-guard.log"

mkdir -p "$(dirname "$LOGFILE")" || true

#######################################
# List aidevops-related processes using pgrep (SC2009: avoids ps|grep)
# Output: ps fields (pid,ppid,tty,rss,etime,command) for matching processes
#######################################
_list_ai_processes() {
	# pgrep -f matches against the full command line; -d, separates PIDs with commas.
	# We use pgrep to find PIDs, then pass them directly to ps — no grep needed.
	local pids
	pids=$(pgrep -f 'opencode|shellcheck|node.*opencode' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
	if [[ -z "$pids" ]]; then
		return 0
	fi
	ps -p "$pids" -o pid=,ppid=,tty=,rss=,etime=,command= 2>/dev/null || true
	return 0
}

#######################################
# Get process age in seconds (portable macOS + Linux)
# Arguments:
#   $1 - PID
# Output: elapsed seconds via stdout
#######################################
_get_process_age() {
	local pid="$1"
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

	local colons_only="${etime//[!:]/}"
	local colon_count="${#colons_only}"

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

#######################################
# Scan all aidevops-related processes and report status
# Output: human-readable report to stdout
#######################################
cmd_scan() {
	echo "=== Process Guard Scan ==="
	echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo ""

	# Find all opencode/node processes related to aidevops
	local total_rss_kb=0
	local process_count=0
	local violations=0

	echo "--- AI Processes ---"
	printf "%-8s %-6s %-6s %-10s %-5s %-12s %-8s %s\n" "PID" "PPID" "RSS_MB" "RUNTIME" "TTY" "COMMAND" "STATUS" "DETAIL"

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Fields: pid, ppid, tty, rss, etime, command (command is last — may contain spaces)
		local pid ppid tty rss etime cmd_full
		read -r pid ppid tty rss etime cmd_full <<<"$line"

		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0

		# Extract basename for limit selection (e.g., /usr/bin/shellcheck → shellcheck)
		local cmd_base="${cmd_full%% *}"
		cmd_base="${cmd_base##*/}"

		local rss_mb=$((rss / 1024))
		total_rss_kb=$((total_rss_kb + rss))
		process_count=$((process_count + 1))

		local age_seconds
		age_seconds=$(_get_process_age "$pid")

		local rss_limit="$CHILD_RSS_LIMIT_KB"
		local runtime_limit="$CHILD_RUNTIME_LIMIT"
		if [[ "$cmd_base" == "shellcheck" ]]; then
			rss_limit="$SHELLCHECK_RSS_LIMIT_KB"
			runtime_limit="$SHELLCHECK_RUNTIME_LIMIT"
		fi

		local status="OK"
		local detail=""
		# TTY-attached processes are interactive — report but don't flag as violations
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			status="INTERACTIVE"
			detail="TTY=$tty (protected)"
		elif [[ "$rss" -gt "$rss_limit" ]]; then
			status="OVER_RSS"
			detail="RSS ${rss_mb}MB > $((rss_limit / 1024))MB"
			violations=$((violations + 1))
		elif [[ "$age_seconds" -gt "$runtime_limit" ]]; then
			status="OVER_TIME"
			detail="runtime ${age_seconds}s > ${runtime_limit}s"
			violations=$((violations + 1))
		elif [[ "$cmd_base" == "shellcheck" ]]; then
			[[ "$ppid" =~ ^[0-9]+$ ]] || ppid=0
			if [[ "$ppid" -eq 1 ]] && [[ "$age_seconds" -gt 120 ]]; then
				status="ORPHAN"
				detail="ppid=1, age=${age_seconds}s (no consumer)"
				violations=$((violations + 1))
			fi
		fi

		printf "%-8s %-6s %-6s %-10s %-5s %-12s %-8s %s\n" "$pid" "$ppid" "${rss_mb}MB" "$etime" "$tty" "$cmd_base" "$status" "$detail"
	done < <(_list_ai_processes)

	echo ""
	echo "Total: ${process_count} processes, $((total_rss_kb / 1024))MB RSS, ${violations} violation(s)"

	# Session count
	echo ""
	echo "--- Interactive Sessions ---"
	local session_count
	session_count=$(ps axo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || session_count=0
	echo "Interactive sessions: ${session_count} (threshold: ${SESSION_COUNT_WARN})"
	if [[ "$session_count" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "WARNING: Session count exceeds threshold. Each session uses 100-440MB + language servers."
	fi

	return 0
}

#######################################
# Kill processes exceeding RSS or runtime limits
# Output: report of killed processes
#######################################
cmd_kill_runaways() {
	local killed=0
	local total_freed_mb=0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Fields: pid, ppid, tty, rss, etime, command (command is last — may contain spaces)
		local pid ppid tty rss etime cmd_full
		read -r pid ppid tty rss etime cmd_full <<<"$line"

		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0

		# Skip TTY-attached processes — these are interactive user sessions
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			continue
		fi

		local cmd_base="${cmd_full%% *}"
		cmd_base="${cmd_base##*/}"

		local age_seconds
		age_seconds=$(_get_process_age "$pid")

		local rss_limit="$CHILD_RSS_LIMIT_KB"
		local runtime_limit="$CHILD_RUNTIME_LIMIT"
		if [[ "$cmd_base" == "shellcheck" ]]; then
			rss_limit="$SHELLCHECK_RSS_LIMIT_KB"
			runtime_limit="$SHELLCHECK_RUNTIME_LIMIT"
		fi

		local violation=""
		if [[ "$rss" -gt "$rss_limit" ]]; then
			local rss_mb=$((rss / 1024))
			violation="RSS ${rss_mb}MB > $((rss_limit / 1024))MB"
		elif [[ "$age_seconds" -gt "$runtime_limit" ]]; then
			violation="runtime ${age_seconds}s > ${runtime_limit}s"
		fi

		# Orphan shellcheck reaper: if parent is PID 1 (reparented because the
		# language server that spawned it exited) and alive >120s, kill it.
		# Nobody is reading the output, so the work is wasted CPU.
		if [[ -z "$violation" ]] && [[ "$cmd_base" == "shellcheck" ]]; then
			[[ "$ppid" =~ ^[0-9]+$ ]] || ppid=0
			if [[ "$ppid" -eq 1 ]] && [[ "$age_seconds" -gt 120 ]]; then
				violation="orphan (ppid=1, age=${age_seconds}s)"
			fi
		fi

		if [[ -n "$violation" ]]; then
			local rss_mb=$((rss / 1024))
			echo "Killing PID $pid ($cmd_base) — $violation"
			echo "[process-guard] Killing PID $pid ($cmd_base) — $violation" >>"$LOGFILE"
			kill "$pid" 2>/dev/null || true
			sleep 1
			if kill -0 "$pid" 2>/dev/null; then
				kill -9 "$pid" 2>/dev/null || true
			fi
			killed=$((killed + 1))
			total_freed_mb=$((total_freed_mb + rss_mb))
		fi
	done < <(_list_ai_processes)

	if [[ "$killed" -gt 0 ]]; then
		echo "Killed $killed process(es), freed ~${total_freed_mb}MB"
		echo "[process-guard] Killed $killed process(es), freed ~${total_freed_mb}MB" >>"$LOGFILE"
	else
		echo "No runaway processes found"
	fi
	return 0
}

#######################################
# Report interactive session count
#######################################
cmd_sessions() {
	local session_count
	session_count=$(ps axo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || session_count=0

	echo "$session_count"

	if [[ "$session_count" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "WARNING: $session_count sessions open (threshold: $SESSION_COUNT_WARN)" >&2
		echo "Each session consumes 100-440MB + language servers (~50-100MB each)." >&2
		echo "Consider closing unused terminal tabs." >&2
		return 1
	fi
	return 0
}

#######################################
# Full status report in JSON format
#######################################
cmd_status() {
	local total_rss_kb=0
	local process_count=0
	local violations=0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Fields: pid, ppid, tty, rss, etime, command (command is last — may contain spaces)
		local pid ppid tty rss etime cmd_full
		read -r pid ppid tty rss etime cmd_full <<<"$line"
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		total_rss_kb=$((total_rss_kb + rss))
		process_count=$((process_count + 1))

		# Skip TTY-attached processes — interactive user sessions
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			continue
		fi

		local cmd_base="${cmd_full%% *}"
		cmd_base="${cmd_base##*/}"
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		local rss_limit="$CHILD_RSS_LIMIT_KB"
		local runtime_limit="$CHILD_RUNTIME_LIMIT"
		if [[ "$cmd_base" == "shellcheck" ]]; then
			rss_limit="$SHELLCHECK_RSS_LIMIT_KB"
			runtime_limit="$SHELLCHECK_RUNTIME_LIMIT"
		fi
		if [[ "$rss" -gt "$rss_limit" ]] || [[ "$age_seconds" -gt "$runtime_limit" ]]; then
			violations=$((violations + 1))
		elif [[ "$cmd_base" == "shellcheck" ]]; then
			[[ "$ppid" =~ ^[0-9]+$ ]] || ppid=0
			if [[ "$ppid" -eq 1 ]] && [[ "$age_seconds" -gt 120 ]]; then
				violations=$((violations + 1))
			fi
		fi
	done < <(_list_ai_processes)

	local session_count
	session_count=$(ps axo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || session_count=0

	# Available memory (Linux)
	local mem_avail_mb="unknown"
	if [[ -f /proc/meminfo ]]; then
		mem_avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "unknown")
	elif [[ "$(uname)" == "Darwin" ]]; then
		local page_size vm_free vm_inactive
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "16384")
		vm_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		vm_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=16384
		[[ "$vm_free" =~ ^[0-9]+$ ]] || vm_free=0
		[[ "$vm_inactive" =~ ^[0-9]+$ ]] || vm_inactive=0
		mem_avail_mb=$(((vm_free + vm_inactive) * page_size / 1048576))
	fi

	printf '{"timestamp":"%s","process_count":%d,"total_rss_mb":%d,"violations":%d,"session_count":%d,"session_warn_threshold":%d,"mem_available_mb":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$process_count" \
		"$((total_rss_kb / 1024))" \
		"$violations" \
		"$session_count" \
		"$SESSION_COUNT_WARN" \
		"$mem_avail_mb"
	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	echo "process-guard-helper.sh — Monitor and kill runaway aidevops processes (t1398)"
	echo ""
	echo "Usage:"
	echo "  process-guard-helper.sh scan              One-shot scan and report"
	echo "  process-guard-helper.sh kill-runaways     Kill processes exceeding limits"
	echo "  process-guard-helper.sh sessions          Report interactive session count"
	echo "  process-guard-helper.sh status            Full status report (JSON)"
	echo "  process-guard-helper.sh help              Show this help"
	echo ""
	echo "Configuration (environment variables):"
	echo "  CHILD_RSS_LIMIT_KB=${CHILD_RSS_LIMIT_KB} ($((CHILD_RSS_LIMIT_KB / 1024))MB)"
	echo "  CHILD_RUNTIME_LIMIT=${CHILD_RUNTIME_LIMIT}s"
	echo "  SHELLCHECK_RSS_LIMIT_KB=${SHELLCHECK_RSS_LIMIT_KB} ($((SHELLCHECK_RSS_LIMIT_KB / 1024))MB)"
	echo "  SHELLCHECK_RUNTIME_LIMIT=${SHELLCHECK_RUNTIME_LIMIT}s"
	echo "  SESSION_COUNT_WARN=${SESSION_COUNT_WARN}"
	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	local command="${1:-help}"

	case "$command" in
	scan) cmd_scan ;;
	kill-runaways) cmd_kill_runaways ;;
	sessions) cmd_sessions ;;
	status) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "Unknown command: $command" >&2
		cmd_help >&2
		return 1
		;;
	esac
}

main "$@"
