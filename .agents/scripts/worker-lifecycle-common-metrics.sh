#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Lifecycle Common -- Stall Evidence, Metrics & Formatting
# =============================================================================
# Worker stall evidence, markdown/log sanitisers, integer validation,
# commit/message counters, struggle-ratio statistics and duration formatting.
#
# Pure move from worker-lifecycle-common.sh (large-file split, GH#40351):
# function bodies, names and shared variables are unchanged.
#
# Usage: sourced by worker-lifecycle-common.sh; callers keep sourcing that file.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_WORKER_LIFECYCLE_COMMON_METRICS_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_COMMON_METRICS_LOADED=1

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
