#!/usr/bin/env bash
# memory-helper.sh - Lightweight memory system for aidevops
# Uses SQLite FTS5 for fast text search without external dependencies
#
# Modularised in t311.4: functions split into memory/ subdirectory modules.
# This file is the entry point — globals, module sourcing, help, and dispatch.
#
# Inspired by Supermemory's architecture for:
# - Relational versioning (updates, extends, derives relationships)
# - Dual timestamps (created_at vs event_date)
# - Contextual disambiguation (atomic, self-contained memories)
#
# Usage:
#   memory-helper.sh store --content "learning" [--type TYPE] [--tags "a,b"] [--session-id ID]
#   memory-helper.sh store --content "new info" --supersedes mem_xxx --relation updates
#   memory-helper.sh recall --query "search terms" [--limit 5] [--type TYPE] [--max-age-days 30]
#   memory-helper.sh history <id>             # Show version history for a memory
#   memory-helper.sh stats                    # Show memory statistics
#   memory-helper.sh prune [--older-than-days 90] [--dry-run]  # Remove stale entries
#   memory-helper.sh validate                 # Check for stale/low-quality entries
#   memory-helper.sh export [--format json|toon]  # Export all memories
#
# Namespace Support (per-runner memory isolation):
#   memory-helper.sh --namespace my-runner store --content "runner-specific learning"
#   memory-helper.sh --namespace my-runner recall --query "search" [--shared]
#   memory-helper.sh --namespace my-runner stats
#   memory-helper.sh namespaces              # List all namespaces
#
# Relational Versioning (inspired by Supermemory):
#   - updates: New info supersedes old (e.g., "favorite color is now green")
#   - extends: Adds detail without contradiction (e.g., adding job title)
#   - derives: Second-order inference from combining memories
#
# Dual Timestamps:
#   - created_at: When the memory was stored
#   - event_date: When the event described actually occurred
#
# Staleness Prevention:
#   - Entries have created_at and last_accessed_at timestamps
#   - Recall updates last_accessed_at (frequently used = valuable)
#   - Prune removes entries older than threshold AND never accessed
#   - Validate warns about potentially stale entries

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration — globals used by sourced modules (memory/_common.sh, store.sh, recall.sh, maintenance.sh)
readonly MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
# shellcheck disable=SC2034 # Used in memory/_common.sh and memory/maintenance.sh
readonly DEFAULT_MAX_AGE_DAYS=90

# Namespace support: --namespace sets a per-runner isolated DB
# Parsed in main() before command dispatch
MEMORY_NAMESPACE=""
MEMORY_DIR="$MEMORY_BASE_DIR"
MEMORY_DB="$MEMORY_DIR/memory.db"
# shellcheck disable=SC2034 # Used in memory/maintenance.sh
readonly STALE_WARNING_DAYS=60

# Valid learning types (matches documentation and Continuous-Claude-v3)
# shellcheck disable=SC2034 # Used in memory/store.sh and memory/recall.sh
readonly VALID_TYPES="WORKING_SOLUTION FAILED_APPROACH CODEBASE_PATTERN USER_PREFERENCE TOOL_CONFIG DECISION CONTEXT ARCHITECTURAL_DECISION ERROR_FIX OPEN_THREAD SUCCESS_PATTERN FAILURE_PATTERN"

# Valid relation types (inspired by Supermemory's relational versioning)
# - updates: New info supersedes old (state mutation)
# - extends: Adds detail without contradiction (refinement)
# - derives: Second-order inference from combining memories
# shellcheck disable=SC2034 # Used in memory/store.sh
readonly VALID_RELATIONS="updates extends derives"

# Source modules (eager loading — simpler, avoids path resolution bugs)
# shellcheck source=memory/_common.sh
source "${SCRIPT_DIR}/memory/_common.sh"
# shellcheck source=memory/store.sh
source "${SCRIPT_DIR}/memory/store.sh"
# shellcheck source=memory/recall.sh
source "${SCRIPT_DIR}/memory/recall.sh"
# shellcheck source=memory/maintenance.sh
source "${SCRIPT_DIR}/memory/maintenance.sh"

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
memory-helper.sh - Lightweight memory system for aidevops

Inspired by Supermemory's architecture for relational versioning,
dual timestamps, and contextual disambiguation.

USAGE:
    memory-helper.sh [--namespace NAME] <command> [options]

COMMANDS:
    store       Store a new learning (with automatic deduplication)
    recall      Search and retrieve learnings
    log         Show recent auto-captured memories (alias for recall --recent --auto-only)
    history     Show version history for a memory (ancestors/descendants)
    latest      Find the latest version of a memory chain
    stats       Show memory statistics
    validate    Check for stale/duplicate entries (with detailed reports)
    prune       Remove old entries (auto-runs every 24h on store)
    prune-patterns  Remove repetitive pattern entries by keyword (e.g., clean_exit_no_signal)
    dedup       Remove exact and near-duplicate entries
    consolidate Merge similar memories to reduce redundancy
    export      Export all memories
    graduate    Promote validated memories into shared docs (delegates to memory-graduate-helper.sh)
    namespaces  List all memory namespaces
    help        Show this help

GLOBAL OPTIONS:
    --namespace <name>    Use isolated memory namespace (per-runner)
                          Creates DB at: memory/namespaces/<name>/memory.db

STORE OPTIONS:
    --content <text>      Learning content (required)
    --type <type>         Learning type (default: WORKING_SOLUTION)
    --tags <tags>         Comma-separated tags
    --confidence <level>  high, medium, or low (default: medium)
    --session-id <id>     Session identifier
    --project <path>      Project path
    --event-date <ISO>    When the event occurred (default: now)
    --supersedes <id>     ID of memory this updates/extends/derives from
    --relation <type>     Relation type: updates, extends, derives
    --auto                Mark as auto-captured (sets source=auto, tracked separately)

VALID TYPES:
    WORKING_SOLUTION, FAILED_APPROACH, CODEBASE_PATTERN, USER_PREFERENCE,
    TOOL_CONFIG, DECISION, CONTEXT, ARCHITECTURAL_DECISION, ERROR_FIX,
    OPEN_THREAD, SUCCESS_PATTERN, FAILURE_PATTERN

RELATION TYPES (inspired by Supermemory):
    updates   - New info supersedes old (state mutation)
                e.g., "My favorite color is now green" updates "...is blue"
    extends   - Adds detail without contradiction (refinement)
                e.g., Adding job title to existing employment memory
    derives   - Second-order inference from combining memories
                e.g., Inferring "works remotely" from location + job info

RECALL OPTIONS:
    --query <text>        Search query (required unless --recent)
    --limit <n>           Max results (default: 5)
    --type <type>         Filter by type
    --max-age-days <n>    Only recent entries
    --project <path>      Filter by project path
    --recent [n]          Show n most recent entries (default: 10)
    --shared              Also search global memory (when using --namespace)
    --auto-only           Show only auto-captured memories
    --manual-only         Show only manually stored memories
    --semantic            Use semantic similarity search (requires embeddings setup)
    --similar             Alias for --semantic
    --hybrid              Combine FTS5 keyword + semantic search using RRF
    --stats               Show memory statistics
    --json                Output as JSON

PRUNE OPTIONS:
    --older-than-days <n> Age threshold (default: 90)
    --dry-run             Show what would be deleted
    --include-accessed    Also prune accessed entries

PRUNE-PATTERNS OPTIONS:
    <keyword>             Error/pattern keyword to match (required)
    --keep <n>            Number of newest entries to keep (default: 3)
    --types <list>        Comma-separated types to search (default: FAILURE_PATTERN,ERROR_FIX,FAILED_APPROACH)
    --dry-run             Show what would be removed without deleting

DEDUP OPTIONS:
    --dry-run             Show what would be removed without deleting
    --exact-only          Only remove exact duplicates (skip near-duplicates)

DEDUPLICATION:
    - Store automatically detects and skips duplicate content
    - Exact matches: identical content string + same type
    - Near matches: same content after normalizing case/punctuation/whitespace
    - When a duplicate is detected on store, the existing entry's access count
      is incremented and its ID is returned
    - Use 'dedup' command to clean up existing duplicates in bulk

AUTO-PRUNING:
    - Runs automatically on every store (at most once per 24 hours)
    - Removes entries older than 90 days that have never been accessed
    - Frequently accessed memories are preserved regardless of age
    - Manual prune available via 'prune' command for custom thresholds

DUAL TIMESTAMPS:
    - created_at:  When the memory was stored in the database
    - event_date:  When the event described actually occurred
    This enables temporal reasoning like "what happened last week?"

PRIVACY FILTERS:
    - <private>...</private> tags are stripped from content before storage
    - Content matching secret patterns (API keys, tokens) is rejected
    - Use privacy-filter-helper.sh for comprehensive scanning

STALENESS PREVENTION:
    - Entries track created_at and last_accessed_at
    - Recall updates last_accessed_at (used = valuable)
    - Prune removes old entries that were never accessed
    - Validate warns about potentially stale entries

EXAMPLES:
    # Store a learning
    memory-helper.sh store --content "Use FTS5 for fast search" --type WORKING_SOLUTION

    # Store with event date (when it happened, not when stored)
    memory-helper.sh store --content "Fixed CORS issue" --event-date "2024-01-15T10:00:00Z"

    # Update an existing memory (creates version chain)
    memory-helper.sh store --content "Favorite color is now green" \
        --supersedes mem_xxx --relation updates

    # Extend a memory with more detail
    memory-helper.sh store --content "Job title: Senior Engineer" \
        --supersedes mem_yyy --relation extends

    # View version history
    memory-helper.sh history mem_xxx

    # Find latest version in a chain
    memory-helper.sh latest mem_xxx

    # Store an auto-captured memory (from AI agent)
    memory-helper.sh store --auto --content "Fixed CORS with nginx headers" --type WORKING_SOLUTION

    # Recall learnings (keyword search - default)
    memory-helper.sh recall --query "database search" --limit 10

    # Recall only auto-captured memories
    memory-helper.sh recall --recent --auto-only

    # Recall only manually stored memories
    memory-helper.sh recall --query "cors" --manual-only

    # Recall learnings (semantic similarity - opt-in, requires setup)
    memory-helper.sh recall --query "how to optimize queries" --semantic

    # Recall learnings (hybrid FTS5+semantic - best results)
    memory-helper.sh recall --query "authentication patterns" --hybrid

    # Check for stale entries
    memory-helper.sh validate

    # Clean up old unused entries
    memory-helper.sh prune --older-than-days 60 --dry-run

    # Consolidate similar memories
    memory-helper.sh consolidate --dry-run

    # Remove duplicate memories (preview first)
    memory-helper.sh dedup --dry-run
    memory-helper.sh dedup
    memory-helper.sh dedup --exact-only

NAMESPACE EXAMPLES:
    # Store in a runner-specific namespace
    memory-helper.sh --namespace code-reviewer store --content "Prefer explicit error handling"

    # Recall from namespace only
    memory-helper.sh --namespace code-reviewer recall "error handling"

    # Recall from namespace + global (shared access)
    memory-helper.sh --namespace code-reviewer recall "error handling" --shared

    # View namespace stats
    memory-helper.sh --namespace code-reviewer stats

    # List all namespaces
    memory-helper.sh namespaces

    # Remove orphaned namespaces (no matching runner)
    memory-helper.sh namespaces prune --dry-run
    memory-helper.sh namespaces prune

    # Migrate entries between namespaces
    memory-helper.sh namespaces migrate --from code-reviewer --to global --dry-run
    memory-helper.sh namespaces migrate --from code-reviewer --to global
    memory-helper.sh namespaces migrate --from global --to seo-analyst --move
EOF
	return 0
}

#######################################
# Main entry point
# Parses global --namespace flag before dispatching to commands
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
			resolve_namespace "$2" || return 1
			shift 2
			;;
		*)
			break
			;;
		esac
	done

	local command="${1:-help}"
	shift || true

	# Show namespace context if set
	if [[ -n "$MEMORY_NAMESPACE" ]]; then
		log_info "Using namespace: $MEMORY_NAMESPACE ($MEMORY_DB)"
	fi

	case "$command" in
	store) cmd_store "$@" ;;
	recall) cmd_recall "$@" ;;
	log) cmd_log "$@" ;;
	history) cmd_history "$@" ;;
	latest) cmd_latest "$@" ;;
	stats) cmd_stats ;;
	validate) cmd_validate ;;
	prune) cmd_prune "$@" ;;
	prune-patterns) cmd_prune_patterns "$@" ;;
	dedup) cmd_dedup "$@" ;;
	consolidate) cmd_consolidate "$@" ;;
	export) cmd_export "$@" ;;
	graduate)
		# Delegate to memory-graduate-helper.sh
		local graduate_script
		graduate_script="$(dirname "$0")/memory-graduate-helper.sh"
		if [[ ! -x "$graduate_script" ]]; then
			log_error "Graduate helper not found: $graduate_script"
			return 1
		fi
		"$graduate_script" "$@"
		;;
	namespaces)
		# Support subcommands: namespaces [list|prune|migrate]
		local ns_subcmd="${1:-list}"
		case "$ns_subcmd" in
		prune)
			shift
			cmd_namespaces_prune "$@"
			;;
		migrate)
			shift
			cmd_namespaces_migrate "$@"
			;;
		list | --json | --format) cmd_namespaces "$@" ;;
		*) cmd_namespaces "$@" ;;
		esac
		;;
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
