#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Conversation Lifecycle -- create, resume, archive, close, get, list
# =============================================================================
# Manages conversation CRUD operations. Extracted from conversation-helper.sh
# to keep each file under the 1500-line file-size-debt threshold.
#
# Usage: source "${SCRIPT_DIR}/conversation-helper-lifecycle.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error, log_info, log_success, log_warn)
#   - conversation-helper.sh orchestrator (conv_db, conv_sql_escape, init_conv_db,
#     generate_conv_id, CONV_MEMORY_DB, VALID_CONV_CHANNELS)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONV_LIFECYCLE_LIB_LOADED:-}" ]] && return 0
_CONV_LIFECYCLE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Create a new conversation
#######################################
cmd_create() {
	local entity_id=""
	local channel=""
	local channel_id=""
	local topic=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--entity)
			entity_id="$2"
			shift 2
			;;
		--channel)
			channel="$2"
			shift 2
			;;
		--channel-id)
			channel_id="$2"
			shift 2
			;;
		--topic)
			topic="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" || -z "$channel" ]]; then
		log_error "Entity and channel are required. Use --entity <id> --channel <type>"
		return 1
	fi

	# Validate channel
	local ch_pattern=" $channel "
	if [[ ! " $VALID_CONV_CHANNELS " =~ $ch_pattern ]]; then
		log_error "Invalid channel: $channel. Valid channels: $VALID_CONV_CHANNELS"
		return 1
	fi

	init_conv_db

	# Verify entity exists
	local esc_entity
	esc_entity=$(conv_sql_escape "$entity_id")
	local entity_exists
	entity_exists=$(conv_db "$CONV_MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$esc_entity';" 2>/dev/null || echo "0")
	if [[ "$entity_exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	# Check for existing active conversation on same entity+channel+channel_id
	local esc_channel_id
	esc_channel_id=$(conv_sql_escape "$channel_id")
	local existing
	existing=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT id FROM conversations
WHERE entity_id = '$esc_entity'
  AND channel = '$channel'
  AND channel_id = '$esc_channel_id'
  AND status = 'active'
LIMIT 1;
EOF
	)

	if [[ -n "$existing" ]]; then
		log_warn "Active conversation already exists: $existing"
		log_info "Use 'conversation-helper.sh resume $existing' to continue it."
		echo "$existing"
		return 0
	fi

	# Generate ID and create
	local conv_id
	conv_id=$(generate_conv_id)
	local esc_topic
	esc_topic=$(conv_sql_escape "$topic")

	conv_db "$CONV_MEMORY_DB" <<EOF
INSERT INTO conversations (id, entity_id, channel, channel_id, topic, status, first_interaction_at)
VALUES ('$conv_id', '$esc_entity', '$channel', '$esc_channel_id', '$esc_topic', 'active',
        strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
EOF

	log_success "Created conversation: $conv_id (entity: $entity_id, channel: $channel)"
	echo "$conv_id"
	return 0
}

#######################################
# Resume an idle or closed conversation
#######################################
cmd_resume() {
	local conv_id="${1:-}"

	if [[ -z "$conv_id" ]]; then
		log_error "Conversation ID is required. Usage: conversation-helper.sh resume <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Check existence and current status
	local current_status
	current_status=$(conv_db "$CONV_MEMORY_DB" "SELECT status FROM conversations WHERE id = '$esc_id';" 2>/dev/null || echo "")
	if [[ -z "$current_status" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi

	if [[ "$current_status" == "active" ]]; then
		log_info "Conversation $conv_id is already active"
		echo "$conv_id"
		return 0
	fi

	conv_db "$CONV_MEMORY_DB" <<EOF
UPDATE conversations SET
    status = 'active',
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$esc_id';
EOF

	log_success "Resumed conversation: $conv_id (was: $current_status)"
	echo "$conv_id"
	return 0
}

#######################################
# Archive a conversation (mark as idle)
#######################################
cmd_archive() {
	local conv_id="${1:-}"

	if [[ -z "$conv_id" ]]; then
		log_error "Conversation ID is required. Usage: conversation-helper.sh archive <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	local current_status
	current_status=$(conv_db "$CONV_MEMORY_DB" "SELECT status FROM conversations WHERE id = '$esc_id';" 2>/dev/null || echo "")
	if [[ -z "$current_status" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi

	if [[ "$current_status" == "idle" ]]; then
		log_info "Conversation $conv_id is already idle/archived"
		return 0
	fi

	# Generate a summary before archiving if there are unsummarised interactions
	local unsummarised_count
	unsummarised_count=$(count_unsummarised_interactions "$conv_id")
	if [[ "$unsummarised_count" -gt 0 ]]; then
		log_info "Generating summary for $unsummarised_count unsummarised interactions before archiving..."
		cmd_summarise "$conv_id" || log_warn "Summary generation failed — archiving without summary"
	fi

	conv_db "$CONV_MEMORY_DB" <<EOF
UPDATE conversations SET
    status = 'idle',
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$esc_id';
EOF

	log_success "Archived conversation: $conv_id"
	return 0
}

#######################################
# Close a conversation permanently
#######################################
cmd_close() {
	local conv_id="${1:-}"

	if [[ -z "$conv_id" ]]; then
		log_error "Conversation ID is required. Usage: conversation-helper.sh close <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	local current_status
	current_status=$(conv_db "$CONV_MEMORY_DB" "SELECT status FROM conversations WHERE id = '$esc_id';" 2>/dev/null || echo "")
	if [[ -z "$current_status" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi

	if [[ "$current_status" == "closed" ]]; then
		log_info "Conversation $conv_id is already closed"
		return 0
	fi

	# Generate final summary before closing
	local unsummarised_count
	unsummarised_count=$(count_unsummarised_interactions "$conv_id")
	if [[ "$unsummarised_count" -gt 0 ]]; then
		log_info "Generating final summary for $unsummarised_count interactions before closing..."
		cmd_summarise "$conv_id" || log_warn "Summary generation failed — closing without final summary"
	fi

	conv_db "$CONV_MEMORY_DB" <<EOF
UPDATE conversations SET
    status = 'closed',
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$esc_id';
EOF

	log_success "Closed conversation: $conv_id"
	return 0
}

#######################################
# Get conversation details
#######################################
cmd_get() {
	local conv_id="${1:-}"
	local format="text"

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			format="json"
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$conv_id" ]]; then
		log_error "Conversation ID is required. Usage: conversation-helper.sh get <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	local exists
	exists=$(conv_db "$CONV_MEMORY_DB" "SELECT COUNT(*) FROM conversations WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi

	if [[ "$format" == "json" ]]; then
		conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT c.*,
    e.name as entity_name,
    e.type as entity_type,
    (SELECT COUNT(*) FROM interactions i WHERE i.conversation_id = c.id) as total_interactions,
    (SELECT COUNT(*) FROM conversation_summaries cs WHERE cs.conversation_id = c.id) as summary_count
FROM conversations c
LEFT JOIN entities e ON c.entity_id = e.id
WHERE c.id = '$esc_id';
EOF
	else
		echo ""
		echo "=== Conversation: $conv_id ==="
		echo ""
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT 'Entity: ' || e.name || ' (' || e.type || ', ' || c.entity_id || ')' || char(10) ||
       'Channel: ' || c.channel || COALESCE(':' || c.channel_id, '') || char(10) ||
       'Topic: ' || COALESCE(NULLIF(c.topic, ''), '(none)') || char(10) ||
       'Status: ' || c.status || char(10) ||
       'Messages: ' || c.interaction_count || char(10) ||
       'First: ' || COALESCE(c.first_interaction_at, '(none)') || char(10) ||
       'Last: ' || COALESCE(c.last_interaction_at, '(none)') || char(10) ||
       'Created: ' || c.created_at || char(10) ||
       'Updated: ' || c.updated_at
FROM conversations c
LEFT JOIN entities e ON c.entity_id = e.id
WHERE c.id = '$esc_id';
EOF

		# Show latest summary if available
		echo ""
		echo "Latest summary:"
		local latest_summary
		latest_summary=$(
			conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.summary
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
  AND cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
		)
		if [[ -z "$latest_summary" ]]; then
			echo "  (no summaries yet)"
		else
			echo "  $latest_summary"
		fi
	fi

	return 0
}

#######################################
# List conversations
#######################################
cmd_list() {
	local entity_filter=""
	local channel_filter=""
	local status_filter=""
	local format="text"
	local limit=50

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--entity)
			entity_filter="$2"
			shift 2
			;;
		--channel)
			channel_filter="$2"
			shift 2
			;;
		--status)
			status_filter="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_conv_db

	local where_clause="1=1"
	if [[ -n "$entity_filter" ]]; then
		where_clause="$where_clause AND c.entity_id = '$(conv_sql_escape "$entity_filter")'"
	fi
	if [[ -n "$channel_filter" ]]; then
		where_clause="$where_clause AND c.channel = '$(conv_sql_escape "$channel_filter")'"
	fi
	if [[ -n "$status_filter" ]]; then
		local st_pattern=" $status_filter "
		if [[ ! " $VALID_CONV_STATUSES " =~ $st_pattern ]]; then
			log_error "Invalid status: $status_filter. Valid: $VALID_CONV_STATUSES"
			return 1
		fi
		where_clause="$where_clause AND c.status = '$status_filter'"
	fi

	if [[ "$format" == "json" ]]; then
		conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT c.id, c.entity_id, e.name as entity_name, c.channel, c.channel_id,
    c.topic, c.status, c.interaction_count, c.last_interaction_at, c.created_at
FROM conversations c
LEFT JOIN entities e ON c.entity_id = e.id
WHERE $where_clause
ORDER BY c.updated_at DESC
LIMIT $limit;
EOF
	else
		echo ""
		echo "=== Conversations ==="
		echo ""
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT c.id || ' | ' || COALESCE(e.name, c.entity_id) || ' | ' ||
    c.channel || COALESCE(':' || NULLIF(c.channel_id, ''), '') || ' | ' ||
    c.status || ' | msgs:' || c.interaction_count ||
    CASE WHEN c.topic != '' THEN ' | ' || substr(c.topic, 1, 40) ELSE '' END
FROM conversations c
LEFT JOIN entities e ON c.entity_id = e.id
WHERE $where_clause
ORDER BY c.updated_at DESC
LIMIT $limit;
EOF
	fi

	return 0
}
