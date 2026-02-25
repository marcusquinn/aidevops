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
