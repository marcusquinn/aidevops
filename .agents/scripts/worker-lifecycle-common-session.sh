#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Lifecycle Common -- Session Resolution
# =============================================================================
# Session title extraction from opencode command lines, session ID
# resolution and recent-message counting.
#
# Pure move from worker-lifecycle-common.sh (large-file split, GH#40351):
# function bodies, names and shared variables are unchanged.
#
# Usage: sourced by worker-lifecycle-common.sh; callers keep sourcing that file.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_WORKER_LIFECYCLE_COMMON_SESSION_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_COMMON_SESSION_LOADED=1

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
