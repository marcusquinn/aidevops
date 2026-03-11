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
# Resolve the OpenCode session DB path
# Returns: path via stdout
#######################################
_opencode_db_path() {
	local db_path="${OPENCODE_DB_PATH:-${HOME}/.local/share/opencode/opencode.db}"
	printf '%s' "$db_path"
	return 0
}

#######################################
# Extract session title from a worker command line
# Arguments:
#   $1 - command line string
# Returns: session title or empty string via stdout
#######################################
_extract_session_title() {
	local cmd="$1"
	local session_title=""

	if [[ "$cmd" =~ --title[[:space:]]+\"([^\"]+)\" ]] || [[ "$cmd" =~ --title[[:space:]]+([^[:space:]]+) ]]; then
		session_title="${BASH_REMATCH[1]}"
	fi

	printf '%s' "$session_title"
	return 0
}

#######################################
# Summarise the recent OpenCode transcript tail for a worker session
# Arguments:
#   $1 - worker command line
#   $2 - recent activity timeout seconds
#   $3 - maximum parts to inspect (optional, default: 8)
# Returns: "classification|summary" where classification is one of
#   active, provider-waiting, stalled, none
#######################################
_get_session_tail_evidence() {
	local cmd="$1"
	local timeout_seconds="$2"
	local part_limit="${3:-8}"
	local db_path session_title
	db_path=$(_opencode_db_path)
	session_title=$(_extract_session_title "$cmd")

	if [[ ! -f "$db_path" ]]; then
		printf '%s' 'none|OpenCode session DB unavailable'
		return 0
	fi

	if [[ -z "$session_title" ]]; then
		printf '%s' 'none|Worker command has no session title'
		return 0
	fi

	SESSION_TAIL_DB_PATH="$db_path" \
		SESSION_TAIL_TITLE="$session_title" \
		SESSION_TAIL_TIMEOUT="$timeout_seconds" \
		SESSION_TAIL_LIMIT="$part_limit" \
		python3 - <<'PY'
import json
import os
import re
import sqlite3
import time

db_path = os.environ["SESSION_TAIL_DB_PATH"]
session_title = os.environ["SESSION_TAIL_TITLE"]
timeout_seconds = int(os.environ["SESSION_TAIL_TIMEOUT"])
part_limit = int(os.environ["SESSION_TAIL_LIMIT"])

provider_markers = (
    "rate limit",
    "rate-limit",
    "429",
    "backoff",
    "retrying",
    "retry after",
    "overloaded",
    "temporarily unavailable",
    "connection reset",
    "timed out",
    "timeout",
    "econnreset",
    "etimedout",
    "service unavailable",
)

def collapse(value: str, limit: int = 120) -> str:
    value = re.sub(r"\s+", " ", value or "").strip()
    if len(value) > limit:
        value = value[: limit - 3] + "..."
    return value.replace("|", "/")

try:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA busy_timeout=5000")
    cursor = conn.cursor()
    cursor.execute(
        """
        SELECT id, title
        FROM session
        WHERE title LIKE ?
        ORDER BY time_created DESC
        LIMIT 1
        """,
        (f"%{session_title}%",),
    )
    session_row = cursor.fetchone()
    if not session_row:
        print("none|No OpenCode session found")
        raise SystemExit(0)

    session_id, resolved_title = session_row
    cursor.execute(
        """
        SELECT COUNT(*)
        FROM message
        WHERE session_id = ?
          AND time_created > strftime('%s', 'now') - ?
        """,
        (session_id, timeout_seconds),
    )
    recent_count = int(cursor.fetchone()[0] or 0)

    cursor.execute(
        """
        SELECT data, time_created
        FROM part
        WHERE session_id = ?
        ORDER BY time_created DESC
        LIMIT ?
        """,
        (session_id, part_limit),
    )
    part_rows = list(reversed(cursor.fetchall()))
except sqlite3.Error as exc:
    print(f"none|Session evidence query failed: {collapse(str(exc), 120)}")
    raise SystemExit(0)

entries = []
search_blob = []
newest_part_time = 0

for raw_data, part_time in part_rows:
    newest_part_time = max(newest_part_time, int(part_time or 0))
    data = json.loads(raw_data)
    part_type = data.get("type", "unknown")

    if part_type == "text":
        preview = collapse(data.get("text", ""))
        if preview:
            entries.append(f'text:"{preview}"')
            search_blob.append(preview.lower())
    elif part_type == "tool":
        state = data.get("state", {})
        status = collapse(str(state.get("status", "unknown")), 24)
        description = collapse(str(state.get("input", {}).get("description", "")))
        tool_name = collapse(str(data.get("tool", "tool")), 32)
        if description:
            entries.append(f'tool:{tool_name}({status}) "{description}"')
            search_blob.append(description.lower())
        else:
            entries.append(f"tool:{tool_name}({status})")
    elif part_type == "step-finish":
        reason = collapse(str(data.get("reason", "done")), 32)
        entries.append(f"step-finish:{reason}")
    elif part_type == "step-start":
        entries.append("step-start")
    elif part_type == "reasoning":
        entries.append("reasoning")
    else:
        entries.append(collapse(part_type, 32))

if not entries:
    entries.append("no-parts")

joined_blob = " ".join(search_blob)
if recent_count > 0:
    classification = "active"
elif any(marker in joined_blob for marker in provider_markers):
    classification = "provider-waiting"
else:
    classification = "stalled"

age_seconds = max(0, int(time.time()) - newest_part_time) if newest_part_time else -1
tail_summary = " > ".join(entries[-5:])
summary = (
    f'session="{collapse(resolved_title, 80)}"; '
    f"recent_messages={recent_count}; "
    f"newest_part_age={age_seconds}s; "
    f"tail={tail_summary}"
)
print(f"{classification}|{summary}")
PY
	return 0
}

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
