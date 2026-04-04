#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
#   _extract_session_title_from_cmd() Extract session title from opencode CLI args
#   _count_recent_opencode_messages() Count recent OpenCode messages by title match
#   _collect_worker_stall_evidence()  Summarise recent worker transcript/output tail
#   _sanitize_log_field()     Strip control characters from log fields
#   _sanitize_markdown()      Strip @ mentions and backticks from markdown
#   _validate_int()           Validate and sanitize integer config values
#   _count_worker_commits()   Count commits in a worktree since elapsed seconds ago
#   _count_worker_messages()  Count session DB messages for a worker
#   _determine_struggle_flag() Determine struggle flag from ratio/commit/elapsed metrics
#   _compute_struggle_ratio() Compute messages/commits ratio for a worker
#   _format_duration()        Format seconds into human-readable duration
#
# Companion files:
#   session_tail_query.py     Extracted Python logic for session tail
#                             classification (GH#6428)
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

	session_title=$(
		SESSION_CMD="$cmd" python3 - <<'PY'
import os
import shlex

cmd = os.environ.get("SESSION_CMD", "")
title = ""

try:
    tokens = shlex.split(cmd)
except Exception:
    tokens = cmd.split()

for idx, token in enumerate(tokens):
    if token == "--title" and idx + 1 < len(tokens):
        collected = []
        for next_token in tokens[idx + 1 :]:
            if next_token.startswith("--"):
                break
            if next_token == "/full-loop":
                break
            collected.append(next_token)
        title = " ".join(collected).strip()
        break

print(title)
PY
	)

	printf '%s' "${session_title:-}"
	return 0
}

#######################################
# Validate preconditions for session tail evidence collection
# Arguments:
#   $1 - worker command line
# Outputs: "db_path|session_title" on success, or "none|<reason>" on failure
# Returns: 0 always (caller checks output prefix)
#######################################
_get_session_tail_preconditions() {
	local cmd="$1"
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

	printf '%s|%s' "$db_path" "$session_title"
	return 0
}

#######################################
# Python script: query OpenCode DB and classify session tail.
# Reads env vars: SESSION_TAIL_DB_PATH, SESSION_TAIL_TITLE,
#   SESSION_TAIL_TIMEOUT, SESSION_TAIL_LIMIT
# Returns: "classification|summary" via stdout
#
# Logic extracted to session_tail_query.py for testability and to
# keep this function under the 100-line complexity threshold (GH#6428).
#######################################
_run_session_tail_python() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local py_script="${script_dir}/session_tail_query.py"

	if [[ ! -f "$py_script" ]]; then
		echo "none|session_tail_query.py not found at ${py_script}" >&2
		printf '%s' "none|session_tail_query.py missing"
		return 1
	fi

	python3 "$py_script"
	return 0
}

#######################################
# Set env vars and invoke the session tail Python script
# Arguments:
#   $1 - db_path
#   $2 - session_title
#   $3 - timeout_seconds
#   $4 - part_limit
# Returns: "classification|summary" via stdout
#######################################
_query_session_tail() {
	local db_path="$1"
	local session_title="$2"
	local timeout_seconds="$3"
	local part_limit="$4"

	SESSION_TAIL_DB_PATH="$db_path" \
		SESSION_TAIL_TITLE="$session_title" \
		SESSION_TAIL_TIMEOUT="$timeout_seconds" \
		SESSION_TAIL_LIMIT="$part_limit" \
		_run_session_tail_python
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

	local preconditions
	preconditions=$(_get_session_tail_preconditions "$cmd")

	# Early-exit if preconditions returned a "none|..." failure
	case "$preconditions" in
	none\|*)
		printf '%s' "$preconditions"
		return 0
		;;
	esac

	local db_path session_title
	db_path="${preconditions%%|*}"
	session_title="${preconditions#*|}"

	_query_session_tail "$db_path" "$session_title" "$timeout_seconds" "$part_limit"
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

#######################################
# Extract the --title value from an opencode command line
# Arguments:
#   $1 - command line string
# Returns: session title via stdout, or empty string if absent
#######################################
_extract_session_title_from_cmd() {
	local cmd="$1"
	_extract_session_title "$cmd"
	return 0
}

#######################################
# Resolve OpenCode session ID from a worker command line
# Arguments:
#   $1 - command line string
# Returns: session id via stdout, or empty string
#######################################
_resolve_session_id_from_cmd() {
	local cmd="$1"
	local db_path
	db_path=$(_opencode_db_path)
	local session_id=""

	if [[ "$cmd" =~ --session[[:space:]]+([^[:space:]]+) ]] || [[ "$cmd" =~ --session=([^[:space:]]+) ]]; then
		session_id="${BASH_REMATCH[1]}"
		printf '%s' "$session_id"
		return 0
	fi

	[[ -f "$db_path" ]] || {
		printf '%s' ""
		return 0
	}

	local session_title
	session_title=$(_extract_session_title_from_cmd "$cmd")
	[[ -n "$session_title" ]] || {
		printf '%s' ""
		return 0
	}

	session_id=$(
		DB_PATH="$db_path" TITLE="$session_title" python3 - <<'PY'
import os, sqlite3
db = os.environ["DB_PATH"]
title = os.environ["TITLE"]
conn = sqlite3.connect(db)
conn.execute("PRAGMA busy_timeout=5000")
cur = conn.cursor()
cur.execute("SELECT id FROM session WHERE title = ? ORDER BY time_created DESC LIMIT 1", (title,))
row = cur.fetchone()
if not row:
    cur.execute("SELECT id FROM session WHERE title LIKE ? ORDER BY time_created DESC LIMIT 1", (f"%{title}%",))
    row = cur.fetchone()
print(row[0] if row else "")
PY
	) 2>/dev/null || session_id=""

	printf '%s' "$session_id"
	return 0
}

#######################################
# Count recent OpenCode messages for sessions matching a title fragment
# Arguments:
#   $1 - title fragment (task ID or session title)
#   $2 - recent window in seconds
# Returns: integer count via stdout
#######################################
_count_recent_opencode_messages() {
	local session_match="$1"
	local recent_window="$2"
	local db_path="${HOME}/.local/share/opencode/opencode.db"

	[[ -n "$session_match" ]] || {
		printf '%s' "0"
		return 0
	}
	[[ "$recent_window" =~ ^[0-9]+$ ]] || recent_window=180

	if [[ ! -f "$db_path" ]]; then
		printf '%s' "0"
		return 0
	fi

	local recent_count
	recent_count=$(
		DB_PATH="$db_path" MATCH="$session_match" WINDOW="$recent_window" python3 - <<'PY'
import os, sqlite3
conn = sqlite3.connect(os.environ["DB_PATH"])
conn.execute("PRAGMA busy_timeout=5000")
cur = conn.cursor()
cur.execute(
    "SELECT COUNT(*) FROM message m JOIN session s ON m.session_id = s.id"
    " WHERE s.title LIKE ?"
    " AND (CASE WHEN m.time_created > 20000000000 THEN m.time_created / 1000 ELSE m.time_created END)"
    " >= strftime('%s', 'now') - ?",
    (f"%{os.environ['MATCH']}%", int(os.environ["WINDOW"])),
)
print(cur.fetchone()[0] or 0)
PY
	) 2>/dev/null || recent_count=0
	[[ "$recent_count" =~ ^[0-9]+$ ]] || recent_count=0

	printf '%s' "$recent_count"
	return 0
}

#######################################
# Summarise recent worker transcript/output evidence for stall diagnosis
# Arguments:
#   $1 - session title fragment (task ID or exact title)
#   $2 - log file path (optional)
#   $3 - recent window in seconds
#   $4 - number of log lines to inspect
# Returns: tab-separated "recent_count<TAB>classification<TAB>excerpt"
#######################################
_collect_worker_stall_evidence() {
	local session_match="$1"
	local log_file="${2:-}"
	local recent_window="${3:-180}"
	local tail_lines="${4:-8}"
	local recent_count
	recent_count=$(_count_recent_opencode_messages "$session_match" "$recent_window")
	[[ "$tail_lines" =~ ^[0-9]+$ ]] || tail_lines=8

	local evidence
	evidence=$(
		python3 - "$log_file" "$tail_lines" <<'PY'
import json
import re
import sys
from collections import deque
from pathlib import Path

log_file = sys.argv[1]
tail_lines = int(sys.argv[2])

classification = "no_log"
excerpt = ""

if log_file and Path(log_file).is_file():
    classification = "no_signal"
    collected = deque(maxlen=max(tail_lines, 1))
    for raw_line in Path(log_file).read_text(errors="ignore").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("{"):
            try:
                obj = json.loads(line)
            except Exception:
                pass
            else:
                event_type = obj.get("type") or obj.get("role") or obj.get("finish") or obj.get("event")
                summary = obj.get("summary") or {}
                title = summary.get("title") or obj.get("title") or ""
                tool_name = ""
                for key in ("tool", "toolName", "name"):
                    value = obj.get(key)
                    if isinstance(value, str) and value:
                        tool_name = value
                        break
                line = " ".join(part for part in [event_type, title, tool_name] if part)
                line = line.strip() or raw_line.strip()
        collected.append(line)

    excerpt = " || ".join(collected)
    excerpt = re.sub(r"\s+", " ", excerpt).strip()
    excerpt = excerpt[:240]
    lowered = excerpt.lower()
    if not excerpt:
        classification = "empty_log"
    elif any(token in lowered for token in ["rate limit", "too many requests", "429", "retry after"]):
        classification = "rate_limited"
    elif any(token in lowered for token in ["full_loop_complete", "pr_url", "worker_done", "exit:0"]):
        classification = "completion_signal"
    elif any(token in lowered for token in ["tool", "reasoning", "step", "assistant", "apply_patch", "bash"]):
        classification = "activity_signal"

excerpt = excerpt.replace("\t", " ").replace("|", "/")

print(f"{classification}\t{excerpt}")
PY
	)

	local classification excerpt
	IFS=$'\t' read -r classification excerpt <<<"${evidence:-no_log$'\t'}"
	printf '%s\t%s\t%s\n' "$recent_count" "$classification" "$excerpt"
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
# Count commits in a worktree since a given number of seconds ago (GH#17078)
# Arguments:
#   $1 - worktree directory path
#   $2 - elapsed seconds (time window for git log)
# Returns: integer commit count via stdout
#######################################
_count_worker_commits() {
	local worktree_dir="$1"
	local elapsed_seconds="$2"
	local commits=0

	if [[ -d "${worktree_dir}/.git" || -f "${worktree_dir}/.git" ]]; then
		# Use (cmd || true) pattern for set -e safety — ensures the pipeline
		# always succeeds and stderr remains visible for debugging (GH#4010)
		commits=$( (git -C "$worktree_dir" log --oneline --since="${elapsed_seconds} seconds ago" || true) | wc -l | tr -d ' ')
	fi

	echo "$commits"
	return 0
}

#######################################
# Count session messages from the OpenCode DB for a worker (GH#17078)
# Arguments:
#   $1 - worker command line
#   $2 - elapsed seconds (time window for message query)
# Output: "available|<count>" or "unavailable|0"
#   "available" means the DB was found and queried
#   "unavailable" means no DB — caller must return n/a (GH#11278)
#######################################
_count_worker_messages() {
	local cmd="$1"
	local elapsed_seconds="$2"
	local db_path="${HOME}/.local/share/opencode/opencode.db"

	# When neither DB is available, return unavailable — NEVER fabricate message
	# counts from elapsed time. The old heuristic (messages = elapsed_minutes × 2)
	# produced false positives: a 19-minute worker could be reported as "17h
	# with struggle_ratio: 48" when the process age was inherited from a
	# long-lived parent or stale worktree. See GH#11278.
	if [[ ! -f "$db_path" ]]; then
		echo "unavailable|0"
		return 0
	fi

	local session_id messages=0
	session_id=$(_resolve_session_id_from_cmd "$cmd")

	if [[ -n "$session_id" ]]; then
		messages=$(
			DB_PATH="$db_path" SID="$session_id" ELAPSED="$elapsed_seconds" python3 - <<'PY'
import os, sqlite3
conn = sqlite3.connect(os.environ["DB_PATH"])
conn.execute("PRAGMA busy_timeout=5000")
cur = conn.cursor()
cur.execute(
    "SELECT COUNT(*) FROM message m"
    " WHERE m.session_id = ?"
    " AND (CASE WHEN m.time_created > 20000000000 THEN m.time_created / 1000 ELSE m.time_created END)"
    " > strftime('%s', 'now') - ?",
    (os.environ["SID"], int(os.environ["ELAPSED"])),
)
print(cur.fetchone()[0] or 0)
PY
		) 2>/dev/null || messages=0
	fi

	echo "available|${messages}"
	return 0
}

#######################################
# Determine the struggle flag from ratio/commit/elapsed metrics (GH#17078)
# Arguments:
#   $1 - ratio (messages / max(1, commits))
#   $2 - commits count
#   $3 - elapsed seconds
#   $4 - min elapsed seconds threshold
#   $5 - ratio threshold for "struggling"
# Returns: flag string ("", "struggling", or "thrashing") via stdout
#######################################
_determine_struggle_flag() {
	local ratio="$1"
	local commits="$2"
	local elapsed_seconds="$3"
	local min_elapsed_seconds="$4"
	local threshold="$5"
	local flag=""

	if [[ "$elapsed_seconds" -ge "$min_elapsed_seconds" ]]; then
		if [[ "$ratio" -gt 50 && "$elapsed_seconds" -ge 3600 ]]; then
			flag="thrashing"
		elif [[ "$ratio" -gt "$threshold" && "$commits" -eq 0 ]]; then
			flag="struggling"
		fi
	fi

	echo "$flag"
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

	# Count commits since worker start (elapsed_seconds is the time window).
	local commits
	commits=$(_count_worker_commits "$worktree_dir" "$elapsed_seconds")

	# Count messages from the session DB (runtime-aware).
	# Supports OpenCode (opencode.db). Returns "unavailable|0" when no DB found.
	local msg_result db_status messages
	msg_result=$(_count_worker_messages "$cmd" "$elapsed_seconds")
	db_status="${msg_result%%|*}"
	messages="${msg_result#*|}"

	# If no session DB is available (e.g., Claude Code runtime without
	# OpenCode DB), return n/a — do NOT fabricate counts (GH#11278).
	if [[ "$db_status" == "unavailable" ]]; then
		echo "n/a|${commits}|0|"
		return 0
	fi

	# Compute ratio and flag
	local denominator=$((commits > 0 ? commits : 1))
	local ratio=$((messages / denominator))
	local flag
	flag=$(_determine_struggle_flag "$ratio" "$commits" "$elapsed_seconds" "$min_elapsed_seconds" "$threshold")

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

#######################################
# List active worker processes (logical, deduplicated).
#
# Moved here from pulse-wrapper.sh so that both pulse-wrapper.sh and
# stats-functions.sh (via stats-wrapper.sh) use the same counting logic.
# Previously, stats-functions.sh had a simpler _scan_active_workers that
# missed headless-runtime-helper workers, didn't deduplicate process chains,
# and didn't filter zombie/stopped processes — producing wrong worker counts
# on the pinned health issue dashboards.
#
# t5072: Count logical workers (one per session/issue), not OS process tree nodes.
# A single opencode worker spawns a 3-process chain:
#   bash sandbox-exec-helper.sh run ... -- opencode run ...  (top-level launcher)
#   node /opt/homebrew/bin/opencode run ...                  (node child)
#   /path/to/.opencode run ...                               (binary grandchild)
# All three contain /full-loop (or /review-issue-pr) and opencode in their command line.
#
# GH#12361 / GH#14944: Workers may appear either as direct opencode
# processes or as headless-runtime-helper.sh wrappers around sandbox +
# opencode children. Counting must treat the whole wrapper/process tree as
# one logical worker.
#
# GH#6413: Process state filtering — exclude zombie (Z) and stopped (T)
# processes.
#
# Output: one line per logical worker: "pid etime command..."
#######################################
list_active_worker_processes() {
	ps axo pid,stat,etime,command | awk '
		{
			is_headless_wrapper = ($0 ~ /(^|[[:space:]\/])headless-runtime-helper\.sh([[:space:]]|$)/ && $0 ~ /(^|[[:space:]])run([[:space:]]|$)/ && $0 ~ /--role[[:space:]]+worker/)
			has_worker_prompt = ($0 ~ /\/full-loop/ || $0 ~ /\/review-issue-pr/)
			has_worker_binary = ($0 ~ /(^|[[:space:]\/])\.?opencode([[:space:]]|$)/ || $0 ~ /(^|[[:space:]\/])headless-runtime-helper\.sh([[:space:]]|$)/)

			if (!(has_worker_prompt || is_headless_wrapper)) next
			if ($0 ~ /(^|[[:space:]])\/pulse([[:space:]]|$)/) next
			if ($0 ~ /Supervisor Pulse/) next
			if (!has_worker_binary) next

			# $2 is the stat column (e.g., S, SN, Ss, Z, Zs, T, TN)
			stat = $2
			# Exclude zombies (Z*) and stopped processes (T*)
			if (stat ~ /^[ZT]/) next
			# Build output line: pid, etime, command (skip stat)
			line = $1 " " $3
			for (i = 4; i <= NF; i++) line = line " " $i
			# Extract issue number for dedup (matches "Issue #NNN" or "issue-NNN")
			issue = ""
			if (match($0, /[Ii]ssue[[:space:]]*#([0-9]+)/) || match($0, /issue-([0-9]+)/)) {
				rest = substr($0, RSTART, RLENGTH)
				gsub(/[^0-9]/, "", rest)
				issue = rest
			}
			# Fallback: extract from --session-key issue-NNN when no Issue #/issue- marker
			if (issue == "" && match($0, /--session-key[[:space:]]+issue-([0-9]+)/)) {
				rest = substr($0, RSTART, RLENGTH)
				gsub(/[^0-9]/, "", rest)
				issue = rest
			}
			# Extract --dir path for dedup key (same issue in different repos
			# = different logical workers)
			dir = ""
			if (match($0, /--dir[[:space:]]+[^[:space:]]+/)) {
				dir = substr($0, RSTART, RLENGTH)
				sub(/--dir[[:space:]]+/, "", dir)
			}
			dedup_key = issue "|" dir
			# Prefer outer launchers over child processes for same issue+dir.
			launcher_rank = 0
			if ($0 ~ /(^|[[:space:]\/])headless-runtime-helper\.sh([[:space:]]|$)/ && $0 ~ /--role[[:space:]]+worker/) {
				launcher_rank = 2
			} else if ($0 ~ /sandbox-exec-helper\.sh/) {
				launcher_rank = 1
			}
			if (issue != "" && dedup_key in seen) {
				# Already have a line for this issue+dir
				if (launcher_rank > seen_launcher_rank[dedup_key]) {
					# Replace inner child with outer launcher
					seen_lines[dedup_key] = line
					seen_launcher_rank[dedup_key] = launcher_rank
				}
				# Otherwise skip (lower-rank child of existing launcher, or duplicate)
			} else if (issue != "") {
				seen[dedup_key] = 1
				seen_lines[dedup_key] = line
				seen_launcher_rank[dedup_key] = launcher_rank
				key_order[++key_count] = dedup_key
			} else {
				# No issue number found — print directly (edge case)
				no_issue_lines[++no_issue_count] = line
			}
		}
		END {
			for (i = 1; i <= key_count; i++) {
				print seen_lines[key_order[i]]
			}
			for (i = 1; i <= no_issue_count; i++) {
				print no_issue_lines[i]
			}
		}
	'
	return 0
}

#######################################
# Escalate issue model tier after repeated worker failures.
#
# After ESCALATION_FAILURE_THRESHOLD (default 2) failures at the current
# tier, adds tier:thinking label to route the next dispatch to opus.
# If already at tier:thinking, no further escalation — the issue stays
# for the fast-fail skip/needs-human path.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - failure count (current fast-fail count AFTER increment)
#   $4 - kill/failure reason (for the comment)
# Returns: 0 always (best-effort, never fatal)
#######################################
ESCALATION_FAILURE_THRESHOLD="${ESCALATION_FAILURE_THRESHOLD:-2}"

escalate_issue_tier() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="${4:-repeated_failure}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	# Validate threshold
	local threshold="$ESCALATION_FAILURE_THRESHOLD"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=2
	[[ "$threshold" -ge 1 ]] || threshold=2

	# Only escalate at the threshold boundary (not on every subsequent failure)
	if [[ "$failure_count" -ne "$threshold" ]]; then
		return 0
	fi

	# Check current labels — skip if already at tier:thinking
	local current_labels
	current_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""

	case ",$current_labels," in
	*,tier:thinking,*)
		# Already at highest auto-escalation tier
		return 0
		;;
	esac

	# Add tier:thinking label (creates label if needed)
	gh label create "tier:thinking" \
		--repo "$repo_slug" \
		--description "Route to opus-tier model for dispatch" \
		--color "7057FF" \
		--force 2>/dev/null || true

	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "tier:thinking" \
		--remove-label "tier:simple" 2>/dev/null || {
		return 0
	}

	# Post escalation comment
	local comment_body="## Model Tier Escalation

**Trigger:** ${failure_count} consecutive worker failures (threshold: ${threshold})
**Action:** Added \`tier:thinking\` label — next dispatch will use opus-tier model.
**Reason:** ${reason}

Previous attempts at the default model tier failed to produce a PR. Escalating to a more capable model.

_Automated by \`escalate_issue_tier()\` in worker-lifecycle-common.sh_"

	gh issue comment "$issue_number" --repo "$repo_slug" \
		--body "$comment_body" 2>/dev/null || true

	return 0
}

#######################################
# Count active worker processes
# Returns: count via stdout
#######################################
count_active_workers() {
	local count
	count=$(list_active_worker_processes | wc -l | tr -d ' ') || count=0
	echo "$count"
	return 0
}

#######################################
# Count interactive AI sessions (t1398)
#
# Counts opencode/claude processes with a real TTY (interactive sessions).
# Shared between pulse-wrapper.sh and stats-functions.sh.
#
# Arguments: none
# Returns: session count via stdout
#######################################
check_session_count() {
	local interactive_count=0

	# Count opencode processes with a real TTY (interactive sessions).
	# Filter both '?' (Linux) and '??' (macOS) headless TTY entries.
	interactive_count=$(ps axo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || interactive_count=0

	echo "$interactive_count"
	return 0
}
