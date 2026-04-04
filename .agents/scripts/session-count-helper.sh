#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Session Count Helper (t1398.4)
# =============================================================================
# Counts concurrent interactive AI coding sessions and warns when the count
# exceeds a configurable threshold (default: 5).
#
# Interactive sessions are AI coding assistants running in a terminal (TUI),
# as opposed to headless workers dispatched via `opencode run` or `claude -p`.
#
# Usage:
#   session-count-helper.sh count          # Print session count
#   session-count-helper.sh check          # Check against threshold, warn if exceeded
#   session-count-helper.sh list           # List detected sessions with details
#   session-count-helper.sh help           # Show usage
#
# Configuration:
#   Config key: safety.max_interactive_sessions (default: 5, 0 = disabled)
#   Env override: AIDEVOPS_MAX_SESSIONS
#
# Exit codes:
#   0 - OK (count within threshold, or check disabled)
#   1 - Warning (count exceeds threshold)
#   2 - Error (invalid usage)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared constants for config_get, colors, logging
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Session Detection (t1665.5 — registry-driven)
# =============================================================================
# Detects interactive AI coding sessions by examining running processes.
# Distinguishes interactive (TUI) sessions from headless workers using
# per-runtime patterns from the runtime registry.

# Get system RAM in GB (used as default session threshold).
# Each session uses ~100-400 MB, so RAM in GB is a reasonable max.
get_system_ram_gb() {
	local ram_gb=16
	if [[ "$(uname)" == "Darwin" ]]; then
		local ram_bytes
		ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
		if [[ "$ram_bytes" -gt 0 ]]; then
			ram_gb=$((ram_bytes / 1073741824))
		fi
	elif [[ -f /proc/meminfo ]]; then
		local ram_kb
		ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
		if [[ "$ram_kb" -gt 0 ]]; then
			ram_gb=$((ram_kb / 1048576))
		fi
	fi
	echo "$ram_gb"
	return 0
}

# Get the configured maximum session count.
# Priority: env var > JSONC config > default (system RAM in GB)
get_max_sessions() {
	# Environment variable override (highest priority)
	if [[ -n "${AIDEVOPS_MAX_SESSIONS:-}" ]]; then
		echo "$AIDEVOPS_MAX_SESSIONS"
		return 0
	fi

	# JSONC config system
	if type config_get &>/dev/null; then
		local val
		val=$(config_get "safety.max_interactive_sessions" "")
		if [[ -n "$val" && "$val" != "5" ]]; then
			# User explicitly configured a value (not the old default)
			echo "$val"
			return 0
		fi
	fi

	# Default: system RAM in GB (e.g., 64 GB RAM = threshold of 64)
	get_system_ram_gb
	return 0
}

# Read the command line for a given PID.
# Uses /proc/PID/cmdline on Linux, ps on macOS.
# Outputs the cmdline string on stdout; empty string if PID has exited.
_get_pid_cmdline() {
	local pid="$1"
	local cmdline=""
	if [[ -r "/proc/${pid}/cmdline" ]]; then
		# Linux: /proc/PID/cmdline has null-separated args
		cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
	else
		# macOS fallback: ps -o args= (2>/dev/null: PID may have exited)
		cmdline=$(ps -o args= -p "$pid" 2>/dev/null || true)
	fi
	echo "$cmdline"
	return 0
}

# Count interactive sessions for a single runtime using registry properties.
# Args: $1 = runtime ID
# Outputs the count on stdout.
_count_runtime_sessions() {
	local rt_id="$1"
	local count=0

	local pgrep_mode pgrep_pat headless_pat exclusion_pat
	pgrep_mode=$(rt_pgrep_mode "$rt_id") || return 0
	pgrep_pat=$(rt_pgrep_pattern "$rt_id") || return 0
	headless_pat=$(rt_headless_cmdline_pattern "$rt_id") || true
	exclusion_pat=$(rt_process_exclusion "$rt_id") || true

	[[ -z "$pgrep_pat" ]] && {
		echo "0"
		return 0
	}

	# Find matching PIDs
	local pids=""
	if [[ "$pgrep_mode" == "x" ]]; then
		pids=$(pgrep -x "$pgrep_pat" || true)
	else
		pids=$(pgrep -f "$pgrep_pat" || true)
	fi

	if [[ -z "$pids" ]]; then
		echo "0"
		return 0
	fi

	local pid cmdline
	while IFS= read -r pid; do
		[[ -z "$pid" ]] && continue
		cmdline=$(_get_pid_cmdline "$pid")

		# Skip headless workers if pattern is defined
		if [[ -n "$headless_pat" ]] && echo "$cmdline" | grep -qE "$headless_pat"; then
			continue
		fi

		# Skip noise processes (language servers, wrappers, etc.)
		if [[ -n "$exclusion_pat" ]] && echo "$cmdline" | grep -qE "$exclusion_pat"; then
			continue
		fi

		count=$((count + 1))
	done <<<"$pids"

	echo "$count"
	return 0
}

# Count interactive AI sessions across all registered runtimes.
# Returns the count on stdout.
count_interactive_sessions() {
	local count=0

	if type rt_list_ids &>/dev/null; then
		local rt_id n
		while IFS= read -r rt_id; do
			n=$(_count_runtime_sessions "$rt_id")
			count=$((count + n))
		done < <(rt_list_ids)
	fi

	echo "$count"
	return 0
}

# Print session details for a given PID and app name.
# Uses 2>/dev/null on ps calls because the PID may have exited
# between detection and inspection (race condition).
_print_session_detail() {
	local pid="$1"
	local app_name="$2"
	local rss_mb etime
	rss_mb=$(ps -o rss= -p "$pid" 2>/dev/null || echo "0")
	rss_mb=$((${rss_mb:-0} / 1024))
	etime=$(ps -o etime= -p "$pid" 2>/dev/null || echo "unknown")
	etime=$(echo "$etime" | tr -d ' ')
	echo "  PID ${pid} | ${app_name} | ${rss_mb} MB | uptime: ${etime}"
	return 0
}

# List interactive sessions for a single runtime with details.
# Args: $1 = runtime ID
# Returns number of sessions found via exit code.
_list_runtime_sessions() {
	local rt_id="$1"
	local found=0

	local display_name pgrep_mode pgrep_pat headless_pat exclusion_pat
	display_name=$(rt_display_name "$rt_id") || display_name="$rt_id"
	pgrep_mode=$(rt_pgrep_mode "$rt_id") || return 0
	pgrep_pat=$(rt_pgrep_pattern "$rt_id") || return 0
	headless_pat=$(rt_headless_cmdline_pattern "$rt_id") || true
	exclusion_pat=$(rt_process_exclusion "$rt_id") || true

	[[ -z "$pgrep_pat" ]] && return 0

	# Find matching PIDs
	local pids=""
	if [[ "$pgrep_mode" == "x" ]]; then
		pids=$(pgrep -x "$pgrep_pat" || true)
	else
		pids=$(pgrep -f "$pgrep_pat" || true)
	fi

	[[ -z "$pids" ]] && return 0

	local pid cmdline
	while IFS= read -r pid; do
		[[ -z "$pid" ]] && continue
		cmdline=$(_get_pid_cmdline "$pid")

		# Skip headless workers
		if [[ -n "$headless_pat" ]] && echo "$cmdline" | grep -qE "$headless_pat"; then
			continue
		fi

		# Skip noise processes
		if [[ -n "$exclusion_pat" ]] && echo "$cmdline" | grep -qE "$exclusion_pat"; then
			continue
		fi

		_print_session_detail "$pid" "$display_name"
		found=$((found + 1))
	done <<<"$pids"

	return "$found"
}

# List detected interactive sessions with details.
# Output format: PID | APP | RSS_MB | UPTIME
list_sessions() {
	local found=0

	if type rt_list_ids &>/dev/null; then
		local rt_id n
		while IFS= read -r rt_id; do
			n=0
			_list_runtime_sessions "$rt_id" || n=$?
			found=$((found + n))
		done < <(rt_list_ids)
	fi

	if [[ "$found" -eq 0 ]]; then
		echo "  No interactive AI sessions detected"
	fi

	return 0
}

# Check session count against threshold and output a warning if exceeded.
# Returns 0 if within threshold, 1 if exceeded.
check_sessions() {
	local max_sessions
	max_sessions=$(get_max_sessions)

	# Disabled if max is 0
	if [[ "$max_sessions" -eq 0 ]]; then
		return 0
	fi

	local session_count
	session_count=$(count_interactive_sessions)

	if [[ "$session_count" -gt "$max_sessions" ]]; then
		echo "SESSION_WARNING: ${session_count} interactive AI sessions detected (threshold: ${max_sessions}). Consider closing unused sessions to reduce memory pressure (~100-400 MB each)."
		return 1
	fi

	return 0
}

# =============================================================================
# CLI Interface
# =============================================================================

show_help() {
	echo "Usage: $(basename "$0") <command>"
	echo ""
	echo "Commands:"
	echo "  count    Print the number of interactive AI sessions"
	echo "  check    Check against threshold, warn if exceeded (exit 1)"
	echo "  list     List detected sessions with PID, app, RSS, uptime"
	echo "  help     Show this help"
	echo ""
	echo "Configuration:"
	echo "  Config key: safety.max_interactive_sessions (default: 5)"
	echo "  Env override: AIDEVOPS_MAX_SESSIONS (0 = disabled)"
	return 0
}

main() {
	local command="${1:-check}"

	case "$command" in
	count)
		count_interactive_sessions
		;;
	check)
		check_sessions
		;;
	list)
		echo "Interactive AI sessions:"
		list_sessions
		echo ""
		echo "Total: $(count_interactive_sessions) interactive | Threshold: $(get_max_sessions)"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 2
		;;
	esac
}

main "$@"
