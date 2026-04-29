#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Conversation Interaction -- idle detection, tone analysis, messaging
# =============================================================================
# Provides AI-judged idle detection (replaces fixed sessionIdleTimeout),
# tone profile extraction, and message management. Extracted from
# conversation-helper.sh.
#
# Usage: source "${SCRIPT_DIR}/conversation-helper-interaction.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error, log_info, log_success, log_warn)
#   - conversation-helper.sh orchestrator (conv_db, conv_sql_escape, init_conv_db,
#     CONV_MEMORY_DB, AI_RESEARCH_SCRIPT, VALID_CONV_DIRECTIONS)
#   - conversation-helper-lifecycle.sh (cmd_resume, cmd_archive)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONV_INTERACTION_LIB_LOADED:-}" ]] && return 0
_CONV_INTERACTION_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Idle Detection ---

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

	# Get conversation metadata in a single query instead of two round-trips.
	# Columns: last_interaction_at | interaction_count
	local _conv_row last_activity interaction_count
	_conv_row=$(conv_db "$CONV_MEMORY_DB" "SELECT last_interaction_at, interaction_count FROM conversations WHERE id = '$esc_id';" 2>/dev/null || echo "")
	IFS='|' read -r last_activity interaction_count <<<"$_conv_row"
	interaction_count="${interaction_count:-0}"

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
	last_epoch=$(date -d "$last_activity" +%s 2>/dev/null || TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_activity" +%s 2>/dev/null || echo "0")
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
	# interaction_count already fetched in the combined query at the top of this function.

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

# --- Tone Analysis ---

#######################################
# Extract tone profile from recent messages using AI (haiku tier).
# Prints tone JSON to stdout, or "{}" if AI unavailable.
# Args: esc_id format
# Returns 1 if no messages to analyse (caller should return early).
#######################################
_tone_extract_from_messages() {
	local esc_id="$1"
	local format="$2"

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
		return 1
	fi

	local tone_data="{}"
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
	fi

	echo "$tone_data"
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
		tone_data=$(_tone_extract_from_messages "$esc_id" "$format") || return 0
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

# --- Messaging ---

#######################################
# Log an interaction via entity-helper.sh (primary) or direct SQLite (fallback).
# Prints the new interaction ID to stdout.
# Args: esc_id entity_id channel channel_id conv_id direction content metadata
#######################################
_add_message_log_interaction() {
	local esc_id="$1"
	local entity_id="$2"
	local channel="$3"
	local channel_id="$4"
	local conv_id="$5"
	local direction="$6"
	local content="$7"
	local metadata="$8"

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
		_add_message_direct_log "$esc_id" "$entity_id" "$channel" "$channel_id" \
			"$conv_id" "$direction" "$content" "$metadata"
	fi
	return 0
}

#######################################
# Fallback: log an interaction directly to SQLite when entity-helper.sh
# is not available. Applies privacy filter and secret detection.
# Prints the new interaction ID to stdout.
# Args: esc_id entity_id channel channel_id conv_id direction content metadata
#######################################
_add_message_direct_log() {
	local esc_id="$1"
	local entity_id="$2"
	local channel="$3"
	local channel_id="$4"
	local conv_id="$5"
	local direction="$6"
	local content="$7"
	local metadata="$8"

	log_warn "entity-helper.sh not found — logging interaction directly"

	# Privacy filter — single sed invocation with multiple -e expressions
	content=$(echo "$content" | sed \
		-e 's/<private>[^<]*<\/private>//g' \
		-e 's/  */ /g' \
		-e 's/^ *//;s/ *$//')
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

	# Get all conversation details in a single query instead of 4 round-trips.
	# Columns: entity_id | channel | channel_id | status
	local _conv_row conv_entity_id channel channel_id status
	_conv_row=$(conv_db "$CONV_MEMORY_DB" "SELECT entity_id, channel, channel_id, status FROM conversations WHERE id = '$esc_id';" 2>/dev/null || echo "")
	if [[ -z "$_conv_row" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi
	IFS='|' read -r conv_entity_id channel channel_id status <<<"$_conv_row"

	# Use provided entity_id or fall back to conversation's entity
	if [[ -z "$entity_id" ]]; then
		entity_id="$conv_entity_id"
	fi
	if [[ "$status" != "active" ]]; then
		log_info "Resuming $status conversation $conv_id"
		cmd_resume "$conv_id" >/dev/null
	fi

	# Delegate to entity-helper.sh (primary) or direct log (fallback).
	# entity-helper.sh log-interaction already updates conversation counters
	# (interaction_count, last_interaction_at) when --conversation-id is passed,
	# so we must NOT duplicate that update here.
	_add_message_log_interaction "$esc_id" "$entity_id" "$channel" "$channel_id" \
		"$conv_id" "$direction" "$content" "$metadata"
	return 0
}
