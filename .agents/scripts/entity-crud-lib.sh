#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Entity CRUD Library -- Create / Get / List / Update / Delete / Search
# =============================================================================
# CRUD commands for the entity memory system (p035 / t1363).
# Handles creating, reading, updating, deleting, and searching entities.
#
# Usage: source "${SCRIPT_DIR}/entity-crud-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error, log_warn, log_success, log_info)
#   - entity-helper.sh (entity_db, generate_entity_id, sql_escape,
#     normalize_channel_id, init_entity_db, ENTITY_MEMORY_DB,
#     VALID_ENTITY_TYPES, VALID_CHANNELS)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ENTITY_CRUD_LIB_LOADED:-}" ]] && return 0
_ENTITY_CRUD_LIB_LOADED=1

# SCRIPT_DIR fallback — required when sourced from a directory other than SCRIPT_DIR
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Entity CRUD
# =============================================================================

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
			local normalized_channel_id
			normalized_channel_id=$(normalize_channel_id "$channel" "$channel_id")
			local esc_channel_id
			esc_channel_id=$(sql_escape "$normalized_channel_id")
			entity_db "$ENTITY_MEMORY_DB" <<EOF
INSERT INTO entity_channels (entity_id, channel, channel_id, display_name, confidence)
VALUES ('$id', '$channel', '$esc_channel_id', '$esc_display', 'confirmed');
EOF
			log_info "Linked to $channel: $normalized_channel_id"
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
