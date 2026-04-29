#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# self-evolution-helper.sh - Self-evolution loop for aidevops
# Detects capability gaps from entity interaction patterns, creates TODO tasks
# with evidence trails, tracks gap frequency, and manages resolution lifecycle.
#
# Part of the conversational memory system (p035 / t1363).
# Uses the same SQLite database (memory.db) as entity-helper.sh and
# conversation-helper.sh.
#
# Architecture:
#   Entity interactions (Layer 0)
#     → Pattern detection (AI judgment, not regex)
#     → Capability gap identification
#     → TODO creation with evidence trail (interaction IDs)
#     → System upgrade (normal aidevops task lifecycle)
#     → Better service to entity
#     → Updated entity model (Layer 2)
#     → Cycle continues
#
# Usage:
#   self-evolution-helper.sh scan-patterns [--entity <id>] [--since <ISO>] [--limit <n>]
#   self-evolution-helper.sh detect-gaps [--entity <id>] [--since <ISO>]
#   self-evolution-helper.sh create-todo <gap_id> [--repo-path <path>]
#   self-evolution-helper.sh list-gaps [--status detected|todo_created|resolved|wont_fix] [--json]
#   self-evolution-helper.sh update-gap <gap_id> --status <status> [--todo-ref <ref>]
#   self-evolution-helper.sh resolve-gap <gap_id> [--todo-ref <ref>]
#   self-evolution-helper.sh pulse-scan [--since <ISO>]
#   self-evolution-helper.sh stats [--json]
#   self-evolution-helper.sh migrate
#   self-evolution-helper.sh help
#
# Sub-libraries (sourced below):
#   self-evolution-helper-db.sh      -- DB utilities, schema init
#   self-evolution-helper-scan.sh    -- Pattern scanning (AI + heuristic)
#   self-evolution-helper-gaps.sh    -- Gap detection and evidence recording
#   self-evolution-helper-todo.sh    -- TODO task creation
#   self-evolution-helper-manage.sh  -- Gap listing, updating, resolution
#   self-evolution-helper-pulse.sh   -- Pulse scanning, interval guard, stats

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration — uses same base as entity-helper.sh
readonly EVOL_MEMORY_BASE_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
EVOL_MEMORY_DB="${EVOL_MEMORY_BASE_DIR}/memory.db"

# AI research script for intelligent judgments (haiku tier)
readonly EVOL_AI_RESEARCH_SCRIPT="${SCRIPT_DIR}/ai-research-helper.sh"

# Default lookback window for pattern scanning (24 hours)
readonly DEFAULT_SCAN_WINDOW_HOURS=24

# Valid gap statuses
readonly VALID_GAP_STATUSES="detected todo_created resolved wont_fix"

# Minimum interactions to consider for pattern scanning
readonly MIN_INTERACTIONS_FOR_SCAN=3

# Pulse interval guard — minimum hours between automatic scans
readonly PULSE_INTERVAL_HOURS=6
readonly EVOL_STATE_DIR="${HOME}/.aidevops/logs"
readonly EVOL_STATE_FILE="${EVOL_STATE_DIR}/self-evolution-last-run"

# --- Source sub-libraries ---

# shellcheck source=./self-evolution-helper-db.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-db.sh"

# shellcheck source=./self-evolution-helper-scan.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-scan.sh"

# shellcheck source=./self-evolution-helper-gaps.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-gaps.sh"

# shellcheck source=./self-evolution-helper-todo.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-todo.sh"

# shellcheck source=./self-evolution-helper-manage.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-manage.sh"

# shellcheck source=./self-evolution-helper-pulse.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-pulse.sh"

# --- Orchestrator functions (kept here for identity-key preservation) ---

#######################################
# Run schema migration (idempotent)
#######################################
cmd_migrate() {
	log_info "Running self-evolution schema migration..."

	# Backup before migration
	if [[ -f "$EVOL_MEMORY_DB" ]]; then
		local backup
		backup=$(backup_sqlite_db "$EVOL_MEMORY_DB" "pre-self-evolution-migrate")
		if [[ $? -ne 0 || -z "$backup" ]]; then
			log_warn "Backup failed before migration — proceeding cautiously"
		else
			log_info "Pre-migration backup: $backup"
		fi
	fi

	init_evol_db

	log_success "Self-evolution schema migration complete"

	# Show table status
	evol_db "$EVOL_MEMORY_DB" <<'EOF'
SELECT 'capability_gaps: ' || (SELECT COUNT(*) FROM capability_gaps) || ' rows' ||
    char(10) || 'gap_evidence: ' || (SELECT COUNT(*) FROM gap_evidence) || ' rows';
EOF

	return 0
}

#######################################
# Print command reference section of help
#######################################
_help_commands() {
	cat <<'EOF'
USAGE:
    self-evolution-helper.sh <command> [options]

PATTERN SCANNING:
    scan-patterns       Scan recent interactions for capability gap patterns
    detect-gaps         Detect gaps and record them in the database
    pulse-scan          Full self-evolution cycle (for pulse supervisor)

GAP MANAGEMENT:
    list-gaps           List capability gaps
    update-gap <id>     Update a gap's status
    resolve-gap <id>    Mark a gap as resolved
    create-todo <id>    Create a TODO task for a gap

SYSTEM:
    stats               Show self-evolution statistics
    migrate             Run schema migration (idempotent)
    help                Show this help

SCAN-PATTERNS OPTIONS:
    --entity <id>       Filter by entity
    --since <ISO>       Scan window start (default: 24h ago)
    --limit <n>         Max interactions to analyse (default: 100)
    --json              Output as JSON

DETECT-GAPS OPTIONS:
    --entity <id>       Filter by entity
    --since <ISO>       Scan window start (default: 24h ago)
    --dry-run           Show what would be detected without recording

CREATE-TODO OPTIONS:
    --repo-path <path>  Repository path for TODO creation (default: ~/Git/aidevops)

LIST-GAPS OPTIONS:
    --status <status>   Filter: detected, todo_created, resolved, wont_fix
    --entity <id>       Filter by entity
    --sort <field>      Sort by: frequency (default), date, status
    --limit <n>         Max results (default: 50)
    --json              Output as JSON

UPDATE-GAP OPTIONS:
    --status <status>   New status (required)
    --todo-ref <ref>    TODO reference (e.g., "t1234 (GH#567)")

PULSE-SCAN OPTIONS:
    --since <ISO>       Scan window start (default: 24h ago)
    --auto-todo-threshold <n>  Frequency threshold for auto-TODO (default: 3)
    --repo-path <path>  Repository path for TODO creation
    --dry-run           Scan without creating TODOs
    --force             Skip interval guard (default: 6h between scans)
EOF
	return 0
}

#######################################
# Print concepts and examples section of help
#######################################
_help_concepts() {
	cat <<'EOF'
SELF-EVOLUTION LOOP:
    The self-evolution loop is the core differentiator of the entity memory
    system. It works as follows:

    1. Entity interactions are logged (Layer 0) by entity-helper.sh
    2. scan-patterns analyses recent interactions using AI judgment (haiku
       tier, ~$0.001/call) to identify capability gaps — things users needed
       that the system couldn't do well
    3. detect-gaps records these patterns in the capability_gaps table,
       deduplicating against existing gaps (incrementing frequency)
    4. When a gap's frequency exceeds the auto-TODO threshold (default: 3),
       pulse-scan automatically creates a TODO task via claim-task-id.sh
    5. The TODO enters the normal aidevops task lifecycle (dispatch, PR, merge)
    6. When the task is completed, the gap is marked as resolved
    7. The system is now better at serving the entity's needs

    This creates a compound improvement loop: more interactions → more
    pattern data → better gap detection → more targeted improvements →
    better service → more interactions.

GAP LIFECYCLE:
    detected       Gap identified from interaction patterns
    todo_created   TODO task created (with evidence trail)
    resolved       The capability was implemented (task completed)
    wont_fix       Gap acknowledged but won't be addressed

EVIDENCE TRAIL:
    Every gap links to the specific interaction IDs that revealed it via
    the gap_evidence table. This provides full traceability:
    gap → gap_evidence → interactions → raw messages

    When a TODO is created, the issue body includes the evidence trail
    so the implementing worker has full context on what users actually
    needed and when.

AI JUDGMENT:
    Pattern scanning uses AI (haiku tier) to identify genuine capability
    gaps vs normal conversation. This follows the Intelligence Over
    Determinism principle — no regex can reliably distinguish "user asked
    for something we can't do" from "user asked a question we answered."

    When AI is unavailable, heuristic fallbacks scan for common indicators
    (outbound messages containing "can't", "unable", etc.) but with lower
    accuracy.

EXAMPLES:
    # Scan recent interactions for patterns
    self-evolution-helper.sh scan-patterns --since 2026-02-27T00:00:00Z

    # Detect and record gaps
    self-evolution-helper.sh detect-gaps --since 2026-02-27T00:00:00Z

    # Run full pulse scan (for supervisor integration)
    self-evolution-helper.sh pulse-scan --auto-todo-threshold 3

    # Force pulse scan (bypass 6h interval guard)
    self-evolution-helper.sh pulse-scan --force

    # List detected gaps sorted by frequency
    self-evolution-helper.sh list-gaps --status detected --sort frequency

    # Create TODO for a specific gap
    self-evolution-helper.sh create-todo gap_xxx --repo-path ~/Git/aidevops

    # Mark a gap as resolved
    self-evolution-helper.sh resolve-gap gap_xxx --todo-ref "t1400 (GH#2600)"

    # View statistics
    self-evolution-helper.sh stats --json
EOF
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
self-evolution-helper.sh - Self-evolution loop for aidevops

Part of the conversational memory system (p035 / t1363).
Detects capability gaps from entity interaction patterns, creates TODO tasks
with evidence trails, tracks gap frequency, and manages resolution lifecycle.

EOF
	_help_commands
	echo ""
	_help_concepts
	return 0
}

#######################################
# Main entry point
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	scan-patterns) cmd_scan_patterns "$@" ;;
	detect-gaps) cmd_detect_gaps "$@" ;;
	create-todo) cmd_create_todo "$@" ;;
	list-gaps) cmd_list_gaps "$@" ;;
	update-gap) cmd_update_gap "$@" ;;
	resolve-gap) cmd_resolve_gap "$@" ;;
	pulse-scan) cmd_pulse_scan "$@" ;;
	stats) cmd_stats "$@" ;;
	migrate) cmd_migrate ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
exit $?
