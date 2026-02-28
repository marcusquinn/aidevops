#!/usr/bin/env bash
# conversation-helper.sh - Conversation lifecycle management for aidevops
# Manages conversation lifecycle (create/resume/archive), context loading
# (Layer 1 summary + recent Layer 0 messages), AI-judged idle detection,
# immutable summary generation with source range references, and tone
# profile extraction.
#
# Part of the conversational memory system (p035 / t1363).
# Uses the same SQLite database (memory.db) as entity-helper.sh and memory-helper.sh.
#
# Architecture:
#   Layer 0: Raw interaction log (immutable, append-only) — entity-helper.sh
#   Layer 1: Per-conversation context (tactical summaries) — THIS SCRIPT
#   Layer 2: Entity relationship model (strategic profiles) — entity-helper.sh
#
# Usage:
#   conversation-helper.sh create --entity <id> --channel <type> [--channel-id <id>] [--topic "topic"]
#   conversation-helper.sh resume <conversation_id>
#   conversation-helper.sh archive <conversation_id>
#   conversation-helper.sh close <conversation_id>
#   conversation-helper.sh get <conversation_id> [--json]
#   conversation-helper.sh list [--entity <id>] [--channel <type>] [--status active|idle|closed] [--json]
#
#   conversation-helper.sh context <conversation_id> [--summary-tokens 2000] [--recent-messages 10] [--json]
#   conversation-helper.sh summarise <conversation_id> [--force]
#   conversation-helper.sh summaries <conversation_id> [--json]
#
#   conversation-helper.sh idle-check [--all] [<conversation_id>]
#   conversation-helper.sh tone <conversation_id> [--json]
#
#   conversation-helper.sh add-message <conversation_id> --content "msg" [--direction inbound|outbound] [--entity <id>]
#
#   conversation-helper.sh migrate
#   conversation-helper.sh stats
#   conversation-helper.sh help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration — uses same base as memory-helper.sh and entity-helper.sh
readonly CONV_MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
CONV_MEMORY_DB="${CONV_MEMORY_BASE_DIR}/memory.db"

# AI research script for intelligent judgments (haiku tier)
readonly AI_RESEARCH_SCRIPT="${SCRIPT_DIR}/ai-research-helper.sh"

# Valid conversation statuses
readonly VALID_CONV_STATUSES="active idle closed"

# Valid interaction directions
readonly VALID_CONV_DIRECTIONS="inbound outbound system"

# Valid channel types (must match entity-helper.sh)
readonly VALID_CONV_CHANNELS="matrix simplex email cli slack discord telegram irc web"

#######################################
# SQLite wrapper (same as entity/memory system)
#######################################
conv_db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Generate unique summary ID
#######################################
generate_summary_id() {
	echo "sum_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
	return 0
}

#######################################
# SQL-escape a value (double single quotes)
#######################################
conv_sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
}

#######################################
# Initialize conversation-specific tables in memory.db
# Adds conversation_summaries table alongside existing tables.
# Idempotent — safe to call multiple times.
#######################################
init_conv_db() {
	mkdir -p "$CONV_MEMORY_BASE_DIR"

	# Set WAL mode and busy timeout
	conv_db "$CONV_MEMORY_DB" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;" >/dev/null 2>&1

	conv_db "$CONV_MEMORY_DB" <<'SCHEMA'

-- Ensure base conversations table exists (created by entity-helper.sh)
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    channel_id TEXT DEFAULT NULL,
    topic TEXT DEFAULT '',
    summary TEXT DEFAULT '',
    status TEXT DEFAULT 'active' CHECK(status IN ('active', 'idle', 'closed')),
    interaction_count INTEGER DEFAULT 0,
    first_interaction_at TEXT DEFAULT NULL,
    last_interaction_at TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_conversations_entity ON conversations(entity_id, status);
CREATE INDEX IF NOT EXISTS idx_conversations_channel ON conversations(channel, status);

-- Versioned, immutable conversation summaries
-- Each summary covers a specific range of interactions and is never edited.
-- New summaries supersede old ones via supersedes_id chain.
CREATE TABLE IF NOT EXISTS conversation_summaries (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    summary TEXT NOT NULL,
    source_range_start TEXT NOT NULL,
    source_range_end TEXT NOT NULL,
    source_interaction_count INTEGER DEFAULT 0,
    tone_profile TEXT DEFAULT '{}',
    pending_actions TEXT DEFAULT '[]',
    supersedes_id TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE,
    FOREIGN KEY (supersedes_id) REFERENCES conversation_summaries(id)
);

CREATE INDEX IF NOT EXISTS idx_conv_summaries_conv ON conversation_summaries(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_conv_summaries_supersedes ON conversation_summaries(supersedes_id);

SCHEMA

	return 0
}

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
# Generate unique conversation ID
#######################################
generate_conv_id() {
	echo "conv_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
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

#######################################
# Load conversation context for an AI model
# Produces model-agnostic plain text with:
#   1. Entity profile summary
#   2. Latest Layer 1 summary (if available)
#   3. Recent Layer 0 messages
# This is the primary context-loading function for channel integrations.
#######################################
cmd_context() {
	local conv_id="${1:-}"
	local summary_tokens=2000
	local recent_messages=10
	local format="text"
	local privacy_filter=false

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--summary-tokens)
			summary_tokens="$2"
			shift 2
			;;
		--recent-messages)
			recent_messages="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		--privacy-filter)
			privacy_filter=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$conv_id" ]]; then
		log_error "Conversation ID is required. Usage: conversation-helper.sh context <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Verify conversation exists and get entity_id
	local conv_data
	conv_data=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT c.entity_id, c.channel, c.channel_id, c.topic, c.status, c.interaction_count,
    e.name as entity_name, e.type as entity_type
FROM conversations c
LEFT JOIN entities e ON c.entity_id = e.id
WHERE c.id = '$esc_id';
EOF
	)

	if [[ -z "$conv_data" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi

	local entity_id entity_name entity_type channel topic
	entity_id=$(conv_db "$CONV_MEMORY_DB" "SELECT entity_id FROM conversations WHERE id = '$esc_id';")
	entity_name=$(conv_db "$CONV_MEMORY_DB" "SELECT e.name FROM conversations c JOIN entities e ON c.entity_id = e.id WHERE c.id = '$esc_id';")
	entity_type=$(conv_db "$CONV_MEMORY_DB" "SELECT e.type FROM conversations c JOIN entities e ON c.entity_id = e.id WHERE c.id = '$esc_id';")
	channel=$(conv_db "$CONV_MEMORY_DB" "SELECT channel FROM conversations WHERE id = '$esc_id';")
	topic=$(conv_db "$CONV_MEMORY_DB" "SELECT topic FROM conversations WHERE id = '$esc_id';")

	local esc_entity
	esc_entity=$(conv_sql_escape "$entity_id")

	if [[ "$format" == "json" ]]; then
		echo "{"

		# Conversation metadata
		echo "\"conversation\":"
		conv_db -json "$CONV_MEMORY_DB" "SELECT id, entity_id, channel, channel_id, topic, status, interaction_count, last_interaction_at FROM conversations WHERE id = '$esc_id';"
		echo ","

		# Entity profile (current, non-superseded entries)
		echo "\"entity_profile\":"
		conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT profile_key, profile_value, confidence
FROM entity_profiles
WHERE entity_id = '$esc_entity'
  AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY profile_key;
EOF
		echo ","

		# Latest summary
		echo "\"latest_summary\":"
		conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT cs.id, cs.summary, cs.source_range_start, cs.source_range_end,
    cs.source_interaction_count, cs.tone_profile, cs.pending_actions, cs.created_at
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
  AND cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
		echo ","

		# Recent messages
		echo "\"recent_messages\":"
		conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT i.id, i.direction, i.content, i.created_at
FROM interactions i
WHERE i.conversation_id = '$esc_id'
ORDER BY i.created_at DESC
LIMIT $recent_messages;
EOF

		echo "}"
	else
		# Model-agnostic plain text context block
		echo "--- CONVERSATION CONTEXT ---"
		echo ""
		echo "Entity: ${entity_name:-Unknown} (${entity_type:-unknown})"
		echo "Channel: $channel"
		if [[ -n "$topic" && "$topic" != "" ]]; then
			echo "Topic: $topic"
		fi
		echo ""

		# Entity profile
		local profile_data
		profile_data=$(
			conv_db "$CONV_MEMORY_DB" <<EOF
SELECT profile_key || ': ' || profile_value
FROM entity_profiles
WHERE entity_id = '$esc_entity'
  AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY profile_key;
EOF
		)
		if [[ -n "$profile_data" ]]; then
			echo "Known preferences:"
			echo "$profile_data" | while IFS= read -r line; do
				echo "  - $line"
			done
			echo ""
		fi

		# Latest summary (Layer 1)
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
		if [[ -n "$latest_summary" ]]; then
			echo "Conversation summary:"
			echo "  $latest_summary"
			echo ""
		fi

		# Pending actions from latest summary
		local pending_actions
		pending_actions=$(
			conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.pending_actions
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
  AND cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
  AND cs.pending_actions != '[]'
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
		)
		if [[ -n "$pending_actions" && "$pending_actions" != "[]" ]]; then
			echo "Pending actions: $pending_actions"
			echo ""
		fi

		# Recent messages (Layer 0)
		echo "Recent messages (last $recent_messages):"
		local messages
		messages=$(
			conv_db "$CONV_MEMORY_DB" <<EOF
SELECT '[' || i.direction || '] ' || i.created_at || char(10) ||
       '  ' || substr(i.content, 1, 200) ||
       CASE WHEN length(i.content) > 200 THEN '...' ELSE '' END
FROM interactions i
WHERE i.conversation_id = '$esc_id'
ORDER BY i.created_at DESC
LIMIT $recent_messages;
EOF
		)

		if [[ -z "$messages" ]]; then
			echo "  (no messages yet)"
		else
			if [[ "$privacy_filter" == true ]]; then
				messages=$(echo "$messages" | sed 's/[a-zA-Z0-9._%+-]\+@[a-zA-Z0-9.-]\+\.[a-zA-Z]\{2,\}/[EMAIL]/g')
				messages=$(echo "$messages" | sed 's/\b[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\b/[IP]/g')
				messages=$(echo "$messages" | sed 's/sk-[a-zA-Z0-9_-]\{20,\}/[API_KEY]/g')
			fi
			echo "$messages"
		fi

		echo ""
		echo "--- END CONTEXT ---"
	fi

	return 0
}

#######################################
# Count interactions not yet covered by any summary
#######################################
count_unsummarised_interactions() {
	local conv_id="$1"
	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Find the last summarised interaction ID
	local last_summarised_end
	last_summarised_end=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.source_range_end
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
	)

	if [[ -z "$last_summarised_end" ]]; then
		# No summaries yet — all interactions are unsummarised
		conv_db "$CONV_MEMORY_DB" "SELECT COUNT(*) FROM interactions WHERE conversation_id = '$esc_id';"
	else
		local esc_end
		esc_end=$(conv_sql_escape "$last_summarised_end")
		# Count interactions created after the last summarised one
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT COUNT(*) FROM interactions
WHERE conversation_id = '$esc_id'
  AND created_at > (SELECT created_at FROM interactions WHERE id = '$esc_end');
EOF
	fi

	return 0
}

#######################################
# Generate an immutable summary for a conversation
# Uses AI (haiku tier) to produce a concise summary with:
#   - Key topics discussed
#   - Decisions made
#   - Pending actions
#   - Tone profile
# The summary references the source interaction range.
#######################################
cmd_summarise() {
	local conv_id="${1:-}"
	local force=false

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$conv_id" ]]; then
		log_error "Conversation ID is required. Usage: conversation-helper.sh summarise <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Verify conversation exists
	local exists
	exists=$(conv_db "$CONV_MEMORY_DB" "SELECT COUNT(*) FROM conversations WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi

	# Find unsummarised interactions
	local last_summarised_end
	last_summarised_end=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.source_range_end
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
	)

	local interactions_query
	if [[ -z "$last_summarised_end" ]]; then
		interactions_query="SELECT id, direction, content, created_at FROM interactions WHERE conversation_id = '$esc_id' ORDER BY created_at ASC"
	else
		local esc_end
		esc_end=$(conv_sql_escape "$last_summarised_end")
		interactions_query="SELECT id, direction, content, created_at FROM interactions WHERE conversation_id = '$esc_id' AND created_at > (SELECT created_at FROM interactions WHERE id = '$esc_end') ORDER BY created_at ASC"
	fi

	# Fetch interactions to summarise
	local interaction_data
	interaction_data=$(conv_db "$CONV_MEMORY_DB" "$interactions_query;")

	if [[ -z "$interaction_data" ]]; then
		if [[ "$force" != true ]]; then
			log_info "No unsummarised interactions for conversation $conv_id"
			return 0
		fi
		# Force mode: re-summarise all interactions
		interaction_data=$(conv_db "$CONV_MEMORY_DB" "SELECT id, direction, content, created_at FROM interactions WHERE conversation_id = '$esc_id' ORDER BY created_at ASC;")
		if [[ -z "$interaction_data" ]]; then
			log_warn "No interactions at all for conversation $conv_id"
			return 0
		fi
	fi

	# Get first and last interaction IDs for source range
	local first_int_id last_int_id int_count
	first_int_id=$(echo "$interaction_data" | head -1 | cut -d'|' -f1)
	last_int_id=$(echo "$interaction_data" | tail -1 | cut -d'|' -f1)
	int_count=$(echo "$interaction_data" | wc -l | tr -d ' ')

	# Format interactions for AI summarisation
	local formatted_interactions=""
	while IFS='|' read -r int_id direction content timestamp; do
		formatted_interactions="${formatted_interactions}[${direction}] ${timestamp}: ${content}
"
	done <<<"$interaction_data"

	# Get entity context for better summarisation
	local entity_name
	entity_name=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT e.name FROM conversations c
JOIN entities e ON c.entity_id = e.id
WHERE c.id = '$esc_id';
EOF
	)

	# Use AI to generate summary, tone profile, and pending actions
	local ai_prompt
	ai_prompt="Analyse this conversation with ${entity_name:-an entity} and produce a JSON response with exactly these fields:
{
  \"summary\": \"A concise 2-4 sentence summary of what was discussed, decisions made, and current state\",
  \"tone_profile\": {
    \"formality\": \"formal|casual|mixed\",
    \"technical_level\": \"high|medium|low\",
    \"sentiment\": \"positive|neutral|negative|mixed\",
    \"pace\": \"fast|moderate|slow\"
  },
  \"pending_actions\": [\"list of any commitments or follow-ups mentioned\"]
}

Conversation ($int_count messages):
$formatted_interactions

Rules:
- Summary must be factual, not interpretive
- Pending actions only if explicitly mentioned
- If no pending actions, use empty array []
- Respond with ONLY the JSON, no markdown fences"

	local ai_response=""
	if [[ -x "$AI_RESEARCH_SCRIPT" ]]; then
		ai_response=$("$AI_RESEARCH_SCRIPT" --model haiku --prompt "$ai_prompt" 2>/dev/null || echo "")
	fi

	# Parse AI response or use fallback
	local summary="" tone_profile="{}" pending_actions="[]"

	if [[ -n "$ai_response" ]] && command -v jq &>/dev/null; then
		# Try to parse JSON response
		summary=$(echo "$ai_response" | jq -r '.summary // empty' 2>/dev/null || echo "")
		tone_profile=$(echo "$ai_response" | jq -c '.tone_profile // {}' 2>/dev/null || echo "{}")
		pending_actions=$(echo "$ai_response" | jq -c '.pending_actions // []' 2>/dev/null || echo "[]")
	fi

	# Fallback: generate basic summary without AI
	if [[ -z "$summary" ]]; then
		summary="Conversation with ${entity_name:-entity} containing $int_count messages. "
		# Extract first and last message snippets
		local first_msg last_msg
		first_msg=$(echo "$interaction_data" | head -1 | cut -d'|' -f3 | head -c 80)
		last_msg=$(echo "$interaction_data" | tail -1 | cut -d'|' -f3 | head -c 80)
		summary="${summary}Started with: \"${first_msg}...\". "
		if [[ "$int_count" -gt 1 ]]; then
			summary="${summary}Most recent: \"${last_msg}...\""
		fi
		tone_profile="{}"
		pending_actions="[]"
	fi

	# Find current summary to supersede
	local current_summary_id
	current_summary_id=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.id FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
  AND cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
	)

	local supersedes_clause="NULL"
	if [[ -n "$current_summary_id" ]]; then
		supersedes_clause="'$(conv_sql_escape "$current_summary_id")'"
	fi

	# Store the immutable summary
	local sum_id
	sum_id=$(generate_summary_id)
	local esc_summary esc_tone esc_actions esc_first esc_last
	esc_summary=$(conv_sql_escape "$summary")
	esc_tone=$(conv_sql_escape "$tone_profile")
	esc_actions=$(conv_sql_escape "$pending_actions")
	esc_first=$(conv_sql_escape "$first_int_id")
	esc_last=$(conv_sql_escape "$last_int_id")

	conv_db "$CONV_MEMORY_DB" <<EOF
INSERT INTO conversation_summaries
    (id, conversation_id, summary, source_range_start, source_range_end,
     source_interaction_count, tone_profile, pending_actions, supersedes_id)
VALUES ('$sum_id', '$esc_id', '$esc_summary', '$esc_first', '$esc_last',
        $int_count, '$esc_tone', '$esc_actions', $supersedes_clause);
EOF

	# Update conversation's summary field with latest
	conv_db "$CONV_MEMORY_DB" <<EOF
UPDATE conversations SET
    summary = '$esc_summary',
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$esc_id';
EOF

	log_success "Generated summary $sum_id for conversation $conv_id ($int_count interactions, range: $first_int_id..$last_int_id)"
	if [[ -n "$current_summary_id" ]]; then
		log_info "Supersedes previous summary: $current_summary_id"
	fi
	echo "$sum_id"
	return 0
}

#######################################
# List summaries for a conversation
#######################################
cmd_summaries() {
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
		log_error "Conversation ID is required. Usage: conversation-helper.sh summaries <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	if [[ "$format" == "json" ]]; then
		conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT cs.id, cs.summary, cs.source_range_start, cs.source_range_end,
    cs.source_interaction_count, cs.tone_profile, cs.pending_actions,
    cs.supersedes_id, cs.created_at,
    CASE WHEN cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
         THEN 1 ELSE 0 END as is_current
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
ORDER BY cs.created_at DESC;
EOF
	else
		echo ""
		echo "=== Summaries for $conv_id ==="
		echo ""
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.id || ' | ' || cs.created_at || ' | msgs:' || cs.source_interaction_count ||
    ' | range:' || cs.source_range_start || '..' || cs.source_range_end ||
    CASE WHEN cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
         THEN ' <- CURRENT' ELSE '' END ||
    char(10) || '  ' || substr(cs.summary, 1, 120) ||
    CASE WHEN length(cs.summary) > 120 THEN '...' ELSE '' END
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
ORDER BY cs.created_at DESC;
EOF
	fi

	return 0
}

#######################################
# AI-judged idle detection
# Replaces fixed sessionIdleTimeout: 300 with intelligent judgment.
# Analyses the last few messages to determine if the conversation has
# naturally concluded, rather than using a fixed time threshold.
#
# Returns: 0 if conversation appears idle, 1 if still active
# Output: "idle" or "active" with reasoning
#######################################
cmd_idle_check() {
	local check_all=false
	local conv_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--all)
			check_all=true
			shift
			;;
		*)
			if [[ -z "$conv_id" ]]; then conv_id="$1"; fi
			shift
			;;
		esac
	done

	init_conv_db

	if [[ "$check_all" == true ]]; then
		# Check all active conversations
		local active_convs
		active_convs=$(conv_db "$CONV_MEMORY_DB" "SELECT id FROM conversations WHERE status = 'active';")
		if [[ -z "$active_convs" ]]; then
			log_info "No active conversations to check"
			return 0
		fi

		local idle_count=0
		while IFS= read -r cid; do
			[[ -z "$cid" ]] && continue
			local result
			result=$(check_single_conversation_idle "$cid")
			if [[ "$result" == "idle" ]]; then
				idle_count=$((idle_count + 1))
				log_info "Conversation $cid: IDLE — archiving"
				cmd_archive "$cid"
			else
				log_info "Conversation $cid: ACTIVE"
			fi
		done <<<"$active_convs"

		log_success "Checked $(echo "$active_convs" | wc -l | tr -d ' ') conversations, archived $idle_count"
		return 0
	fi

	if [[ -z "$conv_id" ]]; then
		log_error "Conversation ID or --all is required. Usage: conversation-helper.sh idle-check <conversation_id>"
		return 1
	fi

	local result
	result=$(check_single_conversation_idle "$conv_id")
	echo "$result"
	if [[ "$result" == "idle" ]]; then
		return 0
	else
		return 1
	fi
}

#######################################
# Check if a single conversation is idle
# Uses AI judgment when available, falls back to heuristics.
# Output: "idle" or "active"
#######################################
check_single_conversation_idle() {
	local conv_id="$1"
	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Get conversation metadata
	local last_activity
	last_activity=$(conv_db "$CONV_MEMORY_DB" "SELECT last_interaction_at FROM conversations WHERE id = '$esc_id';" 2>/dev/null || echo "")

	if [[ -z "$last_activity" ]]; then
		echo "idle"
		return 0
	fi

	# Get last few messages for context
	local recent_messages
	recent_messages=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT direction || ': ' || substr(content, 1, 150)
FROM interactions
WHERE conversation_id = '$esc_id'
ORDER BY created_at DESC
LIMIT 5;
EOF
	)

	# Calculate time since last activity (in seconds)
	local last_epoch now_epoch elapsed_seconds
	last_epoch=$(date -d "$last_activity" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_activity" +%s 2>/dev/null || echo "0")
	now_epoch=$(date +%s)
	elapsed_seconds=$((now_epoch - last_epoch))

	# Try AI judgment first (haiku tier — ~$0.001 per call)
	if [[ -x "$AI_RESEARCH_SCRIPT" && -n "$recent_messages" ]]; then
		local ai_prompt="Given these recent messages from a conversation (most recent first) and that ${elapsed_seconds} seconds have passed since the last message, is this conversation idle (naturally concluded or paused) or still active (expecting a response)?

Recent messages:
$recent_messages

Respond with ONLY one word: 'idle' or 'active'"

		local ai_result
		ai_result=$("$AI_RESEARCH_SCRIPT" --model haiku --prompt "$ai_prompt" 2>/dev/null || echo "")
		ai_result=$(echo "$ai_result" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

		if [[ "$ai_result" == "idle" || "$ai_result" == "active" ]]; then
			echo "$ai_result"
			return 0
		fi
	fi

	# Fallback: heuristic-based idle detection
	# More nuanced than a fixed 300s timeout:
	# - Short conversations (< 5 messages): idle after 10 minutes
	# - Medium conversations (5-20 messages): idle after 30 minutes
	# - Long conversations (> 20 messages): idle after 1 hour
	# - If last message looks like a farewell/acknowledgment: idle after 5 minutes
	local interaction_count
	interaction_count=$(conv_db "$CONV_MEMORY_DB" "SELECT interaction_count FROM conversations WHERE id = '$esc_id';" 2>/dev/null || echo "0")

	# Check for farewell patterns in last message
	local last_message
	last_message=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT lower(content) FROM interactions
WHERE conversation_id = '$esc_id'
ORDER BY created_at DESC
LIMIT 1;
EOF
	)

	local farewell_pattern="(thanks|thank you|bye|goodbye|cheers|talk later|ttyl|got it|perfect|great|ok|okay|sounds good|will do|noted)"
	if echo "$last_message" | grep -qiE "$farewell_pattern"; then
		if [[ "$elapsed_seconds" -gt 300 ]]; then
			echo "idle"
			return 0
		fi
	fi

	# Time-based thresholds scaled by conversation length
	if [[ "$interaction_count" -lt 5 && "$elapsed_seconds" -gt 600 ]]; then
		echo "idle"
	elif [[ "$interaction_count" -lt 20 && "$elapsed_seconds" -gt 1800 ]]; then
		echo "idle"
	elif [[ "$elapsed_seconds" -gt 3600 ]]; then
		echo "idle"
	else
		echo "active"
	fi

	return 0
}

#######################################
# Extract and display tone profile for a conversation
#######################################
cmd_tone() {
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
		log_error "Conversation ID is required. Usage: conversation-helper.sh tone <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Get tone from latest summary
	local tone_data
	tone_data=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.tone_profile
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
  AND cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
	)

	if [[ -z "$tone_data" || "$tone_data" == "{}" ]]; then
		# No tone data from summaries — try to extract from recent messages
		local recent_messages
		recent_messages=$(
			conv_db "$CONV_MEMORY_DB" <<EOF
SELECT direction || ': ' || substr(content, 1, 200)
FROM interactions
WHERE conversation_id = '$esc_id'
ORDER BY created_at DESC
LIMIT 10;
EOF
		)

		if [[ -z "$recent_messages" ]]; then
			log_info "No messages to analyse for tone profile"
			if [[ "$format" == "json" ]]; then
				echo "{}"
			fi
			return 0
		fi

		# Try AI extraction
		if [[ -x "$AI_RESEARCH_SCRIPT" ]]; then
			local ai_prompt="Analyse the tone of this conversation and respond with ONLY a JSON object:
{
  \"formality\": \"formal|casual|mixed\",
  \"technical_level\": \"high|medium|low\",
  \"sentiment\": \"positive|neutral|negative|mixed\",
  \"pace\": \"fast|moderate|slow\"
}

Messages:
$recent_messages

Respond with ONLY the JSON, no markdown fences."

			tone_data=$("$AI_RESEARCH_SCRIPT" --model haiku --prompt "$ai_prompt" 2>/dev/null || echo "{}")
		else
			tone_data="{}"
		fi
	fi

	if [[ "$format" == "json" ]]; then
		echo "$tone_data"
	else
		echo ""
		echo "=== Tone Profile: $conv_id ==="
		echo ""
		if command -v jq &>/dev/null && [[ "$tone_data" != "{}" ]]; then
			echo "$tone_data" | jq -r 'to_entries[] | "  \(.key): \(.value)"' 2>/dev/null || echo "  $tone_data"
		else
			echo "  (no tone data available)"
		fi
	fi

	return 0
}

#######################################
# Add a message to a conversation
# Convenience wrapper that logs an interaction (Layer 0) and updates
# the conversation's counters. Delegates to entity-helper.sh for the
# actual interaction logging.
#######################################
cmd_add_message() {
	local conv_id="${1:-}"
	local content=""
	local direction="inbound"
	local entity_id=""
	local metadata="{}"

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--content)
			content="$2"
			shift 2
			;;
		--direction)
			direction="$2"
			shift 2
			;;
		--entity)
			entity_id="$2"
			shift 2
			;;
		--metadata)
			metadata="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$conv_id" || -z "$content" ]]; then
		log_error "Usage: conversation-helper.sh add-message <conversation_id> --content \"message\""
		return 1
	fi

	local dir_pattern=" $direction "
	if [[ ! " $VALID_CONV_DIRECTIONS " =~ $dir_pattern ]]; then
		log_error "Invalid direction: $direction. Valid: $VALID_CONV_DIRECTIONS"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Get conversation details
	local conv_entity_id channel channel_id
	conv_entity_id=$(conv_db "$CONV_MEMORY_DB" "SELECT entity_id FROM conversations WHERE id = '$esc_id';" 2>/dev/null || echo "")
	if [[ -z "$conv_entity_id" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi

	channel=$(conv_db "$CONV_MEMORY_DB" "SELECT channel FROM conversations WHERE id = '$esc_id';")
	channel_id=$(conv_db "$CONV_MEMORY_DB" "SELECT channel_id FROM conversations WHERE id = '$esc_id';")

	# Use provided entity_id or fall back to conversation's entity
	if [[ -z "$entity_id" ]]; then
		entity_id="$conv_entity_id"
	fi

	# If conversation is idle/closed, resume it
	local status
	status=$(conv_db "$CONV_MEMORY_DB" "SELECT status FROM conversations WHERE id = '$esc_id';")
	if [[ "$status" != "active" ]]; then
		log_info "Resuming $status conversation $conv_id"
		cmd_resume "$conv_id" >/dev/null
	fi

	# Delegate to entity-helper.sh for the actual interaction logging.
	# entity-helper.sh log-interaction already updates conversation counters
	# (interaction_count, last_interaction_at) when --conversation-id is passed,
	# so we must NOT duplicate that update here.
	local entity_helper="${SCRIPT_DIR}/entity-helper.sh"
	if [[ -x "$entity_helper" ]]; then
		local int_id
		int_id=$("$entity_helper" log-interaction "$entity_id" \
			--channel "$channel" \
			--channel-id "$channel_id" \
			--content "$content" \
			--direction "$direction" \
			--conversation-id "$conv_id" \
			--metadata "$metadata" 2>/dev/null)

		if [[ -n "$int_id" ]]; then
			echo "$int_id"
		else
			log_error "Failed to log interaction via entity-helper.sh"
			return 1
		fi
	else
		# Fallback: log directly if entity-helper.sh not available
		log_warn "entity-helper.sh not found — logging interaction directly"

		# Privacy filter
		content=$(echo "$content" | sed 's/<private>[^<]*<\/private>//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
		if echo "$content" | grep -qE '(sk-[a-zA-Z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36})'; then
			log_error "Content appears to contain secrets. Refusing to log."
			return 1
		fi

		local int_id
		int_id="int_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
		local esc_entity esc_content esc_channel_id esc_metadata
		esc_entity=$(conv_sql_escape "$entity_id")
		esc_content=$(conv_sql_escape "$content")
		esc_channel_id=$(conv_sql_escape "$channel_id")
		esc_metadata=$(conv_sql_escape "$metadata")

		conv_db "$CONV_MEMORY_DB" <<EOF
INSERT INTO interactions (id, entity_id, channel, channel_id, conversation_id, direction, content, metadata)
VALUES ('$int_id', '$esc_entity', '$channel', '$esc_channel_id', '$esc_id', '$direction', '$esc_content', '$esc_metadata');
EOF

		# Update FTS
		conv_db "$CONV_MEMORY_DB" <<EOF
INSERT INTO interactions_fts (id, entity_id, content, channel, created_at)
VALUES ('$int_id', '$esc_entity', '$esc_content', '$channel', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
EOF

		echo "$int_id"

		# Only update conversation counters in the fallback path —
		# entity-helper.sh already handles this when it's available
		conv_db "$CONV_MEMORY_DB" <<EOF
UPDATE conversations SET
    interaction_count = interaction_count + 1,
    last_interaction_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    first_interaction_at = COALESCE(first_interaction_at, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
WHERE id = '$esc_id';
EOF
	fi

	return 0
}

#######################################
# Run schema migration (idempotent)
#######################################
cmd_migrate() {
	log_info "Running conversation schema migration..."

	# Backup before migration
	if [[ -f "$CONV_MEMORY_DB" ]]; then
		local backup
		backup=$(backup_sqlite_db "$CONV_MEMORY_DB" "pre-conversation-migrate")
		if [[ $? -ne 0 || -z "$backup" ]]; then
			log_warn "Backup failed before conversation migration — proceeding cautiously"
		else
			log_info "Pre-migration backup: $backup"
		fi
	fi

	init_conv_db

	log_success "Conversation schema migration complete"

	# Show table status
	conv_db "$CONV_MEMORY_DB" <<'EOF'
SELECT 'conversations: ' || (SELECT COUNT(*) FROM conversations) || ' rows' ||
    char(10) || 'conversation_summaries: ' || (SELECT COUNT(*) FROM conversation_summaries) || ' rows' ||
    char(10) || 'interactions: ' || (SELECT COUNT(*) FROM interactions) || ' rows';
EOF

	return 0
}

#######################################
# Show conversation system statistics
#######################################
cmd_stats() {
	init_conv_db

	echo ""
	echo "=== Conversation Statistics ==="
	echo ""

	conv_db "$CONV_MEMORY_DB" <<'EOF'
SELECT 'Total conversations' as metric, COUNT(*) as value FROM conversations
UNION ALL
SELECT 'Active', COUNT(*) FROM conversations WHERE status = 'active'
UNION ALL
SELECT 'Idle', COUNT(*) FROM conversations WHERE status = 'idle'
UNION ALL
SELECT 'Closed', COUNT(*) FROM conversations WHERE status = 'closed'
UNION ALL
SELECT 'Total summaries', COUNT(*) FROM conversation_summaries
UNION ALL
SELECT 'Current summaries', COUNT(*) FROM conversation_summaries
    WHERE id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
UNION ALL
SELECT 'Total interactions (in conversations)', COUNT(*) FROM interactions WHERE conversation_id IS NOT NULL;
EOF

	echo ""

	# Channel distribution
	echo "Conversations by channel:"
	conv_db "$CONV_MEMORY_DB" <<'EOF'
SELECT '  ' || channel || ': ' || COUNT(*) || ' conversations'
FROM conversations
GROUP BY channel
ORDER BY COUNT(*) DESC;
EOF

	echo ""

	# Most active conversations
	echo "Most active conversations (top 5):"
	conv_db "$CONV_MEMORY_DB" <<'EOF'
SELECT '  ' || c.id || ' | ' || COALESCE(e.name, c.entity_id) || ' | ' ||
    c.channel || ' | msgs:' || c.interaction_count || ' | ' || c.status
FROM conversations c
LEFT JOIN entities e ON c.entity_id = e.id
ORDER BY c.interaction_count DESC
LIMIT 5;
EOF

	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
conversation-helper.sh - Conversation lifecycle management for aidevops

Part of the conversational memory system (p035 / t1363).
Manages Layer 1: per-conversation context with AI-judged idle detection,
immutable summaries, and tone profile extraction.

USAGE:
    conversation-helper.sh <command> [options]

LIFECYCLE:
    create              Create a new conversation
    resume <id>         Resume an idle/closed conversation
    archive <id>        Archive a conversation (mark idle, generate summary)
    close <id>          Close a conversation permanently
    get <id>            Get conversation details
    list                List conversations

CONTEXT:
    context <id>        Load conversation context for AI model
    summarise <id>      Generate immutable summary with source range refs
    summaries <id>      List all summaries for a conversation
    tone <id>           Extract/display tone profile

MESSAGES:
    add-message <id>    Add a message to a conversation

INTELLIGENCE:
    idle-check [<id>]   AI-judged idle detection (replaces fixed timeout)

SYSTEM:
    migrate             Run schema migration (idempotent)
    stats               Show conversation statistics
    help                Show this help

CREATE OPTIONS:
    --entity <id>       Entity ID (required)
    --channel <type>    Channel type (required): matrix, simplex, email, cli, etc.
    --channel-id <id>   Channel-specific identifier (room ID, contact ID, etc.)
    --topic <text>      Conversation topic

CONTEXT OPTIONS:
    --summary-tokens <n>    Max tokens for summary (default: 2000)
    --recent-messages <n>   Number of recent messages to include (default: 10)
    --privacy-filter        Redact emails, IPs, API keys in output
    --json                  Output as JSON

SUMMARISE OPTIONS:
    --force             Re-summarise all interactions (not just unsummarised)

IDLE-CHECK OPTIONS:
    --all               Check all active conversations

ADD-MESSAGE OPTIONS:
    --content <text>    Message content (required)
    --direction <dir>   inbound, outbound, or system (default: inbound)
    --entity <id>       Override entity (default: conversation's entity)
    --metadata <json>   Additional metadata as JSON

ARCHITECTURE:
    Layer 0: Raw interaction log (immutable) — managed by entity-helper.sh
    Layer 1: Per-conversation context (THIS SCRIPT)
             - Conversation lifecycle (create/resume/archive/close)
             - Immutable summaries with source range references
             - AI-judged idle detection (replaces fixed sessionIdleTimeout)
             - Tone profile extraction
             - Model-agnostic context loading
    Layer 2: Entity relationship model — managed by entity-helper.sh

IDLE DETECTION:
    Replaces fixed sessionIdleTimeout: 300 with intelligent judgment.
    Uses AI (haiku tier, ~$0.001/call) to analyse last few messages and
    determine if the conversation has naturally concluded. Falls back to
    adaptive heuristics when AI is unavailable:
    - Short conversations (< 5 msgs): idle after 10 min
    - Medium conversations (5-20 msgs): idle after 30 min
    - Long conversations (> 20 msgs): idle after 1 hour
    - Farewell patterns detected: idle after 5 min

SUMMARIES:
    Summaries are immutable — never edited, only superseded.
    Each summary records:
    - source_range_start/end: which interaction IDs it covers
    - source_interaction_count: how many messages were summarised
    - tone_profile: formality, technical level, sentiment, pace
    - pending_actions: commitments or follow-ups mentioned
    - supersedes_id: link to previous summary version

EXAMPLES:
    # Create a conversation
    conversation-helper.sh create --entity ent_xxx --channel matrix \
        --channel-id "!room:server" --topic "Deployment discussion"

    # Add messages
    conversation-helper.sh add-message conv_xxx --content "How's the deploy?"
    conversation-helper.sh add-message conv_xxx --content "All green!" --direction outbound

    # Load context for AI model
    conversation-helper.sh context conv_xxx --recent-messages 20

    # Generate summary
    conversation-helper.sh summarise conv_xxx

    # Check if conversations are idle
    conversation-helper.sh idle-check --all

    # Archive with auto-summary
    conversation-helper.sh archive conv_xxx

    # View tone profile
    conversation-helper.sh tone conv_xxx --json
EOF
	return 0
}

#######################################
# Main entry point
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	create) cmd_create "$@" ;;
	resume) cmd_resume "$@" ;;
	archive) cmd_archive "$@" ;;
	close) cmd_close "$@" ;;
	get) cmd_get "$@" ;;
	list) cmd_list "$@" ;;
	context) cmd_context "$@" ;;
	summarise | summarize) cmd_summarise "$@" ;;
	summaries) cmd_summaries "$@" ;;
	idle-check) cmd_idle_check "$@" ;;
	tone) cmd_tone "$@" ;;
	add-message) cmd_add_message "$@" ;;
	migrate) cmd_migrate ;;
	stats) cmd_stats ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
exit $?
