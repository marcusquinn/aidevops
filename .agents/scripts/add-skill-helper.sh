#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Add External Skill Helper — Orchestrator
# =============================================================================
# Import external skills from GitHub repos, ClawdHub, or raw URLs, convert to
# aidevops format, handle conflicts, and track upstream sources for update detection.
#
# This file is the thin orchestrator. Implementation lives in sub-libraries:
#   - add-skill-helper-core.sh     (parsing, format detection, registration)
#   - add-skill-helper-import.sh   (security scanning, conflict resolution, fetch)
#   - add-skill-helper-commands.sh (cmd_add, cmd_add_url, cmd_add_clawdhub, etc.)
#
# Usage:
#   add-skill-helper.sh add <url|owner/repo|clawdhub:slug> [--name <name>] [--force] [--skip-security]
#   add-skill-helper.sh list
#   add-skill-helper.sh check-updates
#   add-skill-helper.sh remove <name>
#   add-skill-helper.sh help
#
# Examples:
#   add-skill-helper.sh add dmmulroy/cloudflare-skill
#   add-skill-helper.sh add https://github.com/anthropics/skills/pdf
#   add-skill-helper.sh add vercel-labs/agent-skills --name vercel
#   add-skill-helper.sh add clawdhub:caldav-calendar
#   add-skill-helper.sh add https://clawdhub.com/Asleep123/caldav-calendar
#   add-skill-helper.sh add https://convos.org/skill.md --name convos
#   add-skill-helper.sh check-updates
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
SKILL_SOURCES="${AGENTS_DIR}/configs/skill-sources.json"
TEMP_DIR="${TMPDIR:-/tmp}/aidevops-skill-import"
SCAN_RESULTS_FILE=".agents/configs/configs/SKILL-SCAN-RESULTS.md"

# Logging: uses shared log_* from shared-constants.sh with add-skill prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="add-skill"

# --- Source sub-libraries ---

# shellcheck source=./add-skill-helper-core.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/add-skill-helper-core.sh"

# shellcheck source=./add-skill-helper-import.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/add-skill-helper-import.sh"

# shellcheck source=./add-skill-helper-commands.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/add-skill-helper-commands.sh"

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	add)
		if [[ $# -lt 1 ]]; then
			log_error "URL or owner/repo required"
			echo "Usage: add-skill-helper.sh add <url|owner/repo> [--name <name>] [--force] [--skip-security]"
			return 1
		fi
		cmd_add "$@"
		;;
	list)
		cmd_list
		;;
	check-updates | updates)
		cmd_check_updates
		;;
	remove | rm)
		cmd_remove "$@"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
