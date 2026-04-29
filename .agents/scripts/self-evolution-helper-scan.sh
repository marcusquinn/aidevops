#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Self-Evolution Scan -- Pattern scanning from entity interactions
# =============================================================================
# AI-powered and heuristic pattern detection for capability gaps.
# Analyses recent interactions to identify missing features, workflow gaps,
# and UX friction points.
#
# Usage: source "${SCRIPT_DIR}/self-evolution-helper-scan.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_success)
#   - self-evolution-helper-db.sh (evol_db, evol_sql_escape, init_evol_db, hours_ago_iso)
#   - EVOL_MEMORY_DB, EVOL_AI_RESEARCH_SCRIPT, DEFAULT_SCAN_WINDOW_HOURS,
#     MIN_INTERACTIONS_FOR_SCAN must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SELF_EVOL_SCAN_LIB_LOADED:-}" ]] && return 0
_SELF_EVOL_SCAN_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Parse arguments for scan-patterns command
# Outputs: entity_filter, since, limit, format (via stdout assignments)
#######################################
_scan_patterns_parse_args() {
	# Callers set these variables before calling; we modify them in place
	# by echoing "KEY=VALUE" lines that the caller evals.
	local _entity_filter=""
	local _since=""
	local _limit=100
	local _format="text"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--entity)
			_entity_filter="$2"
			shift 2
			;;
		--since)
			_since="$2"
			shift 2
			;;
		--limit)
			_limit="$2"
			shift 2
			;;
		--json)
			_format="json"
			shift
			;;
		*)
			log_warn "scan-patterns: unknown option: $1"
			shift
			;;
		esac
	done

	printf 'entity_filter=%s\nsince=%s\nlimit=%s\nformat=%s\n' \
		"$_entity_filter" "$_since" "$_limit" "$_format"
	return 0
}

#######################################
# Fetch interactions from DB for pattern scanning
# Arguments: $1=since, $2=entity_filter, $3=limit
# Outputs interaction rows to stdout
#######################################
_scan_patterns_fetch_interactions() {
	local since="$1"
	local entity_filter="$2"
	local limit="$3"

	local where_clause
	where_clause="i.created_at >= '$(evol_sql_escape "$since")'"
	if [[ -n "$entity_filter" ]]; then
		where_clause="$where_clause AND i.entity_id = '$(evol_sql_escape "$entity_filter")'"
	fi

	evol_db "$EVOL_MEMORY_DB" <<EOF
SELECT i.id, i.entity_id, i.channel, i.direction, i.content, i.created_at,
    COALESCE(e.name, 'Unknown') as entity_name
FROM interactions i
LEFT JOIN entities e ON i.entity_id = e.id
WHERE $where_clause
ORDER BY i.created_at ASC
LIMIT $limit;
EOF
	return 0
}

#######################################
# Format interactions for AI prompt
# Arguments: $1=interactions (pipe-delimited rows)
# Outputs formatted text to stdout
#######################################
_scan_patterns_format_for_ai() {
	local interactions="$1"
	local formatted=""

	while IFS='|' read -r int_id entity_id channel direction content timestamp entity_name; do
		local truncated_content
		truncated_content=$(echo "$content" | head -c 200)
		formatted="${formatted}[${int_id}] ${direction} ${channel} (${entity_name}) ${timestamp}: ${truncated_content}
"
	done <<<"$interactions"

	echo "$formatted"
	return 0
}

#######################################
# Run AI-powered pattern detection
# Arguments: $1=formatted_interactions, $2=interaction_count
# Outputs JSON array of patterns (or empty string on failure)
#######################################
_scan_patterns_run_ai() {
	local formatted="$1"
	local interaction_count="$2"

	if [[ ! -x "$EVOL_AI_RESEARCH_SCRIPT" ]]; then
		echo ""
		return 0
	fi

	local ai_prompt
	ai_prompt="Analyse these ${interaction_count} recent interactions from an AI assistant system. Identify capability gaps — things users needed that the system couldn't do well, or patterns suggesting missing features.

Interactions:
${formatted}

Respond with ONLY a JSON array of detected patterns. Each pattern:
{
  \"description\": \"What capability is missing or inadequate\",
  \"evidence_ids\": [\"int_xxx\", \"int_yyy\"],
  \"severity\": \"high|medium|low\",
  \"category\": \"missing_feature|workflow_gap|knowledge_gap|integration_gap|ux_friction\",
  \"frequency_hint\": 1
}

Rules:
- Only include genuine capability gaps, not normal conversation
- Evidence IDs must be from the interaction list above
- If no gaps detected, return empty array []
- Respond with ONLY the JSON array, no markdown fences
- Maximum 10 patterns per scan"

	"$EVOL_AI_RESEARCH_SCRIPT" --model haiku --prompt "$ai_prompt" 2>/dev/null || echo ""
	return 0
}

#######################################
# Output scan results in requested format
# Arguments: $1=patterns_json, $2=interaction_count, $3=since, $4=method, $5=format
#######################################
_scan_patterns_output() {
	local patterns="$1"
	local interaction_count="$2"
	local since="$3"
	local method="$4"
	local format="$5"

	local pattern_count
	pattern_count=$(echo "$patterns" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$format" == "json" ]]; then
		echo "{\"patterns\":${patterns},\"interaction_count\":${interaction_count},\"scan_window\":\"${since}\",\"method\":\"${method}\"}"
	else
		echo ""
		echo "=== Pattern Scan Results ==="
		echo "Window: since $since ($interaction_count interactions)"
		echo "Method: ${method}"
		echo "Patterns found: $pattern_count"
		echo ""

		if [[ "$pattern_count" -gt 0 ]]; then
			echo "$patterns" | jq -r '.[] | "[\(.severity)] \(.category): \(.description)\n  Evidence: \(.evidence_ids | join(", "))\n"' 2>/dev/null
		else
			echo "No capability gaps detected in this window."
		fi
	fi
	return 0
}

#######################################
# Scan interaction patterns using AI judgment
# Analyses recent interactions to identify:
#   - Repeated requests the system couldn't fulfil
#   - Friction points (user frustration, repeated clarifications)
#   - Feature requests (explicit or implied)
#   - Workflow gaps (manual steps that could be automated)
#
# Uses haiku-tier AI (~$0.001/call) for pattern significance.
# Falls back to heuristic scanning when AI is unavailable.
#######################################
cmd_scan_patterns() {
	local entity_filter="" since="" limit=100 format="text"

	# Parse args via helper (eval the key=value output)
	local parsed
	parsed=$(_scan_patterns_parse_args "$@")
	while IFS='=' read -r key val; do
		case "$key" in
		entity_filter) entity_filter="$val" ;;
		since) since="$val" ;;
		limit) limit="$val" ;;
		format) format="$val" ;;
		esac
	done <<<"$parsed"

	init_evol_db

	# Default: scan last 24 hours
	if [[ -z "$since" ]]; then
		since=$(hours_ago_iso "$DEFAULT_SCAN_WINDOW_HOURS")
	fi

	# Fetch recent interactions
	local interactions
	interactions=$(_scan_patterns_fetch_interactions "$since" "$entity_filter" "$limit")

	if [[ -z "$interactions" ]]; then
		log_info "No interactions found since $since"
		if [[ "$format" == "json" ]]; then
			echo '{"patterns":[],"interaction_count":0,"scan_window":"'"$since"'"}'
		fi
		return 0
	fi

	local interaction_count
	interaction_count=$(echo "$interactions" | wc -l | tr -d ' ')

	if [[ "$interaction_count" -lt "$MIN_INTERACTIONS_FOR_SCAN" ]]; then
		log_info "Only $interaction_count interactions found (minimum: $MIN_INTERACTIONS_FOR_SCAN). Skipping scan."
		if [[ "$format" == "json" ]]; then
			echo '{"patterns":[],"interaction_count":'"$interaction_count"',"scan_window":"'"$since"'","reason":"below_minimum"}'
		fi
		return 0
	fi

	# Format interactions for AI analysis
	local formatted
	formatted=$(_scan_patterns_format_for_ai "$interactions")

	# Try AI-powered pattern detection
	local ai_result
	ai_result=$(_scan_patterns_run_ai "$formatted" "$interaction_count")

	# Use AI result if valid JSON array
	if [[ -n "$ai_result" ]] && command -v jq &>/dev/null; then
		if echo "$ai_result" | jq -e 'type == "array"' >/dev/null 2>&1; then
			_scan_patterns_output "$ai_result" "$interaction_count" "$since" "AI-judged (haiku)" "$format"
			return 0
		fi
	fi

	# Heuristic fallback: scan for common gap indicators
	local patterns
	patterns=$(scan_patterns_heuristic "$interactions")

	_scan_patterns_output "${patterns:-[]}" "$interaction_count" "$since" "heuristic (AI unavailable)" "$format"
	return 0
}

#######################################
# Heuristic pattern scanning fallback
# Looks for common indicators of capability gaps in interaction content.
# Less accurate than AI but works without API access.
#######################################
scan_patterns_heuristic() {
	local interactions="$1"
	local patterns="[]"

	# Check for "can't", "unable", "doesn't support", "not possible" in outbound messages
	local inability_ids
	inability_ids=$(echo "$interactions" | grep -i 'outbound' | grep -iE "can.t|unable|doesn.t support|not possible|not available|not implemented|don.t have|no way to" | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')

	if [[ -n "$inability_ids" ]]; then
		local inability_count
		inability_count=$(echo "$inability_ids" | tr ',' '\n' | wc -l | tr -d ' ')
		local id_array
		id_array=$(echo "$inability_ids" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')
		patterns=$(echo "$patterns" | jq --argjson ids "[$id_array]" --arg count "$inability_count" \
			'. + [{"description":"System expressed inability to fulfil requests","evidence_ids":$ids,"severity":"medium","category":"missing_feature","frequency_hint":($count|tonumber)}]' 2>/dev/null || echo "$patterns")
	fi

	# Check for repeated questions (same entity asking similar things)
	local repeat_ids
	repeat_ids=$(echo "$interactions" | grep -i 'inbound' | cut -d'|' -f2 | sort | uniq -c | sort -rn | head -3 | awk '$1 > 2 {print $2}')

	if [[ -n "$repeat_ids" ]]; then
		while IFS= read -r entity_id; do
			[[ -z "$entity_id" ]] && continue
			local entity_int_ids
			entity_int_ids=$(echo "$interactions" | grep "|${entity_id}|" | grep 'inbound' | cut -d'|' -f1 | head -5 | tr '\n' ',' | sed 's/,$//')
			if [[ -n "$entity_int_ids" ]]; then
				local eid_array
				eid_array=$(echo "$entity_int_ids" | tr ',' '\n' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')
				patterns=$(echo "$patterns" | jq --argjson ids "[$eid_array]" \
					'. + [{"description":"Entity has high interaction frequency — may indicate unresolved need","evidence_ids":$ids,"severity":"low","category":"ux_friction","frequency_hint":1}]' 2>/dev/null || echo "$patterns")
			fi
		done <<<"$repeat_ids"
	fi

	echo "$patterns"
	return 0
}
