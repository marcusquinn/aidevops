#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Entity Channel Library -- Channel Linking + Profile Management
# =============================================================================
# Channel identity and profile commands for the entity memory system (p035 / t1363).
# Handles linking entities to channel identifiers and managing versioned profiles.
#
# Usage: source "${SCRIPT_DIR}/entity-channel-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error, log_warn, log_success, log_info)
#   - entity-helper.sh (entity_db, generate_profile_id, sql_escape,
#     normalize_channel_id, init_entity_db, ENTITY_MEMORY_DB,
#     VALID_CHANNELS)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ENTITY_CHANNEL_LIB_LOADED:-}" ]] && return 0
_ENTITY_CHANNEL_LIB_LOADED=1

# SCRIPT_DIR fallback — required when sourced from a directory other than SCRIPT_DIR
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Channel Identity Linking
# =============================================================================

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
	local normalized_channel_id
	normalized_channel_id=$(normalize_channel_id "$channel" "$channel_id")
	esc_channel_id=$(sql_escape "$normalized_channel_id")
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
		log_error "Channel identity $channel:$normalized_channel_id is already linked to entity $existing_entity"
		log_error "Unlink it first with: entity-helper.sh unlink $existing_entity --channel $channel --channel-id \"$normalized_channel_id\""
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

	log_success "Linked $channel:$normalized_channel_id -> entity $entity_id ($confidence)"
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
	channel_id=$(normalize_channel_id "$channel" "$channel_id")
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

	local normalized_channel_id
	normalized_channel_id=$(normalize_channel_id "$channel" "$channel_id")
	local esc_channel_id
	esc_channel_id=$(sql_escape "$normalized_channel_id")

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
		log_info "No matching entities found for $channel:$normalized_channel_id"
		log_info "Create one with: entity-helper.sh create --name \"Name\" --channel $channel --channel-id \"$normalized_channel_id\""
		return 0
	fi

	echo "Suggested matches for $channel:$normalized_channel_id:"
	echo "$suggestions"
	echo ""
	log_info "To link: entity-helper.sh link <entity_id> --channel $channel --channel-id \"$normalized_channel_id\" --verified"
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
	channel_id=$(normalize_channel_id "$channel" "$channel_id")
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

# =============================================================================
# Profile Management (versioned)
# =============================================================================

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
