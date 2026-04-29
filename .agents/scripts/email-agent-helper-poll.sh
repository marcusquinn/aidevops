#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Email Agent Poll -- Email retrieval from S3 and ingestion
# =============================================================================
# Provides S3 polling, email parsing, conversation threading for inbound
# emails, and automatic code extraction on ingest.
#
# Usage: source "${SCRIPT_DIR}/email-agent-helper-poll.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, log_info, etc.)
#   - email-agent-helper-core.sh (db, sql_escape, generate_id, etc.)
#   - email-agent-helper-commands.sh (extract_codes_from_text — called on ingest)
#   - Constants from email-agent-helper.sh orchestrator (DB_FILE, EMAIL_TO_MD_SCRIPT, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_EMAIL_AGENT_POLL_LIB_LOADED:-}" ]] && return 0
_EMAIL_AGENT_POLL_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ============================================================================
# Poll command helpers
# ============================================================================

# Parse --since date argument. Outputs normalized ISO 8601 date or empty string.
_poll_parse_since() {
	local raw_since="$1"
	local since=""

	if since=$(date -d "$raw_since" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
		: # GNU date succeeded
	elif since=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$raw_since" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
		: # BSD date with full ISO format
	elif since=$(date -j -u -f '%Y-%m-%d' "$raw_since" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
		: # BSD date with date-only format
	else
		print_error "Invalid date format for --since: '$raw_since' (expected ISO 8601, e.g. 2026-01-15T00:00:00Z or 2026-01-15)"
		return 1
	fi

	echo "$since"
	return 0
}

# Parse email fields from a local .eml file.
# Tries python3 parser first; falls back to grep-based header extraction.
# Outputs: from_addr|to_addr|subj|msg_id_header|in_reply_to|body_text (tab-separated body)
_poll_parse_email() {
	local local_file="$1"

	local parsed_json=""
	if [[ -x "$EMAIL_TO_MD_SCRIPT" ]] && command -v python3 &>/dev/null; then
		parsed_json=$(python3 "$EMAIL_TO_MD_SCRIPT" "$local_file" --json 2>/dev/null || echo "")
	fi

	local from_addr="" to_addr="" subj="" msg_id_header="" in_reply_to="" body_text=""
	if [[ -n "$parsed_json" ]]; then
		from_addr=$(echo "$parsed_json" | jq -r '.from // empty' 2>/dev/null)
		to_addr=$(echo "$parsed_json" | jq -r '.to // empty' 2>/dev/null)
		subj=$(echo "$parsed_json" | jq -r '.subject // empty' 2>/dev/null)
		msg_id_header=$(echo "$parsed_json" | jq -r '.message_id // empty' 2>/dev/null)
		in_reply_to=$(echo "$parsed_json" | jq -r '.in_reply_to // empty' 2>/dev/null)
		body_text=$(echo "$parsed_json" | jq -r '.body_text // empty' 2>/dev/null)
	else
		# Fallback: grep headers from raw .eml
		from_addr=$(grep -m1 -i '^From: ' "$local_file" 2>/dev/null | sed 's/^[Ff]rom: //' || echo "unknown")
		to_addr=$(grep -m1 -i '^To: ' "$local_file" 2>/dev/null | sed 's/^[Tt]o: //' || echo "unknown")
		subj=$(grep -m1 -i '^Subject: ' "$local_file" 2>/dev/null | sed 's/^[Ss]ubject: //' || echo "(no subject)")
		msg_id_header=$(grep -m1 -i '^Message-ID: ' "$local_file" 2>/dev/null | sed 's/^[Mm]essage-[Ii][Dd]: //' || echo "")
		in_reply_to=$(grep -m1 -i '^In-Reply-To: ' "$local_file" 2>/dev/null | sed 's/^[Ii]n-[Rr]eply-[Tt]o: //' || echo "")
		# Extract body (everything after first blank line)
		body_text=$(sed -n '/^$/,$ { /^$/d; p; }' "$local_file" 2>/dev/null | head -200 || echo "")
	fi

	printf '%s|%s|%s|%s|%s\t%s' \
		"$from_addr" "$to_addr" "$subj" "$msg_id_header" "$in_reply_to" "$body_text"
	return 0
}

# Find or create a conversation for an inbound message.
# Outputs conv_id.
_poll_find_or_create_conv() {
	local mission_id="$1"
	local from_addr="$2"
	local to_addr="$3"
	local subj="$4"
	local in_reply_to="$5"

	local conv_id=""
	if [[ -n "$in_reply_to" ]]; then
		conv_id=$(db "$DB_FILE" "
			SELECT conv_id FROM messages
			WHERE (message_id = '$(sql_escape "$in_reply_to")' OR ses_message_id = '$(sql_escape "$in_reply_to")')
			AND mission_id = '$(sql_escape "$mission_id")'
			LIMIT 1;
		")
	fi

	if [[ -z "$conv_id" ]]; then
		# Try matching by subject (strip Re:/Fwd: prefixes) and email address
		local clean_subject
		clean_subject=$(echo "$subj" | sed -E 's/^(Re|Fwd|FW|Fw): *//gi')
		conv_id=$(db "$DB_FILE" "
			SELECT id FROM conversations
			WHERE mission_id = '$(sql_escape "$mission_id")'
			AND (to_email = '$(sql_escape "$from_addr")' OR from_email = '$(sql_escape "$from_addr")')
			AND subject LIKE '%$(sql_escape "$clean_subject")%'
			LIMIT 1;
		")
	fi

	if [[ -z "$conv_id" ]]; then
		conv_id=$(generate_id "conv")
		db "$DB_FILE" "
			INSERT INTO conversations (id, mission_id, subject, to_email, from_email, status)
			VALUES ('$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', '$(sql_escape "$subj")', '$(sql_escape "$to_addr")', '$(sql_escape "$from_addr")', 'active');
		"
	fi

	echo "$conv_id"
	return 0
}

# Store an inbound message in the database and auto-extract codes.
# Outputs the new message ID.
_poll_ingest_message() {
	local mission_id="$1"
	local conv_id="$2"
	local from_addr="$3"
	local to_addr="$4"
	local subj="$5"
	local body_text="$6"
	local msg_id_header="$7"
	local in_reply_to="$8"
	local s3_key="$9"
	local local_file="${10}"

	local ea_msg_id
	ea_msg_id=$(generate_id "msg")
	db "$DB_FILE" "
		INSERT INTO messages (id, conv_id, mission_id, direction, from_email, to_email, subject, body_text, message_id, in_reply_to, s3_key, raw_path)
		VALUES ('$(sql_escape "$ea_msg_id")', '$(sql_escape "$conv_id")', '$(sql_escape "$mission_id")', 'inbound', '$(sql_escape "$from_addr")', '$(sql_escape "$to_addr")', '$(sql_escape "$subj")', '$(sql_escape "$body_text")', '$(sql_escape "$msg_id_header")', '$(sql_escape "$in_reply_to")', '$(sql_escape "$s3_key")', '$(sql_escape "$local_file")');
	"
	db "$DB_FILE" "
		UPDATE conversations SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now'), status = 'active'
		WHERE id = '$(sql_escape "$conv_id")';
	"

	extract_codes_from_text "$ea_msg_id" "$mission_id" "$body_text"

	echo "$ea_msg_id"
	return 0
}

# Process a single S3 key: skip-if-seen, date-filter, download, parse, ingest.
# Returns 0 if ingested, 1 if skipped/failed.
# Outputs the new message ID on success.
_poll_process_key() {
	local mission_id="$1"
	local s3_key="$2"
	local s3_bucket="$3"
	local since="$4"
	local objects_json="$5"
	local download_dir="$6"

	# Skip if already ingested
	local already_exists
	already_exists=$(db "$DB_FILE" "SELECT count(*) FROM messages WHERE s3_key = '$(sql_escape "$s3_key")';")
	if [[ "$already_exists" -gt 0 ]]; then
		return 1
	fi

	# Filter by date if --since specified
	if [[ -n "$since" ]]; then
		local obj_date
		obj_date=$(echo "$objects_json" | jq -r --arg s3_key "$s3_key" '.Contents[] | select(.Key == $s3_key) | .LastModified' 2>/dev/null)
		if [[ -n "$obj_date" && "$obj_date" < "$since" ]]; then
			return 1
		fi
	fi

	# Download the email
	local local_file
	local_file="${download_dir}/$(basename "$s3_key")"
	aws s3 cp "s3://${s3_bucket}/${s3_key}" "$local_file" --quiet 2>/dev/null || {
		print_warning "Failed to download: $s3_key"
		return 1
	}

	# Parse the email (pipe-separated fields; body_text after tab)
	local parsed_fields
	parsed_fields=$(_poll_parse_email "$local_file")
	local pipe_part="${parsed_fields%%	*}"
	local body_text="${parsed_fields#*	}"

	local from_addr to_addr subj msg_id_header in_reply_to
	IFS='|' read -r from_addr to_addr subj msg_id_header in_reply_to <<<"$pipe_part"

	local conv_id
	conv_id=$(_poll_find_or_create_conv "$mission_id" "$from_addr" "$to_addr" "$subj" "$in_reply_to") || return 1

	local ea_msg_id
	ea_msg_id=$(_poll_ingest_message "$mission_id" "$conv_id" \
		"$from_addr" "$to_addr" "$subj" "$body_text" \
		"$msg_id_header" "$in_reply_to" "$s3_key" "$local_file") || return 1

	log_info "Ingested: $ea_msg_id from $from_addr (conv: $conv_id)"
	echo "$ea_msg_id"
	return 0
}

# ============================================================================
# Poll command — retrieve new emails from S3
# ============================================================================

cmd_poll() {
	local mission_id="" since=""

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
		--since)
			[[ $# -lt 2 ]] && {
				print_error "--since requires a value"
				return 1
			}
			since=$(_poll_parse_since "$2") || return 1
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mission_id" ]]; then
		print_error "Mission ID is required (--mission M001)"
		return 1
	fi

	check_dependencies || return 1
	load_config || return 1
	set_aws_credentials || return 1
	ensure_db

	local s3_bucket
	s3_bucket=$(get_config_value '.s3_receive_bucket' '')
	if [[ -z "$s3_bucket" ]]; then
		print_error "S3 receive bucket not configured. Set s3_receive_bucket in config"
		return 1
	fi

	local s3_prefix
	s3_prefix=$(get_config_value '.s3_receive_prefix' 'incoming/')

	local download_dir="${WORKSPACE_DIR}/inbox/${mission_id}"
	mkdir -p "$download_dir"

	local objects_json
	objects_json=$(aws s3api list-objects-v2 --bucket "$s3_bucket" --prefix "$s3_prefix" --output json 2>/dev/null) || {
		print_error "Failed to list S3 objects in $s3_bucket/$s3_prefix"
		return 1
	}

	local object_count
	object_count=$(echo "$objects_json" | jq -r '.KeyCount // 0')
	if [[ "$object_count" -eq 0 ]]; then
		print_info "No new emails in $s3_bucket/$s3_prefix"
		return 0
	fi

	local ingested=0
	local keys
	keys=$(echo "$objects_json" | jq -r '.Contents[]?.Key // empty')

	while IFS= read -r s3_key; do
		[[ -z "$s3_key" ]] && continue
		if _poll_process_key "$mission_id" "$s3_key" "$s3_bucket" "$since" "$objects_json" "$download_dir" >/dev/null; then
			ingested=$((ingested + 1))
		fi
	done <<<"$keys"

	if [[ "$ingested" -gt 0 ]]; then
		print_success "Polled $ingested new emails for mission $mission_id"
	else
		print_info "No new emails for mission $mission_id"
	fi

	return 0
}
