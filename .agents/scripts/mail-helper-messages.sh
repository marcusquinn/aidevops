#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Mail Helper -- Message Operations Sub-Library
# =============================================================================
# Message send, check, read, and archive operations for the inter-agent
# mailbox system.
#
# Usage: source "${SCRIPT_DIR}/mail-helper-messages.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - mail-helper.sh core functions (db, ensure_db, sql_escape, get_agent_id,
#     generate_id)
#   - mail-helper-transport.sh (transport_relay)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MAIL_HELPER_MESSAGES_LIB_LOADED:-}" ]] && return 0
_MAIL_HELPER_MESSAGES_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Validate required send fields and allowed values
# Arguments: to, msg_type, payload, priority
# Returns: 0 if valid, 1 if invalid
#######################################
validate_send_args() {
	local to="$1"
	local msg_type="$2"
	local payload="$3"
	local priority="$4"

	if [[ -z "$to" ]]; then
		log_error "Missing --to <agent-id>"
		return 1
	fi
	if [[ -z "$msg_type" ]]; then
		log_error "Missing --type <message-type>"
		return 1
	fi
	if [[ -z "$payload" ]]; then
		log_error "Missing --payload <message>"
		return 1
	fi

	local valid_types="task_dispatch status_report discovery request broadcast"
	if ! echo "$valid_types" | grep -qw "$msg_type"; then
		log_error "Invalid type: $msg_type (valid: $valid_types)"
		return 1
	fi

	if ! echo "high normal low" | grep -qw "$priority"; then
		log_error "Invalid priority: $priority (valid: high, normal, low)"
		return 1
	fi

	return 0
}

#######################################
# Insert a broadcast message (one row per active agent, or fallback to 'all')
# Arguments: msg_id, from, msg_type, priority, escaped_convoy, escaped_payload
# Returns: 0
#######################################
send_broadcast() {
	local msg_id="$1"
	local from="$2"
	local msg_type="$3"
	local priority="$4"
	local escaped_convoy="$5"
	local escaped_payload="$6"

	local count
	count=$(db "$MAIL_DB" "
        SELECT count(*) FROM agents WHERE status='active' AND id != '$(sql_escape "$from")';
    ")

	local agents_list
	agents_list=$(db "$MAIL_DB" "
        SELECT id FROM agents WHERE status='active' AND id != '$(sql_escape "$from")';
    ")

	if [[ -n "$agents_list" ]]; then
		while IFS= read -r agent_id; do
			local broadcast_id
			broadcast_id=$(generate_id)
			db "$MAIL_DB" "
                INSERT INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
                VALUES ('$broadcast_id', '$(sql_escape "$from")', '$(sql_escape "$agent_id")', '$msg_type', '$priority', '$escaped_convoy', '$escaped_payload');
            "
		done <<<"$agents_list"
		log_success "Broadcast sent: $msg_id (to $count agents)"
	else
		db "$MAIL_DB" "
            INSERT INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
            VALUES ('$msg_id', '$(sql_escape "$from")', 'all', '$msg_type', '$priority', '$escaped_convoy', '$escaped_payload');
        "
		log_success "Sent: $msg_id → all (no agents registered)"
	fi

	return 0
}

#######################################
# Insert a direct (unicast) message
# Arguments: msg_id, from, to, msg_type, priority, escaped_convoy, escaped_payload
# Returns: 0
#######################################
send_direct() {
	local msg_id="$1"
	local from="$2"
	local to="$3"
	local msg_type="$4"
	local priority="$5"
	local escaped_convoy="$6"
	local escaped_payload="$7"

	db "$MAIL_DB" "
        INSERT INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
        VALUES ('$msg_id', '$(sql_escape "$from")', '$(sql_escape "$to")', '$msg_type', '$priority', '$escaped_convoy', '$escaped_payload');
    "
	log_success "Sent: $msg_id → $to (priority: $priority)"
	return 0
}

#######################################
# Send a message
#######################################
cmd_send() {
	local to="" msg_type="" payload="" priority="normal" convoy="none"
	local transport="$MAIL_TRANSPORT"
	local from
	from=$(get_agent_id)

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			[[ $# -lt 2 ]] && {
				log_error "--to requires a value"
				return 1
			}
			to="$2"
			shift 2
			;;
		--type)
			[[ $# -lt 2 ]] && {
				log_error "--type requires a value"
				return 1
			}
			msg_type="$2"
			shift 2
			;;
		--payload)
			[[ $# -lt 2 ]] && {
				log_error "--payload requires a value"
				return 1
			}
			payload="$2"
			shift 2
			;;
		--priority)
			[[ $# -lt 2 ]] && {
				log_error "--priority requires a value"
				return 1
			}
			priority="$2"
			shift 2
			;;
		--convoy)
			[[ $# -lt 2 ]] && {
				log_error "--convoy requires a value"
				return 1
			}
			convoy="$2"
			shift 2
			;;
		--from)
			[[ $# -lt 2 ]] && {
				log_error "--from requires a value"
				return 1
			}
			from="$2"
			shift 2
			;;
		--transport)
			[[ $# -lt 2 ]] && {
				log_error "--transport requires a value"
				return 1
			}
			transport="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	validate_send_args "$to" "$msg_type" "$payload" "$priority" || return 1

	ensure_db

	local msg_id
	msg_id=$(generate_id)
	local escaped_payload
	escaped_payload=$(sql_escape "$payload")
	local escaped_convoy
	escaped_convoy=$(sql_escape "$convoy")

	if [[ "$to" == "all" || "$msg_type" == "broadcast" ]]; then
		send_broadcast "$msg_id" "$from" "$msg_type" "$priority" "$escaped_convoy" "$escaped_payload"
	else
		send_direct "$msg_id" "$from" "$to" "$msg_type" "$priority" "$escaped_convoy" "$escaped_payload"
	fi

	# Relay via configured transport adapter (non-fatal on failure)
	transport_relay "$msg_id" "$from" "$to" "$msg_type" "$priority" "$convoy" "$payload" "$transport"

	echo "$msg_id"
	return 0
}

#######################################
# Check inbox for messages
#######################################
cmd_check() {
	local agent_id="" unread_only=false

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
		--unread-only)
			unread_only=true
			shift
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

	local escaped_id
	escaped_id=$(sql_escape "$agent_id")
	local where_clause="to_agent = '${escaped_id}' AND status != 'archived'"
	if [[ "$unread_only" == true ]]; then
		where_clause="to_agent = '${escaped_id}' AND status = 'unread'"
	fi

	local results
	results=$(db -separator ',' "$MAIL_DB" "
        SELECT id, from_agent, type, priority, convoy, created_at, status
        FROM messages
        WHERE $where_clause
        ORDER BY
            CASE priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 WHEN 'low' THEN 2 END,
            created_at DESC;
    ")

	local total unread
	total=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent = '$(sql_escape "$agent_id")' AND status != 'archived';")
	unread=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent = '$(sql_escape "$agent_id")' AND status = 'unread';")

	echo "<!--TOON:inbox{id,from,type,priority,convoy,timestamp,status}:"
	if [[ -n "$results" ]]; then
		echo "$results"
	fi
	echo "-->"
	echo ""
	echo "Total: $total messages ($unread unread) for $agent_id"
}

#######################################
# Read a specific message (marks as read)
#######################################
cmd_read_msg() {
	local msg_id="" agent_id=""

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
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			msg_id="$1"
			shift
			;;
		esac
	done

	if [[ -z "$msg_id" ]]; then
		log_error "Usage: mail-helper.sh read <message-id> [--agent <id>]"
		return 1
	fi

	ensure_db

	local row
	row=$(db -separator '|' "$MAIL_DB" "
        SELECT id, from_agent, to_agent, type, priority, convoy, created_at, status, payload
        FROM messages WHERE id = '$(sql_escape "$msg_id")';
    ")

	if [[ -z "$row" ]]; then
		log_error "Message not found: $msg_id"
		return 1
	fi

	# Mark as read
	db "$MAIL_DB" "
        UPDATE messages SET status = 'read', read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$(sql_escape "$msg_id")' AND status = 'unread';
    "

	# Output in TOON format for backward compatibility
	local id from_agent to_agent msg_type priority convoy created_at payload
	IFS='|' read -r id from_agent to_agent msg_type priority convoy created_at _ payload <<<"$row"
	echo "<!--TOON:message{id,from,to,type,priority,convoy,timestamp,status}:"
	echo "${id},${from_agent},${to_agent},${msg_type},${priority},${convoy},${created_at},read"
	echo "-->"
	echo ""
	echo "$payload"
}

#######################################
# Archive a message
#######################################
cmd_archive() {
	local msg_id="" agent_id=""

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
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			msg_id="$1"
			shift
			;;
		esac
	done

	if [[ -z "$msg_id" ]]; then
		log_error "Usage: mail-helper.sh archive <message-id> [--agent <id>]"
		return 1
	fi

	ensure_db

	local updated
	updated=$(db "$MAIL_DB" "
        UPDATE messages SET status = 'archived', archived_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$(sql_escape "$msg_id")' AND status != 'archived';
        SELECT changes();
    ")

	if [[ "$updated" -eq 0 ]]; then
		log_error "Message not found or already archived: $msg_id"
		return 1
	fi

	log_success "Archived: $msg_id"
}
