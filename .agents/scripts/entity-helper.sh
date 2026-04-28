#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2329
# SC2329: Library functions (e.g. generate_conversation_id) are exported for
#         callers that source this script; not all are invoked internally
#
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

# Confidence levels for identity links: validated by SQL CHECK constraint
# in entity_channels table (confirmed, suggested, inferred)

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
# Apply core entity and channel table DDL.
# Layer 2 (entities) and cross-channel identity tables.
# Idempotent — all statements use IF NOT EXISTS.
#######################################
_init_entity_db_schema_core() {
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
SCHEMA
	return 0
}

#######################################
# Apply interaction, conversation, profile, gap, and FTS DDL.
# Layers 0 and 1 plus versioned profiles and capability gaps.
# Idempotent — all statements use IF NOT EXISTS.
#######################################
_init_entity_db_schema_interactions() {
	entity_db "$ENTITY_MEMORY_DB" <<'SCHEMA'
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
# Apply all entity schema DDL to the database.
# Delegates to _init_entity_db_schema_core and
# _init_entity_db_schema_interactions for size compliance.
# Idempotent — safe to call multiple times.
#######################################
_init_entity_db_schema() {
	_init_entity_db_schema_core
	_init_entity_db_schema_interactions
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

	_init_entity_db_schema

	return 0
}

#######################################
# SQL-escape a value (double single quotes)
#######################################
sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

#######################################
# Normalize channel identifier for storage/lookup
# Email addresses are case-insensitive and often include plus aliases.
#######################################
normalize_channel_id() {
	local channel="$1"
	local channel_id="$2"

	if [[ "$channel" != "email" ]]; then
		echo "$channel_id"
		return 0
	fi

	local normalized
	normalized=$(printf '%s' "$channel_id" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]')

	if [[ "$normalized" != *"@"* ]]; then
		echo "$normalized"
		return 0
	fi

	local local_part
	local_part="${normalized%@*}"
	local_part="${local_part%%+*}"
	local domain_part
	domain_part="${normalized#*@}"

	echo "${local_part}@${domain_part}"
	return 0
}

#######################################
# Resolve email identity against historical non-normalized entries
#######################################
resolve_email_entity_fallback() {
	local normalized_email="$1"
	local result=""

	local rows
	rows=$(entity_db "$ENTITY_MEMORY_DB" "SELECT entity_id || '|' || channel_id FROM entity_channels WHERE channel = 'email';")
	if [[ -z "$rows" ]]; then
		return 1
	fi

	while IFS='|' read -r candidate_entity candidate_channel_id; do
		if [[ -z "$candidate_entity" || -z "$candidate_channel_id" ]]; then
			continue
		fi

		local normalized_candidate
		normalized_candidate=$(normalize_channel_id "email" "$candidate_channel_id")
		if [[ "$normalized_candidate" == "$normalized_email" ]]; then
			result="$candidate_entity"
			break
		fi
	done <<<"$rows"

	if [[ -z "$result" ]]; then
		return 1
	fi

	echo "$result"
	return 0
}

# =============================================================================
# Sub-library loading
# =============================================================================

# shellcheck source=./entity-crud-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/entity-crud-lib.sh"

# shellcheck source=./entity-channel-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/entity-channel-lib.sh"

# shellcheck source=./entity-interaction-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/entity-interaction-lib.sh"

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
	resolve) cmd_resolve "$@" ;;
	profile) cmd_profile "$@" ;;
	get-profile) cmd_get_profile "$@" ;;
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
