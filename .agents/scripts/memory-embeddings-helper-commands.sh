#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Memory Embeddings Commands -- CLI command implementations
# =============================================================================
# Contains all cmd_* functions for the memory-embeddings-helper CLI.
#
# Usage: source "${SCRIPT_DIR}/memory-embeddings-helper-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (log_error, log_info, log_warn, log_success)
#   - memory-embeddings-helper-engine.sh (check_deps, print_setup_instructions,
#     create_python_engine)
#   - Globals from memory-embeddings-helper.sh (PYTHON_SCRIPT, MEMORY_DB,
#     MEMORY_DIR, EMBEDDINGS_DB, CONFIG_FILE, LOCAL_MODEL_NAME,
#     LOCAL_EMBEDDING_DIM, OPENAI_MODEL_NAME, OPENAI_EMBEDDING_DIM)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MEMORY_EMBEDDINGS_COMMANDS_LIB_LOADED:-}" ]] && return 0
_MEMORY_EMBEDDINGS_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Setup: install dependencies and configure provider
#######################################
cmd_setup() {
	local provider="local"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider | -p)
			provider="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ "$provider" != "local" && "$provider" != "openai" ]]; then
		log_error "Invalid provider: $provider (use 'local' or 'openai')"
		return 1
	fi

	log_info "Setting up semantic memory embeddings (provider: $provider)..."

	if [[ "$provider" == "openai" ]]; then
		# OpenAI provider: needs python3, numpy, and API key
		if ! command -v python3 &>/dev/null; then
			log_error "Python 3 is required. Install it first."
			return 1
		fi

		if ! python3 -c "import numpy" &>/dev/null 2>&1; then
			log_info "Installing numpy..."
			pip install --quiet numpy
		fi

		# Check for API key
		if ! get_openai_key >/dev/null 2>&1; then
			log_warn "OpenAI API key not found."
			echo ""
			echo "Set it with one of:"
			echo "  aidevops secret set openai-api-key"
			echo "  export OPENAI_API_KEY=sk-..."
			echo ""
			echo "Provider configured but key needed before use."
		else
			log_success "OpenAI API key found"
		fi

		save_config "openai"
		create_python_engine

		# Test with a simple embedding if key is available
		if get_openai_key >/dev/null 2>&1; then
			log_info "Testing OpenAI embedding..."
			local api_key
			api_key=$(get_openai_key)
			if OPENAI_API_KEY="$api_key" python3 "$PYTHON_SCRIPT" embed openai "test" >/dev/null 2>&1; then
				log_success "OpenAI embeddings working"
			else
				log_warn "OpenAI test embedding failed. Check your API key."
			fi
		fi
	else
		# Local provider: needs python3, sentence-transformers, numpy
		if ! command -v python3 &>/dev/null; then
			log_error "Python 3 is required. Install it first."
			return 1
		fi

		log_info "Installing Python dependencies..."
		pip install --quiet sentence-transformers numpy

		save_config "local"
		create_python_engine

		log_info "Downloading model ($LOCAL_MODEL_NAME, ~90MB)..."
		python3 "$PYTHON_SCRIPT" embed local "test" >/dev/null
	fi

	log_success "Semantic memory setup complete (provider: $provider)."
	log_info "Run 'memory-embeddings-helper.sh index' to index existing memories."
	return 0
}

#######################################
# Switch or show provider
#######################################
cmd_provider() {
	local new_provider="${1:-}"

	if [[ -z "$new_provider" ]]; then
		local current
		current=$(get_provider)
		log_info "Current provider: $current"
		if [[ -f "$CONFIG_FILE" ]]; then
			local configured_at
			configured_at=$(grep '^configured_at=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
			if [[ -n "$configured_at" ]]; then
				log_info "Configured at: $configured_at"
			fi
		fi
		echo ""
		echo "Available providers:"
		echo "  local   - all-MiniLM-L6-v2 (384d, ~90MB, no API key)"
		echo "  openai  - text-embedding-3-small (1536d, requires API key)"
		echo ""
		echo "Switch with: memory-embeddings-helper.sh provider <local|openai>"
		return 0
	fi

	if [[ "$new_provider" != "local" && "$new_provider" != "openai" ]]; then
		log_error "Invalid provider: $new_provider (use 'local' or 'openai')"
		return 1
	fi

	local old_provider
	old_provider=$(get_provider)

	if [[ "$old_provider" == "$new_provider" ]]; then
		log_info "Already using provider: $new_provider"
		return 0
	fi

	save_config "$new_provider"
	log_success "Switched provider: $old_provider -> $new_provider"

	if [[ -f "$EMBEDDINGS_DB" ]]; then
		log_warn "Existing embeddings were created with '$old_provider' provider."
		log_warn "Run 'memory-embeddings-helper.sh rebuild' to re-index with '$new_provider'."
	fi

	return 0
}

#######################################
# Index all existing memories
#######################################
cmd_index() {
	if ! check_deps; then
		print_setup_instructions
		return 1
	fi

	if [[ ! -f "$MEMORY_DB" ]]; then
		log_error "Memory database not found at $MEMORY_DB"
		log_error "Store some memories first with: memory-helper.sh store --content \"...\""
		return 1
	fi

	local provider
	provider=$(get_provider)

	create_python_engine

	log_info "Indexing memories with $provider provider..."

	local result
	if [[ "$provider" == "openai" ]]; then
		local api_key
		api_key=$(get_openai_key) || {
			log_error "OpenAI API key not found"
			return 1
		}
		result=$(OPENAI_API_KEY="$api_key" python3 "$PYTHON_SCRIPT" index "$provider" "$MEMORY_DB" "$EMBEDDINGS_DB")
	else
		result=$(python3 "$PYTHON_SCRIPT" index "$provider" "$MEMORY_DB" "$EMBEDDINGS_DB")
	fi

	local indexed skipped total
	if command -v jq &>/dev/null; then
		indexed=$(echo "$result" | jq -r '.indexed')
		skipped=$(echo "$result" | jq -r '.skipped')
		total=$(echo "$result" | jq -r '.total')
	else
		indexed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['indexed'])")
		skipped=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['skipped'])")
		total=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['total'])")
	fi

	log_success "Indexed $indexed new memories ($skipped unchanged, $total total) [provider: $provider]"
	return 0
}

#######################################
# Search memories semantically
#######################################
cmd_search() {
	local query=""
	local limit=5
	local format="text"
	local hybrid=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--limit | -l)
			limit="$2"
			shift 2
			;;
		--json)
			format="json"
			shift
			;;
		--format)
			format="$2"
			shift 2
			;;
		--hybrid)
			hybrid=true
			shift
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
		log_error "Query is required: memory-embeddings-helper.sh search \"your query\""
		return 1
	fi

	if ! check_deps; then
		print_setup_instructions
		return 1
	fi

	if [[ ! -f "$EMBEDDINGS_DB" ]]; then
		log_error "Embeddings index not found. Run: memory-embeddings-helper.sh index"
		return 1
	fi

	local provider
	provider=$(get_provider)

	create_python_engine

	local search_cmd="search"
	if [[ "$hybrid" == true ]]; then
		search_cmd="hybrid"
	fi

	local result
	if [[ "$provider" == "openai" ]]; then
		local api_key
		api_key=$(get_openai_key) || {
			log_error "OpenAI API key not found"
			return 1
		}
		result=$(OPENAI_API_KEY="$api_key" python3 "$PYTHON_SCRIPT" "$search_cmd" "$provider" "$EMBEDDINGS_DB" "$MEMORY_DB" "$query" "$limit")
	else
		result=$(python3 "$PYTHON_SCRIPT" "$search_cmd" "$provider" "$EMBEDDINGS_DB" "$MEMORY_DB" "$query" "$limit")
	fi

	if [[ "$format" == "json" ]]; then
		echo "$result"
	else
		local method_label="Semantic"
		if [[ "$hybrid" == true ]]; then
			method_label="Hybrid (FTS5+Semantic)"
		fi

		echo ""
		echo "=== $method_label Search: \"$query\" [$provider] ==="
		echo ""
		if command -v jq &>/dev/null; then
			echo "$result" | jq -r '.[] | "[\(.type)] (score: \(.score)) \(.confidence)\n  \(.content)\n  Tags: \(.tags // "none")\n  Created: \(.created_at)\n  Method: \(.search_method)\n"'
		else
			python3 -c "
import json, sys
results = json.loads(sys.stdin.read())
for r in results:
    print(f'[{r[\"type\"]}] (score: {r[\"score\"]}) {r[\"confidence\"]}')
    print(f'  {r[\"content\"]}')
    print(f'  Tags: {r.get(\"tags\", \"none\")}')
    print(f'  Created: {r[\"created_at\"]}')
    print(f'  Method: {r.get(\"search_method\", \"semantic\")}')
    print()
" <<<"$result"
		fi
	fi
	return 0
}

#######################################
# Add single memory to index
#######################################
cmd_add() {
	local memory_id="$1"

	if [[ -z "$memory_id" ]]; then
		log_error "Memory ID required: memory-embeddings-helper.sh add <memory_id>"
		return 1
	fi

	if ! check_deps; then
		print_setup_instructions
		return 1
	fi

	local provider
	provider=$(get_provider)

	create_python_engine

	local result
	if [[ "$provider" == "openai" ]]; then
		local api_key
		api_key=$(get_openai_key) || {
			log_error "OpenAI API key not found"
			return 1
		}
		result=$(OPENAI_API_KEY="$api_key" python3 "$PYTHON_SCRIPT" add "$provider" "$MEMORY_DB" "$EMBEDDINGS_DB" "$memory_id")
	else
		result=$(python3 "$PYTHON_SCRIPT" add "$provider" "$MEMORY_DB" "$EMBEDDINGS_DB" "$memory_id")
	fi

	if echo "$result" | grep -q '"error"'; then
		log_error "$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['error'])" 2>/dev/null || echo "$result")"
		return 1
	fi

	log_success "Indexed memory: $memory_id [$provider]"
	return 0
}

#######################################
# Auto-index hook: called by memory-helper.sh after store
# Silently indexes new memory if embeddings are configured
# Designed to be fast and non-blocking
#######################################
cmd_auto_index() {
	local memory_id="${1:-}"

	if [[ -z "$memory_id" ]]; then
		return 0
	fi

	# Quick checks: bail fast if not configured
	if [[ ! -f "$CONFIG_FILE" ]]; then
		return 0
	fi

	if [[ ! -f "$EMBEDDINGS_DB" ]]; then
		return 0
	fi

	# Check deps silently
	if ! check_deps 2>/dev/null; then
		return 0
	fi

	local provider
	provider=$(get_provider)

	create_python_engine 2>/dev/null

	# Run in background to avoid slowing down store
	if [[ "$provider" == "openai" ]]; then
		local api_key
		api_key=$(get_openai_key 2>/dev/null) || return 0
		(OPENAI_API_KEY="$api_key" python3 "$PYTHON_SCRIPT" add "$provider" "$MEMORY_DB" "$EMBEDDINGS_DB" "$memory_id" >/dev/null 2>&1) &
	else
		(python3 "$PYTHON_SCRIPT" add "$provider" "$MEMORY_DB" "$EMBEDDINGS_DB" "$memory_id" >/dev/null 2>&1) &
	fi
	disown 2>/dev/null || true

	return 0
}

#######################################
# Find semantically similar memory for dedup (t1363.6)
# Replaces exact-string dedup with semantic similarity.
# Returns the matching memory ID on stdout if a similar memory exists
# above the threshold, or empty string if no match.
#
# Arguments:
#   $1 - content text to check
#   $2 - memory type (e.g., WORKING_SOLUTION)
#   $3 - similarity threshold (default: 0.85)
#
# Exit: 0 if similar found (ID on stdout), 1 if no match
#######################################
cmd_find_similar() {
	local content="${1:-}"
	local mem_type="${2:-}"
	local threshold="${3:-0.85}"

	if [[ -z "$content" || -z "$mem_type" ]]; then
		return 1
	fi

	# Quick checks: bail fast if not configured
	if [[ ! -f "$CONFIG_FILE" ]]; then
		return 1
	fi

	if [[ ! -f "$EMBEDDINGS_DB" ]]; then
		return 1
	fi

	# Check deps silently
	if ! check_deps 2>/dev/null; then
		return 1
	fi

	local provider
	provider=$(get_provider)

	create_python_engine 2>/dev/null

	local result
	if [[ "$provider" == "openai" ]]; then
		local api_key
		api_key=$(get_openai_key 2>/dev/null) || return 1
		result=$(OPENAI_API_KEY="$api_key" python3 "$PYTHON_SCRIPT" find-similar \
			"$provider" "$EMBEDDINGS_DB" "$MEMORY_DB" "$content" "$mem_type" "$threshold" 2>/dev/null) || return 1
	else
		result=$(python3 "$PYTHON_SCRIPT" find-similar \
			"$provider" "$EMBEDDINGS_DB" "$MEMORY_DB" "$content" "$mem_type" "$threshold" 2>/dev/null) || return 1
	fi

	# Parse result — empty JSON object means no match
	if [[ -z "$result" || "$result" == "{}" ]]; then
		return 1
	fi

	# Extract the matching memory ID
	local match_id
	if command -v jq &>/dev/null; then
		match_id=$(echo "$result" | jq -r '.id // empty' 2>/dev/null)
	else
		match_id=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)
	fi

	if [[ -n "$match_id" ]]; then
		echo "$match_id"
		return 0
	fi

	return 1
}

#######################################
# Show index status
#######################################
cmd_status() {
	local provider
	provider=$(get_provider)

	log_info "Provider: $provider"

	if [[ "$provider" == "local" ]]; then
		log_info "Model: $LOCAL_MODEL_NAME (${LOCAL_EMBEDDING_DIM}d)"
	else
		log_info "Model: $OPENAI_MODEL_NAME (${OPENAI_EMBEDDING_DIM}d)"
	fi

	if [[ ! -f "$EMBEDDINGS_DB" ]]; then
		log_info "Embeddings index: not created"
		log_info "Run 'memory-embeddings-helper.sh setup' to enable semantic search"
		return 0
	fi

	if ! check_deps; then
		log_warn "Dependencies not installed for $provider provider"
		log_info "Run 'memory-embeddings-helper.sh setup --provider $provider' to install"
		return 0
	fi

	create_python_engine

	local result
	result=$(python3 "$PYTHON_SCRIPT" status "$EMBEDDINGS_DB")

	local count size_mb
	if command -v jq &>/dev/null; then
		count=$(echo "$result" | jq -r '.count')
		size_mb=$(echo "$result" | jq -r '.size_mb')
		local providers_info
		providers_info=$(echo "$result" | jq -r '.providers | to_entries | map("\(.key): \(.value)") | join(", ")')
		log_info "Embeddings index: $count memories indexed (${size_mb}MB)"
		if [[ -n "$providers_info" ]]; then
			log_info "By provider: $providers_info"
		fi
	else
		count=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])")
		size_mb=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['size_mb'])")
		log_info "Embeddings index: $count memories indexed (${size_mb}MB)"
	fi

	log_info "Database: $EMBEDDINGS_DB"

	# Compare with memory DB
	if [[ -f "$MEMORY_DB" ]]; then
		local total_memories
		total_memories=$(sqlite3 "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "?")
		local unindexed=$((total_memories - count))
		log_info "Total memories: $total_memories ($unindexed unindexed)"
	fi
	return 0
}

#######################################
# Rebuild entire index
#######################################
cmd_rebuild() {
	log_info "Rebuilding embeddings index..."

	if [[ -f "$EMBEDDINGS_DB" ]]; then
		rm "$EMBEDDINGS_DB"
		log_info "Removed old index"
	fi

	cmd_index
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
memory-embeddings-helper.sh - Semantic memory search (opt-in)

PROVIDERS:
  local   - all-MiniLM-L6-v2 (384d, ~90MB download, no API key needed)
  openai  - text-embedding-3-small (1536d, requires OpenAI API key)

USAGE:
  memory-embeddings-helper.sh [--namespace NAME] <command> [options]

COMMANDS:
  setup [--provider local|openai]  Configure and install dependencies
  index                            Index all existing memories
  search "query"                   Semantic similarity search
  search "query" --hybrid          Hybrid FTS5+semantic search (RRF)
  search "query" --limit 10        Search with custom limit
  add <memory_id>                  Index single memory
  auto-index <memory_id>           Auto-index hook (called by memory-helper.sh)
  find-similar "text" TYPE [0.85]  Semantic dedup check (used by check_duplicate)
  status                           Show index stats and provider info
  rebuild                          Rebuild entire index
  provider [local|openai]          Show or switch embedding provider
  help                             Show this help

SEARCH MODES:
  --semantic (default)   Pure vector similarity search
  --hybrid               Combines FTS5 keyword + semantic using Reciprocal
                         Rank Fusion (RRF). Best for natural language queries
                         that benefit from both exact keyword and meaning match.

INTEGRATION:
  memory-helper.sh recall "query" --semantic   Delegates to this script
  memory-helper.sh recall "query" --hybrid     Hybrid FTS5+semantic search

AUTO-INDEXING:
  When embeddings are configured, new memories stored via memory-helper.sh
  are automatically indexed in the background. No manual indexing needed
  after initial setup.

EXAMPLES:
  # Setup with local model (no API key needed)
  memory-embeddings-helper.sh setup --provider local

  # Setup with OpenAI (needs API key)
  memory-embeddings-helper.sh setup --provider openai

  # Index all memories
  memory-embeddings-helper.sh index

  # Semantic search
  memory-embeddings-helper.sh search "how to optimize database queries"

  # Hybrid search (best results)
  memory-embeddings-helper.sh search "authentication patterns" --hybrid

  # Switch provider
  memory-embeddings-helper.sh provider openai

  # Check status
  memory-embeddings-helper.sh status

This is opt-in. FTS5 keyword search (memory-helper.sh recall) works without this.
EOF
	return 0
}
