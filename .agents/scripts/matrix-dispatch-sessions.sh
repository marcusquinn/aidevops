#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Matrix Dispatch Sessions Library — Conversation Session Management
# =============================================================================
# Session listing, statistics, and management for the Matrix dispatch bot.
# Extracted from matrix-dispatch-helper.sh to keep the orchestrator under
# the 2000-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/matrix-dispatch-sessions.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_*, etc.)
#   - matrix-dispatch-helper.sh globals: MEMORY_DB, SESSION_DB
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MATRIX_DISPATCH_SESSIONS_LIB_LOADED:-}" ]] && return 0
_MATRIX_DISPATCH_SESSIONS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Resolve session DB path and table name
# Outputs two lines: db_path, table_name
# Args: subcmd (used for empty-DB messaging)
#######################################
_sessions_resolve_db() {
	local subcmd="$1"
	local db_path="$MEMORY_DB"
	local table_name="matrix_room_sessions"

	if [[ ! -f "$db_path" ]] || ! sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT 1 FROM $table_name LIMIT 1;" &>/dev/null; then
		if [[ -f "$SESSION_DB" ]]; then
			db_path="$SESSION_DB"
			table_name="sessions"
			log_info "Using legacy session store: $SESSION_DB"
		else
			if [[ "$subcmd" == "list" ]]; then
				echo -e "${BOLD}Conversation Sessions${NC}"
				echo "──────────────────────────────────"
				echo "(no sessions — database not yet created)"
				echo "Sessions are created automatically when the bot processes messages."
			else
				log_info "No session database"
			fi
			printf 'NONE\nNONE\n'
			return 0
		fi
	fi

	printf '%s\n%s\n' "$db_path" "$table_name"
	return 0
}

#######################################
# List sessions from entity-aware store
# Args: db_path
#######################################
_sessions_list_entity_aware() {
	local db_path="$1"
	local sessions
	sessions=$(sqlite3 -cmd ".timeout 5000" -separator '|' "$db_path" \
		"SELECT s.room_id, s.runner_name, s.message_count, COALESCE(e.name, ''), s.entity_id, s.last_active
		 FROM matrix_room_sessions s
		 LEFT JOIN entities e ON s.entity_id = e.id
		 ORDER BY s.last_active DESC;" 2>/dev/null)

	if [[ -z "$sessions" ]]; then
		echo "(no sessions)"
		return 0
	fi

	printf "%-35s %-15s %5s %-20s %s\n" "Room ID" "Runner" "Msgs" "Entity" "Last Active"
	printf "%-35s %-15s %5s %-20s %s\n" "───────────────────────────────────" "───────────────" "─────" "────────────────────" "───────────────────"

	while IFS='|' read -r room runner msgs entity_name entity_id active; do
		local entity_display="${entity_name:-${entity_id:-(none)}}"
		printf "%-35s %-15s %5s %-20s %s\n" "$room" "$runner" "$msgs" "$entity_display" "$active"
	done <<<"$sessions"
	return 0
}

#######################################
# List sessions from legacy store
# Args: db_path
#######################################
_sessions_list_legacy() {
	local db_path="$1"
	local sessions
	sessions=$(sqlite3 -cmd ".timeout 5000" -separator '|' "$db_path" \
		"SELECT room_id, runner_name, message_count, length(compacted_context), last_active FROM sessions ORDER BY last_active DESC;" 2>/dev/null)

	if [[ -z "$sessions" ]]; then
		echo "(no sessions)"
		return 0
	fi

	printf "%-40s %-18s %6s %8s %s\n" "Room ID" "Runner" "Msgs" "Context" "Last Active"
	printf "%-40s %-18s %6s %8s %s\n" "────────────────────────────────────────" "──────────────────" "──────" "────────" "───────────────────"

	while IFS='|' read -r room runner msgs ctx_bytes active; do
		local ctx_display
		if [[ "$ctx_bytes" -gt 1024 ]]; then
			ctx_display="$((ctx_bytes / 1024))KB"
		else
			ctx_display="${ctx_bytes}B"
		fi
		printf "%-40s %-18s %6s %8s %s\n" "$room" "$runner" "$msgs" "$ctx_display" "$active"
	done <<<"$sessions"
	return 0
}

#######################################
# Show stats from entity-aware store
# Args: db_path
#######################################
_sessions_stats_entity_aware() {
	local db_path="$1"
	local total_sessions active_sessions matrix_interactions entity_count db_size
	total_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM matrix_room_sessions;" 2>/dev/null || echo "0")
	active_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM matrix_room_sessions WHERE session_id != '';" 2>/dev/null || echo "0")
	matrix_interactions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM interactions WHERE channel = 'matrix';" 2>/dev/null || echo "0")
	entity_count=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM entity_channels WHERE channel = 'matrix';" 2>/dev/null || echo "0")
	db_size=$(_file_size_bytes "$db_path")

	echo "Total sessions:       ${total_sessions:-0}"
	echo "Active sessions:      ${active_sessions:-0}"
	echo "Matrix interactions:  ${matrix_interactions:-0} (Layer 0, immutable)"
	echo "Matrix entities:      ${entity_count:-0}"
	echo "Database:             $db_path ($((${db_size:-0} / 1024))KB)"
	return 0
}

#######################################
# Show stats from legacy store
# Args: db_path
#######################################
_sessions_stats_legacy() {
	local db_path="$1"
	local total_sessions active_sessions total_messages context_bytes db_size
	total_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
	active_sessions=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM sessions WHERE session_id != '';" 2>/dev/null || echo "0")
	total_messages=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COUNT(*) FROM message_log;" 2>/dev/null || echo "0")
	context_bytes=$(sqlite3 -cmd ".timeout 5000" "$db_path" "SELECT COALESCE(SUM(length(compacted_context)), 0) FROM sessions;" 2>/dev/null || echo "0")
	db_size=$(_file_size_bytes "$db_path")

	echo "Total sessions:    ${total_sessions:-0} (legacy store)"
	echo "Active sessions:   ${active_sessions:-0}"
	echo "Messages in log:   ${total_messages:-0}"
	echo "Compacted context: $((${context_bytes:-0} / 1024))KB"
	echo "Database size:     $((${db_size:-0} / 1024))KB"
	return 0
}

#######################################
# Manage conversation sessions
#######################################
cmd_sessions() {
	local subcmd="${1:-list}"
	shift || true

	if ! command -v sqlite3 &>/dev/null; then
		log_error "sqlite3 required for session management"
		return 1
	fi

	ensure_dirs

	local db_info db_path table_name
	db_info=$(_sessions_resolve_db "$subcmd")
	db_path=$(printf '%s' "$db_info" | sed -n '1p')
	table_name=$(printf '%s' "$db_info" | sed -n '2p')

	if [[ "$db_path" == "NONE" ]]; then
		return 0
	fi

	case "$subcmd" in
	list)
		echo -e "${BOLD}Conversation Sessions${NC}"
		echo "──────────────────────────────────"
		if [[ "$table_name" == "matrix_room_sessions" ]]; then
			_sessions_list_entity_aware "$db_path"
		else
			_sessions_list_legacy "$db_path"
		fi
		;;

	clear)
		local room_id="${1:-}"
		if [[ -z "$room_id" ]]; then
			log_error "Room ID required"
			echo "Usage: matrix-dispatch-helper.sh sessions clear '<room_id>'"
			return 1
		fi
		# Clear from entity-aware table (Layer 0 interactions are preserved — immutable)
		sqlite3 -cmd ".timeout 5000" "$db_path" \
			"DELETE FROM $table_name WHERE room_id = '$(printf '%s' "$room_id" | sed "s/'/''/g")';" 2>/dev/null
		log_success "Cleared session for room $room_id"
		log_info "Note: Layer 0 interactions are preserved (immutable). Only session state was cleared."
		;;

	clear-all)
		sqlite3 -cmd ".timeout 5000" "$db_path" \
			"DELETE FROM $table_name;" 2>/dev/null
		log_success "Cleared all sessions"
		log_info "Note: Layer 0 interactions are preserved (immutable). Only session state was cleared."
		;;

	stats)
		echo -e "${BOLD}Session Statistics${NC}"
		echo "──────────────────────────────────"
		if [[ "$table_name" == "matrix_room_sessions" ]]; then
			_sessions_stats_entity_aware "$db_path"
		else
			_sessions_stats_legacy "$db_path"
		fi
		;;

	*)
		log_error "Unknown sessions subcommand: $subcmd"
		echo "Usage: matrix-dispatch-helper.sh sessions [list|clear <room>|clear-all|stats]"
		return 1
		;;
	esac

	return 0
}
