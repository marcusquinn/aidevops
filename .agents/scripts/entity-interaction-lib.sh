#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Entity Interaction Library -- Interactions / Context / Stats / Help
# =============================================================================
# Interaction logging, context loading, statistics, migration, identity
# resolution, and help commands for the entity memory system (p035 / t1363).
#
# Usage: source "${SCRIPT_DIR}/entity-interaction-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error, log_warn, log_success, log_info)
#   - entity-helper.sh (entity_db, generate_interaction_id, sql_escape,
#     normalize_channel_id, resolve_email_entity_fallback, init_entity_db,
#     backup_sqlite_db, ENTITY_MEMORY_DB, VALID_CHANNELS, VALID_DIRECTIONS)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ENTITY_INTERACTION_LIB_LOADED:-}" ]] && return 0
_ENTITY_INTERACTION_LIB_LOADED=1

# SCRIPT_DIR fallback — required when sourced from a directory other than SCRIPT_DIR
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Interaction Logging (Layer 0)
# =============================================================================

#######################################
# Validate and privacy-filter interaction content.
# Prints filtered content to stdout; returns 1 on rejection.
# Args: content channel direction
#######################################
_log_interaction_validate() {
	local content="$1"
	local channel="$2"
	local direction="$3"

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
		return 2
	fi

	echo "$content"
	return 0
}

#######################################
# Write a validated interaction to the database.
# Updates interactions, FTS index, conversation, and entity timestamps.
# Args: esc_id channel esc_channel_id conv_clause direction esc_content esc_metadata esc_conv_id conversation_id
#######################################
_log_interaction_write() {
	local esc_id="$1"
	local channel="$2"
	local esc_channel_id="$3"
	local conv_clause="$4"
	local direction="$5"
	local esc_content="$6"
	local esc_metadata="$7"
	local esc_conv_id="$8"
	local conversation_id="$9"

	local int_id
	int_id=$(generate_interaction_id)

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

	local filtered_content
	filtered_content=$(_log_interaction_validate "$content" "$channel" "$direction")
	local validate_rc=$?
	if [[ $validate_rc -eq 1 ]]; then
		return 1
	elif [[ $validate_rc -eq 2 ]]; then
		return 0
	fi
	content="$filtered_content"

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

	local conv_clause="NULL"
	if [[ -n "$conversation_id" ]]; then
		conv_clause="'$esc_conv_id'"
	fi

	_log_interaction_write \
		"$esc_id" "$channel" "$esc_channel_id" "$conv_clause" \
		"$direction" "$esc_content" "$esc_metadata" "$esc_conv_id" "$conversation_id"
	return $?
}

# =============================================================================
# Context Loading
# =============================================================================

#######################################
# Emit JSON context for an entity (entity + channels + profile + interactions).
# Args: esc_id channel_clause limit
#######################################
_context_json() {
	local esc_id="$1"
	local channel_clause="$2"
	local limit="$3"

	echo "{"

	echo "\"entity\":"
	entity_db -json "$ENTITY_MEMORY_DB" "SELECT * FROM entities WHERE id = '$esc_id';"
	echo ","

	echo "\"channels\":"
	entity_db -json "$ENTITY_MEMORY_DB" "SELECT * FROM entity_channels WHERE entity_id = '$esc_id';"
	echo ","

	echo "\"profile\":"
	entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT profile_key, profile_value, confidence FROM entity_profiles
WHERE entity_id = '$esc_id'
  AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY profile_key;
EOF
	echo ","

	echo "\"recent_interactions\":"
	entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT i.id, i.channel, i.direction, i.content, i.created_at
FROM interactions i
WHERE i.entity_id = '$esc_id' $channel_clause
ORDER BY i.created_at DESC
LIMIT $limit;
EOF

	echo "}"
	return 0
}

#######################################
# Emit human-readable context for an entity.
# Args: entity_id esc_id channel_clause limit privacy_filter
#######################################
_context_text() {
	local entity_id="$1"
	local esc_id="$2"
	local channel_clause="$3"
	local limit="$4"
	local privacy_filter="$5"

	echo ""
	echo "=== Context: $entity_id ==="
	echo ""

	entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT 'Entity: ' || name || ' (' || type || ')' || char(10) ||
       'Channels: ' || (SELECT GROUP_CONCAT(channel || ':' || channel_id, ', ') FROM entity_channels WHERE entity_id = '$esc_id')
FROM entities WHERE id = '$esc_id';
EOF

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
			# Apply privacy filtering to output (sed required: regex quantifiers/char classes/word boundaries)
			interactions=$(sed \
				-e 's/[a-zA-Z0-9._%+-]\+@[a-zA-Z0-9.-]\+\.[a-zA-Z]\{2,\}/[EMAIL]/g' \
				-e 's/\b[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\b/[IP]/g' \
				-e 's/sk-[a-zA-Z0-9_-]\{20,\}/[API_KEY]/g' <<<"$interactions")
		fi
		echo "$interactions"
	fi
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

	local channel_clause=""
	if [[ -n "$channel_filter" ]]; then
		channel_clause="AND i.channel = '$(sql_escape "$channel_filter")'"
	fi

	if [[ "$format" == "json" ]]; then
		_context_json "$esc_id" "$channel_clause" "$limit"
	else
		_context_text "$entity_id" "$esc_id" "$channel_clause" "$limit" "$privacy_filter"
	fi

	return 0
}

# =============================================================================
# System Commands
# =============================================================================

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
# Resolve an entity by channel + channel_id (t1363.6)
# Used by integrations (e.g., matrix bot) to find which entity
# is associated with a given channel identity.
# Returns entity JSON on stdout, or exits 1 if not found.
#######################################
cmd_resolve() {
	local channel=""
	local channel_id=""
	local format="json"

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
		--json)
			format="json"
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$channel" || -z "$channel_id" ]]; then
		log_error "Usage: entity-helper.sh resolve --channel <type> --channel-id <id>"
		return 1
	fi

	init_entity_db

	local esc_channel
	esc_channel=$(sql_escape "$channel")
	channel_id=$(normalize_channel_id "$channel" "$channel_id")
	local esc_channel_id
	esc_channel_id=$(sql_escape "$channel_id")

	local entity_id
	entity_id=$(entity_db "$ENTITY_MEMORY_DB" \
		"SELECT entity_id FROM entity_channels WHERE channel = '$esc_channel' AND channel_id = '$esc_channel_id' LIMIT 1;" \
		2>/dev/null || echo "")

	if [[ -z "$entity_id" && "$channel" == "email" ]]; then
		entity_id=$(resolve_email_entity_fallback "$channel_id" 2>/dev/null || true)
	fi

	if [[ -z "$entity_id" ]]; then
		return 1
	fi

	# Return entity details as JSON
	entity_db -json "$ENTITY_MEMORY_DB" \
		"SELECT * FROM entities WHERE id = '$entity_id';"

	return 0
}

#######################################
# Get a specific profile key for an entity (t1363.6)
# Returns the current (non-superseded) value for the given key.
# Used by integrations to look up specific preferences.
#######################################
cmd_get_profile() {
	local entity_id="${1:-}"
	local key=""
	local format="text"

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--key)
			key="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" || -z "$key" ]]; then
		log_error "Usage: entity-helper.sh get-profile <entity_id> --key <profile_key>"
		return 1
	fi

	init_entity_db

	local esc_id
	esc_id=$(sql_escape "$entity_id")
	local esc_key
	esc_key=$(sql_escape "$key")

	if [[ "$format" == "json" ]]; then
		local result
		result=$(
			entity_db -json "$ENTITY_MEMORY_DB" <<EOF
SELECT ep.id, ep.profile_key, ep.profile_value, ep.confidence, ep.created_at
FROM entity_profiles ep
WHERE ep.entity_id = '$esc_id'
  AND ep.profile_key = '$esc_key'
  AND ep.id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY ep.created_at DESC
LIMIT 1;
EOF
		)
		if [[ -z "$result" || "$result" == "[]" ]]; then
			return 1
		fi
		# Return single object, not array
		if command -v jq &>/dev/null; then
			echo "$result" | jq '.[0] // empty'
		else
			echo "$result"
		fi
	else
		local value
		value=$(
			entity_db "$ENTITY_MEMORY_DB" <<EOF
SELECT ep.profile_value
FROM entity_profiles ep
WHERE ep.entity_id = '$esc_id'
  AND ep.profile_key = '$esc_key'
  AND ep.id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY ep.created_at DESC
LIMIT 1;
EOF
		)
		if [[ -z "$value" ]]; then
			return 1
		fi
		echo "$value"
	fi

	return 0
}

# =============================================================================
# Help
# =============================================================================

#######################################
# Print help: commands section
# Extracted from cmd_help for size compliance.
#######################################
_help_commands() {
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
    resolve         Resolve entity by channel + channel_id

PROFILES (versioned):
    profile <id>            Show current profile
    get-profile <id>        Get a specific profile key (for integrations)
    profile-update <id>     Add/update a profile entry (creates new version)
    profile-history <id>    Show profile version history

INTERACTIONS:
    log-interaction <id>    Log a raw interaction (Layer 0)
    context <id>            Load entity context (privacy-filtered)

SYSTEM:
    stats           Show entity system statistics
    migrate         Run schema migration (idempotent)
    help            Show this help
EOF
	return 0
}

#######################################
# Print help: options, architecture, and examples section
# Extracted from cmd_help for size compliance.
#######################################
_help_options() {
	cat <<'EOF'
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

EMAIL RESOLUTION:
    Email channel IDs are normalized on create/link/suggest/resolve/verify/unlink:
    - Trim whitespace and lowercase address
    - Remove plus alias from local part (name+tag@example.com -> name@example.com)

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
# Show help
#######################################
cmd_help() {
	_help_commands
	_help_options
	return 0
}
