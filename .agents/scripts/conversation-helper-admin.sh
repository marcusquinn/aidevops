#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Conversation Admin -- migrate, stats, help
# =============================================================================
# Provides administrative operations for the conversation system:
# schema migration, statistics, and help output. Extracted from
# conversation-helper.sh.
#
# Usage: source "${SCRIPT_DIR}/conversation-helper-admin.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_success, log_warn, backup_sqlite_db)
#   - conversation-helper.sh orchestrator (conv_db, init_conv_db, CONV_MEMORY_DB)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONV_ADMIN_LIB_LOADED:-}" ]] && return 0
_CONV_ADMIN_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

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
# Print command list and option reference sections of help
#######################################
_help_commands_and_options() {
	cat <<'EOF'
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
EOF
	return 0
}

#######################################
# Print architecture, idle detection, summaries, and examples sections of help
#######################################
_help_details_and_examples() {
	cat <<'EOF'
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
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
conversation-helper.sh - Conversation lifecycle management for aidevops

Part of the conversational memory system (p035 / t1363).
Manages Layer 1: per-conversation context with AI-judged idle detection,
immutable summaries, and tone profile extraction.

EOF
	_help_commands_and_options
	echo ""
	_help_details_and_examples
	return 0
}
