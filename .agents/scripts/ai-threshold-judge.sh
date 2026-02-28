#!/usr/bin/env bash
# ai-threshold-judge.sh — AI-judged threshold decisions for aidevops
# Replaces hardcoded thresholds with haiku-tier AI judgment (~$0.001/call).
#
# Part of the Intelligence Over Determinism principle (p035 / t1363.6):
# fixed thresholds fail on outliers; AI judgment handles context.
#
# Each judgment function:
#   1. Tries AI judgment via ai-research-helper.sh (haiku tier)
#   2. Falls back to improved heuristics if AI unavailable
#   3. Returns a deterministic result (never blocks on AI failure)
#
# Usage:
#   ai-threshold-judge.sh judge-prune-relevance --content "memory content" --age-days 95 --entity "user123"
#   ai-threshold-judge.sh judge-dedup-similarity --content-a "text1" --content-b "text2"
#   ai-threshold-judge.sh judge-prompt-length --entity "user123" --channel matrix --message-count 5
#   ai-threshold-judge.sh help
#
# Exit codes: 0=success, 1=error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

LOG_PREFIX="THRESHOLD"

readonly AI_RESEARCH="${SCRIPT_DIR}/ai-research-helper.sh"
readonly MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"

#######################################
# Judge whether a memory entry should be pruned
# Replaces fixed DEFAULT_MAX_AGE_DAYS=90 with context-aware judgment.
#
# Arguments (via flags):
#   --content    Memory content text
#   --age-days   Days since creation
#   --type       Memory type (WORKING_SOLUTION, etc.)
#   --entity     Entity ID (optional — if set, checks entity relevance)
#   --accessed   Whether ever accessed (true/false)
#   --confidence Memory confidence level
#
# Output: "prune" or "keep" on stdout
# Returns: 0 always (deterministic)
#######################################
cmd_judge_prune_relevance() {
	local content="" age_days="" mem_type="" entity="" accessed="false" confidence=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--content)
			content="$2"
			shift 2
			;;
		--age-days)
			age_days="$2"
			shift 2
			;;
		--type)
			mem_type="$2"
			shift 2
			;;
		--entity)
			entity="$2"
			shift 2
			;;
		--accessed)
			accessed="$2"
			shift 2
			;;
		--confidence)
			confidence="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$content" || -z "$age_days" ]]; then
		log_error "Required: --content and --age-days"
		echo "keep"
		return 0
	fi

	# Fast path: never prune recently accessed high-confidence entries
	if [[ "$accessed" == "true" && "$confidence" == "high" ]]; then
		echo "keep"
		return 0
	fi

	# Fast path: always prune very old, never-accessed, low-confidence entries
	if [[ "$accessed" == "false" && "$age_days" -gt 180 && "$confidence" == "low" ]]; then
		echo "prune"
		return 0
	fi

	# Borderline cases: use AI judgment
	if [[ -x "$AI_RESEARCH" ]]; then
		local truncated_content="${content:0:300}"
		local ai_prompt="You are a memory relevance judge. Given this memory entry, decide if it should be PRUNED (removed) or KEPT.

Memory content (truncated): ${truncated_content}
Age: ${age_days} days
Type: ${mem_type:-unknown}
Ever accessed: ${accessed}
Confidence: ${confidence:-medium}
Entity context: ${entity:-none}

Consider:
- WORKING_SOLUTION and ARCHITECTURAL_DECISION types are long-lived — keep unless very stale
- ERROR_FIX entries lose relevance as codebases change — prune after ~120 days if never accessed
- USER_PREFERENCE entries are valuable if tied to an active entity
- CONTEXT entries are ephemeral — prune after ~60 days if never accessed
- Never-accessed entries are less valuable than frequently-accessed ones

Respond with ONLY one word: 'prune' or 'keep'"

		local ai_result
		ai_result=$("$AI_RESEARCH" --model haiku --max-tokens 10 --prompt "$ai_prompt" 2>/dev/null || echo "")
		ai_result=$(echo "$ai_result" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

		if [[ "$ai_result" == "prune" || "$ai_result" == "keep" ]]; then
			echo "$ai_result"
			return 0
		fi
	fi

	# Fallback: improved heuristics (better than flat 90-day cutoff)
	case "${mem_type:-}" in
	WORKING_SOLUTION | ARCHITECTURAL_DECISION)
		# Long-lived types: 180 days if never accessed
		if [[ "$accessed" == "false" && "$age_days" -gt 180 ]]; then
			echo "prune"
		else
			echo "keep"
		fi
		;;
	ERROR_FIX | FAILED_APPROACH)
		# Medium-lived: 120 days if never accessed
		if [[ "$accessed" == "false" && "$age_days" -gt 120 ]]; then
			echo "prune"
		else
			echo "keep"
		fi
		;;
	CONTEXT | OPEN_THREAD)
		# Short-lived: 60 days if never accessed
		if [[ "$accessed" == "false" && "$age_days" -gt 60 ]]; then
			echo "prune"
		else
			echo "keep"
		fi
		;;
	USER_PREFERENCE)
		# Keep user preferences longer — 365 days
		if [[ "$accessed" == "false" && "$age_days" -gt 365 ]]; then
			echo "prune"
		else
			echo "keep"
		fi
		;;
	*)
		# Default: original 90-day threshold for unknown types
		if [[ "$accessed" == "false" && "$age_days" -gt 90 ]]; then
			echo "prune"
		else
			echo "keep"
		fi
		;;
	esac

	return 0
}

#######################################
# Judge whether two memory entries are semantic duplicates
# Replaces exact-string and normalized-string matching with AI similarity.
#
# Arguments (via flags):
#   --content-a  First memory content
#   --content-b  Second memory content
#
# Output: "duplicate" or "distinct" on stdout
# Returns: 0 always (deterministic)
#######################################
cmd_judge_dedup_similarity() {
	local content_a="" content_b=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--content-a)
			content_a="$2"
			shift 2
			;;
		--content-b)
			content_b="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$content_a" || -z "$content_b" ]]; then
		log_error "Required: --content-a and --content-b"
		echo "distinct"
		return 0
	fi

	# Fast path: exact match
	if [[ "$content_a" == "$content_b" ]]; then
		echo "duplicate"
		return 0
	fi

	# Fast path: very different lengths suggest distinct content
	local len_a=${#content_a}
	local len_b=${#content_b}
	local len_ratio
	if [[ "$len_a" -gt "$len_b" ]]; then
		len_ratio=$((len_a * 100 / (len_b + 1)))
	else
		len_ratio=$((len_b * 100 / (len_a + 1)))
	fi
	if [[ "$len_ratio" -gt 300 ]]; then
		echo "distinct"
		return 0
	fi

	# AI judgment for borderline cases
	if [[ -x "$AI_RESEARCH" ]]; then
		local trunc_a="${content_a:0:200}"
		local trunc_b="${content_b:0:200}"
		local ai_prompt="Are these two memory entries semantic duplicates (same information, possibly worded differently) or distinct (different information)?

Entry A: ${trunc_a}
Entry B: ${trunc_b}

Respond with ONLY one word: 'duplicate' or 'distinct'"

		local ai_result
		ai_result=$("$AI_RESEARCH" --model haiku --max-tokens 10 --prompt "$ai_prompt" 2>/dev/null || echo "")
		ai_result=$(echo "$ai_result" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

		if [[ "$ai_result" == "duplicate" || "$ai_result" == "distinct" ]]; then
			echo "$ai_result"
			return 0
		fi
	fi

	# Fallback: normalized string comparison (existing behavior)
	local norm_a norm_b
	norm_a=$(echo "$content_a" | tr '[:upper:]' '[:lower:]' | sed "s/[.,'!?]//g" | tr -s '[:space:]' ' ')
	norm_b=$(echo "$content_b" | tr '[:upper:]' '[:lower:]' | sed "s/[.,'!?]//g" | tr -s '[:space:]' ' ')

	if [[ "$norm_a" == "$norm_b" ]]; then
		echo "duplicate"
	else
		echo "distinct"
	fi

	return 0
}

#######################################
# Judge optimal prompt/response length for an entity
# Replaces fixed maxPromptLength: 4000 with entity-preference-aware sizing.
#
# Arguments (via flags):
#   --entity         Entity ID (optional)
#   --channel        Channel type (matrix, simplex, email, cli)
#   --message-count  Number of messages in current conversation
#   --last-messages  Recent message text for context (optional)
#
# Output: recommended max length (integer) on stdout
# Returns: 0 always (deterministic)
#######################################
cmd_judge_prompt_length() {
	local entity="" channel="" message_count="" last_messages=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--entity)
			entity="$2"
			shift 2
			;;
		--channel)
			channel="$2"
			shift 2
			;;
		--message-count)
			message_count="$2"
			shift 2
			;;
		--last-messages)
			last_messages="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	# Check entity preferences in memory DB if entity is specified
	local entity_pref_length=""
	if [[ -n "$entity" ]]; then
		local memory_db="${MEMORY_BASE_DIR}/memory.db"
		if [[ -f "$memory_db" ]] && command -v sqlite3 &>/dev/null; then
			local escaped_entity="${entity//"'"/"''"}"
			# Check for stored preference about response length
			entity_pref_length=$(sqlite3 "$memory_db" \
				"SELECT content FROM learnings WHERE type = 'USER_PREFERENCE' AND (content LIKE '%response length%' OR content LIKE '%verbose%' OR content LIKE '%concise%' OR content LIKE '%brief%' OR content LIKE '%detailed%') AND entity_id = '${escaped_entity}' ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || echo "")
		fi
	fi

	# AI judgment if we have entity preference context
	if [[ -x "$AI_RESEARCH" && -n "$entity_pref_length" ]]; then
		local ai_prompt="Based on this user preference about response length, what is the optimal maximum response length in characters?

User preference: ${entity_pref_length}
Channel: ${channel:-unknown}
Messages in conversation: ${message_count:-unknown}

Consider:
- Matrix/chat channels: shorter responses (2000-4000 chars)
- Email: longer responses (4000-8000 chars)
- CLI: medium responses (3000-6000 chars)
- If user prefers concise/brief: use lower end
- If user prefers detailed/verbose: use higher end

Respond with ONLY a number (the recommended max character count)"

		local ai_result
		ai_result=$("$AI_RESEARCH" --model haiku --max-tokens 10 --prompt "$ai_prompt" 2>/dev/null || echo "")
		ai_result=$(echo "$ai_result" | tr -dc '0-9')

		if [[ -n "$ai_result" && "$ai_result" -gt 500 && "$ai_result" -lt 20000 ]]; then
			echo "$ai_result"
			return 0
		fi
	fi

	# Fallback: channel-based defaults (better than flat 4000)
	case "${channel:-}" in
	matrix | simplex)
		echo "3000"
		;;
	email)
		echo "6000"
		;;
	cli)
		echo "4000"
		;;
	*)
		echo "4000"
		;;
	esac

	return 0
}

#######################################
# Display help
#######################################
cmd_help() {
	cat <<'EOF'
ai-threshold-judge.sh — AI-judged threshold decisions

Replaces hardcoded thresholds with haiku-tier AI judgment (~$0.001/call).
Falls back to improved heuristics when AI is unavailable.

Commands:
  judge-prune-relevance   Should a memory entry be pruned or kept?
    --content TEXT         Memory content
    --age-days N          Days since creation
    --type TYPE           Memory type (WORKING_SOLUTION, ERROR_FIX, etc.)
    --entity ID           Entity ID (optional)
    --accessed true|false Whether ever accessed
    --confidence LEVEL    Confidence level (low, medium, high)

  judge-dedup-similarity  Are two entries semantic duplicates?
    --content-a TEXT      First entry
    --content-b TEXT      Second entry

  judge-prompt-length     Optimal response length for entity/channel
    --entity ID           Entity ID (optional)
    --channel TYPE        Channel (matrix, simplex, email, cli)
    --message-count N     Messages in conversation
    --last-messages TEXT   Recent messages (optional)

  help                    Show this help

Examples:
  ai-threshold-judge.sh judge-prune-relevance --content "CORS fix" --age-days 95 --type ERROR_FIX --accessed false
  ai-threshold-judge.sh judge-dedup-similarity --content-a "Use nginx for CORS" --content-b "CORS handled by nginx proxy"
  ai-threshold-judge.sh judge-prompt-length --channel matrix --entity user123
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
	judge-prune-relevance)
		cmd_judge_prune_relevance "$@"
		;;
	judge-dedup-similarity)
		cmd_judge_dedup_similarity "$@"
		;;
	judge-prompt-length)
		cmd_judge_prompt_length "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
