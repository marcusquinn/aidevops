#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# OpenCode DB maintenance -- Subcommand: sessions
# =============================================================================
# Split from opencode-db-maintenance-helper.sh (cmd_sessions and session query helpers).
# Sourced by the helper; relies on its constants and shared helpers.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_OPENCODE_DB_MAINTENANCE_SESSIONS_LOADED:-}" ]] && return 0
_OPENCODE_DB_MAINTENANCE_SESSIONS_LOADED=1

# -----------------------------------------------------------------------------
# Subcommand: sessions
# -----------------------------------------------------------------------------

_sql_quote() {
	local value="$1"
	value=${value//\'/\'\'}
	printf "'%s'" "$value"
	return 0
}

_json_escape() {
	local value="$1"
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\t'/\\t}
	value=${value//$'\n'/\\n}
	value=${value//$'\r'/\\r}
	printf '%s' "$value"
	return 0
}

_sessions_column_exists() {
	local db="$1"
	local column="$2"
	local found
	found=$("$SQLITE3_BIN" -readonly "$db" "SELECT 1 FROM pragma_table_info('session') WHERE name='$column' LIMIT 1;" 2>/dev/null) || true
	[[ "$found" == "1" ]] && return 0
	return 1
}

_sessions_select_expr() {
	local db="$1"
	local column="$2"
	local fallback="$3"
	if _sessions_column_exists "$db" "$column"; then
		printf 's.%s' "$column"
	else
		printf '%s' "$fallback"
	fi
	return 0
}

_sessions_parent_title_expr() {
	local db="$1"
	if _sessions_column_exists "$db" "$SESSION_PARENT_ID_COLUMN"; then
		printf "COALESCE(p.title, '')"
	else
		printf "''"
	fi
	return 0
}

_sessions_from_join() {
	local db="$1"
	if _sessions_column_exists "$db" "$SESSION_PARENT_ID_COLUMN"; then
		printf 'session s LEFT JOIN session p ON p.id = s.%s' "$SESSION_PARENT_ID_COLUMN"
	else
		printf 'session s'
	fi
	return 0
}

_sessions_status_expr() {
	local db="$1"
	local source="$2"
	if [[ "$source" == "archive" ]]; then
		printf "'archived'"
	elif _sessions_column_exists "$db" "$SESSION_PARENT_ID_COLUMN"; then
		printf "CASE WHEN COALESCE(s.%s, '') <> '' THEN 'active-child' ELSE 'active-top-level' END" "$SESSION_PARENT_ID_COLUMN"
	else
		printf "'active-top-level'"
	fi
	return 0
}

_sessions_project_mismatch_expr() {
	local db="$1"
	if _sessions_column_exists "$db" "$SESSION_PROJECT_ID_COLUMN"; then
		printf "CASE WHEN COALESCE(s.directory, '') <> '' AND (SELECT COUNT(DISTINCT COALESCE(s2.%s, '')) FROM session s2 WHERE s2.directory = s.directory) > 1 THEN 'possible-project-id-mismatch' ELSE '' END" "$SESSION_PROJECT_ID_COLUMN"
	else
		printf "''"
	fi
	return 0
}

_sessions_query_db() {
	local db="$1"
	local source="$2"
	local query="$3"
	local exact_id="$4"
	local directory="$5"
	local limit="$6"

	[[ -f "$db" ]] || return 0

	local title_expr directory_expr project_expr parent_expr created_expr updated_expr parent_title_expr from_join status_expr mismatch_expr
	title_expr=$(_sessions_select_expr "$db" "title" "''")
	directory_expr=$(_sessions_select_expr "$db" "directory" "''")
	project_expr=$(_sessions_select_expr "$db" "$SESSION_PROJECT_ID_COLUMN" "''")
	parent_expr=$(_sessions_select_expr "$db" "$SESSION_PARENT_ID_COLUMN" "''")
	created_expr=$(_sessions_select_expr "$db" "time_created" "''")
	updated_expr=$(_sessions_select_expr "$db" "time_updated" "$created_expr")
	parent_title_expr=$(_sessions_parent_title_expr "$db")
	from_join=$(_sessions_from_join "$db")
	status_expr=$(_sessions_status_expr "$db" "$source")
	mismatch_expr=$(_sessions_project_mismatch_expr "$db")

	local where="1=1"
	if [[ -n "$exact_id" ]]; then
		where="s.id = $(_sql_quote "$exact_id")"
	elif [[ -n "$query" ]]; then
		local like
		like=$(_sql_quote "%${query}%")
		where="(s.id LIKE $like OR $title_expr LIKE $like OR $directory_expr LIKE $like OR $project_expr LIKE $like)"
	fi
	if [[ -n "$directory" ]]; then
		local dir_like
		dir_like=$(_sql_quote "%${directory}%")
		where="($where) AND $directory_expr LIKE $dir_like"
	fi

	"$SQLITE3_BIN" -readonly -separator $'\037' "$db" "
SELECT '$source', $status_expr, s.id, COALESCE($title_expr, ''), COALESCE($directory_expr, ''),
       COALESCE($project_expr, ''), COALESCE($parent_expr, ''), $parent_title_expr,
       COALESCE($created_expr, ''), COALESCE($updated_expr, ''), $mismatch_expr
FROM $from_join
WHERE $where
ORDER BY COALESCE($updated_expr, $created_expr, 0) DESC, s.id
LIMIT $limit;" 2>/dev/null || return 1
	return 0
}

_sessions_print_json() {
	local rows="$1"
	local first=true
	printf '[\n'
	while IFS=$'\037' read -r source status id title directory project_id parent_id parent_title created updated mismatch; do
		[[ -n "${id:-}" ]] || continue
		if [[ "$first" == true ]]; then
			first=false
		else
			printf ',\n'
		fi
		printf '  {"source":"%s","status":"%s","id":"%s","title":"%s","directory":"%s","project_id":"%s","parent_id":"%s","parent_title":"%s","created":"%s","updated":"%s","diagnostic":"%s"}' \
			"$(_json_escape "$source")" "$(_json_escape "$status")" "$(_json_escape "$id")" \
			"$(_json_escape "$title")" "$(_json_escape "$directory")" "$(_json_escape "$project_id")" \
			"$(_json_escape "$parent_id")" "$(_json_escape "$parent_title")" "$(_json_escape "$created")" \
			"$(_json_escape "$updated")" "$(_json_escape "$mismatch")"
	done <<<"$rows"
	printf '\n]\n'
	return 0
}

_sessions_print_table() {
	local rows="$1"
	printf '%-8s %-44s %-22s %-30s %-36s %s\n' "SOURCE" "STATUS" "ID" "TITLE" "PARENT" "DIRECTORY"
	printf '%-8s %-44s %-22s %-30s %-36s %s\n' "--------" "--------------------------------------------" "----------------------" "------------------------------" "------------------------------------" "---------"
	while IFS=$'\037' read -r source status id title directory project_id parent_id parent_title created updated mismatch; do
		[[ -n "${id:-}" ]] || continue
		local parent="-"
		if [[ -n "$parent_id" ]]; then
			parent="$parent_id"
			[[ -n "$parent_title" ]] && parent="${parent_id} (${parent_title})"
		fi
		[[ -n "$mismatch" ]] && status="${status}+${mismatch}"
		printf '%-8.8s %-44s %-22.22s %-30.30s %-36s %s\n' "$source" "$status" "$id" "$title" "$parent" "$directory"
	done <<<"$rows"
	printf '\nDiagnostic notes:\n'
	printf '  active-child: session has parent_id and may be hidden from top-level OpenCode session lists.\n'
	printf '  archived: row is in opencode-archive.db, which the OpenCode TUI/CLI does not read.\n'
	printf '  possible-project-id-mismatch: same directory has multiple project_id values.\n'
	return 0
}

cmd_sessions() {
	local query=""
	local exact_id=""
	local directory=""
	local include_archive=false
	local json=false
	local limit=20

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--query | -q)
			query="${2:-}"
			shift 2
			;;
		--id)
			exact_id="${2:-}"
			shift 2
			;;
		--directory | --dir)
			directory="${2:-}"
			shift 2
			;;
		--include-archive | --archive)
			include_archive=true
			shift
			;;
		--json)
			json=true
			shift
			;;
		--limit)
			limit="${2:-20}"
			shift 2
			;;
		--help | -h)
			printf 'Usage: opencode-db-maintenance-helper.sh sessions [--query TEXT|--id ID] [--directory PATH] [--include-archive] [--limit N] [--json]\n'
			return 0
			;;
		*)
			print_error "Unknown sessions option: $arg"
			return 1
			;;
		esac
	done

	if ! _sqlite_available; then
		print_error "${SQLITE3_BIN} CLI not available"
		return 1
	fi
	if ! [[ "$limit" =~ ^[0-9]+$ ]] || [[ "$limit" -lt 1 ]]; then
		print_error "--limit must be a positive integer"
		return 1
	fi
	if [[ -n "$exact_id" && -n "$query" ]]; then
		print_error "Use either --id or --query, not both"
		return 1
	fi
	if [[ ! -f "$OPENCODE_DB" && "$include_archive" != true ]]; then
		print_info "opencode DB not found at $OPENCODE_DB"
		return 0
	fi

	local rows=""
	if [[ -f "$OPENCODE_DB" ]]; then
		rows+="$(_sessions_query_db "$OPENCODE_DB" "active" "$query" "$exact_id" "$directory" "$limit")"
	fi
	if [[ "$include_archive" == true && -f "$OPENCODE_ARCHIVE_DB" ]]; then
		[[ -n "$rows" ]] && rows+=$'\n'
		rows+="$(_sessions_query_db "$OPENCODE_ARCHIVE_DB" "archive" "$query" "$exact_id" "$directory" "$limit")"
	elif [[ "$include_archive" == true && "$json" != true ]]; then
		print_warning "archive DB not found at $OPENCODE_ARCHIVE_DB; continuing with active DB only"
	fi

	if [[ "$json" == true ]]; then
		_sessions_print_json "$rows"
	elif [[ -z "$rows" ]]; then
		print_info "No matching OpenCode sessions found"
	else
		_sessions_print_table "$rows"
	fi
	return 0
}
