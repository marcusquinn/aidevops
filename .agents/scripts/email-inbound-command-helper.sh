#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# email-inbound-command-helper.sh
# Poll inbound email from permitted senders, scan for prompt injection,
# create TODO tasks, and send confirmation replies.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

readonly CONFIG_FILE_DEFAULT="${HOME}/.config/aidevops/email-inbound-commands.conf"
readonly STATE_DIR_DEFAULT="${HOME}/.aidevops/.agent-workspace/email-inbound-commands"
readonly PROCESSED_IDS_FILE="processed-message-ids.txt"
readonly MAX_BODY_CHARS=12000
readonly MAX_DESCRIPTION_CHARS=1200
readonly RECORD_DELIMITER="<<<AIDEVOPS_RECORD_END>>>"

readonly -a BLOCKED_EXTENSIONS=(
	"exe" "bat" "cmd" "com" "scr" "pif" "msi" "msp" "mst"
	"ps1" "psm1" "psd1" "vbs" "vbe" "js" "jse" "ws" "wsf" "wsc" "wsh"
	"jar" "class" "jnlp"
	"docm" "xlsm" "pptm" "dotm" "xltm" "potm" "xlam" "ppam"
	"hta" "cpl" "inf" "reg" "rgs" "sct" "shb" "lnk" "url"
	"iso" "img" "vhd" "vhdx"
	"app" "command" "action" "workflow"
)

CONFIG_FILE="${AIDEVOPS_EMAIL_INBOUND_CONFIG:-$CONFIG_FILE_DEFAULT}"
STATE_DIR="${AIDEVOPS_EMAIL_INBOUND_STATE_DIR:-$STATE_DIR_DEFAULT}"
PROCESSED_FILE=""

PROMPT_GUARD_HELPER="${SCRIPT_DIR}/prompt-guard-helper.sh"
CLAIM_TASK_HELPER="${SCRIPT_DIR}/claim-task-id.sh"
APPLE_MAIL_HELPER="${SCRIPT_DIR}/apple-mail-helper.sh"
AUDIT_LOG_HELPER="${SCRIPT_DIR}/audit-log-helper.sh"
EMAIL_COMPOSE_HELPER="${SCRIPT_DIR}/email-compose-helper.sh"

LOG_PREFIX="EMAIL-INBOUND"

init_state() {
	mkdir -p "$STATE_DIR"
	PROCESSED_FILE="${STATE_DIR}/${PROCESSED_IDS_FILE}"
	if [[ ! -f "$PROCESSED_FILE" ]]; then
		touch "$PROCESSED_FILE"
	fi
	return 0
}

check_dependencies() {
	local missing=0

	if [[ ! -x "$PROMPT_GUARD_HELPER" ]]; then
		log_error "Missing required helper: $PROMPT_GUARD_HELPER"
		missing=1
	fi

	if [[ ! -x "$CLAIM_TASK_HELPER" ]]; then
		log_error "Missing required helper: $CLAIM_TASK_HELPER"
		missing=1
	fi

	if [[ ! -x "$APPLE_MAIL_HELPER" ]]; then
		log_error "Missing required helper: $APPLE_MAIL_HELPER"
		missing=1
	fi

	if [[ "$missing" -eq 1 ]]; then
		return 1
	fi

	return 0
}

ensure_config_exists() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		log_error "Config not found: $CONFIG_FILE"
		log_info "Create it with permitted senders before polling"
		return 1
	fi
	return 0
}

extract_email_address() {
	local sender="$1"
	local extracted=""

	if [[ "$sender" =~ \<([^>]*)\> ]]; then
		extracted="${BASH_REMATCH[1]}"
	else
		extracted="$sender"
	fi

	extracted=$(printf '%s' "$extracted" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	printf '%s\n' "$extracted"
	return 0
}

get_sender_permission() {
	local sender="$1"
	local normalized_sender=""

	normalized_sender=$(extract_email_address "$sender")

	local line=""
	line=$(grep -E "^[[:space:]]*${normalized_sender}[[:space:]]*\|" "$CONFIG_FILE" 2>/dev/null || true)
	if [[ -z "$line" ]]; then
		printf '\n'
		return 0
	fi

	local permission=""
	permission=$(printf '%s' "$line" | cut -d'|' -f2 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
	printf '%s\n' "$permission"
	return 0
}

is_permitted_sender() {
	local sender="$1"
	local permission=""

	permission=$(get_sender_permission "$sender")
	if [[ -z "$permission" ]]; then
		return 1
	fi

	return 0
}

is_processed_message() {
	local message_id="$1"
	if grep -Fxq "$message_id" "$PROCESSED_FILE" 2>/dev/null; then
		return 0
	fi
	return 1
}

mark_message_processed() {
	local message_id="$1"
	printf '%s\n' "$message_id" >>"$PROCESSED_FILE"
	return 0
}

has_blocked_attachments() {
	local attachments_csv="$1"
	local normalized_csv=""

	normalized_csv=$(printf '%s' "$attachments_csv" | tr ';' '\n')
	while IFS= read -r attachment_name; do
		[[ -z "$attachment_name" ]] && continue
		local extension="${attachment_name##*.}"
		extension=$(printf '%s' "$extension" | tr '[:upper:]' '[:lower:]')
		local blocked_ext=""
		for blocked_ext in "${BLOCKED_EXTENSIONS[@]}"; do
			if [[ "$extension" == "$blocked_ext" ]]; then
				log_warn "Blocked executable attachment: $attachment_name"
				return 0
			fi
		done
	done <<<"$normalized_csv"

	return 1
}

scan_for_prompt_injection() {
	local subject="$1"
	local body="$2"
	local combined=""

	combined="Subject: ${subject}"$'\n\n'"${body}"
	if printf '%s' "$combined" | "$PROMPT_GUARD_HELPER" scan-stdin >/dev/null 2>&1; then
		return 0
	fi

	return 1
}

classify_request_type() {
	local subject="$1"
	local body="$2"
	local lowered=""

	lowered=$(printf '%s\n%s' "$subject" "$body" | tr '[:upper:]' '[:lower:]')
	if [[ "$lowered" == *"question:"* ]] || [[ "$lowered" == *"q:"* ]] || [[ "$lowered" == *"?"* ]]; then
		printf 'question\n'
		return 0
	fi

	printf 'task\n'
	return 0
}

sanitize_task_title() {
	local subject="$1"
	local cleaned=""

	cleaned=$(printf '%s' "$subject" | sed -E 's/^[[:space:]]*(re:|fw:|fwd:)[[:space:]]*//I')
	cleaned=$(printf '%s' "$cleaned" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
	if [[ -z "$cleaned" ]]; then
		cleaned="Email request"
	fi

	printf '%s\n' "$cleaned"
	return 0
}

build_task_description() {
	local sender="$1"
	local subject="$2"
	local body="$3"
	local trimmed_body=""

	trimmed_body="$body"
	if [[ "${#trimmed_body}" -gt "$MAX_DESCRIPTION_CHARS" ]]; then
		trimmed_body="${trimmed_body:0:$MAX_DESCRIPTION_CHARS}"
	fi

	cat <<EOF
Inbound email command request.

Sender: $sender
Subject: $subject

Body:
$trimmed_body
EOF
	return 0
}

create_task_from_email() {
	local sender="$1"
	local subject="$2"
	local body="$3"
	local dry_run="$4"

	local task_title=""
	local task_description=""
	local output=""
	local task_id=""
	local task_ref=""

	task_title=$(sanitize_task_title "$subject")
	task_description=$(build_task_description "$sender" "$subject" "$body")

	if [[ "$dry_run" == "true" ]]; then
		printf 'DRY_RUN|t000|ref=none\n'
		return 0
	fi

	output=$("$CLAIM_TASK_HELPER" --repo-path "$PWD" --title "$task_title" --description "$task_description" --labels "email,inbound-command" --no-issue 2>/dev/null || true)
	if [[ -z "$output" ]]; then
		return 1
	fi

	task_id=$(printf '%s\n' "$output" | awk -F'=' '/^task_id=/{print $2; exit}')
	task_ref=$(printf '%s\n' "$output" | awk -F'=' '/^ref=/{print $2; exit}')

	if [[ -z "$task_id" ]]; then
		return 1
	fi

	printf 'OK|%s|ref=%s\n' "$task_id" "${task_ref:-none}"
	return 0
}

build_question_answer() {
	local subject="$1"
	local body="$2"
	local lowered=""

	lowered=$(printf '%s\n%s' "$subject" "$body" | tr '[:upper:]' '[:lower:]')

	if [[ "$lowered" == *"status"* ]]; then
		printf 'Status request received. The inbound interface is operational, and your message passed sender verification and injection scanning.\n'
		return 0
	fi

	if [[ "$lowered" == *"help"* ]] || [[ "$lowered" == *"commands"* ]]; then
		printf 'Supported email commands: send TASK requests to create TODO items, or send QUESTION requests for status/help responses.\n'
		return 0
	fi

	printf 'Question received. This interface currently supports operational status/help responses and task creation by email.\n'
	return 0
}

send_reply() {
	local recipient="$1"
	local subject="$2"
	local body="$3"
	local dry_run="$4"

	if [[ "$dry_run" == "true" ]]; then
		log_info "DRY RUN reply to $recipient: $subject"
		return 0
	fi

	if [[ -x "$EMAIL_COMPOSE_HELPER" ]]; then
		"$EMAIL_COMPOSE_HELPER" send --to "$recipient" --subject "$subject" --body "$body" >/dev/null 2>&1 || true
		return 0
	fi

	if [[ -x "$APPLE_MAIL_HELPER" ]]; then
		"$APPLE_MAIL_HELPER" send --to "$recipient" --subject "$subject" --body "$body" >/dev/null
		return 0
	fi

	log_warn "No reply helper available; skipping email reply"
	return 0
}

audit_event() {
	local event_message="$1"
	local sender="$2"
	local subject="$3"

	if [[ -x "$AUDIT_LOG_HELPER" ]]; then
		"$AUDIT_LOG_HELPER" log security.event "$event_message" --detail sender="$sender" --detail subject="$subject" >/dev/null 2>&1 || true
	fi

	return 0
}

escape_applescript_literal() {
	local value="$1"
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	printf '%s\n' "$value"
	return 0
}

fetch_apple_mail_records() {
	local mailbox_name="$1"
	local account_name="$2"
	local limit="$3"
	local escaped_mailbox=""
	local escaped_account=""

	escaped_mailbox=$(escape_applescript_literal "$mailbox_name")
	escaped_account=$(escape_applescript_literal "$account_name")

	osascript <<APPLESCRIPT
set mailboxName to "$escaped_mailbox"
set accountName to "$escaped_account"
set maxCount to $limit
set maxBodyChars to $MAX_BODY_CHARS
set outputText to ""

tell application "Mail"
	if accountName is not "" then
		set targetMailbox to mailbox mailboxName of account accountName
	else
		set targetMailbox to mailbox mailboxName
	end if

	set totalMessages to count of messages of targetMailbox
	if totalMessages < maxCount then
		set maxCount to totalMessages
	end if

	if maxCount > 0 then
		repeat with i from 1 to maxCount
			set msg to item i of messages of targetMailbox
			set msgId to message id of msg as string
			set msgSender to sender of msg as string
			set msgSubject to subject of msg as string
			set msgBody to content of msg as string
			if (length of msgBody) > maxBodyChars then
				set msgBody to text 1 thru maxBodyChars of msgBody
			end if

			set attachmentNames to ""
			repeat with oneAttachment in mail attachments of msg
				set attachmentNames to attachmentNames & (name of oneAttachment as string) & ";"
			end repeat

			set outputText to outputText & msgId & tab & msgSender & tab & msgSubject & tab & attachmentNames & tab & msgBody & linefeed & "$RECORD_DELIMITER" & linefeed
		end repeat
	end if
end tell

return outputText
APPLESCRIPT
	return 0
}

process_message_record() {
	local message_id="$1"
	local sender="$2"
	local subject="$3"
	local attachments_csv="$4"
	local body="$5"
	local dry_run="$6"

	if is_processed_message "$message_id"; then
		log_info "Skipping already processed message: $message_id"
		return 0
	fi

	if ! is_permitted_sender "$sender"; then
		log_warn "Rejected unauthorized sender: $sender"
		audit_event "Unauthorized inbound email command attempt" "$sender" "$subject"
		send_reply "$(extract_email_address "$sender")" "Rejected: $subject" "Your email was rejected because the sender is not in the permitted allowlist." "$dry_run"
		mark_message_processed "$message_id"
		return 0
	fi

	if has_blocked_attachments "$attachments_csv"; then
		log_warn "Rejected message with blocked attachment from $sender"
		audit_event "Blocked executable attachment in inbound command email" "$sender" "$subject"
		send_reply "$(extract_email_address "$sender")" "Rejected: $subject" "Your email was rejected because executable attachments are not allowed." "$dry_run"
		mark_message_processed "$message_id"
		return 0
	fi

	if ! scan_for_prompt_injection "$subject" "$body"; then
		log_warn "Prompt injection findings for message $message_id"
		audit_event "Prompt injection detected in inbound command email" "$sender" "$subject"
		send_reply "$(extract_email_address "$sender")" "Rejected: $subject" "Your email was rejected by the prompt-injection scanner. Please send a clean plain-text request." "$dry_run"
		mark_message_processed "$message_id"
		return 0
	fi

	local request_type=""
	request_type=$(classify_request_type "$subject" "$body")

	if [[ "$request_type" == "task" ]]; then
		local task_result=""
		task_result=$(create_task_from_email "$sender" "$subject" "$body" "$dry_run" || true)
		if [[ -z "$task_result" ]]; then
			send_reply "$(extract_email_address "$sender")" "Failed: $subject" "Your task request could not be created automatically. Please retry with a shorter subject and body." "$dry_run"
			mark_message_processed "$message_id"
			return 0
		fi

		local created_task_id=""
		local created_task_ref=""
		created_task_id=$(printf '%s' "$task_result" | cut -d'|' -f2)
		created_task_ref=$(printf '%s' "$task_result" | cut -d'|' -f3)
		send_reply "$(extract_email_address "$sender")" "Task created: $created_task_id" "Inbound email command accepted. Created $created_task_id ($created_task_ref)." "$dry_run"
		log_success "Created task $created_task_id from message $message_id"
	else
		local answer=""
		answer=$(build_question_answer "$subject" "$body")
		send_reply "$(extract_email_address "$sender")" "Question received: $subject" "$answer" "$dry_run"
		log_success "Answered question from message $message_id"
	fi

	mark_message_processed "$message_id"
	return 0
}

cmd_poll() {
	local mailbox_name="INBOX"
	local account_name=""
	local limit="10"
	local dry_run="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mailbox)
			[[ $# -lt 2 ]] && {
				log_error "--mailbox requires a value"
				return 1
			}
			mailbox_name="$2"
			shift 2
			;;
		--account)
			[[ $# -lt 2 ]] && {
				log_error "--account requires a value"
				return 1
			}
			account_name="$2"
			shift 2
			;;
		--limit)
			[[ $# -lt 2 ]] && {
				log_error "--limit requires a value"
				return 1
			}
			limit="$2"
			shift 2
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
		log_error "--limit must be a positive integer"
		return 1
	fi

	local records
	records=$(fetch_apple_mail_records "$mailbox_name" "$account_name" "$limit" 2>/dev/null || true)
	if [[ -z "$records" ]]; then
		log_info "No messages found in mailbox '$mailbox_name'"
		return 0
	fi

	local record_buffer=""
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "$RECORD_DELIMITER" ]]; then
			if [[ -n "$record_buffer" ]]; then
				local message_id=""
				local sender=""
				local subject=""
				local attachments_csv=""
				local body=""

				message_id="${record_buffer%%$'\t'*}"
				local remainder="${record_buffer#*$'\t'}"
				sender="${remainder%%$'\t'*}"
				remainder="${remainder#*$'\t'}"
				subject="${remainder%%$'\t'*}"
				remainder="${remainder#*$'\t'}"
				attachments_csv="${remainder%%$'\t'*}"
				body="${remainder#*$'\t'}"

				process_message_record "$message_id" "$sender" "$subject" "$attachments_csv" "$body" "$dry_run"
				record_buffer=""
			fi
			continue
		fi

		if [[ -z "$record_buffer" ]]; then
			record_buffer="$line"
		else
			record_buffer+=$'\n'"$line"
		fi
	done <<<"$records"

	return 0
}

cmd_sender_check() {
	local sender="${1:-}"
	if [[ -z "$sender" ]]; then
		log_error "Usage: $0 sender-check <email>"
		return 1
	fi

	local permission=""
	permission=$(get_sender_permission "$sender")
	if [[ -z "$permission" ]]; then
		printf 'DENIED\n'
		return 1
	fi

	printf 'ALLOWED|%s\n' "$permission"
	return 0
}

show_help() {
	cat <<'EOF'
email-inbound-command-helper.sh - Inbound email command interface

Usage:
  email-inbound-command-helper.sh poll [--mailbox INBOX] [--account NAME] [--limit N] [--dry-run]
  email-inbound-command-helper.sh sender-check <email>
  email-inbound-command-helper.sh help

What it does:
  - Polls mailbox messages via Apple Mail
  - Accepts only permitted senders from config allowlist
  - Rejects executable attachments
  - Runs mandatory prompt injection scan on subject+body
  - Creates tasks via claim-task-id.sh for task requests
  - Sends confirmation/rejection replies

Config:
  ~/.config/aidevops/email-inbound-commands.conf
  Format per line: sender@example.com|permission|description
  Permissions: admin, operator, reporter, readonly

Notes:
  - No executable attachments are processed, ever
  - Prompt injection scan is mandatory on every processed email
EOF
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	init_state

	case "$command" in
	poll)
		check_dependencies
		ensure_config_exists
		cmd_poll "$@"
		;;
	sender-check)
		ensure_config_exists
		cmd_sender_check "$@"
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

	return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
