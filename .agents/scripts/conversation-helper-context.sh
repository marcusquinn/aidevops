#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Conversation Context & Summarisation -- context loading, summaries
# =============================================================================
# Provides context loading for AI models and immutable summary generation
# with source range references. Extracted from conversation-helper.sh.
#
# Usage: source "${SCRIPT_DIR}/conversation-helper-context.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error, log_info, log_success, log_warn)
#   - conversation-helper.sh orchestrator (conv_db, conv_sql_escape, init_conv_db,
#     generate_summary_id, CONV_MEMORY_DB, AI_RESEARCH_SCRIPT)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CONV_CONTEXT_LIB_LOADED:-}" ]] && return 0
_CONV_CONTEXT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Context Functions ---

#######################################
# Output conversation context as JSON
# Args: esc_id esc_entity recent_messages
#######################################
_context_output_json() {
	local esc_id="$1"
	local esc_entity="$2"
	local recent_messages="$3"

	# Capture each query result; sqlite3 -json may return empty string (not [])
	# for zero-row results on some SQLite builds — guard with ${var:-[]} to
	# ensure the hand-assembled JSON object is always valid.
	local _conv_json _profile_json _summary_json _messages_json

	_conv_json=$(conv_db -json "$CONV_MEMORY_DB" "SELECT id, entity_id, channel, channel_id, topic, status, interaction_count, last_interaction_at FROM conversations WHERE id = '$esc_id';")

	_profile_json=$(conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT profile_key, profile_value, confidence
FROM entity_profiles
WHERE entity_id = '$esc_entity'
  AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY profile_key;
EOF
)

	_summary_json=$(conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT cs.id, cs.summary, cs.source_range_start, cs.source_range_end,
    cs.source_interaction_count, cs.tone_profile, cs.pending_actions, cs.created_at
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
  AND cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
)

	_messages_json=$(conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT i.id, i.direction, i.content, i.created_at
FROM interactions i
WHERE i.conversation_id = '$esc_id'
ORDER BY i.created_at DESC
LIMIT $recent_messages;
EOF
)

	echo "{"
	echo "\"conversation\":"
	echo "${_conv_json:-[]}"
	echo ","
	echo "\"entity_profile\":"
	echo "${_profile_json:-[]}"
	echo ","
	echo "\"latest_summary\":"
	echo "${_summary_json:-[]}"
	echo ","
	echo "\"recent_messages\":"
	echo "${_messages_json:-[]}"
	echo "}"
	return 0
}

#######################################
# Print entity profile and conversation summary sections (text context)
# Args: esc_id esc_entity
#######################################
_context_text_profile_and_summary() {
	local esc_id="$1"
	local esc_entity="$2"

	# Entity profile
	local profile_data
	profile_data=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT profile_key || ': ' || profile_value
FROM entity_profiles
WHERE entity_id = '$esc_entity'
  AND id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
ORDER BY profile_key;
EOF
	)
	if [[ -n "$profile_data" ]]; then
		echo "Known preferences:"
		echo "$profile_data" | while IFS= read -r line; do
			echo "  - $line"
		done
		echo ""
	fi

	# Latest summary (Layer 1)
	local latest_summary
	latest_summary=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.summary
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
  AND cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
	)
	if [[ -n "$latest_summary" ]]; then
		echo "Conversation summary:"
		echo "  $latest_summary"
		echo ""
	fi

	# Pending actions from latest summary
	local pending_actions
	pending_actions=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.pending_actions
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
  AND cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
  AND cs.pending_actions != '[]'
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
	)
	if [[ -n "$pending_actions" && "$pending_actions" != "[]" ]]; then
		echo "Pending actions: $pending_actions"
		echo ""
	fi

	return 0
}

#######################################
# Print recent messages section (text context), with optional privacy filter
# Args: esc_id recent_messages privacy_filter
#######################################
_context_text_recent_messages() {
	local esc_id="$1"
	local recent_messages="$2"
	local privacy_filter="$3"

	echo "Recent messages (last $recent_messages):"
	local messages
	messages=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT '[' || i.direction || '] ' || i.created_at || char(10) ||
       '  ' || substr(i.content, 1, 200) ||
       CASE WHEN length(i.content) > 200 THEN '...' ELSE '' END
FROM interactions i
WHERE i.conversation_id = '$esc_id'
ORDER BY i.created_at DESC
LIMIT $recent_messages;
EOF
	)

	if [[ -z "$messages" ]]; then
		echo "  (no messages yet)"
	else
		if [[ "$privacy_filter" == true ]]; then
			messages=$(echo "$messages" | sed \
				-e 's/[a-zA-Z0-9._%+-]\+@[a-zA-Z0-9.-]\+\.[a-zA-Z]\{2,\}/[EMAIL]/g' \
				-e 's/\b[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\b/[IP]/g' \
				-e 's/sk-[a-zA-Z0-9_-]\{20,\}/[API_KEY]/g')
		fi
		echo "$messages"
	fi

	return 0
}

#######################################
# Output conversation context as plain text
# Args: esc_id esc_entity entity_name entity_type channel topic recent_messages privacy_filter
#######################################
_context_output_text() {
	local esc_id="$1"
	local esc_entity="$2"
	local entity_name="$3"
	local entity_type="$4"
	local channel="$5"
	local topic="$6"
	local recent_messages="$7"
	local privacy_filter="$8"

	# Model-agnostic plain text context block
	echo "--- CONVERSATION CONTEXT ---"
	echo ""
	echo "Entity: ${entity_name:-Unknown} (${entity_type:-unknown})"
	echo "Channel: $channel"
	if [[ -n "$topic" && "$topic" != "" ]]; then
		echo "Topic: $topic"
	fi
	echo ""

	_context_text_profile_and_summary "$esc_id" "$esc_entity"
	_context_text_recent_messages "$esc_id" "$recent_messages" "$privacy_filter"

	echo ""
	echo "--- END CONTEXT ---"
	return 0
}

#######################################
# Load conversation context for an AI model
# Produces model-agnostic plain text with:
#   1. Entity profile summary
#   2. Latest Layer 1 summary (if available)
#   3. Recent Layer 0 messages
# This is the primary context-loading function for channel integrations.
#######################################
cmd_context() {
	local conv_id="${1:-}"
	local summary_tokens=2000
	local recent_messages=10
	local format="text"
	local privacy_filter=false

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--summary-tokens)
			summary_tokens="$2"
			shift 2
			;;
		--recent-messages)
			recent_messages="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		--privacy-filter)
			privacy_filter=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$conv_id" ]]; then
		log_error "Conversation ID is required. Usage: conversation-helper.sh context <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Verify conversation exists and get entity_id
	local conv_data
	conv_data=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT c.entity_id, c.channel, c.channel_id, c.topic, c.status, c.interaction_count,
    e.name as entity_name, e.type as entity_type
FROM conversations c
LEFT JOIN entities e ON c.entity_id = e.id
WHERE c.id = '$esc_id';
EOF
	)

	if [[ -z "$conv_data" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi

	# Parse all required fields from conv_data (already fetched above) instead
	# of issuing 5 more round-trips to SQLite.
	# SELECT order: entity_id | channel | channel_id | topic | status | interaction_count | entity_name | entity_type
	local entity_id channel topic entity_name entity_type _channel_id _status _int_count
	IFS='|' read -r entity_id channel _channel_id topic _status _int_count entity_name entity_type <<<"$conv_data"

	local esc_entity
	esc_entity=$(conv_sql_escape "$entity_id")

	if [[ "$format" == "json" ]]; then
		_context_output_json "$esc_id" "$esc_entity" "$recent_messages"
	else
		_context_output_text "$esc_id" "$esc_entity" "$entity_name" "$entity_type" \
			"$channel" "$topic" "$recent_messages" "$privacy_filter"
	fi

	return 0
}

# --- Summarisation Functions ---

#######################################
# Count interactions not yet covered by any summary
#######################################
count_unsummarised_interactions() {
	local conv_id="$1"
	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Find the last summarised interaction ID
	local last_summarised_end
	last_summarised_end=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.source_range_end
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
	)

	if [[ -z "$last_summarised_end" ]]; then
		# No summaries yet — all interactions are unsummarised
		conv_db "$CONV_MEMORY_DB" "SELECT COUNT(*) FROM interactions WHERE conversation_id = '$esc_id';"
	else
		local esc_end
		esc_end=$(conv_sql_escape "$last_summarised_end")
		# Count interactions created after the last summarised one
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT COUNT(*) FROM interactions
WHERE conversation_id = '$esc_id'
  AND created_at > (SELECT created_at FROM interactions WHERE id = '$esc_end');
EOF
	fi

	return 0
}

#######################################
# Fetch interaction data to summarise for a conversation.
# Prints interaction rows to stdout; returns 1 if nothing to summarise.
# Args: esc_id conv_id force
#######################################
_summarise_fetch_interactions() {
	local esc_id="$1"
	local conv_id="$2"
	local force="$3"

	# Find the last summarised interaction boundary
	local last_summarised_end
	last_summarised_end=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.source_range_end
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
	)

	local interactions_query
	if [[ -z "$last_summarised_end" ]]; then
		interactions_query="SELECT id, direction, content, created_at FROM interactions WHERE conversation_id = '$esc_id' ORDER BY created_at ASC"
	else
		local esc_end
		esc_end=$(conv_sql_escape "$last_summarised_end")
		interactions_query="SELECT id, direction, content, created_at FROM interactions WHERE conversation_id = '$esc_id' AND created_at > (SELECT created_at FROM interactions WHERE id = '$esc_end') ORDER BY created_at ASC"
	fi

	local interaction_data
	interaction_data=$(conv_db "$CONV_MEMORY_DB" "$interactions_query;")

	if [[ -z "$interaction_data" ]]; then
		if [[ "$force" != true ]]; then
			log_info "No unsummarised interactions for conversation $conv_id"
			return 1
		fi
		# Force mode: re-summarise all interactions
		interaction_data=$(conv_db "$CONV_MEMORY_DB" "SELECT id, direction, content, created_at FROM interactions WHERE conversation_id = '$esc_id' ORDER BY created_at ASC;")
		if [[ -z "$interaction_data" ]]; then
			log_warn "No interactions at all for conversation $conv_id"
			return 1
		fi
	fi

	echo "$interaction_data"
	return 0
}

#######################################
# Call AI to generate summary, tone profile, and pending actions.
# Falls back to a heuristic summary if AI is unavailable.
# Prints three lines to stdout: summary|tone_profile|pending_actions
# Args: entity_name int_count formatted_interactions interaction_data
#######################################
_summarise_call_ai() {
	local entity_name="$1"
	local int_count="$2"
	local formatted_interactions="$3"
	local interaction_data="$4"

	local ai_prompt
	ai_prompt="Analyse this conversation with ${entity_name:-an entity} and produce a JSON response with exactly these fields:
{
  \"summary\": \"A concise 2-4 sentence summary of what was discussed, decisions made, and current state\",
  \"tone_profile\": {
    \"formality\": \"formal|casual|mixed\",
    \"technical_level\": \"high|medium|low\",
    \"sentiment\": \"positive|neutral|negative|mixed\",
    \"pace\": \"fast|moderate|slow\"
  },
  \"pending_actions\": [\"list of any commitments or follow-ups mentioned\"]
}

Conversation ($int_count messages):
$formatted_interactions

Rules:
- Summary must be factual, not interpretive
- Pending actions only if explicitly mentioned
- If no pending actions, use empty array []
- Respond with ONLY the JSON, no markdown fences"

	local ai_response=""
	if [[ -x "$AI_RESEARCH_SCRIPT" ]]; then
		ai_response=$("$AI_RESEARCH_SCRIPT" --model haiku --prompt "$ai_prompt" 2>/dev/null || echo "")
	fi

	local summary="" tone_profile="{}" pending_actions="[]"

	if [[ -n "$ai_response" ]] && command -v jq &>/dev/null; then
		summary=$(echo "$ai_response" | jq -r '.summary // empty' 2>/dev/null || echo "")
		tone_profile=$(echo "$ai_response" | jq -c '.tone_profile // {}' 2>/dev/null || echo "{}")
		pending_actions=$(echo "$ai_response" | jq -c '.pending_actions // []' 2>/dev/null || echo "[]")
	fi

	# Fallback: generate basic summary without AI
	if [[ -z "$summary" ]]; then
		summary="Conversation with ${entity_name:-entity} containing $int_count messages. "
		local first_msg last_msg
		first_msg=$(echo "$interaction_data" | head -1 | cut -d'|' -f3 | head -c 80)
		last_msg=$(echo "$interaction_data" | tail -1 | cut -d'|' -f3 | head -c 80)
		summary="${summary}Started with: \"${first_msg}...\". "
		if [[ "$int_count" -gt 1 ]]; then
			summary="${summary}Most recent: \"${last_msg}...\""
		fi
		tone_profile="{}"
		pending_actions="[]"
	fi

	# Output as pipe-delimited record (callers parse with IFS)
	printf '%s\n%s\n%s\n' "$summary" "$tone_profile" "$pending_actions"
	return 0
}

#######################################
# Store an immutable summary record and update the conversation row.
# Prints the new summary ID to stdout.
# Args: esc_id conv_id summary tone_profile pending_actions first_int_id last_int_id int_count
#######################################
_summarise_store() {
	local esc_id="$1"
	local conv_id="$2"
	local summary="$3"
	local tone_profile="$4"
	local pending_actions="$5"
	local first_int_id="$6"
	local last_int_id="$7"
	local int_count="$8"

	# Find current summary to supersede
	local current_summary_id
	current_summary_id=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.id FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
  AND cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
ORDER BY cs.created_at DESC
LIMIT 1;
EOF
	)

	local supersedes_clause="NULL"
	if [[ -n "$current_summary_id" ]]; then
		supersedes_clause="'$(conv_sql_escape "$current_summary_id")'"
	fi

	local sum_id
	sum_id=$(generate_summary_id)
	local esc_summary esc_tone esc_actions esc_first esc_last
	esc_summary=$(conv_sql_escape "$summary")
	esc_tone=$(conv_sql_escape "$tone_profile")
	esc_actions=$(conv_sql_escape "$pending_actions")
	esc_first=$(conv_sql_escape "$first_int_id")
	esc_last=$(conv_sql_escape "$last_int_id")

	conv_db "$CONV_MEMORY_DB" <<EOF
INSERT INTO conversation_summaries
    (id, conversation_id, summary, source_range_start, source_range_end,
     source_interaction_count, tone_profile, pending_actions, supersedes_id)
VALUES ('$sum_id', '$esc_id', '$esc_summary', '$esc_first', '$esc_last',
        $int_count, '$esc_tone', '$esc_actions', $supersedes_clause);
EOF

	conv_db "$CONV_MEMORY_DB" <<EOF
UPDATE conversations SET
    summary = '$esc_summary',
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
WHERE id = '$esc_id';
EOF

	log_success "Generated summary $sum_id for conversation $conv_id ($int_count interactions, range: $first_int_id..$last_int_id)"
	if [[ -n "$current_summary_id" ]]; then
		log_info "Supersedes previous summary: $current_summary_id"
	fi
	echo "$sum_id"
	return 0
}

#######################################
# Generate an immutable summary for a conversation
# Uses AI (haiku tier) to produce a concise summary with:
#   - Key topics discussed
#   - Decisions made
#   - Pending actions
#   - Tone profile
# The summary references the source interaction range.
#######################################
cmd_summarise() {
	local conv_id="${1:-}"
	local force=false

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$conv_id" ]]; then
		log_error "Conversation ID is required. Usage: conversation-helper.sh summarise <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	# Verify conversation exists
	local exists
	exists=$(conv_db "$CONV_MEMORY_DB" "SELECT COUNT(*) FROM conversations WHERE id = '$esc_id';")
	if [[ "$exists" == "0" ]]; then
		log_error "Conversation not found: $conv_id"
		return 1
	fi

	# Fetch interactions to summarise (returns 1 with log if nothing to do)
	local interaction_data
	interaction_data=$(_summarise_fetch_interactions "$esc_id" "$conv_id" "$force") || return 0

	# Get first/last IDs and count for source range
	local first_int_id last_int_id int_count
	first_int_id=$(echo "$interaction_data" | head -1 | cut -d'|' -f1)
	last_int_id=$(echo "$interaction_data" | tail -1 | cut -d'|' -f1)
	int_count=$(echo "$interaction_data" | wc -l | tr -d ' ')

	# Format interactions for AI summarisation
	local formatted_interactions=""
	while IFS='|' read -r int_id direction content timestamp; do
		formatted_interactions="${formatted_interactions}[${direction}] ${timestamp}: ${content}
"
	done <<<"$interaction_data"

	# Get entity name for context
	local entity_name
	entity_name=$(
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT e.name FROM conversations c
JOIN entities e ON c.entity_id = e.id
WHERE c.id = '$esc_id';
EOF
	)

	# Generate summary via AI (with heuristic fallback)
	# _summarise_call_ai prints exactly 3 newline-separated lines; parse with
	# read instead of spawning 3 sed processes.
	local ai_output summary tone_profile pending_actions
	ai_output=$(_summarise_call_ai "$entity_name" "$int_count" "$formatted_interactions" "$interaction_data")
	{ read -r summary; read -r tone_profile; read -r pending_actions; } <<<"$ai_output"

	# Store and return the new summary ID
	_summarise_store "$esc_id" "$conv_id" "$summary" "$tone_profile" "$pending_actions" \
		"$first_int_id" "$last_int_id" "$int_count"
	return 0
}

#######################################
# List summaries for a conversation
#######################################
cmd_summaries() {
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
		log_error "Conversation ID is required. Usage: conversation-helper.sh summaries <conversation_id>"
		return 1
	fi

	init_conv_db

	local esc_id
	esc_id=$(conv_sql_escape "$conv_id")

	if [[ "$format" == "json" ]]; then
		conv_db -json "$CONV_MEMORY_DB" <<EOF
SELECT cs.id, cs.summary, cs.source_range_start, cs.source_range_end,
    cs.source_interaction_count, cs.tone_profile, cs.pending_actions,
    cs.supersedes_id, cs.created_at,
    CASE WHEN cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
         THEN 1 ELSE 0 END as is_current
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
ORDER BY cs.created_at DESC;
EOF
	else
		echo ""
		echo "=== Summaries for $conv_id ==="
		echo ""
		conv_db "$CONV_MEMORY_DB" <<EOF
SELECT cs.id || ' | ' || cs.created_at || ' | msgs:' || cs.source_interaction_count ||
    ' | range:' || cs.source_range_start || '..' || cs.source_range_end ||
    CASE WHEN cs.id NOT IN (SELECT supersedes_id FROM conversation_summaries WHERE supersedes_id IS NOT NULL)
         THEN ' <- CURRENT' ELSE '' END ||
    char(10) || '  ' || substr(cs.summary, 1, 120) ||
    CASE WHEN length(cs.summary) > 120 THEN '...' ELSE '' END
FROM conversation_summaries cs
WHERE cs.conversation_id = '$esc_id'
ORDER BY cs.created_at DESC;
EOF
	fi

	return 0
}
