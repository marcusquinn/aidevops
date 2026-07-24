#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shared, read-only evidence probes for OpenCode SQLite maintenance and storage
# reporting. Callers own policy decisions; this library never mutates a DB.

OPENCODE_DB_STATE_UNKNOWN="${OPENCODE_DB_STATE_UNKNOWN:-unknown}"
OPENCODE_DB_STATE_MISSING="${OPENCODE_DB_STATE_MISSING:-missing}"
OPENCODE_ARCHIVE_SCHEMA_MODE_OPTIONAL="optional"
OPENCODE_ARCHIVE_SCHEMA_MODE_REQUIRED="required"

opencode_db_file_signature() {
	local file_path="$1"
	local file_bytes=""
	local file_mtime=""

	if [[ ! -e "$file_path" && ! -L "$file_path" ]]; then
		printf '%s' "$OPENCODE_DB_STATE_MISSING"
		return 0
	fi
	if [[ ! -f "$file_path" ]] || ! declare -F _file_size_bytes >/dev/null 2>&1 || ! declare -F _file_mtime_epoch >/dev/null 2>&1; then
		printf '%s' "$OPENCODE_DB_STATE_UNKNOWN"
		return 0
	fi

	file_bytes=$(_file_size_bytes "$file_path" 2>/dev/null || true)
	file_mtime=$(_file_mtime_epoch "$file_path" 2>/dev/null || true)
	if [[ ! "$file_bytes" =~ ^[0-9]+$ || ! "$file_mtime" =~ ^[0-9]+$ ]]; then
		printf '%s' "$OPENCODE_DB_STATE_UNKNOWN"
		return 0
	fi
	printf '%s:%s' "$file_bytes" "$file_mtime"
	return 0
}

# Emit stable, changing, or unknown for a WAL observed twice. The optional
# third argument supports isolated fixtures without changing the active DB path.
opencode_db_wal_state() {
	local db_path="$1"
	local sample_delay="${2:-1}"
	local wal_path="${3:-${db_path}-wal}"
	local before=""
	local after=""

	if [[ ! "$sample_delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		printf '%s' "$OPENCODE_DB_STATE_UNKNOWN"
		return 0
	fi
	before=$(opencode_db_file_signature "$wal_path")
	if [[ "$before" == "$OPENCODE_DB_STATE_UNKNOWN" ]]; then
		printf '%s' "$OPENCODE_DB_STATE_UNKNOWN"
		return 0
	fi
	sleep "$sample_delay"
	after=$(opencode_db_file_signature "$wal_path")
	if [[ "$after" == "$OPENCODE_DB_STATE_UNKNOWN" ]]; then
		printf '%s' "$OPENCODE_DB_STATE_UNKNOWN"
	elif [[ "$before" != "$after" ]]; then
		printf '%s' "changing"
	else
		printf '%s' "stable"
	fi
	return 0
}

# Emit a holder count, or unknown when lsof-compatible evidence is unavailable.
opencode_db_holder_count() {
	local db_path="$1"
	local holder_command="${2:-lsof}"
	local holder_pids=""
	local holder_count="0"

	if ! command -v "$holder_command" >/dev/null 2>&1; then
		printf '%s' "$OPENCODE_DB_STATE_UNKNOWN"
		return 0
	fi
	holder_pids=$("$holder_command" -t "$db_path" 2>/dev/null || true)
	if [[ -n "$holder_pids" ]]; then
		holder_count=$(printf '%s\n' "$holder_pids" | awk 'NF' | sort -u | wc -l | tr -d ' ')
	fi
	printf '%s' "${holder_count:-0}"
	return 0
}

# Emit readable, missing, or unknown without selecting session content.
opencode_db_schema_state() {
	local db_path="$1"
	local table_count=""

	if [[ ! -e "$db_path" && ! -L "$db_path" ]]; then
		printf '%s' "$OPENCODE_DB_STATE_MISSING"
		return 0
	fi
	if [[ ! -f "$db_path" || ! -r "$db_path" ]] || ! command -v sqlite3 >/dev/null 2>&1; then
		printf '%s' "$OPENCODE_DB_STATE_UNKNOWN"
		return 0
	fi
	table_count=$(sqlite3 -readonly "$db_path" \
		"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('project','session','message','part');" 2>/dev/null || true)
	if [[ "$table_count" == "4" ]]; then
		printf '%s' "readable"
	else
		printf '%s' "$OPENCODE_DB_STATE_UNKNOWN"
	fi
	return 0
}

opencode_db_table_columns() {
	local db_path="$1"
	local table_name="$2"
	sqlite3 "$db_path" "SELECT COALESCE(group_concat(name, ','), '') FROM (SELECT name FROM pragma_table_info('${table_name}') ORDER BY cid);" 2>/dev/null
	return $?
}

opencode_db_table_exists() {
	local db_path="$1"
	local table_name="$2"
	local table_count=""

	table_count=$(sqlite3 "$db_path" \
		"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${table_name}';" 2>/dev/null) || return 1
	[[ "$table_count" == "1" ]]
	return $?
}

OPENCODE_ARCHIVE_SCHEMA_ERROR_TABLE=""
OPENCODE_ARCHIVE_SCHEMA_ERROR_ACTUAL=""
OPENCODE_ARCHIVE_SCHEMA_ERROR_SUPPORTED=""
OPENCODE_ARCHIVE_SCHEMA_ERROR_REASON=""

_opencode_archive_schema_set_error() {
	local table_name="$1"
	local actual_columns="$2"
	local supported_columns="$3"
	local reason="$4"

	OPENCODE_ARCHIVE_SCHEMA_ERROR_TABLE="$table_name"
	OPENCODE_ARCHIVE_SCHEMA_ERROR_ACTUAL="$actual_columns"
	OPENCODE_ARCHIVE_SCHEMA_ERROR_SUPPORTED="$supported_columns"
	OPENCODE_ARCHIVE_SCHEMA_ERROR_REASON="$reason"
	return 0
}

opencode_archive_schema_diagnostic() {
	printf 'table=%s actual_columns=[%s] supported_columns=[%s] reason=%s' \
		"${OPENCODE_ARCHIVE_SCHEMA_ERROR_TABLE:-unknown}" \
		"${OPENCODE_ARCHIVE_SCHEMA_ERROR_ACTUAL:-unavailable}" \
		"${OPENCODE_ARCHIVE_SCHEMA_ERROR_SUPPORTED:-unavailable}" \
		"${OPENCODE_ARCHIVE_SCHEMA_ERROR_REASON:-unavailable}"
	return 0
}

_opencode_archive_columns_match() {
	local actual_columns="$1"
	local supported_columns="$2"

	[[ -n "$actual_columns" && "|${supported_columns}|" == *"|${actual_columns}|"* ]]
	return $?
}

opencode_archive_table_schema_supported() {
	local db_path="$1"
	local table_name="$2"
	local schema_mode="${3:-$OPENCODE_ARCHIVE_SCHEMA_MODE_OPTIONAL}"
	local actual=""
	local supported=""
	local legacy=""
	local compatible=""
	local current=""

	case "$table_name" in
	project)
		legacy="id,worktree,vcs,name,icon_url,icon_color,time_created,time_updated,time_initialized,sandboxes,commands"
		current="${legacy},icon_url_override"
		if [[ "$schema_mode" == "$OPENCODE_ARCHIVE_SCHEMA_MODE_REQUIRED" ]]; then
			supported="$current"
		else
			supported="${legacy}|${current}"
		fi
		;;
	session)
		legacy="id,project_id,parent_id,slug,directory,title,version,share_url,summary_additions,summary_deletions,summary_files,summary_diffs,revert,permission,time_created,time_updated,time_compacting,time_archived,workspace_id"
		compatible="${legacy},path"
		current="${compatible},agent,model,cost,tokens_input,tokens_output,tokens_reasoning,tokens_cache_read,tokens_cache_write,metadata"
		if [[ "$schema_mode" == "$OPENCODE_ARCHIVE_SCHEMA_MODE_REQUIRED" ]]; then
			supported="$current"
		else
			supported="${legacy}|${compatible}|${current}"
		fi
		;;
	message) supported="id,session_id,time_created,time_updated,data" ;;
	part) supported="id,message_id,session_id,time_created,time_updated,data" ;;
	todo) supported="session_id,content,status,priority,position,time_created,time_updated" ;;
	session_share) supported="session_id,id,secret,url,time_created,time_updated" ;;
	session_message) supported="id,session_id,type,time_created,time_updated,data,seq" ;;
	session_input) supported="id,session_id,prompt,delivery,admitted_seq,promoted_seq,time_created" ;;
	session_context_epoch) supported="session_id,baseline,snapshot,baseline_seq" ;;
	event_sequence) supported="aggregate_id,seq,owner_id" ;;
	event) supported="id,aggregate_id,seq,type,data" ;;
	*)
		_opencode_archive_schema_set_error "$table_name" "unavailable" "no-supported-schema" "unknown-table"
		return 1
		;;
	esac

	if ! actual=$(opencode_db_table_columns "$db_path" "$table_name"); then
		_opencode_archive_schema_set_error "$table_name" "unavailable" "$supported" "column-query-failed"
		return 1
	fi
	if _opencode_archive_columns_match "$actual" "$supported"; then
		return 0
	fi
	[[ -n "$actual" ]] || actual="$OPENCODE_DB_STATE_MISSING"
	_opencode_archive_schema_set_error "$table_name" "$actual" "$supported" "column-mismatch"
	return 1
}

# Validate only complete logical-session schemas supported by the archive
# contract. Optional mode accepts known active-DB generations; required mode
# enforces the current aidevops-owned archive schema.
opencode_archive_schema_supported() {
	local db_path="$1"
	local schema_mode="${2:-$OPENCODE_ARCHIVE_SCHEMA_MODE_OPTIONAL}"
	local table_name=""
	local session_columns=""
	local current_session_columns="id,project_id,parent_id,slug,directory,title,version,share_url,summary_additions,summary_deletions,summary_files,summary_diffs,revert,permission,time_created,time_updated,time_compacting,time_archived,workspace_id,path,agent,model,cost,tokens_input,tokens_output,tokens_reasoning,tokens_cache_read,tokens_cache_write,metadata"
	local unknown_session_tables=""
	local unknown_aggregate_tables=""
	local unknown_columns=""

	OPENCODE_ARCHIVE_SCHEMA_ERROR_TABLE=""
	OPENCODE_ARCHIVE_SCHEMA_ERROR_ACTUAL=""
	OPENCODE_ARCHIVE_SCHEMA_ERROR_SUPPORTED=""
	OPENCODE_ARCHIVE_SCHEMA_ERROR_REASON=""
	if [[ "$schema_mode" != "$OPENCODE_ARCHIVE_SCHEMA_MODE_OPTIONAL" && "$schema_mode" != "$OPENCODE_ARCHIVE_SCHEMA_MODE_REQUIRED" ]]; then
		_opencode_archive_schema_set_error "schema" "$schema_mode" "optional|required" "invalid-validation-mode"
		return 1
	fi

	for table_name in project session message part todo session_share; do
		opencode_archive_table_schema_supported "$db_path" "$table_name" "$schema_mode" || return 1
	done

	session_columns=$(opencode_db_table_columns "$db_path" session) || return 1
	if [[ "$schema_mode" == "$OPENCODE_ARCHIVE_SCHEMA_MODE_REQUIRED" || "$session_columns" == "$current_session_columns" ]]; then
		for table_name in session_message session_input session_context_epoch event_sequence event; do
			opencode_archive_table_schema_supported "$db_path" "$table_name" "$OPENCODE_ARCHIVE_SCHEMA_MODE_REQUIRED" || return 1
		done
	else
		for table_name in session_message session_input session_context_epoch event_sequence event; do
			if opencode_db_table_exists "$db_path" "$table_name"; then
				opencode_archive_table_schema_supported "$db_path" "$table_name" optional || return 1
			fi
		done
	fi

	unknown_session_tables=$(sqlite3 "$db_path" \
		"SELECT DISTINCT m.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type='table' AND p.name='session_id' AND m.name NOT IN ('message','part','todo','session_share','session_message','session_input','session_context_epoch') ORDER BY m.name LIMIT 1;" 2>/dev/null) || return 1
	if [[ -n "$unknown_session_tables" ]]; then
		unknown_columns=$(opencode_db_table_columns "$db_path" "$unknown_session_tables" 2>/dev/null || printf 'unavailable')
		_opencode_archive_schema_set_error "$unknown_session_tables" "$unknown_columns" "no-additional-session-id-table" "unknown-session-table"
		return 1
	fi

	unknown_aggregate_tables=$(sqlite3 "$db_path" \
		"SELECT DISTINCT m.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type='table' AND p.name='aggregate_id' AND m.name NOT IN ('event','event_sequence') ORDER BY m.name LIMIT 1;" 2>/dev/null) || return 1
	if [[ -n "$unknown_aggregate_tables" ]]; then
		unknown_columns=$(opencode_db_table_columns "$db_path" "$unknown_aggregate_tables" 2>/dev/null || printf 'unavailable')
		_opencode_archive_schema_set_error "$unknown_aggregate_tables" "$unknown_columns" "no-additional-aggregate-id-table" "unknown-aggregate-table"
		return 1
	fi
	return 0
}
