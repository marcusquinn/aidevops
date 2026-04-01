#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# Apple Reminders Helper — CLI wrapper around remindctl for agent use
#
# Usage: ./reminders-helper.sh [command] [args] [options]
# Commands:
#   setup                          - Check/install remindctl, verify authorization
#   lists                          - List all reminder lists (with account info)
#   show [filter]                  - Show reminders (today|tomorrow|week|overdue|upcoming|all)
#   add <title> [options]          - Create a reminder
#   complete <id>                  - Mark a reminder complete
#   edit <id> [options]            - Edit a reminder
#   help                           - Show this help
#
# Requires: remindctl (brew install steipete/tap/remindctl)
# Authorization: System Settings > Privacy & Security > Reminders
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# =============================================================================
# Dependencies
# =============================================================================

REMINDCTL_BIN="remindctl"
REMINDCTL_TAP="steipete/tap/remindctl"

check_remindctl() {
	if ! command -v "$REMINDCTL_BIN" >/dev/null 2>&1; then
		print_error "remindctl not found. Install: brew install ${REMINDCTL_TAP}"
		return 1
	fi
	return 0
}

check_authorization() {
	local status
	status="$("$REMINDCTL_BIN" status 2>&1)" || true
	if echo "$status" | grep -qi "authorized"; then
		return 0
	fi
	if echo "$status" | grep -qi "denied\|not determined"; then
		print_error "Reminders access not granted."
		print_info "Run: remindctl authorize"
		print_info "Then: System Settings > Privacy & Security > Reminders > enable your terminal app"
		return 1
	fi
	# Unknown status — try anyway
	return 0
}

require_ready() {
	check_remindctl || return 1
	check_authorization || return 1
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_setup() {
	print_info "Checking Apple Reminders CLI setup..."

	# Step 1: remindctl installed?
	if command -v "$REMINDCTL_BIN" >/dev/null 2>&1; then
		local ver
		ver="$("$REMINDCTL_BIN" --help 2>&1 | head -1)"
		print_success "remindctl installed: ${ver}"
	else
		print_warning "remindctl not installed"
		print_info "Install with: brew install ${REMINDCTL_TAP}"
		if command -v brew >/dev/null 2>&1; then
			read -r -p "Install now? [y/N] " answer
			if [[ "$answer" =~ ^[Yy] ]]; then
				brew install "$REMINDCTL_TAP"
				print_success "remindctl installed"
			else
				print_info "Skipped. Install manually when ready."
				return 1
			fi
		else
			print_error "Homebrew not found. Install Homebrew first: https://brew.sh"
			return 1
		fi
	fi

	# Step 2: Authorization
	local status
	status="$("$REMINDCTL_BIN" status 2>&1)" || true
	if echo "$status" | grep -qi "authorized"; then
		print_success "Reminders access: authorized"
	else
		print_warning "Reminders access: not yet authorized"
		print_info "Step 1: Run 'remindctl authorize' in a terminal"
		print_info "Step 2: System Settings > Privacy & Security > Reminders"
		print_info "Step 3: Enable your terminal app (Terminal, iTerm, etc.)"
		return 1
	fi

	# Step 3: Show available lists
	print_info "Available reminder lists:"
	"$REMINDCTL_BIN" list --no-color 2>&1 || true

	print_success "Setup complete. Ready to use."
	return 0
}

cmd_lists() {
	require_ready || return 1

	local use_json="${JSON_OUTPUT:-false}"

	if [[ "$use_json" == "true" ]]; then
		"$REMINDCTL_BIN" list --json --no-input 2>&1
	else
		"$REMINDCTL_BIN" list --no-input --no-color 2>&1
	fi
	return 0
}

cmd_show() {
	require_ready || return 1

	local filter="${1:-today}"
	shift || true

	local list_name=""
	local use_json="${JSON_OUTPUT:-false}"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--list | -l)
			list_name="$2"
			shift 2
			;;
		--json | -j)
			use_json="true"
			shift
			;;
		*)
			shift
			;;
		esac
	done

	local args=("$filter" --no-input --no-color)
	if [[ -n "$list_name" ]]; then
		args+=(--list "$list_name")
	fi
	if [[ "$use_json" == "true" ]]; then
		args+=(--json)
	fi

	"$REMINDCTL_BIN" show "${args[@]}" 2>&1
	return 0
}

cmd_add() {
	require_ready || return 1

	local title=""
	local list_name=""
	local due_date=""
	local notes=""
	local priority=""
	local use_json="${JSON_OUTPUT:-false}"

	# First positional arg is title if not a flag
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		title="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title | -t)
			title="$2"
			shift 2
			;;
		--list | -l)
			list_name="$2"
			shift 2
			;;
		--due | -d)
			due_date="$2"
			shift 2
			;;
		--notes | -n)
			notes="$2"
			shift 2
			;;
		--priority | -p)
			priority="$2"
			shift 2
			;;
		--json | -j)
			use_json="true"
			shift
			;;
		*)
			shift
			;;
		esac
	done

	if [[ -z "$title" ]]; then
		print_error "Title is required. Usage: reminders-helper.sh add \"Buy milk\" --list Shopping"
		return 1
	fi

	local args=("$title" --no-input --no-color)
	if [[ -n "$list_name" ]]; then
		args+=(--list "$list_name")
	fi
	if [[ -n "$due_date" ]]; then
		args+=(--due "$due_date")
	fi
	if [[ -n "$notes" ]]; then
		args+=(--notes "$notes")
	fi
	if [[ -n "$priority" ]]; then
		args+=(--priority "$priority")
	fi
	if [[ "$use_json" == "true" ]]; then
		args+=(--json)
	fi

	"$REMINDCTL_BIN" add "${args[@]}" 2>&1
	local rc=$?

	if [[ $rc -eq 0 ]]; then
		print_success "Reminder created: ${title}"
	else
		print_error "Failed to create reminder: ${title}"
	fi
	return $rc
}

cmd_complete() {
	require_ready || return 1

	local id="$1"
	if [[ -z "$id" ]]; then
		print_error "Reminder ID required. Use 'show' to find IDs."
		return 1
	fi
	shift

	"$REMINDCTL_BIN" complete "$id" --no-input --no-color 2>&1
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		print_success "Reminder completed: ${id}"
	else
		print_error "Failed to complete reminder: ${id}"
	fi
	return $rc
}

cmd_edit() {
	require_ready || return 1

	local id=""
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		id="$1"
		shift
	fi

	if [[ -z "$id" ]]; then
		print_error "Reminder ID required. Use 'show' to find IDs."
		return 1
	fi

	# Pass remaining args through to remindctl edit
	"$REMINDCTL_BIN" edit "$id" --no-input --no-color "$@" 2>&1
	return $?
}

cmd_help() {
	cat <<'HELP'
Apple Reminders Helper — CLI wrapper for agent use

Usage: reminders-helper.sh <command> [args] [options]

Commands:
  setup                    Check/install remindctl, verify authorization
  lists                    List all reminder lists
  show [filter] [options]  Show reminders
  add <title> [options]    Create a reminder
  complete <id>            Mark a reminder complete
  edit <id> [options]      Edit a reminder
  help                     Show this help

Show filters: today, tomorrow, week, overdue, upcoming, completed, all, <date>

Add options:
  --list, -l <name>        Target list (e.g., "Shopping", "Work")
  --due, -d <date>         Due date (e.g., "tomorrow", "2026-01-15", "in 3 days")
  --notes, -n <text>       Notes/description
  --priority, -p <level>   none, low, medium, high
  --json, -j               JSON output (for agent consumption)

Environment:
  JSON_OUTPUT=true         Force JSON output on all commands

Examples:
  reminders-helper.sh setup
  reminders-helper.sh lists
  reminders-helper.sh show today
  reminders-helper.sh show overdue --list Work
  reminders-helper.sh add "Buy milk" --list Shopping --due tomorrow
  reminders-helper.sh add "Review PR" --list Work --due "in 2 hours" --priority high
  reminders-helper.sh add "Call dentist" --due "next Monday" --notes "Ask about cleaning"
  reminders-helper.sh complete 1
  reminders-helper.sh edit 2 --priority high --due tomorrow

Setup (one-time):
  1. brew install steipete/tap/remindctl
  2. remindctl authorize
  3. System Settings > Privacy & Security > Reminders > enable terminal app
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	setup)
		cmd_setup "$@"
		;;
	lists | list)
		cmd_lists "$@"
		;;
	show)
		cmd_show "$@"
		;;
	add)
		cmd_add "$@"
		;;
	complete | done)
		cmd_complete "$@"
		;;
	edit)
		cmd_edit "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
