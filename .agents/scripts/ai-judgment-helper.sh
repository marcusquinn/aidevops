#!/usr/bin/env bash
# ai-judgment-helper.sh - Intelligent threshold replacement for aidevops
# Replaces hardcoded thresholds with AI judgment calls (haiku-tier, ~$0.001 each).
#
# Part of the conversational memory system (p035 / t1363.6).
# Per the Intelligence Over Determinism principle: deterministic rules break on
# outliers; a haiku-tier call handles edge cases that no fixed threshold can.
#
# Thresholds replaced:
#   1. sessionIdleTimeout: 300 → AI judges "has this conversation naturally paused?"
#      (Delegated to conversation-helper.sh idle-check which already implements this)
#   2. DEFAULT_MAX_AGE_DAYS=90 → AI judges "is this memory still relevant?"
#   3. maxPromptLength: 4000 → Dynamic based on entity's observed detail preference
#
# Usage:
#   ai-judgment-helper.sh is-memory-relevant --content "memory text" [--entity <id>] [--age-days N]
#   ai-judgment-helper.sh optimal-response-length --entity <id> [--channel matrix] [--default 4000]
#   ai-judgment-helper.sh should-prune --memory-id <id> [--dry-run]
#   ai-judgment-helper.sh batch-prune-check [--older-than-days 60] [--limit 50] [--dry-run]
#   ai-judgment-helper.sh help
#
# Design:
#   - Every judgment has a deterministic fallback (the old threshold)
#   - AI calls are optional — if ANTHROPIC_API_KEY is missing, fallback is used
#   - Results are cached in memory.db to avoid repeated calls for the same decision
#   - Batch operations rate-limit to avoid API cost spikes
#
# Exit codes:
#   0 - Success
#   1 - Error
#   2 - API unavailable (fallback used, still exits 0 for callers)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly JUDGMENT_MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
JUDGMENT_MEMORY_DB="${JUDGMENT_MEMORY_BASE_DIR}/memory.db"
readonly AI_HELPER="${SCRIPT_DIR}/ai-research-helper.sh"

# Fallback thresholds (used when AI is unavailable)
readonly FALLBACK_MAX_AGE_DAYS=90
readonly FALLBACK_MAX_PROMPT_LENGTH=4000
readonly FALLBACK_IDLE_TIMEOUT=300

# Cache TTL for judgment results (seconds) — avoid re-judging the same memory
readonly JUDGMENT_CACHE_TTL=86400 # 24 hours

#######################################
# SQLite wrapper
#######################################
judgment_db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Initialize judgment cache table
#######################################
init_judgment_cache() {
	mkdir -p "$JUDGMENT_MEMORY_BASE_DIR"

	judgment_db "$JUDGMENT_MEMORY_DB" <<'SCHEMA'
CREATE TABLE IF NOT EXISTS ai_judgment_cache (
    key TEXT PRIMARY KEY,
    judgment TEXT NOT NULL,
    reasoning TEXT DEFAULT '',
    model TEXT DEFAULT 'haiku',
    created_at TEXT DEFAULT (datetime('now')),
    expires_at TEXT DEFAULT (datetime('now', '+1 day'))
);

-- Index for expiry cleanup
CREATE INDEX IF NOT EXISTS idx_judgment_cache_expires
    ON ai_judgment_cache(expires_at);
SCHEMA
	return 0
}

#######################################
# Check judgment cache
# Returns: cached judgment or empty string
#######################################
get_cached_judgment() {
	local key="$1"
	local escaped_key="${key//\'/\'\'}"

	local result
	result=$(judgment_db "$JUDGMENT_MEMORY_DB" \
		"SELECT judgment FROM ai_judgment_cache WHERE key = '$escaped_key' AND expires_at > datetime('now');" \
		2>/dev/null || echo "")
	echo "$result"
	return 0
}

#######################################
# Store judgment in cache
#######################################
cache_judgment() {
	local key="$1"
	local judgment="$2"
	local reasoning="${3:-}"
	local model="${4:-haiku}"

	local escaped_key="${key//\'/\'\'}"
	local escaped_judgment="${judgment//\'/\'\'}"
	local escaped_reasoning="${reasoning//\'/\'\'}"

	judgment_db "$JUDGMENT_MEMORY_DB" <<EOF
INSERT OR REPLACE INTO ai_judgment_cache (key, judgment, reasoning, model, created_at, expires_at)
VALUES ('$escaped_key', '$escaped_judgment', '$escaped_reasoning', '$model', datetime('now'), datetime('now', '+1 day'));
EOF
	return 0
}

#######################################
# Clean expired cache entries
#######################################
clean_judgment_cache() {
	judgment_db "$JUDGMENT_MEMORY_DB" \
		"DELETE FROM ai_judgment_cache WHERE expires_at < datetime('now');" \
		2>/dev/null || true
	return 0
}

#######################################
# Check if AI judgment is available
#######################################
ai_available() {
	[[ -x "$AI_HELPER" ]] && "$AI_HELPER" --prompt "test" --max-tokens 1 --quiet >/dev/null 2>&1
}

#######################################
# Judge whether a memory is still relevant
# Replaces: DEFAULT_MAX_AGE_DAYS=90 (fixed prune threshold)
#
# Arguments:
#   --content TEXT    Memory content to evaluate
#   --entity ID       Entity ID (optional — for entity-relationship context)
#   --age-days N      Age of the memory in days
#   --tags TAGS       Memory tags (optional)
#   --type TYPE       Memory type (optional)
#
# Output: "relevant" or "prune" on stdout
# Exit: 0 always (fallback on error)
#######################################
cmd_is_memory_relevant() {
	local content=""
	local entity_id=""
	local age_days=""
	local tags=""
	local mem_type=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--content)
			content="$2"
			shift 2
			;;
		--entity)
			entity_id="$2"
			shift 2
			;;
		--age-days)
			age_days="$2"
			shift 2
			;;
		--tags)
			tags="$2"
			shift 2
			;;
		--type)
			mem_type="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$content" ]]; then
		log_error "Usage: ai-judgment-helper.sh is-memory-relevant --content \"text\" [--age-days N]"
		return 1
	fi

	init_judgment_cache

	# Generate cache key from content hash
	local cache_key
	cache_key="relevance:$(echo -n "$content" | md5sum | cut -d' ' -f1)"
	local cached
	cached=$(get_cached_judgment "$cache_key")
	if [[ -n "$cached" ]]; then
		echo "$cached"
		return 0
	fi

	# Try AI judgment
	if [[ -x "$AI_HELPER" ]]; then
		local context_info=""
		[[ -n "$age_days" ]] && context_info="Age: ${age_days} days. "
		[[ -n "$tags" ]] && context_info="${context_info}Tags: ${tags}. "
		[[ -n "$mem_type" ]] && context_info="${context_info}Type: ${mem_type}. "

		# Build entity context if available
		local entity_context=""
		if [[ -n "$entity_id" ]]; then
			local entity_name
			entity_name=$(judgment_db "$JUDGMENT_MEMORY_DB" \
				"SELECT name FROM entities WHERE id = '${entity_id//\'/\'\'}' LIMIT 1;" \
				2>/dev/null || echo "")
			if [[ -n "$entity_name" ]]; then
				entity_context="This memory is associated with entity '${entity_name}'. "
			fi
		fi

		local prompt="You are evaluating whether a stored memory/learning should be kept or pruned.
${context_info}${entity_context}
Memory content: ${content}

Is this memory still likely to be useful? Consider:
- Is it a timeless pattern/solution, or time-sensitive info that's likely outdated?
- Would someone working on this codebase/project benefit from knowing this?
- Is it specific enough to be actionable, or too vague to help?

Respond with ONLY one word: 'relevant' or 'prune'"

		local result
		result=$("$AI_HELPER" --prompt "$prompt" --model haiku --max-tokens 10 2>/dev/null || echo "")
		result=$(echo "$result" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

		if [[ "$result" == "relevant" || "$result" == "prune" ]]; then
			cache_judgment "$cache_key" "$result" "" "haiku"
			echo "$result"
			return 0
		fi
	fi

	# Fallback: use the old threshold
	if [[ -n "$age_days" && "$age_days" -gt "$FALLBACK_MAX_AGE_DAYS" ]]; then
		echo "prune"
	else
		echo "relevant"
	fi
	return 0
}

#######################################
# Determine optimal response length for an entity
# Replaces: maxPromptLength: 4000 (fixed truncation)
#
# Arguments:
#   --entity ID       Entity ID to check preferences for
#   --channel TYPE    Channel type (matrix, simplex, etc.)
#   --default N       Default length if no preference found (default: 4000)
#
# Output: integer (max response length in characters)
#######################################
cmd_optimal_response_length() {
	local entity_id=""
	local channel=""
	local default_length=$FALLBACK_MAX_PROMPT_LENGTH

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--entity)
			entity_id="$2"
			shift 2
			;;
		--channel)
			channel="$2"
			shift 2
			;;
		--default)
			default_length="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	init_judgment_cache

	# If no entity, return default
	if [[ -z "$entity_id" ]]; then
		echo "$default_length"
		return 0
	fi

	# Look up entity
	local entity_name
	entity_name=$(judgment_db "$JUDGMENT_MEMORY_DB" \
		"SELECT name FROM entities WHERE id = '${entity_id//\'/\'\'}' LIMIT 1;" \
		2>/dev/null || echo "")

	if [[ -z "$entity_name" ]]; then
		echo "$default_length"
		return 0
	fi

	# Check entity profile for explicit detail preference FIRST
	# An explicit preference always wins — no caching needed (local DB lookup is cheap)
	# Latest version = not superseded by any other entry
	local detail_pref
	detail_pref=$(judgment_db "$JUDGMENT_MEMORY_DB" \
		"SELECT ep.profile_value FROM entity_profiles ep
		 WHERE ep.entity_id = '${entity_id//\'/\'\'}' AND ep.profile_key = 'detail_preference'
		   AND ep.id NOT IN (SELECT supersedes_id FROM entity_profiles WHERE supersedes_id IS NOT NULL)
		 ORDER BY ep.created_at DESC LIMIT 1;" \
		2>/dev/null || echo "")

	# If we have a stored preference, use it directly (no caching — profile is authoritative)
	if [[ -n "$detail_pref" ]]; then
		case "$detail_pref" in
		concise | brief | short)
			echo "2000"
			return 0
			;;
		normal | moderate)
			echo "4000"
			return 0
			;;
		detailed | verbose | long)
			echo "8000"
			return 0
			;;
		esac
	fi

	# Get interaction data for AI judgment and heuristic fallback
	local channel_filter=""
	if [[ -n "$channel" ]]; then
		channel_filter="AND i.channel = '${channel//\'/\'\'}'"
	fi

	local avg_msg_length interaction_count
	avg_msg_length=$(judgment_db "$JUDGMENT_MEMORY_DB" \
		"SELECT COALESCE(AVG(LENGTH(i.content)), 0) FROM interactions i
		 JOIN conversations c ON i.conversation_id = c.id
		 WHERE c.entity_id = '${entity_id//\'/\'\'}' AND i.direction = 'outbound'
		 $channel_filter
		 ORDER BY i.created_at DESC LIMIT 50;" \
		2>/dev/null || echo "0")

	interaction_count=$(judgment_db "$JUDGMENT_MEMORY_DB" \
		"SELECT COUNT(*) FROM interactions i
		 JOIN conversations c ON i.conversation_id = c.id
		 WHERE c.entity_id = '${entity_id//\'/\'\'}' AND i.direction = 'inbound'
		 $channel_filter;" \
		2>/dev/null || echo "0")

	# Not enough interaction data for AI judgment — use default
	if [[ "$interaction_count" -lt 5 ]]; then
		echo "$default_length"
		return 0
	fi

	# Cache key for AI judgment results (not used for profile-based results)
	local cache_key="response_length:${entity_id}:${channel}"
	local cached
	cached=$(get_cached_judgment "$cache_key")
	if [[ -n "$cached" ]]; then
		echo "$cached"
		return 0
	fi

	# Try AI judgment based on interaction patterns
	if [[ -x "$AI_HELPER" ]]; then
		# Get sample of recent inbound messages to gauge user's communication style
		local recent_inbound
		recent_inbound=$(judgment_db "$JUDGMENT_MEMORY_DB" \
			"SELECT substr(i.content, 1, 100) FROM interactions i
			 JOIN conversations c ON i.conversation_id = c.id
			 WHERE c.entity_id = '${entity_id//\'/\'\'}' AND i.direction = 'inbound'
			 $channel_filter
			 ORDER BY i.created_at DESC LIMIT 5;" \
			2>/dev/null || echo "")

		if [[ -n "$recent_inbound" ]]; then
			local prompt="Based on these recent messages from a user, what response length do they prefer?

Recent messages from user:
$recent_inbound

Average response length so far: ${avg_msg_length} chars
Total interactions: ${interaction_count}

Respond with ONLY a number: 2000 (concise), 4000 (normal), or 8000 (detailed)"

			local result
			result=$("$AI_HELPER" --prompt "$prompt" --model haiku --max-tokens 10 2>/dev/null || echo "")
			result=$(echo "$result" | tr -dc '0-9')

			if [[ -n "$result" && "$result" -ge 1000 && "$result" -le 16000 ]]; then
				cache_judgment "$cache_key" "$result"
				echo "$result"
				return 0
			fi
		fi
	fi

	# Fallback: scale based on average outbound message length
	# If we've been sending short responses, keep them short
	local avg_int
	avg_int=$(printf "%.0f" "$avg_msg_length" 2>/dev/null || echo "0")
	if [[ "$avg_int" -gt 0 && "$avg_int" -lt 2000 ]]; then
		echo "3000"
	elif [[ "$avg_int" -gt 6000 ]]; then
		echo "8000"
	else
		echo "$default_length"
	fi
	return 0
}

#######################################
# Check if a specific memory should be pruned
# Combines age, access patterns, and AI judgment
#
# Arguments:
#   --memory-id ID    Memory ID to check
#   --dry-run         Don't actually prune, just report
#
# Output: "keep" or "prune" with reasoning
#######################################
cmd_should_prune() {
	local memory_id=""
	local dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--memory-id)
			memory_id="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$memory_id" ]]; then
		log_error "Usage: ai-judgment-helper.sh should-prune --memory-id <id>"
		return 1
	fi

	init_judgment_cache

	# Get memory details
	local escaped_id="${memory_id//\'/\'\'}"
	local mem_data
	mem_data=$(judgment_db "$JUDGMENT_MEMORY_DB" \
		"SELECT l.content, l.type, l.tags, l.created_at,
		        COALESCE(a.access_count, 0) as access_count,
		        COALESCE(a.last_accessed_at, '') as last_accessed
		 FROM learnings l
		 LEFT JOIN learning_access a ON l.id = a.id
		 WHERE l.id = '$escaped_id';" \
		2>/dev/null || echo "")

	if [[ -z "$mem_data" ]]; then
		log_error "Memory not found: $memory_id"
		return 1
	fi

	# Parse fields
	local content type tags created_at access_count last_accessed
	IFS='|' read -r content type tags created_at access_count last_accessed <<<"$mem_data"

	# Calculate age in days
	local created_epoch now_epoch age_days
	created_epoch=$(date -d "$created_at" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$created_at" +%s 2>/dev/null || echo "0")
	now_epoch=$(date +%s)
	age_days=$(((now_epoch - created_epoch) / 86400))

	# Quick keep: recently accessed memories are always kept
	if [[ "$access_count" -gt 0 && -n "$last_accessed" ]]; then
		local last_epoch
		last_epoch=$(date -d "$last_accessed" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$last_accessed" +%s 2>/dev/null || echo "0")
		local days_since_access=$(((now_epoch - last_epoch) / 86400))
		if [[ "$days_since_access" -lt 30 ]]; then
			echo "keep (accessed $days_since_access days ago, $access_count times total)"
			return 0
		fi
	fi

	# Quick prune: very old, never accessed
	if [[ "$age_days" -gt 180 && "$access_count" -eq 0 ]]; then
		echo "prune (${age_days} days old, never accessed)"
		return 0
	fi

	# Check for entity relationships
	local entity_linked
	entity_linked=$(judgment_db "$JUDGMENT_MEMORY_DB" \
		"SELECT COUNT(*) FROM learning_entities WHERE learning_id = '$escaped_id';" \
		2>/dev/null || echo "0")

	# AI judgment for borderline cases
	local result
	result=$(cmd_is_memory_relevant \
		--content "$content" \
		--age-days "$age_days" \
		--tags "$tags" \
		--type "$type")

	if [[ "$result" == "prune" ]]; then
		local reason="AI judged irrelevant (${age_days}d old, ${access_count} accesses"
		[[ "$entity_linked" -gt 0 ]] && reason="${reason}, linked to ${entity_linked} entities"
		reason="${reason})"
		echo "prune ($reason)"
	else
		echo "keep (AI judged relevant, ${age_days}d old, ${access_count} accesses)"
	fi
	return 0
}

#######################################
# Batch prune check — evaluate multiple memories
# Replaces the blanket DEFAULT_MAX_AGE_DAYS=90 prune
#
# Arguments:
#   --older-than-days N   Only check memories older than N days (default: 60)
#   --limit N             Max memories to check per batch (default: 50)
#   --dry-run             Report only, don't prune
#
# Output: summary of keep/prune decisions
#######################################
cmd_batch_prune_check() {
	local older_than_days=60
	local limit=50
	local dry_run=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--older-than-days)
			older_than_days="$2"
			shift 2
			;;
		--limit)
			limit="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		*) shift ;;
		esac
	done

	init_judgment_cache
	clean_judgment_cache

	# Find candidate memories (old, never or rarely accessed)
	local candidates
	candidates=$(judgment_db "$JUDGMENT_MEMORY_DB" \
		"SELECT l.id, substr(l.content, 1, 100), l.type, l.tags, l.created_at,
		        COALESCE(a.access_count, 0) as access_count
		 FROM learnings l
		 LEFT JOIN learning_access a ON l.id = a.id
		 WHERE l.created_at < datetime('now', '-$older_than_days days')
		 ORDER BY COALESCE(a.access_count, 0) ASC, l.created_at ASC
		 LIMIT $limit;" \
		2>/dev/null || echo "")

	if [[ -z "$candidates" ]]; then
		log_info "No memories older than $older_than_days days to evaluate"
		return 0
	fi

	local keep_count=0
	local prune_count=0
	local prune_ids=()

	while IFS='|' read -r mem_id content type tags created_at access_count; do
		[[ -z "$mem_id" ]] && continue

		# Calculate age
		local created_epoch now_epoch age_days
		created_epoch=$(date -d "$created_at" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$created_at" +%s 2>/dev/null || echo "0")
		now_epoch=$(date +%s)
		age_days=$(((now_epoch - created_epoch) / 86400))

		# Quick decisions first (no API call needed)
		if [[ "$access_count" -gt 3 ]]; then
			keep_count=$((keep_count + 1))
			continue
		fi

		if [[ "$age_days" -gt 180 && "$access_count" -eq 0 ]]; then
			prune_count=$((prune_count + 1))
			prune_ids+=("$mem_id")
			continue
		fi

		# AI judgment for borderline cases
		local result
		result=$(cmd_is_memory_relevant \
			--content "$content" \
			--age-days "$age_days" \
			--tags "$tags" \
			--type "$type")

		if [[ "$result" == "prune" ]]; then
			prune_count=$((prune_count + 1))
			prune_ids+=("$mem_id")
		else
			keep_count=$((keep_count + 1))
		fi

		# Rate limit: small delay between AI calls
		sleep 0.1
	done <<<"$candidates"

	# Report
	log_info "Batch prune check: $keep_count keep, $prune_count prune (of $((keep_count + prune_count)) evaluated)"

	if [[ "$dry_run" == true ]]; then
		if [[ ${#prune_ids[@]} -gt 0 ]]; then
			log_info "[DRY RUN] Would prune: ${prune_ids[*]}"
		fi
	else
		# Actually prune
		if [[ ${#prune_ids[@]} -gt 0 ]]; then
			for pid in "${prune_ids[@]}"; do
				local escaped_pid="${pid//\'/\'\'}"
				judgment_db "$JUDGMENT_MEMORY_DB" "DELETE FROM learning_relations WHERE id = '$escaped_pid' OR supersedes_id = '$escaped_pid';" 2>/dev/null || true
				judgment_db "$JUDGMENT_MEMORY_DB" "DELETE FROM learning_access WHERE id = '$escaped_pid';" 2>/dev/null || true
				judgment_db "$JUDGMENT_MEMORY_DB" "DELETE FROM learning_entities WHERE learning_id = '$escaped_pid';" 2>/dev/null || true
				judgment_db "$JUDGMENT_MEMORY_DB" "DELETE FROM learnings WHERE id = '$escaped_pid';" 2>/dev/null || true
			done
			judgment_db "$JUDGMENT_MEMORY_DB" "INSERT INTO learnings(learnings) VALUES('rebuild');" 2>/dev/null || true
			log_success "Pruned $prune_count memories (AI-judged irrelevant)"
		fi
	fi

	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'HELP'
ai-judgment-helper.sh - Intelligent threshold replacement

Replaces hardcoded thresholds with AI judgment calls (haiku-tier, ~$0.001 each).
Falls back to deterministic thresholds when AI is unavailable.

Commands:
  is-memory-relevant    Judge if a memory should be kept or pruned
  optimal-response-length  Determine ideal response length for an entity
  should-prune          Check if a specific memory should be pruned
  batch-prune-check     Evaluate multiple memories for pruning
  help                  Show this help

Thresholds replaced:
  sessionIdleTimeout: 300  → conversation-helper.sh idle-check (AI-judged)
  DEFAULT_MAX_AGE_DAYS=90  → is-memory-relevant / batch-prune-check
  maxPromptLength: 4000    → optimal-response-length (entity-preference-aware)

Examples:
  # Check if a memory is still relevant
  ai-judgment-helper.sh is-memory-relevant --content "CORS fix: add nginx proxy" --age-days 120

  # Get optimal response length for an entity
  ai-judgment-helper.sh optimal-response-length --entity ent_abc123 --channel matrix

  # Batch evaluate old memories (dry run)
  ai-judgment-helper.sh batch-prune-check --older-than-days 60 --limit 20 --dry-run

  # Replace the old prune command with intelligent pruning
  ai-judgment-helper.sh batch-prune-check --older-than-days 60

Environment:
  ANTHROPIC_API_KEY  Required for AI judgment (falls back to heuristics without it)

Cost: ~$0.001 per haiku judgment call. Batch of 50 memories ≈ $0.05.
HELP
	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	if [[ $# -eq 0 ]]; then
		cmd_help
		return 0
	fi

	local command="$1"
	shift

	case "$command" in
	is-memory-relevant) cmd_is_memory_relevant "$@" ;;
	optimal-response-length) cmd_optimal_response_length "$@" ;;
	should-prune) cmd_should_prune "$@" ;;
	batch-prune-check) cmd_batch_prune_check "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
