#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Email Agent Commands -- Code extraction, threads, conversations, and status
# =============================================================================
# Provides verification code extraction from email text, conversation thread
# display, conversation listing, and status reporting commands.
#
# Usage: source "${SCRIPT_DIR}/email-agent-helper-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, log_info, etc.)
#   - email-agent-helper-core.sh (db, sql_escape, generate_id, ensure_db)
#   - Constants from email-agent-helper.sh orchestrator (DB_FILE, CODE_PATTERNS, LINK_PATTERNS, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_EMAIL_AGENT_COMMANDS_LIB_LOADED:-}" ]] && return 0
_EMAIL_AGENT_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ============================================================================
# Verification code extraction
# ============================================================================

# Extract codes from text and store in database
extract_codes_from_text() {
	local msg_id="$1"
	local mission_id="$2"
	local text="$3"

	[[ -z "$text" ]] && return 0

	local found=0

	# Check OTP/code patterns
	local pattern
	for pattern in "${CODE_PATTERNS[@]}"; do
		local matches
		matches=$(echo "$text" | grep -oE "$pattern" 2>/dev/null || true)
		if [[ -n "$matches" ]]; then
			while IFS= read -r match; do
				[[ -z "$match" ]] && continue
				# Extract just the code value — strip leading label (e.g. "Code: ", "Token is ")
				# then require at least one digit to avoid matching keywords
				local code_value normalized
				normalized=$(echo "$match" | sed -E 's/^[[:alpha:]][[:alpha:] ]*(:[[:space:]]*|[[:space:]]+is[[:space:]]+)//')
				code_value=$(echo "$normalized" | grep -oE '[0-9A-Za-z_-]{4,}' | grep '[0-9]' | head -1 || echo "")
				if [[ -z "$code_value" ]]; then
					# Fallback: try extracting pure digit sequences
					code_value=$(echo "$match" | grep -oE '[0-9]{4,}' | head -1 || echo "")
				fi
				[[ -z "$code_value" ]] && continue

				local code_type="otp"
				if echo "$match" | grep -qi 'token'; then
					code_type="token"
				elif echo "$match" | grep -qi 'api.key\|apikey'; then
					code_type="api_key"
				elif echo "$match" | grep -qi 'password\|passwd'; then
					code_type="password"
				fi

				# Avoid duplicates
				local exists
				exists=$(db "$DB_FILE" "
					SELECT count(*) FROM extracted_codes
					WHERE message_id = '$(sql_escape "$msg_id")' AND code_value = '$(sql_escape "$code_value")';
				")
				if [[ "$exists" -eq 0 ]]; then
					db "$DB_FILE" "
						INSERT INTO extracted_codes (message_id, mission_id, code_type, code_value, confidence)
						VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$mission_id")', '$(sql_escape "$code_type")', '$(sql_escape "$code_value")', 0.9);
					"
					found=$((found + 1))
					log_info "Extracted $code_type: ${code_value:0:4}*** from $msg_id"
				fi
			done <<<"$matches"
		fi
	done

	# Check confirmation/activation link patterns
	local link_pattern
	for link_pattern in "${LINK_PATTERNS[@]}"; do
		local link_matches
		link_matches=$(echo "$text" | grep -oE "$link_pattern" 2>/dev/null || true)
		if [[ -n "$link_matches" ]]; then
			while IFS= read -r link; do
				[[ -z "$link" ]] && continue

				local exists
				exists=$(db "$DB_FILE" "
					SELECT count(*) FROM extracted_codes
					WHERE message_id = '$(sql_escape "$msg_id")' AND code_value = '$(sql_escape "$link")';
				")
				if [[ "$exists" -eq 0 ]]; then
					db "$DB_FILE" "
						INSERT INTO extracted_codes (message_id, mission_id, code_type, code_value, confidence)
						VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$mission_id")', 'link', '$(sql_escape "$link")', 0.85);
					"
					found=$((found + 1))
					log_info "Extracted confirmation link from $msg_id"
				fi
			done <<<"$link_matches"
		fi
	done

	if [[ "$found" -gt 0 ]]; then
		print_success "Extracted $found codes/links from message $msg_id"
	fi

	return 0
}

# Display extracted codes from the database for a given WHERE clause.
_extract_codes_display() {
	local where_clause="$1"

	local codes
	codes=$(db -separator '|' "$DB_FILE" "
		SELECT code_type, code_value, confidence, used, created_at
		FROM extracted_codes ${where_clause}
		ORDER BY created_at DESC;
	")

	if [[ -n "$codes" ]]; then
		echo ""
		echo "Extracted Codes:"
		echo "================"
		while IFS='|' read -r ctype cval conf used created; do
			local status_label="available"
			if [[ "$used" -eq 1 ]]; then
				status_label="used"
			fi
			# Mask sensitive values
			local display_val
			if [[ ${#cval} -gt 8 ]]; then
				display_val="${cval:0:4}...${cval: -4}"
			else
				display_val="${cval:0:2}****"
			fi
			echo "  [$ctype] $display_val (confidence: $conf, $status_label, $created)"
		done <<<"$codes"
	fi

	return 0
}

cmd_extract_codes() {
	local message_id="" mission_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--message)
			[[ $# -lt 2 ]] && {
				print_error "--message requires a value"
				return 1
			}
			message_id="$2"
			shift 2
			;;
		--mission)
			[[ $# -lt 2 ]] && {
				print_error "--mission requires a value"
				return 1
			}
			mission_id="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	if [[ -n "$message_id" ]]; then
		# Extract from specific message
		local body_text
		body_text=$(db "$DB_FILE" "SELECT body_text FROM messages WHERE id = '$(sql_escape "$message_id")';")
		if [[ -z "$body_text" ]]; then
			print_error "Message not found: $message_id"
			return 1
		fi
		local msg_mission
		msg_mission=$(db "$DB_FILE" "SELECT mission_id FROM messages WHERE id = '$(sql_escape "$message_id")';")
		extract_codes_from_text "$message_id" "$msg_mission" "$body_text"
	elif [[ -n "$mission_id" ]]; then
		# Extract from all unprocessed messages in mission
		# Fetch IDs only — body_text may contain pipes and newlines that break
		# pipe-separated parsing, so we fetch each body in a separate query.
		local message_ids
		message_ids=$(db "$DB_FILE" "
			SELECT m.id FROM messages m
			LEFT JOIN extracted_codes ec ON m.id = ec.message_id
			WHERE m.mission_id = '$(sql_escape "$mission_id")'
			AND m.direction = 'inbound'
			AND ec.id IS NULL
			AND m.body_text IS NOT NULL;
		")
		if [[ -z "$message_ids" ]]; then
			print_info "No unprocessed inbound messages for mission $mission_id"
			return 0
		fi
		while IFS= read -r mid; do
			[[ -z "$mid" ]] && continue
			local body
			body=$(db "$DB_FILE" "SELECT body_text FROM messages WHERE id = '$(sql_escape "$mid")';")
			extract_codes_from_text "$mid" "$mission_id" "$body"
		done <<<"$message_ids"
	else
		print_error "Specify --message <id> or --mission <id>"
		return 1
	fi

	# Show extracted codes
	local where_clause=""
	if [[ -n "$mission_id" ]]; then
		where_clause="WHERE mission_id = '$(sql_escape "$mission_id")'"
	elif [[ -n "$message_id" ]]; then
		where_clause="WHERE message_id = '$(sql_escape "$message_id")'"
	fi

	_extract_codes_display "$where_clause"
	return 0
}

# ============================================================================
# Thread command helpers
# ============================================================================

# Display a single conversation thread (messages + extracted codes).
_thread_show_conversation() {
	local conv_id="$1"

	local conv_info
	conv_info=$(db -separator '|' "$DB_FILE" "
		SELECT id, mission_id, subject, to_email, from_email, status, created_at
		FROM conversations WHERE id = '$(sql_escape "$conv_id")';
	")
	if [[ -z "$conv_info" ]]; then
		print_error "Conversation not found: $conv_id"
		return 1
	fi

	local cid cmission csubject cto cfrom cstatus ccreated
	IFS='|' read -r cid cmission csubject cto cfrom cstatus ccreated <<<"$conv_info"

	echo "Conversation: $cid"
	echo "  Mission:  $cmission"
	echo "  Subject:  $csubject"
	echo "  Between:  $cfrom <-> $cto"
	echo "  Status:   $cstatus"
	echo "  Started:  $ccreated"
	echo ""
	echo "Messages:"
	echo "---------"

	local messages
	messages=$(db -separator '|' "$DB_FILE" "
		SELECT id, direction, from_email, subject, created_at,
			   substr(body_text, 1, 200) as preview
		FROM messages
		WHERE conv_id = '$(sql_escape "$conv_id")'
		ORDER BY created_at ASC;
	")

	if [[ -n "$messages" ]]; then
		while IFS='|' read -r mid mdir mfrom msubj mcreated mpreview; do
			local arrow="<-"
			if [[ "$mdir" == "outbound" ]]; then
				arrow="->"
			fi
			echo "  [$mcreated] $arrow $mfrom"
			echo "    Subject: $msubj"
			if [[ -n "$mpreview" ]]; then
				echo "    Preview: ${mpreview:0:120}..."
			fi
			echo ""
		done <<<"$messages"
	else
		echo "  (no messages)"
	fi

	# Show extracted codes for this conversation
	local codes
	codes=$(db -separator '|' "$DB_FILE" "
		SELECT ec.code_type, ec.code_value, ec.confidence, ec.used
		FROM extracted_codes ec
		JOIN messages m ON ec.message_id = m.id
		WHERE m.conv_id = '$(sql_escape "$conv_id")'
		ORDER BY ec.created_at DESC;
	")
	if [[ -n "$codes" ]]; then
		echo "Extracted Codes:"
		while IFS='|' read -r ctype cval conf used; do
			local display_val
			if [[ ${#cval} -gt 8 ]]; then
				display_val="${cval:0:4}...${cval: -4}"
			else
				display_val="${cval:0:2}****"
			fi
			local status_label="available"
			if [[ "$used" -eq 1 ]]; then
				status_label="used"
			fi
			echo "  [$ctype] $display_val ($status_label)"
		done <<<"$codes"
	fi

	return 0
}

# ============================================================================
# Thread / conversation commands
# ============================================================================

cmd_thread() {
	local mission_id="" conv_id=""

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
		--conversation)
			[[ $# -lt 2 ]] && {
				print_error "--conversation requires a value"
				return 1
			}
			conv_id="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$mission_id" && -z "$conv_id" ]]; then
		print_error "Specify --mission <id> or --conversation <id>"
		return 1
	fi

	ensure_db

	if [[ -n "$conv_id" ]]; then
		_thread_show_conversation "$conv_id"
	else
		cmd_conversations "--mission" "$mission_id"
	fi

	return 0
}

cmd_conversations() {
	local mission_id=""

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

	ensure_db

	local conversations
	conversations=$(db -separator '|' "$DB_FILE" "
		SELECT c.id, c.subject, c.to_email, c.from_email, c.status, c.created_at, c.updated_at,
			   (SELECT count(*) FROM messages WHERE conv_id = c.id) as msg_count,
			   (SELECT count(*) FROM extracted_codes ec JOIN messages m ON ec.message_id = m.id WHERE m.conv_id = c.id) as code_count
		FROM conversations c
		WHERE c.mission_id = '$(sql_escape "$mission_id")'
		ORDER BY c.updated_at DESC;
	")

	if [[ -z "$conversations" ]]; then
		print_info "No conversations for mission $mission_id"
		return 0
	fi

	echo "Conversations for mission $mission_id:"
	echo "========================================"
	while IFS='|' read -r cid csubject cto cfrom cstatus ccreated cupdated msg_count code_count; do
		echo "  [$cstatus] $cid"
		echo "    Subject:  $csubject"
		echo "    With:     $cto <-> $cfrom"
		echo "    Messages: $msg_count | Codes: $code_count"
		echo "    Updated:  $cupdated"
		echo ""
	done <<<"$conversations"

	return 0
}

# ============================================================================
# Status command
# ============================================================================

cmd_status() {
	local mission_id=""

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
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	if [[ -n "$mission_id" ]]; then
		local conv_count msg_count code_count
		conv_count=$(db "$DB_FILE" "SELECT count(*) FROM conversations WHERE mission_id = '$(sql_escape "$mission_id")';")
		msg_count=$(db "$DB_FILE" "SELECT count(*) FROM messages WHERE mission_id = '$(sql_escape "$mission_id")';")
		code_count=$(db "$DB_FILE" "SELECT count(*) FROM extracted_codes WHERE mission_id = '$(sql_escape "$mission_id")';")

		local waiting_count
		waiting_count=$(db "$DB_FILE" "SELECT count(*) FROM conversations WHERE mission_id = '$(sql_escape "$mission_id")' AND status = 'waiting';")

		echo "Email Agent Status (Mission: $mission_id)"
		echo "==========================================="
		echo "  Conversations: $conv_count ($waiting_count awaiting response)"
		echo "  Messages:      $msg_count"
		echo "  Codes found:   $code_count"
	else
		local total_conv total_msg total_codes
		total_conv=$(db "$DB_FILE" "SELECT count(*) FROM conversations;")
		total_msg=$(db "$DB_FILE" "SELECT count(*) FROM messages;")
		total_codes=$(db "$DB_FILE" "SELECT count(*) FROM extracted_codes;")

		local missions
		missions=$(db "$DB_FILE" "SELECT DISTINCT mission_id FROM conversations ORDER BY mission_id;")

		echo "Email Agent Status (All Missions)"
		echo "==================================="
		echo "  Total conversations: $total_conv"
		echo "  Total messages:      $total_msg"
		echo "  Total codes found:   $total_codes"
		echo "  Database:            $DB_FILE"

		if [[ -n "$missions" ]]; then
			echo ""
			echo "  Active missions:"
			while IFS= read -r mid; do
				local mc mm
				mc=$(db "$DB_FILE" "SELECT count(*) FROM conversations WHERE mission_id = '$(sql_escape "$mid")';")
				mm=$(db "$DB_FILE" "SELECT count(*) FROM messages WHERE mission_id = '$(sql_escape "$mid")';")
				echo "    $mid: $mc conversations, $mm messages"
			done <<<"$missions"
		fi
	fi

	return 0
}
