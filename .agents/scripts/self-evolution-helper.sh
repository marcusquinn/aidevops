#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Self-Evolution Helper -- Orchestrator
# =============================================================================
# Self-evolution loop for aidevops: detects capability gaps from entity
# interaction patterns, creates TODO tasks with evidence trails, tracks gap
# frequency, and manages resolution lifecycle.
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
# Sub-libraries:
#   - self-evolution-helper-core.sh  -- DB utilities, schema, shared helpers
#   - self-evolution-helper-scan.sh  -- Pattern scanning and heuristic detection
#   - self-evolution-helper-gaps.sh  -- Gap detection, evidence, TODO creation, CRUD
#   - self-evolution-helper-pulse.sh -- Pulse integration, stats, migration, help
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

# Defensive SCRIPT_DIR — needed before sourcing sub-libraries
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# --- Source sub-libraries ---

# shellcheck source=./self-evolution-helper-core.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-core.sh"

# shellcheck source=./self-evolution-helper-scan.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-scan.sh"

# shellcheck source=./self-evolution-helper-gaps.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-gaps.sh"

# shellcheck source=./self-evolution-helper-pulse.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/self-evolution-helper-pulse.sh"

# --- Main entry point ---

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
