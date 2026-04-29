#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Email Agent Send -- Email sending via AWS SES
# =============================================================================
# Provides argument parsing, content resolution, conversation management,
# and both standard and reply sending via AWS SES.
#
# Usage: source "${SCRIPT_DIR}/email-agent-helper-send.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_success, etc.)
#   - email-agent-helper-core.sh (db, sql_escape, generate_id, render_template, etc.)
#   - Constants from email-agent-helper.sh orchestrator (DB_FILE, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_EMAIL_AGENT_SEND_LIB_LOADED:-}" ]] && return 0
_EMAIL_AGENT_SEND_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ============================================================================
# Send command — helpers
# ============================================================================

# Parse arguments for cmd_send. Outputs: mission_id|to_email|template_file|vars_string|subject|body|from_email|reply_to_msg
_send_parse_args() {
	local mission_id="" to_email="" template_file="" vars_string=""
	local subject="" body="" from_email="" reply_to_msg=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--mission)
			[[ $# -lt 2 ]] && {
				print_error "--mission requires a value"
				return 1
			}
			mission_id="$2"
			shift 2
			;;
		--to)
			[[ $# -lt 2 ]] && {
				print_error "--to requires a value"
				return 1
			}
			to_email="$2"
			shift 2
			;;
		--template)
			[[ $# -lt 2 ]] && {
				print_error "--template requires a value"
				return 1
			}
			template_file="$2"
			shift 2
			;;
		--vars)
			[[ $# -lt 2 ]] && {
				print_error "--vars requires a value"
				return 1
			}
			vars_string="$2"
			shift 2
			;;
		--subject)
			[[ $# -lt 2 ]] && {
				print_error "--subject requires a value"
				return 1
			}
			subject="$2"
			shift 2
			;;
		--body)
			[[ $# -lt 2 ]] && {
				print_error "--body requires a value"
				return 1
			}
			body="$2"
			shift 2
			;;
		--from)
			[[ $# -lt 2 ]] && {
				print_error "--from requires a value"
				return 1
			}
			from_email="$2"
			shift 2
			;;
		--reply-to)
			[[ $# -lt 2 ]] && {
				print_error "--reply-to requires a value"
				return 1
			}
			reply_to_msg="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$mission_id" "$to_email" "$template_file" "$vars_string" \
		"$subject" "$body" "$from_email" "$reply_to_msg"
	return 0
}

# Resolve subject and body from template or direct args.
# Sets _subject and _body in caller's scope via output vars passed by name.
# Usage: _send_resolve_content template_file vars_string subject_ref body_ref
_send_resolve_content() {
	local template_file="$1"
	local vars_string="$2"
	local subject_in="$3"
	local body_in="$4"

	local subject="$subject_in"
	local body="$body_in"

	if [[ -n "$template_file" ]]; then
		local rendered
		rendered=$(render_template "$template_file" "$vars_string")
		if [[ -z "$subject" ]]; then
			subject=$(echo "$rendered" | grep -m1 '^Subject: ' | sed 's/^Subject: //' || echo "Mission Communication")
		fi
		if [[ -z "$body" ]]; then
			body=$(extract_template_body "$rendered")
		fi
	fi

	printf '%s\t%s' "$subject" "$body"
	return 0
}

# Find existing conversation by reply reference, or create a new one.
# Outputs conv_id.
_send_find_or_create_conv() {
	local mission_id="$1"
	local subject="$2"
	local to_email="$3"
	local from_email="$4"
	local reply_to_msg="$5"

	local conv_id=""
	if [[ -n "$reply_to_msg" ]]; then
		conv_id=$(db "$DB_FILE" "
			SELECT conv_id FROM messages
			WHERE message_id = '$(sql_escape "$reply_to_msg")' OR id = '$(sql_escape "$reply_to_msg")'
			LIMIT 1;
		")
	fi

	if [[ -z "$conv_id" ]]; then
		conv_id=$(generate_id "conv")
		db "$DB_FILE" "
			INSERT INTO conversations (id, mission_id, subject, to_email, from_email, status)
			VALUES ('$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', '$(sql_escape "$subject")', '$(sql_escape "$to_email")', '$(sql_escape "$from_email")', 'active');
		"
	fi

	echo "$conv_id"
	return 0
}

# Send a reply using SES send-raw-email (adds In-Reply-To/References headers).
# Outputs the new message ID on success.
_send_reply_raw() {
	local mission_id="$1"
	local conv_id="$2"
	local from_email="$3"
	local to_email="$4"
	local subject="$5"
	local body="$6"
	local reply_to_msg="$7"

	local original_message_id
	original_message_id=$(db "$DB_FILE" "
		SELECT message_id FROM messages
		WHERE id = '$(sql_escape "$reply_to_msg")' OR message_id = '$(sql_escape "$reply_to_msg")'
		LIMIT 1;
	")
	[[ -z "$original_message_id" ]] && return 1

	# SES doesn't support custom headers in basic send-email; use send-raw-email
	local raw_message
	raw_message=$(printf 'From: %s\r\nTo: %s\r\nSubject: %s\r\nIn-Reply-To: %s\r\nReferences: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s' \
		"$from_email" "$to_email" "$subject" "$original_message_id" "$original_message_id" "$body")

	local encoded_message
	encoded_message=$(printf '%s' "$raw_message" | base64 | tr -d '\n')

	local ses_result
	ses_result=$(aws ses send-raw-email \
		--raw-message "Data=$encoded_message" \
		--query 'MessageId' --output text 2>&1) || {
		print_error "Failed to send email: $ses_result"
		return 1
	}

	local msg_id
	msg_id=$(generate_id "msg")
	db "$DB_FILE" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text, ses_message_id, in_reply_to)
		VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', 'outbound', '$(sql_escape "$from_email")', '$(sql_escape "$to_email")', '$(sql_escape "$subject")', '$(sql_escape "$body")', '$(sql_escape "$ses_result")', '$(sql_escape "$original_message_id")');
	"
	db "$DB_FILE" "
		UPDATE conversations SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), status = 'waiting'
		WHERE id = '$(sql_escape "$conv_id")';
	"

	print_success "Sent reply: $msg_id (SES: $ses_result) in conversation $conv_id"
	echo "$msg_id"
	return 0
}

# Send a standard (non-reply) email via SES send-email.
# Outputs the new message ID on success.
_send_standard() {
	local mission_id="$1"
	local conv_id="$2"
	local from_email="$3"
	local to_email="$4"
	local subject="$5"
	local body="$6"

	# Build JSON input for safe escaping of all characters
	local ses_input_json ses_tmpfile
	ses_input_json=$(jq -n \
		--arg from "$from_email" \
		--arg to "$to_email" \
		--arg subject "$subject" \
		--arg body "$body" \
		'{
			Source: $from,
			Destination: { ToAddresses: [$to] },
			Message: {
				Subject: { Data: $subject },
				Body: { Text: { Data: $body } }
			}
		}')
	ses_tmpfile=$(mktemp)
	printf '%s' "$ses_input_json" >"$ses_tmpfile"

	local ses_result
	ses_result=$(aws ses send-email \
		--cli-input-json "file://${ses_tmpfile}" \
		--query 'MessageId' --output text 2>&1) || {
		rm -f "$ses_tmpfile"
		print_error "Failed to send email: $ses_result"
		return 1
	}
	rm -f "$ses_tmpfile"

	local msg_id
	msg_id=$(generate_id "msg")
	db "$DB_FILE" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text, ses_message_id)
		VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', 'outbound', '$(sql_escape "$from_email")', '$(sql_escape "$to_email")', '$(sql_escape "$subject")', '$(sql_escape "$body")', '$(sql_escape "$ses_result")');
	"
	db "$DB_FILE" "
		UPDATE conversations SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), status = 'waiting'
		WHERE id = '$(sql_escape "$conv_id")';
	"

	print_success "Sent: $msg_id (SES: $ses_result) in conversation $conv_id"
	echo "$msg_id"
	return 0
}

# ============================================================================
# Send command
# ============================================================================

cmd_send() {
	local parsed
	parsed=$(_send_parse_args "$@") || return 1

	local mission_id to_email template_file vars_string subject body from_email reply_to_msg
	IFS='|' read -r mission_id to_email template_file vars_string subject body from_email reply_to_msg <<<"$parsed"

	if [[ -z "$mission_id" ]]; then
		print_error "Mission ID is required (--mission M001)"
		return 1
	fi
	if [[ -z "$to_email" ]]; then
		print_error "Recipient email is required (--to user@example.com)"
		return 1
	fi

	check_dependencies || return 1
	load_config || return 1
	set_aws_credentials || return 1
	ensure_db

	# Resolve from address
	if [[ -z "$from_email" ]]; then
		from_email=$(get_config_value '.default_from_email' '')
		if [[ -z "$from_email" ]]; then
			print_error "No from address. Set --from or configure default_from_email in config"
			return 1
		fi
	fi

	# Resolve subject/body from template or direct args
	local resolved
	resolved=$(_send_resolve_content "$template_file" "$vars_string" "$subject" "$body")
	subject="${resolved%%	*}"
	body="${resolved#*	}"

	if [[ -z "$subject" ]]; then
		print_error "Subject is required (--subject or template with Subject: header)"
		return 1
	fi
	if [[ -z "$body" ]]; then
		print_error "Body is required (--body or --template)"
		return 1
	fi

	local conv_id
	conv_id=$(_send_find_or_create_conv "$mission_id" "$subject" "$to_email" "$from_email" "$reply_to_msg") || return 1

	# Send as reply (with threading headers) or standard
	if [[ -n "$reply_to_msg" ]]; then
		local reply_msg_id
		reply_msg_id=$(_send_reply_raw "$mission_id" "$conv_id" "$from_email" "$to_email" "$subject" "$body" "$reply_to_msg") || {
			# reply_to_msg not found in DB — fall through to standard send
			true
		}
		if [[ -n "${reply_msg_id:-}" ]]; then
			echo "$reply_msg_id"
			return 0
		fi
	fi

	_send_standard "$mission_id" "$conv_id" "$from_email" "$to_email" "$subject" "$body"
	return 0
}
