#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Conversation Helper -- Orchestrator
# =============================================================================
# Conversation lifecycle management for aidevops.
# Manages conversation lifecycle (create/resume/archive/close), context loading
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
# This is the thin orchestrator. Implementation lives in sub-libraries:
#   - conversation-helper-lifecycle.sh    (create/resume/archive/close/get/list)
#   - conversation-helper-context.sh      (context loading + summarisation)
#   - conversation-helper-interaction.sh  (idle check + tone + messaging)
#   - conversation-helper-admin.sh        (migrate/stats/help)
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
	return $?
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

# --- Source sub-libraries ---

# shellcheck source=./conversation-helper-lifecycle.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/conversation-helper-lifecycle.sh"

# shellcheck source=./conversation-helper-context.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/conversation-helper-context.sh"

# shellcheck source=./conversation-helper-interaction.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/conversation-helper-interaction.sh"

# shellcheck source=./conversation-helper-admin.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/conversation-helper-admin.sh"

# --- Main entry point ---

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
