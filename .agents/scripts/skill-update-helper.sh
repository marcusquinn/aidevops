#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Skill Update Helper
# =============================================================================
# Check imported skills for upstream updates and optionally auto-update.
# Designed to be run periodically (e.g., weekly cron) or on-demand.
#
# Usage:
#   skill-update-helper.sh check           # Check for updates (default)
#   skill-update-helper.sh update [name]   # Update specific or all skills
#   skill-update-helper.sh status          # Show skill status summary
#   skill-update-helper.sh pr [name]       # Create PRs for updated skills
#
# Options:
#   --auto-update        Automatically update skills with changes
#   --quiet              Suppress non-essential output
#   --non-interactive    Headless mode: log to auto-update.log, no prompts, graceful errors
#   --json               Output in JSON format
#   --dry-run            Show what would be done without making changes
#
# Sub-libraries:
#   skill-update-core-lib.sh   — utilities, check/update/status commands
#   skill-update-pr-lib.sh     — PR generation helpers, single-skill PR pipeline
#   skill-update-batch-lib.sh  — batch PR pipeline, cmd_pr dispatcher
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# t2976: canonical audit logger for worktree-removal events
if [[ -f "${SCRIPT_DIR}/audit-worktree-removal-helper.sh" ]]; then
	# shellcheck source=audit-worktree-removal-helper.sh
	source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
fi
# Caller ID constant (avoids repeated literals).
_WTAR_SU_CALLER="skill-update-helper.sh"

set -euo pipefail

# Configuration
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
SKILL_SOURCES="${AGENTS_DIR}/configs/skill-sources.json"
ADD_SKILL_HELPER="${AGENTS_DIR}/scripts/add-skill-helper.sh"

# Options
AUTO_UPDATE=false
QUIET=false
NON_INTERACTIVE=false
JSON_OUTPUT=false
DRY_RUN=false
# Batch mode for PR creation: one-per-skill (default) or single-pr
BATCH_MODE="${SKILL_UPDATE_BATCH_MODE:-one-per-skill}"

# Log file for non-interactive / headless mode (shared with auto-update-helper.sh)
readonly SKILL_LOG_FILE="${HOME}/.aidevops/logs/auto-update.log"

# Worktree helper
WORKTREE_HELPER="${SCRIPT_DIR}/worktree-helper.sh"

# =============================================================================
# Logging (defined here so sub-libs can use them immediately on source)
# =============================================================================

# Write a timestamped entry to the shared auto-update log file.
# Used in non-interactive mode so headless callers (cron, auto-update-helper.sh)
# can inspect results without parsing stdout.
_log_to_file() {
	local level="$1"
	shift
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	mkdir -p "$(dirname "$SKILL_LOG_FILE")" 2>/dev/null || true
	printf '[%s] [skill-update] [%s] %s\n' "$timestamp" "$level" "$*" >>"$SKILL_LOG_FILE"
	return 0
}

log_info() {
	if [[ "$NON_INTERACTIVE" == true ]]; then
		_log_to_file "INFO" "$1"
	elif [[ "$QUIET" != true ]]; then
		echo -e "${BLUE}[skill-update]${NC} $1"
	fi
	return 0
}

log_success() {
	if [[ "$NON_INTERACTIVE" == true ]]; then
		_log_to_file "INFO" "$1"
	elif [[ "$QUIET" != true ]]; then
		echo -e "${GREEN}[OK]${NC} $1"
	fi
	return 0
}

log_warning() {
	if [[ "$NON_INTERACTIVE" == true ]]; then
		_log_to_file "WARN" "$1"
	else
		echo -e "${YELLOW}[WARN]${NC} $1"
	fi
	return 0
}

log_error() {
	if [[ "$NON_INTERACTIVE" == true ]]; then
		_log_to_file "ERROR" "$1"
	else
		echo -e "${RED}[ERROR]${NC} $1"
	fi
	return 0
}

# =============================================================================
# Sub-library sources
# =============================================================================

# shellcheck source=./skill-update-core-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/skill-update-core-lib.sh"

# shellcheck source=./skill-update-pr-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/skill-update-pr-lib.sh"

# shellcheck source=./skill-update-batch-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/skill-update-batch-lib.sh"

# =============================================================================
# Main
# =============================================================================

main() {
	local command="check"
	local skill_name=""

	# Parse arguments using named variable for clarity (S7679)
	local arg
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		check | update | status | pr)
			command="$arg"
			shift
			;;
		--auto-update)
			AUTO_UPDATE=true
			shift
			;;
		--quiet | -q)
			QUIET=true
			shift
			;;
		--non-interactive)
			NON_INTERACTIVE=true
			QUIET=true
			shift
			;;
		--json)
			JSON_OUTPUT=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--batch-mode)
			if [[ $# -lt 2 ]]; then
				log_error "--batch-mode requires a value: one-per-skill or single-pr"
				exit 1
			fi
			BATCH_MODE="$2"
			if [[ "$BATCH_MODE" != "one-per-skill" && "$BATCH_MODE" != "single-pr" ]]; then
				log_error "Invalid --batch-mode value: $BATCH_MODE (must be one-per-skill or single-pr)"
				exit 1
			fi
			shift 2
			;;
		--help | -h)
			show_help
			exit 0
			;;
		-*)
			log_error "Unknown option: $arg"
			show_help
			exit 1
			;;
		*)
			# Assume it's a skill name for update/pr command
			skill_name="$arg"
			shift
			;;
		esac
	done

	# In non-interactive mode, install an ERR trap so unexpected errors are
	# logged to auto-update.log and the process exits cleanly (exit 0) rather
	# than crashing with no log entry.  The trap must be set after arg parsing
	# so that NON_INTERACTIVE is already true when it fires.
	if [[ "$NON_INTERACTIVE" == true ]]; then
		trap '_non_interactive_error_handler $LINENO' ERR
		log_info "Starting skill-update-helper.sh in non-interactive mode (command=$command)"
	fi

	case "$command" in
	check)
		cmd_check
		;;
	update)
		cmd_update "$skill_name"
		;;
	status)
		cmd_status
		;;
	pr)
		cmd_pr "$skill_name"
		;;
	*)
		log_error "Unknown command: $command"
		show_help
		exit 1
		;;
	esac
	return 0
}

# Error handler for non-interactive mode — logs the failure and exits cleanly.
# Defined at file scope so it is available when the trap fires.
_non_interactive_error_handler() {
	local exit_code="$?"
	local line_no="${1:-unknown}"
	_log_to_file "ERROR" "Unexpected error at line ${line_no} (exit ${exit_code}) — skill-update-helper.sh aborted"
	exit 0
	return 0
}

main "$@"
