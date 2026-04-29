#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Mail Helper -- Transport Adapters Sub-Library
# =============================================================================
# Transport adapter operations for the inter-agent mailbox system.
# Handles envelope encoding/decoding, transport availability checks,
# sending via SimpleX/Matrix, receiving/polling, and transport status.
#
# Usage: source "${SCRIPT_DIR}/mail-helper-transport.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_warn, log_error, log_success)
#   - mail-helper.sh core functions (db, ensure_db, sql_escape, get_agent_id,
#     decode_mail_envelope via self-reference)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MAIL_HELPER_TRANSPORT_LIB_LOADED:-}" ]] && return 0
_MAIL_HELPER_TRANSPORT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

#######################################
# Transport Adapter: Encode message as envelope for chat transports
# Format: [AIDEVOPS-MAIL] v1|id|from|to|type|priority|convoy|payload
# This structured format allows receiving agents to parse and ingest.
#######################################
encode_mail_envelope() {
	local msg_id="$1"
	local from_agent="$2"
	local to_agent="$3"
	local msg_type="$4"
	local priority="$5"
	local convoy="$6"
	local payload="$7"

	# Base64-encode payload to preserve newlines and special chars
	local encoded_payload
	encoded_payload=$(printf '%s' "$payload" | base64 | tr -d '\n')

	printf '%s v%s|%s|%s|%s|%s|%s|%s|%s' \
		"$MAIL_ENVELOPE_PREFIX" "$MAIL_ENVELOPE_VERSION" \
		"$msg_id" "$from_agent" "$to_agent" "$msg_type" \
		"$priority" "$convoy" "$encoded_payload"
	return 0
}

#######################################
# Transport Adapter: Decode envelope back to message fields
# Arguments: envelope string
# Output: pipe-separated fields (id|from|to|type|priority|convoy|payload)
#######################################
decode_mail_envelope() {
	local envelope="$1"

	# Strip prefix and version
	local body
	body="${envelope#"${MAIL_ENVELOPE_PREFIX} v${MAIL_ENVELOPE_VERSION}|"}"

	# Split on pipe: id|from|to|type|priority|convoy|encoded_payload
	local msg_id from_agent to_agent msg_type priority convoy encoded_payload
	IFS='|' read -r msg_id from_agent to_agent msg_type priority convoy encoded_payload <<<"$body"

	# Decode payload from base64
	local payload
	payload=$(printf '%s' "$encoded_payload" | base64 -d 2>/dev/null || echo "")

	printf '%s|%s|%s|%s|%s|%s|%s' \
		"$msg_id" "$from_agent" "$to_agent" "$msg_type" \
		"$priority" "$convoy" "$payload"
	return 0
}

#######################################
# Transport Adapter: Check if a transport is available
# Arguments: transport name (simplex|matrix)
# Returns: 0 if available, 1 if not
#######################################
transport_available() {
	local transport="$1"

	case "$transport" in
	simplex)
		if [[ ! -x "$SIMPLEX_HELPER" ]]; then
			return 1
		fi
		# Check if simplex-chat binary exists
		if ! command -v simplex-chat &>/dev/null; then
			return 1
		fi
		return 0
		;;
	matrix)
		if [[ ! -f "$MATRIX_BOT_CONFIG" ]]; then
			return 1
		fi
		if ! command -v curl &>/dev/null; then
			return 1
		fi
		return 0
		;;
	local)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

#######################################
# Transport Adapter: Send via SimpleX
# Relays a mail envelope through SimpleX Chat (contact or group)
#######################################
transport_simplex_send() {
	local envelope="$1"
	local rc=0

	if ! transport_available "simplex"; then
		log_warn "SimpleX transport not available (simplex-chat not installed or simplex-helper.sh not found)"
		return 1
	fi

	# Prefer group delivery (broadcast to all agents in the group)
	if [[ -n "$SIMPLEX_MAIL_GROUP" ]]; then
		rc=0
		"$SIMPLEX_HELPER" send-group "$SIMPLEX_MAIL_GROUP" "$envelope" || rc=$?
		if [[ $rc -eq 0 ]]; then
			log_info "Relayed via SimpleX group: $SIMPLEX_MAIL_GROUP"
			return 0
		fi
		log_warn "SimpleX group send failed (rc=$rc), trying contact..."
	fi

	# Fallback to direct contact
	if [[ -n "$SIMPLEX_MAIL_CONTACT" ]]; then
		rc=0
		"$SIMPLEX_HELPER" send "$SIMPLEX_MAIL_CONTACT" "$envelope" || rc=$?
		if [[ $rc -eq 0 ]]; then
			log_info "Relayed via SimpleX contact: $SIMPLEX_MAIL_CONTACT"
			return 0
		fi
		log_warn "SimpleX contact send failed (rc=$rc)"
	fi

	log_error "SimpleX transport: no group or contact configured (set AIDEVOPS_SIMPLEX_MAIL_GROUP or AIDEVOPS_SIMPLEX_MAIL_CONTACT)"
	return 1
}

#######################################
# Transport Adapter: Send via Matrix
# Posts a mail envelope to a Matrix room via the bot's homeserver API
#######################################
transport_matrix_send() {
	local envelope="$1"

	if ! transport_available "matrix"; then
		log_warn "Matrix transport not available (matrix-bot.json not found or curl missing)"
		return 1
	fi

	if [[ -z "$MATRIX_MAIL_ROOM" ]]; then
		log_error "Matrix transport: no room configured (set AIDEVOPS_MATRIX_MAIL_ROOM)"
		return 1
	fi

	# Read homeserver and token from matrix-bot.json
	local homeserver_url access_token
	homeserver_url=$(jq -r '.homeserverUrl // empty' "$MATRIX_BOT_CONFIG" 2>/dev/null)
	access_token=$(jq -r '.accessToken // empty' "$MATRIX_BOT_CONFIG" 2>/dev/null)

	if [[ -z "$homeserver_url" || -z "$access_token" ]]; then
		log_error "Matrix transport: homeserverUrl or accessToken missing from $MATRIX_BOT_CONFIG"
		return 1
	fi

	# URL-encode the room ID
	local encoded_room
	encoded_room=$(printf '%s' "$MATRIX_MAIL_ROOM" | jq -sRr @uri 2>/dev/null)

	# Generate a unique transaction ID
	local txn_id
	txn_id="mail-$(date +%s)-${RANDOM}"

	# Send as m.room.message via Matrix Client-Server API
	local endpoint="${homeserver_url}/_matrix/client/v3/rooms/${encoded_room}/send/m.room.message/${txn_id}"

	local json_body
	json_body=$(jq -n --arg body "$envelope" '{msgtype: "m.text", body: $body}')

	local http_code curl_stderr
	curl_stderr=$(mktemp) || curl_stderr="/dev/null"
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	if [[ "$curl_stderr" != "/dev/null" ]]; then
		push_cleanup "rm -f '${curl_stderr}'"
	fi
	http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
		-X PUT "$endpoint" \
		-H "Authorization: Bearer $access_token" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>"$curl_stderr") || http_code="000"
	if [[ "$http_code" != "200" && -s "$curl_stderr" ]]; then
		log_warn "Matrix curl error to endpoint $endpoint: $(cat "$curl_stderr")"
	fi
	# Fast-path cleanup — remove as soon as content has been read
	rm -f "$curl_stderr"

	if [[ "$http_code" == "200" ]]; then
		log_info "Relayed via Matrix room: $MATRIX_MAIL_ROOM"
		return 0
	fi

	log_error "Matrix transport: send failed (HTTP $http_code)"
	return 1
}

#######################################
# Transport Adapter: Relay message after local storage
# Called by cmd_send after inserting into local SQLite.
# Relays via configured transport(s). Failures are logged but non-fatal.
#######################################
transport_relay() {
	local msg_id="$1"
	local from_agent="$2"
	local to_agent="$3"
	local msg_type="$4"
	local priority="$5"
	local convoy="$6"
	local payload="$7"
	local transport="${8:-$MAIL_TRANSPORT}"

	# Local-only: nothing to relay
	if [[ "$transport" == "local" ]]; then
		return 0
	fi

	local envelope
	envelope=$(encode_mail_envelope "$msg_id" "$from_agent" "$to_agent" "$msg_type" "$priority" "$convoy" "$payload")

	case "$transport" in
	simplex)
		transport_simplex_send "$envelope" || true
		;;
	matrix)
		transport_matrix_send "$envelope" || true
		;;
	all)
		transport_simplex_send "$envelope" || true
		transport_matrix_send "$envelope" || true
		;;
	*)
		log_warn "Unknown transport: $transport (using local only)"
		;;
	esac

	return 0
}

#######################################
# Transport Adapter: Ingest a decoded envelope into local SQLite
# Deduplicates by message ID (INSERT OR IGNORE).
#######################################
ingest_remote_message() {
	local msg_id="$1"
	local from_agent="$2"
	local to_agent="$3"
	local msg_type="$4"
	local priority="$5"
	local convoy="$6"
	local payload="$7"

	ensure_db

	local escaped_payload
	escaped_payload=$(sql_escape "$payload")
	local escaped_convoy
	escaped_convoy=$(sql_escape "$convoy")

	db "$MAIL_DB" "
        INSERT OR IGNORE INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
        VALUES ('$(sql_escape "$msg_id")', '$(sql_escape "$from_agent")', '$(sql_escape "$to_agent")', '$(sql_escape "$msg_type")', '$(sql_escape "$priority")', '$escaped_convoy', '$escaped_payload');
    "

	return 0
}

#######################################
# Receive: Poll remote transports and ingest messages
#######################################
cmd_receive() {
	local transport="${MAIL_TRANSPORT}"
	local agent_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--transport)
			[[ $# -lt 2 ]] && {
				log_error "--transport requires a value"
				return 1
			}
			transport="$2"
			shift 2
			;;
		--agent)
			[[ $# -lt 2 ]] && {
				log_error "--agent requires a value"
				return 1
			}
			agent_id="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$agent_id" ]]; then
		agent_id=$(get_agent_id)
	fi

	ensure_db

	local ingested=0

	# SimpleX receive: read recent messages from the SimpleX CLI WebSocket
	if [[ "$transport" == "simplex" || "$transport" == "all" ]]; then
		ingested=$((ingested + $(receive_simplex "$agent_id")))
	fi

	# Matrix receive: fetch recent messages from the Matrix room
	if [[ "$transport" == "matrix" || "$transport" == "all" ]]; then
		ingested=$((ingested + $(receive_matrix "$agent_id")))
	fi

	if [[ "$ingested" -gt 0 ]]; then
		log_success "Ingested $ingested messages from remote transports"
	else
		log_info "No new messages from remote transports"
	fi

	return 0
}

#######################################
# Receive from SimpleX: read messages via simplex-helper.sh
# SimpleX doesn't have a polling API in the CLI helper — messages arrive
# via the WebSocket event stream. For now, we check a local spool directory
# where a SimpleX bot process can deposit received envelopes.
#######################################
receive_simplex() {
	local agent_id="$1"
	local count=0

	if ! transport_available "simplex"; then
		echo "0"
		return 0
	fi

	local spool_dir="${MAIL_DIR}/spool/simplex"
	if [[ ! -d "$spool_dir" ]]; then
		echo "0"
		return 0
	fi

	# Process envelope files deposited by the SimpleX bot
	local envelope_file
	for envelope_file in "$spool_dir"/*.envelope; do
		[[ -f "$envelope_file" ]] || continue

		local envelope
		envelope=$(cat "$envelope_file")

		# Verify it's a valid mail envelope
		if [[ "$envelope" != "${MAIL_ENVELOPE_PREFIX}"* ]]; then
			log_warn "Skipping invalid envelope: $(basename "$envelope_file")"
			continue
		fi

		local decoded
		decoded=$(decode_mail_envelope "$envelope")

		local msg_id from_agent to_agent msg_type priority convoy payload
		IFS='|' read -r msg_id from_agent to_agent msg_type priority convoy payload <<<"$decoded"

		local should_archive="true"
		# Only ingest messages addressed to this agent or to "all"
		if [[ "$to_agent" == "$agent_id" || "$to_agent" == "all" ]]; then
			if ingest_remote_message "$msg_id" "$from_agent" "$to_agent" "$msg_type" "$priority" "$convoy" "$payload"; then
				count=$((count + 1))
			else
				should_archive="false"
				log_warn "Failed to ingest envelope $(basename "$envelope_file"); leaving for retry"
			fi
		fi

		# Archive processed envelope only when safe to do so
		if [[ "$should_archive" == "true" ]]; then
			local archive_rc=0
			mv "$envelope_file" "${envelope_file}.processed" || archive_rc=$?
			if [[ $archive_rc -ne 0 ]]; then
				log_warn "Failed to archive envelope (rc=$archive_rc); leaving original in place: $envelope_file"
			fi
		fi
	done

	echo "$count"
	return 0
}

#######################################
# Receive from Matrix: fetch recent messages from the configured room
# Uses the Matrix Client-Server API to read recent events and extract
# mail envelopes from message bodies.
#######################################
receive_matrix() {
	local agent_id="$1"
	local count=0

	if ! transport_available "matrix"; then
		echo "0"
		return 0
	fi

	if [[ -z "$MATRIX_MAIL_ROOM" ]]; then
		echo "0"
		return 0
	fi

	local homeserver_url access_token
	homeserver_url=$(jq -r '.homeserverUrl // empty' "$MATRIX_BOT_CONFIG" 2>/dev/null)
	access_token=$(jq -r '.accessToken // empty' "$MATRIX_BOT_CONFIG" 2>/dev/null)

	if [[ -z "$homeserver_url" || -z "$access_token" ]]; then
		echo "0"
		return 0
	fi

	# Read the since token for incremental sync
	local since_file="${MAIL_DIR}/.matrix-since-token"
	local since_token=""
	if [[ -f "$since_file" ]]; then
		since_token=$(cat "$since_file")
	fi

	# URL-encode the room ID
	local encoded_room
	encoded_room=$(printf '%s' "$MATRIX_MAIL_ROOM" | jq -sRr @uri 2>/dev/null)

	# Fetch recent messages (last 50)
	local endpoint="${homeserver_url}/_matrix/client/v3/rooms/${encoded_room}/messages?dir=b&limit=50"
	if [[ -n "$since_token" ]]; then
		endpoint="${endpoint}&from=${since_token}"
	fi

	local response
	response=$(curl -sf \
		-H "Authorization: Bearer $access_token" \
		"$endpoint" 2>/dev/null) || {
		log_warn "Matrix receive: failed to fetch messages"
		echo "0"
		return 0
	}

	# Save the pagination token for next poll
	local new_token
	new_token=$(printf '%s' "$response" | jq -r '.end // empty' 2>/dev/null)
	if [[ -n "$new_token" ]]; then
		printf '%s' "$new_token" >"$since_file"
	fi

	# Extract mail envelopes from message events
	local events
	events=$(printf '%s' "$response" | jq -r '.chunk[]? | select(.type == "m.room.message") | .content.body // empty' 2>/dev/null)

	if [[ -z "$events" ]]; then
		echo "0"
		return 0
	fi

	while IFS= read -r body; do
		# Only process mail envelopes
		if [[ "$body" != "${MAIL_ENVELOPE_PREFIX}"* ]]; then
			continue
		fi

		local decoded
		decoded=$(decode_mail_envelope "$body")

		local msg_id from_agent to_agent msg_type priority convoy payload
		IFS='|' read -r msg_id from_agent to_agent msg_type priority convoy payload <<<"$decoded"

		# Only ingest messages addressed to this agent or to "all"
		if [[ "$to_agent" == "$agent_id" || "$to_agent" == "all" ]]; then
			ingest_remote_message "$msg_id" "$from_agent" "$to_agent" "$msg_type" "$priority" "$convoy" "$payload"
			count=$((count + 1))
		fi
	done <<<"$events"

	echo "$count"
	return 0
}

#######################################
# Transport Status: show configured transports and their availability
#######################################
cmd_transport_status() {
	echo "Mail Transport Status"
	echo "====================="
	echo ""
	echo "  Default transport: $MAIL_TRANSPORT"
	echo ""

	# Local
	echo "  local:"
	echo "    Status:    always available"
	echo "    Database:  $MAIL_DB"
	if [[ -f "$MAIL_DB" ]]; then
		local db_size
		# Linux stat -c first (stat -f%z on Linux outputs filesystem info to stdout)
		db_size=$(stat -c%s "$MAIL_DB" 2>/dev/null || stat -f%z "$MAIL_DB" 2>/dev/null || echo "0")
		echo "    Size:      $((db_size / 1024))KB"
	else
		echo "    Size:      (not initialized)"
	fi
	echo ""

	# SimpleX
	echo "  simplex:"
	if transport_available "simplex"; then
		echo "    Status:    available"
	else
		echo "    Status:    NOT available"
		if [[ ! -x "$SIMPLEX_HELPER" ]]; then
			echo "    Missing:   simplex-helper.sh"
		fi
		if ! command -v simplex-chat &>/dev/null; then
			echo "    Missing:   simplex-chat binary"
		fi
	fi
	echo "    Group:     ${SIMPLEX_MAIL_GROUP:-not set}"
	echo "    Contact:   ${SIMPLEX_MAIL_CONTACT:-not set}"
	local spool_dir="${MAIL_DIR}/spool/simplex"
	if [[ -d "$spool_dir" ]]; then
		local pending
		pending=$(find "$spool_dir" -name "*.envelope" 2>/dev/null | wc -l | tr -d ' ')
		echo "    Spool:     $pending pending envelopes"
	else
		echo "    Spool:     (not initialized)"
	fi
	echo ""

	# Matrix
	echo "  matrix:"
	if transport_available "matrix"; then
		echo "    Status:    available"
		local homeserver
		homeserver=$(jq -r '.homeserverUrl // "unknown"' "$MATRIX_BOT_CONFIG" 2>/dev/null)
		echo "    Server:    $homeserver"
	else
		echo "    Status:    NOT available"
		if [[ ! -f "$MATRIX_BOT_CONFIG" ]]; then
			echo "    Missing:   $MATRIX_BOT_CONFIG"
		fi
	fi
	echo "    Room:      ${MATRIX_MAIL_ROOM:-not set}"
	local since_file="${MAIL_DIR}/.matrix-since-token"
	if [[ -f "$since_file" ]]; then
		echo "    Sync:      has pagination token"
	else
		echo "    Sync:      no pagination token (will fetch recent history)"
	fi
	echo ""

	return 0
}
