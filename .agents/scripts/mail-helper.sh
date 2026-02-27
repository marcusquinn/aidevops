#!/usr/bin/env bash
# mail-helper.sh - SQLite-backed inter-agent mailbox system
# Enables asynchronous communication between parallel agent sessions
# Supports transport adapters for cross-machine communication (SimpleX, Matrix)
#
# Usage:
#   mail-helper.sh send --to <agent-id> --type <type> --payload "message" [--priority high|normal|low] [--convoy <id>] [--transport <local|simplex|matrix|all>]
#   mail-helper.sh check [--agent <id>] [--unread-only]
#   mail-helper.sh read <message-id> [--agent <id>]
#   mail-helper.sh archive <message-id> [--agent <id>]
#   mail-helper.sh prune [--older-than-days 7] [--force]
#   mail-helper.sh status [--agent <id>]
#   mail-helper.sh register --agent <id> --role <role> [--branch <branch>] [--worktree <path>]
#   mail-helper.sh deregister --agent <id>
#   mail-helper.sh agents [--active-only]
#   mail-helper.sh receive [--transport <simplex|matrix|all>]  # Poll remote transports
#   mail-helper.sh transport-status                             # Show transport adapter status
#   mail-helper.sh migrate                                      # Migrate TOON files to SQLite
#
# Message Types:
#   task_dispatch   - Coordinator assigns work to agent
#   status_report   - Agent reports progress/completion
#   discovery       - Agent shares a finding with others
#   request         - Agent requests help/info from another
#   broadcast       - Message to all agents
#
# Transport Adapters:
#   local   - SQLite only (default, same-machine agents)
#   simplex - Relay via SimpleX Chat (cross-machine, E2E encrypted)
#   matrix  - Relay via Matrix room (cross-machine, federated)
#   all     - Relay via all configured transports
#
# Lifecycle: send → check → read → archive (prune is manual with storage report)
#
# Performance: SQLite WAL mode handles thousands of messages with <10ms queries.
# Previous TOON file-based system: ~25ms per message (2.5s for 100 messages).
# SQLite: <1ms per query regardless of message count.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly MAIL_DIR="${AIDEVOPS_MAIL_DIR:-$HOME/.aidevops/.agent-workspace/mail}"
readonly MAIL_DB="$MAIL_DIR/mailbox.db"
readonly DEFAULT_PRUNE_DAYS=7
readonly MEMORY_HELPER="$HOME/.aidevops/agents/scripts/memory-helper.sh"

# Transport adapter configuration
readonly MAIL_TRANSPORT="${AIDEVOPS_MAIL_TRANSPORT:-local}"
readonly SIMPLEX_HELPER="${SCRIPT_DIR}/simplex-helper.sh"
readonly SIMPLEX_MAIL_CONTACT="${AIDEVOPS_SIMPLEX_MAIL_CONTACT:-}"
readonly SIMPLEX_MAIL_GROUP="${AIDEVOPS_SIMPLEX_MAIL_GROUP:-#aidevops-mail}"
readonly MATRIX_MAIL_ROOM="${AIDEVOPS_MATRIX_MAIL_ROOM:-}"
readonly MATRIX_BOT_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/aidevops/matrix-bot.json"
# Envelope prefix for structured messages over chat transports
readonly MAIL_ENVELOPE_PREFIX="[AIDEVOPS-MAIL]"
readonly MAIL_ENVELOPE_VERSION="1"

# Logging: uses shared log_* from shared-constants.sh with MAIL prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="MAIL"

#######################################
# SQLite wrapper: sets busy_timeout on every connection (t135.3)
# busy_timeout is per-connection and must be set each time
#######################################
db() {
	sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Ensure database exists and is initialized
#######################################
ensure_db() {
	mkdir -p "$MAIL_DIR"

	if [[ ! -f "$MAIL_DB" ]]; then
		init_db
		return 0
	fi

	# Check if schema needs upgrade (agents table might be missing)
	local has_agents
	has_agents=$(db "$MAIL_DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='agents';")
	if [[ "$has_agents" -eq 0 ]]; then
		init_db
	fi

	# Ensure WAL mode for existing databases created before t135.3
	local current_mode
	current_mode=$(db "$MAIL_DB" "PRAGMA journal_mode;" 2>/dev/null || echo "")
	if [[ "$current_mode" != "wal" ]]; then
		db "$MAIL_DB" "PRAGMA journal_mode=WAL;" 2>/dev/null || echo "[WARN] Failed to enable WAL mode for mail DB" >&2
	fi

	return 0
}

#######################################
# Initialize SQLite database with schema
#######################################
init_db() {
	db "$MAIL_DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS messages (
    id          TEXT PRIMARY KEY,
    from_agent  TEXT NOT NULL,
    to_agent    TEXT NOT NULL,
    type        TEXT NOT NULL CHECK(type IN ('task_dispatch','status_report','discovery','request','broadcast')),
    priority    TEXT NOT NULL DEFAULT 'normal' CHECK(priority IN ('high','normal','low')),
    convoy      TEXT DEFAULT 'none',
    payload     TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'unread' CHECK(status IN ('unread','read','archived')),
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at     TEXT,
    archived_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_messages_to_status ON messages(to_agent, status);
CREATE INDEX IF NOT EXISTS idx_messages_to_unread ON messages(to_agent) WHERE status = 'unread';
CREATE INDEX IF NOT EXISTS idx_messages_type ON messages(type);
CREATE INDEX IF NOT EXISTS idx_messages_convoy ON messages(convoy) WHERE convoy != 'none';
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_archived ON messages(archived_at) WHERE status = 'archived';

CREATE TABLE IF NOT EXISTS agents (
    id          TEXT PRIMARY KEY,
    role        TEXT NOT NULL DEFAULT 'worker',
    branch      TEXT,
    worktree    TEXT,
    status      TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','inactive')),
    registered  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    last_seen   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE INDEX IF NOT EXISTS idx_agents_status ON agents(status);
SQL

	log_info "Initialized mailbox database: $MAIL_DB"
}

#######################################
# Generate unique message ID
# Format: msg-YYYYMMDD-HHMMSS-RANDOM
#######################################
generate_id() {
	local timestamp
	timestamp=$(date +%Y%m%d-%H%M%S)
	local random
	random=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
	echo "msg-${timestamp}-${random}"
}

#######################################
# Get current agent ID (from env or derive)
#######################################
get_agent_id() {
	if [[ -n "${AIDEVOPS_AGENT_ID:-}" ]]; then
		echo "$AIDEVOPS_AGENT_ID"
		return 0
	fi
	local branch
	branch=$(git branch --show-current 2>/dev/null || echo "unknown")
	local worktree_name
	worktree_name=$(basename "$(pwd)" | sed 's/^aidevops[.-]//')
	if [[ "$worktree_name" != "aidevops" && "$worktree_name" != "." ]]; then
		echo "agent-${worktree_name}"
	else
		echo "agent-${branch}"
	fi
}

#######################################
# Escape single quotes for SQL
#######################################
sql_escape() {
	local input="$1"
	echo "${input//\'/\'\'}"
}

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

	if ! transport_available "simplex"; then
		log_warn "SimpleX transport not available (simplex-chat not installed or simplex-helper.sh not found)"
		return 1
	fi

	# Prefer group delivery (broadcast to all agents in the group)
	if [[ -n "$SIMPLEX_MAIL_GROUP" ]]; then
		"$SIMPLEX_HELPER" send-group "$SIMPLEX_MAIL_GROUP" "$envelope" 2>/dev/null
		local rc=$?
		if [[ $rc -eq 0 ]]; then
			log_info "Relayed via SimpleX group: $SIMPLEX_MAIL_GROUP"
			return 0
		fi
		log_warn "SimpleX group send failed (rc=$rc), trying contact..."
	fi

	# Fallback to direct contact
	if [[ -n "$SIMPLEX_MAIL_CONTACT" ]]; then
		"$SIMPLEX_HELPER" send "$SIMPLEX_MAIL_CONTACT" "$envelope" 2>/dev/null
		local rc=$?
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

	local http_code
	http_code=$(curl -sf -o /dev/null -w '%{http_code}' \
		-X PUT "$endpoint" \
		-H "Authorization: Bearer $access_token" \
		-H "Content-Type: application/json" \
		-d "$json_body" 2>/dev/null) || http_code="000"

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

		# Only ingest messages addressed to this agent or to "all"
		if [[ "$to_agent" == "$agent_id" || "$to_agent" == "all" ]]; then
			ingest_remote_message "$msg_id" "$from_agent" "$to_agent" "$msg_type" "$priority" "$convoy" "$payload"
			count=$((count + 1))
		fi

		# Archive processed envelope
		mv "$envelope_file" "${envelope_file}.processed" 2>/dev/null || rm -f "$envelope_file"
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
		db_size=$(stat -f%z "$MAIL_DB" 2>/dev/null || stat -c%s "$MAIL_DB" 2>/dev/null || echo "0")
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

#######################################
# Send a message
#######################################
cmd_send() {
	local to="" msg_type="" payload="" priority="normal" convoy="none"
	local transport="$MAIL_TRANSPORT"
	local from
	from=$(get_agent_id)

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--to)
			[[ $# -lt 2 ]] && {
				log_error "--to requires a value"
				return 1
			}
			to="$2"
			shift 2
			;;
		--type)
			[[ $# -lt 2 ]] && {
				log_error "--type requires a value"
				return 1
			}
			msg_type="$2"
			shift 2
			;;
		--payload)
			[[ $# -lt 2 ]] && {
				log_error "--payload requires a value"
				return 1
			}
			payload="$2"
			shift 2
			;;
		--priority)
			[[ $# -lt 2 ]] && {
				log_error "--priority requires a value"
				return 1
			}
			priority="$2"
			shift 2
			;;
		--convoy)
			[[ $# -lt 2 ]] && {
				log_error "--convoy requires a value"
				return 1
			}
			convoy="$2"
			shift 2
			;;
		--from)
			[[ $# -lt 2 ]] && {
				log_error "--from requires a value"
				return 1
			}
			from="$2"
			shift 2
			;;
		--transport)
			[[ $# -lt 2 ]] && {
				log_error "--transport requires a value"
				return 1
			}
			transport="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$to" ]]; then
		log_error "Missing --to <agent-id>"
		return 1
	fi
	if [[ -z "$msg_type" ]]; then
		log_error "Missing --type <message-type>"
		return 1
	fi
	if [[ -z "$payload" ]]; then
		log_error "Missing --payload <message>"
		return 1
	fi

	local valid_types="task_dispatch status_report discovery request broadcast"
	if ! echo "$valid_types" | grep -qw "$msg_type"; then
		log_error "Invalid type: $msg_type (valid: $valid_types)"
		return 1
	fi

	if ! echo "high normal low" | grep -qw "$priority"; then
		log_error "Invalid priority: $priority (valid: high, normal, low)"
		return 1
	fi

	ensure_db

	local msg_id
	msg_id=$(generate_id)
	local escaped_payload
	escaped_payload=$(sql_escape "$payload")
	local escaped_convoy
	escaped_convoy=$(sql_escape "$convoy")

	if [[ "$to" == "all" || "$msg_type" == "broadcast" ]]; then
		# Broadcast: insert one message per active agent (excluding sender)
		local count
		count=$(db "$MAIL_DB" "
            SELECT count(*) FROM agents WHERE status='active' AND id != '$(sql_escape "$from")';
        ")

		local agents_list
		agents_list=$(db "$MAIL_DB" "
            SELECT id FROM agents WHERE status='active' AND id != '$(sql_escape "$from")';
        ")

		if [[ -n "$agents_list" ]]; then
			while IFS= read -r agent_id; do
				local broadcast_id
				broadcast_id=$(generate_id)
				db "$MAIL_DB" "
                    INSERT INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
                    VALUES ('$broadcast_id', '$(sql_escape "$from")', '$(sql_escape "$agent_id")', '$msg_type', '$priority', '$escaped_convoy', '$escaped_payload');
                "
			done <<<"$agents_list"
			log_success "Broadcast sent: $msg_id (to $count agents)"
		else
			# No agents registered, insert as general broadcast
			db "$MAIL_DB" "
                INSERT INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
                VALUES ('$msg_id', '$(sql_escape "$from")', 'all', '$msg_type', '$priority', '$escaped_convoy', '$escaped_payload');
            "
			log_success "Sent: $msg_id → all (no agents registered)"
		fi
	else
		db "$MAIL_DB" "
            INSERT INTO messages (id, from_agent, to_agent, type, priority, convoy, payload)
            VALUES ('$msg_id', '$(sql_escape "$from")', '$(sql_escape "$to")', '$msg_type', '$priority', '$escaped_convoy', '$escaped_payload');
        "
		log_success "Sent: $msg_id → $to (priority: $priority)"
	fi

	# Relay via configured transport adapter (non-fatal on failure)
	transport_relay "$msg_id" "$from" "$to" "$msg_type" "$priority" "$convoy" "$payload" "$transport"

	echo "$msg_id"
}

#######################################
# Check inbox for messages
#######################################
cmd_check() {
	local agent_id="" unread_only=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--agent)
			[[ $# -lt 2 ]] && {
				log_error "--agent requires a value"
				return 1
			}
			agent_id="$2"
			shift 2
			;;
		--unread-only)
			unread_only=true
			shift
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

	local escaped_id
	escaped_id=$(sql_escape "$agent_id")
	local where_clause="to_agent = '${escaped_id}' AND status != 'archived'"
	if [[ "$unread_only" == true ]]; then
		where_clause="to_agent = '${escaped_id}' AND status = 'unread'"
	fi

	local results
	results=$(db -separator ',' "$MAIL_DB" "
        SELECT id, from_agent, type, priority, convoy, created_at, status
        FROM messages
        WHERE $where_clause
        ORDER BY
            CASE priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 WHEN 'low' THEN 2 END,
            created_at DESC;
    ")

	local total unread
	total=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent = '$(sql_escape "$agent_id")' AND status != 'archived';")
	unread=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent = '$(sql_escape "$agent_id")' AND status = 'unread';")

	echo "<!--TOON:inbox{id,from,type,priority,convoy,timestamp,status}:"
	if [[ -n "$results" ]]; then
		echo "$results"
	fi
	echo "-->"
	echo ""
	echo "Total: $total messages ($unread unread) for $agent_id"
}

#######################################
# Read a specific message (marks as read)
#######################################
cmd_read_msg() {
	local msg_id="" agent_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--agent)
			[[ $# -lt 2 ]] && {
				log_error "--agent requires a value"
				return 1
			}
			agent_id="$2"
			shift 2
			;;
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			msg_id="$1"
			shift
			;;
		esac
	done

	if [[ -z "$msg_id" ]]; then
		log_error "Usage: mail-helper.sh read <message-id> [--agent <id>]"
		return 1
	fi

	ensure_db

	local row
	row=$(db -separator '|' "$MAIL_DB" "
        SELECT id, from_agent, to_agent, type, priority, convoy, created_at, status, payload
        FROM messages WHERE id = '$(sql_escape "$msg_id")';
    ")

	if [[ -z "$row" ]]; then
		log_error "Message not found: $msg_id"
		return 1
	fi

	# Mark as read
	db "$MAIL_DB" "
        UPDATE messages SET status = 'read', read_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$(sql_escape "$msg_id")' AND status = 'unread';
    "

	# Output in TOON format for backward compatibility
	local id from_agent to_agent msg_type priority convoy created_at payload
	IFS='|' read -r id from_agent to_agent msg_type priority convoy created_at _ payload <<<"$row"
	echo "<!--TOON:message{id,from,to,type,priority,convoy,timestamp,status}:"
	echo "${id},${from_agent},${to_agent},${msg_type},${priority},${convoy},${created_at},read"
	echo "-->"
	echo ""
	echo "$payload"
}

#######################################
# Archive a message
#######################################
cmd_archive() {
	local msg_id="" agent_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--agent)
			[[ $# -lt 2 ]] && {
				log_error "--agent requires a value"
				return 1
			}
			agent_id="$2"
			shift 2
			;;
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			msg_id="$1"
			shift
			;;
		esac
	done

	if [[ -z "$msg_id" ]]; then
		log_error "Usage: mail-helper.sh archive <message-id> [--agent <id>]"
		return 1
	fi

	ensure_db

	local updated
	updated=$(db "$MAIL_DB" "
        UPDATE messages SET status = 'archived', archived_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$(sql_escape "$msg_id")' AND status != 'archived';
        SELECT changes();
    ")

	if [[ "$updated" -eq 0 ]]; then
		log_error "Message not found or already archived: $msg_id"
		return 1
	fi

	log_success "Archived: $msg_id"
}

#######################################
# Prune: manual deletion with storage report
# By default shows storage report. Use --force to actually delete.
#######################################
cmd_prune() {
	local older_than_days="$DEFAULT_PRUNE_DAYS"
	local force=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--older-than-days)
			[[ $# -lt 2 ]] && {
				log_error "--older-than-days requires a value"
				return 1
			}
			older_than_days="$2"
			shift 2
			;;
		--force)
			force=true
			shift
			;;
		# Keep --dry-run as alias for default behavior (backward compat)
		--dry-run) shift ;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if ! [[ "$older_than_days" =~ ^[0-9]+$ ]]; then
		log_error "Invalid value for --older-than-days: must be a positive integer"
		return 1
	fi

	ensure_db

	# Storage report
	local db_size_bytes
	db_size_bytes=$(stat -f%z "$MAIL_DB" 2>/dev/null || stat -c%s "$MAIL_DB" 2>/dev/null || echo "0")
	local db_size_kb=$((db_size_bytes / 1024))

	# Single query for all counts (reduces sqlite3 invocations)
	local total_messages unread_messages read_messages archived_messages
	IFS='|' read -r total_messages unread_messages read_messages archived_messages < <(db -separator '|' "$MAIL_DB" "
        SELECT count(*),
            coalesce(sum(CASE WHEN status = 'unread' THEN 1 ELSE 0 END), 0),
            coalesce(sum(CASE WHEN status = 'read' THEN 1 ELSE 0 END), 0),
            coalesce(sum(CASE WHEN status = 'archived' THEN 1 ELSE 0 END), 0)
        FROM messages;
    ")

	# Single query for prunable + archivable counts
	local prunable archivable
	IFS='|' read -r prunable archivable < <(db -separator '|' "$MAIL_DB" "
        SELECT
            coalesce(sum(CASE WHEN status = 'archived' AND archived_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days') THEN 1 ELSE 0 END), 0),
            coalesce(sum(CASE WHEN status = 'read' AND read_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days') THEN 1 ELSE 0 END), 0)
        FROM messages;
    ")

	# Single query for date range
	local oldest_msg newest_msg
	IFS='|' read -r oldest_msg newest_msg < <(db -separator '|' "$MAIL_DB" "
        SELECT coalesce(min(created_at), 'none'), coalesce(max(created_at), 'none') FROM messages;
    ")

	# Per-type breakdown
	local type_breakdown
	type_breakdown=$(db -separator ': ' "$MAIL_DB" "
        SELECT type, count(*) FROM messages GROUP BY type ORDER BY count(*) DESC;
    ")

	echo "Mailbox Storage Report"
	echo "======================"
	echo ""
	echo "  Database:    ${db_size_kb}KB ($MAIL_DB)"
	echo "  Messages:    $total_messages total"
	echo "    Unread:    $unread_messages"
	echo "    Read:      $read_messages"
	echo "    Archived:  $archived_messages"
	echo "  Date range:  $oldest_msg → $newest_msg"
	echo ""
	echo "  By type:"
	if [[ -n "$type_breakdown" ]]; then
		echo "$type_breakdown" | while IFS= read -r line; do
			echo "    $line"
		done
	else
		echo "    (none)"
	fi
	echo ""
	echo "  Prunable (archived >${older_than_days}d): $prunable messages"
	echo "  Archivable (read >${older_than_days}d):   $archivable messages"

	if [[ "$force" != true ]]; then
		if [[ "$prunable" -gt 0 || "$archivable" -gt 0 ]]; then
			echo ""
			echo "  To delete prunable messages:  mail-helper.sh prune --force"
			echo "  To change threshold:          mail-helper.sh prune --older-than-days 30 --force"
		else
			echo ""
			echo "  Nothing to prune. All messages are within the ${older_than_days}-day window."
		fi
		return 0
	fi

	# --force: actually delete
	log_info "Pruning with --force (${older_than_days}-day threshold)..."

	# Backup before bulk delete (t188)
	local prune_backup
	prune_backup=$(backup_sqlite_db "$MAIL_DB" "pre-prune")
	if [[ $? -ne 0 || -z "$prune_backup" ]]; then
		log_warn "Backup failed before prune — proceeding cautiously"
	fi

	# Capture discoveries and status reports to memory before pruning
	local remembered=0
	if [[ -x "$MEMORY_HELPER" ]]; then
		local notable_messages
		notable_messages=$(db -separator '|' "$MAIL_DB" "
            SELECT type, payload FROM messages
            WHERE status = 'archived'
            AND archived_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days')
            AND type IN ('discovery', 'status_report');
        ")

		if [[ -n "$notable_messages" ]]; then
			while IFS='|' read -r msg_type payload; do
				if [[ -n "$payload" ]]; then
					"$MEMORY_HELPER" store \
						--content "Mailbox ($msg_type): $payload" \
						--type CONTEXT \
						--tags "mailbox,${msg_type},archived" 2>/dev/null && remembered=$((remembered + 1))
				fi
			done <<<"$notable_messages"
		fi
	fi

	# Archive old read messages first
	local auto_archived
	auto_archived=$(db "$MAIL_DB" "
        UPDATE messages SET status = 'archived', archived_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE status = 'read'
        AND read_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days');
        SELECT changes();
    ")

	# Delete old archived messages
	local pruned
	pruned=$(db "$MAIL_DB" "
        DELETE FROM messages
        WHERE status = 'archived'
        AND archived_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$older_than_days days');
        SELECT changes();
    ")

	# Vacuum to reclaim space
	db "$MAIL_DB" "VACUUM;"

	local new_size_bytes
	new_size_bytes=$(stat -f%z "$MAIL_DB" 2>/dev/null || stat -c%s "$MAIL_DB" 2>/dev/null || echo "0")
	local new_size_kb=$((new_size_bytes / 1024))
	local saved_kb=$((db_size_kb - new_size_kb))

	log_success "Pruned $pruned messages, archived $auto_archived read messages ($remembered captured to memory)"
	log_info "Storage: ${db_size_kb}KB → ${new_size_kb}KB (saved ${saved_kb}KB)"

	# Clean up old backups (t188)
	cleanup_sqlite_backups "$MAIL_DB" 5
}

#######################################
# Show mailbox status
#######################################
cmd_status() {
	local agent_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
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

	ensure_db

	if [[ -n "$agent_id" ]]; then
		local escaped_id
		escaped_id=$(sql_escape "$agent_id")
		local inbox_count unread_count
		inbox_count=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent='$escaped_id' AND status != 'archived';")
		unread_count=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE to_agent='$escaped_id' AND status = 'unread';")
		echo "Agent: $agent_id"
		echo "  Inbox: $inbox_count messages ($unread_count unread)"
	else
		local total_unread total_read total_archived total_agents
		total_unread=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE status = 'unread';")
		total_read=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE status = 'read';")
		total_archived=$(db "$MAIL_DB" "SELECT count(*) FROM messages WHERE status = 'archived';")
		total_agents=$(db "$MAIL_DB" "SELECT count(*) FROM agents WHERE status = 'active';")

		local total_inbox=$((total_unread + total_read))

		echo "<!--TOON:mail_status{inbox,outbox,archive,agents}:"
		echo "${total_inbox},0,${total_archived},${total_agents}"
		echo "-->"
		echo ""
		echo "Mailbox Status:"
		echo "  Active:   $total_inbox messages ($total_unread unread, $total_read read)"
		echo "  Archived: $total_archived messages"
		echo "  Agents:   $total_agents active"

		local agent_list
		agent_list=$(db -separator ',' "$MAIL_DB" "
            SELECT id, role, branch, status, registered, last_seen FROM agents ORDER BY last_seen DESC;
        ")
		if [[ -n "$agent_list" ]]; then
			echo ""
			echo "Registered Agents:"
			echo "<!--TOON:agents{id,role,branch,status,registered,last_seen}:"
			echo "$agent_list"
			echo "-->"
		fi
	fi
}

#######################################
# Register an agent
#######################################
cmd_register() {
	local agent_id="" role="" branch="" worktree=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--agent)
			[[ $# -lt 2 ]] && {
				log_error "--agent requires a value"
				return 1
			}
			agent_id="$2"
			shift 2
			;;
		--role)
			[[ $# -lt 2 ]] && {
				log_error "--role requires a value"
				return 1
			}
			role="$2"
			shift 2
			;;
		--branch)
			[[ $# -lt 2 ]] && {
				log_error "--branch requires a value"
				return 1
			}
			branch="$2"
			shift 2
			;;
		--worktree)
			[[ $# -lt 2 ]] && {
				log_error "--worktree requires a value"
				return 1
			}
			worktree="$2"
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
	if [[ -z "$role" ]]; then
		role="worker"
	fi
	if [[ -z "$branch" ]]; then
		branch=$(git branch --show-current 2>/dev/null || echo "unknown")
	fi
	if [[ -z "$worktree" ]]; then
		worktree=$(pwd)
	fi

	ensure_db

	db "$MAIL_DB" "
        INSERT INTO agents (id, role, branch, worktree, status)
        VALUES ('$(sql_escape "$agent_id")', '$(sql_escape "$role")', '$(sql_escape "$branch")', '$(sql_escape "$worktree")', 'active')
        ON CONFLICT(id) DO UPDATE SET
            role = excluded.role,
            branch = excluded.branch,
            worktree = excluded.worktree,
            status = 'active',
            last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now');
    "

	log_success "Registered agent: $agent_id (role: $role, branch: $branch)"
}

#######################################
# Deregister an agent
#######################################
cmd_deregister() {
	local agent_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
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

	db "$MAIL_DB" "
        UPDATE agents SET status = 'inactive', last_seen = strftime('%Y-%m-%dT%H:%M:%SZ','now')
        WHERE id = '$(sql_escape "$agent_id")';
    "

	log_success "Deregistered agent: $agent_id (marked inactive)"
}

#######################################
# List registered agents
#######################################
cmd_agents() {
	local active_only=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--active-only)
			active_only=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	ensure_db

	if [[ "$active_only" == true ]]; then
		echo "Active Agents:"
		db -separator ',' "$MAIL_DB" "
            SELECT id, role, branch, last_seen FROM agents WHERE status = 'active' ORDER BY last_seen DESC;
        " | while IFS=',' read -r id role branch last_seen; do
			echo -e "  ${CYAN}$id${NC} ($role) on $branch - last seen: $last_seen"
		done
	else
		echo "<!--TOON:agents{id,role,branch,worktree,status,registered,last_seen}:"
		db -separator ',' "$MAIL_DB" "
            SELECT id, role, branch, worktree, status, registered, last_seen FROM agents ORDER BY last_seen DESC;
        "
		echo "-->"
	fi
}

#######################################
# Migrate TOON files to SQLite
#######################################
cmd_migrate() {
	ensure_db

	local migrated=0
	local inbox_dir="$MAIL_DIR/inbox"
	local outbox_dir="$MAIL_DIR/outbox"
	local archive_dir="$MAIL_DIR/archive"

	# Migrate inbox messages
	if [[ -d "$inbox_dir" ]]; then
		while IFS= read -r msg_file; do
			[[ -f "$msg_file" ]] || continue
			local header
			header=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1) || continue
			[[ -z "$header" ]] && continue

			local id from_agent to_agent msg_type priority convoy timestamp status
			IFS=',' read -r id from_agent to_agent msg_type priority convoy timestamp status <<<"$header"
			local payload
			payload=$(sed -n '/^-->$/,$ { /^-->$/d; p; }' "$msg_file" | sed '/^$/d')

			local escaped_payload
			escaped_payload=$(sql_escape "$payload")

			db "$MAIL_DB" "
                INSERT OR IGNORE INTO messages (id, from_agent, to_agent, type, priority, convoy, payload, status, created_at)
                VALUES ('$(sql_escape "$id")', '$(sql_escape "$from_agent")', '$(sql_escape "$to_agent")', '$(sql_escape "$msg_type")', '$(sql_escape "$priority")', '$(sql_escape "$convoy")', '$escaped_payload', '$(sql_escape "$status")', '$(sql_escape "$timestamp")');
            " 2>/dev/null && migrated=$((migrated + 1))
		done < <(find "$inbox_dir" "$outbox_dir" -name "*.toon" 2>/dev/null)
	fi

	# Migrate archived messages
	if [[ -d "$archive_dir" ]]; then
		while IFS= read -r msg_file; do
			[[ -f "$msg_file" ]] || continue
			local header
			header=$(grep -A1 'TOON:message{' "$msg_file" 2>/dev/null | tail -1) || continue
			[[ -z "$header" ]] && continue

			local id from_agent to_agent msg_type priority convoy timestamp status
			IFS=',' read -r id from_agent to_agent msg_type priority convoy timestamp status <<<"$header"
			local payload
			payload=$(sed -n '/^-->$/,$ { /^-->$/d; p; }' "$msg_file" | sed '/^$/d')

			local escaped_payload
			escaped_payload=$(sql_escape "$payload")

			db "$MAIL_DB" "
                INSERT OR IGNORE INTO messages (id, from_agent, to_agent, type, priority, convoy, payload, status, created_at, archived_at)
                VALUES ('$(sql_escape "$id")', '$(sql_escape "$from_agent")', '$(sql_escape "$to_agent")', '$(sql_escape "$msg_type")', '$(sql_escape "$priority")', '$(sql_escape "$convoy")', '$escaped_payload', 'archived', '$(sql_escape "$timestamp")', strftime('%Y-%m-%dT%H:%M:%SZ','now'));
            " 2>/dev/null && migrated=$((migrated + 1))
		done < <(find "$archive_dir" -name "*.toon" 2>/dev/null)
	fi

	# Migrate registry
	local registry_file="$MAIL_DIR/registry.toon"
	local agents_migrated=0
	if [[ -f "$registry_file" ]]; then
		while IFS=',' read -r id role branch worktree status registered last_seen; do
			[[ "$id" == "<!--"* || "$id" == "-->"* || -z "$id" ]] && continue
			db "$MAIL_DB" "
                INSERT OR IGNORE INTO agents (id, role, branch, worktree, status, registered, last_seen)
                VALUES ('$(sql_escape "$id")', '$(sql_escape "$role")', '$(sql_escape "$branch")', '$(sql_escape "$worktree")', '$(sql_escape "$status")', '$(sql_escape "$registered")', '$(sql_escape "$last_seen")');
            " 2>/dev/null && agents_migrated=$((agents_migrated + 1))
		done <"$registry_file"
	fi

	log_success "Migration complete: $migrated messages, $agents_migrated agents"

	# Rename old directories as backup (don't delete)
	if [[ $migrated -gt 0 || $agents_migrated -gt 0 ]]; then
		local backup_suffix
		backup_suffix=$(date +%Y%m%d-%H%M%S)
		for dir in "$inbox_dir" "$outbox_dir" "$archive_dir"; do
			if [[ -d "$dir" ]] && find "$dir" -name "*.toon" 2>/dev/null | grep -q .; then
				mv "$dir" "${dir}.pre-sqlite-${backup_suffix}"
				mkdir -p "$dir"
				log_info "Backed up: $dir → ${dir}.pre-sqlite-${backup_suffix}"
			fi
		done
		if [[ -f "$registry_file" ]]; then
			mv "$registry_file" "${registry_file}.pre-sqlite-${backup_suffix}"
			log_info "Backed up: $registry_file"
		fi
	fi
}

#######################################
# Show usage
#######################################
show_usage() {
	cat <<'EOF'
mail-helper.sh - SQLite-backed inter-agent mailbox system with transport adapters

Usage:
  mail-helper.sh send --to <agent-id> --type <type> --payload "message" [options]
  mail-helper.sh check [--agent <id>] [--unread-only]
  mail-helper.sh read <message-id> [--agent <id>]
  mail-helper.sh archive <message-id> [--agent <id>]
  mail-helper.sh prune [--older-than-days 7] [--force]
  mail-helper.sh status [--agent <id>]
  mail-helper.sh register --agent <id> --role <role> [--branch <branch>]
  mail-helper.sh deregister --agent <id>
  mail-helper.sh agents [--active-only]
  mail-helper.sh receive [--transport <simplex|matrix|all>]  Poll remote transports
  mail-helper.sh transport-status                             Show transport status
  mail-helper.sh migrate                                      Migrate TOON files to SQLite

Message Types:
  task_dispatch   Coordinator assigns work to agent
  status_report   Agent reports progress/completion
  discovery       Agent shares a finding with others
  request         Agent requests help/info from another
  broadcast       Message to all agents

Transport Adapters:
  local           SQLite only (default, same-machine agents)
  simplex         Relay via SimpleX Chat (cross-machine, E2E encrypted)
  matrix          Relay via Matrix room (cross-machine, federated)
  all             Relay via all configured transports

Options:
  --priority      high|normal|low (default: normal)
  --convoy        Group related messages by convoy ID
  --transport     Override transport for this send (local|simplex|matrix|all)

Environment:
  AIDEVOPS_AGENT_ID              Override auto-detected agent identity
  AIDEVOPS_MAIL_DIR              Override mail directory location
  AIDEVOPS_MAIL_TRANSPORT        Default transport (local|simplex|matrix|all)
  AIDEVOPS_SIMPLEX_MAIL_GROUP    SimpleX group for mail relay (default: #aidevops-mail)
  AIDEVOPS_SIMPLEX_MAIL_CONTACT  SimpleX contact for mail relay (fallback)
  AIDEVOPS_MATRIX_MAIL_ROOM      Matrix room ID for mail relay

Lifecycle:
  send → check → read → archive (prune is manual with storage report)

Transport Flow:
  send: always stores locally, then relays via configured transport
  receive: polls remote transports, ingests into local SQLite (deduplicates)

Prune:
  mail-helper.sh prune                          Show storage report
  mail-helper.sh prune --force                  Delete archived messages >7 days old
  mail-helper.sh prune --older-than-days 30     Report with 30-day threshold
  mail-helper.sh prune --older-than-days 30 --force  Delete with 30-day threshold

Performance:
  SQLite WAL mode - <1ms queries at any scale (vs 25ms/message with files)
EOF
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	send) cmd_send "$@" ;;
	check) cmd_check "$@" ;;
	read) cmd_read_msg "$@" ;;
	archive) cmd_archive "$@" ;;
	prune) cmd_prune "$@" ;;
	status) cmd_status "$@" ;;
	register) cmd_register "$@" ;;
	deregister) cmd_deregister "$@" ;;
	agents) cmd_agents "$@" ;;
	receive) cmd_receive "$@" ;;
	transport-status) cmd_transport_status "$@" ;;
	migrate) cmd_migrate "$@" ;;
	help | --help | -h) show_usage ;;
	*)
		log_error "Unknown command: $command"
		show_usage
		return 1
		;;
	esac
}

main "$@"
