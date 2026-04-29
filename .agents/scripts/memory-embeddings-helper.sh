#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Memory Embeddings Helper -- Orchestrator
# =============================================================================
# Semantic memory search using vector embeddings.
# Opt-in enhancement for memory-helper.sh (FTS5 remains the default).
#
# Supports two embedding providers:
#   - local: all-MiniLM-L6-v2 via sentence-transformers (~90MB, no API key)
#   - openai: text-embedding-3-small via OpenAI API (requires API key)
#
# Usage:
#   memory-embeddings-helper.sh setup [--provider local|openai]
#   memory-embeddings-helper.sh index
#   memory-embeddings-helper.sh search "query"
#   memory-embeddings-helper.sh search "query" --hybrid
#   memory-embeddings-helper.sh search "query" --limit 10
#   memory-embeddings-helper.sh add <memory_id>
#   memory-embeddings-helper.sh status
#   memory-embeddings-helper.sh rebuild
#   memory-embeddings-helper.sh provider [local|openai]
#   memory-embeddings-helper.sh help
#
# Sub-libraries:
#   memory-embeddings-helper-engine.sh   -- Python engine generation
#   memory-embeddings-helper-commands.sh -- CLI command implementations
#
# Part of aidevops framework: https://aidevops.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
readonly LOCAL_MODEL_NAME="all-MiniLM-L6-v2"
readonly LOCAL_EMBEDDING_DIM=384
readonly OPENAI_MODEL_NAME="text-embedding-3-small"
readonly OPENAI_EMBEDDING_DIM=1536

# Namespace support: resolved in main() before command dispatch
EMBEDDINGS_NAMESPACE=""
MEMORY_DIR="$MEMORY_BASE_DIR"
MEMORY_DB="$MEMORY_DIR/memory.db"
EMBEDDINGS_DB="$MEMORY_DIR/embeddings.db"
PYTHON_SCRIPT="$MEMORY_DIR/.embeddings-engine.py"
CONFIG_FILE="$MEMORY_DIR/.embeddings-config"

# Logging: uses shared log_* from shared-constants.sh

#######################################
# Resolve namespace to correct DB paths
#######################################
resolve_embeddings_namespace() {
	local namespace="$1"

	if [[ -z "$namespace" ]]; then
		MEMORY_DIR="$MEMORY_BASE_DIR"
		MEMORY_DB="$MEMORY_DIR/memory.db"
		EMBEDDINGS_DB="$MEMORY_DIR/embeddings.db"
		PYTHON_SCRIPT="$MEMORY_BASE_DIR/.embeddings-engine.py"
		CONFIG_FILE="$MEMORY_BASE_DIR/.embeddings-config"
		return 0
	fi

	if [[ ! "$namespace" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
		log_error "Invalid namespace: '$namespace'"
		return 1
	fi

	EMBEDDINGS_NAMESPACE="$namespace"
	MEMORY_DIR="$MEMORY_BASE_DIR/namespaces/$namespace"
	MEMORY_DB="$MEMORY_DIR/memory.db"
	EMBEDDINGS_DB="$MEMORY_DIR/embeddings.db"
	# Python script and config stay in base dir (shared across namespaces)
	PYTHON_SCRIPT="$MEMORY_BASE_DIR/.embeddings-engine.py"
	CONFIG_FILE="$MEMORY_BASE_DIR/.embeddings-config"
	return 0
}

#######################################
# Read configured provider (default: local)
#######################################
get_provider() {
	if [[ -f "$CONFIG_FILE" ]]; then
		local provider
		provider=$(grep '^provider=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
		if [[ "$provider" == "openai" || "$provider" == "local" ]]; then
			echo "$provider"
			return 0
		fi
	fi
	echo "local"
	return 0
}

#######################################
# Get embedding dimension for current provider
#######################################
get_embedding_dim() {
	local provider
	provider=$(get_provider)
	if [[ "$provider" == "openai" ]]; then
		echo "$OPENAI_EMBEDDING_DIM"
	else
		echo "$LOCAL_EMBEDDING_DIM"
	fi
	return 0
}

#######################################
# Save provider configuration
#######################################
save_config() {
	local provider="$1"
	mkdir -p "$(dirname "$CONFIG_FILE")"
	echo "provider=$provider" >"$CONFIG_FILE"
	echo "configured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$CONFIG_FILE"
	return 0
}

#######################################
# Get OpenAI API key from aidevops secret store
# NEVER prints the key to stdout in normal operation
#######################################
get_openai_key() {
	# Check environment variable first
	if [[ -n "${OPENAI_API_KEY:-}" ]]; then
		echo "$OPENAI_API_KEY"
		return 0
	fi

	# Check aidevops secret store (gopass)
	if command -v gopass &>/dev/null; then
		local key
		key=$(gopass show -o "aidevops/openai-api-key" 2>/dev/null || echo "")
		if [[ -n "$key" ]]; then
			echo "$key"
			return 0
		fi
	fi

	# Check credentials file
	local creds_file="$HOME/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]]; then
		local key
		# shellcheck disable=SC1090
		key=$(source "$creds_file" 2>/dev/null && echo "${OPENAI_API_KEY:-}")
		if [[ -n "$key" ]]; then
			echo "$key"
			return 0
		fi
	fi

	return 1
}

# --- Source sub-libraries ---

# shellcheck source=./memory-embeddings-helper-engine.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/memory-embeddings-helper-engine.sh"

# shellcheck source=./memory-embeddings-helper-commands.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/memory-embeddings-helper-commands.sh"

#######################################
# Main entry point
#######################################
main() {
	# Parse global flags before command
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--namespace | -n)
			if [[ $# -lt 2 ]]; then
				log_error "--namespace requires a value"
				return 1
			fi
			resolve_embeddings_namespace "$2" || return 1
			shift 2
			;;
		*)
			break
			;;
		esac
	done

	local command="${1:-help}"
	shift || true

	if [[ -n "$EMBEDDINGS_NAMESPACE" ]]; then
		log_info "Using namespace: $EMBEDDINGS_NAMESPACE"
	fi

	case "$command" in
	setup) cmd_setup "$@" ;;
	index) cmd_index ;;
	search) cmd_search "$@" ;;
	add) cmd_add "${1:-}" ;;
	auto-index) cmd_auto_index "${1:-}" ;;
	find-similar) cmd_find_similar "$@" ;;
	status) cmd_status ;;
	rebuild) cmd_rebuild ;;
	provider) cmd_provider "${1:-}" ;;
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
