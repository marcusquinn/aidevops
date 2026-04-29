#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Mail Helper -- Management Sub-Library
# =============================================================================
# Prune, status, agent registry, and migration operations for the inter-agent
# mailbox system.
#
# Usage: source "${SCRIPT_DIR}/mail-helper-management.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success, CYAN, NC,
#     backup_sqlite_db, cleanup_sqlite_backups)
#   - mail-helper.sh core functions (db, ensure_db, sql_escape, get_agent_id)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MAIL_HELPER_MANAGEMENT_LIB_LOADED:-}" ]] && return 0
_MAIL_HELPER_MANAGEMENT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Parse arguments for cmd_prune
# Outputs: older_than_days and force values to stdout as key=value lines
# Returns: 0 on success, 1 on parse error
#######################################
parse_prune_args() {
	local older_than_days="$DEFAULT_PRUNE_DAYS"
	local force=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--older-than-days)
			[[ $# -lt 2 ]] && {
				log_error "--older-than-days requires a value"
				return 1
			}
			older_than_days="$2"
			shift 2
			;;
		--force)
			force=true
			shift
			;;
		# Keep --dry-run as alias for default behavior (backward compat)
		--dry-run) shift ;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if ! [[ "$older_than_days" =~ ^[0-9]+$ ]]; then
		log_error "Invalid value for --older-than-days: must be a positive integer"
		return 1
	fi

	printf 'older_than_days=%s\nforce=%s\n' "$older_than_days" "$force"
	return 0
}

#######################################
# Print the mailbox storage report
# Arguments: older_than_days, db_size_kb (pre-computed)
# Returns: prunable count via stdout last line "prunable=N archivable=N"
#######################################
prune_storage_report() {
	local older_than_days="$1"
	local db_size_kb="$2"

	local total_messages unread_messages read_messages archived_messages
	IFS='|' read -r total_messages unread_messages read_messages archived_messages < <(db -separator '|' "$MAIL_DB" "
        SELECT count(*),
            coalesce(sum(CASE WHEN status = 'unread' THEN 1 ELSE 0 END), 0),
            coalesce(sum(CASE WHEN status = 'read' THEN 1 ELSE 0 END), 0),
            coalesce(sum(CASE WHEN status = 'archived' THEN 1 ELSE 0 END), 0)
        FROM messages;
    ")

	local prunable archivable
	IFS='|' read -r prunable archivable < <(db -separator '|' "$MAIL_DB" "
        SELECT
            coalesce(sum(CASE WHEN status = 'archived' AND archived_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days') THEN 1 ELSE 0 END), 0),
            coalesce(sum(CASE WHEN status = 'read' AND read_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days') THEN 1 ELSE 0 END), 0)
        FROM messages;
    ")

	local oldest_msg newest_msg
	IFS='|' read -r oldest_msg newest_msg < <(db -separator '|' "$MAIL_DB" "
        SELECT coalesce(min(created_at), 'none'), coalesce(max(created_at), 'none') FROM messages;
    ")

	local type_breakdown
	type_breakdown=$(db -separator ': ' "$MAIL_DB" "
        SELECT type, count(*) FROM messages GROUP BY type ORDER BY count(*) DESC;
    ")

	echo "Mailbox Storage Report"
	echo "======================"
	echo ""
	echo "  Database:    ${db_size_kb}KB ($MAIL_DB)"
	echo "  Messages:    $total_messages total"
	echo "    Unread:    $unread_messages"
	echo "    Read:      $read_messages"
	echo "    Archived:  $archived_messages"
	echo "  Date range:  $oldest_msg → $newest_msg"
	echo ""
	echo "  By type:"
	if [[ -n "$type_breakdown" ]]; then
		echo "$type_breakdown" | while IFS= read -r line; do
			echo "    $line"
		done
	else
		echo "    (none)"
	fi
	echo ""
	echo "  Prunable (archived >${older_than_days}d): $prunable messages"
	echo "  Archivable (read >${older_than_days}d):   $archivable messages"

	# Return counts for caller decision
	printf 'prunable=%s archivable=%s\n' "$prunable" "$archivable"
	return 0
}

#######################################
# Execute the prune deletion (--force path)
# Arguments: older_than_days, db_size_kb (pre-computed, for savings report)
# Returns: 0
#######################################
prune_execute() {
	local older_than_days="$1"
	local db_size_kb="$2"

	log_info "Pruning with --force (${older_than_days}-day threshold)..."

	# Backup before bulk delete (t188)
	local prune_backup
	prune_backup=$(backup_sqlite_db "$MAIL_DB" "pre-prune")
	if [[ $? -ne 0 || -z "$prune_backup" ]]; then
		log_warn "Backup failed before prune — proceeding cautiously"
	fi

	# Capture discoveries and status reports to memory before pruning
	local remembered=0
	if [[ -x "$MEMORY_HELPER" ]]; then
		local notable_messages
		notable_messages=$(db -separator '|' "$MAIL_DB" "
            SELECT type, payload FROM messages
            WHERE status = 'archived'
            AND archived_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days')
            AND type IN ('discovery', 'status_report');
        ")

		if [[ -n "$notable_messages" ]]; then
			while IFS='|' read -r msg_type payload; do
				if [[ -n "$payload" ]]; then
					"$MEMORY_HELPER" store \
						--content "Mailbox ($msg_type): $payload" \
						--type CONTEXT \
						--tags "mailbox,${msg_type},archived" 2>/dev/null && remembered=$((remembered + 1))
				fi
			done <<<"$notable_messages"
		fi
	fi

	# Archive old read messages first
	local auto_archived
	auto_archived=$(db "$MAIL_DB" "
        UPDATE messages SET status = 'archived', archived_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE status = 'read'
        AND read_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days');
        SELECT changes();
    ")

	# Delete old archived messages
	local pruned
	pruned=$(db "$MAIL_DB" "
        DELETE FROM messages
        WHERE status = 'archived'
        AND archived_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days');
        SELECT changes();
    ")

	# Vacuum to reclaim space
	db "$MAIL_DB" "VACUUM;"

	local new_size_bytes
	new_size_bytes=$(_file_size_bytes "$MAIL_DB")
	local new_size_kb=$((new_size_bytes / 1024))
	local saved_kb=$((db_size_kb - new_size_kb))

	log_success "Pruned $pruned messages, archived $auto_archived read messages ($remembered captured to memory)"
	log_info "Storage: ${db_size_kb}KB → ${new_size_kb}KB (saved ${saved_kb}KB)"

	# Clean up old backups (t188)
	cleanup_sqlite_backups "$MAIL_DB" 5
	return 0
}

#######################################
# Prune: manual deletion with storage report
# By default shows storage report. Use --force to actually delete.
#######################################
cmd_prune() {
	local older_than_days="$DEFAULT_PRUNE_DAYS"
	local force=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--older-than-days)
			[[ $# -lt 2 ]] && {
				log_error "--older-than-days requires a value"
				return 1
			}
			older_than_days="$2"
			shift 2
			;;
		--force)
			force=true
			shift
			;;
		--dry-run) shift ;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if ! [[ "$older_than_days" =~ ^[0-9]+$ ]]; then
		log_error "Invalid value for --older-than-days: must be a positive integer"
		return 1
	fi

	ensure_db

	local db_size_bytes
	db_size_bytes=$(_file_size_bytes "$MAIL_DB")
	local db_size_kb=$((db_size_bytes / 1024))

	local report_output prunable archivable
	report_output=$(prune_storage_report "$older_than_days" "$db_size_kb")
	# Last line of report is "prunable=N archivable=N"
	local counts_line
	counts_line=$(printf '%s\n' "$report_output" | tail -1)
	prunable="${counts_line#prunable=}"
	prunable="${prunable% archivable=*}"
	archivable="${counts_line##* archivable=}"
	# Print the report (all lines except the last counts line)
	printf '%s\n' "$report_output" | sed '$d'

	if [[ "$force" != true ]]; then
		if [[ "$prunable" -gt 0 || "$archivable" -gt 0 ]]; then
			echo ""
			echo "  To delete prunable messages:  mail-helper.sh prune --force"
			echo "  To change threshold:          mail-helper.sh prune --older-than-days 30 --force"
		else
			echo ""
			echo "  Nothing to prune. All messages are within the ${older_than_days}-day window."
		fi
		return 0
	fi

	prune_execute "$older_than_days" "$db_size_kb"
	return 0
}

#######################################
# Show mailbox status
#######################################
cmd_status() {
	local agent_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--agent)
			[[ $# -lt 2 ]] && {
				log_error "--agent requires a value"
				return 1
			}
			agent_id="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	if [[ -n "$agent_id" ]]; then
		local escaped_id
		escaped_id=$(sql_escape "$agent_id")
		local inbox_count unread_count
		IFS='|' read -r inbox_count unread_count < <(db -separator '|' "$MAIL_DB" "
            SELECT
                COALESCE(SUM(CASE WHEN status != 'archived' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN status = 'unread' THEN 1 ELSE 0 END), 0)
            FROM messages WHERE to_agent='$escaped_id';
        ")
		echo "Agent: $agent_id"
		echo "  Inbox: $inbox_count messages ($unread_count unread)"
	else
		local total_unread total_read total_archived total_agents
		IFS='|' read -r total_unread total_read total_archived < <(db -separator '|' "$MAIL_DB" "
            SELECT
                COALESCE(SUM(CASE WHEN status = 'unread' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN status = 'read' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN status = 'archived' THEN 1 ELSE 0 END), 0)
            FROM messages;
        ")
		total_agents=$(db "$MAIL_DB" "SELECT count(*) FROM agents WHERE status = 'active';")

		local total_inbox=$((total_unread + total_read))

		echo "<!--TOON:mail_status{inbox,outbox,archive,agents}:"
		echo "${total_inbox},0,${total_archived},${total_agents}"
		echo "-->"
		echo ""
		echo "Mailbox Status:"
		echo "  Active:   $total_inbox messages ($total_unread unread, $total_read read)"
		echo "  Archived: $total_archived messages"
		echo "  Agents:   $total_agents active"

		local agent_list
		agent_list=$(db -separator ',' "$MAIL_DB" "
            SELECT id, role, branch, status, registered, last_seen FROM agents ORDER BY last_seen DESC;
        ")
		if [[ -n "$agent_list" ]]; then
			echo ""
			echo "Registered Agents:"
			echo "<!--TOON:agents{id,role,branch,status,registered,last_seen}:"
			echo "$agent_list"
			echo "-->"
		fi
	fi
}

#######################################
# Register an agent
#######################################
cmd_register() {
	local agent_id="" role="" branch="" worktree=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--agent)
			[[ $# -lt 2 ]] && {
				log_error "--agent requires a value"
				return 1
			}
			agent_id="$2"
			shift 2
			;;
		--role)
			[[ $# -lt 2 ]] && {
				log_error "--role requires a value"
				return 1
			}
			role="$2"
			shift 2
			;;
		--branch)
			[[ $# -lt 2 ]] && {
				log_error "--branch requires a value"
				return 1
			}
			branch="$2"
			shift 2
			;;
		--worktree)
			[[ $# -lt 2 ]] && {
				log_error "--worktree requires a value"
				return 1
			}
			worktree="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$agent_id" ]]; then
		agent_id=$(get_agent_id)
	fi
	if [[ -z "$role" ]]; then
		role="worker"
	fi
	if [[ -z "$branch" ]]; then
		branch=$(git branch --show-current 2>/dev/null || echo "unknown")
	fi
	if [[ -z "$worktree" ]]; then
		worktree=$(pwd)
	fi

	ensure_db

	db "$MAIL_DB" "
        INSERT INTO agents (id, role, branch, worktree, status)
        VALUES ('$(sql_escape "$agent_id")', '$(sql_escape "$role")', '$(sql_escape "$branch")', '$(sql_escape "$worktree")', 'active')
        ON CONFLICT(id) DO UPDATE SET
            role = excluded.role,
            branch = excluded.branch,
            worktree = excluded.worktree,
            status = 'active',
            last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now');
    "

	log_success "Registered agent: $agent_id (role: $role, branch: $branch)"
}

#######################################
# Deregister an agent
#######################################
cmd_deregister() {
	local agent_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--agent)
			[[ $# -lt 2 ]] && {
				log_error "--agent requires a value"
				return 1
			}
			agent_id="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$agent_id" ]]; then
		agent_id=$(get_agent_id)
	fi

	ensure_db

	db "$MAIL_DB" "
        UPDATE agents SET status = 'inactive', last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$(sql_escape "$agent_id")';
    "

	log_success "Deregistered agent: $agent_id (marked inactive)"
}

#######################################
# List registered agents
#######################################
cmd_agents() {
	local active_only=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--active-only)
			active_only=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	if [[ "$active_only" == true ]]; then
		echo "Active Agents:"
		db -separator ',' "$MAIL_DB" "
            SELECT id, role, branch, last_seen FROM agents WHERE status = 'active' ORDER BY last_seen DESC;
        " | while IFS=',' read -r id role branch last_seen; do
			echo -e "  ${CYAN}$id${NC} ($role) on $branch - last seen: $last_seen"
		done
	else
		echo "<!--TOON:agents{id,role,branch,worktree,status,registered,last_seen}:"
		db -separator ',' "$MAIL_DB" "
            SELECT id, role, branch, worktree, status, registered, last_seen FROM agents ORDER BY last_seen DESC;
        "
		echo "-->"
	fi
}

#######################################
# Migrate TOON files to SQLite
#######################################
cmd_migrate() {
	ensure_db

	local migrated=0
	local inbox_dir="$MAIL_DIR/inbox"
	local outbox_dir="$MAIL_DIR/outbox"
	local archive_dir="$MAIL_DIR/archive"

	# Migrate inbox + outbox messages
	if [[ -d "$inbox_dir" || -d "$outbox_dir" ]]; then
		while IFS= read -r msg_file; do
			[[ -f "$msg_file" ]] || continue
			local header
			header=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1) || continue
			[[ -z "$header" ]] && continue

			local id from_agent to_agent msg_type priority convoy timestamp status
			IFS=',' read -r id from_agent to_agent msg_type priority convoy timestamp status <<<"$header"
			local payload
			payload=$(sed -n '/^-->$/,$ { /^-->$/d; p; }' "$msg_file" | sed '/^$/d')

			local escaped_payload
			escaped_payload=$(sql_escape "$payload")

			db "$MAIL_DB" "
                INSERT OR IGNORE INTO messages (id, from_agent, to_agent, type, priority, convoy, payload, status, created_at)
                VALUES ('$(sql_escape "$id")', '$(sql_escape "$from_agent")', '$(sql_escape "$to_agent")', '$(sql_escape "$msg_type")', '$(sql_escape "$priority")', '$(sql_escape "$convoy")', '$escaped_payload', '$(sql_escape "$status")', '$(sql_escape "$timestamp")');
            " 2>/dev/null && migrated=$((migrated + 1))
		done < <(find "$inbox_dir" "$outbox_dir" -name "*.toon" 2>/dev/null)
	fi

	# Migrate archived messages
	if [[ -d "$archive_dir" ]]; then
		while IFS= read -r msg_file; do
			[[ -f "$msg_file" ]] || continue
			local header
			header=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1) || continue
			[[ -z "$header" ]] && continue

			local id from_agent to_agent msg_type priority convoy timestamp status
			IFS=',' read -r id from_agent to_agent msg_type priority convoy timestamp status <<<"$header"
			local payload
			payload=$(sed -n '/^-->$/,$ { /^-->$/d; p; }' "$msg_file" | sed '/^$/d')

			local escaped_payload
			escaped_payload=$(sql_escape "$payload")

			db "$MAIL_DB" "
                INSERT OR IGNORE INTO messages (id, from_agent, to_agent, type, priority, convoy, payload, status, created_at, archived_at)
                VALUES ('$(sql_escape "$id")', '$(sql_escape "$from_agent")', '$(sql_escape "$to_agent")', '$(sql_escape "$msg_type")', '$(sql_escape "$priority")', '$(sql_escape "$convoy")', '$escaped_payload', 'archived', '$(sql_escape "$timestamp")', strftime('%Y-%m-%dT%H:%M:%SZ','now'));
            " 2>/dev/null && migrated=$((migrated + 1))
		done < <(find "$archive_dir" -name "*.toon" 2>/dev/null)
	fi

	# Migrate registry
	local registry_file="$MAIL_DIR/registry.toon"
	local agents_migrated=0
	if [[ -f "$registry_file" ]]; then
		while IFS=',' read -r id role branch worktree status registered last_seen; do
			[[ "$id" == "<!--"* || "$id" == "-->"* || -z "$id" ]] && continue
			db "$MAIL_DB" "
                INSERT OR IGNORE INTO agents (id, role, branch, worktree, status, registered, last_seen)
                VALUES ('$(sql_escape "$id")', '$(sql_escape "$role")', '$(sql_escape "$branch")', '$(sql_escape "$worktree")', '$(sql_escape "$status")', '$(sql_escape "$registered")', '$(sql_escape "$last_seen")');
            " 2>/dev/null && agents_migrated=$((agents_migrated + 1))
		done <"$registry_file"
	fi

	log_success "Migration complete: $migrated messages, $agents_migrated agents"

	# Rename old directories as backup (don't delete)
	if [[ $migrated -gt 0 || $agents_migrated -gt 0 ]]; then
		local backup_suffix
		backup_suffix=$(date +%Y%m%d-%H%M%S)
		for dir in "$inbox_dir" "$outbox_dir" "$archive_dir"; do
			if [[ -d "$dir" ]] && find "$dir" -name "*.toon" 2>/dev/null | grep -q .; then
				mv "$dir" "${dir}.pre-sqlite-${backup_suffix}"
				mkdir -p "$dir"
				log_info "Backed up: $dir → ${dir}.pre-sqlite-${backup_suffix}"
			fi
		done
		if [[ -f "$registry_file" ]]; then
			mv "$registry_file" "${registry_file}.pre-sqlite-${backup_suffix}"
			log_info "Backed up: $registry_file"
		fi
	fi
}
