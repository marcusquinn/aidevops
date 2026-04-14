#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# Apple Mail Helper Script
# AppleScript bridge for Apple Mail on macOS
# Provides CLI access to accounts, inbox, send, signatures, smart-mailbox,
# organize, flag, attachment-settings, and archive operations.
#
# Usage: apple-mail-helper.sh <command> [options]
#
# Commands:
#   accounts              List configured Apple Mail accounts
#   inbox                 Read messages from a mailbox
#   send                  Compose and send an email (supports --draft)
#   signatures            List and extract email signatures
#   smart-mailbox         Create smart mailboxes
#   organize              Move messages to category mailboxes
#   flag                  Set Apple Mail flags on messages
#   attachment-settings   Set image attachment size
#   archive               Archive messages from inbox
#   help                  Show this help
#
# macOS-only — requires Apple Mail (Mail.app) configured.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Platform Guard
# =============================================================================

check_macos() {
	if [[ "$(uname -s)" != "Darwin" ]]; then
		print_error "apple-mail-helper.sh requires macOS (detected: $(uname -s))"
		print_info "Apple Mail and AppleScript are only available on macOS."
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

# Run multi-line AppleScript from stdin
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
# accounts — List configured Apple Mail accounts
# =============================================================================

cmd_accounts() {
	print_info "Apple Mail accounts:"
	run_applescript '
tell application "Mail"
    set output to ""
    repeat with acct in accounts
        set acctName to name of acct
        set acctType to account type of acct as string
        set acctEmail to email addresses of acct as string
        set acctEnabled to enabled of acct
        set enabledStr to "enabled"
        if not acctEnabled then set enabledStr to "disabled"
        set output to output & acctName & " | " & acctType & " | " & acctEmail & " | " & enabledStr & linefeed
    end repeat
    return output
end tell'
	return 0
}

# =============================================================================
# inbox — Read messages from a mailbox
# =============================================================================

cmd_inbox() {
	local mailbox_name="${1:-INBOX}"
	local account_name="${2:-}"
	local count="${3:-10}"

	if [[ -n "$account_name" ]]; then
		print_info "Reading $count messages from '$mailbox_name' in account '$account_name':"
		run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    set acct to account "$account_name"
    set mbox to mailbox "$mailbox_name" of acct
    set msgs to messages 1 through $count of mbox
    set output to ""
    repeat with msg in msgs
        set msgSubject to subject of msg
        set msgSender to sender of msg
        set msgDate to date received of msg as string
        set msgRead to read status of msg
        set readStr to "unread"
        if msgRead then set readStr to "read"
        set output to output & msgDate & " | " & msgSender & " | " & msgSubject & " | " & readStr & linefeed
    end repeat
    return output
end tell
APPLESCRIPT
	else
		print_info "Reading $count messages from '$mailbox_name' (all accounts):"
		run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    set mbox to mailbox "$mailbox_name"
    set msgCount to count of messages of mbox
    if msgCount < $count then set maxCount to msgCount
    if msgCount is greater than or equal to $count then set maxCount to $count
    set msgs to messages 1 through maxCount of mbox
    set output to ""
    repeat with msg in msgs
        set msgSubject to subject of msg
        set msgSender to sender of msg
        set msgDate to date received of msg as string
        set msgRead to read status of msg
        set readStr to "unread"
        if msgRead then set readStr to "read"
        set output to output & msgDate & " | " & msgSender & " | " & msgSubject & " | " & readStr & linefeed
    end repeat
    return output
end tell
APPLESCRIPT
	fi
	return 0
}

# =============================================================================
# send — Compose and send an email (with optional --draft hold)
# =============================================================================

cmd_send() {
	local to_addr=""
	local subject=""
	local body=""
	local from_addr=""
	local draft_mode=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			to_addr="$2"
			shift 2
			;;
		--subject)
			subject="$2"
			shift 2
			;;
		--body)
			body="$2"
			shift 2
			;;
		--from)
			from_addr="$2"
			shift 2
			;;
		--draft)
			draft_mode=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$to_addr" || -z "$subject" ]]; then
		print_error "Usage: $0 send --to <email> --subject <subject> --body <body> [--from <email>] [--draft]"
		return 1
	fi

	# Escape double quotes in body and subject for AppleScript
	local escaped_body="${body//\"/\\\"}"
	local escaped_subject="${subject//\"/\\\"}"

	if [[ "$draft_mode" = true ]]; then
		print_info "Creating draft email (held for review)..."
		local from_clause=""
		if [[ -n "$from_addr" ]]; then
			from_clause="set sender of newMsg to \"$from_addr\""
		fi
		run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    set newMsg to make new outgoing message with properties {subject:"$escaped_subject", content:"$escaped_body", visible:true}
    tell newMsg
        make new to recipient at end of to recipients with properties {address:"$to_addr"}
        $from_clause
    end tell
end tell
APPLESCRIPT
		print_success "Draft created and displayed for review. Review in Mail.app before sending."
	else
		print_info "Sending email to $to_addr..."
		local from_clause=""
		if [[ -n "$from_addr" ]]; then
			from_clause="set sender of newMsg to \"$from_addr\""
		fi
		run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    set newMsg to make new outgoing message with properties {subject:"$escaped_subject", content:"$escaped_body", visible:false}
    tell newMsg
        make new to recipient at end of to recipients with properties {address:"$to_addr"}
        $from_clause
    end tell
    send newMsg
end tell
APPLESCRIPT
		print_success "Email sent to $to_addr"
	fi
	return 0
}

# =============================================================================
# signatures — List and extract email signatures
# =============================================================================

cmd_signatures() {
	local action="${1:-list}"

	case "$action" in
	list)
		print_info "Apple Mail signatures:"
		run_applescript '
tell application "Mail"
    set output to ""
    set sigs to name of every signature
    repeat with sigName in sigs
        set output to output & sigName & linefeed
    end repeat
    return output
end tell'
		;;
	extract)
		print_info "Extracting signatures from Apple Mail data directory..."
		local sig_dirs
		# Apple Mail stores signatures in versioned directories
		# Use a while-read loop for bash 3.2 compatibility
		local found_any=false
		while IFS= read -r sig_dir; do
			found_any=true
			print_info "Signature directory: $sig_dir"
			local sig_count=0
			while IFS= read -r sig_file; do
				sig_count=$((sig_count + 1))
				local basename
				basename="$(basename "$sig_file")"
				print_info "  [$sig_count] $basename"
			done < <(find "$sig_dir" -name "*.mailsignature" -type f 2>/dev/null)
			if [[ "$sig_count" -eq 0 ]]; then
				print_warning "  No .mailsignature files found"
			fi
		done < <(find ~/Library/Mail -path "*/MailData/Signatures" -type d 2>/dev/null)
		if [[ "$found_any" = false ]]; then
			print_warning "No Apple Mail signature directories found"
			print_info "Expected at: ~/Library/Mail/V*/MailData/Signatures/"
		fi
		;;
	read)
		local sig_name="${2:-}"
		if [[ -z "$sig_name" ]]; then
			print_error "Usage: $0 signatures read <signature-name>"
			return 1
		fi
		print_info "Reading signature '$sig_name':"
		run_applescript "tell application \"Mail\" to return content of signature \"$sig_name\""
		;;
	*)
		print_error "Unknown signatures action: $action"
		print_info "Usage: $0 signatures [list|extract|read <name>]"
		return 1
		;;
	esac
	return 0
}

# =============================================================================
# smart-mailbox — Create smart mailboxes via AppleScript
# =============================================================================

_smart_mailbox_create() {
	local name="${1:-}"
	local predicate="${2:-}"
	if [[ -z "$name" || -z "$predicate" ]]; then
		print_error "Usage: $0 smart-mailbox create <name> <predicate>"
		print_info "Predicate examples:"
		print_info "  'sender contains \"example.com\"'"
		print_info "  'subject contains \"invoice\"'"
		print_info "  'sender = \"user@example.com\"'"
		return 1
	fi
	print_info "Creating smart mailbox '$name'..."
	local escaped_name="${name//\"/\\\"}"
	local escaped_pred="${predicate//\"/\\\"}"
	run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    make new smart mailbox with properties {name:"$escaped_name", search predicate:"$escaped_pred"}
end tell
APPLESCRIPT
	print_success "Smart mailbox '$name' created"
	return 0
}

_smart_mailbox_list() {
	print_info "Smart mailboxes:"
	run_applescript '
tell application "Mail"
    set output to ""
    repeat with smb in smart mailboxes
        set smbName to name of smb
        set output to output & smbName & linefeed
    end repeat
    return output
end tell'
	return 0
}

_smart_mailbox_contact() {
	local contact_email="${1:-}"
	if [[ -z "$contact_email" ]]; then
		print_error "Usage: $0 smart-mailbox contact <email>"
		return 1
	fi
	local box_name="From: $contact_email"
	local escaped_email="${contact_email//\"/\\\"}"
	local escaped_box="${box_name//\"/\\\"}"
	print_info "Creating smart mailbox for contact '$contact_email'..."
	run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    make new smart mailbox with properties {name:"$escaped_box", search predicate:"sender = \"$escaped_email\""}
end tell
APPLESCRIPT
	print_success "Smart mailbox '$box_name' created"
	return 0
}

_smart_mailbox_domain() {
	local domain="${1:-}"
	if [[ -z "$domain" ]]; then
		print_error "Usage: $0 smart-mailbox domain <domain>"
		return 1
	fi
	local box_name="Domain: $domain"
	local escaped_domain="${domain//\"/\\\"}"
	local escaped_box="${box_name//\"/\\\"}"
	print_info "Creating smart mailbox for domain '$domain'..."
	run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    make new smart mailbox with properties {name:"$escaped_box", search predicate:"sender contains \"@$escaped_domain\""}
end tell
APPLESCRIPT
	print_success "Smart mailbox '$box_name' created"
	return 0
}

_smart_mailbox_project() {
	local project_name="${1:-}"
	if [[ -z "$project_name" ]]; then
		print_error "Usage: $0 smart-mailbox project <project-name>"
		return 1
	fi
	local box_name="Project: $project_name"
	local escaped_project="${project_name//\"/\\\"}"
	local escaped_box="${box_name//\"/\\\"}"
	print_info "Creating smart mailbox for project '$project_name'..."
	run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    make new smart mailbox with properties {name:"$escaped_box", search predicate:"subject contains \"$escaped_project\""}
end tell
APPLESCRIPT
	print_success "Smart mailbox '$box_name' created"
	return 0
}

_smart_mailbox_help() {
	echo "Usage: $0 smart-mailbox <action> [options]"
	echo ""
	echo "Actions:"
	echo "  list                          List all smart mailboxes"
	echo "  create <name> <predicate>     Create with custom predicate"
	echo "  contact <email>               Create for a specific contact"
	echo "  domain <domain>               Create for a domain"
	echo "  project <project-name>        Create for a project (subject match)"
	return 0
}

cmd_smart_mailbox() {
	local action="${1:-help}"
	shift || true

	case "$action" in
	create) _smart_mailbox_create "$@" ;;
	list) _smart_mailbox_list ;;
	contact) _smart_mailbox_contact "$@" ;;
	domain) _smart_mailbox_domain "$@" ;;
	project) _smart_mailbox_project "$@" ;;
	help | *) _smart_mailbox_help ;;
	esac
	return 0
}

# =============================================================================
# organize — Move messages to category mailboxes
# =============================================================================

cmd_organize() {
	local message_id="${1:-}"
	local category="${2:-}"

	if [[ -z "$message_id" || -z "$category" ]]; then
		print_error "Usage: $0 organize <message-id> <category>"
		print_info "Categories: Primary, Transactions, Updates, Promotions, Junk"
		return 1
	fi

	# Validate category
	case "$category" in
	Primary | Transactions | Updates | Promotions | Junk) ;;
	*)
		print_error "Invalid category: $category"
		print_info "Valid categories: Primary, Transactions, Updates, Promotions, Junk"
		return 1
		;;
	esac

	print_info "Moving message '$message_id' to '$category'..."
	run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    -- Find the message by message ID header
    set targetMsgs to (every message of inbox whose message id is "$message_id")
    if (count of targetMsgs) is 0 then
        error "Message not found with ID: $message_id"
    end if
    set targetMsg to item 1 of targetMsgs

    -- Find or create the category mailbox
    set acct to account of mailbox of targetMsg
    try
        set destBox to mailbox "$category" of acct
    on error
        set destBox to make new mailbox with properties {name:"$category"} at acct
    end try

    move targetMsg to destBox
    return "Moved to $category"
end tell
APPLESCRIPT
	print_success "Message moved to '$category'"
	return 0
}

# =============================================================================
# flag — Set Apple Mail flags on messages
# =============================================================================

cmd_flag() {
	local message_id="${1:-}"
	local flag_color="${2:-}"

	if [[ -z "$message_id" || -z "$flag_color" ]]; then
		print_error "Usage: $0 flag <message-id> <color>"
		echo ""
		echo "Flag colors and their suggested meanings:"
		echo "  red       Reminders — needs follow-up"
		echo "  orange    Tasks — action required"
		echo "  yellow    Review — needs review"
		echo "  green     Filing — file/archive when done"
		echo "  blue      Ideas — interesting, save for later"
		echo "  purple    Add-to-Contacts — add sender to contacts"
		echo "  gray      General flag"
		return 1
	fi

	# Map color names to Apple Mail flag index
	local flag_index
	case "$flag_color" in
	red) flag_index=0 ;;
	orange) flag_index=1 ;;
	yellow) flag_index=2 ;;
	green) flag_index=3 ;;
	blue) flag_index=4 ;;
	purple) flag_index=5 ;;
	gray) flag_index=6 ;;
	*)
		print_error "Invalid flag color: $flag_color"
		print_info "Valid colors: red, orange, yellow, green, blue, purple, gray"
		return 1
		;;
	esac

	print_info "Flagging message '$message_id' with $flag_color..."
	run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    set targetMsgs to (every message of inbox whose message id is "$message_id")
    if (count of targetMsgs) is 0 then
        error "Message not found with ID: $message_id"
    end if
    set targetMsg to item 1 of targetMsgs
    set flag index of targetMsg to $flag_index
    set flagged status of targetMsg to true
    return "Flagged with $flag_color"
end tell
APPLESCRIPT
	print_success "Message flagged with $flag_color"
	return 0
}

# =============================================================================
# attachment-settings — Set image attachment size
# =============================================================================

cmd_attachment_settings() {
	local size="${1:-}"

	if [[ -z "$size" ]]; then
		print_error "Usage: $0 attachment-settings <size>"
		print_info "Sizes: original, large"
		print_info "  original  Send images at full resolution"
		print_info "  large     Resize images to Large (approx 1280px)"
		return 1
	fi

	local size_value
	case "$size" in
	original) size_value="actual size" ;;
	large) size_value="large" ;;
	*)
		print_error "Invalid size: $size"
		print_info "Valid sizes: original, large"
		return 1
		;;
	esac

	print_info "Setting image attachment size to '$size'..."
	run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    set download remote content to true
end tell
tell application "System Events"
    tell process "Mail"
        -- Note: Apple Mail attachment size is set per-message in the compose window.
        -- This sets the preference via defaults for new messages.
    end tell
end tell
APPLESCRIPT

	# Use defaults write for the persistent preference
	if [[ "$size" = "original" ]]; then
		# shell-portability: ignore next — apple-mail-helper is macOS-only
		defaults write com.apple.mail ImageSizePreference -int 0
	else
		# shell-portability: ignore next — apple-mail-helper is macOS-only
		defaults write com.apple.mail ImageSizePreference -int 3
	fi

	print_success "Image attachment size set to '$size'"
	print_info "This applies to new compose windows."
	return 0
}

# =============================================================================
# archive — Archive messages from inbox
# =============================================================================

cmd_archive() {
	local message_id="${1:-}"
	local account_name="${2:-}"

	if [[ -z "$message_id" ]]; then
		print_error "Usage: $0 archive <message-id> [account-name]"
		print_info "Archives the message by moving it to the Archive mailbox."
		return 1
	fi

	print_info "Archiving message '$message_id'..."
	if [[ -n "$account_name" ]]; then
		run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    set acct to account "$account_name"
    set targetMsgs to (every message of inbox whose message id is "$message_id")
    if (count of targetMsgs) is 0 then
        error "Message not found with ID: $message_id"
    end if
    set targetMsg to item 1 of targetMsgs

    -- Try Archive mailbox, fall back to All Mail
    try
        set archiveBox to mailbox "Archive" of acct
    on error
        try
            set archiveBox to mailbox "[Gmail]/All Mail" of acct
        on error
            set archiveBox to make new mailbox with properties {name:"Archive"} at acct
        end try
    end try

    move targetMsg to archiveBox
    return "Archived"
end tell
APPLESCRIPT
	else
		run_applescript_stdin <<APPLESCRIPT
tell application "Mail"
    set targetMsgs to (every message of inbox whose message id is "$message_id")
    if (count of targetMsgs) is 0 then
        error "Message not found with ID: $message_id"
    end if
    set targetMsg to item 1 of targetMsgs
    set acct to account of mailbox of targetMsg

    -- Try Archive mailbox, fall back to All Mail
    try
        set archiveBox to mailbox "Archive" of acct
    on error
        try
            set archiveBox to mailbox "[Gmail]/All Mail" of acct
        on error
            set archiveBox to make new mailbox with properties {name:"Archive"} at acct
        end try
    end try

    move targetMsg to archiveBox
    return "Archived"
end tell
APPLESCRIPT
	fi
	print_success "Message archived"
	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	echo "Apple Mail Helper — AppleScript bridge for Mail.app"
	echo ""
	echo "Usage: $0 <command> [options]"
	echo ""
	echo "Commands:"
	echo "  accounts                          List configured Mail accounts"
	echo "  inbox [mailbox] [account] [count] Read messages (default: INBOX, 10)"
	echo "  send --to <email> --subject <subj> --body <body> [--from <email>] [--draft]"
	echo "                                    Compose and send (--draft holds for review)"
	echo "  signatures [list|extract|read <name>]"
	echo "                                    List, extract, or read signatures"
	echo "  smart-mailbox <action> [options]  Create/list smart mailboxes"
	echo "  organize <message-id> <category>  Move message to category"
	echo "  flag <message-id> <color>         Set flag color on message"
	echo "  attachment-settings <size>        Set image size (original|large)"
	echo "  archive <message-id> [account]    Archive a message"
	echo "  help                              Show this help"
	echo ""
	echo "Flag colors: red (Reminders), orange (Tasks), yellow (Review),"
	echo "  green (Filing), blue (Ideas), purple (Add-to-Contacts), gray (General)"
	echo ""
	echo "Categories: Primary, Transactions, Updates, Promotions, Junk"
	echo ""
	echo "Requires: macOS with Apple Mail configured"
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	check_macos

	case "$command" in
	accounts)
		cmd_accounts
		;;
	inbox)
		cmd_inbox "$@"
		;;
	send)
		cmd_send "$@"
		;;
	signatures)
		cmd_signatures "$@"
		;;
	smart-mailbox)
		cmd_smart_mailbox "$@"
		;;
	organize)
		cmd_organize "$@"
		;;
	flag)
		cmd_flag "$@"
		;;
	attachment-settings)
		cmd_attachment_settings "$@"
		;;
	archive)
		cmd_archive "$@"
		;;
	help | *)
		show_help
		;;
	esac
	return 0
}

main "$@"
