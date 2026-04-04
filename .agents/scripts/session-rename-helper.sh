#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# session-rename-helper.sh - Rename OpenCode sessions via SQLite database
# Part of aidevops framework: https://aidevops.sh
#
# Replaces .opencode/tool/session-rename.ts.disabled — the TypeScript tool
# used Bun's SQLite binding; this script uses the sqlite3 CLI directly.
#
# Usage:
#   session-rename-helper.sh rename <session-id> <new-title>
#   session-rename-helper.sh sync-branch [session-id]
#   session-rename-helper.sh list [--limit N]
#   session-rename-helper.sh current
#   session-rename-helper.sh help
#
# Commands:
#   rename <session-id> <title>   Rename a specific session by ID
#   sync-branch [session-id]      Rename session to match current git branch
#   list [--limit N]              List recent sessions (default: 10)
#   current                       Show the most recent session ID and title
#   help                          Show this help
#
# Environment:
#   OPENCODE_DB   Override default DB path (~/.local/share/opencode/opencode.db)
#
# Exit codes:
#   0  Success
#   1  Error (session not found, DB unavailable, missing args)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Constants
# =============================================================================

readonly DEFAULT_DB_PATH="${HOME}/.local/share/opencode/opencode.db"
readonly DEFAULT_LIST_LIMIT=10

# =============================================================================
# Helpers
# =============================================================================

# Resolve the OpenCode SQLite database path.
# Respects OPENCODE_DB env var override.
# Output: absolute path on stdout
# Returns: 1 if DB file does not exist
_get_db_path() {
	local db_path="${OPENCODE_DB:-$DEFAULT_DB_PATH}"
	if [[ ! -f "$db_path" ]]; then
		print_error "OpenCode database not found: ${db_path}"
		print_info "Set OPENCODE_DB to override the default path"
		return 1
	fi
	echo "$db_path"
	return 0
}

# Verify sqlite3 is available.
# Returns: 1 if not found
_require_sqlite3() {
	if ! command -v sqlite3 >/dev/null 2>&1; then
		print_error "sqlite3 is required but not installed"
		print_info "Install via: brew install sqlite (macOS) or apt-get install sqlite3 (Linux)"
		return 1
	fi
	return 0
}

# Escape a string for SQL single-quoted literals.
# Arguments:
#   $1 - raw string
# Output: escaped string on stdout
_sql_escape() {
	local raw_value="$1"
	printf '%s' "$raw_value" | sed "s/'/''/g"
	return 0
}

# Resolve sync target session ID.
# Priority:
#   1) explicit session ID argument
#   2) most recent session whose directory matches $PWD
#   3) most recent session globally
# Arguments:
#   $1 - sqlite database path
#   $2 - optional explicit session ID
# Output: session ID on stdout
# Returns: 0 on success, 1 when no session found
_resolve_sync_session_id() {
	local db_path="$1"
	local explicit_session_id="${2:-}"

	if [[ -n "$explicit_session_id" ]]; then
		printf '%s' "$explicit_session_id"
		return 0
	fi

	local cwd_escaped
	cwd_escaped="$(_sql_escape "$PWD")"

	local session_id
	session_id="$(sqlite3 "$db_path" \
		"SELECT id FROM session WHERE directory = '${cwd_escaped}' ORDER BY time_updated DESC LIMIT 1;" 2>/dev/null || echo "")"

	if [[ -z "$session_id" ]]; then
		session_id="$(sqlite3 "$db_path" \
			"SELECT id FROM session ORDER BY time_updated DESC LIMIT 1;" 2>/dev/null || echo "")"
	fi

	if [[ -z "$session_id" ]]; then
		print_error "No sessions found in database"
		return 1
	fi

	printf '%s' "$session_id"
	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Rename a session by updating its title in the SQLite database.
# Arguments:
#   $1 - session ID
#   $2 - new title
# Returns: 0 on success, 1 on failure
cmd_rename() {
	local session_id="${1:-}"
	local new_title="${2:-}"

	if [[ -z "$session_id" ]]; then
		print_error "session-id is required"
		cmd_help
		return 1
	fi

	if [[ -z "$new_title" ]]; then
		print_error "title is required"
		cmd_help
		return 1
	fi

	_require_sqlite3 || return 1

	local db_path
	db_path="$(_get_db_path)" || return 1

	local now_ms
	now_ms="$(date +%s)000"

	local escaped_title escaped_session_id
	escaped_title="$(_sql_escape "$new_title")"
	escaped_session_id="$(_sql_escape "$session_id")"

	local changes
	changes="$(sqlite3 "$db_path" \
		"UPDATE session SET title = '${escaped_title}', time_updated = ${now_ms} WHERE id = '${escaped_session_id}'; SELECT changes();")"

	if [[ "$changes" -eq 0 ]]; then
		print_error "Session not found: ${session_id}"
		print_info "Run 'session-rename-helper.sh list' to see available sessions"
		return 1
	fi

	print_success "Session renamed to: ${new_title}"
	return 0
}

# Rename the most relevant (or specified) session to match the current git branch.
# Arguments:
#   $1 - session ID (optional; defaults to current-directory session)
# Returns: 0 on success, 1 on failure
cmd_sync_branch() {
	local session_id="${1:-}"

	_require_sqlite3 || return 1

	local db_path
	db_path="$(_get_db_path)" || return 1

	# Resolve session ID (explicit argument, then cwd match, then global fallback)
	session_id="$(_resolve_sync_session_id "$db_path" "$session_id")" || return 1

	# Get current git branch
	local branch
	if ! branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
		print_error "Not in a git repository or git command failed"
		return 1
	fi

	if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
		print_error "No branch checked out (detached HEAD state)"
		return 1
	fi

	cmd_rename "$session_id" "$branch"
	return $?
}

# List recent sessions from the database.
# Arguments:
#   --limit N   Number of sessions to show (default: 10)
# Returns: 0 always
cmd_list() {
	local limit="$DEFAULT_LIST_LIMIT"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit)
			[[ $# -lt 2 ]] && {
				print_error "--limit requires a value"
				return 1
			}
			limit="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	_require_sqlite3 || return 1

	local db_path
	db_path="$(_get_db_path)" || return 1

	printf "%-36s  %-50s  %s\n" "ID" "Title" "Updated"
	printf "%-36s  %-50s  %s\n" "$(printf '%0.s-' {1..36})" "$(printf '%0.s-' {1..50})" "----------"

	sqlite3 -separator $'\t' "$db_path" \
		"SELECT id, title, datetime(time_updated/1000, 'unixepoch', 'localtime') FROM session ORDER BY time_updated DESC LIMIT ${limit};" \
		2>/dev/null | while IFS=$'\t' read -r sid title updated; do
		printf "%-36s  %-50s  %s\n" "$sid" "${title:0:50}" "$updated"
	done

	return 0
}

# Show the most recent session ID and title.
# Returns: 0 on success, 1 if no sessions found
cmd_current() {
	_require_sqlite3 || return 1

	local db_path
	db_path="$(_get_db_path)" || return 1

	local result
	result="$(sqlite3 -separator $'\t' "$db_path" \
		"SELECT id, title FROM session ORDER BY time_updated DESC LIMIT 1;" 2>/dev/null || echo "")"

	if [[ -z "$result" ]]; then
		print_warning "No sessions found in database"
		return 1
	fi

	local sid title
	IFS=$'\t' read -r sid title <<<"$result"

	printf "ID:    %s\n" "$sid"
	printf "Title: %s\n" "$title"
	return 0
}

cmd_help() {
	sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	rename) cmd_rename "$@" ;;
	sync-branch) cmd_sync_branch "$@" ;;
	list) cmd_list "$@" ;;
	current) cmd_current ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
