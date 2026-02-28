#!/usr/bin/env bash
# entity-helper.sh - Entity memory system for aidevops
# Manages entities (people, agents, services) with cross-channel identity,
# versioned profiles, and privacy-filtered context loading.
#
# Part of the conversational memory system (p035 / t1363).
# Uses the same SQLite database (memory.db) as memory-helper.sh.
#
# Architecture:
#   Layer 0: Raw interaction log (immutable, append-only)
#   Layer 1: Per-conversation context (tactical summaries)
#   Layer 2: Entity relationship model (strategic profiles)
#
# Usage:
#   entity-helper.sh create --name "Name" --type person [--channel matrix --channel-id @user:server]
#   entity-helper.sh get <entity_id>
#   entity-helper.sh list [--type person|agent|service] [--channel matrix]
#   entity-helper.sh update <entity_id> --name "New Name"
#   entity-helper.sh delete <entity_id> [--confirm]
#   entity-helper.sh search --query "name or alias"
#
#   entity-helper.sh link <entity_id> --channel matrix --channel-id @user:server [--verified]
#   entity-helper.sh unlink <entity_id> --channel matrix --channel-id @user:server
#   entity-helper.sh suggest <channel> <channel_id>
#   entity-helper.sh verify <entity_id> --channel matrix --channel-id @user:server
#   entity-helper.sh channels <entity_id>
#
#   entity-helper.sh profile <entity_id> [--json]
#   entity-helper.sh profile-update <entity_id> --key "preference" --value "concise responses" [--evidence "observed in 5 conversations"]
#   entity-helper.sh profile-history <entity_id>
#
#   entity-helper.sh log-interaction <entity_id> --channel matrix --content "message" [--direction inbound|outbound]
#   entity-helper.sh context <entity_id> [--channel matrix] [--limit 20] [--privacy-filter]
#
#   entity-helper.sh stats
#   entity-helper.sh migrate
#   entity-helper.sh help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration — uses same base as memory-helper.sh
readonly ENTITY_MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
ENTITY_MEMORY_DB="${ENTITY_MEMORY_BASE_DIR}/memory.db"

# Valid entity types
readonly VALID_ENTITY_TYPES="person agent service"

# Valid channel types
readonly VALID_CHANNELS="matrix simplex email cli slack discord telegram irc web"

# Valid interaction directions
readonly VALID_DIRECTIONS="inbound outbound system"

# Valid confidence levels for identity links
readonly VALID_LINK_CONFIDENCE="confirmed suggested inferred"

#######################################
# SQLite wrapper (same as memory system)
#######################################
entity_db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Generate unique entity ID
#######################################
generate_entity_id() {
	echo "ent_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
	return 0
}

#######################################
# Generate unique interaction ID
#######################################
generate_interaction_id() {
	echo "int_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
	return 0
}

#######################################
# Generate unique conversation ID
#######################################
generate_conversation_id() {
	echo "conv_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
	return 0
}

#######################################
# Generate unique profile ID
#######################################
generate_profile_id() {
	echo "prof_$(date +%Y%m%d%H%M%S)_$(head -c 4 /dev/urandom | xxd -p)"
	return 0
}

#######################################
# Initialize entity tables in memory.db
# Adds entity-specific tables alongside existing learnings tables.
# Idempotent — safe to call multiple times.
#######################################
init_entity_db() {
	mkdir -p "$ENTITY_MEMORY_BASE_DIR"

	# Set WAL mode and busy timeout (output suppressed — PRAGMAs echo their values)
	entity_db "$ENTITY_MEMORY_DB" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;" >/dev/null 2>&1

	entity_db "$ENTITY_MEMORY_DB" <<'SCHEMA'

-- Layer 2: Entity relationship model
-- Core entity table — a person, agent, or service we interact with
CREATE TABLE IF NOT EXISTS entities (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('person', 'agent', 'service')),
    display_name TEXT DEFAULT NULL,
    aliases TEXT DEFAULT '',
    notes TEXT DEFAULT '',
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Cross-channel identity linking
-- Maps channel-specific identifiers to entities
-- confidence: confirmed (user verified), suggested (system proposed), inferred (pattern match)
CREATE TABLE IF NOT EXISTS entity_channels (
    entity_id TEXT NOT NULL,
    channel TEXT NOT NULL CHECK(channel IN ('matrix', 'simplex', 'email', 'cli', 'slack', 'discord', 'telegram', 'irc', 'web')),
    channel_id TEXT NOT NULL,
    display_name TEXT DEFAULT NULL,
    confidence TEXT DEFAULT 'suggested' CHECK(confidence IN ('confirmed', 'suggested', 'inferred')),
    verified_at TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (channel, channel_id),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
);

-- Index for fast entity lookups by channel
CREATE INDEX IF NOT EXISTS idx_entity_channels_entity ON entity_channels(entity_id);

-- Layer 0: Raw interaction log (immutable, append-only)
-- Every message across all channels — source of truth
CREATE TABLE IF NOT EXISTS interactions (
    id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    channel_id TEXT DEFAULT NULL,
    conversation_id TEXT DEFAULT NULL,
    direction TEXT NOT NULL DEFAULT 'inbound' CHECK(direction IN ('inbound', 'outbound', 'system')),
    content TEXT NOT NULL,
    metadata TEXT DEFAULT '{}',
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
);

-- Indexes for interaction queries
CREATE INDEX IF NOT EXISTS idx_interactions_entity ON interactions(entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_interactions_conversation ON interactions(conversation_id);
CREATE INDEX IF NOT EXISTS idx_interactions_channel ON interactions(channel, channel_id, created_at DESC);

-- Layer 1: Per-conversation context (tactical)
-- Active threads per entity+channel with summaries
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
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_conversations_entity ON conversations(entity_id, status);

-- Layer 2: Versioned entity profiles
-- Inferred needs, expectations, preferences — with evidence
-- Uses supersedes_id pattern from existing learning_relations
CREATE TABLE IF NOT EXISTS entity_profiles (
    id TEXT PRIMARY KEY,
    entity_id TEXT NOT NULL,
    profile_key TEXT NOT NULL,
    profile_value TEXT NOT NULL,
    evidence TEXT DEFAULT '',
    confidence TEXT DEFAULT 'medium' CHECK(confidence IN ('high', 'medium', 'low')),
    supersedes_id TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE,
    FOREIGN KEY (supersedes_id) REFERENCES entity_profiles(id)
);

CREATE INDEX IF NOT EXISTS idx_entity_profiles_entity ON entity_profiles(entity_id, profile_key);
CREATE INDEX IF NOT EXISTS idx_entity_profiles_supersedes ON entity_profiles(supersedes_id);

-- Capability gaps detected from entity interactions
-- Feeds into self-evolution loop: gap -> TODO -> upgrade -> better service
CREATE TABLE IF NOT EXISTS capability_gaps (
    id TEXT PRIMARY KEY,
    entity_id TEXT DEFAULT NULL,
    description TEXT NOT NULL,
    evidence TEXT DEFAULT '',
    frequency INTEGER DEFAULT 1,
    status TEXT DEFAULT 'detected' CHECK(status IN ('detected', 'todo_created', 'resolved', 'wont_fix')),
    todo_ref TEXT DEFAULT NULL,
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_capability_gaps_status ON capability_gaps(status);

-- FTS5 index for searching interactions
CREATE VIRTUAL TABLE IF NOT EXISTS interactions_fts USING fts5(
    id UNINDEXED,
    entity_id UNINDEXED,
    content,
    channel UNINDEXED,
    created_at UNINDEXED,
    tokenize='porter unicode61'
);
SCHEMA

	return 0
}

#######################################
# SQL-escape a value (double single quotes)
#######################################
sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
}

#######################################
# Create a new entity
#######################################
cmd_create() {
	local name=""
	local type="person"
	local display_name=""
	local aliases=""
	local notes=""
	local channel=""
	local channel_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			name="$2"
			shift 2
			;;
		--type)
			type="$2"
			shift 2
			;;
		--display-name)
			display_name="$2"
			shift 2
			;;
		--aliases)
			aliases="$2"
			shift 2
			;;
		--notes)
			notes="$2"
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
		*) shift ;;
		esac
	done

	if [[ -z "$name" ]]; then
		log_error "Name is required. Use --name \"Entity Name\""
		return 1
	fi

	# Validate type
	local type_pattern=" $type "
	if [[ ! " $VALID_ENTITY_TYPES " =~ $type_pattern ]]; then
		log_error "Invalid type: $type. Valid types: $VALID_ENTITY_TYPES"
		return 1
	fi

	init_entity_db

	local id
	id=$(generate_entity_id)

	local esc_name esc_display esc_aliases esc_notes
	esc_name=$(sql_escape "$name")
	esc_display=$(sql_escape "$display_name")
	esc_aliases=$(sql_escape "$aliases")
	esc_notes=$(sql_escape "$notes")

	entity_db "$ENTITY_MEMORY_DB" <<EOF
INSERT INTO entities (id, name, type, display_name, aliases, notes)
VALUES ('$id', '$esc_name', '$type', '$esc_display', '$esc_aliases', '$esc_notes');
EOF

	# If channel info provided, create the initial channel link
	if [[ -n "$channel" && -n "$channel_id" ]]; then
		local channel_pattern=" $channel "
		if [[ ! " $VALID_CHANNELS " =~ $channel_pattern ]]; then
			log_warn "Invalid channel: $channel. Skipping channel link."
		else
			local esc_channel_id
			esc_channel_id=$(sql_escape "$channel_id")
			entity_db "$ENTITY_MEMORY_DB" <<EOF
INSERT INTO entity_channels (entity_id, channel, channel_id, display_name, confidence)
VALUES ('$id', '$channel', '$esc_channel_id', '$esc_display', 'confirmed');
EOF
			log_info "Linked to $channel: $channel_id"
		fi
	fi

	log_success "Created entity: $id ($name, $type)"
	echo "$id"
	return 0
}

#######################################
# Get entity by ID
#######################################
cmd_get() {
	local entity_id="${1:-}"
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

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh get <entity_id>"
		return 1
	fi

	init_entity_db

	local esc_id
	esc_id=$(sql_escape "$entity_id")

	# Check existence
	local exists
	exists=$(entity_db "$ENTITY_MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	if [[ "$format" == "json" ]]; then
		entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT e.*,
    (SELECT COUNT(*) FROM entity_channels ec WHERE ec.entity_id = e.id) as channel_count,
    (SELECT COUNT(*) FROM interactions i WHERE i.entity_id = e.id) as interaction_count,
    (SELECT COUNT(*) FROM conversations c WHERE c.entity_id = e.id AND c.status = 'active') as active_conversations
FROM entities e WHERE e.id = '$esc_id';
EOF
	else
		echo ""
		echo "=== Entity: $entity_id ==="
		echo ""
		entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT 'Name: ' || name || char(10) ||
       'Type: ' || type || char(10) ||
       'Display: ' || COALESCE(display_name, '(none)') || char(10) ||
       'Aliases: ' || COALESCE(aliases, '(none)') || char(10) ||
       'Notes: ' || COALESCE(notes, '(none)') || char(10) ||
       'Created: ' || created_at || char(10) ||
       'Updated: ' || updated_at
FROM entities WHERE id = '$esc_id';
EOF

		echo ""
		echo "Channels:"
		local channels
		channels=$(entity_db "$ENTITY_MEMORY_DB" \
			"SELECT channel || ': ' || channel_id || ' [' || confidence || ']' FROM entity_channels WHERE entity_id = '$esc_id';")
		if [[ -z "$channels" ]]; then
			echo "  (none)"
		else
			echo "$channels" | while IFS= read -r line; do
				echo "  $line"
			done
		fi

		echo ""
		echo "Stats:"
		entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT '  Interactions: ' || (SELECT COUNT(*) FROM interactions WHERE entity_id = '$esc_id') || char(10) ||
       '  Active conversations: ' || (SELECT COUNT(*) FROM conversations WHERE entity_id = '$esc_id' AND status = 'active') || char(10) ||
       '  Profile entries: ' || (SELECT COUNT(*) FROM entity_profiles WHERE entity_id = '$esc_id' AND supersedes_id IS NULL);
EOF
	fi

	return 0
}

#######################################
# List entities
#######################################
cmd_list() {
	local type_filter=""
	local channel_filter=""
	local format="text"
	local limit=50

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			type_filter="$2"
			shift 2
			;;
		--channel)
			channel_filter="$2"
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

	init_entity_db

	local where_clause="1=1"
	if [[ -n "$type_filter" ]]; then
		local type_filter_pattern=" $type_filter "
		if [[ ! " $VALID_ENTITY_TYPES " =~ $type_filter_pattern ]]; then
			log_error "Invalid type: $type_filter. Valid types: $VALID_ENTITY_TYPES"
			return 1
		fi
		where_clause="$where_clause AND e.type = '$type_filter'"
	fi
	if [[ -n "$channel_filter" ]]; then
		where_clause="$where_clause AND e.id IN (SELECT entity_id FROM entity_channels WHERE channel = '$(sql_escape "$channel_filter")')"
	fi

	if [[ "$format" == "json" ]]; then
		entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT e.id, e.name, e.type, e.display_name, e.created_at,
    (SELECT COUNT(*) FROM entity_channels ec WHERE ec.entity_id = e.id) as channel_count,
    (SELECT COUNT(*) FROM interactions i WHERE i.entity_id = e.id) as interaction_count
FROM entities e
WHERE $where_clause
ORDER BY e.updated_at DESC
LIMIT $limit;
EOF
	else
		echo ""
		echo "=== Entities ==="
		echo ""
		entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT e.id || ' | ' || e.name || ' (' || e.type || ') | channels: ' ||
    (SELECT COUNT(*) FROM entity_channels ec WHERE ec.entity_id = e.id) ||
    ' | interactions: ' ||
    (SELECT COUNT(*) FROM interactions i WHERE i.entity_id = e.id)
FROM entities e
WHERE $where_clause
ORDER BY e.updated_at DESC
LIMIT $limit;
EOF
	fi

	return 0
}

#######################################
# Update an entity
#######################################
cmd_update() {
	local entity_id="${1:-}"
	shift || true

	local name="" display_name="" aliases="" notes="" type=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			name="$2"
			shift 2
			;;
		--display-name)
			display_name="$2"
			shift 2
			;;
		--aliases)
			aliases="$2"
			shift 2
			;;
		--notes)
			notes="$2"
			shift 2
			;;
		--type)
			type="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh update <entity_id> --name \"New Name\""
		return 1
	fi

	init_entity_db

	local esc_id
	esc_id=$(sql_escape "$entity_id")

	# Check existence
	local exists
	exists=$(entity_db "$ENTITY_MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	# Build SET clause dynamically
	local set_parts=()
	if [[ -n "$name" ]]; then
		set_parts+=("name = '$(sql_escape "$name")'")
	fi
	if [[ -n "$display_name" ]]; then
		set_parts+=("display_name = '$(sql_escape "$display_name")'")
	fi
	if [[ -n "$aliases" ]]; then
		set_parts+=("aliases = '$(sql_escape "$aliases")'")
	fi
	if [[ -n "$notes" ]]; then
		set_parts+=("notes = '$(sql_escape "$notes")'")
	fi
	if [[ -n "$type" ]]; then
		local update_type_pattern=" $type "
		if [[ ! " $VALID_ENTITY_TYPES " =~ $update_type_pattern ]]; then
			log_error "Invalid type: $type. Valid types: $VALID_ENTITY_TYPES"
			return 1
		fi
		set_parts+=("type = '$type'")
	fi

	if [[ ${#set_parts[@]} -eq 0 ]]; then
		log_warn "No fields to update"
		return 0
	fi

	set_parts+=("updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')")

	local set_clause
	set_clause=$(printf ", %s" "${set_parts[@]}")
	set_clause="${set_clause:2}" # Remove leading ", "

	entity_db "$ENTITY_MEMORY_DB" "UPDATE entities SET $set_clause WHERE id = '$esc_id';"

	log_success "Updated entity: $entity_id"
	return 0
}

#######################################
# Delete an entity
#######################################
cmd_delete() {
	local entity_id="${1:-}"
	local confirm=false

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--confirm)
			confirm=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh delete <entity_id> --confirm"
		return 1
	fi

	init_entity_db

	local esc_id
	esc_id=$(sql_escape "$entity_id")

	# Check existence
	local exists
	exists=$(entity_db "$ENTITY_MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	if [[ "$confirm" != true ]]; then
		local entity_name
		entity_name=$(entity_db "$ENTITY_MEMORY_DB" "SELECT name FROM entities WHERE id = '$esc_id';")
		local interaction_count
		interaction_count=$(entity_db "$ENTITY_MEMORY_DB" "SELECT COUNT(*) FROM interactions WHERE entity_id = '$esc_id';")
		log_warn "This will delete entity '$entity_name' and $interaction_count interactions."
		log_warn "Use --confirm to proceed."
		return 1
	fi

	# CASCADE handles entity_channels, interactions, conversations, entity_profiles
	# But we need to clean up FTS manually
	entity_db "$ENTITY_MEMORY_DB" <<EOF
DELETE FROM interactions_fts WHERE id IN (SELECT id FROM interactions WHERE entity_id = '$esc_id');
DELETE FROM capability_gaps WHERE entity_id = '$esc_id';
DELETE FROM entity_profiles WHERE entity_id = '$esc_id';
DELETE FROM conversations WHERE entity_id = '$esc_id';
DELETE FROM interactions WHERE entity_id = '$esc_id';
DELETE FROM entity_channels WHERE entity_id = '$esc_id';
DELETE FROM entities WHERE id = '$esc_id';
EOF

	log_success "Deleted entity: $entity_id"
	return 0
}

#######################################
# Search entities by name or alias
#######################################
cmd_search() {
	local query=""
	local format="text"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--query | -q)
			query="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		*)
			if [[ -z "$query" ]]; then query="$1"; fi
			shift
			;;
		esac
	done

	if [[ -z "$query" ]]; then
		log_error "Query is required. Usage: entity-helper.sh search --query \"name\""
		return 1
	fi

	init_entity_db

	local esc_query
	esc_query=$(sql_escape "$query")

	if [[ "$format" == "json" ]]; then
		entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT e.id, e.name, e.type, e.display_name, e.aliases, e.created_at
FROM entities e
WHERE e.name LIKE '%${esc_query}%'
   OR e.display_name LIKE '%${esc_query}%'
   OR e.aliases LIKE '%${esc_query}%'
   OR e.id IN (SELECT entity_id FROM entity_channels WHERE channel_id LIKE '%${esc_query}%' OR display_name LIKE '%${esc_query}%')
ORDER BY e.updated_at DESC
LIMIT 20;
EOF
	else
		echo ""
		echo "=== Search: \"$query\" ==="
		echo ""
		entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT e.id || ' | ' || e.name || ' (' || e.type || ')'
FROM entities e
WHERE e.name LIKE '%${esc_query}%'
   OR e.display_name LIKE '%${esc_query}%'
   OR e.aliases LIKE '%${esc_query}%'
   OR e.id IN (SELECT entity_id FROM entity_channels WHERE channel_id LIKE '%${esc_query}%' OR display_name LIKE '%${esc_query}%')
ORDER BY e.updated_at DESC
LIMIT 20;
EOF
	fi

	return 0
}

#######################################
# Link an entity to a channel identity
#######################################
cmd_link() {
	local entity_id="${1:-}"
	local channel=""
	local channel_id=""
	local display_name=""
	local verified=false

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel)
			channel="$2"
			shift 2
			;;
		--channel-id)
			channel_id="$2"
			shift 2
			;;
		--display-name)
			display_name="$2"
			shift 2
			;;
		--verified)
			verified=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" || -z "$channel" || -z "$channel_id" ]]; then
		log_error "Usage: entity-helper.sh link <entity_id> --channel <type> --channel-id <id>"
		return 1
	fi

	local link_channel_pattern=" $channel "
	if [[ ! " $VALID_CHANNELS " =~ $link_channel_pattern ]]; then
		log_error "Invalid channel: $channel. Valid channels: $VALID_CHANNELS"
		return 1
	fi

	init_entity_db

	local esc_id esc_channel_id esc_display
	esc_id=$(sql_escape "$entity_id")
	esc_channel_id=$(sql_escape "$channel_id")
	esc_display=$(sql_escape "$display_name")

	# Check entity exists
	local exists
	exists=$(entity_db "$ENTITY_MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	# Check if this channel_id is already linked to another entity
	local existing_entity
	existing_entity=$(entity_db "$ENTITY_MEMORY_DB" \
		"SELECT entity_id FROM entity_channels WHERE channel = '$channel' AND channel_id = '$esc_channel_id';" 2>/dev/null || echo "")
	if [[ -n "$existing_entity" && "$existing_entity" != "$entity_id" ]]; then
		log_error "Channel identity $channel:$channel_id is already linked to entity $existing_entity"
		log_error "Unlink it first with: entity-helper.sh unlink $existing_entity --channel $channel --channel-id \"$channel_id\""
		return 1
	fi

	local confidence="suggested"
	local verified_at="NULL"
	if [[ "$verified" == true ]]; then
		confidence="confirmed"
		verified_at="strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
	fi

	entity_db "$ENTITY_MEMORY_DB" <<EOF
INSERT INTO entity_channels (entity_id, channel, channel_id, display_name, confidence, verified_at)
VALUES ('$esc_id', '$channel', '$esc_channel_id', '$esc_display', '$confidence', $verified_at)
ON CONFLICT(channel, channel_id) DO UPDATE SET
    entity_id = '$esc_id',
    display_name = CASE WHEN '$esc_display' != '' THEN '$esc_display' ELSE entity_channels.display_name END,
    confidence = '$confidence',
    verified_at = $verified_at;
EOF

	log_success "Linked $channel:$channel_id -> entity $entity_id ($confidence)"
	return 0
}

#######################################
# Unlink an entity from a channel identity
#######################################
cmd_unlink() {
	local entity_id="${1:-}"
	local channel=""
	local channel_id=""

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel)
			channel="$2"
			shift 2
			;;
		--channel-id)
			channel_id="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" || -z "$channel" || -z "$channel_id" ]]; then
		log_error "Usage: entity-helper.sh unlink <entity_id> --channel <type> --channel-id <id>"
		return 1
	fi

	init_entity_db

	local esc_id esc_channel_id
	esc_id=$(sql_escape "$entity_id")
	esc_channel_id=$(sql_escape "$channel_id")

	local deleted
	deleted=$(
		entity_db "$ENTITY_MEMORY_DB" <<EOF
DELETE FROM entity_channels
WHERE entity_id = '$esc_id' AND channel = '$channel' AND channel_id = '$esc_channel_id';
SELECT changes();
EOF
	)

	if [[ "$deleted" == "0" ]]; then
		log_warn "No matching link found for $channel:$channel_id on entity $entity_id"
		return 0
	fi

	log_success "Unlinked $channel:$channel_id from entity $entity_id"
	return 0
}

#######################################
# Suggest entity matches for a channel identity
# Identity resolution: suggest, don't assume
#######################################
cmd_suggest() {
	local channel="${1:-}"
	local channel_id="${2:-}"

	if [[ -z "$channel" || -z "$channel_id" ]]; then
		log_error "Usage: entity-helper.sh suggest <channel> <channel_id>"
		return 1
	fi

	init_entity_db

	local esc_channel_id
	esc_channel_id=$(sql_escape "$channel_id")

	# 1. Exact match on channel_id
	local exact_match
	exact_match=$(
		entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT e.id, e.name, e.type, ec.confidence, ec.channel
FROM entities e
JOIN entity_channels ec ON e.id = ec.entity_id
WHERE ec.channel = '$channel' AND ec.channel_id = '$esc_channel_id';
EOF
	)

	if [[ -n "$exact_match" && "$exact_match" != "[]" ]]; then
		echo "Exact match found:"
		echo "$exact_match"
		return 0
	fi

	# 2. Fuzzy match: look for similar channel_ids or display names
	local suggestions
	suggestions=$(
		entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT DISTINCT e.id, e.name, e.type, ec.channel, ec.channel_id, ec.confidence,
    'channel_id_similar' as match_type
FROM entities e
JOIN entity_channels ec ON e.id = ec.entity_id
WHERE ec.channel_id LIKE '%${esc_channel_id}%'
   OR ec.display_name LIKE '%${esc_channel_id}%'
UNION
SELECT DISTINCT e.id, e.name, e.type, '' as channel, '' as channel_id, '' as confidence,
    'name_similar' as match_type
FROM entities e
WHERE e.name LIKE '%${esc_channel_id}%'
   OR e.aliases LIKE '%${esc_channel_id}%'
LIMIT 10;
EOF
	)

	if [[ -z "$suggestions" || "$suggestions" == "[]" ]]; then
		log_info "No matching entities found for $channel:$channel_id"
		log_info "Create one with: entity-helper.sh create --name \"Name\" --channel $channel --channel-id \"$channel_id\""
		return 0
	fi

	echo "Suggested matches for $channel:$channel_id:"
	echo "$suggestions"
	echo ""
	log_info "To link: entity-helper.sh link <entity_id> --channel $channel --channel-id \"$channel_id\" --verified"
	return 0
}

#######################################
# Verify a channel link (upgrade confidence to confirmed)
#######################################
cmd_verify() {
	local entity_id="${1:-}"
	local channel=""
	local channel_id=""

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel)
			channel="$2"
			shift 2
			;;
		--channel-id)
			channel_id="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" || -z "$channel" || -z "$channel_id" ]]; then
		log_error "Usage: entity-helper.sh verify <entity_id> --channel <type> --channel-id <id>"
		return 1
	fi

	init_entity_db

	local esc_id esc_channel_id
	esc_id=$(sql_escape "$entity_id")
	esc_channel_id=$(sql_escape "$channel_id")

	entity_db "$ENTITY_MEMORY_DB" <<EOF
UPDATE entity_channels
SET confidence = 'confirmed',
    verified_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE entity_id = '$esc_id'
  AND channel = '$channel'
  AND channel_id = '$esc_channel_id';
EOF

	local changes
	changes=$(entity_db "$ENTITY_MEMORY_DB" "SELECT changes();")
	if [[ "$changes" == "0" ]]; then
		log_warn "No matching link found to verify"
		return 0
	fi

	log_success "Verified $channel:$channel_id for entity $entity_id"
	return 0
}

#######################################
# List channels for an entity
#######################################
cmd_channels() {
	local entity_id="${1:-}"
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

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh channels <entity_id>"
		return 1
	fi

	init_entity_db

	local esc_id
	esc_id=$(sql_escape "$entity_id")

	if [[ "$format" == "json" ]]; then
		entity_db -json "$ENTITY_MEMORY_DB" \
			"SELECT * FROM entity_channels WHERE entity_id = '$esc_id' ORDER BY channel;"
	else
		echo ""
		echo "=== Channels for $entity_id ==="
		echo ""
		entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT channel || ': ' || channel_id ||
    ' [' || confidence || ']' ||
    CASE WHEN verified_at IS NOT NULL THEN ' (verified: ' || verified_at || ')' ELSE '' END
FROM entity_channels
WHERE entity_id = '$esc_id'
ORDER BY channel;
EOF
	fi

	return 0
}

#######################################
# Get current entity profile (latest version of each key)
#######################################
cmd_profile() {
	local entity_id="${1:-}"
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

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh profile <entity_id>"
		return 1
	fi

	init_entity_db

	local esc_id
	esc_id=$(sql_escape "$entity_id")

	# Get latest version of each profile key (not superseded by anything)
	if [[ "$format" == "json" ]]; then
		entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT ep.id, ep.profile_key, ep.profile_value, ep.evidence, ep.confidence, ep.created_at
FROM entity_profiles ep
WHERE ep.entity_id = '$esc_id'
  AND ep.id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY ep.profile_key;
EOF
	else
		echo ""
		echo "=== Profile: $entity_id ==="
		echo ""

		local entity_name
		entity_name=$(entity_db "$ENTITY_MEMORY_DB" "SELECT name FROM entities WHERE id = '$esc_id';" 2>/dev/null || echo "Unknown")
		echo "Entity: $entity_name"
		echo ""

		local profiles
		profiles=$(
			entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT ep.profile_key || ': ' || ep.profile_value ||
    ' [' || ep.confidence || ']' ||
    CASE WHEN ep.evidence != '' THEN char(10) || '  Evidence: ' || ep.evidence ELSE '' END
FROM entity_profiles ep
WHERE ep.entity_id = '$esc_id'
  AND ep.id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY ep.profile_key;
EOF
		)

		if [[ -z "$profiles" ]]; then
			echo "  (no profile entries yet)"
		else
			echo "$profiles"
		fi
	fi

	return 0
}

#######################################
# Update entity profile (versioned — creates new entry, supersedes old)
#######################################
cmd_profile_update() {
	local entity_id="${1:-}"
	local key=""
	local value=""
	local evidence=""
	local confidence="medium"

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--key)
			key="$2"
			shift 2
			;;
		--value)
			value="$2"
			shift 2
			;;
		--evidence)
			evidence="$2"
			shift 2
			;;
		--confidence)
			confidence="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" || -z "$key" || -z "$value" ]]; then
		log_error "Usage: entity-helper.sh profile-update <entity_id> --key \"pref\" --value \"value\""
		return 1
	fi

	if [[ ! "$confidence" =~ ^(high|medium|low)$ ]]; then
		log_error "Invalid confidence: $confidence (use high, medium, or low)"
		return 1
	fi

	init_entity_db

	local esc_id esc_key esc_value esc_evidence
	esc_id=$(sql_escape "$entity_id")
	esc_key=$(sql_escape "$key")
	esc_value=$(sql_escape "$value")
	esc_evidence=$(sql_escape "$evidence")

	# Check entity exists
	local exists
	exists=$(entity_db "$ENTITY_MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	# Find current version of this key (if any) to supersede
	local current_id
	current_id=$(
		entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT ep.id FROM entity_profiles ep
WHERE ep.entity_id = '$esc_id'
  AND ep.profile_key = '$esc_key'
  AND ep.id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
LIMIT 1;
EOF
	)

	local new_id
	new_id=$(generate_profile_id)

	local supersedes_clause="NULL"
	if [[ -n "$current_id" ]]; then
		supersedes_clause="'$(sql_escape "$current_id")'"
	fi

	entity_db "$ENTITY_MEMORY_DB" <<EOF
INSERT INTO entity_profiles (id, entity_id, profile_key, profile_value, evidence, confidence, supersedes_id)
VALUES ('$new_id', '$esc_id', '$esc_key', '$esc_value', '$esc_evidence', '$confidence', $supersedes_clause);
EOF

	# Update entity's updated_at
	entity_db "$ENTITY_MEMORY_DB" \
		"UPDATE entities SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '$esc_id';"

	if [[ -n "$current_id" ]]; then
		log_success "Updated profile: $key (supersedes $current_id)"
	else
		log_success "Created profile entry: $key"
	fi
	echo "$new_id"
	return 0
}

#######################################
# Show profile version history for an entity
#######################################
cmd_profile_history() {
	local entity_id="${1:-}"

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh profile-history <entity_id>"
		return 1
	fi

	init_entity_db

	local esc_id
	esc_id=$(sql_escape "$entity_id")

	echo ""
	echo "=== Profile History: $entity_id ==="
	echo ""

	entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT ep.profile_key || ': ' || ep.profile_value ||
    ' [' || ep.confidence || '] ' || ep.created_at ||
    CASE WHEN ep.supersedes_id IS NOT NULL THEN ' (supersedes ' || ep.supersedes_id || ')' ELSE ' (original)' END ||
    CASE WHEN ep.id NOT IN (SELECT COALESCE(supersedes_id, '') FROM entity_profiles) THEN ' <- CURRENT' ELSE '' END
FROM entity_profiles ep
WHERE ep.entity_id = '$esc_id'
ORDER BY ep.profile_key, ep.created_at DESC;
EOF

	return 0
}

#######################################
# Log an interaction (Layer 0 — immutable)
#######################################
cmd_log_interaction() {
	local entity_id="${1:-}"
	local channel=""
	local channel_id=""
	local content=""
	local direction="inbound"
	local conversation_id=""
	local metadata="{}"

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel)
			channel="$2"
			shift 2
			;;
		--channel-id)
			channel_id="$2"
			shift 2
			;;
		--content)
			content="$2"
			shift 2
			;;
		--direction)
			direction="$2"
			shift 2
			;;
		--conversation-id)
			conversation_id="$2"
			shift 2
			;;
		--metadata)
			metadata="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" || -z "$channel" || -z "$content" ]]; then
		log_error "Usage: entity-helper.sh log-interaction <entity_id> --channel <type> --content \"message\""
		return 1
	fi

	local log_channel_pattern=" $channel "
	if [[ ! " $VALID_CHANNELS " =~ $log_channel_pattern ]]; then
		log_error "Invalid channel: $channel. Valid channels: $VALID_CHANNELS"
		return 1
	fi

	local direction_pattern=" $direction "
	if [[ ! " $VALID_DIRECTIONS " =~ $direction_pattern ]]; then
		log_error "Invalid direction: $direction. Valid: $VALID_DIRECTIONS"
		return 1
	fi

	# Privacy filter: strip <private>...</private> blocks
	content=$(echo "$content" | sed 's/<private>[^<]*<\/private>//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

	# Privacy filter: reject content that looks like secrets
	if echo "$content" | grep -qE '(sk-[a-zA-Z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36})'; then
		log_error "Content appears to contain secrets. Refusing to log."
		return 1
	fi

	if [[ -z "$content" ]]; then
		log_warn "Content is empty after privacy filtering. Skipping."
		return 0
	fi

	init_entity_db

	local esc_id esc_channel_id esc_content esc_conv_id esc_metadata
	esc_id=$(sql_escape "$entity_id")
	esc_channel_id=$(sql_escape "$channel_id")
	esc_content=$(sql_escape "$content")
	esc_conv_id=$(sql_escape "$conversation_id")
	esc_metadata=$(sql_escape "$metadata")

	# Check entity exists
	local exists
	exists=$(entity_db "$ENTITY_MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	local int_id
	int_id=$(generate_interaction_id)

	local conv_clause="NULL"
	if [[ -n "$conversation_id" ]]; then
		conv_clause="'$esc_conv_id'"
	fi

	entity_db "$ENTITY_MEMORY_DB" <<EOF
INSERT INTO interactions (id, entity_id, channel, channel_id, conversation_id, direction, content, metadata)
VALUES ('$int_id', '$esc_id', '$channel', '$esc_channel_id', $conv_clause, '$direction', '$esc_content', '$esc_metadata');
EOF

	# Update FTS index
	entity_db "$ENTITY_MEMORY_DB" <<EOF
INSERT INTO interactions_fts (id, entity_id, content, channel, created_at)
VALUES ('$int_id', '$esc_id', '$esc_content', '$channel', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
EOF

	# Update conversation if linked
	if [[ -n "$conversation_id" ]]; then
		entity_db "$ENTITY_MEMORY_DB" <<EOF
UPDATE conversations SET
    interaction_count = interaction_count + 1,
    last_interaction_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$esc_conv_id';
EOF
	fi

	# Update entity's updated_at
	entity_db "$ENTITY_MEMORY_DB" \
		"UPDATE entities SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '$esc_id';"

	echo "$int_id"
	return 0
}

#######################################
# Load context for an entity (privacy-filtered)
#######################################
cmd_context() {
	local entity_id="${1:-}"
	local channel_filter=""
	local limit=20
	local privacy_filter=false
	local format="text"

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel)
			channel_filter="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--privacy-filter)
			privacy_filter=true
			shift
			;;
		--json)
			format="json"
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh context <entity_id>"
		return 1
	fi

	init_entity_db

	local esc_id
	esc_id=$(sql_escape "$entity_id")

	# Build channel filter
	local channel_clause=""
	if [[ -n "$channel_filter" ]]; then
		channel_clause="AND i.channel = '$(sql_escape "$channel_filter")'"
	fi

	if [[ "$format" == "json" ]]; then
		# Entity info + profile + recent interactions
		echo "{"

		# Entity
		echo "\"entity\":"
		entity_db -json "$ENTITY_MEMORY_DB" "SELECT * FROM entities WHERE id = '$esc_id';"
		echo ","

		# Channels
		echo "\"channels\":"
		entity_db -json "$ENTITY_MEMORY_DB" "SELECT * FROM entity_channels WHERE entity_id = '$esc_id';"
		echo ","

		# Current profile
		echo "\"profile\":"
		entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT profile_key, profile_value, confidence FROM entity_profiles
WHERE entity_id = '$esc_id'
  AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY profile_key;
EOF
		echo ","

		# Recent interactions
		echo "\"recent_interactions\":"
		entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT i.id, i.channel, i.direction, i.content, i.created_at
FROM interactions i
WHERE i.entity_id = '$esc_id' $channel_clause
ORDER BY i.created_at DESC
LIMIT $limit;
EOF

		echo "}"
	else
		echo ""
		echo "=== Context: $entity_id ==="
		echo ""

		# Entity info
		entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT 'Entity: ' || name || ' (' || type || ')' || char(10) ||
       'Channels: ' || (SELECT GROUP_CONCAT(channel || ':' || channel_id, ', ') FROM entity_channels WHERE entity_id = '$esc_id')
FROM entities WHERE id = '$esc_id';
EOF

		# Profile summary
		echo ""
		echo "Profile:"
		local profile_data
		profile_data=$(
			entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT '  ' || profile_key || ': ' || profile_value
FROM entity_profiles
WHERE entity_id = '$esc_id'
  AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY profile_key;
EOF
		)
		if [[ -z "$profile_data" ]]; then
			echo "  (no profile data)"
		else
			echo "$profile_data"
		fi

		# Recent interactions
		echo ""
		echo "Recent interactions (last $limit):"
		local interactions
		interactions=$(
			entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT '  [' || i.direction || '] ' || i.channel || ' ' || i.created_at || char(10) ||
       '    ' || substr(i.content, 1, 120) ||
       CASE WHEN length(i.content) > 120 THEN '...' ELSE '' END
FROM interactions i
WHERE i.entity_id = '$esc_id' $channel_clause
ORDER BY i.created_at DESC
LIMIT $limit;
EOF
		)

		if [[ -z "$interactions" ]]; then
			echo "  (no interactions)"
		else
			if [[ "$privacy_filter" == true ]]; then
				# Apply privacy filtering to output
				interactions=$(echo "$interactions" | sed 's/[a-zA-Z0-9._%+-]\+@[a-zA-Z0-9.-]\+\.[a-zA-Z]\{2,\}/[EMAIL]/g')
				interactions=$(echo "$interactions" | sed 's/\b[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\b/[IP]/g')
				interactions=$(echo "$interactions" | sed 's/sk-[a-zA-Z0-9_-]\{20,\}/[API_KEY]/g')
			fi
			echo "$interactions"
		fi
	fi

	return 0
}

#######################################
# Show entity system statistics
#######################################
cmd_stats() {
	init_entity_db

	echo ""
	echo "=== Entity Memory Statistics ==="
	echo ""

	entity_db "$ENTITY_MEMORY_DB" <<'EOF'
SELECT 'Total entities' as metric, COUNT(*) as value FROM entities
UNION ALL
SELECT 'By type: ' || type, COUNT(*) FROM entities GROUP BY type
UNION ALL
SELECT 'Channel links', COUNT(*) FROM entity_channels
UNION ALL
SELECT 'Verified links', COUNT(*) FROM entity_channels WHERE confidence = 'confirmed'
UNION ALL
SELECT 'Total interactions', COUNT(*) FROM interactions
UNION ALL
SELECT 'Active conversations', COUNT(*) FROM conversations WHERE status = 'active'
UNION ALL
SELECT 'Profile entries', COUNT(*) FROM entity_profiles
UNION ALL
SELECT 'Capability gaps', COUNT(*) FROM capability_gaps WHERE status = 'detected';
EOF

	echo ""

	# Channel distribution
	echo "Channel distribution:"
	entity_db "$ENTITY_MEMORY_DB" <<'EOF'
SELECT '  ' || channel || ': ' || COUNT(*) || ' links'
FROM entity_channels
GROUP BY channel
ORDER BY COUNT(*) DESC;
EOF

	echo ""

	# Interaction volume
	echo "Interaction volume:"
	entity_db "$ENTITY_MEMORY_DB" <<'EOF'
SELECT
    CASE
        WHEN created_at >= datetime('now', '-1 days') THEN '  Last 24h'
        WHEN created_at >= datetime('now', '-7 days') THEN '  Last 7 days'
        WHEN created_at >= datetime('now', '-30 days') THEN '  Last 30 days'
        ELSE '  Older'
    END as period,
    COUNT(*) as count
FROM interactions
GROUP BY 1
ORDER BY 1;
EOF

	return 0
}

#######################################
# Run schema migration (idempotent)
#######################################
cmd_migrate() {
	log_info "Running entity schema migration..."

	# Backup before migration
	if [[ -f "$ENTITY_MEMORY_DB" ]]; then
		local backup
		backup=$(backup_sqlite_db "$ENTITY_MEMORY_DB" "pre-entity-migrate")
		if [[ $? -ne 0 || -z "$backup" ]]; then
			log_warn "Backup failed before entity migration — proceeding cautiously"
		else
			log_info "Pre-migration backup: $backup"
		fi
	fi

	init_entity_db

	log_success "Entity schema migration complete"

	# Show table status
	entity_db "$ENTITY_MEMORY_DB" <<'EOF'
SELECT 'entities: ' || (SELECT COUNT(*) FROM entities) || ' rows' ||
    char(10) || 'entity_channels: ' || (SELECT COUNT(*) FROM entity_channels) || ' rows' ||
    char(10) || 'interactions: ' || (SELECT COUNT(*) FROM interactions) || ' rows' ||
    char(10) || 'conversations: ' || (SELECT COUNT(*) FROM conversations) || ' rows' ||
    char(10) || 'entity_profiles: ' || (SELECT COUNT(*) FROM entity_profiles) || ' rows' ||
    char(10) || 'capability_gaps: ' || (SELECT COUNT(*) FROM capability_gaps) || ' rows' ||
    char(10) || 'interactions_fts: ' || (SELECT COUNT(*) FROM interactions_fts) || ' rows';
EOF

	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
entity-helper.sh - Entity memory system for aidevops

Part of the conversational memory system (p035 / t1363).
Manages entities (people, agents, services) with cross-channel identity,
versioned profiles, and privacy-filtered context loading.

USAGE:
    entity-helper.sh <command> [options]

ENTITY CRUD:
    create          Create a new entity
    get <id>        Get entity details
    list            List all entities
    update <id>     Update entity fields
    delete <id>     Delete entity (requires --confirm)
    search          Search entities by name/alias

IDENTITY LINKING:
    link <id>       Link entity to a channel identity
    unlink <id>     Remove a channel link
    suggest         Suggest entity matches for a channel identity
    verify <id>     Verify a channel link (upgrade to confirmed)
    channels <id>   List channels for an entity

PROFILES (versioned):
    profile <id>            Show current profile
    profile-update <id>     Add/update a profile entry (creates new version)
    profile-history <id>    Show profile version history

INTERACTIONS:
    log-interaction <id>    Log a raw interaction (Layer 0)
    context <id>            Load entity context (privacy-filtered)

SYSTEM:
    stats           Show entity system statistics
    migrate         Run schema migration (idempotent)
    help            Show this help

CREATE OPTIONS:
    --name <name>           Entity name (required)
    --type <type>           person, agent, or service (default: person)
    --display-name <name>   Display name
    --aliases <list>        Comma-separated aliases
    --notes <text>          Free-form notes
    --channel <type>        Initial channel type
    --channel-id <id>       Initial channel identifier

LINK OPTIONS:
    --channel <type>        Channel type (matrix, simplex, email, cli, etc.)
    --channel-id <id>       Channel-specific identifier
    --display-name <name>   Display name on this channel
    --verified              Mark as confirmed (default: suggested)

PROFILE-UPDATE OPTIONS:
    --key <key>             Profile attribute name (required)
    --value <value>         Profile attribute value (required)
    --evidence <text>       Evidence for this observation
    --confidence <level>    high, medium, or low (default: medium)

LOG-INTERACTION OPTIONS:
    --channel <type>        Channel type (required)
    --channel-id <id>       Channel identifier
    --content <text>        Message content (required)
    --direction <dir>       inbound, outbound, or system (default: inbound)
    --conversation-id <id>  Link to a conversation
    --metadata <json>       Additional metadata as JSON

CONTEXT OPTIONS:
    --channel <type>        Filter by channel
    --limit <n>             Max interactions to show (default: 20)
    --privacy-filter        Redact emails, IPs, API keys in output
    --json                  Output as JSON

ARCHITECTURE:
    Layer 0: Raw interaction log (immutable, append-only)
             Every message across all channels — source of truth
    Layer 1: Per-conversation context (tactical summaries)
             Active threads per entity+channel
    Layer 2: Entity relationship model (strategic profiles)
             Cross-channel identity, versioned preferences, capability gaps

EXAMPLES:
    # Create an entity with initial channel link
    entity-helper.sh create --name "Marcus" --type person \
        --channel matrix --channel-id "@marcus:server.com"

    # Link additional channel
    entity-helper.sh link ent_xxx --channel email \
        --channel-id "marcus@example.com" --verified

    # Suggest matches for unknown identity
    entity-helper.sh suggest simplex "~user123"

    # Update profile (versioned)
    entity-helper.sh profile-update ent_xxx \
        --key "communication_style" --value "prefers concise responses" \
        --evidence "observed across 5 conversations"

    # Log an interaction
    entity-helper.sh log-interaction ent_xxx \
        --channel matrix --content "How's the deployment going?"

    # Load context for an entity (privacy-filtered)
    entity-helper.sh context ent_xxx --privacy-filter --limit 10
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
	get) cmd_get "$@" ;;
	list) cmd_list "$@" ;;
	update) cmd_update "$@" ;;
	delete) cmd_delete "$@" ;;
	search) cmd_search "$@" ;;
	link) cmd_link "$@" ;;
	unlink) cmd_unlink "$@" ;;
	suggest) cmd_suggest "$@" ;;
	verify) cmd_verify "$@" ;;
	channels) cmd_channels "$@" ;;
	profile) cmd_profile "$@" ;;
	profile-update) cmd_profile_update "$@" ;;
	profile-history) cmd_profile_history "$@" ;;
	log-interaction) cmd_log_interaction "$@" ;;
	context) cmd_context "$@" ;;
	stats) cmd_stats ;;
	migrate) cmd_migrate ;;
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
