#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# Calendar Helper — cross-platform CLI for agent use
#
# Backends:
#   macOS:  icalBuddy (read) + osascript (write) via Calendar.app / EventKit
#   Linux:  khal + vdirsyncer (CalDAV)
#
# Usage: ./calendar-helper.sh [command] [args] [options]
# Commands:
#   setup                - Check/install backend, verify access
#   calendars            - List all calendars
#   today                - Show today's events
#   show [filter]        - Show events (today|tomorrow|week|DATE|DATE..DATE)
#   add <title> [opts]   - Create an event
#   search <query>       - Search events
#   sync                 - Sync CalDAV (Linux; macOS syncs automatically)
#   help                 - Show this help
#
# Author: AI DevOps Framework
# Version: 1.0.0
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
# macOS Backend (icalBuddy + osascript)
# =============================================================================

macos_check_ready() {
	# Calendar.app is always available on macOS; osascript handles access
	return 0
}

macos_setup() {
	print_info "Checking Calendar access (macOS)..."
	local count
	count="$(osascript -e 'tell application "Calendar" to count of calendars' 2>&1)" || true
	if [[ "$count" =~ ^[0-9]+$ ]]; then
		print_success "Calendar access: authorized (${count} calendars)"
		print_info "Available calendars:"
		osascript -e 'tell application "Calendar" to get name of every calendar' 2>&1 || true
	else
		print_warning "Calendar access may need authorization."
		print_info "System Settings > Privacy & Security > Calendars > enable your terminal app"
		return 1
	fi
	print_success "macOS calendar setup complete."
	return 0
}

macos_calendars() {
	osascript -e 'tell application "Calendar" to get name of every calendar' 2>&1
	return 0
}

macos_show() {
	local filter="$1"
	local calendar="$2"

	local cal_filter=""
	if [[ -n "$calendar" ]]; then
		cal_filter="of calendar \"${calendar}\""
	fi

	# Calculate date range based on filter
	local script=""
	case "$filter" in
	today)
		script="
set startDate to current date
set time of startDate to 0
set endDate to startDate + 1 * days"
		;;
	tomorrow)
		script="
set startDate to (current date) + 1 * days
set time of startDate to 0
set endDate to startDate + 1 * days"
		;;
	week)
		script="
set startDate to current date
set time of startDate to 0
set endDate to startDate + 7 * days"
		;;
	*)
		# For specific dates, fall back to a wide range
		script="
set startDate to current date
set time of startDate to 0
set endDate to startDate + 30 * days"
		;;
	esac

	osascript -e "
tell application \"Calendar\"
	${script}
	set output to {}
	repeat with cal in calendars
		if \"${calendar}\" is \"\" or name of cal is \"${calendar}\" then
			repeat with evt in (events of cal)
				try
					if start date of evt >= startDate and start date of evt < endDate then
						set evtLine to (start date of evt as text) & \" | \" & summary of evt
						if location of evt is not missing value and location of evt is not \"\" then
							set evtLine to evtLine & \" @ \" & location of evt
						end if
						set end of output to evtLine
					end if
				end try
			end repeat
		end if
	end repeat
	if (count of output) = 0 then return \"No events found.\"
	return output as text
end tell" 2>&1
	return 0
}

macos_add() {
	local title="$1" calendar="$2" start_dt="$3" end_dt="$4"
	local location="$5" notes="$6" url="$7" allday="$8"

	local cal_clause=""
	if [[ -n "$calendar" ]]; then
		cal_clause="of calendar \"${calendar}\""
	fi

	local props="set summary of newEvent to \"${title}\""
	[[ -n "$location" ]] && props="${props}
set location of newEvent to \"${location}\""
	[[ -n "$notes" ]] && props="${props}
set description of newEvent to \"${notes}\""
	[[ -n "$url" ]] && props="${props}
set url of newEvent to \"${url}\""

	local date_setup=""
	if [[ "$allday" == "true" ]]; then
		date_setup="set allday event of newEvent to true
set start date of newEvent to date \"${start_dt}\""
	else
		date_setup="set start date of newEvent to date \"${start_dt}\""
		if [[ -n "$end_dt" ]]; then
			date_setup="${date_setup}
set end date of newEvent to date \"${end_dt}\""
		fi
	fi

	osascript -e "
tell application \"Calendar\"
	set newEvent to make new event at end of events ${cal_clause} with properties {summary:\"${title}\"}
	${date_setup}
	${props}
end tell" 2>&1

	return $?
}

macos_search() {
	local query="$1"
	local calendar="$2"

	local cal_filter=""
	if [[ -n "$calendar" ]]; then
		cal_filter="of calendar \"${calendar}\""
	fi

	osascript -e "
tell application \"Calendar\"
	set startDate to current date
	set endDate to startDate + 90 * days
	set output to {}
	repeat with cal in calendars
		if \"${calendar}\" is \"\" or name of cal is \"${calendar}\" then
			repeat with evt in (events of cal)
				try
					if start date of evt >= startDate and start date of evt < endDate then
						if summary of evt contains \"${query}\" then
							set evtLine to (start date of evt as text) & \" | \" & summary of evt
							set end of output to evtLine
						end if
					end if
				end try
			end repeat
		end if
	end repeat
	if (count of output) = 0 then return \"No matching events found.\"
	return output as text
end tell" 2>&1
	return 0
}

macos_sync() {
	print_info "macOS syncs calendars automatically via EventKit."
	return 0
}

# =============================================================================
# Linux Backend (khal + vdirsyncer)
# =============================================================================

linux_check_ready() {
	if ! command -v khal >/dev/null 2>&1; then
		print_error "khal not found. Install: brew install khal (or pipx install khal)"
		return 1
	fi
	if ! command -v vdirsyncer >/dev/null 2>&1; then
		print_error "vdirsyncer not found. Install: pipx install vdirsyncer"
		return 1
	fi
	return 0
}

linux_setup() {
	print_info "Checking Calendar CLI setup (Linux)..."

	if command -v khal >/dev/null 2>&1; then
		print_success "khal installed: $(khal --version 2>&1)"
	else
		print_warning "khal not installed. Install: brew install khal (or pipx install khal)"
		return 1
	fi

	if command -v vdirsyncer >/dev/null 2>&1; then
		print_success "vdirsyncer installed: $(vdirsyncer --version 2>&1)"
	else
		print_warning "vdirsyncer not installed. Install: pipx install vdirsyncer"
		return 1
	fi

	if [[ -f "${HOME}/.config/khal/config" ]]; then
		print_success "khal config found"
	else
		print_warning "khal not configured: ~/.config/khal/config"
		print_info "Run: khal configure"
		return 1
	fi

	print_info "Available calendars:"
	khal printcalendars 2>&1 || true
	print_success "Linux calendar setup complete."
	return 0
}

linux_calendars() {
	khal printcalendars 2>&1
	return 0
}

linux_show() {
	local filter="$1"
	local calendar="$2"

	local args=()
	[[ -n "$calendar" ]] && args+=(-a "$calendar")

	case "$filter" in
	today) khal list "${args[@]}" today today 2>&1 ;;
	tomorrow) khal list "${args[@]}" tomorrow tomorrow 2>&1 ;;
	week) khal list "${args[@]}" today 7d 2>&1 ;;
	*)
		if [[ "$filter" == *..* ]]; then
			local from="${filter%..*}"
			local to="${filter#*..}"
			khal list "${args[@]}" "$from" "$to" 2>&1
		else
			khal list "${args[@]}" "$filter" "$filter" 2>&1
		fi
		;;
	esac
	return 0
}

linux_add() {
	local title="$1" calendar="$2" start_dt="$3" end_dt="$4"
	local location="$5" notes="$6" url="$7" allday="$8"

	local args=()
	[[ -n "$calendar" ]] && args+=(-a "$calendar")
	[[ -n "$location" ]] && args+=(-l "$location")
	[[ -n "$url" ]] && args+=(--url "$url")

	if [[ "$allday" == "true" ]]; then
		args+=("$start_dt" "$title")
	else
		args+=("$start_dt")
		[[ -n "$end_dt" ]] && args+=("$end_dt")
		args+=("$title")
	fi

	if [[ -n "$notes" ]]; then
		args+=(:: "$notes")
	fi

	khal new "${args[@]}" 2>&1
	return $?
}

linux_search() {
	local query="$1"
	local calendar="$2"

	local args=()
	[[ -n "$calendar" ]] && args+=(-a "$calendar")

	khal search "${args[@]}" "$query" 2>&1
	return 0
}

linux_sync() {
	print_info "Syncing CalDAV..."
	vdirsyncer sync 2>&1
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		print_success "CalDAV sync complete"
	else
		print_warning "CalDAV sync had issues (exit ${rc})"
	fi
	return $rc
}

# =============================================================================
# Platform-Dispatching Commands
# =============================================================================

cmd_setup() {
	print_info "Platform: ${PLATFORM}"
	case "$PLATFORM" in
	macos) macos_setup ;;
	linux) linux_setup ;;
	esac
}

cmd_calendars() {
	case "$PLATFORM" in
	macos)
		macos_check_ready || return 1
		macos_calendars
		;;
	linux)
		linux_check_ready || return 1
		linux_calendars
		;;
	esac
}

cmd_show() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local filter="${1:-today}"
	shift || true

	local calendar=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--calendar | -a)
			calendar="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	case "$PLATFORM" in
	macos) macos_show "$filter" "$calendar" ;;
	linux) linux_show "$filter" "$calendar" ;;
	esac
}

cmd_add() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local title="" calendar="" start_dt="" end_dt=""
	local location="" notes="" url="" allday=""

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
		--calendar | -a)
			calendar="$2"
			shift 2
			;;
		--start | -s)
			start_dt="$2"
			shift 2
			;;
		--end | -e)
			end_dt="$2"
			shift 2
			;;
		--location | -l)
			location="$2"
			shift 2
			;;
		--notes | -n)
			notes="$2"
			shift 2
			;;
		--url | -u)
			url="$2"
			shift 2
			;;
		--allday)
			allday="true"
			shift
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$title" ]]; then
		print_error "Title required. Usage: calendar-helper.sh add \"Meeting\" --start \"2026-04-05 14:00\" --end \"2026-04-05 15:00\""
		return 1
	fi
	if [[ -z "$start_dt" ]]; then
		print_error "Start date/time required (--start)"
		return 1
	fi

	local rc=0
	case "$PLATFORM" in
	macos)
		macos_add "$title" "$calendar" "$start_dt" "$end_dt" \
			"$location" "$notes" "$url" "$allday"
		rc=$?
		;;
	linux)
		linux_add "$title" "$calendar" "$start_dt" "$end_dt" \
			"$location" "$notes" "$url" "$allday"
		rc=$?
		;;
	esac

	if [[ $rc -eq 0 ]]; then
		print_success "Event created: ${title}"
	else
		print_error "Failed to create event: ${title}"
	fi
	return $rc
}

cmd_search() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local query="${1:-}"
	if [[ -z "$query" ]]; then
		print_error "Search query required."
		return 1
	fi
	shift || true

	local calendar=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--calendar | -a)
			calendar="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	case "$PLATFORM" in
	macos) macos_search "$query" "$calendar" ;;
	linux) linux_search "$query" "$calendar" ;;
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

cmd_help() {
	cat <<'HELP'
Calendar Helper — cross-platform CLI for agent use

Backends: icalBuddy + osascript (macOS) | khal + vdirsyncer (Linux)

Usage: calendar-helper.sh <command> [args] [options]

Commands:
  setup                    Check/install backend, verify access
  calendars                List all calendars
  show [filter] [options]  Show events
  add <title> [options]    Create an event
  search <query> [options] Search events
  sync                     Sync CalDAV (Linux; macOS syncs automatically)
  help                     Show this help

Show filters: today, tomorrow, week, DATE, DATE..DATE

Add options:
  --calendar, -a <name>    Target calendar
  --start, -s <datetime>   Start date/time (required)
  --end, -e <datetime>     End date/time
  --location, -l <text>    Location
  --notes, -n <text>       Description/notes
  --url, -u <url>          Event URL
  --allday                 All-day event (no time needed)

Examples:
  calendar-helper.sh setup
  calendar-helper.sh calendars
  calendar-helper.sh show today
  calendar-helper.sh show week --calendar Work
  calendar-helper.sh show 2026-04-10..2026-04-15
  calendar-helper.sh add "Team standup" --start "2026-04-05 09:00" --end "2026-04-05 09:30" --calendar Work
  calendar-helper.sh add "Holiday" --start "2026-04-10" --allday --calendar Personal
  calendar-helper.sh add "Dinner" --start "2026-04-05 19:00" --location "The Restaurant" --notes "Reservation for 4"
  calendar-helper.sh search "standup" --calendar Work
  calendar-helper.sh sync

Setup — macOS: No install needed (uses Calendar.app). May need Privacy authorization.
Setup — Linux: brew install khal && pipx install vdirsyncer, then configure CalDAV
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
	calendars | cals) cmd_calendars "$@" ;;
	show | today) cmd_show "$command" "$@" ;;
	add | new) cmd_add "$@" ;;
	search | find) cmd_search "$@" ;;
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
