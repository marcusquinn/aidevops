#!/usr/bin/env bash
# _common.sh - Shared helpers for supervisor modules
#
# Provides common functions used across all supervisor modules:
# - db(): SQLite wrapper with busy_timeout
# - log_*(): Structured logging functions
# - sql_escape(): SQL string escaping
# - log_cmd(): Command execution with stderr logging

set -euo pipefail

#######################################
# SQLite wrapper: sets busy_timeout on every connection
# busy_timeout is per-connection and must be set each time
# Arguments:
#   $1 - database path
#   $2+ - SQL commands or options
#######################################
db() {
	sqlite3 -cmd ".timeout 5000" "$@"
	local rc=$?
	return $rc
}

#######################################
# Structured logging functions
# All output to stderr with color-coded prefixes
#######################################
log_info() {
	echo -e "${BLUE}[SUPERVISOR]${NC} $*" >&2
	return 0
}

log_success() {
	echo -e "${GREEN}[SUPERVISOR]${NC} $*" >&2
	return 0
}

log_warn() {
	echo -e "${YELLOW}[SUPERVISOR]${NC} $*" >&2
	return 0
}

log_error() {
	echo -e "${RED}[SUPERVISOR]${NC} $*" >&2
	return 0
}

log_verbose() {
	[[ "${SUPERVISOR_VERBOSE:-}" == "true" ]] && echo -e "${BLUE}[SUPERVISOR]${NC} $*" >&2 || true
	return 0
}

#######################################
# Escape single quotes for SQL
# Arguments:
#   $1 - input string
# Returns:
#   Escaped string on stdout
#######################################
sql_escape() {
	local input="$1"
	# t1040: Use printf+sed for reliable single-quote escaping.
	# Bash parameter expansion ${input//\'/\'\'} fails in some quoting
	# contexts, causing SQLite INSERT errors for task descriptions
	# containing apostrophes (e.g. "supervisor's", "don't").
	printf '%s' "$input" | sed "s/'/''/g"
	return 0
}

#######################################
# Log stderr from a command to the supervisor log file
# Preserves exit code. Use for DB writes, API calls, state transitions.
# Arguments:
#   $1 - context label
#   $2+ - command and arguments
# Returns:
#   Exit code from the command
#######################################
log_cmd() {
	local context="$1"
	shift
	local ts
	ts="$(date '+%H:%M:%S' 2>/dev/null || echo "?")"
	echo "[$ts] [$context] $*" >>"${SUPERVISOR_LOG:-/dev/null}" 2>/dev/null || true
	"$@" 2>>"${SUPERVISOR_LOG:-/dev/null}"
	local rc=$?
	[[ $rc -ne 0 ]] && echo "[$ts] [$context] exit=$rc" >>"${SUPERVISOR_LOG:-/dev/null}" 2>/dev/null || true
	return $rc
}

#######################################
# Portable timeout — works on macOS (no GNU coreutils) and Linux
# Uses background process + kill pattern when `timeout` is unavailable.
# Arguments:
#   $1 - timeout in seconds
#   $@ - command to run
# Returns:
#   Command exit code, or 124 on timeout (matches GNU timeout convention)
#######################################
portable_timeout() {
	local secs="$1"
	shift

	# If GNU timeout is available, use it (faster, handles signals better)
	if command -v timeout &>/dev/null; then
		timeout "$secs" "$@"
		return $?
	fi

	# Fallback: background the command, sleep, kill if still running
	"$@" &
	local cmd_pid=$!

	(
		sleep "$secs"
		kill "$cmd_pid" 2>/dev/null
	) &
	local watchdog_pid=$!

	wait "$cmd_pid" 2>/dev/null
	local exit_code=$?

	# Clean up watchdog if command finished before timeout
	kill "$watchdog_pid" 2>/dev/null
	wait "$watchdog_pid" 2>/dev/null

	# If killed by our watchdog, return 124 (GNU timeout convention)
	if [[ $exit_code -eq 137 || $exit_code -eq 143 ]]; then
		return 124
	fi

	return "$exit_code"
}
