#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shared, read-only evidence probes for OpenCode SQLite maintenance and storage
# reporting. Callers own policy decisions; this library never mutates a DB.

OPENCODE_DB_STATE_UNKNOWN="${OPENCODE_DB_STATE_UNKNOWN:-unknown}"

opencode_db_file_signature() {
	local file_path="$1"
	local file_bytes=""
	local file_mtime=""

	if [[ ! -e "$file_path" && ! -L "$file_path" ]]; then
		printf '%s' "missing"
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
		printf '%s' "missing"
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

opencode_archive_table_schema_supported() {
	local db_path="$1"
	local table_name="$2"
	local actual=""
	local expected=""
	local compatible=""

	actual=$(opencode_db_table_columns "$db_path" "$table_name") || return 1
	case "$table_name" in
	project)
		expected="id,worktree,vcs,name,icon_url,icon_color,time_created,time_updated,time_initialized,sandboxes,commands"
		compatible="${expected},icon_url_override"
		;;
	session)
		expected="id,project_id,parent_id,slug,directory,title,version,share_url,summary_additions,summary_deletions,summary_files,summary_diffs,revert,permission,time_created,time_updated,time_compacting,time_archived,workspace_id"
		compatible="${expected},path"
		;;
	message) expected="id,session_id,time_created,time_updated,data" ;;
	part) expected="id,message_id,session_id,time_created,time_updated,data" ;;
	todo) expected="session_id,content,status,priority,position,time_created,time_updated" ;;
	session_share) expected="session_id,id,secret,url,time_created,time_updated" ;;
	event) expected="id,aggregate_id,seq,type,data" ;;
	*) return 1 ;;
	esac

	if [[ "$actual" == "$expected" || (-n "$compatible" && "$actual" == "$compatible") ]]; then
		return 0
	fi
	return 1
}

# Validate only the complete logical-session schema supported by the existing
# archive contract. event_mode is optional for active DBs and required for the
# aidevops-owned archive schema.
opencode_archive_schema_supported() {
	local db_path="$1"
	local event_mode="${2:-optional}"
	local table_name=""
	local event_exists=""
	local unknown_session_tables=""

	for table_name in project session message part todo session_share; do
		opencode_archive_table_schema_supported "$db_path" "$table_name" || return 1
	done
	event_exists=$(sqlite3 "$db_path" \
		"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='event';" 2>/dev/null || true)
	if [[ "$event_exists" == "1" ]]; then
		opencode_archive_table_schema_supported "$db_path" event || return 1
	elif [[ "$event_mode" == "required" ]]; then
		return 1
	fi

	unknown_session_tables=$(sqlite3 "$db_path" \
		"SELECT DISTINCT m.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type='table' AND p.name='session_id' AND m.name NOT IN ('message','part','todo','session_share') ORDER BY m.name;" 2>/dev/null) || return 1
	[[ -z "$unknown_session_tables" ]] || return 1
	return 0
}
