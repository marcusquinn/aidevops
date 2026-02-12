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
}

#######################################
# Structured logging functions
# All output to stderr with color-coded prefixes
#######################################
log_info() {
	echo -e "${BLUE}[SUPERVISOR]${NC} $*" >&2
}

log_success() {
	echo -e "${GREEN}[SUPERVISOR]${NC} $*" >&2
}

log_warn() {
	echo -e "${YELLOW}[SUPERVISOR]${NC} $*" >&2
}

log_error() {
	echo -e "${RED}[SUPERVISOR]${NC} $*" >&2
}

log_verbose() {
	[[ "${SUPERVISOR_VERBOSE:-}" == "true" ]] && echo -e "${BLUE}[SUPERVISOR]${NC} $*" >&2 || true
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
	echo "${input//\'/\'\'}"
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
