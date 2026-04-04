#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# Contacts Helper — cross-platform CLI for agent use
#
# Backends:
#   macOS:  osascript via Contacts.app
#   Linux:  khard + vdirsyncer (CardDAV)
#
# Usage: ./contacts-helper.sh [command] [args] [options]
# Commands:
#   setup                - Check/install backend, verify access
#   books                - List addressbooks
#   search <query>       - Search contacts by name/email/phone
#   show <name>          - Show full contact details
#   add [options]        - Create a new contact
#   email <query>        - List email addresses matching query
#   phone <query>        - List phone numbers matching query
#   sync                 - Sync CardDAV (Linux; macOS syncs automatically)
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
# macOS Backend (osascript / Contacts.app)
# =============================================================================

macos_check_ready() {
	# Contacts.app is always available on macOS
	return 0
}

macos_setup() {
	print_info "Checking Contacts access (macOS)..."
	# Test access by listing a small number
	local count
	count="$(osascript -e 'tell application "Contacts" to count of people' 2>&1)" || true
	if [[ "$count" =~ ^[0-9]+$ ]]; then
		print_success "Contacts access: authorized (${count} contacts)"
	else
		print_warning "Contacts access may need authorization."
		print_info "System Settings > Privacy & Security > Contacts > enable your terminal app"
		return 1
	fi
	print_success "macOS contacts setup complete."
	return 0
}

macos_books() {
	osascript -e 'tell application "Contacts" to get name of every group' 2>&1
	return 0
}

macos_search() {
	local query="$1"
	# Fast approach: get all names, filter in bash (avoids slow AppleScript whose)
	osascript -e 'tell application "Contacts" to get name of every person' 2>&1 |
		tr ',' '\n' | sed 's/^ //' | grep -i "$query" || echo "No contacts found matching: ${query}"
	return 0
}

macos_show() {
	local name="$1"
	osascript -e "
tell application \"Contacts\"
	set matchList to every person whose name is \"${name}\"
	if (count of matchList) = 0 then
		set matchList to every person whose name contains \"${name}\"
	end if
	if (count of matchList) = 0 then return \"No contact found matching: ${name}\"
	set p to item 1 of matchList
	set output to {\"Name: \" & name of p}
	try
		if organization of p is not missing value then set end of output to \"Organization: \" & organization of p
	end try
	try
		if job title of p is not missing value then set end of output to \"Job Title: \" & job title of p
	end try
	repeat with e in emails of p
		set end of output to \"Email (\" & label of e & \"): \" & value of e
	end repeat
	repeat with ph in phones of p
		set end of output to \"Phone (\" & label of ph & \"): \" & value of ph
	end repeat
	try
		if note of p is not missing value then set end of output to \"Notes: \" & note of p
	end try
	return output as text
end tell" 2>&1
	return 0
}

macos_add() {
	local first="$1" last="$2" org="$3" email="$4" phone="$5"
	local notes="$6" jobtitle="$7"

	local props="first name:\"${first}\""
	[[ -n "$last" ]] && props="${props}, last name:\"${last}\""
	[[ -n "$org" ]] && props="${props}, organization:\"${org}\""
	[[ -n "$jobtitle" ]] && props="${props}, job title:\"${jobtitle}\""
	[[ -n "$notes" ]] && props="${props}, note:\"${notes}\""

	local extra_cmds=""
	if [[ -n "$email" ]]; then
		extra_cmds="${extra_cmds}
make new email at end of emails of newPerson with properties {label:\"work\", value:\"${email}\"}"
	fi
	if [[ -n "$phone" ]]; then
		extra_cmds="${extra_cmds}
make new phone at end of phones of newPerson with properties {label:\"mobile\", value:\"${phone}\"}"
	fi

	osascript -e "
tell application \"Contacts\"
	set newPerson to make new person with properties {${props}}
	${extra_cmds}
	save
end tell" 2>&1

	return $?
}

macos_email() {
	local query="$1"
	# Get matching names first (fast), then pull emails for matches
	local names
	names="$(osascript -e 'tell application "Contacts" to get name of every person' 2>&1 |
		tr ',' '\n' | sed 's/^ //' | grep -i "$query")" || true
	if [[ -z "$names" ]]; then
		echo "No contacts found matching: ${query}"
		return 0
	fi
	# Get email for the first match (detailed lookup)
	local first_match
	first_match="$(echo "$names" | head -1 | sed 's/^[[:space:]]*//')"
	macos_show "$first_match" 2>&1 | grep -i "Email" || echo "No email found for: ${first_match}"
	return 0
}

macos_phone() {
	local query="$1"
	local names
	names="$(osascript -e 'tell application "Contacts" to get name of every person' 2>&1 |
		tr ',' '\n' | sed 's/^ //' | grep -i "$query")" || true
	if [[ -z "$names" ]]; then
		echo "No contacts found matching: ${query}"
		return 0
	fi
	local first_match
	first_match="$(echo "$names" | head -1 | sed 's/^[[:space:]]*//')"
	macos_show "$first_match" 2>&1 | grep -i "Phone" || echo "No phone found for: ${first_match}"
	return 0
}

macos_sync() {
	print_info "macOS syncs contacts automatically via iCloud/CardDAV."
	return 0
}

# =============================================================================
# Linux Backend (khard + vdirsyncer)
# =============================================================================

KHARD_BIN="khard"

linux_check_ready() {
	if ! command -v "$KHARD_BIN" >/dev/null 2>&1; then
		print_error "khard not found. Install: brew install khard (or pipx install khard)"
		return 1
	fi
	if ! command -v vdirsyncer >/dev/null 2>&1; then
		print_error "vdirsyncer not found. Install: pipx install vdirsyncer"
		return 1
	fi
	if [[ ! -f "${HOME}/.config/khard/khard.conf" ]]; then
		print_error "khard not configured: ~/.config/khard/khard.conf"
		return 1
	fi
	return 0
}

linux_setup() {
	print_info "Checking Contacts CLI setup (Linux)..."

	if command -v "$KHARD_BIN" >/dev/null 2>&1; then
		print_success "khard installed: $("$KHARD_BIN" --version 2>&1)"
	else
		print_warning "khard not installed. Install: brew install khard"
		return 1
	fi

	if command -v vdirsyncer >/dev/null 2>&1; then
		print_success "vdirsyncer installed"
	else
		print_warning "vdirsyncer not installed. Install: pipx install vdirsyncer"
		return 1
	fi

	if [[ -f "${HOME}/.config/khard/khard.conf" ]]; then
		print_success "khard config found"
	else
		print_warning "khard not configured: ~/.config/khard/khard.conf"
		return 1
	fi

	print_info "Addressbooks:"
	"$KHARD_BIN" addressbooks 2>&1 || true
	print_success "Linux contacts setup complete."
	return 0
}

linux_books() {
	"$KHARD_BIN" addressbooks 2>&1
	return 0
}

linux_search() {
	local query="$1"
	"$KHARD_BIN" list "$query" 2>&1
	return 0
}

linux_show() {
	local name="$1"
	"$KHARD_BIN" show "$name" 2>&1
	return 0
}

linux_add() {
	local first="$1" last="$2" org="$3" email="$4" phone="$5"
	local notes="$6" jobtitle="$7"

	# Build a YAML template and pipe to khard
	local yaml="First name: ${first}"
	[[ -n "$last" ]] && yaml="${yaml}
Last name: ${last}"
	[[ -n "$org" ]] && yaml="${yaml}
Organisation: ${org}"
	[[ -n "$jobtitle" ]] && yaml="${yaml}
Title: ${jobtitle}"
	[[ -n "$notes" ]] && yaml="${yaml}
Note: ${notes}"
	[[ -n "$email" ]] && yaml="${yaml}
Email:
    work: ${email}"
	[[ -n "$phone" ]] && yaml="${yaml}
Phone:
    cell: ${phone}"

	echo "$yaml" | "$KHARD_BIN" new --skip-unparsable 2>&1
	return $?
}

linux_email() {
	local query="$1"
	"$KHARD_BIN" email "$query" 2>&1
	return 0
}

linux_phone() {
	local query="$1"
	"$KHARD_BIN" phone "$query" 2>&1
	return 0
}

linux_sync() {
	print_info "Syncing CardDAV..."
	vdirsyncer sync 2>&1
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		print_success "CardDAV sync complete"
	else
		print_warning "CardDAV sync had issues (exit ${rc})"
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

cmd_books() {
	case "$PLATFORM" in
	macos)
		macos_check_ready || return 1
		macos_books
		;;
	linux)
		linux_check_ready || return 1
		linux_books
		;;
	esac
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

	case "$PLATFORM" in
	macos) macos_search "$query" ;;
	linux) linux_search "$query" ;;
	esac
}

cmd_show() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local name="${1:-}"
	if [[ -z "$name" ]]; then
		print_error "Contact name required."
		return 1
	fi

	case "$PLATFORM" in
	macos) macos_show "$name" ;;
	linux) linux_show "$name" ;;
	esac
}

cmd_add() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local first="" last="" org="" email="" phone="" notes="" jobtitle=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--first | -f)
			first="$2"
			shift 2
			;;
		--last | -l)
			last="$2"
			shift 2
			;;
		--org | -o)
			org="$2"
			shift 2
			;;
		--email | -e)
			email="$2"
			shift 2
			;;
		--phone | -p)
			phone="$2"
			shift 2
			;;
		--notes | -n)
			notes="$2"
			shift 2
			;;
		--title | -t)
			jobtitle="$2"
			shift 2
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$first" && -z "$org" ]]; then
		print_error "First name (--first) or organization (--org) required."
		return 1
	fi

	local rc=0
	case "$PLATFORM" in
	macos)
		macos_add "$first" "$last" "$org" "$email" "$phone" "$notes" "$jobtitle"
		rc=$?
		;;
	linux)
		linux_add "$first" "$last" "$org" "$email" "$phone" "$notes" "$jobtitle"
		rc=$?
		;;
	esac

	if [[ $rc -eq 0 ]]; then
		print_success "Contact created: ${first} ${last}"
	else
		print_error "Failed to create contact"
	fi
	return $rc
}

cmd_email() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local query="${1:-}"
	if [[ -z "$query" ]]; then
		print_error "Search query required."
		return 1
	fi

	case "$PLATFORM" in
	macos) macos_email "$query" ;;
	linux) linux_email "$query" ;;
	esac
}

cmd_phone() {
	case "$PLATFORM" in
	macos) macos_check_ready || return 1 ;;
	linux) linux_check_ready || return 1 ;;
	esac

	local query="${1:-}"
	if [[ -z "$query" ]]; then
		print_error "Search query required."
		return 1
	fi

	case "$PLATFORM" in
	macos) macos_phone "$query" ;;
	linux) linux_phone "$query" ;;
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
Contacts Helper — cross-platform CLI for agent use

Backends: osascript/Contacts.app (macOS) | khard + vdirsyncer (Linux/CardDAV)

Usage: contacts-helper.sh <command> [args] [options]

Commands:
  setup                  Check/install backend, verify access
  books                  List addressbooks/groups
  search <query>         Search contacts by name
  show <name>            Show full contact details
  add [options]          Create a new contact
  email <query>          List email addresses matching name
  phone <query>          List phone numbers matching name
  sync                   Sync CardDAV (Linux; macOS syncs automatically)
  help                   Show this help

Add options:
  --first, -f <name>     First name
  --last, -l <name>      Last name
  --org, -o <company>    Organization/company
  --email, -e <addr>     Email address
  --phone, -p <number>   Phone number
  --title, -t <title>    Job title
  --notes, -n <text>     Notes

Examples:
  contacts-helper.sh setup
  contacts-helper.sh search "John"
  contacts-helper.sh show "John Smith"
  contacts-helper.sh email "Smith"
  contacts-helper.sh phone "Smith"
  contacts-helper.sh add --first John --last Smith --email john@example.com --phone "+44123456789"
  contacts-helper.sh add --first Jane --org "Acme Corp" --title "CTO" --notes "Met at conference"
  contacts-helper.sh sync

Setup — macOS: No install needed (uses Contacts.app). May need Privacy authorization.
Setup — Linux: brew install khard && pipx install vdirsyncer, then configure CardDAV.
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
	books | addressbooks | groups) cmd_books "$@" ;;
	search | find) cmd_search "$@" ;;
	show | details) cmd_show "$@" ;;
	add | new) cmd_add "$@" ;;
	email | emails) cmd_email "$@" ;;
	phone | phones) cmd_phone "$@" ;;
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
