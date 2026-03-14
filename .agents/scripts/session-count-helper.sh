#!/usr/bin/env bash
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
# Session Detection
# =============================================================================
# Detects interactive AI coding sessions by examining running processes.
# Distinguishes interactive (TUI) sessions from headless workers.
#
# Known AI coding assistants and their process signatures:
#   opencode (interactive): .opencode (no "run" argument in cmdline)
#   opencode (headless):    .opencode run ... (has "run" in cmdline)
#   claude (interactive):   claude (no "-p" or "--print" in cmdline)
#   claude (headless):      claude -p ... or claude --print ...
#   cursor:                 Cursor process
#   windsurf:               Windsurf process
#   aider:                  aider (Python process)

# Get the configured maximum session count.
# Priority: env var > JSONC config > default (5)
get_max_sessions() {
	# Environment variable override (highest priority)
	if [[ -n "${AIDEVOPS_MAX_SESSIONS:-}" ]]; then
		echo "$AIDEVOPS_MAX_SESSIONS"
		return 0
	fi

	# JSONC config system
	if type config_get &>/dev/null; then
		local val
		val=$(config_get "safety.max_interactive_sessions" "5")
		echo "$val"
		return 0
	fi

	# Default
	echo "5"
	return 0
}

# Count interactive AI sessions.
# Returns the count on stdout.
# Uses pgrep + /proc/cmdline (Linux) or ps (macOS) to distinguish
# interactive from headless sessions.
count_interactive_sessions() {
	local count=0

	# --- OpenCode sessions ---
	# Interactive opencode: the .opencode binary running WITHOUT "run" as
	# the first argument after the binary name.
	# Headless: .opencode run ...
	local opencode_pids=""
	opencode_pids=$(pgrep -f '\.opencode' || true)

	if [[ -n "$opencode_pids" ]]; then
		local pid
		while IFS= read -r pid; do
			[[ -z "$pid" ]] && continue
			local cmdline=""
			if [[ -r "/proc/${pid}/cmdline" ]]; then
				# Linux: /proc/PID/cmdline has null-separated args
				cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
			else
				# macOS fallback: ps -o args= (2>/dev/null: PID may have exited)
				cmdline=$(ps -o args= -p "$pid" 2>/dev/null || true)
			fi

			# Skip if this is a headless worker (has "run" after .opencode)
			# Also skip language servers and helper processes
			if echo "$cmdline" | grep -qE '\.opencode run '; then
				continue
			fi
			# Skip language servers spawned by opencode
			if echo "$cmdline" | grep -qE '(typescript-language-server|eslintServer|vscode-)'; then
				continue
			fi
			# Skip node wrapper processes (the actual .opencode binary is what matters)
			if echo "$cmdline" | grep -qE '^node .*/bin/opencode'; then
				continue
			fi
			# This is an interactive opencode session
			count=$((count + 1))
		done <<<"$opencode_pids"
	fi

	# --- Claude Code sessions ---
	# Interactive claude: the claude binary WITHOUT "-p", "--print", or "run"
	local claude_pids=""
	claude_pids=$(pgrep -x claude || true)

	if [[ -n "$claude_pids" ]]; then
		local pid
		while IFS= read -r pid; do
			[[ -z "$pid" ]] && continue
			local cmdline=""
			if [[ -r "/proc/${pid}/cmdline" ]]; then
				cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
			else
				# macOS fallback (2>/dev/null: PID may have exited)
				cmdline=$(ps -o args= -p "$pid" 2>/dev/null || true)
			fi

			# Skip headless modes
			if echo "$cmdline" | grep -qE 'claude (-p|--print|run) '; then
				continue
			fi
			count=$((count + 1))
		done <<<"$claude_pids"
	fi

	# --- Cursor sessions ---
	# Note: pgrep -c is Linux-only; use pgrep | wc -l for cross-platform.
	# Guard with -n check to avoid counting empty output as 1.
	local cursor_pids=""
	cursor_pids=$(pgrep -f 'Cursor\.app' || true)
	if [[ -n "$cursor_pids" ]]; then
		local cursor_count
		cursor_count=$(echo "$cursor_pids" | wc -l)
		count=$((count + cursor_count))
	fi

	# --- Windsurf sessions ---
	local windsurf_pids=""
	windsurf_pids=$(pgrep -f 'Windsurf' || true)
	if [[ -n "$windsurf_pids" ]]; then
		local windsurf_count
		windsurf_count=$(echo "$windsurf_pids" | wc -l)
		count=$((count + windsurf_count))
	fi

	# --- Aider sessions ---
	local aider_pids=""
	aider_pids=$(pgrep -f 'aider' || true)
	if [[ -n "$aider_pids" ]]; then
		local aider_count
		aider_count=$(echo "$aider_pids" | wc -l)
		count=$((count + aider_count))
	fi

	echo "$count"
	return 0
}

# List detected interactive sessions with details.
# Output format: PID | APP | RSS_MB | UPTIME
list_sessions() {
	local found=0

	# Helper: print session details for a given PID and app name.
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

	# --- OpenCode sessions ---
	local opencode_pids=""
	opencode_pids=$(pgrep -f '\.opencode' || true)

	if [[ -n "$opencode_pids" ]]; then
		local pid
		while IFS= read -r pid; do
			[[ -z "$pid" ]] && continue
			local cmdline=""
			if [[ -r "/proc/${pid}/cmdline" ]]; then
				cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
			else
				# macOS fallback (2>/dev/null: PID may have exited)
				cmdline=$(ps -o args= -p "$pid" 2>/dev/null || true)
			fi

			# Skip headless, language servers, node wrappers
			if echo "$cmdline" | grep -qE '\.opencode run '; then
				continue
			fi
			if echo "$cmdline" | grep -qE '(typescript-language-server|eslintServer|vscode-)'; then
				continue
			fi
			if echo "$cmdline" | grep -qE '^node .*/bin/opencode'; then
				continue
			fi

			_print_session_detail "$pid" "OpenCode"
			found=$((found + 1))
		done <<<"$opencode_pids"
	fi

	# --- Claude Code sessions ---
	local claude_pids=""
	claude_pids=$(pgrep -x claude || true)

	if [[ -n "$claude_pids" ]]; then
		local pid
		while IFS= read -r pid; do
			[[ -z "$pid" ]] && continue
			local cmdline=""
			if [[ -r "/proc/${pid}/cmdline" ]]; then
				cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
			else
				# macOS fallback (2>/dev/null: PID may have exited)
				cmdline=$(ps -o args= -p "$pid" 2>/dev/null || true)
			fi

			if echo "$cmdline" | grep -qE 'claude (-p|--print|run) '; then
				continue
			fi

			_print_session_detail "$pid" "Claude Code"
			found=$((found + 1))
		done <<<"$claude_pids"
	fi

	# --- Cursor sessions ---
	local cursor_pids=""
	cursor_pids=$(pgrep -f 'Cursor\.app' || true)

	if [[ -n "$cursor_pids" ]]; then
		local pid
		while IFS= read -r pid; do
			[[ -z "$pid" ]] && continue
			_print_session_detail "$pid" "Cursor"
			found=$((found + 1))
		done <<<"$cursor_pids"
	fi

	# --- Windsurf sessions ---
	local windsurf_pids=""
	windsurf_pids=$(pgrep -f 'Windsurf' || true)

	if [[ -n "$windsurf_pids" ]]; then
		local pid
		while IFS= read -r pid; do
			[[ -z "$pid" ]] && continue
			_print_session_detail "$pid" "Windsurf"
			found=$((found + 1))
		done <<<"$windsurf_pids"
	fi

	# --- Aider sessions ---
	local aider_pids=""
	aider_pids=$(pgrep -f 'aider' || true)

	if [[ -n "$aider_pids" ]]; then
		local pid
		while IFS= read -r pid; do
			[[ -z "$pid" ]] && continue
			_print_session_detail "$pid" "Aider"
			found=$((found + 1))
		done <<<"$aider_pids"
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
