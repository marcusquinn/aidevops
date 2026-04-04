#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# Email Contact Sync Helper for AI DevOps Framework
# Extracts contact data from email signatures and syncs to macOS Contacts.
#
# Strategy:
#   1. Extract contacts via email-signature-parser-helper.sh (TOON files)
#   2. Match against existing macOS Contacts by email address
#   3. Create new contacts or update existing ones
#   4. Deduplication by email address (primary key)
#
# Fields synced: name, title (job title), company, phone, email, website
#
# macOS-only — requires Contacts.app (AddressBook framework via AppleScript).
#
# Author: AI DevOps Framework
# Version: 1.0.0 (t1505)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Constants
# =============================================================================

readonly DEFAULT_CONTACTS_DIR="${HOME}/.aidevops/.agent-workspace/contacts"
readonly SIG_PARSER="${SCRIPT_DIR}/email-signature-parser-helper.sh"

# =============================================================================
# Platform Guard
# =============================================================================

check_macos() {
	if [[ "$(uname -s)" != "Darwin" ]]; then
		print_error "email-contact-sync-helper.sh requires macOS (detected: $(uname -s))"
		print_info "macOS Contacts and AppleScript are only available on macOS."
		exit 1
	fi
	return 0
}

# =============================================================================
# Utility: run AppleScript safely
# =============================================================================

run_applescript() {
	local script="$1"
	local result
	if ! result=$(osascript -e "$script" 2>&1); then
		print_error "AppleScript failed: $result"
		return 1
	fi
	echo "$result"
	return 0
}

# Run multi-line AppleScript from a heredoc via stdin
run_applescript_stdin() {
	local result
	if ! result=$(osascript 2>&1); then
		print_error "AppleScript failed: $result"
		return 1
	fi
	echo "$result"
	return 0
}

# =============================================================================
# TOON Parsing — read fields from a contact TOON file
# =============================================================================

# Read a single field value from a TOON contact file.
# Usage: toon_field <file> <field>
toon_field() {
	local toon_file="$1"
	local field="$2"
	local value=""
	while IFS= read -r line; do
		case "$line" in
		"  ${field}: "*) value="${line#  "${field}": }" ;;
		esac
	done <"$toon_file"
	echo "$value"
	return 0
}

# =============================================================================
# macOS Contacts — lookup and write via AppleScript
# =============================================================================

# Check if a contact with the given email already exists in macOS Contacts.
# Returns "true" if found, "false" otherwise.
contacts_email_exists() {
	local email="$1"
	local result
	result=$(
		run_applescript_stdin <<APPLESCRIPT
tell application "Contacts"
    set matchList to (every person whose value of emails contains "$email")
    if (count of matchList) > 0 then
        return "true"
    else
        return "false"
    end if
end tell
APPLESCRIPT
	) || return 1
	echo "$result"
	return 0
}

# Create a new contact in macOS Contacts.
# Args: email name title company phone website
contacts_create() {
	local email="$1"
	local name="${2:-}"
	local title="${3:-}"
	local company="${4:-}"
	local phone="${5:-}"
	local website="${6:-}"

	# Split name into first/last (best-effort: last word = last name)
	local first_name="$name"
	local last_name=""
	if [[ "$name" == *" "* ]]; then
		last_name="${name##* }"
		first_name="${name% *}"
	fi

	# Build AppleScript — only set fields that are non-empty
	local as_script
	as_script="tell application \"Contacts\"
    set newPerson to make new person with properties {first name:\"${first_name}\", last name:\"${last_name}\"}"

	if [[ -n "$company" ]]; then
		as_script="${as_script}
    set organization of newPerson to \"${company}\""
	fi

	if [[ -n "$title" ]]; then
		as_script="${as_script}
    set job title of newPerson to \"${title}\""
	fi

	as_script="${as_script}
    make new email at end of emails of newPerson with properties {label:\"work\", value:\"${email}\"}"

	if [[ -n "$phone" ]]; then
		as_script="${as_script}
    make new phone at end of phones of newPerson with properties {label:\"work\", value:\"${phone}\"}"
	fi

	if [[ -n "$website" ]]; then
		as_script="${as_script}
    make new url at end of urls of newPerson with properties {label:\"work\", value:\"${website}\"}"
	fi

	as_script="${as_script}
    save
end tell"

	run_applescript "$as_script" >/dev/null
	return 0
}

# Update an existing contact in macOS Contacts (matched by email).
# Only updates fields that are non-empty in the TOON record.
# Args: email name title company phone website
contacts_update() {
	local email="$1"
	local name="${2:-}"
	local title="${3:-}"
	local company="${4:-}"
	local phone="${5:-}"
	local website="${6:-}"

	# Split name into first/last
	local first_name="$name"
	local last_name=""
	if [[ "$name" == *" "* ]]; then
		last_name="${name##* }"
		first_name="${name% *}"
	fi

	# Build update script — only update non-empty fields
	local as_script
	as_script="tell application \"Contacts\"
    set matchList to (every person whose value of emails contains \"${email}\")
    if (count of matchList) = 0 then return \"not_found\"
    set thePerson to item 1 of matchList"

	if [[ -n "$name" ]]; then
		as_script="${as_script}
    if first name of thePerson is \"\" then set first name of thePerson to \"${first_name}\"
    if last name of thePerson is \"\" then set last name of thePerson to \"${last_name}\""
	fi

	if [[ -n "$company" ]]; then
		as_script="${as_script}
    if organization of thePerson is \"\" then set organization of thePerson to \"${company}\""
	fi

	if [[ -n "$title" ]]; then
		as_script="${as_script}
    if job title of thePerson is \"\" then set job title of thePerson to \"${title}\""
	fi

	if [[ -n "$phone" ]]; then
		as_script="${as_script}
    if (count of phones of thePerson) = 0 then
        make new phone at end of phones of thePerson with properties {label:\"work\", value:\"${phone}\"}
    end if"
	fi

	if [[ -n "$website" ]]; then
		as_script="${as_script}
    if (count of urls of thePerson) = 0 then
        make new url at end of urls of thePerson with properties {label:\"work\", value:\"${website}\"}
    end if"
	fi

	as_script="${as_script}
    save
end tell"

	run_applescript "$as_script" >/dev/null
	return 0
}

# =============================================================================
# Sync a single TOON contact file to macOS Contacts
# =============================================================================

sync_toon_contact() {
	local toon_file="$1"
	local dry_run="${2:-false}"

	if [[ ! -f "$toon_file" ]]; then
		print_error "TOON file not found: $toon_file"
		return 1
	fi

	# Read fields from TOON
	local email name title company phone website
	email=$(toon_field "$toon_file" "email")
	name=$(toon_field "$toon_file" "name")
	title=$(toon_field "$toon_file" "title")
	company=$(toon_field "$toon_file" "company")
	phone=$(toon_field "$toon_file" "phone")
	website=$(toon_field "$toon_file" "website")

	if [[ -z "$email" ]]; then
		print_warning "Skipping $(basename "$toon_file"): no email address"
		return 0
	fi

	if [[ "$dry_run" == "true" ]]; then
		print_info "[dry-run] Would sync: ${email} | ${name:-<no name>} | ${company:-<no company>}"
		return 0
	fi

	# Check if contact exists
	local exists
	exists=$(contacts_email_exists "$email") || {
		print_warning "Could not query Contacts for: $email"
		return 1
	}

	if [[ "$exists" == "true" ]]; then
		contacts_update "$email" "$name" "$title" "$company" "$phone" "$website"
		print_success "Updated: ${email} (${name:-<no name>})"
	else
		contacts_create "$email" "$name" "$title" "$company" "$phone" "$website"
		print_success "Created: ${email} (${name:-<no name>})"
	fi

	return 0
}

# =============================================================================
# Commands
# =============================================================================

# Parse an email file/stdin and sync extracted contacts to macOS Contacts.
# Args: input_source [--dry-run] [--contacts-dir <dir>]
cmd_sync_email() {
	local input_source="${1:--}"
	local dry_run="false"
	local contacts_dir="$DEFAULT_CONTACTS_DIR"

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run) dry_run="true" ;;
		--contacts-dir)
			contacts_dir="${2:-}"
			shift
			;;
		*) print_warning "Unknown option: $1" ;;
		esac
		shift
	done

	if [[ ! -x "$SIG_PARSER" ]]; then
		print_error "email-signature-parser-helper.sh not found or not executable: $SIG_PARSER"
		return 1
	fi

	mkdir -p "$contacts_dir"

	# Extract contacts via signature parser
	local toon_file
	toon_file=$("$SIG_PARSER" parse "$input_source" "$contacts_dir" "email-contact-sync") || {
		print_warning "No contact extracted from: $input_source"
		return 0
	}

	if [[ -z "$toon_file" || ! -f "$toon_file" ]]; then
		print_warning "Signature parser returned no TOON file"
		return 0
	fi

	sync_toon_contact "$toon_file" "$dry_run"
	return 0
}

# Sync all TOON files in a contacts directory to macOS Contacts.
# Args: [contacts_dir] [--dry-run]
cmd_sync_all() {
	local contacts_dir="$DEFAULT_CONTACTS_DIR"
	local dry_run="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run) dry_run="true" ;;
		--contacts-dir)
			contacts_dir="${2:-}"
			shift
			;;
		*)
			# Positional: contacts dir
			if [[ -d "$1" ]]; then
				contacts_dir="$1"
			else
				print_warning "Unknown option or directory not found: $1"
			fi
			;;
		esac
		shift
	done

	if [[ ! -d "$contacts_dir" ]]; then
		print_info "No contacts directory found: $contacts_dir"
		return 0
	fi

	local count=0
	local synced=0
	local failed=0

	while IFS= read -r -d '' toon_file; do
		count=$((count + 1))
		if sync_toon_contact "$toon_file" "$dry_run"; then
			synced=$((synced + 1))
		else
			failed=$((failed + 1))
		fi
	done < <(find "$contacts_dir" -name "*.toon" -type f -print0 2>/dev/null | sort -z)

	print_info "Sync complete: ${synced}/${count} synced, ${failed} failed"
	return 0
}

# Batch parse a directory of email files and sync all extracted contacts.
# Args: email_dir [--dry-run] [--contacts-dir <dir>] [--pattern <glob>]
cmd_batch() {
	local email_dir="${1:-.}"
	local dry_run="false"
	local contacts_dir="$DEFAULT_CONTACTS_DIR"
	local pattern="*.eml"

	shift || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run) dry_run="true" ;;
		--contacts-dir)
			contacts_dir="${2:-}"
			shift
			;;
		--pattern)
			pattern="${2:-*.eml}"
			shift
			;;
		*) print_warning "Unknown option: $1" ;;
		esac
		shift
	done

	if [[ ! -d "$email_dir" ]]; then
		print_error "Email directory not found: $email_dir"
		return 1
	fi

	if [[ ! -x "$SIG_PARSER" ]]; then
		print_error "email-signature-parser-helper.sh not found: $SIG_PARSER"
		return 1
	fi

	mkdir -p "$contacts_dir"

	local count=0
	local parsed=0
	local failed=0

	while IFS= read -r -d '' email_file; do
		count=$((count + 1))
		print_info "Parsing: $(basename "$email_file")"
		local toon_file
		toon_file=$("$SIG_PARSER" parse "$email_file" "$contacts_dir" "email-contact-sync:$(basename "$email_file")") || {
			print_warning "No contact extracted from: $(basename "$email_file")"
			failed=$((failed + 1))
			continue
		}
		if [[ -n "$toon_file" && -f "$toon_file" ]]; then
			if sync_toon_contact "$toon_file" "$dry_run"; then
				parsed=$((parsed + 1))
			else
				failed=$((failed + 1))
			fi
		else
			failed=$((failed + 1))
		fi
	done < <(find "$email_dir" -name "$pattern" -type f -print0 2>/dev/null)

	print_info "Batch complete: ${parsed}/${count} synced, ${failed} failed"
	return 0
}

# List all contacts in macOS Contacts (basic summary).
cmd_list() {
	print_info "macOS Contacts (first 50):"
	run_applescript_stdin <<'APPLESCRIPT'
tell application "Contacts"
    set output to ""
    set personList to every person
    set maxCount to 50
    if (count of personList) < maxCount then set maxCount to count of personList
    repeat with i from 1 to maxCount
        set thePerson to item i of personList
        set pName to (first name of thePerson & " " & last name of thePerson)
        set pOrg to organization of thePerson
        set pEmails to ""
        repeat with e in emails of thePerson
            set pEmails to pEmails & value of e & " "
        end repeat
        set output to output & pName & " | " & pOrg & " | " & pEmails & linefeed
    end repeat
    return output
end tell
APPLESCRIPT
	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	cat <<'HELP'
Email Contact Sync Helper - AI DevOps Framework

Extracts contact data from email signatures and syncs to macOS Contacts.
macOS-only — requires Contacts.app.

Usage: email-contact-sync-helper.sh <command> [options]

Commands:
  sync-email <file|->   Parse email and sync extracted contact to macOS Contacts
  sync-all              Sync all TOON files in contacts dir to macOS Contacts
  batch <dir>           Parse all emails in dir and sync contacts
  list                  List contacts in macOS Contacts (first 50)
  help                  Show this help

Options:
  --dry-run             Show what would be synced without writing to Contacts
  --contacts-dir <dir>  TOON contacts directory (default: ~/.aidevops/.agent-workspace/contacts)
  --pattern <glob>      File pattern for batch (default: *.eml)

Examples:
  # Parse a single email and sync contact
  email-contact-sync-helper.sh sync-email email.txt

  # Parse from stdin
  cat email.txt | email-contact-sync-helper.sh sync-email -

  # Dry run: see what would be synced
  email-contact-sync-helper.sh sync-email email.txt --dry-run

  # Sync all previously extracted TOON contacts
  email-contact-sync-helper.sh sync-all ~/.aidevops/.agent-workspace/contacts

  # Batch parse and sync all .eml files in a directory
  email-contact-sync-helper.sh batch ./emails --dry-run

  # List macOS Contacts
  email-contact-sync-helper.sh list

Strategy:
  1. email-signature-parser-helper.sh extracts contact fields to TOON files
  2. Deduplication by email address (primary key in macOS Contacts)
  3. Create new contact if email not found; update empty fields if found
  4. Fields: name (first/last split), job title, company, phone, email, website
HELP
	return 0
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	check_macos

	case "$command" in
	sync-email)
		cmd_sync_email "$@"
		;;
	sync-all)
		cmd_sync_all "$@"
		;;
	batch)
		cmd_batch "$@"
		;;
	list)
		cmd_list
		;;
	help | --help | -h)
		show_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
