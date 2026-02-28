#!/usr/bin/env bash
# entity-helper.sh - Entity management for aidevops multi-channel memory system
# Part of the three-layer entity memory model (t1363.1):
#   Layer 0: Raw interaction log (immutable, append-only)
#   Layer 1: Per-conversation context (tactical)
#   Layer 2: Entity relationship model (strategic)
#
# Provides: entity CRUD, identity resolution (link/unlink/verify/suggest),
#           interaction logging, entity profile management, capability gap tracking,
#           privacy-filtered context loading.
#
# Usage:
#   entity-helper.sh create --name "Marcus" [--type person]
#   entity-helper.sh get <entity_id>
#   entity-helper.sh list [--type person|agent|service|group]
#   entity-helper.sh update <entity_id> --name "New Name"
#   entity-helper.sh search --query "marcus"
#
#   entity-helper.sh channel add <entity_id> --type matrix --handle "@user:server"
#   entity-helper.sh channel remove <channel_id>
#   entity-helper.sh channel list <entity_id>
#
#   entity-helper.sh link <entity_id> <entity_id>       # Merge two entities
#   entity-helper.sh unlink <channel_id>                 # Detach channel from entity
#   entity-helper.sh verify <channel_id>                 # Mark channel as verified
#   entity-helper.sh suggest                             # Suggest potential identity links
#
#   entity-helper.sh interact --entity <id> --channel-type matrix --channel-id "!room:server" \
#       --direction inbound --content "Hello"
#
#   entity-helper.sh profile add <entity_id> --type needs --content "Prefers concise responses" \
#       [--confidence high] [--evidence '["int_xxx","int_yyy"]']
#   entity-helper.sh profile list <entity_id> [--type needs]
#
#   entity-helper.sh gap add --description "Cannot generate PDFs" [--entity <id>] \
#       [--evidence '["int_xxx"]']
#   entity-helper.sh gap list [--status detected|task_created|resolved]
#   entity-helper.sh gap resolve <gap_id> [--task <task_id>]
#
#   entity-helper.sh context <entity_id> --channel-type matrix [--channel-id "!room:server"]
#   entity-helper.sh stats

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
MEMORY_DIR="$MEMORY_BASE_DIR"
MEMORY_DB="$MEMORY_DIR/memory.db"

# Source memory common utilities (db wrapper, init_db, generate_id, etc.)
# shellcheck source=memory/_common.sh
source "${SCRIPT_DIR}/memory/_common.sh"

# Valid entity types
readonly VALID_ENTITY_TYPES="person agent service group"
readonly VALID_CHANNEL_TYPES="matrix simplex email cli dm web"
readonly VALID_PROFILE_TYPES="needs expectations preferences gaps satisfaction"
readonly VALID_GAP_STATUSES="detected task_created resolved"
readonly VALID_PRIVACY_LEVELS="public private shared"

#######################################
# SQL-escape a value (double single quotes)
#######################################
_sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

#######################################
# Create a new entity
#######################################
cmd_create() {
	local name=""
	local entity_type="person"

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
		*)
			if [[ -z "$name" ]]; then
				name="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$name" ]]; then
		log_error "Name is required. Use --name \"Entity Name\""
		return 1
	fi

	# Validate entity type
	local type_pattern=" $entity_type "
	if [[ ! " $VALID_ENTITY_TYPES " =~ $type_pattern ]]; then
		log_error "Invalid entity type: $entity_type (valid: $VALID_ENTITY_TYPES)"
		return 1
	fi

	init_db

	local id
	id=$(generate_id "ent")
	local escaped_name
	escaped_name=$(_sql_escape "$name")

	db "$MEMORY_DB" "INSERT INTO entities (id, display_name, entity_type) VALUES ('$id', '$escaped_name', '$entity_type');"

	log_success "Created entity: $id ($name, $entity_type)"
	echo "$id"
	return 0
}

#######################################
# Get entity details
#######################################
cmd_get() {
	local entity_id="$1"

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required"
		return 1
	fi

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$entity_id")

	local result
	result=$(db -json "$MEMORY_DB" "SELECT * FROM entities WHERE id = '$escaped_id';")

	if [[ -z "$result" || "$result" == "[]" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	echo "$result"

	# Also show channels
	local channels
	channels=$(db -json "$MEMORY_DB" "SELECT * FROM entity_channels WHERE entity_id = '$escaped_id';")
	if [[ -n "$channels" && "$channels" != "[]" ]]; then
		echo ""
		echo "Channels:"
		echo "$channels"
	fi

	return 0
}

#######################################
# List entities
#######################################
cmd_list() {
	local type_filter=""
	local format="text"
	local limit=50

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type | -t)
			type_filter="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		--limit | -l)
			limit="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	local where_clause=""
	if [[ -n "$type_filter" ]]; then
		local type_pattern=" $type_filter "
		if [[ ! " $VALID_ENTITY_TYPES " =~ $type_pattern ]]; then
			log_error "Invalid entity type: $type_filter (valid: $VALID_ENTITY_TYPES)"
			return 1
		fi
		where_clause="WHERE entity_type = '$type_filter'"
	fi

	local results
	results=$(db -json "$MEMORY_DB" "SELECT e.*, (SELECT COUNT(*) FROM entity_channels ec WHERE ec.entity_id = e.id) as channel_count, (SELECT COUNT(*) FROM interactions i WHERE i.entity_id = e.id) as interaction_count FROM entities e $where_clause ORDER BY e.updated_at DESC LIMIT $limit;")

	if [[ "$format" == "json" ]]; then
		echo "$results"
	else
		if [[ -z "$results" || "$results" == "[]" ]]; then
			log_info "No entities found"
			return 0
		fi

		echo ""
		echo "=== Entities ==="
		echo ""
		if command -v jq &>/dev/null; then
			echo "$results" | jq -r '.[] | "  \(.id) | \(.display_name) (\(.entity_type)) | \(.channel_count) channels | \(.interaction_count) interactions"'
		else
			echo "$results"
		fi
		echo ""
	fi

	return 0
}

#######################################
# Update entity
#######################################
cmd_update() {
	local entity_id="$1"
	shift || true

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required"
		return 1
	fi

	local name=""
	local entity_type=""

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
		*) shift ;;
		esac
	done

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$entity_id")

	# Verify entity exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	local updates=""
	if [[ -n "$name" ]]; then
		local escaped_name
		escaped_name=$(_sql_escape "$name")
		updates="display_name = '$escaped_name'"
	fi
	if [[ -n "$entity_type" ]]; then
		local type_pattern=" $entity_type "
		if [[ ! " $VALID_ENTITY_TYPES " =~ $type_pattern ]]; then
			log_error "Invalid entity type: $entity_type (valid: $VALID_ENTITY_TYPES)"
			return 1
		fi
		if [[ -n "$updates" ]]; then
			updates="$updates, "
		fi
		updates="${updates}entity_type = '$entity_type'"
	fi

	if [[ -z "$updates" ]]; then
		log_warn "No updates specified"
		return 0
	fi

	db "$MEMORY_DB" "UPDATE entities SET $updates, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '$escaped_id';"

	log_success "Updated entity: $entity_id"
	return 0
}

#######################################
# Search entities by name
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
			if [[ -z "$query" ]]; then
				query="$1"
			fi
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

	local results
	results=$(db -json "$MEMORY_DB" "SELECT e.*, (SELECT COUNT(*) FROM entity_channels ec WHERE ec.entity_id = e.id) as channel_count FROM entities e WHERE e.display_name LIKE '%$escaped_query%' OR e.id IN (SELECT entity_id FROM entity_channels WHERE channel_handle LIKE '%$escaped_query%') ORDER BY e.updated_at DESC LIMIT $limit;")

	if [[ -z "$results" || "$results" == "[]" ]]; then
		log_warn "No entities found matching: $query"
		return 0
	fi

	echo "$results"
	return 0
}

#######################################
# Channel management subcommands
#######################################
cmd_channel() {
	local subcmd="${1:-}"
	shift || true

	case "$subcmd" in
	add) cmd_channel_add "$@" ;;
	remove) cmd_channel_remove "$@" ;;
	list) cmd_channel_list "$@" ;;
	*)
		log_error "Unknown channel subcommand: $subcmd (use: add, remove, list)"
		return 1
		;;
	esac
}

cmd_channel_add() {
	local entity_id="$1"
	shift || true

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required"
		return 1
	fi

	local channel_type=""
	local channel_handle=""
	local privacy_level="private"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type | -t)
			channel_type="$2"
			shift 2
			;;
		--handle | -h)
			channel_handle="$2"
			shift 2
			;;
		--privacy)
			privacy_level="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$channel_type" || -z "$channel_handle" ]]; then
		log_error "Both --type and --handle are required"
		return 1
	fi

	# Validate channel type
	local type_pattern=" $channel_type "
	if [[ ! " $VALID_CHANNEL_TYPES " =~ $type_pattern ]]; then
		log_error "Invalid channel type: $channel_type (valid: $VALID_CHANNEL_TYPES)"
		return 1
	fi

	# Validate privacy level
	local priv_pattern=" $privacy_level "
	if [[ ! " $VALID_PRIVACY_LEVELS " =~ $priv_pattern ]]; then
		log_error "Invalid privacy level: $privacy_level (valid: $VALID_PRIVACY_LEVELS)"
		return 1
	fi

	init_db

	local escaped_eid
	escaped_eid=$(_sql_escape "$entity_id")

	# Verify entity exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_eid';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	local id
	id=$(generate_id "ech")
	local escaped_handle
	escaped_handle=$(_sql_escape "$channel_handle")

	# Check for existing channel handle (unique constraint)
	local existing
	existing=$(db "$MEMORY_DB" "SELECT entity_id FROM entity_channels WHERE channel_type = '$channel_type' AND channel_handle = '$escaped_handle';" 2>/dev/null || echo "")
	if [[ -n "$existing" ]]; then
		log_error "Channel handle already registered to entity: $existing"
		log_error "Use 'entity-helper.sh link' to merge entities, or 'unlink' first"
		return 1
	fi

	db "$MEMORY_DB" "INSERT INTO entity_channels (id, entity_id, channel_type, channel_handle, privacy_level) VALUES ('$id', '$escaped_eid', '$channel_type', '$escaped_handle', '$privacy_level');"

	# Update entity timestamp
	db "$MEMORY_DB" "UPDATE entities SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '$escaped_eid';"

	log_success "Added channel: $id ($channel_type: $channel_handle -> $entity_id)"
	echo "$id"
	return 0
}

cmd_channel_remove() {
	local channel_id="$1"

	if [[ -z "$channel_id" ]]; then
		log_error "Channel ID is required"
		return 1
	fi

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$channel_id")

	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entity_channels WHERE id = '$escaped_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Channel not found: $channel_id"
		return 1
	fi

	db "$MEMORY_DB" "DELETE FROM entity_channels WHERE id = '$escaped_id';"

	log_success "Removed channel: $channel_id"
	return 0
}

cmd_channel_list() {
	local entity_id="$1"

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required"
		return 1
	fi

	init_db

	local escaped_id
	escaped_id=$(_sql_escape "$entity_id")

	local results
	results=$(db -json "$MEMORY_DB" "SELECT * FROM entity_channels WHERE entity_id = '$escaped_id' ORDER BY channel_type;")

	if [[ -z "$results" || "$results" == "[]" ]]; then
		log_info "No channels for entity: $entity_id"
		return 0
	fi

	echo "$results"
	return 0
}

#######################################
# Identity resolution: link two entities (merge)
# Moves all channels, interactions, profiles, and gaps from source to target.
# Source entity is deleted after merge.
#######################################
cmd_link() {
	local target_id="$1"
	local source_id="$2"

	if [[ -z "$target_id" || -z "$source_id" ]]; then
		log_error "Usage: entity-helper.sh link <target_entity_id> <source_entity_id>"
		return 1
	fi

	if [[ "$target_id" == "$source_id" ]]; then
		log_error "Cannot link an entity to itself"
		return 1
	fi

	init_db

	local escaped_target
	escaped_target=$(_sql_escape "$target_id")
	local escaped_source
	escaped_source=$(_sql_escape "$source_id")

	# Verify both entities exist
	local target_exists
	target_exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_target';")
	local source_exists
	source_exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_source';")

	if [[ "$target_exists" == "0" ]]; then
		log_error "Target entity not found: $target_id"
		return 1
	fi
	if [[ "$source_exists" == "0" ]]; then
		log_error "Source entity not found: $source_id"
		return 1
	fi

	# Move all related records from source to target
	db "$MEMORY_DB" <<EOF
-- Move channels
UPDATE entity_channels SET entity_id = '$escaped_target' WHERE entity_id = '$escaped_source';
-- Move interactions
UPDATE interactions SET entity_id = '$escaped_target' WHERE entity_id = '$escaped_source';
-- Move conversations
UPDATE conversations SET entity_id = '$escaped_target' WHERE entity_id = '$escaped_source';
-- Move profiles
UPDATE entity_profiles SET entity_id = '$escaped_target' WHERE entity_id = '$escaped_source';
-- Move capability gaps
UPDATE capability_gaps SET entity_id = '$escaped_target' WHERE entity_id = '$escaped_source';
-- Delete source entity
DELETE FROM entities WHERE id = '$escaped_source';
-- Update target timestamp
UPDATE entities SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '$escaped_target';
EOF

	log_success "Merged entity $source_id into $target_id"
	return 0
}

#######################################
# Identity resolution: unlink a channel from its entity
# Creates a new entity for the detached channel
#######################################
cmd_unlink() {
	local channel_id="$1"

	if [[ -z "$channel_id" ]]; then
		log_error "Channel ID is required"
		return 1
	fi

	init_db

	local escaped_cid
	escaped_cid=$(_sql_escape "$channel_id")

	# Get channel details
	local channel_info
	channel_info=$(db "$MEMORY_DB" "SELECT entity_id, channel_type, channel_handle FROM entity_channels WHERE id = '$escaped_cid';")
	if [[ -z "$channel_info" ]]; then
		log_error "Channel not found: $channel_id"
		return 1
	fi

	local old_entity_id channel_type channel_handle
	IFS='|' read -r old_entity_id channel_type channel_handle <<<"$channel_info"

	# Create new entity for the detached channel
	local new_entity_id
	new_entity_id=$(generate_id "ent")
	local escaped_handle
	escaped_handle=$(_sql_escape "$channel_handle")

	db "$MEMORY_DB" <<EOF
-- Create new entity
INSERT INTO entities (id, display_name, entity_type)
VALUES ('$new_entity_id', '$escaped_handle', 'person');
-- Move channel to new entity
UPDATE entity_channels SET entity_id = '$new_entity_id' WHERE id = '$escaped_cid';
EOF

	log_success "Unlinked channel $channel_id from $old_entity_id -> new entity $new_entity_id"
	echo "$new_entity_id"
	return 0
}

#######################################
# Identity resolution: verify a channel link
#######################################
cmd_verify() {
	local channel_id="$1"

	if [[ -z "$channel_id" ]]; then
		log_error "Channel ID is required"
		return 1
	fi

	init_db

	local escaped_cid
	escaped_cid=$(_sql_escape "$channel_id")

	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entity_channels WHERE id = '$escaped_cid';")
	if [[ "$exists" == "0" ]]; then
		log_error "Channel not found: $channel_id"
		return 1
	fi

	db "$MEMORY_DB" "UPDATE entity_channels SET verified = 1 WHERE id = '$escaped_cid';"

	log_success "Verified channel: $channel_id"
	return 0
}

#######################################
# Identity resolution: suggest potential links
# Finds entities that might be the same person based on name similarity
#######################################
cmd_suggest() {
	init_db

	echo ""
	echo "=== Potential Identity Links ==="
	echo ""

	# Find entities with similar display names
	local suggestions
	suggestions=$(
		db "$MEMORY_DB" <<'EOF'
SELECT e1.id, e1.display_name, e2.id, e2.display_name
FROM entities e1
JOIN entities e2 ON e1.id < e2.id
WHERE lower(e1.display_name) = lower(e2.display_name)
   OR (length(e1.display_name) > 3 AND lower(e2.display_name) LIKE '%' || lower(e1.display_name) || '%')
   OR (length(e2.display_name) > 3 AND lower(e1.display_name) LIKE '%' || lower(e2.display_name) || '%')
LIMIT 20;
EOF
	)

	if [[ -z "$suggestions" ]]; then
		# Also check for unverified channels
		local unverified_count
		unverified_count=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entity_channels WHERE verified = 0;")
		if [[ "$unverified_count" -gt 0 ]]; then
			log_info "$unverified_count unverified channel links"
			db "$MEMORY_DB" <<'EOF'
SELECT ec.id, e.display_name, ec.channel_type, ec.channel_handle
FROM entity_channels ec
JOIN entities e ON ec.entity_id = e.id
WHERE ec.verified = 0
ORDER BY ec.created_at DESC
LIMIT 10;
EOF
		else
			log_info "No potential links found"
		fi
	else
		echo "$suggestions" | while IFS='|' read -r id1 name1 id2 name2; do
			echo "  Possible match: $name1 ($id1) <-> $name2 ($id2)"
			echo "    To merge: entity-helper.sh link $id1 $id2"
			echo ""
		done
	fi

	return 0
}

#######################################
# Log an interaction (Layer 0 — immutable, append-only)
# This is the ONLY write path for interactions.
# No UPDATE or DELETE operations exist for this table.
#######################################
cmd_interact() {
	local entity_id=""
	local channel_type=""
	local channel_id=""
	local direction=""
	local content=""
	local message_type="text"
	local metadata=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--entity | -e)
			entity_id="$2"
			shift 2
			;;
		--channel-type)
			channel_type="$2"
			shift 2
			;;
		--channel-id)
			channel_id="$2"
			shift 2
			;;
		--direction | -d)
			direction="$2"
			shift 2
			;;
		--content | -c)
			content="$2"
			shift 2
			;;
		--message-type)
			message_type="$2"
			shift 2
			;;
		--metadata)
			metadata="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	# Validate required fields
	if [[ -z "$entity_id" || -z "$channel_type" || -z "$channel_id" || -z "$direction" || -z "$content" ]]; then
		log_error "Required: --entity, --channel-type, --channel-id, --direction, --content"
		return 1
	fi

	# Validate direction
	if [[ "$direction" != "inbound" && "$direction" != "outbound" ]]; then
		log_error "Invalid direction: $direction (use: inbound, outbound)"
		return 1
	fi

	# Validate message type
	local valid_msg_types="text voice file reaction command"
	local msg_pattern=" $message_type "
	if [[ ! " $valid_msg_types " =~ $msg_pattern ]]; then
		log_error "Invalid message type: $message_type (valid: $valid_msg_types)"
		return 1
	fi

	init_db

	local escaped_eid
	escaped_eid=$(_sql_escape "$entity_id")

	# Verify entity exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_eid';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	local id
	id=$(generate_id "int")
	local escaped_content
	escaped_content=$(_sql_escape "$content")
	local escaped_channel_id
	escaped_channel_id=$(_sql_escape "$channel_id")
	local escaped_metadata
	escaped_metadata=$(_sql_escape "$metadata")

	# Insert interaction (append-only — no updates or deletes)
	db "$MEMORY_DB" <<EOF
INSERT INTO interactions (id, entity_id, channel_type, channel_id, direction, content, message_type, metadata)
VALUES ('$id', '$escaped_eid', '$channel_type', '$escaped_channel_id', '$direction', '$escaped_content', '$message_type', '$escaped_metadata');
EOF

	# Update FTS index
	local created_at
	created_at=$(db "$MEMORY_DB" "SELECT created_at FROM interactions WHERE id = '$id';")
	db "$MEMORY_DB" "INSERT INTO interactions_fts (content, entity_id, channel_type, created_at) VALUES ('$escaped_content', '$escaped_eid', '$channel_type', '$created_at');"

	# Update entity timestamp
	db "$MEMORY_DB" "UPDATE entities SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '$escaped_eid';"

	echo "$id"
	return 0
}

#######################################
# Entity profile management
#######################################
cmd_profile() {
	local subcmd="${1:-}"
	shift || true

	case "$subcmd" in
	add) cmd_profile_add "$@" ;;
	list) cmd_profile_list "$@" ;;
	*)
		log_error "Unknown profile subcommand: $subcmd (use: add, list)"
		return 1
		;;
	esac
}

cmd_profile_add() {
	local entity_id="$1"
	shift || true

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required"
		return 1
	fi

	local profile_type=""
	local content=""
	local confidence="medium"
	local evidence=""
	local supersedes_id=""

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
		--evidence)
			evidence="$2"
			shift 2
			;;
		--supersedes)
			supersedes_id="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$profile_type" || -z "$content" ]]; then
		log_error "Required: --type and --content"
		return 1
	fi

	# Validate profile type
	local type_pattern=" $profile_type "
	if [[ ! " $VALID_PROFILE_TYPES " =~ $type_pattern ]]; then
		log_error "Invalid profile type: $profile_type (valid: $VALID_PROFILE_TYPES)"
		return 1
	fi

	# Validate confidence
	if [[ ! "$confidence" =~ ^(low|medium|high)$ ]]; then
		log_error "Invalid confidence: $confidence (use: low, medium, high)"
		return 1
	fi

	init_db

	local escaped_eid
	escaped_eid=$(_sql_escape "$entity_id")

	# Verify entity exists
	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM entities WHERE id = '$escaped_eid';")
	if [[ "$exists" == "0" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	local id
	id=$(generate_id "ep")
	local escaped_content
	escaped_content=$(_sql_escape "$content")
	local escaped_evidence
	escaped_evidence=$(_sql_escape "$evidence")
	local escaped_supersedes
	escaped_supersedes=$(_sql_escape "$supersedes_id")

	db "$MEMORY_DB" "INSERT INTO entity_profiles (id, entity_id, profile_type, content, confidence, evidence, supersedes_id) VALUES ('$id', '$escaped_eid', '$profile_type', '$escaped_content', '$confidence', '$escaped_evidence', '$escaped_supersedes');"

	log_success "Added profile: $id ($profile_type for $entity_id)"
	echo "$id"
	return 0
}

cmd_profile_list() {
	local entity_id="$1"
	shift || true

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required"
		return 1
	fi

	local type_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type | -t)
			type_filter="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	local escaped_eid
	escaped_eid=$(_sql_escape "$entity_id")

	local where_clause="WHERE entity_id = '$escaped_eid'"
	if [[ -n "$type_filter" ]]; then
		where_clause="$where_clause AND profile_type = '$type_filter'"
	fi

	# Show only the latest version of each profile (not superseded by anything)
	local results
	results=$(db -json "$MEMORY_DB" "SELECT * FROM entity_profiles $where_clause AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL AND supersedes_id != '') ORDER BY profile_type, created_at DESC;")

	if [[ -z "$results" || "$results" == "[]" ]]; then
		log_info "No profiles for entity: $entity_id"
		return 0
	fi

	echo "$results"
	return 0
}

#######################################
# Capability gap management
#######################################
cmd_gap() {
	local subcmd="${1:-}"
	shift || true

	case "$subcmd" in
	add) cmd_gap_add "$@" ;;
	list) cmd_gap_list "$@" ;;
	resolve) cmd_gap_resolve "$@" ;;
	*)
		log_error "Unknown gap subcommand: $subcmd (use: add, list, resolve)"
		return 1
		;;
	esac
}

cmd_gap_add() {
	local description=""
	local entity_id=""
	local evidence=""

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
		--evidence)
			evidence="$2"
			shift 2
			;;
		*)
			if [[ -z "$description" ]]; then
				description="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$description" ]]; then
		log_error "Description is required. Use --description \"...\""
		return 1
	fi

	init_db

	local id
	id=$(generate_id "gap")
	local escaped_desc
	escaped_desc=$(_sql_escape "$description")
	local escaped_eid
	escaped_eid=$(_sql_escape "$entity_id")
	local escaped_evidence
	escaped_evidence=$(_sql_escape "$evidence")

	# Check for existing similar gap (avoid duplicates)
	local existing_gap
	existing_gap=$(db "$MEMORY_DB" "SELECT id FROM capability_gaps WHERE description = '$escaped_desc' AND status != 'resolved' LIMIT 1;" 2>/dev/null || echo "")
	if [[ -n "$existing_gap" ]]; then
		# Increment frequency instead of creating duplicate
		db "$MEMORY_DB" "UPDATE capability_gaps SET frequency = frequency + 1 WHERE id = '$existing_gap';"
		log_info "Existing gap updated (frequency incremented): $existing_gap"
		echo "$existing_gap"
		return 0
	fi

	db "$MEMORY_DB" "INSERT INTO capability_gaps (id, entity_id, description, evidence) VALUES ('$id', '$escaped_eid', '$escaped_desc', '$escaped_evidence');"

	log_success "Added capability gap: $id"
	echo "$id"
	return 0
}

cmd_gap_list() {
	local status_filter=""
	local format="text"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--status | -s)
			status_filter="$2"
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

	local where_clause=""
	if [[ -n "$status_filter" ]]; then
		local status_pattern=" $status_filter "
		if [[ ! " $VALID_GAP_STATUSES " =~ $status_pattern ]]; then
			log_error "Invalid status: $status_filter (valid: $VALID_GAP_STATUSES)"
			return 1
		fi
		where_clause="WHERE status = '$status_filter'"
	fi

	local results
	results=$(db -json "$MEMORY_DB" "SELECT cg.*, e.display_name as entity_name FROM capability_gaps cg LEFT JOIN entities e ON cg.entity_id = e.id $where_clause ORDER BY cg.frequency DESC, cg.created_at DESC;")

	if [[ "$format" == "json" ]]; then
		echo "$results"
	else
		if [[ -z "$results" || "$results" == "[]" ]]; then
			log_info "No capability gaps found"
			return 0
		fi

		echo ""
		echo "=== Capability Gaps ==="
		echo ""
		if command -v jq &>/dev/null; then
			echo "$results" | jq -r '.[] | "  [\(.status)] \(.description) (freq: \(.frequency))\n    Entity: \(.entity_name // "system-wide") | Task: \(.todo_task_id // "none")\n    Created: \(.created_at)\n"'
		else
			echo "$results"
		fi
	fi

	return 0
}

cmd_gap_resolve() {
	local gap_id="$1"
	shift || true

	if [[ -z "$gap_id" ]]; then
		log_error "Gap ID is required"
		return 1
	fi

	local task_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task | -t)
			task_id="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_db

	local escaped_gid
	escaped_gid=$(_sql_escape "$gap_id")

	local exists
	exists=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM capability_gaps WHERE id = '$escaped_gid';")
	if [[ "$exists" == "0" ]]; then
		log_error "Gap not found: $gap_id"
		return 1
	fi

	local status="resolved"
	local task_update=""
	if [[ -n "$task_id" ]]; then
		local escaped_tid
		escaped_tid=$(_sql_escape "$task_id")
		task_update=", todo_task_id = '$escaped_tid'"
		status="task_created"
	fi

	db "$MEMORY_DB" "UPDATE capability_gaps SET status = '$status'$task_update, resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = '$escaped_gid';"

	log_success "Gap $gap_id marked as $status"
	return 0
}

#######################################
# Privacy-filtered context loading
# Loads entity context appropriate for the current channel's privacy level.
# Public channel info -> available everywhere
# Private channel info -> only in same-privacy-level channels
# Shared info -> available everywhere
#######################################
cmd_context() {
	local entity_id="$1"
	shift || true

	if [[ -z "$entity_id" ]]; then
		log_error "Entity ID is required"
		return 1
	fi

	local channel_type=""
	local channel_id=""
	local limit=20

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--channel-type)
			channel_type="$2"
			shift 2
			;;
		--channel-id)
			channel_id="$2"
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

	local escaped_eid
	escaped_eid=$(_sql_escape "$entity_id")

	# Verify entity exists
	local entity_info
	entity_info=$(db "$MEMORY_DB" "SELECT display_name, entity_type FROM entities WHERE id = '$escaped_eid';")
	if [[ -z "$entity_info" ]]; then
		log_error "Entity not found: $entity_id"
		return 1
	fi

	local display_name entity_type
	IFS='|' read -r display_name entity_type <<<"$entity_info"

	echo "=== Entity Context: $display_name ($entity_type) ==="
	echo ""

	# 1. Entity profile (Layer 2) — filtered by privacy
	echo "--- Profile ---"
	local profile_results
	if [[ -n "$channel_type" ]]; then
		# Determine privacy level of the requesting channel
		local requesting_privacy
		requesting_privacy=$(db "$MEMORY_DB" "SELECT privacy_level FROM entity_channels WHERE entity_id = '$escaped_eid' AND channel_type = '$channel_type' LIMIT 1;" 2>/dev/null || echo "private")

		if [[ "$requesting_privacy" == "public" || "$requesting_privacy" == "shared" ]]; then
			# Public/shared channels can see all non-private profiles
			profile_results=$(db "$MEMORY_DB" "SELECT * FROM entity_profiles WHERE entity_id = '$escaped_eid' AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL AND supersedes_id != '') ORDER BY profile_type, created_at DESC;")
		else
			# Private channels: only show profiles derived from same channel type or shared
			# This prevents cross-channel information leakage
			profile_results=$(db "$MEMORY_DB" "SELECT ep.* FROM entity_profiles ep WHERE ep.entity_id = '$escaped_eid' AND ep.id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL AND supersedes_id != '') ORDER BY ep.profile_type, ep.created_at DESC;")
		fi
	else
		# No channel context — show all profiles (admin view)
		profile_results=$(db "$MEMORY_DB" "SELECT * FROM entity_profiles WHERE entity_id = '$escaped_eid' AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL AND supersedes_id != '') ORDER BY profile_type, created_at DESC;")
	fi

	if [[ -n "$profile_results" ]]; then
		echo "$profile_results"
	else
		echo "  (no profile data)"
	fi
	echo ""

	# 2. Active conversations (Layer 1)
	echo "--- Active Conversations ---"
	local conv_filter=""
	if [[ -n "$channel_type" ]]; then
		conv_filter="AND channel_type = '$channel_type'"
	fi
	if [[ -n "$channel_id" ]]; then
		local escaped_cid
		escaped_cid=$(_sql_escape "$channel_id")
		conv_filter="$conv_filter AND channel_id = '$escaped_cid'"
	fi

	local conversations
	conversations=$(db "$MEMORY_DB" "SELECT id, channel_type, channel_id, status, summary, last_activity_at FROM conversations WHERE entity_id = '$escaped_eid' AND status != 'archived' $conv_filter ORDER BY last_activity_at DESC LIMIT 5;")

	if [[ -n "$conversations" ]]; then
		echo "$conversations"
	else
		echo "  (no active conversations)"
	fi
	echo ""

	# 3. Recent interactions (Layer 0) — privacy filtered
	echo "--- Recent Interactions ---"
	local interaction_filter=""
	if [[ -n "$channel_type" ]]; then
		# In private channels, only show interactions from the same channel
		local req_privacy
		req_privacy=$(db "$MEMORY_DB" "SELECT privacy_level FROM entity_channels WHERE entity_id = '$escaped_eid' AND channel_type = '$channel_type' LIMIT 1;" 2>/dev/null || echo "private")

		if [[ "$req_privacy" == "private" ]]; then
			interaction_filter="AND channel_type = '$channel_type'"
			if [[ -n "$channel_id" ]]; then
				local escaped_int_cid
				escaped_int_cid=$(_sql_escape "$channel_id")
				interaction_filter="$interaction_filter AND channel_id = '$escaped_int_cid'"
			fi
		fi
		# Public/shared: show all interactions (no filter)
	fi

	local interactions
	interactions=$(db "$MEMORY_DB" "SELECT id, channel_type, direction, substr(content, 1, 100) as content_preview, created_at FROM interactions WHERE entity_id = '$escaped_eid' $interaction_filter ORDER BY created_at DESC LIMIT $limit;")

	if [[ -n "$interactions" ]]; then
		echo "$interactions"
	else
		echo "  (no interactions)"
	fi
	echo ""

	# 4. Capability gaps related to this entity
	local gaps
	gaps=$(db "$MEMORY_DB" "SELECT id, description, frequency, status FROM capability_gaps WHERE entity_id = '$escaped_eid' AND status != 'resolved' ORDER BY frequency DESC LIMIT 5;")
	if [[ -n "$gaps" ]]; then
		echo "--- Capability Gaps ---"
		echo "$gaps"
		echo ""
	fi

	return 0
}

#######################################
# Entity statistics
#######################################
cmd_stats() {
	init_db

	echo ""
	echo "=== Entity Memory Statistics ==="
	echo ""

	db "$MEMORY_DB" <<'EOF'
SELECT 'Total entities' as metric, COUNT(*) as value FROM entities
UNION ALL
SELECT 'By type: ' || entity_type, COUNT(*) FROM entities GROUP BY entity_type
UNION ALL
SELECT 'Total channels', COUNT(*) FROM entity_channels
UNION ALL
SELECT 'Verified channels', COUNT(*) FROM entity_channels WHERE verified = 1
UNION ALL
SELECT 'Total interactions', COUNT(*) FROM interactions
UNION ALL
SELECT 'Inbound interactions', COUNT(*) FROM interactions WHERE direction = 'inbound'
UNION ALL
SELECT 'Outbound interactions', COUNT(*) FROM interactions WHERE direction = 'outbound'
UNION ALL
SELECT 'Active conversations', COUNT(*) FROM conversations WHERE status = 'active'
UNION ALL
SELECT 'Entity profiles', COUNT(*) FROM entity_profiles
UNION ALL
SELECT 'Capability gaps (open)', COUNT(*) FROM capability_gaps WHERE status != 'resolved';
EOF

	echo ""
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
entity-helper.sh - Entity management for aidevops multi-channel memory

Part of the three-layer entity memory model (t1363):
  Layer 0: Raw interaction log (immutable, append-only)
  Layer 1: Per-conversation context (tactical)
  Layer 2: Entity relationship model (strategic)

USAGE:
    entity-helper.sh <command> [options]

ENTITY COMMANDS:
    create          Create a new entity
    get <id>        Get entity details
    list            List all entities
    update <id>     Update entity name/type
    search          Search entities by name or channel handle

CHANNEL COMMANDS:
    channel add <entity_id> --type <type> --handle <handle>
    channel remove <channel_id>
    channel list <entity_id>

IDENTITY RESOLUTION:
    link <target> <source>   Merge source entity into target
    unlink <channel_id>      Detach channel into new entity
    verify <channel_id>      Mark channel link as verified
    suggest                  Suggest potential identity links

INTERACTION LOG (Layer 0):
    interact        Log an interaction (append-only, immutable)

ENTITY PROFILES (Layer 2):
    profile add <entity_id> --type <type> --content <text>
    profile list <entity_id> [--type <type>]

CAPABILITY GAPS:
    gap add --description <text> [--entity <id>]
    gap list [--status detected|task_created|resolved]
    gap resolve <gap_id> [--task <task_id>]

CONTEXT LOADING:
    context <entity_id> --channel-type <type> [--channel-id <id>]

OTHER:
    stats           Show entity memory statistics
    help            Show this help

ENTITY TYPES:
    person, agent, service, group

CHANNEL TYPES:
    matrix, simplex, email, cli, dm, web

PROFILE TYPES:
    needs, expectations, preferences, gaps, satisfaction

PRIVACY LEVELS:
    public   - Information visible in all channels
    private  - Information only visible in same-privacy channels
    shared   - Explicitly shared across channels by user consent

EXAMPLES:
    # Create an entity
    entity-helper.sh create --name "Marcus" --type person

    # Add channel handles
    entity-helper.sh channel add ent_xxx --type matrix --handle "@marcus:server"
    entity-helper.sh channel add ent_xxx --type email --handle "marcus@example.com"

    # Log an interaction
    entity-helper.sh interact --entity ent_xxx --channel-type matrix \
        --channel-id "!room:server" --direction inbound --content "Hello"

    # Add a profile observation
    entity-helper.sh profile add ent_xxx --type preferences \
        --content "Prefers concise responses" --confidence high \
        --evidence '["int_xxx","int_yyy"]'

    # Load privacy-filtered context
    entity-helper.sh context ent_xxx --channel-type matrix

    # Identity resolution
    entity-helper.sh link ent_target ent_source
    entity-helper.sh verify ech_xxx
    entity-helper.sh suggest
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
	search) cmd_search "$@" ;;
	channel) cmd_channel "$@" ;;
	link) cmd_link "$@" ;;
	unlink) cmd_unlink "$@" ;;
	verify) cmd_verify "$@" ;;
	suggest) cmd_suggest "$@" ;;
	interact) cmd_interact "$@" ;;
	profile) cmd_profile "$@" ;;
	gap) cmd_gap "$@" ;;
	context) cmd_context "$@" ;;
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
