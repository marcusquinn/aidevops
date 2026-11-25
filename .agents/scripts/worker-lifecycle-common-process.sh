#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Lifecycle Common -- Process Tree & Session Tail Helpers
# =============================================================================
# OpenCode session DB tail queries, process tree kill/age/CPU primitives
# and watchdog kill-reason classification.
#
# Pure move from worker-lifecycle-common.sh (large-file split, GH#40351):
# function bodies, names and shared variables are unchanged.
#
# Usage: sourced by worker-lifecycle-common.sh; callers keep sourcing that file.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_WORKER_LIFECYCLE_COMMON_PROCESS_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_COMMON_PROCESS_LOADED=1

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
# Walk a process tree breadth-first and emit all descendant PIDs (t3059)
#
# Iteratively walks the full descendant tree using pgrep -P at each
# level. The root PID itself is NOT emitted — only its descendants
# (children, grandchildren, …). Output is one PID per line, deduped
# via sort -u. Returns nothing (zero lines) for a leaf process.
#
# pgrep -P only returns DIRECT children. A naive one-level pgrep
# undercounts when active processes are nested deeper than one level
# (e.g., parent shell → opencode wrapper → node runtime → language
# server). Walking BFS preserves the full tree.
#
# Used by:
#   _get_process_tree_cpu (t1398.3) — sum CPU% across whole tree
#   _watchdog_tree_cpu    (t3059)   — same primitive in worker-activity-watchdog.sh
#
# Arguments:
#   arg1 - root PID
# Returns: descendant PIDs, one per line, sorted+deduped, via stdout
#######################################
_get_descendant_pids() {
	local root_pid="$1"
	[[ "$root_pid" =~ ^[0-9]+$ ]] || return 0

	local pids_to_scan=("$root_pid")
	local descendants=()
	local i=0
	while [[ $i -lt ${#pids_to_scan[@]} ]]; do
		local current_pid="${pids_to_scan[$i]}"
		local child
		while IFS= read -r child; do
			if [[ -n "$child" ]]; then
				pids_to_scan+=("$child")
				descendants+=("$child")
			fi
		done < <(pgrep -P "$current_pid" 2>/dev/null || true)
		i=$((i + 1))
	done

	# Bash 3.2: guard against expanding an empty array under set -u.
	if [[ ${#descendants[@]} -gt 0 ]]; then
		printf "%s\n" "${descendants[@]}" | sort -u
	fi
	return 0
}

#######################################
# Get CPU usage percentage for a process tree (t1398.3, refactored t3059)
#
# Walks the full descendant tree (BFS) via _get_descendant_pids, then
# sums per-PID CPU% (root + descendants) via _get_pid_cpu. Previous
# inline-BFS implementation was duplicated in worker-activity-watchdog.sh's
# _watchdog_tree_cpu (one-level pgrep -P only); both now share the helper.
#
# Arguments:
#   arg1 - PID
# Returns: integer CPU percentage via stdout (0-N, summed across cores)
#######################################
_get_process_tree_cpu() {
	local pid="$1"
	local total_cpu
	total_cpu=$(_get_pid_cpu "$pid")

	local descendant
	while IFS= read -r descendant; do
		[[ -n "$descendant" ]] || continue
		local cpu
		cpu=$(_get_pid_cpu "$descendant")
		total_cpu=$((total_cpu + cpu))
	done < <(_get_descendant_pids "$pid")

	echo "$total_cpu"
	return 0
}

#######################################
# Return whether the most recent worker output records a trusted provider
# failure (GH#34067).
#
# Only the trusted classifier (headless-runtime-provider-classifier.py, also
# used by the fast rate-limit monitor) may identify provider failures. It
# accepts structured APIError events and runtime-tagged lines, never free text
# from tool results or documentation. Only the output tail is classified, so a
# provider error the runtime already recovered from cannot justify a later kill.
#
# Arguments:
#   arg1 - worker output file
#   arg2 - tail lines to classify (optional; default
#          WORKER_PROVIDER_FAILURE_TAIL_LINES, then 40)
# Returns: 0 for rate_limit, quota_exceeded or provider server errors; 1 otherwise
#######################################
_worker_output_has_fresh_provider_failure() {
	local output_file="$1"
	local tail_lines="${2:-${WORKER_PROVIDER_FAILURE_TAIL_LINES:-40}}"
	local classifier="${_WLC_SCRIPT_DIR}/headless-runtime-provider-classifier.py"
	local classification="" reason="" provider_type="" _rest=""

	[[ -f "$output_file" && -f "$classifier" ]] || return 1
	[[ "$tail_lines" =~ ^[1-9][0-9]*$ ]] || tail_lines=40
	classification=$(tail -n "$tail_lines" "$output_file" 2>/dev/null |
		python3 "$classifier" /dev/stdin 2>/dev/null) || return 1
	[[ -n "$classification" ]] || return 1
	IFS=$'\t' read -r reason provider_type _rest <<<"$classification"
	case "$reason" in
	rate_limit | quota_exceeded) return 0 ;;
	provider_error)
		[[ "$provider_type" == "server_error" ]] && return 0
		;;
	esac
	return 1
}

#######################################
# Map a watchdog kill reason string to the class persisted in
# ${exit_code_file}.kill_reason and emitted in [lifecycle] worker_killed
# lines (t3056 / GH#34067). One mapping keeps telemetry, the persisted
# reason and classify_worker_kill_reason in agreement.
#
# Arguments:
#   arg1 - human-readable reason, prefixed with its kill path
# Returns: class string via stdout; 0 always
#######################################
_worker_kill_reason_class() {
	local reason="$1"
	case "$reason" in
	phase1:*) printf '%s' "phase1_zero_output" ;;
	# GH#34068: elapsed cap reached while liveness deferrals were recent —
	# policy-cap termination, not proven inactivity.
	hard_kill_cap_active:*) printf '%s' "hard_kill_cap_active" ;;
	hard_kill:*) printf '%s' "hard_kill_stall" ;;
	provider_rate_limit:*) printf '%s' "provider_rate_limit" ;;
	stall:*) printf '%s' "no_output_stall" ;;
	*) printf '%s' "other" ;;
	esac
	return 0
}
