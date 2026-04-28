#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Mail Helper -- Orchestrator
# =============================================================================
# SQLite-backed inter-agent mailbox system with transport adapters.
# Enables asynchronous communication between parallel agent sessions.
# Supports transport adapters for cross-machine communication (SimpleX, Matrix).
#
# This is the thin orchestrator that sources sub-libraries:
#   - mail-helper-transport.sh   (envelope, transport send/receive/status)
#   - mail-helper-messages.sh    (send, check, read, archive)
#   - mail-helper-management.sh  (prune, status, register, agents, migrate)
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

# =============================================================================
# Core Functions (kept in orchestrator for identity-key stability)
# =============================================================================

#######################################
# SQLite wrapper: sets busy_timeout on every connection (t135.3)
# busy_timeout is per-connection and must be set each time
#######################################
db() {
	sqlite3 -cmd ".timeout 5000" "$@"
	return 0
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
	return 0
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
	return 0
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
	return 0
}

#######################################
# Escape single quotes for SQL
#######################################
sql_escape() {
	local input="$1"
	echo "${input//\'/\'\'}"
	return 0
}

# =============================================================================
# Source Sub-Libraries
# =============================================================================

# shellcheck source=./mail-helper-transport.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/mail-helper-transport.sh"

# shellcheck source=./mail-helper-messages.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/mail-helper-messages.sh"

# shellcheck source=./mail-helper-management.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/mail-helper-management.sh"

# =============================================================================
# Usage & Main
# =============================================================================

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
	return 0
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
