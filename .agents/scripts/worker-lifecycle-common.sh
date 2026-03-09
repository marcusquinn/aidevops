#!/usr/bin/env bash
# worker-lifecycle-common.sh — Shared process lifecycle functions
#
# Extracted from pulse-wrapper.sh (t1419) so that both pulse-wrapper.sh and
# worker-watchdog.sh can reuse the same battle-tested process management
# primitives without duplication.
#
# Functions provided:
#   _kill_tree()              Kill a process and all its children (SIGTERM)
#   _force_kill_tree()        Force kill a process tree (SIGKILL)
#   _get_process_age()        Get process age in seconds from ps etime
#   _get_pid_cpu()            Get integer CPU% for a single PID
#   _get_process_tree_cpu()   Get CPU% summed across a process tree (BFS)
#   _sanitize_log_field()     Strip control characters from log fields
#   _sanitize_markdown()      Strip @ mentions and backticks from markdown
#   _validate_int()           Validate and sanitize integer config values
#   _compute_struggle_ratio() Compute messages/commits ratio for a worker
#   _format_duration()        Format seconds into human-readable duration
#
# Usage: source worker-lifecycle-common.sh
#
# Include guard prevents double-loading (readonly errors, function redefinition).

# Include guard
[[ -n "${_WORKER_LIFECYCLE_COMMON_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_COMMON_LOADED=1

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

	# Validate components are numeric before arithmetic expansion
	[[ "$days" =~ ^[0-9]+$ ]] || days=0
	[[ "$hours" =~ ^[0-9]+$ ]] || hours=0
	[[ "$minutes" =~ ^[0-9]+$ ]] || minutes=0
	[[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0

	# Remove leading zeros to avoid octal interpretation
	days=$((10#${days}))
	hours=$((10#${hours}))
	minutes=$((10#${minutes}))
	seconds=$((10#${seconds}))

	echo $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
	return 0
}

#######################################
# Get integer CPU% for a single PID (helper for _get_process_tree_cpu)
#
# Extracts %CPU via ps, truncates to integer, validates numeric.
# Returns 0 if the process doesn't exist or ps fails.
#
# Arguments:
#   $1 - PID
# Returns: integer CPU percentage via stdout
#######################################
_get_pid_cpu() {
	local pid="$1"
	local cpu_str
	cpu_str=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ') || cpu_str="0"
	# ps returns float like "12.3" — extract integer part
	local cpu_int="${cpu_str%%.*}"
	[[ "$cpu_int" =~ ^[0-9]+$ ]] || cpu_int=0
	echo "$cpu_int"
	return 0
}

#######################################
# Get CPU usage percentage for a process tree (t1398.3)
#
# Iteratively walks the full descendant tree (BFS) using pgrep -P at
# each level. Previous implementation only checked direct children,
# missing grandchildren and deeper descendants — this caused incorrect
# CPU calculations when active processes were nested deeper than one
# level (e.g., node -> shell -> language-server).
#
# Arguments:
#   $1 - PID
# Returns: integer CPU percentage via stdout (0-N, summed across cores)
#######################################
_get_process_tree_cpu() {
	local pid="$1"
	local total_cpu=0

	# Iteratively find the initial PID and all its descendants (BFS).
	# pgrep -P only returns direct children, so we expand level by level.
	local pids_to_scan=("$pid")
	local all_pids=()
	local i=0
	while [[ $i -lt ${#pids_to_scan[@]} ]]; do
		local current_pid="${pids_to_scan[$i]}"
		all_pids+=("$current_pid")
		local child
		while IFS= read -r child; do
			[[ -n "$child" ]] && pids_to_scan+=("$child")
		done < <(pgrep -P "$current_pid" 2>/dev/null || true)
		i=$((i + 1))
	done

	# Sum CPU for all unique PIDs in the process tree.
	local p
	for p in $(printf "%s\n" "${all_pids[@]}" | sort -u); do
		local cpu
		cpu=$(_get_pid_cpu "$p")
		total_cpu=$((total_cpu + cpu))
	done

	echo "$total_cpu"
	return 0
}

# Sanitise untrusted strings before embedding in GitHub markdown comments.
# Strips @ mentions (prevents unwanted notifications) and backtick sequences
# (prevents markdown injection). Used for API response data that gets posted
# as issue/PR comments.
_sanitize_markdown() {
	local input="$1"
	# Remove @ mentions to prevent notification spam
	input="${input//@/}"
	# Remove backtick sequences that could break markdown fencing
	input="${input//\`/}"
	printf '%s' "$input"
	return 0
}

# Sanitise untrusted strings before writing to log files.
# Strips control characters (newlines, carriage returns, tabs, and non-printable
# chars) to prevent log injection attacks where a crafted process name could
# insert fake log entries or mislead administrators. (Gemini review, PR #2881)
_sanitize_log_field() {
	local input="$1"
	# Strip all control characters (ASCII 0x00-0x1F and 0x7F) except space.
	# The tr octal range is intentional (not a glob).
	# shellcheck disable=SC2060
	printf '%s' "$input" | tr -d '\000-\037\177'
	return 0
}

#######################################
# Validate numeric configuration values
#
# Prevents command injection via $(( )) expansion. Bash arithmetic
# evaluates variable contents as expressions, so unsanitised strings
# like "a[$(cmd)]" would execute arbitrary commands.
#
# Arguments:
#   $1 - variable name (for error messages)
#   $2 - value to validate
#   $3 - default value if invalid
#   $4 - minimum value (optional, default: 0)
# Returns: validated integer via stdout
#######################################
_validate_int() {
	local name="$1" value="$2" default="$3" min="${4:-0}"
	if ! [[ "$value" =~ ^[0-9]+$ ]]; then
		echo "[worker-lifecycle] Invalid ${name}: ${value} — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	# Canonicalize to base-10: strip leading zeros to prevent bash octal interpretation
	# e.g., "08" (invalid octal) or "01024" (octal 532) become "8" and "1024"
	local canonical
	canonical=$(printf '%d' "$((10#$value))")
	# Enforce minimum to prevent divide-by-zero for divisor-backed settings
	if ((canonical < min)); then
		echo "[worker-lifecycle] ${name}=${canonical} below minimum ${min} — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	printf '%s' "$canonical"
	return 0
}

#######################################
# Compute struggle ratio for a single worker (t1367)
#
# struggle_ratio = messages / max(1, commits)
# High ratio with elapsed time indicates a worker that is active but
# not producing useful output (thrashing). This is an informational
# signal — the supervisor LLM decides what to do with it.
#
# Arguments:
#   $1 - worker PID
#   $2 - worker elapsed seconds
#   $3 - worker command line
# Output: "ratio|commits|messages|flag" to stdout
#   flag: "" (normal), "struggling", or "thrashing"
#######################################
_compute_struggle_ratio() {
	local pid="$1"
	local elapsed_seconds="$2"
	local cmd="$3"

	local threshold="${STRUGGLE_RATIO_THRESHOLD:-30}"
	local min_elapsed="${STRUGGLE_MIN_ELAPSED_MINUTES:-30}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=30
	[[ "$min_elapsed" =~ ^[0-9]+$ ]] || min_elapsed=30
	local min_elapsed_seconds=$((min_elapsed * 60))

	# Extract --dir from command line
	local worktree_dir=""
	if [[ "$cmd" =~ --dir[[:space:]]+([^[:space:]]+) ]]; then
		worktree_dir="${BASH_REMATCH[1]}"
	fi

	# No worktree — can't compute
	if [[ -z "$worktree_dir" || ! -d "$worktree_dir" ]]; then
		echo "n/a|0|0|"
		return 0
	fi

	# Count commits since worker start
	local commits=0
	if [[ -d "${worktree_dir}/.git" || -f "${worktree_dir}/.git" ]]; then
		local since_seconds_ago="${elapsed_seconds}"
		# Use (cmd || true) pattern for set -e safety — ensures the pipeline
		# always succeeds and stderr remains visible for debugging (GH#4010)
		commits=$( (git -C "$worktree_dir" log --oneline --since="${since_seconds_ago} seconds ago" || true) | wc -l | tr -d ' ')
	fi

	# Estimate message count from OpenCode session DB
	local messages=0
	local db_path="${HOME}/.local/share/opencode/opencode.db"

	if [[ -f "$db_path" ]]; then
		# Extract title from command to match session
		local session_title=""
		if [[ "$cmd" =~ --title[[:space:]]+\"([^\"]+)\" ]] || [[ "$cmd" =~ --title[[:space:]]+([^[:space:]]+) ]]; then
			session_title="${BASH_REMATCH[1]}"
		fi

		if [[ -n "$session_title" ]]; then
			# Query message count for the most recent session matching this title
			# Use sqlite3 with a LIKE match on session title
			local escaped_title="${session_title//\'/\'\'}"
			# Use (cmd || echo 0) pattern for set -e safety — ensures the
			# assignment always succeeds and stderr remains visible (GH#4010)
			messages=$(sqlite3 "$db_path" "
				SELECT COUNT(*)
				FROM message m
				JOIN session s ON m.session_id = s.id
				WHERE s.title LIKE '%${escaped_title}%'
				AND s.time_created > strftime('%s', 'now') - ${elapsed_seconds}
			" || echo 0)
		fi
	fi

	# Fallback: estimate from elapsed time if DB query failed
	# Conservative heuristic: ~2 messages per minute for an active worker
	if [[ "$messages" -eq 0 && "$elapsed_seconds" -gt 300 ]]; then
		local elapsed_minutes=$((elapsed_seconds / 60))
		messages=$((elapsed_minutes * 2))
	fi

	# Compute ratio
	local denominator=$((commits > 0 ? commits : 1))
	local ratio=$((messages / denominator))

	# Determine flag
	local flag=""
	if [[ "$elapsed_seconds" -ge "$min_elapsed_seconds" ]]; then
		if [[ "$ratio" -gt 50 && "$elapsed_seconds" -ge 3600 ]]; then
			flag="thrashing"
		elif [[ "$ratio" -gt "$threshold" && "$commits" -eq 0 ]]; then
			flag="struggling"
		fi
	fi

	echo "${ratio}|${commits}|${messages}|${flag}"
	return 0
}

#######################################
# Format seconds into human-readable duration
# Arguments:
#   $1 - seconds
# Returns: formatted string via stdout (e.g., "2h 15m", "45m 30s")
#######################################
_format_duration() {
	local total_seconds="$1"
	[[ "$total_seconds" =~ ^[0-9]+$ ]] || total_seconds=0

	local hours=$((total_seconds / 3600))
	local minutes=$(((total_seconds % 3600) / 60))
	local seconds=$((total_seconds % 60))

	if [[ "$hours" -gt 0 ]]; then
		echo "${hours}h ${minutes}m"
	elif [[ "$minutes" -gt 0 ]]; then
		echo "${minutes}m ${seconds}s"
	else
		echo "${seconds}s"
	fi
	return 0
}
