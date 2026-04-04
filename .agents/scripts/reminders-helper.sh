#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# Reminders Helper — cross-platform CLI for agent use
#
# Backends:
#   macOS:  remindctl (EventKit, brew install steipete/tap/remindctl)
#   Linux:  todoman + vdirsyncer (CalDAV, pipx install todoman vdirsyncer)
#
# Usage: ./reminders-helper.sh [command] [args] [options]
# Commands:
#   setup                          - Check/install backend, verify access
#   lists                          - List all reminder lists
#   show [filter]                  - Show reminders (today|tomorrow|week|overdue|upcoming|all)
#   add <title> [options]          - Create a reminder
#   complete <id>                  - Mark a reminder complete
#   edit <id> [options]            - Edit a reminder
#   sync                           - Sync CalDAV (Linux only; macOS is automatic)
#   help                           - Show this help
#
# Author: AI DevOps Framework
# Version: 2.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

init_log_file

# =============================================================================
# Platform Detection
# =============================================================================

detect_platform() {
	local os
	os="$(uname -s)"
	case "$os" in
	Darwin) echo "macos" ;;
	Linux) echo "linux" ;;
	*)
		print_error "Unsupported platform: ${os}"
		return 1
		;;
	esac
	return 0
}

PLATFORM="$(detect_platform)" || exit 1

# =============================================================================
# macOS Backend (remindctl)
# =============================================================================

REMINDCTL_BIN="remindctl"
REMINDCTL_TAP="steipete/tap/remindctl"

macos_check_ready() {
	if ! command -v "$REMINDCTL_BIN" >/dev/null 2>&1; then
		print_error "remindctl not found. Install: brew install ${REMINDCTL_TAP}"
		return 1
	fi
	local status
	status="$("$REMINDCTL_BIN" status 2>&1)" || true
	if echo "$status" | grep -qi "denied\|not determined"; then
		print_error "Reminders access not granted."
		print_info "Run: remindctl authorize"
		print_info "Then: System Settings > Privacy & Security > Reminders > enable your terminal app"
		return 1
	fi
	return 0
}

macos_setup() {
	print_info "Checking remindctl (macOS backend)..."

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

	print_info "Available reminder lists:"
	"$REMINDCTL_BIN" list --no-color 2>&1 || true
	print_success "macOS setup complete."
	return 0
}

macos_lists() {
	local use_json="${1:-false}"
	if [[ "$use_json" == "true" ]]; then
		"$REMINDCTL_BIN" list --json --no-input 2>&1
	else
		"$REMINDCTL_BIN" list --no-input --no-color 2>&1
	fi
	return 0
}

macos_show() {
	local filter="$1"
	local list_name="$2"
	local use_json="$3"

	local args=("$filter" --no-input --no-color)
	[[ -n "$list_name" ]] && args+=(--list "$list_name")
	[[ "$use_json" == "true" ]] && args+=(--json)

	"$REMINDCTL_BIN" show "${args[@]}" 2>&1
	return 0
}

macos_add() {
	local title="$1" list_name="$2" due_date="$3" notes="$4" priority="$5" use_json="$6"
	local url="$7" flag="$8" tags="$9" location="${10:-}"

	# Prepend URL to notes (remindctl has no native URL field)
	if [[ -n "$url" ]]; then
		if [[ -n "$notes" ]]; then
			notes="${url}
${notes}"
		else
			notes="$url"
		fi
	fi

	local args=("$title" --no-input --no-color)
	[[ -n "$list_name" ]] && args+=(--list "$list_name")
	[[ -n "$due_date" ]] && args+=(--due "$due_date")
	[[ -n "$notes" ]] && args+=(--notes "$notes")
	[[ -n "$priority" ]] && args+=(--priority "$priority")
	[[ "$use_json" == "true" ]] && args+=(--json)

	"$REMINDCTL_BIN" add "${args[@]}" 2>&1
	local rc=$?

	# Post-creation: set fields remindctl doesn't support via osascript
	if [[ $rc -eq 0 ]]; then
		local target_list="${list_name:-Reminders}"
		# Set flagged status
		if [[ "$flag" == "true" ]]; then
			osascript -e "
				tell application \"Reminders\"
					set rl to list \"${target_list}\"
					set r to (last reminder of rl whose name is \"${title}\")
					set flagged of r to true
				end tell" 2>/dev/null || print_warning "Could not set flag (osascript)"
		fi
		# Tags: not available via AppleScript or remindctl — log limitation
		if [[ -n "$tags" ]]; then
			print_warning "Tags not supported on macOS CLI. Tags: ${tags}"
		fi
		# Location: not available via AppleScript or remindctl
		if [[ -n "$location" ]]; then
			print_warning "Location not supported on macOS CLI. Location: ${location}"
		fi
	fi

	return $rc
}

macos_complete() {
	local id="$1"
	"$REMINDCTL_BIN" complete "$id" --no-input --no-color 2>&1
	return $?
}

macos_edit() {
	local id="$1"
	shift
	"$REMINDCTL_BIN" edit "$id" --no-input --no-color "$@" 2>&1
	return $?
}

macos_sync() {
	print_info "macOS syncs automatically via EventKit. No manual sync needed."
	return 0
}

# =============================================================================
# Linux Backend (todoman + vdirsyncer)
# =============================================================================

TODOMAN_BIN="todo"
VDIRSYNCER_BIN="vdirsyncer"

linux_check_ready() {
	if ! command -v "$TODOMAN_BIN" >/dev/null 2>&1; then
		print_error "todoman not found. Install: pipx install todoman"
		return 1
	fi
	if ! command -v "$VDIRSYNCER_BIN" >/dev/null 2>&1; then
		print_error "vdirsyncer not found. Install: pipx install vdirsyncer"
		return 1
	fi
	if [[ ! -f "${HOME}/.config/todoman/config.py" ]]; then
		print_error "todoman not configured. See: reminders-helper.sh help"
		return 1
	fi
	if [[ ! -f "${HOME}/.config/vdirsyncer/config" ]]; then
		print_error "vdirsyncer not configured. See: reminders-helper.sh help"
		return 1
	fi
	return 0
}

linux_setup() {
	print_info "Checking todoman + vdirsyncer (Linux backend)..."

	# todoman
	if command -v "$TODOMAN_BIN" >/dev/null 2>&1; then
		local ver
		ver="$("$TODOMAN_BIN" --version 2>&1)"
		print_success "todoman installed: ${ver}"
	else
		print_warning "todoman not installed"
		if command -v pipx >/dev/null 2>&1; then
			read -r -p "Install todoman now? [y/N] " answer
			if [[ "$answer" =~ ^[Yy] ]]; then
				pipx install todoman
				print_success "todoman installed"
			else
				print_info "Install manually: pipx install todoman"
				return 1
			fi
		else
			print_info "Install with: pipx install todoman (or pip install --user todoman)"
			return 1
		fi
	fi

	# vdirsyncer
	if command -v "$VDIRSYNCER_BIN" >/dev/null 2>&1; then
		local vver
		vver="$("$VDIRSYNCER_BIN" --version 2>&1)"
		print_success "vdirsyncer installed: ${vver}"
	else
		print_warning "vdirsyncer not installed"
		print_info "Install with: pipx install vdirsyncer"
		return 1
	fi

	# Config check
	if [[ -f "${HOME}/.config/vdirsyncer/config" ]]; then
		print_success "vdirsyncer config found"
	else
		print_warning "vdirsyncer config missing: ~/.config/vdirsyncer/config"
		print_info "See 'reminders-helper.sh help' for configuration guide"
		return 1
	fi

	if [[ -f "${HOME}/.config/todoman/config.py" ]]; then
		print_success "todoman config found"
	else
		print_warning "todoman config missing: ~/.config/todoman/config.py"
		print_info "See 'reminders-helper.sh help' for configuration guide"
		return 1
	fi

	# Show lists
	print_info "Available reminder lists:"
	"$TODOMAN_BIN" list --porcelain 2>&1 || "$TODOMAN_BIN" list 2>&1 || true

	print_success "Linux setup complete."
	return 0
}

linux_sync() {
	print_info "Syncing CalDAV..."
	"$VDIRSYNCER_BIN" sync 2>&1
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		print_success "CalDAV sync complete"
	else
		print_warning "CalDAV sync had issues (exit ${rc}). Check vdirsyncer config."
	fi
	return $rc
}

linux_lists() {
	local use_json="${1:-false}"
	if [[ "$use_json" == "true" ]]; then
		"$TODOMAN_BIN" list --porcelain 2>&1
	else
		"$TODOMAN_BIN" list 2>&1
	fi
	return 0
}

linux_show() {
	local filter="$1"
	local list_name="$2"
	local use_json="$3"

	local args=()

	# Translate remindctl-style filters to todoman equivalents
	case "$filter" in
	today) args+=(--due 24) ;;
	tomorrow) args+=(--due 48) ;;
	week) args+=(--due 168) ;;
	overdue) args+=(--due 0) ;;
	completed) args+=(--status COMPLETED) ;;
	all) args+=(--status ANY) ;;
	upcoming | *) ;; # no filter = all incomplete
	esac

	[[ -n "$list_name" ]] && args+=("$list_name")
	[[ "$use_json" == "true" ]] && args+=(--porcelain)

	"$TODOMAN_BIN" list "${args[@]}" 2>&1
	return 0
}

# Map priority names to todoman values.
# VTODO spec: 1-4=high, 5=medium, 6-9=low, 0=none.
# todoman accepts the words directly since v4.4.
linux_map_priority() {
	local pri="$1"
	case "$pri" in
	high) echo "high" ;;
	medium) echo "medium" ;;
	low) echo "low" ;;
	none | "") echo "" ;;
	*) echo "$pri" ;;
	esac
	return 0
}

linux_add() {
	local title="$1" list_name="$2" due_date="$3" notes="$4" priority="$5" use_json="$6"
	local url="$7" flag="$8" tags="$9" location="${10:-}"

	# Prepend URL to notes (todoman has no native URL field)
	if [[ -n "$url" ]]; then
		if [[ -n "$notes" ]]; then
			notes="${url}
${notes}"
		else
			notes="$url"
		fi
	fi

	local args=("$title")
	[[ -n "$list_name" ]] && args+=(--list "$list_name")
	[[ -n "$due_date" ]] && args+=(--due "$due_date")
	[[ -n "$location" ]] && args+=(--location "$location")

	# Tags via --category (can be repeated)
	if [[ -n "$tags" ]]; then
		local IFS=','
		local tag
		for tag in $tags; do
			tag="$(echo "$tag" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
			[[ -n "$tag" ]] && args+=(--category "$tag")
		done
		unset IFS
	fi

	local mapped_pri=""
	if [[ -n "$priority" ]]; then
		mapped_pri="$(linux_map_priority "$priority")"
		[[ -n "$mapped_pri" ]] && args+=(--priority "$mapped_pri")
	fi

	# Flag: not natively supported by todoman, add to notes
	if [[ "$flag" == "true" ]]; then
		if [[ -n "$notes" ]]; then
			notes="[FLAGGED]
${notes}"
		else
			notes="[FLAGGED]"
		fi
	fi

	if [[ -n "$notes" ]]; then
		echo "$notes" | "$TODOMAN_BIN" new "${args[@]}" --read-description 2>&1
	else
		"$TODOMAN_BIN" new "${args[@]}" 2>&1
	fi
	return $?
}

linux_complete() {
	local id="$1"
	local subcmd="done"
	"$TODOMAN_BIN" "$subcmd" "$id" 2>&1
	return $?
}

linux_edit() {
	local id="$1"
	shift
	# Translate common flags: --title is not supported by todoman edit,
	# but --due, --priority, --location are.
	"$TODOMAN_BIN" edit "$id" "$@" 2>&1
	return $?
}

# =============================================================================
# Platform-Dispatching Commands
# =============================================================================

cmd_setup() {
	print_info "Platform detected: ${PLATFORM}"
	case "$PLATFORM" in
	macos) macos_setup ;;
	linux) linux_setup ;;
	esac
}

cmd_sync() {
	case "$PLATFORM" in
	macos) macos_sync ;;
	linux)
		linux_check_ready || return 1
		linux_sync
		;;
	esac
}

cmd_lists() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local use_json="${JSON_OUTPUT:-false}"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json | -j)
			use_json="true"
			shift
			;;
		*) shift ;;
		esac
	done

	case "$PLATFORM" in
	macos) macos_lists "$use_json" ;;
	linux) linux_lists "$use_json" ;;
	esac
}

cmd_show() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

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
		*) shift ;;
		esac
	done

	case "$PLATFORM" in
	macos) macos_show "$filter" "$list_name" "$use_json" ;;
	linux) linux_show "$filter" "$list_name" "$use_json" ;;
	esac
}

cmd_add() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local title="" list_name="" due_date="" notes="" priority=""
	local url="" flag="" tags="" location=""
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
		--url | -u)
			url="$2"
			shift 2
			;;
		--flag | -f)
			flag="true"
			shift
			;;
		--tags)
			tags="$2"
			shift 2
			;;
		--location)
			location="$2"
			shift 2
			;;
		--json | -j)
			use_json="true"
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$title" ]]; then
		print_error "Title is required. Usage: reminders-helper.sh add \"Buy milk\" --list Shopping"
		return 1
	fi

	local rc=0
	case "$PLATFORM" in
	macos)
		macos_add "$title" "$list_name" "$due_date" "$notes" "$priority" "$use_json" \
			"$url" "$flag" "$tags" "$location"
		rc=$?
		;;
	linux)
		linux_add "$title" "$list_name" "$due_date" "$notes" "$priority" "$use_json" \
			"$url" "$flag" "$tags" "$location"
		rc=$?
		;;
	esac

	if [[ $rc -eq 0 ]]; then
		print_success "Reminder created: ${title}"
	else
		print_error "Failed to create reminder: ${title}"
	fi
	return $rc
}

cmd_complete() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local id="${1:-}"
	if [[ -z "$id" ]]; then
		print_error "Reminder ID required. Use 'show' to find IDs."
		return 1
	fi
	shift

	local rc=0
	case "$PLATFORM" in
	macos)
		macos_complete "$id"
		rc=$?
		;;
	linux)
		linux_complete "$id"
		rc=$?
		;;
	esac

	if [[ $rc -eq 0 ]]; then
		print_success "Reminder completed: ${id}"
	else
		print_error "Failed to complete reminder: ${id}"
	fi
	return $rc
}

cmd_edit() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local id=""
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		id="$1"
		shift
	fi

	if [[ -z "$id" ]]; then
		print_error "Reminder ID required. Use 'show' to find IDs."
		return 1
	fi

	case "$PLATFORM" in
	macos) macos_edit "$id" "$@" ;;
	linux) linux_edit "$id" "$@" ;;
	esac
}

cmd_help() {
	cat <<'HELP'
Reminders Helper — cross-platform CLI for agent use

Backends: remindctl (macOS/EventKit) | todoman + vdirsyncer (Linux/CalDAV)

Usage: reminders-helper.sh <command> [args] [options]

Commands:
  setup                    Check/install backend, verify access
  lists                    List all reminder lists
  show [filter] [options]  Show reminders
  add <title> [options]    Create a reminder
  complete <id>            Mark a reminder complete
  edit <id> [options]      Edit a reminder
  sync                     Sync CalDAV (Linux; macOS syncs automatically)
  help                     Show this help

Show filters: today, tomorrow, week, overdue, upcoming, completed, all

Add options:
  --list, -l <name>        Target list (e.g., "Shopping", "Work")
  --due, -d <date>         Due date (e.g., "tomorrow", "2026-01-15")
  --notes, -n <text>       Notes/description
  --priority, -p <level>   none, low, medium, high
  --url, -u <url>          URL (prepended to notes)
  --flag, -f               Flag the reminder (macOS only)
  --tags <a,b,c>           Comma-separated tags (Linux only)
  --location <text>        Location text (Linux only)
  --json, -j               JSON output (for agent consumption)

Environment:
  JSON_OUTPUT=true         Force JSON output on all commands

Examples:
  reminders-helper.sh setup
  reminders-helper.sh lists
  reminders-helper.sh show today
  reminders-helper.sh show overdue --list Work
  reminders-helper.sh add "Buy milk" --list Shopping --due tomorrow
  reminders-helper.sh add "Review PR" --list Work --due "2026-04-05" --priority high
  reminders-helper.sh add "Call dentist" --notes "Ask about cleaning"
  reminders-helper.sh complete 1
  reminders-helper.sh edit 2 --priority high --due tomorrow
  reminders-helper.sh sync

Setup — macOS (one-time):
  1. brew install steipete/tap/remindctl
  2. remindctl authorize
  3. System Settings > Privacy & Security > Reminders > enable terminal app

Setup — Linux (one-time):
  1. pipx install todoman vdirsyncer
  2. Configure vdirsyncer: ~/.config/vdirsyncer/config
     [general]
     status_path = "~/.local/share/vdirsyncer/status/"
     [pair reminders]
     a = "reminders_local"
     b = "reminders_remote"
     collections = ["from a", "from b"]
     [storage reminders_local]
     type = "filesystem"
     path = "~/.local/share/calendars/"
     fileext = ".ics"
     [storage reminders_remote]
     type = "caldav"
     url = "https://caldav.icloud.com/"
     username = "your@icloud.com"
     password.fetch = ["command", "gopass", "show", "icloud/app-password"]
  3. Configure todoman: ~/.config/todoman/config.py
     path = "~/.local/share/calendars/*"
     date_format = "%Y-%m-%d"
     time_format = "%H:%M"
     default_list = "Reminders"
  4. vdirsyncer discover && vdirsyncer sync
  5. Verify: todo list
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
	setup) cmd_setup "$@" ;;
	lists | list) cmd_lists "$@" ;;
	show) cmd_show "$@" ;;
	add) cmd_add "$@" ;;
	complete | done) cmd_complete "$@" ;;
	edit) cmd_edit "$@" ;;
	sync) cmd_sync "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
