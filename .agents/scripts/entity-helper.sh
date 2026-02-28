#!/usr/bin/env bash
# entity-helper.sh - Entity management for multi-channel relationship continuity
# Part of the aidevops memory system (t1363.1)
#
# Provides: entity CRUD, identity resolution (link/unlink/verify/suggest),
# privacy-filtered context loading, interaction logging, profile management.
#
# Uses the same SQLite database (memory.db) as memory-helper.sh — enables
# cross-queries between entity and project memories without cross-DB joins.
#
# Architecture:
#   Layer 0: interactions (immutable raw log, append-only)
#   Layer 1: conversations (per-entity+channel tactical context)
#   Layer 2: entity_profiles (versioned relationship model)
#   Self-evolution: capability_gaps (gap detection -> TODO -> upgrade)
#
# Usage:
#   entity-helper.sh create --name "Name" [--type person] [--privacy standard]
#   entity-helper.sh get <entity_id>
#   entity-helper.sh list [--type person] [--limit 20]
#   entity-helper.sh update <entity_id> --name "New Name" [--privacy sensitive]
#   entity-helper.sh delete <entity_id> [--confirm]
#   entity-helper.sh search --query "search terms" [--limit 10]
#
#   entity-helper.sh link <entity_id> --channel matrix --identifier "@user:server"
#   entity-helper.sh unlink <channel_link_id>
#   entity-helper.sh verify <channel_link_id> [--by "admin"]
#   entity-helper.sh suggest --channel matrix --identifier "@user:server"
#   entity-helper.sh resolve --channel matrix --identifier "@user:server"
#
#   entity-helper.sh context <entity_id> [--privacy-filter standard] [--limit 20]
#   entity-helper.sh profile <entity_id> [--type preference] [--content "..."]
#   entity-helper.sh interact <entity_id> --channel matrix --direction inbound --summary "..."
#
#   entity-helper.sh gap create --description "..." [--entity <id>] [--type missing_feature]
#   entity-helper.sh gap list [--status detected]
#   entity-helper.sh stats

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration — reuse memory system globals
readonly MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
MEMORY_DIR="$MEMORY_BASE_DIR"
MEMORY_DB="$MEMORY_DIR/memory.db"

# Valid entity types
readonly VALID_ENTITY_TYPES="person agent service group"
readonly VALID_CHANNELS="matrix simplex email cli slack discord web sms other"
readonly VALID_PRIVACY_LEVELS="public standard sensitive restricted"
readonly VALID_PROFILE_TYPES="preference need expectation style capability context"
readonly VALID_GAP_TYPES="missing_feature poor_response slow_response wrong_channel knowledge_gap integration_gap"
readonly VALID_GAP_STATUSES="detected todo_created in_progress resolved wont_fix"
readonly VALID_DIRECTIONS="inbound outbound"

# Source memory common utilities (db wrapper, init_db, generate_entity_id, etc.)
# shellcheck source=memory/_common.sh
source "${SCRIPT_DIR}/memory/_common.sh"

#######################################
# SQL-escape a value (double single quotes)
#######################################
_sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

#######################################
# Validate a value is in a space-separated list
#######################################
_validate_in_list() {
	local value="$1"
	local valid_list="$2"
	local field_name="$3"

	local pattern=" $value "
	if [[ ! " $valid_list " =~ $pattern ]]; then
		log_error "Invalid $field_name: '$value'"
		log_error "Valid values: $valid_list"
		return 1
	fi
	return 0
}

#######################################
# Map privacy level to numeric rank for comparison
# public(0) < standard(1) < sensitive(2) < restricted(3)
#######################################
_privacy_rank() {
	local level="$1"
	case "$level" in
	public) echo "0" ;;
	standard) echo "1" ;;
	sensitive) echo "2" ;;
	restricted) echo "3" ;;
	*) echo "1" ;;
	esac
	return 0
}

# =============================================================================
# Entity CRUD
# =============================================================================

#######################################
# Create a new entity
#######################################
cmd_create() {
	local name=""
	local entity_type="person"
	local privacy_level="standard"
	local notes=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name | -n)
			name="$2"
			shift 2
			;;
		--type | -t)
			entity_type="$2"
			shift 2
			;;
		--privacy | -p)
			privacy_level="$2"
			shift 2
			;;
		--notes)
			notes="$2"
			shift 2
			;;
		*)
			if [[ -z "$name" ]]; then name="$1"; fi
			shift
			;;
		esac
	done

	if [[ -z "$name" ]]; then
		log_error "Name is required. Use --name \"Entity Name\""
		return 1
	fi

	_validate_in_list "$entity_type" "$VALID_ENTITY_TYPES" "entity type" || return 1
	_validate_in_list "$privacy_level" "$VALID_PRIVACY_LEVELS" "privacy level" || return 1

	init_db

	local id
	id=$(generate_entity_id "ent")
	local escaped_name
	escaped_name=$(_sql_escape "$name")
	local escaped_notes
	escaped_notes=$(_sql_escape "$notes")

	db "$MEMORY_DB" <<EOF
INSERT INTO entities (id, display_name, entity_type, privacy_level, notes)
VALUES ('$id', '$escaped_name', '$entity_type', '$privacy_level', '$escaped_notes');
EOF

	log_success "Created entity: $id ($name)"
	echo "$id"
	return 0
}

#######################################
# Get entity details
#######################################
cmd_get() {
	local entity_id="$1"

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh get <entity_id>"
		return 1
	fi

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$entity_id")

	# Check entity exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	# Get entity with channel count and interaction count
	db -json "$MEMORY_DB" <<EOF
SELECT
    e.id,
    e.display_name,
    e.entity_type,
    e.privacy_level,
    e.notes,
    e.created_at,
    e.updated_at,
    (SELECT COUNT(*) FROM entity_channels ec WHERE ec.entity_id = e.id) as channel_count,
    (SELECT COUNT(*) FROM interactions i WHERE i.entity_id = e.id) as interaction_count,
    (SELECT COUNT(*) FROM conversations c WHERE c.entity_id = e.id AND c.status = 'active') as active_conversations
FROM entities e
WHERE e.id = '$escaped_id';
EOF

	# Show linked channels
	local channels
	channels=$(db -json "$MEMORY_DB" "SELECT id, channel, channel_identifier, display_name, verified FROM entity_channels WHERE entity_id = '$escaped_id';")
	if [[ -n "$channels" && "$channels" != "[]" ]]; then
		echo ""
		echo "Linked channels:"
		echo "$channels"
	fi

	return 0
}

#######################################
# List entities
#######################################
cmd_list() {
	local entity_type=""
	local limit=20
	local format="json"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type | -t)
			entity_type="$2"
			shift 2
			;;
		--limit | -l)
			limit="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		*) shift ;;
		esac
	done

	init_db

	local type_filter=""
	if [[ -n "$entity_type" ]]; then
		_validate_in_list "$entity_type" "$VALID_ENTITY_TYPES" "entity type" || return 1
		type_filter="WHERE e.entity_type = '$entity_type'"
	fi

	db -json "$MEMORY_DB" <<EOF
SELECT
    e.id,
    e.display_name,
    e.entity_type,
    e.privacy_level,
    e.created_at,
    (SELECT COUNT(*) FROM entity_channels ec WHERE ec.entity_id = e.id) as channel_count,
    (SELECT COUNT(*) FROM interactions i WHERE i.entity_id = e.id) as interaction_count
FROM entities e
$type_filter
ORDER BY e.updated_at DESC
LIMIT $limit;
EOF
	return 0
}

#######################################
# Update an entity
#######################################
cmd_update() {
	local entity_id="$1"
	shift || true

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh update <entity_id> [--name ...] [--privacy ...]"
		return 1
	fi

	local name=""
	local privacy_level=""
	local notes=""
	local has_updates=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name | -n)
			name="$2"
			has_updates=true
			shift 2
			;;
		--privacy | -p)
			privacy_level="$2"
			has_updates=true
			shift 2
			;;
		--notes)
			notes="$2"
			has_updates=true
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ "$has_updates" != true ]]; then
		log_error "No updates specified. Use --name, --privacy, or --notes"
		return 1
	fi

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$entity_id")

	# Check entity exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	# Build SET clause
	local set_parts=()
	if [[ -n "$name" ]]; then
		local escaped_name
		escaped_name=$(_sql_escape "$name")
		set_parts+=("display_name = '$escaped_name'")
	fi
	if [[ -n "$privacy_level" ]]; then
		_validate_in_list "$privacy_level" "$VALID_PRIVACY_LEVELS" "privacy level" || return 1
		set_parts+=("privacy_level = '$privacy_level'")
	fi
	if [[ -n "$notes" ]]; then
		local escaped_notes
		escaped_notes=$(_sql_escape "$notes")
		set_parts+=("notes = '$escaped_notes'")
	fi
	set_parts+=("updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')")

	local set_clause
	set_clause=$(printf ", %s" "${set_parts[@]}")
	set_clause="${set_clause:2}" # Remove leading ", "

	db "$MEMORY_DB" "UPDATE entities SET $set_clause WHERE id = '$escaped_id';"

	log_success "Updated entity: $entity_id"
	return 0
}

#######################################
# Delete an entity (with cascade)
#######################################
cmd_delete() {
	local entity_id="$1"
	shift || true
	local confirm=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--confirm | -y)
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

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$entity_id")

	# Check entity exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	if [[ "$confirm" != true ]]; then
		local display_name
		display_name=$(db "$MEMORY_DB" "SELECT display_name FROM entities WHERE id = '$escaped_id';")
		local interaction_count
		interaction_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM interactions WHERE entity_id = '$escaped_id';")
		log_warn "This will delete entity '$display_name' ($entity_id) and all associated data:"
		log_warn "  - Channel links, interactions ($interaction_count), conversations, profiles, capability gaps"
		log_warn "Add --confirm to proceed"
		return 1
	fi

	# Delete in dependency order (SQLite foreign keys with ON DELETE CASCADE
	# may not be enabled, so delete explicitly)
	db "$MEMORY_DB" <<EOF
DELETE FROM capability_gaps WHERE entity_id = '$escaped_id';
DELETE FROM entity_profiles WHERE entity_id = '$escaped_id';
DELETE FROM interactions WHERE entity_id = '$escaped_id';
DELETE FROM conversations WHERE entity_id = '$escaped_id';
DELETE FROM entity_channels WHERE entity_id = '$escaped_id';
DELETE FROM entities WHERE id = '$escaped_id';
EOF

	# Clean up FTS
	db "$MEMORY_DB" "DELETE FROM interactions_fts WHERE entity_id = '$escaped_id';" 2>/dev/null || true

	log_success "Deleted entity: $entity_id"
	return 0
}

#######################################
# Search entities by name or notes
#######################################
cmd_search() {
	local query=""
	local limit=10

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--query | -q)
			query="$2"
			shift 2
			;;
		--limit | -l)
			limit="$2"
			shift 2
			;;
		*)
			if [[ -z "$query" ]]; then query="$1"; fi
			shift
			;;
		esac
	done

	if [[ -z "$query" ]]; then
		log_error "Query is required. Use --query \"search terms\""
		return 1
	fi

	init_db

	local escaped_query
	escaped_query=$(_sql_escape "$query")

	db -json "$MEMORY_DB" <<EOF
SELECT
    e.id,
    e.display_name,
    e.entity_type,
    e.privacy_level,
    e.created_at,
    (SELECT COUNT(*) FROM entity_channels ec WHERE ec.entity_id = e.id) as channel_count,
    (SELECT COUNT(*) FROM interactions i WHERE i.entity_id = e.id) as interaction_count
FROM entities e
WHERE e.display_name LIKE '%${escaped_query}%'
   OR e.notes LIKE '%${escaped_query}%'
   OR e.id IN (
       SELECT entity_id FROM entity_channels
       WHERE channel_identifier LIKE '%${escaped_query}%'
          OR display_name LIKE '%${escaped_query}%'
   )
ORDER BY e.updated_at DESC
LIMIT $limit;
EOF
	return 0
}

# =============================================================================
# Identity Resolution (link/unlink/verify/suggest/resolve)
# =============================================================================

#######################################
# Link a channel identity to an entity
#######################################
cmd_link() {
	local entity_id="$1"
	shift || true

	local channel=""
	local identifier=""
	local display_name=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel | -c)
			channel="$2"
			shift 2
			;;
		--identifier | --id | -i)
			identifier="$2"
			shift 2
			;;
		--display-name | --name)
			display_name="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" || -z "$channel" || -z "$identifier" ]]; then
		log_error "Usage: entity-helper.sh link <entity_id> --channel <channel> --identifier <id>"
		return 1
	fi

	_validate_in_list "$channel" "$VALID_CHANNELS" "channel" || return 1

	init_db

	local escaped_entity_id
	escaped_entity_id=$(_sql_escape "$entity_id")

	# Check entity exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_entity_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	# Check for existing link (same channel+identifier)
	local escaped_identifier
	escaped_identifier=$(_sql_escape "$identifier")
	local existing
	existing=$(db "$MEMORY_DB" "SELECT entity_id FROM entity_channels WHERE channel = '$channel' AND channel_identifier = '$escaped_identifier';" 2>/dev/null || echo "")
	if [[ -n "$existing" ]]; then
		if [[ "$existing" == "$entity_id" ]]; then
			log_warn "Channel identity already linked to this entity"
			return 0
		fi
		log_error "Channel identity $channel:$identifier is already linked to entity $existing"
		log_error "Use 'unlink' first, or 'suggest' to see potential matches"
		return 1
	fi

	local link_id
	link_id=$(generate_entity_id "ecl")
	local escaped_display
	escaped_display=$(_sql_escape "$display_name")

	db "$MEMORY_DB" <<EOF
INSERT INTO entity_channels (id, entity_id, channel, channel_identifier, display_name)
VALUES ('$link_id', '$escaped_entity_id', '$channel', '$escaped_identifier', '$escaped_display');
EOF

	log_success "Linked $channel:$identifier to entity $entity_id (link: $link_id)"
	echo "$link_id"
	return 0
}

#######################################
# Unlink a channel identity
#######################################
cmd_unlink() {
	local link_id="$1"

	if [[ -z "$link_id" ]]; then
		log_error "Channel link ID is required. Usage: entity-helper.sh unlink <channel_link_id>"
		return 1
	fi

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$link_id")

	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entity_channels WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Channel link not found: $link_id"
		return 1
	fi

	db "$MEMORY_DB" "DELETE FROM entity_channels WHERE id = '$escaped_id';"

	log_success "Unlinked channel identity: $link_id"
	return 0
}

#######################################
# Verify a channel link (confirm identity)
#######################################
cmd_verify() {
	local link_id="$1"
	shift || true
	local verified_by="system"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--by)
			verified_by="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$link_id" ]]; then
		log_error "Channel link ID is required. Usage: entity-helper.sh verify <channel_link_id> [--by admin]"
		return 1
	fi

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$link_id")
	local escaped_by
	escaped_by=$(_sql_escape "$verified_by")

	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entity_channels WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Channel link not found: $link_id"
		return 1
	fi

	db "$MEMORY_DB" <<EOF
UPDATE entity_channels
SET verified = 1,
    verified_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    verified_by = '$escaped_by'
WHERE id = '$escaped_id';
EOF

	log_success "Verified channel link: $link_id (by: $verified_by)"
	return 0
}

#######################################
# Suggest entity matches for a channel identity
# Never auto-links — suggests candidates for human confirmation
#######################################
cmd_suggest() {
	local channel=""
	local identifier=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel | -c)
			channel="$2"
			shift 2
			;;
		--identifier | --id | -i)
			identifier="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$channel" || -z "$identifier" ]]; then
		log_error "Usage: entity-helper.sh suggest --channel <channel> --identifier <id>"
		return 1
	fi

	_validate_in_list "$channel" "$VALID_CHANNELS" "channel" || return 1

	init_db

	local escaped_identifier
	escaped_identifier=$(_sql_escape "$identifier")

	# 1. Exact match on channel+identifier
	local exact_match
	exact_match=$(
		db -json "$MEMORY_DB" <<EOF
SELECT e.id, e.display_name, e.entity_type, ec.channel, ec.channel_identifier, ec.verified,
       'exact_match' as match_type
FROM entity_channels ec
JOIN entities e ON ec.entity_id = e.id
WHERE ec.channel = '$channel' AND ec.channel_identifier = '$escaped_identifier';
EOF
	)

	if [[ -n "$exact_match" && "$exact_match" != "[]" ]]; then
		echo "$exact_match"
		return 0
	fi

	# 2. Fuzzy match: same identifier on different channels
	local cross_channel
	cross_channel=$(
		db -json "$MEMORY_DB" <<EOF
SELECT e.id, e.display_name, e.entity_type, ec.channel, ec.channel_identifier, ec.verified,
       'cross_channel' as match_type
FROM entity_channels ec
JOIN entities e ON ec.entity_id = e.id
WHERE ec.channel_identifier LIKE '%${escaped_identifier}%'
   OR '$escaped_identifier' LIKE '%' || ec.channel_identifier || '%'
LIMIT 5;
EOF
	)

	# 3. Name-based match: extract name part from identifier
	local name_part=""
	case "$channel" in
	matrix)
		name_part="${identifier%%:*}"
		name_part="${name_part#@}"
		;;
	email) name_part="${identifier%%@*}" ;;
	*) name_part="$identifier" ;;
	esac

	local escaped_name_part
	escaped_name_part=$(_sql_escape "$name_part")
	local name_match
	name_match=$(
		db -json "$MEMORY_DB" <<EOF
SELECT e.id, e.display_name, e.entity_type, '' as channel, '' as channel_identifier, 0 as verified,
       'name_similarity' as match_type
FROM entities e
WHERE lower(e.display_name) LIKE '%${escaped_name_part}%'
LIMIT 5;
EOF
	)

	# Combine results
	if command -v jq &>/dev/null; then
		jq -s '.[0] + .[1] + .[2] | unique_by(.id)' \
			<(echo "${cross_channel:-[]}") \
			<(echo "${name_match:-[]}") \
			<(echo "[]")
	else
		echo "${cross_channel:-[]}"
		echo "${name_match:-[]}"
	fi

	return 0
}

#######################################
# Resolve a channel identity to an entity (lookup only, no creation)
# Returns entity details if found, empty if not
#######################################
cmd_resolve() {
	local channel=""
	local identifier=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel | -c)
			channel="$2"
			shift 2
			;;
		--identifier | --id | -i)
			identifier="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$channel" || -z "$identifier" ]]; then
		log_error "Usage: entity-helper.sh resolve --channel <channel> --identifier <id>"
		return 1
	fi

	init_db

	local escaped_identifier
	escaped_identifier=$(_sql_escape "$identifier")

	local result
	result=$(
		db -json "$MEMORY_DB" <<EOF
SELECT e.id, e.display_name, e.entity_type, e.privacy_level,
       ec.verified, ec.channel, ec.channel_identifier
FROM entity_channels ec
JOIN entities e ON ec.entity_id = e.id
WHERE ec.channel = '$channel' AND ec.channel_identifier = '$escaped_identifier';
EOF
	)

	if [[ -z "$result" || "$result" == "[]" ]]; then
		return 1
	fi

	echo "$result"
	return 0
}

# =============================================================================
# Privacy-Filtered Context Loading
# =============================================================================

#######################################
# Load entity context with privacy filtering
# Returns interaction history, profiles, and conversation state
# filtered by the caller's privacy clearance level
#######################################
cmd_context() {
	local entity_id="$1"
	shift || true

	local privacy_filter="standard"
	local limit=20
	local include_profiles=true
	local include_conversations=true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--privacy-filter | --privacy | -p)
			privacy_filter="$2"
			shift 2
			;;
		--limit | -l)
			limit="$2"
			shift 2
			;;
		--no-profiles)
			include_profiles=false
			shift
			;;
		--no-conversations)
			include_conversations=false
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required. Usage: entity-helper.sh context <entity_id> [--privacy-filter standard]"
		return 1
	fi

	_validate_in_list "$privacy_filter" "$VALID_PRIVACY_LEVELS" "privacy filter" || return 1

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$entity_id")

	# Check entity exists and privacy level allows access
	local entity_privacy
	entity_privacy=$(db "$MEMORY_DB" "SELECT privacy_level FROM entities WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	if [[ -z "$entity_privacy" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	# Privacy hierarchy: public < standard < sensitive < restricted
	# Caller must have equal or higher clearance than entity's privacy level
	local caller_rank
	local entity_rank
	caller_rank=$(_privacy_rank "$privacy_filter")
	entity_rank=$(_privacy_rank "$entity_privacy")

	if [[ "$caller_rank" -lt "$entity_rank" ]]; then
		log_error "Insufficient privacy clearance: entity requires '$entity_privacy', caller has '$privacy_filter'"
		return 1
	fi

	# Build context output
	echo "{"

	# Entity basic info
	echo "  \"entity\":"
	db -json "$MEMORY_DB" "SELECT id, display_name, entity_type, privacy_level, created_at FROM entities WHERE id = '$escaped_id';"

	# Recent interactions (privacy-filtered: strip content for restricted entities at standard clearance)
	echo ", \"recent_interactions\":"
	if [[ "$entity_rank" -le "$caller_rank" ]]; then
		db -json "$MEMORY_DB" <<EOF
SELECT id, channel, direction, content_summary, created_at, conversation_id
FROM interactions
WHERE entity_id = '$escaped_id'
ORDER BY created_at DESC
LIMIT $limit;
EOF
	else
		# Redacted view — show metadata only
		db -json "$MEMORY_DB" <<EOF
SELECT id, channel, direction, '[REDACTED]' as content_summary, created_at, conversation_id
FROM interactions
WHERE entity_id = '$escaped_id'
ORDER BY created_at DESC
LIMIT $limit;
EOF
	fi

	# Active conversations
	if [[ "$include_conversations" == true ]]; then
		echo ", \"conversations\":"
		db -json "$MEMORY_DB" <<EOF
SELECT id, channel, status, summary, pending_actions, interaction_count,
       first_interaction_at, last_interaction_at
FROM conversations
WHERE entity_id = '$escaped_id' AND status IN ('active', 'idle')
ORDER BY last_interaction_at DESC;
EOF
	fi

	# Entity profiles (latest version per type)
	if [[ "$include_profiles" == true ]]; then
		echo ", \"profiles\":"
		db -json "$MEMORY_DB" <<EOF
SELECT ep.id, ep.profile_type, ep.content, ep.confidence, ep.created_at
FROM entity_profiles ep
WHERE ep.entity_id = '$escaped_id'
  AND ep.id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY ep.profile_type, ep.created_at DESC;
EOF
	fi

	# Channel identities
	echo ", \"channels\":"
	db -json "$MEMORY_DB" "SELECT id, channel, channel_identifier, display_name, verified FROM entity_channels WHERE entity_id = '$escaped_id';"

	echo "}"
	return 0
}

# =============================================================================
# Interaction Logging
# =============================================================================

#######################################
# Log an interaction (Layer 0 — immutable append)
#######################################
cmd_interact() {
	local entity_id="$1"
	shift || true

	local channel=""
	local direction=""
	local summary=""
	local metadata="{}"
	local conversation_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel | -c)
			channel="$2"
			shift 2
			;;
		--direction | -d)
			direction="$2"
			shift 2
			;;
		--summary | -s)
			summary="$2"
			shift 2
			;;
		--metadata | -m)
			metadata="$2"
			shift 2
			;;
		--conversation | --conv)
			conversation_id="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" || -z "$channel" || -z "$direction" || -z "$summary" ]]; then
		log_error "Usage: entity-helper.sh interact <entity_id> --channel <ch> --direction <in/out> --summary \"...\""
		return 1
	fi

	_validate_in_list "$channel" "$VALID_CHANNELS" "channel" || return 1
	_validate_in_list "$direction" "$VALID_DIRECTIONS" "direction" || return 1

	init_db

	local escaped_entity_id
	escaped_entity_id=$(_sql_escape "$entity_id")

	# Check entity exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_entity_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	# Privacy filter: strip <private>...</private> blocks from summary
	summary=$(echo "$summary" | sed 's/<private>[^<]*<\/private>//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')

	# Privacy filter: reject content that looks like secrets
	if echo "$summary" | grep -qE '(sk-[a-zA-Z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[a-zA-Z0-9]{36})'; then
		log_error "Content appears to contain secrets. Refusing to store."
		return 1
	fi

	local interaction_id
	interaction_id=$(generate_entity_id "int")
	local escaped_summary
	escaped_summary=$(_sql_escape "$summary")
	local escaped_metadata
	escaped_metadata=$(_sql_escape "$metadata")
	local escaped_conv_id
	escaped_conv_id=$(_sql_escape "$conversation_id")

	# Generate content hash for dedup detection
	local content_hash
	content_hash=$(echo -n "$summary" | shasum -a 256 | cut -d' ' -f1)

	db "$MEMORY_DB" <<EOF
INSERT INTO interactions (id, entity_id, channel, direction, content_summary, content_hash, metadata, conversation_id)
VALUES ('$interaction_id', '$escaped_entity_id', '$channel', '$direction', '$escaped_summary', '$content_hash', '$escaped_metadata', NULLIF('$escaped_conv_id', ''));
EOF

	# Index in FTS
	db "$MEMORY_DB" <<EOF
INSERT INTO interactions_fts (id, entity_id, content_summary, channel, created_at)
VALUES ('$interaction_id', '$escaped_entity_id', '$escaped_summary', '$channel', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
EOF

	# Update conversation if linked
	if [[ -n "$conversation_id" ]]; then
		db "$MEMORY_DB" <<EOF
UPDATE conversations
SET interaction_count = interaction_count + 1,
    last_interaction_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$escaped_conv_id';
EOF
	fi

	# Update entity's updated_at
	db "$MEMORY_DB" "UPDATE entities SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '$escaped_entity_id';"

	log_success "Logged interaction: $interaction_id"
	echo "$interaction_id"
	return 0
}

# =============================================================================
# Profile Management
# =============================================================================

#######################################
# Add or view entity profiles
#######################################
cmd_profile() {
	local entity_id="$1"
	shift || true

	local profile_type=""
	local content=""
	local confidence="medium"
	local supersedes_id=""
	local evidence_ids=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type | -t)
			profile_type="$2"
			shift 2
			;;
		--content | -c)
			content="$2"
			shift 2
			;;
		--confidence)
			confidence="$2"
			shift 2
			;;
		--supersedes)
			supersedes_id="$2"
			shift 2
			;;
		--evidence)
			evidence_ids="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required"
		return 1
	fi

	init_db

	local escaped_entity_id
	escaped_entity_id=$(_sql_escape "$entity_id")

	# If no content, show existing profiles
	if [[ -z "$content" ]]; then
		local type_filter=""
		if [[ -n "$profile_type" ]]; then
			_validate_in_list "$profile_type" "$VALID_PROFILE_TYPES" "profile type" || return 1
			type_filter="AND ep.profile_type = '$profile_type'"
		fi

		db -json "$MEMORY_DB" <<EOF
SELECT ep.id, ep.profile_type, ep.content, ep.confidence, ep.evidence_ids,
       ep.supersedes_id, ep.created_at
FROM entity_profiles ep
WHERE ep.entity_id = '$escaped_entity_id' $type_filter
  AND ep.id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY ep.profile_type, ep.created_at DESC;
EOF
		return 0
	fi

	# Create new profile
	if [[ -z "$profile_type" ]]; then
		log_error "Profile type is required when adding content. Use --type <type>"
		return 1
	fi

	_validate_in_list "$profile_type" "$VALID_PROFILE_TYPES" "profile type" || return 1

	local profile_id
	profile_id=$(generate_entity_id "epr")
	local escaped_content
	escaped_content=$(_sql_escape "$content")
	local escaped_evidence
	escaped_evidence=$(_sql_escape "$evidence_ids")
	local escaped_supersedes
	escaped_supersedes=$(_sql_escape "$supersedes_id")

	db "$MEMORY_DB" <<EOF
INSERT INTO entity_profiles (id, entity_id, profile_type, content, confidence, evidence_ids, supersedes_id)
VALUES ('$profile_id', '$escaped_entity_id', '$profile_type', '$escaped_content', '$confidence', '$escaped_evidence', NULLIF('$escaped_supersedes', ''));
EOF

	log_success "Added profile: $profile_id ($profile_type)"
	echo "$profile_id"
	return 0
}

# =============================================================================
# Capability Gap Management
# =============================================================================

#######################################
# Manage capability gaps (self-evolution loop)
#######################################
cmd_gap() {
	local subcmd="${1:-list}"
	shift || true

	case "$subcmd" in
	create) _gap_create "$@" ;;
	list) _gap_list "$@" ;;
	update) _gap_update "$@" ;;
	*)
		log_error "Unknown gap subcommand: $subcmd (use create, list, update)"
		return 1
		;;
	esac
}

_gap_create() {
	local description=""
	local entity_id=""
	local gap_type="missing_feature"
	local evidence_ids=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--description | -d)
			description="$2"
			shift 2
			;;
		--entity | -e)
			entity_id="$2"
			shift 2
			;;
		--type | -t)
			gap_type="$2"
			shift 2
			;;
		--evidence)
			evidence_ids="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$description" ]]; then
		log_error "Description is required. Use --description \"...\""
		return 1
	fi

	_validate_in_list "$gap_type" "$VALID_GAP_TYPES" "gap type" || return 1

	init_db

	local gap_id
	gap_id=$(generate_entity_id "gap")
	local escaped_desc
	escaped_desc=$(_sql_escape "$description")
	local escaped_entity
	escaped_entity=$(_sql_escape "$entity_id")
	local escaped_evidence
	escaped_evidence=$(_sql_escape "$evidence_ids")

	# Check for existing similar gap (dedup)
	local existing_gap
	existing_gap=$(db "$MEMORY_DB" "SELECT id FROM capability_gaps WHERE description = '$escaped_desc' AND status NOT IN ('resolved', 'wont_fix') LIMIT 1;" 2>/dev/null || echo "")
	if [[ -n "$existing_gap" ]]; then
		# Increment frequency instead of creating duplicate
		db "$MEMORY_DB" "UPDATE capability_gaps SET frequency = frequency + 1 WHERE id = '$existing_gap';"
		log_warn "Similar gap already exists ($existing_gap), incremented frequency"
		echo "$existing_gap"
		return 0
	fi

	db "$MEMORY_DB" <<EOF
INSERT INTO capability_gaps (id, entity_id, gap_type, description, evidence_ids)
VALUES ('$gap_id', NULLIF('$escaped_entity', ''), '$gap_type', '$escaped_desc', '$escaped_evidence');
EOF

	log_success "Created capability gap: $gap_id"
	echo "$gap_id"
	return 0
}

_gap_list() {
	local status=""
	local limit=20

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--status | -s)
			status="$2"
			shift 2
			;;
		--limit | -l)
			limit="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	local status_filter=""
	if [[ -n "$status" ]]; then
		_validate_in_list "$status" "$VALID_GAP_STATUSES" "gap status" || return 1
		status_filter="WHERE cg.status = '$status'"
	fi

	db -json "$MEMORY_DB" <<EOF
SELECT cg.id, cg.gap_type, cg.description, cg.frequency, cg.status,
       cg.todo_task_id, cg.entity_id, cg.created_at, cg.resolved_at,
       COALESCE(e.display_name, '') as entity_name
FROM capability_gaps cg
LEFT JOIN entities e ON cg.entity_id = e.id
$status_filter
ORDER BY cg.frequency DESC, cg.created_at DESC
LIMIT $limit;
EOF
	return 0
}

_gap_update() {
	local gap_id="$1"
	shift || true

	local status=""
	local todo_task_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--status | -s)
			status="$2"
			shift 2
			;;
		--todo | -t)
			todo_task_id="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$gap_id" ]]; then
		log_error "Gap ID is required"
		return 1
	fi

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$gap_id")

	local set_parts=()
	if [[ -n "$status" ]]; then
		_validate_in_list "$status" "$VALID_GAP_STATUSES" "gap status" || return 1
		set_parts+=("status = '$status'")
		if [[ "$status" == "resolved" ]]; then
			set_parts+=("resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')")
		fi
	fi
	if [[ -n "$todo_task_id" ]]; then
		local escaped_todo
		escaped_todo=$(_sql_escape "$todo_task_id")
		set_parts+=("todo_task_id = '$escaped_todo'")
		# Auto-set status to todo_created if creating a TODO link
		if [[ -z "$status" ]]; then
			set_parts+=("status = 'todo_created'")
		fi
	fi

	if [[ ${#set_parts[@]} -eq 0 ]]; then
		log_error "No updates specified. Use --status or --todo"
		return 1
	fi

	local set_clause
	set_clause=$(printf ", %s" "${set_parts[@]}")
	set_clause="${set_clause:2}"

	db "$MEMORY_DB" "UPDATE capability_gaps SET $set_clause WHERE id = '$escaped_id';"

	log_success "Updated capability gap: $gap_id"
	return 0
}

# =============================================================================
# Statistics
# =============================================================================

#######################################
# Show entity system statistics
#######################################
cmd_stats() {
	init_db

	echo ""
	echo "=== Entity System Statistics ==="
	echo ""

	db "$MEMORY_DB" <<'EOF'
SELECT 'Total entities' as metric, COUNT(*) as value FROM entities
UNION ALL
SELECT 'By type: ' || entity_type, COUNT(*) FROM entities GROUP BY entity_type
UNION ALL
SELECT 'Channel links', COUNT(*) FROM entity_channels
UNION ALL
SELECT 'Verified links', COUNT(*) FROM entity_channels WHERE verified = 1
UNION ALL
SELECT 'Total interactions', COUNT(*) FROM interactions
UNION ALL
SELECT 'Active conversations', COUNT(*) FROM conversations WHERE status = 'active'
UNION ALL
SELECT 'Entity profiles', COUNT(*) FROM entity_profiles
UNION ALL
SELECT 'Capability gaps (open)', COUNT(*) FROM capability_gaps WHERE status NOT IN ('resolved', 'wont_fix');
EOF

	echo ""

	# Channel distribution
	echo "Channel distribution:"
	db "$MEMORY_DB" <<'EOF'
SELECT '  ' || channel, COUNT(*) FROM entity_channels GROUP BY channel ORDER BY COUNT(*) DESC;
EOF

	echo ""

	# Top entities by interaction count
	echo "Most active entities:"
	db "$MEMORY_DB" <<'EOF'
SELECT '  ' || e.display_name || ' (' || e.entity_type || ')', COUNT(i.id) as interactions
FROM entities e
LEFT JOIN interactions i ON e.id = i.entity_id
GROUP BY e.id
ORDER BY interactions DESC
LIMIT 5;
EOF

	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'EOF'
entity-helper.sh - Entity management for multi-channel relationship continuity (t1363.1)

USAGE:
    entity-helper.sh <command> [options]

ENTITY CRUD:
    create      Create a new entity
    get         Get entity details with channels and stats
    list        List entities (optionally filtered by type)
    update      Update entity name, privacy, or notes
    delete      Delete entity and all associated data (requires --confirm)
    search      Search entities by name, notes, or channel identifier

IDENTITY RESOLUTION:
    link        Link a channel identity to an entity
    unlink      Remove a channel identity link
    verify      Mark a channel link as verified
    suggest     Suggest entity matches for a channel identity (never auto-links)
    resolve     Look up entity by channel+identifier (exact match only)

CONTEXT & INTERACTIONS:
    context     Load privacy-filtered entity context (interactions, profiles, conversations)
    interact    Log an interaction (Layer 0 immutable append)
    profile     View or add entity profiles (versioned, with supersedes chain)

CAPABILITY GAPS:
    gap create  Record a detected capability gap
    gap list    List capability gaps (optionally by status)
    gap update  Update gap status or link to TODO task

STATISTICS:
    stats       Show entity system statistics

PRIVACY LEVELS:
    public      Visible to all agents and channels
    standard    Default — visible to authenticated agents
    sensitive   Restricted to agents with explicit clearance
    restricted  Highest restriction — metadata only without clearance

ENTITY TYPES:
    person      Human individual
    agent       AI agent or bot
    service     External service or API
    group       Group of entities

CHANNELS:
    matrix, simplex, email, cli, slack, discord, web, sms, other

EXAMPLES:
    # Create an entity
    entity-helper.sh create --name "Marcus Quinn" --type person --privacy standard

    # Link channel identities
    entity-helper.sh link ent_xxx --channel matrix --identifier "@marcus:server.com"
    entity-helper.sh link ent_xxx --channel email --identifier "marcus@example.com"

    # Verify a link
    entity-helper.sh verify ecl_xxx --by "admin"

    # Suggest matches for unknown identity
    entity-helper.sh suggest --channel simplex --identifier "user123"

    # Resolve known identity
    entity-helper.sh resolve --channel matrix --identifier "@marcus:server.com"

    # Load entity context (privacy-filtered)
    entity-helper.sh context ent_xxx --privacy-filter standard

    # Log an interaction
    entity-helper.sh interact ent_xxx --channel matrix --direction inbound --summary "Asked about deployment status"

    # Add a profile observation
    entity-helper.sh profile ent_xxx --type preference --content "Prefers concise responses"

    # Record a capability gap
    entity-helper.sh gap create --description "No deployment status dashboard" --type missing_feature

    # Link gap to TODO task
    entity-helper.sh gap update gap_xxx --todo t1400 --status todo_created
EOF
	return 0
}

# =============================================================================
# Main Entry Point
# =============================================================================

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
	verify) cmd_verify "$@" ;;
	suggest) cmd_suggest "$@" ;;
	resolve) cmd_resolve "$@" ;;
	context) cmd_context "$@" ;;
	interact) cmd_interact "$@" ;;
	profile) cmd_profile "$@" ;;
	gap) cmd_gap "$@" ;;
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
