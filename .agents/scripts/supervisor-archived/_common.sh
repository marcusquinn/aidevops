#!/usr/bin/env bash
# _common.sh - Shared helpers for supervisor modules
#
# Provides common functions used across all supervisor modules:
# - db(): SQLite wrapper with busy_timeout
# - log_*(): Structured logging functions
# - sql_escape(): SQL string escaping
# - log_cmd(): Command execution with stderr logging

set -euo pipefail

# Source shared-constants.sh for timeout_sec() and other shared utilities
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_COMMON_DIR}/../shared-constants.sh"

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
# Parameterized SQLite query — prevents SQL injection (GH#3527)
# Uses SQLite's .param mechanism to bind values separately from query logic.
# Arguments:
#   $1 - database path
#   $2 - SQL query with :name placeholders (e.g. "SELECT * FROM t WHERE id = :id")
#   $3+ - name=value pairs for each placeholder (e.g. "id=some-value")
# Example:
#   db_param "$DB" "SELECT id FROM tasks WHERE id = :tid" "tid=$task_id"
#   db_param "$DB" "INSERT INTO batch_tasks VALUES (:bid, :tid, :pos)" \
#       "bid=$batch_id" "tid=$task_id" "pos=$position"
#######################################
db_param() {
	local db_path="$1"
	local query="$2"
	shift 2

	# Build .param set commands for each name=value argument.
	# Uses double-quoted values so single quotes (apostrophes) in task IDs,
	# descriptions, and repo paths are handled safely without shell escaping
	# issues. Double-quotes within values are escaped as \".
	local param_cmds=()
	local pair name value escaped
	for pair in "$@"; do
		name="${pair%%=*}"
		value="${pair#*=}"
		# Escape any double-quotes in the value
		escaped="${value//\"/\\\"}"
		param_cmds+=(-cmd ".param set :${name} \"${escaped}\"")
	done

	sqlite3 -cmd ".timeout 5000" "${param_cmds[@]}" "$db_path" "$query"
	local rc=$?
	return $rc
}

#######################################
# Structured logging functions
# All output to stderr with color-coded prefixes.
# Uses printf to safely handle arbitrary message content (avoids echo -e
# interpreting backslash sequences in $* and word-splitting on unquoted args).
#######################################
log_info() {
	printf "%b %s\n" "${BLUE}[SUPERVISOR]${NC}" "$*" >&2
	return 0
}

log_success() {
	printf "%b %s\n" "${GREEN}[SUPERVISOR]${NC}" "$*" >&2
	return 0
}

log_warn() {
	printf "%b %s\n" "${YELLOW}[SUPERVISOR]${NC}" "$*" >&2
	return 0
}

log_error() {
	printf "%b %s\n" "${RED}[SUPERVISOR]${NC}" "$*" >&2
	return 0
}

log_verbose() {
	[[ "${SUPERVISOR_VERBOSE:-}" == "true" ]] && printf "%b %s\n" "${BLUE}[SUPERVISOR]${NC}" "$*" >&2 || true
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
#######################################
# Compute per-task hung timeout from ~estimate field in TODO.md (t1199)
# Args: $1 = task_id
# Returns: timeout in seconds via stdout
# Logic: 2x the estimate, capped at 4h (14400s), default 30m (1800s) if no estimate
#######################################
get_task_hung_timeout() {
	local task_id="$1"
	local default_timeout=1800 # 30 minutes
	local max_timeout=14400    # 4 hours cap

	# Query repo from DB to locate TODO.md
	local task_repo
	task_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
	if [[ -z "$task_repo" ]]; then
		echo "$default_timeout"
		return 0
	fi

	local todo_file="${task_repo}/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		echo "$default_timeout"
		return 0
	fi

	# Extract the TODO.md line for this task
	local task_line
	task_line=$(grep -m1 "^[[:space:]]*- \[.\] ${task_id}[[:space:]]" "$todo_file" 2>/dev/null || echo "")
	if [[ -z "$task_line" ]]; then
		echo "$default_timeout"
		return 0
	fi

	# Parse ~estimate field: matches ~Nh (hours) or ~Nm (minutes) or ~N.Nh
	local estimate_raw
	estimate_raw=$(echo "$task_line" | grep -oE '~[0-9]+(\.[0-9]+)?[hm]' | head -1 || echo "")
	if [[ -z "$estimate_raw" ]]; then
		echo "$default_timeout"
		return 0
	fi

	# Convert estimate to seconds
	local estimate_seconds=0
	if [[ "$estimate_raw" =~ ~([0-9]+(\.[0-9]+)?)h ]]; then
		local hours="${BASH_REMATCH[1]}"
		# Use awk for float arithmetic (e.g., ~1.5h)
		estimate_seconds=$(awk "BEGIN { printf \"%d\", ${hours} * 3600 }" 2>/dev/null || echo "0")
	elif [[ "$estimate_raw" =~ ~([0-9]+)m ]]; then
		local minutes="${BASH_REMATCH[1]}"
		estimate_seconds=$((minutes * 60))
	fi

	if [[ "$estimate_seconds" -le 0 ]]; then
		echo "$default_timeout"
		return 0
	fi

	# Apply 2x multiplier
	local hung_timeout=$((estimate_seconds * 2))

	# Cap at max_timeout
	if [[ "$hung_timeout" -gt "$max_timeout" ]]; then
		hung_timeout="$max_timeout"
	fi

	# Enforce minimum of default_timeout (30m) — don't go below the baseline
	if [[ "$hung_timeout" -lt "$default_timeout" ]]; then
		hung_timeout="$default_timeout"
	fi

	echo "$hung_timeout"
	return 0
}

# portable_timeout delegates to timeout_sec from shared-constants.sh (t1504).
# Kept as a wrapper for backward compatibility with archived supervisor modules.
# Exit codes: 124 = timeout (GNU convention); 137 = 128+SIGKILL; 143 = 128+SIGTERM.
portable_timeout() {
	timeout_sec "$@"
	return $?
}

#######################################
# Extract token counts from a worker log file (t1114)
# Supports camelCase (opencode JSON) and snake_case (claude CLI JSON) formats.
# Results are stored in module-level globals _EXTRACT_TOKENS_IN and
# _EXTRACT_TOKENS_OUT. Callers copy these into their own local variables.
#
# Usage:
#   local tokens_in="" tokens_out=""
#   extract_tokens_from_log "$log_file"
#   tokens_in="$_EXTRACT_TOKENS_IN"
#   tokens_out="$_EXTRACT_TOKENS_OUT"
#
# $1: log_file path (may be empty or non-existent — handled gracefully)
#######################################
_EXTRACT_TOKENS_IN=""
_EXTRACT_TOKENS_OUT=""
extract_tokens_from_log() {
	local log_file="$1"
	_EXTRACT_TOKENS_IN=""
	_EXTRACT_TOKENS_OUT=""

	if [[ -z "$log_file" || ! -f "$log_file" ]]; then
		return 0
	fi

	local raw_in raw_out
	raw_in=$(grep -oE '"inputTokens":[0-9]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
	raw_out=$(grep -oE '"outputTokens":[0-9]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
	if [[ -z "$raw_in" ]]; then
		raw_in=$(grep -oE '"input_tokens":[0-9]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
	fi
	if [[ -z "$raw_out" ]]; then
		raw_out=$(grep -oE '"output_tokens":[0-9]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
	fi
	[[ -n "$raw_in" ]] && _EXTRACT_TOKENS_IN="$raw_in"
	[[ -n "$raw_out" ]] && _EXTRACT_TOKENS_OUT="$raw_out"
	return 0
}
