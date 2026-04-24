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
#   session_tail_query.py              Session tail classification (GH#6428)
#   worker_lifecycle_extract_title.py  Extract --title from CLI args (GH#17561)
#   worker_lifecycle_stall_evidence.py Classify worker log tail (GH#17561)
#   worker_lifecycle_resolve_session.py Resolve session ID from title (GH#17561)
#   worker_lifecycle_count_messages.py Count session DB messages (GH#17561)
#   list_active_workers.awk            Deduplicate active worker processes (GH#17561)
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
#   cmd - command line string
# Returns: session title or empty string via stdout
#
# Logic extracted to worker_lifecycle_extract_title.py (GH#17561).
#######################################
_extract_session_title() {
	local cmd="$1"
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local py_script="${script_dir}/worker_lifecycle_extract_title.py"
	local session_title=""

	if [[ -f "$py_script" ]]; then
		session_title=$(SESSION_CMD="$cmd" python3 "$py_script" 2>/dev/null) || session_title=""
	fi

	printf '%s' "${session_title:-}"
	return 0
}

#######################################
# Validate preconditions for session tail evidence collection
# Arguments:
#   cmd - worker command line
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
#   db_path
#   session_title
#   timeout_seconds
#   part_limit
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
#   arg1 - worker command line
#   arg2 - recent activity timeout seconds
#   arg3 - maximum parts to inspect (optional, default: 8)
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
#   arg1 - PID to kill
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
#   arg1 - PID to kill
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
#   arg1 - PID
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
#   arg1 - PID
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
#   arg1 - PID
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
#   arg1 - command line string
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
#   arg1 - command line string
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

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# Logic extracted to worker_lifecycle_resolve_session.py (GH#17561)
	session_id=$(
		DB_PATH="$db_path" TITLE="$session_title" \
			python3 "${script_dir}/worker_lifecycle_resolve_session.py"
	) 2>/dev/null || session_id=""

	printf '%s' "$session_id"
	return 0
}

#######################################
# Count recent OpenCode messages for sessions matching a title fragment
# Arguments:
#   arg1 - title fragment (task ID or session title)
#   arg2 - recent window in seconds
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

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local recent_count
	# Logic extracted to worker_lifecycle_count_messages.py (GH#17561)
	recent_count=$(
		DB_PATH="$db_path" MODE="recent" MATCH="$session_match" WINDOW="$recent_window" \
			python3 "${script_dir}/worker_lifecycle_count_messages.py"
	) 2>/dev/null || recent_count=0
	[[ "$recent_count" =~ ^[0-9]+$ ]] || recent_count=0

	printf '%s' "$recent_count"
	return 0
}

#######################################
# Summarise recent worker transcript/output evidence for stall diagnosis
# Arguments:
#   arg1 - session title fragment (task ID or exact title)
#   arg2 - log file path (optional)
#   arg3 - recent window in seconds
#   arg4 - number of log lines to inspect
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

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local py_script="${script_dir}/worker_lifecycle_stall_evidence.py"

	local evidence
	# Logic extracted to worker_lifecycle_stall_evidence.py (GH#17561)
	evidence=$(python3 "$py_script" "$log_file" "$tail_lines" 2>/dev/null) || evidence=""

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
#   arg1 - variable name (for error messages)
#   arg2 - value to validate
#   arg3 - default value if invalid
#   arg4 - minimum value (optional, default: 0)
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
#   arg1 - worktree directory path
#   arg2 - elapsed seconds (time window for git log)
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
#   arg1 - worker command line
#   arg2 - elapsed seconds (time window for message query)
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
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		# Logic extracted to worker_lifecycle_count_messages.py (GH#17561)
		messages=$(
			DB_PATH="$db_path" MODE="session" MATCH="$session_id" WINDOW="$elapsed_seconds" \
				python3 "${script_dir}/worker_lifecycle_count_messages.py"
		) 2>/dev/null || messages=0
	fi

	echo "available|${messages}"
	return 0
}

#######################################
# Determine the struggle flag from ratio/commit/elapsed metrics (GH#17078)
# Arguments:
#   arg1 - ratio (messages / max(1, commits))
#   arg2 - commits count
#   arg3 - elapsed seconds
#   arg4 - min elapsed seconds threshold
#   arg5 - ratio threshold for "struggling"
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
#   arg1 - worker PID
#   arg2 - worker elapsed seconds
#   arg3 - worker command line
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
#   arg1 - seconds
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
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local awk_script="${script_dir}/list_active_workers.awk"
	# Awk logic extracted to list_active_workers.awk (GH#17561)
	# t2190: use `axww` (unlimited line width) so Linux procps doesn't
	# truncate the command column to the detected terminal width (~80
	# cols when piped). Worker commands contain the full HEADLESS_
	# CONTINUATION_CONTRACT_V6 prompt (5000+ chars); without `ww`, the
	# awk match on `/full-loop`, `--role worker`, `--session-key issue-NNN`,
	# and `--dir <path>` all fail — has_worker_for_repo_issue returns
	# false within the 35s grace window, recover_failed_launch_state
	# unassigns the worker, and every dispatch cycle loops on the same
	# issue. macOS BSD ps already emits full commands; `ww` is harmless
	# there (and also supported).
	ps axwwo pid,stat,etime,command | awk -f "$awk_script"
	return 0
}

#######################################
# Body quality gate for escalate_issue_tier (GH#17561)
# Returns 0 if escalation should proceed, 1 if blocked (posts diagnostic comment).
# Arguments:
#   arg1 - issue number
#   arg2 - repo slug
#   arg3 - failure count
#   arg4 - threshold
#   arg5 - issue body text
#######################################
_escalate_body_quality_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local threshold="$4"
	local issue_body="$5"

	# Empty body — no context to check, allow escalation
	[[ -n "$issue_body" ]] || return 0

	# Check for file path indicators: paths with extensions, EDIT:/NEW: prefixes,
	# backtick-quoted paths, or "Files to Modify" section headers.
	# shellcheck disable=SC2016 # pattern is literal regex; no variable expansion intended
	if echo "$issue_body" | grep -qE '(EDIT:|NEW:|`[a-zA-Z0-9_./-]+\.[a-z]+`|Files to Modify|## How|\.sh:|\.py:|\.ts:|\.js:|\.md:)'; then
		return 0
	fi

	# Body lacks implementation context — post diagnostic instead of escalating
	local diag_body="## Escalation Blocked: Missing Implementation Context

**Trigger:** ${failure_count} consecutive worker failures (threshold: ${threshold})
**Action:** Escalation **skipped** — issue body lacks file paths and implementation steps.

Workers fail when they must explore the entire codebase to find what to change. Adding explicit file paths, reference patterns, and verification commands to the issue body is more effective than escalating to a more expensive model.

**Required:** Update the issue body with a \`## How\` section containing:
- Files to modify (with paths and line ranges)
- Reference pattern (\`model on <existing-file>\`)
- Verification command

_Automated by \`escalate_issue_tier()\` body quality gate (t1900) in worker-lifecycle-common.sh_"
	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "$diag_body" 2>/dev/null || true
	return 1
}

#######################################
# Post an idempotent diagnostic comment when tier escalation is skipped
# because the worker crashed with crash_type=no_work (infrastructure
# failure — FD exhaustion, plugin init crash, branch naming race, auth
# refresh race). Tier escalation is the wrong response to infra failures:
# a more expensive model cannot fix an FD leak. We keep the issue at its
# current tier, let the next retry attempt run cheaply after the infra
# issue resolves, and rely on the existing circuit breakers to apply NMR
# on cost/staleness thresholds if retries keep failing.
#
# Idempotent: checks for a prior comment with the marker
# <!-- no-work-escalation-skip --> and skips if present, so a cascade of
# consecutive no_work failures doesn't spam the issue with duplicates.
#
# Arguments:
#   arg1 - issue number
#   arg2 - repo slug (owner/repo)
#   arg3 - failure count (for context)
#   arg4 - kill/failure reason (sanitised)
# Returns: 0 always (best-effort, never fatal)
#######################################
_log_no_work_skip_escalation() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="${4:-worker_exited_before_reading_brief}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local nmr_threshold="${NO_WORK_NMR_THRESHOLD:-3}"

	# Circuit-breaker path (t2769): when failure_count reaches the threshold,
	# apply needs-maintainer-review with a marker that
	# _nmr_application_is_circuit_breaker_trip recognises, so auto-approval
	# preserves NMR (t2386 split semantics).
	if [[ "$failure_count" -ge "$nmr_threshold" ]]; then
		local nmr_marker='cost-circuit-breaker:no_work_loop'
		local existing_nmr=""
		existing_nmr=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate \
			--jq "[.[] | select(.body | contains(\"${nmr_marker}\"))] | length" \
			2>/dev/null) || existing_nmr=""
		if [[ "$existing_nmr" =~ ^[1-9][0-9]*$ ]]; then
			printf '[worker-lifecycle][t2769] no_work NMR circuit breaker already applied for #%s (%s, count=%s)\n' \
				"$issue_number" "$repo_slug" "$failure_count" >&2 || true
			return 0
		fi

		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-maintainer-review" 2>/dev/null || true

		local safe_reason
		safe_reason=$(_sanitize_markdown "$reason")

		gh_issue_comment "$issue_number" --repo "$repo_slug" \
			--body "<!-- ${nmr_marker} -->
## no_work Circuit Breaker Fired (t2769)

**Trigger:** ${failure_count} consecutive worker failure(s) classified as \`no_work\` (threshold: ${nmr_threshold}).
**Action:** Applied \`needs-maintainer-review\`. Further automated dispatch is suspended.
**Last failure reason:** ${safe_reason}

**Why this class of failure does not cascade tiers:** \`no_work\` means the worker crashed during runtime setup before reading any target files (FD exhaustion, plugin init failure, auth refresh race). A more expensive model cannot fix an infrastructure problem it never reached.

**Possible causes:**
- Brief not yet merged or branch missing at dispatch time
- Auth token stale or missing
- Plugin init crash (FD exhaustion, env pollution)
- Branch naming race at dispatch time

Remove \`needs-maintainer-review\` after investigating the root cause to re-enable dispatch.

_Per-issue no_work circuit breaker (t2769). The \`${nmr_marker}\` marker is recognised by \`_nmr_application_is_circuit_breaker_trip\` in \`pulse-nmr-approval.sh\` (t2386 split semantics: auto-approval preserves NMR)._" 2>/dev/null || true

		printf '[worker-lifecycle][t2769] no_work NMR circuit breaker fired for #%s (%s, count=%s)\n' \
			"$issue_number" "$repo_slug" "$failure_count" >&2 || true
		return 0
	fi

	# Below threshold: idempotent diagnostic comment (existing t2387 behaviour).
	local marker='<!-- no-work-escalation-skip -->'

	# Idempotency check: skip if a prior comment already carries the marker.
	# Best-effort — if gh api fails, fall through and post (better to repeat
	# once than to lose the diagnostic entirely).
	local existing=""
	existing=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq "[.[] | select(.body | contains(\"${marker}\"))] | length" \
		2>/dev/null) || existing=""
	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		# Already posted once — nothing more to do. Still emit a one-line
		# log so operators can track the skip rate if they're tailing logs.
		printf '[worker-lifecycle][t2387] no_work skip-escalation already recorded for #%s (%s, count=%s)\n' \
			"$issue_number" "$repo_slug" "$failure_count" >&2 || true
		return 0
	fi

	local safe_reason
	safe_reason=$(_sanitize_markdown "$reason")

	local comment_body="${marker}
## Tier Escalation Skipped: Infrastructure Failure (no_work)

**Trigger:** ${failure_count} worker failure(s) classified as \`no_work\` — the worker exited during setup without reading any target files.
**Action:** Tier escalation **skipped**. The issue stays at its current tier so the next retry can succeed cheaply once the infrastructure issue resolves.
**Reason:** ${safe_reason}

**Why no cascade:** \`no_work\` means the worker never engaged with the brief — it crashed during runtime setup (FD exhaustion, plugin init failure, branch naming race, auth refresh race). A more expensive model cannot fix an infrastructure problem it never reached. Cascading to \`tier:thinking\` would burn opus tokens on a problem sonnet (or haiku) will handle once the infra clears.

After ${nmr_threshold} consecutive \`no_work\` failures the per-issue no_work circuit breaker (t2769) applies \`needs-maintainer-review\` with a \`cost-circuit-breaker:no_work_loop\` marker that \`_nmr_application_is_circuit_breaker_trip\` (t2386) recognises, so auto-approval correctly preserves NMR.

_Automated by \`escalate_issue_tier()\` no_work skip (t2387) in worker-lifecycle-common.sh_"

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "$comment_body" 2>/dev/null || true

	printf '[worker-lifecycle][t2387] no_work skip-escalation posted for #%s (%s, count=%s)\n' \
		"$issue_number" "$repo_slug" "$failure_count" >&2 || true
	return 0
}

#######################################
# Escalate issue model tier after repeated worker failures.
#
# Cascade escalation: tier:simple → tier:standard → tier:thinking.
# Crash-type-aware thresholds determine when escalation fires:
#   - "overwhelmed": model read files, attempted work, but couldn't complete
#     → escalate immediately (threshold=1). Retrying at the same tier wastes
#     tokens on the same complexity the model already failed on.
#   - "no_work": infrastructure failure (FD exhaustion, plugin init crash,
#     auth refresh race). **Short-circuits BEFORE tier cascade** (t2387) —
#     a more expensive model cannot fix infrastructure. Keeps the issue
#     at its current tier and posts a diagnostic comment via
#     _log_no_work_skip_escalation; existing circuit breakers apply NMR
#     on cost/staleness thresholds if retries persist.
#   - "partial" / other: default threshold (2). Model got partway, may
#     succeed with a continuation or fresh attempt.
#
# If already at tier:thinking, no further escalation — the issue stays
# for the needs-human path.
#
# Each escalation posts a structured report to the issue so the next
# tier starts with accumulated context, not from zero.
#
# Arguments:
#   arg1 - issue number
#   arg2 - repo slug (owner/repo)
#   arg3 - failure count (current fast-fail count AFTER increment)
#   arg4 - kill/failure reason (for the comment)
#   arg5 - crash type: "overwhelmed" | "no_work" | "partial" | "" (optional)
# Returns: 0 always (best-effort, never fatal)
#######################################
ESCALATION_FAILURE_THRESHOLD="${ESCALATION_FAILURE_THRESHOLD:-2}"
ESCALATION_OVERWHELMED_THRESHOLD="${ESCALATION_OVERWHELMED_THRESHOLD:-1}"
NO_WORK_NMR_THRESHOLD="${NO_WORK_NMR_THRESHOLD:-3}"

escalate_issue_tier() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="${4:-repeated_failure}"
	local crash_type="${5:-}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	# Validate failure_count is numeric (CodeRabbit review)
	[[ "$failure_count" =~ ^[0-9]+$ ]] || return 0

	# Select threshold based on crash type:
	# - "overwhelmed" = model attempted real work but couldn't complete.
	#   Immediate escalation (threshold=1) because retrying at the same
	#   tier reproduces the same failure mode.
	# - "no_work" / other = transient/infra failures. Use default (2).
	local threshold="$ESCALATION_FAILURE_THRESHOLD"
	if [[ "$crash_type" == "overwhelmed" ]]; then
		threshold="$ESCALATION_OVERWHELMED_THRESHOLD"
	fi
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=2
	[[ "$threshold" -ge 1 ]] || threshold=2

	# t2387: no_work crashes are infrastructure failures (FD exhaustion,
	# plugin init crash, branch naming race, auth refresh race — see t2116
	# session memory). Tier escalation is the wrong response: a more
	# expensive model cannot fix an FD leak or an auth race. Skip the
	# cascade entirely and keep the issue at its current tier so the
	# next retry can succeed cheaply once the infra issue resolves. If
	# retries keep failing, the existing circuit-breaker helpers
	# (cost-circuit-breaker, dispatch-dedup-stale, stale-recovery) apply
	# NMR on their own thresholds using markers that t2386
	# _nmr_application_is_circuit_breaker_trip recognises, so auto-approval
	# preserves the NMR correctly. This early return also subsumes the
	# t2119 body-quality-gate skip — the later gate call becomes
	# unreachable on no_work crashes, so the original inline != guard is
	# no longer needed there.
	if [[ "$crash_type" == "no_work" ]]; then
		_log_no_work_skip_escalation "$issue_number" "$repo_slug" \
			"$failure_count" "$reason"
		return 0
	fi

	# Only escalate at the threshold boundary (not on every subsequent failure)
	if [[ "$failure_count" -ne "$threshold" ]]; then
		return 0
	fi

	# Determine current tier and next tier in cascade
	local current_labels
	current_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""

	local current_tier="standard"
	local next_tier=""
	local next_label=""
	local remove_label=""

	# Check for model:opus-4-7 override label first — signals a previous
	# cascade step already escalated from opus-4.6 to opus-4.7 within
	# tier:thinking (t2239). When both tier:thinking AND model:opus-4-7
	# are present, the cascade is exhausted — hand off to NMR.
	local has_opus_47_label=false
	case ",$current_labels," in
	*,model:opus-4-7,*) has_opus_47_label=true ;;
	esac

	# Determine current tier — tier:thinking is the canonical opus-tier label.
	# Within tier:thinking there is a further rung: opus-4.6 (default) →
	# opus-4.7 (via model:opus-4-7 label override) → NMR (t2239).
	case ",$current_labels," in
	*,tier:thinking,*)
		if [[ "$has_opus_47_label" == "true" ]]; then
			# Already escalated to opus-4.7 within tier:thinking — terminal
			return 0
		fi
		# tier:thinking on opus-4.6 → add model:opus-4-7 override.
		# Keep the tier:thinking label for history; the model: override
		# takes precedence in pulse-model-routing.sh label resolution.
		current_tier="thinking (opus-4.6)"
		next_tier="thinking (opus-4.7)"
		next_label="model:opus-4-7"
		remove_label=""
		;;
	*,tier:standard,*)
		current_tier="standard"
		next_tier="thinking"
		next_label="tier:thinking"
		remove_label="tier:standard"
		;;
	*,tier:simple,*)
		current_tier="simple"
		next_tier="standard"
		next_label="tier:standard"
		remove_label="tier:simple"
		;;
	*)
		# No tier label — treat as standard, escalate to thinking
		current_tier="standard"
		next_tier="thinking"
		next_label="tier:thinking"
		remove_label=""
		;;
	esac

	# Body quality gate (t1900): check if the issue body has implementation
	# context before escalating. If the body lacks file paths, the root cause
	# is a vague issue — not model capability. Escalating wastes a more
	# expensive model on the same exploration problem.
	#
	# Note: t2119 originally added an inline `crash_type != "no_work"` guard
	# here so no_work crashes would bypass the body-gate. That guard was
	# removed by t2387 when the entire function gained an earlier
	# `crash_type == "no_work"` short-circuit that returns before reaching
	# this point — so only overwhelmed / partial / unclassified reach here,
	# and every path through the function that gets here wants the gate
	# evaluated.
	local issue_body
	issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || issue_body=""
	_escalate_body_quality_gate "$issue_number" "$repo_slug" \
		"$failure_count" "$threshold" "$issue_body" || return 0

	# Create next tier label (creates label if needed)
	local label_desc=""
	local label_color=""
	case "$next_label" in
	tier:thinking)
		label_desc="Route to opus-tier model for dispatch"
		label_color="7057FF"
		;;
	tier:standard)
		label_desc="Route to sonnet-tier model for dispatch"
		label_color="0E8A16"
		;;
	model:opus-4-7)
		# Model-override label (t2239). Takes precedence over tier:*
		# labels in pulse-model-routing.sh resolve_dispatch_model_for_labels.
		# Applied either by the cascade (after opus-4.6 exhausts its retries
		# at tier:thinking) or manually by maintainers to jump straight to
		# opus-4.7 for short-context high-reasoning tasks.
		label_desc="Override: route dispatch to claude-opus-4-7 (wins over tier:*)"
		label_color="0075CA"
		;;
	esac

	gh label create "$next_label" \
		--repo "$repo_slug" \
		--description "$label_desc" \
		--color "$label_color" \
		--force 2>/dev/null || true

	# Swap tier labels
	local edit_args="--add-label $next_label"
	if [[ -n "$remove_label" ]]; then
		edit_args="$edit_args --remove-label $remove_label"
	fi
	# shellcheck disable=SC2086
	gh issue edit "$issue_number" --repo "$repo_slug" \
		$edit_args 2>/dev/null || {
		return 0
	}

	# Post escalation comment (sanitize reason to prevent markdown injection)
	local safe_reason
	safe_reason=$(_sanitize_markdown "$reason")
	local crash_type_label=""
	case "$crash_type" in
	overwhelmed)
		crash_type_label="**Crash type:** \`overwhelmed\` — model read target files and attempted implementation but could not produce commits. Immediate escalation triggered (threshold=1)."
		;;
	partial)
		crash_type_label="**Crash type:** \`partial\` — worker produced commits but could not complete the PR lifecycle."
		;;
	esac
	# Note: t2387 removed the `no_work` case here because that crash_type
	# short-circuits at the top of escalate_issue_tier and never reaches
	# the comment-posting path. Infrastructure failures get their own
	# diagnostic comment via _log_no_work_skip_escalation instead.
	local comment_body="## Cascade Tier Escalation: tier:${current_tier} → tier:${next_tier}

**Trigger:** ${failure_count} consecutive worker failures at \`tier:${current_tier}\` (threshold: ${threshold})
**Action:** Added \`${next_label}\` label — next dispatch will use ${next_tier}-tier model.
**Reason:** ${safe_reason}
${crash_type_label:+${crash_type_label}
}
Previous attempts at \`tier:${current_tier}\` failed to produce a PR. Escalating to a more capable model with accumulated context from prior attempts.

The next worker should review prior attempt comments on this issue for context on what was tried and where it got stuck.

_Automated by \`escalate_issue_tier()\` cascade dispatch in worker-lifecycle-common.sh_"

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "$comment_body" 2>/dev/null || true

	# Record escalation in tier telemetry
	local ledger_helper="${HOME}/.aidevops/agents/scripts/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		"$ledger_helper" record-outcome \
			--issue "$issue_number" --repo "$repo_slug" \
			--outcome "escalated" --tier "$current_tier" \
			--reason "$safe_reason" 2>/dev/null || true
	fi

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
	# t2190: ps axwwo so the awk regex isn't defeated by Linux procps truncation.
	interactive_count=$(ps axwwo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || interactive_count=0

	echo "$interactive_count"
	return 0
}
